# 09: HIL com placa física (após CI verde)

**What to build:** APÓS todos os tickets anteriores concluídos e o CI passando, runner dedicado com C3 real que grava o firmware e valida via rede: `GET /health`, `GET /blink` e `413` em POST grande.

**Blocked by:** 06 (WiFi mais exemplo fim-a-fim), 08 (CI com gate de build e tamanho).

**Status:** ready-for-agent

- [ ] Todos os tickets 01–08 concluídos e CI verde antes de iniciar
- [ ] Runner com placa física valida os três cenários via rede real
- [ ] Concorrência serializada (uma placa, um job por vez)
