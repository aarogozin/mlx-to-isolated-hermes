#!/usr/bin/env bash
# scripts/hermes-sync-models.sh — Sync oMLX model catalog into the Hermes agent VM.
# Downloads the model list from the running oMLX API, merges it with the
# LM Studio catalog, and writes the Hermes config.yaml + .env inside the VM.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
ENV_FILE="${PROJECT_ROOT}/.env"
CATALOG="${PROJECT_ROOT}/.runtime/lmstudio-models.json"

OVERRIDE_VM_NAME="${VM_NAME:-}"

if [[ -f "${ENV_FILE}" ]]; then
  set -a
  # shellcheck disable=SC1090
  source "${ENV_FILE}"
  set +a
fi

# shellcheck source=vm-common.sh
source "${SCRIPT_DIR}/vm-common.sh"

VM_NAME="${OVERRIDE_VM_NAME:-${HERMES_VM_NAME:-${VM_NAME:-omlx-agent-ubuntu}}}"
VM_SSH_USER="${VM_SSH_USER:-agent}"
OPENAI_BASE_URL="${OPENAI_BASE_URL:-http://localhost:8000/v1}"
OPENAI_BASE_URL_GUEST="${OPENAI_BASE_URL_GUEST:-http://model-host.internal:8000/v1}"
OPENAI_API_KEY="${OPENAI_API_KEY:-}"
MODEL_NAME="${MODEL_NAME:-}"

[[ -n "${OPENAI_API_KEY}" ]] || {
  echo "ERROR: OPENAI_API_KEY missing." >&2
  exit 1
}

# ── Check that the VM is available; skip gracefully if not ────────────────────
if ! require_vm_ready 2>/dev/null; then
  echo "warn VM not ready; skipped Hermes model sync" >&2
  exit 0
fi

# ── Fetch model list from the running oMLX API ────────────────────────────────
tmp_models="$(mktemp)"
tmp_catalog="$(mktemp)"
trap 'rm -f "${tmp_models}" "${tmp_catalog}"' EXIT

curl -fsS --max-time 5 \
  -H "Authorization: Bearer ${OPENAI_API_KEY}" \
  "${OPENAI_BASE_URL%/}/models" \
  | jq '.data | map({id})' > "${tmp_models}"

if [[ -s "${CATALOG}" ]]; then
  cp "${CATALOG}" "${tmp_catalog}"
else
  printf '[]\n' > "${tmp_catalog}"
fi

if [[ -z "${MODEL_NAME}" ]]; then
  MODEL_NAME="$(jq -r '.[0].id // empty' "${tmp_models}")"
fi

# ── Transfer catalog files to the guest ──────────────────────────────────────
vm_transfer "${tmp_models}"  /tmp/omlx-api-models.json
vm_transfer "${tmp_catalog}" /tmp/omlx-lmstudio-catalog.json

# ── Run the Python config writer as root on the guest ────────────────────────
vm_exec_root_env \
  AGENT_USER="${VM_SSH_USER}" \
  OPENAI_BASE_URL="${OPENAI_BASE_URL_GUEST}" \
  OPENAI_API_KEY="${OPENAI_API_KEY}" \
  MODEL_NAME="${MODEL_NAME}" \
  -- "python3 -" <<'PY'
import json
import os
import pwd
import grp
from pathlib import Path

import yaml

agent_user = os.environ["AGENT_USER"]
home       = Path(f"/home/{agent_user}")
config_path = home / ".hermes" / "config.yaml"
env_path    = home / ".hermes" / ".env"
models_path = Path("/tmp/omlx-api-models.json")
catalog_path = Path("/tmp/omlx-lmstudio-catalog.json")

config_path.parent.mkdir(parents=True, exist_ok=True)

api_models = json.loads(models_path.read_text()) if models_path.exists() else []
catalog    = json.loads(catalog_path.read_text()) if catalog_path.exists() else []
catalog_by_id = {item.get("id"): item for item in catalog if item.get("id")}

models = {}
for item in api_models:
    model_id = item.get("id")
    if not model_id:
        continue
    meta = catalog_by_id.get(model_id, {})
    entry = {}
    ctx = meta.get("maxContextLength")
    if isinstance(ctx, int) and ctx > 0:
        entry["context_length"] = ctx
    models[model_id] = entry

selected = os.environ.get("MODEL_NAME") or (next(iter(models), "local-model"))
base_url = os.environ["OPENAI_BASE_URL"]
api_key  = os.environ["OPENAI_API_KEY"]

if config_path.exists():
    data = yaml.safe_load(config_path.read_text()) or {}
    if not isinstance(data, dict):
        data = {}
else:
    data = {}

data["model"] = {
    "provider": "local-omlx",
    "default":  selected,
}

providers = data.get("providers")
if not isinstance(providers, dict):
    providers = {}
data["providers"] = providers
providers["local-omlx"] = {
    "name":            "Local oMLX",
    "base_url":        base_url,
    "api_key":         api_key,
    "default_model":   selected,
    "transport":       "chat_completions",
    "discover_models": True,
    "models":          models,
}

terminal = data.get("terminal")
if not isinstance(terminal, dict):
    terminal = {}
data["terminal"] = terminal
terminal.setdefault("backend", "local")
terminal.setdefault("cwd", f"/home/{agent_user}/workspace")

config_path.write_text(yaml.safe_dump(data, sort_keys=False), encoding="utf-8")

lines = []
if env_path.exists():
    for line in env_path.read_text().splitlines():
        if not line.startswith("MODEL_NAME="):
            lines.append(line)
lines.append(f"MODEL_NAME={selected}")
env_path.write_text("\n".join(lines).rstrip() + "\n", encoding="utf-8")

uid = pwd.getpwnam(agent_user).pw_uid
gid = grp.getgrnam(agent_user).gr_gid
os.chown(config_path, uid, gid)
os.chown(env_path,    uid, gid)

print(f"Synced Hermes provider local-omlx with {len(models)} model(s); default={selected}")
PY
