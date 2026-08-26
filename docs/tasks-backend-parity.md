# Tasks de Paridade Backend (LLVM vs C)

> **⚠️ SUPERSEDED (2026-08):** o backend C foi **removido** (coroutines stackless, ADR 48).
> Não há mais "paridade LLVM vs C". Este arquivo foi renomeado de propósito para permanecer como
> **índice operacional dos `TODO(emitter)`**
> restantes no backend LLVM (GAPs, SPECIAL CASEs, WORKAROUNDs, duplicações do runtime) — use-o
> para caçar dívidas técnicas do emissor. O trabalho estrutural (modelo de valor de `String`,
> dispatch via vtable real) continua valendo, referenciado pelo `docs/roadmap.md` (Task 61.5 /
> Task 64.11).
>
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
| C1 / C2 | `core.zig` | `emitLoadInt64`/`emitStoreInt64` duplicavam funções C em IR | **Removido** — substituído por chamadas nativas de stdlib (`Standard.loadInt64`/`Standard.storeInt64`) |
| Bloco B (GC no JIT) | `core.zig`, `expression.zig` | JIT usava `malloc` cru em vez de `GC_malloc` | **Resolvido** — `__eiwa_gc_init_ctor`, `GC_allow_register_threads()`, `registerJITGlobalsAsRoots()` e `prefer_gc_alloc` garantem alocações gerenciadas pelo Boehm GC no JIT e nativo |
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
| A10 | `core.zig:1884` | DUP | `emitToStringHelper` reimplementa a heurística `eiwa_to_string` do runtime (`0→"null"`, `1→"true"`, `<0x10000→int`, senão String) | médio |
| A11 | `core.zig:1959` | DUP | `emitHashStringHelper` copia manual `String.hashCode` (redundante se String for materializada) | médio |
| A12 | `core.zig:2024` | SPECIAL CASE | Helper hand-emitido de `String.replace` | médio |

---

## 🟡 B. WORKAROUNDs de libgc no JIT (CONCLUÍDO)
> **Resolvido:** O JIT e o build nativo alocam via `GC_malloc`/`GC_REALLOC` com registro de raízes globais e de threads (`prefer_gc_alloc`).

---

## 🔵 C. Duplicações de runtime (independem do modelo de String)

| ID | Local | Tipo | Descrição | Esforço |
|---|---|---|---|---|
| C3 | `expression.zig:477` | DUP/HEURISTIC | Teste "Stringable-ness" duplicado (get_expr vs call_expr) e stringly-typed (`"Stringable"`/`"core_Stringable"` + lista hardcoded) | **médio** — centralizar helper `isStringable(resolved_type)` |
| C4 | `core.zig:2275` | DUP/WORKAROUND | `emitSocketHelpers` hand-emite em IR os 6 helpers POSIX (`eiwa_tcp_bind/accept`, `eiwa_socket_read/write`, `eiwa_tcp_set_nonblocking`, `eiwa_socket_close`), duplicando `net_helpers.h` (`static inline`). Constantes hardcoded por plataforma (macOS vs Linux). | **médio** — compilar e linkar o wrapper C real |

---

## 🔴 D. GAPs reais (bugs potenciais / robustez)

| ID | Local | Tipo | Descrição | Esforço |
|---|---|---|---|---|
| D1 | `expression.zig:3249` | HEURISTIC | `when (x) is T` por heurística de range de ponteiro: `< 0x10000 → Int/Double`, `<= 1 → Bool`, `>= 0x10000 → custom`. | estrutural |
| D2 | `expression.zig:3856` | VALUE-MODEL | `coerceArg` box/unbox/extends em toda chamada (primitivas = ints crus, Union/contract = ponteiros). "Symptom, not a fix" | estrutural |
| D3 | `core.zig:306` | FRAGILE | `jmp_buf` modelado como `[64 × i64]` fixo; o tamanho real é plataforma/arch-específico. Fix: frame com `jmp_buf` real dependente do target. | médio |
| D4 | `statement.zig:537` | GAP | **LLVM só trata `catches[0]`** em `try/catch`. Se um código Eiwa usar 2+ catches (`catch (e: TypeA) ... catch (e: TypeB)`), o LLVM ignora os blocos subsequentes. | médio |

---

## 📌 Sugestão de ordem de execução

1. **C3** (helper `isStringable` único) — reduz drift entre get_expr/call_expr.
2. **D3** (`jmp_buf`) — fragilidade pontual de plataforma no frame de exceção.
3. **D4** (multi-catch LLVM) — suporte completo a múltiplos blocos catch tipados.
4. **C4** (`emitSocketHelpers`) — linkar runtime/helpers em vez de gerar IR manual.
5. **Bloco A** — modelo de valor de `String` (`{i8*, i64}`) e vtables reais (elimina A1–A12).

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
