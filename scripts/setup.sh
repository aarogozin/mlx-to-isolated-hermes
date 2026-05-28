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
ENV_FILE="${PROJECT_ROOT}/.env"
ENV_EXAMPLE="${PROJECT_ROOT}/.env.example"

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
    printf "${BOLD}  ?  %s${RESET} ${DIM}[%s]${RESET}: " "${text}" "${default}"
  else
    printf "${BOLD}  ?  %s${RESET}: " "${text}"
  fi
  read -r answer
  printf '%s' "${answer:-${default}}"
}

prompt_secret() {
  local text="$1"
  local answer
  printf "${BOLD}  ?  %s${RESET}: " "${text}"
  read -r -s answer
  echo
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

# ── Banner ────────────────────────────────────────────────────────────────────
print_banner() {
  clear
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
HAVE_MULTIPASS=0; HAVE_DOCKER=0
OMLX_RUNNING=0

detect_state() {
  step "Detecting installed tools"

  command -v brew >/dev/null 2>&1 \
    && { HAVE_BREW=1;    ok  "Homebrew"; } \
    || warn "Homebrew not found"

  { [[ -x "${HOME}/.lmstudio/bin/lms" ]] || command -v lms >/dev/null 2>&1; } \
    && { HAVE_LMS=1;    ok  "LM Studio CLI (lms)"; } \
    || warn "LM Studio CLI not found"

  command -v omlx >/dev/null 2>&1 \
    && { HAVE_OMLX=1;   ok  "oMLX"; } \
    || warn "oMLX not found"

  command -v multipass >/dev/null 2>&1 \
    && { HAVE_MULTIPASS=1; ok "Multipass"; } || true

  { command -v docker >/dev/null 2>&1 && docker version >/dev/null 2>&1; } \
    && { HAVE_DOCKER=1; ok  "Docker Desktop"; } || true

  [[ -f "${ENV_FILE}" ]] && ok ".env present" || warn ".env not found (will create)"

  local api_key base_url
  api_key="$(env_get OPENAI_API_KEY)"
  base_url="$(env_get OPENAI_BASE_URL)"
  base_url="${base_url:-http://localhost:8000/v1}"

  if [[ -n "${api_key}" ]] && \
     curl -fsS --max-time 2 \
       -H "Authorization: Bearer ${api_key}" \
       "${base_url}/models" >/dev/null 2>&1; then
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
  "${SCRIPT_DIR}/bootstrap-macos.sh"
  HAVE_BREW=1; HAVE_OMLX=1
}

# ── Step 3: Choose runtime and backend ────────────────────────────────────────
AGENT_RUNTIME=""
BACKEND=""
PREVIOUS_AGENT_RUNTIME=""
PREVIOUS_SANDBOX_BACKEND=""
SETUP_AGENT_CONFLICT_POLICY="prompt"

choose_runtime() {
  step "Choose agent runtime"
  printf "  ${DIM}Hermes and OpenClaw can run in Docker or Multipass. Only one stack may run at a time.${RESET}\n"

  local idx
  idx="$(choose_menu "Which agent runtime do you want?" \
    "Hermes      — supported" \
    "OpenClaw    — supported")"

  ensure_env_file
  case "${idx}" in
    0)
      AGENT_RUNTIME="hermes"
      env_put AGENT_RUNTIME "hermes"
      ok "Agent runtime: Hermes"
      ;;
    1)
      AGENT_RUNTIME="openclaw"
      env_put AGENT_RUNTIME "openclaw"
      ok "Agent runtime: OpenClaw"
      ;;
  esac
}

choose_backend() {
  step "Choose sandbox backend"
  printf "  ${DIM}This controls where the selected agent runs.\n"
  printf "  Inference (LLM) always stays on your Mac via oMLX.${RESET}\n"

  local -a options=()
  local -a keys=()

  # Multipass is always offered; install if missing.
  if [[ "${HAVE_MULTIPASS}" -eq 1 ]]; then
    options+=("Multipass VM     — Ubuntu 24.04 ARM64  (recommended)")
  else
    options+=("Multipass VM     — Ubuntu 24.04 ARM64  ✦ will be installed")
  fi
  keys+=("multipass")

  if [[ "${HAVE_DOCKER}" -eq 1 ]]; then
    options+=("Docker           — official agent image, daemon-friendly")
  else
    options+=("Docker           — official agent image  ✦ Docker Desktop not running")
  fi
  keys+=("docker")

  local idx
  idx="$(choose_menu "Which sandbox backend do you want?" "${options[@]}")"
  BACKEND="${keys[$idx]}"

  ensure_env_file

  case "${BACKEND}" in
    multipass)
      env_put SANDBOX_BACKEND multipass
      ok "Backend: Multipass VM"
      ;;
    docker)
      env_put SANDBOX_BACKEND docker
      ok "Backend: Docker"
      ;;
  esac
}

runtime_target() {
  case "${BACKEND}" in
    docker) printf 'docker\n' ;;
    multipass|vm) printf 'vm\n' ;;
    *) printf '%s\n' "${BACKEND}" ;;
  esac
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
  done < <("${SCRIPT_DIR}/agent-control.sh" active || true)

  if [[ "${#active_records[@]}" -eq 0 ]]; then
    ok "No active agent stack detected"
    return
  fi

  printf "  ${DIM}Detected active agent stack(s):${RESET}\n"
  local same_active=0
  local other_active=0
  local mode
  for record in "${active_records[@]}"; do
    mode="${record%%|*}"
    printf "    ${CYAN}- %s${RESET}\n" "$(agent_mode_label "${record}")"
    if [[ "${mode}" == "${requested_mode}" ]]; then
      same_active=1
    else
      other_active=1
    fi
  done
  printf "  ${DIM}Requested stack: ${requested_mode}${RESET}\n"

  local idx
  if [[ "${other_active}" -eq 0 && "${same_active}" -eq 1 ]]; then
    idx="$(choose_menu "The requested stack is already running. What should setup do?" \
      "Reuse it and continue setup" \
      "Pause/restart it before continuing" \
      "Full clean-all reset before continuing" \
      "Abort setup")"
    case "${idx}" in
      0)
        SETUP_AGENT_CONFLICT_POLICY="prompt"
        ok "Will reuse active stack"
        ;;
      1)
        pause_detected_mode "${requested_mode}"
        SETUP_AGENT_CONFLICT_POLICY="prompt"
        ok "Active stack paused"
        ;;
      2)
        FORCE=1 "${SCRIPT_DIR}/clean-all.sh"
        SETUP_AGENT_CONFLICT_POLICY="prompt"
        ok "Sandbox reset complete"
        ;;
      3)
        abort_setup "Setup aborted by user."
        ;;
    esac
    return
  fi

  idx="$(choose_menu "Another stack is active. What should setup do?" \
    "Pause active stack(s) and continue" \
    "Full clean-all reset before continuing" \
    "Continue anyway without stopping anything" \
    "Abort setup")"
  case "${idx}" in
    0)
      for record in "${active_records[@]}"; do
        mode="${record%%|*}"
        [[ "${mode}" == "${requested_mode}" ]] && continue
        pause_detected_mode "${mode}"
      done
      SETUP_AGENT_CONFLICT_POLICY="prompt"
      ok "Conflicting stack(s) paused"
      ;;
    1)
      FORCE=1 "${SCRIPT_DIR}/clean-all.sh"
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
    printf "  ${DIM}Telegram lets you chat with the agent from your phone. Press Enter to skip.${RESET}\n"
    tg_token="$(prompt "Telegram bot token (from @BotFather)")"
    if [[ -n "${tg_token}" ]]; then
      env_put TELEGRAM_BOT_TOKEN "${tg_token}"
      ok "Telegram bot token saved"
    else
      info "Telegram skipped — you can add TELEGRAM_BOT_TOKEN to .env later"
    fi
  else
    ok "Telegram bot token already configured"
  fi

  if [[ -n "$(env_get TELEGRAM_BOT_TOKEN)" ]]; then
    local tg_uid
    tg_uid="$(env_get TELEGRAM_USER_ID)"
    if [[ -z "${tg_uid}" ]]; then
      printf "  ${DIM}Your numeric Telegram user ID (from @userinfobot) enables auto-approve. Optional.${RESET}\n"
      tg_uid="$(prompt "Your Telegram user ID" "")"
      [[ -n "${tg_uid}" ]] && env_put TELEGRAM_USER_ID "${tg_uid}" && ok "Telegram user ID: ${tg_uid}"
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

  info "Syncing LM Studio model catalog..."
  if ! "${SCRIPT_DIR}/models-sync-omlx.sh" >/dev/null 2>&1; then
    warn "Could not sync model catalog."
    warn "Make sure LM Studio has at least one MLX safetensors model downloaded."
    warn "After downloading a model, run: make model-select"
    return
  fi

  local catalog="${PROJECT_ROOT}/.runtime/lmstudio-models.json"
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

  MODEL="${SELECTED_MODEL}" "${SCRIPT_DIR}/models-sync-omlx.sh" >/dev/null 2>&1 || true
  ok "Model: ${SELECTED_MODEL}"
}

# ── Step 6: Optional local RAG ────────────────────────────────────────────────
configure_rag() {
  step "Local RAG"
  printf "  ${DIM}RAG indexes your Obsidian/documents folder and exposes it to ${AGENT_RUNTIME} through rag-search.${RESET}\n"
  printf "  ${DIM}It is optional, local-only, and can be rebuilt from source notes at any time.${RESET}\n"

  local idx
  idx="$(choose_menu "Do you want to connect and verify RAG for this deployment?" \
    "Yes — install/index/start RAG and verify it after agent deploy" \
    "Skip for now — keep RAG disabled for this setup")"

  if [[ "${idx}" -ne 0 ]]; then
    RAG_SELECTED=0
    env_put RAG_ENABLED "0"
    info "RAG skipped for this setup"
    return
  fi

  RAG_SELECTED=1
  env_put RAG_ENABLED "1"

  local rag_runtime install_rag_host
  rag_runtime="$(env_get RAG_RUNTIME)"
  rag_runtime="${rag_runtime:-docker}"
  install_rag_host="$(env_get INSTALL_RAG_HOST)"
  install_rag_host="${install_rag_host:-0}"
  if [[ "${rag_runtime}" != "host" || "${install_rag_host}" != "1" ]]; then
    rag_runtime="docker"
  fi
  if [[ "${rag_runtime}" == "docker" && "${HAVE_DOCKER}" -ne 1 ]]; then
    die "Docker Desktop is required for Docker-first RAG. Start Docker Desktop or set RAG_RUNTIME=host and INSTALL_RAG_HOST=1 for the legacy host path."
  fi
  env_put RAG_RUNTIME "${rag_runtime}"
  ok "RAG runtime: ${rag_runtime}"

  local source_path
  source_path="$(env_get RAG_SOURCE_PATH)"
  if [[ -z "${source_path}" || "${source_path}" == '${OBSIDIAN_SHARED_PATH}' || "${source_path}" == '${OBSIDIAN_SHARED_PATH:-}' ]]; then
    source_path="$(env_get OBSIDIAN_SHARED_PATH)"
  fi

  if [[ -z "${source_path}" ]]; then
    printf "  ${DIM}Point this at your Obsidian vault or another local notes/documents folder.${RESET}\n"
    source_path="$(prompt "RAG source path")"
  fi

  [[ -n "${source_path}" ]] || die "RAG was selected but no source path was provided."
  source_path="${source_path/#\~/${HOME}}"
  [[ -d "${source_path}" ]] || die "RAG source path does not exist: ${source_path}"

  env_put OBSIDIAN_SHARED_PATH "${source_path}"
  env_put RAG_SOURCE_PATH "${source_path}"
  local rag_port
  rag_port="$(env_get RAG_PORT)"; rag_port="${rag_port:-8765}"
  env_put RAG_PORT "${rag_port}"
  env_put RAG_BASE_URL "http://127.0.0.1:${rag_port}"
  env_put RAG_BASE_URL_GUEST "http://rag-host.internal:${rag_port}"
  env_put RAG_BASE_URL_DOCKER "http://rag-host.internal:${rag_port}"
  env_put RAG_AUTO_INDEX "1"
  [[ -n "$(env_get RAG_WATCH_INTERVAL_SECONDS)" ]] || env_put RAG_WATCH_INTERVAL_SECONDS "20"
  [[ -n "$(env_get RAG_WATCH_DEBOUNCE_SECONDS)" ]] || env_put RAG_WATCH_DEBOUNCE_SECONDS "3"
  env_put MULTIPASS_SHARED_MODE "mount"

  RAG_SMOKE_QUERY="$(env_get RAG_SMOKE_QUERY)"
  RAG_SMOKE_QUERY="${RAG_SMOKE_QUERY:-${SELECTED_MODEL:-local knowledge}}"
  info "RAG smoke-test query: ${RAG_SMOKE_QUERY}"

  substep "Installing RAG dependencies..."
  "${SCRIPT_DIR}/rag-control.sh" install

  if [[ "${rag_runtime}" == "docker" ]]; then
    substep "Starting Dockerized RAG service..."
  else
    substep "Starting host RAG service and auto-index watcher..."
  fi
  "${SCRIPT_DIR}/rag-control.sh" start

  substep "Indexing local knowledge source (starting in background)..."
  local log_file=".runtime/rag/rag-index.log"
  if [[ "${rag_runtime}" == "docker" ]]; then
    log_file=".runtime/rag-docker/rag-index.log"
  fi
  mkdir -p "$(dirname "${log_file}")"
  nohup "${SCRIPT_DIR}/rag-control.sh" index > "${log_file}" 2>&1 &
  info "Indexing is running asynchronously. Check progress: tail -f ${log_file} or make rag-logs"

  substep "Verifying RAG search API..."
  local attempts=5
  local i
  local api_online=0
  for ((i=1; i<=attempts; i++)); do
    if "${SCRIPT_DIR}/rag-control.sh" search "${RAG_SMOKE_QUERY}" >/dev/null 2>&1; then
      api_online=1
      break
    fi
    sleep 1
  done
  if [[ "${api_online}" -eq 1 ]]; then
    ok "RAG search API is online"
  else
    warn "RAG search API did not respond within ${attempts}s, but indexing is running in background."
  fi
}

# ── Step 7: Start oMLX ────────────────────────────────────────────────────────
start_omlx() {
  step "Starting oMLX model server (background, launchd)"
  if [[ "${OMLX_RUNNING}" -eq 1 ]]; then
    info "oMLX already running — skipping"
    return
  fi
  "${SCRIPT_DIR}/model-start-omlx-bg.sh"
  OMLX_RUNNING=1
  ok "oMLX started"
}

# ── Step 8: Create sandbox ────────────────────────────────────────────────────
create_sandbox() {
  step "Starting selected agent stack"
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
    multipass)
      local vm_name
      local vm_user
      if [[ "${AGENT_RUNTIME}" == "openclaw" ]]; then
        vm_name="$(env_get OPENCLAW_VM_NAME)"; vm_name="${vm_name:-omlx-openclaw-ubuntu}"
      else
        vm_name="$(env_get HERMES_VM_NAME)"; vm_name="${vm_name:-$(env_get VM_NAME)}"; vm_name="${vm_name:-omlx-agent-ubuntu}"
      fi
      vm_user="$(env_get VM_SSH_USER)"; vm_user="${vm_user:-agent}"
      health_output="$(multipass exec "${vm_name}" -- \
        curl -fsS --max-time 5 "http://rag-host.internal:${rag_port}/health" 2>&1 || true)"
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
      agent_data_dir="${SCRIPT_DIR}/../.runtime/agent"
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
    printf "  ${DIM}   ${BOLD}make agent-start${RESET}\n"
  fi

  printf "\n"

  # ── Quick commands ──
  printf "  ${BOLD}Useful commands:${RESET}\n"
  printf "  ${DIM}  make agent-open-dashboard ${RESET}# open Dashboard in browser\n"
  printf "  ${DIM}  make doctor               ${RESET}# full system health check\n"
  printf "  ${DIM}  make model-select         ${RESET}# switch local model\n"
  printf "  ${DIM}  make rag-search QUERY=\"...\" ${RESET}# query local RAG\n"
  printf "  ${DIM}  make rag-index-status     ${RESET}# show indexing progress\n"
  printf "  ${DIM}  make rag-status           ${RESET}# RAG service status\n"
  if [[ "${BACKEND}" != "docker" ]]; then
    printf "  ${DIM}  make vm-ssh               ${RESET}# SSH into the agent VM\n"
    printf "  ${DIM}  make vm-status            ${RESET}# show VM status and IP\n"
  else
    printf "  ${DIM}  make agent-shell          ${RESET}# shell into the Docker agent\n"
  fi
  [[ -n "${tg_token}" ]] && printf "  ${DIM}  make agent-status         ${RESET}# check gateway status\n"
  printf "\n"

  # ── Auto-open dashboard in browser ──
  if command -v open > /dev/null 2>&1; then
    open "${DASHBOARD_URL}"
  fi

  # ── RAG indexing status ──
  if [[ "${RAG_SELECTED:-0}" -eq 1 ]]; then
    printf "\n"
    printf "  ${BOLD}RAG indexing status:${RESET}\n"
    "${SCRIPT_DIR}/rag-control.sh" index-status 2>/dev/null | sed 's/^/  /' || true
    printf "  ${DIM}  Run 'make rag-index-status' any time to refresh.${RESET}\n"
  fi
}

# ── Main ──────────────────────────────────────────────────────────────────────
main() {
  if [[ ! -t 0 || ! -t 1 ]]; then
    die "setup.sh must be run in an interactive terminal."
  fi

  print_banner
  ensure_env_file
  PREVIOUS_AGENT_RUNTIME="$(env_get AGENT_RUNTIME)"
  PREVIOUS_SANDBOX_BACKEND="$(env_get SANDBOX_BACKEND)"
  detect_state
  run_bootstrap_if_needed
  choose_runtime
  choose_backend
  preflight_active_agent
  configure_credentials
  configure_model
  configure_rag
  start_omlx
  create_sandbox
  verify_rag_after_deploy
  start_dashboard
  start_telegram
  verify_telegram
  print_summary
}

main "$@"
