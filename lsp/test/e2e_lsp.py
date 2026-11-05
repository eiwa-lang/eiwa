#!/usr/bin/env python3
"""End-to-end test for eiwa-lsp over stdio (LSP 3.17 JSON-RPC framing).

Usage:
    python3 lsp/test/e2e_lsp.py [path/to/eiwa-lsp]

Requires the server binary (build it first):
    ./bin/eiwac build -o lsp/bin/eiwa-lsp lsp/src/main.ei

Requires `eiwac` on PATH (or EIWAC set) for diagnostics and the std probe.
Exits non-zero on the first failed assertion.
"""

import json
import os
import subprocess
import sys
import tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
BIN = sys.argv[1] if len(sys.argv) > 1 else os.path.join("lsp", "bin", "eiwa-lsp")
if not os.path.isabs(BIN):
    BIN = os.path.join(ROOT, BIN)
if not os.path.exists(BIN):
    sys.exit(f"missing server binary: {BIN} (build it with: ./bin/eiwac build -o {BIN} lsp/src/main.ei)")
if "EIWAC" not in os.environ:
    eiwac = os.path.join(ROOT, "bin", "eiwac")
    if sys.platform == "win32":
        eiwac += ".exe"
    if os.path.exists(eiwac):
        os.environ["EIWAC"] = eiwac
    else:
        sys.exit("need eiwac on PATH or EIWAC set")

MAIN = """import { helper } from "util"
import { parseJson } from "std.json"

type Counter {
    fun inc(): Int {
        return 1
    }
}

contract Drawable {
    fun draw()
}

init {
    val c = Counter()
    println(c.inc())
    println(helper())
    val n = 42
    println(n.toString())
    val v = parseJson("{}")
    println(v)
}
"""

UTIL = """fun helper(): Int {
    return 7
}
"""

IMPL = """contract Drawable {
    fun draw()
}
type Button : Drawable {
    implement fun draw() {
    }
}
type Label : Drawable {
    implement fun draw() {
    }
}
"""

BAD = """init {
    val x: Int = "hello"
}
"""

FAILS = []


def check(name, cond, extra=""):
    print(("PASS " if cond else "FAIL ") + name + (f" :: {extra}" if extra and not cond else ""))
    if not cond:
        FAILS.append(name)


class Client:
    def __init__(self):
        self.proc = subprocess.Popen(
            [BIN], stdin=subprocess.PIPE, stdout=subprocess.PIPE, cwd=ROOT
        )

    def send(self, msg):
        body = json.dumps(msg).encode()
        self.proc.stdin.write(b"Content-Length: %d\r\n\r\n" % len(body) + body)
        self.proc.stdin.flush()

    def read_msg(self):
        headers = {}
        while True:
            line = b""
            while not line.endswith(b"\r\n"):
                chunk = self.proc.stdout.read(1)
                if not chunk:
                    raise EOFError("server closed stdout")
                line += chunk
            line = line.decode().strip()
            if line == "":
                break
            k, v = line.split(":", 1)
            headers[k.strip().lower()] = v.strip()
        size = int(headers["content-length"])
        body = b""
        while len(body) < size:
            body += self.proc.stdout.read(size - len(body))
        return json.loads(body)

    def request(self, rid, method, params):
        self.send({"jsonrpc": "2.0", "id": rid, "method": method, "params": params})
        return self.read_msg()["result"]

    def notify(self, method, params):
        self.send({"jsonrpc": "2.0", "method": method, "params": params})

    def close(self):
        self.send({"jsonrpc": "2.0", "id": 999, "method": "shutdown", "params": {}})
        self.read_msg()
        self.send({"jsonrpc": "2.0", "method": "exit", "params": {}})
        self.proc.stdin.close()
        return self.proc.wait(timeout=15)


def main():
    tmp = tempfile.mkdtemp(prefix="eiwa-lsp-e2e-")
    src = os.path.join(tmp, "src")
    os.makedirs(src)
    files = {
        "src/main.ei": MAIN,
        "src/util.ei": UTIL,
        "src/impl.ei": IMPL,
        "src/bad.ei": BAD,
        "eiwa.yaml": "name: e2e\nversion: 0.1.0\n",
    }
    for rel, text in files.items():
        with open(os.path.join(tmp, rel), "w") as f:
            f.write(text)
    def uri(rel):
        return "file://" + os.path.realpath(os.path.join(tmp, rel)).replace(os.sep, "/")

    srv = Client()
    try:
        caps = srv.request(1, "initialize", {"rootUri": uri(""), "capabilities": {}})[
            "capabilities"
        ]
        check("initialize caps", caps.get("textDocumentSync") == 1)
        for key in (
            "hoverProvider",
            "completionProvider",
            "definitionProvider",
            "implementationProvider",
            "documentSymbolProvider",
        ):
            check(f"capability {key}", bool(caps.get(key)))
        srv.notify("initialized", {})

        # diagnostics: bad file -> 1, good file -> 0
        srv.notify(
            "textDocument/didOpen",
            {"textDocument": {"uri": uri("src/bad.ei"), "languageId": "eiwa", "version": 1, "text": BAD}},
        )
        diags = srv.read_msg()["params"]["diagnostics"]
        check("bad file has 1 diagnostic", len(diags) == 1, json.dumps(diags))
        if diags:
            check("diagnostic is an error", diags[0].get("severity") == 1)
            check("diagnostic mentions Int", "Int" in diags[0].get("message", ""))

        srv.notify(
            "textDocument/didOpen",
            {"textDocument": {"uri": uri("src/main.ei"), "languageId": "eiwa", "version": 1, "text": MAIN}},
        )
        check("good file has no diagnostics", srv.read_msg()["params"]["diagnostics"] == [])

        lines = MAIN.split("\n")
        ln_inc = next(i for i, l in enumerate(lines) if "c.inc()" in l)
        col_inc = lines[ln_inc].index("inc") + 1
        pos = lambda line, col: {"textDocument": {"uri": uri("src/main.ei")}, "position": {"line": line, "character": col}}

        # same-file receiver: c.inc() with `val c = Counter()` above
        loc = srv.request(2, "textDocument/definition", pos(ln_inc, col_inc))
        check("definition receiver same-file", loc and loc["uri"] == uri("src/main.ei") and loc["range"]["start"]["line"] == 4, json.dumps(loc))

        # cross-file: helper() imported from util
        ln_h = next(i for i, l in enumerate(lines) if "helper()" in l)
        loc = srv.request(3, "textDocument/definition", pos(ln_h, lines[ln_h].index("helper") + 1))
        check("definition cross-file import", loc and loc["uri"] == uri("src/util.ei") and loc["range"]["start"]["line"] == 0, json.dumps(loc))

        # implicit stdlib: parseJson
        ln_p = next(i for i, l in enumerate(lines) if "parseJson(" in l)
        loc = srv.request(4, "textDocument/definition", pos(ln_p, lines[ln_p].index("parseJson") + 1))
        check("definition implicit std", loc and loc["uri"].replace("\\", "/").endswith("std/json.ei"), json.dumps(loc))

        # synthesized: n.toString() -> contract method
        ln_t = next(i for i, l in enumerate(lines) if "n.toString()" in l)
        loc = srv.request(5, "textDocument/definition", pos(ln_t, lines[ln_t].index("toString") + 1))
        check("definition synthesized method", loc and loc["uri"].replace("\\", "/").endswith("std/core.ei"), json.dumps(loc))

        # hover shows the signature
        hov = srv.request(6, "textDocument/hover", pos(ln_inc, col_inc))
        check("hover markdown", hov and "fun inc" in hov["contents"]["value"], json.dumps(hov)[:160])

        # document symbols + completion
        syms = srv.request(7, "textDocument/documentSymbol", {"textDocument": {"uri": uri("src/main.ei")}})
        names = {s["name"] for s in syms}
        check("document symbols", {"Counter", "inc", "Drawable", "draw"} <= names, json.dumps(sorted(names)))
        comp = srv.request(8, "textDocument/completion", pos(ln_inc, 1))
        check("completion items", len(comp["items"]) > 0)

        # implementations: contract method -> both implementors
        srv.notify(
            "textDocument/didOpen",
            {"textDocument": {"uri": uri("src/impl.ei"), "languageId": "eiwa", "version": 1, "text": IMPL}},
        )
        srv.read_msg()  # diagnostics
        ilines = IMPL.split("\n")
        locs = srv.request(
            9,
            "textDocument/implementation",
            {"textDocument": {"uri": uri("src/impl.ei")}, "position": {"line": 1, "character": ilines[1].index("draw") + 1}},
        )
        got = sorted(r["range"]["start"]["line"] for r in locs)
        check("implementations", got == [4, 8], json.dumps(locs))
    finally:
        code = srv.close()
    check("clean shutdown", code == 0, f"exit={code}")

    if FAILS:
        print(f"\n{len(FAILS)} FAILURES")
        sys.exit(1)
    print("\nALL E2E CHECKS PASSED")


if __name__ == "__main__":
    main()
