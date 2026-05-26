# Quick Test Guide — omlx_to_client

Fast local smoke tests for an Apple Silicon Mac.

## Interactive Path

```bash
make bootstrap
make setup
make agent-status
make agent-open-dashboard
```

`make setup` chooses the agent runtime (`hermes` or `openclaw`), sandbox backend (`multipass` or `docker`), Telegram credentials from `.env`, a local MLX model from LM Studio, and then starts the selected stack.

The wizard also checks for already-running agent stacks. If one is active, it lets you reuse it, pause/restart it, clean all sandbox state, continue anyway for advanced debugging, or abort.

The optional RAG step connects `OBSIDIAN_SHARED_PATH`, indexes the source folder, starts the host RAG service and watcher, then verifies `rag-search` from inside the selected Docker/Multipass environment.

## Multipass Smoke

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

If `OBSIDIAN_SHARED_PATH` is unset, `shared-mounts-check` skips with a clear message.

## RAG Smoke

If `OBSIDIAN_SHARED_PATH` points to an Obsidian vault or another local documents folder:

```bash
make rag-install
make rag-index
make rag-sync
make rag-start
make rag-watch-start
make rag-search QUERY="release smoke"
make rag-status
```

Agents receive a `rag-search` bridge inside Docker/Multipass and connect to the host service through `rag-host.internal:8765`. With `RAG_AUTO_INDEX=1`, `make rag-start` also runs a lightweight watcher that picks up source changes after a short polling delay.

PDFs, images, spreadsheets, and text-like files are indexed by default. OCR is enabled as a capability, but `RAG_OCR_MODE=needed` means normal selectable-text PDFs do not invoke OCR. `make rag-install` installs Tesseract and downloads only the requested OCR language data into `.runtime/tessdata`.

## Docker Smoke

Docker uses official upstream images: `nousresearch/hermes-agent:latest` for Hermes and `ghcr.io/openclaw/openclaw:latest` for OpenClaw. This project does not build a local agent image.

```bash
SANDBOX_BACKEND=docker make agent-start
SANDBOX_BACKEND=docker make agent-status
SANDBOX_BACKEND=docker make agent-shell
```

Low-level Docker e2e remains available as a script command:

```bash
./scripts/docker-e2e.sh
```

## Release Gate

```bash
make release-check
SKIP_VM_E2E=1 SKIP_DOCKER_E2E=1 make release-check
```

`release-check` runs shell/Python syntax checks, mocked shared-folder tests, RAG unit tests, host doctor/model checks, optional RAG smoke, VM e2e, shared-folder smoke, Docker e2e, daemon status checks, and an English-only tracked-text scan.

## Local Matrix E2E

```bash
make matrix-e2e
MATRIX_MODES="hermes/docker" MATRIX_CLEAN_MODE=none make matrix-e2e
MATRIX_RAG_SOURCE_MODE=env make matrix-e2e
```

`matrix-e2e` locally checks Hermes/OpenClaw across Docker/Multipass against one shared host RAG service. By default it runs `FORCE=1 clean-all` once, preserves `.env`, model stores, and your real Obsidian/RAG source, creates a synthetic vault/index inside `.runtime/matrix-e2e/<run>/`, and disables Telegram only for child processes. Use `MATRIX_RAG_SOURCE_MODE=env` to test your configured `OBSIDIAN_SHARED_PATH`.

## Useful Commands

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
make rag-sync
make rag-search QUERY="..."
make shared-mounts-status
make vm-snapshot
make vm-reset
```

## Project Layout

```text
scripts/
  setup.sh                 main interactive entrypoint
  bootstrap-macos.sh       host dependency bootstrap
  vm-common.sh             Multipass guest helpers
  vm-create-multipass.sh   Ubuntu 24.04 ARM64 VM creation
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
