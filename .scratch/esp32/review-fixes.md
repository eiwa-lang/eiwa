# Review fixes — senior review of feat/esp32c3-engines (2026-11-16)

## Must (bloqueavam o "pronto")

- [x] M1: esp32 `PollLayout.poll` abortava — trocado por FFI real para o
      `poll()` do compat; `EspStub` deletado. Prova: link + loopback host.
- [x] M2: `getJmpBufWords` devolve 19 só no freestanding; resto 64.

## Should (foram juntos)

- [x] S3: sem código aqui; aceito e rastreado pelo 07 + compiler bug.
- [x] S4: guard `#ifndef CONFIG_EIWA_WIFI_*` no wifi_helpers.c.
- [x] S5: `.gitignore` para `eiwa_prog.o`, `build/`, `sdkconfig`,
      `size.json` do exemplo.
- [x] S6: comentário stale do `gpio.ei` corrigido.
- [x] S7: `build --target esp32` sem `-o` gera `.o`.

## Nice (foram juntos, menos um)

- [x] N8: newline final em `src/core/target.zig`.
- [x] N9: aviso de `--target` ignorado no teste por diretório.
- [ ] N10 (adiado): cache da imagem Docker no CI — não verificável
      aqui, ganho marginal; o job atual é correto, só lento.

## Comentários

Podados aos que impedem quebra: decisões de ABI/triple, limites de
RAM, armadilhas do link. `shortcut:` mantidos (são decisões).
