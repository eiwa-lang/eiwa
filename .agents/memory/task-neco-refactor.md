# Phase 51 — Refatoração Task<T> (neco)

Decisões do Socratic Gate (2026-07-25):

- **Migração:** neco + bindings primeiro, special cases removidos por último (suite sempre verde; dois runtimes coexistem temporariamente).
- **Lambda → C:** captura de escopo suportada via trampolim C (paridade com os 8 testes de `task_test.ei`; regressão inaceitável).
- **Identidade:** fundir em um único campo `id` vindo do neco (sem `taskId` separado; logs usam o id do neco).
- **Branch:** `feature/phase51` (já existia e estava checked out; substitui a sugerida `phase-51-task-neco`).
- **DoD:** `zig build test` + `eiwa test` (suite completa) verdes; zero special cases (`grep` limpo em `infer_call.zig`, `infer_member.zig`, `expression.zig`, `core.zig`); `fiber.c/h` deletados; I/O fiber-aware (Tasks 36.8–36.10) FORA de escopo.
- **Constraints do plano:** sem novas keywords/sintaxes; mínimo de Zig e C; `task {}` inicia execução imediatamente, `await()` só bloqueia até o resultado.
- Plano detalhado: `docs/plan_mono_task.md`. Esqueleto de referência: `samples/example.ei` (usa `TaskExample<T>` extra — decisão de design a validar na implementação).

## Resultado (2026-07-26) — Phase 51 DONE

- `Task<T>` 100% Eiwa em `std/core.ei`: `contract Awaitable<T>`, `lib Neco`, `type Task<T>(var id, var done, var result: T?, val block)`, factory `fun task<T>`. `await()` ficou no próprio type (skill TaskNeco abandonado: skill não acessa campos do consumidor com verificação).
- Runtime: `third_wrapper.c` (trampolim + macro main + cola GC/neco) + patch `EIWA PATCH` em `neco.c` (stacks via env allocator). `fiber.c/h` deletados.
- Lições duras (não re-derivar):
  - Boehm GC varre [SP, stackbottom]; em stack de corotina isso cruza memória não mapeada → SEGV. Solução: stacks de corotina como raízes do GC + `GC_set_stackbottom` re-apontado a cada troca de corotina.
  - Primeira chamada a `neco_start` BLOQUEIA até todas as corotinas acabarem → o main do usuário precisa rodar dentro do runtime (macro `main` no header).
  - `neco_start` retorna NECO_OK, não o id → usar `neco_lastid()`.
  - **Lambdas no C eram nomeadas só por `linha_col`**: instâncias monomorfizadas do mesmo genérico colidiam (`task<Int>`/`task<String>` compartilhavam `_lambda_198_19`) → a versão errada escrevia int(4B) em campo ponteiro(8B) → SEGV intermitente. Fix: transpiler sufixa com `current_fn_c_name`. Qualquer novo símbolo C derivado de posição de nó AST precisa do mesmo cuidado.
  - `Void` não pode instanciar `type` genérico (campo `void` não existe em C); checker rejeita com erro claro. Função genérica com T=Void só em retorno é válida.
  - lldb trava nesta máquina (TCC); diagnosticar via probes com `fprintf(stderr)`.
- Verificado: `zig build test` ✅, `eiwa test` 132/0 ✅, `task_test.ei` 8/8 ✅, `samples/example.ei` ✅, grep zero de special cases ✅.
