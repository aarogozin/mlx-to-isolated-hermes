#!/usr/bin/env bash
# scripts/agents-install.sh — Install Hermes inside the Multipass agent VM.
# Reads all configuration from .env.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
ENV_FILE="${PROJECT_ROOT}/.env"

OVERRIDE_VM_NAME="${VM_NAME:-}"

if [[ -f "${ENV_FILE}" ]]; then
  set -a
  # shellcheck disable=SC1090
  source "${ENV_FILE}"
  set +a
fi

# shellcheck source=vm-common.sh
source "${SCRIPT_DIR}/vm-common.sh"

VM_NAME="${OVERRIDE_VM_NAME:-${HERMES_VM_NAME:-${VM_NAME:-omlx-agent-ubuntu}}}"
VM_SSH_USER="${VM_SSH_USER:-agent}"
OPENAI_BASE_URL_GUEST="${OPENAI_BASE_URL_GUEST:-http://model-host.internal:8000/v1}"
ANTHROPIC_BASE_URL_GUEST="${ANTHROPIC_BASE_URL_GUEST:-http://model-host.internal:8000}"
OPENAI_API_KEY="${OPENAI_API_KEY:-}"
ANTHROPIC_API_KEY="${ANTHROPIC_API_KEY:-${OPENAI_API_KEY}}"
MODEL_NAME="${MODEL_NAME:-local-model}"
TELEGRAM_BOT_TOKEN="${TELEGRAM_BOT_TOKEN:-}"
TELEGRAM_USER_ID="${TELEGRAM_USER_ID:-}"
TELEGRAM_ALLOWED_USERS="${TELEGRAM_ALLOWED_USERS:-}"
TELEGRAM_GROUP_ALLOWED_USERS="${TELEGRAM_GROUP_ALLOWED_USERS:-}"
TELEGRAM_GROUP_ALLOWED_CHATS="${TELEGRAM_GROUP_ALLOWED_CHATS:-}"
GATEWAY_ALLOWED_USERS="${GATEWAY_ALLOWED_USERS:-}"
GATEWAY_ALLOW_ALL_USERS="${GATEWAY_ALLOW_ALL_USERS:-false}"
HERMES_INSTALL_TIMEOUT_SECONDS="${HERMES_INSTALL_TIMEOUT_SECONDS:-900}"
HERMES_INSTALL_RETRIES="${HERMES_INSTALL_RETRIES:-3}"
HERMES_REF="${HERMES_REF:-main}"

if [[ -n "${TELEGRAM_USER_ID}" ]]; then
  TELEGRAM_ALLOWED_USERS="${TELEGRAM_ALLOWED_USERS:-${TELEGRAM_USER_ID}}"
  GATEWAY_ALLOWED_USERS="${GATEWAY_ALLOWED_USERS:-${TELEGRAM_USER_ID}}"
fi

die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

[[ -n "${OPENAI_API_KEY}" ]] || die "OPENAI_API_KEY missing. Run make bootstrap or set it in .env."

install_vm() {
  require_vm_ready

  # ── Transfer the installer script to the guest ──
  vm_transfer - /tmp/install-agents.sh <<'INSTALLER'
#!/usr/bin/env bash
set -euo pipefail

AGENT_USER="${AGENT_USER:-agent}"
OPENAI_BASE_URL="${OPENAI_BASE_URL:-http://model-host.internal:8000/v1}"
ANTHROPIC_BASE_URL="${ANTHROPIC_BASE_URL:-http://model-host.internal:8000}"
OPENAI_API_KEY="${OPENAI_API_KEY:-}"
ANTHROPIC_API_KEY="${ANTHROPIC_API_KEY:-${OPENAI_API_KEY}}"
MODEL_NAME="${MODEL_NAME:-local-model}"
TELEGRAM_BOT_TOKEN="${TELEGRAM_BOT_TOKEN:-}"
TELEGRAM_USER_ID="${TELEGRAM_USER_ID:-}"
TELEGRAM_ALLOWED_USERS="${TELEGRAM_ALLOWED_USERS:-}"
TELEGRAM_GROUP_ALLOWED_USERS="${TELEGRAM_GROUP_ALLOWED_USERS:-}"
TELEGRAM_GROUP_ALLOWED_CHATS="${TELEGRAM_GROUP_ALLOWED_CHATS:-}"
GATEWAY_ALLOWED_USERS="${GATEWAY_ALLOWED_USERS:-}"
GATEWAY_ALLOW_ALL_USERS="${GATEWAY_ALLOW_ALL_USERS:-false}"
HERMES_INSTALL_TIMEOUT_SECONDS="${HERMES_INSTALL_TIMEOUT_SECONDS:-900}"
HERMES_INSTALL_RETRIES="${HERMES_INSTALL_RETRIES:-3}"
HERMES_REF="${HERMES_REF:-main}"

[[ -n "${OPENAI_API_KEY}" ]] || {
  echo "ERROR: OPENAI_API_KEY missing." >&2
  exit 1
}

if [[ "$(id -u)" -ne 0 ]]; then
  exec sudo -E \
    AGENT_USER="${AGENT_USER}" \
    OPENAI_BASE_URL="${OPENAI_BASE_URL}" \
    ANTHROPIC_BASE_URL="${ANTHROPIC_BASE_URL}" \
    OPENAI_API_KEY="${OPENAI_API_KEY}" \
    ANTHROPIC_API_KEY="${ANTHROPIC_API_KEY}" \
    MODEL_NAME="${MODEL_NAME}" \
    TELEGRAM_BOT_TOKEN="${TELEGRAM_BOT_TOKEN}" \
    TELEGRAM_USER_ID="${TELEGRAM_USER_ID}" \
    TELEGRAM_ALLOWED_USERS="${TELEGRAM_ALLOWED_USERS}" \
    TELEGRAM_GROUP_ALLOWED_USERS="${TELEGRAM_GROUP_ALLOWED_USERS}" \
    TELEGRAM_GROUP_ALLOWED_CHATS="${TELEGRAM_GROUP_ALLOWED_CHATS}" \
    GATEWAY_ALLOWED_USERS="${GATEWAY_ALLOWED_USERS}" \
    GATEWAY_ALLOW_ALL_USERS="${GATEWAY_ALLOW_ALL_USERS}" \
    HERMES_INSTALL_TIMEOUT_SECONDS="${HERMES_INSTALL_TIMEOUT_SECONDS}" \
    HERMES_INSTALL_RETRIES="${HERMES_INSTALL_RETRIES}" \
    HERMES_REF="${HERMES_REF}" \
    bash "$0"
fi

apt-get update
DEBIAN_FRONTEND=noninteractive apt-get install -y \
  ca-certificates curl git gnupg jq python3 python3-pip python3-venv ripgrep

node_major="$(node -p "Number(process.versions.node.split('.')[0])" 2>/dev/null || echo 0)"
if [[ "${node_major}" -lt 20 ]]; then
  curl -fsSL https://deb.nodesource.com/setup_22.x | bash -
  DEBIAN_FRONTEND=noninteractive apt-get install -y nodejs
fi
npm install -g pnpm@10

install -d -o "${AGENT_USER}" -g "${AGENT_USER}" \
  "/home/${AGENT_USER}/workspace" \
  "/home/${AGENT_USER}/.local/bin" \
  "/home/${AGENT_USER}/.local/share" \
  "/home/${AGENT_USER}/.hermes"
chown -R "${AGENT_USER}:${AGENT_USER}" \
  "/home/${AGENT_USER}/.local" \
  "/home/${AGENT_USER}/workspace" \
  "/home/${AGENT_USER}/.hermes"

sudo -Hu "${AGENT_USER}" env \
  HOME="/home/${AGENT_USER}" \
  USER="${AGENT_USER}" \
  LOGNAME="${AGENT_USER}" \
  HERMES_INSTALL_TIMEOUT_SECONDS="${HERMES_INSTALL_TIMEOUT_SECONDS}" \
  HERMES_INSTALL_RETRIES="${HERMES_INSTALL_RETRIES}" \
  HERMES_REF="${HERMES_REF}" \
  bash -c '
    set -euo pipefail
    export PATH="$HOME/.local/bin:$PATH"
    if command -v hermes >/dev/null 2>&1; then
      exit 0
    fi

    install_dir="$HOME/.hermes/hermes-agent"
    archive_url="https://github.com/NousResearch/hermes-agent/archive/refs/heads/${HERMES_REF}.tar.gz"
    work_dir="$(mktemp -d)"
    cleanup() {
      rm -rf "$work_dir"
    }
    trap cleanup EXIT

    for attempt in $(seq 1 "${HERMES_INSTALL_RETRIES}"); do
      if [[ -d "$HOME/.hermes/hermes-agent" && ! -x "$HOME/.hermes/hermes-agent/venv/bin/hermes" ]]; then
        rm -rf "$HOME/.hermes/hermes-agent"
      fi

      rm -rf "$work_dir/hermes-src" "$work_dir/hermes.tar.gz"
      mkdir -p "$work_dir/hermes-src"

      echo "Installing Hermes from GitHub archive (${HERMES_REF}), attempt ${attempt}/${HERMES_INSTALL_RETRIES}..."
      if timeout "${HERMES_INSTALL_TIMEOUT_SECONDS}s" \
        curl -L --fail --retry 5 --retry-delay 3 --connect-timeout 10 \
          -o "$work_dir/hermes.tar.gz" "$archive_url" && \
        tar -xzf "$work_dir/hermes.tar.gz" -C "$work_dir/hermes-src" --strip-components=1; then
        rm -rf "$install_dir"
        mkdir -p "$(dirname "$install_dir")"
        mv "$work_dir/hermes-src" "$install_dir"
        cd "$install_dir"

        if ! command -v uv >/dev/null 2>&1; then
          curl -LsSf https://astral.sh/uv/install.sh | sh
          export PATH="$HOME/.local/bin:$PATH"
        fi

        export UV_NO_CONFIG=1
        uv python install 3.11 >/dev/null
        uv venv venv --python 3.11

        if [[ -f uv.lock ]]; then
          if ! UV_PROJECT_ENVIRONMENT="$install_dir/venv" uv sync --extra all --locked; then
            echo "uv sync failed; falling back to editable install tiers..." >&2
            if ! uv pip install --python "$install_dir/venv/bin/python" -e ".[all]"; then
              uv pip install --python "$install_dir/venv/bin/python" -e "."
            fi
          fi
        else
          if ! uv pip install --python "$install_dir/venv/bin/python" -e ".[all]"; then
            uv pip install --python "$install_dir/venv/bin/python" -e "."
          fi
        fi

        if [[ ! -x "$install_dir/venv/bin/hermes" ]]; then
          echo "Hermes entrypoint missing after install: $install_dir/venv/bin/hermes" >&2
          exit 1
        fi

        mkdir -p "$HOME/.local/bin"
        cat > "$HOME/.local/bin/hermes" <<EOF
#!/usr/bin/env bash
unset PYTHONPATH PYTHONHOME
export HERMES_HOME="\${HERMES_HOME:-\$HOME/.hermes}"
exec "$install_dir/venv/bin/hermes" "\$@"
EOF
        chmod +x "$HOME/.local/bin/hermes"

        if [[ -f "$install_dir/tools/skills_sync.py" ]]; then
          "$install_dir/venv/bin/python" "$install_dir/tools/skills_sync.py" || true
        fi

        exit 0
      fi
      if [[ "${attempt}" -lt "${HERMES_INSTALL_RETRIES}" ]]; then
        echo "Hermes install failed on attempt ${attempt}/${HERMES_INSTALL_RETRIES}; retrying in 10s..." >&2
        sleep 10
      fi
    done

    echo "ERROR: Hermes install failed after ${HERMES_INSTALL_RETRIES} attempt(s)." >&2
    echo "Retry later with ./scripts/agents-install.sh or increase HERMES_INSTALL_TIMEOUT_SECONDS." >&2
    exit 1
  '

sudo -Hu "${AGENT_USER}" env \
  HOME="/home/${AGENT_USER}" \
  USER="${AGENT_USER}" \
  LOGNAME="${AGENT_USER}" \
  bash -c \
  'cd "$HOME"; python_bin="$HOME/.hermes/hermes-agent/venv/bin/python"; if [[ -x "$python_bin" ]] && ! "$python_bin" -c "import telegram" >/dev/null 2>&1; then if command -v uv >/dev/null 2>&1; then uv pip install --python "$python_bin" "python-telegram-bot>=21,<23"; else "$python_bin" -m ensurepip --upgrade >/dev/null 2>&1 || true; "$python_bin" -m pip install --upgrade "python-telegram-bot>=21,<23"; fi; fi'

detected_model="${MODEL_NAME}"
if [[ "${detected_model}" == "local-model" ]]; then
  api_model="$(curl -fsS --max-time 3 "${OPENAI_BASE_URL%/}/models" 2>/dev/null \
    | jq -r ".data[0].id // empty" 2>/dev/null || true)"
  [[ -n "${api_model}" ]] && detected_model="${api_model}"
fi

cat > "/home/${AGENT_USER}/.hermes/.env" <<ENVEOF
OPENAI_BASE_URL=${OPENAI_BASE_URL}
ANTHROPIC_BASE_URL=${ANTHROPIC_BASE_URL}
OPENAI_API_KEY=${OPENAI_API_KEY}
ANTHROPIC_API_KEY=${ANTHROPIC_API_KEY}
MODEL_NAME=${detected_model}
ENVEOF

append_env_if_set() {
  local key="$1"
  local value="$2"
  if [[ -n "${value}" ]]; then
    printf '%s=%s\n' "${key}" "${value}" >> "/home/${AGENT_USER}/.hermes/.env"
  fi
}

append_env_if_set TELEGRAM_BOT_TOKEN "${TELEGRAM_BOT_TOKEN}"
append_env_if_set TELEGRAM_USER_ID "${TELEGRAM_USER_ID}"
append_env_if_set TELEGRAM_ALLOWED_USERS "${TELEGRAM_ALLOWED_USERS}"
append_env_if_set TELEGRAM_GROUP_ALLOWED_USERS "${TELEGRAM_GROUP_ALLOWED_USERS}"
append_env_if_set TELEGRAM_GROUP_ALLOWED_CHATS "${TELEGRAM_GROUP_ALLOWED_CHATS}"
append_env_if_set GATEWAY_ALLOWED_USERS "${GATEWAY_ALLOWED_USERS}"
append_env_if_set GATEWAY_ALLOW_ALL_USERS "${GATEWAY_ALLOW_ALL_USERS}"

cat > "/home/${AGENT_USER}/.hermes/config.yaml" <<CFGEOF
model:
  provider: local-omlx
  default: "${detected_model}"
providers:
  local-omlx:
    name: "Local oMLX"
    base_url: "${OPENAI_BASE_URL}"
    api_key: "${OPENAI_API_KEY}"
    default_model: "${detected_model}"
    transport: "chat_completions"
    discover_models: true
    models:
      "${detected_model}": {}
terminal:
  backend: local
  cwd: "/home/${AGENT_USER}/workspace"
CFGEOF

cat > "/home/${AGENT_USER}/.profile.d-local-ai" <<PROFILEEOF
export PATH="\$HOME/.local/bin:\$PATH"
export OPENAI_BASE_URL="${OPENAI_BASE_URL}"
export ANTHROPIC_BASE_URL="${ANTHROPIC_BASE_URL}"
export OPENAI_API_KEY="${OPENAI_API_KEY}"
export ANTHROPIC_API_KEY="${ANTHROPIC_API_KEY}"
export MODEL_NAME="${detected_model}"
PROFILEEOF

profile_source='[ -f "$HOME/.profile.d-local-ai" ] && . "$HOME/.profile.d-local-ai"'
grep -Fqx "${profile_source}" "/home/${AGENT_USER}/.profile" \
  || printf '\n%s\n' "${profile_source}" >> "/home/${AGENT_USER}/.profile"

chown -R "${AGENT_USER}:${AGENT_USER}" \
  "/home/${AGENT_USER}/.hermes" \
  "/home/${AGENT_USER}/workspace" \
  "/home/${AGENT_USER}/.profile.d-local-ai" \
  "/home/${AGENT_USER}/.profile"

sudo -Hu "${AGENT_USER}" env \
  HOME="/home/${AGENT_USER}" \
  USER="${AGENT_USER}" \
  LOGNAME="${AGENT_USER}" \
  bash -c \
  'export PATH="$HOME/.local/bin:$PATH"; command -v hermes && hermes --help >/dev/null'
INSTALLER

  # ── Execute the installer on the guest as root ──
  vm_exec_root_env \
    AGENT_USER="${VM_SSH_USER}" \
    OPENAI_BASE_URL="${OPENAI_BASE_URL_GUEST}" \
    ANTHROPIC_BASE_URL="${ANTHROPIC_BASE_URL_GUEST}" \
    OPENAI_API_KEY="${OPENAI_API_KEY}" \
    ANTHROPIC_API_KEY="${ANTHROPIC_API_KEY}" \
    MODEL_NAME="${MODEL_NAME}" \
    TELEGRAM_BOT_TOKEN="${TELEGRAM_BOT_TOKEN}" \
    TELEGRAM_USER_ID="${TELEGRAM_USER_ID}" \
    TELEGRAM_ALLOWED_USERS="${TELEGRAM_ALLOWED_USERS}" \
    TELEGRAM_GROUP_ALLOWED_USERS="${TELEGRAM_GROUP_ALLOWED_USERS}" \
    TELEGRAM_GROUP_ALLOWED_CHATS="${TELEGRAM_GROUP_ALLOWED_CHATS}" \
    GATEWAY_ALLOWED_USERS="${GATEWAY_ALLOWED_USERS}" \
    GATEWAY_ALLOW_ALL_USERS="${GATEWAY_ALLOW_ALL_USERS}" \
    HERMES_INSTALL_TIMEOUT_SECONDS="${HERMES_INSTALL_TIMEOUT_SECONDS}" \
    HERMES_INSTALL_RETRIES="${HERMES_INSTALL_RETRIES}" \
    HERMES_REF="${HERMES_REF}" \
    -- "bash /tmp/install-agents.sh"
}

install_vm
