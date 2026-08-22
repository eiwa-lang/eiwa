# Plano: Monomorfização + Refatoração de `Task<T>` (Alinhar com [read roadmap](docs/roadmap.md) Ver Phase 50 e Phase 51)

> **⚠️ OBSOLETO (2026-08):** este plano levou o `Task<T>` ao modelo **neco (stackful)** da
> Phase 51. O neco foi **removido** — o modelo atual é **coroutines stackless** (Phase 68 /
> ADR 48 / `docs/tasks-coroutines-stackless.md`): `task {}`/`await()` viram state machines
> geradas pelo compilador + Scheduler em Eiwa puro. Mantido apenas como histórico.

## Etapa 2 — Refatoração de `Task<T>` (Remover Special Cases) (Phase 51)

### O que será removido

| Arquivo | Linha | O que faz |
|---------|-------|-----------|
| `infer_call.zig` | ~44 | Hardcoded `if name == "task"` |
| `infer_member.zig` | — | Hardcoded `.await()` resolution |
| `expression.zig` | ~373 | Hardcoded `task()` Geração de C |
| `expression.zig` | ~481 | Hardcoded `.await()` Geração de C |
| `core.zig` (backend) | ~55 | Hardcoded `if base_name == "Task"` em `cType` |

### Novo fluxo

```
eiwa task { 42 }
    │
    ├── task é fun task<T>(block: () -> T): Task<T> (genérica normal)
    │
    ├── Type checker monomorfiza: fun task<Int>(block: () -> Int): Task<Int>
    │   └── Corpo real em std/core.ei roda e retorna Task<Int>
    │
    ├── Transpiler: emite função task_Int normalmente
    │
    └── Task<Int> é type concreto monomorfizado
```

### Tasks

#### Task 51.1.1: Garantir que `fun task<T>` seja type-checkável
O corpo de `task<T>` em `std/core.ei` invoca o construtor de `Task<T>`:
```eiwa
fun task<T>(block: () -> T): Task<T> {
    return Task<T>.new(block)
}
```
Com monomorfização, `Task<Int>` vira struct concreta. O construtor `Task<Int>.new` chama libaco/neco para criar a co-rotina de verdade.

#### Task 51.1.2: Código da fibra vai pra `lib {}` (neco)
Em vez de gerar `({ })` inline no transpiler, o construtor de `Task<T>` chama `lib {}`:
```eiwa
lib Neco {
    fun neco_start(fn: OpaquePointer, argc: Int, ...): Int
    fun neco_suspend(): Int
    fun neco_resume(id: Int): Int
    fun neco_lastid(): Int
}
```
O construtor `Task<T>.new(block)` aloca a Task, cria co-rotina via `neco_start`, armazena o identificador retornado em `self.id`. A lambda `block` precisa ser convertida para ponteiro de função C via closure.
Arquivo: `src/std/core.ei` + runtime `src/runtime/third_party/neco/`

#### Task 51.1.3: Remover special case `task()` em `infer_call.zig:44`
Remover o bloco `if (std.mem.eql(u8, name, "task"))` especial do type-checking de chamadas.

#### Task 51.1.4: Remover special case `.await()` em `infer_member.zig`
Remover a lógica especial de resolução do método virtual/membro `.await()` no type checker de propriedades e métodos.

#### Task 51.1.5: Remover special case `Task` codegen em `expression.zig:373`
Remover o bloco que gera código C personalizado ao identificar chamadas a `task { ... }`.

#### Task 51.1.6: Remover special case `.await()` codegen em `expression.zig:481`
Remover a geração de código C sob demanda para `.await()` no CTranspiler.

#### Task 51.1.7: Remover special case `cType("Task")` em `core.zig:55`
Remover do backend C a conversão forçada de instâncias genéricas `Task` para `EiwaTask*`:
```zig
.GenericInstance => |gi| {
    if (std.mem.eql(u8, gi.base_name, "Task")) return "EiwaTask*";  // ← REMOVER
}
```
Cada `Task<T>` monomorfizada passará a gerar seu próprio tipo struct em C (ex: `Task_Int*`).

#### Task 51.1.8: Remover `src/runtime/fiber.c` e `src/runtime/fiber.h` (substituído por neco)
Deletar o runtime legado de fibras cooperativas em C baseado em `ucontext.h`/`makecontext`.

#### Verificação
- `eiwa test samples/tests/task_test.ei` — mesmos 8 testes passam
- Nenhum `grep "task" src/core/type_checker/infer_call.zig` além de nomes de variável
- Nenhum `grep "await" src/core/type_checker/infer_member.zig` como special case
- Nenhum bloco `base_name == "Task"` no transpiler

---

## Etapa 3 — Arquitetura Final: Contract + Skill + neco (Phase 51)

### Design final da linguagem

```eiwa
// ===== std/core.ei =====

// Contrato: qualquer coisa que pode ser aguardada
contract Awaitable<T> {
    fun await(): T
}

// Skill: exemplo de como implementar Awaitable usando neco, buscar documentação de como usar o neco em https://github.com/tidwall/neco
lib Neco {
    fun neco_start(fn: OpaquePointer, argc: Int, ...): Int
    fun neco_suspend(): Int
    fun neco_resume(id: Int): Int
    fun neco_lastid(): Int
}

skill TaskNeco : Awaitable<T> {
    implement fun await(): T {
        while (!this.done) {
            Neco.neco_resume(this.id)
        }
        return *this.resultPtr
    }
}

// Type concreto que compõe o skill o contrato e o type esta quase completo em (../samples/example.ei) so precisa bind com a lib Neco
```

### Tasks

#### Task 51.2.1: `lib {}` bindings de neco
Baixar neco em `src/runtime/third_party/neco/` (single-file: `neco.c` + `neco.h`):
- `neco.h` — header público
- `neco.c` — implementação completa (amalgamação, sem dependências)
Criar binding `lib Neco` em `src/std/core.ei` expondo as funções necessárias.

#### Task 51.2.2: `await()` via skill implementado
O método `await()` no skill `TaskNeco`:
1. Loop `while(!this.done)` chamando `Neco.neco_resume(this.id)`
2. Quando done, ler `this.resultPtr` e retornar valor tipado
Isso substitui os `({ })` blocks do transpiler atual.

#### Task 51.2.5: Remover runtime legado de compilação
Após neco + refatoração:
- `src/runtime/fiber.c` — deletar
- `src/runtime/fiber.h` — deletar
- `src/main.zig` — remover `src/runtime/fiber.c` dos args de compilação

#### Observações

- O metodo task {} deve começar a executar imediatamente assim como em (Kotlin async {} e lauch {}), await() deve apenas bloquear até o resultado estar pronto.
- Não deveria ser necessário codigos em zig que conheça neco, tudo deve ser gerenciado pelo eiwa
- Bindings C ficam em `<lib>/<lib>_wrapper.{h,c}` ao lado de cada lib vendorada, referenciados direto pelo `@Header` do bloco `lib`.
- Devemos tentar usar o minimo de zig e C possivel, tudo deve ser gerenciado pelo eiwa, nao pode haver grandes blocos de codigo em zig conhecendo as libs de eiwa, precisamos abstrair isso ao maximo.
- Tudo que foi feito para o task anteriormente deve ser desfeito.
- Devemos utilizar o sistema de tipos e contratos existente para implementar o task, nao devemos criar novas keywords ou sintaxes.

#### Verificação

- `eiwa test samples/tests/task_test.ei` — mesmos 8 testes passam
- `eiwa test` — suite completa passa (123+ testes)
- Nenhum código de runtime legado (grep por `fiber.c`, `fiber_entry`, `swapcontext`)
- Nenhum special case no compilador

---

## Estrutura de Diretórios Final

```
src/
├── runtime/
│   └── third_party/
│       └── neco/
│           ├── LICENSE
│           ├── neco.c
│           └── neco.h
├── std/
│   └── core.ei              ← Task<T>, Awaitable<T>, TaskNeco, task<T>
├── core/
│   ├── ast.zig               ← generic_params em contract/skill/fun/type
│   └── type_checker/
│       ├── infer_call.zig    ← sem special cases
│       ├── infer_member.zig  ← sem special cases
│       └── ...
└── backend/
    └── c_transpiler/
        ├── expression.zig    ← sem special cases
        ├── core.zig          ← sem special case Task
        └── ...
```

---

## Dependências Completas

```
[Phase 51: Refatoração de Task<T>]
Etapa 2 (Remover Special Cases) ──── necessário para Etapa 3
    │
    ▼
Etapa 3 (Contract + Skill + neco) ─── destino final
```

## Cronograma Estimado

| Fase | Etapa | Esforço | Complexidade |
|------|-------|---------|--------------|
| **Phase 51** | 1 — Contract + Skill + neco | 2-3 dias | Média |
| **Total** | | **2-3 dias** | |

## Checklist Final (100% do destino)

- [ ] `contract Awaitable<T>` com type param
- [ ] `skill TaskNeco : Awaitable<T>` com type param
- [ ] neco em `third_party/neco/` com binding `lib Neco`
- [ ] `Task<T>` usando `skill TaskNeco` + neco no runtime
- [ ] Nenhum special case `task`/`await` no compilador
- [ ] `fiber.c`/`fiber.h` removidos
- [ ] todos testes passando

---

## ✅ Resultado (executado — Phase 51 DONE)

Implementado com as seguintes divergências do plano original:

- **`skill TaskNeco` não criado:** skills não têm acesso verificado aos campos do `type`
  consumidor, então `await()` ficou no próprio `type Task<T>` (`std/core.ei`).
- **Campo único `id`** (fundido; sem `taskId`/`co_id`).
- **`lib Neco`** em `std/core.ei` com `@Alias` para wrappers C em
  `src/runtime/third_party/neco/neco_wrapper.c` (trampolim de closure `() -> Void`,
  macro `main` própria que roda o main do usuário dentro do runtime neco, e cola
  Boehm GC ↔ stacks de corotina: stacks ≥64KB do env allocator viram raízes do GC e
  o stackbottom é re-apontado a cada troca de corotina).
- **Patch `EIWA PATCH` em `neco.c`:** `stack_get_`/`stack_put_` usam o env allocator
  (upstream usava `malloc`/`free` crus, invisíveis ao tracking de stacks).
- **Fixes habilitadores no compilador:** sufixo por função nos nomes C de lambda/env
  (colisão entre instâncias monomorfizadas causava SEGV — ex: `task<Int>` + `task<String>`
  no mesmo programa); `T?` vira `Union(T, Null)` em `monomorphizeClass`; import de função
  genérica (`import { task }`) via `generic_functions_ast`; `Task<Void>` suportado via erasure de Void no
  backend C (campo/param `int` dummy em `cStorageType`, store de valor Void apagado,
  `return <void>` vira `return;`).
- **Verificação:** `zig build test` ✅, `./zig-out/bin/eiwa test` 132 PASS / 0 FAIL ✅,
  `task_test.ei` 9/9 ✅, grep zero de special cases (`task`, `await`, `EiwaTask`, `fiber`)
  no checker/transpiler ✅.
