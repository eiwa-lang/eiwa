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

## 1. `eiwa.freeze` sobrepõe o manifesto silenciosamente

`loadProject` (`main.ei:496`) substitui toda a lista de deps pelo conteúdo de
`eiwa.freeze` quando este existe. Os comandos `add`/`remove` (que editam apenas
`eiwa.yaml`) **não** atualizam o freeze. Consequências:

- Um dep adicionado depois de um `freeze` é **ignorado** no build/run/test.
- Um dep removido do manifesto continua **sendo compilado** (presente no freeze).

**Sugestão**: sincronizar `add`/`remove` com o freeze, ou tratar o freeze como
aditivo/cache em vez de fonte de verdade.

## 2. Parser YAML caseiro, frágil

Não há parser YAML no projeto (TODO em `main.ei:6`). O parser
`parseManifest` (`main.ei:296`) é baseado em indentação por **espaços**:

- `indentOf` (`main.ei:172`) só conta `" "`; **tabs quebram** a estrutura.
- Exige indentação exata (deps em 2 espaços, campos em 4).
- Não suporta aspas, comentários inline, anchors/aliases, listas ou strings
  multilinha.

**Sugestão**: adotar um parser YAML/serde quando disponível (conforme TODO).

## 3. Teste integrado de dependências desabilitado

`cli/test/cli_integration_test.ei:213-216` — as asserções críticas de
`build --frozen` / `run` / `test` com um git dep + freeze estão **comentadas**
com a nota `// TODO........NAO PASSA ESSA BOSTA`.

O cenário foi reproduzido manualmente e **passa** hoje (build/run/test com git
dep + freeze + `import { hello } from "dep"`). O comentário está obsoleto:
vale reativar as linhas.

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
