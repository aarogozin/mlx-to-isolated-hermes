#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
ENV_FILE="${PROJECT_ROOT}/.env"

OVERRIDE_OBSIDIAN_SHARED_PATH_SET="${OBSIDIAN_SHARED_PATH+x}"
OVERRIDE_OBSIDIAN_SHARED_PATH="${OBSIDIAN_SHARED_PATH:-}"
OVERRIDE_RAG_SOURCE_PATH_SET="${RAG_SOURCE_PATH+x}"
OVERRIDE_RAG_SOURCE_PATH="${RAG_SOURCE_PATH:-}"
OVERRIDE_RAG_INDEX_PATH_SET="${RAG_INDEX_PATH+x}"
OVERRIDE_RAG_INDEX_PATH="${RAG_INDEX_PATH:-}"
OVERRIDE_RAG_DOCKER_INDEX_PATH_SET="${RAG_DOCKER_INDEX_PATH+x}"
OVERRIDE_RAG_DOCKER_INDEX_PATH="${RAG_DOCKER_INDEX_PATH:-}"
OVERRIDE_RAG_HOST_SET="${RAG_HOST+x}"
OVERRIDE_RAG_HOST="${RAG_HOST:-}"
OVERRIDE_RAG_BIND_HOST_SET="${RAG_BIND_HOST+x}"
OVERRIDE_RAG_BIND_HOST="${RAG_BIND_HOST:-}"
OVERRIDE_RAG_PORT_SET="${RAG_PORT+x}"
OVERRIDE_RAG_PORT="${RAG_PORT:-}"
OVERRIDE_RAG_ENABLED_SET="${RAG_ENABLED+x}"
OVERRIDE_RAG_ENABLED="${RAG_ENABLED:-}"
OVERRIDE_RAG_RUNTIME_SET="${RAG_RUNTIME+x}"
OVERRIDE_RAG_RUNTIME="${RAG_RUNTIME:-}"

if [[ -f "${ENV_FILE}" ]]; then
  set -a
  # shellcheck disable=SC1090
  source "${ENV_FILE}"
  set +a
fi

if [[ -n "${OVERRIDE_OBSIDIAN_SHARED_PATH_SET}" ]]; then
  OBSIDIAN_SHARED_PATH="${OVERRIDE_OBSIDIAN_SHARED_PATH}"
fi
if [[ -n "${OVERRIDE_RAG_SOURCE_PATH_SET}" ]]; then
  RAG_SOURCE_PATH="${OVERRIDE_RAG_SOURCE_PATH}"
fi
if [[ -n "${OVERRIDE_RAG_INDEX_PATH_SET}" ]]; then
  RAG_INDEX_PATH="${OVERRIDE_RAG_INDEX_PATH}"
fi
if [[ -n "${OVERRIDE_RAG_DOCKER_INDEX_PATH_SET}" ]]; then
  RAG_DOCKER_INDEX_PATH="${OVERRIDE_RAG_DOCKER_INDEX_PATH}"
fi

RAG_ENABLED="${OVERRIDE_RAG_ENABLED:-${RAG_ENABLED:-1}}"
RAG_RUNTIME="${OVERRIDE_RAG_RUNTIME:-${RAG_RUNTIME:-docker}}"
RAG_INDEX_PATH="${RAG_INDEX_PATH:-.runtime/rag}"
RAG_DOCKER_INDEX_PATH="${RAG_DOCKER_INDEX_PATH:-.runtime/rag-docker}"
RAG_HOST="${OVERRIDE_RAG_HOST:-${RAG_HOST:-127.0.0.1}}"
RAG_BIND_HOST="${OVERRIDE_RAG_BIND_HOST:-${RAG_BIND_HOST:-0.0.0.0}}"
RAG_PORT="${OVERRIDE_RAG_PORT:-${RAG_PORT:-8765}}"
RAG_VENV_PATH="${RAG_VENV_PATH:-.runtime/rag-venv}"
RAG_EMBEDDING_BACKEND="${RAG_EMBEDDING_BACKEND:-sentence-transformers}"
RAG_OCR_TESSDATA_PATH="${RAG_OCR_TESSDATA_PATH:-.runtime/tessdata}"
RAG_OCR_LANGUAGE_SOURCE="${RAG_OCR_LANGUAGE_SOURCE:-https://raw.githubusercontent.com/tesseract-ocr/tessdata_fast/main}"

case "${RAG_INDEX_PATH}" in
  /*) RAG_INDEX_ABS="${RAG_INDEX_PATH}" ;;
  *) RAG_INDEX_ABS="${PROJECT_ROOT}/${RAG_INDEX_PATH}" ;;
esac

case "${RAG_DOCKER_INDEX_PATH}" in
  /*) RAG_DOCKER_INDEX_ABS="${RAG_DOCKER_INDEX_PATH}" ;;
  *) RAG_DOCKER_INDEX_ABS="${PROJECT_ROOT}/${RAG_DOCKER_INDEX_PATH}" ;;
esac

case "${RAG_VENV_PATH}" in
  /*) RAG_VENV_ABS="${RAG_VENV_PATH}" ;;
  *) RAG_VENV_ABS="${PROJECT_ROOT}/${RAG_VENV_PATH}" ;;
esac

case "${RAG_OCR_TESSDATA_PATH}" in
  /*) RAG_OCR_TESSDATA_ABS="${RAG_OCR_TESSDATA_PATH}" ;;
  *) RAG_OCR_TESSDATA_ABS="${PROJECT_ROOT}/${RAG_OCR_TESSDATA_PATH}" ;;
esac

PID_FILE="${RAG_INDEX_ABS}/rag-service.pid"
LOG_FILE="${RAG_INDEX_ABS}/rag-service.log"
WATCH_PID_FILE="${RAG_INDEX_ABS}/rag-watch.pid"
WATCH_LOG_FILE="${RAG_INDEX_ABS}/rag-watch.log"
PYTHON_BIN="${RAG_VENV_ABS}/bin/python"
RAG_DOCKER_COMPOSE_FILE="${PROJECT_ROOT}/docker-compose.rag.yml"
RAG_DOCKER_PROJECT="${RAG_DOCKER_PROJECT:-mlx-isolated-rag}"
RAG_DOCKER_NAME="${RAG_DOCKER_NAME:-mlx-isolated-rag}"
RAG_API_IMAGE="${RAG_API_IMAGE:-python:3.12-slim}"
RAG_DOCKER_EMBEDDING_BACKEND="${RAG_DOCKER_EMBEDDING_BACKEND:-hash}"
RAG_QDRANT_IMAGE="${RAG_QDRANT_IMAGE:-qdrant/qdrant:latest}"
RAG_TEI_IMAGE="${RAG_TEI_IMAGE:-ghcr.io/huggingface/text-embeddings-inference:cpu-latest}"
RAG_TIKA_IMAGE="${RAG_TIKA_IMAGE:-apache/tika:latest-full}"
RAG_DOCLING_IMAGE="${RAG_DOCLING_IMAGE:-quay.io/docling-project/docling-serve:latest}"
RAG_REQUIRE_IMAGE_PREFLIGHT="${RAG_REQUIRE_IMAGE_PREFLIGHT:-1}"
RAG_DOCKER_PULL_POLICY="${RAG_DOCKER_PULL_POLICY:-missing}"

die() {
  echo "ERROR: $*" >&2
  exit 1
}

ensure_enabled() {
  case "${RAG_ENABLED}" in
    1|true|yes|on) ;;
    *) die "RAG is disabled. Set RAG_ENABLED=1 in .env." ;;
  esac
}

ensure_host_runtime_allowed() {
  [[ "${INSTALL_RAG_HOST:-0}" == "1" || "${INSTALL_RAG_HOST:-0}" == "true" ]] \
    || die "Host RAG is a legacy escape hatch. Set INSTALL_RAG_HOST=1 to install or run host-side RAG dependencies."
}

rag_source_path() {
  local path="${RAG_SOURCE_PATH:-}"
  if [[ -z "${path}" || "${path}" == '${OBSIDIAN_SHARED_PATH}' || "${path}" == '${OBSIDIAN_SHARED_PATH:-}' ]]; then
    path="${OBSIDIAN_SHARED_PATH:-}"
  fi
  [[ -n "${path}" ]] || die "RAG source path is unset. Set OBSIDIAN_SHARED_PATH or RAG_SOURCE_PATH."
  path="${path/#\~/${HOME}}"
  case "${path}" in
    /*) ;;
    *) path="${PROJECT_ROOT}/${path}" ;;
  esac
  [[ -d "${path}" ]] || die "RAG source path does not exist: ${path}"
  printf '%s\n' "${path}"
}

compose_env_args() {
  local source_mount
  if ! source_mount="$(rag_source_path 2>/dev/null)"; then
    if [[ "${RAG_COMPOSE_ALLOW_MISSING_SOURCE:-0}" == "1" ]]; then
      source_mount="${PROJECT_ROOT}"
    else
      rag_source_path
    fi
  fi
  printf '%s\0' \
    "RAG_SOURCE_MOUNT=${source_mount}" \
    "RAG_INDEX_MOUNT=${RAG_DOCKER_INDEX_ABS}" \
    "RAG_TESSDATA_MOUNT=${RAG_OCR_TESSDATA_ABS}" \
    "RAG_CACHE_MOUNT=${PROJECT_ROOT}/.runtime/rag-cache" \
    "RAG_API_VENV_MOUNT=${PROJECT_ROOT}/.runtime/rag-api-venv" \
    "RAG_DOCKER_NAME=${RAG_DOCKER_NAME}" \
    "RAG_API_IMAGE=${RAG_API_IMAGE}" \
    "RAG_DOCKER_EMBEDDING_BACKEND=${RAG_DOCKER_EMBEDDING_BACKEND}" \
    "RAG_QDRANT_IMAGE=${RAG_QDRANT_IMAGE}" \
    "RAG_TEI_IMAGE=${RAG_TEI_IMAGE}" \
    "RAG_TIKA_IMAGE=${RAG_TIKA_IMAGE}" \
    "RAG_DOCLING_IMAGE=${RAG_DOCLING_IMAGE}" \
    "RAG_QDRANT_MOUNT=${PROJECT_ROOT}/.runtime/qdrant" \
    "RAG_PORT=${RAG_PORT}" \
    "RAG_EMBEDDING_MODEL=${RAG_EMBEDDING_MODEL:-intfloat/multilingual-e5-small}" \
    "RAG_EMBEDDING_BACKEND=${RAG_EMBEDDING_BACKEND}" \
    "RAG_TEXT_EXTENSIONS=${RAG_TEXT_EXTENSIONS:-.md,.txt,.rst,.csv,.tsv,.json,.yaml,.yml,.toml,.xml,.html,.xlsx,.xlsm,.xls,.xlsb,.ods,.pdf,.png,.jpg,.jpeg,.tif,.tiff}" \
    "RAG_EXCLUDE_GLOBS=${RAG_EXCLUDE_GLOBS:-.git/**,.obsidian/**,node_modules/**,.trash/**,*.env,*.key,*.pem}" \
    "RAG_MAX_FILE_MB=${RAG_MAX_FILE_MB:-10}" \
    "RAG_DOCUMENT_MAX_FILE_MB=${RAG_DOCUMENT_MAX_FILE_MB:-50}" \
    "RAG_CHUNK_TOKENS=${RAG_CHUNK_TOKENS:-800}" \
    "RAG_CHUNK_OVERLAP_TOKENS=${RAG_CHUNK_OVERLAP_TOKENS:-120}" \
    "RAG_TOP_K=${RAG_TOP_K:-8}" \
    "RAG_SPREADSHEETS_ENABLED=${RAG_SPREADSHEETS_ENABLED:-1}" \
    "RAG_SPREADSHEET_MAX_FILE_MB=${RAG_SPREADSHEET_MAX_FILE_MB:-50}" \
    "RAG_SPREADSHEET_MAX_ROWS_PER_CHUNK=${RAG_SPREADSHEET_MAX_ROWS_PER_CHUNK:-50}" \
    "RAG_SPREADSHEET_MAX_ROWS_FULL=${RAG_SPREADSHEET_MAX_ROWS_FULL:-5000}" \
    "RAG_SPREADSHEET_INCLUDE_HIDDEN=${RAG_SPREADSHEET_INCLUDE_HIDDEN:-0}" \
    "RAG_SPREADSHEET_INCLUDE_FORMULAS=${RAG_SPREADSHEET_INCLUDE_FORMULAS:-1}" \
    "RAG_SPREADSHEET_INCLUDE_COMMENTS=${RAG_SPREADSHEET_INCLUDE_COMMENTS:-1}" \
    "RAG_PDF_ENABLED=${RAG_PDF_ENABLED:-1}" \
    "RAG_IMAGES_ENABLED=${RAG_IMAGES_ENABLED:-1}" \
    "RAG_OCR_ENABLED=${RAG_OCR_ENABLED:-1}" \
    "RAG_OCR_MODE=${RAG_OCR_MODE:-needed}" \
    "RAG_OCR_LANGUAGES=${RAG_OCR_LANGUAGES:-rus+eng+deu}" \
    "RAG_OCR_LANGUAGE_SOURCE=${RAG_OCR_LANGUAGE_SOURCE}" \
    "RAG_OCR_MIN_TEXT_CHARS=${RAG_OCR_MIN_TEXT_CHARS:-200}" \
    "RAG_OCR_MAX_PAGES=${RAG_OCR_MAX_PAGES:-25}" \
    "RAG_OCR_DPI=${RAG_OCR_DPI:-200}"
}

docker_compose() {
  command -v docker >/dev/null 2>&1 || die "docker CLI missing"
  local -a env_args=()
  local item
  while IFS= read -r -d '' item; do
    env_args+=("${item}")
  done < <(compose_env_args)
  if [[ "${RAG_DOCKER_EMBEDDING_BACKEND}" == "tei" ]]; then
    env_args+=("COMPOSE_PROFILES=tei")
  fi
  env "${env_args[@]}" docker compose \
    -f "${RAG_DOCKER_COMPOSE_FILE}" \
    --project-name "${RAG_DOCKER_PROJECT}" \
    "$@"
}

image_has_arm64() {
  local image="$1"
  local local_platform
  local_platform="$(docker image inspect "${image}" --format '{{.Os}}/{{.Architecture}}' 2>/dev/null || true)"
  if [[ "${local_platform}" == "linux/arm64" || "${local_platform}" == "linux/aarch64" ]]; then
    return 0
  fi
  if [[ -n "${local_platform}" ]]; then
    echo "${image} is present locally but is ${local_platform}, not linux/arm64" >&2
    return 2
  fi

  local manifest
  local manifest_error
  manifest_error="$(mktemp)"
  if ! manifest="$(docker manifest inspect "${image}" 2>"${manifest_error}")"; then
    cat "${manifest_error}" >&2 || true
    rm -f "${manifest_error}"
    return 1
  fi
  rm -f "${manifest_error}"
  MANIFEST_JSON="${manifest}" python3 - "${image}" <<'PY'
import json
import os
import sys

image = sys.argv[1]
manifest = json.loads(os.environ["MANIFEST_JSON"])
if "manifests" not in manifest:
    arch = manifest.get("architecture")
    sys.exit(0 if arch in {"arm64", "aarch64"} else 2)
for item in manifest["manifests"]:
    platform = item.get("platform", {})
    if platform.get("os") == "linux" and platform.get("architecture") == "arm64":
        sys.exit(0)
print(f"{image} does not publish a linux/arm64 manifest", file=sys.stderr)
sys.exit(2)
PY
}

docker_image_preflight() {
  [[ "${RAG_REQUIRE_IMAGE_PREFLIGHT}" == "1" || "${RAG_REQUIRE_IMAGE_PREFLIGHT}" == "true" ]] || return 0
  command -v docker >/dev/null 2>&1 || die "docker CLI missing"
  local image
  local -a images=("${RAG_API_IMAGE}" "${RAG_QDRANT_IMAGE}" "${RAG_TIKA_IMAGE}" "${RAG_DOCLING_IMAGE}")
  if [[ "${RAG_DOCKER_EMBEDDING_BACKEND}" == "tei" ]]; then
    images+=("${RAG_TEI_IMAGE}")
  fi
  for image in "${images[@]}"; do
    if image_has_arm64 "${image}"; then
      echo "ok image ${image} linux/arm64"
    else
      die "Docker image is unavailable, rate-limited, or lacks linux/arm64 support: ${image}. If Docker Hub is rate-limited, retry after login or after the image is already pulled locally."
    fi
  done
}

docker_required_images() {
  printf '%s\n' "${RAG_API_IMAGE}" "${RAG_QDRANT_IMAGE}" "${RAG_TIKA_IMAGE}" "${RAG_DOCLING_IMAGE}"
  if [[ "${RAG_DOCKER_EMBEDDING_BACKEND}" == "tei" ]]; then
    printf '%s\n' "${RAG_TEI_IMAGE}"
  fi
}

docker_images_present() {
  local image
  while IFS= read -r image; do
    [[ -n "${image}" ]] || continue
    docker image inspect "${image}" >/dev/null 2>&1 || return 1
  done < <(docker_required_images)
}

docker_rag_running() {
  command -v docker >/dev/null 2>&1 \
    && docker container inspect "${RAG_DOCKER_NAME}" >/dev/null 2>&1 \
    && [[ "$(docker inspect -f '{{.State.Running}}' "${RAG_DOCKER_NAME}" 2>/dev/null || true)" == "true" ]]
}

wait_docker_api() {
  local attempts="${RAG_DOCKER_START_TIMEOUT_SECONDS:-600}"
  local i
  for ((i = 1; i <= attempts; i++)); do
    if curl -fsS --max-time 2 "http://${RAG_HOST}:${RAG_PORT}/health" >/dev/null 2>&1; then
      return 0
    fi
    sleep 1
  done
  docker_logs >&2 || true
  die "Docker RAG API did not become ready within ${attempts}s."
}

docker_install() {
  ensure_enabled
  mkdir -p "${RAG_DOCKER_INDEX_ABS}" "${PROJECT_ROOT}/.runtime/rag-cache" "${PROJECT_ROOT}/.runtime/rag-api-venv" "${PROJECT_ROOT}/.runtime/qdrant"
  docker_image_preflight
  if [[ "${RAG_DOCKER_PULL_POLICY}" == "missing" ]] && docker_images_present; then
    echo "Docker RAG images already present locally; skipping pull."
  else
    docker_compose pull
  fi
}

docker_preflight() {
  ensure_enabled
  docker_image_preflight
  echo "Docker RAG image preflight passed."
}

docker_index() {
  ensure_enabled
  docker_start
  docker_compose exec -T rag-api /venv/bin/python /app/scripts/rag-container-api.py index "$@"
}

docker_start() {
  ensure_enabled
  mkdir -p "${RAG_DOCKER_INDEX_ABS}" "${PROJECT_ROOT}/.runtime/rag-cache" "${PROJECT_ROOT}/.runtime/rag-api-venv" "${PROJECT_ROOT}/.runtime/qdrant"
  if ! docker_rag_running && [[ -n "$(port_service_pids)" ]]; then
    die "Host RAG is already listening on http://${RAG_HOST}:${RAG_PORT}. Stop it with RAG_RUNTIME=host make rag-stop before starting Docker RAG."
  fi
  docker_image_preflight
  docker_compose up -d
  wait_docker_api
  echo "RAG Docker service running: http://${RAG_HOST}:${RAG_PORT}"
}

docker_stop() {
  RAG_COMPOSE_ALLOW_MISSING_SOURCE=1 docker_compose down
}

docker_status() {
  if docker_rag_running; then
    echo "rag=docker-running container=${RAG_DOCKER_NAME} url=http://${RAG_HOST}:${RAG_PORT}"
    curl -fsS --max-time 2 "http://${RAG_HOST}:${RAG_PORT}/health" || true
    echo
  else
    echo "rag=docker-stopped container=${RAG_DOCKER_NAME} url=http://${RAG_HOST}:${RAG_PORT}"
    RAG_COMPOSE_ALLOW_MISSING_SOURCE=1 docker_compose ps -a || true
    return 1
  fi
}

docker_doctor() {
  if docker_rag_running; then
    curl -fsS --max-time 5 "http://${RAG_HOST}:${RAG_PORT}/health"
    echo
  else
    echo "rag=docker-stopped container=${RAG_DOCKER_NAME} url=http://${RAG_HOST}:${RAG_PORT}"
    RAG_COMPOSE_ALLOW_MISSING_SOURCE=1 docker_compose ps -a || true
    return 1
  fi
}

docker_search() {
  if docker_rag_running; then
    docker_compose exec -T rag-api /venv/bin/python /app/scripts/rag-container-api.py search "$@"
  else
    die "Docker RAG is not running. Start it with RAG_RUNTIME=docker make rag-up."
  fi
}

docker_logs() {
  RAG_COMPOSE_ALLOW_MISSING_SOURCE=1 docker_compose logs --tail "${RAG_LOG_LINES:-120}"
}

install_deps() {
  mkdir -p "${RAG_INDEX_ABS}"
  if [[ ! -x "${PYTHON_BIN}" ]]; then
    python3 -m venv "${RAG_VENV_ABS}"
  fi
  "${PYTHON_BIN}" -m pip install --upgrade pip wheel
  "${PYTHON_BIN}" -m pip install --upgrade lancedb fastapi uvicorn pydantic
  "${PYTHON_BIN}" -m pip install --upgrade pymupdf pillow pytesseract
  if [[ "${RAG_SPREADSHEETS_ENABLED:-1}" == "1" || "${RAG_SPREADSHEETS_ENABLED:-1}" == "true" ]]; then
    "${PYTHON_BIN}" -m pip install --upgrade openpyxl python-calamine
    if [[ "${INSTALL_RAG_DUCKDB:-0}" == "1" || "${INSTALL_RAG_DUCKDB:-0}" == "true" ]]; then
      "${PYTHON_BIN}" -m pip install --upgrade duckdb
    fi
  fi
  if [[ "${RAG_EMBEDDING_BACKEND}" != "hash" ]]; then
    "${PYTHON_BIN}" -m pip install --upgrade sentence-transformers
  fi

  local install_ocr="${INSTALL_RAG_OCR:-}"
  if [[ -z "${install_ocr}" ]]; then
    if [[ "${RAG_OCR_ENABLED:-1}" == "0" || "${RAG_OCR_ENABLED:-1}" == "false" ]]; then
      install_ocr=0
    else
      install_ocr=1
    fi
  fi

  if [[ "${install_ocr}" == "1" || "${install_ocr}" == "true" ]]; then
    if command -v brew >/dev/null 2>&1; then
      brew install tesseract
    else
      echo "WARN: Homebrew missing; install tesseract manually for OCR." >&2
    fi
    install_ocr_languages
  else
    echo "Skipping OCR system dependencies because INSTALL_RAG_OCR=0 or RAG_OCR_ENABLED=0."
  fi
}

install_ocr_languages() {
  mkdir -p "${RAG_OCR_TESSDATA_ABS}"

  local langs="${RAG_OCR_LANGUAGES:-rus+eng+deu}"
  local lang source file tmp
  IFS='+' read -r -a lang_parts <<< "${langs}"
  for lang in "${lang_parts[@]}"; do
    [[ -n "${lang}" ]] || continue
    file="${RAG_OCR_TESSDATA_ABS}/${lang}.traineddata"
    if [[ -s "${file}" ]]; then
      echo "ok OCR language: ${lang}"
      continue
    fi
    source="${RAG_OCR_LANGUAGE_SOURCE%/}/${lang}.traineddata"
    tmp="${file}.tmp"
    echo "Installing OCR language: ${lang}"
    curl -fL --retry 3 --connect-timeout 20 -o "${tmp}" "${source}"
    mv "${tmp}" "${file}"
  done
}

ensure_installed() {
  if [[ ! -x "${PYTHON_BIN}" ]]; then
    install_deps
  fi
}

service_pid() {
  if [[ -f "${PID_FILE}" ]]; then
    cat "${PID_FILE}"
  fi
}

service_running() {
  local pid
  pid="$(service_pid || true)"
  [[ -n "${pid}" ]] && kill -0 "${pid}" >/dev/null 2>&1
}

watch_pid() {
  if [[ -f "${WATCH_PID_FILE}" ]]; then
    cat "${WATCH_PID_FILE}"
  fi
}

watch_running() {
  local pid
  pid="$(watch_pid || true)"
  [[ -n "${pid}" ]] && kill -0 "${pid}" >/dev/null 2>&1
}

port_service_pids() {
  command -v lsof >/dev/null 2>&1 || return 0
  local pid
  while IFS= read -r pid; do
    [[ -n "${pid}" ]] || continue
    if ps -p "${pid}" -o command= 2>/dev/null | grep -F "${SCRIPT_DIR}/rag.py serve" >/dev/null; then
      printf '%s\n' "${pid}"
    fi
  done < <(lsof -tiTCP:"${RAG_PORT}" -sTCP:LISTEN 2>/dev/null || true)
}

start_service() {
  ensure_enabled
  ensure_installed
  mkdir -p "${RAG_INDEX_ABS}"
  if service_running; then
    echo "RAG service already running: pid=$(service_pid), url=http://${RAG_HOST}:${RAG_PORT}"
    return 0
  fi
  if docker_rag_running; then
    die "Docker RAG is already running on http://${RAG_HOST}:${RAG_PORT}. Stop it with RAG_RUNTIME=docker make rag-down before starting host RAG."
  fi
  RAG_BIND_HOST="${RAG_BIND_HOST}" RAG_HOST="${RAG_HOST}" RAG_PORT="${RAG_PORT}" \
    nohup "${PYTHON_BIN}" "${SCRIPT_DIR}/rag.py" serve >"${LOG_FILE}" 2>&1 &
  echo "$!" > "${PID_FILE}"
  sleep 1
  if ! service_running; then
    tail -n 80 "${LOG_FILE}" >&2 || true
    die "RAG service failed to start"
  fi
  echo "RAG service running: http://${RAG_HOST}:${RAG_PORT}"
}

start_watch() {
  ensure_enabled
  ensure_installed
  mkdir -p "${RAG_INDEX_ABS}"
  if watch_running; then
    echo "RAG watcher already running: pid=$(watch_pid), source=${RAG_SOURCE_PATH:-${OBSIDIAN_SHARED_PATH:-unset}}"
    return 0
  fi
  nohup "${PYTHON_BIN}" "${SCRIPT_DIR}/rag.py" watch >"${WATCH_LOG_FILE}" 2>&1 &
  echo "$!" > "${WATCH_PID_FILE}"
  sleep 1
  if ! watch_running; then
    tail -n 80 "${WATCH_LOG_FILE}" >&2 || true
    die "RAG watcher failed to start"
  fi
  echo "RAG watcher running: pid=$(watch_pid), source=${RAG_SOURCE_PATH:-${OBSIDIAN_SHARED_PATH:-unset}}"
}

stop_watch() {
  if watch_running; then
    kill "$(watch_pid)" >/dev/null 2>&1 || true
    rm -f "${WATCH_PID_FILE}"
    echo "RAG watcher stopped"
  else
    rm -f "${WATCH_PID_FILE}"
    echo "RAG watcher not running"
  fi
}

stop_service() {
  local stopped=0
  if service_running; then
    kill "$(service_pid)" >/dev/null 2>&1 || true
    rm -f "${PID_FILE}"
    stopped=1
  else
    rm -f "${PID_FILE}"
  fi

  local pid
  while IFS= read -r pid; do
    [[ -n "${pid}" ]] || continue
    kill "${pid}" >/dev/null 2>&1 || true
    stopped=1
  done < <(port_service_pids)

  if [[ "${stopped}" == "1" ]]; then
    echo "RAG service stopped"
  else
    echo "RAG service not running"
  fi
}

status_service() {
  if service_running; then
    echo "rag=running pid=$(service_pid) url=http://${RAG_HOST}:${RAG_PORT}"
    curl -fsS --max-time 2 "http://${RAG_HOST}:${RAG_PORT}/health" || true
    echo
  else
    echo "rag=stopped url=http://${RAG_HOST}:${RAG_PORT}"
  fi
  if watch_running; then
    echo "rag_watch=running pid=$(watch_pid) interval=${RAG_WATCH_INTERVAL_SECONDS:-20}s"
  else
    echo "rag_watch=stopped interval=${RAG_WATCH_INTERVAL_SECONDS:-20}s"
  fi
}


index_status() {
  local log_file
  if [[ "${RAG_RUNTIME}" == "docker" ]]; then
    log_file="${RAG_DOCKER_INDEX_ABS}/rag-index.log"
  else
    log_file="${RAG_INDEX_ABS}/rag-index.log"
  fi

  if [[ ! -f "${log_file}" ]]; then
    echo "rag_index=not_started  (no log found at ${log_file})"
    return 0
  fi

  # Extract latest progress counter [N/TOTAL]
  local progress_line current=0 total=0
  progress_line="$(grep -o '\[[0-9]*/[0-9]*\]' "${log_file}" | tail -1 || true)"
  if [[ "${progress_line}" =~ \[([0-9]+)/([0-9]+)\] ]]; then
    current="${BASH_REMATCH[1]}"
    total="${BASH_REMATCH[2]}"
  fi

  # Last file that was being indexed
  local last_file
  last_file="$(grep -o '\[[0-9]*/[0-9]*\] Indexing [^:]*' "${log_file}" 2>/dev/null | sed 's/\[[0-9]*\/[0-9]*\] Indexing //' | tail -1 || true)"

  # Detect if indexer process is still alive
  local running=0
  if pgrep -f "rag-control.sh index" > /dev/null 2>&1 || pgrep -f "rag-control index" > /dev/null 2>&1; then
    running=1
  fi

  if [[ "${total}" -gt 0 ]]; then
    local pct=$(( current * 100 / total ))
    if [[ "${running}" -eq 1 ]]; then
      printf "rag_index=running   %d/%d files (%d%%)\n" "${current}" "${total}" "${pct}"
    elif [[ "${current}" -ge "${total}" ]]; then
      printf "rag_index=complete  %d/%d files (100%%)\n" "${current}" "${total}"
    else
      printf "rag_index=stopped   %d/%d files (%d%%) — run 'make rag-index' to resume\n" "${current}" "${total}" "${pct}"
    fi
    [[ -n "${last_file}" ]] && printf "last_file=%s\n" "${last_file}"
  else
    if [[ "${running}" -eq 1 ]]; then
      echo "rag_index=running  (scanning files...)"
    else
      echo "rag_index=unknown  (no progress found in log — run 'make rag-index' to start)"
    fi
  fi
}

ACTION="${1:-}"
shift || true

case "${ACTION}" in
  install)
    case "${RAG_RUNTIME}" in
      docker) docker_install ;;
      host) ensure_host_runtime_allowed; install_deps; "${PYTHON_BIN}" "${SCRIPT_DIR}/rag.py" doctor || true ;;
      *) die "unsupported RAG_RUNTIME=${RAG_RUNTIME}. Use host or docker." ;;
    esac
    ;;
  preflight)
    case "${RAG_RUNTIME}" in
      docker) docker_preflight ;;
      host) ensure_host_runtime_allowed; echo "Host RAG has no Docker image preflight." ;;
      *) die "unsupported RAG_RUNTIME=${RAG_RUNTIME}. Use host or docker." ;;
    esac
    ;;
  index)
    case "${RAG_RUNTIME}" in
      docker) docker_index "$@" ;;
      host) ensure_host_runtime_allowed; ensure_enabled; ensure_installed; "${PYTHON_BIN}" "${SCRIPT_DIR}/rag.py" index "$@" ;;
      *) die "unsupported RAG_RUNTIME=${RAG_RUNTIME}. Use host or docker." ;;
    esac
    ;;
  sync)
    case "${RAG_RUNTIME}" in
      docker) docker_start; docker_index "$@" ;;
      host) ensure_host_runtime_allowed; ensure_enabled; ensure_installed; "${PYTHON_BIN}" "${SCRIPT_DIR}/rag.py" index "$@"; start_service ;;
      *) die "unsupported RAG_RUNTIME=${RAG_RUNTIME}. Use host or docker." ;;
    esac
    ;;
  search)
    case "${RAG_RUNTIME}" in
      docker) docker_search "$@" ;;
      host) ensure_host_runtime_allowed; ensure_enabled; ensure_installed; "${PYTHON_BIN}" "${SCRIPT_DIR}/rag.py" search "$@" ;;
      *) die "unsupported RAG_RUNTIME=${RAG_RUNTIME}. Use host or docker." ;;
    esac
    ;;
  start)
    case "${RAG_RUNTIME}" in
      docker) docker_start ;;
      host)
        ensure_host_runtime_allowed
        start_service
        if [[ "${RAG_AUTO_INDEX:-0}" == "1" || "${RAG_AUTO_INDEX:-0}" == "true" ]]; then
          start_watch
        fi
        ;;
      *) die "unsupported RAG_RUNTIME=${RAG_RUNTIME}. Use host or docker." ;;
    esac
    ;;
  stop)
    case "${RAG_RUNTIME}" in
      docker) docker_stop ;;
      host) stop_watch; stop_service ;;
      *) die "unsupported RAG_RUNTIME=${RAG_RUNTIME}. Use host or docker." ;;
    esac
    ;;
  restart)
    case "${RAG_RUNTIME}" in
      docker) docker_stop; docker_start ;;
      host)
        ensure_host_runtime_allowed
        stop_watch
        stop_service
        start_service
        if [[ "${RAG_AUTO_INDEX:-0}" == "1" || "${RAG_AUTO_INDEX:-0}" == "true" ]]; then
          start_watch
        fi
        ;;
      *) die "unsupported RAG_RUNTIME=${RAG_RUNTIME}. Use host or docker." ;;
    esac
    ;;
  up)
    RAG_RUNTIME=docker docker_start
    ;;
  down)
    RAG_RUNTIME=docker docker_stop
    ;;
  watch)
    [[ "${RAG_RUNTIME}" == "host" ]] || die "watch is only available for RAG_RUNTIME=host; Docker RAG indexes on startup or via rag-index."
    ensure_host_runtime_allowed
    ensure_enabled
    ensure_installed
    "${PYTHON_BIN}" "${SCRIPT_DIR}/rag.py" watch "$@"
    ;;
  watch-start)
    [[ "${RAG_RUNTIME}" == "host" ]] || die "watch-start is only available for RAG_RUNTIME=host."
    ensure_host_runtime_allowed
    start_watch
    ;;
  watch-stop)
    [[ "${RAG_RUNTIME}" == "host" ]] || die "watch-stop is only available for RAG_RUNTIME=host."
    stop_watch
    ;;
  watch-restart)
    [[ "${RAG_RUNTIME}" == "host" ]] || die "watch-restart is only available for RAG_RUNTIME=host."
    ensure_host_runtime_allowed
    stop_watch
    start_watch
    ;;
  watch-status)
    [[ "${RAG_RUNTIME}" == "host" ]] || die "watch-status is only available for RAG_RUNTIME=host."
    if watch_running; then
      echo "rag_watch=running pid=$(watch_pid) source=${RAG_SOURCE_PATH:-${OBSIDIAN_SHARED_PATH:-unset}}"
    else
      echo "rag_watch=stopped source=${RAG_SOURCE_PATH:-${OBSIDIAN_SHARED_PATH:-unset}}"
      exit 1
    fi
    ;;
  status)
    case "${RAG_RUNTIME}" in
      docker) docker_status ;;
      host) status_service ;;
      *) die "unsupported RAG_RUNTIME=${RAG_RUNTIME}. Use host or docker." ;;
    esac
    ;;
  doctor)
    case "${RAG_RUNTIME}" in
      docker) docker_doctor ;;
      host)
        ensure_host_runtime_allowed
        if [[ "${RAG_ENABLED}" != "1" && "${RAG_ENABLED}" != "true" ]]; then
          echo "rag=disabled"
          exit 0
        fi
        if [[ ! -x "${PYTHON_BIN}" ]]; then
          echo "rag_venv=missing path=${RAG_VENV_ABS}"
          echo "next=make rag-install"
          exit 2
        fi
        "${PYTHON_BIN}" "${SCRIPT_DIR}/rag.py" doctor
        ;;
      *) die "unsupported RAG_RUNTIME=${RAG_RUNTIME}. Use host or docker." ;;
    esac
    ;;
  health)
    case "${RAG_RUNTIME}" in
      docker) docker_doctor ;;
      host) ensure_host_runtime_allowed; ensure_installed; "${PYTHON_BIN}" "${SCRIPT_DIR}/rag.py" health ;;
      *) die "unsupported RAG_RUNTIME=${RAG_RUNTIME}. Use host or docker." ;;
    esac
    ;;
  logs)
    case "${RAG_RUNTIME}" in
      docker) docker_logs ;;
      host) tail -n "${RAG_LOG_LINES:-120}" "${LOG_FILE}" 2>/dev/null || true ;;
      *) die "unsupported RAG_RUNTIME=${RAG_RUNTIME}. Use host or docker." ;;
    esac
    ;;
  watch-logs)
    [[ "${RAG_RUNTIME}" == "host" ]] || die "watch-logs is only available for RAG_RUNTIME=host."
    tail -n "${RAG_LOG_LINES:-120}" "${WATCH_LOG_FILE}" 2>/dev/null || true
    ;;
  index-status)
    index_status
    ;;
  *)
    cat >&2 <<EOF
Usage: $0 <install|preflight|index|sync|search|start|stop|restart|up|down|status|doctor|health|logs|index-status|watch|watch-start|watch-stop|watch-restart|watch-status|watch-logs>
EOF
    exit 2
    ;;
esac
