#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
ENV_FILE="${PROJECT_ROOT}/.env"
ENV_EXAMPLE="${PROJECT_ROOT}/.env.example"
STATE_DIR="${PROJECT_ROOT}/.vm"

OVERRIDE_AGENT_RUNTIME="${AGENT_RUNTIME:-}"
OVERRIDE_VM_NAME="${VM_NAME:-}"
OVERRIDE_OBSIDIAN_SHARED_PATH_SET="${OBSIDIAN_SHARED_PATH+x}"
OVERRIDE_OBSIDIAN_SHARED_PATH="${OBSIDIAN_SHARED_PATH:-}"
OVERRIDE_OBSIDIAN_GUEST_PATH="${OBSIDIAN_GUEST_PATH:-}"

if [[ -f "${ENV_FILE}" ]]; then
  set -a
  # shellcheck disable=SC1090
  source "${ENV_FILE}"
  set +a
elif [[ -f "${ENV_EXAMPLE}" ]]; then
  set -a
  # shellcheck disable=SC1090
  source "${ENV_EXAMPLE}"
  set +a
fi

AGENT_RUNTIME="${OVERRIDE_AGENT_RUNTIME:-${AGENT_RUNTIME:-hermes}}"
HERMES_VM_NAME="${HERMES_VM_NAME:-${VM_NAME:-omlx-agent-ubuntu}}"
OPENCLAW_VM_NAME="${OPENCLAW_VM_NAME:-omlx-openclaw-ubuntu}"
case "${AGENT_RUNTIME}" in
  hermes) DEFAULT_VM_NAME="${HERMES_VM_NAME}" ;;
  openclaw) DEFAULT_VM_NAME="${OPENCLAW_VM_NAME}" ;;
  *) DEFAULT_VM_NAME="${VM_NAME:-omlx-agent-ubuntu}" ;;
esac
VM_NAME="${OVERRIDE_VM_NAME:-${DEFAULT_VM_NAME}}"
VM_CPUS="${VM_CPUS:-4}"
VM_MEMORY="${VM_MEMORY:-8G}"
VM_DISK="${VM_DISK:-80G}"
VM_SSH_USER="${VM_SSH_USER:-agent}"
VM_SSH_KEY="${VM_SSH_KEY:-${HOME}/.ssh/omlx_agent_vm_ed25519}"
USER_SSH_PUBLIC_KEY="${USER_SSH_PUBLIC_KEY:-${HOME}/.ssh/id_ed25519.pub}"
VM_SNAPSHOT_NAME="${VM_SNAPSHOT_NAME:-clean-agent-base}"
if [[ -n "${OVERRIDE_OBSIDIAN_SHARED_PATH_SET}" ]]; then
  OBSIDIAN_SHARED_PATH="${OVERRIDE_OBSIDIAN_SHARED_PATH}"
else
  OBSIDIAN_SHARED_PATH="${OBSIDIAN_SHARED_PATH:-}"
fi
OBSIDIAN_GUEST_PATH="${OVERRIDE_OBSIDIAN_GUEST_PATH:-${OBSIDIAN_GUEST_PATH:-/mnt/obsidian}}"
SHARED_MOUNTS_REQUIRED="${SHARED_MOUNTS_REQUIRED:-0}"
UBUNTU_MULTIPASS_IMAGE="${UBUNTU_MULTIPASS_IMAGE:-24.04}"
MULTIPASS_LAUNCH_TIMEOUT="${MULTIPASS_LAUNCH_TIMEOUT:-900}"
VM_PACKAGE_UPGRADE="${VM_PACKAGE_UPGRADE:-false}"
OPENAI_API_KEY="${OPENAI_API_KEY:-}"
ANTHROPIC_API_KEY="${ANTHROPIC_API_KEY:-${OPENAI_API_KEY}}"
TAILSCALE_AUTH_KEY="${TAILSCALE_AUTH_KEY:-}"
TAILSCALE_ENABLED="${TAILSCALE_ENABLED:-0}"
TAILSCALE_HOSTNAME="${TAILSCALE_HOSTNAME:-${VM_NAME}}"
TAILSCALE_EXTRA_ARGS="${TAILSCALE_EXTRA_ARGS:-}"

log() {
  printf '\n==> %s\n' "$*"
}

die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

shell_quote() {
  printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"
}

set_env_value() {
  local key="$1"
  local value="$2"
  local escaped_value
  local tmp

  [[ -f "${ENV_FILE}" ]] || cp "${ENV_EXAMPLE}" "${ENV_FILE}"
  escaped_value="$(shell_quote "${value}")"
  tmp="$(mktemp)"

  if grep -q "^${key}=" "${ENV_FILE}"; then
    awk -v key="${key}" -v value="${escaped_value}" '
      $0 ~ "^" key "=" {
        print key "=" value
        replaced = 1
        next
      }
      { print }
      END {
        if (replaced != 1) {
          print key "=" value
        }
      }
    ' "${ENV_FILE}" > "${tmp}"
  else
    cp "${ENV_FILE}" "${tmp}"
    printf '%s=%s\n' "${key}" "${escaped_value}" >> "${tmp}"
  fi

  mv "${tmp}" "${ENV_FILE}"
}

ensure_ssh_key() {
  log "Preparing SSH keys"

  if [[ ! -f "${VM_SSH_KEY}" ]]; then
    mkdir -p "$(dirname "${VM_SSH_KEY}")"
    ssh-keygen -t ed25519 -N "" -C "${VM_NAME}" -f "${VM_SSH_KEY}"
  fi

  [[ -f "${VM_SSH_KEY}.pub" ]] || die "Missing generated public key: ${VM_SSH_KEY}.pub"
}

collect_ssh_public_keys_yaml() {
  local key_files=()
  local candidate
  local key_file
  local tmp

  key_files+=("${VM_SSH_KEY}.pub")
  [[ -n "${USER_SSH_PUBLIC_KEY}" ]] && key_files+=("${USER_SSH_PUBLIC_KEY}")

  for candidate in \
    "${HOME}/.ssh/id_ed25519.pub" \
    "${HOME}/.ssh/id_ecdsa.pub" \
    "${HOME}/.ssh/id_rsa.pub" \
    "${HOME}/.ssh/id_ed25519_sk.pub" \
    "${HOME}/.ssh/id_ecdsa_sk.pub"; do
    key_files+=("${candidate}")
  done

  tmp="$(mktemp)"
  for key_file in "${key_files[@]}"; do
    [[ -f "${key_file}" ]] && sed '/^[[:space:]]*$/d' "${key_file}" >> "${tmp}"
  done

  [[ -s "${tmp}" ]] || die "No SSH public keys found under ~/.ssh."
  awk '!seen[$0]++ { print "      - " $0 }' "${tmp}"
  rm -f "${tmp}"
}

instance_exists() {
  multipass info "${VM_NAME}" >/dev/null 2>&1
}

create_cloud_init() {
  log "Generating cloud-init config"

  mkdir -p "${STATE_DIR}"
  CLOUD_INIT="${STATE_DIR}/${VM_NAME}-cloud-init.yaml"

  local public_keys_yaml
  public_keys_yaml="$(collect_ssh_public_keys_yaml)"

  cat > "${CLOUD_INIT}" <<EOF
#cloud-config
users:
  - name: ${VM_SSH_USER}
    groups: [adm, sudo]
    shell: /bin/bash
    sudo: ["ALL=(ALL) NOPASSWD:ALL"]
    ssh_authorized_keys:
${public_keys_yaml}
ssh_pwauth: false
disable_root: true
package_update: true
package_upgrade: ${VM_PACKAGE_UPGRADE}
packages:
  - openssh-server
  - ca-certificates
  - curl
  - wget
  - git
  - jq
  - ripgrep
  - build-essential
  - python3
  - python3-pip
  - python3-venv
write_files:
  - path: /usr/local/sbin/update-host-service-aliases
    permissions: '0755'
    content: |
      #!/usr/bin/env bash
      set -euo pipefail
      gateway="\$(ip route | awk '/default/ {print \$3; exit}')"
      if [[ -z "\${gateway}" ]]; then
        exit 0
      fi
      grep -Ev '[[:space:]](model-host|rag-host)\.internal$' /etc/hosts > /etc/hosts.tmp
      printf '%s model-host.internal\n' "\${gateway}" >> /etc/hosts.tmp
      printf '%s rag-host.internal\n' "\${gateway}" >> /etc/hosts.tmp
      mv /etc/hosts.tmp /etc/hosts
  - path: /usr/local/sbin/update-model-host-alias
    permissions: '0755'
    content: |
      #!/usr/bin/env bash
      exec /usr/local/sbin/update-host-service-aliases
  - path: /etc/systemd/system/host-service-aliases.service
    permissions: '0644'
    content: |
      [Unit]
      Description=Map host service aliases to the default gateway
      After=network-online.target
      Wants=network-online.target

      [Service]
      Type=oneshot
      ExecStart=/usr/local/sbin/update-host-service-aliases
      RemainAfterExit=yes

      [Install]
      WantedBy=multi-user.target
  - path: /etc/systemd/system/model-host-alias.service
    permissions: '0644'
    content: |
      [Unit]
      Description=Compatibility alias for host service mapping
      After=host-service-aliases.service

      [Service]
      Type=oneshot
      ExecStart=/usr/local/sbin/update-host-service-aliases
      RemainAfterExit=yes

      [Install]
      WantedBy=multi-user.target
  - path: /etc/profile.d/local-model-server.sh
    permissions: '0644'
    content: |
      export OPENAI_BASE_URL=\${OPENAI_BASE_URL:-http://model-host.internal:8000/v1}
      export ANTHROPIC_BASE_URL=\${ANTHROPIC_BASE_URL:-http://model-host.internal:8000}
      export RAG_BASE_URL=\${RAG_BASE_URL:-http://rag-host.internal:8765}
      export OPENAI_API_KEY=\${OPENAI_API_KEY:-${OPENAI_API_KEY}}
      export ANTHROPIC_API_KEY=\${ANTHROPIC_API_KEY:-${ANTHROPIC_API_KEY}}
runcmd:
  - mkdir -p /mnt/obsidian
  - mkdir -p /home/${VM_SSH_USER}/workspace /home/${VM_SSH_USER}/.hermes /home/${VM_SSH_USER}/.local/bin
  - chown -R ${VM_SSH_USER}:${VM_SSH_USER} /home/${VM_SSH_USER}/workspace /home/${VM_SSH_USER}/.hermes /home/${VM_SSH_USER}/.local
  - chmod 0755 /usr/local/sbin/update-host-service-aliases /usr/local/sbin/update-model-host-alias
  - chmod 0644 /etc/systemd/system/host-service-aliases.service /etc/systemd/system/model-host-alias.service /etc/profile.d/local-model-server.sh
  - systemctl daemon-reload
  - systemctl enable --now host-service-aliases.service
  - systemctl enable --now model-host-alias.service
  - systemctl enable --now ssh
EOF

  if [[ "${TAILSCALE_ENABLED}" == "1" || "${TAILSCALE_ENABLED}" == "true" || -n "${TAILSCALE_AUTH_KEY}" ]]; then
    cat >> "${CLOUD_INIT}" <<EOF
  - curl -fsSL https://tailscale.com/install.sh | sh
EOF
    if [[ -n "${TAILSCALE_AUTH_KEY}" ]]; then
      printf '  - tailscale up --authkey="%s" --hostname="%s" --accept-routes %s\n' "${TAILSCALE_AUTH_KEY}" "${TAILSCALE_HOSTNAME}" "${TAILSCALE_EXTRA_ARGS}" >> "${CLOUD_INIT}"
    fi
  fi

  cat >> "${CLOUD_INIT}" <<EOF
final_message: "omlx-agent Multipass Ubuntu VM is ready after \$UPTIME seconds"
EOF
}

create_instance() {
  log "Creating Multipass Ubuntu VM"

  if instance_exists; then
    die "Multipass instance already exists: ${VM_NAME}. Use make vm-start or delete it with: multipass delete --purge ${VM_NAME}"
  fi

  multipass launch "${UBUNTU_MULTIPASS_IMAGE}" \
    --name "${VM_NAME}" \
    --cpus "${VM_CPUS}" \
    --memory "${VM_MEMORY}" \
    --disk "${VM_DISK}" \
    --timeout "${MULTIPASS_LAUNCH_TIMEOUT}" \
    --cloud-init "${CLOUD_INIT}"
}

configure_shared_folder() {
  if [[ -z "${OBSIDIAN_SHARED_PATH}" ]]; then
    return
  fi

  log "Mounting Obsidian knowledge folder"
  if ! OBSIDIAN_SHARED_PATH="${OBSIDIAN_SHARED_PATH}" \
    OBSIDIAN_GUEST_PATH="${OBSIDIAN_GUEST_PATH}" \
    VM_NAME="${VM_NAME}" \
    "${SCRIPT_DIR}/shared-mounts.sh" sync multipass; then
    if [[ "${SHARED_MOUNTS_REQUIRED}" == "1" ]]; then
      die "shared folder mount failed"
    fi
    echo "WARNING: shared folder mount failed; continuing because SHARED_MOUNTS_REQUIRED=0."
  fi
}

write_state() {
  mkdir -p "${STATE_DIR}"
  cat > "${STATE_DIR}/${VM_NAME}.env" <<EOF
VM_NAME=$(shell_quote "${VM_NAME}")
VM_SSH_USER=$(shell_quote "${VM_SSH_USER}")
VM_SSH_KEY=$(shell_quote "${VM_SSH_KEY}")
USER_SSH_PUBLIC_KEY=$(shell_quote "${USER_SSH_PUBLIC_KEY}")
VM_SNAPSHOT_NAME=$(shell_quote "${VM_SNAPSHOT_NAME}")
EOF

  case "${AGENT_RUNTIME}" in
    hermes)
      set_env_value VM_NAME "${VM_NAME}"
      set_env_value HERMES_VM_NAME "${VM_NAME}"
      ;;
    openclaw)
      set_env_value OPENCLAW_VM_NAME "${VM_NAME}"
      ;;
  esac
  set_env_value VM_CPUS "${VM_CPUS}"
  set_env_value VM_MEMORY "${VM_MEMORY}"
  set_env_value VM_DISK "${VM_DISK}"
  set_env_value VM_SSH_USER "${VM_SSH_USER}"
  set_env_value VM_SSH_KEY "${VM_SSH_KEY}"
  set_env_value USER_SSH_PUBLIC_KEY "${USER_SSH_PUBLIC_KEY}"
  set_env_value VM_SNAPSHOT_NAME "${VM_SNAPSHOT_NAME}"
  set_env_value UBUNTU_MULTIPASS_IMAGE "${UBUNTU_MULTIPASS_IMAGE}"
  set_env_value MULTIPASS_LAUNCH_TIMEOUT "${MULTIPASS_LAUNCH_TIMEOUT}"
  set_env_value VM_PACKAGE_UPGRADE "${VM_PACKAGE_UPGRADE}"
  set_env_value TAILSCALE_ENABLED "${TAILSCALE_ENABLED}"
  set_env_value TAILSCALE_HOSTNAME "${TAILSCALE_HOSTNAME}"
}

main() {
  command -v multipass >/dev/null 2>&1 || die "Missing multipass. Run make bootstrap first."
  command -v ssh-keygen >/dev/null 2>&1 || die "Missing ssh-keygen."

  ensure_ssh_key
  create_cloud_init
  create_instance
  configure_shared_folder
  write_state

  log "Multipass VM created"
  cat <<EOF
Instance: ${VM_NAME}
Image: ${UBUNTU_MULTIPASS_IMAGE}
Resources: ${VM_CPUS} vCPU, ${VM_MEMORY} RAM, ${VM_DISK} disk
SSH user: ${VM_SSH_USER}
EOF

  if [[ -n "${TAILSCALE_AUTH_KEY}" ]]; then
    echo "Tailscale: Configured with Auth Key (automated join)"
  elif [[ "${TAILSCALE_ENABLED}" == "1" || "${TAILSCALE_ENABLED}" == "true" ]]; then
    echo "Tailscale: Installed. To join your tailnet, run:"
    echo "  multipass exec ${VM_NAME} -- sudo tailscale up --hostname=${TAILSCALE_HOSTNAME}"
  else
    echo "Tailscale: Disabled. Set TAILSCALE_ENABLED=1 or TAILSCALE_AUTH_KEY to install it in the VM."
  fi

  cat <<EOF

Next:
  make vm-ssh
  make vm-snapshot
EOF
}

main "$@"
