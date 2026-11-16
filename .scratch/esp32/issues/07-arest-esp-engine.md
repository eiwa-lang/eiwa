# 07: Motor client HTTP no arest

**What to build:** no repo do `arest`, um motor sobre o client HTTP do IDF implementando o mesmo contrato de engine, de modo que `arestClient { get/post }` tenha assinatura idêntica no host e no C3 (neste repo entra só o alvo; o motor vive lá).

**Blocked by:** 01 (Contratos antes dos motores).

**Status:** blocked — lives in the external `eiwa-lang/arest` repo (needs the `HttpEngine` ESP motor there); unblocked by 01's contract, nothing to do in this repo.

- [ ] Mesma assinatura de `get`/`post` nos dois alvos
- [ ] Erro de compilação claro se o motor não existir para o alvo
- [ ] Testes do `arest` no host seguem verdes
