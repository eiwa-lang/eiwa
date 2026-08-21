# Tasks — Path 1: Shadow Stack GC (remover C backend + neco)

> **⚠️ SUPERSEDED (2026-08):** este plano foi **substituído** por
> [`tasks-coroutines-stackless.md`](tasks-coroutines-stackless.md). A decisão de adotar
> **coroutines stackless** (estilo Kotlin, sem stack switching) **elimina a necessidade da
> shadow stack** (Fase 4 abaixo — **NÃO será implementada**): sem corrotinas neco, o estado
> suspenso vive em objetos heap `Continuation`, alcançáveis por ponteiros, e a varredura
> conservadora do OS stack + `GC_malloc` bastam.
>
> O que **permanece válido** deste plano (e está espelhado na **Fase F** do plano stackless):
> - **Fase 1** — remover o backend C (`src/backend/c_transpiler/`, `--backend=c`, `BackendKind.c`).
> - **Fase 2** — remover o neco (`src/runtime/third_party/neco/`).
> - **Fase 3** — remover o mecanismo `@MainWrapper`.
>
> Manter este arquivo apenas como histórico da decisão. **Não seguir a Fase 4.**

---

<details>
<summary><b>Plano original (arquivado — não executar a Fase 4)</b></summary>

> **Decisão de arquitetura (2026-08):** adotar o **Caminho 1** — GC preciso via **shadow stack**
> no JIT LLVM — e, sem necessidade de retrocompatibilidade com o backend C, **remover
> completamente o backend C e o runtime neco**. O JIT LLVM vira o único backend.
> Este arquivo é o plano operacional; atualizar checkboxes conforme o trabalho avança.

**Objetivo:** eliminar a classe de bugs de raízes GC não escaneadas (crash de corrupção de
`co`/corrotina nos stress tests) substituindo a varredura conservadora dependente de
corrotinas por **raízes determinísticas e explícitas** (shadow stack), e simplificar o
projeto removendo o backend C e o neco.

---

## Contexto e justificativa

### O crash investigado
- Stress tests (concat/array a 20k iterações) **passam** e crasham no teardown da corrotina
  neco (`coexit` → `comap_delete`): o `struct coroutine *co` (malloc cru) amanhece com bytes
  de string ("some ext") ou null. Backend C passa o mesmo workload a 200k.
- Causa raiz: raízes GC dependem de escanear stacks de corrotinas neco
  (`eiwa_track_stack` + `GC_add_roots` + `GC_set_stackbottom` + `eiwa_gc_fix_stackbottom`).
  Um slot de stack não escaneado num momento de coleta → objeto vivo coletado →
  ponteiro stale → corrupção de memória adjacente (heap malloc do neco).

### Por que remover neco resolve o problema de raiz
- Sem neco, o programa roda direto na **stack do OS main thread**, que o Boehm já registra
  automaticamente via `GC_init` (pthread). É exatamente o modelo do backend C (passa a 200k).
- Remove também o `@MainWrapper` (único usuário é o neco), os shims de main wrapper e o
  dance de `GC_set_stackbottom` — três fontes de fragilidade.

### O que a shadow stack agrega (Path 1)
- Raízes de **locais** viram explícitas e determinísticas (frames em heap GC linkadas de um
  único global), em vez de depender da varredura conservadora da stack nativa.
- A varredura conservadora da stack do OS **permanece como backstop** para temporários de
  expressão e registradores (híbrido seguro: local → shadow slot; temporário → scan).
- Coletor continua sendo o **Boehm** (não trocamos de GC). `GC_malloc` para objetos e frames.

---

## Decisões de escopo (confirmadas)

1. **Remover o backend C** por completo: `src/backend/c_transpiler/`, flag `--backend=c`,
   `BackendKind.c`, path CTranspiler em `main.zig`, incluindo `eiwa_runtime.h`.
2. **Remover o neco** por completo: `src/runtime/third_party/neco/`, `src/std/coroutines.ei`,
   coroutines (`task`/`await`/`yield`/`Task`/`Awaitable`), samples e testes dependentes.
3. **Remover o mecanismo `@MainWrapper`** (único usuário era o neco).
4. **Shadow stack** no emitter LLVM (Path 1), mantendo Boehm como coletor.
5. **LLVM passa a ser obrigatório**: build sem LLVM vira erro de configuração (sem fallback C).

---

## Fase 1 — Remover o backend C

- [ ] Deletar `src/backend/c_transpiler/` inteiro (`core.zig`, `declaration.zig`,
      `expression.zig`, `statement.zig`, `std_lib.zig`, `eiwa_runtime.h`).
- [ ] `src/main.zig`: remover `const c_transpiler = @import("backend/c_transpiler/core.zig")`,
      `BackendKind.c`, parsing de `--backend=c`, e o path CTranspiler (`transpiler.*`,
      `transpile`, invocação `zig cc` ~linhas 508-590, flags `-I...c_transpiler`).
- [ ] `src/main.zig` test runner (~linha 207): `backend_flag` sempre `--backend=llvm` (ou
      remover a flag, já que é o padrão); `backend_name` = "LLVM".
- [ ] `build.zig`: `has_llvm` vira pré-requisito — se `llvm_info == null`, emitir erro claro
      e não compilar (remover o fallback/condicional de C no `main.zig`/`build.zig`).
- [ ] `cli/src/main.ei`: help text (~linha 377 "Backend (c | llvm)") e forwarding de
      `--backend` — aceitar apenas `llvm` (ou remover o passthrough).
- [ ] Validar: `zig build`, `zig build test`, `./bin/eiwac test samples/tests`
      (só LLVM agora).

## Fase 2 — Remover o neco e coroutines

- [ ] Deletar `src/runtime/third_party/neco/` (`neco.c`, `neco.h`, `neco_wrapper.c`,
      `neco_wrapper.h`, `LICENSE`).
- [ ] Deletar `src/std/coroutines.ei` (objetos `Coroutine`, `EventLoop`, `Task`, `task`,
      `@MainWrapper`).
- [ ] `src/std/core.ei`: remover o contrato `Awaitable<T>` (~linha 344-347) — morto sem
      coroutines.
- [ ] `src/std/system.ei`: remover `import { Coroutine }`, reimplementar `sleep`/`sleepMs`
      via FFI `nanosleep` (libc) e remover `yield()` (ou torná-lo no-op).
- [ ] `src/std/net.ei`: remover `import { EventLoop }` e `EventLoop.waitReadable/Writable`;
      sockets viram bloqueantes (remover `setNonblocking` ou trocar por `poll` bloqueante).
- [ ] `src/std/db.ei`: remover `import { Coroutine }` e as chamadas `Coroutine.yield()`.
- [ ] Deletar samples: `samples/task_sample.ei`, `samples/task_loop.ei`,
      `samples/tests/task_test.ei` (14 testes — o count do suite cai).
- [ ] `samples/tests/composition_test.ei`: remover `Awaitable`/`TaskLibaco` (linhas 108-113,
      opcional, são auto-contidos e inócuos).
- [ ] Validar que nenhum teste/sample restante importa `std.coroutines`/usa `task {`/`await(`.

## Fase 3 — Remover o mecanismo `@MainWrapper`

- [ ] Type checker/frontend: remover coleta de `main_wrappers` (`MainWrapperInfo`) e parsing
      de `@MainWrapper` se ainda existir no parser/type_system.
- [ ] `src/main.zig` (~407-425, 480-486): remover `global_main_wrappers` e o preenchimento
      de `emitter.main_wrapper_c_names`/`main_wrapper_is_lib`.
- [ ] `src/backend/llvm_emitter/core.zig`: remover `main_wrapper_c_names`,
      `main_wrapper_is_lib`, `emitMainWrapperEntry` (linha ~970) e o branch `wrapped` em
      `executeJIT` (linha ~3192). Entry vira direto: `main` (run) / `eiwa_test_main` (test).
- [ ] `src/backend/llvm_emitter/core.zig` (~3153): atualizar o comentário que menciona
      `Neco_main_wrapper` como único caller de `GC_init` (hoje o host chama em executeJIT).
- [ ] Manter `GC_init()` host-side em `executeJIT` (idempotente) e o global ctor
      `__eiwa_gc_init_ctor` para build nativo.

## Fase 4 — Shadow stack no emitter LLVM (o núcleo do Path 1)

### Design
- **Global raiz:** `@eiwa_gc_shadow_top = global ptr null` (com initializer → registrado
  automaticamente por `registerJITGlobalsAsRoots`, que já itera globals não-declaration).
- **Frame:** struct GC_malloc'd `{ prev: ptr, n: i64, roots: [N x ptr] }`, alocada via
  `getHeapAllocFn`. Cadeia linkada a partir de `@eiwa_gc_shadow_top`. Como frames são
  objetos GC, o coletor os escaneia automaticamente uma vez que a head é alcançável.
- **Por função com slots:** prólogo faz push (aloca frame, `frame.prev = top`, `top = frame`);
  epílogo faz pop (`top = frame.prev`) antes de cada `ret`.
- **Locais:** todo local cujo LLVM type seja ponteiro (String, objetos, arrays, closures,
  fat pointer `{ptr,ptr}`, boxed cell) ganha um slot; seu storage no `scope` passa a ser
  `gep(frame, slot_i)` em vez do alloca → leituras/escritas passam por memória escaneada.
- **Backstop:** manter a varredura conservadora da stack nativa do OS (temporários de
  expressão e registradores continuam cobertos por ela).

### Implementação
- [ ] `emitFunctionBody` (core.zig:2740): pré-varredura do AST de `func_node` para contar
      slots N (params + `this` + var_decls pointer-typed); emitir prólogo (push) no entry
      block quando N > 0.
- [ ] `core.zig:2755-2780` (`this` + params): storage vira `gep(frame, slot)` para types
      pointer/fat-pointer.
- [ ] `statement.zig:56-106` (var_decl): para pointer-typed, `scope` recebe
      `gep(frame, slot_i)` em vez de alloca (inclui boxed cell → slot guarda o box_ptr).
- [ ] Helper `emitShadowPop(builder, frame)` chamado antes de cada `ret` de corpo de função:
      `statement.zig` return_stmt (~351-396), corpos expression-bodied (core.zig:2788-2794),
      lambdas/closures (expression.zig:1552-1576, 1681-1683).
- [ ] Fat pointers `{ptr,ptr}` (contratos): guardar só o primeiro word (object ptr) no slot —
      a vtable é global JIT já rootada.
- [ ] Exceções (setjmp/longjmp): documentar que o unwind pula os pops → over-retention
      (objetos de frames mortos ficam vivos), **não** é bug de corretude. Melhoria futura:
      salvar/restaurar shadow top no `EiwaExceptionFrame`.

### Validação da shadow stack
- [ ] Stress tests (S1a concat / S1b array / S2 array-push / S3 exceptions) a 20k+ **passam**.
- [ ] App `home` / `http_sample.ei` (via `std.net` bloqueante) funciona no LLVM.

## Fase 5 — Validação geral (ordem obrigatória)

- [ ] `zig build`
- [ ] `zig build test`
- [ ] `./bin/eiwac test samples/tests` → **todos passam** (recomputar count após remover
      task_test.ei)
- [ ] `./bin/eiwac run samples/main.ei`
- [ ] `./bin/eiwac build samples/main.ei -o /tmp/t && /tmp/t` (build nativo; ctor
      `__eiwa_gc_init_ctor` + shadow top em `.data/.bss` escaneados automaticamente)
- [ ] `./bin/eiwac test samples/tests --release` (opcional)

## Fase 6 — Docs

- [ ] `AGENTS.md`/`agents.md`: remover referências a backend C, neco, coroutines, e ao
      fluxo `eiwac test` com dois backends.
- [ ] `docs/architecture.md`, `docs/roadmap.md`: marcar backend C e neco removidos; adicionar
      decisão do shadow stack.
- [ ] `docs/decisions.md`: novo ADR — "Shadow stack GC no JIT; remoção do backend C e neco".
- [ ] `docs/language_tour.md`: remover seção de coroutines/task/await/yield.
- [ ] `docs/tasks-backend-parity.md`: obsoleto (sem backend C) — deletar ou marcar histórico.
- [ ] `docs/tasks-bloco-b-gc-jit.md` + `docs/bloco-b-handoff.md`: marcar como superseded
      pelo shadow stack.
- [x] Limpar dirs temporários de stress: `gc_s1/ gc_s1a/ gc_s1b/ gc_s2/ gc_s3/
      gc_stress_tmp/` (testes estáveis consolidados em `samples/tests/gc_stress_test.ei`).

---

## Riscos e notas

- **Temporários de expressão**: continuam cobertos pela varredura conservadora nativa
  (backstop) — a shadow stack é determinística para locais, não substitui o scan do OS stack.
- **Over-retention por exceção**: aceitável (frames mortos via longjmp mantêm objetos vivos;
  corrige-se depois salvando o shadow top no exception frame).
- **`net.ei` bloqueante**: mudança de semântica (antes async via neco, agora blocking).
  Verificar `http_sample.ei` e testes HTTP.
- **LLVM obrigatório**: ambiente sem LLVM 21+ deixa de compilar `eiwac` (erro claro no
  build.zig). Requisito aceito.

</details>