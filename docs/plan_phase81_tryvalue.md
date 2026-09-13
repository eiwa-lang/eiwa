# Plano — Phase 81: `try` como expressão (`T?`, estilo `runCatching {}.getOrNull()`)

## 0. Decisões fechadas

1. **Só bare `try` sem `catch` vira expressão no MVP.** `val r = try { f() }`
   vale `T?`: sucesso → trailing expression, exceção → `null`. É o
   `runCatching { }.getOrNull()` nativo, sem objeto `Result`.
2. **`T?` com flatten + Void Safety** (precedentes: short ternary Phase 18,
   `if`-valor Phase 76/79): corpo `Void` em posição de valor = `TypeError`;
   `T??` achata para `T?`.
3. **Statement intocado:** `try { ... }` como instrução continua `Void` e
   engole silenciosamente (regressão zero por construção).
4. **`try/catch` em posição de valor = erro explícito no MVP**
   (`try with catch in value position not yet supported`). Unificação
   try/catch como expressão Kotlin (`val r = try { a } catch { b }`) fica para
   follow-up.
5. **Parser cirúrgico** (espelho da Phase 76): aceitar `try` nos slots-valor
   (init de `val`/`var`, `return`, RHS de atribuição, trailing de bloco-valor).
   Sem virar expressão geral (args de call, operandos, condições ficam de fora).
6. **MVP sync:** `sleepMs()`/`yield()`/`.await()` dentro de `try`-expressão =
   `TypeError` explícito (mesma restrição do `for`-valor e do `break` em task,
   ADR 54/55/64).

## 1. Semântica alvo

```kotlin
val retorno: String? = try { PersonaGoal.metodo() }
// ok   -> "goal!"
// throw -> null

val r = try { 42 }              // Int? = 42 (inferido)
val s: String? = try {
    val a = tryOk()
    a + "!"                     // trailing expression
}                               // "ok!"

val v: String = (try { boom() }) ?: "fallback"  // compõe com elvis
val n: String? = try { try { ok() } }           // aninha

// ERROS (MVP):
val bad = try { print("hi") }                   // TypeError: corpo Void
val c = try { boom() } catch { "x" }            // TypeError: catch em valor (follow-up)
task { val r = try { sleepMs(1); ok() } }       // TypeError: suspend em try-valor
```

## 2. Parser

* `src/frontend/parser/statement.zig:129-183` — extrair `tryStatement()`.
* `src/frontend/parser/expression.zig` (~`kw_if`/`kw_when`) — aceitar `kw_try`
  em posição de expressão primária, chamando o mesmo `tryStatement()`.
* `src/core/ast.zig:382-385` — `try_stmt{ body, catches }` ganha
  `is_value: bool = false` (padrão de `if_expr:309`, `when_expr:397`,
  `for_stmt.collect:359`). Parser seta `true` via `expression()`, `false` via
  `declaration()` (`declaration.zig:59`).

## 3. Checker

* `src/core/type_checker/infer_stmt.zig:756-794` (`inferTryStmt`,
  via `core.zig:1159`):
  * `is_value=false` → `t.* = .Void` (hoje, inalterado).
  * `is_value=true` + 0 catches → inferir trailing do `body`
    (`inferBranchAsExpression`/`inferBlockAsExpression` da Phase 79);
    `Void` → `TypeError`; senão `T?` com flatten.
  * `is_value=true` + catches → `TypeError` dedicado (follow-up).
* Marcação de slots-valor: reutilizar `markTrailingValue` da Phase 76
  (init, `return`, RHS — nunca expressão geral).

## 4. Emissor LLVM

* `src/backend/llvm_emitter/statement.zig:555-704` — extrair frame
  `setjmp`/`longjmp` para helper compartilhado.
* Novo caminho-valor (`expression.zig` + `core.zig:2490`): `alloca` slot
  resultado, `store` trailing no `try.body`, `store null` no `catch_bb`
  (bare try hoje só limpa `active_global:697-700` e salta), `load` em
  `after_bb`.
* `expression.zig:131,265` (collect locals/captures) já cobre `try_stmt`;
  validar que o slot não vaza como capture.

## 5. Coroutines / misc

* `src/core/coroutines.zig:285,401` + `coroutines_transform.zig:2178,2211`
  (`machineBuildTryStmt`) — rejeição uniforme de suspend em try-valor no MVP
  (mensagem dedicada, espelho G5 da 76 e `BreakInSuspendContext` da 78).
* `infer_stmt.zig:336,408,435` — `break` dentro de try-valor segue regra
  lambda/`for`-valor.

## 6. RED verify (esta fase)

```bash
./bin/eiwac test samples/tests/try_expression_test.ei
# esperado HOJE: error: Expected expression. (8 testes, 0 passam)
./bin/eiwac test samples/tests/exception_test.ei  # verde (regressão)
```

Cobertura RED: `samples/tests/try_expression_test.ei` (8 testes).

## 7. Tasks (GREEN)

* [x] **Task 81.1:** parser + flag `is_value` (+ `clone`).
* [x] **Task 81.2:** checker + `T?`/flatten/Void-error + rejeição catch-valor.
* [x] **Task 81.3:** emissor valor (slot + null no catch path).
* [x] **Task 81.4:** transform (rejeição task) + docs `language_tour.md §6`.
* [x] **Verify:** `try_expression_test.ei` 8/8 + suite cheia + `zig build test`.
* [x] **Cleanup pós-GREEN:** frame `setjmp` compartilhado
  (`emitTryBegin`/`emitTryPop` em `statement.zig`, usado pelos dois
  emissores); walkers de task unificados (`taskNodeHas(node, kind)`).

## 8. Follow-ups (OPEN, ver Roadmap "Follow-ups Phase 81")

* [ ] **F1 — `try/catch` como expressão com fallback:** `val r = try { a } catch { b }`
  com unificação `T` (hoje: `TypeError` dedicado).
* [ ] **F2 — try-valor em `task {}`:** plumbing do slot `res` na state machine
  (hoje: `TypeError` uniforme, espelho G5/78).
* [ ] **F3 — `try` como operando geral:** LHS do `?:` conta como slot-valor
  (`inferBinaryExpr` marca antes de inferir — só converte erro em valor);
  ramos de ternário e demais operandos binários continuam fora.
  `obj.x = try {...}` não verificado.
* [ ] **F4 — Cobertura `T` contract/genérico:** `val r: Drawable? = try {...}`
  sem teste (emissão via fat pointer não exercitada).
* [ ] **F5 — Phase 80 (bug herdado, confirmado):** `try { 0 }` retorna `null`
  — escalar zero boxeia para ponteiro nulo. Ver `try { 41 + 1 }` OK.
