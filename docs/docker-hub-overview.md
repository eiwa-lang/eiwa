<p align="center">
  <img src="https://eiwa.dev/assets/eiwa.png" alt="Eiwa" width="32" />
</p>

# Quick reference

- **Maintained by:** [the Eiwa team](https://github.com/eiwa-lang/eiwa)
- **Where to get help:** [Eiwa documentation](https://eiwa.dev), [GitHub Discussions](https://github.com/eiwa-lang/eiwa/discussions)
- **Where to file issues:** [https://github.com/eiwa-lang/eiwa/issues](https://github.com/eiwa-lang/eiwa/issues)
- **Supported architectures:** `linux/amd64`, `linux/arm64`
- **Source of this description:** [`docs/docker-hub-overview.md`](https://github.com/eiwa-lang/eiwa/blob/main/docs/docker-hub-overview.md) in [`eiwa-lang/eiwa`](https://github.com/eiwa-lang/eiwa) (synced to the Hub on every release)

# What is Eiwa?

<p align="center">
  <img src="https://eiwa.dev/assets/owl-card.png" alt="Eitau, the Eiwa mascot" width="220" />
</p>

Eiwa is a pragmatic, statically typed, natively compiled systems language with Kotlin-inspired syntax. Everything compiles directly to native code via LLVM — with a JIT for instant development loops and `-O3` for production — backed by a conservative garbage collector. Its type system is 100% composition-based (`type`, `contract`, `skill`, `object`, `implement`; no inheritance), with compile-time null safety, stackless coroutines (`task {}` / `.await()`), and an `eiwa` developer CLI for project and dependency management. Learn more at [eiwa.dev](https://eiwa.dev).

This image is the official Eiwa toolchain: the `eiwac` compiler backend, the `eiwa` project CLI, and the standard library, on `debian:trixie-slim`. `ENTRYPOINT` is `eiwa`, working directory is `/work`.

# How to use this image

## Start a new project

```console
$ docker run --rm -it -v "$PWD":/work -w /work eiwac/eiwa:latest init my-app
$ cd my-app
```

## Run your project

Mount your project on `/work` (requires `eiwa.yaml` + `src/main.ei`):

```console
$ docker run --rm -v "$PWD":/work -p 8080:8080 eiwac/eiwa:latest run .
```

## Run a standalone script

Single `.ei` files need no project — they are delegated to the `eiwac` backend:

```console
$ docker run --rm -v "$PWD":/work eiwac/eiwa:latest eiwac run script.ei
```

## Run the test suite

```console
$ docker run --rm -v "$PWD":/work eiwac/eiwa:latest test
```

## Compile your app

The most common pattern is a multi-stage build: compile with this image, then copy only the native binary into a slim runtime (the runtime does **not** need the compiler):

```dockerfile
FROM eiwac/eiwa:latest AS compile   # prod: pin the exact version, never latest
WORKDIR /app
COPY ./ ./
RUN eiwa build --release

FROM debian:stable-slim AS runtime
RUN apt-get update && apt-get install -y --no-install-recommends \
      libcurl4 libgc1 ca-certificates openssl \
    && rm -rf /var/lib/apt/lists/*
COPY --from=compile /app/app /app/server
WORKDIR /app
CMD ["./server"]
```

Then build and run your service:

```console
$ docker build -t my-service .
$ docker run --rm -p 8080:8080 my-service
```

For reproducible CI builds, commit an `eiwa.freeze` file (`eiwa freeze` pins every dependency to its exact commit) and build with `RUN eiwa build --release --frozen`.

# Image variants

## `eiwac/eiwa:<version>`

Pinned toolchain for a specific [Eiwa release](https://github.com/eiwa-lang/eiwa/releases). **Use these in production** — check the releases page for the newest tag.

## `eiwac/eiwa:latest`

Follows the newest release. Intended for **local development only**; never deploy on `latest`.

Both variants are published for `linux/amd64` and `linux/arm64`, with `EIWA_HOME=/opt/eiwa/src` and `EIWA_BASELINE_CPU=1` (portable binaries, safe under emulation) pre-configured.

# License

The Eiwa toolchain in this image follows the license of the [eiwa-lang/eiwa](https://github.com/eiwa-lang/eiwa) repository. As with all Docker images, your own built artifacts additionally contain other software under various licenses (notably Debian base packages); it is the image user's responsibility to ensure compliance.
