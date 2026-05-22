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
  brew_install_cask_or_manual_admin multipass "/Applications/Multipass.app" "Install Multipass with an admin prompt from a normal terminal:
  brew install --cask multipass

Or download Canonical Multipass for macOS from:
  https://multipass.run/install"

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
  local key="$1"
  local value="$2"
  local escaped_value
  local tmp

  escaped_value="$(shell_quote "${value}")"
  tmp="$(mktemp)"

  if grep -q "^${key}=" "${ENV_FILE}"; then
    awk -v key="${key}" -v value="${escaped_value}" '
      BEGIN { replaced = 0 }
      $0 ~ "^" key "=" {
        print key "=" value
        replaced = 1
        next
      }
      { print }
      END {
        if (replaced == 0) {
          print key "=" value
        }
      }
    ' "${ENV_FILE}" > "${tmp}"
  else
    cp "${ENV_FILE}" "${tmp}"
    printf '%s=%s\n' "${key}" "${escaped_value}" >> "${tmp}"
  fi

  mv "${tmp}" "${ENV_FILE}"
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
  set_env_value SANDBOX_BACKEND "multipass"
  set_env_value MODEL_DIR "${model_dir}"
  set_env_value OMLX_PORT "8000"
  set_env_value LMSTUDIO_PORT "1234"
  set_env_value MODEL_BIND_HOST "0.0.0.0"
  set_env_value OPENAI_BASE_URL "http://localhost:8000/v1"
  set_env_value ANTHROPIC_BASE_URL "http://localhost:8000"
  set_env_value VM_NAME "omlx-agent-ubuntu"
  set_env_value VM_CPUS "4"
  set_env_value VM_MEMORY_MB "8192"
  set_env_value VM_MEMORY "8G"
  set_env_value VM_DISK_GB "80"
  set_env_value VM_DISK "80G"
  set_env_value VM_SSH_USER "agent"
  set_env_value VM_SSH_KEY "${HOME}/.ssh/omlx_agent_vm_ed25519"
  set_env_value USER_SSH_PUBLIC_KEY "${HOME}/.ssh/id_ed25519.pub"
  set_env_value VM_SNAPSHOT_NAME "clean-agent-base"
  set_env_value UBUNTU_MULTIPASS_IMAGE "24.04"
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
  set_env_value OPENCLAW_CONTROL_PORT "18789"

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
