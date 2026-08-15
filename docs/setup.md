# Getting Started (Setup & Dependencies)

Para desenvolver ou compilar o motor da linguagem **Eiwa**, você precisará preparar o seu ambiente de desenvolvimento com algumas ferramentas primordiais. Por ser construído em **Zig** e compilar via **LLVM**, o Eiwa exige uma *toolchain* de sistemas instalada.

## 1. Dependências do Sistema

### Zig (Compilador Principal)
O código fonte do Eiwa é escrito em Zig. Você precisa do compilador do Zig para "compilar o nosso compilador".
- **Versão Suportada:** 0.16.0+
- **Instalação Oficial:** [https://ziglang.org/download/](https://ziglang.org/download/)
- Verifique a instalação rodando: `zig version`

### Boehm Garbage Collector (Gestão de Memória)
Como o Eiwa gera código que aloca memória dinamicamente, usamos o Boehm-Demers-Weiser GC para rastrear e limpar a memória (evitando *Memory Leaks* crônicos). Sem isso, o compilador vai falhar acusando a ausência da flag `-lgc`.

### LLVM 21+ (Emissor Nativo & JIT)
O backend nativo do Eiwa é o **LLVM**: compila a AST resolvida para LLVM IR em memória, executa via JIT para loops de desenvolvimento instantâneos e otimiza com `-O3` para binários de produção. O sistema precisa do **LLVM 21+** instalado com os arquivos de cabeçalho (`llvm-c`).

**Instalação das Dependências no Linux (Ubuntu/Debian):**
```bash
sudo apt update
sudo apt install libgc-dev llvm-21-dev
```

**Instalação no macOS:**
```bash
brew install bdw-gc llvm@21
```

**Instalação no Windows (MSYS2 / vcpkg):**
```bash
# MSYS2 MinGW-w64:
pacman -S mingw-w64-x86_64-gc mingw-w64-x86_64-llvm

# Ou vcpkg:
vcpkg install bdw-gc
```

---

## 2. Compilando o CLI do Eiwa
Com as dependências instaladas, acesse a raiz do projeto e construa o CLI usando o *build system* nativo do Zig:

```bash
zig build
```
Esse comando vai compilar toda a engine (Lexer, Parser, TypeChecker e o backend LLVM) e colocar o binário executável na pasta `zig-out/bin/eiwa`.

---

## 3. Comandos Úteis do Eiwa

Após gerar o executável do Eiwa, você pode rodar os seguintes comandos:

### `eiwa run <arquivo.ei>`
*Foco: Desenvolvimento Rápido.*
Lê o código Eiwa, compila para LLVM IR em memória e executa imediatamente via JIT — sem arquivos intermediários no disco. O tempo de resposta é quase instantâneo.

### `eiwa build <arquivo.ei>`
*Foco: Geração de Artefato Estático.*
Lê o código, emite LLVM IR, passa pelo pipeline de otimização do LLVM (`-O3`) e gera um binário nativo estático pronto para distribuição.
