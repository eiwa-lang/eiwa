# Regex — std.regex (engine 100% Eiwa)

Decisões (2026-09-13, branch `feature/std-regex`):

- **Engine própria em Eiwa puro** (zero deps C): parser + backtracker recursivo sobre bytes
  (`NativeMemory.readByte`) em `src/std/regex.ei`.
- **API Kotlin-parity**: `type Regex` com `matches` (full match), `find -> MatchResult?`,
  `replace` (todas as ocorrências) + atalhos `String.matchesRegex/findRegex/replaceRegex`.
- Compilação do pattern é **lazy** (`ensureCompiled()`): body-field initializers que chamam
  métodos de outros tipos importados se mostraram frágeis no emitter (`root` ficava null /
  "Variable not found"). Evitar esse padrão em std.
- **NÃO usar `Int?` para posições/índices**: o backend boxa escalares nullable via
  `IntToPtr` (expression.zig ~4534), então `0`/`0.0` viram `null`. Bug pré-existente do
  compilador, NÃO corrigido nesta branch. Workaround: sentinel `-1` (matchers retornam
  `Int`, `-1` = no match). `Type?` de heap (ponteiro) funciona normalmente.
- Módulo registrado em `src/core/type_checker/infer_decl.zig` (`std_modules` +
  `user_implicit_imports` — como `kotlin.text`, regex é default-import).
- Atribuição indexada `list[i] = x` desugar para `.put()` — usar `.set(i, x)` em std.
- Sintaxe suportada: literais, `.`, `\d \D \w \W \s \S \n \t \r`, classes `[a-z]`/`[^...]`,
  `^ $`, `* + ? {n} {n,} {n,m}` (greedy), grupos `(...)`, alternância `|`.
- Testes: `samples/tests/regex_test.ei` (14 testes). Docs: language_tour.md §33.

## Status do bug (atualizado 2026-09-13)
- CORRIGIDO na Phase 80 (branch `fix/nullable-scalar-zero`): representação
  **zero-sentinel** — box de escalar 0 vira `(ptr)0x8` (não-null), resto segue
  value-in-ptr; unbox faz o inverso. `== null`/`?.`/`?:`/`toString`/`==`
  funcionam sem mudanças nos null checks. Suite: 542 verdes.
