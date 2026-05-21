#!/usr/bin/env bash
# scripts/docker-build.sh — Build the Hermes agent Docker image.
#
# Environment variables:
#   DOCKER_IMAGE    Local tag (default: omlx-agent-hermes:VERSION)
#   GHCR_IMAGE      Optional ghcr.io image path for additional tagging
#                   e.g. ghcr.io/aarogozin/mlx-to-isolated-hermes
#   DOCKER_PUSH     Set to "1" to push to GHCR after build
#   PLATFORM        Build platform (default: linux/arm64)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
ENV_FILE="${PROJECT_ROOT}/.env"
VERSION_FILE="${PROJECT_ROOT}/VERSION"

if [[ -f "${ENV_FILE}" ]]; then
  set -a
  # shellcheck disable=SC1090
  source "${ENV_FILE}"
  set +a
fi

VERSION="$(cat "${VERSION_FILE}" 2>/dev/null || echo "0.0.0")"
DOCKER_IMAGE="${DOCKER_IMAGE:-omlx-agent-hermes:${VERSION}}"
PLATFORM="${PLATFORM:-linux/arm64}"
DOCKER_PUSH="${DOCKER_PUSH:-0}"
BUILD_DATE="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
VCS_REF="$(git -C "${PROJECT_ROOT}" rev-parse --short HEAD 2>/dev/null || echo "unknown")"

command -v docker >/dev/null 2>&1 || {
  echo "ERROR: docker CLI missing. Run make bootstrap or install Docker Desktop." >&2
  exit 1
}

# ── Build ─────────────────────────────────────────────────────────────────────
echo "==> Building Docker image: ${DOCKER_IMAGE}  (platform: ${PLATFORM})"
echo "    Version: ${VERSION}  Commit: ${VCS_REF}  Date: ${BUILD_DATE}"

docker buildx build \
  --platform "${PLATFORM}" \
  --build-arg VERSION="${VERSION}" \
  --build-arg BUILD_DATE="${BUILD_DATE}" \
  --build-arg VCS_REF="${VCS_REF}" \
  -t "${DOCKER_IMAGE}" \
  -f "${PROJECT_ROOT}/docker/Dockerfile" \
  --load \
  "${PROJECT_ROOT}"

echo "Built: ${DOCKER_IMAGE}"

# ── Optional: tag and push to GHCR ───────────────────────────────────────────
if [[ -n "${GHCR_IMAGE:-}" ]]; then
  GHCR_VERSIONED="${GHCR_IMAGE}:${VERSION}"
  GHCR_LATEST="${GHCR_IMAGE}:latest"

  docker tag "${DOCKER_IMAGE}" "${GHCR_VERSIONED}"
  docker tag "${DOCKER_IMAGE}" "${GHCR_LATEST}"
  echo "Tagged: ${GHCR_VERSIONED}"
  echo "Tagged: ${GHCR_LATEST}"

  if [[ "${DOCKER_PUSH}" == "1" ]]; then
    docker push "${GHCR_VERSIONED}"
    docker push "${GHCR_LATEST}"
    echo "Pushed to GHCR: ${GHCR_IMAGE}"
  fi
fi
