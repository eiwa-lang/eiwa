# 01: Contratos antes dos motores (prefactor)

**What to build:** todo binding de syscall passa a existir atrás de um contrato com implementação por alvo, sem mudar nenhum comportamento no host: o cliente HTTP direto vira um backend atrás do contrato de engine, e nenhum binding com syscall fica sem tag de alvo.

**Blocked by:** None (can start immediately).

**Status:** done (0f328ee)

- [ ] Todo `lib` que toca syscall tem tag de alvo ou contrato correspondente; build host inalterado
- [ ] Cliente HTTP funciona via contrato de engine com o motor atual como default
- [ ] Suíte `eiwac test` host segue verde
