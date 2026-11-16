# 02: Alvo esp32 emite objeto RV32

**What to build:** `eiwac build --target esp32` (alias `esp32-riscv`) aceita o novo alvo — baseline RISC-V 32-bit comum da família, sem PIC — e um exemplo mínimo compila até objeto; o link final pode falhar ainda — o verificável aqui é a emissão do objeto para o alvo. O chip é `IDF_TARGET` do projeto (default C3), não parte do nome.

**Blocked by:** None (can start immediately).

**Status:** ready-for-agent

- [ ] `--target esp32` e alias `esp32-riscv` reconhecidos com arquitetura RISC-V 32-bit
- [ ] Tabela de tamanho de `jmp_buf` cobre o alvo 32-bit do firmware
- [ ] Exemplo mínimo emite objeto sem erros de verificação do IR
