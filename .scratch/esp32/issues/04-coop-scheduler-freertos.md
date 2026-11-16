# 04: Scheduler cooperativo sobre FreeRTOS

**What to build:** `task`/`await`/`sleepMs`/`yield` funcionam no firmware com a mesma sintaxe do host, sobre uma única task do RTOS com scheduler cooperativo — sem thread por conexão e sem stacks de megabytes.

**Blocked by:** 03 (Perfil freestanding linka no IDF).

**Status:** ready-for-agent

- [ ] Duas tasks cooperativas alternam e piscam LED com tempos corretos
- [ ] Espera usa primitives do RTOS (sem busy-loop)
- [ ] Sintaxe do usuário idêntica à do host
