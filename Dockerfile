# syntax=docker/dockerfile:1
#
# Eiwa toolchain image (eiwac compiler + eiwa CLI + stdlib).
#
# Binaries are downloaded from the GitHub Release tarball (same URLs used by
# install.sh): eiwa-<version>-linux-<arch>.tar.gz
#
# Usage:
#   docker build -t eiwalang/eiwa --build-arg EIWA_VERSION=v0.1.0 .
#   docker run --rm -v "$PWD":/work eiwalang/eiwa run myproject
#   docker run --rm -v "$PWD":/work eiwalang/eiwa eiwac run script.ei
#
# Runtime deps: eiwac links libLLVM.so.21.1 (libllvm21) and the eiwa CLI links
# Boehm GC (libgc; libunwind on arm64). `eiwac build` links native binaries
# (and the JIT compiles lib C sources) via the system C compiler, so `gcc` is
# included. libcurl4-openssl-dev (dev headers) is shipped because the bundled
# stdlib's std.http links -lcurl. No zig / LLVM headers needed.
#
# Base is Debian 13 (trixie, glibc 2.41): the release binary is built on
# Ubuntu 24.04 (glibc 2.39) so a base older than 2.39 would not load it.

FROM debian:trixie-slim

# Build args. EIWA_VERSION="latest" resolves the newest tag via the GitHub API.
ARG EIWA_VERSION=latest
ARG EIWA_CACHE_BUST=1
ARG TARGETARCH

RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates \
        curl \
        git \
        tar \
        wget \
    && wget -qO- https://apt.llvm.org/llvm-snapshot.gpg.key | tee /etc/apt/trusted.gpg.d/apt.llvm.org.asc \
    && CODENAME="$(sed -n 's/.*VERSION_CODENAME=\([a-z]*\).*/\1/p' /etc/os-release)" \
    && echo "deb [signed-by=/etc/apt/trusted.gpg.d/apt.llvm.org.asc] https://apt.llvm.org/${CODENAME}/ llvm-toolchain-${CODENAME}-21 main" > /etc/apt/sources.list.d/llvm.list \
    && apt-get update \
    && apt-get install -y --no-install-recommends libllvm21 libgc-dev libunwind-dev gcc libcurl4-openssl-dev \
    && rm -rf /var/lib/apt/lists/*

RUN case "$TARGETARCH" in \
        amd64|x86_64)  RELEASE_ARCH="x86_64" ;; \
        arm64|aarch64) RELEASE_ARCH="arm64" ;; \
        *) echo "unsupported arch: $TARGETARCH" >&2; exit 1 ;; \
    esac \
    && if [ "$EIWA_VERSION" = "latest" ]; then \
         EIWA_VERSION="$(curl -fsSL https://api.github.com/repos/eiwa-lang/eiwa/releases/latest \
           | sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)"; \
       fi \
    && [ -n "$EIWA_VERSION" ] || { echo "could not resolve the latest Eiwa release" >&2; exit 1; } \
    && VERSION="${EIWA_VERSION#v}" \
    && TARBALL="eiwa-${VERSION}-linux-${RELEASE_ARCH}.tar.gz" \
    && URL="https://github.com/eiwa-lang/eiwa/releases/download/${EIWA_VERSION}/${TARBALL}" \
    && echo "Downloading $URL" \
    && curl -fsSL "$URL" -o "/tmp/${TARBALL}" \
    && curl -fsSL "$URL.sha256" -o "/tmp/${TARBALL}.sha256" \
    && EXPECTED="$(awk '{print $1}' "/tmp/${TARBALL}.sha256")" \
    && ACTUAL="$(sha256sum "/tmp/${TARBALL}" | awk '{print $1}')" \
    && [ "$EXPECTED" = "$ACTUAL" ] || { echo "checksum mismatch for $TARBALL" >&2; exit 1; } \
    && mkdir -p /opt/eiwa \
    && tar -xzf "/tmp/${TARBALL}" -C /opt/eiwa --strip-components=1 \
    && chmod +x /opt/eiwa/bin/eiwac /opt/eiwa/bin/eiwa \
    && rm -f "/tmp/${TARBALL}" "/tmp/${TARBALL}.sha256"

# Shipped layout: <bin>/eiwac + <src>/ side by side, exactly like the release
# tarball, so eiwa_home resolves the stdlib at runtime (EIWA_HOME backstop).
# EIWA_BASELINE_CPU forces portable binaries when building projects inside the
# container (no host-only features like AVX-512, which break under emulation).
ENV EIWA_HOME=/opt/eiwa/src \
    EIWA_BASELINE_CPU=1 \
    PATH="/opt/eiwa/bin:${PATH}"

WORKDIR /work
ENTRYPOINT ["/opt/eiwa/bin/eiwa"]
CMD ["--help"]