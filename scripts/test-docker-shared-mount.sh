#!/usr/bin/env bash
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
CONTAINER_NAME="omlx-ci-shared-$RANDOM-$$"

cleanup() {
  docker rm -f "${CONTAINER_NAME}" >/dev/null 2>&1 || true
  rm -rf "${TMP_DIR}"
}
trap cleanup EXIT

command -v docker >/dev/null 2>&1 || {
  echo "docker CLI missing" >&2
  exit 1
}

docker version >/dev/null
mkdir -p "${TMP_DIR}/shared"

docker run -d \
  --name "${CONTAINER_NAME}" \
  -v "${TMP_DIR}/shared:/mnt/obsidian:rw" \
  ubuntu:24.04 \
  bash -lc 'sleep 300' >/dev/null

OBSIDIAN_SHARED_PATH="${TMP_DIR}/shared" \
OBSIDIAN_GUEST_PATH="/mnt/obsidian" \
DOCKER_NAME="${CONTAINER_NAME}" \
  "${PROJECT_ROOT}/scripts/shared-mounts-check.sh" docker

echo "docker shared mount smoke passed"
