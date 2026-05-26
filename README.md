# MLX Isolated Agent Stack

Run local MLX models on an Apple Silicon Mac and connect them to an isolated agent sandbox.

The host keeps the expensive pieces local: LM Studio downloads models, oMLX serves them through an OpenAI-compatible API, and an optional local RAG service indexes your notes and documents. The agent runs separately in Docker or Multipass.

## What You Get

- Local model serving with LM Studio + oMLX.
- Hermes or OpenClaw running in Docker or a Multipass Ubuntu VM.
- One active agent stack at a time, with safe switching prompts.
- Optional local RAG over an Obsidian vault or documents folder.
- PDF, image, spreadsheet, and text indexing with needed-only OCR.
- Telegram and local web dashboard/control UI support.

Version: `0.4.0`

## Quickstart

```bash
make bootstrap
make setup
make agent-status
make agent-open-dashboard
```

If LM Studio was just installed, launch it once before rerunning `make bootstrap`; that initializes the `lms` CLI.

`make setup` is the main entrypoint. It asks for:

- agent runtime: Hermes or OpenClaw;
- sandbox backend: Docker or Multipass;
- local model from LM Studio;
- optional Telegram credentials;
- optional RAG source folder and RAG runtime.

Run `make help` for the public command list.

## Architecture

```text
macOS host
  LM Studio       model download/catalog
  oMLX            OpenAI-compatible model API on :8000
  RAG service     Docker Compose API + Qdrant on :8765

Sandbox
  Hermes/OpenClaw in Docker or Multipass
  model API       http://model-host.internal:8000/v1
  RAG API         http://rag-host.internal:8765
```

Inference stays on the Mac. The sandbox is where the agent can install packages, work with shared files, and run tools.

## Supported Agent Modes

```bash
AGENT_RUNTIME=hermes   SANDBOX_BACKEND=multipass make agent-start
AGENT_RUNTIME=hermes   SANDBOX_BACKEND=docker    make agent-start
AGENT_RUNTIME=openclaw SANDBOX_BACKEND=multipass make agent-start
AGENT_RUNTIME=openclaw SANDBOX_BACKEND=docker    make agent-start
```

Only one stack should be active at a time. `make setup` detects existing stacks and offers to reuse, pause, reset, or abort. For non-interactive switching:

```bash
AGENT_RUNTIME=openclaw SANDBOX_BACKEND=multipass make agent-switch
```

## Models

Use LM Studio to discover and download MLX models, then sync the selected model into oMLX:

```bash
make models-search
make models-list
make model-select
make model-start-bg
```

Model cleanup helpers can scan LM Studio, oMLX runtime links, and Ollama storage for incomplete downloads:

```bash
make models-doctor
make models-prune-incomplete
```

## Local RAG

RAG is local-first and Docker-first. Your source folder remains the source of truth; `.runtime/` holds rebuildable Docker volumes and indexes.

```bash
make rag-preflight
make rag-sync
make rag-search QUERY="what did we decide about OpenClaw?"
make rag-status
```

Indexed by default:

- Markdown, plain text, JSON/YAML/TOML/XML/HTML, CSV/TSV;
- Office documents, Excel/ODS, PDFs, and images through containerized Docling/Tika;
- scanned PDFs and images through needed-only OCR in parser containers.

```bash
RAG_RUNTIME=docker make rag-preflight
RAG_RUNTIME=docker make rag-up
RAG_RUNTIME=docker make rag-sync
RAG_RUNTIME=docker make rag-search QUERY="release notes"
RAG_RUNTIME=docker make rag-down
```

Docker RAG uses prebuilt containers for parsing/OCR and vector storage, with lightweight local hash embeddings by default. The host does not install Tesseract, PyMuPDF, LanceDB, sentence-transformers, or Office parsers by default.

See [docs/RAG.md](docs/RAG.md).

## Shared Folder

Set `OBSIDIAN_SHARED_PATH` to the folder you want the agent and RAG to see. Docker uses a bind mount. Multipass uses a live mount by default.

```bash
make shared-mounts-check
```

## Telegram and Dashboard

Add Telegram credentials to `.env`:

```bash
TELEGRAM_BOT_TOKEN=...
TELEGRAM_USER_ID=123456789
```

Then start the selected stack:

```bash
make agent-start
make agent-open-dashboard
```

Remote dashboard access is opt-in through Cloudflare Tunnel. See [docs/REMOTE_ACCESS.md](docs/REMOTE_ACCESS.md).

## Safety Notes

- `.env` is ignored by git and should hold all local secrets.
- Model files and RAG indexes stay local.
- oMLX uses Bearer auth for local API access.
- Docker and Multipass sandbox agent execution, but they are not a substitute for reviewing secrets and mounted folders.
- `FORCE=1 make clean-all` removes sandbox runtime state but preserves `.env`, model downloads, and source documents.

## Release Checks

```bash
make ci-check
SKIP_VM_E2E=1 SKIP_DOCKER_E2E=1 make release-check
```

For a full local sandbox matrix:

```bash
make matrix-e2e
```

Provider roadmap: [docs/PROVIDERS.md](docs/PROVIDERS.md).
