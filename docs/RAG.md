# Local RAG

The oMLX Isolated Agent Stack provides a Docker-first local RAG layer for Obsidian vaults and personal documents.

Your shared folder is the source of truth. Everything under `.runtime/` is derived state and can be rebuilt.

## Runtime

Public RAG runs in Docker Compose by default:

```bash
RAG_RUNTIME=docker
```

The compose stack uses prebuilt images:

- `python:3.12-slim` for the small RAG API/indexer.
- `qdrant/qdrant` for vector storage.
- Hash embeddings in the RAG API by default, avoiding a heavyweight embedding image on Apple Silicon.
- `quay.io/docling-project/docling-serve` for primary document parsing/OCR.
- `apache/tika:latest-full` for broad fallback extraction and OCR.

The source folder is mounted read-only. Derived state is stored under `.runtime/`.

`make rag-preflight` verifies that required images publish `linux/arm64` manifests before pulling them. `make rag-up` runs the same preflight before starting containers. TEI can be enabled later with `RAG_DOCKER_EMBEDDING_BACKEND=tei`, but it is not the default because current public TEI CPU tags do not provide a normal Apple Silicon `arm64` image.

Host-side RAG is legacy-only. It is not installed by bootstrap or setup. Use it only with:

```bash
RAG_RUNTIME=host INSTALL_RAG_HOST=1
```

## Commands

```bash
make rag-preflight
make rag-up
make rag-sync
make rag-search QUERY="project release notes"
make rag-why QUERY="project release notes"
make rag-status
make rag-doctor
make rag-down
make rag-logs
```

`rag-sync` starts Docker RAG if needed, indexes the shared source folder, and keeps the API available at:

```text
http://127.0.0.1:8765
```

Agent sandboxes use:

```text
http://rag-host.internal:8765
```

## Indexed Files

Default extensions:

```text
.md,.txt,.rst,.csv,.tsv,.json,.yaml,.yml,.toml,.xml,.html,.xlsx,.xlsm,.xls,.xlsb,.ods,.pdf,.png,.jpg,.jpeg,.tif,.tiff,.doc,.docx,.ppt,.pptx
```

Default excludes:

```text
.git/**,.obsidian/**,node_modules/**,.trash/**,*.env,*.key,*.pem
```

Text-like files are read directly by the RAG API. PDFs, images, and Office files are extracted through Docling first where possible and Tika as fallback.

## Needed-Only OCR

OCR is enabled as a capability, but it is only used when needed:

- Text PDFs are extracted without OCR first.
- If PDF text is below `RAG_OCR_MIN_TEXT_CHARS`, scanned-PDF OCR is attempted.
- Images always require OCR.
- Office/text files do not trigger OCR.

OCR runs inside parser containers, not on the macOS host.

## Agent Usage

Hermes and OpenClaw receive a `rag-search` CLI bridge:

```bash
rag-search "what did we decide about OpenClaw?"
rag-search --json "telegram daemon conflict"
```

The agent should call this tool before answering questions about local notes, source documents, or project memory. The project does not automatically inject RAG context into every prompt.

For debugging retrieval quality, use:

```bash
make rag-why QUERY="project release notes"
```

It prints source paths, scores, extractor names, OCR usage, chunk indexes, and excerpts so you can see why a result was returned.

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

The source folder is mounted read-only into Docker. Indexes, parser cache, embedding cache, and Qdrant storage stay local under `.runtime/`. No cloud APIs are used by default.
