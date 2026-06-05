# Changelog

## 0.5.25 — 2026-06-05

Add unified `make update` command to update all stack components in one step:

- **`scripts/update.sh`** — New orchestrator script that updates each active component in order:
  1. Git repo self-update (`git pull --ff-only`, non-fatal on local changes)
  2. oMLX via Homebrew (`brew upgrade jundot/omlx/omlx`, skipped if `MODEL_BACKEND` is not `omlx`)
  3. Agent container — `docker pull` + recreate (Hermes or OpenClaw depending on `AGENT_RUNTIME`)
  4. RAG Docker stack — `docker compose pull` for all services + restart if running (skipped if `RAG_ENABLED=0`)
  5. LM Studio note (cannot be automated — macOS app)
- **Dry-run mode** (`--dry-run` / `make update-dry-run`) — shows exactly what would happen without modifying anything.
- **Per-component skip flags** — `--skip-git`, `--skip-omlx`, `--skip-agent`, `--skip-rag` for selective updates.
- **Non-fatal steps** — a failure in any single component does not abort the rest; a summary table at the end shows what succeeded, warned, failed, or was skipped.
- **Image change detection** — shows before/after image digest so you can see what actually changed vs. what was already current.
- **Makefile targets** — `make update` and `make update-dry-run` added with help entries.
- **README** — new "Updating the Stack" section documenting all update options.

## 0.5.24 — 2026-06-04

Comprehensive hardening and bug fix pass across the Docker RAG service, container startup scripts, and setup wizard:

### 🔴 Critical fixes

- **RAG Concurrency Race Condition** (`rag-container-api.py`): Added a `threading.Lock` (`_index_lock`) to prevent the background file-watcher thread and the `POST /index` HTTP endpoint from running `index_documents()` simultaneously. Concurrent runs would corrupt the manifest JSON and produce non-deterministic Qdrant upserts. Watcher now skips its trigger if indexing is already in progress; the API returns HTTP 409 instead.
- **Silent Document Drop on Embed Failure** (`rag-container-api.py`): If `embed()` returned fewer vectors than expected (e.g. TEI returned an empty batch silently), documents were recorded with `chunks: 0` but *without* `skipped: True`, causing `sha256` to match on the next run and the document to be permanently invisible to search. Fixed by validating `len(vectors) == len(chunks)` and raising `RuntimeError` on mismatch so the doc is properly flagged for retry.
- **Silent TEI Fallback** (`rag-container-api.py`): `except Exception: pass` in `tei_embeddings()` was swallowing primary-endpoint errors. Now logs a `Warning:` message before falling back to `/embed`, making network issues visible in container logs.

### 🟠 High-priority fixes

- **Dead if/else in Chromium Install** (`docker-control.sh`, `telegram-control.sh`): Both branches of the inner `if/else` ran identical `apt-get install chromium` commands — the condition was meaningless dead code. Collapsed to a single unconditional install when the configured path is missing.
- **Missing Login Shell in Container Provisioning** (`docker-create.sh`): The `-l` (login shell) flag was accidentally removed from the `write_data_volume` heredoc runner, meaning `/etc/profile` was not sourced. With `set -euo pipefail` active, any tool relying on the login PATH (e.g. `uv` in `/usr/local/bin`) would produce `command not found` and abort container provisioning silently. Restored `-l`.
- **O(n) Manifest Writes During Indexing** (`rag-container-api.py`): The condition `if changed > 0` was always true after the first file, causing a full manifest JSON write on *every* subsequent file iteration (even skipped ones). With thousands of notes this meant thousands of unnecessary disk writes. Fixed to write manifest only when the *current* file was actually modified.
- **Post-Index Fingerprint TOCTOU** (`rag-container-api.py`): The file-watcher was setting `previous = current` using a fingerprint computed *before* `index_documents()` ran. Files that changed *during* a long indexing pass were silently missed. Fingerprint is now recomputed *after* indexing completes.
- **Multiple Qdrant Client Instances** (`rag-container-api.py`): `ensure_collection()` was creating its own `QdrantClient` connection instead of reusing the one already open in `index_documents()`. Now accepts the client as a parameter, eliminating the extra connection.

### 🟡 Medium fixes

- **TEI Service Missing CPU Limit** (`docker-compose.rag.yml`): The `tei` (Text Embeddings Inference) service had no `cpus:` limit while every other CPU-heavy service (`docling`, `playwright`, `firecrawl-api`) was constrained. Added `cpus: '4.0'` to prevent full core saturation on Apple Silicon.
- **Misleading Error Message for Missing Volume Variable** (`docker-compose.rag.yml`): The volume bind for the RAG source directory used `${RAG_SOURCE_MOUNT}` but the error message instructed users to set `RAG_SOURCE_PATH` — a different, unrelated variable. Fixed message to name the correct variable.
- **Hidden docker-create.sh Errors in Telegram Gateway** (`telegram-control.sh`): `docker-create.sh` output was piped to `/dev/null`, masking any container provisioning failures and causing `docker_start_and_patch()` to run against a non-existent container with cryptic follow-up errors. Removed the redirect.

### 🟢 Low-priority fixes

- **Hardcoded Developer Path in Setup Wizard** (`setup.sh`): The Syncthing default sync path was hardcoded as `/Users/tonyr/hermes` — the original developer's home directory. Changed to portable `${HOME}/hermes`.
- **`.env` Wipe Risk in `repair_corrupted_env`** (`setup.sh`): If all lines in `.env` matched the corruption pattern, `grep -v` returned an empty file and `|| true` silently allowed overwriting `.env` with nothing, wiping all user configuration. Added a file-size guard: repair is skipped with a warning if the filtered output is empty.


## 0.5.23 — 2026-06-01

Fix setup wizard prompt UI output leakage and add configuration auto-healing:

- **Stderr Redirection for Prompt UIs**: Redirected all prompt question prints and secret entry echo lines inside `setup.sh` to `stderr` (`>&2`). This stops `$(prompt ...)` command substitutions from capturing ANSI escape color codes and text prompts, ensuring only the raw user input is assigned to variables.
- **Auto-Healing Env Routine**: Added a `repair_corrupted_env` routine executing on setup start. It automatically checks `.env` and cleans up any corrupted variables containing raw ANSI escape sequences (e.g. `\x1b` or `[1m` patterns), restoring the config file to a healthy state.

## 0.5.22 — 2026-06-01

Automate self-hosted n8n owner credentials provisioning:

- **Automated Owner Account Creation**: Configured the self-hosted n8n service in `docker-compose.rag.yml` using `N8N_INSTANCE_OWNER_*` variables to automatically provision a local admin account on start. Bypasses the first-time setup wizard and avoids credentials lockout. Defaults to `admin@local.agent` / `admin123`.

## 0.5.21 — 2026-06-01

Improve setup wizard quality of life, n8n API Key automation, and automated validation tests:

- **Non-Interactive Bypass Logic**: Enabled the setup wizard (`scripts/setup.sh`) to run fully non-interactively when options (e.g. agent runtime, LLM model, RAG, Syncthing, n8n) are already configured in the `.env` file. Bypasses terminal prompts and automatically selects safe non-blocking choices for port and stack conflict resolution.
- **Dry-Run Validation Support**: Added a `--dry-run` (`-d`) flag to `setup.sh` to parse and validate configurations in CI or staging environments without spinning up Docker containers or macOS model server daemons.
- **n8n API Key Setup Prompt**: Enhanced the setup wizard to detect if n8n is enabled and prompt the user to paste their generated n8n API key, falling back to a warning in non-interactive mode.
- **Automated Validation Test Suite**: Introduced `scripts/test-wizard.sh` verifying all configurations, validation errors, and dry-run completions, hooked directly into local checks (`make ci-check`) and GitHub Actions CI workflow.

## 0.5.20 — 2026-06-01

Integrate optional self-hosted n8n workflow engine and harden configurations:

- **Optional n8n Integration**: Deployed n8n under the `n8n` compose profile in `docker-compose.rag.yml`. Configured database persistence using SQLite inside a named Docker volume (`rag-n8n-data`), avoiding resource overhead from external databases.
- **Granular Setup Wizard**: Updated the interactive setup wizard (`scripts/setup.sh`) to allow users to selectively enable/disable n8n during first-time configuration, keeping n8n fully optional and disabled by default.
- **Security Hardening**: Locked down the local n8n container port (`5678`) to the loopback interface (`127.0.0.1`) and disabled telemetry diagnostics data sharing (`N8N_DIAGNOSTICS_ENABLED=false`) inside the container environment block.
- **n8n MCP Guide**: Wrote a detailed guide (`docs/n8n_mcp_guide.md`) mapping out trigger settings (MCP Server Trigger node) and showing how to connect n8n workflows to the AI agent.

## 0.5.19 — 2026-05-31

Automate folder configuration inside Syncthing:

- **Automated Sync Folder Configuration**: Introduced a Python orchestration helper `scripts/syncthing-auto-config.py` executed automatically upon stack startup. It extracts the container's Syncthing API key and local Device ID, queries the REST API, and automatically adds the `hermes` sync folder mapped to `/var/syncthing/Sync` (without requiring manual user setup in the GUI).
- **Marker Directory (.stfolder) Auto-creation**: Added automatic creation of the `.stfolder` marker directory inside the target sync directory on the host to prevent Syncthing from failing with "folder marker missing" errors.

## 0.5.18 — 2026-05-31

Integrate Syncthing peer-to-peer file synchronization and local Firecrawl self-hosted crawling:

- **Syncthing P2P File Sync**: Added Syncthing under the `syncthing` compose profile to enable local-first, serverless folder synchronization between the host's `/Users/tonyr/hermes` path and user devices (e.g. iPhone, other computers). Exposes standard sync protocol and local discovery ports.
- **Self-Hosted Local Firecrawl**: Integrated a local Firecrawl API, Playwright microservice, and ephemeral Redis, Postgres, and RabbitMQ dependencies into the Docker stack to allow local web scraping without external API keys or cloud dependencies.
- **RAG Indexing Optimizations & Bugfixes**:
  - Truncated text inputs passed to the Hugging Face text-embeddings-inference (TEI) service to 10,000 characters to prevent `413 Payload Too Large` errors on massive files.
  - Corrected environment variable casing bugs (`override_syncthing_enabled_set` -> `OVERRIDE_SYNCTHING_ENABLED_SET`) inside `rag-control.sh` that previously caused unbound variable startup crashes.

## 0.5.17 — 2026-05-31

Fix MCP server configurations and environment isolation issues:

- **yfinance Pydantic ValidationError Fix**: Resolved validation errors in the `yfinance` MCP server (`openmarkets`) by executing the server subprocess via `env -i -C /tmp HOME=/tmp` to isolate it from container environment variables and prevent loading `/opt/data/.env`.
- **Puppeteer Headless Evasion**: Configured the environment variable `DOCKER_CONTAINER: "true"` inside the Puppeteer server `env` config block to force Chromium into headless and no-sandbox mode for unprivileged execution.
- **Python MCP command correction**: Upgraded default server command templates in `docker-create.sh` to use `uvx` instead of `npx` for Python-based servers (`fetch`, `git`, `docker-manager`, and `yfinance`).

## 0.5.16 — 2026-05-31

Fix Chromium path resolution and configuration merging for browser tools:

- **Config Merging Correction**: Fixed config merging logic in `docker-create.sh` which was discarding the `env` block (specifically `PUPPETEER_EXECUTABLE_PATH`) for pre-existing `puppeteer` configurations in `config.yaml`.
- **System Browser Integration**: Configured `AGENT_BROWSER_EXECUTABLE_PATH="/usr/bin/chromium"` inside the container to point Playwright and the built-in browser engine (`browser_navigate`) to the system Chromium binary.
- **State Refresh on Installation**: Added s6 service restarts (`main-hermes` and `gateway-default`) after automated Chromium installation to reload the environment and clear cached browser check flags.

## 0.5.15 — 2026-05-31

Fix automated Chromium container installation and add task abort mechanism:

- **Chromium Footprint and Stability**: Added `--no-install-recommends` during automated chromium packages setup inside `docker-control.sh` and `telegram-control.sh` to prevent OOM/limit issues that previously caused the container's boot script execution to be terminated.
- **Asynchronous & Interruptible Watcher**: Re-engineered the note-driven watcher `obsidian-watcher.py` using non-blocking asynchronous process spawning and active PID tracking.
- **Task Abort Flow**: Users can now stop running research agents on the fly by changing the note's status from `processing` to anything else (or deleting the file). The watcher will automatically terminate the process, record the abort error, and archive the note.
- **Dynamic Polling**: Increased polling frequency to every 2 seconds when a task is running (for instant response to cancellations) while maintaining the resource-saving 30-second interval when idle.

## 0.5.14 — 2026-05-31

Refined Obsidian note task layout, daily research partitioning, and archiving:

- **Daily Research Partitioning**: Saves detailed research notes inside date-partitioned folders (`researches/YYYY-MM-DD/task_name.md`) instead of cluttering the root researches directory.
- **Task Archiving**: Automatically moves completed or failed task files from the root `_tasks/` directory to `_tasks/archive/` to keep the active tasks folder clean, while updating the metadata reference with `status: completed` and a `research_file` link.
- **Follow-up Workflow**: Updated documentation on how to resume chat threads by returning the archived note to `_tasks/` and setting `status: pending` (maintaining the `session_id`).

## 0.5.13 — 2026-05-31

Refined Obsidian Watcher strictness:

- **Strict Status Guard**: Restrained the note-driven watcher to ONLY process files that have `status: pending` explicitly declared in the frontmatter. Notes without this metadata are completely ignored.
- **Auto-Debounce**: Added a 5-second modification debounce. The watcher will only pick up a pending task if it has been idle (not saved/modified) for at least 5 seconds, preventing execution of incomplete notes while the user is still actively typing.
- **Redundant Voice Reversion**: Removed the host-side audio recording script and Makefile target since Telegram voice transcribing is sufficient.
- **Fixed boot check**: Wrapped `command -v chromium` check in a shell execution (`sh -c`) to prevent always running `apt-get` on container boot.

## 0.5.12 — 2026-05-31

Integrated Puppeteer and Obsidian Watcher configurations:

- **Configurable Obsidian Polling Interval**: Added `OBSIDIAN_WATCH_INTERVAL_SECONDS` (default: 30 seconds) to `.env` and modified the background watcher to parse container `.env` secrets at startup to adjust the folder scanning frequency, minimizing host CPU overhead when idle.
- **Automated Chromium / Puppeteer Setup**: Configured the boot logic to automatically check and install system `chromium` via `apt-get` (using `uv` for python dependencies) and injected `PUPPETEER_EXECUTABLE_PATH` to enable the Puppeteer MCP server out-of-the-box.

## 0.5.11 — 2026-05-31

Integrated Obsidian Note-Driven Workflow:

- **Background Watcher**: Added `obsidian-watcher.py` inside the container to continuously monitor the designated Obsidian vault folder (`_tasks/`) for new or pending notes (`status: pending` or not set).
- **Oneshot Execution & Session Resumes**: Auto-executes notes using the Hermes CLI in oneshot mode, automatically resuming existing multi-turn chat sessions if `session` or `session_id` is defined in frontmatter.
- **Bi-directional Sync**: Appends agent responses directly back to the Obsidian note and updates frontmatter metadata (`status: completed` and timestamps) to prevent reprocessing.

## 0.5.10 — 2026-05-31

Integrated local offline Whisper speech-to-text (STT) support:

- **Hugging Face Model Cache Persistence**: Declared the `HF_HOME=/opt/data/.cache/huggingface` environment variable to save model weights under the persistent host directory.
- **Pre-loaded dependencies**: Configured the container boot scripts (`docker-control.sh` and `telegram-control.sh`) to pre-install `faster-whisper` and pre-download the Whisper `base` model weights, enabling zero-latency and 100% offline transcribing out-of-the-box.

## 0.5.9 — 2026-05-31

Integrated Yahoo Finance, Puppeteer, and Docker MCP servers:

- **Docker Socket Mount**: Added `/var/run/docker.sock` volume mount to allow the agent to inspect and manage Docker containers on the host.
- **Financial & Developer MCPs**: Configured out-of-the-box support for `yfinance` (stock quotes & company data), `puppeteer` (advanced JS scraping), and `docker-manager` (host Docker management).

## 0.5.8 — 2026-05-30

Integrated Model Context Protocol (MCP) servers and config merging:

- **MCP Servers Integration**: Added default config setups for `brave-search`, `github`, `filesystem`, `fetch`, and `git` MCP servers inside the Hermes container.
- **Auto-Activation of MCPs**: Optional MCP servers (`brave-search` and `github`) are auto-enabled based on the presence of `BRAVE_API_KEY` and `GITHUB_PERSONAL_ACCESS_TOKEN` in the environment.
- **Config Persistence**: Replaced the destructive raw overwrite of `config.yaml` with a Python-based merging script that preserves user-customized settings upon container recreation.

## 0.5.7 — 2026-05-30

Removed Playwright browser dependency in favor of MCP Brave Search:

- **Browser Removal**: Reverted persistent Playwright configuration and deleted browser binaries to optimize container footprint, replacing web queries with lightweight Brave Search API.

## 0.5.6 — 2026-05-30

Integrated HERMES_YOLO_MODE support:

- **YOLO Mode Support**: Propagated `HERMES_YOLO_MODE` environment variable from the host to the Docker sandbox container, allowing users to run the Hermes agent autonomously without tool execution prompts.

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
