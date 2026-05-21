# Changelog

## Unreleased

- Add `scripts/setup.sh` interactive wizard (`make setup`): guides through backend selection (Multipass / VMware Fusion / Docker), credentials, model selection, and full stack deployment with Dashboard URL and Telegram verification at the end.
- Add `scripts/vm-common.sh` shared VM guest helpers (`require_vm_ready`, `get_vm_ip`, `vm_exec`, `vm_exec_root`, `vm_exec_root_env`, `vm_transfer`) supporting both Multipass and VMware Fusion engines.
- Refactor `agents-install.sh`, `hermes-sync-models.sh`, `e2e-ready.sh`, `dashboard-control.sh`, `telegram-control.sh` to use `vm-common.sh` — VMware Fusion engine now fully supported end-to-end.
- Fix `doctor.sh` to check only the active VM engine (Multipass or VMware), reporting the other as inactive rather than failed.
- Fix `release-check.sh` to validate VERSION as a semver string instead of comparing against a hardcoded constant.
- Add `MODEL_DEFAULT_STRATEGY` env var to `models-sync-omlx.sh` (`largest-tool` default, `smallest-tool`, `largest`, `first`).
- Add `make vm-status` and `make vm-list-snapshots` targets.
- Improve `docker/Dockerfile`: OCI labels, `HEALTHCHECK`, `WORKDIR`, build args (`VERSION`, `BUILD_DATE`, `VCS_REF`).
- Update `scripts/docker-build.sh` to use `docker buildx`, inject OCI build args, and support `GHCR_IMAGE` / `DOCKER_PUSH=1` for pushing to GitHub Container Registry.
- Add `.github/workflows/docker.yml`: CI pipeline that lints shell scripts, builds the ARM64 Docker image with QEMU on GitHub-hosted runners, pushes to `ghcr.io/aarogozin/mlx-to-isolated-hermes`, and smoke-tests the published image.
- Add `.github/workflows/release.yml`: automatically creates a GitHub Release from `CHANGELOG.md` when a `v*` tag is pushed.

## 0.1.0 — 2026-05-21

Initial public release.

- Bootstrap Apple Silicon macOS hosts with Homebrew, LM Studio, oMLX, Docker Desktop, Multipass, and core CLI tools.
- Use LM Studio for MLX model discovery/download and oMLX as the default OpenAI-compatible host runtime.
- Create a Multipass Ubuntu 24.04 ARM64 VM sandbox with SSH keys, optional Obsidian vault mount, and `model-host.internal` host routing.
- Install and configure Hermes in the VM against the selected host model.
- Add launchd-backed persistent oMLX host serving.
- Add Docker preview sandbox using a custom image based on the official Hermes Agent image.
- Add release verification scripts and documentation for the 0.1.0 GitHub release.
