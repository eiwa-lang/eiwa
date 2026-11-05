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
| `textDocument/hover` (same-file + cross-file, receiver-aware) | ✅ |
| `textDocument/completion` (keywords + file symbols) | ✅ |
| `textDocument/definition` (same-file + imports + implicit stdlib + `Tipo.metodo` + import paths; synthesized `toString`/`equals`/`hashCode` → their contract methods) | ✅ |
| `textDocument/implementation` (same-file + imported modules: `implement fun` / types per contract) | ✅ |
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

# end-to-end protocol test (stdio JSON-RPC against a scratch project)
EIWAC=$PWD/bin/eiwac python3 lsp/test/e2e_lsp.py lsp/bin/eiwa-lsp
```

The server speaks LSP on stdin/stdout. `EIWAC` env overrides the compiler
binary used for diagnostics (default: `eiwac` on `PATH`).

`std.*` go-to-definition resolves against `eiwac --print-std-dir`
(like `rustc --print sysroot` / `go env GOROOT`); `EIWA_SRC` overrides it
manually (rust-analyzer `RUST_SRC_PATH` style). No configuration needed —
installed toolchains ship `src/` next to `bin/`.

Ecosystem packages resolve like the `eiwa` CLI: `path:` deps against the
project root, pinned (`commit:`) deps against `~/.eiwa/repository`,
unpinned deps against whichever checkouts contain the module.
`EIWA_MODULE_PATH` (colon-separated, like the compiler's `--module-path`)
adds extra roots.

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
lsp/src/server.ei        JSON-RPC dispatch + hover/completion/definition/implementation/symbols
lsp/src/store.ei         open documents (uri → text/version)
lsp/src/analysis.ei      dependency-free text scanner (decls, members, containers, imports)
lsp/src/index.ei         stdlib symbol index built from the shipped sources
lsp/src/deps.ei          project deps (eiwa.yaml/freeze) + module-path resolution
lsp/src/toolchain.ei     locates eiwac + stdlib (`--print-std-dir`, `EIWA_SRC`/`EIWAC` overrides)
lsp/src/diagnostics.ei   eiwac check → LSP Diagnostic[] (errors + warnings)
lsp/test/analysis_test.ei  unit tests (run: `eiwac test lsp/test`)
lsp/test/server_test.ei    server dispatch + store unit tests
lsp/test/e2e_lsp.py        stdio protocol test (run: `python3 lsp/test/e2e_lsp.py lsp/bin/eiwa-lsp`)
```

Design rule: no hand-written name tables. Implicit names (`println`,
`File`, `parseJson`…), synthesized-method targets (`toString` →
`Stringable`) and module locations are all derived at startup by scanning
the real `std/*.ei` found via `eiwac --print-std-dir`.

Lookup order is lexical scope, outermost first: same file, then explicit
imports, then implicit top-level declarations, then an imported
module's members, then the synthesized contract method. Files are visited
in alphabetical order so ties resolve deterministically; only top-level
declarations participate in implicit lookup, so bare calls never land on
a coincidental same-named member.
```

`Stdin` lives in `src/std/io.ei`, backed by the tiny
`src/runtime/third_party/eiwa_stdio/stdio_helpers` trampolines that expose
the process `stdin` stream (a `lib` block cannot name the `stdin` macro
directly). `eiwac check` (`src/main.zig`) type-checks without codegen so
per-save diagnostics cost ~0.05s instead of a full LLVM build.
