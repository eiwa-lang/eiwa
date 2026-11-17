# 03: Perfil freestanding linka no IDF

**What to build:** um firmware-exemplo (pisca LED + log via serial) linka com o build do ESP-IDF sem coletor de lixo, sem threads do OS e sem client HTTP nativo; o relay do tamanho do firmware é publicado.

**Blocked by:** 01 (Contratos antes dos motores), 02 (Alvo esp32 emite objeto RV32).

**Status:** done (c5ac8bb)

- [ ] Link sem `-lgc`, sem pthreads, sem curl; alocador padrão usa o heap do firmware
- [ ] Entrada via `app_main`, saída de texto via serial
- [ ] `idf.py build` passa e `size` do firmware é publicado
