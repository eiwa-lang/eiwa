# Tasks — Bloco B Real: Boehm GC dentro do JIT LLVM

> **Origem:** `docs/bloco-b-handoff.md` (investigação 2026-08). Este arquivo é o plano
> operacional com fases, detalhes de implementação e validação. Atualizar os checkboxes
> conforme o trabalho avança.

**Objetivo:** o JIT (`eiwac run/test --backend=llvm`) alocar via `GC_malloc`/`GC_realloc`
reais — memória **zerada + gerenciada** pelo Boehm GC, paridade com o backend C —
eliminando o heisenbug de memória não zerada e os leaks do `malloc` cru.

**Princípio de segurança:** tudo gated pela flag `prefer_gc_alloc` (definida em
`main.zig` = `is_build or build_options.has_gc`). Host sem libgc ⇒ comportamento
atual bit-a-bit (malloc-first). Flag off = revert instantâneo.

---

## Diagnóstico confirmado na exploração (2026-08-17)

O handoff estava correto; a exploração do código revelou 3 armadilhas adicionais:

1. **Armadilha do stub-pass** (`core.zig:825-867`): `GC_init` e `GC_realloc` **não**
   estão na allowlist de símbolos libc — só `GC_malloc` está (linha 829). Sem adicioná-los,
   o stub-pass reescreve chamadas a eles como `ret void`/`ret null` → quebra silenciosa.
2. **Dois mecanismos de `GC_init`**:
   - **JIT**: chamar do lado Zig no início de `executeJIT` (extern gated por `has_gc`).
     Idempotente; cobre programas sem neco (o crash SIGABRT do experimento anterior).
   - **Build nativo** (`eiwac build`): o binário roda standalone → **emitir** call
     `GC_init()` no início do main quando `prefer_gc_alloc` (o backend C faz o mesmo,
     `c_transpiler/declaration.zig:353`).
3. **`GC_realloc` é função real exportada** pela libgc (diferente de `GC_REALLOC`, que é
   macro) → o JIT resolve do host via dlsym, sem forwarder. O forwarder FFI `GC_REALLOC`
   (`core.zig:148-168`) só troca o alvo interno.

**Sem risco novo em stacks**: a main thread é auto-registrada pelo `GC_init` (pthread);
stacks de corrotinas neco já são registradas como raízes por `neco_wrapper.c`
(`eiwa_track_stack`/`GC_add_roots`/`eiwa_gc_fix_stackbottom`) — reuso, zero trabalho novo.

**Confirmado na máquina:** libgc em `/opt/homebrew/lib/libgc.dylib`; APIs LLVM 21
`LLVMGetExecutionEngineTargetMachine`, `LLVMCreateTargetData`, `LLVMABISizeOfType`,
`LLVMIsDeclaration` presentes; `GC_add_roots(low, high_plus_1)` (gc.h:659). Nenhum teste
Zig executa o JIT (`zig build test` só tem testes triviais).

---

## Fase 1 — build.zig: detectar e linkar libgc no host

- [ ] `findLibgcPath()` no padrão de `findLlvmPath()`:
  - macOS arm64: `/opt/homebrew/lib/libgc.dylib`
  - macOS Intel: `/usr/local/lib/libgc.dylib`
  - Linux: `/usr/lib/x86_64-linux-gnu/libgc.so`, `/usr/lib/libgc.so`, `/usr/local/lib/libgc.so`
- [ ] `options.addOption(bool, "has_gc", has_gc)`.
- [ ] Linkar `gc` (`linkSystemLibrary`) + `addLibraryPath` em `exe_module` **e** `test_module`.
- [ ] Garantir `link_libc = true` quando linkar gc (hoje só é setado no bloco `has_llvm`).
- [ ] Verificar: `otool -L bin/eiwac | grep libgc` (macOS) após `zig build`.

## Fase 2 — core.zig: infra de alocação GC

- [ ] `pub var prefer_gc_alloc: bool = false;` (ao lado de `pub var verbose`).
- [ ] Externs gated: `const gc = if (build_options.has_gc) struct { extern "c" fn GC_init() void; extern "c" fn GC_add_roots([*]u8, [*]u8) void; ... }`.
- [ ] Helper único de alocação:
  ```zig
  pub fn getHeapAllocFn(mod) llvm.LLVMValueRef  // GC_malloc-first se prefer_gc_alloc, senão malloc-first
  pub fn getHeapReallocFn(mod) llvm.LLVMValueRef // GC_realloc-first se prefer_gc_alloc, senão realloc
  ```
  (ambos com fallback criação de protótipo, como os sites fazem hoje).
- [ ] Pass 0 do `emitModule` (`core.zig:122-128`): declarar protótipo `GC_realloc(ptr, i64) -> ptr` junto de `GC_malloc`/`malloc`.
- [ ] Allowlist do stub-pass (`core.zig:825-867`): adicionar `GC_init` e `GC_realloc`.
- [ ] Forwarders FFI (`core.zig:136-168`): `GC_MALLOC` → `getHeapAllocFn`; `GC_REALLOC` → `getHeapReallocFn` (trocar alvo fixo malloc/realloc pelos helpers).
- [ ] `main.zig` (~linha 471, **antes** de `emitter.emitModule`): `llvm_emitter.prefer_gc_alloc = is_build or build_options.has_gc;` — acessível pois `llvm_emitter` importa `core.zig` diretamente (main.zig:12).

## Fase 3 — executeJIT: GC_init + registro de raízes

- [ ] No início de `executeJIT` (`core.zig:3051`): `if (has_gc) gc.GC_init();` — idempotente
      (programas com neco chamam de novo via `Neco_main_wrapper`, sem problema).
- [ ] `registerJITGlobalsAsRoots(engine, mod)` — chamada **após** `LLVMCreateExecutionEngineForModule`
      e **antes** de invocar o main:
  - TargetData: `LLVMGetExecutionEngineTargetMachine(engine)` → `LLVMCopyStringRepOfTargetData` → `LLVMCreateTargetData`.
  - Iterar `LLVMGetFirstGlobal`/`LLVMGetNextGlobal`; **pular** `LLVMIsDeclaration`.
  - Por global: `addr = LLVMGetPointerToGlobal(engine, g)`; `size = LLVMABISizeOfType(td, LLVMGlobalGetValueType(g))`; `size > 0` ⇒ `GC_add_roots(addr, addr + size)` (high é exclusivo, gc.h:659).
  - Cobre: `eiwa_exception_stack`, `eiwa_active_exception`, singletons de `object`/`enum`
    (preenchidos pelos initializers dentro do main/shim), vtables e strings literais
    (falsos positivos de varredura conservadora são inócuos).
- [ ] Comentário no código explicando por que não remover roots (engine nunca é disposed,
      `core.zig:3077-3079`; roots vivem até o exit).

## Fase 4 — flip dos sites de alocação

Trocar `malloc orelse GC_malloc` (e equivalentes) por `getHeapAllocFn(mod)`; `realloc` por
`getHeapReallocFn(mod)`. Remover os comentários `TODO(emitter)`/WORKAROUND correspondentes
(substituir por referência curta a este doc).

- [ ] `core.zig:141` (forwarder GC_MALLOC — via Fase 2)
- [ ] `core.zig:1100` (`emitEnumInitializers`)
- [ ] `core.zig:1726` (`emitToStringHelper` int-to-str buf)
- [ ] `core.zig:2533` (`emitTypeConstructor` — **manter** o TODO do 128-byte fixo, é issue separada)
- [ ] `expression.zig:425` (Int → string em get_expr)
- [ ] `expression.zig:448` (Double → string)
- [ ] `expression.zig:818` (array_literal)
- [ ] `expression.zig:1128` (concat de strings)
- [ ] `expression.zig:1588` (closure env)
- [ ] `expression.zig:2188` (concat, outro path — tem fallback LLVMAddFunction)
- [ ] `expression.zig:2386` (substring)
- [ ] `expression.zig:3736` (map literal buckets)
- [ ] `expression.zig:3915` (fat_box struct→ptr — já é GC_malloc direto; manter, mas garantir fallback)
- [ ] `statement.zig:85` (boxed var cell)
- [ ] `expression.zig:4491` (`emitNativeArrayPush` grow): `realloc` → `getHeapReallocFn`

## Fase 5 — build nativo: GC_init emitido

- [ ] No path de emissão do main (`emitMainWrapperEntry` shim mais interno, `core.zig:908-935`,
      e no main não-wrapped): emitir `call void @GC_init()` como primeira instrução quando
      `prefer_gc_alloc`. Cobre `eiwac build` (binário linka `-lgc` via `emitNativeBinary:2865`).
- [ ] Validar manualmente: `./bin/eiwac build samples/<algo>.ei -o /tmp/t && /tmp/t`.

## Fase 6 — validação (ordem obrigatória)

- [ ] `zig build`
- [ ] `zig build test`
- [ ] `./bin/eiwac test --backend=llvm samples/tests` → **59/59** (foi 11 SIGABRT no experimento sem init)
- [ ] `./bin/eiwac test --backend=c samples/tests` → **59/59** (não pode mudar — backend C intocado)
- [ ] App `home` (arest): `eiwa run --backend=llvm` → servidor sobe; `curl` responde HTTP
      (nota: o blocker `writeByte`/Pointer do handoff §7.1 é gap separado — o objetivo aqui
      é o heisenbug de memória sumir e o comportamento estabilizar).
- [ ] Stress de coleta (opcional mas recomendado): sample que aloca muito em loop no JIT
      para forçar GC cycle e provar que os roots seguram singletons.

## Fase 7 — docs

- [ ] `docs/bloco-b-handoff.md`: marcar status resolvido/pacial com o que funcionou e o que falta.
- [ ] `docs/tasks-backend-parity.md`: marcar B1–B4 como resolvidos (quando validado).
- [ ] Este arquivo: checkboxes finais + notas de follow-up (special-cases C4/A10–A12 removíveis).

---

## Fora de escopo (não atacar neste bloco)

- Remoção dos special-cases hand-emitidos (C4 `emitSocketHelpers`, A10–A12, etc.) — só
  depois do Bloco B validado, e caso a caso (alguns também servem o build nativo).
- Bug `Socket.read`/`writeByte` (dispatch de método null-safe em `Pointer`, handoff §7.1)
  — gap independente que bloqueia o `home` servir HTTP.
- TODO do 128-byte fixo no construtor (`core.zig:2535`) — issue separada de tamanho real
  do struct (`LLVMStoreSizeOfType`).
- Registro de roots para o **build nativo** — binário nativo tem `.data`/`.bss` scaneados
  automaticamente pelo GC (diferente do JIT, cujos globals vivem em memória mmap do MCJIT).
