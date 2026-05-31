#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
OMLX_HOME="${OMLX_HOME:-${PROJECT_ROOT}}"
ENV_FILE="${OMLX_HOME}/.env"

OVERRIDE_HERMES_IMAGE="${HERMES_IMAGE:-}"
OVERRIDE_DOCKER_NAME="${DOCKER_NAME:-}"
OVERRIDE_AGENT_DATA_DIR="${AGENT_DATA_DIR:-}"
OVERRIDE_DOCKER_DATA_VOLUME="${DOCKER_DATA_VOLUME:-}"
OVERRIDE_DOCKER_WORKSPACE_VOLUME="${DOCKER_WORKSPACE_VOLUME:-}"
OVERRIDE_DOCKER_DASHBOARD_PORT="${DOCKER_DASHBOARD_PORT:-}"
OVERRIDE_DOCKER_GATEWAY_API_PORT="${DOCKER_GATEWAY_API_PORT:-}"
OVERRIDE_MODEL_NAME="${MODEL_NAME:-}"
OVERRIDE_OBSIDIAN_SHARED_PATH_SET="${OBSIDIAN_SHARED_PATH+x}"
OVERRIDE_OBSIDIAN_SHARED_PATH="${OBSIDIAN_SHARED_PATH:-}"
OVERRIDE_OBSIDIAN_GUEST_PATH="${OBSIDIAN_GUEST_PATH:-}"
OVERRIDE_TELEGRAM_BOT_TOKEN_SET="${TELEGRAM_BOT_TOKEN+x}"
OVERRIDE_TELEGRAM_BOT_TOKEN="${TELEGRAM_BOT_TOKEN:-}"
OVERRIDE_BRAVE_API_KEY_SET="${BRAVE_API_KEY+x}"
OVERRIDE_BRAVE_API_KEY="${BRAVE_API_KEY:-}"
OVERRIDE_GITHUB_PERSONAL_ACCESS_TOKEN_SET="${GITHUB_PERSONAL_ACCESS_TOKEN+x}"
OVERRIDE_GITHUB_PERSONAL_ACCESS_TOKEN="${GITHUB_PERSONAL_ACCESS_TOKEN:-}"

if [[ -f "${ENV_FILE}" ]]; then
  set -a
  # shellcheck disable=SC1090
  source "${ENV_FILE}"
  set +a
fi

DOCKER_NAME="${OVERRIDE_DOCKER_NAME:-${DOCKER_NAME:-omlx-agent-docker}}"
HERMES_IMAGE="${OVERRIDE_HERMES_IMAGE:-${HERMES_IMAGE:-nousresearch/hermes-agent:latest}}"
DOCKER_IMAGE="${HERMES_IMAGE}"
AGENT_DATA_DIR="${OVERRIDE_AGENT_DATA_DIR:-${AGENT_DATA_DIR:-}}"
DOCKER_DATA_VOLUME="${OVERRIDE_DOCKER_DATA_VOLUME:-${DOCKER_DATA_VOLUME:-${DOCKER_NAME}-data}}"
DOCKER_WORKSPACE_VOLUME="${OVERRIDE_DOCKER_WORKSPACE_VOLUME:-${DOCKER_WORKSPACE_VOLUME:-${DOCKER_NAME}-workspace}}"
DOCKER_CPUS="${DOCKER_CPUS:-2}"
DOCKER_MEMORY="${DOCKER_MEMORY:-4g}"
DOCKER_SHM_SIZE="${DOCKER_SHM_SIZE:-1g}"
HERMES_DASHBOARD_PORT="${HERMES_DASHBOARD_PORT:-9119}"
HERMES_DASHBOARD_INSECURE="${HERMES_DASHBOARD_INSECURE:-}"
DOCKER_DASHBOARD_PORT="${OVERRIDE_DOCKER_DASHBOARD_PORT:-${DOCKER_DASHBOARD_PORT:-9120}}"
HERMES_GATEWAY_API_PORT="${HERMES_GATEWAY_API_PORT:-8642}"
DOCKER_GATEWAY_API_PORT="${OVERRIDE_DOCKER_GATEWAY_API_PORT:-${DOCKER_GATEWAY_API_PORT:-8642}}"
OPENAI_BASE_URL_DOCKER="${OPENAI_BASE_URL_DOCKER:-http://host.docker.internal:8000/v1}"
ANTHROPIC_BASE_URL_DOCKER="${ANTHROPIC_BASE_URL_DOCKER:-http://host.docker.internal:8000}"
RAG_BASE_URL_DOCKER="${RAG_BASE_URL_DOCKER:-http://rag-host.internal:8765}"
OPENAI_API_KEY="${OPENAI_API_KEY:-}"
ANTHROPIC_API_KEY="${ANTHROPIC_API_KEY:-${OPENAI_API_KEY}}"
MODEL_NAME="${OVERRIDE_MODEL_NAME:-${MODEL_NAME:-}}"
if [[ -n "${OVERRIDE_OBSIDIAN_SHARED_PATH_SET}" ]]; then
  OBSIDIAN_SHARED_PATH="${OVERRIDE_OBSIDIAN_SHARED_PATH}"
else
  OBSIDIAN_SHARED_PATH="${OBSIDIAN_SHARED_PATH:-}"
fi
OBSIDIAN_GUEST_PATH="${OVERRIDE_OBSIDIAN_GUEST_PATH:-${OBSIDIAN_GUEST_PATH:-/mnt/obsidian}}"
if [[ -n "${OVERRIDE_TELEGRAM_BOT_TOKEN_SET}" ]]; then
  TELEGRAM_BOT_TOKEN="${OVERRIDE_TELEGRAM_BOT_TOKEN}"
else
  TELEGRAM_BOT_TOKEN="${TELEGRAM_BOT_TOKEN:-}"
fi
if [[ -n "${OVERRIDE_BRAVE_API_KEY_SET}" ]]; then
  BRAVE_API_KEY="${OVERRIDE_BRAVE_API_KEY}"
else
  BRAVE_API_KEY="${BRAVE_API_KEY:-}"
fi
if [[ -n "${OVERRIDE_GITHUB_PERSONAL_ACCESS_TOKEN_SET}" ]]; then
  GITHUB_PERSONAL_ACCESS_TOKEN="${OVERRIDE_GITHUB_PERSONAL_ACCESS_TOKEN}"
else
  GITHUB_PERSONAL_ACCESS_TOKEN="${GITHUB_PERSONAL_ACCESS_TOKEN:-}"
fi
TELEGRAM_USER_ID="${TELEGRAM_USER_ID:-}"
TELEGRAM_ALLOWED_USERS="${TELEGRAM_ALLOWED_USERS:-}"
TELEGRAM_GROUP_ALLOWED_USERS="${TELEGRAM_GROUP_ALLOWED_USERS:-}"
TELEGRAM_GROUP_ALLOWED_CHATS="${TELEGRAM_GROUP_ALLOWED_CHATS:-}"
GATEWAY_ALLOWED_USERS="${GATEWAY_ALLOWED_USERS:-}"
GATEWAY_ALLOW_ALL_USERS="${GATEWAY_ALLOW_ALL_USERS:-false}"

if [[ -n "${TELEGRAM_USER_ID}" ]]; then
  TELEGRAM_ALLOWED_USERS="${TELEGRAM_ALLOWED_USERS:-${TELEGRAM_USER_ID}}"
  GATEWAY_ALLOWED_USERS="${GATEWAY_ALLOWED_USERS:-${TELEGRAM_USER_ID}}"
fi

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
  path="${path%/}"
  printf '%s\n' "${path}"
}

# Resolve agent data directory:
# 1. AGENT_DATA_DIR if set (absolute or relative to PROJECT_ROOT)
# 2. Falls back to .runtime/agent inside the project
agent_data_dir_abs() {
  local dir="${AGENT_DATA_DIR:-}"
  if [[ -z "${dir}" ]]; then
    dir="${OMLX_HOME}/.runtime/agent"
  else
    dir="$(normalize_path "${dir}")"
    case "${dir}" in
      /*) ;;
      *) dir="${OMLX_HOME}/${dir}" ;;
    esac
  fi
  printf '%s\n' "${dir}"
}

# Auto-detect Docker platform (arm64 on Apple Silicon, amd64 otherwise)
docker_platform() {
  local arch
  arch="$(uname -m)"
  case "${arch}" in
    arm64|aarch64) echo "linux/arm64" ;;
    *) echo "linux/amd64" ;;
  esac
}
DOCKER_PLATFORM="$(docker_platform)"

command -v docker > /dev/null 2>&1 || die "docker CLI missing. Run make bootstrap or install Docker Desktop."
[[ -n "${OPENAI_API_KEY}" ]] || die "OPENAI_API_KEY missing. Run make bootstrap or set it in .env."

if ! docker image inspect "${DOCKER_IMAGE}" > /dev/null 2>&1; then
  docker pull --platform "${DOCKER_PLATFORM}" "${DOCKER_IMAGE}"
fi

served_models_json="$(curl -fsS --max-time 3 -H "Authorization: Bearer ${OPENAI_API_KEY}" "${OPENAI_BASE_URL:-http://localhost:8000/v1}/models" 2>/dev/null || true)"
if [[ -n "${served_models_json}" ]]; then
  detected_model="$(printf '%s' "${served_models_json}" | jq -r '.data[0].id // empty' 2>/dev/null || true)"
  if [[ -z "${MODEL_NAME}" || "${MODEL_NAME}" == "local-model" ]] || \
     ! printf '%s' "${served_models_json}" | jq -e --arg model "${MODEL_NAME}" '.data[]? | select(.id == $model)' >/dev/null 2>&1; then
    MODEL_NAME="${detected_model:-local-model}"
  fi
elif [[ -z "${MODEL_NAME}" ]]; then
  MODEL_NAME="local-model"
fi

# Resolve data directory (bind-mount path or named volumes)
DATA_DIR_ABS="$(agent_data_dir_abs)"
USE_BIND_MOUNT=1

# If AGENT_DATA_DIR is unset AND user explicitly has volume vars set,
# they may prefer the old named-volume mode. But bind-mount is the new default.
if [[ -z "${AGENT_DATA_DIR:-}" && "${DOCKER_BIND_MOUNT:-1}" == "0" ]]; then
  USE_BIND_MOUNT=0
fi

if [[ "${USE_BIND_MOUNT}" -eq 1 ]]; then
  mkdir -p "${DATA_DIR_ABS}" "${DATA_DIR_ABS}/workspace"
  data_mount="${DATA_DIR_ABS}:/opt/data"
  workspace_mount="${DATA_DIR_ABS}/workspace:/opt/data/workspace"
  echo "Agent data directory (host): ${DATA_DIR_ABS}"
else
  docker volume create "${DOCKER_DATA_VOLUME}" > /dev/null
  docker volume create "${DOCKER_WORKSPACE_VOLUME}" > /dev/null
  data_mount="${DOCKER_DATA_VOLUME}:/opt/data"
  workspace_mount="${DOCKER_WORKSPACE_VOLUME}:/opt/data/workspace"
  echo "Agent data volume: ${DOCKER_DATA_VOLUME}"
fi

write_data_volume() {
  docker run --rm \
    -e OPENAI_BASE_URL="${OPENAI_BASE_URL_DOCKER}" \
    -e ANTHROPIC_BASE_URL="${ANTHROPIC_BASE_URL_DOCKER}" \
    -e OPENAI_API_KEY="${OPENAI_API_KEY}" \
    -e ANTHROPIC_API_KEY="${ANTHROPIC_API_KEY}" \
    -e MODEL_NAME="${MODEL_NAME}" \
    -e TELEGRAM_BOT_TOKEN="${TELEGRAM_BOT_TOKEN}" \
    -e TELEGRAM_USER_ID="${TELEGRAM_USER_ID}" \
    -e TELEGRAM_ALLOWED_USERS="${TELEGRAM_ALLOWED_USERS}" \
    -e TELEGRAM_GROUP_ALLOWED_USERS="${TELEGRAM_GROUP_ALLOWED_USERS}" \
    -e TELEGRAM_GROUP_ALLOWED_CHATS="${TELEGRAM_GROUP_ALLOWED_CHATS}" \
    -e GATEWAY_ALLOWED_USERS="${GATEWAY_ALLOWED_USERS}" \
    -e GATEWAY_ALLOW_ALL_USERS="${GATEWAY_ALLOW_ALL_USERS}" \
    -e RAG_BASE_URL="${RAG_BASE_URL_DOCKER}" \
    -e HERMES_YOLO_MODE="${HERMES_YOLO_MODE:-}" \
    -e BRAVE_API_KEY="${BRAVE_API_KEY}" \
    -e GITHUB_PERSONAL_ACCESS_TOKEN="${GITHUB_PERSONAL_ACCESS_TOKEN}" \
    -v "${SCRIPT_DIR}/rag-search-bridge.sh:/tmp/rag-search:ro" \
    -v "${data_mount}" \
    -v "${workspace_mount}" \
    "${DOCKER_IMAGE}" \
    /bin/bash -lc 'set -euo pipefail
mkdir -p /opt/data/logs /opt/data/workspace /opt/data/.local/bin
cat > /opt/data/.env <<EOF
OPENAI_BASE_URL=${OPENAI_BASE_URL}
ANTHROPIC_BASE_URL=${ANTHROPIC_BASE_URL}
OPENAI_API_KEY=${OPENAI_API_KEY}
ANTHROPIC_API_KEY=${ANTHROPIC_API_KEY}
MODEL_NAME=${MODEL_NAME}
RAG_BASE_URL=${RAG_BASE_URL}
EOF
append_env_if_set() {
  key="$1"
  value="$2"
  if [[ -n "$value" ]]; then
    printf "%s=%s\n" "$key" "$value" >> /opt/data/.env
  fi
}
append_env_if_set TELEGRAM_BOT_TOKEN "${TELEGRAM_BOT_TOKEN}"
append_env_if_set TELEGRAM_USER_ID "${TELEGRAM_USER_ID}"
append_env_if_set TELEGRAM_ALLOWED_USERS "${TELEGRAM_ALLOWED_USERS}"
append_env_if_set TELEGRAM_GROUP_ALLOWED_USERS "${TELEGRAM_GROUP_ALLOWED_USERS}"
append_env_if_set TELEGRAM_GROUP_ALLOWED_CHATS "${TELEGRAM_GROUP_ALLOWED_CHATS}"
append_env_if_set GATEWAY_ALLOWED_USERS "${GATEWAY_ALLOWED_USERS}"
append_env_if_set GATEWAY_ALLOW_ALL_USERS "${GATEWAY_ALLOW_ALL_USERS}"
append_env_if_set HERMES_YOLO_MODE "${HERMES_YOLO_MODE:-}"
append_env_if_set BRAVE_API_KEY "${BRAVE_API_KEY}"
append_env_if_set GITHUB_PERSONAL_ACCESS_TOKEN "${GITHUB_PERSONAL_ACCESS_TOKEN}"
append_env_if_set OBSIDIAN_WATCH_INTERVAL_SECONDS "${OBSIDIAN_WATCH_INTERVAL_SECONDS:-}"
/opt/hermes/.venv/bin/python3 -c '\''
import yaml, sys
from pathlib import Path

model_name = sys.argv[1]
base_url = sys.argv[2]
api_key = sys.argv[3]
brave_key = sys.argv[4]
github_token = sys.argv[5]

config_path = Path("/opt/data/config.yaml")

default_mcp_servers = {
    "brave-search": {
        "command": "npx",
        "args": ["-y", "@modelcontextprotocol/server-brave-search"],
        "env": {"BRAVE_API_KEY": brave_key},
        "enabled": bool(brave_key)
    },
    "github": {
        "command": "npx",
        "args": ["-y", "@modelcontextprotocol/server-github"],
        "env": {"GITHUB_PERSONAL_ACCESS_TOKEN": github_token},
        "enabled": bool(github_token)
    },
    "filesystem": {
        "command": "npx",
        "args": ["-y", "@modelcontextprotocol/server-filesystem", "/opt/data/workspace", "/mnt/obsidian"],
        "enabled": True
    },
    "fetch": {
        "command": "uvx",
        "args": ["mcp-server-fetch"],
        "enabled": True
    },
    "git": {
        "command": "uvx",
        "args": ["mcp-server-git"],
        "enabled": True
    },
    "yfinance": {
        "command": "env",
        "args": ["-i", "-C", "/tmp", "HOME=/tmp", "PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin", "uvx", "mcp-server-yfinance"],
        "enabled": True
    },
    "puppeteer": {
        "command": "npx",
        "args": ["-y", "@modelcontextprotocol/server-puppeteer"],
        "env": {
            "PUPPETEER_EXECUTABLE_PATH": "/usr/bin/chromium",
            "DOCKER_CONTAINER": "true"
        },
        "enabled": True
    },
    "docker-manager": {
        "command": "uvx",
        "args": ["mcp-server-docker"],
        "enabled": True
    }
}

new_config = {
    "model": {
        "provider": "local-omlx",
        "default": model_name
    },
    "providers": {
        "local-omlx": {
            "name": "Local oMLX",
            "base_url": base_url,
            "api_key": api_key,
            "default_model": model_name,
            "transport": "chat_completions",
            "discover_models": True,
            "models": {}
        }
    },
    "terminal": {
        "backend": "local",
        "cwd": "/opt/data/workspace"
    },
    "mcp_servers": default_mcp_servers
}

if config_path.exists():
    try:
        with open(config_path, "r") as f:
            data = yaml.safe_load(f) or {}
    except Exception:
        data = {}
    
    if "model" not in data or not isinstance(data["model"], dict):
        data["model"] = {}
    data["model"]["provider"] = "local-omlx"
    data["model"]["default"] = model_name
    
    if "providers" not in data or not isinstance(data["providers"], dict):
        data["providers"] = {}
    data["providers"]["local-omlx"] = new_config["providers"]["local-omlx"]
    
    if "terminal" not in data or not isinstance(data["terminal"], dict):
        data["terminal"] = {}
    if "backend" not in data["terminal"]:
        data["terminal"]["backend"] = "local"
    if "cwd" not in data["terminal"]:
        data["terminal"]["cwd"] = "/opt/data/workspace"
        
    if "mcp_servers" not in data or not isinstance(data["mcp_servers"], dict):
        data["mcp_servers"] = {}
    
    for k, v in default_mcp_servers.items():
        if k not in data["mcp_servers"]:
            data["mcp_servers"][k] = v
        else:
            data["mcp_servers"][k]["command"] = v["command"]
            data["mcp_servers"][k]["args"] = v["args"]
            if "cwd" in v:
                data["mcp_servers"][k]["cwd"] = v["cwd"]
            if "env" in v:
                if "env" not in data["mcp_servers"][k] or not isinstance(data["mcp_servers"][k]["env"], dict):
                    data["mcp_servers"][k]["env"] = {}
                for env_k, env_v in v["env"].items():
                    data["mcp_servers"][k]["env"][env_k] = env_v
            
            if k == "brave-search":
                data["mcp_servers"][k]["enabled"] = bool(brave_key)
            elif k == "github":
                data["mcp_servers"][k]["enabled"] = bool(github_token)
else:
    data = new_config

with open(config_path, "w") as f:
    yaml.safe_dump(data, f, default_flow_style=False)
'\'' "${MODEL_NAME}" "${OPENAI_BASE_URL}" "${OPENAI_API_KEY}" "${BRAVE_API_KEY:-}" "${GITHUB_PERSONAL_ACCESS_TOKEN:-}"
install -m 0755 /tmp/rag-search /opt/data/.local/bin/rag-search
mkdir -p /opt/data/skills/local-rag
cat > /opt/data/skills/local-rag/SKILL.md <<'EOF'
# Local RAG

Use `rag-search "query"` before answering questions that may depend on local notes, Obsidian vault content, project knowledge, or personal documents. Prefer a focused search query, cite the returned note path when useful, and do not claim the local knowledge base has no answer until `rag-search` returns no relevant results. The tool queries the local Docker RAG API at ${RAG_BASE_URL}.
EOF
chmod 600 /opt/data/.env /opt/data/config.yaml'
}

write_data_volume

mount_args=(
  -v "${data_mount}"
  -v "${workspace_mount}"
)

if [[ -S "/var/run/docker.sock" || -e "/var/run/docker.sock" ]]; then
  mount_args+=(-v "/var/run/docker.sock:/var/run/docker.sock")
fi

mount_args+=(-v "${SCRIPT_DIR}/obsidian-watcher.py:/opt/hermes/obsidian-watcher.py:ro")

if [[ -n "${OBSIDIAN_SHARED_PATH}" ]]; then
  OBSIDIAN_SHARED_PATH="$(normalize_path "${OBSIDIAN_SHARED_PATH}")"
  [[ -d "${OBSIDIAN_SHARED_PATH}" ]] || die "OBSIDIAN_SHARED_PATH does not exist: ${OBSIDIAN_SHARED_PATH}"
  mount_args+=(-v "${OBSIDIAN_SHARED_PATH}:${OBSIDIAN_GUEST_PATH}:rw")
fi

desired_command="gateway run"
desired_dashboard_port="127.0.0.1:${DOCKER_DASHBOARD_PORT}"
desired_gateway_port="127.0.0.1:${DOCKER_GATEWAY_API_PORT}"

if docker container inspect "${DOCKER_NAME}" >/dev/null 2>&1; then
  echo "Stopping and removing existing Hermes Docker container: ${DOCKER_NAME}"
  docker stop "${DOCKER_NAME}" >/dev/null 2>&1 || true
  docker rm "${DOCKER_NAME}" >/dev/null 2>&1 || true
fi

  docker create \
  --name "${DOCKER_NAME}" \
  --platform "${DOCKER_PLATFORM}" \
  --restart unless-stopped \
  --cpus "${DOCKER_CPUS}" \
  --memory "${DOCKER_MEMORY}" \
  --shm-size "${DOCKER_SHM_SIZE}" \
  -p "127.0.0.1:${DOCKER_GATEWAY_API_PORT}:8642" \
  -p "127.0.0.1:${DOCKER_DASHBOARD_PORT}:9119" \
  --add-host host.docker.internal:host-gateway \
  --add-host model-host.internal:host-gateway \
  --add-host rag-host.internal:host-gateway \
  -e HERMES_DASHBOARD=1 \
  -e HERMES_DASHBOARD_HOST=0.0.0.0 \
  -e HERMES_DASHBOARD_PORT="${HERMES_DASHBOARD_PORT}" \
  -e HERMES_DASHBOARD_TUI="${HERMES_DASHBOARD_TUI:-0}" \
  -e HERMES_DASHBOARD_INSECURE="${HERMES_DASHBOARD_INSECURE}" \
  -e HERMES_YOLO_MODE="${HERMES_YOLO_MODE:-}" \
  -e HF_HOME=/opt/data/.cache/huggingface \
  -e DOCKER_CONTAINER=true \
  -e AGENT_BROWSER_EXECUTABLE_PATH="/usr/bin/chromium" \
  -e PATH="/opt/hermes/bin:/opt/hermes/.venv/bin:/opt/data/.local/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" \
  "${mount_args[@]}" \
  "${DOCKER_IMAGE}" \
  gateway run >/dev/null

echo "Created Docker Hermes gateway: ${DOCKER_NAME}"
echo "Image: ${DOCKER_IMAGE}"
echo "Model API: ${OPENAI_BASE_URL_DOCKER}"
echo "Model: ${MODEL_NAME}"
echo "Dashboard: http://127.0.0.1:${DOCKER_DASHBOARD_PORT}"
echo "Gateway API: http://127.0.0.1:${DOCKER_GATEWAY_API_PORT}"
if [[ "${USE_BIND_MOUNT}" -eq 1 ]]; then
  echo "Agent data (host): ${DATA_DIR_ABS}"
fi
