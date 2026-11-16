# 08: CI com gate de build e tamanho

**What to build:** job novo no CI em container `espressif/idf` que compila o exemplo fim-a-fim e falha se o firmware estourar os tetos de flash/RAM; a suíte host continua como guardiã da sintaxe.

**Blocked by:** 06 (WiFi mais exemplo fim-a-fim).

**Status:** ready-for-agent

- [ ] Job compila o firmware-exemplo do zero no CI
- [ ] Gate de `size` com tetos de flash/RAM falha o PR se estourar
- [ ] QEMU dispensado (sem rádio WiFi); documentado o porquê
