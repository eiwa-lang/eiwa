# Handoff — Bloco B Real: Boehm GC dentro do JIT LLVM

> **⚠️ OBSOLETO (2026-08):** o **Bloco B foi implementado** — o JIT LLVM aloca via
> `GC_malloc`/`GC_realloc` de verdade (`prefer_gc_alloc`, `getHeapAllocFn`/`getHeapReallocFn`,
> `GC_init` host-side, `registerJITGlobalsAsRoots`, ctor `__eiwa_gc_init_ctor`). Mantido apenas
> como **histórico da investigação** (causa raiz e tentativas). O plano correspondente
> (`tasks-bloco-b-gc-jit.md`) foi removido.

> **Status (2026-08):** investigado e tentado, **NÃO resolvido**. Este doc é o handoff completo para
> quem for atacar o Bloco B de verdade. Registra o que já foi feito, o que foi tentado e quebrou,
> a causa raiz real, o checklist de implementação, e os special-cases que ficam redundantes ao
> resolver. Links para `docs/roadmap.md` e `docs/tasks-backend-parity.md` no final.

---

## 1. O que é o "Bloco B Real"

O **Bloco B** de `docs/tasks-backend-parity.md` descreve WORKAROUNDs de libgc no JIT: o código
JIT'd aloca com **`malloc` cru** (memória **não zerada**, sem GC) em vez de `GC_malloc`, porque o
host `eiwac` não linkava libgc — então `GC_malloc` resolvia pra null/garbage no JIT.

**Bloco B Real** = fazer o JIT usar **`GC_malloc` de verdade**: memória zerada + gerenciada pelo
Boehm GC, idêntico ao backend C (que usa `GC_MALLOC` via `eiwa_runtime.h`). Isso:
- **Elimina o heisenbug** de memória não inicializada (o maior problema atual do LLVM).
- **Elimina os leaks** (hoje `malloc` nunca libera).
- **Torna redundantes vários special-cases** hand-emitidos (seção 6).

---

## 2. Estado atual (fechado) — 2026-08

Guardrail verde em **ambos os backends**:
```
./bin/eiwac test --backend=c    samples/tests   → ALL 59 TESTS PASSED
./bin/eiwac test --backend=llvm samples/tests   → ALL 59 TESTS PASSED
zig build test                                    → pass
```

Commits relacionados (no `main`):
- `7c04c71` — fix: emit void-safe stores + hand-emit socket helpers.
- `8ab3318` — fix: keep socket libc fns unstubbed, correct port order and property/not handling.
- `cd6035d` — ci (Docker namespace, pré-existente).

Nenhum código do Bloco B está commitado (o experimento foi revertido, ver seção 4).

---

## 3. O que o trabalho no bug-3 revelou (contexto)

O app `home` (servidor HTTP arest) **não roda no LLVM** (`eiwa run --backend=llvm`). Durante a
investigação foram corrigidos **5 bugs reais do emitter** (commitados acima):

| Bug | Fix | Local |
|---|---|---|
| `socket`/`bind`/`listen`/`accept`/`read`/`write`/`fcntl`/`close`/`memset`/`calloc` eram **stubados** (allowlist de libc incompleta) → `socket()` retorna 0, nenhum socket real | adicionados à allowlist do stub-pass | `core.zig:856-866` |
| Porta **byte-swapped** no `sockaddr_in` (bindava na porta errada) | ordem big-endian corrigida | `core.zig` (emitSocketHelpers) |
| Campo de classe (`this.builder.mcpBuilder`) resolvido como **global** → load null → IR inválido | skip do path global p/ class-property | `expression.zig` (get_expr) |
| `!` (not lógico) retornava **i64** → `br i64` inválido | retorna i1 | `expression.zig` (.bang) |
| store de valor `void` travava o compilador (`Task<Void>`) | helper `storeValue` | `expression.zig`/`statement.zig` |

Resultado atual no LLVM: o servidor arest **binda na porta certa, aceita conexões, e o
dispatcher deixa de ser stubado** — mas **não serve HTTP** (ver seção 7).

---

## 4. O que foi tentado para o Bloco B e o que quebrou

**Experimento (REVERTIDO — não commitado):**

1. **Linkar libgc no host `eiwac`** (`build.zig`): `addLibraryPath(/opt/homebrew/lib) + /usr/local/lib` +
   `linkSystemLibrary("gc", .{})` para `exe_module` e `test_module`.
   - ✅ **Funcionou**: `otool -L bin/eiwac` mostra `/opt/homebrew/opt/bdw-gc/lib/libgc.1.dylib`.

2. **Trocar a preferência de alocação de `malloc`→`GC_malloc`** no emitter (helper `getGCOrMalloc`
   em `core.zig`, aplicado nos ~15 sites `malloc orelse GC_malloc`).
   - ❌ **Quebrou: 11 testes SIGABRT** no LLVM (crash silencioso, sem mensagem).

**Diagnóstico do crash:** programas JIT que **não usam neco** (ex: `mut_test.ei`,
`serialization_test.ei`) nunca chamam `GC_init()`. O `@MainWrapper` `Neco_main_wrapper` é quem
chama `GC_init()`. Sem init, `GC_malloc` crasha (assert/SIGABRT). Além disso, mesmo com init, o
GC precisa **escanear as raízes corretas** do JIT (globals + stacks) para não coletar objetos vivos.

**Conclusão:** o Bloco B **não é só "linkar libgc"**. É integração GC↔JIT completa.

---

## 5. Causa raiz real + checklist de implementação (Bloco B Real)

### Por que o JIT não pode usar `GC_malloc` hoje
1. **Sem `GC_init`** em programas sem neco → `GC_malloc` crasha.
2. **Sem registro de raízes** dos globals/stacks do JIT → GC coleta objetos vivos → crash/UB.
3. O `malloc` cru atual mascara tudo isso (nunca coleta, mas também nunca zera).

### Checklist para resolver de verdade
- [ ] **`GC_init()` sempre** antes de rodar qualquer programa JIT, não só nos com neco.
      Idealmente no `executeJIT` (`core.zig`) antes de chamar o main, ou num wrapper de init
      sempre presente. Ver como `Neco_main_wrapper` faz (`neco_wrapper.c:165`).
- [ ] **Registrar raízes do JIT**: globals do módulo como GC roots
      (`GC_add_roots`), e integrar com o esquema de coroutine stacks já existente em
      `neco_wrapper.c` (`eiwa_track_stack`/`eiwa_gc_fix_stackbottom`).
- [ ] **Trocar os ~15 sites** `malloc orelse GC_malloc` → `GC_malloc orelse malloc`
      (helper `getGCOrMalloc` já testado). Lista em `tasks-backend-parity.md` B1–B4 +
      os sites novos:
      - `core.zig:141,1100,1726,1853,2533`
      - `expression.zig:425,448,818,870,1128,1588,2188,2386,3736`
      - `statement.zig:85`
- [ ] **`GC_REALLOC`** para `EiwaArray_push` / `gcRealloc` (o C usa `GC_REALLOC`; hoje usa
      `realloc` cru). Ver `tasks-backend-parity.md` B4.
- [ ] **Validar**: `zig build test` + 59/59 nos 2 backends + o app `home` no LLVM.

> ⚠️ **Risco:** integração de GC com neco (stacks alternados) é delicada. O `neco_wrapper.c` já
> tem a infra de `eiwa_track_stack`/`GC_add_roots`/`eiwa_gc_fix_stackbottom` justamente para isso
> — reaproveitar, não reinventar.

---

## 6. Special-cases a REMOVER quando o Bloco B resolver

Quando o JIT tiver GC_malloc (e idealmente o runtime linkado no host), estes ficam redundantes:

| ID (parity-doc) | Special-case | Por que fica redundante |
|---|---|---|
| **C4** | `emitSocketHelpers` (`core.zig:2074`) — hand-emite os 6 helpers POSIX duplicando `net_helpers.h` | com o runtime linkado no host, resolve da libc/runtime real |
| **A10** | `emitToStringHelper` (`core.zig:1677`) — duplica `eiwa_to_string` | helper real disponível |
| **A11** | `emitHashStringHelper` (`core.zig:1769`) — duplica `String.hashCode` | idem |
| **A12** | `emitStrReplaceHelper` (`core.zig:1829`) — duplica `String.replace` | idem |
| **B1–B4** | WORKAROUNDs `malloc`/`realloc` no JIT | viram `GC_malloc`/`GC_REALLOC` |
| `emitCharAtHelper`, `emitWriteByteHelper`, `emitRandomBytesHelper`, `emitNowMillisHelper` | idem (`core.zig:1998,2018,2040,2307`) | com runtime no host, linka o helper real |

**Mas atenção:** a maioria desses (`emitToStringHelper` etc.) também serve o **build nativo**
(`emitNativeBinary`), que já linka `-lgc`. A remoção deve ser avaliada caso a caso — alguns podem
precisar virar libs linkadas em vez de IR re-emitido. O item C4 (`emitSocketHelpers`) é o maior
e mais claramente removível com o runtime no host.

---

## 7. O projeto `home` (arest) — estado no LLVM

- ✅ Binda na porta certa (`fd=3`, `TCP *:PORT LISTEN`).
- ✅ `accept()` bloqueia e retorna conexão real.
- ✅ Dispatcher/serveStatic sem stubs.
- ❌ **Não serve HTTP** (`curl → HTTP 000`).
- ❌ **Heisenbug de memória não zerada** (malloc cru) ainda presente — some/muda com layout.

**Blockers restantes para o `home` funcionar no LLVM:**
1. **`Socket.read` stubado** — `buf?.writeByte(n, 0)` (null-safe call de método em `Pointer`)
   não é resolvido no get_expr → `PropertyNotFound` → não lê o request.
   Local: `expression.zig` get_expr (métodos de `Pointer`), e o special-case `writeByte`→
   `eiwa_write_byte` existe no call path (`expression.zig:1763`) mas o get_expr falha antes.
   → Este é um **gap de dispatch de método em Pointer**, não do Bloco B.
2. **Longa cauda** do path de resposta (`writeResponse`, etc.) — pode revelar mais gaps.
3. **Bloco B Real** (seção 5) — para eliminar o heisenbug de memória.

> O backend **C** do `home` funciona (é a base de trabalho do usuário). O LLVM é o objetivo.

---

## 8. Guardrails — como verificar qualquer mudança

```bash
zig build                                          # compila
zig build test                                     # testes do compilador (Zig)
./bin/eiwac test --backend=c samples/tests         # 59/59
./bin/eiwac test --backend=llvm samples/tests      # 59/59
# app home:
../../eiwa-lang/bin/eiwa run --backend=llvm        # (no dir do projeto home) — deve subir e servir HTTP
```

---

## 9. Links para docs

- **`docs/roadmap.md`**: Phase 65 (`@Source` C no LLVM + `@MainWrapper`), Phase 20 (parity gaps),
  Phase 63/64 (parity concluída). Referência de onde o runtime C é compilado pro JIT.
- **`docs/tasks-backend-parity.md`**:
  - **Bloco B** (WORKAROUNDs libgc): `B1`–`B4` — a seção que este doc expande.
  - **Bloco A**: dívida de modelo de String (A1–A12) — inclui os helpers que o Bloco B destrava.
  - **C4**: `emitSocketHelpers` (DUP/WORKAROUND).
- **Runtime do GC/neco**: `src/runtime/third_party/neco/neco_wrapper.c` — `eiwa_track_stack`,
  `GC_add_roots`, `eiwa_gc_fix_stackbottom`, `Neco_main_wrapper` (chama `GC_init`).

---

## 10. Resumo pro próximo esforço

> **Bloco B Real não é linkar libgc.** É: (1) `GC_init()` garantido no JIT, (2) raízes JIT
> registradas, (3) flip `malloc→GC_malloc` + `GC_REALLOC`. Só depois disso os special-cases
> hand-emitidos (C4, A10–A12, B1–B4) podem ser removidos. Separe isso do bug do `writeByte`/Pointer
> (dispatch de método em Pointer), que é um gap independente que bloqueia o `home` servir HTTP.
