# Changelog

## Unreleased

## 0.2.0 — 2026-05-22

Release hardening for the cleaned-up Multipass/Docker stack.

- Make Multipass the only supported VM backend and remove VMware Fusion from active scripts, docs, diagnostics, and env defaults.
- Use the official `nousresearch/hermes-agent:latest` Docker image directly; remove the custom Dockerfile, Docker build command, and GHCR image workflow.
- Shrink the public `Makefile` to the user-facing setup, model, agent, VM, shared-folder, and release commands.
- Add `shared-mounts-check` and wire it into `release-check` so local release validation proves the shared folder can be synced and read from the sandbox.
- Add GitHub CI for shell syntax and mocked shared-folder command-flow tests without requiring nested Multipass on hosted runners.
- Harden Multipass Hermes installation by downloading the GitHub archive instead of relying on a large `git clone` inside the VM.
- Improve Telegram/dashboard daemon handoff so switching between Docker and Multipass does not leave duplicate Telegram polling sessions.

## 0.1.0 — 2026-05-21

Initial public release.

- Bootstrap Apple Silicon macOS hosts with Homebrew, LM Studio, oMLX, Docker Desktop, Multipass, and core CLI tools.
- Use LM Studio for MLX model discovery/download and oMLX as the default OpenAI-compatible host runtime.
- Create a Multipass Ubuntu 24.04 ARM64 VM sandbox with SSH keys, optional Obsidian vault sync, and `model-host.internal` host routing.
- Install and configure Hermes in the VM against the selected host model.
- Add launchd-backed persistent oMLX host serving.
- Add Docker preview sandbox for Hermes.
- Add release verification scripts and documentation for the 0.1.0 GitHub release.
