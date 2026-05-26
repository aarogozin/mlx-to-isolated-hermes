#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

cd "${PROJECT_ROOT}"

if ! command -v tesseract >/dev/null 2>&1; then
  echo "rag ocr smoke skipped: tesseract missing"
  exit 0
fi

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

mkdir -p "${TMP_DIR}/vault"

OCR_IMAGE="${TMP_DIR}/vault/scan.png" .runtime/rag-venv/bin/python - <<'PY'
import os
from PIL import Image, ImageDraw

image = Image.new("RGB", (900, 180), "white")
draw = ImageDraw.Draw(image)
draw.text((30, 60), "ocr sentinel local rag english", fill="black")
image.save(os.environ["OCR_IMAGE"])
PY

RAG_SOURCE_PATH="${TMP_DIR}/vault" \
RAG_INDEX_PATH="${TMP_DIR}/index" \
RAG_EMBEDDING_BACKEND=hash \
RAG_OCR_ENABLED=1 \
RAG_OCR_LANGUAGES="${RAG_OCR_LANGUAGES:-eng}" \
  .runtime/rag-venv/bin/python scripts/rag.py index >/dev/null

RAG_SOURCE_PATH="${TMP_DIR}/vault" \
RAG_INDEX_PATH="${TMP_DIR}/index" \
RAG_EMBEDDING_BACKEND=hash \
  .runtime/rag-venv/bin/python scripts/rag.py search --json --source-type image "ocr sentinel" \
  | jq -e '.results | length > 0 and .[0].ocr_used == true and .[0].extractor == "tesseract"' >/dev/null

echo "rag ocr smoke passed"
