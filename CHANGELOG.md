# Changelog

## 0.5.0 — 2026-05-29

Docker-first agent setup with host-visible persistent data and separated knowledge sources.

- Make Docker the default and only wizard-presented backend. Multipass VM
  remains functional but must be selected manually via `SANDBOX_BACKEND=multipass`.
- Add `AGENT_DATA_DIR` bind-mount: agent config, skills, and workspace are now
  visible on the host at `.runtime/agent/` by default. Set an absolute path to
  keep data outside the project directory.
- Simplify `make setup` wizard to two questions: agent choice (Hermes/OpenClaw)
  and RAG (yes/no). Backend, API key, and base URLs are set automatically.
- Separate `RAG_SOURCE_PATH` (documents library, RAG-only, read-only mount) from
  `OBSIDIAN_SHARED_PATH` (agent workspace, read-write mount at `/mnt/obsidian`).
  The agent no longer gets direct access to the documents folder.
- Add `make agent-update` — pull latest image and restart without losing data.
- Add `make agent-data` — show agent data directory on the host.
- Add `make rag-index-status` — show RAG indexing progress.
- Fix RAG connectivity check to verify `/health` endpoint instead of requiring
  search results (indexing is async and takes time on first run).
- Fix Qdrant payload size limit error (400 Bad Request) during document indexing by writing chunks to Qdrant incrementally (per-document) and batching upserts in blocks of 100 points.
- Add support for `HERMES_DASHBOARD_INSECURE` environment variable to bypass auth/security checks on the Hermes dashboard.
- Auto-detect Docker platform (arm64/amd64) instead of hardcoding `linux/arm64`.
- Restructure `.env.example` with a **START HERE** block for host paths and API
  keys, followed by sections for each subsystem. VM variables moved to the bottom
  as legacy/deprecated.
- Rewrite README: Docker-first architecture, persistent data table, knowledge
  sources documentation, clean two-question quickstart.

## 0.4.0 — 2026-05-25

Docker-first local RAG preview for Obsidian-backed agent knowledge and personal documents.

- Add Docker Compose RAG using prebuilt Docling, Tika, Qdrant, TEI, and Python images.
- Add local indexing for Obsidian/text files with metadata and source paths.
- Add Office, PDF, image, and spreadsheet extraction through containerized parser services.
- Add needed-only OCR fallback for scanned documents without installing host Tesseract by default.
- Add `rag-*` Make targets for install, index, search, service lifecycle, and diagnostics.
- Add interactive `make setup` RAG opt-in with Docker indexing and sandbox `rag-search` smoke verification.
- Add setup preflight handling for already-running agent stacks before deployment.
- Add local `make matrix-e2e` to smoke Hermes/OpenClaw across Docker/Multipass with shared Docker RAG.
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
- Add remote dashboard helpers and print OpenClaw Control UI auth URLs with `OPENCLAW_GATEWAY_TOKEN`.
- Add `models-doctor` and `models-prune-incomplete` to scan LM Studio, oMLX runtime symlinks, and Ollama storage for incomplete downloads.
- Add timeouts to shared-folder smoke cleanup so Multipass mount cleanup cannot hang release checks.
- Update docs for the four supported agent/runtime combinations and model cleanup workflow.

## 0.2.0 — 2026-05-22

Release hardening for the cleaned-up Multipass/Docker stack.

- Make Multipass the supported VM backend and simplify active scripts, docs, diagnostics, and env defaults around that path.
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
