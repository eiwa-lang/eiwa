# Spec: Suporte ESP32 (membros RISC-V) com motores trocáveis

> Status: Proposta (branch `feat/esp32c3-engines`)
> Complementa o plano aprovado de cross-compilation e abstração de plataforma: esta spec é a instanciação para alvos freestanding/ESP-IDF, com HTTP server no C3 como primeiro caso concreto.
> Label sugerida no tracker: `ready-for-agent`.
> Nome do alvo: `--target esp32` (canônico), alias `esp32-riscv`. Chip via `IDF_TARGET` (default C3). Xtensa (S3/clássico/S2) fora de escopo.

## Problem Statement

Quero compilar programas Eiwa para o ESP32 (membros RISC-V: C3, e pelo baseline comum C6/H2) e subir um HTTP server nele, sem que o programador mude a forma de programar: o mesmo código que roda no host deve rodar no chip. Hoje isso é impossível porque o backend assume ambiente hosted 64-bit (libc completa, Boehm GC, pthreads com stacks de 8MB, `libcurl`, `poll`, `exit`), e o C3 é um RV32IMC single-core com ~400KB SRAM, sem OS, com toolchain ESP-IDF + FreeRTOS + lwIP.

## Solution

Introduzir o alvo `--target esp32` (alias `esp32-riscv`) sobre dois níveis: perfil `freestanding` (sem OS) + motores ESP-IDF (WiFi/NVS, lwIP, timer, UART). O chip é parâmetro do projeto IDF (`IDF_TARGET`, default C3), não do nome do alvo — o codegen usa o baseline RV32 comum, que roda em todos os RISC-V da família. Tudo que toca o OS segue o padrão **contrato estável + motor por alvo** (o mesmo padrão que os motores de poll e threading já usam): a sintaxe e as APIs que o programador vê (`Server`, `Socket`, `print`, `task`/`await`, `arest`, `Client`) ficam byte-idênticas; só os motores mudam conforme `--target`. Primeiro caso concreto validado: C3 com HTTP puro sobre lwIP, sem TLS.

## User Stories

1. Como programador Eiwa, quero compilar o mesmo `blink_http.ei` para host e para ESP32 sem editar o código, para não manter dois fontes.
2. Como programador Eiwa, quero usar `Server`/`accept`/`readRequest`/`writeResponse` no ESP32 igual ao host, para reaproveitar o que já sei.
3. Como programador Eiwa, quero usar a DSL `arest` (routing `get`/`post`, `respond`, `receive`) no ESP32, para não reescrever rotas em baixo nível.
4. Como programador Eiwa, quero `Client.get/post` com a mesma assinatura no ESP32 (motor lwIP em vez de curl), para chamar APIs externas.
5. Como programador Eiwa, quero `print`/`println` funcionando no ESP32 (saída UART), para debugar via monitor serial.
6. Como programador Eiwa, quero `Wifi.connect(ssid, pass)` bloqueando até obter IP, com credenciais fora do código, para ligar o server após a rede subir.
7. Como programador Eiwa, quero `sleepMs`/`task`/`await` com a mesma semântica no ESP32 (cooperativo single-thread), para não reestruturar concorrência.
8. Como mantenedor da stdlib, quero que todo binding de syscall seja `contract` + implementação por alvo, para que um alvo novo seja só motores novos.
9. Como mantenedor do compilador, quero `eiwac build --target esp32` gerando artefato linkável pelo ESP-IDF, para o flash continuar via `idf.py`.
10. Como mantenedor do CI, quero um job que prove que o firmware ESP32 compila e cabe na flash/RAM a cada PR, para não regredir silenciosamente.
11. Como mantenedor do CI, quero o `eiwac test` host continuando como guardião da sintaxe, já que o programa-usuário é idêntico nos dois alvos.
12. Como operador do lab, quero um teste com hardware real (C3) que bata `GET /health` e valide `413` em POST grande, para validar WiFi/lwIP de verdade.
13. Como programador Eiwa, quero erro de compilação claro quando uma API não tem motor para o alvo (ex. client TLS no ESP32), em vez de falha no link.
14. Como usuário de Mac, quero compilar o `eiwac` e cruzar para `esp32` no macOS, para não depender de Linux.

## Implementation Decisions

- **Alvo único `esp32` (alias `esp32-riscv`)**: perfil `freestanding` (sem OS: sem GC, sem threads OS, entrada `app_main`, sem `exit`) + motores ESP-IDF (WiFi/NVS, lwIP, timer, UART). O chip é `IDF_TARGET` do projeto (default C3); C6/H2 são cobertos pelo baseline RV32 comum sem alvo novo. Xtensa fica explicitamente fora de escopo.
- **Seam única e preferencial**: o seletor de plataforma que já filtra `lib`/`object` por alvo. Nenhum binding com syscall vive sem tag de alvo; todo binding ganha `contract` + `object` por alvo, seguindo o precedente dos motores de poll e threading.
- **Memória**: no perfil `freestanding` o alocador padrão deixa de ser o GC coletor e passa a ser o heap do firmware; nada de ctor de GC nem registro de threads do coletor. O tipo inteiro de 64-bit é mantido nesta fase (custo de soft-float/libcall aceito).
- **Concorrência**: no ESP, um único scheduler cooperativo sobre uma task FreeRTOS; operações de espera viram primitives do RTOS e multiplexação de I/O. Sem thread por conexão e sem stacks de megabytes.
- **Transporte HTTP**: reimplementar o mesmo conjunto de primitivas de socket sobre lwIP, mantendo os tipos `Socket`/`TCPServer` e todo o parsing/resposta HTTP em Eiwa puro, intocados. Limites fixos (cabeçalho ~2KB, corpo ~8KB, `413` + close acima, sempre `Connection: close`).
- **Cliente HTTP**: novo motor sobre o client HTTP do IDF implementando o mesmo contrato de engine do `arest` (que já prevê `CurlEngine`/`MockEngine`); o motor ESP vive no repo do `arest`, aqui entra só o alvo.
- **TLS fora desta fase**: somente HTTP; HTTPS via mbedTLS fica para fase 2.
- **WiFi**: `connect` bloqueante até IP com retry, credenciais via configuração de build (não hardcoded); sem portal captive nesta fase. Sem roteador novo: roteamento manual/`arest` existente.
- **Entrada/saída**: `print` vira UART, relógio vira timer do IDF, `try/catch` sobre o mecanismo nativo do firmware (perfil sem exceção avaliado se estourar pilha).
- **Build**: `eiwac build --target esp32` emite objeto + pasta de componente IDF com `sdkconfig` default (chip via `IDF_TARGET`); flash/monitor via `idf.py` (CLI oficial do ESP-IDF: configura toolchain, compila, grava com `esptool`, abre serial).
- **CI**: job novo em container `espressif/idf` que compila o firmware-exemplo e publica `size` com tetos de flash/RAM como gate; QEMU dispensado (não emula WiFi); hardware-in-the-loop com placa física fica para fase com runner dedicado.

## Testing Decisions

- Bom teste aqui testa comportamento externo do firmware (resposta HTTP, código de status, uso de flash/RAM), não detalhes de codegen.
- Módulos testados: motores ESP (socket lwIP, scheduler cooperativo, WiFi connect) via firmware-exemplo compilado + gate de tamanho; sintaxe e semântica continuam cobertas pela suíte `eiwac test` existente no host.
- Prior art: a suíte nativa paralela por arquivo e os probes de crash/exceção do `ci.yml`; o job ESP segue o mesmo formato (build → teste → gate), só que com `idf.py build/size` no lugar de execução host.

## Out of Scope

TLS/HTTPS no ESP32; Xtensa (S3/clássico/S2) — alvo separado futuro, nada nesta spec; portal WiFi/captive; roteador HTTP novo; QEMU com rede; tipo inteiro de 32-bit; dynamic dispatch/JIT no alvo (só AOT); flash automático pelo `eiwac` (continua via `idf.py`).

## Further Notes

- Glossário resolvido na sessão: **Motor** (implementação por alvo atrás de um contrato), **Alvo** (canônico `esp32`, alias `esp32-riscv`; chip via `IDF_TARGET`), **Perfil freestanding** (sem OS/GC/threads). Candidato a ADR quando a fronteira de decisão esvaziar.
- Premissa verificada no repo: o `Dockerfile` e o `ci.yml` atuais não têm nada de ESP-IDF/RISC-V — o job ESP é trabalho novo, não reuso.
- Precedentes de nomenclatura: Rust usa triples por chip (`riscv32imc-esp-espidf` no C3, `riscv32imac-esp-espidf` no C6 — código `imc` roda no C6 por extensão aditiva); TinyGo e ESP-IDF nomeiam por chip; MicroPython/Arduino chamam a porta de `esp32` para a família. Nossa escolha (`esp32` + chip no `IDF_TARGET`) segue o modelo família+variante do PlatformIO.
