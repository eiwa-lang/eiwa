# Plano — Phase 96: uniões anônimas (`A | B`) + descritores de identidade

## 0. Decisões fechadas

1. **Sem declaração:** `fromJson<UGoto | UCollect>(raw)`, `List<UGoto | UCollect>`,
   `MutableList<A | B | C>`, campos e params aceitam a tupla inline.
2. **Chave lowercase fixa, sem `@Alias`:** a chave é o lowercase do nome-fonte
   do tipo (`GotoStep` → `"gotostep"`). Inline não tem onde pendurar alias.
3. **Nominal ≠ estrutural, sem conversão:** `union Step` e `UGoto|UCollect` são
   tipos distintos mesmo com os mesmos membros; misturar é erro loud, nunca
   acordo silencioso de wire.
4. **Identidade por descritor, não por contrato:** global `{Type}_descriptor`
   por tipo (o endereço é a identidade); o fat da união vira `{data, &Descritor}`.
   `Serializable` segue exigido no declarado, mas só pelo serde (delegação).
   A identidade do declarado migra junto (testes verdes provam não-mudança).
5. **Escopo:** `type`s de referência em 96; `String` junto (sem box); escalares
   (`Int`/`Double`/`Bool`) na 97 (box na fronteira + unbox do follow-up 91.4).

## 1. Semântica alvo

```kotlin
val s = fromJson<UGoto | UCollect | UPaginate>(gotoJson())  // chaves agotostep-like por tipo
assert(s is UGoto)

val list: MutableList<UGoto | UCollect | UPaginate> = MutableList<UGoto | UCollect | UPaginate>()
list.add(UGoto("https://x/"))
val label = when (list.get(0)) {  // sem else: cobra os 3
  is UGoto -> "goto"
  is UCollect -> "collect"
  is UPaginate -> "paginate"
}
```

Erros: tag desconhecida/cardinalidade lançam como no declarado; membro
não-`Serializable`/primitivo (fora `String`) é `TypeError` posicionado;
conversão nomeada↔estrutural é `TypeError`.

## 2. Mudanças por camada

### 2.1 Abstração de lista de membros
Tudo que hoje lê `unions_ast` passa a resolver `unionMembers(typ)`:
declarado (`Custom` no registro) ou estrutural (componentes do `.Union`).
Aplica em: `conformsTo`, `isUnionNominal`, serde (`isSerdeUnion`,
`List`/`Map`/direto), `when`, `unionIdentityContract`.

### 2.2 Descritores (`{Type}_descriptor`)
- Novo global por tipo usado em união (lazy); só o endereço importa (v1).
- `coerceToUnion`: fat `{data, &Descritor}` em vez de vtable `Serializable`.
- `is`/`when`: comparam descritores; tripwire de thin mantido.
- Migrar a identidade do declarado (manter exigência `Serializable` p/ serde).
- Rebind estreitado e `as` operam sobre fat com descritor (inalterados na forma).

### 2.3 Checker
- `when` sem `else` sobre `.Union` estrutural cobra os componentes.
- Literais vazios anotados (`val l: MutableList<A | B> = ...`) via `.mut()`.
- `fromJson<A | B>` monomorfiza sobre `.Union` + sintetiza deserialize com
  chaves lowercase e mangling de membros ordenados (internar `A|B` ≣ `B|A`).

### 2.4 Emissor
- Lowering condicional: `.Union` só vira fat se todos os componentes forem
  customs (uniões abertas com primitivos seguem ptr, intocado).
- Generalizar os 6–8 pontos nominais para estrutural (args, returns, var-init,
  literais, `as`, `is`/`when`, slots de coleção).
- `String` como membro: sem box (já é heap); `is String` nominal no sujeito união.

## 3. Testes

` samples/tests/union_anonymous_xfail_test.ei` (5 REDs: decode, lowercase,
lista mutável + dispatch, round-trip, tag desconhecida) deve passar
integralmente na GREEN (XPASS força promoção). Negativas manuais: membro
`Int` rejeitado, mistura nomeada↔estrutural rejeitada, `==`/rótulos fora.

Verify: xfail promovido + suíte completa + `zig build test` + `eiwac build` smoke.

## 4. Fora de escopo (Phase 97: escalares)

`Int`/`Double`/`Bool` como membros: box na fronteira (célula heap, Phase 80),
`is` nominal por descritor, unbox no load estreitado (follow-up 91.4).
`String` entra já na 96.

## 5. Riscos

- **Duas identidades em trânsito:** declarado migra junto para não haver
  fat-`Serializable` e fat-descritor convivendo; suíte prova a migração.
- **Internação fraca:** `A|B` vs `B|A` geram codegen duplicado se o mangling
  não ordenar — ordenar antes de internar.
- **`==`/toString sobre valores anônimos:** semântica a definir na execução
  (identidade de ponteiro vs delegação); documentar a escolha no ADR.
