# Problemas conhecidos do sistema de dependências (eiwa CLI)

Documento de problemas identificados no gerenciador de dependências do CLI
(`cli/src/main.ei`) e na ponte com o compilador `eiwac`. Serve como lista de
pendências para futuras correções. Não reflete estado "final" do sistema — o
sistema evolui junto com o roadmap.

---

## Contexto rápido (arquitetura)

O sistema tem duas camadas:

- **`eiwac`** (compilador, Zig): desconhece `eiwa.yaml`. Resolve imports
  somente via `--module-path`. A stdlib (`std/*`) é embutida no binário; os
  módulos de dependência chegam como pastas passadas via `--module-path`.
- **`eiwa`** (CLI, `cli/src/main.ei`): dono do manifesto `eiwa.yaml`, baixa
  deps git, grava freeze e delega a compilação ao `eiwac`.

Fluxo: `eiwa build` clona cada dep para `~/.eiwa/repository/<name>/<commit>` e
passa `<repo>/src` como `--module-path` para o `eiwac`.

Precedência de resolução de versão (`loadProject`, `main.ei:475`):
`eiwa.freeze` > cache `~/.eiwa/resolutions/<hash>.yaml` > `git ls-remote`.

---

## 1. ~~`eiwa.freeze` sobrepõe o manifesto silenciosamente~~ (RESOLVIDO)

`loadProject` (`main.ei:509`) usa `mergeResolvedDeps`: itera as deps do
**manifesto** e só pega o commit pinado do freeze/cache quando o nome bate.
Deps removidas do manifesto não são mais compiladas, e deps novas (ausentes do
freeze) são resolvidas on-the-fly por `resolveMissing` (com aviso no console).
O freeze funciona como cache aditivo, não como fonte de verdade. Rode
`eiwa freeze` para re-piná-lo após `add`/`remove`.

## 2. ~~Parser YAML caseiro, frágil~~ (PARCIALMENTE RESOLVIDO)

Não há parser YAML completo no projeto (TODO em `main.ei:6`) — continua sendo
a solução definitiva. Mas o parser minimalista foi robustecido:

- `indentOf` conta **tabs e espaços** como unidades de indentação.
- `parseManifest`/`removeCommand` usam **indentação relativa** (o primeiro
  nível indentado sob `dependencies:` define o nível das deps; campos são
  qualquer nível mais profundo) — não exigem mais 2/4 espaços exatos.
- Valores passam por `parseScalar`: remove **comentários inline** (` # ...`,
  respeitando aspas) e **aspas simples/duplas** ao redor do valor.

Ainda não suporta: anchors/aliases, listas ou strings multilinha.

## 3. ~~Teste integrado de dependências desabilitado~~ (RESOLVIDO)

`cli/test/cli_integration_test.ei:213` — as asserções de `build --frozen` /
`run` / `test` com git dep + freeze foram **reativadas**.

Ao reativar, o teste revelou um bug real (flaky ~50%): o `freeze` gravava o
commit do **cache de resoluções** (chaveado pelo hash do manifesto), que podia
estar velho em relação ao HEAD remoto — o build então tentava clonar um commit
inexistente no repo (`fatal: unable to read tree`). Corrigido:
`freezeCommand` agora re-resolve as refs a partir do manifesto (como
`updateCommand` faz) e atualiza o cache de resoluções junto com o freeze.

## 4. Re-clone e acúmulo de clones

`ensureCloned` (`main.ei:369`) só considera o dep clonado se
`dest/eiwa.yaml` existir:

- Deps que não possuem `eiwa.yaml` são **re-clonadas a cada build** (exige
  rede toda vez), mesmo com o commit já em cache.
- Clones antigos em `~/.eiwa/repository/<name>/<commit>` **nunca são
  removidos** → o disco cresce indefinidamente.

**Sugestão**: usar presença do commit checkout como marcador de cache e
implementar limpeza de versões antigas (GC).

## 5. Sem resolução transitiva (MVS)

O plano (`docs/plan_package_manager.md`) especifica Minimal Version Selection
para deps transitivas, mas isso **não está implementado**. Somente deps
diretas são baixadas e adicionadas ao `--module-path`. Deps de deps não são
resolvidas.

## 6. Tags anotadas: SHA do objeto-tag (não peeled)

`resolveCommit` usa `git ls-remote <url> <ref>`, que para uma **tag anotada**
devolve o SHA do objeto-tag, não o do commit. Hoje funciona porque
`git checkout <sha>` desreferencia a tag, mas o SHA gravado no freeze não é o
do commit real (inconsistência no registro).

**Sugestão**: usar `ls-remote <url> refs/tags/<tag>^{}` (peeled) para obter o
commit, ou armazenar a ref como tag em vez do SHA.

## 7. Concatenação de shell sem aspas

Vários comandos são montados por concatenação de string e executados via
`Process.exec` (ex.: `runOrFail`, montagem do `fullCmd` em
`compilerCommand`, `main.ei:977-1001`). Caminhos com espaços quebram, e há
risco de injeção com valores vindos do manifesto/CLI (ex.: `-o`, `--module-path`,
`git:`).

**Sugestão**: usar execução com vetor de argumentos (sem shell) e/ou citar
corretamente os argumentos.

## 8. `ssh://` e estilo scp não reconhecidos

`parseDepSpec` (`main.ei:670`) reconhece `http(s)://`, `git@`, caminhos
locais e `org/repo`. Não reconhece URLs `ssh://git@host/repo.git` nem o estilo
scp `git@host:org/repo.git`, que caem em outros ramos e são tratados
incorretamente (ex.: `git@host:org` vira `github:`).

## 9. Branch default `main` assumido

`parseDepSpec` (sem `@ref`) assume `branch = "main"`. Repositórios cujo branch
padrão é `master` (ou outro) falham com
`Error: could not resolve 'main' for dependency`. `gitUrl`/`resolveCommit`
não consultam o branch padrão remoto (`HEAD`).

## 10. `git:` sem `.git`/caminho local não tratado como fonte

Deps que só usam `git:` de forma ambígua (ou entradas inválidas no manifesto)
podem ter `hasSource` falso e ser silenciosamente ignoradas no build (não
entram no `--module-path`), sem aviso ao usuário.

---

## Observações não-problema (comportamento atual)

- **Registry**: explicitamente fora de escopo — não há registry próprio,
  somente sources git (`plan_package_manager.md`, `roadmap.md`).
- **Sem semver**: versões são refs git exatas (branch/tag/commit); `eiwa
  update` é o único comando que altera refs resolvidas.
- **Dois mecanismos de pin**: cache de resolução por máquina
  (`~/.eiwa/resolutions/<hash>.yaml`) e freeze versionável (`eiwa.freeze`,
  para builds reproduzíveis / CI com `--frozen`).
