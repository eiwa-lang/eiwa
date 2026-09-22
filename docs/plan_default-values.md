# Plan — Default values: nullable fn-type + lambda default (TDD)

Status: **RED** (failing tests committed, fix pending).
RED tests: `samples/tests/fn_default_value_test.ei`,
`samples/tests/lambda_lookahead_test.ei`.

## 1. Origem

`underhold-webclient-ei/src/shared/template/components/ui.ei:12-20`:

```kotlin
fun BodyBuilder.uiButton(
        label: String? = null,
        ...
        handler: (BodyBuilder.() -> Void)? = null
)
```

- Falha 1: `error: Expected '->' in function type signature. --> ui.ei:19:43`
- Após trocar para `handler: BodyBuilder.() -> Void = {}` —
  Falha 2: `error: Expected parameter name in lambda. --> ui.ei:19:45`

Bare `BodyBuilder.() -> Void` (sem default) compila — prova em
`layout.ei:9`, `htmx_extensions.ei:6`, `ui.ei:154,173`.
`String? = null` compila. `= {}` isolado em arquivo pequeno também
compila. Os dois bugs abaixo explicam os erros no arquivo real.

## 2. Bug A — `(Fn)?` não parseia (confirmado)

`src/frontend/parser/core.zig:115-138` (`core_parseType`): ao ver `(`,
sempre interpreta como tipo-função `(params) -> retorno` e exige `->`
após `)`. Em `(BodyBuilder.() -> Void)`, o primeiro "parâmetro" consome
`BodyBuilder.() -> Void` inteiro (ramo receiver, `core.zig:180-205`);
sobra `)` e depois `?` onde se esperava `->`.
**A linguagem não tem agrupamento parentetizado de tipos.**
Repro mínima (falha hoje):

```kotlin
fun maybeDouble(n: Int, cb: ((Int) -> Int)? = null): Int {
    if (cb != null) {
        return cb(n)
    }
    return -1
}
```

**Fix F1 (`core.zig`):** suportar agrupamento — ao ver `(`, se não houver
`->` após `)`, tratar como tipo agrupado e aplicar `?` / `| Null` ao
grupo. Preservar `(A, B) -> R`, `(A) -> R`, `R.() -> Ret`, `String?`,
`A | B`. Questão em aberto (não travada pelo RED): precedência de
`R.() -> Ret | Null` (retorno anulável vs função anulável) — decidir e
documentar; o RED usa a forma agrupada explícita.

## 3. Bug B — lookahead de lambda começa um token atrasado (confirmado)

**Root cause:** `parseLambdaLiteral`
(`src/frontend/parser/expression.zig:409-444`) detecta `params ->`
com um lookahead (`temp_lexer`), mas todos os call sites fazem
`match(.l_brace)` ANTES de chamar — o que já avança `current` para o
primeiro token do corpo. `var temp_lexer = self.lexer` então escaneia
a partir de DEPOIS de `current`, ou seja, **um token após o `{`**.

Para `{}` vazio: após o `match`, `current` já é `}` e o lexer está após
ele — o lookahead varre o código SEGUINTE ao lambda até `}`/eof em
profundidade 0. Qualquer `->` posterior em profundidade 0 (assinaturas
de fn-type, etc.) liga `has_arrow` falsamente → o parser tenta ler
nomes de parâmetro a partir de `}` → `Expected parameter name in
lambda` apontando para logo após o `{}`.

Evidência (bissecção no `ui.ei` real + repros mínimas em `/tmp`,
todas com o `bin/eiwac` atual):

- `= {}` sozinho no arquivo: PASSA.
- `= {}` + função posterior com parâmetro fn-type (`(Int) -> Int` ou
  `R.() -> Void`, com ou sem default): FALHA no `{}` anterior.
- Ordem importa: fn com fn-param ANTES + `= {}` DEPOIS: PASSA.
- Função posterior SEM parâmetro fn-type: PASSA.
- Mesmo bug em trailing lambda de nível superior (`runIt {}` seguido
  de `fun useIt(cb: () -> Int)`): FALHA em `runIt {}`.
- Trailing `{}` aninhado sobrevive por sorte (o `}` que o envolve
  encerra o scan).
- Corpo NÃO-vazio com anotação fn-type dentro (`{ val f: (Int)
  -> Int = ... }`): o `->` da anotação é confundido com arrow de
  parâmetros → mesma falha dentro do corpo.

Repro mínima do caso 1 (falha hoje, erro em `3:69`):

```kotlin
type Widget(var label: String = "")

fun Widget.first(label: String? = null, init: Widget.() -> Void = {}) {
    print(label ?: "none")
    init(this)
}

fun Widget.second(id: String, bodyContent: Widget.() -> Void) {
    print(id)
    bodyContent(this)
}
```

**Fix F2 (`expression.zig:409-444`):** incluir `self.current` no
lookahead (processar o token atual antes de escanear o resto) +
atalho explícito: se `self.check(.r_brace)`, corpo vazio → sem
parâmetros, sem lookahead. Isso cobre os casos 1–2 em todos os call
sites (default e trailing). Checar também `{ -> ... }` (arrow como
`current`). Para o caso 3 (anotação `->` dentro do corpo), o scan
ingênuo é insuficiente — recomendação: parse especulativo de
`param (, param)* ->` com save/restore do parser (padrão já usado em
`call()`, `expression.zig:247-289`) em vez de scan léxico, ou abortar
o lookahead em tokens impossíveis no head de parâmetros (`=`, `;`,
keywords como `val`/`fun`).

**Fix F3 (`type_checker/infer_expr.zig:640-644`):** após F1/F2,
garantir que initializer lambda (inclusive vazio) seja checado contra
o tipo declarado (receiver + `Void`, zero params) e que
`if (cb != null)` estreite parâmetro função.

## 4. TDD

- RED: `fn_default_value_test.ei` (Bug A + Bug B em defaults) e
  `lambda_lookahead_test.ei` (Bug B em trailing + guard que já passa).
- GREEN: F1+F2(+F3 se necessário), `zig build`, ambos passam.
- Sem regressão: `zig build test` + `./bin/eiwac test` verdes;
  `when ... ->`, `for ... { a, b -> }`, trailing `{}`/`{ }`,
  `(Int, String) -> Bool`, `BodyBuilder.() -> Void`,
  `Map<K,V> = Map()` intactos.
- Validação ponta a ponta: `uiButton` com `handler` opcional volta a
  compilar em `underhold-webclient-ei` (`eiwa run`).

## 5. Referências

- `src/frontend/parser/core.zig:115-250` — `core_parseType`
- `src/frontend/parser/declaration.zig:297-335` — params + `initializer`
- `src/frontend/parser/expression.zig:275-315,346-356` — call sites
  (`match(.l_brace)` → `parseLambdaLiteral`)
- `src/frontend/parser/expression.zig:409-456` — `parseLambdaLiteral`
- `src/frontend/parser/expression.zig:570-576` — `primary()` (`{`→lambda)
- `src/frontend/lexer.zig:8-16,44-49` — Lexer é streaming, sem estado
  global (cópia `temp_lexer` é independente; o bug é de posicionamento)
- `src/core/type_checker/infer_expr.zig:640-644`
- `samples/lambda_sample.ei`, `samples/tests/lambda_test.ei`,
  `samples/tests/default_params_test.ei`,
  `samples/tests/nullable_arg_test.ei`
- Build/test: `zig build` / `zig build test` / `./bin/eiwac run <file>` /
  `./bin/eiwac test <file>` (ver `AGENTS.md`, `Makefile`)
