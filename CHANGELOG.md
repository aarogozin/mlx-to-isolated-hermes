# Changelog

## Unreleased

- Add `make mcp-doctor` for safe MCP configuration inspection and local no-op smoke checks.
- Add `make rag-why` for explainable RAG results with scores, source types, extractors, OCR usage, and excerpts.
- Add `make stack-smoke` and wire it into `make update` as a post-update verification step.
- Add `make release-notes` to draft concise release notes from git history.
- Harden GitHub Actions with Node 24 opt-in, diff hygiene checks, MCP mock checks, and disabled Go cache when no `go.sum` exists.

## 0.5.26 - 2026-06-17

Harden the Docker-first local agent stack and RAG runtime:

- Fix Hermes Docker provisioning so the generated Local RAG skill is written as text instead of accidentally executing `rag-search` during container creation.
- Mount `rag-search` into `/usr/local/bin` so Hermes and shell sessions can always reach the host RAG bridge.
- Make Docker RAG safer by default: hash embeddings are the public default, TEI is opt-in, and the RAG API binds to loopback unless explicitly changed.
- Detect stale RAG source mounts and recreate the RAG API container when `RAG_SOURCE_PATH` changes.
- Keep optional services opt-in: local Firecrawl only starts with `FIRECRAWL_LOCAL_ENABLED=1`, and Firecrawl MCP stays disabled without a real cloud key or local service.
- Disable stale Linear OAuth MCP config unless `LINEAR_MCP_ENABLED=1` is set and login has been completed.
- Keep the official Hermes dashboard local Docker mode working while leaving the code-level dashboard auth bypass patch disabled by default.
- Improve `rag-index-status` so successful incremental indexing reports `complete` instead of stale partial progress.
- Remove remaining personal-path leftovers from public docs and examples.

## 0.5.25 - 2026-06-05

Add unified `make update` command to update all stack components in one step:

- Add `scripts/update.sh` as the update orchestrator.
- Add dry-run mode through `make update-dry-run`.
- Add per-component skip flags for git, oMLX, agent, and RAG updates.
- Keep update steps non-fatal and summarize results at the end.
- Show Docker image digest changes when containers are updated.
