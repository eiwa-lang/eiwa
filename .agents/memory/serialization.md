---
type: project
created: 2026-07-20
updated: 2026-07-20
---

# Serialization (JSON/YAML) — DESIGN APPROVED (2026-07-20)

## Decisions (Socratic Gate, 2026-07-20)
- Opt-in: type marca `: Serializable` (contract marker). Nada é serializável por default.
- Skills plugáveis: `+ Json` e/ou `+ Yaml` adicionam os métodos (`toJson()`, `toYaml()`).
  Reusa o mecanismo de composição da Phase 41 (skill clonada por type consumidor).
- Fase 1 = somente serialização. Desserialização (`fromJson`) é Fase 2 (precisa alocador,
  erros de parse, semântica de construção).
- Sem customização de campos na v1: nome e formato padrão. (rename/skip ficam para
  futura anotação tipo `@rename`.)
- Regra de campos: só serializa campos de tipos serializáveis (primitivos +
  types `: Serializable`, recursivo); demais campos são IGNORADOS silenciosamente.
- Sem reflexão estilo Java: metadados de campos emitidos em compile-time pelo
  compilador; corpo de `toJson`/`toYaml` gerado monomorfizado por type (dispatch
  estático). Nada de walk de tabela em runtime na v1.

## Open implementation questions (resolver na implementação)
- Contract marker vazio: verificar se o checker aceita `contract Serializable` sem métodos
  (o sample atual declara `fun serialize(): String`).
- Mecanismo de corpo gerado: provável anotação `@CompilerGenerated` na skill em std,
  ou codegen reconhecer as skills por nome qualificado (std.serde.Json).
- Onde mora: novo `src/std/serde.ei` (ou `json.ei`/`yaml.ei` separados).
- Coleções (Array/Map de serializáveis): escopo da v1 ou v1.5?

## Conventions lembradas
- Criar branch dedicada para mudanças grandes (default do projeto; user já dispensou uma vez).
- Verificação: `zig build`, `zig build test`, `eiwa test samples/tests` (88/88 baseline).
