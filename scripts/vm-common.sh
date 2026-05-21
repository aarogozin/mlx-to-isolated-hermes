#!/usr/bin/env bash
# scripts/vm-common.sh — Shared VM guest helpers (Multipass + VMware Fusion).
#
# SOURCE this file from other scripts. Do NOT execute directly.
# The caller must have already loaded .env so that VM_ENGINE, VM_NAME,
# VM_SSH_USER, VM_SSH_KEY, and VMX_PATH are available in the environment.
#
# Public API
# ──────────
#   require_vm_ready              — exit if the guest VM does not exist
#   get_vm_ip                     — print the guest IP address
#   vm_exec          "<cmd>"      — run a login-shell command as the agent user
#   vm_exec_root     "<cmd>"      — run a login-shell command as root
#   vm_exec_root_env [K=V …] -- "<cmd>"
#                                 — run as root with extra env vars (stdin forwarded)
#   vm_transfer      <src> <dst>  — copy a local file (or stdin when src="-")
#                                   to an absolute path inside the guest

# ── Internal helpers ──────────────────────────────────────────────────────────

_vm_known_hosts() {
  # Resolve the project root relative to this file so callers don't need to set it.
  local script_dir
  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  printf '%s' "${script_dir}/../.runtime/known_hosts"
}

# Build SSH option array into a global _VM_SSH_OPTS, then callers can use
# "${_VM_SSH_OPTS[@]}" to expand it safely (no word-splitting issues).
_vm_build_ssh_opts() {
  local known_hosts
  known_hosts="$(_vm_known_hosts)"
  _VM_SSH_OPTS=(
    -i "${VM_SSH_KEY:-${HOME}/.ssh/omlx_agent_vm_ed25519}"
    -o BatchMode=yes
    -o StrictHostKeyChecking=accept-new
    -o UserKnownHostsFile="${known_hosts}"
  )
}

# ── require_vm_ready ──────────────────────────────────────────────────────────
require_vm_ready() {
  local engine="${VM_ENGINE:-multipass}"
  local name="${VM_NAME:-omlx-agent-ubuntu}"

  case "${engine}" in
    multipass)
      command -v multipass >/dev/null 2>&1 \
        || { printf 'ERROR: multipass not found. Run make bootstrap.\n' >&2; return 1; }
      multipass info "${name}" >/dev/null 2>&1 \
        || { printf 'ERROR: Multipass VM "%s" not found. Run make vm-create.\n' "${name}" >&2; return 1; }
      ;;
    vmware|fusion)
      local vmrun="${VMRUN_PATH:-/Applications/VMware Fusion.app/Contents/Public/vmrun}"
      [[ -x "${vmrun}" ]] \
        || { printf 'ERROR: vmrun not found: %s\n' "${vmrun}" >&2; return 1; }
      [[ -f "${VMX_PATH:-}" ]] \
        || { printf 'ERROR: VMX not found: %s. Run make vm-create.\n' "${VMX_PATH:-}" >&2; return 1; }
      [[ -f "${VM_SSH_KEY:-}" ]] \
        || { printf 'ERROR: VM SSH key not found: %s. Run make vm-create.\n' "${VM_SSH_KEY:-}" >&2; return 1; }
      ;;
    *)
      printf 'ERROR: unsupported VM_ENGINE=%s. Use multipass or vmware.\n' "${engine}" >&2
      return 1
      ;;
  esac
}

# ── get_vm_ip ─────────────────────────────────────────────────────────────────
get_vm_ip() {
  local engine="${VM_ENGINE:-multipass}"
  local name="${VM_NAME:-omlx-agent-ubuntu}"

  case "${engine}" in
    multipass)
      multipass info "${name}" | awk '/IPv4/ { print $2; exit }'
      ;;
    vmware|fusion)
      local vmrun="${VMRUN_PATH:-/Applications/VMware Fusion.app/Contents/Public/vmrun}"
      "${vmrun}" -T fusion getGuestIPAddress "${VMX_PATH}" -wait
      ;;
    *)
      printf 'ERROR: unsupported VM_ENGINE=%s\n' "${engine}" >&2
      return 1
      ;;
  esac
}

# ── vm_exec ───────────────────────────────────────────────────────────────────
# Run a login-shell command as the agent user inside the guest VM.
# The single argument is passed to `bash -lc`.
vm_exec() {
  local cmd="$1"
  local engine="${VM_ENGINE:-multipass}"
  local name="${VM_NAME:-omlx-agent-ubuntu}"
  local user="${VM_SSH_USER:-agent}"

  case "${engine}" in
    multipass)
      multipass exec "${name}" -- sudo -Hu "${user}" bash -lc "${cmd}"
      ;;
    vmware|fusion)
      local ip
      ip="$(get_vm_ip)"
      _vm_build_ssh_opts
      ssh "${_VM_SSH_OPTS[@]}" "${user}@${ip}" bash -lc "${cmd}"
      ;;
    *)
      printf 'ERROR: unsupported VM_ENGINE=%s\n' "${engine}" >&2
      return 1
      ;;
  esac
}

# ── vm_exec_root ──────────────────────────────────────────────────────────────
# Run a login-shell command as root inside the guest VM.
# stdin is forwarded, so heredocs work as expected.
vm_exec_root() {
  local cmd="$1"
  local engine="${VM_ENGINE:-multipass}"
  local name="${VM_NAME:-omlx-agent-ubuntu}"
  local user="${VM_SSH_USER:-agent}"

  case "${engine}" in
    multipass)
      multipass exec "${name}" -- sudo bash -lc "${cmd}"
      ;;
    vmware|fusion)
      local ip
      ip="$(get_vm_ip)"
      _vm_build_ssh_opts
      ssh "${_VM_SSH_OPTS[@]}" "${user}@${ip}" sudo bash -lc "${cmd}"
      ;;
    *)
      printf 'ERROR: unsupported VM_ENGINE=%s\n' "${engine}" >&2
      return 1
      ;;
  esac
}

# ── vm_exec_root_env ──────────────────────────────────────────────────────────
# Run a command as root with explicit KEY=VALUE environment variables.
# All arguments up to (but not including) the last one are treated as env vars;
# the last argument is the command string passed to bash -lc.
# stdin is forwarded (supports heredocs and piped Python/shell scripts).
#
# Usage example:
#   vm_exec_root_env \
#     AGENT_USER="agent" \
#     OPENAI_API_KEY="sk-..." \
#     -- "python3 -" <<'PY'
#   print("hello")
#   PY
#
# The sentinel "--" is optional; when omitted the last positional argument is
# taken as the command.
vm_exec_root_env() {
  local engine="${VM_ENGINE:-multipass}"
  local name="${VM_NAME:-omlx-agent-ubuntu}"
  local user="${VM_SSH_USER:-agent}"

  # Collect env vars and command: everything before an optional "--" is an
  # env var; the first arg after "--" (or the last arg) is the command.
  local -a env_args=()
  local cmd=""
  local past_separator=0

  for arg in "$@"; do
    if [[ "${past_separator}" -eq 1 ]]; then
      cmd="${arg}"
      break
    fi
    if [[ "${arg}" == "--" ]]; then
      past_separator=1
    else
      env_args+=("${arg}")
    fi
  done

  # If no "--" was found, the last env_arg is actually the command.
  if [[ -z "${cmd}" && "${#env_args[@]}" -gt 0 ]]; then
    cmd="${env_args[-1]}"
    unset 'env_args[-1]'
  fi

  case "${engine}" in
    multipass)
      multipass exec "${name}" -- sudo env "${env_args[@]}" bash -lc "${cmd}"
      ;;
    vmware|fusion)
      local ip
      ip="$(get_vm_ip)"
      _vm_build_ssh_opts
      ssh "${_VM_SSH_OPTS[@]}" "${user}@${ip}" sudo env "${env_args[@]}" bash -lc "${cmd}"
      ;;
    *)
      printf 'ERROR: unsupported VM_ENGINE=%s\n' "${engine}" >&2
      return 1
      ;;
  esac
}

# ── vm_transfer ───────────────────────────────────────────────────────────────
# Transfer a local file (or stdin when src="-") to the guest VM.
# dst must be an absolute path inside the guest.
vm_transfer() {
  local src="$1"
  local dst="$2"
  local engine="${VM_ENGINE:-multipass}"
  local name="${VM_NAME:-omlx-agent-ubuntu}"
  local user="${VM_SSH_USER:-agent}"

  case "${engine}" in
    multipass)
      if [[ "${src}" == "-" ]]; then
        multipass transfer - "${name}:${dst}"
      else
        multipass transfer "${src}" "${name}:${dst}"
      fi
      ;;
    vmware|fusion)
      local ip
      ip="$(get_vm_ip)"
      _vm_build_ssh_opts
      if [[ "${src}" == "-" ]]; then
        ssh "${_VM_SSH_OPTS[@]}" "${user}@${ip}" "cat > $(printf '%q' "${dst}")"
      else
        scp "${_VM_SSH_OPTS[@]}" "${src}" "${user}@${ip}:${dst}"
      fi
      ;;
    *)
      printf 'ERROR: unsupported VM_ENGINE=%s\n' "${engine}" >&2
      return 1
      ;;
  esac
}
