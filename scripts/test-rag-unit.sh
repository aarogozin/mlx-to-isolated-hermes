#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

RAG_EMBEDDING_BACKEND=hash python3 "${SCRIPT_DIR}/rag.py" self-test
