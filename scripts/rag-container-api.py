#!/usr/bin/env python3
"""Docker-first RAG API backed by Qdrant and prebuilt parser services."""

from __future__ import annotations

import fnmatch
import hashlib
import json
import mimetypes
import os
import sys
import threading
import time
import uuid
from dataclasses import dataclass
from pathlib import Path
from typing import Any

import requests
from fastapi import FastAPI, HTTPException, Request
from qdrant_client import QdrantClient, models

# Global lock: prevents concurrent indexing runs (watcher thread vs. /index API)
_index_lock = threading.Lock()


TEXT_EXTENSIONS = {
    ".md",
    ".txt",
    ".rst",
    ".csv",
    ".tsv",
    ".json",
    ".yaml",
    ".yml",
    ".toml",
    ".xml",
    ".html",
}
PDF_EXTENSIONS = {".pdf"}
IMAGE_EXTENSIONS = {".png", ".jpg", ".jpeg", ".tif", ".tiff"}
DOCUMENT_EXTENSIONS = {
    ".doc",
    ".docx",
    ".ppt",
    ".pptx",
    ".xlsx",
    ".xlsm",
    ".xls",
    ".xlsb",
    ".ods",
}


@dataclass
class Chunk:
    text: str
    metadata: dict[str, Any]


def env(name: str, default: str = "") -> str:
    return os.environ.get(name, default)


def env_int(name: str, default: int) -> int:
    try:
        return int(env(name, str(default)))
    except ValueError:
        return default


def env_bool(name: str, default: bool = False) -> bool:
    value = env(name, "1" if default else "0").strip().lower()
    return value in {"1", "true", "yes", "on"}


def source_path() -> Path:
    return Path(env("RAG_SOURCE_PATH", "/source")).resolve()


def qdrant() -> QdrantClient:
    return QdrantClient(url=env("RAG_QDRANT_URL", "http://qdrant:6333"))


def collection_name() -> str:
    return env("RAG_QDRANT_COLLECTION", "rag_chunks")


def allowed_extensions() -> set[str]:
    raw = env(
        "RAG_TEXT_EXTENSIONS",
        ".md,.txt,.rst,.csv,.tsv,.json,.yaml,.yml,.toml,.xml,.html,.xlsx,.xlsm,.xls,.xlsb,.ods,.pdf,.png,.jpg,.jpeg,.tif,.tiff,.doc,.docx,.ppt,.pptx",
    )
    return {item.strip().lower() for item in raw.split(",") if item.strip()}


def exclude_globs() -> list[str]:
    raw = env("RAG_EXCLUDE_GLOBS", ".git/**,.obsidian/**,node_modules/**,.trash/**,*.env,*.key,*.pem")
    return [item.strip() for item in raw.split(",") if item.strip()]


def is_excluded(path: Path, root: Path) -> bool:
    rel = path.relative_to(root)
    if any(part.startswith('.') for part in rel.parts):
        return True
    rel_str = rel.as_posix()
    return any(fnmatch.fnmatch(rel_str, pattern) or fnmatch.fnmatch(path.name, pattern) for pattern in exclude_globs())


def file_sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for block in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def chunk_text(text: str, target_words: int | None = None, overlap_words: int | None = None) -> list[str]:
    target = target_words or env_int("RAG_CHUNK_TOKENS", 400)
    overlap = overlap_words or env_int("RAG_CHUNK_OVERLAP_TOKENS", 50)
    paragraphs = text.split("\n\n")
    chunks: list[str] = []
    current_chunk: list[str] = []
    current_words = 0
    
    for para in paragraphs:
        para = para.strip()
        if not para:
            continue
        para_words = para.split()
        if not para_words:
            continue
            
        if current_words + len(para_words) <= target:
            current_chunk.append(para)
            current_words += len(para_words)
        else:
            if len(para_words) > target:
                if current_chunk:
                    chunks.append("\n\n".join(current_chunk))
                    current_chunk = []
                    current_words = 0
                
                sentences = para.split(". ")
                for sent in sentences:
                    sent = sent.strip()
                    if not sent:
                        continue
                    sent_words = sent.split()
                    if not sent_words:
                        continue
                    
                    if current_words + len(sent_words) <= target:
                        current_chunk.append(sent)
                        current_words += len(sent_words)
                    else:
                        if current_chunk:
                            chunks.append(". ".join(current_chunk) + ".")
                        current_chunk = [sent]
                        current_words = len(sent_words)
            else:
                if current_chunk:
                    chunks.append("\n\n".join(current_chunk))
                overlap_text = ""
                if current_chunk:
                    last_para_words = current_chunk[-1].split()
                    overlap_text = " ".join(last_para_words[-overlap:]) if len(last_para_words) >= overlap else current_chunk[-1]
                
                current_chunk = []
                current_words = 0
                if overlap_text:
                    current_chunk.append(overlap_text)
                    current_words = len(overlap_text.split())
                current_chunk.append(para)
                current_words += len(para_words)
                
    if current_chunk:
        chunks.append("\n\n".join(current_chunk))
        
    return chunks


def read_text_file(path: Path) -> str:
    return path.read_text(encoding="utf-8", errors="ignore")


def tika_extract(path: Path, ocr_strategy: str | None = None) -> str:
    print(f"  -> Extracting with Tika (strategy={ocr_strategy or 'default'})...", flush=True)
    url = env("RAG_TIKA_URL", "http://tika:9998").rstrip("/") + "/tika"
    headers = {"Accept": "text/plain"}
    content_type = mimetypes.guess_type(path.name)[0]
    if content_type:
        headers["Content-Type"] = content_type
    if ocr_strategy:
        headers["X-Tika-PDFOcrStrategy"] = ocr_strategy
    with path.open("rb") as handle:
        response = requests.put(url, data=handle, headers=headers, timeout=300)
    response.raise_for_status()
    return response.text.strip()


def docling_extract(path: Path) -> str:
    print(f"  -> Extracting with Docling...", flush=True)
    base = env("RAG_DOCLING_URL", "http://docling:5001").rstrip("/")
    endpoints = ["/v1/convert/file", "/convert/file"]
    for endpoint in endpoints:
        try:
            with path.open("rb") as handle:
                files = {"files": (path.name, handle, mimetypes.guess_type(path.name)[0] or "application/octet-stream")}
                response = requests.post(base + endpoint, files=files, timeout=300)
            if response.status_code >= 400:
                continue
            content_type = response.headers.get("content-type", "")
            if "application/json" in content_type:
                payload = response.json()
                text = find_text_in_docling_payload(payload)
            else:
                text = response.text
            if text and text.strip():
                return text.strip()
        except Exception:
            continue
    raise RuntimeError("docling extraction unavailable")


def find_text_in_docling_payload(payload: Any) -> str:
    if isinstance(payload, str):
        return payload
    if isinstance(payload, dict):
        for key in ("markdown", "text", "content", "document"):
            value = payload.get(key)
            if isinstance(value, str) and value.strip():
                return value
        parts = [find_text_in_docling_payload(value) for value in payload.values()]
        return "\n".join(part for part in parts if part)
    if isinstance(payload, list):
        parts = [find_text_in_docling_payload(value) for value in payload]
        return "\n".join(part for part in parts if part)
    return ""


def extract_file(path: Path) -> tuple[str, dict[str, Any]]:
    ext = path.suffix.lower()
    metadata: dict[str, Any] = {"extension": ext, "extractor": "", "ocr_used": False}
    min_text = env_int("RAG_OCR_MIN_TEXT_CHARS", 200)
    ocr_enabled = env_bool("RAG_OCR_ENABLED", True) and env("RAG_OCR_MODE", "needed") in {"needed", "always"}

    if ext in TEXT_EXTENSIONS:
        metadata["source_type"] = "text"
        metadata["extractor"] = "direct"
        return read_text_file(path), metadata

    if ext in PDF_EXTENSIONS and env_bool("RAG_PDF_ENABLED", True):
        text = tika_extract(path, ocr_strategy="no_ocr")
        metadata["source_type"] = "pdf"
        metadata["extractor"] = "tika"
        if len(text) >= min_text or not ocr_enabled:
            return text, metadata
        try:
            text = docling_extract(path)
            metadata["extractor"] = "docling"
        except Exception:
            text = tika_extract(path, ocr_strategy="ocr_only")
            metadata["extractor"] = "tika"
        metadata["ocr_used"] = True
        metadata["ocr_languages"] = env("RAG_OCR_LANGUAGES", "rus+eng+deu")
        return text, metadata

    if ext in IMAGE_EXTENSIONS and env_bool("RAG_IMAGES_ENABLED", True):
        if not ocr_enabled:
            raise RuntimeError("ocr_required")
        try:
            text = docling_extract(path)
            metadata["extractor"] = "docling"
        except Exception:
            text = tika_extract(path)
            metadata["extractor"] = "tika"
        metadata["source_type"] = "image"
        metadata["ocr_used"] = True
        metadata["ocr_languages"] = env("RAG_OCR_LANGUAGES", "rus+eng+deu")
        return text, metadata

    if ext in DOCUMENT_EXTENSIONS:
        try:
            text = tika_extract(path)
            metadata["extractor"] = "tika"
        except Exception:
            text = docling_extract(path)
            metadata["extractor"] = "docling"
        metadata["source_type"] = "document"
        return text, metadata

    raise RuntimeError(f"unsupported extension: {ext}")


def hash_embedding(text: str, dim: int | None = None) -> list[float]:
    size = dim or env_int("RAG_HASH_EMBEDDING_DIM", 384)
    values = [0.0] * size
    for token in text.lower().split():
        digest = hashlib.blake2b(token.encode("utf-8"), digest_size=8).digest()
        index = int.from_bytes(digest[:4], "big") % size
        sign = 1.0 if digest[4] % 2 == 0 else -1.0
        values[index] += sign
    norm = sum(value * value for value in values) ** 0.5 or 1.0
    return [value / norm for value in values]


def tei_embeddings(texts: list[str]) -> list[list[float]]:
    base = env("RAG_TEI_URL", "http://tei:80").rstrip("/")
    batch_size = 16
    results = []
    for i in range(0, len(texts), batch_size):
        # Truncate each text chunk to a safe maximum limit of 10000 characters to prevent TEI 413 Payload Too Large
        batch = [t[:10000] for t in texts[i : i + batch_size]]
        payload = {"input": batch, "model": env("RAG_EMBEDDING_MODEL", "intfloat/multilingual-e5-small")}
        try:
            response = requests.post(base + "/v1/embeddings", json=payload, timeout=180)
            if response.status_code < 400:
                data = response.json().get("data", [])
                results.extend([item["embedding"] for item in data])
                continue
        except Exception as _tei_exc:
            print(f"Warning: primary TEI /v1/embeddings failed ({_tei_exc}), trying /embed fallback", flush=True)
        response = requests.post(base + "/embed", json={"inputs": batch}, timeout=180)
        response.raise_for_status()
        payload = response.json()
        if isinstance(payload, list) and payload and isinstance(payload[0], list):
            results.extend(payload)
        else:
            raise RuntimeError("unexpected TEI embedding response")
    return results


def embed(texts: list[str]) -> list[list[float]]:
    backend = env("RAG_DOCKER_EMBEDDING_BACKEND", "hash")
    if backend == "hash":
        return [hash_embedding(text) for text in texts]
    return tei_embeddings(texts)


def load_manifest() -> dict[str, Any]:
    path = Path(env("RAG_MANIFEST_PATH", "/cache/rag-manifest.json"))
    if path.exists():
        try:
            with open(path, "r", encoding="utf-8") as f:
                return json.load(f)
        except Exception:
            pass
    return {"documents": {}, "table_schema_version": 1}


def save_manifest(manifest: dict[str, Any]) -> None:
    path = Path(env("RAG_MANIFEST_PATH", "/cache/rag-manifest.json"))
    path.parent.mkdir(parents=True, exist_ok=True)
    try:
        with open(path, "w", encoding="utf-8") as f:
            json.dump(manifest, f, ensure_ascii=False, indent=2)
    except Exception as exc:
        print(f"Warning: Failed to save manifest: {exc}", flush=True)


def delete_document(client: QdrantClient, rel: str) -> None:
    client.delete(
        collection_name=collection_name(),
        points_selector=models.Filter(
            must=[
                models.FieldCondition(
                    key="path",
                    match=models.MatchValue(value=rel),
                )
            ]
        ),
        wait=True
    )


def ensure_collection(client: QdrantClient, vector_size: int) -> None:
    """Create the Qdrant collection if it does not exist, reusing the provided client."""
    name = collection_name()
    existing = [col.name for col in client.get_collections().collections]
    if name not in existing:
        client.create_collection(
            collection_name=name,
            vectors_config=models.VectorParams(size=vector_size, distance=models.Distance.COSINE),
        )


def scan_files() -> list[Path]:
    root = source_path()
    allowed = allowed_extensions()
    max_text = env_int("RAG_MAX_FILE_MB", 10) * 1024 * 1024
    max_doc = env_int("RAG_DOCUMENT_MAX_FILE_MB", 50) * 1024 * 1024
    paths: list[Path] = []
    for path in root.rglob("*"):
        if not path.is_file() or is_excluded(path, root):
            continue
        ext = path.suffix.lower()
        if ext not in allowed:
            continue
        limit = max_text if ext in TEXT_EXTENSIONS else max_doc
        if path.stat().st_size > limit:
            continue
        paths.append(path)
    return paths


def build_chunks(path: Path) -> list[Chunk]:
    root = source_path()
    text, metadata = extract_file(path)
    rel = path.relative_to(root).as_posix()
    digest = file_sha256(path)
    chunks: list[Chunk] = []
    for index, piece in enumerate(chunk_text(text)):
        chunks.append(
            Chunk(
                text=piece,
                metadata={
                    **metadata,
                    "path": rel,
                    "title": path.stem,
                    "chunk_index": index,
                    "sha256": digest,
                    "mtime": path.stat().st_mtime,
                },
            )
        )
    return chunks


def index_documents() -> dict[str, Any]:
    errors: list[dict[str, str]] = []
    files = scan_files()
    total = len(files)
    
    client = qdrant()
    name = collection_name()
    existing = [collection.name for collection in client.get_collections().collections]
    
    manifest = load_manifest()
    
    # Recreate collection if schemas or parameters change
    model_changed = manifest.get("embedding_model") != env("RAG_EMBEDDING_MODEL", "intfloat/multilingual-e5-small")
    backend_changed = manifest.get("embedding_backend") != env("RAG_DOCKER_EMBEDDING_BACKEND", "hash")
    recreate = (name not in existing) or model_changed or backend_changed
    
    if recreate:
        print(f"Recreating Qdrant collection '{name}'...", flush=True)
        if name in existing:
            client.delete_collection(name)
        collection_initialized = False
        manifest["documents"] = {}
    else:
        collection_initialized = True

    documents = manifest.setdefault("documents", {})
    seen: set[str] = set()
    changed = 0
    skipped = 0
    chunks_written = 0

    print(f"Starting indexing for {total} files.", flush=True)

    for idx, path in enumerate(files, 1):
        rel = path.relative_to(source_path()).as_posix()
        seen.add(rel)
        digest = file_sha256(path)
        stat = path.stat()

        current = documents.get(rel, {})
        if current.get("sha256") == digest and not current.get("skipped"):
            skipped += 1
            continue

        print(f"[{idx}/{total}] Indexing {rel}...", flush=True)
        try:
            if collection_initialized:
                delete_document(client, rel)

            chunks = build_chunks(path)
            if not chunks:
                documents[rel] = {
                    "sha256": digest,
                    "mtime": stat.st_mtime,
                    "size": stat.st_size,
                    "chunks": 0,
                }
            else:
                vectors = embed([chunk.text for chunk in chunks])
                # BUG-2 guard: if embed() returns nothing (TEI unhealthy), force a retry next run
                if len(vectors) != len(chunks):
                    raise RuntimeError(
                        f"embed() returned {len(vectors)} vectors for {len(chunks)} chunks"
                    )
                doc_points = [
                    models.PointStruct(
                        id=str(uuid.uuid5(uuid.NAMESPACE_URL, f"{chunk.metadata['path']}:{chunk.metadata['chunk_index']}")),
                        vector=vector,
                        payload={**chunk.metadata, "text": chunk.text},
                    )
                    for chunk, vector in zip(chunks, vectors)
                ]
                if doc_points:
                    if not collection_initialized:
                        # BUG-8: reuse same client, not a new connection
                        ensure_collection(client, len(doc_points[0].vector))
                        collection_initialized = True

                    # Batch upsert to avoid oversized requests for large documents
                    batch_size = 100
                    for i in range(0, len(doc_points), batch_size):
                        client.upsert(collection_name=name, points=doc_points[i : i + batch_size], wait=True)
                    chunks_written += len(doc_points)

                documents[rel] = {
                    "sha256": digest,
                    "mtime": stat.st_mtime,
                    "size": stat.st_size,
                    "chunks": len(doc_points),
                }
            changed += 1
        except Exception as exc:
            errors.append({"path": rel, "reason": str(exc)})
            print(f"  ✗ Error indexing {rel}: {exc}", flush=True)
            # BUG-2: mark as skipped=True so next run retries (sha256 alone won't trigger retry)
            documents[rel] = {
                "sha256": digest,
                "mtime": stat.st_mtime,
                "size": stat.st_size,
                "chunks": 0,
                "skipped": True,
                "error": str(exc),
            }
            changed += 1

        # BUG-6: Incremental save only after this file was processed (not on every iteration)
        manifest["updated_at"] = time.time()
        manifest["embedding_model"] = env("RAG_EMBEDDING_MODEL", "intfloat/multilingual-e5-small")
        manifest["embedding_backend"] = env("RAG_DOCKER_EMBEDDING_BACKEND", "hash")
        save_manifest(manifest)

    pruned = 0
    to_prune = [rel for rel in documents if rel not in seen]
    for rel in to_prune:
        print(f"Pruning deleted document {rel}...", flush=True)
        if collection_initialized:
            delete_document(client, rel)
        del documents[rel]
        pruned += 1

    manifest["updated_at"] = time.time()
    manifest["embedding_model"] = env("RAG_EMBEDDING_MODEL", "intfloat/multilingual-e5-small")
    manifest["embedding_backend"] = env("RAG_DOCKER_EMBEDDING_BACKEND", "hash")
    save_manifest(manifest)

    print(f"Indexing completed: {changed} changed, {skipped} skipped, {pruned} pruned. Total chunks written: {chunks_written}", flush=True)
    return {
        "documents": len(files),
        "chunks_written": chunks_written,
        "changed": changed,
        "skipped": skipped,
        "pruned": pruned,
        "errors": errors
    }


def search(query: str, top_k: int | None = None) -> dict[str, Any]:
    vector = embed([query])[0]
    limit = top_k or env_int("RAG_TOP_K", 8)
    client = qdrant()
    try:
        result = client.query_points(
            collection_name=collection_name(),
            query=vector,
            limit=limit,
            with_payload=True,
        ).points
    except AttributeError:
        result = client.search(collection_name=collection_name(), query_vector=vector, limit=limit, with_payload=True)
    hits = []
    for point in result:
        payload = point.payload or {}
        hits.append(
            {
                "score": float(point.score),
                "path": payload.get("path", ""),
                "title": payload.get("title", ""),
                "source_type": payload.get("source_type", ""),
                "extractor": payload.get("extractor", ""),
                "ocr_used": payload.get("ocr_used", False),
                "ocr_languages": payload.get("ocr_languages", ""),
                "chunk_index": payload.get("chunk_index", 0),
                "mtime": payload.get("mtime", 0),
                "sha256": payload.get("sha256", ""),
                "extension": payload.get("extension", ""),
                "text": payload.get("text", ""),
                "excerpt": payload.get("text", "")[:800],
            }
        )
    return {"query": query, "results": hits}


def service_status(name: str, url: str) -> dict[str, Any]:
    try:
        response = requests.get(url, timeout=3)
        return {"name": name, "ok": response.status_code < 500, "status": response.status_code}
    except Exception as exc:
        return {"name": name, "ok": False, "error": str(exc)}


def health() -> dict[str, Any]:
    embedding_backend = env("RAG_DOCKER_EMBEDDING_BACKEND", "hash")
    statuses = [
        service_status("qdrant", env("RAG_QDRANT_URL", "http://qdrant:6333") + "/"),
        service_status("tika", env("RAG_TIKA_URL", "http://tika:9998") + "/tika"),
        service_status("docling", env("RAG_DOCLING_URL", "http://docling:5001") + "/health"),
    ]
    if embedding_backend == "tei":
        statuses.append(service_status("tei", env("RAG_TEI_URL", "http://tei:80") + "/health"))
    try:
        collections = [collection.name for collection in qdrant().get_collections().collections]
        qdrant_ok = True
    except Exception:
        collections = []
        qdrant_ok = False
    return {
        "ok": qdrant_ok,
        "runtime": "docker",
        "source_path": str(source_path()),
        "embedding_backend": embedding_backend,
        "collection": collection_name(),
        "collection_exists": collection_name() in collections,
        "services": statuses,
    }


def format_markdown(result: dict[str, Any]) -> str:
    lines = [f"# RAG results for: {result['query']}"]
    for idx, hit in enumerate(result.get("results", []), start=1):
        excerpt = " ".join(str(hit.get("text", "")).split())[:700]
        lines.append("")
        lines.append(f"{idx}. {hit.get('path', '')} score={hit.get('score', 0):.4f}")
        lines.append(f"   source={hit.get('source_type', '')} extractor={hit.get('extractor', '')} ocr={hit.get('ocr_used', False)}")
        lines.append(f"   {excerpt}")
    return "\n".join(lines)


def source_fingerprint(root: Path) -> str:
    digest = hashlib.sha256()
    for path in scan_files():
        try:
            stat = path.stat()
            rel = path.relative_to(root).as_posix()
            digest.update(rel.encode("utf-8", errors="replace"))
            digest.update(b"\0")
            digest.update(str(stat.st_mtime_ns).encode("ascii"))
            digest.update(b"\0")
            digest.update(str(stat.st_size).encode("ascii"))
            digest.update(b"\0")
        except OSError:
            continue
    return digest.hexdigest()


def watch_loop() -> None:
    interval = env_int("RAG_WATCH_INTERVAL_SECONDS", 20)
    debounce = env_int("RAG_WATCH_DEBOUNCE_SECONDS", 3)
    interval = max(2, interval)
    debounce = max(0, debounce)
    root = source_path()
    
    print(f"[Watcher] Starting RAG file watcher. interval={interval}s, debounce={debounce}s, path={root}", flush=True)
    
    # Wait for the service to be healthy (specifically, Qdrant/Tika/TEI to be up)
    time.sleep(5)
    
    # Run initial index if RAG_AUTO_INDEX_ON_START is true
    if env_bool("RAG_AUTO_INDEX_ON_START", True):
        print("[Watcher] Running initial RAG indexing on startup...", flush=True)
        try:
            index_documents()
        except Exception as exc:
            print(f"[Watcher] Initial indexing failed: {exc}", flush=True)

    previous = source_fingerprint(root)
    while True:
        try:
            time.sleep(interval)
            current = source_fingerprint(root)
            if current != previous:
                print(f"[Watcher] Change detected in {root}. Debouncing for {debounce}s...", flush=True)
                if debounce:
                    time.sleep(debounce)
                # BUG-1: use lock — skip if manual /index is already running
                if _index_lock.acquire(blocking=False):
                    try:
                        print("[Watcher] Changes stabilized. Triggering indexing...", flush=True)
                        index_documents()
                    finally:
                        _index_lock.release()
                else:
                    print("[Watcher] Indexing already in progress, skipping this trigger.", flush=True)
                # BUG-12: recompute AFTER indexing so changes during the run aren't missed
                previous = source_fingerprint(root)
        except Exception as exc:
            print(f"[Watcher] Error in watcher loop: {exc}", flush=True)


def serve() -> None:
    import uvicorn

    if env_bool("RAG_AUTO_INDEX", True):
        watcher_thread = threading.Thread(target=watch_loop, daemon=True)
        watcher_thread.start()

    app = FastAPI(title="Docker RAG API", version="0.5.3")

    @app.get("/health")
    def health_route() -> dict[str, Any]:
        return health()

    @app.post("/index")
    async def index_route(_: Request) -> dict[str, Any]:
        # BUG-1: return 409 if watcher is already indexing
        if not _index_lock.acquire(blocking=False):
            raise HTTPException(status_code=409, detail="Indexing already in progress")
        try:
            return index_documents()
        finally:
            _index_lock.release()

    @app.post("/search")
    async def search_route(request: Request) -> dict[str, Any]:
        payload = await request.json()
        query = str(payload.get("query", "")).strip()
        if not query:
            raise HTTPException(status_code=400, detail="query is required")
        top_k = payload.get("top_k")
        return search(query, int(top_k) if top_k else None)

    @app.get("/documents/{document_id}")
    def document_route(document_id: str) -> dict[str, Any]:
        raise HTTPException(status_code=501, detail=f"document lookup is not implemented for id={document_id}")

    uvicorn.run(app, host=env("RAG_BIND_HOST", "0.0.0.0"), port=env_int("RAG_PORT", 8765))


def main(argv: list[str]) -> int:
    command = argv[1] if len(argv) > 1 else "serve"
    if command == "serve":
        serve()
        return 0
    if command == "index":
        print(json.dumps(index_documents(), ensure_ascii=False, indent=2))
        return 0
    if command == "health" or command == "doctor":
        print(json.dumps(health(), ensure_ascii=False, indent=2))
        return 0
    if command == "search":
        json_output = "--json" in argv
        args = [arg for arg in argv[2:] if arg != "--json"]
        query = " ".join(args).strip()
        if not query:
            print("Usage: rag-container-api.py search [--json] <query>", file=sys.stderr)
            return 2
        result = search(query)
        print(json.dumps(result, ensure_ascii=False, indent=2) if json_output else format_markdown(result))
        return 0
    print(f"unknown command: {command}", file=sys.stderr)
    return 2


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
