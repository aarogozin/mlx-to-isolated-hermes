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

В wizard также появится опциональный шаг RAG: подключить `OBSIDIAN_SHARED_PATH`, проиндексировать заметки, запустить host RAG service и проверить `rag-search` уже внутри выбранного Docker/Multipass окружения.

## Ручной Multipass smoke

```bash
make doctor
make models-list
make models-doctor
make model-select
make model-start-bg
make rag-doctor
make vm-create
make agent-start
make agent-status
make shared-mounts-check
```

Если `OBSIDIAN_SHARED_PATH` не задан, `shared-mounts-check` честно пропустит проверку.

## RAG smoke

Если `OBSIDIAN_SHARED_PATH` указывает на Obsidian vault или папку с текстами:

```bash
make rag-install
make rag-index
make rag-start
make rag-search QUERY="проверочный запрос"
make rag-status
```

Агенты получают `rag-search` внутри Docker/Multipass и ходят к host-сервису через `rag-host.internal:8765`.

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

`release-check` делает shell/Python syntax, mock-тест shared-folder логики, RAG unit tests, host doctor/model check, optional RAG smoke, VM e2e, shared-folder smoke, Docker e2e, Telegram/dashboard status.

## Local matrix e2e

```bash
make matrix-e2e
MATRIX_MODES="hermes/docker" MATRIX_CLEAN_MODE=none make matrix-e2e
MATRIX_RAG_SOURCE_MODE=env make matrix-e2e
```

Matrix e2e локально прогоняет Hermes/OpenClaw в Docker/Multipass с одним общим host RAG. По умолчанию делает `FORCE=1 clean-all` один раз, не трогает `.env`, модели и твой реальный Obsidian/RAG source, а для проверки создает synthetic vault/index внутри `.runtime/matrix-e2e/<run>/`. Telegram отключается только для дочерних процессов. Для проверки реального vault используй `MATRIX_RAG_SOURCE_MODE=env`.

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
make rag-index
make rag-search QUERY="..."
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
  matrix-e2e.sh            local four-mode sandbox/RAG smoke
  shared-mounts.sh         shared folder sync/status
  shared-mounts-check.sh   real shared folder smoke
  test-shared-mounts-mock.sh
  rag.py                   host LanceDB RAG index/service
  rag-control.sh           RAG install/index/service lifecycle
  rag-search-bridge.sh     sandbox CLI bridge to host RAG
.github/workflows/
  ci.yml                   shell/python + mocked shared-folder + RAG tests
  release.yml              GitHub Release from tags
```
