# MLX Isolated Agent Stack

Run local MLX models on an Apple Silicon Mac and connect them to an isolated
agent running in Docker — no cloud, no subscription, fully private.

The host keeps the heavy lifting local: LM Studio downloads models, oMLX
serves them through an OpenAI-compatible API, and an optional RAG service
indexes your documents. The agent runs in Docker with its data visible on the
host filesystem.

**Version:** `0.5.1`

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
│   └── RAG API     http://rag-host.internal:8765
└── RAG stack (docker-compose.rag.yml)
    ├── qdrant        vector storage
    ├── tika          document parsing
    ├── docling       advanced PDF/image conversion
    └── rag-api       FastAPI search endpoint
```

Inference stays on the Mac. The agent container is where tools run, files
are written, and packages can be installed.

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

## Telegram and Dashboard

Add to `.env` before running `make setup`, or enter interactively in the wizard:

```bash
TELEGRAM_BOT_TOKEN=...       # from @BotFather
TELEGRAM_USER_ID=123456789   # from @userinfobot
```

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
| `OBSIDIAN_SHARED_PATH` | _(empty)_ | Notes folder for agent |
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
SKIP_VM_E2E=1 SKIP_DOCKER_E2E=1 make release-check
make matrix-e2e                            # full sandbox matrix (optional)
```

Provider roadmap: [docs/PROVIDERS.md](docs/PROVIDERS.md).
