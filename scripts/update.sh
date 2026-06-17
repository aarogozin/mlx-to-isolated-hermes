#!/usr/bin/env bash
# scripts/update.sh — Update all oMLX stack components.
#
# Usage:
#   ./scripts/update.sh [--dry-run] [--skip-git] [--skip-omlx] [--skip-agent] [--skip-rag] [--skip-smoke]
#
# Updates in order:
#   1. Git repo self-update   (git pull --ff-only, non-fatal)
#   2. oMLX                   (brew upgrade, if installed)
#   3. Agent                  (Hermes or OpenClaw docker pull + recreate)
#   4. RAG Docker stack       (compose pull for all services + restart)
#
# Each step is independent — a failure in one step does not abort the rest.
# Use --dry-run to preview what would happen without changing anything.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
OMLX_HOME="${OMLX_HOME:-${PROJECT_ROOT}}"
ENV_FILE="${OMLX_HOME}/.env"

# ── Colour helpers ─────────────────────────────────────────────────────────────
if [[ -t 1 && "${NO_COLOR:-}" == "" ]]; then
  BOLD="\033[1m"; RESET="\033[0m"
  GREEN="\033[0;32m"; YELLOW="\033[1;33m"; RED="\033[0;31m"; CYAN="\033[0;36m"; DIM="\033[2m"
else
  BOLD=""; RESET=""; GREEN=""; YELLOW=""; RED=""; CYAN=""; DIM=""
fi

step()   { printf "\n${BOLD}${CYAN}▶  %s${RESET}\n" "$*"; }
ok()     { printf "   ${GREEN}✓${RESET}  %s\n" "$*"; }
warn()   { printf "   ${YELLOW}⚠${RESET}  %s\n" "$*"; }
info()   { printf "   ${DIM}·${RESET}  %s\n" "$*"; }
fail()   { printf "   ${RED}✗${RESET}  %s\n" "$*"; }
dry()    { printf "   ${DIM}[dry-run]${RESET} %s\n" "$*"; }

# ── Parse flags ────────────────────────────────────────────────────────────────
DRY_RUN=0
SKIP_GIT=0
SKIP_OMLX=0
SKIP_AGENT=0
SKIP_RAG=0
SKIP_SMOKE="${SKIP_UPDATE_SMOKE:-0}"

for arg in "$@"; do
  case "${arg}" in
    --dry-run)    DRY_RUN=1 ;;
    --skip-git)   SKIP_GIT=1 ;;
    --skip-omlx)  SKIP_OMLX=1 ;;
    --skip-agent) SKIP_AGENT=1 ;;
    --skip-rag)   SKIP_RAG=1 ;;
    --skip-smoke) SKIP_SMOKE=1 ;;
    -h|--help)
      grep '^#' "${BASH_SOURCE[0]}" | head -20 | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *)
      printf "Unknown flag: %s\n" "${arg}" >&2
      printf "Usage: %s [--dry-run] [--skip-git] [--skip-omlx] [--skip-agent] [--skip-rag] [--skip-smoke]\n" "$0" >&2
      exit 2
      ;;
  esac
done

# ── Load .env ─────────────────────────────────────────────────────────────────
if [[ -f "${ENV_FILE}" ]]; then
  set -a
  # shellcheck disable=SC1090
  source "${ENV_FILE}"
  set +a
fi

# Resolve runtime settings
AGENT_RUNTIME="${AGENT_RUNTIME:-hermes}"
RAG_ENABLED="${RAG_ENABLED:-1}"
RAG_RUNTIME="${RAG_RUNTIME:-docker}"
N8N_ENABLED="${N8N_ENABLED:-0}"
SYNCTHING_ENABLED="${SYNCTHING_ENABLED:-0}"
MODEL_BACKEND="${MODEL_BACKEND:-omlx}"

# ── Result tracking ────────────────────────────────────────────────────────────
declare -a RESULTS_OK=()
declare -a RESULTS_WARN=()
declare -a RESULTS_FAIL=()
declare -a RESULTS_SKIP=()

result_ok()   { RESULTS_OK+=("$*"); }
result_warn() { RESULTS_WARN+=("$*"); }
result_fail() { RESULTS_FAIL+=("$*"); }
result_skip() { RESULTS_SKIP+=("$*"); }

# ── Helper: image digest before/after ─────────────────────────────────────────
image_digest() {
  docker image inspect "$1" --format '{{index .RepoDigests 0}}' 2>/dev/null \
    | grep -o 'sha256:[a-f0-9]\{12\}' || echo "(local)"
}

# ── Banner ─────────────────────────────────────────────────────────────────────
printf "${BOLD}"
printf "\n  ╔══════════════════════════════════════╗\n"
printf   "  ║   oMLX Stack Updater  🔄             ║\n"
printf   "  ╚══════════════════════════════════════╝${RESET}\n"
if [[ "${DRY_RUN}" -eq 1 ]]; then
  printf "\n  ${YELLOW}${BOLD}DRY-RUN MODE — no changes will be made${RESET}\n"
fi

# ─────────────────────────────────────────────────────────────────────────────
# STEP 1: Git self-update
# ─────────────────────────────────────────────────────────────────────────────
if [[ "${SKIP_GIT}" -eq 1 ]]; then
  result_skip "Git repo (skipped)"
else
  step "Git: pulling latest commits"
  info "Project root: ${PROJECT_ROOT}"

  if [[ "${DRY_RUN}" -eq 1 ]]; then
    dry "git -C '${PROJECT_ROOT}' pull --ff-only"
    result_skip "Git repo (dry-run)"
  else
    git_before="$(git -C "${PROJECT_ROOT}" rev-parse --short HEAD 2>/dev/null || echo "?")"
    if git -C "${PROJECT_ROOT}" pull --ff-only 2>&1 | while IFS= read -r line; do info "${line}"; done; then
      git_after="$(git -C "${PROJECT_ROOT}" rev-parse --short HEAD 2>/dev/null || echo "?")"
      if [[ "${git_before}" == "${git_after}" ]]; then
        ok "Already up to date (${git_after})"
        result_ok "Git repo — already current (${git_after})"
      else
        ok "Updated: ${git_before} → ${git_after}"
        result_ok "Git repo — updated ${git_before} → ${git_after}"
      fi
    else
      warn "git pull --ff-only failed (local changes or diverged branch). Continuing..."
      result_warn "Git repo — pull failed (local changes?)"
    fi
  fi
fi

# ─────────────────────────────────────────────────────────────────────────────
# STEP 2: oMLX (Homebrew binary) — only if MODEL_BACKEND=omlx
# ─────────────────────────────────────────────────────────────────────────────
if [[ "${SKIP_OMLX}" -eq 1 ]]; then
  result_skip "oMLX (skipped)"
elif [[ "${MODEL_BACKEND}" != "omlx" ]]; then
  info "Skipping oMLX — MODEL_BACKEND is '${MODEL_BACKEND}' (not omlx)"
  result_skip "oMLX (MODEL_BACKEND=${MODEL_BACKEND})"
elif ! command -v brew > /dev/null 2>&1; then
  warn "Homebrew not found — skipping oMLX update"
  result_skip "oMLX (brew not found)"
else
  step "oMLX: upgrading via Homebrew"
  if [[ "${DRY_RUN}" -eq 1 ]]; then
    dry "${SCRIPT_DIR}/omlx-update.sh"
    result_skip "oMLX (dry-run)"
  else
    if "${SCRIPT_DIR}/omlx-update.sh" 2>&1 | while IFS= read -r line; do info "${line}"; done; then
      ok "oMLX upgrade complete"
      result_ok "oMLX — upgraded"
    else
      warn "oMLX upgrade failed (may already be latest)"
      result_warn "oMLX — upgrade failed or already current"
    fi
  fi
fi

# ─────────────────────────────────────────────────────────────────────────────
# STEP 3: Agent container (Hermes or OpenClaw)
# ─────────────────────────────────────────────────────────────────────────────
if [[ "${SKIP_AGENT}" -eq 1 ]]; then
  result_skip "Agent (skipped)"
else
  step "Agent (${AGENT_RUNTIME}): pulling latest image"

  case "${AGENT_RUNTIME}" in
    hermes)
      agent_image="${HERMES_IMAGE:-nousresearch/hermes-agent:latest}"
      agent_container="${DOCKER_NAME:-omlx-agent-docker}"
      ;;
    openclaw)
      agent_image="${OPENCLAW_IMAGE:-ghcr.io/openclaw/openclaw:latest}"
      agent_container="${OPENCLAW_DOCKER_NAME:-omlx-agent-openclaw-docker}"
      ;;
    *)
      warn "Unknown AGENT_RUNTIME='${AGENT_RUNTIME}' — skipping agent update"
      result_skip "Agent (unknown runtime: ${AGENT_RUNTIME})"
      agent_image=""
      ;;
  esac

  if [[ -n "${agent_image:-}" ]]; then
    info "Image: ${agent_image}"
    info "Container: ${agent_container}"

    if [[ "${DRY_RUN}" -eq 1 ]]; then
      dry "docker pull ${agent_image}"
      dry "${SCRIPT_DIR}/agent-control.sh update"
      result_skip "Agent / ${AGENT_RUNTIME} (dry-run)"
    else
      digest_before="$(image_digest "${agent_image}")"
      if "${SCRIPT_DIR}/agent-control.sh" update 2>&1 | while IFS= read -r line; do info "${line}"; done; then
        digest_after="$(image_digest "${agent_image}")"
        if [[ "${digest_before}" == "${digest_after}" ]]; then
          ok "Image unchanged (${digest_after})"
          result_ok "Agent / ${AGENT_RUNTIME} — already current"
        else
          ok "Updated: ${digest_before} → ${digest_after}"
          result_ok "Agent / ${AGENT_RUNTIME} — image updated + container recreated"
        fi
      else
        fail "Agent update failed"
        result_fail "Agent / ${AGENT_RUNTIME} — update failed"
      fi
    fi
  fi
fi

# ─────────────────────────────────────────────────────────────────────────────
# STEP 4: RAG Docker stack
# ─────────────────────────────────────────────────────────────────────────────
if [[ "${SKIP_RAG}" -eq 1 ]]; then
  result_skip "RAG stack (skipped)"
elif [[ "${RAG_ENABLED}" != "1" && "${RAG_ENABLED}" != "true" && "${RAG_ENABLED}" != "yes" ]]; then
  info "Skipping RAG stack — RAG_ENABLED is off"
  result_skip "RAG stack (RAG_ENABLED=${RAG_ENABLED})"
elif [[ "${RAG_RUNTIME}" != "docker" ]]; then
  info "Skipping Docker RAG pull — RAG_RUNTIME='${RAG_RUNTIME}' (not docker)"
  result_skip "RAG stack (RAG_RUNTIME=${RAG_RUNTIME})"
elif ! command -v docker > /dev/null 2>&1; then
  warn "Docker not found — skipping RAG update"
  result_skip "RAG stack (docker not found)"
else
  step "RAG stack: pulling latest Docker images"

  compose_file="${PROJECT_ROOT}/docker-compose.rag.yml"
  if [[ ! -f "${compose_file}" ]]; then
    warn "docker-compose.rag.yml not found — skipping RAG update"
    result_skip "RAG stack (compose file missing)"
  else
    # Show which images we'll pull
    rag_images=(
      "${RAG_API_IMAGE:-python:3.12-slim}"
      "${RAG_QDRANT_IMAGE:-qdrant/qdrant:latest}"
      "${RAG_TIKA_IMAGE:-apache/tika:latest-full}"
      "${RAG_DOCLING_IMAGE:-quay.io/docling-project/docling-serve:latest}"
    )
    if [[ "${RAG_DOCKER_EMBEDDING_BACKEND:-hash}" == "tei" ]]; then
      rag_images+=("${RAG_TEI_IMAGE:-ghcr.io/huggingface/text-embeddings-inference:cpu-latest}")
    fi
    # Optional profiles
    [[ "${N8N_ENABLED:-0}" == "1" ]] && rag_images+=("n8nio/n8n:latest")
    [[ "${SYNCTHING_ENABLED:-0}" == "1" ]] && rag_images+=("syncthing/syncthing:latest")
    [[ "${FIRECRAWL_LOCAL_ENABLED:-0}" == "1" ]] && rag_images+=("ghcr.io/firecrawl/firecrawl:latest" "ghcr.io/firecrawl/playwright-service:latest" "redis:alpine" "rabbitmq:3-management" "ghcr.io/firecrawl/nuq-postgres:latest")

    for img in "${rag_images[@]}"; do
      info "Will pull: ${img}"
    done

    # Check if RAG stack is currently running
    rag_was_running=0
    if docker container inspect "${RAG_DOCKER_NAME:-mlx-isolated-rag}" > /dev/null 2>&1 \
       && [[ "$(docker inspect -f '{{.State.Running}}' "${RAG_DOCKER_NAME:-mlx-isolated-rag}" 2>/dev/null)" == "true" ]]; then
      rag_was_running=1
      info "RAG stack is currently running — will restart after pull"
    fi

    if [[ "${DRY_RUN}" -eq 1 ]]; then
      dry "RAG_DOCKER_PULL_POLICY=always ${SCRIPT_DIR}/rag-control.sh install"
      [[ "${rag_was_running}" -eq 1 ]] && dry "${SCRIPT_DIR}/rag-control.sh start"
      result_skip "RAG stack (dry-run)"
    else
      rag_failed=0
      if RAG_DOCKER_PULL_POLICY=always "${SCRIPT_DIR}/rag-control.sh" install 2>&1 \
         | while IFS= read -r line; do info "${line}"; done; then
        ok "RAG images pulled"
      else
        fail "RAG image pull failed"
        rag_failed=1
      fi

      if [[ "${rag_was_running}" -eq 1 ]]; then
        info "Restarting RAG stack..."
        if "${SCRIPT_DIR}/rag-control.sh" start 2>&1 | while IFS= read -r line; do info "${line}"; done; then
          ok "RAG stack restarted"
        else
          warn "RAG stack restart failed — try: make rag-up"
          rag_failed=1
        fi
      fi

      if [[ "${rag_failed}" -eq 0 ]]; then
        result_ok "RAG stack — images updated${rag_was_running:+ and restarted}"
      else
        result_fail "RAG stack — partial failure (see above)"
      fi
    fi
  fi
fi

# ─────────────────────────────────────────────────────────────────────────────
# STEP 5: Post-update smoke test
# ─────────────────────────────────────────────────────────────────────────────
if [[ "${DRY_RUN}" -eq 1 ]]; then
  result_skip "Post-update smoke (dry-run)"
elif [[ "${SKIP_SMOKE}" == "1" || "${SKIP_SMOKE}" == "true" ]]; then
  result_skip "Post-update smoke (skipped)"
elif [[ "${#RESULTS_FAIL[@]}" -gt 0 ]]; then
  result_skip "Post-update smoke (skipped because update had failures)"
else
  step "Post-update smoke"
  if "${SCRIPT_DIR}/stack-smoke.sh" 2>&1 | while IFS= read -r line; do info "${line}"; done; then
    ok "Post-update smoke passed"
    result_ok "Post-update smoke — passed"
  else
    fail "Post-update smoke failed"
    result_fail "Post-update smoke — failed"
  fi
fi

# ─────────────────────────────────────────────────────────────────────────────
# STEP 6: LM Studio note (cannot be automated — macOS GUI app)
# ─────────────────────────────────────────────────────────────────────────────
if [[ "${MODEL_BACKEND}" == "lmstudio" ]]; then
  step "LM Studio"
  warn "LM Studio is a macOS app — update it manually via the app's built-in updater"
  info "Or download the latest version from: https://lmstudio.ai"
  result_warn "LM Studio — manual update required"
fi

# ─────────────────────────────────────────────────────────────────────────────
# SUMMARY
# ─────────────────────────────────────────────────────────────────────────────
printf "\n${BOLD}${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}\n"
printf "${BOLD}  Update Summary${RESET}\n"
printf "${BOLD}${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}\n"

for item in "${RESULTS_OK[@]+"${RESULTS_OK[@]}"}"; do
  printf "  ${GREEN}✓${RESET}  %s\n" "${item}"
done
for item in "${RESULTS_WARN[@]+"${RESULTS_WARN[@]}"}"; do
  printf "  ${YELLOW}⚠${RESET}  %s\n" "${item}"
done
for item in "${RESULTS_FAIL[@]+"${RESULTS_FAIL[@]}"}"; do
  printf "  ${RED}✗${RESET}  %s\n" "${item}"
done
for item in "${RESULTS_SKIP[@]+"${RESULTS_SKIP[@]}"}"; do
  printf "  ${DIM}–${RESET}  %s\n" "${item}"
done

if [[ "${DRY_RUN}" -eq 1 ]]; then
  printf "\n  ${YELLOW}${BOLD}Dry-run complete — no changes were made.${RESET}\n"
  printf "  Run without --dry-run to apply.\n\n"
elif [[ "${#RESULTS_FAIL[@]}" -gt 0 ]]; then
  printf "\n  ${RED}${BOLD}Some components failed to update.${RESET} Check output above.\n\n"
  exit 1
else
  printf "\n  ${GREEN}${BOLD}Stack update complete!${RESET}\n\n"
fi
