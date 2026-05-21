#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
ENV_FILE="${PROJECT_ROOT}/.env"
MODEL_REQUIRED=0

if [[ "${1:-}" == "--model-required" ]]; then
  MODEL_REQUIRED=1
fi

failures=0
warnings=0

pass() {
  printf 'ok   %s\n' "$*"
}

warn() {
  warnings=$((warnings + 1))
  printf 'warn %s\n' "$*"
}

fail() {
  failures=$((failures + 1))
  printf 'fail %s\n' "$*"
}

check_command() {
  local name="$1"
  local cmd="$2"

  if command -v "$cmd" >/dev/null 2>&1; then
    pass "${name}: $(command -v "$cmd")"
  else
    fail "${name}: missing ${cmd}"
  fi
}

load_env() {
  if [[ -f "${ENV_FILE}" ]]; then
    set -a
    # shellcheck disable=SC1090
    source "${ENV_FILE}"
    set +a
    pass ".env loaded"
  else
    warn ".env missing; run make bootstrap"
  fi
}

check_platform() {
  if [[ "$(uname -s)" == "Darwin" ]]; then
    pass "macOS host"
  else
    fail "not running on macOS"
  fi

  if [[ "$(uname -m)" == "arm64" ]]; then
    pass "Apple Silicon arm64"
  else
    fail "not running on arm64"
  fi
}

check_lms() {
  if [[ -x "${HOME}/.lmstudio/bin/lms" ]]; then
    pass "lms: ${HOME}/.lmstudio/bin/lms"
  elif command -v lms >/dev/null 2>&1; then
    pass "lms: $(command -v lms)"
  else
    fail "lms missing; launch LM Studio once after install"
  fi
}

check_user_ssh_key() {
  local user_key="${USER_SSH_PUBLIC_KEY:-${HOME}/.ssh/id_ed25519.pub}"

  if [[ -f "${user_key}" ]]; then
    pass "user SSH public key: ${user_key}"
  else
    warn "user SSH public key not found: ${user_key}; vm-create will still generate ${VM_SSH_KEY:-${HOME}/.ssh/omlx_agent_vm_ed25519}.pub"
  fi
}

find_vmrun() {
  if [[ -n "${VMRUN_PATH:-}" && -x "${VMRUN_PATH}" ]]; then
    printf '%s\n' "${VMRUN_PATH}"
    return 0
  fi

  local candidates=(
    "/Applications/VMware Fusion.app/Contents/Public/vmrun"
    "/Applications/VMware Fusion.app/Contents/Library/vmrun"
  )

  local candidate
  for candidate in "${candidates[@]}"; do
    if [[ -x "${candidate}" ]]; then
      printf '%s\n' "${candidate}"
      return 0
    fi
  done

  return 1
}

check_vmware() {
  if [[ -d "/Applications/VMware Fusion.app" ]]; then
    pass "VMware Fusion app"
  else
    fail "VMware Fusion app missing"
    return
  fi

  local vmrun_path
  if vmrun_path="$(find_vmrun)"; then
    pass "vmrun: ${vmrun_path}"
  else
    fail "vmrun missing"
  fi

  if [[ -x "/Applications/VMware Fusion.app/Contents/Library/vmcli" ]]; then
    pass "vmcli"
  else
    fail "vmcli missing"
  fi

  if [[ -x "/Applications/VMware Fusion.app/Contents/Library/vmware-vdiskmanager" ]]; then
    pass "vmware-vdiskmanager"
  else
    fail "vmware-vdiskmanager missing"
  fi
}

check_multipass() {
  if command -v multipass >/dev/null 2>&1; then
    pass "multipass: $(command -v multipass)"
    if multipass version >/dev/null 2>&1; then
      pass "Multipass daemon reachable"
    else
      warn "multipass CLI exists, but daemon is not reachable; launch/open Multipass once"
    fi
  else
    fail "multipass missing"
  fi
}

check_docker() {
  if [[ -d "/Applications/Docker.app" ]]; then
    pass "Docker.app"
  else
    fail "Docker.app missing"
  fi

  if command -v docker >/dev/null 2>&1; then
    pass "docker CLI: $(command -v docker)"
    if docker version >/dev/null 2>&1; then
      pass "Docker daemon reachable"
    else
      warn "Docker CLI exists, but daemon is not reachable; launch Docker Desktop"
    fi
  else
    fail "docker CLI missing"
  fi
}

check_model_api() {
  local base_url="${OPENAI_BASE_URL:-http://localhost:8000/v1}"
  local api_key="${OPENAI_API_KEY:-}"
  local models_url="${base_url%/}/models"
  local curl_args=(-fsS --max-time 3)

  if [[ -n "${api_key}" ]]; then
    curl_args+=(-H "Authorization: Bearer ${api_key}")
  fi

  if curl "${curl_args[@]}" "${models_url}" >/dev/null 2>&1; then
    pass "model API reachable: ${models_url}"
  elif [[ "${MODEL_REQUIRED}" == "1" ]]; then
    fail "model API not reachable: ${models_url}"
  else
    warn "model API not reachable yet: ${models_url}"
  fi
}

check_model_dir() {
  local model_dir="${MODEL_DIR:-${HOME}/.lmstudio/models}"

  if [[ -d "${model_dir}" ]]; then
    pass "model dir: ${model_dir}"
  else
    warn "model dir missing: ${model_dir}"
  fi
}

main() {
  load_env
  check_platform
  check_command "brew" brew
  check_command "git" git
  check_command "jq" jq
  check_command "yq" yq
  if [[ "${VM_ENGINE:-multipass}" == "vmware" || "${VM_ENGINE:-multipass}" == "fusion" ]]; then
    check_command "qemu-img" qemu-img
  elif command -v qemu-img >/dev/null 2>&1; then
    pass "qemu-img: $(command -v qemu-img)"
  else
    warn "qemu-img missing; only needed for VM_ENGINE=vmware"
  fi
  check_command "uv" uv
  check_command "pipx" pipx
  check_command "node" node
  check_command "pnpm" pnpm
  check_command "omlx" omlx
  check_lms
  check_user_ssh_key
  check_model_dir

  # Check only the active VM engine; skip (with a note) the inactive one.
  local engine="${VM_ENGINE:-multipass}"
  case "${engine}" in
    multipass)
      check_multipass
      if [[ -d "/Applications/VMware Fusion.app" ]]; then
        pass "VMware Fusion installed (inactive; set VM_ENGINE=vmware to use it)"
      fi
      ;;
    vmware|fusion)
      check_vmware
      if command -v multipass >/dev/null 2>&1; then
        pass "multipass installed (inactive; set VM_ENGINE=multipass to use it)"
      fi
      ;;
    *)
      fail "unknown VM_ENGINE=${engine}"
      ;;
  esac

  check_docker
  check_model_api

  printf '\nDoctor finished: %s failure(s), %s warning(s)\n' "${failures}" "${warnings}"

  if [[ "${failures}" -gt 0 ]]; then
    exit 1
  fi
}

main "$@"
