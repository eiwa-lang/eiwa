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
- [x] Validado: `main` de `task_sample.ei` → `is_suspend=true`; os 3 `await()` →
      `is_suspend_call=true`; sem falsos positivos.

## Fase C — Transformação AST → state machine (o núcleo, `src/core/coroutines.zig`)

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
3. [ ] **Gerar struct `Continuation`**: `{ label, saved_locals..., result: T?, exception,
      next_waiter }`. (parcial — o transform gera `{ task: StackTask<T>, <capturadas...> }`
      com `resume()`/`isDone()`; `label`/`switch(label)` ainda não é necessário no modelo
      blocking-poll.)
4. [ ] **Reescrever corpo** em `resume(cont)` com `switch(label)`:
      cada estado = trecho retilíneo até o próximo ponto de suspensão. (parcial — o modelo
      blocking-poll executa o corpo inteiro num único `resume()`, usando nested
      `Scheduler.run()` nos polls, sem `switch(label)`.)
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
      `samples/task_p3_debug.ei` (99). Limitação conhecida: `try/catch` como última
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

## Fase D — Emissão LLVM

- [ ] Emitir o struct `Continuation` (via structs existentes) + função `resume` (via
      `emitFunctionBody` reaproveitado sobre o AST transformado).
- [ ] Emitir calls do runtime: `scheduler_schedule/resume/suspend`, `COROUTINE_SUSPENDED`.
- [ ] Entry de `main`/`eiwa_test_main`: rodar `scheduler_run()` (event loop) até vazio;
      testes: cada `test {}` vira uma coroutine (substitui o loop atual de setjmp por
      coroutines; manter setjmp p/ exceções dentro de cada teste).
- [ ] Global ctor `__eiwa_gc_init_ctor` + `GC_init` host-side seguem como estão.

## Fase E — Scheduler runtime **em Eiwa** (sem arquivo C)

> **Decisão (2026-08):** o scheduler é escrito em **Eiwa puro**, não em C. As únicas
> primitivas de sistema (`poll()` para I/O, `clock_gettime` para timers) são alcançadas
> pelo FFI já existente (`lib` + `@Header`/`@Alias`), igual ao padrão de `time.ei`
> (`NativeTime.time()`). Nenhum `eiwa_scheduler.c` é criado.

- [x] `src/std/coroutines.ei`: base do scheduler Eiwa (sem neco) — ✅ PARCIAL (2026-08):
  - [x] `contract Continuation { resume(), isDone() }` — state machine gerada pelo compilador.
  - [x] `object Scheduler` com `schedule(cont)`/`run()` — fila FIFO **linked list intrusiva**
        (`type ContNode(val cont: Continuation, var next: ContNode?)`), NÃO `MutableList`
        (o backend LLVM ainda não armazena fat pointers em coleções genéricas — ver
        `samples/tests/contract_collection_storage_test.ei`).
  - [x] Validado com continuations escritas à mão: interleaving cooperativo FIFO correto
        (`samples/tests/scheduler_test.ei`).
  - [ ] `type Continuation` concreto com `result`/`done`/`waiters` (quando o transform precisar).
  - [ ] Timer heap para `sleep/delay`; `lib NativePoll { @Header("<poll.h>") }` para I/O.
  - [ ] Reescrever `Task<T>`/`task {}`/`Coroutine.*`/`EventLoop.*` sobre o Scheduler
        (depende do transform, Fase C).
- [ ] `src/std/system.ei` (sleep/yield), `net.ei` (poll bloqueante), `db.ei` (yield removido).

## Fase F — Remover backend C + neco + @MainWrapper

(mesmo escopo do plano anterior — agora seguro, pois o stdlib não depende mais de neco)

- [ ] Deletar `src/backend/c_transpiler/`, flag `--backend=c`, `BackendKind.c`, path
      CTranspiler em `main.zig`; LLVM obrigatório (`build.zig` erro sem LLVM).
- [ ] Deletar `src/runtime/third_party/neco/` e `src/std/coroutines.ei` (antigo, stackful).
- [ ] Remover mecanismo `@MainWrapper` (`main_wrapper_c_names`, `emitMainWrapperEntry`,
      shims); entry = `main`/`eiwa_test_main` com `scheduler_run()`.
- [ ] `cli/src/main.ei`: help/forwarding `--backend` só llvm.
- [ ] `samples`: deletar `task_sample.ei`, `task_loop.ei`, `task_test.ei` (ou reescrever
      `task_test.ei` usando o novo `task {}`); remover `Awaitable`/`TaskLibaco` mortos.
- [ ] `core.ei`: remover `Awaitable<T>` do contrato (ou manter como interface do `Task`).

## Fase G — Validação (ordem obrigatória)

- [ ] `zig build`, `zig build test`.
- [ ] `./bin/eiwac test samples/tests` → **todos passam** (recomputar count).
- [ ] Stress tests originais (concat/array a 20k+) **passam** — prova que o crash sumiu.
- [ ] Novo `samples/tests/task_test.ei` (reescrito stackless): task/await, múltiplos tasks
      concorrentes, sleep/delay, nested tasks.
- [ ] `./bin/eiwac run samples/main.ei`; `./bin/eiwac build samples/main.ei -o /tmp/t && /tmp/t`.
- [ ] `http_sample.ei` (net.ei via poll) sobe e responde no LLVM.
- [ ] Performance: medir overhead de `task{}`+`await` simples vs chamada direta (fast path
      deve ser ~1 branch + switch).

## Fase H — Docs

- [ ] `AGENTS.md`/`agents.md`, `architecture.md`, `roadmap.md`: coroutines stackless, C/neco
      removidos.
- [ ] `docs/decisions.md`: ADR — "Coroutines stackless (Kotlin-style); remoção C + neco".
- [ ] `docs/language_tour.md`: seção `suspend fun`/`task{}`/`await()`.
- [ ] `docs/tasks-backend-parity.md`, `docs/tasks-bloco-b-gc-jit.md`,
      `docs/bloco-b-handoff.md`: obsoletos/superseded.
- [x] Limpar `gc_s1/ gc_s1a/ gc_s1b/ gc_s2/ gc_s3/ gc_stress_tmp/` (testes
      estáveis consolidados em `samples/tests/gc_stress_test.ei`).

## Fase I — Proposta: Dispatchers / thread pool (paralelismo real, estilo Kotlin)

> **Origem (2026-08):** o Eiwa implementa coroutines **cooperativas single-thread**
> (equivalente ao `Dispatchers.Main`/`Unconfined` do Kotlin). Para paralelismo real
> (como `Dispatchers.Default`/`IO` do Kotlin ou goroutines do Go), é preciso um
> dispatcher + thread pool. **PROPOSTA — não é o modelo atual; requer redesign.**
> Só avaliar depois que Fase C/D/E/F estiverem completas e a suíte 100% verde.

- [ ] **Conceito de `Dispatcher`**: contexto onde um `task {}` roda. Por padrão
      `Dispatcher.Single` (o scheduler atual, single-thread). Futuro: `Dispatcher.Default`
      (thread pool = nº de cores), `Dispatcher.IO`.
- [ ] **Scheduler por pool**: hoje `Scheduler` é um singleton global. Para paralelismo,
      cada dispatcher tem sua própria fila + event loop numa thread OS dedicada. `await()`
      precisa esperar **entre** threads (notificação/cross-thread), não só `runStep()` local.
- [ ] **Sincronização de estado compartilhado**: tasks em threads diferentes acessam o
      mesmo `StackTask`/box/var capturada — exige locks/atomics para `done`/`result`/`waiters`
      e para vars boxed. Este é o maior risco de corretude (data races).
- [ ] **GC multithread**: Boehm GC já suporta threads, mas o registro de raízes do JIT
      (`registerJITGlobalsAsRoots`) e as stacks de múltiplas threads precisam ser revisados.
- [ ] **Semântica**: definir se `task {}` num dispatcher paralelo roda eager (como Go/Kotlin
      Default) ou continua lazy. Proposto: eager no dispatcher paralelo (agenda + roda na
      thread do pool), lazy no single (atual).
- [ ] **Como o programador escolhe**: `task(Dispatcher.Default) { ... }` ou
      `withDispatcher { }` — alinhado ao `withContext` do Kotlin.
- [ ] **Validar**: benchmark de CPU-bound (ex: N-Body paralelo) vs single-thread;
      suíte existente continua verde no `Dispatcher.Single` (default).

**Decisão recomendada:** adiar. O modelo cooperativo single-thread cobre os casos de I/O
leve e concorrência estruturada (que é o objetivo do projeto). Paralelismo real adiciona
uma camada grande de complexidade (sincronização, GC multithread) sem mudar o modelo de
programação para o caso principal. Revisitar se houver demanda por CPU-bound paralelo.

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