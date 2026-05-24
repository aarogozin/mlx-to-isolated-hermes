# omlx_to_client

Apple Silicon local-agent stack:

- LM Studio finds and downloads MLX models.
- oMLX serves those models on the macOS host through an OpenAI-compatible API.
- Hermes or OpenClaw runs in an isolated Multipass VM or Docker container and connects back to the host model server.

Version: `0.3.0`

## Quickstart

```bash
make bootstrap
make setup
make agent-status
make agent-open-dashboard
```

If LM Studio was just installed, launch it once before rerunning `make bootstrap`; this initializes the `lms` CLI.

## Architecture

Inference stays on macOS. The sandbox runs tools, package installs, documents, notes, browser tooling, and agent workflows.

```text
macOS host
  LM Studio -> downloaded MLX model catalog
  oMLX      -> http://0.0.0.0:8000/v1 with Bearer auth

Multipass Ubuntu 24.04 ARM64 VMs
  Hermes   -> HERMES_VM_NAME   -> http://model-host.internal:8000/v1
  OpenClaw -> OPENCLAW_VM_NAME -> http://model-host.internal:8000/v1

Docker Desktop container
  Hermes/OpenClaw -> http://host.docker.internal:8000/v1
```

Hermes and OpenClaw are both exposed through the same `agent-*` commands. Only one agent stack should run at a time. Interactive setup can pause the active stack and switch; direct `make agent-start` remains conservative unless `AGENT_CONFLICT_POLICY=pause` is set.

## Bootstrap

```bash
make bootstrap
make doctor
```

Bootstrap installs or verifies Homebrew, LM Studio/`lms`, oMLX, Docker Desktop, Multipass, and core CLI tools. It creates `.env` from `.env.example` and generates a local API key for oMLX auth. `.env` is ignored by git.

## Models

```bash
make models-search
make models-list
make models-sync
make models-doctor
make models-prune-incomplete
make model-select
make model-start-bg
make model-stop-bg
make model-check
```

`make models-sync` reads the LM Studio catalog, symlinks compatible MLX safetensors LLMs into `.runtime/omlx-models`, and writes `MODEL_DIR`/`MODEL_NAME` into `.env`.

The selected model becomes the active agent's default. All inference still goes through host oMLX.

`make models-doctor` scans LM Studio, `.runtime/omlx-models`, and Ollama model storage for broken symlinks, temporary download artifacts, zero-byte blobs, invalid/truncated safetensors or GGUF files, and Ollama manifests with missing blobs. `make models-prune-incomplete` removes only safely identified incomplete artifacts older than `MODEL_CLEAN_MIN_AGE_HOURS` (`1` by default).

## Multipass VM

```bash
make vm-create
make agent-start
make vm-ssh
```

Defaults:

- Ubuntu Server 24.04 LTS ARM64
- Hermes VM: `HERMES_VM_NAME=omlx-agent-ubuntu`
- OpenClaw VM: `OPENCLAW_VM_NAME=omlx-openclaw-ubuntu`
- `VM_CPUS=4`
- `VM_MEMORY=8G`
- `VM_DISK=80G`
- `VM_SSH_USER=agent`
- generated SSH key: `~/.ssh/omlx_agent_vm_ed25519`
- current user public key: `~/.ssh/id_ed25519.pub`

Snapshot/reset:

```bash
make vm-stop
make vm-snapshot
make vm-start
make vm-reset
make vm-destroy
```

`make vm-*` uses the selected `AGENT_RUNTIME`; override it when needed:

```bash
AGENT_RUNTIME=openclaw make vm-status
AGENT_RUNTIME=hermes make vm-status
```

Multipass can only snapshot stopped instances, so the release workflow is stop -> snapshot -> start.

## Shared Folder

If `OBSIDIAN_SHARED_PATH` is set, Multipass syncs that folder to `OBSIDIAN_GUEST_PATH` (`/mnt/obsidian` by default). The default `MULTIPASS_SHARED_MODE=transfer` copies a snapshot and avoids brittle SSHFS behavior.

```bash
make shared-mounts-sync
make shared-mounts-status
make shared-mounts-check
```

`shared-mounts-check` writes a temporary marker on the host, syncs the folder, verifies identical content inside the sandbox, and cleans up. Docker uses a live bind mount and also verifies write-back from the container.

Agent startup treats the shared folder as optional by default (`SHARED_MOUNTS_REQUIRED=0`). Set `SHARED_MOUNTS_REQUIRED=1` when startup should fail unless the folder is available.

## Agent Commands

Use these when you do not want to think about whether the active sandbox is Docker or Multipass:

```bash
make agent-start
make agent-stop
make agent-restart
make agent-pause
make agent-switch
make agent-status
make agent-logs
make agent-shell
make agent-open-dashboard
```

The commands read `AGENT_RUNTIME` and `SANDBOX_BACKEND` from `.env`.

Supported combinations:

- `AGENT_RUNTIME=hermes SANDBOX_BACKEND=multipass`
- `AGENT_RUNTIME=hermes SANDBOX_BACKEND=docker`
- `AGENT_RUNTIME=openclaw SANDBOX_BACKEND=multipass`
- `AGENT_RUNTIME=openclaw SANDBOX_BACKEND=docker`

`make agent-start` refuses to start a different combination while another agent is running. `make setup` prompts to pause the active stack and continue. For non-interactive switching:

```bash
AGENT_RUNTIME=openclaw SANDBOX_BACKEND=multipass make agent-switch
AGENT_RUNTIME=hermes SANDBOX_BACKEND=multipass make agent-switch
```

`make agent-switch` also saves the requested runtime/backend back into `.env`, so later `make vm-*` and `make agent-*` commands point at the same stack. `make agent-pause` stops the selected agent and stops its VM when the backend is Multipass. `FORCE=1 make clean-all` is the full destructive sandbox reset.

For OpenClaw, `make agent-start`, `make setup`, and `make agent-open-dashboard` print both the local Control UI URL and the one-time bootstrap auth URL:

```text
http://127.0.0.1:18789/#token=<OPENCLAW_GATEWAY_TOKEN>
```

The token is generated into local `.env` and is intentionally ignored by git.

## Docker Sandbox

Docker uses official upstream images and connects to host oMLX through Docker Desktop networking. This repository does not build or publish a custom Docker image.

```bash
SANDBOX_BACKEND=docker make agent-start
SANDBOX_BACKEND=docker make agent-status
SANDBOX_BACKEND=docker make agent-shell
```

Hermes uses `nousresearch/hermes-agent:latest`. OpenClaw uses `ghcr.io/openclaw/openclaw:latest` and exposes the Control UI on `OPENCLAW_CONTROL_PORT` (`18789` by default).

Docker uses named volumes for agent state/workspace. If `OBSIDIAN_SHARED_PATH` is set, it is bind-mounted to `OBSIDIAN_GUEST_PATH`.

Do not install GUI Obsidian in Docker. Mount an Obsidian vault as files and let agent tools work with the notes directly. Telegram, Discord, and similar integrations should be configured through the agent gateway rather than desktop apps.

## Clean Sandbox Reset

```bash
make clean-all
FORCE=1 make clean-all
```

`clean-all` stops oMLX, Telegram gateways, dashboards/control UIs, Docker, and Multipass; then deletes both runtime VMs and Hermes/OpenClaw Docker sandbox volumes. It preserves `.env`, API keys, Telegram credentials, host dependencies, and LM Studio model files.

## Telegram Gateway

Create a Telegram bot with `@BotFather`, then put the token in `.env`:

```bash
TELEGRAM_BOT_TOKEN=...
TELEGRAM_USER_ID=123456789
TELEGRAM_ALLOWED_USERS=123456789
```

Get your numeric Telegram user ID from `@userinfobot`. `TELEGRAM_USER_ID` is a local convenience shortcut; scripts map it into allowlists when `TELEGRAM_ALLOWED_USERS` and runtime-specific allowlists are empty.

Start the active backend daemon:

```bash
make agent-start
make agent-logs
```

## Dashboard Access

Local dashboard:

```bash
make agent-open-dashboard
```

Remote access is opt-in. Tailscale is disabled by default; set `TAILSCALE_ENABLED=1` or provide `TAILSCALE_AUTH_KEY` if you want VMs to join your tailnet during creation. For the host dashboard/control UI:

```bash
make dashboard-remote-start
make dashboard-remote-status
make dashboard-remote-stop
```

`TAILSCALE_SERVE_MODE=serve` is private to your tailnet. `TAILSCALE_SERVE_MODE=funnel` is public internet exposure and should be used only deliberately. Do not expose the dashboard by raw public port forwarding.

See [docs/REMOTE_ACCESS.md](docs/REMOTE_ACCESS.md).

## Release Check

```bash
make release-check
SKIP_VM_E2E=1 SKIP_DOCKER_E2E=1 make release-check
```

Release check runs shell syntax, mocked shared-folder tests, host doctor/model API checks, VM e2e, real shared-folder smoke, Docker e2e, and daemon status checks.
