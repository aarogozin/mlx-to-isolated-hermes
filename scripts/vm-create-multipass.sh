#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
ENV_FILE="${PROJECT_ROOT}/.env"
ENV_EXAMPLE="${PROJECT_ROOT}/.env.example"
STATE_DIR="${PROJECT_ROOT}/.vm"

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

VM_NAME="${VM_NAME:-omlx-agent-ubuntu}"
VM_CPUS="${VM_CPUS:-4}"
VM_MEMORY="${VM_MEMORY:-8G}"
VM_DISK="${VM_DISK:-80G}"
VM_SSH_USER="${VM_SSH_USER:-agent}"
VM_SSH_KEY="${VM_SSH_KEY:-${HOME}/.ssh/omlx_agent_vm_ed25519}"
USER_SSH_PUBLIC_KEY="${USER_SSH_PUBLIC_KEY:-${HOME}/.ssh/id_ed25519.pub}"
VM_SNAPSHOT_NAME="${VM_SNAPSHOT_NAME:-clean-agent-base}"
OBSIDIAN_SHARED_PATH="${OBSIDIAN_SHARED_PATH:-}"
UBUNTU_MULTIPASS_IMAGE="${UBUNTU_MULTIPASS_IMAGE:-24.04}"
OPENAI_API_KEY="${OPENAI_API_KEY:-}"
ANTHROPIC_API_KEY="${ANTHROPIC_API_KEY:-${OPENAI_API_KEY}}"

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
package_upgrade: true
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
  - nodejs
  - npm
write_files:
  - path: /usr/local/sbin/update-model-host-alias
    permissions: "0755"
    content: |
      #!/usr/bin/env bash
      set -euo pipefail
      gateway="\$(ip route | awk '/default/ {print \$3; exit}')"
      if [[ -z "\${gateway}" ]]; then
        exit 0
      fi
      grep -v '[[:space:]]model-host\.internal$' /etc/hosts > /etc/hosts.tmp
      printf '%s model-host.internal\n' "\${gateway}" >> /etc/hosts.tmp
      mv /etc/hosts.tmp /etc/hosts
  - path: /etc/systemd/system/model-host-alias.service
    permissions: "0644"
    content: |
      [Unit]
      Description=Map model-host.internal to the default gateway
      After=network-online.target
      Wants=network-online.target

      [Service]
      Type=oneshot
      ExecStart=/usr/local/sbin/update-model-host-alias
      RemainAfterExit=yes

      [Install]
      WantedBy=multi-user.target
  - path: /etc/profile.d/local-model-server.sh
    permissions: "0644"
    content: |
      export OPENAI_BASE_URL=\${OPENAI_BASE_URL:-http://model-host.internal:8000/v1}
      export ANTHROPIC_BASE_URL=\${ANTHROPIC_BASE_URL:-http://model-host.internal:8000}
      export OPENAI_API_KEY=\${OPENAI_API_KEY:-${OPENAI_API_KEY}}
      export ANTHROPIC_API_KEY=\${ANTHROPIC_API_KEY:-${ANTHROPIC_API_KEY}}
runcmd:
  - mkdir -p /mnt/obsidian
  - mkdir -p /home/${VM_SSH_USER}/workspace /home/${VM_SSH_USER}/.hermes /home/${VM_SSH_USER}/.local/bin
  - chown -R ${VM_SSH_USER}:${VM_SSH_USER} /home/${VM_SSH_USER}/workspace /home/${VM_SSH_USER}/.hermes /home/${VM_SSH_USER}/.local
  - systemctl daemon-reload
  - systemctl enable --now model-host-alias.service
  - systemctl enable --now ssh
  - npm install -g pnpm@10 || true
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
    --cloud-init "${CLOUD_INIT}"
}

configure_shared_folder() {
  if [[ -z "${OBSIDIAN_SHARED_PATH}" ]]; then
    return
  fi

  log "Mounting Obsidian knowledge folder"

  [[ -d "${OBSIDIAN_SHARED_PATH}" ]] || die "OBSIDIAN_SHARED_PATH does not exist: ${OBSIDIAN_SHARED_PATH}"
  multipass exec "${VM_NAME}" -- sudo mkdir -p /mnt/obsidian
  multipass mount "${OBSIDIAN_SHARED_PATH}" "${VM_NAME}:/mnt/obsidian"
}

write_state() {
  mkdir -p "${STATE_DIR}"
  cat > "${STATE_DIR}/${VM_NAME}.env" <<EOF
VM_ENGINE=$(shell_quote "multipass")
VM_NAME=$(shell_quote "${VM_NAME}")
VM_SSH_USER=$(shell_quote "${VM_SSH_USER}")
VM_SSH_KEY=$(shell_quote "${VM_SSH_KEY}")
USER_SSH_PUBLIC_KEY=$(shell_quote "${USER_SSH_PUBLIC_KEY}")
VM_SNAPSHOT_NAME=$(shell_quote "${VM_SNAPSHOT_NAME}")
EOF

  set_env_value VM_ENGINE "multipass"
  set_env_value VM_NAME "${VM_NAME}"
  set_env_value VM_CPUS "${VM_CPUS}"
  set_env_value VM_MEMORY "${VM_MEMORY}"
  set_env_value VM_DISK "${VM_DISK}"
  set_env_value VM_SSH_USER "${VM_SSH_USER}"
  set_env_value VM_SSH_KEY "${VM_SSH_KEY}"
  set_env_value USER_SSH_PUBLIC_KEY "${USER_SSH_PUBLIC_KEY}"
  set_env_value VM_SNAPSHOT_NAME "${VM_SNAPSHOT_NAME}"
  set_env_value UBUNTU_MULTIPASS_IMAGE "${UBUNTU_MULTIPASS_IMAGE}"
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

Next:
  make vm-ssh
  make vm-snapshot
EOF
}

main "$@"
