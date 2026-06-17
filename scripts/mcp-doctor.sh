#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
OMLX_HOME="${OMLX_HOME:-${PROJECT_ROOT}}"
ENV_FILE="${OMLX_HOME}/.env"

QUIET=0
MOCK=0
for arg in "$@"; do
  case "${arg}" in
    --quiet) QUIET=1 ;;
    --mock) MOCK=1 ;;
    -h|--help)
      cat <<EOF
Usage: $0 [--quiet] [--mock]

Inspect enabled Hermes MCP servers and run safe local smoke checks.
Secrets are never printed; only presence/absence is reported.
EOF
      exit 0
      ;;
    *)
      echo "Unknown flag: ${arg}" >&2
      exit 2
      ;;
  esac
done

if [[ -f "${ENV_FILE}" ]]; then
  set -a
  # shellcheck disable=SC1090
  source "${ENV_FILE}"
  set +a
fi

DOCKER_NAME="${DOCKER_NAME:-omlx-agent-docker}"
failures=0
warnings=0

say() {
  [[ "${QUIET}" == "1" ]] || printf '%s\n' "$*"
}

ok() {
  say "ok   $*"
}

warn() {
  warnings=$((warnings + 1))
  say "warn $*"
}

fail() {
  failures=$((failures + 1))
  say "fail $*"
}

container_running() {
  command -v docker >/dev/null 2>&1 \
    && docker container inspect "${DOCKER_NAME}" >/dev/null 2>&1 \
    && [[ "$(docker inspect -f '{{.State.Running}}' "${DOCKER_NAME}" 2>/dev/null || true)" == "true" ]]
}

mock_report() {
  ok "mock MCP config parsed"
  ok "filesystem enabled smoke=skipped"
  ok "fetch enabled smoke=skipped"
  ok "git enabled smoke=skipped"
  ok "n8n disabled token=missing"
  say "mcp_doctor=ok failures=0 warnings=0"
}

if [[ "${MOCK}" == "1" ]]; then
  mock_report
  exit 0
fi

if ! container_running; then
  warn "Hermes Docker container is not running: ${DOCKER_NAME}"
  say "next=make agent-start"
  exit 1
fi

mcp_rows=()
while IFS= read -r row; do
  mcp_rows+=("${row}")
done < <(docker exec -i "${DOCKER_NAME}" /opt/hermes/.venv/bin/python3 - <<'PY'
from pathlib import Path
import yaml

cfg = Path("/opt/data/config.yaml")
data = yaml.safe_load(cfg.read_text()) if cfg.exists() else {}
servers = data.get("mcp_servers") or data.get("mcpServers") or {}
for name in sorted(servers):
    item = servers.get(name) or {}
    if not isinstance(item, dict):
        continue
    enabled = item.get("enabled", True)
    command = str(item.get("command", ""))
    args = item.get("args") or []
    env = item.get("env") or {}
    present = []
    for key, value in sorted(env.items()):
        present.append(f"{key}:{'present' if str(value or '').strip() else 'missing'}")
    print("\t".join([
        name,
        "enabled" if enabled else "disabled",
        command,
        " ".join(str(arg) for arg in args),
        ",".join(present),
    ]))
PY
)

if [[ "${#mcp_rows[@]}" -eq 0 ]]; then
  fail "no MCP servers found in /opt/data/config.yaml"
  exit 1
fi

ok "MCP config loaded from ${DOCKER_NAME}"

check_command_in_container() {
  local command_name="$1"
  docker exec "${DOCKER_NAME}" sh -lc "command -v '${command_name}' >/dev/null 2>&1"
}

check_enabled_server() {
  local name="$1"
  local command="$2"
  local args="$3"
  local env_status="$4"

  case "${name}" in
    filesystem)
      if docker exec "${DOCKER_NAME}" sh -lc 'test -d /opt/data/workspace'; then
        ok "filesystem smoke: /opt/data/workspace"
      else
        fail "filesystem smoke: /opt/data/workspace missing"
      fi
      if docker exec "${DOCKER_NAME}" sh -lc 'test -d /mnt/obsidian'; then
        ok "filesystem smoke: /mnt/obsidian"
      else
        warn "filesystem smoke: /mnt/obsidian is not mounted"
      fi
      ;;
    fetch|git|yfinance|docker-manager)
      local required_command="${command}"
      if [[ "${command}" == "env" && "${args}" == *" uvx "* ]]; then
        required_command="uvx"
      fi
      if check_command_in_container "${required_command}"; then
        ok "${name} smoke: command available (${required_command})"
      else
        fail "${name} smoke: command missing (${required_command})"
      fi
      ;;
    puppeteer)
      if docker exec "${DOCKER_NAME}" sh -lc 'test -x "${AGENT_BROWSER_EXECUTABLE_PATH:-}" || find /opt/hermes/.playwright -type f -executable 2>/dev/null | head -n 1 | grep -q .'; then
        ok "puppeteer smoke: browser executable available"
      else
        fail "puppeteer smoke: browser executable missing"
      fi
      ;;
    n8n)
      if docker exec "${DOCKER_NAME}" sh -lc 'curl -fsS --max-time 3 http://host.docker.internal:5678/healthz >/dev/null'; then
        ok "n8n smoke: health endpoint reachable"
      else
        fail "n8n smoke: health endpoint not reachable"
      fi
      ;;
    brave-search|github)
      if [[ "${env_status}" == *":present"* ]]; then
        ok "${name} configured: token present"
      else
        fail "${name} configured: enabled but token missing"
      fi
      ;;
    firecrawl)
      if [[ "${env_status}" == *"FIRECRAWL_API_KEY:present"* ]]; then
        ok "firecrawl configured: API key present"
      elif [[ "${env_status}" == *"FIRECRAWL_API_URL:present"* ]]; then
        ok "firecrawl configured: local/remote URL present"
      else
        fail "firecrawl configured: enabled but API settings missing"
      fi
      ;;
    *)
      warn "${name}: no dedicated smoke check"
      ;;
  esac
}

for row in "${mcp_rows[@]}"; do
  IFS=$'\t' read -r name state command args env_status <<<"${row}"
  if [[ "${state}" == "enabled" ]]; then
    ok "${name}: enabled command=${command} args=${args}"
    check_enabled_server "${name}" "${command}" "${args}" "${env_status:-}"
  else
    say "skip ${name}: disabled ${env_status:-}"
  fi
done

say "mcp_doctor=done failures=${failures} warnings=${warnings}"
[[ "${failures}" -eq 0 ]]
