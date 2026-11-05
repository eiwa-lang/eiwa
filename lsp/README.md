# eiwa-lsp — Eiwa Language Server (written in Eiwa)

JSON-RPC language server for the Eiwa programming language (LSP 3.17),
transported over stdio with `Content-Length` framing. The server itself is
100% Eiwa (`lsp/src/`); diagnostics are produced by `eiwac check`.

## Features

| Capability | Status |
|---|---|
| `initialize`, `shutdown`, `exit` | ✅ |
| `textDocument/didOpen|didChange|didSave|didClose` (full sync) | ✅ |
| `textDocument/publishDiagnostics` (via `eiwac check` on save/open) | ✅ |
| `textDocument/hover` (same-file declaration preview) | ✅ |
| `textDocument/completion` (keywords + file symbols) | ✅ |
| `textDocument/definition` (same-file goto) | ✅ |
| `textDocument/documentSymbol` | ✅ |
| Cross-file goto / workspace symbols | follow-up |
| Unsaved-buffer diagnostics overlay | follow-up (checks the file on disk) |
| TCP transport (`--port`) | follow-up (stdio only for now) |

## Build & run

```bash
# from eiwa-lang/
./bin/eiwa build          # inside lsp/  →  lsp/bin/eiwa-lsp
# or directly:
./bin/eiwac build -o lsp/bin/eiwa-lsp lsp/src/main.ei

# unit tests (pure-Eiwa analysis + diagnostic parsing; cli-style layout)
./bin/eiwac test lsp/test
```

The server speaks LSP on stdin/stdout. `EIWAC` env overrides the compiler
binary used for diagnostics (default: `eiwac` on `PATH`).

## Editor setup

**Neovim (`nvim-lspconfig`):**

```lua
vim.api.nvim_create_autocmd("FileType", {
  pattern = "eiwa",
  callback = function()
    vim.lsp.start({ name = "eiwa-lsp", cmd = { "/path/to/eiwa-lsp" } })
  end,
})
```

**Zed** — user settings (`~/.config/zed/settings.json`):

```json
{ "lsp": { "eiwa-lsp": { "binary": { "path": "/path/to/eiwa-lsp" } } } }
```

**VS Code** — any generic LSP client extension (e.g. `llvm-vs-code-extensions.vscode-clangd`
style configured for Eiwa, or `trixnz.vscode-lsp-cilent`), launched as
`eiwa-lsp` for language id `eiwa` (`.ei` files).

## Architecture

```
lsp/src/main.ei          stdio loop (read → dispatch → respond)
lsp/src/transport.ei     Content-Length framing (Stdin.readLine/readExact)
lsp/src/server.ei        JSON-RPC dispatch + hover/completion/definition/symbols
lsp/src/store.ei         open documents (uri → text/version)
lsp/src/analysis.ei      dependency-free text scanner (decls, words, keywords)
lsp/src/diagnostics.ei   eiwac check → LSP Diagnostic[] (errors + warnings)
lsp/test/analysis_test.ei  unit tests (run: `eiwac test lsp/test`)
```

`Stdin` lives in `src/std/io.ei`, backed by the tiny
`src/runtime/third_party/eiwa_stdio/stdio_helpers` trampolines that expose
the process `stdin` stream (a `lib` block cannot name the `stdin` macro
directly). `eiwac check` (`src/main.zig`) type-checks without codegen so
per-save diagnostics cost ~0.05s instead of a full LLVM build.
