# 06: WiFi mais exemplo fim-a-fim

**What to build:** `Wifi.connect` bloqueia até obter IP (com retry, credenciais via configuração de build, nunca hardcoded) e o exemplo `blink_http` sobe o server após o IP, respondendo `/blink` que alterna o LED.

**Blocked by:** 05 (HTTP server sobre lwIP).

**Status:** done (bdad55c)

- [ ] Conexão só inicia o server após IP obtido; queda de WiFi não trava o firmware
- [ ] `GET /blink` alterna o LED e responde 200
- [ ] Credenciais fora do código-fonte
