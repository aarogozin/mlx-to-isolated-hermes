#!/usr/bin/env bash
# scripts/vm-common.sh — Shared Multipass guest helpers.
#
# Source this file from other scripts. Do not execute it directly.

_vm_known_hosts() {
  local script_dir
  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  printf '%s' "${script_dir}/../.runtime/known_hosts"
}

require_vm_ready() {
  local name="${VM_NAME:-omlx-agent-ubuntu}"

  command -v multipass >/dev/null 2>&1 \
    || { printf 'ERROR: multipass not found. Run make bootstrap.\n' >&2; return 1; }
  multipass info "${name}" >/dev/null 2>&1 \
    || { printf 'ERROR: Multipass VM "%s" not found. Run make vm-create.\n' "${name}" >&2; return 1; }
}

get_vm_ip() {
  local name="${VM_NAME:-omlx-agent-ubuntu}"
  multipass info "${name}" | awk '/IPv4/ { print $2; exit }'
}

vm_exec() {
  local cmd="$1"
  local name="${VM_NAME:-omlx-agent-ubuntu}"
  local user="${VM_SSH_USER:-agent}"

  multipass exec "${name}" -- sudo -Hu "${user}" bash -lc "${cmd}"
}

vm_exec_root() {
  local cmd="$1"
  local name="${VM_NAME:-omlx-agent-ubuntu}"

  multipass exec "${name}" -- sudo bash -lc "${cmd}"
}

vm_exec_root_env() {
  local name="${VM_NAME:-omlx-agent-ubuntu}"
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

  if [[ -z "${cmd}" && "${#env_args[@]}" -gt 0 ]]; then
    cmd="${env_args[-1]}"
    unset 'env_args[-1]'
  fi

  multipass exec "${name}" -- sudo env "${env_args[@]}" bash -lc "${cmd}"
}

vm_transfer() {
  local src="$1"
  local dst="$2"
  local name="${VM_NAME:-omlx-agent-ubuntu}"

  if [[ "${src}" == "-" ]]; then
    multipass transfer - "${name}:${dst}"
  else
    multipass transfer "${src}" "${name}:${dst}"
  fi
}
