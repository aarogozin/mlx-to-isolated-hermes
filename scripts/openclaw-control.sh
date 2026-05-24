#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
ENV_FILE="${PROJECT_ROOT}/.env"
RUNTIME_DIR="${PROJECT_ROOT}/.runtime"

OVERRIDE_SANDBOX_BACKEND="${SANDBOX_BACKEND:-}"
OVERRIDE_VM_NAME="${VM_NAME:-}"
OVERRIDE_OPENCLAW_IMAGE="${OPENCLAW_IMAGE:-}"
OVERRIDE_OPENCLAW_CONTROL_PORT="${OPENCLAW_CONTROL_PORT:-}"
OVERRIDE_OPENCLAW_BRIDGE_PORT="${OPENCLAW_BRIDGE_PORT:-}"
OVERRIDE_OPENCLAW_DOCKER_NAME="${OPENCLAW_DOCKER_NAME:-}"
OVERRIDE_OPENCLAW_DOCKER_CONFIG_VOLUME="${OPENCLAW_DOCKER_CONFIG_VOLUME:-}"
OVERRIDE_OPENCLAW_DOCKER_WORKSPACE_VOLUME="${OPENCLAW_DOCKER_WORKSPACE_VOLUME:-}"
OVERRIDE_OPENCLAW_DOCKER_AUTH_VOLUME="${OPENCLAW_DOCKER_AUTH_VOLUME:-}"
OVERRIDE_OPENCLAW_GATEWAY_TOKEN="${OPENCLAW_GATEWAY_TOKEN:-}"
OVERRIDE_MODEL_NAME="${MODEL_NAME:-}"
OVERRIDE_TELEGRAM_BOT_TOKEN_SET="${TELEGRAM_BOT_TOKEN+x}"
OVERRIDE_TELEGRAM_BOT_TOKEN="${TELEGRAM_BOT_TOKEN:-}"

if [[ -f "${ENV_FILE}" ]]; then
  set -a
  # shellcheck disable=SC1090
  source "${ENV_FILE}"
  set +a
fi

ACTION="${1:-status}"
TARGET="${2:-${OVERRIDE_SANDBOX_BACKEND:-${SANDBOX_BACKEND:-multipass}}}"

VM_NAME="${OVERRIDE_VM_NAME:-${OPENCLAW_VM_NAME:-omlx-openclaw-ubuntu}}"
VM_SSH_USER="${VM_SSH_USER:-agent}"
VM_SSH_KEY="${VM_SSH_KEY:-${HOME}/.ssh/omlx_agent_vm_ed25519}"
OPENCLAW_IMAGE="${OVERRIDE_OPENCLAW_IMAGE:-${OPENCLAW_IMAGE:-ghcr.io/openclaw/openclaw:latest}}"
OPENCLAW_PULL_POLICY="${OPENCLAW_PULL_POLICY:-latest}"
OPENCLAW_DOCKER_NAME="${OVERRIDE_OPENCLAW_DOCKER_NAME:-${OPENCLAW_DOCKER_NAME:-omlx-agent-openclaw-docker}}"
OPENCLAW_DOCKER_CONFIG_VOLUME="${OVERRIDE_OPENCLAW_DOCKER_CONFIG_VOLUME:-${OPENCLAW_DOCKER_CONFIG_VOLUME:-${OPENCLAW_DOCKER_NAME}-config}}"
OPENCLAW_DOCKER_WORKSPACE_VOLUME="${OVERRIDE_OPENCLAW_DOCKER_WORKSPACE_VOLUME:-${OPENCLAW_DOCKER_WORKSPACE_VOLUME:-${OPENCLAW_DOCKER_NAME}-workspace}}"
OPENCLAW_DOCKER_AUTH_VOLUME="${OVERRIDE_OPENCLAW_DOCKER_AUTH_VOLUME:-${OPENCLAW_DOCKER_AUTH_VOLUME:-${OPENCLAW_DOCKER_NAME}-auth}}"
OPENCLAW_CONTROL_PORT="${OVERRIDE_OPENCLAW_CONTROL_PORT:-${OPENCLAW_CONTROL_PORT:-18789}}"
OPENCLAW_BRIDGE_PORT="${OVERRIDE_OPENCLAW_BRIDGE_PORT:-${OPENCLAW_BRIDGE_PORT:-18790}}"
OPENCLAW_GATEWAY_TOKEN="${OVERRIDE_OPENCLAW_GATEWAY_TOKEN:-${OPENCLAW_GATEWAY_TOKEN:-}}"
OPENCLAW_GATEWAY_BIND="${OPENCLAW_GATEWAY_BIND:-lan}"
OPENCLAW_ALLOW_TAILSCALE_AUTH="${OPENCLAW_ALLOW_TAILSCALE_AUTH:-0}"
OPENCLAW_CONTROL_ALLOWED_ORIGINS="${OPENCLAW_CONTROL_ALLOWED_ORIGINS:-}"
TAILSCALE_DASHBOARD_ORIGIN="${TAILSCALE_DASHBOARD_ORIGIN:-}"
OPENCLAW_OPENAI_BASE_URL_DOCKER="${OPENCLAW_OPENAI_BASE_URL_DOCKER:-${OPENAI_BASE_URL_DOCKER:-http://host.docker.internal:8000/v1}}"
OPENCLAW_OPENAI_BASE_URL_GUEST="${OPENCLAW_OPENAI_BASE_URL_GUEST:-${OPENAI_BASE_URL_GUEST:-http://model-host.internal:8000/v1}}"
OPENAI_BASE_URL="${OPENAI_BASE_URL:-http://localhost:8000/v1}"
OPENAI_API_KEY="${OPENAI_API_KEY:-}"
MODEL_NAME="${OVERRIDE_MODEL_NAME:-${MODEL_NAME:-local-model}}"
OBSIDIAN_SHARED_PATH="${OBSIDIAN_SHARED_PATH:-}"
OBSIDIAN_GUEST_PATH="${OBSIDIAN_GUEST_PATH:-/mnt/obsidian}"
if [[ -n "${OVERRIDE_TELEGRAM_BOT_TOKEN_SET}" ]]; then
  TELEGRAM_BOT_TOKEN="${OVERRIDE_TELEGRAM_BOT_TOKEN}"
else
  TELEGRAM_BOT_TOKEN="${TELEGRAM_BOT_TOKEN:-}"
fi
TELEGRAM_USER_ID="${TELEGRAM_USER_ID:-}"
TELEGRAM_ALLOWED_USERS="${TELEGRAM_ALLOWED_USERS:-}"
TIMEOUT_BIN="$(command -v timeout || command -v gtimeout || true)"

if [[ -n "${TELEGRAM_USER_ID}" ]]; then
  TELEGRAM_ALLOWED_USERS="${TELEGRAM_ALLOWED_USERS:-${TELEGRAM_USER_ID}}"
fi

die() {
  echo "ERROR: $*" >&2
  exit 1
}

usage() {
  cat <<EOF
Usage: $0 <start|stop|restart|status|logs|shell|open-dashboard|destroy> [docker|multipass]
EOF
}

normalize_path() {
  local path="$1"
  [[ -n "${path}" ]] || return 0
  if [[ "${path}" == "~/"* ]]; then
    path="${HOME}/${path#~/}"
  fi
  printf '%s\n' "${path%/}"
}

ensure_gateway_token() {
  if [[ -n "${OPENCLAW_GATEWAY_TOKEN}" ]]; then
    return 0
  fi
  OPENCLAW_GATEWAY_TOKEN="$(openssl rand -hex 24 2>/dev/null || LC_ALL=C tr -dc 'a-f0-9' </dev/urandom | head -c 48; printf '\n')"
  "${SCRIPT_DIR}/env-set.sh" "${ENV_FILE}" OPENCLAW_GATEWAY_TOKEN "${OPENCLAW_GATEWAY_TOKEN}"
}

openclaw_dashboard_base_url() {
  printf 'http://127.0.0.1:%s' "${OPENCLAW_CONTROL_PORT}"
}

openclaw_dashboard_auth_url() {
  ensure_gateway_token
  printf '%s/#token=%s' "$(openclaw_dashboard_base_url)" "${OPENCLAW_GATEWAY_TOKEN}"
}

print_dashboard_access() {
  ensure_gateway_token
  cat <<EOF
Control UI: $(openclaw_dashboard_base_url)
Control UI auth URL: $(openclaw_dashboard_auth_url)
OPENCLAW_GATEWAY_TOKEN=${OPENCLAW_GATEWAY_TOKEN}
EOF
  if [[ "${OPENCLAW_ALLOW_TAILSCALE_AUTH}" == "1" || "${OPENCLAW_ALLOW_TAILSCALE_AUTH}" == "true" ]]; then
    echo "Tailscale auth: enabled for OpenClaw Control UI"
  fi
}

detect_model() {
  if [[ -n "${MODEL_NAME}" && "${MODEL_NAME}" != "local-model" ]]; then
    return 0
  fi
  local detected
  detected="$(curl -fsS --max-time 3 -H "Authorization: Bearer ${OPENAI_API_KEY}" "${OPENAI_BASE_URL%/}/models" 2>/dev/null \
    | jq -r '.data[0].id // empty' 2>/dev/null || true)"
  [[ -n "${detected}" ]] && MODEL_NAME="${detected}"
}

openclaw_env_args() {
  local base_url="$1"
  printf '%s\0' \
    -e "HOME=/home/node" \
    -e "OPENCLAW_HOME=/home/node" \
    -e "OPENCLAW_STATE_DIR=/home/node/.openclaw" \
    -e "OPENCLAW_CONFIG_PATH=/home/node/.openclaw/openclaw.json" \
    -e "OPENCLAW_CONFIG_DIR=/home/node/.openclaw" \
    -e "OPENCLAW_WORKSPACE_DIR=/home/node/.openclaw/workspace" \
    -e "OPENCLAW_AUTH_PROFILE_SECRET_DIR=/home/node/.config/openclaw" \
    -e "OPENCLAW_GATEWAY_TOKEN=${OPENCLAW_GATEWAY_TOKEN}" \
    -e "OPENCLAW_ALLOW_INSECURE_PRIVATE_WS=1" \
    -e "OPENCLAW_DISABLE_BONJOUR=1" \
    -e "CUSTOM_API_KEY=${OPENAI_API_KEY}" \
    -e "OPENAI_API_KEY=${OPENAI_API_KEY}" \
    -e "OPENAI_BASE_URL=${base_url}" \
    -e "MODEL_NAME=${MODEL_NAME}" \
    -e "TELEGRAM_BOT_TOKEN=${TELEGRAM_BOT_TOKEN}" \
    -e "TELEGRAM_USER_ID=${TELEGRAM_USER_ID}" \
    -e "TELEGRAM_ALLOWED_USERS=${TELEGRAM_ALLOWED_USERS}"
}

docker_container_exists() {
  docker container inspect "${OPENCLAW_DOCKER_NAME}" >/dev/null 2>&1
}

docker_container_running() {
  [[ "$(docker inspect -f '{{.State.Running}}' "${OPENCLAW_DOCKER_NAME}" 2>/dev/null || true)" == "true" ]]
}

docker_run_cli() {
  local -a env_args=()
  while IFS= read -r -d '' arg; do
    env_args+=("${arg}")
  done < <(openclaw_env_args "${OPENCLAW_OPENAI_BASE_URL_DOCKER}")

  docker run --rm \
    --platform linux/arm64 \
    --add-host host.docker.internal:host-gateway \
    --add-host model-host.internal:host-gateway \
    --entrypoint node \
    "${env_args[@]}" \
    -v "${OPENCLAW_DOCKER_CONFIG_VOLUME}:/home/node/.openclaw" \
    -v "${OPENCLAW_DOCKER_WORKSPACE_VOLUME}:/home/node/.openclaw/workspace" \
    -v "${OPENCLAW_DOCKER_AUTH_VOLUME}:/home/node/.config/openclaw" \
    "${OPENCLAW_IMAGE}" \
    openclaw.mjs "$@"
}

docker_prepare_volumes() {
  docker run --rm \
    --platform linux/arm64 \
    --user root \
    --entrypoint sh \
    -v "${OPENCLAW_DOCKER_CONFIG_VOLUME}:/home/node/.openclaw" \
    -v "${OPENCLAW_DOCKER_WORKSPACE_VOLUME}:/home/node/.openclaw/workspace" \
    -v "${OPENCLAW_DOCKER_AUTH_VOLUME}:/home/node/.config/openclaw" \
    "${OPENCLAW_IMAGE}" \
    -lc 'mkdir -p /home/node/.openclaw/workspace /home/node/.config/openclaw && chown -R 1000:1000 /home/node/.openclaw /home/node/.config/openclaw'
}

openclaw_config_json() {
  local allow_tailscale=false
  if [[ "${OPENCLAW_ALLOW_TAILSCALE_AUTH}" == "1" || "${OPENCLAW_ALLOW_TAILSCALE_AUTH}" == "true" ]]; then
    allow_tailscale=true
  fi
  jq -cn \
    --arg bind "${OPENCLAW_GATEWAY_BIND}" \
    --arg origin1 "http://localhost:${OPENCLAW_CONTROL_PORT}" \
    --arg origin2 "http://127.0.0.1:${OPENCLAW_CONTROL_PORT}" \
    --arg tailscale_origin "${TAILSCALE_DASHBOARD_ORIGIN}" \
    --arg extra_origins "${OPENCLAW_CONTROL_ALLOWED_ORIGINS}" \
    --argjson allow_tailscale "${allow_tailscale}" \
    --arg tg_token "${TELEGRAM_BOT_TOKEN}" \
    --arg tg_users "${TELEGRAM_ALLOWED_USERS}" '
    def split_origins:
      split(",") | map(gsub("^\\s+|\\s+$";"")) | map(select(. != ""));
    def origins:
      ([$origin1, $origin2]
        + (if $tailscale_origin != "" then [$tailscale_origin] else [] end)
        + (if $extra_origins != "" then ($extra_origins | split_origins) else [] end))
      | unique;
    [
      {path:"gateway.mode", value:"local"},
      {path:"gateway.bind", value:$bind},
      {path:"gateway.controlUi.allowedOrigins", value:origins},
      {path:"gateway.auth.allowTailscale", value:$allow_tailscale}
    ]
    + (if $tg_token != "" then [
      {path:"channels.telegram.enabled", value:true},
      {path:"channels.telegram.dmPolicy", value:(if $tg_users != "" then "allowlist" else "pairing" end)},
      {path:"channels.telegram.groups", value:{"*": {requireMention: true}}}
    ] else [] end)
    + (if $tg_users != "" then [
      {path:"channels.telegram.allowFrom", value:($tg_users | split(",") | map(gsub("^\\s+|\\s+$";"")) | map(select(. != "")))}
    ] else [] end)
  '
}

docker_configure() {
  ensure_gateway_token
  detect_model
  [[ -n "${OPENAI_API_KEY}" ]] || die "OPENAI_API_KEY missing. Run make bootstrap or set it in .env."
  command -v docker >/dev/null 2>&1 || die "docker CLI missing. Run make bootstrap or install Docker Desktop."

  if [[ "${OPENCLAW_PULL_POLICY}" == "always" || ( "${OPENCLAW_PULL_POLICY}" == "latest" && "${OPENCLAW_IMAGE}" == *":latest" ) ]] \
    || ! docker image inspect "${OPENCLAW_IMAGE}" >/dev/null 2>&1; then
    docker pull --platform linux/arm64 "${OPENCLAW_IMAGE}"
  fi

  docker volume create "${OPENCLAW_DOCKER_CONFIG_VOLUME}" >/dev/null
  docker volume create "${OPENCLAW_DOCKER_WORKSPACE_VOLUME}" >/dev/null
  docker volume create "${OPENCLAW_DOCKER_AUTH_VOLUME}" >/dev/null
  docker_prepare_volumes

  docker_run_cli onboard \
    --non-interactive \
    --accept-risk \
    --mode local \
    --auth-choice custom-api-key \
    --custom-base-url "${OPENCLAW_OPENAI_BASE_URL_DOCKER}" \
    --custom-model-id "${MODEL_NAME}" \
    --custom-api-key "${OPENAI_API_KEY}" \
    --secret-input-mode plaintext \
    --custom-compatibility openai \
    --custom-text-input \
    --gateway-auth token \
    --gateway-bind "${OPENCLAW_GATEWAY_BIND}" \
    --gateway-port 18789 \
    --gateway-token-ref-env OPENCLAW_GATEWAY_TOKEN \
    --no-install-daemon \
    --skip-daemon \
    --skip-ui \
    --skip-health >/dev/null

  docker_run_cli config set --batch-json "$(openclaw_config_json)" >/dev/null
}

docker_create() {
  docker_configure

  local -a env_args=()
  while IFS= read -r -d '' arg; do
    env_args+=("${arg}")
  done < <(openclaw_env_args "${OPENCLAW_OPENAI_BASE_URL_DOCKER}")

  local -a mount_args=(
    -v "${OPENCLAW_DOCKER_CONFIG_VOLUME}:/home/node/.openclaw"
    -v "${OPENCLAW_DOCKER_WORKSPACE_VOLUME}:/home/node/.openclaw/workspace"
    -v "${OPENCLAW_DOCKER_AUTH_VOLUME}:/home/node/.config/openclaw"
  )
  if [[ -n "${OBSIDIAN_SHARED_PATH}" ]]; then
    local host_path
    host_path="$(normalize_path "${OBSIDIAN_SHARED_PATH}")"
    [[ -d "${host_path}" ]] || die "OBSIDIAN_SHARED_PATH does not exist: ${host_path}"
    mount_args+=(-v "${host_path}:${OBSIDIAN_GUEST_PATH}:rw")
  fi

  if docker_container_exists; then
    echo "OpenClaw Docker container already exists: ${OPENCLAW_DOCKER_NAME}"
    return 0
  fi

  docker create \
    --name "${OPENCLAW_DOCKER_NAME}" \
    --platform linux/arm64 \
    --restart unless-stopped \
    --cpus "${DOCKER_CPUS:-2}" \
    --memory "${DOCKER_MEMORY:-4g}" \
    --shm-size "${DOCKER_SHM_SIZE:-1g}" \
    -p "127.0.0.1:${OPENCLAW_CONTROL_PORT}:18789" \
    -p "127.0.0.1:${OPENCLAW_BRIDGE_PORT}:18790" \
    --add-host host.docker.internal:host-gateway \
    --add-host model-host.internal:host-gateway \
    --cap-drop NET_RAW \
    --cap-drop NET_ADMIN \
    --security-opt no-new-privileges:true \
    "${env_args[@]}" \
    "${mount_args[@]}" \
    "${OPENCLAW_IMAGE}" \
    node openclaw.mjs gateway run \
      --bind "${OPENCLAW_GATEWAY_BIND}" \
      --port 18789 \
      --auth token \
      --token "${OPENCLAW_GATEWAY_TOKEN}" >/dev/null

  echo "Created OpenClaw Docker gateway: ${OPENCLAW_DOCKER_NAME}"
  print_dashboard_access
}

  docker_start() {
  docker_create
  docker start "${OPENCLAW_DOCKER_NAME}" >/dev/null
  echo "OpenClaw Docker gateway running: ${OPENCLAW_DOCKER_NAME}"
  print_dashboard_access
}

docker_stop() {
  if docker_container_exists; then
    docker stop "${OPENCLAW_DOCKER_NAME}" >/dev/null 2>&1 || true
    echo "OpenClaw Docker gateway stopped: ${OPENCLAW_DOCKER_NAME}"
  else
    echo "OpenClaw Docker gateway does not exist: ${OPENCLAW_DOCKER_NAME}"
  fi
}

docker_destroy() {
  docker_stop
  if docker_container_exists; then
    docker rm "${OPENCLAW_DOCKER_NAME}" >/dev/null 2>&1 || true
  fi
  docker volume rm "${OPENCLAW_DOCKER_CONFIG_VOLUME}" "${OPENCLAW_DOCKER_WORKSPACE_VOLUME}" "${OPENCLAW_DOCKER_AUTH_VOLUME}" >/dev/null 2>&1 || true
  echo "Removed OpenClaw Docker volumes if present: ${OPENCLAW_DOCKER_CONFIG_VOLUME}, ${OPENCLAW_DOCKER_WORKSPACE_VOLUME}, ${OPENCLAW_DOCKER_AUTH_VOLUME}"
}

vm_exec_agent() {
  multipass exec "${VM_NAME}" -- sudo -Hu "${VM_SSH_USER}" bash -lc "export PATH=\"\$HOME/.npm-global/bin:\$HOME/.local/bin:\$PATH\"; $1"
}

vm_exec_root() {
  multipass exec "${VM_NAME}" -- sudo bash -lc "$1"
}

vm_running() {
  command -v multipass >/dev/null 2>&1 && multipass info "${VM_NAME}" >/dev/null 2>&1
}

vm_running_state() {
  vm_running && [[ "$(multipass info "${VM_NAME}" | awk '/State/ { print $2; exit }')" == "Running" ]]
}

ensure_vm_model_host_alias() {
  vm_exec_root '
    if [[ -f /usr/local/sbin/update-model-host-alias ]]; then
      chmod 0755 /usr/local/sbin/update-model-host-alias
      systemctl daemon-reload
      systemctl enable --now model-host-alias.service >/dev/null 2>&1 || /usr/local/sbin/update-model-host-alias || true
    else
      gateway="$(ip route | awk "/default/ {print \$3; exit}")"
      if [[ -n "${gateway}" ]]; then
        grep -v "[[:space:]]model-host\\.internal$" /etc/hosts > /etc/hosts.tmp
        printf "%s model-host.internal\n" "${gateway}" >> /etc/hosts.tmp
        mv /etc/hosts.tmp /etc/hosts
      fi
    fi
  ' >/dev/null 2>&1 || true
}

vm_openclaw_process_running() {
  local ip
  vm_running_state || return 1
  ip="$(multipass info "${VM_NAME}" | awk '/IPv4/ { print $2; exit }')"
  [[ -n "${ip}" ]] || return 1
  if [[ -n "${TIMEOUT_BIN}" ]]; then
    "${TIMEOUT_BIN}" 5s ssh -i "${VM_SSH_KEY}" \
      -o BatchMode=yes -o ConnectTimeout=3 -o StrictHostKeyChecking=accept-new \
      "${VM_SSH_USER}@${ip}" "pgrep -af '[o]penclaw($| )|[n]ode .*openclaw.mjs gateway|[n]ode .*dist/index.js gateway'" >/dev/null 2>&1
  else
    ssh -i "${VM_SSH_KEY}" \
      -o BatchMode=yes -o ConnectTimeout=3 -o StrictHostKeyChecking=accept-new \
      "${VM_SSH_USER}@${ip}" "pgrep -af '[o]penclaw($| )|[n]ode .*openclaw.mjs gateway|[n]ode .*dist/index.js gateway'" >/dev/null 2>&1
  fi
}

vm_configure() {
  ensure_gateway_token
  detect_model
  [[ -n "${OPENAI_API_KEY}" ]] || die "OPENAI_API_KEY missing. Run make bootstrap or set it in .env."
  vm_running || die "Multipass VM missing: ${VM_NAME}. Run make vm-create first."
  ensure_vm_model_host_alias

  vm_exec_root 'apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y ca-certificates curl jq lsof procps'
  vm_exec_root "install -d -o '${VM_SSH_USER}' -g '${VM_SSH_USER}' '/home/${VM_SSH_USER}/.openclaw' '/home/${VM_SSH_USER}/.openclaw/workspace'"

  vm_exec_agent 'if ! command -v openclaw >/dev/null 2>&1; then curl -fsSL https://openclaw.ai/install.sh | NO_PROMPT=1 bash -s -- --no-onboard; fi'

  local config_json
  config_json="$(openclaw_config_json)"

  multipass exec "${VM_NAME}" -- sudo -Hu "${VM_SSH_USER}" env \
    HOME="/home/${VM_SSH_USER}" \
    OPENCLAW_HOME="/home/${VM_SSH_USER}" \
    OPENCLAW_STATE_DIR="/home/${VM_SSH_USER}/.openclaw" \
    OPENCLAW_CONFIG_PATH="/home/${VM_SSH_USER}/.openclaw/openclaw.json" \
    OPENCLAW_CONFIG_DIR="/home/${VM_SSH_USER}/.openclaw" \
    OPENCLAW_WORKSPACE_DIR="/home/${VM_SSH_USER}/.openclaw/workspace" \
    OPENCLAW_AUTH_PROFILE_SECRET_DIR="/home/${VM_SSH_USER}/.config/openclaw" \
    OPENCLAW_GATEWAY_TOKEN="${OPENCLAW_GATEWAY_TOKEN}" \
    OPENCLAW_GATEWAY_BIND="${OPENCLAW_GATEWAY_BIND}" \
    OPENCLAW_CONTROL_PORT="${OPENCLAW_CONTROL_PORT}" \
    OPENCLAW_DISABLE_BONJOUR=1 \
    OPENAI_API_KEY="${OPENAI_API_KEY}" \
    CUSTOM_API_KEY="${OPENAI_API_KEY}" \
    OPENAI_BASE_URL="${OPENCLAW_OPENAI_BASE_URL_GUEST}" \
    MODEL_NAME="${MODEL_NAME}" \
    TELEGRAM_BOT_TOKEN="${TELEGRAM_BOT_TOKEN}" \
    TELEGRAM_USER_ID="${TELEGRAM_USER_ID}" \
    TELEGRAM_ALLOWED_USERS="${TELEGRAM_ALLOWED_USERS}" \
    OPENCLAW_CONFIG_BATCH_JSON="${config_json}" \
    bash -lc 'openclaw onboard --non-interactive --accept-risk --mode local --auth-choice custom-api-key --custom-base-url "$OPENAI_BASE_URL" --custom-model-id "$MODEL_NAME" --custom-api-key "$OPENAI_API_KEY" --secret-input-mode plaintext --custom-compatibility openai --custom-text-input --gateway-auth token --gateway-bind "$OPENCLAW_GATEWAY_BIND" --gateway-port "$OPENCLAW_CONTROL_PORT" --gateway-token-ref-env OPENCLAW_GATEWAY_TOKEN --no-install-daemon --skip-daemon --skip-ui --skip-health >/dev/null && openclaw config set --batch-json "$OPENCLAW_CONFIG_BATCH_JSON" >/dev/null'

  vm_exec_agent "cat > ~/.openclaw/.env <<'EOF'
OPENCLAW_HOME=/home/${VM_SSH_USER}
OPENCLAW_STATE_DIR=/home/${VM_SSH_USER}/.openclaw
OPENCLAW_CONFIG_PATH=/home/${VM_SSH_USER}/.openclaw/openclaw.json
OPENCLAW_CONFIG_DIR=/home/${VM_SSH_USER}/.openclaw
OPENCLAW_WORKSPACE_DIR=/home/${VM_SSH_USER}/.openclaw/workspace
OPENCLAW_AUTH_PROFILE_SECRET_DIR=/home/${VM_SSH_USER}/.config/openclaw
OPENCLAW_GATEWAY_TOKEN=${OPENCLAW_GATEWAY_TOKEN}
OPENCLAW_DISABLE_BONJOUR=1
OPENAI_API_KEY=${OPENAI_API_KEY}
CUSTOM_API_KEY=${OPENAI_API_KEY}
OPENAI_BASE_URL=${OPENCLAW_OPENAI_BASE_URL_GUEST}
MODEL_NAME=${MODEL_NAME}
TELEGRAM_BOT_TOKEN=${TELEGRAM_BOT_TOKEN}
TELEGRAM_USER_ID=${TELEGRAM_USER_ID}
TELEGRAM_ALLOWED_USERS=${TELEGRAM_ALLOWED_USERS}
EOF
chmod 600 ~/.openclaw/.env"

  vm_exec_agent "grep -Fqx 'export PATH=\"\$HOME/.npm-global/bin:\$HOME/.local/bin:\$PATH\"' ~/.profile || printf '\\nexport PATH=\"\$HOME/.npm-global/bin:\$HOME/.local/bin:\$PATH\"\\n' >> ~/.profile"
}

vm_start_tunnel() {
  mkdir -p "${RUNTIME_DIR}"
  local pid_file="${RUNTIME_DIR}/openclaw-vm-dashboard-tunnel.pid"
  if [[ -f "${pid_file}" ]] && kill -0 "$(cat "${pid_file}")" >/dev/null 2>&1; then
    return 0
  fi
  local ip
  ip="$(multipass info "${VM_NAME}" | awk '/IPv4/ { print $2; exit }')"
  [[ -n "${ip}" ]] || die "could not detect VM IP for ${VM_NAME}"
  ssh -fN \
    -i "${VM_SSH_KEY}" \
    -o StrictHostKeyChecking=accept-new \
    -o ExitOnForwardFailure=yes \
    -L "127.0.0.1:${OPENCLAW_CONTROL_PORT}:127.0.0.1:${OPENCLAW_CONTROL_PORT}" \
    "${VM_SSH_USER}@${ip}"
  pgrep -f "127.0.0.1:${OPENCLAW_CONTROL_PORT}:127.0.0.1:${OPENCLAW_CONTROL_PORT}" | tail -n1 > "${pid_file}" || true
}

vm_stop_tunnel() {
  local pid_file="${RUNTIME_DIR}/openclaw-vm-dashboard-tunnel.pid"
  if [[ -f "${pid_file}" ]]; then
    kill "$(cat "${pid_file}")" >/dev/null 2>&1 || true
    rm -f "${pid_file}"
  fi
  pkill -f "127.0.0.1:${OPENCLAW_CONTROL_PORT}:127.0.0.1:${OPENCLAW_CONTROL_PORT}" >/dev/null 2>&1 || true
}

vm_start() {
  vm_running_state || "${SCRIPT_DIR}/vm-control.sh" start
  vm_configure
  vm_exec_agent "mkdir -p ~/.openclaw/logs; if [[ -f ~/.openclaw/gateway.pid ]] && kill -0 \"\$(cat ~/.openclaw/gateway.pid)\" >/dev/null 2>&1 && ps -p \"\$(cat ~/.openclaw/gateway.pid)\" -o command= | grep -Eq '[o]penclaw|[n]ode .*openclaw.mjs'; then exit 0; fi; set -a; . ~/.openclaw/.env; set +a; nohup openclaw gateway run --bind '${OPENCLAW_GATEWAY_BIND}' --port '${OPENCLAW_CONTROL_PORT}' --auth token --token '${OPENCLAW_GATEWAY_TOKEN}' > ~/.openclaw/logs/gateway.log 2>&1 & echo \$! > ~/.openclaw/gateway.pid"
  vm_start_tunnel
  echo "OpenClaw VM gateway running: ${VM_NAME}"
  print_dashboard_access
}

vm_stop() {
  vm_stop_tunnel
  if vm_running; then
    vm_exec_agent "pkill -f '[o]penclaw($| )|[n]ode .*openclaw.mjs gateway|[n]ode .*dist/index.js gateway' >/dev/null 2>&1 || true; rm -f ~/.openclaw/gateway.pid" || true
  fi
  echo "OpenClaw VM gateway stopped: ${VM_NAME}"
}

vm_destroy_runtime() {
  vm_stop
  if vm_running; then
    vm_exec_root "rm -rf '/home/${VM_SSH_USER}/.openclaw'" || true
  fi
  echo "Removed OpenClaw VM runtime if present."
}

status_target() {
  case "$1" in
    docker)
      if command -v docker >/dev/null 2>&1 && docker_container_exists; then
        if docker_container_running; then
          echo "openclaw_docker=running container=${OPENCLAW_DOCKER_NAME}"
        else
          echo "openclaw_docker=stopped container=${OPENCLAW_DOCKER_NAME}"
        fi
      else
        echo "openclaw_docker=missing container=${OPENCLAW_DOCKER_NAME}"
      fi
      ;;
    multipass|vm)
      if vm_openclaw_process_running; then
        echo "openclaw_vm=running vm=${VM_NAME}"
      elif vm_running; then
        echo "openclaw_vm=stopped vm=${VM_NAME}"
      else
        echo "openclaw_vm=missing vm=${VM_NAME}"
      fi
      ;;
  esac
}

case "${ACTION}:${TARGET}" in
  start:docker) docker_start ;;
  start:multipass|start:vm) vm_start ;;
  stop:docker) docker_stop ;;
  stop:multipass|stop:vm) vm_stop ;;
  restart:docker) docker_stop; docker_start ;;
  restart:multipass|restart:vm) vm_stop; vm_start ;;
  status:docker) status_target docker ;;
  status:multipass|status:vm) status_target multipass ;;
  logs:docker) docker logs --tail 200 "${OPENCLAW_DOCKER_NAME}" 2>&1 || true ;;
  logs:multipass|logs:vm) vm_exec_agent 'tail -n 200 ~/.openclaw/logs/gateway.log 2>/dev/null || true' ;;
  shell:docker)
    docker_create
    docker_container_running || docker start "${OPENCLAW_DOCKER_NAME}" >/dev/null
    tty_args=(-i)
    if [[ -t 0 && -t 1 ]]; then
      tty_args=(-it)
    fi
    exec docker exec "${tty_args[@]}" "${OPENCLAW_DOCKER_NAME}" /bin/bash
    ;;
  shell:multipass|shell:vm) "${SCRIPT_DIR}/vm-control.sh" ssh ;;
  open-dashboard:docker|open-dashboard:multipass|open-dashboard:vm)
    print_dashboard_access
    if command -v open >/dev/null 2>&1; then
      open "$(openclaw_dashboard_auth_url)"
    else
      echo "OpenClaw Control UI: $(openclaw_dashboard_auth_url)"
    fi
    ;;
  destroy:docker) docker_destroy ;;
  destroy:multipass|destroy:vm) vm_destroy_runtime ;;
  *)
    usage
    exit 2
    ;;
esac
