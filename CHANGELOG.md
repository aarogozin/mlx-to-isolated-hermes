# Changelog

## 0.5.5 — 2026-05-30

Preserved TUI preferences and dashboard chat activation:

- **TUI Preference Preservation**: Updated `setup.sh` to only set `HERMES_DASHBOARD_TUI` to `"0"` by default if it is not already defined in the configuration, preventing subsequent setup runs from disabling the Chat tab.

## 0.5.4 — 2026-05-30

Dynamic command hints and Hermes WebSocket loopback gate fixes:

- **Dynamic Command Hints**: Updated `setup.sh` to print `omlx-agent` CLI command suggestions instead of developer `make` targets when executed under the Go wrapper (using the `OMLX_CLI` environment variable).
- **Hermes Dashboard Chat Fix**: Added a patch for WebSocket token comparisons inside the Hermes container in both `dashboard-control.sh` and `telegram-control.sh`, bypassing token verification under localhost/insecure connections to restore the Chat component on the dashboard.

## 0.5.3 — 2026-05-30

Global distribution packaging, configuration isolation, and OpenClaw privilege updates:

- **Go CLI Wrapper (`omlx-agent`)**: Compiled Go command-line tool that embeds all static assets (scripts, templates, Compose files) and extracts them on launch or version mismatch to `~/.omlx/dist/`, providing a single executable that works globally.
- **Dynamic Configuration Isolation (`OMLX_HOME`)**: Updated all shell scripts and Python components to support `OMLX_HOME` environment override, concentrating writeable state, logs, model catalogs, and the `.env` file in the user's home directory (`~/.omlx/`) to keep code and configuration directories separate.
- **OpenClaw Sandbox Privilege Elevation**: Updated the OpenClaw sandbox in `openclaw-control.sh` to run as `root` (`--user root`) with mapped `HOME=/home/node` for volume configuration persistence. Removed container capability drops and privilege locks (`no-new-privileges`) to enable the agent to install system-level Debian packages and dependencies dynamically.
- **Homebrew Formula and CI Release Automation**: Added a Homebrew Formula stub in `Formula/omlx-agent.rb` and configured `release.yml` GitHub Actions workflow to build Apple Silicon (`darwin/arm64`) executables, publish release assets, and automatically push updated formula definitions to the custom `homebrew-tap` repository.

## 0.5.2 — 2026-05-30

Pure Docker transition, RAG optimizations, and setup wizard hardening:

- **Robust Port & Process Resolution**: Fixed the macOS `lsof` newline parsing bug for IPv4/IPv6 port bindings. Implemented automatic Docker container stopping and host process termination when target ports are occupied.
- **macOS launchd Integration**: Integrated automatic detection, unloading, and disabling of launchd-managed host processes (e.g. host-level openclaw gateway) during setup conflict resolution to prevent automatic process restart loops.
- **Docker Auto-Recreation**: Configured Docker creation scripts to *always* stop and remove existing containers on start/create. This guarantees that `.env` updates, ports, and mounts are always freshly applied and resolves stale exited/created container states.
- **RAG Settings & Splitter Optimization**: Standardized default chunk token size to 400 and overlap to 50. Enabled `tei` semantic embeddings as the default backend. Optimized RAG text splitting in `rag-container-api.py` to divide text semantically by paragraph and sentence boundaries.
- **ARM64 TEI Pulling Fix**: Configured the RAG controller to dynamically map `cpu-latest` to `cpu-arm64-latest` for TEI on Apple Silicon arm64 hosts, avoiding image pull errors from outdated `.env` settings.
- **Pure Docker Purge**: Removed all legacy Multipass VM control scripts, Makefile targets, and VM smoke checks in CI.

## 0.5.1 — 2026-05-29

Hotfix for Hermes Docker Dashboard Chat:

- Fix dashboard chat session showing `[session ended]` and `events feed disconnected` inside Docker by patching the WebSocket loopback gate check to allow connections when `--insecure` is set.
- Add `/opt/hermes/bin` and `/opt/hermes/.venv/bin` to the container's `PATH` to ensure the `hermes` executable can be spawned by the PTY.

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
