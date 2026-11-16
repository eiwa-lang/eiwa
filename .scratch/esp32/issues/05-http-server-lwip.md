# 05: HTTP server sobre lwIP

**What to build:** `Server.accept`/`readRequest`/`writeResponse` com a mesma API do host servem `GET /health` no firmware sobre lwIP, com tetos de memória (cabeçalho ~2KB, corpo ~8KB, `413` acima, sempre `Connection: close`).

**Blocked by:** 03 (Perfil freestanding linka no IDF), 04 (Scheduler cooperativo sobre FreeRTOS).

**Status:** ready-for-agent

- [ ] `GET /health` responde 200 com corpo correto
- [ ] POST acima do teto responde 413 e fecha a conexão
- [ ] Parsing/roteamento em Eiwa puro reutilizado sem modificação
