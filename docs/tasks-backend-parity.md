# Tasks de Paridade Backend (LLVM vs C)

> **Contexto:** durante a fase de paridade LLVM/C (Phase 61-66) foram acumulados TODO no
> emissor LLVM (`src/backend/llvm_emitter/`) que mapeiam **GAPs reais**, **SPECIAL CASEs**,
> **WORKAROUNDs** (libgc) e **duplicações** do runtime. Este arquivo é o índice operacional
> desses TODO — para não depender de grep a cada sessão.
>
> **Linha de base (AGO/2026):** guardrail `samples/tests` **59/59** nos backends LLVM e C.
> Qualquer mudança deve manter esse guardrail + `zig build test` verdes.
>
> **Referência estrutural:** os itens de valor-modelo de `String` são pré-requisito para
> remover a tolerância de skip-stub — ver `docs/roadmap.md` **Task 61.5** (dispatch via
> vtable real) e **Task 64.11** (representação `String = {i8*, i64}`).

---

## ✅ Já resolvidos (AGO/2026)

| Item | Local | O que era | Como foi resolvido |
|---|---|---|---|
| Comment obsoleto (map_literal) | `expression.zig` (~3747) | TODO descrevendo fix já aplicado ("PREVIOUSLY returned null") | **Deletado** — o código já constrói o `Map` real |
| Comment obsoleto (field heuristic) | `expression.zig` (~274) | TODO sobre fallback `scope.get(name)==null` | **Deletado** — fallback removido via `owner_type_c_name` (`is_class_property`) |
| Tolerância skip-stub | `core.zig:555` | Comentário dizia "remove once Phase 61 lands" | **Comentário reescrito** — verificado que a tolerância ainda é necessária (detalhes no próprio TODO) |
| Reachability O(n²) | `core.zig` (~400) | `drainReachableWorklist` varria todos os statements por função do worklist | **Indexado** — `buildFuncIndex` + lookup O(1) |
| Method-scan por prefixo | `expression.zig` (~2750) | Fallback que varria todas as funções por `{tipo}_{metodo}` | **Removido** — provado que nunca encontrava match (só disparava para enum `toString`/`hashCode`); os lookups exatos (`c_name` → `resolved_c_name` → `{tipo}_{metodo}`) já cobrem |

---

## 🟠 A. Dívida estrutural: modelo de valor de `String` + dispatch via vtable

**Bloco único de trabalho** — ver roadmap **Task 64.11** (String `{i8*, i64}`) e **Task 61.5**
(SPECIAL CASEs via vtable real). Resolver o modelo de String torna redundantes quase todos
os itens deste bloco.

| ID | Local | Tipo | Descrição | Esforço |
|---|---|---|---|---|
| A1 | `core.zig:508` | HEURISTIC | Skip-list de primitivas por **nome** (`core_String`/`core_Int`/`core_Bool`/`core_Double`) em vez de flag de primitividade do type checker | estrutural |
| A2 | `expression.zig:476` | SPECIAL CASE | `Int.toDouble()` / `Double.toInt()` emitem casts diretos (FPToSI/SIToFP) fora do dispatch | médio |
| A3 | `expression.zig:504` | SPECIAL CASE | `hashCode` de Int/Bool/Double/String/Pointer por helper (`eiwa_hash_string`) em vez de vtable `Hashable` | médio |
| A4 | `expression.zig:1944` | SPECIAL CASE | `String.replace` roteado a `eiwa_str_replace` (não via vtable) | médio |
| A5 | `expression.zig:1975` | SPECIAL CASE | Intercept de `String.toString()` (identidade) antes do dispatch genérico | médio |
| A6 | `expression.zig:2094` | SPECIAL CASE | Concat inline de `+` em String (malloc/strlen/sprintf) porque String é `char*` cru | estrutural |
| A7 | `expression.zig:2884` | COUPLING | Pass-through get_expr↔call_expr de `toString`/`hashCode` (coupling sutil, ordem-dependente) — o pass-through de `hashCode` foi adicionado em AGO/2026 espelhando o de `toString`; colapsar num único path | médio |
| A8 | `expression.zig:381` | SPECIAL CASE | `push`/`get`/`set`/`length` de `.Array` inline (em vez de helpers `EiwaArray_*` como o C) | médio |
| A9 | `expression.zig:2935` | LAYOUT | `.length` sobre layout raw de buffer array (slot 0 = size, 1 = cap, 2.. = elems) | baixo-médio |
| A10 | `core.zig:1484` | DUP | `emitToStringHelper` reimplementa a heurística `eiwa_to_string` do runtime (`0→"null"`, `1→"true"`, `<0x10000→int`, senão String) | médio |
| A11 | `core.zig:1730` | DUP | `emitHashStringHelper` copia manual `String.hashCode` (redundante se String for materializada) | médio |
| A12 | `core.zig:1795` | SPECIAL CASE | Helper hand-emitido de `String.replace` | médio |

---

## 🟡 B. WORKAROUNDs de libgc no JIT

> **Causa raiz única:** o binário host `eiwac` não linka libgc, então código JIT que chama
> `GC_malloc` resolve para null/garbage e pendura. O emitter prefere `malloc` (leaks, sem GC)
> até o host linkar libgc. O build nativo (`emitNativeBinary`) já usa `-lgc`.

| ID | Local | Tipo | Descrição | Esforço |
|---|---|---|---|---|
| B1 | `core.zig:2252` | WORKAROUND | `malloc` em vez de `GC_malloc` na alocação de `type`/objetos | estrutural (build/link host) |
| B2 | `core.zig:1693` | WORKAROUND | `malloc` first no `core_Int_toString` (buf 32) | idem |
| B3 | `expression.zig:800` | WORKAROUND | `malloc` first na alocação de array | idem |
| B4 | `expression.zig:4417` | WORKAROUND | `realloc` first no `EiwaArray_push` (C usa `GC_REALLOC`) | idem |

---

## 🔵 C. Duplicações de runtime (independem do modelo de String)

| ID | Local | Tipo | Descrição | Esforço |
|---|---|---|---|---|
| C1 | `core.zig:1554` | DUP | `emitLoadInt64` emite IR inline que duplica `eiwa_load_int64` do runtime | **baixo** — linkar o helper em vez de re-emitir |
| C2 | `core.zig:1571` | DUP | `emitStoreInt64` idem para `eiwa_store_int64` | **baixo** — idem |
| C3 | `expression.zig:401` | DUP/HEURISTIC | Teste "Stringable-ness" duplicado (get_expr vs call_expr) e stringly-typed (`"Stringable"`/`"core_Stringable"` + lista hardcoded) | **médio** — centralizar helper `isStringable(resolved_type)` |
| C4 | `core.zig:2057` | DUP/WORKAROUND | `emitSocketHelpers` hand-emite em IR os 6 helpers POSIX (`eiwa_tcp_bind/accept`, `eiwa_socket_read/write`, `eiwa_tcp_set_nonblocking`, `eiwa_socket_close`), duplicando `net_helpers.h` (`static inline`). O backend C `#include` o header no `.c` gerado; o LLVM não tem C pra injetar e o JIT dylib nunca compila o header, então os externs resolveriam pra null (crash). Constantes hardcoded por plataforma (macOS vs Linux). **Torna-se redundante se/bloco B** (linkar runtime no host) for feito. | **médio** — só resolve com o runtime linkado no host |

---

## 🔴 D. GAPs reais (bugs potenciais / paridade)

| ID | Local | Tipo | Descrição | Esforço |
|---|---|---|---|---|
| D1 | `expression.zig:3249` | HEURISTIC | `when (x) is T` por heurística de range de ponteiro: `< 0x10000 → Int/Double`, `<= 1 → Bool`, `>= 0x10000 → custom`. **Espelhado no C** em `c_transpiler/expression.zig:1120` | estrutural |
| D2 | `expression.zig:3856` | VALUE-MODEL | `coerceArg` box/unbox/extends em toda chamada (primitivas = ints crus, Union/contract = ponteiros). "Symptom, not a fix" | estrutural |
| D3 | `core.zig:217` | FRAGILE | `jmp_buf` modelado como `[64 × i64]` fixo; o tamanho real é plataforma/arch-específico. Fix: frame com `jmp_buf` real (ou incluir `eiwa_runtime.h` como o C) | médio |
| D4 | `c_transpiler/statement.zig:197` | PARITY GAP | **LLVM só trata `catches[0]`** em `try/catch`; o C trata multi-catch tipado + else-rethrow. Se um Eiwa usar 2+ catches, o LLVM falha silenciosamente | médio |

---

## 🟢 E. Referências cruzadas no C (não são TODO do C, apontam para o LLVM)

| Local | O que é |
|---|---|
| `c_transpiler/statement.zig:197` | Comentário apontando que o LLVM só lida com `catches[0]` → item D4 |
| `c_transpiler/expression.zig:1120` | Comentário apontando que o LLVM herdou a heurística `when (x) is T` → item D1 |

---

## 📌 Sugestão de ordem de execução

1. **C1/C2** (duplicação `eiwa_load/store_int64`) — mecânico, baixo risco, elimina duplicação.
2. **C3** (helper `isStringable` único) — reduz drift entre get_expr/call_expr.
3. **D3** (jmp_buf) — fragilidade pontual de plataforma.
4. **D4** (multi-catch LLVM) — gap de paridade real, teste dedicado.
5. **Bloco A** — após D4; destrava a remoção da tolerância `core.zig:555`.
6. **Bloco B** — depende de decisão de build/link do host (libgc no `eiwac`).

---

## 📝 Notas de investigação (AGO/2026)

- **`JsonValue.toString` (enum/custom) ainda falha ao emitir**: `.toString()` em tipo enum
  desce pelo caminho de closure (`expression.zig` ~3050) e falha `PropertyNotFound` — registrado
  no roadmap (Task 61.5). Exige o modelo de String (Task 64.11) ou dispatch via vtable.
- **Bug real corrigido — `Pointer.toString`**: `get_expr` `.toString()` em `Pointer` puro agora
  emite `eiwa_to_string` (antes: stub silencioso retornando null). Espelha o C.
- **Bug real corrigido — double-call de `hashCode`**: `call_expr` re-invocava o resultado do
  `get_expr` como ponteiro de função (`call addrspace(64) i64 %hash()` → IR inválido). Pass-through
  adicionado em `expression.zig` (~2979).
