#!/bin/sh
# Eiwa Docker build & publish helper.
#
#   ./scripts/docker.sh build   # build local image
#   ./scripts/docker.sh push    # build + push to Docker Hub (amd64 + arm64)
#
# Image: eiwa-lang/eiwa (tags: latest + v<git tag>)

set -e

IMAGE="eiwa-lang/eiwa"
VERSION="$(git describe --tags --always 2>/dev/null || echo dev)"
case "$VERSION" in
  v*) TAG="$VERSION" ;;
  *)  TAG="latest" ;;
esac

say() { printf '\033[1;32m%s\033[0m\n' "$*"; }

case "${1:-build}" in
  build)
    say "Building $IMAGE:$TAG ..."
    docker build -t "$IMAGE:$TAG" .
    ;;
  push)
    say "Building and pushing $IMAGE:$TAG (amd64 + arm64) ..."
    docker buildx build --platform linux/amd64,linux/arm64 \
      -t "$IMAGE:$TAG" \
      -t "$IMAGE:latest" \
      --push .
    ;;
  *)
    echo "usage: $0 {build|push}" >&2
    exit 1
    ;;
esac