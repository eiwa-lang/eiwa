# Plano — Phase 95: `union` fechada com dispatch serde (estilo `enum`)

## 0. Decisões fechadas

1. **Sintaxe bloco estilo `enum` (sem `=`, sem `|`, sem `closed`):**
   ```kotlin
   type Goto(val url: String, val waitUntil: String, val timeoutMs: Int) : Serializable
   type Collect(val selector: String, val fields: Map<String, FieldDef>) : Serializable
   type Paginate(val selector: String, val maxPages: Int) : Serializable

   union Step {
     Goto, Collect, Paginate
   }
   ```
2. **Wire externamente taggeado, 1 chave:** `{"goto": {...}}`. A chave é o discriminador; o valor é o payload. Sem `kind`, sem sondagem estrutural interna (resolve a colisão `selector` entre `Collect`/`Paginate`).
3. **Chave via `@Alias` reutilizado (sem `@Tag`):** sem alias, chave = nome lowercased (`Goto` → `"goto"`); com `@Alias("goto")`, vale o alias. Mesma semântica "nome Eiwa ↔ nome externo" da ADR 62.
   ```kotlin
   union Step {
     @Alias("goto") Goto,
     Collect,
     Paginate
   }
   ```
4. **Serde-agnóstico, camada `SerdeValue`:** `Step.serialize()` retorna `SerdeObject([SerdeField(chave, inner.serialize())])`; `Step.deserialize(v)` opera sobre `SerdeValue`. `Json`/`Yaml` herdam sem mudança (precedente ADR 62, `serdeWireName`).
5. **Fechado, sem novo layout LLVM v1:** `union` baixa para o maquinário atual de `contract` (fat pointer + vtable, `docs/architecture.md:68`). Ganho é estático: lista fechada no checker para dispatch + exaustividade. `contract` puro foi rejeitado (aberto, sem dispatch gerado, `List<Contract>` é o gap da Phase 43).
6. **Erros fail-fast, contrato L2/L3:** objeto com 0/2+ chaves → `throw Exception` com esperado `goto|collect|paginate` + recebido; tag desconhecida → throw com a tag; campo interno faltando → recursão na regra atual (`Missing required field ...`, `src/core/type_checker/infer_decl.zig:1644-1679`); nunca `null` silencioso.
7. **Exemplo canônico (quotes):**
   ```json
   {
     "name": "quotes",
     "steps": [
       {"goto": {"url": "https://quotes.toscrape.com/", "waitUntil": "load", "timeoutMs": 15000}},
       {"collect": {"selector": "div.quote", "fields": {"text": {"selector": "span.text"}}}},
       {"paginate": {"selector": "li.next a", "maxPages": 100}}
     ],
     "required": ["text", "author"]
   }
   ```
   Nota: `fields` é `Map<String, FieldDef>`, não `List` (ramo `Map` do deserialize já existe). `FieldDef(val selector: String, val many: Bool = false, val attr: String = "")`.

## 1. Semântica alvo

```kotlin
val s: Step = Goto("https://x/", "load", 15000)  // variante atribui à união
val json = serializeJson(s)                       // {"goto": {...}} — só campos da variante
val back: Step = fromJson<Step>(json)             // dispatch pela chave

val label = when (s) {                            // sem else: cobra as 3
  is Goto -> "goto:" + s.url                      // smartcast como contract
  is Collect -> "collect:" + s.selector
  is Paginate -> "paginate:" + s.maxPages.toString()
}

val pipe = fromJson<Pipeline>(raw)                // List<Step> via Step.deserialize
```

Erros:

```kotlin
fromJson<Step>("{}")                    // throw: esperava 1 de goto|collect|paginate, got 0
fromJson<Step>("{\"a\":{},\"b\":{}}")   // throw: 2 chaves
fromJson<Step>("{\"fly\":{}}")          // throw: unknown variant 'fly'
fromJson<Step>("{\"goto\":{}}")         // throw: Missing required field 'url' for type 'Goto'
when (s) { is Goto -> 1 }               // TypeError posicionado: missing Collect, Paginate
```

## 2. Mudanças por camada

### 2.1 Lexer/Parser/AST
- `kw_union` + `union_decl { name, members: [{name, alias?}] }` em `src/core/ast.zig` (espelho de `enum_decl:261`).
- Parser: `union Name { [@Alias(..)] Member, ... }`, vírgula final opcional. Membros são referências a `type`s (não definição inline).
- Erros posicionados: bloco vazio, membro duplicado, membro desconhecido/não-`type`, `@Alias` duplicado no bloco.

### 2.2 Checker
- Registro da união + lista fechada de membros; cada membro deve ser `type` (genéricos: rejeitar v1, como `generateSerdeDeserialize` já faz).
- Compatibilidade: variante → união ok (`val s: Step = Goto(...)`); união → variante só via `is`/`as` com smartcast (caminho de `infer_when.zig:65-77`, estendido para membros da união).
- `is`/`as` contra membro funciona sobre valor de tipo união; `when is` estreita como contract.
- Exaustividade: `when` sobre união em posição-valor sem `else` exige um branch `is` por membro; faltantes → `TypeError` posicionado no `when` listando os ausentes. Com `else`, regra atual vale. Statement continua sem exigir.
- `union` não instancia (`Step(...)` é erro), não tem métodos próprios v1, não entra em `:`/`+` como membro.

### 2.3 Serde codegen (mesmo lugar do deserialize atual, `infer_decl.zig:3020`)
- `serialize`: `SerdeObject([SerdeField(wireKey, inner.serialize())])` — só campos da variante.
- `deserialize(value: SerdeValue): Step`:
  1. `obj = asSerdeObject(value)`; `size != 1` → throw com esperado + recebido;
  2. `match fields[0].name` por chave wire (`@Alias` ou lowercased); desconhecida → throw com a tag;
  3. delega a `Variante.deserialize(inner)` (recursão L2/L3 cobre `Map<String, FieldDef>`, defaults, nullables).
- `List<Step>` funciona via `deserializeList` + `Step.deserialize`, sem tocar Phase 43.

### 2.4 Emissor LLVM
- Sem novo struct v1: valor de tipo união usa o caminho de `contract` (void* + descriptor/vtable). Construção é construção da variante + coerção variante→união no mesmo caminho de upcast existente.
- `when is` sobre união usa o caminho de `is`/smartcast existente.

## 3. Testes (TDD: RED depois GREEN)

Novo `samples/tests/union_serde_test.ei` (~10 testes, fixture quotes acima):
1. decode de cada variante com valores (`goto`/`collect`/`paginate`).
2. tag desconhecida lança com detalhe (`fly` no `message()`).
3. 0 chaves e 2 chaves lançam (cardinalidade).
4. campo interno faltando lança recursivo (`{"goto": {}}` → `url`).
5. round-trip `toJson→fromJson` por variante + `Pipeline` com `List<Step>` (só campos da variante no JSON).
6. `@Alias` customiza a chave nos dois sentidos.
7. `when` exaustivo compila; não-exaustivo falha (negativa manual, erro posicionado).
8. YAML: `toYaml`/`fromYaml` do mesmo `Pipeline` (agnóstico a formato).

Verify: novo arquivo verde + suíte completa + `zig build test`, sem regressão em `serde_*_test` / `enum_test` / `when_sample`.

## 4. Docs

- `docs/language_tour.md` §11 (novo `union`, wire, `@Alias` na chave, `when` exaustivo) + §21.5 (remissão).
- `docs/roadmap.md` Phase 95: checklist + verify.
- `docs/decisions.md`: ADR (externamente taggeado, `@Alias` reutilizado, serde-agnóstico, fechado sem novo layout).

## 5. Fora de escopo (follow-ups)

- Variantes inline com payload no bloco (`union Step { Goto(url: String) }`).
- Variantes unitárias sem payload / genéricas (`union Opt<T>`).
- `union` em `:`/`+`, métodos no bloco `union`, `values()`/`byName` estilo enum.
- Layout LLVM dedicado (struct tag+payload max-size) e otimização de boxing.
- Migração do formato flat atual (`kind: String`); opt-in por tipo.

## 6. Riscos

- **`:` vs membros:** bloco evita a colisão com `:` de contracts, mas o parser deve distinguir `union` de `type`/`enum` em todos os passes (decl, assinatura, corpo).
- **Default lowercased:** `Goto` → `goto` é convenção nova; colisão de duas variantes que lowercasem igual deve ser `TypeError` de registro.
- **`when` com `else` mascara falta:** por construção (wildcard), documentar no tour.
- **`Map<String, FieldDef>` com defaults:** `{"selector": "x"}` ancora `many=false`; explicitar no teste para não confundir com "chave ausente lança".
