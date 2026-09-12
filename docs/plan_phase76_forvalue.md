# Plano — Phase 76: `for` como expressão (`List<T>`, estilo `.map`)

## 0. Decisões fechadas (brainstorming)

1. **Sempre `List<T>`:** `break v` anexa `v` e encerra (nunca vira o resultado —
   sem união `List<T> | R`, sem Rust-`loop`). `break` bare encerra e devolve o
   coletado até ali.
2. **`if` sem `else` em posição de valor vale `T?` (conserto do `Void` calado).**
   Hoje `val a = if (false) { "asd" }` compila com `a: Void` e só explode
   depois (`PropertyNotFound` longe da causa). Com a regra nova, vale `String?`
   (`null` no caminho falso) — o short ternary de bloco (`c ? v` já vale `T?`
   hoje). Statement (`if` como instrução) continua `Void`, intocado.
   Consequência direta: o filtro bare funciona sem regra própria do `for`:
   `for ([1,2,3]) { n -> if (n > 1) n }` → corpo `Int?` → null pula → `[2, 3]`.
   Branch `Void` em posição de valor = `TypeError` (precedente: Void Safety do
   short ternary, Phase 18) — é o buraco fechado, não nova restrição arbitrária.
3. **MVP:** sync + `List`/`Array` apenas. `task {}` com `for`-valor = erro
   (uniforme, como o `break` na 78). `for`-valor sobre `Map` = `TypeError`
   explícito "not yet supported" (o `__brk` + append-adiado da 75 não sai de
   graça). Lista vazia exige anotação.

## 1. Semântica alvo

```kotlin
// map puro: trailing expression coletada por iteração
val doubled = for ([1, 2, 3]) { it * 2 }   // List<Int> = [2, 4, 6]

// statement: idêntico a hoje, zero-alloc (nada coletado, nada alocado)
for ([1, 2, 3]) { println(it) }

// filter implícito: null não entra na lista (bare-if vale T? pela regra 2)
val evens = for ([1, 2, 3, 4]) { n -> if (mod(n, 2) == 0) n else null }  // [2, 4]
val odds = for ([1, 2, 3, 4]) { n -> mod(n, 2) == 1 ? n }                // [1, 3]
val odds2 = for ([1, 2, 3, 4]) { n -> if (mod(n, 2) == 1) n }            // [1, 3]

// o conserto do Void calado, fora do for:
val a = if (false) { "asd" }   // String? = null (antes: Void silencioso)

// break bare: encerra, devolve o coletado até ali
val first2 = for ([1, 2, 3, 4]) { i, n -> if (i == 2) break; n * 10 }    // [10, 20]

// break v: anexa v e encerra
val withEnd = for ([1, 2, 3]) { n -> if (n == 2) break -1; n }           // [1, -1]

// anotado: T vem da anotação, corpo checado contra ela
val xs: List<Int> = for (getNums()) { it * 2 }

// ERROS (corpo Void continua erro — só null filtra):
for ([1, 2]) { println(it) }                    // statement: ok, sem lista
val bad = for ([1, 2]) { println(it) }          // TypeError: corpo Void em for-valor
val e: List<Int> = for ([]) { it }              // ok (T da anotação)
val u = for ([]) { it }                         // TypeError: sugira anotação
```

Regras:

- Modo-valor ⇔ o `for` está em: inicializador de `val`/`var`, RHS de atribuição,
  valor de `return`, ou trailing statement de bloco-valor (corpo de lambda/fun
  com retorno não-`Void`, branch de `if`/`when`-valor). Todo o resto = statement.
- `for` não aninha em expressões (só existe em posição de declaração) — os slots
  acima são exaustivos, sem precisar de atributo herdado global. O `if`/`when`,
  que aninham, carregam a mesma flag (`is_value`) nos mesmos slots.
- `if` sem `else` com `is_value`: branch `T` → `if` vale `T?` (achata se já
  anulável); branch `Void` → `TypeError` (Void Safety). Sem `is_value`:
  `Void` como hoje — statement zero risco de regressão por construção.
- `T` do `for`: do corpo (trailing não-nulo; `T?` coleta com null-skip) ou da
  anotação `List<T>` quando houver; `break v` e trailing compatíveis com `T`.
- `break`/`break v` fora das regras da 78: sem mudança (incl. erro em `task`).
- `return` em lambda: sem mudança (ADR 53).

## 2. Mudanças por camada

### 2.0 Stdlib `map`/`filter` (opcional, sem compilador — pode pousar antes)
`fun map<T, R>(xs: List<T>, f: (T) -> R): List<R>` e `filter` em
`std.collections` via `for` + `MutableList` atuais. Compila hoje; serve de
referência executável da semântica e de fallback até o GREEN.

### 2.1 Investigação (primeiro)
- Confirmar os slots-valor no checker: `inferVarDecl` (init), `inferAssignment`
  (RHS), `inferReturnStmt` (valor), corpos de `fun` (como o trailing é inferido
  e checado contra o retorno declarado?), `inferBranchAsExpression` ×
  `checkBlock` em `if`/`when` statement (a 79 usa o primeiro sempre — trocar o
  statement para `checkBlock` ou passar flag? medir regressão em `if_expr_test`).
- Como `array_literal` constrói/infere `List<T>` (reusar para o tipo resultado e,
  se possível, para a emissão do builder).
- Como `MutableList.add` / `.freeze()` baixam no emissor (reusar na coleta).

### 2.2 AST (`src/core/ast.zig`)
- `for_stmt`: `collect: bool = false` (modo-valor). `if_expr`/`when_expr`:
  `is_value: bool = false` (propaga para branches — setado pelos mesmos slots).
- Sem mudança no parser (sintaxe idêntica; modo é inferido).

### 2.3 Checker (`infer_stmt.zig`, `core.zig`, `infer_decl.zig`, `infer_expr.zig`)
- Sites que marcam: var-init, assignment-RHS, return-valor (`collect = true`
  direto no nó `for`; idem `is_value` em `if`/`when` nessas posições).
- Trailing: corpo de lambda (`collect` = retorno esperado não-`Void`/inferido),
  corpo de `fun` (mesma regra vs retorno declarado), branch de `if`/`when`
  **apenas se** o `if`/`when` está com `is_value`.
- `inferIfExpr` sem `else` com `is_value`: branch `T` → `if` vale `T?`
  (achata `T??`, espelha o short ternary); branch `Void` → `TypeError` dedicado.
  Sem `is_value`: `Void` como hoje. `else if` sem `else` final cai na recursão
  (interno `T?` unifica com o externo). Corpo do `for`-valor é inferido em modo
  bloco-valor (trailing com `is_value`), então o bare-if filtra sem regra extra.
- `inferForStmt` com `collect`:
  - infere iterável (List/Array; **Map → TypeError dedicado** nesta fase);
  - T do corpo (trailing: `Void` → erro, `T?` → coleta com null-skip,
    `T` → coleta); com anotação `List<R>`: checa compatibilidade;
  - `break v` no corpo: compatível com T (`break` em loop-valor mira o loop;
    o `is_lambda_break` continua só para lambdas);
  - `resolved_type = List<T>` (construir como o literal faz).
- `for` statement (`collect=false`): idêntico a hoje (zero-alloc garantido por
  construção — o emissor nem cria o builder).

### 2.4 Emissor LLVM (`statement.zig` `for_stmt`)
- `collect=false`: caminho atual, intocado.
- `collect=true`: antes do loop, cria builder `MutableList<T>` (reusar emissão
  de `MutableList(...)` + `.add`, ou manipulação direta do buffer espelhando o
  literal); fim de cada iteração: avalia o valor, null-check (`T?` pula),
  append; `break` bare → `br after`; `break v` → avalia, append, `br after`;
  após o loop: `freeze()` → `List<T>`.
- `if`-valor sem `else`: caminho falso emite `null` de tipo `T?` (espelhar o
  short ternary; Phase 79 nota que o emissor já estava pronto p/ bloco-valor —
  confirmar o caminho sem-`else` em posição de expressão).
- Reusar a pilha `LoopStack` da 78 sem mudança (só `after_bb` importa aqui).

### 2.5 Coroutines transform (rejeição, espelho da 78)
- `rewriteTaskCall`: escanear o corpo também para `for` com `collect=true` →
  mesmo `TypeError` uniforme (mesmo sem suspensão).
- `machineBuildStmt`/`machineBuildBranch`: `for_stmt` com `collect` → erro
  dedicado (cobre `@Suspend fun` fora de `task`).
- Sem promotion de coletor nesta fase (é o follow-up: coletor como body field).

## 3. Testes (TDD: RED depois GREEN)

Novo `samples/tests/for_value_test.ei` (~12 testes):
1. map básico (`it * 2` → `[2,4,6]`, tipo e ordem).
2. param nomeado + índice (`i, n ->`, ex. `break` no índice).
3. null-skip explícito (`else null`) e short ternary (`c ? n`).
4. `break` bare devolve prefixo; `break v` anexa e encerra.
5. anotado (`val xs: List<Int>`) + `break v` compatível.
6. statement inalterado (soma com `var`, sem alocação observável).
7. vazio anotado (`List<Int> = for ([])`) — conforme inferência de `[]` permitir.
8. `for`-valor como valor de `return` em `fun`.
9. `if`-valor sem `else`: `val a = if (false) { "asd" }` → `String?` = null;
   statement-`if` continua `Void` (regressão zero por construção).
10. Negativas manuais (padrão 78): corpo `Void`, branch `Void` em `if`-valor,
    `break v` incompatível, `for`-valor sobre Map, `for`-valor em `task`.

Verify: `for_value_test.ei` verde + suíte completa + `zig build test`, sem
regressão em `for_lambda_test` / `for_index_test` / `for_map_test` /
`arrays_and_loops_test` / `if_expr_test`.

## 4. Docs

- `docs/language_tour.md` §3 (`for` expressão, null-skip, `break` com valor).
- `docs/roadmap.md` Phase 76: checklist + verify.
- `docs/decisions.md`: ADR 65 (sempre-`List`, null-skip vs Void-erro, slots-valor,
  rejeição em task, Map follow-up).

## 5. Fora de escopo (follow-ups)

- `for`-valor sobre `Map`/`keys()`/`values()` (append-adiado do `__brk_val`).
- `for`-valor em `task {}` / `@Suspend` (coletor como body field da state machine).
- `for` com tipo de elemento heterogêneo (união como `T`? hoje: primeiro tipo
  comum via compatibilidade, como branches do `if`).
- Labels (`break@outer` com valor).
- Otimização: pré-dimensionar o builder com `size()` do iterável.

## 6. Riscos

- **Regra de slots incompleta:** `for` em posição que esquecemos (ex.: trailing
  de `fun` com retorno inferido) compila como statement e "engole" a lista —
  erro silencioso de UX. Mitigação: Task 2.1 levanta TODOS os slots; teste 8
  cobre `return`; tour documenta os slots.
- **`if` statement trocar para `checkBlock`:** pode mudar `resolved_type` de
  branches e quebrar a 79 — mitigação: `if_expr_test` no guardrail + comparar
  antes/depois.
- **Inferência de `[]` vazio:** se o literal vazio não ancora tipo algum, o
  teste 7 vira erro esperado documentado (não falha da fase).
- **Fallout do `if`-valor:** branch `Void` em slot-valor vira `TypeError` — código
  existente que faz `val x = if (c) { sideEffect() }` (hoje: `x: Void` calado)
  passa a não compilar. A suíte (457) quantifica; se o estrago for grande ou
  inocente, fallback: branch `Void` em slot-valor mantém `Void` (conserto parcial
  — só branches não-`Void` viram `T?`), documentado no ADR.
- **`T?` vs `Void` no trailing do `for`:** com a regra 2, bare-if filtra; corpo
  genuinamente `Void` (`println`) continua erro dedicado.
