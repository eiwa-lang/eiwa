# Architectural Decision Records (ADRs)

Este documento registra as decisões arquiteturais estruturais tomadas durante o desenvolvimento do compilador Eiwa.

## ADR 01: C Transpiler Backend para Desenvolvimento (`run`)
**Data:** Fase 02
**Contexto:** Precisávamos de uma forma rápida de iterar e testar código Eiwa sem a complexidade de compilar LLVM IR em tempo de desenvolvimento.
**Decisão:** O comando `eiwa run` atua como um Transpilador puro, gerando código C intermediário e invocando `zig cc -O0`.
**Razão:** O C age como uma "Assembly de alto nível". É incrivelmente portável, extremamente otimizado e drásticamente mais fácil de debugar. Isso garante compilações sub-segundo no ciclo de feedback do dev.

## ADR 02: Operator Overloading via Modifiers
**Data:** Fase 11 e 12
**Contexto:** Queríamos permitir a sobrecarga de operadores matemáticos (`+`, `-`) em classes personalizadas (ex: `Vector`).
**Decisão:** O Eiwa adota uma abordagem estrita baseada em Kotlin. Para sobrecarregar um operador, o método deve ter um nome de contrato exato (ex: `plus`) e **obrigatoriamente** possuir o modificador `operator`.
**Razão:** Evita sobrecargas acidentais de funções comuns chamadas "plus". Traz clareza semântica: ao ler a classe, você sabe imediatamente que aquela função altera o comportamento matemático da linguagem.

## ADR 03: Null Safety as Compile-Time Union Types
**Data:** Fase 13
**Contexto:** C (o nosso alvo de transpilação) é notório por Segmentation Faults causados por ponteiros nulos. Precisávamos de um mecanismo para blindar isso.
**Decisão:** Implementar *Null Safety* rigoroso no TypeChecker. Tipos com `?` (ex: `String?`) são internamente tratados como *Union Types* (`.String | .Null`). O compilador bloqueia *hard* o acesso de propriedades ou métodos nesses tipos, exigindo o uso de operadores seguros (`?.`, `?:` ou `!!`).
**Razão:** Prevenção total de SegFaults por Null Pointers. O Transpilador emite macros ternárias em C que verificam a nulidade antes do acesso, garantindo a segurança de memória em tempo de execução ditada estaticamente.

## ADR 04: Memory Management via Boehm GC
**Data:** Fase 14 (Aprovado, Implementação Pendente)
**Contexto:** O Eiwa gera código C que usa `malloc` extensivamente para construir strings nativas e instanciar classes. No entanto, não geramos chamadas `free()`, causando vazamentos crônicos de memória (*Memory Leaks*).
**Decisão:** Em vez de poluir o código C final com milhares de rotinas de *Reference Counting* injetadas pelo TypeChecker, adotaremos a integração com o **Boehm-Demers-Weiser Conservative Garbage Collector** (Mesma arquitetura do compilador Crystal).
**Razão:** Máximo pragmatismo. Apenas trocamos `malloc` por `GC_MALLOC` no emissor C e linkamos a biblioteca `-lgc`. O coletor de lixo atua perfeitamente em background com impacto estrutural quase zero na arquitetura do nosso AST/TypeChecker.

## ADR 05: LLVM Native Emitter para Produção (`build --release`)
**Data:** Concepção Original da Spec
**Contexto:** Enquanto o C Transpiler é rápido para desenvolver, precisamos de otimizações de ponta para binários de produção sem a sobrecarga de macros pesadas ou dependências externas difíceis de controlar.
**Decisão:** O comando `eiwa build --release` desviará do backend C e invocará um emissor focado em **LLVM IR**. Usaremos as APIs/Bindings do LLVM direto no Zig para traduzir a AST Resolvida para IR e deixar o LLVM otimizá-lo.
**Razão:** LLVM garante performance de estado da arte (comparável a C/C++ ou Rust). Uma linguagem moderna orientada a performance necessita dessa via direta para gerar binários monolíticos ultrarrápidos para servidores.

## ADR 06: File-based Namespaces e Native Test System
**Data:** Fase 16 e 21
**Contexto:** Queríamos evitar a complexidade do ecossistema de bibliotecas de teste (como JUnit ou vitest) e manter a filosofia minimalista e pragmática do Eiwa.
**Decisão:** Criar uma suite de testes de primeira classe nativa (`eiwa test`), aliada a um sistema de importação baseado puramente em arquivos (ES6/Go style). O compilador condensa testes dinamicamente da árvore de arquivos e resolve o name mangling dos módulos C para evitar colisões entre as suítes, abstraindo e ignorando automaticamente as funções `main` de desenvolvimento da compilação de testes. As extensões `.ei` nos imports se tornam opcionais.
**Razão:** Máxima fluidez para o desenvolvedor. Testes integrados desde a linguagem base elevam a qualidade do código criado no ecossistema Eiwa sem nenhum tipo de boilerplate ou configuração de build necessária.

## ADR 07: Top-Level Statements (Fim da obrigatoriedade do `main`)
**Data:** Fase 22
**Contexto:** O Eiwa utilizava `fun main()` obrigatoriamente como ponto de entrada por herança estrita do C. Contudo, isso gerava um *boilerplate* indesejado para o desenvolvedor durante a criação de scripts rápidos ou arquivos leves, indo contra a filosofia dinâmica do comando `eiwa run`.
**Decisão:** Adotar a **Abordagem Híbrida** para a inicialização do programa (semelhante ao C# 9+). O desenvolvedor não precisa mais de `fun main()`. Instruções soltas (ex: `print("Hello")`) escritas na raiz do arquivo compilado serão agrupadas silenciosamente pelo compilador e injetadas dentro do `main` nativo em C. Se o desenvolvedor optar por criar um `fun main()` explicitamente, o compilador o respeitará. Argumentos de CLI e saídas de erro serão tratados com uma variável global injetada `args` e uma função de sistema `exit(code)`.
**Razão:** Entrega o melhor dos dois mundos. Scripting ultrarrápido com poucas linhas para ferramentas simples, e o padrão estrutural coeso e robusto do `main` tradicional para aplicações grandes e complexas em produção.

## ADR 08: Interoperabilidade Nativa C e C-Macros via Tipo `Unknown`
**Data:** Fase 17
**Contexto:** Ao construir a linguagem Eiwa (focada em extrema performance e baixo nível), integrá-la sem atritos ao ecossistema C é essencial. Além disso, as funções intrínsecas (como `print`) estavam engessadas diretamente no TypeChecker do compilador. Precisávamos da fundação para a primeira "Standard Library" (`core.ei`).
**Decisão:** Introduzir o bloco `lib` para declarar *bindings* de C, combinado com **Anotações Estruturais** (`@Header`) consumidas pelo CTranspiler para ejetar as diretivas `#include`. Para manter a flexibilidade de C macros (como a nossa macro C interna `_Generic` do `print`, que aceita Int, String, Bool), implementamos um tipo mágico `Unknown` em Eiwa que burla temporariamente o TypeChecker para aqueles parâmetros específicos. (Nota: Substituído parcialmente pelo ADR 09).
**Razão:** Remove a complexidade do compilador, isola as definições base da linguagem em código "user-space" (o arquivo `core.ei` usa `lib System` para injetar `print`), e permite que a própria Stdlib do Eiwa usufrua de ponteiros C diretos no transpilador com total zero-overhead. Planejamos no futuro evoluir as anotações para o nível de linguagem estrita (Fase 24), mas esta base estrutural garante entregas de produto rápidas na iteração atual.

## ADR 09: Function Overloading e Implicit Standard Library
**Data:** Fase 23
**Contexto:** O uso da macro `_Generic` em C e o tipo mágico `Unknown` eram gambiarras arquiteturais instáveis e difíceis de manter. Além disso, os desenvolvedores precisavam importar explicitamente funções essenciais (ex: `import { print } from "system"`) em todos os arquivos.
**Decisão:** 
1. Implementar **Function Overloading** nativo no TypeChecker, permitindo múltiplas assinaturas para a mesma função (ex: `print(String)`, `print(Int)`), com **Name Mangling** dinâmico (ex: `system_print_String`) na emissão C para evitar colisões. O tipo `Unknown` perde sua obrigatoriedade como muleta arquitetural.
2. Implementar **Wildcard Imports** (`import *`) na camada semântica e injetar uma importação implícita (`import {} from "system"`) no início de todo arquivo compilado.
**Razão:** Traz robustez absurda para o sistema de tipos (verificando os tipos de funções no *compile-time* em vez de falhar no GCC) e melhora massivamente a ergonomia (*Developer Experience*) ao fornecer as APIs de sistema automaticamente de forma transparente.

## ADR 10: Arrays Nativos Estritamente Imutáveis
**Data:** Fase 24 (Início)
**Contexto:** Ao desenhar o suporte nativo para arrays dinâmicos (`[Type]`), questionamos se o Eiwa deveria permitir métodos de mutação (ex: `.push()`, `.pop()`) vinculados a `val`/`var` (Estilo Rust/Swift) ou criar tipos explícitos distintos (Estilo Kotlin).
**Decisão:** O tipo nativo `[Type]` é **estritamente imutável** do ponto de vista do TypeChecker do Eiwa e atua puramente como um "Syntactic Sugar" para `List<Type>`. Modificações requerem estruturas de dados explícitas separadas no futuro (ex: `MutableList<Type>`).
**Razão:** Máxima aderência à filosofia de segurança de tipos do Kotlin. Garante previsibilidade (um array recebido por função nunca terá seu tamanho/dados alterados acidentalmente). Embora internamente o C Transpiler gere *structs* C dinâmicos capazes de crescer, o compilador restringe essa capacidade estaticamente no nível da linguagem.

## ADR 11: Standard Library Packages e Epoch-First Time API
**Data:** Fase 26
**Contexto:** O arquivo `system.ei` estava crescendo descontroladamente, agindo como um monólito ("God File"). Além disso, precisávamos adicionar suporte a manipulação de Datas/Tempos, uma área historicamente propensa a bugs (timezones, daylight savings) em linguagens antigas.
**Decisão:** 
1. **Pacotes Virtuais:** O TypeChecker agora intercepta pacotes que começam com `std.` (ex: `std.time`) e roteia a busca diretamente para a pasta interna `std/` do compilador, ao invés de usar caminhos relativos ao projeto do usuário. O antigo `system.ei` se tornou `std.core` (`std/core.ei`).
2. **Epoch-First Time API:** Escolhemos o modelo do **Go** para a classe `Time`. Ela possui apenas uma propriedade (`val sec: Int`) que guarda os segundos absolutos (Unix Epoch `time_t`). Operações matemáticas (como somar horas usando a classe `Duration`) são processadas como somas de inteiros ultra-rápidas. Formatações e consultas baseadas em fuso horário (ex: Extrair Ano, Mês, Dia) são delegadas ao `<time.h>` no frontend C através do novo bloco nativo `lib NativeTime`. 
**Razão:** A quebra em pacotes `std.*` oficializa a Standard Library modular, blindando a SDK do Eiwa. A arquitetura Epoch-First garante que não haverão bugs de Fuso Horário na memória central das aplicações, aliada a uma performance monstruosa na CPU para matemática de tempo (apenas somas de bits) essencial para desenvolvimento de alto rendimento.

## ADR 12: Single-Pass Type Inference via Early Returns
**Data:** Refinamento Fase 26 / Bugfixes (Julho 2026)
**Contexto:** Ao suportar a inferência de blocos complexos, retornos condicionais e construtores nativos, o compilador enfrentou um bug grave: nós isolados (como *string literals*) passavam pela esteira do `TypeChecker` múltiplas vezes em avaliações de blocos sobrepostos. Isso causava mutações recursivas na AST gerando código corrompido no backend C, como `core_String_new(core_String_new(...))`, culminando em *Segmentation Faults*.
**Decisão:** O núcleo do `TypeChecker` (`core_inferNode`) implementa uma blindagem de **Early Return**. Qualquer nó da AST que já possua o `resolved_type` preenchido por uma visita anterior é devolvido imediatamente, prevenindo a re-varredura.
**Razão:** Elimina mutações duplas acidentais nos nós da AST e melhora radicalmente a estabilidade e performance do compilador, assegurando que o TypeChecker atue estruturalmente como um varredor O(N) (*Single-Pass*) puro na árvore.

## ADR 13: C-Style Prefix Unary Operators Integration
**Data:** Fase 27
**Contexto:** O compilador precisava de suporte nativo a operadores unários lógicos (`!condicao`) e matemáticos (`-10`). O desafio era gerir corretamente a ordem matemática sem conflitar com operadores de segurança *postfix*, como a asserção non-null (`!!`).
**Decisão:** A leitura dos unários (`unary()`) foi inserida estritamente na árvore do *Recursive Descent Parser* após `factor()` (* /) e antes de `call()`. Os tokens `.bang` (`!`) e `.minus` (`-`) foram modelados com suporte a empilhamento de múltiplas *Unary Expressions*.
**Razão:** Seguir a especificação sólida das linguagens da família C (Kotlin, Swift), permitindo o agrupamento seguro dessas expressões na emissão final (ex: gerando `!(cond)` no transpiler) e tipagem granular independente e blindada para cada operador.

## ADR 14: Representação Estruturada de Tipos na AST (ASTTypeRef)
**Data:** Fase 28
**Contexto:** O compilador representava tipos no AST utilizando strings cruas formatadas (ex: `"List<Int>"` ou `"[Int]"`). Essa abordagem exigia análises de strings complexas, lentas e propensas a falhas (usando `startsWith`, `indexOf` ou `split`) sempre que o `TypeChecker` precisava resolver tipos, tratar tipos opcionais (`Opt` / `?`) ou realizar monomorfização de classes genéricas.
**Decisão:** Substituir a representação de tipo baseada em strings por um modelo estruturado chamado `ASTTypeRef`, composto por campos explícitos (`name`, `generic_args`, `is_array`, `is_nullable`). O parser passa a instanciar e propagar essa estrutura recursiva a partir das anotações de tipo. O `TypeChecker` agora resolve os tipos semanticamente utilizando barramentos estruturais, e as substituições genéricas operam diretamente por clonagem da árvore `ASTTypeRef`.
**Razão:** Traz robustez extrema para o sistema de tipos. Elimina a necessidade de parsing de strings "ad-hoc" no verificador semântico e resolve de forma elegante e escalável a manipulação de classes genéricas com qualquer número de parâmetros (não mais limitados a 1 ou 2 argumentos genéricos). As otimizações de compatibilidade com os nomes de arquivos mangled (como `Opt` e `?`) foram mapeadas perfeitamente para manter a integridade total do backend.

## ADR 15: Herança de Classe por Embutimento de Structs e Ponteiros de Função
**Data:** Fase 30
**Contexto:** O Eiwa necessita de suporte a herança de classes para permitir polimorfismo dinâmico e implementar o tratamento estruturado de Exceções (Phase 19). Precisamos de uma arquitetura que ofereça polimorfismo mantendo a performance de uma linguagem nativa compilada e que se adapte de forma direta tanto no C Transpiler quanto no futuro LLVM Backend.
**Decisão:** Adotar herança de classe única baseada em embutimento de structs em C (onde a struct da classe pai é o primeiro campo da struct da classe filha) combinado com despacho dinâmico via ponteiros de função embutidos na struct. Toda classe marcada como `open` ou que possui herança terá seus ponteiros de métodos dinâmicos instanciados nas structs e remapeados nos construtores das subclasses.
**Razão:** Permite polimorfismo dinâmico e reutilização de estado sem a necessidade de tabelas de métodos virtuais (VTables) globais complexas no compilador. A herança por embutimento garante que a conversão de ponteiros (upcasting) no backend C e LLVM IR seja gratuita (offset zero). Os ponteiros de função na struct facilitam o despacho dinâmico direto em C (`obj->speak_ptr(obj)`) e LLVM IR (`indirect call`), e permitem otimizações nativas de devirtualização pelo compilador LLVM.

## ADR 16: Exception Handling via local setjmp/longjmp Stack Unwinding
**Data:** Fase 19
**Contexto:** Queríamos implementar o tratamento estruturado de exceções (`try-catch`), com suporte a multi-catch e captura genérica de erros, gerando código que mapeie eficientemente para C e que seja compatível com a infraestrutura futura de `landingpad`/`invoke` do LLVM IR.
**Decisão:** Adotar um modelo de desenrolamento de pilha não-local baseado na biblioteca padrão `<setjmp.h>`.
1. Cada bloco `try` gera um frame de exceção local empilhado em uma pilha thread-local (`eiwa_exception_stack`), capturando o ponto de retorno via `setjmp`.
2. Lançamentos de erros (`throw`) armazenam a exceção ativa em uma variável thread-local e saltam para o frame ativo via `longjmp`.
3. Os catches são resolvidos por ordem de declaração usando RTTI dinâmico em runtime (`eiwa_is_instance`). Se nenhum capturar, ocorre rethrow automático. O tipo estático da variável capturada no multi-catch é a classe base `Exception`.
4. Opcionalmente suportar blocos `catch` anônimos sem assinatura (`catch { ... }`) que capturam qualquer erro de forma silenciosa.
**Razão:** O uso de `setjmp`/`longjmp` simula a nível de C o comportamento de tabelas de saltos não-locais de exceções tradicionais. Esse modelo mapeia-se de forma direta para a instrução nativa `invoke` e blocos de `landingpad` no backend LLVM IR futuro, fornecendo no futuro tratamento de custo zero (Zero-Cost Exception) sem comprometer o fluxo lógico de C do transpiler atual.

## ADR 17: Operadores Ternário e Ternário Curto
**Data:** Fase 18
**Contexto:** O Eiwa não possuía o operador condicional ternário (`? :`), exigindo o uso de blocos `if-else` mais verbosos. Além disso, queríamos suportar um operador ternário curto (`condicao ? valor`) que retorna `null` implicitamente quando a condição é falsa.
**Decisão:**
1. **Precedência e Associatividade:** O operador ternário terá precedência logo abaixo do operador Elvis (`?:`) e acima do de atribuição (`=`), associando à direita (permitindo ternários aninhados sem parênteses, ex: `a ? b : c ? d : e` avalia como `a ? b : (c ? d : e)`).
2. **Tipo de Retorno (Ternário Curto):** O tipo retornado pelo ternário curto `a ? b` é uma união entre o tipo de `b` e `Null` (ex: `Type?`). Para evitar tipos opcionais aninhados redundantes (ex: `String??`), achatamos o tipo de retorno se `b` já for anulável. Expressões do tipo `Void` são proibidas como branch positiva.
3. **Transpilação para C:** Para o ternário padrão, geramos `((cond) ? (then) : (else))`. Para o ternário curto, como o C não o suporta nativamente, transpilamos como `((cond) ? (then) : 0)`.
**Razão:** Traz mais concisão e expressividade à linguagem, seguindo o pragmatismo e a simplicidade da transpilação direta para C, com checagem estática rigorosa de nulidade no TypeChecker.

## ADR 18: Pattern Matching e Expressões when
**Data:** Fase 32
**Contexto:** O compilador Eiwa precisava de uma forma expressiva de controle de fluxo condicional baseado em valores e tipos, para substituir cadeias longas de `if-else` e dar suporte a smart casting elegante.
**Decisão:** Adotar a expressão `when` (estilo Kotlin). A expressão `when` pode ter um assunto (`when (x)`) ou não. Suportará condições baseadas em valores literais, expressões gerais ou testes de tipo (`is Type` / `!is Type`). Cada caso é separado de seu corpo usando o operador `->`. Para transpilação, geramos uma cadeia de `if-else` em C embutida em uma Expressão de Bloco de Instruções do GCC (`({ ... })`).
Se o `when` retornar um valor não-Void, o compilador exige a presença de um ramo `else` para garantir a exaustividade (checagem de tipos rigorosa). Além disso, se o assunto for um identificador (variável estável) e houver uma única checagem de tipo `is Type` (sem negação `is_not == false`), o compilador fará *smart cast* da variável dentro do escopo daquele ramo.
**Razão:** O uso da expressão de bloco C `({ ... })` permite que `when` funcione tanto como expressão quanto instrução de forma uniforme em C, sem a limitação de switch-cases de C (que só suportam inteiros constantes). O *smart casting* melhora radicalmente a ergonomia de checagem de tipos polimórficos estabelecida no ADR 15.

## ADR 19: Standard Library HTTP e Networking via FFI e Evolução de Loop de Eventos
**Data:** Fase 35 e 36
**Contexto:** Para criar frameworks web e bibliotecas de requisição no Eiwa, precisamos de uma API de HTTP client e HTTP server performática. Go e Crystal usam concorrência baseada em fibers/goroutines sobre loops de eventos, mas o Eiwa não possui scheduler cooperativo nem event loop integrado no runtime atualmente.
**Decisão:** Adotar uma abordagem híbrida evolutiva:
1. **Fase Inicial (Phase 35):** Implementar o cliente HTTP (`std.http.Client`) via FFI com a biblioteca C `libcurl`, e o servidor HTTP (`std.http.Server`) utilizando FFI com `libuv` (ou soquetes não-bloqueantes com wrappers leves em C compilados no runtime).
2. **Fase de Concorrência Avançada (Phase 36):** Projetar uma infraestrutura de Fibers cooperativas no C runtime e um loop de eventos centralizado baseado em `epoll`/`kqueue`/`libevent`. Reimplementar soquetes da standard library para suspender as fibers em caso de bloqueio de I/O, entregando concorrência de altíssima performance no nível de Go e Crystal.
**Razão:** A curto prazo, reutilizar `libcurl` e `libuv` através de FFI aproveita a performance máxima e maturidade dessas bibliotecas em C, minimizando o risco de falhas de segurança e reduzindo drasticamente o esforço de implementação. A longo prazo, a Fase 36 unificada (ver ADR 35) substitui esta abordagem por fibras nativas em Zig + task { }/await() + I/O não-bloqueante, dando ao Eiwa a mesma ergonomia síncrona e escalabilidade em concorrência que Go e Crystal.

## ADR 20: Lambda Expressions & Higher-Order Functions (Lambdas e Funções de Alta Ordem)
**Data:** Fase 31
**Contexto:** Para suportar programação funcional, concorrência e expressividade no estilo Kotlin, o Eiwa necessita de suporte a lambdas (literais de função) e closures (funções que capturam variáveis de escopo léxico externo).
**Decisão:**
1. **Sintaxe e Parâmetros:** Seguir estritamente o estilo Kotlin. Se nenhum parâmetro for declarado explicitamente (ex: `{ it + 1 }`), uma variável implícita chamada `it` será automaticamente injetada pelo TypeChecker com o tipo correspondente do argumento esperado pelo contexto. Se parâmetros explícitos forem providos (ex: `{ x -> x + 1 }`), a variável `it` não será definida. Além disso, suportar a sintaxe de *Trailing Lambda* (Lambda Pendente), onde a lambda pode ser passada fora dos parênteses se for o último argumento de uma chamada de função (ex: `html { ... }` ou `foo(arg) { ... }`).
2. **Mecanismo de Captura (Closures):** Variáveis imutáveis (`val`) capturadas são passadas por cópia/valor diretamente para a estrutura de contexto da closure. Variáveis mutáveis (`var`) capturadas sofrerão *boxing* automático (alocadas no heap via Boehm GC como uma struct wrapper) para garantir consistência de leitura e escrita tanto no escopo externo quanto interno à lambda.
3. **Representação no C e LLVM Backend:** Usar o padrão de *Ponteiro Gordo* (Fat Pointer). Uma closure é representada em C e LLVM como uma struct com dois ponteiros: um ponteiro para a função real e um ponteiro genérico de contexto/ambiente (`void* env`). A assinatura da função gerada sempre terá o ponteiro do ambiente (`env`) como primeiro argumento. A chamada é transpilada uniformemente como `closure.fn_ptr(closure.env, args...)`.
**Razão:** A sintaxe com `it` traz excelente ergonomia idêntica ao Kotlin. A representação de *Ponteiro Gordo* no backend C e LLVM IR é o padrão da indústria (Rust/Swift/Go), evitando poluição de código gerado e permitindo passagem uniforme de funções de primeira classe, garantindo a evolução do compilador para emissão de código nativo via LLVM sem grandes refatorações estruturais.

## ADR 21: Objects & Boundless Namespaces
**Data:** Fase 38
**Contexto:** O Eiwa precisava de suporte a membros estáticos (funções e variáveis associadas a uma classe/tipo, e não a instâncias específicas) para permitir fábricas de instanciação, constantes e namespaces limpos. Em vez de introduzir a palavra-chave `static` clássica do C++/Java, optou-se pela semântica de blocos de objeto associados (`object`).
**Decisão:**
1. Introduzir a palavra-chave `object` para declarar blocos estáticos nomeados (`object File { ... }`) ou anônimos (`object { ... }`).
2. Implementar binding restrito no Parser: a declaração de `object` anônimo deve ser na mesma linha do fechamento da classe como uma continuação (`} object {`). Da mesma forma, uma classe anônima seguindo um `object` nomeado deve continuar na mesma linha (`} class (...) {`). O Parser valida isso comparando o número da linha do token com a linha do último brace de fechamento (`}`). Se não estiverem na mesma linha, gera um erro de sintaxe.
3. Unificar os escopos no TypeChecker: o TypeChecker resolve membros estáticos buscando no bloco `object` associado (onde não há injeção de ponteiro implícito `this`), e membros de instância no bloco `class` correspondente (onde há injeção de `this`). Acesso estático ocorre via `Type.membro`.
4. Transpilação sem overhead: funções estáticas declaradas no `object` são compiladas diretamente como funções globais sem o argumento de ponteiro de instância (`this`). Variáveis estáticas no `object` tornam-se variáveis globais em C, com os nomes mangled adequadamente (`File_read`, `File_defaultPath`).
**Razão:** Mantém a simplicidade do modelo de transpilação sem introduzir modificadores redundantes de escopo (`static`) em cada campo. A exigência de mesma linha na continuação (`} object {`) reforça a integridade visual da declaração conjunta, tratando o bloco `object` como parte intrínseca do tipo.

## ADR 22: Standard Library Environment Configuration (`std.env`)
**Data:** Fase 39
**Contexto:** O Eiwa precisava de suporte a gerenciamento de variáveis de ambiente do processo e leitura de arquivos de configuração locais `.env` de forma limpa, tipada e resiliente.
**Decisão:**
1. Criar o módulo `std.env` expondo o objeto `Env` com suporte a `load()`, `get()`, `set()`, `unset()` e `exists()`.
2. Implementar FFI bindings eficientes para a biblioteca padrão do C (`getenv`, `setenv`, `unsetenv` e `atoi` do `<stdlib.h>`).
3. O método `Env.load(path)` fará checagem de legibilidade silenciosa do arquivo via FFI (tentando `fopen` no modo leitura) antes de processá-lo, retornando `false` sem emitir erros no stdout se o arquivo não existir.
4. O parseador de `.env` descartará linhas vazias e comentários iniciados por `#`, fará split no primeiro caractere `=`, aplicará trim de espaços/newlines nas chaves e valores, e removerá aspas externas simples (`'`) ou duplas (`"`) do valor.
5. Permitir conversão automática e segura para tipos em sobrecargas de `Env.get`:
   - `Env.get(key): String?` (retorna `null` se não existir).
   - `Env.get(key, default: String): String` (retorna o default se não existir).
   - `Env.get(key, default: Int): Int` (converte via `atoi` ou retorna default se não existir).
   - `Env.get(key, default: Bool): Bool` (valida valores truthy como `"true"`, `"1"`, `"yes"`, `"on"` ou retorna default se não existir).
6. Executar o auto-loading automático do `.env` na primeira chamada de leitura (`get`, `exists`) caso `Env.load()` não tenha sido invocado previamente.
**Razão:** Centraliza o acesso à configuração do processo sob uma única API consistente, facilitando inicialização de servidores e scripts que dependem de configurações dinâmicas de infraestrutura sem poluir a saída de erros na inicialização.

## ADR 23: Arquitetura de Compilador Multi-Pass (Kotlin/Crystal Style)
**Data:** Fase 40
**Contexto:** O compilador Eiwa operava por análise semântica e resolução de imports recursivas na mesma passagem (single-pass sob demanda). Essa estrutura gerava recursão infinita ou falha por falta de símbolos caso houvesse dependência circular entre classes/módulos do usuário (ex: Classe A referenciando Classe B e vice-versa), além de causar redundância na transpilação final em C.
**Decisão:** Refatorar o pipeline em três passes ordenados e centralizados sob um driver/orquestrador (Opção A):
1. **Parsing Pass:** Carrega e analisa recursivamente todos os arquivos a partir do ponto de entrada (incluindo implicit imports e explicit imports), armazenando as ASTs brutas em um registro global mapeado pelo caminho físico absoluto do arquivo.
2. **Declaration Pass:** Varre todas as ASTs cadastradas para registrar as assinaturas públicas de todos os tipos (classes, construtores, objetos, funções, bibliotecas FFI) nos respectivos escopos locais e globais, resolvendo namespaces e imports de assinaturas de forma estática sem validar corpos.
3. **Semantic Body Validation Pass:** Executa a validação semântica profunda e verificação de tipos de expressões, corpos de métodos/funções, inicializadores padrões e statements soltos em todos os arquivos no registro unificado.
Além disso, atualizar o `CTranspiler` para verificar se um arquivo físico (incluindo o core da stdlib) já foi transpiled através de um mapa de controle `emitted_modules`, garantindo deduplicação total de símbolos em C.
**Razão:** Permite dependências circulares de tipos completas no nível de linguagem de forma transparente, garante clareza de passes no compilador, elimina redundâncias no backend CTranspiler e fornece a base de dados ideal (ASTs pré-resolvidas de escopo) para a futura geração nativa de LLVM IR.

## ADR 25: Sistema de Tipos por Composição — Types, Contracts & Skills (Substitui Herança)
**Data:** Fase 41
**Contexto:** A experiência com herança de implementação (ADR 15, Fase 30) revelou os problemas clássicos do modelo: acoplamento frágil entre classes base e derivadas, hierarquias de exceção artificiais, e structs com ponteiros de função remapeados em cadeias de construtores. A linguagem precisava de um modelo de reúso de comportamento e polimorfismo que mantivesse cada abstração com responsabilidade única.
**Decisão:** Substituir completamente o modelo OO por herança por um sistema de composição baseado em cinco declarações:
1. **`type`** — única declaração que possui estado e identidade. Pode implementar contracts (`:`) e compor skills (`+`).
2. **`object`** — singleton (mantém a semântica do ADR 21).
3. **`contract`** — define apenas API comportamental: métodos sem corpo, sem estado, sem construtores, não instanciável.
4. **`skill`** — comportamento reutilizável com implementação: sem estado, sem construtores, não instanciável. Pode *requerer* contracts via `:`, mas **não os implementa** — os métodos requeridos são resolvidos contra o `type` consumidor (ex: `skill Shadow : Drawable` pode chamar `draw()`).
5. **`enum`** — mantida como está; seu alinhamento formal com o novo modelo fica para uma fase futura.

## ADR 26: Imports Não-Desestruturados Não Re-Exportam Símbolos Transitivos
**Data:** Pós-Fase 41 (Julho 2026)
**Contexto:** Imports não-desestruturados (`import {} from "mod"`, incluindo os imports implícitos de `std.core`/`std.env`/`std.collections`/`std.time`) copiavam **todo** o escopo global do módulo importado — incluindo símbolos que esse módulo tinha, por sua vez, importado de terceiros. Como `std.env` importa `{ File }` de `std.fs`, todo arquivo de usuário recebia `File → fs_File` no escopo global. Qualquer tipo local chamado `File` (ou `List`, `Map`, `Time`...) colidia com o símbolo vazado e falhava com `SymbolAlreadyDefined` (ex: `samples/companion_sample.ei`).
**Decisão:** Cada `TypeChecker` passa a registrar em `local_symbols` apenas os símbolos **declarados no próprio módulo** (types, contracts, skills, objects, funções top-level, libs). No import não-desestruturado, apenas símbolos pertencentes a `local_symbols` do módulo importado são copiados para o consumidor (escopo e aliases). As tabelas `classes_ast`/`contracts_ast`/`skills_ast`/`objects_ast` continuam copiadas integralmente, pois são indexadas por nome mangled (sem risco de colisão) e necessárias ao transpiler. Imports desestruturados (`import { X }`) não mudam: continuam explícitos e capazes de importar qualquer símbolo visível.
**Razão:** Elimina o vazamento transitivo de símbolos pela cadeia de imports, restaurando o shadowing natural: o módulo local sempre pode declarar tipos com nomes que coincidem com dependências de dependências (ex: `type File` local convivendo com `fs.File`). Módulos continuam recebendo exatamente a API pública dos módulos que importam — nem mais, nem menos.

## ADR 27: Serialização JSON/YAML por Composição — Contract `Serializable` + Skills de Formato
**Data:** Fase 45 (Julho 2026)
**Contexto:** A linguagem precisava de serialização de objetos para JSON e YAML sem reflexão ao estilo Java (introspecção de campos em runtime). O sistema de composição da Fase 41 (ADR 25) oferece o encaixe natural: contracts para opt-in e skills para comportamento plugável.
**Decisão:**
1. **Opt-in via contract marker:** nenhum `type` é serializável por default. O usuário marca `type User(...): Serializable`. O contract declara um único método: `fun serdeFields(): List<SerdeField>`.
2. **Metadados em compile-time:** o compilador **gera o corpo de `serdeFields()`** para cada `type` que implementa `Serializable` — uma lista de `SerdeField(name, value)` construída com acesso direto aos campos. Não há tabela consultada nem introspecção em runtime; o método gerado é código comum, inlinável e com dispatch estático. Se o usuário escrever o próprio `implement fun serdeFields()`, o dele prevalece (escape hatch para pular/renomear campos sem anotações).
3. **Encoders 100% em Eiwa:** os formatos são skills na stdlib (`std.serde`): `skill Json : Serializable { fun toJson(): String }` e `skill Yaml : Serializable { fun toYaml(): String }`, compostas com `+`. Seus corpos são `.ei` puro e usam `when (v) { is SerdeInt -> ... }` com smart cast para percorrer a lista de `serdeFields()`. Novos formatos (Toml, XML, binário) são skills novas sem tocar o compilador.
4. **Valores heterogêneos via contract marker `SerdeValue`:** cada valor é encaixotado em um box std que implementa `SerdeValue` (`SerdeInt`, `SerdeBool`, `SerdeString`, `SerdeObject`, `SerdeListValue`). O contract é vazio (marker); os encoders usam `when (v) { is SerdeInt -> v.v.toString() }` com smart cast garantido pelo type checker para acessar os campos das boxes concretas.
5. **Regra de campos:** só entram na lista gerada campos de tipos serializáveis — primitivos (`Int`, `Bool`, `String`), `type`s que implementam `Serializable` (recursivo via `SerdeObject`) e `List<T>` com `T` serializável (via `SerdeXList` + `SerdeListValue`). Campos de qualquer outro tipo são **ignorados silenciosamente**. Campos `Map<K,V>` e nullable ficam para uma fase futura.
6. **Somente serialização:** `fromJson`/`fromYaml` ficam para fase futura — exigem alocador, erros de parse e semântica de construção, dobrando o escopo.
**Razão:** Restringir o codegen do compilador a um único método (`serdeFields()`) minimiza a superfície de manutenção do backend e mantém os formatos como biblioteca pura, na filosofia de composição do ADR 25. O custo de boxing + dispatch de contract por campo é aceito na v1 em troca de extensibilidade (qualquer usuário pode escrever um encoder em `.ei`) e pode ser otimizado depois sem mudar a API pública. Comparado a reflexão Java, os metadados são resolvidos em compile-time: nomes de campos e acessos viram código gerado, não lookup em runtime.

Regras centrais:
- **Hard break:** as palavras-chave `class`, `open`, `abstract` e a sintaxe de herança (`class Sub : Super()`) são removidas da linguagem. Não há alias nem modo de compatibilidade.
- **Validação de composição:** um `type` só pode compor uma skill se implementar *todos* os contracts requeridos por ela. Erro de compilação: `Skill 'Shadow' requires contract 'Drawable'. Type 'Button' does not implement it.`
- **Conflitos de skills:** se duas skills compostas declaram o mesmo membro, o compilador reporta ambiguidade até que o `type` resolva explicitamente com `implement` e chamada qualificada (`MouseInput.click()`).
- **Palavra-chave `implement`:** substitui `override` no novo modelo — sem herança não há "sobrescrita", apenas implementação de contracts e resolução de conflitos. `override` é removida junto com `class`.
- **Exceções sem hierarquia:** qualquer `type` que implemente o contract `Throwable` pode ser lançado/capturado. A classe base `Exception` deixa de existir; as checagens de `throw`/`catch` passam a verificar conformidade com o contract.
- **Representação em runtime:** valores de tipo contract (ex: `d: Drawable`, `e: Throwable`) são representados como *fat pointers* (ponteiro de dados + ponteiro de vtable), permitindo dispatch dinâmico e coleções heterogêneas (`List<Drawable>`). Chamadas com tipo estático concreto usam dispatch estático direto.
**Razão:** A composição via skills elimina o acoplamento de hierarquias sem abrir mão do reúso de código; os contracts preservam polimorfismo dinâmico com custo explícito e localizado (apenas valores de tipo contract pagam o fat pointer). O modelo garante por construção que todo método invocado por uma skill existe no tipo consumidor, tornando inválidos estados que em linguagens com traits/interfaces só falham em tempo de linkagem ou runtime. A remoção total da herança simplifica o TypeChecker (sem resolução de cadeias de superclasses) e o backend (sem embutimento de structs e remapeamento de ponteiros de função do ADR 15). **Este ADR substitui o ADR 15 e torna a Phase 33 (Interfaces & Abstract Classes) obsoleta — interfaces e classes abstratas nunca existirão; `contract` e `skill` ocupam esses papéis.**

## ADR 24: Suporte a Escape de Aspas e Caracteres Especiais em Strings
**Data:** Fase de Estabilização (Julho 2026)
**Contexto:** O Eiwa não suportava escape de aspas em literais de String, o que impedia construções básicas como `"Ele disse \"Olá\""`. Qualquer aspa dupla `"` encontrada dentro de uma string fechava o literal prematuramente no Lexer.
**Decisão:**
1. **Tratamento no Lexer:** Modificar o analisador léxico (`lexer.zig`) no método `string` para ignorar aspas de fechamento se forem precedidas por um caractere de escape (barra invertida `\\`), e também consumir a própria sequência de escape (e o caractere seguinte) para permitir outros escapes padrão do Kotlin/C (como `\\`, `\n`, `\t`, `\r`, `\'`, `\b`).
2. **Cálculo de Tamanho no Type Checker:** Modificar a inferência de tipo de literais de string em `core.zig` para calcular o comprimento correto da string descontando os caracteres de barra invertida (`\\`) usados como escape. Isso garante que a propriedade `length` das Strings geradas em C represente a quantidade correta de bytes de dados.
3. **Transpilação:** As sequências de escape em C coincidem exatamente com as do Kotlin, portanto o backend do transpiler pode ejetar a string diretamente sem a necessidade de re-mapeamento complexo em tempo de transpilação.
**Razão:** Traz conformidade com o padrão do Kotlin e de outras linguagens modernas de forma extremamente simples e robusta, com impacto mínimo no parser e garantia de consistência de tamanho e integridade de memória.

## ADR 28: General Union Types (T1 | T2) e Autoboxing de Primitivos
**Data:** Fase 46 (Julho 2026)
**Contexto:** Originalmente, Union Types (`|`) eram usados internamente apenas para *Null Safety* (`String?` ➔ `String | Null`). A linguagem não suportava uniões arbitrárias de tipos em declarações de variáveis ou estruturas de dados genéricas como `Map<String, String | Int>`.
**Decisão:**
1. **Parsing Generalizado:** O parser passa a aceitar encadeamentos arbitrários de tipos no operador `|` em anotações de tipo e argumentos genéricos (`Type1 | Type2 | ...`).
2. **Subtipagem e Resolução Semântica:** No TypeChecker, uma expressão é compatível com `T1 | T2` se for compatível com `T1` ou `T2`. Se a expressão origem for ela própria uma união, todos os seus componentes devem ser aceitos pelo tipo destino.
3. **Representação no C Transpiler:** Uniões gerais não-nulas entre tipos distintos (ex: `String | Int`) são representadas no backend C como `void*`. Valores de tipos primitivos (`Int`, `Bool`) atribuídos a uma variável do tipo Union passam por autoboxing/unboxing de ponteiro `(void*)(intptr_t)val` e `(int)(intptr_t)val`.
4. **Coleções Genéricas Heterogêneas:** Monomorphizações como `Map<String, String | Int>` operam transparentemente com a união tratada como tipo de valor `V`, permitindo armazenar múltiplos tipos na mesma coleção de forma segura.
**Razão:** Expande o sistema de tipos para permitir mapas e variáveis dinâmicas de múltiplos tipos sem perder a checagem de tipos estática na linguagem base.

## ADR 29: Contratos Principais do Sistema e Derivação Automática de Skills (`Stringable`, `Hashable`, `Equatable`, `Echoable`)
**Data:** Fase 47 (Concluída - Julho 2026)
**Contexto:** A conversão de objetos, tipos primitivos e uniões para string ou hash dependia historicamente de métodos soltos ou de helpers procedurais em C (como `eiwa_to_string` no `eiwa_runtime.h` para inspecionar uniões `void*`). Do ponto de vista de arquitetura de linguagem, todas as abstrações fundamentais devem ser expressas nativamente em código `.ei` usando o modelo de composição (`contract` + `skill` do ADR 25).
**Decisão:**
1. **Contratos Nativos do Sistema:** A Standard Library (`src/std/core.ei`) define os contratos fundamentais da linguagem:
   - `contract Stringable { fun toString(): String }`
   - `contract Equatable { operator fun equals(other: Stringable): Bool }`
   - `contract Hashable { fun hashCode(): Int }`
   - `skill Echoable : Stringable { fun echo() { println(this.toString()) } }`
2. **Conformidade Automática e Sintetização:** Todo `type` e `object` declarado no Eiwa implementa automaticamente os contratos `Stringable`, `Equatable` e `Hashable`. Caso o tipo não forneça uma implementação explícita, o TypeChecker sintetiza automaticamente a implementação padrão (ex: `toString()` baseado no nome e membros da struct, `hashCode()` combinando hashes dos campos, e `equals()` por comparação estrutural de membros). Propriedades do tipo closure (`is_function`) são ignoradas durante a sintetização para evitar comparações/casts inválidos no backend C.
3. **Tipos Primitivos Conformes:** Os tipos primitivos (`Int`, `Bool`, `String`, `Pointer`) são declarados explicitamente em `src/std/core.ei` como implementadores dos contratos `Stringable`, `Hashable` e `Equatable`.
4. **Helpers no C Runtime com Despacho por VTable:** Em uniões (`String | Int`) ou genéricos apagados (`void*`), chamadas a `eiwa_to_string` e `eiwa_hash_code` no `eiwa_runtime.h` utilizam despacho dinâmico por VTable (`eiwa_find_vtable`) via `core_Stringable_contract` e `core_Hashable_contract`, tratando unboxing de primitivos de forma transparente sem duplicar código no transpiler.
5. **Helpers Globais de I/O e Controle de Fluxo:** A stdlib disponibiliza `echo(value: Stringable?)`, `loop(block: () -> Void)` e `repeat(count: Int, block: (Int) -> Void)`.
## ADR 30: Arquitetura Modular da Standard Library (`std.core`, `std.io`, `std.system`, `std.exceptions`)
**Data:** Fase de Estabilização e Refatoração (Julho 2026)
**Contexto:** Historicamente, o arquivo `src/std/core.ei` agregava uma grande quantidade de responsabilidades heterogêneas: bindings nativos C (`lib Standard`, `lib Posix`, `lib NativeString`), primitivos da linguagem, I/O de console (`print`, `println`), controle de fluxo (`loop`, `repeat`, `sleep`), exceções (`Throwable`, `AssertionException`) e contratos fundamentais. Esse padrão monolítico dificultava a manutenção e feria o princípio de responsabilidade única.
**Decisão:**
1. **Separação de Módulos da Stdlib:** O arquivo monolítico `src/std/core.ei` foi decomposto em quatro arquivos com responsabilidades bem delimitadas:
   - `src/std/core.ei`: Primitivos da linguagem (`Int`, `Bool`, `String`, `Pointer`), contratos essenciais (`Stringable`, `Equatable`, `Hashable`) e bindings C nativos de memória e utilitários (`lib Standard`, `lib NativeString`).
   - `src/std/io.ei`: I/O de console e terminal (`lib Console` com `printf`, `puts`, `fflush`), funções globais de saída (`print`, `println`, `echo`) e a skill `Echoable`.
   - `src/std/system.ei`: Utilitários de sistema, processos e loops (`lib Posix` com `sleep`, `usleep`, `exit`, `loop`, `repeat`).
   - `src/std/exceptions.ei`: Infraestrutura nativa de exceções e asserções (`contract Throwable`, `type AssertionException`, `fun assert`).
2. **Constantes de Importação Implícita no TypeChecker:** As constantes de importação implícita (`core_implicit_imports`, `user_implicit_imports`, `core_fallback_modules`) foram centralizadas no compilador (`infer_decl.zig`), eliminando condicionais hardcoded.
3. **Injeção Transparente & Compatibilidade Retroativa:** Todo programa Eiwa e módulo da stdlib importa automaticamente o conjunto fundamental de sub-módulos da stdlib (`std.core`, `std.io`, `std.system`, `std.exceptions`), mantendo 100% de compatibilidade retroativa para funções globais (`print`, `assert`, `exit`, `sleep`, etc.) e imports desestruturados pré-existentes (`import { print } from "std.core"`).
**Razão:** Organiza o código da biblioteca padrão em módulos pequenos e especialistas (~30-50 linhas cada), melhora a clareza arquitetural no compilador e elimina acoplamento entre I/O, gerenciamento de processos e tratamento de exceções.

## ADR 31: Sintaxe de Membro Implícito de `this` (Uso Opcional de `this.`)
**Data:** Fase de Estabilização (Julho 2026)
**Contexto:** Acessar propriedades de uma instância ou invocar métodos irmãos dentro de métodos de `type` e de lambdas de receptor (`T.() -> Void`) exigia a escrita explícita de `this.field` ou `this.method()`, gerando ruído sintático desnecessário em métodos e na escrita de DSLs.
**Decisão:**
1. **Resolução de Escopo Implícito:** O uso de `this.` torna-se opcional em métodos de `type` e em lambdas de receptor (`T.() -> Void`). Quando um identificador não qualificado é utilizado para leitura, escrita ou chamada de função, o compilador verifica o escopo local e, caso não seja uma variável/parâmetro local, mapeia automaticamente para o membro de `this`.
2. **Regra de Sombreamento (Shadowing):** Se um parâmetro de método ou variável local possuir o mesmo nome de uma propriedade do objeto (ex: `fun setPort(port: Int)`), o parâmetro local tem precedência sobre a propriedade. Nesses casos, o acesso à propriedade exige o uso explícito de `this.port`.
3. **Chamadas de Métodos Irmãos e Reatribuição:** O TypeChecker pré-registra as assinaturas de todos os métodos da classe no `class_scope` antes da checagem de corpos, permitindo chamadas diretas a qualquer método da mesma classe (inclusive métodos declarados mais abaixo no código) sem prefixar `this.`. Em atribuições (`running = false`), o compilador detecta que a variável pertence ao tipo e emite a reatribuição correta de membro (`this->running = false`) no CTranspiler.
**Razão:** Reduz a verbosidade e alinha a ergonomia sintática do Eiwa com linguagens como Kotlin, Swift e Java. Garante código legível e limpo em DSLs sem comprometer a segurança estática dos tipos nem a clareza em casos de sombreamento de parâmetros.

## ADR 32: Arquitetura do Módulo de Log da Standard Library (`std.log`)
**Data:** Fase 48 (Julho 2026)
**Contexto:** O Eiwa não possuía uma biblioteca padrão de logging. Aplicações recorriam a instruções manuais e não-estruturadas de `print` e `echo`. A linguagem precisava de um módulo de logging idiomático, rápido, contextual e com suporte a saídas legíveis por humanos (ANSI no terminal) e em JSON para produção.
**Decisão:**
1. **Avaliação Preguiçosa via Lambdas:** Os métodos de log (`trace`, `debug`, `info`, `warn`, `error`) recebem o conteúdo da mensagem por meio de uma lambda sem argumentos (`msgFn: () -> String`). Se o nível atual do logger for inferior ao nível do evento, a lambda não é invocada, evitando alocações e concatenações de strings desnecessárias.
2. **Suporte a Exceções `Throwable`:** Sobrecargas de `warn` e `error` aceitam um argumento opcional do contrato `Throwable` antes da lambda de mensagem: `Log.error(e) { "Falha no banco" }`.
3. **Formatadores por Composição (`skill`):** A formatação de logs é definida pelo contrato `contract LogFormatter`. As implementações são fornecidas via skills de composição (`skill TextFormatter` com cores ANSI para console e `skill JsonFormatter` para produção em nuvem), alinhadas ao modelo de composição do ADR 25 e ADR 27.
4. **Facade Estática e Instâncias Contextuais:** O objeto `object Log` atua como facade estática delegando ao logger raiz. Métodos `.with(key, value)` e `.withFields(map)` criam instâncias imutáveis `Logger` com campos de contexto herdados.
**Razão:** Combina máxima performance (zero allocation para logs filtrados) com concisão sintática (trailing lambdas), alinhando a stdlib de logs ao modelo de composição por skills e contracts da linguagem.

## ADR 33: Tipos `enum` First-Class na Linguagem e Refatoração de `std.log`
**Data:** Fase 49 (Julho 2026)
**Contexto:** Atualmente, constantes agrupadas como níveis de log (`LogLevel`) em `src/std/log.ei` utilizam inteiros em um `object` (`val TRACE: Int = 0`). Isso impede a checagem estática rigorosa de valores no compilador, perde a semântica de tipos nativos e força a conversão manual de inteiros em cadeias de texto (`logLevelToString(level: Int)`).
**Decisão:**
1. **Declaração Nativa de `enum`:** A linguagem introduz a palavra-chave `enum` para declarar enums fortemente tipados (`enum LogLevel { TRACE, DEBUG, INFO, WARN, ERROR, OFF }`).
2. **Propriedades e Métodos Implícitos:** Todo tipo `enum` terá membros sintetizados automaticamente pelo compilador:
   - `ordinal: Int`: Índice numérico do variante base zero (0..N-1).
   - `name: String`: Nome textual do variante (ex: `"DEBUG"`).
   - `values(): List<EnumType>`: Coleção com todas as instâncias do enum.
   - Implementação automática dos contratos `Stringable`, `Equatable` e `Hashable`.
3. **Refatoração de `std.log`:** O módulo `src/std/log.ei` substituirá `object LogLevel` por `enum LogLevel`, e todas as assinaturas (`LogFormatter`, `TextFormatter`, `JsonFormatter`, `Logger`, e a fachada `object Log`) passarão a operar nativamente com o tipo `LogLevel` em vez de `Int`.
**Razão:** Elimina constantes mágicas de inteiros, garante segurança de tipos em tempo de compilação para enumerações e eleva a ergonomia do módulo `std.log` e de toda a linguagem Eiwa.

### ADR 34: Compiler Toolchain Migration to Zig 0.16.0
**Status:** Aceito / Implementado
**Data:** Fase 49 (Julho 2026)
**Contexto:** O compilador Eiwa foi desenvolvido visando a versão 0.13.0 do Zig. No entanto, ambientes modernos de desenvolvimento (macOS Homebrew, Linux e Windows) utilizam a release Zig 0.16.0. A compilação do compilador sob o 0.16.0 falhava devido a breaking changes no build system (`build.zig.zon`, `root_module`), na remoção da versão managed de `std.ArrayList` e na reestruturação do subsistema de I/O (`std.Io`).
**Decisão:**
1. Atualizar o sistema de build ([build.zig.zon](file:///Users/leodouglas/Projects/dystral-lang/build.zig.zon) e [build.zig](file:///Users/leodouglas/Projects/dystral-lang/build.zig)) para o formato Zig 0.16.0 (`.name = .eiwa`, `.fingerprint`, `.root_module`).
2. Criar uma camada de compatibilidade em [src/core/compat.zig](file:///Users/leodouglas/Projects/dystral-lang/src/core/compat.zig) que adapta a nova estrutura *unmanaged* do `std.ArrayList` do Zig 0.16.0 mantendo acesso direto à propriedade `.items` e métodos de escrita (`.print(...)`, `.writeAll(...)`), preservando a ergonomia do compilador.
3. Atualizar a entrada do CLI para `pub fn main(init: std.process.Init)` e propagar o manipulador `std.Io` para chamadas de disco e subprocessos (`std.process.run`, `std.process.spawn`).
**Razão:** Permite que desenvolvedores em Linux, macOS e Windows compilem o Eiwa nativamente utilizando a versão mais recente do Zig (0.16.0) sem quebrar o ecossistema existente.

## ADR 35: Concorrência Estruturada com Fibras e Tasks
> **⚠️ SUPERSEDED (2026-08) pelo ADR 48:** fibras C (`fiber.c`/`fiber.h`) e o neco (stackful)
> foram **removidos**. O modelo atual é **coroutines stackless** (Phase 68): `task {}`/`await()`
> viram state machines geradas pelo compilador + Scheduler em Eiwa puro. Histórico mantido.
**Data:** Fase 36 (MVP) / Fase 50 (Monomorfização Real) / Fase 51 (Refactoring com neco)
**Contexto:** O Eiwa não possuía concorrência nativa. Precisávamos de concorrência leve ergonômica similar a Kotlin Coroutines, sem runtime de threads OS.
**Decisão:** O MVP (Fase 36) implementou fibras em C via `ucontext.h` (`fiber.c`/`fiber.h`) com special cases hardcoded no compilador para `task{}`/`await()`. A Fase 51 substituirá este runtime C por **neco** (https://github.com/tidwall/neco) em `third_party/neco/`, usando a monomorfização real (Generic method) da Fase 50 como dependência direta para que `Task<T>` seja 100% implementado em Eiwa na stdlib via `contract Awaitable<T>` + `skill TaskNeco + lib Neco`, eliminando todos os special cases do compilador.
**Razão:** neco foi escolhido sobre libaco por ser single-file (sem assembly platform-specific), usar kqueue/epoll nativamente, ter API limpa para suspend/resume por ID e ser MIT license. A dependência da monomorfização real (Generic method) desenvolvida na Fase 50 elimina a dívida técnica dos special cases da Fase 36 e permite que qualquer tipo/função genérica se beneficie do mesmo mecanismo.

## ADR 36: Function Call Resolution — Local Scope First with Compatibility Fallback
**Status:** Aceito / Implementado
**Data:** Fase 51 (Julho 2026)

**Contexto:** Ao chamar funções sem qualificação (`echo(name)`), o compilador precisava decidir qual escopo consultar primeiro: o escopo local (métodos de `this`, skills injetadas, lambdas com receiver) ou o escopo global (funções top-level como `echo(value: Stringable?)`, `print()`, `File()`).

O problema original: a skill `Echoable` (injetada automaticamente em todo `type` via ADR 29) fornece um método `echo()` com 0 parâmetros. Dentro de `Person.echoName()`, a chamada `echo(name)` encontrava esse método local primeiro e falhava por aridade, em vez de cair para a função global compatível.

**Decisão:** Implementar busca em duas fases no `inferCallExpr` (`src/core/type_checker/infer_call.zig`):

1. **Fase 1 — Escopo Local (`scope.lookupFunctions`)**: Consulta apenas funções **com receiver** (métodos de `this`, skills, lambdas com receiver `T.() -> Void`). Se houver match **compatível** (aridade + tipos), usa esse.
2. **Fase 2 — Escopo Global (`self.global_scope.lookupFunctions`)**: Se nenhum match local compatível, consulta apenas funções **sem receiver** (funções top-level). Se houver match compatível, usa esse.
3. **Fallback**: Se nada compatível, continua para lógica existente de funções genéricas e lookup de variáveis (construtores de tipo como `File(path)`).

**Comportamento de Shadowing (igual ao Kotlin):**
- Método local **compatível** → ganha do global
- Método local **incompatível** (aridade/tipos) → cai pro global
- Construtores (`File(path)`, `Person("Leo", 30)`) → fallback para variable lookup

**Razão:** Semântica previsível estilo Kotlin (escopo mais próximo vence) mas sem "shadowing acidental" que quebra chamadas válidas. Permite override intencional quando assinaturas são compatíveis, mas protege contra skills injetadas automaticamente com assinaturas incompatíveis (como `Echoable.echo()` sem parâmetros).

## ADR 37: Escape de Palavras Reservadas do C no Transpiler (`cIdent`)
**Status:** Aceito / Implementado
**Data:** Julho 2026

**Contexto:** Identificadores Eiwa válidos como `var bool = false` colidiam com palavras reservadas do C (`bool` via stdbool.h, `int`, `char`, etc.), gerando erros obscuros do compilador C no código emitido.

**Decisão:** Introduzir `cIdent()` em `src/backend/c_transpiler/core.zig`, que prefixa identificadores reservados com `eiwa_` (ex.: `bool` → `eiwa_bool`). Aplicado de forma consistente em todos os pontos de emissão de nomes de usuário: `var_decl`, `identifier`, `assignment`, parâmetros de função e captures de lambda (campos do env struct e variáveis locais da lambda). Propriedades de tipos (`this->prop`) e nomes mangled (`resolved_c_name`) não precisam de escape, pois já passam por name mangling ou são qualificados.

**Razão:** O usuário não deve precisar conhecer a lista de palavras reservadas do C para nomear variáveis em Eiwa. O escape centralizado num único helper evita espalhar a lista de reservadas pelo transpiler.

## ADR 39: Boxing de Capturas por Atribuição em Closures
**Status:** Aceito / Implementado
**Data:** Julho 2026

**Contexto:** A detecção de captura de variáveis mutáveis (que promove a variável a uma box heap-allocated compartilhada com a closure) só existia no caminho de leitura (`inferIdentifier`). Uma variável capturada **exclusivamente por atribuição** (ex.: `{ flag = true }`) nunca era boxed: o C gerado copiava o valor para dentro da lambda e a mutação era invisível fora dela — quebrando semântica de closure em qualquer contexto, não apenas em tasks.

**Decisão:** Espelhar a lógica de detecção de captura em `inferAssignment` (`src/core/type_checker/infer_expr.zig`): ao atribuir a uma variável definida além de uma fronteira de função (`is_function_boundary`), marcar o símbolo e o `var_decl` como `is_boxed`, fazendo o transpiler emitir acesso via ponteiro de box (`box->value`) tanto na declaração quanto na closure.

**Razão:** Semântica correta de closures (compartilhamento por referência de variáveis mutáveis capturadas, como Kotlin/Swift) independente de a variável ser lida ou apenas escrita dentro da lambda.

## ADR 40: Scope Functions Estilo Kotlin — Auto-Injeção de `Scope<T>` e Generic Methods com Receiver
**Status:** Aceito / Implementado
**Data:** Julho 2026

**Contexto:** A skill `Scope<T>` (let/run/also/apply/takeIf/takeUnless) existia na stdlib mas não era injetada em nenhum tipo — scope functions eram inutilizáveis. Três lacunas do compilador impediam o uso: (1) skills genéricas não tinham seus type params ligados ao tipo consumidor, (2) a inferência de generic methods não cobria type params em posição de retorno de function type (`R` em `(T) -> R`), (3) métodos genéricos monomorfizados não suportavam `this` (receiver).

**Decisão:**
1. **Auto-injeção universal:** todo `type` recebe a skill `Scope` automaticamente (como `Stringable`), incl. primitivos de `std.core`. A skill foi movida de `std.system` para `std.core` e `with` virou função top-level (`with(x) { }`). Conflitos de nome seguem a regra existente de `composeSkills` (método explícito do tipo vence, versão da skill fica qualificada como `Scope_let`).
2. **Binding T=Self:** `composeSkills` agora substitui os generic params da skill pelos type refs do tipo consumidor, construídos a partir dos refs **originais** do método da skill — `cloneTypeRef` aplica `alias_map` e pode reescrever `T` para um alias stale (ex.: `Int`) antes do binding.
3. **Inferência de generic methods:** estendida para type params em retorno de function type — a lambda é inferida com parâmetros concretos e retorno `Unknown` (compatível com tudo), e `R` é lido do tipo resolvido da lambda. O mesmo truque foi aplicado à dedução de funções genéricas top-level (necessário para `with`). O lookup do nó base em `monomorphizeFunction` é escopado à classe dona do método (o mapa global `generic_functions_ast` colide entre classes — toda classe tem um `let<R>` composto).
4. **Receiver em métodos monomorfizados:** `monomorphizeFunction` aceita um receiver opcional (define `this` no escopo de inferência), o transpiler emite `this` como primeiro parâmetro C quando `fn_type.receiver != null`, e a chamada reescrita passa o objeto como primeiro argumento. Member lookup no call site agora mapeia primitivos (`.Int` → `core_Int`).

**Razão:** Paridade com as scope functions do Kotlin (`5.let { it * 2 }`, `p.also { ... }`, `p.takeIf { ... }`) sem extension functions (Fase 34), reutilizando o sistema de composição (ADR 25) e a monomorfização (Fase 50).

## ADR 38: Driver PostgreSQL — Contratos `std.db` + Implementação 100% Eiwa
**Data:** Phase 53 (Julho 2026)
**Contexto:** O Eiwa precisava de acesso a bancos de dados SQL. A abordagem ingênua seria criar um driver monolítico com bindings C diretos. Porém, isso acoplaria o usuário a uma implementação específica, repetiria o padrão ruim de bibliotecas HTTP antigas (pré-ADR 19) e impediria que futuros drivers (MySQL, SQLite) compartilhassem a mesma API.

**Decisão:**
1. **Contracts provider-independentes em `std.db`:** Criar `src/std/db.ei` com `contract Database`, `contract Connection`, `contract Statement`, `contract Result` e `contract Row`. Toda aplicação Eiwa depende **somente de `std.db`** — nunca do driver diretamente.
2. **Entry point via `object Postgres`:** O ponto de entrada é `Postgres.connect(url)` — um `object` singleton (ADR 21), seguindo o padrão de Crystal (`DB.open`), Kotlin Exposed (`Database.connect`) e Go pgx (`pgx.Connect`). Sem instância de driver intermediária. O `contract Database` existe para **injeção de dependência** (ex: mocks em testes), não para o fluxo normal de uso.
3. **Implementação 100% Eiwa:** O driver PostgreSQL (`src/postgres/`) é Eiwa puro. A única camada C são dois helpers de glue:
   - `eiwa_neco_wait_readable(fd)` / `eiwa_neco_wait_writable(fd)` em `neco_wrapper.c` — necessários para o loop async non-blocking.
   - `eiwa_pq_exec_params` em `libpq_wrapper.h` — converte `EiwaArray<String>` para `char**` antes de chamar `PQexecParams`.
4. **Async via Neco (sem busy-wait):** O driver usa `PQsendQuery → PQsocket → Neco.waitReadable(fd)` para ceder a fibra enquanto aguarda o PostgreSQL, retomando apenas quando o socket estiver pronto. Nunca poleia em loop. Segue o mesmo padrão do `neco_sleep` e `neco_join` já estabelecidos na Phase 51.
5. **Eager result collection:** Após `PQgetResult`, os dados são copiados imediatamente para `List<PgRow>` em memória Eiwa gerenciada pelo Boehm GC e `PQclear()` é chamado logo em seguida. O `PGresult*` não vive além da construção do `PgResult`. Isso elimina o risco de vazamento de recursos nativos e mantém a GC como única fonte de verdade de lifetime.
6. **Params via `List<String>`:** `fun execute(sql: String, params: List<String>)` em vez de varargs. Varargs são postergados para uma fase futura após suporte nativo ao nível do compilador.
7. **Transaction com rollback automático:** `db.transaction { }` recebe um trailing lambda. Em caso de exceção, o `ROLLBACK` é emitido automaticamente antes do rethrow — comportamento transparente para o usuário.

**Razão:** Mantém a filosofia do Eiwa de composição e camadas limpas (ADR 25). A separação `std.db` (contracts) vs `std.postgres` (implementação) garante que futuros drivers (MySQL, SQLite, SQL Server) partilhem a mesma API sem mudanças na camada de aplicação, idêntico ao padrão JDBC/Kotlin Exposed. A escolha de eager collection (vs cursor lazy) simplifica o lifetime management sem GC finalizers — decisão pragmática aceitável na v1, revisável quando cursores de streaming forem necessários.

## ADR 41: Unificação de Ponteiros Primitivos (`Pointer`), Métodos de Acesso a Memória (`NativeMemory`) e Modularização de `eiwa_runtime.h`
**Status:** Aceito / Implementado
**Data:** Julho 2026

**Contexto:**
1. A standard library e FFI possuíam dois tipos de ponteiro concorrentes (`OpaquePointer` e `Pointer<T>`), gerando duplicidade e redundância.
2. Não havia métodos orientados a objetos em ponteiros para leitura e escrita de bytes em offsets de memória (`readByte` / `writeByte`).
3. O header de runtime em C (`src/backend/c_transpiler/eiwa_runtime.h`) estava se tornando um monólito (incluindo helpers POSIX de sockets, helpers do cURL e utilitários de memória), violando o princípio de modularidade e desacoplamento.

**Decisão:**
1. **Tipo Único `Pointer`:** Substituir `OpaquePointer` e `Pointer<T>` por um tipo primitivo único e conciso: `type Pointer`.
2. **Separação em `lib NativeMemory`:** Criar a biblioteca `lib NativeMemory` em `src/std/core.ei` contendo os bindings C de acesso a bytes (`eiwa_char_at` e `eiwa_write_byte`), mantendo `lib NativeString` focada exclusivamente nas funções de string C (`<string.h>`).
3. **Métodos Idiomáticos em `type Pointer`:** O `type Pointer` expõe métodos com corpos explícitos delegando para `NativeMemory` (`readByte(index: Int): Int` e `writeByte(index: Int, value: Int): Void`), mantendo a regra gramatical estrita do Eiwa (métodos de `type` sempre têm corpo). Em C, o compilador inlina a chamada para desindexação direta de ponteiros (`((uint8_t*)ptr)[index]`) com custo zero de execução.
4. **Modularização do Runtime C:**
   - Extrair helpers POSIX de rede (`eiwa_tcp_bind`, `eiwa_socket_read`, etc.) para `src/backend/c_transpiler/runtime/net_helpers.h`, vinculado via `@Header("runtime/net_helpers.h")` em `std/net.ei`.
   - Extrair helpers do cURL (`eiwa_curl_write_callback`, etc.) para `src/backend/c_transpiler/runtime/curl_helpers.h`, vinculado via `@Header("<curl/curl.h>", "runtime/curl_helpers.h")` em `std/http.ei`.
   - O `eiwa_runtime.h` é reduzido em ~47% (ficando exclusivamente com VTables, Contratos, GC, Exceções e Closures).

**Razão:**
Traz ergonomia e clareza para a FFI e stdlib do Eiwa, simplifica o Type Checker (eliminando tipos de ponteiros legados), garante consistência gramatical da linguagem e aplica o princípio de "pay-only-for-what-you-use" no backend C, onde headers de rede ou cURL só são incluídos na compilação se os módulos correspondentes do Eiwa forem importados.

## ADR 42: Abstração Agnóstica de Coroutines e Event-Loop (`object Coroutine` & `object EventLoop`)
**Status:** Aceito / Implementado
**Data:** Julho 2026

**Contexto:**
A biblioteca C Neco (`lib Neco`) estava sendo importada e chamada diretamente em múltiplos pontos da standard library (`std.net`, `std.system`) e em drivers de banco de dados (`samples/postgres/connection.ei`). Isso criava um acoplamento direto com a biblioteca C subjacente. Se a runtime do Eiwa trocasse a engine de concorrência por `libuv`, `io_uring` ou green threads nativas em Zig backend, todo o código da stdlib e das aplicações quebraria.

**Decisão:**
1. **Encapsulamento de `lib Neco`:** Restringir a declaração `lib Neco` como privada/interna ao módulo `std.coroutines` (sem exportá-la para os consumidores).
2. **Abstração por Objetos `Coroutine` e `EventLoop`:**
   - **`object Coroutine`**: Expõe chamadas agnósticas de concorrência (`Coroutine.start`, `Coroutine.join`, `Coroutine.yield`, `Coroutine.sleep`, `Coroutine.sleepMs`).
   - **`object EventLoop`**: Expõe chamadas agnósticas de polling de I/O (`EventLoop.waitReadable`, `EventLoop.waitWritable`).
3. **Refatoração dos Módulos Consumidores:**
   - `std.system`: Importa `Coroutine` para `sleep()` e expõe o helper `yield()`.
   - `std.net`: Importa `EventLoop` para I/O não-bloqueante em sockets TCP.
   - Driver PostgreSQL (`samples/postgres/connection.ei`): Importa `EventLoop` para wait de leitura não-bloqueante via libpq.
4. **Renomeação de Skill Interno:** `TaskableNeco` refatorado para `TaskableCoroutine`.

**Razão:**
Elimina o acoplamento direto de código da stdlib e drivers de aplicação com bibliotecas C específicas de coroutine. Garante que futuras substituições da engine de event loop ou coroutines exijam alterações exclusivamente no módulo `src/std/coroutines.ei`.

## ADR 43: Pool de Conexões de Banco de Dados Genérico (`type ConnectionPool<C>`) e Checagens Estáticas no Compilador
**Status:** Aceito / Implementado
**Data:** Julho 2026

**Contexto:**
1. O pool de conexões com banco de dados inicialmente desenvolvido no driver PostgreSQL (`PgPool`) estava acoplado ao driver `std.postgres`, gerando duplicação de lógica se novos drivers de banco de dados (como MySQL ou SQLite) fossem introduzidos na `std.db`.
2. Falhava uma checagem estática no compilador Eiwa para validar a simetria do modificador `implement` em `type`: se um desenvolvedor marcasse um método com `implement`, mas esse método não estivesse presente em nenhum contrato declarado no `type`, o compilador aceitava a declaração e gerava vtables C corrompidas no backend.

**Decisão:**
1. **Promoção de `ConnectionPool<C>` para `std.db`**: O pool de conexões cooperativo baseado em fibras foi promovido a um `type ConnectionPool<C>(val factory: () -> C, ...)` genérico e agnóstico na `std.db`, capaz de gerenciar qualquer tipo de conexão que implemente os contratos `Connection` e `Closeable`.
2. **Promover `BoundStatement` para `std.db`**: Abstração genérica de Prepared Statements com construtor fluente de parâmetros (`.bind()`).
3. **Inspecionar Inferência de Construtores Genéricos**: O TypeChecker foi atualizado (`infer_call.zig`) para inferir o parâmetro genérico `C` a partir do tipo de retorno de uma lambda fábrica de parâmetro (`factory: () -> C`), permitindo instanciar `ConnectionPool({ Postgres.connectRaw(url) }, maxConnections)` sem requerer a anotação manual `ConnectionPool<PgConnection>`.
4. **Validação Estática de `implement` Reverso**: O `inferTypeDecl` (`infer_decl.zig`) agora valida recursivamente que todo método em um `type` marcado com `implement` obrigatoriamente pertença a pelo menos um contrato declarado no cabeçalho ou resolva ambiguidade de `skill`. Emitindo o diagnóstico `TypeError` estático no compile-time caso contrário.

**Razão:**
Garante 100% de reuso de código no ecossistema de bancos de dados da `std.db`, elimina duplicação de infraestrutura de pool e traz robustez ao TypeChecker ao barrar vtables quebradas antes da transpilação C.

## ADR 44: Captura Transitiva de Variáveis em Closures Aninhadas (N-Level Nested Lambdas)
**Status:** Aceito / Implementado
**Data:** Julho 2026

**Contexto:**
Quando uma lambda profunda (nível N, ex: `get("/data") { pool.query(...) }`) capturava uma variável declarada em um escopo externo (ex: `val pool` em `fun main()`), a análise de escopo do CTranspiler (`collectCaptures`) não garantia a captura dessa variável através das closures intermediárias (`arest` ➔ `routing` ➔ `get`). Isso resultava no erro de compilação em C `use of undeclared identifier 'pool'`, forçando acoplamento artificial entre frameworks e dependências externas.

**Decisão:**
1. **Varredura Recursiva em `collectCaptures`**: Atualizar a esteira de análise de closures em `src/backend/c_transpiler/expression.zig` para inspecionar nós `.lambda_expr` aninhados.
2. **Propagação Transitiva de Structs `env`**: Qualquer variável requerida por uma lambda interna que não esteja declarada na lambda intermediária nem no seu escopo local imediato é promovida e incluída na lista de capturas das closures intermediárias.
3. **Desacoplamento Total de Frameworks**: Garante que frameworks Web (como Arest) permaneçam 100% agnósticos e que os consumidores consigam acessar instâncias de infraestrutura (como `pool`) declaradas no escopo do `main()` diretamente dentro das rotas.

**Razão:**
Elimina acoplamentos artificiais em frameworks, garante paridade com o modelo de closures do Kotlin/Swift e assegura a corretude da geração de código C e LLVM IR em qualquer nível de aninhamento de funções de alta ordem.

## ADR 45: Padrão `Money` Value Type na Standard Library (`std.money`) baseado em Minor Units e Fowler Allocation Engine
**Status:** Aceito / Implementado
**Data:** Julho 2026

**Contexto:**
Operações financeiras utilizando tipos de ponto flutuante (`Float`/`Double`) causam imprecisões binárias catastróficas em virtude da representação IEEE 754 (ex: `0.1 + 0.2 != 0.3`). Histórica e tradicionalmente (como no ecossistema Java), soluções como `BigDecimal` trouxeram precisão, porém ao custo de sintaxe extremamente verbosa (`a.add(b)`), alta alocação de memória e gestão manual complexa de arredondamento.

**Decisão:**
1. **Representação por Menor Unidade Não-Fracionada (Minor Units / Centavos):** Armazenar internamente os valores monetários como números inteiros (`cents: Int`), onde R$ 10,50 é representado por `1050` centavos. Isso elimina totalmente qualquer imprecisão de ponto flutuante com custo zero de alocação de CPU para adições e subtrações.
2. **Encapsulamento de Moeda (`Currency`) com Checagem Estrita:** O tipo `Money` vincula cada valor a um `Currency(code, symbol, decimals)`. Operações matemáticas entre moedas distintas (`BRL` + `USD`) disparam exceção em tempo de execução, garantindo a integridade dos cálculos do domínio.
3. **Fowler Allocation Engine (`allocate` & `split`):** Operações de divisão financeira (como rateio de parcelas, impostos ou porcentagens) não utilizam arredondamentos flutuantes arbitrários. O método `.allocate(ratios: [Int])` calcula a distribuição ponderada e aloca sequencialmente centavos remanescentes (*remainder cents*), assegurando a conservação exata da soma total dos centavos sem perda de valor.
4. **Sobrecarga de Operadores Matemáticos:** Implementação de `operator fun plus`, `operator fun minus`, `operator fun times` e `operator fun equals` no `type Money`.

**Razão:**
Entrega um padrão de domínio financeiro moderno, conciso e seguro para a linguagem Eiwa. Elimina bugs clássicos de arredondamento sem exigir uma engine `Decimal` pesada no runtime em C, alinhando-se aos princípios da linguagem de ser performática, pragmática e expressiva.

## ADR 46: Emissor Nativo LLVM C-API In-Memory (Compilação Ultra-Rápida & Execution Engine JIT)
**Status:** Aprovado / Em Implementação
**Data:** Julho 2026

**Contexto:**
1. O backend de transpilação para C (`src/backend/c_transpiler.zig`) do Eiwa gera código intermediário `.c` e invoca a ferramenta externa `zig cc -O0` via subprocesso shell. Embora muito portável e maduro, esse modelo envolve I/O de disco para arquivos temporários e sobrecarga de criação de processos.
2. Para alcançar compilações instantâneas (desenvolvimento com latência < 5ms) e performance de execução de estado da arte em binários finais de produção, o compilador precisa de um backend LLVM nativo e direto.

**Decisão:**
1. **Arquitetura de Backend Duplo (Zero-Risco):** O backend C permanece como fallback seguro e padrão (`--backend=c`). O novo backend LLVM (`--backend=llvm`) opera em paralelo (`src/backend/llvm_emitter/`), compartilhando 100% da esteira de Frontend (Lexer, Parser, AST e TypeChecker global).
2. **Construção de IR 100% em Memória via C-API:** Eliminar totalmente a escrita de arquivos intermediários `.ll` no disco e a invocação de ferramentas de linha de comando (`llc`, `clang`). A estrutura IR é construída diretamente na RAM utilizando a C-API do LLVM 21 (`llvm-c/Core.h`, `LLVMModuleRef`, `LLVMBuilderRef`).
3. **Execução Instantânea JIT para `eiwa run`:** O comando `eiwa run --backend=llvm` compila e executa o código diretamente da memória utilizando o LLVM OrcJIT v2 (`LLVMCreateExecutionEngineForModule`), alcançando velocidade de dev loop inferior a 5 milissegundos.
4. **Otimização `mem2reg` em Dev vs `-O3` em Release:**
   - Em modo desenvolvimento, o compilador executa apenas o pass `mem2reg` do LLVM para converter alocações de pilha (`alloca`) em registradores SSA virtuais em tempo recorde.
   - Em modo de produção (`eiwa build --release --backend=llvm`), o compilador ativa o pipeline `-O3` completo direcionado à arquitetura nativa do processador (`-mcpu=native`), Tail Call Optimization (`LLVMSetTailCall`) e alocações atômicas no Boehm GC (`GC_MALLOC_ATOMIC`) para arrays numéricos e buffers de string.

**Razão:**
Elimina 100% do I/O de disco intermediário e da sobrecarga de spawn de subprocessos. Garante velocidade de compilação instantânea no ciclo de feedback do desenvolvedor e entrega binários finais otimizados ao nível de C/C++ e Rust para produção, mantendo total estabilidade no backend C existente.



## ADR 47: Dynamic Dispatch de Contratos via Fat Pointers + Vtables por Contrato (Modelo Rust)
**Status:** Aprovado / Prioritário
**Data:** Agosto 2026

**Contexto:**
1. O sistema de composição do Eiwa (ADR 25) permite `type X : ContratoA + ContratoB`, exigindo dispatch polimórfico para múltiplos contratos por tipo concreto.
2. O backend C resolve dispatch via `EiwaTypeDescriptor` + busca linear (`eiwa_implements`/`eiwa_find_vtable` em `eiwa_runtime.h`), que escala mal com o número de contratos.
3. O backend LLVM (ADR 46) não possui nenhum mecanismo de dispatch real: apenas special cases stringly-typed para `toString`/`hashCode` (`src/backend/llvm_emitter/expression.zig`), que quebram ao encontrar métodos arbitrários de contrato (ex.: `serdeFields()` de `Serializable`, descoberto na investigação de paridade da branch `feat/llvm-backend-parity`).

**Decisão:**
Adotar **fat pointers à la Rust** como modelo canônico de dispatch de contratos:
1. **Representação:** Todo valor tipado estaticamente como `contract` é um par `(data_ptr, vtable_ptr)`. Tipos concretos permanecem sem vptr embutido (zero custo quando não polimórfico).
2. **Uma vtable por par (tipo, contrato):** Um `type` com N contratos gera N vtables constantes globais. Smart casts (`when (x) is Contrato`) trocam o par `(data, vtable)`.
3. **Aplicável aos dois backends:** O emissor LLVM passa a ter dispatch real O(1); o backend C pode migrar do modelo de busca linear para o mesmo par posteriormente, convergindo os modelos.
4. **Substituição gradual dos special cases:** Os helpers hand-emitted (`eiwa_to_string`, `eiwa_hash_string`, `eiwa_str_replace`) e os `TODO(emitter): SPECIAL CASE` em `llvm_emitter` são revisados e removidos à medida que o dispatch real cobre `Stringable`/`Hashable`.

**Razão:**
Dispatch O(1) sem busca linear, casa naturalmente com múltiplos contratos por tipo (impossível com vptr único estilo C++), é trivialmente devirtualizável pelo otimizador LLVM quando a vtable é constante conhecida, e é o modelo provado em produção pelo Rust (`&dyn Trait`). O custo é a mudança de representação de valores de contrato em todo o pipeline (coerção de argumentos, unions, coleções heterogêneas `List<Drawable>` — Phase 43), justificando uma fase dedicada.

## ADR 48: Coroutines Stackless (estilo Kotlin) + Remoção do backend C e do neco
**Status:** Aprovado / Implementado (Fases A–K)
**Data:** Agosto 2026

**Contexto:**
1. O modelo de concorrência era baseado em **neco (stackful)** — stack switching em C com registro de stacks como raízes GC (`GC_add_roots`/`GC_set_stackbottom`). Os stress tests a 20k iterações crashavam com corrupção de memória: um slot de stack não escaneado numa coleta → objeto vivo coletado → ponteiro stale.
2. A investigação (Path 1) propôs **shadow stack** no emitter LLVM; mas corrotinas stackful exigem escanear stacks que o Boehm GC não gerencia de forma confiável.
3. O backend C (`c_transpiler`) era o único suporte de compatibilidade restante — paridade total LLVM já alcançada (Phase 63/64) tornava-o dispensável.

**Decisão:**
1. **Coroutines stackless (estilo Kotlin):** funções suspensas (`task {}`/`await()`) são transformadas pelo compilador em **state machines** — objetos heap `Continuation` com `label` + locais promovidos, resumíveis via `Scheduler` Eiwa-puro (fila FIFO + timer heap). Sem stack switching: o estado suspenso é alcançável por ponteiros, coberto pela varredura conservadora do OS stack. O GC volta ao modelo do antigo backend C (provado a 200k iterações) — o crash desaparece **sem shadow stack**.
2. **Suspensão cooperativa:** `sleep`/`sleepMs`/`yield` viram pontos de suspensão reais (`switch(label)`); `await()` em task bodies state machine registra o caller como **waiter** (cadeia FIFO) e suspende, retomando quando a task aguardada completa.
3. **Remoção do backend C + neco + `@MainWrapper`:** LLVM passa a ser o **único** backend (obrigatório no build). O entry vira `main`/`eiwa_test_main` direto (sem shims de `@MainWrapper`).
4. **Scheduler em Eiwa puro:** o runtime de corrotinas é escrito em Eiwa (`src/std/coroutines.ei`); as únicas primitivas de sistema (`nanosleep`/`sched_yield`/`poll`) vêm do FFI (`lib` + `@Header`/`@Alias`). Nenhum `eiwa_scheduler.c`.
5. **Paralelismo real (thread pool / dispatchers) é PROPOSTA adiada:** requer espera cross-thread, sincronização de estado e GC multithread — redesign, não o modelo atual.

Elimina a classe inteira de bugs de raízes GC não escaneadas sem a complexidade da shadow stack; mantém o modelo de programação Kotlin (`task {}`/`await()`) sem runtime C de corrotinas; simplifica o projeto removendo o segundo backend e o mecanismo `@MainWrapper`.

## ADR 49: Motor Unificado de Diagnósticos, Internal Compiler Error (ICE) e Validação Estrita de Métodos
**Status:** Aprovado / Implementado
**Data:** Agosto 2026

**Contexto:**
1. A saída de erros do compilador apresentava ruídos, duplicações de mensagens genéricas (`Error: compilation failed (TypeError)`) e inconsistências visuais entre os passos do pipeline (Lexer, Parser, TypeChecker e Backend).
2. Quando ocorria geração de IR inválido pelo backend LLVM (ex.: incompatibilidade de tipo em instruções intrínsecas), o verificador `LLVMVerifyModule` imprimia linhas de texto soltas no stderr e **continuava a execução**, levando a tentativas de execução no JIT com ponteiros corrompidos e resultando em *Segmentation Faults* crípticos com endereços de memória brutos.
3. No `TypeChecker` (`src/core/type_checker/infer_call.zig`), chamadas de métodos de tipos (`type`) e contratos (`contract`) inferiam os nós dos argumentos mas omitiam a validação de compatibilidade (`isCompatible`), permitindo que expressões inválidas (como `String + Int`) passassem silenciosamente para o backend.

**Decisão:**
1. **Motor Centralizado de Diagnósticos (`src/core/diagnostics.zig`):**
   - Criação de formatador padrão moderno (Rust/Clang/Zig) com indicação precisa de localização `--> file.ei:line:col`, gutter com alinhamento vertical exato das barras `|`, realce por sublinhado `^` e suporte a cores ANSI respeitando `NO_COLOR` e TTY.
   - Nomes de tipos amigáveis (`formatTypeName` em `src/core/type_system.zig`) exibidos nas mensagens de erro (`'String'`, `'Int'`).
2. **Abort Imediato na Falha de Verificação LLVM (ICE):**
   - A falha em `LLVMVerifyModule` tanto no JIT quanto na compilação nativa AOT aborta imediatamente o pipeline como um **Internal Compiler Error (ICE)** com orientações para reporte de bug no repositório, impedindo execuções de memória corrompida.
3. **Validação Estrita de Argumentos no TypeChecker:**
   - Adicionadas verificações `isCompatible(expected, actual)` nas esteiras de despacho de métodos de instâncias e contratos em `infer_call.zig`, capturando erros de tipo diretamente no frontend antes da emissão de código.
4. **Crash Handler Estruturado:**
   - Detecção explícita de dereferenciamento de ponteiro nulo (endereço `0x0`) e resolução de símbolos (`dladdr`) nos rastros de pilha do JIT.

**Razão:**
Garante que todo erro de código do usuário seja diagnosticado no frontend com apontamento visual exato da linha e coluna, elimina crashes imprevisíveis por execução de IR inválido e eleva a qualidade da experiência do desenvolvedor (DX) aos padrões de compiladores de ponta.

## ADR 50: Concatenação de `String` com Primitivos e Tipos `Stringable`
**Status:** Aprovado / Implementado
**Data:** Agosto 2026

**Contexto:**
1. A assinatura do operador de concatenação em `type String` (`src/std/core.ei`) estava restrita exclusivamente a `operator fun plus(other: String): String`.
2. Como resultado, tentar concatenar uma `String` com tipos primitivos (`Int`, `Double`, `Bool`) ou objetos de domínio que implementam o contrato `Stringable` (ex.: `"Items: " + count`) resultava em erro de compilação ou exigia a chamada manual e verbosa de `.toString()` (ex.: `"Items: " + count.toString()`).

**Decisão:**
1. **Assinatura Baseada no Contrato `Stringable` na Stdlib (`src/std/core.ei`):**
   - Atualizar a declaração do operador em `type String` para:
     ```kotlin
     operator fun plus(other: Stringable): String {
         val totalLen = this.length + other.toString().length
         val buf = Standard.gcMalloc(totalLen + 1)
         Standard.sprintfInt(buf, "%s%s".ptr, this.ptr, other.toString().ptr)
         return String(buf, totalLen)
     }
     ```
   - Como `Int`, `Double`, `Bool`, `String` e tipos de usuário com `implement fun toString()` conformam ao contrato `Stringable`, a validação do TypeChecker aceita todos esses tipos naturalmente.
2. **Emissão de Código e Coerção no Backend LLVM (`src/backend/llvm_emitter/expression.zig`):**
   - Implementação de `emitValueToString` para tratar a conversão eficiente de operandos não-string em tempo de emissão:
     - `Int`: formatação via `sprintf("%lld")` em buffer alocado pelo GC.
     - `Bool`: seleção direta das constantes de string `"true"` e `"false"`.
     - `Double`: formatação via `sprintf("%g")` em buffer alocado pelo GC.
     - `Custom`: despacho para o método `{Type}_toString` correspondente.
     - Fallback dinâmico: chamada de `eiwa_to_string`.
   - Marcação de reachability em `collectCallees` (`src/backend/llvm_emitter/core.zig`) para garantir que os métodos `toString` dos operandos não sejam descartados pelo tree-shaking.

**Razão:**
Entrega ergonomia moderna de concatenação de strings (estilo Kotlin/Swift/TypeScript), mantendo a estrita segurança de tipos no frontend através do contrato `Stringable` e performance nativa otimizada no backend LLVM sem overhead desnecessário.

## ADR 51: Dispatchers & Thread Pool para Concorrência Multi-Core Real (Phase 69)
**Status:** Aprovado (Em Implementação)
**Data:** Agosto 2026

**Contexto:**
1. O Eiwa implementou com sucesso coroutines stackless (ADR 48), eliminando o neco e a necessidade de shadow stack. No entanto, a execução operava em modo cooperativo single-thread (`Dispatcher.Single`).
2. Para cargas de trabalho CPU-bound reais e servidores concorrentes de alto desempenho (como o framework `arest`), a execução em thread única exigia workarounds (como chamar `Scheduler.run()` no loop de accept) e não utilizava múltiplos núcleos da CPU.
3. Precisamos de um modelo de paralelismo multi-thread limpo, seguro para o Boehm GC, sem arquivos C adicionais e ergonomicamente espelhado no modelo de `Dispatchers` do Kotlin.

**Decisão:**
1. **`Dispatcher.Default` como Padrão Global Eager:**
   - Todo bloco `task { ... }` agora executa por padrão em `Dispatchers.Default`, sendo despachado e executado imediatamente (*eager*) em uma thread trabalhadora do pool, sem a necessidade de chamadas manuais a `.await()` ou `Scheduler.run()`.
2. **Arquitetura do Pool de Threads:**
   - O pool é dimensionado com $N = \text{max}(1, \text{Threads.numCores()})$ threads OS nativas (`pthread_create`).
   - Cada thread de worker executa um loop consumindo continuações de uma fila protegida por `Mutex` e `CondVar` em Eiwa puro (`src/std/thread.ei`), dormindo em `cond_wait` quando a fila está vazia (consumo zero de CPU).
3. **Dispatchers Customizados:**
   - `Dispatcher` é um `type` padrão em Eiwa. Usuários e bibliotecas podem instanciar pools dedicados com `Dispatchers.create(name, threads)` (ex.: pool de banco de dados ou `Dispatchers.IO` para FFI bloqueante) e executar tarefas neles via `task(dispatcher) { ... }`.
4. **Sincronização de Estado & Await Cross-Thread:**
   - O estado de término de `StackTask` utiliza operações atômicas (`AtomicBool` em `src/std/atomic.ei`).
   - Quando uma tarefa é concluída em uma thread do pool, os waiters registrados na waiter-chain são notificados e re-enfileirados no scheduler de seu dispatcher de origem, mantendo a ordem FIFO.
5. **Integração Multithread com Boehm GC:**
   - Cada thread criada no pool registra sua stack base via `GC_register_my_thread(&stack_base)` e desregistra na finalização, garantindo rastreamento conservador seguro de raízes GC entre múltiplas threads.
6. **Zero Runtime em C:**
   - Todas as primitivas de threading e sincronização residem na biblioteca padrão em Eiwa puro (`src/std/thread.ei`, `src/std/atomic.ei`), usando blocos FFI `lib NativeThread` e `lib NativeAtomic`.

**Razão:**
Entrega paralelismo real multi-core com speedup proporcional ao número de núcleos para tarefas CPU-bound, elimina o acoplamento do loop de eventos em servidores web e mantém total elegância idiomática no padrão Kotlin/Eiwa.

## ADR 52: Case-Sensitive Module Imports & Cross-Platform Filesystem Safety
**Status:** Aprovado
**Data:** Agosto 2026

**Contexto:**
1. O macOS (APFS) e o Windows (NTFS) são sistemas de arquivos *case-insensitive* por padrão, enquanto o Linux (ext4/btrfs) é estritamente *case-sensitive*.
2. Isso causava bugs em que desenvolvedores no macOS importavam módulos com maiúsculas/minúsculas divergentes do nome real no disco (ex.: `import { Person } from ".samples.Person"` quando o arquivo era `samples/person.ei`). O código funcionava localmente no Mac, mas quebrava com `FileNotFound` no Linux/CI.
3. Compiladores modernos (como Go com validação de pacotes e TypeScript com `forceConsistentCasingInFileNames`) impõem verificação estrita de casing em todos os sistemas operacionais.

**Decisão:**
1. **Verificação Estrita de Casing em Tempo de Compilação (`case_checker.zig`):**
   - Durante a resolução de cada módulo (`import` statement e carregamento de dependências), o `eiwac` inspeciona a listagem de entradas do diretório pai no disco via `std.Io.Dir.iterate()`.
   - O compilador compara o nome do arquivo solicitado com o nome exato retornado pelo sistema de arquivos.
   - Caso haja divergência de maiúsculas/minúsculas (ex.: importou `.Person` mas o arquivo é `person.ei`), a compilação é **rejeitada imediatamente**, mesmo no macOS e Windows, com mensagem descritiva apontando o arquivo real no disco.
2. **Convenção Canônica de Nomenclatura:**
   - Nomes de arquivos e caminhos de módulos em Eiwa devem ser em `snake_case` / `lowercase` (ex.: `person.ei`, `http_client.ei`).
   - Nomes de tipos, contratos e skills são em `PascalCase` (`type Person`, `contract Drawable`), mantendo clara a separação entre o tipo exportado e o arquivo de origem.

**Razão:**
Garante paridade total entre ambientes de desenvolvimento locais (macOS/Windows) e ambientes de produção/CI (Linux), prevenindo falhas silenciosas de importação e impondo consistência arquitetural na base de código.

## ADR 53: Hoisting de `await` em Atribuições e Proibição Estática de `return` em Lambdas / Tasks
**Status:** Aprovado
**Data:** Agosto 2026

**Contexto:**
1. **Atribuições com `await`:** O transformador de corotinas stackless (`coroutines_transform.zig`) suportava hoisting de expressões com `.await()` em `var_decl`, `return_stmt`, `if_expr` e `while_stmt`. No entanto, expressões de reatribuição (`assignment`, ex.: `x = inner.await() + x` ou `x = t.await()`) não realizavam o hoisting, forçando a criação de variáveis temporárias intermediárias manuais (`val res = inner.await(); x = res + x`).
2. **`return` dentro de Lambdas e Tasks:** No Eiwa, o valor de retorno de lambdas e blocos `task { ... }` é definido estritamente pela sua expressão final (*trailing expression*). No entanto, o `TypeChecker` não validava o uso de instruções `return` dentro de lambdas, permitindo que um `return value` compilasse silenciosamente em corotinas e causasse saída prematura da função de máquina de estados `resume()` sem assinalar `done = true`, travando `.await()` indefinidamente.

**Decisão:**
1. **Hoisting Automático em Nós `.assignment`:**
   - O `hoistAwaitsWalk` e o `rewriteStatement` passam a cobrir o nó `.assignment`.
   - Expressões contendo `.await()` à direita de uma atribuição são desaçucaradas em variáveis temporárias no preâmbulo (`val __awaitN = expr.await()`), e a atribuição final é reescrita para consumir o valor resolvido (`x = __awaitN + x`).
   - Atribuições diretas de tarefas (`t2 = task { ... }`) preservam corretamente a mutabilidade do identificador alvo (`is_mut`).
2. **Proibição Estática de `return` em Lambdas e Tasks (`Scope.is_lambda_boundary`):**
   - O `Scope` do compilador agora registra a flag `is_lambda_boundary = true` em lambdas e closures.
   - Em `inferReturnStmt` (`infer_stmt.zig`), o compilador inspeciona a hierarquia de escopos. Caso um `return` seja detectado dentro de uma lambda ou bloco `task {}` antes de uma fronteira de função real (`fun`), a compilação é **rejeitada imediatamente com erro estático**:
     ```
     error: 'return' is not allowed inside a lambda or task block. Use the trailing expression to return a value.
     ```

## ADR 54: Suspensão em Laços `for` e Inicialização Universal de Campos na State Machine
**Status:** Aprovado
**Data:** Agosto 2026

**Contexto:**
1. **Laços `for` com Suspensão:** Anteriormente, o motor de corrotinas stackless (`coroutines_transform.zig`) suportava pontos de suspensão verdadeira (`sleepMs`, `yield`, `await`) dentro de laços `while`, mas laços `for` contendo suspensão falhavam porque não eram divididos em estados independentes da máquina de estados (`MachineState`).
2. **Campos da Continuação (`body_fields`):** Para sobreviver a suspensões entre estados, variáveis locais de uma tarefa são promovidas a campos de propriedade da classe gerada `__TaskBlockN`. Tipos primitivos (`Int`, `Double`, `Bool`, `String`) possuem valores zero padrão (`0`, `0.0`, `false`, `""`), mas tipos por referência (`NativeArray`, `List`, `Map`, classes de usuário) não possuíam inicializadores estáticos conhecidos a priori, o que gerava incompatibilidades no TypeChecker ou demandava checagens hardcoded e frágeis por nome de classe.

**Decisão:**
1. **Desaçucaramento Automático de `for` Suspensivo para `while`:**
   - Quando um laço `for` dentro de uma tarefa contém chamadas de suspensão verdadeira ou `await`, o transformador converte o laço estruturalmente para:
     ```
     val __for_arr = iterable.items // ou iterable
     var __for_i = 0
     val __for_len = __for_arr.length
     while (__for_i < __for_len) {
         val item = __for_arr[__for_i]
         ... corpo com sleep/yield/await ...
         __for_i = __for_i + 1
     }
     ```
   - O `while` gerado é então dividido naturalmente pela máquina de estados em estados de transição (`label = cond`, `label = body`, `label = increment`).
2. **Modelo Universal de Inicialização de Campos de Referência (`T? = null`):**
   - Elimina qualquer caso especial hardcoded para classes específicas da biblioteca padrão (como `List` ou `StackTask`).
   - Qualquer variável local promovida cujo tipo seja por referência é registrada na classe de continuação como um campo anulável (`T?`) com inicializador padrão `null` (`body_fields: is_nullable = true, init = null`).
3. **Desembrulho Automático em Leituras Promovidas:**
   - No `rewritePromotedRefs`, ao reescrever acessos a membros em receptores promovidos (`this.<campo>`), o compilador gera o desembrulho seguro (`this.<campo>!!.<membro>`) sempre que a variável original era não-nula, garantindo plena segurança estática no TypeChecker sem necessidade de código defensivo em user-space.

**Razão:**
Elimina casos especiais e suposições frágeis do compilador, unificando a promoção de variáveis locais na State Machine de forma matemática e consistente com o sistema de tipos anuláveis do Eiwa, além de permitir o uso livre de laços `for` idiomáticos com qualquer chamada assíncrona ou suspensiva.

---

## ADR 55: Tratamento de `try / catch` Cruzando Estados de Suspensão na State Machine
**Status:** Aprovado
**Data:** Agosto 2026

**Contexto:**
Quando um bloco `try / catch` envolvia operações suspensivas (`sleepMs()`, `yield()`, `.await()`) dentro de uma corrotina `task {}`, o builder de máquinas de estados (`machineBuildStmt` em `src/core/coroutines_transform.zig`) não possuía suporte nativo a nós `.try_stmt`, rejeitando a compilação com `error.SuspendInOperand`.
Além disso, em sistemas que utilizam `setjmp`/`longjmp` para exceções (como o runtime LLVM do Eiwa), quadros de exceção (`EiwaExceptionFrame`) alocados na pilha C são desenrolados quando a função `resume()` suspende e retorna ao scheduler. Se um quadro de exceção permanecesse aberto durante a suspensão, o ponteiro na lista global `eiwa_exception_stack` apontaria para memória de pilha desfeita.

**Decisão:**
1. **Isolamento de Exceções por Estado (`machineBuildTryStmt`):**
   - Para cada manipulador `catch` associado ao `try_stmt`, o compilador constrói os estados correspondentes do corpo do `catch`, terminando na transição para o estado posterior ao `try` (`this.label = after`).
   - Para o corpo do `try`, os estados da máquina de estados são gerados sequencialmente.
   - Cada estado individual gerado a partir do corpo do `try` tem suas instruções síncronas envolvidas por um `try_stmt` sintético local.
2. **Separação Estrita entre Instruções do Usuário e Terminadores:**
   - Instruções de suspensão (`Scheduler.sleep()`, `Scheduler.yield()`) e instruções de retorno (`return`) são mantidas **fora** do bloco `try` local do estado.
   - Isso garante que a suspensão retorne ao escalonador com o registro de pilha de exceções limpo (`eiwa_exception_stack` desempilhado).
3. **Desvio Automático para Estados de Manipulação (`catch`):**
   - Caso qualquer instrução síncrona dentro do estado lance uma exceção durante a execução de `resume()`, o `catch` sintético local captura o objeto de exceção, armazena-o no campo de propriedade promovido (`this.<vname> = <vname>`) e redireciona a máquina de estados para o rótulo do manipulador de catch correspondente (`this.label = catch_label`).
   - O loop de despacho `while (true)` do `resume()` avança imediatamente para o estado de tratamento do erro.

**Razão:**
Permite tratamento transparente, determinístico e robusto de exceções através de quaisquer fronteiras assíncronas e pontos de suspensão cooperativa sem corrupção da pilha C ou vazamento de quadros de `setjmp`.

---

## ADR 56: I/O Waiters Cooperativos no TaskScheduler (`EventLoop.waitReadable` / `waitWritable`)
**Status:** Aprovado
**Data:** Agosto 2026

**Contexto:**
1. No modelo de corrotinas stackless multi-thread (ADR 51), chamadas a operações de rede bloqueantes (`accept()`, `read()`, `write()`) dentro de uma `task {}` bloqueavam a thread do sistema operacional (OS thread) no kernel, impedindo que outros trabalhos e timers fossem processados no mesmo worker.
2. No framework `arest`, o loop do servidor precisava recorrer a bridges provisórios (ex: polling não-bloqueante combinado com `sleepMs(1)` ou `Scheduler.run()`), consumindo CPU desnecessariamente e não integrando diretamente os eventos de socket ao scheduler.
3. Precisamos de um modelo limpo onde operações de socket suspendam a corrotina registrando-a como um "I/O Waiter" no `TaskScheduler`, liberando a thread para processar outras tarefas e acordando a continuação assim que o descritor estiver pronto.

**Decisão:**
1. **Primitivas de Suspensão de I/O na State Machine:**
   - As chamadas `EventLoop.waitReadable(fd)` e `EventLoop.waitWritable(fd)` são reconhecidas como primitivas de suspensão pelo transformador de corrotinas (`src/core/coroutines_transform.zig`), sendo reescritas para `Scheduler.waitReadable(this, fd)` e `Scheduler.waitWritable(this, fd)` com avanço de estado e retorno ao scheduler.
2. **Fila de I/O Waiters no `TaskScheduler` (`src/std/coroutines.ei`):**
   - Adicionada a lista encadeada `ioHead: IoWaiterNode?`, registrando o descritor de arquivo (`fd`), a máscara de eventos (`POLLIN = 1`, `POLLOUT = 4`), a continuação (`cont`) e o próximo nó.
   - Implementado o método `pollIoLocked(timeoutMs)` que monta a tabela `struct pollfd`, destrava o mutex durante a chamada de sistema `poll()`, e reinsere na fila pronta (`head`/`tail`) todas as corrotinas cujos descritores reportaram prontidão (`revents != 0`).
3. **Eleição de Líder e Polling Livre de Deadlock:**
   - Adicionada a flag de controle `isPolling: Bool` no `TaskScheduler`, garantindo que apenas uma thread de worker execute a chamada `poll()` por vez. As demais threads aguardam no `CondVar`.
   - Quando `ioHead` contém descritores pendentes, as threads de worker realizam uma espera limitada (2ms) avançando o relógio virtual `this.now` e verificando I/O e timers simultaneamente, garantindo despertar imediato sem loops de consumo alto de CPU (busy-wait).
4. **Métodos de Rede Nativos Cooperativos (`src/std/net.ei`):**
   - As funções `TCPServer.accept()`, `Socket.read()` e `Socket.write()` foram anotadas com `@Suspend` e integradas nativamente a `EventLoop.waitReadable` e `waitWritable`.

**Razão:**
Permite servidores TCP e clientes de rede de alto desempenho em Eiwa operando sobre I/O cooperativo não-bloqueante em pool multi-core real sem qualquer dependência de runtimes C externos.

---

## ADR 57: Cross-Compilation (`--target`) e Especialização de Plataforma Declarativa
**Status:** Aprovado / Implementado
**Data:** Agosto 2026

**Contexto:**
1. O compilador Eiwa compilava exclusivamente para a máquina e sistema operacional host nativo (`builtin.target`).
2. Para criar utilitários de linha de comando portáveis e servidores web prontos para produção em containers Linux e executáveis Windows a partir do macOS/Linux (estilo Go, Rust, Crystal), era indispensável suportar compilação cruzada *out-of-the-box* via flag `--target`.
3. Diferentes sistemas operacionais possuem chamadas e APIs nativas distintas (ex.: `sysconf` e `poll` em POSIX vs `WSAPoll`, `GetSystemInfo` e `_popen` em Windows). Uma abordagem baseada em sufixos mágicos de arquivos (ex.: `_linux.ei`, `_windows.ei`) é propensa a erros acidentais de digitação e fragmenta o código.

**Decisão:**
1. **Sintaxe de Especialização Direta na Declaração:**
   - O Eiwa introduz anotações de plataforma nos nós `object`, `lib` e `type`:
     ```kotlin
     object("windows") CurrentAudioDriver : AudioDriver { ... }
     object("linux", "macos") CurrentAudioDriver : AudioDriver { ... }
     lib("posix") NativeProcess { ... }
     lib("windows") NativeProcess { ... }
     ```
2. **Resolução com Fallback Universal:**
   - Uma declaração sem discriminador de plataforma (ex.: `object CurrentAudioDriver : AudioDriver { ... }`) atua como fallback padrão.
   - O TypeChecker seleciona a declaração especializada caso o alvo ativo corresponda à tag de plataforma; caso contrário, seleciona a declaração universal fallback.
3. **Resolução de Targets e Aliases Simplificados (`src/core/target.zig`):**
   - Suporte a aliases amigáveis como `--target windows` (`x86_64-windows-gnu` / COFF), `--target linux` (`x86_64-linux-musl` / ELF), `--target linux-arm64` (`aarch64-linux-musl`), `--target macos` (`arm64-apple-darwin` / `x86_64-apple-darwin`), `--target wasm` (`wasm32-wasi`), além de triples completas.
   - Sem a flag `--target`, o compilador preserva 100% de retrocompatibilidade utilizando o host nativo.
4. **Backend LLVM & Linker Cruzado Autocontido (`src/backend/llvm_emitter/core.zig`):**
   - Configuração de triples canônicas e data layouts por módulo antes da otimização e geração de código.
   - Inclusão automática de símbolos CRT requeridos por plataforma (ex.: `_fltused = 1` no Windows).
   - Linking cruzado inteligente via `zig cc -target <triple>`.
   - Suporte a ambientes sem Boehm GC externo durante cross-compilation, mapeando alocações de heap para a libc padrão (`malloc`/`calloc`/`realloc`) e fornecendo stubs no-op seguros de ciclo de vida do GC.

**Razão:**
Permite aos desenvolvedores distribuir binários estáticos portáveis para qualquer sistema operacional de forma simples, declarativa, segura e sem atrito com dependências externas.

---

## ADR 58: Pipeline de Compilação Incremental — Binary Cache + Split Emission (Go-like `eiwa run`/`build`)
**Status:** Aprovado / Implementado
**Data:** Agosto 2026
**Referência:** `docs/perf-plan-incremental-cache.md` (plano vivo com status tracker e benchmarks)

**Contexto:**
1. `eiwa run`/`eiwa build` recompilavam **todo o programa** a cada execução — stdlib, dependências git (`~/.eiwa/repository`), e o código do projeto — do zero. Um `run` de um serviço simples custava ~2.8s, muito acima do padrão Go (`go run` ~0.1-0.3s).
2. O compilador `eiwac` era construído em modo **Debug** por padrão (`zig build`), tornando todas as fases do compilador várias vezes mais lentas que um binário otimizado.
3. O backend LLVM emitia **um único módulo LLVM** com pruning por reachability — correto, mas impossível de cachear por unidade de compilação: qualquer mudança invalidava tudo.

**Decisão:**

1. **Compiler build padrão = ReleaseSafe** (`build.zig`): `zig build` produz `eiwac` otimizado (safety checks on), com `-Doptimize=Debug` disponível para desenvolvimento do compilador. Sozinho, ~2.2x de speedup em todas as compilações.

2. **Binary cache full-program (A0/A1):** `eiwac build` calcula um hash de conteúdo cobrindo **todo o closure de imports** (paths + sources), o binário do `eiwac` em si (que embute a stdlib via `std_modules`), o triple, flags de codegen e `EIWA_BASELINE_CPU`. Hit → copia o binário cacheado (`~/.eiwa/cache/bin/<sha256>`) e pula o backend inteiro. `run --aot` (usado por `eiwa run` de projetos) compila-if-stale e executa o binário — warm `run` ≈ **0.01-0.1s**.

3. **Split emission em 2 unidades (A2/A3):** o backend passa a emitir **dois objetos LLVM** em vez de um módulo único:
   - **Deps unit** — std + dependências `--module-path` (ex.: `~/.eiwa/repository`), emitida uma vez e cacheada em `~/.eiwa/cache/objects/<hash>.o`. Chave = sources de deps + compilador + flags + **assinatura do pool de monomorfização** (nomes ordenados de `classes_ast` — ver razão abaixo).
   - **Entry unit** — código do projeto, re-emitida a cada build e linkada contra o objeto de deps via `cc` (`linkObjects`).
   - Rebuild com fonte do projeto alterada cai de ~0.65s para **~0.27s** (deps.o reutilizado).

4. **Protocolo de ownership entre unidades:** define-se qual unidade define cada símbolo para evitar colisões de link:
   - **Estado mutável compartilhado** (`eiwa_exception_stack`, `eiwa_active_exception`, `eiwa_argc/argv`), GC ctor (`llvm.global_ctors`), argv support, main shim e top-level statements → **entry unit apenas** (instância única).
   - **Helpers/intrinsics/lambdas** (`eiwa_to_string`, `GC_MALLOC`, `lambda_anon_N`...) → **linkage `internal`** (cópia privada por objeto).
   - **Types/funções/vtables** → a unidade dona define; as outras declaram `extern`. Ctors de `type` (emitidos inline em `declareType`), enums, globais de objetos e vtables seguem a mesma regra.
   - **Vtables de contratos**: cada unidade **pré-declara o conjunto completo de vtables do programa** (`constant`, sem initializer) para que `when (x) is Contract` (que itera todos os globals `_vtable` do módulo) veja todas em toda unidade; `isRealVtable` aceita declarações `extern` constantes.
   - **Stub pass**: só stubam símbolos que a própria unidade possui; a entry ainda stuba "synthetics" de nenhum módulo, mas **nunca** o que o deps.o define.
   - **Pool de monomorfização** (`classes_ast`): instâncias genéricas pertencem à entry unit; deps referenciam `extern`.

5. **Assinatura do pool no hash do deps.o (correção de instabilidade):** métodos de skill genéricos (ex.: `equals` de coleções fazendo `is List<T>`) referenciam vtables de **todas** as instâncias `List<X>` do programa — conjunto dirigido pelo código do entry. Sem isso, um deps.o cacheado de um build com `List<Dependency>` quebrava (undefined vtable) num build onde o entry não instancia mais `Dependency`. Incluir os **nomes ordenados de `classes_ast`** na chave do deps.o invalida exatamente quando o conjunto de tipos instanciados muda.

6. **Escape hatches:** `--no-cache` desativa o cache (fallback legacy de módulo único); `EIWA_CACHE_DIR` sobrepõe `~/.eiwa/cache`.

**Resultados medidos (`example/home`, Apple Silicon):**

| Cenário | Antes | Depois |
|---------|-------|--------|
| `eiwa build` inalterado | 2.78s | **0.01-0.02s** |
| `eiwa run` → serviço no ar | ~2.8s + JIT | **≤0.1s** |
| Build com fonte do projeto alterada | 2.78s | **0.27s** |
| Guardrail `eiwac test` (95 testes) | 100.76s | **55-57s** |

**Razão:**
- **Go-like warm dev loop**: a maioria dos dev-loops altera só o código do projeto; o deps.o cacheado torna o rebuild dominado pelo link (~0.1s) + entry emit (~0.1s) + typecheck (~0.05s) = **~0.27s**.
- **Dois units em vez de N (A4)**: as unidades deps×entry capturam ~90% do ganho (deps dominam o código emitido e mudam raramente) com superfície de link mínima. N-way por módulo fica adiado (reavaliar se o projeto crescer).
- **A5 (cache de typecheck) medido e adiado**: typecheck = ~49ms (18%) do rebuild; serializar AST+symbols inter-module não justifica o risco para ~0.05s. Piso real = emit+link (~210ms).
- **`internal` em vez de `linkonce_odr`**: helpers/lambdas nunca cruzam unidades — `internal` é mais simples e permite dead-strip. `linkonce_odr` voltaria a ser necessário se A4 (N-way) for implementado.






