# omlx_to_client

Apple Silicon local-agent stack:

- LM Studio finds and downloads MLX models.
- oMLX serves those models on the macOS host through an OpenAI-compatible API.
- Hermes runs in an isolated Multipass VM or Docker container and connects back to the host model server.

Version: `0.2.0`

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

Multipass Ubuntu 24.04 ARM64 VM
  Hermes    -> http://model-host.internal:8000/v1

Docker Desktop container
  Hermes    -> http://host.docker.internal:8000/v1
```

Hermes is fully supported. OpenClaw is recognized as a planned adapter stub and does not run end-to-end yet.

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
make model-select
make model-start-bg
make model-stop-bg
make model-check
```

`make models-sync` reads the LM Studio catalog, symlinks compatible MLX safetensors LLMs into `.runtime/omlx-models`, and writes `MODEL_DIR`/`MODEL_NAME` into `.env`.

The selected model becomes Hermes' default. All models served by oMLX are also written into Hermes as the `local-omlx` provider so they are available in Hermes model selection and Dashboard flows where supported.

## Multipass VM

```bash
make vm-create
make agent-start
make vm-ssh
```

Defaults:

- Ubuntu Server 24.04 LTS ARM64
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
make agent-status
make agent-logs
make agent-shell
make agent-open-dashboard
```

The commands read `AGENT_RUNTIME` and `SANDBOX_BACKEND` from `.env`. When Telegram is configured, `make agent-start` stops the previous backend gateway before starting the selected one, so switching between Docker and Multipass does not leave two Telegram polling sessions fighting for the same bot token.

## Docker Sandbox

Docker uses the official `nousresearch/hermes-agent:latest` image and connects to host oMLX through Docker Desktop networking. This repository does not build or publish a custom Docker image.

```bash
SANDBOX_BACKEND=docker make agent-start
SANDBOX_BACKEND=docker make agent-status
SANDBOX_BACKEND=docker make agent-shell
```

Docker uses named volumes for `/opt/data` and `/opt/data/workspace`. If `OBSIDIAN_SHARED_PATH` is set, it is bind-mounted to `OBSIDIAN_GUEST_PATH`.

Do not install GUI Obsidian in Docker. Mount an Obsidian vault as files and let Hermes skills/tools work with the notes directly. Telegram, Discord, and similar integrations should be configured through Hermes gateway tokens and skills rather than desktop apps.

## Clean Sandbox Reset

```bash
make clean-all
FORCE=1 make clean-all
```

`clean-all` stops oMLX, Telegram gateways, dashboards, Docker, and Multipass; then deletes Docker sandbox volumes and the Multipass VM. It preserves `.env`, API keys, Telegram credentials, host dependencies, and LM Studio model files.

## Telegram Gateway

Create a Telegram bot with `@BotFather`, then put the token in `.env`:

```bash
TELEGRAM_BOT_TOKEN=...
TELEGRAM_USER_ID=123456789
TELEGRAM_ALLOWED_USERS=123456789
```

Get your numeric Telegram user ID from `@userinfobot`. `TELEGRAM_USER_ID` is a local convenience shortcut; scripts map it into Hermes allowlists when `TELEGRAM_ALLOWED_USERS` and `GATEWAY_ALLOWED_USERS` are empty.

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

Public internet access should be opt-in through Tailscale Serve or Cloudflare Tunnel + Access. Do not expose the dashboard by raw public port forwarding.

See [docs/REMOTE_ACCESS.md](docs/REMOTE_ACCESS.md).

## Release Check

```bash
make release-check
SKIP_VM_E2E=1 SKIP_DOCKER_E2E=1 make release-check
```

Release check runs shell syntax, mocked shared-folder tests, host doctor/model API checks, VM e2e, real shared-folder smoke, Docker e2e, and daemon status checks.
