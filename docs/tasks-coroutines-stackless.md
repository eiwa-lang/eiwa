# Tasks — Coroutines Stackless (async/await estilo Kotlin) + remoção C/neco

> **Decisão de arquitetura (2026-08):** adotar **coroutines stackless** (estilo Kotlin) como o
> modelo de concorrência do Eiwa, substituindo o neco (stackful). Sem stack switching, o GC
> volta ao modelo conservador do backend C (provado a 200k iterações) e o crash de corrupção
> de raiz GC desaparece **sem precisar de shadow stack**. Remover backend C + neco + `@MainWrapper`.
>
> Origem: `docs/tasks-shadow-stack-gc.md` (Path 1) — este arquivo substitui a Fase 4 daquele
> plano: em vez de shadow stack, a transformação de coroutines stackless elimina a necessidade
> dela. Manter a decisão de remover C/neco.

**Objetivo:** coroutines leves, idioma Kotlin: `suspend fun`, `await()`, `task {}` — o
compilador transforma funções suspensas em **state machines** (objeto `Continuation` no heap),
sem C runtime de coroutines, com GC trivially seguro (estado suspenso = objeto heap, nada de
escanear stack).

---

## Por que stackless resolve o problema do crash

- O crash veio de raízes GC em stacks de corrotinas neco (`GC_add_roots` + `GC_set_stackbottom`).
- Stackless **não tem stack switching**: o estado suspenso vive em objetos heap
  (`Continuation`), alcançáveis por ponteiros — varredura conservadora normal.
- Programa roda na stack do OS main thread (modelo do backend C). `GC_init` + varredura nativa
  cobrem tudo. Shadow stack vira **opcional/futuro**, não pré-requisito.

---

## Modelo de linguagem (sintaxe Kotlin-inspired)

```kotlin
suspend fun fetchData(): String {
    val resp = await(http.get("/users"))   // ponto de suspensão
    return resp
}

fun main() {
    val task = task { fetchData() }        // task {} retorna Task<T>
    val data = task.await()                // suspende até concluir
}
```

- **`suspend fun`**: nova palavra-chave. Função que pode suspender. Só chamável de contexto
  suspend (regra de type checking, como Kotlin).
- **`await()`**: método suspend em `Task<T>`/`Deferred<T>` — vira o ponto de suspensão.
- **`task { }`**: cria e agenda um `Task<T>` (continuação raiz).
- **`Coroutine.sleep`/`delay`**: suspensão por tempo.
- **I/O**: `EventLoop.waitReadable/waitWritable` → baseados em `poll()` no scheduler
  (não bloqueante).

---

## Protocolo de suspensão (Kotlin model)

- Cada função suspend vira um `Continuation` heap-allocated com campo `label: Int` + locais
  promovidos + `result` + `exception`.
- Corpo reescrito como `resume(cont)` com `switch (label)`:
  - **fast path**: chamadas que completam síncronamente continuam sem devolver controle;
  - **suspensão**: o callee retorna o sentinel `COROUTINE_SUSPENDED`; o caller salva label +
    locais vivos e devolve controle ao scheduler.
- Função suspend retorna: `Continuation*` se completou síncrono (via campo result) ou o
  sentinel `COROUTINE_SUSPENDED` (null ptr) se suspendeu. Caller testa o retorno.
- Conclusão: grava `cont.result`, marca done, agenda os waiters (cadeia de continuations).

---

## Fases

## Fase A — Detecção por inferência (sem keyword) — ✅ CONCLUÍDA (2026-08)

> **Decisão (2026-08):** sem keyword `suspend`. O compilador **infere** funções suspend pelo
> fecho transitivo sobre chamadas a métodos `@Suspend` do stdlib. Superfície da linguagem
> inalterada (`task {}`/`await()`/`sleep()` como hoje).

- [x] Annotations no stdlib: `@Suspend` em `Task.await()`, `Coroutine.sleep/sleepMs/yield`,
      `EventLoop.waitReadable/waitWritable`, e no contrato `Awaitable.await()`;
      `@Coroutine` em `task<T>` (`src/std/coroutines.ei`, `src/std/core.ei`).
- [x] AST (`src/core/ast.zig`): `fun_decl.is_suspend` (setado pelo pass) e
      `call_expr.is_suspend_call`.
- [x] Parser: contract methods aceitam annotations (`declaration.zig`).

## Fase B — Type checking / detecção (passo pós-typecheck) — ✅ CONCLUÍDA (2026-08)

- [x] `src/core/coroutines.zig` `detectSuspendFunctions()`: seeds `@Suspend`, fecho transitivo,
      regra de fronteira `@Coroutine` (suspensão dentro de lambda `task {}` não propaga).
- [x] **Resolução por declaração**: call sites com receiver de contrato (ex.: `Awaitable<T>`
      retornado por `task {}`) não têm `resolved_c_name` — o pass resolve o método por
      receiver type + nome (`isSuspendDecl`/`findMethodHasSuspend`).
- [x] Integração em `src/main.zig` após type checking, antes do backend.
- [x] Validado: `main` com `task { }`/`await()` → `is_suspend=true`; os `await()` →
      `is_suspend_call=true`; sem falsos positivos (o sample de validação `task_sample.ei`,
      neco-era, foi removido na Fase F — a detecção segue coberta por `task_test`/
      `task_transform_test`).

## Fase C — Transformação AST → state machine (o núcleo, `src/core/coroutines.zig`) — ✅ CONCLUÍDA (2026-08)

Passo novo **entre type checking e emissão**: recebe AST resolvido, reescreve cada função
suspend em uma state machine (gera AST novo consumido pelo emitter).

1. [x] **Identificar pontos de suspensão**: `call_expr` marcados na Fase B. (transform Fase C/P1
      reescreve `task {}`/`<recv>.await()` via `src/core/coroutines_transform.zig`.)
2. [x] **Promoção de locais**: `collectCaptures` coleta variáveis livres do bloco
      (`identifier` com `resolved_type` e não declaradas dentro do bloco) e as vira campos
      do `Continuation` gerado (`buildTaskBlockType`). **Conservador**: todo identificador
      livre vira campo (não há análise de liveness). Campos capturados são `var` (mutáveis)
      para suportar acumuladores/assignments dentro do task. `var` mutável capturado é
      re-boxed no call site do ctor (`CapturedVar.is_boxed`) para que o emitter faça
      double-deref e passe o **valor** (não o box pointer) para o campo — ver fix em
      `infer_decl.zig` (`inferVarDecl` restaura `is_boxed` ao re-declarar o símbolo).
3. [x] **Gerar struct `Continuation`**: `{ label, saved_locals..., result: T?, exception,
      next_waiter }`. — o transform gera `__TaskBlockN { task: StackTask<T>, <capturadas...>,
      <body_fields (locais + label)>, }` com `resume()`/`isDone()`; a dispatch por `label`
      (state machine) foi implementada na Fase J.
4. [x] **Reescrever corpo** em `resume(cont)` com `switch(label)`:
      cada estado = trecho retilíneo até o próximo ponto de suspensão; transições explícitas
      `this.label = <next>`. Bodies com `sleep`/`sleepMs`/`yield` viram state machine (Fase J);
      bodies sem suspensão real seguem single-shot (um único `resume()`, sem `switch`) — e
      `await()` em state machines suspende via waiter-chain (Fase K).
5. [x] **Conclusão**: gravar `result`, done, despachar waiters. (em `buildResume` — mark done,
      reschedule dos waiters via `Scheduler.schedule`, clear da lista.)
6. [x] **`task { }`**: continuação raiz + agendamento no scheduler. (transform gera
      `__TaskBlockN(StackTask<T>(false,null,null))` + `Scheduler.schedule(...)`.)

Casos em ordem:
- [x] P1 — corpo retilíneo com `await()` simples, sem loops/try. **CONCLUÍDO (2026-08)**:
      reescreve `val x = task { bloco }`, `val x = <recv>.await()` e `return <recv>.await()`
      (var_decl/return em corpos de `fun`); block splices no `resume()`; re-valida via
      `inferFunDecl`; tail (tipos gerados + monomorfizados) inserido em `program.statements`
      após os imports. Validado: `samples/tests/task_transform_test.ei` (3 testes passam) e
      `stackless_task_test.ei`. Erros de linguagem não claros viram mensagens com
      `file:line` + ponteiro para o desenvolvedor final.
- [x] P2 — loops com suspensão + await como operando. **CONCLUÍDO (2026-08)**:
      `rewriteStatements` desce recursivamente em `block`/`if`/`while`/`for`/`try`
      (nested tasks dentro de loops viram continuações próprias); awaits usados como
      operando (`inner.await() + 100`) são **hoisted** em `val __awaitN = <recv>.await()`
      precedentes (`containsAwait`/`hoistAwaitsFromExpr`) e substituídos por identificadores.
      Captura de `var` mutável funciona (ver item 2 — fix boxed no ctor arg). Validado:
      `samples/tests/task_transform_test.ei` **6/6** (inclui `nestedTask`,
      `inlineTaskAwait`, `loopWithAwait`) + `total = total + task{}.await()` (assignment
      com await no valor). Gaps adiados: `continue`/`break` dentro de task com suspensão;
      await como receiver de composite (`task{}.await()` como operando de outra expressão).
- [x] P3 — `try/catch` atravessando suspensão (estado de exceção + resume na exceção).
      **CONCLUÍDO (2026-08)**: `rewriteStatement` desce em `try_stmt` (body + catches);
      o `throw` após uma suspensão (await hoisted dentro do try) é capturado pelo `catch`
      quando o resume roda via Scheduler. Fix de aliasing adicional em `rewriteCapturedRefs`
      `.assignment` (captura local de `name`/`value` antes de sobrescrever `node.data` —
      mesmo bug do `.identifier`) e preservação de `is_mut` nos binds de `rewriteAwaitCall`/
      `rewriteTaskAwaitCall`. Validado: `samples/tests/task_transform_test.ei` **8/8**
      (novos: `tryCatchAfterSuspend` == 99, `tryWithAwaitNoThrow` == 42) +
      `TaskCalculator.tryCatchInMethod` == 42 (o debug `task_p3_debug.ei` foi removido na
      Fase F). Limitação conhecida: `try/catch` como última
      expressão do bloco não vira resultado do task (`blockReturnType` não trata
      `try_stmt` como expr — usar variável capturada + trailing, como nos testes).
- [x] P4 — `Task<T>` genérico, `await` em tipos genéricos, suspend em métodos de type.
      **CONCLUÍDO (2026-08)**: `transformModule` agora processa `type_decl.methods` e
      `object_decl.members` além de funções top-level: extrai `rewriteFunctionBody` (reescreve
      o corpo sem re-validar) e re-infere o `type_decl`/`object_decl` inteiro via
      `inferTypeDecl`/`inferObjectDecl` para resolver o machinery no escopo de classe (`this`).
      Fix crítico: `clearResolvedTypes` ganhou cases `.type_decl`/`.object_decl` (antes não
      descia aos métodos — os `var_decl` reescritos ficavam sem `resolved_type` e o emitter
      falhava `MissingTypeForVarDecl`). Validado: `samples/tests/task_transform_test.ei` **12/12**
      (novos: `TaskCalculator.doubleOf` == 42, `sumOfTask` == 30, `tryCatchInMethod` == 42,
      `TaskBoxer<T>.identity` em `Int` e `String`).
- [x] P5 — `Task<T>` exposto na stdlib stackless (remover `Task<T>`/`Awaitable` neco),
      `Coroutine.sleep/delay` sobre o Scheduler (timer heap), I/O via `poll`.
      **CONCLUÍDO (2026-08, parcial)**: `src/std/coroutines.ei` foi reescrito **sem neco**
      (stackful): removidos `lib Neco` + `@MainWrapper` + `Task<T>`/`Taskable`/`TaskableCoroutine`
      neco; `task<T>` agora retorna `StackTask<T> : Awaitable<T>` (o entry sem `@MainWrapper` é
      `main`/`eiwa_test_main` direto, e o `Scheduler`/`StackTask` stackless seguem). `Coroutine.sleep/
      sleepMs` usam `nanosleep` (FFI), `yield` usa `sched_yield`, `EventLoop.waitReadable/waitWritable`
      usam `poll` (FFI) — todos via primitivas de sistema, sem neco. Fixes no transform:
      processa corpos de `test_decl` (task/await direto em `test {}`), `clearResolvedTypes` cobre
      `.test_decl`, e `buildResume` não consome assignment/set como valor de retorno (`isValueStatement`
      — tasks Void executam a última stmt por efeito, sem `this.task.result`). Validado:
      `task_test.ei` **14/14** (reescrito p/ modelo stackless), suíte `samples/tests` 64/2.
      **Propagação de writes em vars capturadas implementada**: campo capturado boxed é
      declarado com `ClassProp.is_boxed`, o ctor do `__TaskBlockN` recebe o **box pointer**
      (`identifier.is_box_ref` — single deref no call site), e o get/set de `this.<name>`
      no resume faz double-deref (`get_expr`/`set_expr` `.is_boxed`). Writes dentro do task
      agora voltam para a var externa (paridade com closures). **Semântica lazy**: o corpo do
      task não roda na criação (`task {}` só cria + agenda); roda no primeiro `await()`
      (`Scheduler.run()`). Diferente do neco (eager, `.start()` imediato). Gaps adiados:
      **timer heap cooperativo** (sleep hoje bloqueia o thread via nanosleep — verdadeira
      suspensão exige switch(label), Fase D).
      **Scheduler melhorado (await não acopla tasks independentes)**: `buildPollStmt` gera
      `while (!recv.done && Scheduler.runStep())` — roda só até a tarefa aguardada completar,
      deixando tasks independentes na fila para o próprio await (novo `Scheduler.runStep()`).
      **Drain de fire-and-forget**: `transformModule` agora transforma funções com `task{}`
      mesmo sem `is_suspend` (main com `task{}` sem await), e anexa `Scheduler.run()` no final
      do `main` e de cada `test {}` — tasks agendados mas nunca awaitados ainda rodam antes do
      programa terminar. Validado: `task_test.ei` **16/16** (novos: `independent tasks are not
      coupled by await`, `fire-and-forget task runs on the main scheduler drain`).
      TODO: **box de 16 bytes fixo** (`statement.zig` `cell_size = 16`) — o cell heap de vars
      boxed tem tamanho fixo que cabe fat pointer/i64/ptr/double, mas pode estourar para tipos
      custom grandes; alocar `LLVMStoreSizeOfType` (pré-existente nos closures, estender no P5).
      TODO: **object static String concat crasha** (`"x" + Obj.v` onde `v: String`) — bug
      pré-existente do emitter, não relacionado a coroutines; investigar emissão de get_expr
      de campo String de object em concat.
      TODO: **interleave de loops com sleep** — `samples/tests/interleave_test.ei` (dois
      `task { while { log+="A"; sleepMs(1) } }`/`"B"`), que falhava de propósito no modelo
      blocking-poll (`AAABBB`), **PASSA desde a Fase J** (`ABABAB` — switch(label) + timer
      heap cooperativo). Deletado `samples/task_loop.ei` (era demonstração neco stackful com
      2 loops infinitos que travava no modelo stackless).

## Fase D — Emissão LLVM — ✅ CONCLUÍDA (2026-08)

- [x] Emitir o struct `Continuation` (via structs existentes) + função `resume` (via
      `emitFunctionBody` reaproveitado sobre o AST transformado). — o transform gera
      `__TaskBlockN` (com `resume()`/`isDone()`), declarados via `declareType`/emitidos
      como métodos normais; validado em `task_transform_test`/`task_test`.
- [x] Emitir calls do runtime: `scheduler_schedule/resume/suspend`, `COROUTINE_SUSPENDED`. —
      `Scheduler.schedule`/`Scheduler.run`/`runStep`/`sleep`/`yield` são emitidos como calls
      Eiwa normais; `switch(label)` é usado nas state machines (Fase J). O sentinel
      `COROUTINE_SUSPENDED` **não é usado**: `resume()` é `Void` e a suspensão é sinalizada
      por auto-re-agendamento.
- [x] Entry de `main`/`eiwa_test_main`: rodar `scheduler_run()` (event loop) até vazio. —
      sem `@MainWrapper`, o entry é `main`/`eiwa_test_main` direto; `Scheduler.run()` é
      chamado no final (drain de fire-and-forget, ver Fase C/P5). O loop atual de setjmp
      p/ exceções dentro de cada teste é **mantido** (não substituído por coroutines).
- [x] Global ctor `__eiwa_gc_init_ctor` + `GC_init` host-side seguem como estão. — ctor
      emitido quando `prefer_gc_alloc` (builds nativos); JIT chama `GC_init` do host.

## Fase E — Scheduler runtime **em Eiwa** (sem arquivo C) — ✅ CONCLUÍDA (2026-08)

> **Decisão (2026-08):** o scheduler é escrito em **Eiwa puro**, não em C. As únicas
> primitivas de sistema (`poll()` para I/O, `clock_gettime` para timers) são alcançadas
> pelo FFI já existente (`lib` + `@Header`/`@Alias`), igual ao padrão de `time.ei`
> (`NativeTime.time()`). Nenhum `eiwa_scheduler.c` é criado.

- [x] `src/std/coroutines.ei`: base do scheduler Eiwa (sem neco) — ✅ CONCLUÍDA (2026-08):
  - [x] `contract Continuation { resume(), isDone() }` — state machine gerada pelo compilador.
  - [x] `object Scheduler` com `schedule(cont)`/`run()`/`runStep()` — fila FIFO **linked
        list intrusiva** (`type ContNode(val cont: Continuation, var next: ContNode?)`), NÃO
        `MutableList` (o backend LLVM ainda não armazena fat pointers em coleções genéricas).
  - [x] Validado com continuations escritas à mão: interleaving cooperativo FIFO correto
        (`samples/tests/scheduler_test.ei`).
  - [x] `type StackTask<T>(done, result, waiters)` — o "Continuation concreto" que o transform
        usa (com `await`/`awaitCoop`/`isDone` implementando `Awaitable<T>`).
  - [x] `Task<T>`/`task {}`/`Coroutine.*`/`EventLoop.*` reescritos sobre o Scheduler/FFI
        (Fase C/P5): `task<T>` retorna `StackTask<T>`; `Coroutine.sleep/sleepMs` via
        `nanosleep`, `yield` via `sched_yield`, `EventLoop.waitReadable/waitWritable` via `poll`.
  - [x] **Timer heap cooperativo** para `sleep/delay` — implementado na **Fase J**:
        `TimerNode(deadline, cont, next)` em lista ordenada, `Scheduler.now` (relógio virtual
        ms), `fireTimers()` (bloqueia só quando nada está pronto) e re-agendamento das tasks
        vencidas. `Coroutine.sleep/sleepMs` **fora** do corpo de task continuam bloqueando
        (nanosleep); **dentro**, o transform os reescreve em `Scheduler.sleep(this, ...)`
        (suspensão verdadeira). Aceite: `samples/tests/interleave_test.ei` (`ABABAB`).
- [x] `src/std/system.ei` (sleep/yield) — reescrito sobre o novo `Coroutine`; `net.ei`
      (poll bloqueante) — usa `EventLoop` (poll); `db.ei` — `Coroutine.yield` (sched_yield).

## Fase F — Remover backend C + neco + @MainWrapper — ✅ CONCLUÍDA (2026-08)

(mesmo escopo do plano anterior — agora seguro, pois o stdlib não depende mais de neco)

- [x] Deletar `src/backend/c_transpiler/`, flag `--backend=c`, `BackendKind.c`, path
      CTranspiler em `main.zig`; LLVM obrigatório (`build.zig` erro sem LLVM).
- [x] Deletar `src/runtime/third_party/neco/` (o `src/std/coroutines.ei` antigo stackful já
      havia sido reescrito stackless nas Fases C/P5/E).
- [x] Remover mecanismo `@MainWrapper` (`main_wrapper_c_names`, `emitMainWrapperEntry`,
      shims); entry = `main`/`eiwa_test_main` direto (drain via `Scheduler.run()`).
- [x] `cli/src/main.ei`: sem forwarding de `--backend` (o help/CLI usa só `eiwac`).
- [x] `samples`: deletados `task_sample.ei` (demo neco), `task_loop.ei` (stackful, já antes),
      `main_wrapper_sample.ei` (usava `@MainWrapper` removido) e `task_p3_debug.ei` (debug
      redundante com `tryCatchInMethod`). `task_test.ei` foi **reescrito stackless** (16/16).
- [x] Comentários mortos: removidas as ~20 referências a `src/backend/c_transpiler/*.zig` nos
      comentários do emitter (mantida a nota de proveniência "original C backend").
- [x] `core.ei`: **MANTER `Awaitable<T>` como interface enxuta** — `@Suspend await(): T` +
      `isDone(): Bool` (SEM `start()`, que era no-op neco); `StackTask<T>` o implementa.
      O compilador resolve `await`/`isDone` por receiver type + nome.

## Fase G — Validação — ✅ CONCLUÍDA (2026-08)

- [x] `zig build`, `zig build test` — verdes.
- [x] `./bin/eiwac test samples/tests` → **68 PASS, 2 FAIL** (as 2 falhas são as
      pré-existentes `contract_collection_storage_test`/`closure_struct_field_test`, não
      relacionadas a coroutines).
- [x] Stress tests originais (concat/array a 20k+) passam (`samples/tests/gc_stress_test.ei`).
- [x] `samples/tests/task_test.ei` reescrito stackless (16/16) + `task_transform_test` (12/12)
      + `interleave_test` (`ABABAB`) + `yield_test` + `scheduler_test` + `body_fields_test`
      + `coop_await_test` — verdes.
- [x] `./bin/eiwac run samples/main.ei` e `./bin/eiwac build samples/main.ei -o /tmp/t && /tmp/t`.
- [~] `http_sample.ei` — **cliente** (GET/POST via libcurl) passa; **servidor** agora serve
      (RESOLVIDO 2026-08 — ver gaps: object init em run/build, dispatch de método em `Pointer`,
      `startsWith`/`endsWith` inline, `task {}` statement + drain no arest). O exemplo `home`
      (arest) serve página, fragments e static assets em nativo e JIT.
- [x] Performance: fast path de `task{}`+`await` simples ≈ chamada direta (state machine
      single-shot roda num único resume; overhead é o schedule/poll mínimo).

## Fase H — Docs — ✅ CONCLUÍDA (2026-08)

- [x] `AGENTS.md`: LLVM como único backend, coroutines stackless, mapa de módulos
      (`coroutines.zig`/`coroutines_transform.zig`), `src/std/coroutines.ei`.
- [x] `architecture.md`: seção "Coroutines Stackless" no Core.
- [x] `roadmap.md`: **Phase 68** (coroutines stackless, IN PROGRESS) como fase atual; fases
      20/36/51/65 marcadas/superseded (neco/fibras/`@MainWrapper` em remoção).
- [x] `docs/decisions.md`: **ADR 48** — "Coroutines stackless (Kotlin-style); remoção C + neco".
- [x] `docs/language_tour.md`: seção 20 reescrita para o modelo stackless (`StackTask<T>`,
      state machines, waiter-chain, gaps).
- [x] `docs/tasks-backend-parity.md` + `docs/bloco-b-handoff.md`: marcados obsoletos/superseded
      (parity index renomeado de propósito como índice `TODO(emitter)`; Bloco B já implementado).
      Removidos `tasks-bloco-b-gc-jit.md` e `tasks-shadow-stack-gc.md` (superseded).
- [x] Limpar `gc_s1/ gc_s1a/ gc_s1b/ gc_s2/ gc_s3/ gc_stress_tmp/` (testes
      estáveis consolidados em `samples/tests/gc_stress_test.ei`).

## Fase I — Dispatchers / thread pool (paralelismo real, estilo Kotlin) — PLANEJADA como Phase 69

> **Origem (2026-08):** o Eiwa implementa coroutines **cooperativas single-thread**
> (equivalente ao `Dispatchers.Main`/`Unconfined` do Kotlin). Para paralelismo real
> (como `Dispatchers.Default`/`IO` do Kotlin ou goroutines do Go), é preciso um
> dispatcher + thread pool.
>
> **Status (2026-08):** promovida de **proposta adiada** a **plano operacional completo** —
> ver **Phase 69** em [`docs/roadmap.md`](roadmap.md) (tabela Kotlin × Eiwa, etapas 0–6,
> riscos). Resumo dos itens abaixo; o detalhamento por tarefa está no roadmap.

- [ ] **Conceito de `Dispatcher`**: contexto onde um `task {}` roda. Por padrão
      `Dispatcher.Single` (o scheduler atual, single-thread). Futuro: `Dispatcher.Default`
      (thread pool = nº de cores), `Dispatcher.IO`.
- [ ] **Scheduler por pool**: hoje `Scheduler` é um singleton global. Para paralelismo,
      cada dispatcher tem sua própria fila + event loop numa thread OS dedicada. `await()`
      precisa esperar **entre** threads (notificação/cross-thread), não só `runStep()` local.
- [ ] **Sincronização de estado compartilhado**: tasks em threads diferentes acessam o
      mesmo `StackTask`/box/var capturada — exige locks/atomics para `done`/`result`/`waiters`
      e para vars boxed. Este é o maior risco de corretude (data races).
- [ ] **GC multithread**: Boehm GC já suporta threads (`GC_allow_register_threads` +
      `GC_register_my_thread`), mas o registro de raízes do JIT (`registerJITGlobalsAsRoots`)
      e as stacks de múltiplas threads precisam ser revisados.
- [ ] **Semântica**: `task {}` num dispatcher paralelo roda **eager** (como Go/Kotlin
      Default: agenda + roda na thread do pool); **lazy** no single (atual).
- [ ] **Como o programador escolhe**: `task(Dispatcher.Default) { ... }` ou
      `withDispatcher { }` — alinhado ao `withContext` do Kotlin.
- [ ] **Validar**: benchmark de CPU-bound (ex: N-Body paralelo) vs single-thread;
      suíte existente continua verde no `Dispatcher.Single` (default).

**Decisão:** implementar como **Phase 69** no roadmap (etapas 0–6: threads FFI/atomics →
`Scheduler` como instância → pool por dispatcher → await cross-thread → GC multithread →
API/semântica → validação/benchmark). **Pré-requisitos concluídos:** Fase J (suspensão
verdadeira) e Fase K (await cooperativo / waiter-chain) — sem elas, "paralelismo" seria
só bloqueio de thread.

---

## Fase J — Suspensão verdadeira: `switch(label)` + timer heap cooperativo — ✅ CONCLUÍDA (2026-08)

> **Estado final:** task bodies com pontos de suspensão reais (`sleep`/`sleepMs`/`yield`)
> são transformados em **state machines** (`switch(label)` via dispatch `if (label==N)` em
> `while(true)`); o Scheduler ganhou **timer heap** (lista ordenada por deadline + relógio
> virtual) e `runStep`/`run` timer-aware. `samples/tests/interleave_test.ei` passa
> (`ABABAB`). `await()` permanece blocking-poll no root; suspensão real acontece **dentro**
> do corpo do task (que é o que o teste de aceite exige).

**Diferença `yield()` × `delay()`/`sleep()` (semântica alvo, Kotlin-style):**

- **`yield()`** = justiça (fairness), sem dimensão temporal. Re-enfileira a continuação na
  fila **de prontas** e retorna `COROUTINE_SUSPENDED` — outra coroutine pronta roda agora,
  e esta volta na próxima oportunidade. (`Scheduler.schedule(this); return SUSPENDED`)
- **`delay()`/`sleep()`** = suspensão **por tempo**. Não volta para a fila de prontas; entra
  num **timer heap** e só é re-agendada quando o relógio dispara. O scheduler segue rodando
  outras coroutines enquanto isso. (`TimerHeap.schedule(this, now + ms); return SUSPENDED`)

### Checklist

- [x] **Transform `switch(label)`** (Fase C item 4): task bodies com `sleep`/`sleepMs`/`yield`
      viram state machine em `resume()` (`while(true)` + dispatch `if (this.label == N)`).
      Cada estado = trecho retilíneo até o próximo ponto de suspensão; transições explícitas
      `this.label = <next>`. O builder CFG roda em **ordem reversa** (last→first, threading o
      "after"); statements plain viram estados próprios (sem merge, para não corromper joins
      de controle de fluxo). `continue`/`break` não existem na linguagem; `for`/`try` com
      suspensão dentro são GAPS (erro `file:line`). Awaits continuam blocking-poll.
- [x] **Locais promovidos a `body_fields`**: novos campos `var`/`val` no corpo do `type`
      (feature nova, Kotlin-style) — o continuation do task ganha `var label: Int = <entry>`
      + um campo por local do corpo (default: 0/0.0/false/""/null). `val` exige initializer;
      `var` não-null exige initializer; `var`/`val` nullable omitem → null. Atribuir a `val`
      é erro de tipo.
- [x] **`TimerHeap` no `Scheduler`** (Fase E): `TimerNode(deadline, cont, next)` em lista
      ordenada; `Scheduler.now` = relógio virtual (ms, avança pelos próprios waits);
      `fireTimers()` bloqueia (nanosleep) até o deadline mais próximo e move vencidos para a
      fila de prontas. `runStep`/`run` timer-aware (`await`-poll continua funcionando).
- [x] **`Coroutine.sleep/sleepMs`/`yield` como pontos de suspensão**: no corpo do task o
      transform reescreve `sleepMs(x)`→`Scheduler.sleep(this, x)`, `sleep(x)`→
      `Scheduler.sleep(this, x/1e6)`, `yield()`→`Scheduler.yield(this)`, seguidos de
      `this.label = <next>; return`. O `Continuation.resume()` **permanece `Void`** (sem
      sentinel): a suspensão é sinalizada por auto-re-agendamento; conclusão via
      `task.done = true`. Isso evita adaptar `scheduler_test.ei` (guardrail).
- [x] **`interleave_test.ei` passa** (`ABABAB`) — critério de aceite da fase.
- [x] **Regressão**: suíte `samples/tests` **67 PASS, 2 FAIL** (as 2 falhas são as
      pré-existentes `contract_collection_storage_test`/`closure_struct_field_test`,
      não relacionadas a coroutines). `body_fields_test.ei` (5) e `yield_test.ei` (1) novos.
- [x] **Fix — tasks genuinamente `Task<Void>` não rodavam o corpo** (bug pré-existente
      mascarado pelos `task { ...; 1 }` de `interleave_test`): o hoist do await gerava
      `val __awaitN = <task>.result!!` que, para um task `Void` (`Void? !!` → Void), virava
      um `var` de tipo Void; o emitter (`statement.zig` var_decl) só avaliava o initializer
      por efeito **sem criar binding no scope** → a referência posterior a `__awaitN` falhava
      com `VariableNotFound` e o `emitFunctionBodyOrStub` stubbava a função inteira
      silenciosamente (retornando `false`/nada). **Correção:** o emitter agora liga o nome
      de vars Void a um dummy no scope. `interleave_test`/`yield_test` são `Task<Void>`
      (sem retorno numérico).

### Notas

- O `EventLoop.waitReadable/waitWritable` (via `poll`) pode ficar para uma fase seguinte:
  esperar readiness é o mesmo mecanismo do timer heap (uma lista de "waiters de I/O").
- **`await()` cooperativo (waiter-chain) dentro do corpo do task — ✅ CONCLUÍDO (2026-08).**
  Ver Fase K abaixo. `await()` continua blocking-poll **no root** (main/test/top-level — o
  root é o driver) e em task bodies **single-shot** (sem sleep/yield — o poll acoplado não
  faz mal). Dentro de um task body **state machine** (com sleep/yield), o await registra o
  caller como waiter e suspende (ver Fase K).
- **Habilita a Fase I** (dispatchers/thread pool): a waiter-chain é o pré-requisito da espera
  cross-thread. Ainda falta a Fase I em si (thread pool, sincronização de estado, GC
  multithread) — continua sendo **PROPOSTA, não o modelo atual**.
- **Fix — erros de compilação sem backtrace Zig:** o pipeline de `main.zig` era `!void`
  e deixava erros de tipo/emissão propagarem para o runtime do Zig, que imprimia
  `error: TypeError` + stack trace nativo depois da mensagem Eiwa limpa. `main` agora é um
  wrapper que chama `run()` e, em erro, imprime `Error: compilation failed (<name>).` e
  `exit(1)` — sem stack trace Zig. A mensagem Eiwa (REPORT_ERROR com file:line:col) já foi
  impressa antes do erro propagar.

---

## Fase K — `await()` cooperativo (waiter-chain) dentro do corpo do task — ✅ CONCLUÍDA (2026-08)

> **Estado final:** dentro de um task body **state machine** (corpo com `sleep`/`sleepMs`/
> `yield`), `await()` deixa de ser blocking-poll e vira uma **suspensão cooperativa**: o
> caller registra o próprio continuation como **waiter** da task aguardada e devolve o
> controle ao scheduler (`this.label = <read>; return`). Quando a task aguardada completa,
> seu done state reschedule os waiters (FIFO). `samples/tests/coop_await_test.ei` (4 testes)
> verde: valor após yield, valor após sleep com inner task lazy, result String, e **dois
> tasks aguardando a MESMA task** retomados em FIFO (`S12`, r1=43, r2=44).

### Mecanismo

- `src/std/coroutines.ei` — `StackTask.awaitCoop(cont: Continuation): Bool`: fast path
  `done` → `true`; senão **append** `WaiterNode(cont, null)` na cauda da waiter chain (FIFO,
  para casar com a iteração head→tail do done state) e `false`. Método normal (NÃO
  `implement` — não faz parte de `Awaitable<T>`).
- `src/core/coroutines_transform.zig` — modo `coop` encadeado por `rewriteStatements`/
  `rewriteStatement`/`rewritePreamble`/`rewriteBranch` (single-shot/root passam `false`,
  `buildResumeStateMachine` passa `true`):
  - `rewriteAwaitCall`/`rewriteTaskAwaitCall` em modo coop geram o marker
    `val <name> = __CoopAwait(<recv>)` (com `type_ref` do result type — `stmt.resolved_type`
    ou `singleTypeArg(recv.resolved_type)`; `hoistAwaitsWalk` preserva `decl.resolved_type`).
  - `machineBuildStmt` detecta o marker (`isCoopAwaitMarker`) e chama
    `machineBuildCoopAwait`: dois estados —
    **guard**: `if (!<recv>.awaitCoop(this)) { this.label = <read>; return }` /
    `this.label = <read>`;
    **read**: `this.<name> = <recv>.result!!` (fast path quando já done) / `this.label = <after>`.
  - **Promoção de novos locais**: `collectNewLocals` promove vars criadas pela machinery
    (`__taskN`, binds como `inner`, `__awaitN`) a **body fields** (precisam sobreviver entre
    estados — cada statement vira um estado próprio, sem merge). `fieldInitializerForTypeRef`
    dá o default (primitivos/nullable via `defaultInitializerForTypeRef`; `StackTask<T>`
    via `StackTask<T>(false, null, null)`). Depois `rewritePromotedRefs(new_locals)` reescreve
    refs (`__taskN`→`this.__taskN`) e converte os var_decls em `this.<name> = ...`.
  - **Fix de RHS não reescrito**: `rewritePromotedRefs`/`rewriteCapturedRefs` nos casos
    `.var_decl` e `.assignment` agora reescrevem as refs do **initializer/value primeiro**
    antes de converter para `set_expr`. Sem isso, `acc = inner.await() + acc` virava
    `this.acc = inner.await() + acc` com `acc` **sem** `this.` no RHS → resolvia como class
    property no resume() e o emitter lia o **box pointer** (lixo) em vez do valor boxed.
  - **Ordem de splice**: `transformModule` agora spliceia tipos **monomorfizados primeiro**
    (ex.: `StackTask<Int>`) e continuações depois. `declareType` emite o corpo do ctor
    inline; o ctor do `__TaskBlockN` avalia os initializers de body fields (chamadas a
    `StackTask<T>(...)`), então o tipo callee precisa estar declarado antes — senão
    `VariableNotFound: coroutines_StackTask_Int` na emissão.

### Checklist

- [x] `StackTask.awaitCoop(cont)` — append FIFO na waiter chain + fast path.
- [x] Modo `coop` no transform; marker `__CoopAwait`; guard/read states no CFG.
- [x] Promoção de novos locais da machinery a body fields (`collectNewLocals`).
- [x] Fix RHS nos `.var_decl`/`.assignment` de `rewritePromotedRefs`/`rewriteCapturedRefs`.
- [x] Ordem de splice: monomorfizados antes das continuações.
- [x] `coop_await_test.ei` (4 testes) verde; suíte `samples/tests` **68 PASS, 2 FAIL** (as 2
      falhas continuam sendo `contract_collection_storage_test`/`closure_struct_field_test`,
      pré-existentes). `interleave_test` (`ABABAB`), `yield_test`, `task_test`,
      `task_transform_test`, `scheduler_test`, `body_fields_test` verdes.
- [x] `zig build` + `zig build test` verdes.

### Notas / limitações (Fase K)

- **`await()` em task body single-shot continua blocking-poll** (sem sleep/yield não há state
  machine; o poll reentrante funciona e não há outros tasks cooperativos para estrelvar).
  Fazer awaits dispararem state machine é uma extensão futura, não o alvo desta fase.
- `return <recv>.await()` dentro de corpo de task segue como **gap** (retorno prematuro do
  `resume()`). `await` como operando dentro de `assignment` não é hoisted (falta caso
  `.assignment` em `hoistAwaitsWalk`) — o `inner.await()` fica como chamada direta (bloqueia
  via `Scheduler.run()`, funciona, mas não suspende).
- `__CoopAwait`/`__TaskBlockN`/`__taskN`/`__awaitN` são nomes **internos do transform**,
  consumidos antes da emissão (a golden rule "sem special cases por nome" refere-se ao
  **emitter**/runtime — `__cblambda`, `__TaskBlock` — não ao transform, que já usa esses
  nomes gerados).

---

### Handoff — estado final do plano

> Este bloco consolida o estado real do código depois que o plano foi **concluído**
> (Fases A–H). Leia TODO este arquivo antes de mexer em qualquer coisa de
> coroutines/concorrência (AGENTS.md, decisões acima, Fases C/D/E/F/J/K).

**Estado da suíte (baseline):** `./bin/eiwac test samples/tests` → **68 test files PASS, 2 FAIL**.
As 2 falhas são `contract_collection_storage_test.ei` e `closure_struct_field_test.ei`
(**pré-existentes, NÃO relacionadas a coroutines**). `interleave_test.ei` **PASSA** (`ABABAB`),
`yield_test.ei` (3 testes) verde, `coop_await_test.ei` (4 testes) verde. `git status` limpo.

**Comandos:** `zig build` | `./bin/eiwac test samples/tests` |
`./bin/eiwac test samples/tests/coop_await_test.ei` | `./bin/eiwac test samples/tests/interleave_test.ei` |
`./bin/eiwac test samples/tests/yield_test.ei`.

**Fechado:** backend C + neco + `@MainWrapper` removidos; LLVM único backend; scheduler em
Eiwa puro; suspensão verdadeira (`switch(label)` + timer heap); `await()` cooperativo
(waiter-chain); docs/ADR atualizados.

**Próximo trabalho (não é mais "fechar o plano" — são features/gaps do modelo):**

- **Awaits em task body single-shot continuam blocking-poll.** Se quiser uniformidade total
  (waiter-chain em qualquer task), fazer `isAwaitCall`/`isTaskAwaitCall` dispararem
  `state_machine` em `buildTaskBlockType` (hoje só `sleep`/`yield` disparam). Incremental:
  primeiro `nestedTask`/`loopWithAwait` do `task_transform_test` verdes no caminho state
  machine, depois flipar a detecção.
  > **Experimento (2026-08, REVERTIDO):** um flip direto (adicionar `containsAwait(s)` à
  > condição de `state_machine`) expôs **3 bugs encadeados** em caminhos nunca exercitados
  > (todos os testes usavam single-shot): (1) o composto `val r = task{...}.await()` bindava
  > `r` duas vezes (machinery `val r = __taskN` + marker `val r = __CoopAwait(...)`), e o
  > body field `this.r` pegava o tipo `StackTask_Int`; (2) o caminho single-shot perdeu o
  > `appendSlice(machinery)` (bug meu de edição, `__task0` undeclared); (3) **capture boxed de
  > local promovido**: `i` local do corpo do task externo vira body field `this.i` (Int puro,
  > `collectLocalVars` força `is_boxed=false`), mas o task interno `task { i * 10 }` captura
  > `i` com `boxed=true` (checker marca var mutável capturada por lambda) → ctor do
  > `__TaskBlock2` recebe Int como box pointer → `resume()` deref de ponteiro nulo (segfault,
  > confirmado no lldb: `ldr x8, [x8]` em `__TaskBlock2_resume`). Fixes parciais mantidos
  > (dormentes, validados pela suíte): coop composto dropa o bind da machinery
  > (`rewriteTaskAwaitCall` coop), `rewritePromotedRefs` reescreve o receiver do marker
  > coop-await, e `buildResumeStateMachine` reescreve com `promoted` (não só `new_locals` —
  > os args do ctor gerados na etapa 2 referenciam locals promovidos na etapa 1). **Ação
  > correta para retomar:** forçar o caminho state machine para `nestedTask`/`loopWithAwait`
  > um de cada vez (não flip global), e resolver o bug 3 (boxed capture de local promovido a
  > body field) antes do flip.
- **`hoistAwaitsWalk` sem caso `.assignment`**: `x = inner.await() + x` não é hoisted (o await
  vira chamada direta dentro do estado). Adicionar o caso `.assignment` (e `.index_set_expr`).
- **`try` com `await` cooperativo dentro**: `machineBuildStmt` não tem caso `.try_stmt` (erro
  `SuspendInOperand`). O single-shot já trata try+await; o state machine ainda não.
- **`for` com suspensão dentro do corpo do task**: gap conhecido (erro `file:line`).
- **`await()` no ROOT ainda é blocking-poll** (`buildPollStmt`) — decisão pendente para a
  **Fase I** (dispatchers/thread pool), que continua **PROPOSTA**.
- **I/O waiters**: `EventLoop.waitReadable/waitWritable` hoje bloqueiam via `poll`; transformá-los
  em suspensão cooperativa é o mesmo mecanismo do timer heap (uma lista de "waiters de I/O").
- **BRIDGE — `Scheduler.run()` no loop de accept do arest** (2026-08, `arest/src/arest/arest.ei`):
  `task { dispatcher.dispatch(conn) }` só **enfileira** (stackless lazy); como o `accept()`
  bloqueia via `poll(-1)` e nunca retorna ao root, nada bombeia a FIFO e o handler não roda
  (conexão aceita no backlog mas sem resposta). O bridge adiciona `Scheduler.run()` logo após
  agendar, fazendo o handler síncrono rodar até o fim. ⚠️ **REMOVER este `Scheduler.run()` quando
  os I/O waiters cooperativos (Fase I / Phase 69) estiverem prontos**: com `waitReadable`/
  `waitWritable` virando suspensão real, o accept loop vira um await cooperativo no scheduler e
  o drain manual deixa de ser necessário (concorrência real de conexões).
- **Server HTTP no LLVM — RESOLVIDO (2026-08)** (era "`http_sample.ei` server segfaulta ao
  responder", ver Fase G). Causas raiz corrigidas no emitter: (a) object/enum initializers
  só rodavam em modo teste (singletons como `Log.rootLogger` ficavam null → segfault 0x8);
  (b) safe-call de método em `Pointer` (`buf?.writeByte`) não despachava e o corpo era stub
  (`Socket.read` → `ret null`); (c) `String.startsWith`/`endsWith` eram stubs (métodos de
  primitivos pulados no Pass 2) → `serveStatic` nunca casava; (d) `task {}` como statement
  (sem `val x =`) nunca era agendado. Validação: server do exemplo `home` serve página,
  fragments e static assets em nativo e JIT.

**Modelo atual (referência):**

- `src/core/coroutines_transform.zig`:
  - `buildResume` — `resume()` single-shot (bloco sem suspensão real): reescreve captures,
    splices o bloco, `this.task.result = <last>`, `done = true`, reschedule da waiter chain.
  - `buildResumeStateMachine` — `resume()` como state machine p/ task bodies com
    `sleep`/`sleepMs`/`yield`: `while(true) { if (this.label==N) {...} else ... }`, locais
    promovidos a body fields, `this.label` default = entry. Builder CFG em ordem reversa;
    statements plain viram estados próprios (nunca merge em joins). Awaits → marker
    `__CoopAwait` (Fase K); novos locais da machinery promovidos via `collectNewLocals`.
  - `buildPollStmt` — `await()` vira `while (!recv.done && Scheduler.runStep()) {}` (root e
    task bodies single-shot).
  - `rewriteAwaitCall`/`rewriteTaskAwaitCall`/`rewriteReturnAwait`, `hoistAwaitsFromExpr`,
    `transformModule`/`transformFunction`, `buildTaskBlockType` (roteia state machine ×
    single-shot e adiciona `body_fields`).
- `src/std/coroutines.ei`:
  - `contract Continuation { resume(), isDone() }` — `resume()` **Void** (suspensão é
    sinalizada por auto-re-agendamento; conclusão via `task.done = true`).
  - `object Scheduler` com `schedule`/`run`/`runStep` (FIFO intrusiva) + **timer heap**:
    `TimerNode(deadline, cont, next)`, `Scheduler.now` (relógio virtual ms),
    `sleep(cont, ms)`/`yield(cont)`/`fireTimers()`/`waitMs(ms)`. `run` = `while(runStep())`.
  - `type StackTask<T>(done, result, waiters)` com `await()`/`isDone()` (Awaitable) +
    `awaitCoop(cont)` (waiter-chain FIFO, usada pelo transform).
  - `Coroutine.sleep/sleepMs` (nanosleep) / `yield` (sched_yield) bloqueiam fora do corpo de
    task; dentro do corpo, o transform os reescreve em `Scheduler.sleep(this, ...)` /
    `Scheduler.yield(this)`.
  - `task<T>` retorna `StackTask<T>(false, null, null)` — ctor chamado pelo transform.

**Regras de ouro (não quebrar):**

1. `coroutines_transform.zig` já foi **perdido e reconstruído** uma vez — mudanças devem ser
   **conservadoras e incrementais**. Sem reescritas em massa sem teste verde por passo.
2. **Sem gambiarras**: sem special cases por nome no **emitter**/runtime (`__cblambda`,
   `__TaskBlock`), sem chamadas manuais de `LLVMAddFunction`, sem adaptar testes para
   acomodar bugs do compiler. (Nomes internos do **transform** — `__CoopAwait`,
   `__TaskBlockN`, `__taskN` — são consumidos antes da emissão e são o padrão existente.)
3. **Não reintroduzir** neco, `@MainWrapper`, `--backend`, ou o contrato `Awaitable<T>`.
4. **Sem prints/debug permanentes**.
5. **Guardrail: testes que passam continuam passando** — não adaptar testes para o mecanismo.
6. Após cada passo: `zig build` + teste mínimo + regressão (`task_test`, `task_transform_test`,
   `scheduler_test`, `interleave_test`, `yield_test`, `body_fields_test`, `coop_await_test`).

**Fixes recentes que não devem ser revertidos (contexto de sessões anteriores):**

- NUL-termination no trampoline `cFunctionPtr` (`src/backend/llvm_emitter/expression.zig` L1690):
  `c_name` é slice não-terminado → usar `dupeZ` antes de `LLVMGetNamedFunction`.
- `Awaitable<T>` mantido como interface enxuta (`@Suspend await` + `isDone`, SEM `start()`);
  `StackTask` o implementa em `src/std/coroutines.ei`.
- Detecção de suspend (`src/core/coroutines.zig`) resolve por **receiver type + nome**
  (`isSuspendDecl`/`findMethodHasSuspend`), não por contrato.
- Box de 16 bytes fixo para vars capturadas (`cell_size`) — TODO conhecido, alocar
  `LLVMStoreSizeOfType` (pré-existente nos closures).
- Fase K: splice de monomorfizados antes das continuações; `.var_decl`/`.assignment`
  reescrevem o RHS antes de converter para `set_expr`.

**Gaps conhecidos a corrigir:**
`object static String concat crasha` (`"x" + Obj.v`), `toString` mangled de List/Map
(pré-existente no emitter), `try/catch` como última expr de bloco de task, `for`/`try`/`return`
com suspensão dentro do corpo do task, await como receiver de composite. (Server HTTP no LLVM:
**resolvido** — ver nota do BRIDGE `Scheduler.run()` acima.)

---

## Riscos e notas

- **Transformação é o risco central**: começar com P1 (retilíneo) end-to-end funcionando
  antes de loops/try. Testar cada fase.
- **Exceções através de suspensão** (P3) é o caso mais espinhoso — Kotlin resolve com estado
  de exceção no continuation; pode ser adiado se `try/catch`+`await` for raro no início.
- **I/O**: `poll()` single-threaded; sem concorrência de kernel, mas suficiente para
  `TCPServer`/`http_sample`.
- **Shadow stack**: **não** será implementada (stackless torna desnecessária). GC conservador
  do OS stack + `GC_malloc` (Bloco B) bastam. Reavaliar só se reintroduzirmos stackful.
- **Scheduler próprio** substitui neco com ~300-500 linhas de C sob nosso controle (vs 8770).
