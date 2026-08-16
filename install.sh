#!/bin/sh
# Eiwa installer — `curl -fsSL https://eiwa.dev/install.sh | sh`
#
# Downloads the latest Eiwa release from GitHub Releases and installs it to
# ~/.local/share/eiwa (override with EIWA_INSTALL_DIR), symlinking `eiwa` and
# `eiwac` into ~/.local/bin (override with EIWA_BIN_DIR).
#
# Prerequisites (not bundled — the binaries link them dynamically):
#   - LLVM 21+   (Linux: sudo apt install llvm-21-dev | macOS: brew install llvm@21)
#   - Boehm GC   (Linux: sudo apt install libgc-dev  | macOS: brew install bdw-gc)

set -e

REPO="eiwa-lang/eiwa"
BASE_URL="https://github.com/$REPO/releases/download"
API_URL="https://api.github.com/repos/$REPO/releases/latest"

say() { printf '\033[1;32m%s\033[0m\n' "$*"; }
warn() { printf '\033[1;33m%s\033[0m\n' "$*"; }
die() { printf '\033[1;31m%s\033[0m\n' "$*" >&2; exit 1; }

# --- detect OS / architecture ---
OS="$(uname -s | tr '[:upper:]' '[:lower:]')"
ARCH="$(uname -m)"
case "$OS" in
  darwin) os_triple="darwin" ;;
  linux)  os_triple="linux" ;;
  *) die "Eiwa installer: unsupported OS '$OS'" ;;
esac
case "$ARCH" in
  x86_64|amd64)  arch_triple="x86_64" ;;
  arm64|aarch64) arch_triple="arm64" ;;
  *) die "Eiwa installer: unsupported architecture '$ARCH'" ;;
esac

# --- resolve version ---
if [ -z "${EIWA_VERSION:-}" ]; then
  say "Resolving latest Eiwa release..."
  EIWA_VERSION="$(curl -fsSL "$API_URL" | sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)"
  [ -n "$EIWA_VERSION" ] || die "Eiwa installer: could not resolve the latest release"
fi
VERSION="${EIWA_VERSION#v}"

# --- install locations ---
INSTALL_DIR="${EIWA_INSTALL_DIR:-$HOME/.local/share/eiwa}"
BIN_DIR="${EIWA_BIN_DIR:-$HOME/.local/bin}"
mkdir -p "$INSTALL_DIR" "$BIN_DIR"

# --- download + verify ---
TARBALL="eiwa-$VERSION-$os_triple-$arch_triple.tar.gz"
URL="$BASE_URL/$EIWA_VERSION/$TARBALL"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT INT TERM

say "Downloading $URL"
curl -fsSL "$URL" -o "$TMP_DIR/$TARBALL"
curl -fsSL "$URL.sha256" -o "$TMP_DIR/$TARBALL.sha256"

EXPECTED="$(awk '{print $1}' "$TMP_DIR/$TARBALL.sha256")"
ACTUAL="$( (command -v shasum >/dev/null 2>&1 && shasum -a 256 "$TMP_DIR/$TARBALL") || sha256sum "$TMP_DIR/$TARBALL" | awk '{print $1}')"
if [ "$EXPECTED" != "$ACTUAL" ]; then
  die "Eiwa installer: checksum mismatch for $TARBALL"
fi

# --- extract ---
say "Installing Eiwa $VERSION to $INSTALL_DIR"
rm -rf "$INSTALL_DIR"
mkdir -p "$INSTALL_DIR"
tar -xzf "$TMP_DIR/$TARBALL" -C "$INSTALL_DIR" --strip-components=1
chmod +x "$INSTALL_DIR/bin/eiwac" "$INSTALL_DIR/bin/eiwa"

# --- symlink into bin dir ---
ln -sf "$INSTALL_DIR/bin/eiwac" "$BIN_DIR/eiwac"
ln -sf "$INSTALL_DIR/bin/eiwa" "$BIN_DIR/eiwa"

# --- PATH setup ---
case ":$PATH:" in
  *":$BIN_DIR:"*) ;;
  *)
    RC=""
    for f in "$HOME/.zshrc" "$HOME/.bashrc" "$HOME/.profile"; do
      [ -f "$f" ] && RC="$f" && break
    done
    if [ -n "$RC" ]; then
      printf '\nexport PATH="%s:$PATH"\n' "$BIN_DIR" >> "$RC"
      warn "Added $BIN_DIR to PATH in $RC (restart your shell or run: source $RC)"
    else
      warn "Add $BIN_DIR to your PATH manually."
    fi
    ;;
esac

say "Done! Run 'eiwa --help' to get started."
warn "Note: 'eiwac' links LLVM 21 and 'eiwa' links Boehm GC dynamically."
warn "Install them if missing: Linux: sudo apt install llvm-21-dev libgc-dev  |  macOS: brew install llvm@21 bdw-gc"