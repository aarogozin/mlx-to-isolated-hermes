#!/usr/bin/env bash
# scripts/shared-mounts.sh — Check and sync agent shared Obsidian directory.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
ENV_FILE="${PROJECT_ROOT}/.env"

OVERRIDE_OBSIDIAN_SHARED_PATH_SET="${OBSIDIAN_SHARED_PATH+x}"
OVERRIDE_OBSIDIAN_SHARED_PATH="${OBSIDIAN_SHARED_PATH:-}"

if [[ -f "${ENV_FILE}" ]]; then
  set -a
  # shellcheck disable=SC1090
  source "${ENV_FILE}"
  set +a
fi

ACTION="${1:-status}"
TARGET="docker"

if [[ -n "${OVERRIDE_OBSIDIAN_SHARED_PATH_SET}" ]]; then
  OBSIDIAN_SHARED_PATH="${OVERRIDE_OBSIDIAN_SHARED_PATH}"
else
  OBSIDIAN_SHARED_PATH="${OBSIDIAN_SHARED_PATH:-}"
fi

DOCKER_NAME="${DOCKER_NAME:-omlx-agent-docker}"

usage() {
  cat <<EOF
Usage: $0 <sync|status>
EOF
}

die() {
  echo "ERROR: $*" >&2
  exit 1
}

normalize_path() {
  local path="$1"
  [[ -n "${path}" ]] || return 0
  if [[ "${path}" == "~/"* ]]; then
    path="${HOME}/${path#~/}"
  fi
  printf '%s\n' "${path%/}"
}

host_path="$(normalize_path "${OBSIDIAN_SHARED_PATH}")"

status_docker() {
  if ! command -v docker >/dev/null 2>&1 || ! docker container inspect "${DOCKER_NAME}" >/dev/null 2>&1; then
    echo "shared=unknown docker=missing"
    return 0
  fi
  docker inspect -f '{{range .Mounts}}{{println .Source "->" .Destination}}{{end}}' "${DOCKER_NAME}"
}

case "${ACTION}" in
  sync)
    [[ -n "${host_path}" ]] || { echo "shared=disabled"; exit 0; }
    [[ -d "${host_path}" ]] || die "OBSIDIAN_SHARED_PATH does not exist: ${host_path}"
    echo "shared=configured source=${host_path} target=/mnt/obsidian"
    ;;
  status)
    status_docker
    ;;
  *)
    usage
    exit 2
    ;;
esac
