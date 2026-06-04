#!/usr/bin/env bash
# scripts/setup.sh — Interactive oMLX → local agent Setup Wizard
#
# Usage:
#   ./scripts/setup.sh
#   make setup
#
# Guides you through:
#   1. Detecting installed tools
#   2. Choosing an agent runtime and sandbox backend
#   3. Configuring credentials (.env)
#   4. Selecting a local LLM model
#   5. Deploying the full stack (oMLX + agent + Dashboard/Control UI + Telegram)
#   6. Printing the Dashboard URL and confirming Telegram access

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
OMLX_HOME="${OMLX_HOME:-${PROJECT_ROOT}}"
ENV_FILE="${OMLX_HOME}/.env"
ENV_EXAMPLE="${PROJECT_ROOT}/.env.example"
FORCE_PROMPTS=0
DRY_RUN=0

assert_interactive() {
  local var_name="$1"
  local description="$2"
  if [[ ! -t 0 || ! -t 1 ]]; then
    die "Required setting '${var_name}' (${description}) is missing in .env, and setup is running in a non-interactive terminal."
  fi
}


# ── Colour palette ────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
BOLD='\033[1m'
DIM='\033[2m'
RESET='\033[0m'

# ── Output helpers ────────────────────────────────────────────────────────────
ok()     { printf "${GREEN}  ✓  %s${RESET}\n" "$*"; }
info()   { printf "${CYAN}  →  %s${RESET}\n"  "$*"; }
warn()   { printf "${YELLOW}  ⚠  %s${RESET}\n"  "$*"; }
err()    { printf "${RED}  ✗  %s${RESET}\n"  "$*" >&2; }
step()   { printf "\n${BOLD}${BLUE}══  %s${RESET}\n" "$*"; }
substep(){ printf "${BOLD}  ·  %s${RESET}\n" "$*"; }
die()    { err "$*"; exit 1; }

# ── Interactive prompts ───────────────────────────────────────────────────────
prompt() {
  # prompt <text> [default]  →  prints the user's answer (or default)
  local text="$1"
  local default="${2:-}"
  local answer
  if [[ -n "${default}" ]]; then
    printf "${BOLD}  ?  %s${RESET} ${DIM}[%s]${RESET}: " "${text}" "${default}" >&2
  else
    printf "${BOLD}  ?  %s${RESET}: " "${text}" >&2
  fi
  read -r answer
  printf '%s' "${answer:-${default}}"
}

prompt_secret() {
  local text="$1"
  local answer
  printf "${BOLD}  ?  %s${RESET}: " "${text}" >&2
  read -r -s answer
  echo >&2
  printf '%s' "${answer}"
}

# Numbered menu.  Returns 0-based index of the chosen option.
# All UI output goes to stderr so $(choose_menu ...) captures only the result.
choose_menu() {
  local title="$1"; shift
  local -a options=("$@")
  local i
  printf "\n  ${BOLD}%s${RESET}\n" "${title}" >&2
  for i in "${!options[@]}"; do
    printf "    ${CYAN}%d)${RESET}  %s\n" "$((i + 1))" "${options[$i]}" >&2
  done
  local choice
  while true; do
    printf "${BOLD}  →  Select [1-%d]: ${RESET}" "${#options[@]}" >&2
    read -r choice </dev/tty
    if [[ "${choice}" =~ ^[0-9]+$ ]] && \
       [[ "${choice}" -ge 1 ]] && \
       [[ "${choice}" -le "${#options[@]}" ]]; then
      echo "$((choice - 1))"
      return
    fi
    warn "Please enter a number between 1 and ${#options[@]}"
  done
}

# ── .env helpers ──────────────────────────────────────────────────────────────
env_get() {
  local key="$1"
  [[ -f "${ENV_FILE}" ]] || { printf ''; return; }
  # Use a subshell so sourcing doesn't pollute the wizard environment.
  (set -a; source "${ENV_FILE}" 2>/dev/null; set +a; printf '%s' "${!key:-}")
}

env_put() {
  "${SCRIPT_DIR}/env-set.sh" "${ENV_FILE}" "$1" "$2"
}

ensure_env_file() {
  if [[ ! -f "${ENV_FILE}" ]]; then
    [[ -f "${ENV_EXAMPLE}" ]] || die ".env.example not found — is PROJECT_ROOT correct?"
    cp "${ENV_EXAMPLE}" "${ENV_FILE}"
  fi
}

repair_corrupted_env() {
  if [[ -f "${ENV_FILE}" ]]; then
    if grep -qE '(\x1b|\[1m|\?  |n8n API Key)' "${ENV_FILE}"; then
      substep "Repairing corrupted ANSI entries in .env..."
      local temp_env="${ENV_FILE}.tmp"
      grep -vE '(\x1b|\[1m|\?  |n8n API Key)' "${ENV_FILE}" > "${temp_env}" || true
      # Guard: never replace .env with an empty file
      if [[ -s "${temp_env}" ]]; then
        mv "${temp_env}" "${ENV_FILE}"
        ok ".env file repaired (removed corrupted entries)"
      else
        rm -f "${temp_env}"
        warn "repair_corrupted_env: all lines matched the corruption pattern — skipping repair to avoid wiping .env"
      fi
    fi
  fi
}

# ── Banner ────────────────────────────────────────────────────────────────────
print_banner() {
  if [[ -t 1 && -n "${TERM:-}" ]]; then
    clear
  fi
  printf "${CYAN}${BOLD}"
  cat <<'BANNER'

  ╔══════════════════════════════════════════════════════════════╗
  ║                                                              ║
  ║        oMLX  →  Agent    ·   Setup Wizard   🚀              ║
  ║                                                              ║
  ║    Apple Silicon  ·  Local LLM  ·  Isolated Agent Stack     ║
  ║                                                              ║
  ╚══════════════════════════════════════════════════════════════╝

BANNER
  printf "${RESET}"
}

# ── Step 1: Detect current state ──────────────────────────────────────────────
HAVE_BREW=0; HAVE_LMS=0; HAVE_OMLX=0
HAVE_DOCKER=0
OMLX_RUNNING=0

detect_state() {
  step "Detecting installed tools"

  command -v brew > /dev/null 2>&1 \
    && { HAVE_BREW=1;    ok  "Homebrew"; } \
    || warn "Homebrew not found"

  { [[ -x "${HOME}/.lmstudio/bin/lms" ]] || command -v lms > /dev/null 2>&1; } \
    && { HAVE_LMS=1;    ok  "LM Studio CLI (lms)"; } \
    || warn "LM Studio CLI not found"

  command -v omlx > /dev/null 2>&1 \
    && { HAVE_OMLX=1;   ok  "oMLX"; } \
    || warn "oMLX not found"

  if { command -v docker > /dev/null 2>&1 && docker version > /dev/null 2>&1; }; then
    HAVE_DOCKER=1
    ok "Docker Desktop"
  else
    warn "Docker Desktop not running — start it before continuing"
  fi

  [[ -f "${ENV_FILE}" ]] && ok ".env present" || warn ".env not found (will create)"

  local api_key base_url
  api_key="$(env_get OPENAI_API_KEY)"
  base_url="$(env_get OPENAI_BASE_URL)"
  base_url="${base_url:-http://localhost:8000/v1}"

  if [[ -n "${api_key}" ]] && \
     curl -fsS --max-time 2 \
       -H "Authorization: Bearer ${api_key}" \
       "${base_url}/models" > /dev/null 2>&1; then
    OMLX_RUNNING=1
    ok "oMLX API already reachable at ${base_url}"
  else
    warn "oMLX API not running yet"
  fi
}

# ── Step 2: Bootstrap ─────────────────────────────────────────────────────────
run_bootstrap_if_needed() {
  if [[ "${HAVE_BREW}" -eq 1 && "${HAVE_OMLX}" -eq 1 ]]; then
    info "Core tools already installed — skipping bootstrap"
    return
  fi
  step "Installing prerequisites"
  if [[ "${DRY_RUN}" -eq 1 ]]; then
    info "[Dry-Run] Would run bootstrap-macos.sh"
  else
    "${SCRIPT_DIR}/bootstrap-macos.sh"
  fi
  HAVE_BREW=1; HAVE_OMLX=1
}

FORCE_RESTART_RAG=1

get_agent_records() {
  if command -v docker >/dev/null 2>&1; then
    local hermes_name="${DOCKER_NAME:-omlx-agent-docker}"
    if docker container inspect "${hermes_name}" >/dev/null 2>&1; then
      local status
      status="$(docker inspect -f '{{.State.Status}}' "${hermes_name}" 2>/dev/null || echo "unknown")"
      echo "hermes|${hermes_name}|${status}"
    fi
    local openclaw_name="${OPENCLAW_DOCKER_NAME:-omlx-agent-openclaw-docker}"
    if docker container inspect "${openclaw_name}" >/dev/null 2>&1; then
      local status
      status="$(docker inspect -f '{{.State.Status}}' "${openclaw_name}" 2>/dev/null || echo "unknown")"
      echo "openclaw|${openclaw_name}|${status}"
    fi
  fi
}

preflight_agent_state() {
  step "Checking for active agent stacks"

  local -a active_records=()
  local record
  while IFS= read -r record; do
    [[ -n "${record}" ]] || continue
    active_records+=("${record}")
  done < <(get_agent_records)

  if [[ "${#active_records[@]}" -gt 0 ]]; then
    printf "  ${DIM}Detected existing agent stack(s):${RESET}\n"
    for r in "${active_records[@]}"; do
      local runtime="${r%%|*}"
      local name="$(printf '%s\n' "${r}" | cut -d'|' -f2)"
      local status="$(printf '%s\n' "${r}" | cut -d'|' -f3)"
      printf "    ${CYAN}- %s (status: %s)${RESET}\n" "${runtime} [Docker: ${name}]" "${status}"
    done
    
    local idx
    if [[ "${FORCE_PROMPTS}" -eq 0 ]]; then
      idx=0
      info "Non-interactive default: Stopping and removing existing agent stack(s)"
    else
      idx="$(choose_menu "An agent stack currently exists in Docker. What would you like to do?" \
        "Stop and remove existing agent stack(s) (recommended)" \
        "Leave them as is and continue setup" \
        "Abort setup")"
    fi
    case "${idx}" in
      0)
        substep "Stopping and removing agent stack(s)..."
        for r in "${active_records[@]}"; do
          local runtime="${r%%|*}"
          local name="$(printf '%s\n' "${r}" | cut -d'|' -f2)"
          if [[ "${DRY_RUN}" -eq 1 ]]; then
            info "[Dry-Run] Would stop and remove existing agent stack: ${runtime} [Docker: ${name}]"
          else
            AGENT_RUNTIME="${runtime}" SANDBOX_BACKEND="docker" "${SCRIPT_DIR}/agent-control.sh" stop >/dev/null 2>&1 || true
            docker rm -f "${name}" >/dev/null 2>&1 || true
          fi
        done
        ok "Agent stack(s) stopped and removed"
        ;;
      1)
        warn "Continuing setup with existing agent stacks."
        ;;
      2)
        abort_setup "Setup aborted by user."
        ;;
    esac
  else
    ok "No active agent stack detected"
  fi

  # Ask if they want to restart/rebuild the RAG stack
  if [[ -x "${SCRIPT_DIR}/rag-control.sh" ]]; then
    local rag_status
    rag_status="$(RAG_ENABLED=1 "${SCRIPT_DIR}/rag-control.sh" status 2>/dev/null || true)"
    if [[ "${rag_status}" == *"rag=running"* ]]; then
      printf "\n"
      local rag_choice
      if [[ "${FORCE_PROMPTS}" -eq 0 ]]; then
        rag_choice=0
        info "Non-interactive default: Keeping current running RAG stack"
      else
        rag_choice="$(choose_menu "RAG stack is currently running. What would you like to do?" \
          "Keep the current RAG stack running (reuse)" \
          "Restart/rebuild the RAG stack" \
          "Stop RAG stack and continue setup without it")"
      fi
      case "${rag_choice}" in
        0)
          FORCE_RESTART_RAG=0
          ok "Will reuse running RAG stack"
          ;;
        1)
          FORCE_RESTART_RAG=1
          substep "RAG stack will be restarted during deployment"
          ;;
        2)
          FORCE_RESTART_RAG=0
          RAG_SELECTED=0
          substep "Stopping RAG stack..."
          if [[ "${DRY_RUN}" -eq 1 ]]; then
            info "[Dry-Run] Would stop RAG stack"
          else
            RAG_ENABLED=1 "${SCRIPT_DIR}/rag-control.sh" stop >/dev/null 2>&1 || true
          fi
          ok "RAG stack stopped"
          ;;
      esac
    else
      FORCE_RESTART_RAG=1
    fi
  fi
}

# ── Step 3: Choose agent runtime ─────────────────────────────────────────────
AGENT_RUNTIME=""
BACKEND="docker"          # Docker is the only supported backend
PREVIOUS_AGENT_RUNTIME=""
PREVIOUS_SANDBOX_BACKEND=""
SETUP_AGENT_CONFLICT_POLICY="prompt"

choose_runtime() {
  # Skip if AGENT_RUNTIME is already set and the user is re-running setup
  local current
  current="$(env_get AGENT_RUNTIME)"
  if [[ -n "${current}" && "${current}" != "hermes" && "${current}" != "openclaw" ]]; then
    current=""
  fi

  if [[ "${FORCE_PROMPTS}" -eq 0 && -n "${current}" ]]; then
    AGENT_RUNTIME="${current}"
    ensure_env_file
    # Always lock in Docker as the backend
    env_put SANDBOX_BACKEND "docker"
    env_put TELEGRAM_TARGET "docker"
    env_put DASHBOARD_TARGET "docker"
    if [[ -z "$(env_get HERMES_DASHBOARD_TUI)" ]]; then
      env_put HERMES_DASHBOARD_TUI "0"
    fi
    BACKEND="docker"
    ok "Agent: ${AGENT_RUNTIME} (from .env)"
    return
  fi

  assert_interactive "AGENT_RUNTIME" "agent runtime selection (hermes or openclaw)"

  step "Choose agent"
  printf "  ${DIM}Both agents run in Docker. Only one stack may be active at a time.${RESET}\n"

  local -a options=()
  options+=("Hermes       — conversational agent, Telegram / web dashboard")
  options+=("OpenClaw     — browser-use agent, control UI")

  local idx
  idx="$(choose_menu "Which agent do you want to run?" "${options[@]}")"

  ensure_env_file
  # Always lock in Docker as the backend
  env_put SANDBOX_BACKEND "docker"
  env_put TELEGRAM_TARGET "docker"
  env_put DASHBOARD_TARGET "docker"
  if [[ -z "$(env_get HERMES_DASHBOARD_TUI)" ]]; then
    env_put HERMES_DASHBOARD_TUI "0"
  fi
  BACKEND="docker"

  case "${idx}" in
    0)
      AGENT_RUNTIME="hermes"
      env_put AGENT_RUNTIME "hermes"
      ok "Agent: Hermes (Docker)"
      ;;
    1)
      AGENT_RUNTIME="openclaw"
      env_put AGENT_RUNTIME "openclaw"
      ok "Agent: OpenClaw (Docker)"
      ;;
  esac
}

runtime_target() {
  # Always Docker
  printf 'docker\n'
}

agent_mode_label() {
  local record="$1"
  local mode runtime backend target_name
  mode="${record%%|*}"
  runtime="$(printf '%s\n' "${record}" | cut -d'|' -f2)"
  backend="$(printf '%s\n' "${record}" | cut -d'|' -f3)"
  target_name="$(printf '%s\n' "${record}" | cut -d'|' -f4)"
  printf '%s (%s/%s: %s)\n' "${mode}" "${runtime}" "${backend}" "${target_name}"
}

pause_detected_mode() {
  local mode="$1"
  "${SCRIPT_DIR}/agent-control.sh" pause-mode "${mode}"
}

abort_setup() {
  [[ -n "${PREVIOUS_AGENT_RUNTIME}" ]] && env_put AGENT_RUNTIME "${PREVIOUS_AGENT_RUNTIME}"
  [[ -n "${PREVIOUS_SANDBOX_BACKEND}" ]] && env_put SANDBOX_BACKEND "${PREVIOUS_SANDBOX_BACKEND}"
  die "$1"
}

preflight_active_agent() {
  step "Active agent preflight"

  local requested_mode="${AGENT_RUNTIME}/$(runtime_target)"
  local -a active_records=()
  local record
  while IFS= read -r record; do
    [[ -n "${record}" ]] || continue
    active_records+=("${record}")
  done < <(get_agent_records)

  if [[ "${#active_records[@]}" -eq 0 ]]; then
    ok "No active agent stack detected"
    return
  fi

  printf "  ${DIM}Detected active agent stack(s):${RESET}\n"
  local same_active=0
  local other_active=0
  for record in "${active_records[@]}"; do
    local runtime="${record%%|*}"
    local name="$(printf '%s\n' "${record}" | cut -d'|' -f2)"
    local status="$(printf '%s\n' "${record}" | cut -d'|' -f3)"
    printf "    ${CYAN}- %s (status: %s)${RESET}\n" "${runtime} [Docker: ${name}]" "${status}"
    if [[ "${runtime}" == "${AGENT_RUNTIME}" ]]; then
      same_active=1
    else
      other_active=1
    fi
  done
  printf "  ${DIM}Requested stack: ${requested_mode}${RESET}\n"

  local idx
  if [[ "${other_active}" -eq 0 && "${same_active}" -eq 1 ]]; then
    if [[ "${FORCE_PROMPTS}" -eq 0 ]]; then
      idx=1
      info "Non-interactive default: Recreating agent stack container to apply configuration"
    else
      idx="$(choose_menu "The requested stack already exists. What should setup do?" \
        "Reuse it and continue setup" \
        "Stop and remove it to force recreate (recommended)" \
        "Full clean-all reset before continuing" \
        "Abort setup")"
    fi
    case "${idx}" in
      0)
        SETUP_AGENT_CONFLICT_POLICY="prompt"
        ok "Will reuse active stack"
        ;;
      1)
        local container_name
        container_name="${DOCKER_NAME:-omlx-agent-docker}"
        if [[ "${AGENT_RUNTIME}" == "openclaw" ]]; then
          container_name="${OPENCLAW_DOCKER_NAME:-omlx-agent-openclaw-docker}"
        fi
        if [[ "${DRY_RUN}" -eq 1 ]]; then
          info "[Dry-Run] Would stop/pause and remove container '${container_name}'"
        else
          pause_detected_mode "${requested_mode}"
          substep "Removing container '${container_name}' to force recreation..."
          docker rm -f "${container_name}" >/dev/null 2>&1 || true
        fi
        SETUP_AGENT_CONFLICT_POLICY="prompt"
        ok "Active stack stopped and removed"
        ;;
      2)
        if [[ "${DRY_RUN}" -eq 1 ]]; then
          info "[Dry-Run] Would run clean-all.sh"
        else
          FORCE=1 "${SCRIPT_DIR}/clean-all.sh"
        fi
        SETUP_AGENT_CONFLICT_POLICY="prompt"
        ok "Sandbox reset complete"
        ;;
      3)
        abort_setup "Setup aborted by user."
        ;;
    esac
    return
  fi

  if [[ "${FORCE_PROMPTS}" -eq 0 ]]; then
    idx=0
    info "Non-interactive default: Stopping conflicting agent stack(s)"
  else
    idx="$(choose_menu "Another stack exists. What should setup do?" \
      "Stop and remove conflicting stack(s) and continue" \
      "Full clean-all reset before continuing" \
      "Continue anyway without stopping anything" \
      "Abort setup")"
  fi
  case "${idx}" in
    0)
      for record in "${active_records[@]}"; do
        local runtime="${record%%|*}"
        local name="$(printf '%s\n' "${record}" | cut -d'|' -f2)"
        local r_mode="${runtime}/docker"
        [[ "${runtime}" == "${AGENT_RUNTIME}" ]] && continue
        if [[ "${DRY_RUN}" -eq 1 ]]; then
          info "[Dry-Run] Would pause and remove conflicting container '${name}'"
        else
          pause_detected_mode "${r_mode}"
          substep "Removing container '${name}'..."
          docker rm -f "${name}" >/dev/null 2>&1 || true
        fi
      done
      SETUP_AGENT_CONFLICT_POLICY="prompt"
      ok "Conflicting stack(s) stopped and removed"
      ;;
    1)
      if [[ "${DRY_RUN}" -eq 1 ]]; then
        info "[Dry-Run] Would run clean-all.sh"
      else
        FORCE=1 "${SCRIPT_DIR}/clean-all.sh"
      fi
      SETUP_AGENT_CONFLICT_POLICY="prompt"
      ok "Sandbox reset complete"
      ;;
    2)
      SETUP_AGENT_CONFLICT_POLICY="ignore"
      warn "Continuing with another stack still active. Use this only for stale detection or advanced debugging."
      ;;
    3)
      abort_setup "Setup aborted by user."
      ;;
  esac
}

preflight_port_conflicts() {
  step "Port conflict check"

  if [[ -f "${ENV_FILE}" ]]; then
    set -a
    source "${ENV_FILE}"
    set +a
  fi

  local -a ports=()
  local -a labels=()
  if [[ "${AGENT_RUNTIME}" == "hermes" ]]; then
    ports+=("${DOCKER_DASHBOARD_PORT:-9120}" "${DOCKER_GATEWAY_API_PORT:-8642}")
    labels+=("Hermes Dashboard" "Hermes Gateway API")
  else
    ports+=("${OPENCLAW_CONTROL_PORT:-18789}")
    labels+=("OpenClaw Control")
    if [[ "${OPENCLAW_EXPOSE_BRIDGE_PORT:-0}" == "1" || "${OPENCLAW_EXPOSE_BRIDGE_PORT:-0}" == "true" ]]; then
      ports+=("${OPENCLAW_BRIDGE_PORT:-18790}")
      labels+=("OpenClaw Bridge")
    fi
  fi

  local conflict_found=0
  for i in "${!ports[@]}"; do
    local port="${ports[$i]}"
    local label="${labels[$i]}"
    local lsof_lines
    lsof_lines="$(lsof -nP -iTCP:"${port}" -sTCP:LISTEN 2>/dev/null | tail -n +2 || true)"
    if [[ -n "${lsof_lines}" ]]; then
      conflict_found=1
      local first_line
      first_line="$(printf '%s\n' "${lsof_lines}" | head -n 1)"
      local proc_name
      proc_name="$(printf '%s\n' "${first_line}" | awk '{print $1}')"
      local pid
      pid="$(printf '%s\n' "${first_line}" | awk '{print $2}')"
      
      warn "Port ${port} (${label}) is already in use by process '${proc_name}' (PID: ${pid})."
      
      if [[ "${proc_name}" == "docker-pr"* || "${proc_name}" == "com.docke"* ]]; then
        local container_name
        container_name="$(docker ps --filter "publish=${port}" --format '{{.Names}}' 2>/dev/null || true)"
        if [[ -n "${container_name}" ]]; then
          warn "Port is mapped by running container: ${container_name}."
        fi
      fi
    fi
  done

  if [[ "${conflict_found}" -eq 1 ]]; then
    local idx
    if [[ "${FORCE_PROMPTS}" -eq 0 ]]; then
      idx=0
      info "Non-interactive default: Attempting to clear port conflicts automatically"
    else
      idx="$(choose_menu "Port conflicts detected. How should setup proceed?" \
        "Attempt to kill conflicting host processes / stop Docker containers and continue" \
        "Ignore and continue anyway (may fail to start)" \
        "Abort setup")"
    fi
    case "${idx}" in
      0)
        for port in "${ports[@]}"; do
          # 1. Stop any docker container mapping this port
          local container_name
          container_name="$(docker ps --filter "publish=${port}" --format '{{.Names}}' 2>/dev/null | head -n 1 || true)"
          if [[ -n "${container_name}" ]]; then
            if [[ "${DRY_RUN}" -eq 1 ]]; then
              info "[Dry-Run] Would stop container '${container_name}' occupying port ${port}"
            else
              substep "Stopping container '${container_name}' occupying port ${port}..."
              docker stop "${container_name}" >/dev/null 2>&1 || true
            fi
          fi

          # 2. Kill any host process occupying this port
          local pids
          pids="$(lsof -t -iTCP:"${port}" -sTCP:LISTEN 2>/dev/null | sort -u || true)"
          if [[ -n "${pids}" ]]; then
            for pid in ${pids}; do
              local comm
              comm="$(ps -p "${pid}" -o comm= 2>/dev/null || true)"
              local comm_base
              comm_base="$(basename "${comm}" 2>/dev/null || echo "${comm}")"
              if [[ "${comm_base}" != *"docker"* && "${comm_base}" != *"launchd"* && -n "${pid}" ]]; then
                # Check if this process is managed by launchd
                local label
                label="$(launchctl list 2>/dev/null | grep -E "(^|[[:space:]])${pid}([[:space:]]|$)" | awk '{print $3}' || true)"
                if [[ -n "${label}" ]]; then
                  if [[ "${DRY_RUN}" -eq 1 ]]; then
                    info "[Dry-Run] Would stop launchd service '${label}' (PID: ${pid}) occupying port ${port}"
                  else
                    substep "Stopping launchd service '${label}' (PID: ${pid}) occupying port ${port}..."
                    local plist_paths=(
                      "${HOME}/Library/LaunchAgents/${label}.plist"
                      "/Library/LaunchAgents/${label}.plist"
                      "/Library/LaunchDaemons/${label}.plist"
                    )
                    for plist in "${plist_paths[@]}"; do
                      if [[ -f "${plist}" ]]; then
                        launchctl bootout "gui/$(id -u)" "${plist}" >/dev/null 2>&1 || \
                        launchctl unload "${plist}" >/dev/null 2>&1 || true
                        mv "${plist}" "${plist}.disabled" >/dev/null 2>&1 || true
                      fi
                    done
                    launchctl remove "${label}" >/dev/null 2>&1 || true
                  fi
                fi

                if [[ "${DRY_RUN}" -eq 1 ]]; then
                  info "[Dry-Run] Would kill process '${comm_base}' (PID: ${pid}) occupying port ${port}"
                else
                  substep "Killing process '${comm_base}' (PID: ${pid}) occupying port ${port}..."
                  kill -9 "${pid}" 2>/dev/null || true
                fi
              fi
            done
          fi
        done
        ok "Port cleanup finished."
        ;;
      1)
        ok "Continuing despite conflicts."
        ;;
      2)
        abort_setup "Setup aborted due to port conflicts."
        ;;
    esac
  else
    ok "All required ports are available"
  fi
}

# ── Step 4: Credentials ───────────────────────────────────────────────────────
configure_credentials() {
  step "Credentials"
  ensure_env_file

  # ── oMLX API key ──
  local current_key
  current_key="$(env_get OPENAI_API_KEY)"
  local is_placeholder=0
  [[ -z "${current_key}" || "${current_key}" == "change-me" || \
     "${current_key}" == "local-not-needed" ]] && is_placeholder=1

  if [[ "${is_placeholder}" -eq 1 ]]; then
    substep "Generating local oMLX API key..."
    local new_key
    new_key="$(openssl rand -hex 24 2>/dev/null \
      || LC_ALL=C tr -dc 'a-f0-9' </dev/urandom | head -c 48; printf '\n')"
    env_put OPENAI_API_KEY "${new_key}"
    env_put ANTHROPIC_API_KEY "${new_key}"
    ok "API key generated"
  else
    ok "API key already configured"
  fi

  # ── Base URLs ──
  env_put OPENAI_BASE_URL     "http://localhost:8000/v1"
  env_put ANTHROPIC_BASE_URL  "http://localhost:8000"

  # ── Telegram (optional) ──
  printf "\n"
  local tg_token
  tg_token="$(env_get TELEGRAM_BOT_TOKEN)"

  if [[ -z "${tg_token}" ]]; then
    if [[ "${FORCE_PROMPTS}" -eq 0 || ! -t 0 ]]; then
      info "Telegram skipped — no bot token configured in .env"
    else
      printf "  ${DIM}Telegram lets you chat with the agent from your phone. Press Enter to skip.${RESET}\n"
      tg_token="$(prompt "Telegram bot token (from @BotFather)")"
      if [[ -n "${tg_token}" ]]; then
        env_put TELEGRAM_BOT_TOKEN "${tg_token}"
        ok "Telegram bot token saved"
      else
        info "Telegram skipped — you can add TELEGRAM_BOT_TOKEN to .env later"
      fi
    fi
  else
    ok "Telegram bot token already configured"
  fi

  if [[ -n "$(env_get TELEGRAM_BOT_TOKEN)" ]]; then
    local tg_uid
    tg_uid="$(env_get TELEGRAM_USER_ID)"
    if [[ -z "${tg_uid}" ]]; then
      if [[ "${FORCE_PROMPTS}" -eq 1 && -t 0 ]]; then
        printf "  ${DIM}Your numeric Telegram user ID (from @userinfobot) enables auto-approve. Optional.${RESET}\n"
        tg_uid="$(prompt "Your Telegram user ID" "")"
        [[ -n "${tg_uid}" ]] && env_put TELEGRAM_USER_ID "${tg_uid}" && ok "Telegram user ID: ${tg_uid}"
      fi
    else
      ok "Telegram user ID: ${tg_uid}"
    fi
  fi
}

# ── Step 5: Model selection ───────────────────────────────────────────────────
SELECTED_MODEL=""
RAG_SELECTED=0
RAG_SMOKE_QUERY=""

configure_model() {
  step "Model selection"

  local current_model
  current_model="$(env_get MODEL_NAME)"
  if [[ "${FORCE_PROMPTS}" -eq 0 && -n "${current_model}" ]]; then
    SELECTED_MODEL="${current_model}"
    if [[ "${DRY_RUN}" -eq 0 ]]; then
      MODEL="${SELECTED_MODEL}" "${SCRIPT_DIR}/models-sync-omlx.sh" > /dev/null 2>&1 || true
    fi
    ok "Model: ${SELECTED_MODEL} (from .env)"
    return
  fi

  assert_interactive "MODEL_NAME" "local LLM model selection"

  info "Syncing LM Studio model catalog..."
  if ! "${SCRIPT_DIR}/models-sync-omlx.sh" >/dev/null 2>&1; then
    warn "Could not sync model catalog."
    warn "Make sure LM Studio has at least one MLX safetensors model downloaded."
    warn "After downloading a model, run: make model-select"
    return
  fi

  local catalog="${OMLX_HOME}/.runtime/lmstudio-models.json"
  if [[ ! -s "${catalog}" ]]; then
    warn "No MLX safetensors models found in LM Studio."
    warn "Download a model in LM Studio, then run: make model-select"
    return
  fi

  # Build menu from the catalog JSON.
  local -a model_ids=()
  local -a model_labels=()
  while IFS=$'\t' read -r mid mdisplay msize mtool; do
    model_ids+=("${mid}")
    local label="${mdisplay}  (${msize} GB"
    [[ "${mtool}" == "true" ]] && label+="  ✓ tool-use" || label+="  – no tool-use"
    label+=")"
    model_labels+=("${label}")
  done < <(jq -r '.[] | [.id, .displayName, ((.sizeBytes/1e9)|tostring|.[0:5]), (.trainedForToolUse|tostring)] | @tsv' "${catalog}")

  if [[ "${#model_ids[@]}" -eq 0 ]]; then
    warn "No models to display. Download an MLX model in LM Studio first."
    return
  fi

  local choice
  choice="$(choose_menu "Select the model for ${AGENT_RUNTIME}:" "${model_labels[@]}")"
  SELECTED_MODEL="${model_ids[$choice]}"

  if [[ "${DRY_RUN}" -eq 0 ]]; then
    MODEL="${SELECTED_MODEL}" "${SCRIPT_DIR}/models-sync-omlx.sh" > /dev/null 2>&1 || true
  fi
  ok "Model: ${SELECTED_MODEL}"
}

# ── Step 6: Optional local RAG ────────────────────────────────────────────────
configure_rag() {
  step "Local RAG"
  printf "  ${DIM}RAG indexes your documents folder and makes it searchable by the agent.${RESET}\n"
  printf "  ${DIM}It runs fully locally in Docker and can be rebuilt from source at any time.${RESET}\n"

  local rag_enabled
  rag_enabled="$(env_get RAG_ENABLED)"
  if [[ "${FORCE_PROMPTS}" -eq 0 && -n "${rag_enabled}" ]]; then
    if [[ "${rag_enabled}" == "1" || "${rag_enabled}" == "true" ]]; then
      RAG_SELECTED=1
      ok "RAG: enabled (from .env)"
    else
      RAG_SELECTED=0
      ok "RAG: disabled (from .env)"
    fi
  else
    local idx
    if [[ "${FORCE_PROMPTS}" -eq 0 ]]; then
      # Non-interactive default when not set in .env
      RAG_SELECTED=0
      env_put RAG_ENABLED "0"
      info "Non-interactive default: skipping RAG"
    else
      idx="$(choose_menu "Enable local RAG for this deployment?" \
        "Yes — index my documents and connect RAG to the agent" \
        "No  — skip RAG for now (can be enabled later with make rag-up)")"
      if [[ "${idx}" -eq 0 ]]; then
        RAG_SELECTED=1
        env_put RAG_ENABLED "1"
        env_put RAG_RUNTIME "docker"
        ok "RAG runtime: Docker"
      else
        RAG_SELECTED=0
        env_put RAG_ENABLED "0"
        info "RAG skipped — run 'make rag-up && make rag-index' to enable later"
      fi
    fi
  fi

  local rag_port
  rag_port="$(env_get RAG_PORT)"; rag_port="${rag_port:-8765}"

  if [[ "${RAG_SELECTED}" -eq 1 ]]; then
    if [[ "${DRY_RUN}" -eq 0 ]]; then
      [[ "${HAVE_DOCKER}" -eq 1 ]] || die "Docker Desktop is required for RAG. Start Docker Desktop first."
    fi

    # ── RAG source path (documents library) ──
    local rag_source_path
    rag_source_path="$(env_get RAG_SOURCE_PATH)"
    if [[ "${rag_source_path}" == '${OBSIDIAN_SHARED_PATH}' || "${rag_source_path}" == '${OBSIDIAN_SHARED_PATH:-}' ]]; then
      rag_source_path=""
    fi
    if [[ -z "${rag_source_path}" ]]; then
      rag_source_path="$(env_get OBSIDIAN_SHARED_PATH)"
    fi

    if [[ "${FORCE_PROMPTS}" -eq 1 || -z "${rag_source_path}" ]]; then
      assert_interactive "RAG_SOURCE_PATH" "path to documents / vault for RAG"
      printf "\n  ${BOLD}Documents folder for RAG${RESET}\n"
      printf "  ${DIM}This folder will be indexed and made searchable via rag-search.\n"
      printf "  Mounted read-only into the RAG container. PDFs, Word, spreadsheets,\n"
      printf "  Markdown and plain text are all supported.${RESET}\n"
      rag_source_path="$(prompt "Documents / vault path")"
    fi

    [[ -n "${rag_source_path}" ]] || die "RAG was selected but no source path was provided."
    rag_source_path="${rag_source_path/#\~/${HOME}}"
    if [[ "${DRY_RUN}" -eq 0 ]]; then
      [[ -d "${rag_source_path}" ]] || die "Path does not exist: ${rag_source_path}"
    fi
    env_put RAG_SOURCE_PATH "${rag_source_path}"
    ok "RAG source: ${rag_source_path}"

    # ── Obsidian workspace (agent read-write mount) ──
    local obsidian_path
    obsidian_path="$(env_get OBSIDIAN_SHARED_PATH)"

    if [[ "${FORCE_PROMPTS}" -eq 1 || -z "${obsidian_path}" ]]; then
      if [[ ! -t 0 || ! -t 1 ]]; then
        obsidian_path="${rag_source_path}"
      else
        printf "\n  ${BOLD}Agent workspace (Obsidian vault)${RESET}\n"
        printf "  ${DIM}This folder is mounted read-write inside the agent container at /mnt/obsidian.\n"
        printf "  The agent can read and create notes here directly.\n"
        printf "  Press Enter to use the same folder as the documents source.${RESET}\n"
        obsidian_path="$(prompt "Obsidian vault path (Enter = same as documents)" "")"
      fi
    fi

    if [[ -z "${obsidian_path}" ]]; then
      obsidian_path="${rag_source_path}"
      info "Agent workspace: same as RAG source (${obsidian_path})"
    else
      obsidian_path="${obsidian_path/#\~/${HOME}}"
      if [[ "${DRY_RUN}" -eq 0 ]]; then
        [[ -d "${obsidian_path}" ]] || die "Obsidian path does not exist: ${obsidian_path}"
      fi
      ok "Agent workspace: ${obsidian_path}"
    fi
    env_put OBSIDIAN_SHARED_PATH "${obsidian_path}"

    env_put RAG_PORT            "${rag_port}"
    env_put RAG_BASE_URL        "http://127.0.0.1:${rag_port}"
    env_put RAG_BASE_URL_GUEST  "http://rag-host.internal:${rag_port}"
    env_put RAG_BASE_URL_DOCKER "http://rag-host.internal:${rag_port}"
    env_put RAG_AUTO_INDEX "1"
    [[ -n "$(env_get RAG_WATCH_INTERVAL_SECONDS)" ]] || env_put RAG_WATCH_INTERVAL_SECONDS "20"
    [[ -n "$(env_get RAG_WATCH_DEBOUNCE_SECONDS)" ]] || env_put RAG_WATCH_DEBOUNCE_SECONDS "3"
  fi

  # ── Optional Services: Syncthing ──
  local syncthing_enabled
  syncthing_enabled="$(env_get SYNCTHING_ENABLED)"
  local run_syncthing=0

  if [[ "${FORCE_PROMPTS}" -eq 0 && -n "${syncthing_enabled}" ]]; then
    if [[ "${syncthing_enabled}" == "1" || "${syncthing_enabled}" == "true" ]]; then
      run_syncthing=1
      ok "Syncthing: enabled (from .env)"
    else
      run_syncthing=0
      ok "Syncthing: disabled (from .env)"
    fi
  else
    if [[ "${FORCE_PROMPTS}" -eq 0 ]]; then
      run_syncthing=0
      env_put SYNCTHING_ENABLED "0"
      info "Non-interactive default: Syncthing disabled"
    else
      printf "\n  ${BOLD}Optional Service: Syncthing File Synchronization${RESET}\n"
      local sync_opt
      sync_opt="$(choose_menu "Enable Syncthing for peer-to-peer file synchronization?" \
        "No  — skip Syncthing (default)" \
        "Yes — enable Syncthing and sync documents/Obsidian")"
      if [[ "${sync_opt}" -eq 1 ]]; then
        run_syncthing=1
        env_put SYNCTHING_ENABLED "1"
      else
        run_syncthing=0
        env_put SYNCTHING_ENABLED "0"
      fi
    fi
  fi

  if [[ "${run_syncthing}" -eq 1 ]]; then
    local sync_path
    sync_path="$(env_get SYNCTHING_SYNC_PATH)"
    if [[ -z "${sync_path}" ]]; then
      sync_path="${HOME}/hermes"
    fi
    env_put SYNCTHING_SYNC_PATH "${sync_path}"
    ok "Syncthing sync path: ${sync_path}"
  else
    ok "Syncthing disabled"
  fi

  # ── Optional Services: n8n ──
  local n8n_enabled
  n8n_enabled="$(env_get N8N_ENABLED)"
  local run_n8n=0

  if [[ "${FORCE_PROMPTS}" -eq 0 && -n "${n8n_enabled}" ]]; then
    if [[ "${n8n_enabled}" == "1" || "${n8n_enabled}" == "true" ]]; then
      run_n8n=1
      ok "n8n: enabled (from .env)"
    else
      run_n8n=0
      ok "n8n: disabled (from .env)"
    fi
  else
    if [[ "${FORCE_PROMPTS}" -eq 0 ]]; then
      run_n8n=0
      env_put N8N_ENABLED "0"
      info "Non-interactive default: n8n disabled"
    else
      printf "\n  ${BOLD}Optional Service: n8n Workflow Automation${RESET}\n"
      local n8n_opt
      n8n_opt="$(choose_menu "Enable n8n self-hosted workflow automation?" \
        "No  — skip n8n (default, recommended to save resources)" \
        "Yes — enable n8n and connect tools via MCP")"
      if [[ "${n8n_opt}" -eq 1 ]]; then
        run_n8n=1
        env_put N8N_ENABLED "1"
      else
        run_n8n=0
        env_put N8N_ENABLED "0"
      fi
    fi
  fi

  if [[ "${run_n8n}" -eq 1 ]]; then
    ok "n8n enabled (port: 5678)"

    # Check for n8n API Key
    local n8n_api_key
    n8n_api_key="$(env_get N8N_API_KEY)"

    if [[ -z "${n8n_api_key}" ]]; then
      if [[ ! -t 0 || ! -t 1 ]]; then
        warn "N8N_API_KEY is empty in .env. n8n tool integration is disabled."
      else
        printf "\n  ${BOLD}n8n API Key Setup${RESET}\n"
        printf "  ${DIM}n8n is enabled, but N8N_API_KEY is not configured in .env.\n"
        printf "  To connect the agent to n8n workflows via MCP, you must generate an API key:\n"
        printf "  1. Open n8n in your browser: http://127.0.0.1:5678 (after setup finishes)\n"
        printf "  2. Complete the owner account setup.\n"
        printf "  3. Go to Settings -> API Keys (or n8n API) and generate a key.\n"
        printf "  4. Paste the key here, or press Enter to skip and configure it later.${RESET}\n"
        n8n_api_key="$(prompt "n8n API Key" "")"
        if [[ -n "${n8n_api_key}" ]]; then
          env_put N8N_API_KEY "${n8n_api_key}"
          ok "n8n API Key configured"
        else
          warn "n8n API Key is empty. The agent's n8n MCP tool integration will remain disabled."
        fi
      fi
    else
      ok "n8n API Key: configured"
    fi
  else
    ok "n8n disabled"
  fi

  # Deployment execution (skipped in dry-run)
  if [[ "${RAG_SELECTED}" -eq 1 ]]; then
    if [[ "${FORCE_RESTART_RAG:-1}" -eq 1 ]]; then
      substep "Installing RAG dependencies..."
      if [[ "${DRY_RUN}" -eq 1 ]]; then
        info "[Dry-Run] Would run rag-control.sh install"
      else
        "${SCRIPT_DIR}/rag-control.sh" install
      fi

      substep "Starting RAG containers (Qdrant, Tika, Docling, API)..."
      if [[ "${DRY_RUN}" -eq 1 ]]; then
        info "[Dry-Run] Would run rag-control.sh start"
      else
        "${SCRIPT_DIR}/rag-control.sh" start
      fi

      substep "Starting background indexing..."
      local log_file="${OMLX_HOME}/.runtime/rag-docker/rag-index.log"
      mkdir -p "$(dirname "${log_file}")"
      if [[ "${DRY_RUN}" -eq 1 ]]; then
        info "[Dry-Run] Would start indexing in background"
      else
        nohup "${SCRIPT_DIR}/rag-control.sh" index > "${log_file}" 2>&1 &
      fi
      info "Indexing in background — check progress: make rag-index-status"
    else
      ok "Reusing already running RAG stack"
    fi

    substep "Verifying RAG API is reachable..."
    if [[ "${DRY_RUN}" -eq 1 ]]; then
      ok "[Dry-Run] Mocked RAG API online check"
    else
      local attempts=5 i api_online=0
      for ((i=1; i<=attempts; i++)); do
        if curl -fsS --max-time 2 "http://127.0.0.1:${rag_port}/health" > /dev/null 2>&1; then
          api_online=1
          break
        fi
        sleep 1
      done
      if [[ "${api_online}" -eq 1 ]]; then
        ok "RAG API online at http://127.0.0.1:${rag_port}"
      else
        warn "RAG API not yet responding — containers may still be starting. Check: make rag-status"
      fi
    fi
  fi
}

# ── Step 7: Start oMLX ────────────────────────────────────────────────────────
start_omlx() {
  step "Starting oMLX model server (background, launchd)"
  if [[ "${OMLX_RUNNING}" -eq 1 ]]; then
    info "oMLX already running — skipping"
    return
  fi
  if [[ "${DRY_RUN}" -eq 1 ]]; then
    info "[Dry-Run] Would start oMLX model server (background, launchd)"
    OMLX_RUNNING=1
    return
  fi
  "${SCRIPT_DIR}/model-start-omlx-bg.sh"
  OMLX_RUNNING=1
  ok "oMLX started"
}

# ── Step 8: Create sandbox ────────────────────────────────────────────────────
create_sandbox() {
  step "Starting selected agent stack"
  if [[ "${DRY_RUN}" -eq 1 ]]; then
    info "[Dry-Run] Would start selected agent stack via agent-control.sh"
    ok "Agent stack ready"
    return
  fi
  if ! AGENT_RUNTIME="${AGENT_RUNTIME}" SANDBOX_BACKEND="${BACKEND}" AGENT_CONFLICT_POLICY="${SETUP_AGENT_CONFLICT_POLICY}" "${SCRIPT_DIR}/agent-control.sh" start; then
    [[ -n "${PREVIOUS_AGENT_RUNTIME}" ]] && env_put AGENT_RUNTIME "${PREVIOUS_AGENT_RUNTIME}"
    [[ -n "${PREVIOUS_SANDBOX_BACKEND}" ]] && env_put SANDBOX_BACKEND "${PREVIOUS_SANDBOX_BACKEND}"
    die "Agent stack start failed; restored previous runtime/backend selection in .env."
  fi
  ok "Agent stack ready"
}

verify_rag_after_deploy() {
  [[ "${RAG_SELECTED}" -eq 1 ]] || return 0

  step "Verifying RAG inside sandbox"
  if [[ "${DRY_RUN}" -eq 1 ]]; then
    ok "[Dry-Run] Verified RAG inside sandbox reachable"
    return 0
  fi
  local rag_port
  rag_port="$(env_get RAG_PORT)"; rag_port="${rag_port:-8765}"
  local health_output=""
  local health_ok=0

  case "${BACKEND}" in
    docker)
      if [[ "${AGENT_RUNTIME}" == "openclaw" ]]; then
        local container
        container="$(env_get OPENCLAW_DOCKER_NAME)"; container="${container:-omlx-agent-openclaw-docker}"
        health_output="$(docker exec \
          "${container}" sh -lc \
          "curl -fsS --max-time 5 http://rag-host.internal:${rag_port}/health" 2>&1 || true)"
      else
        local container
        container="$(env_get DOCKER_NAME)"; container="${container:-omlx-agent-docker}"
        health_output="$(docker exec \
          "${container}" /bin/bash -lc \
          "curl -fsS --max-time 5 http://rag-host.internal:${rag_port}/health" 2>&1 || true)"
      fi
      ;;

  esac

  if printf '%s\n' "${health_output}" | grep -q '"ok":true'; then
    ok "RAG is reachable from ${AGENT_RUNTIME}/${BACKEND} (indexing may still be in progress)"
    info "Run 'make rag-logs' to follow indexing progress, 'make rag-search QUERY=...' when done."
  else
    printf '%s\n' "${health_output}" | sed -n '1,20p' | sed 's/^/     /'
    die "RAG API is not reachable from ${AGENT_RUNTIME}/${BACKEND} sandbox at http://rag-host.internal:${rag_port}/health"
  fi
}

# ── Step 9: Dashboard ─────────────────────────────────────────────────────────
DASHBOARD_URL=""

start_dashboard() {
  step "Dashboard / Control UI"
  local port
  if [[ "${AGENT_RUNTIME}" == "openclaw" ]]; then
    port="$(env_get OPENCLAW_CONTROL_PORT)"; port="${port:-18789}"
    local token
    token="$(env_get OPENCLAW_GATEWAY_TOKEN)"
    if [[ -n "${token}" ]]; then
      DASHBOARD_URL="http://127.0.0.1:${port}/#token=${token}"
    else
      DASHBOARD_URL="http://127.0.0.1:${port}"
    fi
  elif [[ "${BACKEND}" == "docker" ]]; then
    port="$(env_get DOCKER_DASHBOARD_PORT)"; port="${port:-9120}"
    DASHBOARD_URL="http://127.0.0.1:${port}"
  else
    port="$(env_get HERMES_DASHBOARD_PORT)"; port="${port:-9119}"
    DASHBOARD_URL="http://127.0.0.1:${port}"
  fi
  ok "UI: ${DASHBOARD_URL}"
}

# ── Step 10: Telegram gateway ─────────────────────────────────────────────────
TELEGRAM_STARTED=0

start_telegram() {
  local tg_token
  tg_token="$(env_get TELEGRAM_BOT_TOKEN)"
  [[ -n "${tg_token}" ]] || { info "Telegram not configured — skipping gateway"; return; }

  step "Telegram gateway"
  info "Telegram is managed by the selected agent stack."
  TELEGRAM_STARTED=1
  ok "Telegram configured"
}

# ── Step 11: Verify Telegram connectivity ─────────────────────────────────────
TELEGRAM_REACHABLE=0
TELEGRAM_BOT_USERNAME=""

verify_telegram() {
  local tg_token
  tg_token="$(env_get TELEGRAM_BOT_TOKEN)"
  [[ -n "${tg_token}" ]] || return 0

  info "Verifying Telegram bot connectivity..."
  if [[ "${DRY_RUN}" -eq 1 ]]; then
    ok "[Dry-Run] Telegram bot connectivity check mocked"
    TELEGRAM_REACHABLE=1
    return 0
  fi
  local response
  response="$(curl -fsS --max-time 6 \
    "https://api.telegram.org/bot${tg_token}/getMe" 2>/dev/null || true)"
  if [[ -n "${response}" ]] && printf '%s' "${response}" | jq -e '.ok == true' >/dev/null 2>&1; then
    TELEGRAM_REACHABLE=1
    TELEGRAM_BOT_USERNAME="$(printf '%s' "${response}" | jq -r '.result.username // ""')"
  fi
}

# ── Step 12: Final summary ────────────────────────────────────────────────────
print_summary() {
  local model; model="$(env_get MODEL_NAME)"; model="${model:-unknown}"
  local base_url; base_url="$(env_get OPENAI_BASE_URL)"; base_url="${base_url:-http://localhost:8000/v1}"
  local tg_uid; tg_uid="$(env_get TELEGRAM_USER_ID)"

  printf "\n"
  printf "${GREEN}${BOLD}"
  cat <<'DONE'
  ╔══════════════════════════════════════════════════════════════╗
  ║                                                              ║
  ║                 Setup complete!   🎉                         ║
  ║                                                              ║
  ╚══════════════════════════════════════════════════════════════╝
DONE
  printf "${RESET}\n"

  # ── Stack info ──
  printf "  ${BOLD}Runtime:${RESET}    %s\n"   "${AGENT_RUNTIME}"
  printf "  ${BOLD}Backend:${RESET}    %s\n"   "${BACKEND}"
  printf "  ${BOLD}Model:${RESET}      %s\n"   "${model}"
  printf "  ${BOLD}oMLX API:${RESET}   %s\n"   "${base_url}"
  if [[ "${BACKEND}" == "docker" ]]; then
    local agent_data_dir
    agent_data_dir="$(env_get AGENT_DATA_DIR)"
    if [[ -z "${agent_data_dir}" ]]; then
      agent_data_dir="${OMLX_HOME}/.runtime/agent"
    fi
    printf "  ${BOLD}Agent data:${RESET} %s\n" "${agent_data_dir}"
  fi
  if [[ "${RAG_SELECTED}" -eq 1 ]]; then
    printf "  ${BOLD}RAG:${RESET}        %s\n"   "enabled at http://127.0.0.1:$(env_get RAG_PORT)"
  else
    printf "  ${BOLD}RAG:${RESET}        %s\n"   "disabled for this setup"
  fi
  printf "\n"

  # ── Dashboard ──
  printf "  ${BOLD}${CYAN}Agent UI${RESET}\n"
  printf "  ${BOLD}  ➜  %s${RESET}\n" "${DASHBOARD_URL}"
  if [[ "${AGENT_RUNTIME}" == "openclaw" ]]; then
    local oc_token
    oc_token="$(env_get OPENCLAW_GATEWAY_TOKEN)"
    [[ -n "${oc_token}" ]] && printf "  ${DIM}     OPENCLAW_GATEWAY_TOKEN=%s${RESET}\n" "${oc_token}"
  fi
  printf "\n"

  # ── Telegram ──
  local tg_token; tg_token="$(env_get TELEGRAM_BOT_TOKEN)"
  if [[ -n "${tg_token}" ]]; then
    if [[ "${TELEGRAM_REACHABLE}" -eq 1 ]]; then
      if [[ -n "${TELEGRAM_BOT_USERNAME}" ]]; then
        printf "  ${GREEN}✓  Telegram bot ${BOLD}@%s${RESET}${GREEN} is active${RESET}\n" "${TELEGRAM_BOT_USERNAME}"
      else
        printf "  ${GREEN}✓  Telegram bot is reachable${RESET}\n"
      fi
      if [[ -n "${tg_uid}" ]]; then
        printf "  ${DIM}   Auto-approved for Telegram user ID: %s${RESET}\n" "${tg_uid}"
      elif [[ "${AGENT_RUNTIME}" == "openclaw" ]]; then
        printf "  ${DIM}   OpenClaw will use Telegram pairing/Control UI approval for first contact.${RESET}\n"
      else
        printf "  ${DIM}   To approve access: ${BOLD}./scripts/telegram-control.sh pairing${RESET}${DIM} then ${BOLD}CODE=<code> ./scripts/telegram-control.sh approve${RESET}\n"
      fi
    else
      printf "  ${YELLOW}⚠  Telegram bot token set but could not verify (check internet / token)${RESET}\n"
    fi
  else
    printf "  ${DIM}   Telegram not configured. Add TELEGRAM_BOT_TOKEN to .env and run:${RESET}\n"
    if [[ -n "${OMLX_CLI:-}" ]]; then
      printf "  ${DIM}   ${BOLD}omlx-agent start${RESET}\n"
    else
      printf "  ${DIM}   ${BOLD}make agent-start${RESET}\n"
    fi
  fi

  printf "\n"

  # ── Quick commands ──
  printf "  ${BOLD}Useful commands:${RESET}\n"
  if [[ -n "${OMLX_CLI:-}" ]]; then
    printf "  ${DIM}  omlx-agent open-dashboard ${RESET}# open Dashboard/Control UI in browser\n"
    printf "  ${DIM}  omlx-agent doctor         ${RESET}# full system health check\n"
    printf "  ${DIM}  omlx-agent model-select   ${RESET}# switch local model\n"
    printf "  ${DIM}  omlx-agent rag-search \"...\" ${RESET}# query local RAG\n"
    printf "  ${DIM}  omlx-agent rag-status     ${RESET}# RAG service status\n"
    printf "  ${DIM}  omlx-agent shell          ${RESET}# shell into the Docker agent\n"
    [[ -n "${tg_token}" ]] && printf "  ${DIM}  omlx-agent status         ${RESET}# check gateway status\n"
  else
    printf "  ${DIM}  make agent-open-dashboard ${RESET}# open Dashboard in browser\n"
    printf "  ${DIM}  make doctor               ${RESET}# full system health check\n"
    printf "  ${DIM}  make model-select         ${RESET}# switch local model\n"
    printf "  ${DIM}  make rag-search QUERY=\"...\" ${RESET}# query local RAG\n"
    printf "  ${DIM}  make rag-index-status     ${RESET}# show indexing progress\n"
    printf "  ${DIM}  make rag-status           ${RESET}# RAG service status\n"
    printf "  ${DIM}  make agent-shell          ${RESET}# shell into the Docker agent\n"
    [[ -n "${tg_token}" ]] && printf "  ${DIM}  make agent-status         ${RESET}# check gateway status\n"
  fi
  printf "\n"

  # ── Auto-open dashboard in browser ──
  if [[ "${DRY_RUN}" -eq 0 ]] && command -v open > /dev/null 2>&1; then
    open "${DASHBOARD_URL}"
  fi

  # ── RAG indexing status ──
  if [[ "${RAG_SELECTED:-0}" -eq 1 ]]; then
    printf "\n"
    printf "  ${BOLD}RAG indexing status:${RESET}\n"
    if [[ "${DRY_RUN}" -eq 1 ]]; then
      info "[Dry-Run] RAG indexing status mocked"
    else
      "${SCRIPT_DIR}/rag-control.sh" index-status 2>/dev/null | sed 's/^/  /' || true
    fi
    if [[ -n "${OMLX_CLI:-}" ]]; then
      printf "  ${DIM}  Run 'omlx-agent status' any time to refresh RAG / stack status.${RESET}\n"
    else
      printf "  ${DIM}  Run 'make rag-index-status' any time to refresh.${RESET}\n"
    fi
  fi
}

# ── Main ──────────────────────────────────────────────────────────────────────
main() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -f|--force)
        FORCE_PROMPTS=1
        shift
        ;;
      -d|--dry-run)
        DRY_RUN=1
        shift
        ;;
      *)
        die "Unknown argument: $1"
        ;;
    esac
  done

  print_banner
  ensure_env_file
  repair_corrupted_env
  PREVIOUS_AGENT_RUNTIME="$(env_get AGENT_RUNTIME)"
  PREVIOUS_SANDBOX_BACKEND="$(env_get SANDBOX_BACKEND)"
  detect_state
  run_bootstrap_if_needed
  preflight_agent_state
  choose_runtime          # Step 3: Hermes or OpenClaw — always Docker
  preflight_active_agent  # Step 4: conflict detection
  preflight_port_conflicts # Step 4b: check for port conflicts on host
  configure_credentials   # Step 5: API key + Telegram
  configure_model         # Step 6: model selection
  configure_rag           # Step 7: RAG yes/no + source path
  start_omlx              # Step 8: start model server
  create_sandbox          # Step 9: start agent container
  verify_rag_after_deploy # Step 10: check RAG reachability from container
  start_dashboard         # Step 11: SSH tunnel / container port
  start_telegram          # Step 12: Telegram gateway
  verify_telegram         # Step 13: test Telegram bot token
  print_summary           # Step 14: final summary
}

main "$@"
