# Changelog

## Unreleased

## 0.4.0 — 2026-05-25

Local RAG preview for Obsidian-backed agent knowledge and personal documents.

- Add host-side LanceDB RAG index and FastAPI search service under `.runtime/rag`.
- Add manual incremental indexing for Obsidian/text files with metadata, headings, tags, and wikilinks.
- Add workbook-aware spreadsheet indexing for Excel/ODS files with sheet, range, row, formula, and comment metadata.
- Add PDF and image indexing with needed-only OCR fallback for scanned documents.
- Install OCR support by default through Tesseract plus local `.runtime/tessdata` language files.
- Add `rag-*` Make targets for install, index, search, service lifecycle, and diagnostics.
- Add interactive `make setup` RAG opt-in with host indexing and sandbox `rag-search` smoke verification.
- Add setup preflight handling for already-running agent stacks before deployment.
- Add local `make matrix-e2e` to smoke Hermes/OpenClaw across Docker/Multipass with shared host RAG.
- Expose `rag-host.internal` to Multipass and Docker sandboxes, parallel to `model-host.internal`.
- Install a small `rag-search` bridge into Hermes/OpenClaw environments so agents can query local notes explicitly.
- Add English-only docs, RAG unit tests, OCR smoke tests, and release-check hooks.

## 0.3.0 — 2026-05-24

OpenClaw runtime hardening and model artifact cleanup.

- Make OpenClaw deploy end-to-end in Docker and Multipass using the current official CLI/entrypoint flow.
- Split Multipass VM state by runtime: Hermes keeps `omlx-agent-ubuntu`, OpenClaw uses `omlx-openclaw-ubuntu`.
- Add conflict policies plus `agent-pause` and `agent-switch` so setup can pause the active stack and continue.
- Add single-agent conflict detection across Hermes/OpenClaw and Docker/Multipass so Telegram polling is not started twice.
- Harden OpenClaw Docker volumes, auth-secret storage, gateway token setup, and Control UI ports.
- Harden OpenClaw Multipass install/start by adding the npm user prefix to PATH and using `openclaw gateway run`.
- Restore `model-host.internal` automatically on VM start/reset and OpenClaw startup so switched VMs can always reach host oMLX.
- Make Tailscale optional by default, add remote dashboard helpers, and print OpenClaw Control UI auth URLs with `OPENCLAW_GATEWAY_TOKEN`.
- Add `models-doctor` and `models-prune-incomplete` to scan LM Studio, oMLX runtime symlinks, and Ollama storage for incomplete downloads.
- Add timeouts to shared-folder smoke cleanup so Multipass mount cleanup cannot hang release checks.
- Update docs for the four supported agent/runtime combinations and model cleanup workflow.

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
