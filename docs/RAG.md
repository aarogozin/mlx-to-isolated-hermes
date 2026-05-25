# Local RAG

v0.4.0 adds a local RAG layer for Obsidian-backed agent knowledge.

The source of truth is still your notes folder. The vector index under `.runtime/rag` is derived state and can be deleted or rebuilt at any time.

## Defaults

```bash
RAG_ENABLED=1
RAG_SOURCE_PATH=${OBSIDIAN_SHARED_PATH:-}
RAG_INDEX_PATH=.runtime/rag
RAG_HOST=127.0.0.1
RAG_BIND_HOST=0.0.0.0
RAG_PORT=8765
RAG_EMBEDDING_MODEL=intfloat/multilingual-e5-small
RAG_AUTO_INDEX=1
RAG_WATCH_INTERVAL_SECONDS=20
RAG_WATCH_DEBOUNCE_SECONDS=3
```

The service runs on the host and is shared by all four agent modes:

- Hermes on Multipass
- Hermes on Docker
- OpenClaw on Multipass
- OpenClaw on Docker

Sandboxes reach it at:

```text
http://rag-host.internal:8765
```

## Commands

```bash
make rag-install
make rag-index
make rag-sync
make rag-start
make rag-watch-start
make rag-search QUERY="project release notes"
make rag-status
make rag-stop
make rag-doctor
```

`rag-index` is incremental by default: unchanged files are skipped, changed files are re-indexed, and deleted files are pruned.
`rag-sync` runs one incremental index pass and starts the host RAG service.
When `RAG_AUTO_INDEX=1`, `rag-start` also starts a lightweight watcher that re-indexes changed/deleted files after a short polling delay.

## Indexed Files

Text-like extensions are indexed:

```text
.md,.txt,.rst,.csv,.tsv,.json,.yaml,.yml,.toml,.xml,.html
```

Default excludes:

```text
.git/**,.obsidian/**,node_modules/**,.trash/**,*.env,*.key,*.pem
```

Files larger than `RAG_MAX_FILE_MB` are skipped.

## Agent Usage

Agent environments receive a small CLI bridge:

```bash
rag-search "what did we decide about OpenClaw?"
rag-search --json --top-k 5 "telegram daemon conflict"
```

This is intentionally explicit in v0.4.0. The agent should call `rag-search` before answering questions about local notes, Obsidian vault content, project knowledge, or personal documents. The project does not automatically inject note context into every prompt yet.

The shared folder and the RAG index solve different problems:

- `OBSIDIAN_SHARED_PATH` is the live source folder the agent can read and write as files.
- `.runtime/rag` is a searchable derived index built from that source folder.

Docker uses a live bind mount. Multipass should use `MULTIPASS_SHARED_MODE=mount` for a live host folder; `transfer` is only a snapshot fallback and is not suitable for no-manual-sync workflows.

## API

```text
GET  /health
POST /index
POST /search
GET  /documents/{id}
```

Example:

```bash
curl -fsS http://127.0.0.1:8765/search \
  -H 'Content-Type: application/json' \
  -d '{"query":"local model server","top_k":8}'
```

## Privacy

Everything runs locally. No cloud APIs are used for indexing or search. The default embedding model is downloaded through Python package/model tooling into the local machine cache.
