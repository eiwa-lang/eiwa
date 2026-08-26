# Tasks — Phase 69: Dispatchers & Thread Pool (Paralelismo Multi-Core Real)

> **Decisão de Arquitetura (ADR 51 / 2026-08):** Evoluir o modelo de corrotinas stackless do Eiwa
> de cooperativo single-thread para **paralelismo real multi-core**, adotando `Dispatchers.Default`
> como o padrão global para `task { ... }` (execução eager em thread pool de N cores), suporte a
> `task(dispatcher) { ... }`, pools customizados via `Dispatchers.create(...)` e sincronização
> thread-safe via `Mutex`, `CondVar` e `AtomicBool`/`AtomicInt` em Eiwa puro.

---

## 🎯 Objetivo & Princípios

1. **Paralelismo Real Multi-Core:** Tasks executam verdadeiramente em paralelo em múltiplas threads OS (`pthread`), atingindo speedup real em tarefas CPU-bound.
2. **`Dispatchers.Default` como Padrão Eager:** `task { ... }` despacha imediatamente a tarefa para o pool de workers sem exigir chamadas a `.await()` ou `Scheduler.run()` manual.
3. **Zero Runtime em C:** Primitivas de threading e atômicos são escritas em Eiwa puro (`src/std/thread.ei`, `src/std/atomic.ei`) sobre bindings FFI (`lib NativeThread`, `lib NativeAtomic`).
4. **Segurança de GC:** Toda thread trabalhadora é registrada no Boehm GC (`GC_register_my_thread(&stack_base)`).
5. **Zero Quebra de Compatibilidade:** Código existente continua funcionando com garantia de finalização ordenada.

---

## 📋 Checklist Operacional

### Etapa 0 — Primitivas de Threading e Atomics no Stdlib (FFI) — ✅ CONCLUÍDA (2026-08)
- [x] **Task 69.0.1:** Criar `src/std/thread.ei` com `lib NativeThread`:
  - Bindings POSIX: `pthread_create`, `pthread_join`, `pthread_self`
  - Sincronização: `pthread_mutex_init`, `pthread_mutex_lock`, `pthread_mutex_unlock`, `pthread_mutex_destroy`
  - Condition Variables: `pthread_cond_init`, `pthread_cond_wait`, `pthread_cond_signal`, `pthread_cond_broadcast`, `pthread_cond_destroy`
  - Detecção de núcleos: `sysconf(_SC_NPROCESSORS_ONLN)`
  - Tipos de alto nível: `type Thread(val handle: Pointer)` com `join()`, `type Mutex`, `type CondVar`, `object Threads` com `numCores()` e `spawn(block)`.
- [x] **Task 69.0.2:** Criar `src/std/atomic.ei` com `lib NativeAtomic` (via helpers LLVM `eiwa_atomic_*` em `core.zig`):
  - Operações atômicas nativas: `eiwa_atomic_cas_bool`, `eiwa_atomic_cas_val`, `eiwa_atomic_fetch_add`, `eiwa_atomic_test_and_set`.
  - Tipos: `type AtomicBool` e `type AtomicInt` com `get()`, `set(v)`, `addAndGet(delta)`, `compareAndSet(expected, new)`.
- [x] **Verify 69.0:** Testes `samples/tests/threads_test.ei` (5/5) e `samples/tests/atomic_test.ei` (3/3) passando.

---

### Etapa 1 — `TaskScheduler` Thread-Safe Instanciável — ✅ CONCLUÍDA (2026-08)
- [x] **Task 69.1.1:** Implementar `type TaskScheduler`:
  - Campos de instância: `head`, `tail`, `timerHead`, `now`, `mutex: Mutex`, `cond: CondVar`.
  - Operações de fila protegidas por mutex; `schedule()` dispara `cond.signal()`.
  - Método `popBlocking(): ContNode?` com `cond.wait(mutex)` para thread pool.
  - Facade global `object Scheduler` encaminhando para `Dispatchers.Default.scheduler`.
- [x] **Task 69.1.2:** Unificar chamadas internas e evitar colisão de símbolos entre o tipo instanciável `TaskScheduler` e o facade `Scheduler`.
- [x] **Verify 69.1:** Suíte de corrotinas existente (`task_test`, `interleave_test`, `yield_test`, `coop_await_test`) 100% verde.

---

### Etapa 2 — `Dispatcher.Default` com Thread Pool de N Cores — ✅ CONCLUÍDA (2026-08)
- [x] **Task 69.2.1:** Implementar `type Dispatcher(val name: String, val nThreads: Int, val scheduler: TaskScheduler)`:
  - `object Dispatchers` com `val Single = Dispatcher("single", 1, TaskScheduler.create())`.
  - `val Default = Dispatcher("default", Threads.numCores(), TaskScheduler.create())`.
  - Factory `Dispatchers.create(name: String, threads: Int): Dispatcher`.
- [x] **Task 69.2.2:** Implementar worker loop de threads no pool:
  - Consumo de nós da fila com `popBlocking()`.
  - Registro de GC por thread (`GC_register_my_thread` / `GC_unregister_my_thread`).
- [x] **Task 69.2.3:** Gerenciamento de ciclo de vida e shutdown gracioso do pool.
- [x] **Verify 69.2:** Múltiplas tarefas executam concorrentemente em threads do pool.

---

### Etapa 3 — `await()` Cross-Thread e Notificação de Waiters — ✅ CONCLUÍDA (2026-08)
- [x] **Task 69.3.1:** `StackTask` thread-safe:
  - Campos `done: Bool`, `result: T?`, `waiters: WaiterNode?`.
  - Conclusão no worker despacha waiters na fila do scheduler com `cond.signal()`.
- [x] **Task 69.3.2:** `await()` entre threads:
  - Caller registra continuação e aguarda notificação thread-safe sem spinlock ocupado.
- [x] **Verify 69.3:** Validação completa com waiters entre threads do pool e thread principal em `dispatchers_test.ei` e `coop_await_test.ei`.

---

### Etapa 4 — Registro Multithread no Boehm GC — ✅ CONCLUÍDA (2026-08)
- [x] **Task 69.4.1:** Inicializar `GC_allow_register_threads()` em `__eiwa_gc_init_ctor` e JIT initialization (`core.zig`).
- [x] **Task 69.4.2:** Expor wrappers `lib NativeGC` no stdlib para registro de stacks por thread (`NativeGC.getStackBase`, `NativeGC.registerMyThread`, `NativeGC.unregisterMyThread`).
- [x] **Verify 69.4:** Threads do pool registradas e desalocando normalmente sem corrupção ou vazamento.

---

### Etapa 5 — Integração no Compilador & Default Eager — ✅ CONCLUÍDA (2026-08)
- [x] **Task 69.5.1:** Atualizar `src/core/coroutines_transform.zig` e `src/core/type_checker/`:
  - `task { ... }` agenda por padrão em `Dispatchers.Default` (execução eager imediata).
  - Suporte a `task(dispatcher) { ... }` com dispatcher explícito (monomorfização por aridade em `infer_call.zig` e lookup em `monomorphize.zig`).
- [x] **Task 69.5.2:** Drain automático de `Dispatchers.Default` ao término de `main` e `test`.
- [x] **Verify 69.5:** Suíte `samples/tests/dispatchers_test.ei` testando `Dispatchers.Default`, `Dispatchers.create(...)` e `Dispatchers.Single` 100% verde.

---

### Etapa 6 — Benchmark Multi-Core & Regressão Final — ✅ CONCLUÍDA (2026-08)
- [x] **Task 69.6.1:** Criar benchmark CPU-bound (`samples/benchmarks/parallel_primes_benchmark.ei`).
- [x] **Task 69.6.2:** Medir speedup em múltiplos núcleos (vs `Dispatchers.Single`).
- [x] **Task 69.6.3:** Executar regressão completa da suíte de testes: `LLVM Test Suite: ALL PASS`.
