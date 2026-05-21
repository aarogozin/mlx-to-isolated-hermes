#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
ENV_FILE="${PROJECT_ROOT}/.env"
ENV_EXAMPLE="${PROJECT_ROOT}/.env.example"
STATE_DIR="${PROJECT_ROOT}/.vm"
CACHE_DIR="${PROJECT_ROOT}/.cache/ubuntu-cloud-images"

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
else
  printf 'ERROR: missing .env and .env.example\n' >&2
  exit 1
fi

VM_NAME="${VM_NAME:-omlx-agent-ubuntu}"
VM_DIR="${VM_DIR:-${HOME}/Virtual Machines.localized}"
VM_BUNDLE="${VM_DIR}/${VM_NAME}.vmwarevm"
VMX_PATH="${VMX_PATH:-${VM_BUNDLE}/${VM_NAME}.vmx}"
VM_CPUS="${VM_CPUS:-4}"
VM_MEMORY_MB="${VM_MEMORY_MB:-8192}"
VM_DISK_GB="${VM_DISK_GB:-80}"
VM_SSH_USER="${VM_SSH_USER:-agent}"
VM_SSH_KEY="${VM_SSH_KEY:-${HOME}/.ssh/omlx_agent_vm_ed25519}"
USER_SSH_PUBLIC_KEY="${USER_SSH_PUBLIC_KEY:-${HOME}/.ssh/id_ed25519.pub}"
VM_SNAPSHOT_NAME="${VM_SNAPSHOT_NAME:-clean-agent-base}"
OBSIDIAN_SHARED_PATH="${OBSIDIAN_SHARED_PATH:-}"
UBUNTU_CLOUD_IMAGE_URL="${UBUNTU_CLOUD_IMAGE_URL:-https://cloud-images.ubuntu.com/releases/resolute/release/ubuntu-26.04-server-cloudimg-arm64.img}"
UBUNTU_CLOUD_IMAGE_SHA256SUMS_URL="${UBUNTU_CLOUD_IMAGE_SHA256SUMS_URL:-https://cloud-images.ubuntu.com/releases/resolute/release/SHA256SUMS}"
OPENAI_API_KEY="${OPENAI_API_KEY:-}"
ANTHROPIC_API_KEY="${ANTHROPIC_API_KEY:-${OPENAI_API_KEY}}"

VMCLI="/Applications/VMware Fusion.app/Contents/Library/vmcli"
VMRUN="${VMRUN_PATH:-/Applications/VMware Fusion.app/Contents/Public/vmrun}"
VDISKMANAGER="/Applications/VMware Fusion.app/Contents/Library/vmware-vdiskmanager"

log() {
  printf '\n==> %s\n' "$*"
}

die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || die "Missing required command: $1"
}

require_file() {
  [[ -e "$1" ]] || die "Missing required path: $1"
}

shell_quote() {
  printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"
}

set_env_value() {
  local key="$1"
  local value="$2"
  local escaped_value
  local tmp

  escaped_value="$(shell_quote "${value}")"
  tmp="$(mktemp)"

  if [[ ! -f "${ENV_FILE}" ]]; then
    cp "${ENV_EXAMPLE}" "${ENV_FILE}"
  fi

  if grep -q "^${key}=" "${ENV_FILE}"; then
    awk -v key="${key}" -v value="${escaped_value}" '
      BEGIN { replaced = 0 }
      $0 ~ "^" key "=" {
        print key "=" value
        replaced = 1
        next
      }
      { print }
      END {
        if (replaced == 0) {
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

set_vmx_value() {
  local key="$1"
  local value="$2"
  local tmp

  tmp="$(mktemp)"

  if grep -q "^${key}[[:space:]]*=" "${VMX_PATH}"; then
    awk -v key="${key}" -v value="${value}" '
      $0 ~ "^" key "[[:space:]]*=" {
        print key " = \"" value "\""
        next
      }
      { print }
    ' "${VMX_PATH}" > "${tmp}"
  else
    cp "${VMX_PATH}" "${tmp}"
    printf '%s = "%s"\n' "${key}" "${value}" >> "${tmp}"
  fi

  mv "${tmp}" "${VMX_PATH}"
}

ensure_ssh_key() {
  log "Preparing SSH key"

  if [[ ! -f "${VM_SSH_KEY}" ]]; then
    mkdir -p "$(dirname "${VM_SSH_KEY}")"
    ssh-keygen -t ed25519 -N "" -C "${VM_NAME}" -f "${VM_SSH_KEY}"
  fi

  require_file "${VM_SSH_KEY}.pub"
}

collect_ssh_public_keys_yaml() {
  local key_files=()
  local candidate
  local key_file

  key_files+=("${VM_SSH_KEY}.pub")

  if [[ -n "${USER_SSH_PUBLIC_KEY}" ]]; then
    key_files+=("${USER_SSH_PUBLIC_KEY}")
  fi

  for candidate in \
    "${HOME}/.ssh/id_ed25519.pub" \
    "${HOME}/.ssh/id_ecdsa.pub" \
    "${HOME}/.ssh/id_rsa.pub" \
    "${HOME}/.ssh/id_ed25519_sk.pub" \
    "${HOME}/.ssh/id_ecdsa_sk.pub"; do
    key_files+=("${candidate}")
  done

  local tmp
  tmp="$(mktemp)"

  for key_file in "${key_files[@]}"; do
    if [[ -f "${key_file}" ]]; then
      sed '/^[[:space:]]*$/d' "${key_file}" >> "${tmp}"
    fi
  done

  if [[ ! -s "${tmp}" ]]; then
    rm -f "${tmp}"
    die "No SSH public keys found. Expected ${VM_SSH_KEY}.pub or a key under ~/.ssh/*.pub."
  fi

  awk '!seen[$0]++ { print "      - " $0 }' "${tmp}"
  rm -f "${tmp}"
}

download_cloud_image() {
  log "Downloading Ubuntu 26.04 LTS ARM64 cloud image"

  mkdir -p "${CACHE_DIR}"

  local image_name
  image_name="$(basename "${UBUNTU_CLOUD_IMAGE_URL}")"
  CLOUD_IMAGE="${CACHE_DIR}/${image_name}"
  SHA256SUMS="${CACHE_DIR}/SHA256SUMS"

  if [[ ! -f "${CLOUD_IMAGE}" ]]; then
    curl -fL "${UBUNTU_CLOUD_IMAGE_URL}" -o "${CLOUD_IMAGE}"
  fi

  curl -fsSL "${UBUNTU_CLOUD_IMAGE_SHA256SUMS_URL}" -o "${SHA256SUMS}"

  (
    cd "${CACHE_DIR}"
    shasum -a 256 --ignore-missing -c "${SHA256SUMS}"
  )
}

create_seed_iso() {
  log "Generating cloud-init seed ISO"

  local seed_dir="${STATE_DIR}/seed-${VM_NAME}"
  SEED_ISO="${VM_BUNDLE}/seed.iso"

  rm -rf "${seed_dir}"
  mkdir -p "${seed_dir}" "${VM_BUNDLE}"

  local public_keys_yaml
  public_keys_yaml="$(collect_ssh_public_keys_yaml)"

  cat > "${seed_dir}/meta-data" <<EOF
instance-id: ${VM_NAME}
local-hostname: ${VM_NAME}
EOF

  cat > "${seed_dir}/user-data" <<EOF
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
  - open-vm-tools
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
  - fuse3
  - open-vm-tools
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
      Description=Map model-host.internal to the VMware NAT gateway
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
  - path: /etc/systemd/system/mnt-obsidian.mount
    permissions: "0644"
    content: |
      [Unit]
      Description=Read-only Obsidian VMware shared folder
      ConditionVirtualization=vmware

      [Mount]
      What=.host:/obsidian
      Where=/mnt/obsidian
      Type=fuse.vmhgfs-fuse
      Options=allow_other,ro

      [Install]
      WantedBy=multi-user.target
  - path: /etc/systemd/system/mnt-obsidian.automount
    permissions: "0644"
    content: |
      [Unit]
      Description=Automount read-only Obsidian VMware shared folder
      ConditionVirtualization=vmware

      [Automount]
      Where=/mnt/obsidian

      [Install]
      WantedBy=multi-user.target
runcmd:
  - mkdir -p /mnt/obsidian
  - systemctl daemon-reload
  - systemctl enable --now model-host-alias.service
  - systemctl enable --now ssh
  - systemctl enable --now mnt-obsidian.automount || true
  - npm install -g pnpm@10 || true
final_message: "omlx-agent Ubuntu VM is ready after \$UPTIME seconds"
EOF

  hdiutil makehybrid -quiet -o "${SEED_ISO}" -iso -joliet -default-volume-name cidata "${seed_dir}"
}

create_vm_shell() {
  log "Creating VMware Fusion VM shell"

  if [[ -e "${VM_BUNDLE}" ]]; then
    die "VM bundle already exists: ${VM_BUNDLE}. Remove it or set VM_NAME/VM_DIR to a new value."
  fi

  mkdir -p "${VM_DIR}"
  "${VMCLI}" VM Create -n "${VM_NAME}" -d "${VM_DIR}" -c arm-ubuntu-64

  [[ -f "${VMX_PATH}" ]] || die "VM was created but VMX was not found: ${VMX_PATH}"
}

install_disk() {
  log "Installing cloud image disk"

  local vm_disk="${VM_BUNDLE}/${VM_NAME}.vmdk"

  qemu-img convert -p -O vmdk "${CLOUD_IMAGE}" "${vm_disk}"
  "${VDISKMANAGER}" -x "${VM_DISK_GB}GB" "${vm_disk}"
}

configure_vmx() {
  log "Configuring VMX"

  set_vmx_value displayName "${VM_NAME}"
  set_vmx_value guestOS arm-ubuntu-64
  set_vmx_value firmware efi
  set_vmx_value memsize "${VM_MEMORY_MB}"
  set_vmx_value numvcpus "${VM_CPUS}"
  set_vmx_value ethernet0.present TRUE
  set_vmx_value ethernet0.connectionType nat
  set_vmx_value ethernet0.virtualDev vmxnet3
  set_vmx_value ethernet0.addressType generated
  set_vmx_value nvme0.present TRUE
  set_vmx_value nvme0:0.present TRUE
  set_vmx_value nvme0:0.fileName "${VM_NAME}.vmdk"
  set_vmx_value nvme0:0.deviceType disk
  set_vmx_value sata0.present TRUE
  set_vmx_value sata0:1.present TRUE
  set_vmx_value sata0:1.fileName seed.iso
  set_vmx_value sata0:1.deviceType cdrom-image
  set_vmx_value sata0:1.startConnected TRUE
  set_vmx_value isolation.tools.copy.disable TRUE
  set_vmx_value isolation.tools.paste.disable TRUE
  set_vmx_value tools.syncTime TRUE
}

configure_shared_folders() {
  if [[ -z "${OBSIDIAN_SHARED_PATH}" ]]; then
    return
  fi

  log "Adding read-only Obsidian shared folder"

  [[ -d "${OBSIDIAN_SHARED_PATH}" ]] || die "OBSIDIAN_SHARED_PATH does not exist: ${OBSIDIAN_SHARED_PATH}"

  "${VMRUN}" -T fusion enableSharedFolders "${VMX_PATH}" || true
  "${VMRUN}" -T fusion addSharedFolder "${VMX_PATH}" obsidian "${OBSIDIAN_SHARED_PATH}" || true
  "${VMRUN}" -T fusion setSharedFolderState "${VMX_PATH}" obsidian "${OBSIDIAN_SHARED_PATH}" readonly
}

write_state() {
  mkdir -p "${STATE_DIR}"
  cat > "${STATE_DIR}/${VM_NAME}.env" <<EOF
VM_NAME=$(shell_quote "${VM_NAME}")
VMX_PATH=$(shell_quote "${VMX_PATH}")
VM_SSH_USER=$(shell_quote "${VM_SSH_USER}")
VM_SSH_KEY=$(shell_quote "${VM_SSH_KEY}")
USER_SSH_PUBLIC_KEY=$(shell_quote "${USER_SSH_PUBLIC_KEY}")
VM_SNAPSHOT_NAME=$(shell_quote "${VM_SNAPSHOT_NAME}")
EOF

  set_env_value VM_NAME "${VM_NAME}"
  set_env_value VM_DIR "${VM_DIR}"
  set_env_value VMX_PATH "${VMX_PATH}"
  set_env_value VM_CPUS "${VM_CPUS}"
  set_env_value VM_MEMORY_MB "${VM_MEMORY_MB}"
  set_env_value VM_DISK_GB "${VM_DISK_GB}"
  set_env_value VM_SSH_USER "${VM_SSH_USER}"
  set_env_value VM_SSH_KEY "${VM_SSH_KEY}"
  set_env_value USER_SSH_PUBLIC_KEY "${USER_SSH_PUBLIC_KEY}"
  set_env_value VM_SNAPSHOT_NAME "${VM_SNAPSHOT_NAME}"
}

main() {
  require_command curl
  require_command qemu-img
  require_command shasum
  require_command hdiutil
  require_command ssh-keygen
  require_file "${VMCLI}"
  require_file "${VMRUN}"
  require_file "${VDISKMANAGER}"

  ensure_ssh_key
  download_cloud_image
  create_vm_shell
  install_disk
  create_seed_iso
  configure_vmx
  configure_shared_folders
  write_state

  log "VM created"
  cat <<EOF
VMX: ${VMX_PATH}
Resources: ${VM_CPUS} vCPU, ${VM_MEMORY_MB} MB RAM, ${VM_DISK_GB} GB disk
SSH user: ${VM_SSH_USER}

Next:
  make vm-start
  make vm-ssh

After first boot and package provisioning:
  make vm-snapshot
EOF
}

main "$@"
