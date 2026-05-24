# Quick Test Guide — omlx_to_client

Быстрый прогон стека на Apple Silicon Mac.

## Интерактивный путь

```bash
make bootstrap
make setup
make agent-status
make agent-open-dashboard
```

`make setup` выбирает runtime (`hermes` или `openclaw`), backend (`multipass` или `docker`), Telegram credentials из `.env`, локальную MLX-модель из LM Studio и запускает стек.

## Ручной Multipass smoke

```bash
make doctor
make models-list
make models-doctor
make model-select
make model-start-bg
make vm-create
make agent-start
make agent-status
make shared-mounts-check
```

Если `OBSIDIAN_SHARED_PATH` не задан, `shared-mounts-check` честно пропустит проверку.

## Docker smoke

Docker использует официальные образы: `nousresearch/hermes-agent:latest` для Hermes и `ghcr.io/openclaw/openclaw:latest` для OpenClaw. Локальный image в этом проекте не собирается.

```bash
SANDBOX_BACKEND=docker make agent-start
SANDBOX_BACKEND=docker make agent-status
SANDBOX_BACKEND=docker make agent-shell
```

Низкоуровневый Docker e2e остался script-командой:

```bash
./scripts/docker-e2e.sh
```

## Release gate

```bash
make release-check
SKIP_VM_E2E=1 SKIP_DOCKER_E2E=1 make release-check
```

`release-check` делает shell syntax, mock-тест shared-folder логики, host doctor/model check, VM e2e, shared-folder smoke, Docker e2e, Telegram/dashboard status.

## Полезные команды

```bash
make clean-all
make agent-pause
AGENT_RUNTIME=openclaw SANDBOX_BACKEND=multipass make agent-switch
AGENT_RUNTIME=hermes SANDBOX_BACKEND=multipass make agent-switch
make agent-open-dashboard
make dashboard-remote-start
make dashboard-remote-stop
make model-start-bg
make model-stop-bg
make shared-mounts-sync
make shared-mounts-status
make vm-snapshot
make vm-reset
```

## Структура

```text
scripts/
  setup.sh                 main interactive entrypoint
  bootstrap-macos.sh       host dependency bootstrap
  vm-common.sh             Multipass guest helpers
  vm-create-multipass.sh   Ubuntu 24.04 ARM64 VM create
  agent-control.sh         unified Hermes/OpenClaw control
  openclaw-control.sh      OpenClaw Docker/Multipass runtime control
  shared-mounts.sh         shared folder sync/status
  shared-mounts-check.sh   real shared folder smoke
  test-shared-mounts-mock.sh
.github/workflows/
  ci.yml                   shell + mocked shared-folder tests
  release.yml              GitHub Release from tags
```
