# MLX Isolated Agent Stack

Run local MLX models on an Apple Silicon Mac and connect them to an isolated
agent running in Docker — no cloud, no subscription, fully private.

The host keeps the heavy lifting local: LM Studio downloads models, oMLX
serves them through an OpenAI-compatible API, and an optional RAG service
indexes your documents. The agent runs in Docker with its data visible on the
host filesystem.

**Version:** `0.5.15`

---

## Quickstart

```bash
make bootstrap        # install Homebrew, oMLX, Docker check
make setup            # interactive wizard — 2 questions
make agent-status
make agent-open-dashboard
```

`make setup` asks exactly two things:

1. **Which agent?** Hermes (conversational, Telegram + web dashboard) or
   OpenClaw (browser-use, control UI)
2. **Enable RAG?** Index a local documents folder for semantic search

Everything else — Docker backend, API key, base URLs — is set automatically.

---

## How It Works

```
macOS host
├── LM Studio         model download + catalog
├── oMLX              OpenAI-compatible API  → :8000
└── RAG service       Qdrant + parsers       → :8765  (optional)

Docker containers
├── Hermes / OpenClaw agent
│   ├── model API   http://model-host.internal:8000/v1
│   ├── RAG API     http://rag-host.internal:8765
│   └── Watchers    Obsidian note watcher daemon
└── RAG stack (docker-compose.rag.yml)
    ├── qdrant        vector storage
    ├── tika          document parsing
    ├── docling       advanced PDF/image conversion
    └── rag-api       FastAPI search endpoint
```

Inference stays on the Mac. The agent container is where tools run, files
are written, and packages can be installed.

---

## Model Context Protocol (MCP) Servers

The Hermes agent comes equipped with the following out-of-the-box MCP integrations:

1. **Filesystem**: Grants tools read/write access to `/opt/data/workspace` and `/mnt/obsidian` (your active vault).
2. **Fetch**: Lightweight webpage downloader tool for fetching clean text content.
3. **Git**: Inspect repositories, run diffs, stage and commit changes within the workspace.
4. **Yfinance**: Fetches stock quotes, financial reports, and company metrics from Yahoo Finance.
5. **Puppeteer**: Runs full JS-capable browser automation inside the container. Chromium is automatically installed inside the container on boot, and Puppeteer is pre-configured to use it.
6. **Docker Manager**: Inspect and manage host Docker containers (requires docker socket access).
7. **Brave Search**: Fast web search (requires `BRAVE_API_KEY` in `.env`).
8. **GitHub**: Access pull requests, issues, and codebases (requires `GITHUB_PERSONAL_ACCESS_TOKEN` in `.env`).

---

## Obsidian Note-Driven Workflow

You can interact with the agent directly from within Obsidian without opening Telegram or the Web UI.

### 1. Setup
Set `OBSIDIAN_SHARED_PATH` in `.env` to your Obsidian vault. When the container starts, a background watcher process (`obsidian-watcher.py`) starts inside the container. It polls the `_tasks/` subdirectory of your vault at the frequency configured by `OBSIDIAN_WATCH_INTERVAL_SECONDS` (default: `30` seconds).

### 2. Formulating a Task
Create a new markdown note under the `_tasks/` folder of your vault (e.g. `_tasks/stock-analysis.md`).

For the watcher to pick up your task, it **must contain YAML frontmatter** with `status: pending`. If `status` is missing or set to anything else, the note is ignored, preventing the agent from reading your note while you are still typing it.

Additionally, a **5-second debounce** is applied: the watcher will wait until the note has not been modified for at least 5 seconds before beginning execution.

### 3. Note Format Example
```markdown
---
status: pending
---
Analyze Apple's financial performance for the last quarter and write a brief summary report.
```

When the watcher detects the pending status:
1. It updates the frontmatter to `status: processing` and records `started_at: <timestamp>`.
2. It executes the note's prompt through the Hermes CLI.
3. Once completed:
   - It writes the detailed response/result to `researches/YYYY-MM-DD/task_name.md`.
   - It updates the task note's frontmatter to `status: completed` and adds a reference link to the results: `research_file: researches/YYYY-MM-DD/task_name.md`.
   - It moves the task note from the root `_tasks/` directory to `_tasks/archive/task_name.md` to keep your task list clean and prevent reprocessing.

### 4. Continuous Chats / Multi-turn Conversations
Since archived tasks are ignored by the watcher, to ask follow-up questions:
1. Move the archived note back to the root `_tasks/` directory.
2. Append your next question or prompt at the bottom of the note.
3. Set the frontmatter `status` back to `pending`.

The watcher will detect the note, read the `session_id` inside the frontmatter, and resume the conversation seamlessly.

Example follow-up note (before setting status to pending and moving it back to `_tasks/`):
```markdown
---
completed_at: '2026-05-31T09:38:37Z'
started_at: '2026-05-31T09:38:28Z'
status: pending
session_id: '20260531_093828_ba6c86'
research_file: researches/2026-05-31/apple-analysis.md
---
Analyze Apple's financial performance for the last quarter and write a brief summary report.

Now compare these figures with Microsoft's performance in the same quarter.
```

### 5. Stopping / Aborting Running Researches
If a research task gets stuck, goes into a loop, or you simply want to cancel it:
- Open the active task note in your vault (which will have `status: processing` in the frontmatter).
- Change the `status` field to anything other than `processing` (e.g. `status: stop` or `status: abort`), or delete the task file entirely.
- The background watcher (which polls every 2 seconds during active execution for high responsiveness) will immediately detect this change, terminate the running agent process inside the container, record an abort error, and archive the note to `_tasks/archive/` to keep your workspace clean.

---

## Persistent Data

| What | Where | Variable |
|---|---|---|
| Agent config, skills, workspace | Host: `.runtime/agent/` (default) | `AGENT_DATA_DIR` |
| Agent Obsidian workspace | Host: your folder → `/mnt/obsidian` (rw) | `OBSIDIAN_SHARED_PATH` |
| Documents for RAG indexing | Host: your folder → `/source` (ro, RAG only) | `RAG_SOURCE_PATH` |
| RAG vector index (Qdrant) | **Docker volume** `mlx-isolated-rag_rag-qdrant` | — |
| RAG Python venv | Docker volume `mlx-isolated-rag_rag-api-venv` | — |

Agent data is bind-mounted so files are visible on the host. RAG index and
Python dependencies live in Docker named volumes — they survive `make rag-down`
and are not polluting your project directory.

Set `AGENT_DATA_DIR` to a path outside the project (e.g. `~/.local/share/omlx-agent`)
to keep agent data across `git clean`.

```bash
make agent-data      # show current host path for agent data
make agent-update    # pull latest Hermes or OpenClaw image, restart, keep all data
```

---

## Knowledge Sources

The agent has two distinct ways to access your content:

### `OBSIDIAN_SHARED_PATH` — active workspace

Mounted **read-write** at `/mnt/obsidian` inside the agent container.
The agent can read notes, create new files, and follow links here using its
file tools directly.

### `RAG_SOURCE_PATH` — passive document library

Mounted **read-only** into the **RAG container only** — the agent container
does **not** get a mount to this folder.
PDFs, Word files, spreadsheets, scanned images, and notes are indexed into
Qdrant and made searchable through the `rag-search` tool.

This separation means the agent always retrieves knowledge through semantic
search rather than browsing raw files, which prevents confusion when the
documents library is large or contains binary files.

Both variables can point to the **same folder** (wizard default) or to
separate directories. Separate paths are recommended when your documents
library is large or distinct from your active notes.

```bash
# .env — the two lines that matter
OBSIDIAN_SHARED_PATH=/Users/you/vault       # agent reads/writes here
RAG_SOURCE_PATH=/Users/you/documents        # RAG indexes here, agent cannot browse
```

```bash
make rag-index-status   # indexing progress
make rag-search QUERY="what did we decide about X?"
make rag-status
# Wipe index and reindex from scratch:
# docker volume rm mlx-isolated-rag_rag-qdrant && make rag-up && make rag-index
```

---

## Models

```bash
make models-search          # search LM Studio catalog
make models-list            # list downloaded models
make model-select           # pick active model interactively
make model-start-bg         # start oMLX in background
make models-doctor          # scan for incomplete downloads
make models-prune-incomplete
```

---

## Agent Commands

```bash
make agent-start            # start the configured agent stack
make agent-stop
make agent-restart
make agent-status           # show running containers + ports
make agent-shell            # open a shell inside the agent container
make agent-open-dashboard   # open the web dashboard / control UI
make agent-update           # pull latest image, restart, keep data
make agent-data             # show host data directory
```

---

## Telegram Bot with Local Whisper (STT)

Add to `.env` before running `make setup`, or enter interactively in the wizard:

```bash
TELEGRAM_BOT_TOKEN=...       # from @BotFather
TELEGRAM_USER_ID=123456789   # from @userinfobot
```

The Hermes bot runs entirely inside the container. It features **100% offline Whisper transcription** for voice messages. When you send a voice message to the Telegram bot, it uses the container's preloaded faster-whisper library and local `base` weights to transcribe your speech and run it as a prompt.

The Hermes web dashboard is available at `http://127.0.0.1:9120` by default
as soon as the container starts — no SSH tunnel needed.

Remote access via Cloudflare Tunnel is opt-in. See [docs/REMOTE_ACCESS.md](docs/REMOTE_ACCESS.md).

---

## Configuration

All settings live in `.env`. The file is created from `.env.example` on first
run. The top section — **START HERE** — lists every variable you might want to
change. Everything else has sensible defaults.

Key variables:

| Variable | Default | Purpose |
|---|---|---|
| `AGENT_DATA_DIR` | `.runtime/agent` | Agent data on host |
| `OBSIDIAN_SHARED_PATH` | _(empty)_ | Notes folder for agent / Obsidian watcher |
| `OBSIDIAN_WATCH_INTERVAL_SECONDS` | `30` | Obsidian tasks folder scan frequency |
| `RAG_SOURCE_PATH` | _(same as above)_ | Documents folder for RAG |
| `MODEL_DIR` | `~/.lmstudio/models` | LM Studio model storage |
| `DOCKER_DASHBOARD_PORT` | `9120` | Dashboard port on host |
| `HERMES_IMAGE` | `nousresearch/hermes-agent:latest` | Agent image |

---

## Safety

- `.env` is git-ignored and holds all local secrets.
- Model files and RAG indexes stay local — nothing is uploaded.
- oMLX uses Bearer auth for local API access.
- The Docker agent container is isolated; it cannot reach host services
  unless explicitly exposed through `host.docker.internal`.
- `FORCE=1 make clean-all` removes runtime state but preserves `.env`,
  model downloads, and source documents.

---

## Release and CI

```bash
make ci-check                              # shell syntax + unit tests
make release-check
make matrix-e2e                            # full sandbox matrix (optional)
```

Provider roadmap: [docs/PROVIDERS.md](docs/PROVIDERS.md).
