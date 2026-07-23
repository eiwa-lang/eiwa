# Getting Started (Setup & Dependencies)

Para desenvolver ou compilar o motor da linguagem **Aether**, você precisará preparar o seu ambiente de desenvolvimento com algumas ferramentas primordiais. Por ser construído em **Zig** e transpilado para **C**, o Aether exige uma *toolchain* de sistemas instalada.

## 1. Dependências do Sistema

### Zig (Compilador Principal)
O código fonte do Aether é escrito em Zig. Você precisa do compilador do Zig para "compilar o nosso compilador".
- **Versão Suportada:** 0.16.0+
- **Instalação Oficial:** [https://ziglang.org/download/](https://ziglang.org/download/)
- Verifique a instalação rodando: `zig version`

### Boehm Garbage Collector (Gestão de Memória)
Como o Aether gera código C que aloca memória dinamicamente, usamos o Boehm-Demers-Weiser GC para rastrear e limpar a memória (evitando *Memory Leaks* crônicos). Sem isso, o compilador vai falhar acusando a ausência da flag `-lgc`.

**Instalação no Linux (Ubuntu/Debian):**
```bash
sudo apt update
sudo apt install libgc-dev
```

**Instalação no macOS:**
```bash
brew install bdw-gc
```

**Instalação no Windows (MSYS2 / vcpkg):**
```bash
# MSYS2 MinGW-w64:
pacman -S mingw-w64-x86_64-gc

# Ou vcpkg:
vcpkg install bdw-gc
```

---

## 2. Compilando o CLI do Aether
Com as dependências instaladas, acesse a raiz do projeto e construa o CLI usando o *build system* nativo do Zig:

```bash
zig build
```
Esse comando vai compilar toda a engine (Lexer, Parser, TypeChecker e C Transpiler) e colocar o binário executável na pasta `zig-out/bin/aether`.

---

## 3. Comandos Úteis do Aether

Após gerar o executável do Aether, você pode rodar os seguintes comandos:

### `aether run <arquivo.ae>`
*Foco: Desenvolvimento Rápido.*
Lê o código Aether, transpila para C intermediário, invoca o `zig cc` (C compiler nativo embutido no Zig) para gerar um binário temporário, executa imediatamente e depois apaga todos os traços no disco. O tempo de resposta é quase instantâneo.

### `aether build <arquivo.ae>`
*Foco: Geração de Artefato Estático.*
Lê o código, transpila para C, compila o binário e deixa ele pronto para distribuição na sua pasta atual, apagando apenas os arquivos temporários de compilação em C.
