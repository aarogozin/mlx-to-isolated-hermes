#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

BREW_BIN="/opt/homebrew/bin/brew"
ZPROFILE="${HOME}/.zprofile"
LMS_DIR="${HOME}/.lmstudio/bin"
LMS_BIN="${LMS_DIR}/lms"
ENV_FILE="${PROJECT_ROOT}/.env"
ENV_EXAMPLE="${PROJECT_ROOT}/.env.example"

log() {
  printf '\n==> %s\n' "$*"
}

warn() {
  printf 'WARN: %s\n' "$*" >&2
}

die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

append_line_once() {
  local file="$1"
  local line="$2"

  touch "$file"
  if ! grep -Fqx "$line" "$file"; then
    printf '\n%s\n' "$line" >> "$file"
  fi
}

shell_quote() {
  printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"
}

generate_local_api_key() {
  if command -v openssl >/dev/null 2>&1; then
    openssl rand -hex 24
  else
    LC_ALL=C tr -dc 'a-f0-9' < /dev/urandom | head -c 48
    printf '\n'
  fi
}

env_value() {
  local key="$1"

  if [[ ! -f "${ENV_FILE}" ]]; then
    return 0
  fi

  set -a
  # shellcheck disable=SC1090
  source "${ENV_FILE}"
  set +a
  printf '%s\n' "${!key:-}"
}

is_placeholder_secret() {
  local value="$1"
  local legacy_default

  legacy_default="$(printf 'b%s' 'ig7')"

  [[ -z "${value}" || "${value}" == "${legacy_default}" || "${value}" == "change-me" || "${value}" == "local-not-needed" ]]
}

require_apple_silicon_macos() {
  log "Checking host platform"

  if [[ "$(uname -s)" != "Darwin" ]]; then
    die "This bootstrap script targets macOS."
  fi

  if [[ "$(uname -m)" != "arm64" ]]; then
    die "This project targets Apple Silicon arm64 Macs."
  fi
}

ensure_homebrew() {
  log "Checking Homebrew"

  if ! command -v brew >/dev/null 2>&1 && [[ ! -x "${BREW_BIN}" ]]; then
    log "Installing Homebrew"
    /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
  fi

  if [[ -x "${BREW_BIN}" ]]; then
    eval "$("${BREW_BIN}" shellenv)"
    append_line_once "${ZPROFILE}" 'eval "$(/opt/homebrew/bin/brew shellenv)"'
  fi

  command -v brew >/dev/null 2>&1 || die "Homebrew install did not put brew on PATH."

  log "Updating Homebrew metadata"
  brew update --quiet
}

brew_install_formula() {
  local formula="$1"

  if brew list --formula --versions "$formula" >/dev/null 2>&1; then
    printf 'ok formula: %s\n' "$formula"
    return
  fi

  log "Installing formula: ${formula}"
  brew install "$formula"
}

brew_install_cask_if_app_missing() {
  local cask="$1"
  local app_path="$2"

  if brew list --cask --versions "$cask" >/dev/null 2>&1; then
    printf 'ok cask: %s\n' "$cask"
    return
  fi

  if [[ -n "${app_path}" && -e "${app_path}" ]]; then
    printf 'ok app: %s\n' "${app_path}"
    return
  fi

  log "Installing cask: ${cask}"
  brew install --cask "$cask"
}

brew_install_cask_or_manual_admin() {
  local cask="$1"
  local app_path="$2"
  local manual_message="$3"

  if brew list --cask --versions "$cask" >/dev/null 2>&1; then
    printf 'ok cask: %s\n' "$cask"
    return
  fi

  if [[ -n "${app_path}" && -e "${app_path}" ]]; then
    printf 'ok app: %s\n' "${app_path}"
    return
  fi

  log "Installing cask: ${cask}"
  if brew install --cask "$cask"; then
    return
  fi

  warn "Could not install ${cask} non-interactively. It likely needs an administrator password."
  cat <<EOF >&2
${manual_message}

After installing it, rerun:
  make bootstrap
EOF
  return 1
}

truthy() {
  case "${1:-}" in
    1|true|yes|on) return 0 ;;
    *) return 1 ;;
  esac
}

install_rag_ocr_languages() {
  local langs="${RAG_OCR_LANGUAGES:-$(env_value RAG_OCR_LANGUAGES)}"
  local tessdata_path="${RAG_OCR_TESSDATA_PATH:-$(env_value RAG_OCR_TESSDATA_PATH)}"
  local language_source="${RAG_OCR_LANGUAGE_SOURCE:-$(env_value RAG_OCR_LANGUAGE_SOURCE)}"
  langs="${langs:-rus+eng+deu}"
  tessdata_path="${tessdata_path:-.runtime/tessdata}"
  language_source="${language_source:-https://raw.githubusercontent.com/tesseract-ocr/tessdata_fast/main}"

  case "${tessdata_path}" in
    /*) ;;
    *) tessdata_path="${PROJECT_ROOT}/${tessdata_path}" ;;
  esac

  mkdir -p "${tessdata_path}"

  local lang file tmp source
  IFS='+' read -r -a lang_parts <<< "${langs}"
  for lang in "${lang_parts[@]}"; do
    [[ -n "${lang}" ]] || continue
    file="${tessdata_path}/${lang}.traineddata"
    if [[ -s "${file}" ]]; then
      printf 'ok OCR language: %s\n' "${lang}"
      continue
    fi
    source="${language_source%/}/${lang}.traineddata"
    tmp="${file}.tmp"
    log "Installing OCR language: ${lang}"
    curl -fL --retry 3 --connect-timeout 20 -o "${tmp}" "${source}"
    mv "${tmp}" "${file}"
  done
}

ensure_tap() {
  local tap="$1"
  local url="$2"

  if brew tap | grep -Fqx "$tap"; then
    printf 'ok tap: %s\n' "$tap"
    return
  fi

  log "Adding Homebrew tap: ${tap}"
  brew tap "$tap" "$url"
}

install_core_tools() {
  log "Installing core CLI tools"

  brew_install_formula git
  brew_install_formula jq
  brew_install_formula yq
  brew_install_formula curl
  brew_install_formula wget
  brew_install_formula coreutils
  brew_install_formula uv
  brew_install_formula pipx
  brew_install_formula node@24
  brew_install_formula pnpm

  if brew --prefix node@24 >/dev/null 2>&1; then
    local node_path
    node_path="$(brew --prefix node@24)/bin"
    append_line_once "${ZPROFILE}" 'export PATH="/opt/homebrew/opt/node@24/bin:$PATH"'
    export PATH="${node_path}:${PATH}"
  fi
}

install_apps_and_runtimes() {
  log "Installing app and runtime dependencies"

  brew_install_cask_if_app_missing lm-studio "/Applications/LM Studio.app"
  brew_install_cask_if_app_missing docker-desktop "/Applications/Docker.app"


  ensure_tap jundot/omlx https://github.com/jundot/omlx

  if [[ "${INSTALL_OMLX_GRAMMAR:-0}" == "1" ]]; then
    log "Installing oMLX with structured-output grammar support"
    if brew list --formula --versions jundot/omlx/omlx >/dev/null 2>&1; then
      brew reinstall jundot/omlx/omlx --with-grammar
    else
      brew install jundot/omlx/omlx --with-grammar
    fi
  else
    brew_install_formula jundot/omlx/omlx
  fi

  local rag_runtime rag_ocr_enabled install_rag_ocr install_rag_host
  rag_runtime="${RAG_RUNTIME:-$(env_value RAG_RUNTIME)}"
  rag_runtime="${rag_runtime:-docker}"
  rag_ocr_enabled="${RAG_OCR_ENABLED:-$(env_value RAG_OCR_ENABLED)}"
  rag_ocr_enabled="${rag_ocr_enabled:-1}"
  install_rag_ocr="${INSTALL_RAG_OCR:-$(env_value INSTALL_RAG_OCR)}"
  install_rag_ocr="${install_rag_ocr:-0}"
  install_rag_host="${INSTALL_RAG_HOST:-$(env_value INSTALL_RAG_HOST)}"
  install_rag_host="${install_rag_host:-0}"

  if [[ "${rag_runtime}" == "host" ]] && truthy "${install_rag_host}" && truthy "${rag_ocr_enabled}" && truthy "${install_rag_ocr}"; then
    log "Installing RAG OCR system dependencies"
    brew_install_formula tesseract
    install_rag_ocr_languages
  else
    printf 'ok rag OCR system deps: skipped\n'
  fi
}

ensure_lmstudio_path() {
  log "Configuring LM Studio CLI path"

  append_line_once "${ZPROFILE}" 'export PATH="$HOME/.lmstudio/bin:$PATH"'
  export PATH="${LMS_DIR}:${PATH}"
}

verify_lms() {
  log "Verifying LM Studio CLI"

  if [[ -x "${LMS_BIN}" ]]; then
    "${LMS_BIN}" --help >/dev/null
    printf 'ok lms: %s\n' "${LMS_BIN}"
    return
  fi

  if command -v lms >/dev/null 2>&1; then
    lms --help >/dev/null
    printf 'ok lms: %s\n' "$(command -v lms)"
    return
  fi

  die "LM Studio is installed, but lms is not initialized. Launch LM Studio once, then rerun make bootstrap."
}

detect_lmstudio_model_dir() {
  if [[ -n "${LMSTUDIO_MODEL_DIR:-}" ]]; then
    printf '%s\n' "${LMSTUDIO_MODEL_DIR}"
    return
  fi

  local candidates=(
    "${HOME}/.lmstudio/models"
    "${HOME}/Library/Application Support/LM Studio/models"
  )

  local candidate
  for candidate in "${candidates[@]}"; do
    if [[ -d "${candidate}" ]]; then
      printf '%s\n' "${candidate}"
      return
    fi
  done

  printf '%s\n' "${HOME}/.lmstudio/models"
}

set_env_value() {
  "${SCRIPT_DIR}/env-set.sh" "${ENV_FILE}" "$1" "$2"
}

configure_project_env() {
  log "Configuring project .env"

  if [[ ! -f "${ENV_FILE}" ]]; then
    cp "${ENV_EXAMPLE}" "${ENV_FILE}"
  fi

  local model_dir
  local existing_openai_key
  local existing_anthropic_key
  local local_api_key
  model_dir="$(detect_lmstudio_model_dir)"
  existing_openai_key="$(env_value OPENAI_API_KEY)"
  existing_anthropic_key="$(env_value ANTHROPIC_API_KEY)"

  mkdir -p "${model_dir}"

  if is_placeholder_secret "${existing_openai_key}"; then
    local_api_key="$(generate_local_api_key)"
    set_env_value OPENAI_API_KEY "${local_api_key}"
    existing_openai_key="${local_api_key}"
  fi

  if is_placeholder_secret "${existing_anthropic_key}"; then
    set_env_value ANTHROPIC_API_KEY "${existing_openai_key}"
  fi

  set_env_value MODEL_BACKEND "omlx"
  set_env_value AGENT_RUNTIME "hermes"
  set_env_value SANDBOX_BACKEND "docker"
  set_env_value MODEL_DIR "${model_dir}"
  set_env_value OLLAMA_MODELS "${HOME}/.ollama/models"
  set_env_value MODEL_CLEAN_MIN_AGE_HOURS "1"
  set_env_value RAG_ENABLED "1"
  [[ -n "$(env_value RAG_RUNTIME)" ]] || set_env_value RAG_RUNTIME "docker"
  [[ -n "$(env_value RAG_SOURCE_PATH)" ]] || set_env_value RAG_SOURCE_PATH '${OBSIDIAN_SHARED_PATH:-}'
  [[ -n "$(env_value RAG_INDEX_PATH)" ]] || set_env_value RAG_INDEX_PATH ".runtime/rag"
  [[ -n "$(env_value RAG_HOST)" ]] || set_env_value RAG_HOST "127.0.0.1"
  [[ -n "$(env_value RAG_BIND_HOST)" ]] || set_env_value RAG_BIND_HOST "0.0.0.0"
  [[ -n "$(env_value RAG_PORT)" ]] || set_env_value RAG_PORT "8765"
  [[ -n "$(env_value RAG_BASE_URL)" ]] || set_env_value RAG_BASE_URL "http://127.0.0.1:8765"
  [[ -n "$(env_value RAG_BASE_URL_GUEST)" ]] || set_env_value RAG_BASE_URL_GUEST "http://rag-host.internal:8765"
  [[ -n "$(env_value RAG_BASE_URL_DOCKER)" ]] || set_env_value RAG_BASE_URL_DOCKER "http://rag-host.internal:8765"
  [[ -n "$(env_value RAG_EMBEDDING_MODEL)" ]] || set_env_value RAG_EMBEDDING_MODEL "intfloat/multilingual-e5-small"
  [[ -n "$(env_value RAG_EMBEDDING_BACKEND)" ]] || set_env_value RAG_EMBEDDING_BACKEND "sentence-transformers"
  [[ -n "$(env_value RAG_TEXT_EXTENSIONS)" ]] || set_env_value RAG_TEXT_EXTENSIONS ".md,.txt,.rst,.csv,.tsv,.json,.yaml,.yml,.toml,.xml,.html,.xlsx,.xlsm,.xls,.xlsb,.ods,.pdf,.png,.jpg,.jpeg,.tif,.tiff"
  [[ -n "$(env_value RAG_EXCLUDE_GLOBS)" ]] || set_env_value RAG_EXCLUDE_GLOBS ".git/**,.obsidian/**,node_modules/**,.trash/**,*.env,*.key,*.pem"
  [[ -n "$(env_value RAG_MAX_FILE_MB)" ]] || set_env_value RAG_MAX_FILE_MB "10"
  [[ -n "$(env_value RAG_DOCUMENT_MAX_FILE_MB)" ]] || set_env_value RAG_DOCUMENT_MAX_FILE_MB "50"
  [[ -n "$(env_value RAG_CHUNK_TOKENS)" ]] || set_env_value RAG_CHUNK_TOKENS "800"
  [[ -n "$(env_value RAG_CHUNK_OVERLAP_TOKENS)" ]] || set_env_value RAG_CHUNK_OVERLAP_TOKENS "120"
  [[ -n "$(env_value RAG_TOP_K)" ]] || set_env_value RAG_TOP_K "8"
  [[ -n "$(env_value RAG_AUTO_INDEX)" ]] || set_env_value RAG_AUTO_INDEX "1"
  [[ -n "$(env_value RAG_WATCH_INTERVAL_SECONDS)" ]] || set_env_value RAG_WATCH_INTERVAL_SECONDS "20"
  [[ -n "$(env_value RAG_WATCH_DEBOUNCE_SECONDS)" ]] || set_env_value RAG_WATCH_DEBOUNCE_SECONDS "3"
  [[ -n "$(env_value RAG_SPREADSHEETS_ENABLED)" ]] || set_env_value RAG_SPREADSHEETS_ENABLED "1"
  [[ -n "$(env_value RAG_SPREADSHEET_MAX_FILE_MB)" ]] || set_env_value RAG_SPREADSHEET_MAX_FILE_MB "50"
  [[ -n "$(env_value RAG_SPREADSHEET_MAX_ROWS_PER_CHUNK)" ]] || set_env_value RAG_SPREADSHEET_MAX_ROWS_PER_CHUNK "50"
  [[ -n "$(env_value RAG_SPREADSHEET_MAX_ROWS_FULL)" ]] || set_env_value RAG_SPREADSHEET_MAX_ROWS_FULL "5000"
  [[ -n "$(env_value RAG_SPREADSHEET_INCLUDE_HIDDEN)" ]] || set_env_value RAG_SPREADSHEET_INCLUDE_HIDDEN "0"
  [[ -n "$(env_value RAG_SPREADSHEET_INCLUDE_FORMULAS)" ]] || set_env_value RAG_SPREADSHEET_INCLUDE_FORMULAS "1"
  [[ -n "$(env_value RAG_SPREADSHEET_INCLUDE_COMMENTS)" ]] || set_env_value RAG_SPREADSHEET_INCLUDE_COMMENTS "1"
  [[ -n "$(env_value RAG_PDF_ENABLED)" ]] || set_env_value RAG_PDF_ENABLED "1"
  [[ -n "$(env_value RAG_IMAGES_ENABLED)" ]] || set_env_value RAG_IMAGES_ENABLED "1"
  [[ -n "$(env_value RAG_OCR_ENABLED)" ]] || set_env_value RAG_OCR_ENABLED "1"
  [[ -n "$(env_value RAG_OCR_MODE)" ]] || set_env_value RAG_OCR_MODE "needed"
  [[ -n "$(env_value RAG_OCR_LANGUAGES)" ]] || set_env_value RAG_OCR_LANGUAGES "rus+eng+deu"
  [[ -n "$(env_value RAG_OCR_TESSDATA_PATH)" ]] || set_env_value RAG_OCR_TESSDATA_PATH ".runtime/tessdata"
  [[ -n "$(env_value RAG_OCR_LANGUAGE_SOURCE)" ]] || set_env_value RAG_OCR_LANGUAGE_SOURCE "https://raw.githubusercontent.com/tesseract-ocr/tessdata_fast/main"
  [[ -n "$(env_value RAG_OCR_MIN_TEXT_CHARS)" ]] || set_env_value RAG_OCR_MIN_TEXT_CHARS "200"
  [[ -n "$(env_value RAG_OCR_MAX_PAGES)" ]] || set_env_value RAG_OCR_MAX_PAGES "25"
  [[ -n "$(env_value RAG_OCR_DPI)" ]] || set_env_value RAG_OCR_DPI "200"
  [[ -n "$(env_value INSTALL_RAG_OCR)" ]] || set_env_value INSTALL_RAG_OCR "0"
  [[ -n "$(env_value RAG_DOCKER_NAME)" ]] || set_env_value RAG_DOCKER_NAME "mlx-isolated-rag"
  [[ -n "$(env_value RAG_DOCKER_PROJECT)" ]] || set_env_value RAG_DOCKER_PROJECT "mlx-isolated-rag"
  [[ -n "$(env_value RAG_DOCKER_INDEX_PATH)" ]] || set_env_value RAG_DOCKER_INDEX_PATH ".runtime/rag-docker"
  [[ -n "$(env_value RAG_API_IMAGE)" ]] || set_env_value RAG_API_IMAGE "python:3.12-slim"
  [[ -n "$(env_value RAG_QDRANT_IMAGE)" ]] || set_env_value RAG_QDRANT_IMAGE "qdrant/qdrant:latest"
  [[ -n "$(env_value RAG_TEI_IMAGE)" ]] || set_env_value RAG_TEI_IMAGE "ghcr.io/huggingface/text-embeddings-inference:cpu-arm64-latest"
  [[ -n "$(env_value RAG_TIKA_IMAGE)" ]] || set_env_value RAG_TIKA_IMAGE "apache/tika:latest-full"
  [[ -n "$(env_value RAG_DOCLING_IMAGE)" ]] || set_env_value RAG_DOCLING_IMAGE "quay.io/docling-project/docling-serve:latest"
  [[ -n "$(env_value RAG_DOCKER_EMBEDDING_BACKEND)" ]] || set_env_value RAG_DOCKER_EMBEDDING_BACKEND "tei"
  [[ -n "$(env_value RAG_DOCKER_START_TIMEOUT_SECONDS)" ]] || set_env_value RAG_DOCKER_START_TIMEOUT_SECONDS "600"
  [[ -n "$(env_value INSTALL_RAG_HOST)" ]] || set_env_value INSTALL_RAG_HOST "0"
  [[ -n "$(env_value RAG_AUTO_INDEX_ON_START)" ]] || set_env_value RAG_AUTO_INDEX_ON_START "1"
  [[ -n "$(env_value MATRIX_MODES)" ]] || set_env_value MATRIX_MODES "hermes/docker openclaw/docker"
  [[ -n "$(env_value MATRIX_RAG_QUERY)" ]] || set_env_value MATRIX_RAG_QUERY "OpenClaw"
  [[ -n "$(env_value MATRIX_CHAT_TIMEOUT_SECONDS)" ]] || set_env_value MATRIX_CHAT_TIMEOUT_SECONDS "180"
  [[ -n "$(env_value MATRIX_CLEAN_MODE)" ]] || set_env_value MATRIX_CLEAN_MODE "once"
  [[ -n "$(env_value MATRIX_TELEGRAM)" ]] || set_env_value MATRIX_TELEGRAM "disabled"
  [[ -n "$(env_value MATRIX_FINAL_ACTION)" ]] || set_env_value MATRIX_FINAL_ACTION "pause"
  set_env_value OMLX_PORT "8000"
  set_env_value LMSTUDIO_PORT "1234"
  set_env_value MODEL_BIND_HOST "0.0.0.0"
  set_env_value OPENAI_BASE_URL "http://localhost:8000/v1"
  set_env_value ANTHROPIC_BASE_URL "http://localhost:8000"

  set_env_value DOCKER_NAME "omlx-agent-docker"
  set_env_value HERMES_IMAGE "nousresearch/hermes-agent:latest"
  set_env_value DOCKER_DATA_VOLUME "omlx-agent-docker-data"
  set_env_value DOCKER_WORKSPACE_VOLUME "omlx-agent-docker-workspace"
  set_env_value DOCKER_CPUS "2"
  set_env_value DOCKER_MEMORY "4g"
  set_env_value DOCKER_SHM_SIZE "1g"
  set_env_value DOCKER_DASHBOARD_PORT "9120"
  set_env_value HERMES_GATEWAY_API_PORT "8642"
  set_env_value DOCKER_GATEWAY_API_PORT "8642"
  set_env_value OPENAI_BASE_URL_DOCKER "http://host.docker.internal:8000/v1"
  set_env_value ANTHROPIC_BASE_URL_DOCKER "http://host.docker.internal:8000"
  set_env_value OPENCLAW_IMAGE "ghcr.io/openclaw/openclaw:latest"
  set_env_value OPENCLAW_PULL_POLICY "latest"
  set_env_value OPENCLAW_CONTROL_PORT "18789"
  set_env_value OPENCLAW_BRIDGE_PORT "18790"
  [[ -n "$(env_value OPENCLAW_CONTROL_ALLOWED_ORIGINS)" ]] || set_env_value OPENCLAW_CONTROL_ALLOWED_ORIGINS ""
  if is_placeholder_secret "$(env_value OPENCLAW_GATEWAY_TOKEN)"; then
    set_env_value OPENCLAW_GATEWAY_TOKEN "$(generate_local_api_key)"
  fi
  set_env_value OPENCLAW_DOCKER_NAME "omlx-agent-openclaw-docker"
  set_env_value OPENCLAW_DOCKER_CONFIG_VOLUME "omlx-agent-openclaw-config"
  set_env_value OPENCLAW_DOCKER_WORKSPACE_VOLUME "omlx-agent-openclaw-workspace"
  set_env_value OPENCLAW_DOCKER_AUTH_VOLUME "omlx-agent-openclaw-auth"
  set_env_value OPENCLAW_OPENAI_BASE_URL_DOCKER "http://host.docker.internal:8000/v1"
  set_env_value OPENCLAW_OPENAI_BASE_URL_GUEST "http://model-host.internal:8000/v1"

  printf 'ok model dir: %s\n' "${model_dir}"
}

verify_omlx() {
  log "Verifying oMLX"

  command -v omlx >/dev/null 2>&1 || die "omlx is not available on PATH after installation."
  omlx --help >/dev/null
  omlx serve --help >/dev/null || warn "omlx serve --help failed; check oMLX installation."
  brew services info jundot/omlx/omlx >/dev/null || warn "brew services info for oMLX failed."
  printf 'ok omlx: %s\n' "$(command -v omlx)"
}

verify_docker() {
  log "Verifying Docker Desktop"

  if [[ ! -d "/Applications/Docker.app" ]]; then
    die "Docker Desktop install did not create /Applications/Docker.app."
  fi

  if command -v docker >/dev/null 2>&1; then
    docker --version
  else
    warn "docker CLI is not on PATH yet. Launch Docker Desktop once, then rerun doctor."
  fi
}

print_next_steps() {
  log "Bootstrap complete"
  cat <<EOF
Next:
  make doctor
  make models-search       # wraps: lms get --mlx
  make models-list         # wraps: lms ls --json
  make model-start-bg      # serves LM Studio model dir with oMLX
  make rag-up              # Dockerized RAG/OCR services

Project env:
  ${ENV_FILE}
EOF
}

main() {
  require_apple_silicon_macos
  ensure_homebrew
  install_core_tools
  install_apps_and_runtimes
  ensure_lmstudio_path
  verify_lms
  configure_project_env
  verify_omlx
  verify_docker
  print_next_steps
}

main "$@"
