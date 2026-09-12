# Plano — Phase 78: `break` / `break v`

## 0. Decisões fechadas (brainstorming)

1. **Escopo = ambos:** saída antecipada de loops + guards em lambda.
2. **Só síncrono nesta fase:** `break` dentro de `task {}` (ou função suspensa) = **erro de compilação**.
3. **Termo da lambda = `break v`:** sem reabilitar `return` em lambda (mantém ADR 53).
   Ideia-guia: o `for` comum vai retornar valor como `list.map()` do Kotlin (Phase 76);
   `break v` já nasce como o veículo desse valor.
4. **Sem `continue`:** pular iteração se escreve com `if`/`else` (a Phase 79 já dá
   valor ao `if`) — uma keyword só, menos superfície no checker/emissor.

## 1. Análise Swift e outras linguagens (resumo)

| Linguagem | Função | Lambda/bloco (saída local) | Loop |
|---|---|---|---|
| Swift | `return` + `guard-else-return` | `return` (local) | `break` / `continue` + labels |
| Kotlin | `return` | `return@label` (local); `return` puro é non-local | `break` / `continue` + labels |
| Rust | `return` | `return` (local) | `break` (+ valor) / `continue` + labels `'outer` |
| Dart | `return` | `return` (local) | `break` / `continue` + labels |
| Ruby | `return` | `next v` (= sai do bloco) / `break v` (= sai do iterador) | `break` / `next` |

Conclusão: `break` é o consenso para sair de loop. Para não reintroduzir
`return` na lambda (feio + proibido pelo ADR 53), Eiwa adota o modelo Ruby/Rust:
**`break v` sai do construto interno com valor**. `continue` foi descartado por
decisão de escopo (item 4 acima).

## 2. Semântica alvo

```kotlin
// Loop: bare break (statement, tipo Void)
while (cond) {
    if (x > 10) break
    sum = sum + x
}

for (nums) { n ->
    if (n > 100) break
    total = total + n
}

// Pular iteração: if/else, sem keyword
for (nums) { n ->
    if (n != 0) {
        total = total + n
    }
}

// Lambda: break v = saída local com valor (substitui o `return` proibido)
val f = { x: Int ->
    if (x < 0) break 0
    x * 2
}

// Loop com valor (ponte para a Phase 76 — for estilo .map):
// nesta fase o valor é checado mas descartado (loop ainda é statement Void);
// a Phase 76 passa a usá-lo como resultado do `for`.
for (nums) { n ->
    if (n < 0) break -1
    total = total + n
}
```

Regras:

- `break` bare: só dentro de `while`/`for`. Fora de loop e fora de lambda = `TypeError`.
- `break v`: dentro de lambda (sai da lambda com `v`, tipo = tipo de `v`, deve ser
  compatível com o tipo de retorno inferido/esperado da lambda) ou dentro de loop
  (checado, descartado nesta fase; vira valor do `for` na Phase 76).
- `break` dentro de `task {}` ou função/lambda suspensa = `TypeError`
  explícito (suspensão + salto não compõem nesta fase).
- `return` em lambda continua proibido (ADR 53, sem mudança).
- Sem labels nesta fase (loops aninhados: `break` = mais interno; labels = follow-up).

## 3. Mudanças por camada

### 3.1 Lexer (`src/frontend/lexer.zig`)
- `identifierType`: `"break"` → `.kw_break`.

### 3.2 AST (`src/core/ast.zig`)
- `TokenType`: `kw_break`.
- Novo nó: `break_stmt: struct { value: ?*ASTNode }`.
- Cobrir nos walkers: `clone.zig`, `coroutines.zig` (has/containsSuspend),
  `coroutines_transform.zig` (collect/rewrite — ver 3.5), `collectCallees`/`collectCaptures`
  no emitter.

### 3.3 Parser (`declaration.zig`, novo `breakStatement` em `statement.zig`)
- `if (match(.kw_break)) return breakStatement();`
- `break`: valor opcional = expressão se o próximo token pode iniciar expressão
  (mesmo padrão do `returnStatement`: nada se `r_brace`/`eof` à frente).

### 3.4 TypeChecker (`infer_stmt.zig` + `core.zig` dispatch)
- Novo estado de escopo: flag `is_loop_boundary` (ou contador `loop_depth` no
  `Scope`) setada ao inferir corpo de `while`/`for` — inclui o desugar do `for-map`
  (Phase 75), que gera `while` aninhado: o desugar deve propagar a flag.
- `inferBreakStmt`:
  - Caminha escopos: se achar `is_lambda_boundary` antes de função → contexto lambda.
  - Se dentro de suspend (`is_suspend` / bloco `task`) → erro "break não
    suportado em task (síncrono apenas)".
  - `break` bare fora de loop e fora de lambda → erro.
  - `break v` em lambda → infere `v`, tipo do stmt = tipo de `v`
    (compatibilidade com retorno da lambda checada no call site como hoje).
  - `break v` em loop (statement) → infere `v` (checa), tipo do stmt = `Void`
    (valor descartado; Phase 76 consome).
  - `break` bare em loop → `Void`.
- `return` em lambda: sem mudança (erro ADR 53).

### 3.5 Emissor LLVM (`statement.zig`)
- Pilha de loop por função: ao emitir `while_stmt`/`for_stmt`, empilha
  `{ after_bb }`; desempilha ao sair.
  - `break` bare → `br after_bb`.
  - `break v` em loop (statement) → avalia `v` e **descarta** (emite expressão,
    ignora valor), depois `br after_bb` (comportamento Kotlin de statement;
    documentar).
  - `break v` em lambda → mesma lowering do `return v` da lambda: o corpo da
    lambda é emitido como função; `break v` = `ret v` (com as coerções do path
    `return_stmt` da lambda, linhas ~2018 e ~1780 de `expression.zig`).
- Guardas: não emitir `br` se o bloco já tem terminador; posicionar builder no
  bloco seguinte morto ou marcar inalcançável (padrão já usado no `return`).

### 3.6 Coroutines transform
- `break` **nunca chega ao transform em task**: o checker rejeita
  antes (erro). No transform, tratar como `return_stmt` nos walkers
  (`hasTaskOrAwait`, `containsAwait`, collects) retornando `false` para o valor
  (sem hoisting de await — `break t.await()` = erro já dado pelo 3.4; se o valor
  contiver `await` fora de task, hoisting normal via `inferNode`).
- `for`+suspend (Task 68.1.1): sem mudança — `break` não existe nesse
  caminho por construção.

## 4. Testes (TDD: RED depois GREEN)

Novo `samples/tests/break_test.ei` (9 testes, RED confirmado):
1. `while` com `break` para soma limitada.
2. `for` com `break` (param nomeado, `it` implícito e `i, item`).
3. Lambda: `break v` early-exit (`{ x -> if (x<0) break 0; x*2 }`).
4. Lambda: `break v` tipo incompatível = erro (fixture negativa, no GREEN).
5. `break` fora de loop = erro de compilação (fixture negativa, no GREEN).
6. `return` em lambda continua erro (regressão ADR 53, no GREEN).
7. `break` em `task {}` = erro (novo, no GREEN).
8. `for` sobre Map com `break` (desugar Phase 75).
9. `break v` em loop-statement compila (valor descartado).
10. Aninhados: `break` sai do mais interno.

Verify: `break_test.ei` verde + suíte completa
(`./bin/eiwac test samples/tests`) + `zig build test` sem regressão.

## 5. Docs

- `docs/language_tour.md` §3 (loops) + §15 (lambda): `break`/`break v`.
- `docs/roadmap.md` Phase 78: checklist + verify.
- `docs/decisions.md`: ADR 64 (`break` vs `return`, `break v`, sync-only, ponte Phase 76).

## 6. Fora de escopo (follow-ups)

- `continue` — descartado por decisão de escopo (ver item 4 do §0); se um dia
  fizer falta, reabrir como proposta própria.
- Labels (`break@outer`) — fase futura.
- `for` como expressão com valor (Phase 76 consome o `break v` desta fase).
- `break` em `task {}` suspensa (exige plumbing na state machine).
- `when`/`try` como fronteira de `break` (só loop/lambda nesta fase).

## 7. Riscos

- Desugar `for-map` (Phase 75) gera `while` aninhado: `break` do usuário deve
  mirar o loop lógico, não o `while` interno — a flag de escopo (3.4) resolve,
  mas exige teste dedicado.
- `break v` em lambda genérica/monomorfizada: checagem de compatibilidade segue
  o caminho existente do trailing expression; sem caminho novo.
