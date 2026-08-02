# Eiwa Package Manager Specification

> Version: 0.1 Status: Draft

## Goals

-   A single CLI for the entire developer experience.
-   Simple and predictable.
-   No mandatory lock file.
-   Automatic dependency resolution.
-   Reproducible builds through an explicit `freeze` command.
-   Shared dependency repository across all projects.
-   Clean project directories.

## Out of Scope (v0.1)

-   **Own registry**: there is no Eiwa package registry. Dependencies
    are consumed exclusively from git hosts (GitHub, GitLab or any
    custom git server).
-   **`eiwa publish`**: not implemented in v0.1. Distribution happens
    through git repositories (tags/branches); a publishing flow, if
    ever needed, will be specified in a future version.
-   **`eiwa doc`**: not implemented in v0.1.
-   **Version ranges** (e.g. `^1.3`): not supported in v0.1. Only exact
    git refs (branch, tag or commit) are allowed.
-   **Security hardening** (checksum verification of tarballs,
    signatures, mandatory TLS policy): deferred to v0.2.

## Pending / Known Limitations

-   **`eiwa` → `eiwac` invocation**: currently via process spawning
    (`system()`). The recommended future design is linking the compiler
    as a library and calling it in-process.
-   **Runtime C headers location**: `eiwac` resolves its internal C
    headers (`eiwa_runtime.h`, `third_party/`) through an absolute path
    captured at compile time (`eiwa_home`). Fine for development, but a
    distributed binary must embed these headers (e.g. `@embedFile` +
    temp cache extraction) or install them alongside the executable.
-   **v0.1 commands**: only `build` and `run` are implemented, using
    the fixed entry point `src/main.ei`. `init`, `add`, `remove`,
    `update`, `freeze` come next.
-   **Manifest parser**: the CLI uses a minimal line/indentation parser
    for `eiwa.yaml` (git dependencies only, marked with a TODO in the
    code). It must be replaced by a typed manifest DTO once a YAML
    parser/serde exists in Eiwa.
-   **Dependency resolution**: git dependencies are resolved once via
    `git ls-remote` and recorded in `~/.eiwa/resolutions/<manifest-hash>.yaml`;
    subsequent builds reuse the recorded commit without network access.
    Packages are cloned to `~/.eiwa/repository/<name>/<commit>` and passed
    to `eiwac` as `--module-path <repo>/src` and `eiwa.freeze`. Still
    missing: transitive resolution and GitLab/custom git sources.

## Executables

### `eiwa`

Official developer CLI.

Responsibilities:

-   project initialization
-   dependency management
-   compilation
-   execution
-   testing
-   dependency updates
-   freeze generation

Example:

``` bash
eiwa init

eiwa add orm github:eiwa-lang/orm
eiwa remove orm

eiwa update
eiwa update orm

eiwa build
eiwa run
eiwa test

eiwa freeze
```

### `eiwac`

Compiler backend.

Responsibilities:

-   lexer
-   parser
-   semantic analysis
-   optimization
-   code generation
-   linking

Normally invoked only by `eiwa`.

## Project Structure

``` text
my-project/
├── src/
├── test/
└── eiwa.yaml
```

No hidden directories inside the project.

`src/` and `test/` are fixed conventions, not configurable.

## Manifest

Filename:

``` text
eiwa.yaml
```

Example:

``` yaml
name: my-project
version: 1.0.0

dependencies:
  orm:
    github: eiwa-lang/orm
    tag: v2.0.0
  postgres:
    gitlab: eiwa-lang/postgres
    branch: main
```

Dependencies are always git repositories, referenced by an exact git
ref (branch, tag or commit). There is no version shorthand: versions
are expressed as git tags.

Optional build output path (default: `bin/<name>`):

``` yaml
name: my-project
output: bin/my-tool
```

## Dependency Sources

### GitHub

``` yaml
dependencies:
  orm:
    github: eiwa-lang/orm
```

Expands to `https://github.com/eiwa-lang/orm.git`.

### GitLab

``` yaml
dependencies:
  orm:
    gitlab: eiwa-lang/orm
```

Expands to `https://gitlab.com/eiwa-lang/orm.git`.

### Custom git server

``` yaml
dependencies:
  orm:
    git: https://git.example.com/eiwa-lang/orm.git
```

Any HTTPS git URL.

### Branch

``` yaml
dependencies:
  orm:
    github: eiwa-lang/orm
    branch: main
```

The first resolution stores the current HEAD commit locally. Future
builds reuse the same commit until:

``` bash
eiwa update
```

or

``` bash
eiwa update orm
```

### Tag

``` yaml
dependencies:
  orm:
    github: eiwa-lang/orm
    tag: v2.0.0
```

### Commit

``` yaml
dependencies:
  orm:
    github: eiwa-lang/orm
    commit: 84d2ab3
```

`branch`, `tag` and `commit` work identically for `github`, `gitlab`
and `git` sources. When no ref is given, the default branch HEAD is
resolved.

## Dependency Resolution

`eiwa build` never upgrades dependencies automatically.

Only `eiwa update` changes resolved refs.

Transitive dependencies are read from each dependency's own
`eiwa.yaml`. When the same package appears multiple times in the graph
with tag refs, **Minimal Version Selection** (Go-style) applies: the
resolved tag is the maximum of all tags required in the dependency
graph (tags must follow semver ordering). Resolution is deterministic,
without backtracking. Conflicting non-tag refs (different branches or
commits) are a hard error.

## Local Repository

All local state is stored outside projects.

Suggested layout:

``` text
~/.eiwa/
├── repository/
├── resolutions/
└── cache/
```

`repository/` stores downloaded packages.

`resolutions/` stores one file per project, keyed by manifest hash
(`resolutions/<manifest-hash>.yaml`). Keying by hash instead of project
path means moving or renaming the project directory never invalidates
the resolution, and per-project files avoid locking and corruption
issues of a single shared database. Each file records:

-   manifest hash
-   resolved refs (commits)
-   repository locations

## Build Algorithm

1.  Read `eiwa.yaml`
2.  Compute manifest hash
3.  Lookup `resolutions/<manifest-hash>.yaml`
4.  If found:
    -   reuse previous resolution
5.  Otherwise:
    -   resolve dependencies
    -   download missing packages
    -   write `resolutions/<manifest-hash>.yaml`
    -   build

`eiwa build --frozen` fails if no `eiwa.freeze` exists. Intended for CI.

## Freeze

``` bash
eiwa freeze
```

Generates:

``` text
eiwa.freeze
```

Example:

``` yaml
dependencies:
  orm:
    github: eiwa-lang/orm
    branch: main
```

becomes:

``` yaml
dependencies:
  orm:
    github: eiwa-lang/orm
    commit: 84d2ab3
```

If `eiwa.freeze` exists, it overrides local resolution data.

**Teams and CI must commit `eiwa.freeze`.** Without it, two machines
building the same project may resolve different dependency versions.
Reproducible builds are only guaranteed through the freeze file.

## Design Principles

-   One CLI.
-   Clean projects.
-   No mandatory lock file.
-   Explicit updates.
-   Shared local repository.
-   Local resolution state outside the project, keyed by manifest hash.
-   Reproducible builds through `freeze`.
