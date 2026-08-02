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

-   **`eiwa publish`**: not implemented in v0.1. There is no registry
    publishing flow yet; dependencies are consumed from the local
    repository or GitHub. Publishing will be specified in a future
    version.
-   **`eiwa doc`**: not implemented in v0.1.
-   **Version ranges** (e.g. `^1.3`): not supported in v0.1. Only exact
    versions are allowed. A decision on supporting ranges (or not) is
    deferred to a future version of this spec.
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
    to `eiwac` as `--module-path <repo>/src`.     and `eiwa.freeze`. Still missing: `eiwa update`
    (re-resolution), registry dependencies and transitive
    resolution (MVS).

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

eiwa add postgres
eiwa remove postgres

eiwa update
eiwa update postgres

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
  postgres: 1.3.0
  http: 2.0.0
```

Only exact versions are allowed in v0.1 (no ranges like `^1.3`).

Optional build output path (default: `bin/<name>`):

``` yaml
name: my-project
output: bin/my-tool
```

Alternative syntax:

``` yaml
dependencies:
  postgres:
    version: 1.3.0
```

## Dependency Sources

### Registry (local)

``` yaml
dependencies:
  postgres: 1.3.0
```

### GitHub

``` yaml
dependencies:
  orm:
    github: eiwa-lang/orm
```

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

## Dependency Resolution

`eiwa build` never upgrades dependencies automatically.

Only `eiwa update` changes resolved versions.

Transitive dependencies use **Minimal Version Selection** (Go-style):
each package declares the exact minimum version of its dependencies,
and the resolved version of each package is the maximum of all versions
required in the dependency graph. Resolution is deterministic, without
backtracking.

## Local Repository

All local state is stored outside projects.

Suggested layout:

``` text
~/.eiwa/
├── repository/
├── metadata.db
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
-   resolved versions
-   resolved commits
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

Registry dependencies are also pinned to their exact resolved version:

``` yaml
dependencies:
  postgres: 1.3.7
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
