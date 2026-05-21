# omlx_to_client

Apple Silicon local-agent stack:

- LM Studio finds and downloads MLX models.
- oMLX serves those models on the macOS host through an OpenAI-compatible API.
- Hermes runs in an isolated sandbox and connects back to the host model server.

Version: `0.1.0`

## Quickstart

```bash
make bootstrap
make models-search
make models-list
make vm-create
make e2e-ready
make vm-ssh
hermes
```

If LM Studio was just installed, launch it once before rerunning `make bootstrap`; this initializes the `lms` CLI.

## Architecture

The stable 0.1.0 path is:

```text
macOS host
  LM Studio -> downloaded MLX model catalog
  oMLX      -> http://0.0.0.0:8000/v1 with Bearer auth

Multipass Ubuntu 24.04 ARM64 VM
  Hermes    -> http://model-host.internal:8000/v1
```

Docker preview uses the same host oMLX server:

```text
Docker Desktop container
  Hermes    -> http://host.docker.internal:8000/v1
```

Inference stays on macOS. The VM/container runs tools, package installs, documents, notes, browsers, and agent workflows.

## Bootstrap

```bash
make bootstrap
make doctor
```

Bootstrap installs or verifies:

- Homebrew
- LM Studio and `lms`
- oMLX
- Docker Desktop
- Multipass
- core CLI tools: `git`, `jq`, `yq`, `curl`, `wget`, `coreutils`, `uv`, `pipx`, `node@24`, `pnpm`

The script creates `.env` from `.env.example` and generates a local API key for oMLX auth. `.env` is ignored by git.

VMware Fusion remains a manual fallback path. It is not required for the default Multipass flow.

## Models

```bash
make models-search       # opens LM Studio model search for MLX models
make models-list         # prints downloaded LM Studio models
make models-sync         # symlinks compatible MLX safetensors models for oMLX
make model-select        # choose the default local model for Hermes/oMLX
make model-start-bg      # starts persistent launchd-backed oMLX
make model-stop-bg       # stops the launchd-backed oMLX service
make model-check         # verifies /v1/models with Bearer auth
```

`make models-sync` reads the LM Studio catalog, symlinks compatible MLX safetensors LLMs into `.runtime/omlx-models`, and writes `MODEL_DIR`/`MODEL_NAME` into `.env`.

Choose a model interactively:

```bash
make model-select
```

Or non-interactively:

```bash
MODEL=qwen3.6-27b-ud-mlx make model-select
```

The selected model becomes Hermes' default, while all models served by oMLX are written into Hermes as the `local-omlx` provider so they show up in `hermes model` and Dashboard model selection.

## Stable VM Sandbox

```bash
make vm-create
make e2e-ready
make vm-ssh
hermes
```

The VM is Ubuntu Server 24.04 LTS ARM64 through Multipass. Ubuntu 24.04 is the default because Hermes browser tooling currently works there on arm64; newer Ubuntu images may break Playwright support.

Defaults:

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
```

Multipass can only snapshot stopped instances, so the release workflow is stop -> snapshot -> start.

If `OBSIDIAN_SHARED_PATH` is set, the VM mounts that folder at `/mnt/obsidian`.

## Docker Preview

Docker support is a preview backend in 0.1.0. It runs Hermes in a custom image based on the official Hermes Agent Docker image and connects to host oMLX through Docker Desktop networking.

```bash
make docker-build
make docker-create
make docker-start
make docker-shell
```

Inside the container:

```bash
hermes
```

End-to-end Docker smoke:

```bash
make docker-e2e
```

Reset Docker preview state:

```bash
make docker-stop
make docker-reset
DOCKER_RESET_DATA=1 make docker-reset   # also removes Hermes data/workspace volumes
```

Docker uses named volumes:

- `/opt/data` for Hermes config/state
- `/home/agent/workspace` for agent workspace
- optional `/mnt/obsidian` if `OBSIDIAN_SHARED_PATH` is set

Do not install GUI Obsidian in Docker. Mount an Obsidian vault as files and let Hermes skills/tools work with the notes directly. Telegram, Discord, and similar integrations should be configured through Hermes gateway tokens and skills rather than desktop apps.

## Telegram Gateway

Create a Telegram bot with `@BotFather`, then put the token in `.env`:

```bash
TELEGRAM_BOT_TOKEN=...
```

Recommended for immediate access without pairing:

```bash
TELEGRAM_USER_ID=123456789
TELEGRAM_ALLOWED_USERS=123456789
```

Get your numeric Telegram user ID from `@userinfobot`. `TELEGRAM_USER_ID` is a local convenience shortcut; the scripts map it into the Hermes allowlist when `TELEGRAM_ALLOWED_USERS` and `GATEWAY_ALLOWED_USERS` are empty. If no allowlist is set, Hermes will require pairing: send a message to the bot, list pending requests, then approve the code.

VM target, the default:

```bash
make telegram-start
make telegram-status
make telegram-pairing
CODE=<pairing-code> make telegram-approve
make telegram-logs
make telegram-doctor
```

Docker preview target:

```bash
TELEGRAM_TARGET=docker make telegram-start
TELEGRAM_TARGET=docker make telegram-status
```

Supported `.env` knobs:

- `TELEGRAM_BOT_TOKEN`
- `TELEGRAM_USER_ID`
- `TELEGRAM_ALLOWED_USERS`
- `TELEGRAM_GROUP_ALLOWED_USERS`
- `TELEGRAM_GROUP_ALLOWED_CHATS`
- `GATEWAY_ALLOWED_USERS`
- `GATEWAY_ALLOW_ALL_USERS=false`
- `TELEGRAM_TARGET=vm`

Telegram Bot API polling allows only one active gateway per bot token. If you see `Conflict: terminated by other getUpdates request`, run:

```bash
make telegram-doctor
make telegram-stop-host
make telegram-restart
```

## Hermes Dashboard

Hermes Dashboard runs inside the sandbox. The default VM path exposes it only on your Mac through a local SSH tunnel:

```bash
make dashboard-start
make dashboard-status
make dashboard-open
```

Default URL:

```text
http://127.0.0.1:9119
```

Stop it with:

```bash
make dashboard-stop
```

Docker preview is available with:

```bash
DASHBOARD_TARGET=docker make dashboard-start
```

Dashboard knobs:

- `DASHBOARD_TARGET=vm`
- `HERMES_DASHBOARD_PORT=9119`
- `HERMES_DASHBOARD_TUI=1`

Remote access:

- Use Tailscale Serve for private HTTPS access from your own devices.
- Use Cloudflare Tunnel plus Cloudflare Access for a public HTTPS hostname.
- Avoid exposing Dashboard directly with a plain reverse proxy unless you have a separate authentication layer.

Commands:

```bash
make dashboard-tailscale-start
make dashboard-cloudflare-start
```

See [Remote Dashboard Access](docs/REMOTE_ACCESS.md).

## Release Check

```bash
make release-check
```

This runs shell syntax checks, release metadata checks, secret/runtime scans, host doctor, model API check, VM e2e smoke, and Docker e2e smoke.

To skip expensive smoke tests during local iteration:

```bash
SKIP_VM_E2E=1 SKIP_DOCKER_E2E=1 make release-check
```

## Security Notes

- oMLX binds to `0.0.0.0` so VM/Docker sandboxes can reach it.
- Bearer auth is required; bootstrap generates the key into `.env`.
- `.env`, `.runtime/`, `.vm/`, logs, and local caches are ignored by git.
- Telegram tokens and user IDs stay in `.env`; do not copy them into tracked docs or scripts.
- Hermes Dashboard defaults to `127.0.0.1` access. Do not bind it to a public interface because it can expose agent configuration and API keys.
- Treat mounted notes and documents as sensitive. For untrusted agents, prefer a copied/synced knowledge snapshot over a live writable mount.
