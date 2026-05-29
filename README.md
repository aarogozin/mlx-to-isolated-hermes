# MLX Isolated Agent Stack

Run local MLX models on an Apple Silicon Mac and connect them to an isolated
agent running in Docker — no cloud, no subscription, fully private.

The host keeps the heavy lifting local: LM Studio downloads models, oMLX
serves them through an OpenAI-compatible API, and an optional RAG service
indexes your documents. The agent runs in Docker with its data visible on the
host filesystem.

**Version:** `0.5.0`

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

All agent state is stored on the host and bind-mounted into the container,
so nothing is lost across restarts or image updates.

| What | Host path | Variable |
|---|---|---|
| Agent config, skills, workspace | `.runtime/agent/` (default) | `AGENT_DATA_DIR` |
| Obsidian vault (agent workspace) | your folder | `OBSIDIAN_SHARED_PATH` |
| Documents for RAG | your folder | `RAG_SOURCE_PATH` |
| RAG vector index | Docker volume `mlx-isolated-rag_qdrant` | — |

Set `AGENT_DATA_DIR` to a path outside the project (e.g. `~/.local/share/omlx-agent`)
if you want agent data to survive `git clean`.

```bash
make agent-data      # show current agent data directory on host
make agent-update    # pull latest image and restart without losing data
```

---

## Knowledge Sources

The stack supports two distinct knowledge paths:

**`OBSIDIAN_SHARED_PATH`** — agent workspace, mounted **read-write** at
`/mnt/obsidian` inside the container. The agent can read existing notes and
create new ones here directly via file tools.

**`RAG_SOURCE_PATH`** — documents library, mounted **read-only** into the RAG
container only. PDFs, Word files, spreadsheets, and scanned images are indexed
and made searchable through `rag-search`. The agent container does **not** get
a direct mount to this folder — it accesses the content exclusively via
`rag-search`, preventing confusion between direct file access and semantic
retrieval.

Both paths can point to the same folder (the wizard default) or to separate
directories. Separating them is recommended when your documents library is
large or contains binary files the agent should not browse directly.

```bash
make rag-index-status   # show indexing progress
make rag-search QUERY="what did we decide about X?"
make rag-status
```

Indexed by default: Markdown, plain text, JSON/YAML/TOML/XML/HTML, CSV/TSV,
Office documents (xlsx/ods), PDFs, and images through containerized
Docling/Tika with needed-only OCR.

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
