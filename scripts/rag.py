#!/usr/bin/env python3
"""Local LanceDB RAG index for Obsidian/text files."""

from __future__ import annotations

import argparse
import fnmatch
import hashlib
import json
import os
import re
import sys
import tempfile
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Iterable


PROJECT_ROOT = Path(__file__).resolve().parents[1]
ENV_FILE = PROJECT_ROOT / ".env"
DEFAULT_EXTENSIONS = ".md,.txt,.rst,.csv,.tsv,.json,.yaml,.yml,.toml,.xml,.html"
DEFAULT_EXCLUDES = ".git/**,.obsidian/**,node_modules/**,.trash/**,*.env,*.key,*.pem"
TABLE_NAME = "chunks"
MANIFEST_NAME = "manifest.json"


def read_env_file(path: Path = ENV_FILE) -> dict[str, str]:
    values: dict[str, str] = {}
    if not path.exists():
        return values
    for raw_line in path.read_text(encoding="utf-8", errors="replace").splitlines():
        line = raw_line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, value = line.split("=", 1)
        key = key.strip()
        value = value.strip()
        if (value.startswith('"') and value.endswith('"')) or (
            value.startswith("'") and value.endswith("'")
        ):
            value = value[1:-1]
        values.setdefault(key, os.path.expandvars(value))
    return values


ENV = read_env_file()


def env(name: str, default: str = "") -> str:
    value = os.environ.get(name, ENV.get(name, default))
    return os.path.expandvars(value)


def env_bool(name: str, default: bool = False) -> bool:
    value = env(name, "1" if default else "0").strip().lower()
    return value in {"1", "true", "yes", "on"}


def env_int(name: str, default: int) -> int:
    try:
        return int(env(name, str(default)))
    except ValueError:
        return default


def expand_path(value: str) -> Path:
    return Path(os.path.expandvars(os.path.expanduser(value))).resolve()


def split_csv(value: str) -> list[str]:
    return [item.strip() for item in value.split(",") if item.strip()]


def normalize_exts(value: str) -> set[str]:
    exts: set[str] = set()
    for ext in split_csv(value):
        exts.add(ext if ext.startswith(".") else f".{ext}")
    return exts


def source_path() -> Path:
    raw = env("RAG_SOURCE_PATH", env("OBSIDIAN_SHARED_PATH", ""))
    if raw in {"", "${OBSIDIAN_SHARED_PATH}", "${OBSIDIAN_SHARED_PATH:-}"}:
        raw = env("OBSIDIAN_SHARED_PATH", "")
    if not raw:
        raise RuntimeError("RAG_SOURCE_PATH is unset; set OBSIDIAN_SHARED_PATH or RAG_SOURCE_PATH.")
    return expand_path(raw)


def index_path() -> Path:
    raw = env("RAG_INDEX_PATH", ".runtime/rag")
    path = expand_path(raw)
    if not path.is_absolute():
        path = (PROJECT_ROOT / raw).resolve()
    return path


def lancedb_path() -> Path:
    return index_path() / "lancedb"


def manifest_path() -> Path:
    return index_path() / MANIFEST_NAME


def load_manifest() -> dict[str, Any]:
    path = manifest_path()
    if not path.exists():
        return {"documents": {}}
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except json.JSONDecodeError:
        return {"documents": {}}


def save_manifest(manifest: dict[str, Any]) -> None:
    path = manifest_path()
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(".tmp")
    tmp.write_text(json.dumps(manifest, ensure_ascii=False, indent=2, sort_keys=True), encoding="utf-8")
    tmp.replace(path)


def relpath(path: Path, root: Path) -> str:
    return path.resolve().relative_to(root.resolve()).as_posix()


def is_excluded(relative: str, patterns: Iterable[str]) -> bool:
    parts = Path(relative).parts
    for pattern in patterns:
        pattern = pattern.strip()
        if not pattern:
            continue
        if fnmatch.fnmatch(relative, pattern) or fnmatch.fnmatch(Path(relative).name, pattern):
            return True
        if pattern.endswith("/**") and relative.startswith(pattern[:-3].rstrip("/") + "/"):
            return True
        if pattern.startswith(".") and pattern.endswith("/**"):
            dirname = pattern[:-3].rstrip("/")
            if dirname in parts:
                return True
        if pattern.endswith("/**"):
            dirname = pattern[:-3].rstrip("/")
            if "/" not in dirname and dirname in parts:
                return True
    return False


def discover_files(root: Path) -> list[Path]:
    extensions = normalize_exts(env("RAG_TEXT_EXTENSIONS", DEFAULT_EXTENSIONS))
    excludes = split_csv(env("RAG_EXCLUDE_GLOBS", DEFAULT_EXCLUDES))
    max_bytes = env_int("RAG_MAX_FILE_MB", 10) * 1024 * 1024
    files: list[Path] = []
    for path in root.rglob("*"):
        if not path.is_file():
            continue
        relative = relpath(path, root)
        if is_excluded(relative, excludes):
            continue
        if path.suffix.lower() not in extensions:
            continue
        try:
            if path.stat().st_size > max_bytes:
                continue
        except OSError:
            continue
        files.append(path)
    return sorted(files)


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for block in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


FRONTMATTER_RE = re.compile(r"\A---\s*\n(.*?)\n---\s*\n", re.DOTALL)
HEADING_RE = re.compile(r"^(#{1,6})\s+(.+?)\s*$", re.MULTILINE)
TAG_RE = re.compile(r"(?<!\w)#([A-Za-z0-9_/-]+)")
WIKILINK_RE = re.compile(r"\[\[([^\]]+)\]\]")


def parse_frontmatter(text: str) -> tuple[dict[str, Any], str]:
    match = FRONTMATTER_RE.match(text)
    if not match:
        return {}, text
    raw = match.group(1)
    frontmatter: dict[str, Any] = {}
    for line in raw.splitlines():
        if ":" not in line or line.startswith((" ", "\t", "-")):
            continue
        key, value = line.split(":", 1)
        key = key.strip()
        value = value.strip().strip('"').strip("'")
        if value.startswith("[") and value.endswith("]"):
            value = [item.strip().strip('"').strip("'") for item in value[1:-1].split(",") if item.strip()]
        frontmatter[key] = value
    return frontmatter, text[match.end() :]


def extract_tags(text: str, frontmatter: dict[str, Any]) -> list[str]:
    tags = set(TAG_RE.findall(text))
    raw_tags = frontmatter.get("tags") or frontmatter.get("tag")
    if isinstance(raw_tags, str):
        tags.update(item.strip().lstrip("#") for item in re.split(r"[,\s]+", raw_tags) if item.strip())
    elif isinstance(raw_tags, list):
        tags.update(str(item).strip().lstrip("#") for item in raw_tags if str(item).strip())
    return sorted(tags)


def extract_links(text: str) -> list[str]:
    links = []
    for raw in WIKILINK_RE.findall(text):
        target = raw.split("|", 1)[0].split("#", 1)[0].strip()
        if target:
            links.append(target)
    return sorted(set(links))


def extract_title(path: Path, frontmatter: dict[str, Any], text: str) -> str:
    for key in ("title", "name"):
        value = frontmatter.get(key)
        if isinstance(value, str) and value.strip():
            return value.strip()
    match = HEADING_RE.search(text)
    if match:
        return match.group(2).strip()
    return path.stem


def tokenish_len(text: str) -> int:
    return max(1, len(text) // 4)


@dataclass
class Chunk:
    text: str
    heading: str


def trim_to_chunks(blocks: list[tuple[str, str]], target_tokens: int, overlap_tokens: int) -> list[Chunk]:
    target_chars = max(400, target_tokens * 4)
    overlap_chars = max(0, overlap_tokens * 4)
    chunks: list[Chunk] = []
    current = ""
    current_heading = ""
    for heading, block in blocks:
        block = block.strip()
        if not block:
            continue
        if len(block) > target_chars:
            start = 0
            while start < len(block):
                part = block[start : start + target_chars].strip()
                if part:
                    chunks.append(Chunk(part, heading))
                if start + target_chars >= len(block):
                    break
                start = max(start + target_chars - overlap_chars, start + 1)
            current = ""
            current_heading = ""
            continue
        if current and len(current) + len(block) + 2 > target_chars:
            chunks.append(Chunk(current.strip(), current_heading))
            tail = current[-overlap_chars:].strip() if overlap_chars else ""
            current = f"{tail}\n\n{block}" if tail else block
            current_heading = heading
        else:
            current = f"{current}\n\n{block}" if current else block
            current_heading = current_heading or heading
    if current.strip():
        chunks.append(Chunk(current.strip(), current_heading))
    return chunks


def markdown_blocks(text: str) -> list[tuple[str, str]]:
    blocks: list[tuple[str, str]] = []
    current_heading = ""
    current_lines: list[str] = []
    for line in text.splitlines():
        heading = re.match(r"^(#{1,6})\s+(.+?)\s*$", line)
        if heading and current_lines:
            blocks.append((current_heading, "\n".join(current_lines)))
            current_lines = []
        if heading:
            current_heading = heading.group(2).strip()
        current_lines.append(line)
    if current_lines:
        blocks.append((current_heading, "\n".join(current_lines)))
    return blocks


def plain_blocks(text: str) -> list[tuple[str, str]]:
    parts = [part.strip() for part in re.split(r"\n\s*\n", text) if part.strip()]
    if not parts:
        parts = [line.strip() for line in text.splitlines() if line.strip()]
    return [("", part) for part in parts]


def chunk_document(path: Path, text: str) -> tuple[dict[str, Any], list[Chunk]]:
    frontmatter, body = parse_frontmatter(text)
    title = extract_title(path, frontmatter, body)
    tags = extract_tags(body, frontmatter)
    links = extract_links(body)
    headings = [match.group(2).strip() for match in HEADING_RE.finditer(body)]
    if path.suffix.lower() == ".md":
        blocks = markdown_blocks(body)
    else:
        blocks = plain_blocks(body)
    chunks = trim_to_chunks(
        blocks,
        env_int("RAG_CHUNK_TOKENS", 800),
        env_int("RAG_CHUNK_OVERLAP_TOKENS", 120),
    )
    metadata = {
        "title": title,
        "frontmatter": frontmatter,
        "tags": tags,
        "links": links,
        "headings": headings,
    }
    return metadata, chunks


class Embedder:
    def __init__(self) -> None:
        self.backend = env("RAG_EMBEDDING_BACKEND", "sentence-transformers")
        self.model_name = env("RAG_EMBEDDING_MODEL", "intfloat/multilingual-e5-small")
        self.model: Any = None
        if self.backend == "hash":
            return
        try:
            from sentence_transformers import SentenceTransformer
        except ImportError as exc:
            raise RuntimeError("sentence-transformers missing; run make rag-install") from exc
        self.model = SentenceTransformer(self.model_name)

    def embed(self, texts: list[str], query: bool = False) -> list[list[float]]:
        if self.backend == "hash":
            return [hash_embedding(text) for text in texts]
        prefix = "query: " if query else "passage: "
        vectors = self.model.encode(
            [prefix + text for text in texts],
            normalize_embeddings=True,
            show_progress_bar=False,
        )
        return [list(map(float, vector)) for vector in vectors]


def hash_embedding(text: str, dimensions: int = 384) -> list[float]:
    buckets = [0.0] * dimensions
    words = re.findall(r"[\w/-]+", text.lower())
    for word in words or [text.lower()]:
        digest = hashlib.sha256(word.encode("utf-8")).digest()
        index = int.from_bytes(digest[:4], "big") % dimensions
        sign = 1.0 if digest[4] % 2 == 0 else -1.0
        buckets[index] += sign
    norm = sum(value * value for value in buckets) ** 0.5 or 1.0
    return [value / norm for value in buckets]


def require_lancedb() -> Any:
    try:
        import lancedb
    except ImportError as exc:
        raise RuntimeError("lancedb missing; run make rag-install") from exc
    return lancedb


def db_table_names(db: Any) -> set[str]:
    if hasattr(db, "list_tables"):
        tables = db.list_tables()
        if hasattr(tables, "tables"):
            return set(tables.tables)
        return set(tables)
    return set(db.table_names())


def open_table(create: bool = False) -> Any:
    lancedb = require_lancedb()
    db = lancedb.connect(str(lancedb_path()))
    names = db_table_names(db)
    if TABLE_NAME in names:
        return db.open_table(TABLE_NAME)
    if create:
        return None
    raise RuntimeError("RAG index is empty; run make rag-index")


def delete_document(table: Any, document_id: str) -> None:
    try:
        table.delete(f"document_id = '{document_id}'")
    except Exception:
        # Older lancedb versions throw when a predicate matches no rows.
        pass


def add_rows(rows: list[dict[str, Any]]) -> None:
    lancedb = require_lancedb()
    db = lancedb.connect(str(lancedb_path()))
    if TABLE_NAME in db_table_names(db):
        table = db.open_table(TABLE_NAME)
        table.add(rows)
    else:
        db.create_table(TABLE_NAME, data=rows)


def build_rows(root: Path, path: Path, digest: str, embedder: Embedder) -> list[dict[str, Any]]:
    text = path.read_text(encoding="utf-8", errors="replace")
    metadata, chunks = chunk_document(path, text)
    relative = relpath(path, root)
    stat = path.stat()
    vectors = embedder.embed([chunk.text for chunk in chunks]) if chunks else []
    rows: list[dict[str, Any]] = []
    document_id = hashlib.sha256(relative.encode("utf-8")).hexdigest()
    for index, chunk in enumerate(chunks):
        rows.append(
            {
                "id": f"{document_id}:{index}",
                "document_id": document_id,
                "relative_path": relative,
                "source_path": str(path),
                "chunk_index": index,
                "text": chunk.text,
                "title": metadata["title"],
                "heading": chunk.heading,
                "extension": path.suffix.lower(),
                "mtime": float(stat.st_mtime),
                "sha256": digest,
                "tags": ",".join(metadata["tags"]),
                "links_json": json.dumps(metadata["links"], ensure_ascii=False),
                "frontmatter_json": json.dumps(metadata["frontmatter"], ensure_ascii=False),
                "headings_json": json.dumps(metadata["headings"], ensure_ascii=False),
                "vector": vectors[index],
            }
        )
    return rows


def index_documents(prune: bool = True) -> dict[str, Any]:
    root = source_path()
    if not root.exists():
        raise RuntimeError(f"RAG source path does not exist: {root}")
    index_path().mkdir(parents=True, exist_ok=True)
    lancedb_path().mkdir(parents=True, exist_ok=True)
    manifest = load_manifest()
    documents = manifest.setdefault("documents", {})
    embedder = Embedder()
    files = discover_files(root)
    seen: set[str] = set()
    changed = 0
    skipped = 0
    chunks_written = 0
    table = open_table(create=True)

    for path in files:
        relative = relpath(path, root)
        seen.add(relative)
        digest = sha256_file(path)
        stat = path.stat()
        current = documents.get(relative, {})
        if current.get("sha256") == digest:
            skipped += 1
            continue
        document_id = hashlib.sha256(relative.encode("utf-8")).hexdigest()
        if table is not None:
            delete_document(table, document_id)
        rows = build_rows(root, path, digest, embedder)
        if rows:
            add_rows(rows)
            table = open_table(create=True)
        documents[relative] = {
            "document_id": document_id,
            "sha256": digest,
            "mtime": float(stat.st_mtime),
            "size": int(stat.st_size),
            "chunks": len(rows),
        }
        changed += 1
        chunks_written += len(rows)

    pruned = 0
    if prune and table is not None:
        for relative in sorted(set(documents) - seen):
            delete_document(table, documents[relative]["document_id"])
            del documents[relative]
            pruned += 1

    manifest["updated_at"] = time.time()
    manifest["source_path"] = str(root)
    manifest["embedding_model"] = env("RAG_EMBEDDING_MODEL", "intfloat/multilingual-e5-small")
    manifest["embedding_backend"] = env("RAG_EMBEDDING_BACKEND", "sentence-transformers")
    save_manifest(manifest)
    return {
        "source_path": str(root),
        "documents": len(documents),
        "changed": changed,
        "skipped": skipped,
        "pruned": pruned,
        "chunks_written": chunks_written,
    }


def row_matches(row: dict[str, Any], filters: dict[str, Any]) -> bool:
    path_filter = filters.get("path")
    if path_filter and path_filter not in row.get("relative_path", ""):
        return False
    ext_filter = filters.get("extension")
    if ext_filter:
        ext = str(ext_filter)
        if not ext.startswith("."):
            ext = "." + ext
        if row.get("extension") != ext:
            return False
    tag_filter = filters.get("tag")
    if tag_filter:
        tags = {tag.strip() for tag in str(row.get("tags", "")).split(",") if tag.strip()}
        if str(tag_filter).lstrip("#") not in tags:
            return False
    modified_after = filters.get("modified_after")
    if modified_after:
        try:
            if float(row.get("mtime", 0)) < float(modified_after):
                return False
        except ValueError:
            return False
    return True


def search(query: str, top_k: int | None = None, filters: dict[str, Any] | None = None) -> dict[str, Any]:
    filters = filters or {}
    top_k = top_k or env_int("RAG_TOP_K", 8)
    table = open_table()
    embedder = Embedder()
    vector = embedder.embed([query], query=True)[0]
    # Fetch a wider candidate set so CLI-side filters still leave enough rows.
    rows = table.search(vector).limit(max(top_k * 5, top_k)).to_list()
    results = []
    for row in rows:
        if not row_matches(row, filters):
            continue
        text = str(row.get("text", ""))
        results.append(
            {
                "id": row.get("id"),
                "document_id": row.get("document_id"),
                "path": row.get("relative_path"),
                "title": row.get("title"),
                "heading": row.get("heading"),
                "extension": row.get("extension"),
                "score": float(row.get("_distance", 0.0)),
                "tags": [tag for tag in str(row.get("tags", "")).split(",") if tag],
                "excerpt": make_excerpt(text),
                "text": text,
            }
        )
        if len(results) >= top_k:
            break
    return {"query": query, "top_k": top_k, "results": results}


def make_excerpt(text: str, max_chars: int = 500) -> str:
    text = re.sub(r"\s+", " ", text).strip()
    if len(text) <= max_chars:
        return text
    return text[: max_chars - 1].rstrip() + "..."


def render_markdown(payload: dict[str, Any]) -> str:
    results = payload.get("results", [])
    if not results:
        return f"No RAG results for: {payload.get('query', '')}"
    lines = [f"RAG results for: {payload.get('query', '')}", ""]
    for idx, item in enumerate(results, start=1):
        heading = item.get("heading") or item.get("title") or item.get("path")
        lines.append(f"{idx}. {item.get('path')} - {heading}")
        lines.append(f"   score: {item.get('score'):.4f}")
        if item.get("tags"):
            lines.append(f"   tags: {', '.join(item['tags'])}")
        lines.append(f"   {item.get('excerpt', '')}")
        lines.append("")
    return "\n".join(lines).rstrip()


def get_document(document_id: str) -> dict[str, Any]:
    table = open_table()
    rows = table.search().where(f"document_id = '{document_id}'").limit(1000).to_list()
    rows = sorted(rows, key=lambda row: int(row.get("chunk_index", 0)))
    if not rows:
        raise KeyError(document_id)
    return {
        "document_id": document_id,
        "path": rows[0].get("relative_path"),
        "title": rows[0].get("title"),
        "chunks": [
            {
                "chunk_index": row.get("chunk_index"),
                "heading": row.get("heading"),
                "text": row.get("text"),
            }
            for row in rows
        ],
    }


def health() -> dict[str, Any]:
    manifest = load_manifest()
    table_exists = False
    try:
        table_exists = TABLE_NAME in db_table_names(require_lancedb().connect(str(lancedb_path())))
    except Exception:
        table_exists = False
    return {
        "ok": True,
        "enabled": env_bool("RAG_ENABLED", True),
        "source_path": env("RAG_SOURCE_PATH", env("OBSIDIAN_SHARED_PATH", "")),
        "index_path": str(index_path()),
        "table_exists": table_exists,
        "documents": len(manifest.get("documents", {})),
        "embedding_model": env("RAG_EMBEDDING_MODEL", "intfloat/multilingual-e5-small"),
        "embedding_backend": env("RAG_EMBEDDING_BACKEND", "sentence-transformers"),
    }


def serve() -> None:
    try:
        from fastapi import FastAPI, HTTPException, Request
        import uvicorn
    except ImportError as exc:
        raise RuntimeError("FastAPI/uvicorn missing; run make rag-install") from exc

    # With postponed annotations enabled, FastAPI resolves route annotations from
    # module globals rather than this function's local imports.
    globals()["Request"] = Request

    app = FastAPI(title="oMLX Agent Local RAG", version="0.4.0")

    @app.get("/health")
    def health_route() -> dict[str, Any]:
        return health()

    @app.post("/index")
    async def index_route(request: Request) -> dict[str, Any]:
        try:
            payload = await request.json()
        except Exception:
            payload = {}
        prune = bool(payload.get("prune", True)) if isinstance(payload, dict) else True
        return index_documents(prune=prune)

    @app.post("/search")
    async def search_route(request: Request) -> dict[str, Any]:
        try:
            payload = await request.json()
        except Exception as exc:
            raise HTTPException(status_code=400, detail="invalid JSON body") from exc
        if not isinstance(payload, dict):
            raise HTTPException(status_code=400, detail="JSON body must be an object")
        query = str(payload.get("query", "")).strip()
        if not query:
            raise HTTPException(status_code=400, detail="query is required")
        top_k = payload.get("top_k")
        if top_k is not None:
            try:
                top_k = int(top_k)
            except (TypeError, ValueError) as exc:
                raise HTTPException(status_code=400, detail="top_k must be an integer") from exc
            if top_k < 1 or top_k > 50:
                raise HTTPException(status_code=400, detail="top_k must be between 1 and 50")
        filters = payload.get("filters") or {}
        if not isinstance(filters, dict):
            raise HTTPException(status_code=400, detail="filters must be an object")
        return search(query, top_k=top_k, filters=filters)

    @app.get("/documents/{document_id}")
    def document_route(document_id: str) -> dict[str, Any]:
        try:
            return get_document(document_id)
        except KeyError as exc:
            raise HTTPException(status_code=404, detail="document not found") from exc

    host = env("RAG_BIND_HOST", env("RAG_HOST", "127.0.0.1"))
    port = env_int("RAG_PORT", 8765)
    uvicorn.run(app, host=host, port=port)


def doctor() -> int:
    ok = True
    print(f"enabled={env('RAG_ENABLED', '1')}")
    raw_source = env("RAG_SOURCE_PATH", env("OBSIDIAN_SHARED_PATH", ""))
    if raw_source in {"", "${OBSIDIAN_SHARED_PATH}", "${OBSIDIAN_SHARED_PATH:-}"}:
        raw_source = env("OBSIDIAN_SHARED_PATH", "")
    if raw_source:
        src = expand_path(raw_source)
        print(f"source={src}")
        if src.exists() and src.is_dir():
            print("source_status=ok")
        else:
            print("source_status=missing")
            ok = False
    else:
        print("source_status=unset")
        ok = False
    print(f"index={index_path()}")
    for module in ("lancedb", "fastapi", "uvicorn"):
        try:
            __import__(module)
            print(f"module_{module}=ok")
        except ImportError:
            print(f"module_{module}=missing")
            ok = False
    if env("RAG_EMBEDDING_BACKEND", "sentence-transformers") != "hash":
        try:
            __import__("sentence_transformers")
            print("module_sentence_transformers=ok")
        except ImportError:
            print("module_sentence_transformers=missing")
            ok = False
    print(json.dumps(health(), sort_keys=True))
    return 0 if ok else 2


def self_test() -> None:
    class ListTablesObject:
        tables = ["chunks", "archive"]

    class NewLanceDb:
        def list_tables(self) -> ListTablesObject:
            return ListTablesObject()

    class ListLanceDb:
        def list_tables(self) -> list[str]:
            return ["chunks"]

    class OldLanceDb:
        def table_names(self) -> list[str]:
            return ["legacy"]

    assert db_table_names(NewLanceDb()) == {"chunks", "archive"}
    assert db_table_names(ListLanceDb()) == {"chunks"}
    assert db_table_names(OldLanceDb()) == {"legacy"}

    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp) / "vault"
        root.mkdir()
        (root / ".obsidian").mkdir()
        (root / ".obsidian" / "workspace.json").write_text('{"secret": true}', encoding="utf-8")
        (root / "Nested" / "Vault" / ".obsidian").mkdir(parents=True)
        (root / "Nested" / "Vault" / ".obsidian" / "plugins.json").write_text('{"secret": true}', encoding="utf-8")
        (root / "Nested" / "Vault" / "nested.md").write_text("# Nested\n\nVisible note.", encoding="utf-8")
        (root / "note.md").write_text(
            "---\ntitle: Local RAG\ntags: [agent, obsidian]\n---\n"
            "# Local RAG\n\nThis note explains [[Hermes]] and OpenClaw search.\n\n# Details\n\nMore text.",
            encoding="utf-8",
        )
        (root / "data.json").write_text('{"project": "omlx", "kind": "rag"}', encoding="utf-8")
        (root / "secret.env").write_text("TOKEN=bad", encoding="utf-8")
        previous = dict(os.environ)
        try:
            os.environ["RAG_SOURCE_PATH"] = str(root)
            os.environ["RAG_TEXT_EXTENSIONS"] = ".md,.json"
            os.environ["RAG_EXCLUDE_GLOBS"] = DEFAULT_EXCLUDES
            files = [relpath(path, root) for path in discover_files(root)]
            assert set(files) == {"Nested/Vault/nested.md", "data.json", "note.md"}, files
            metadata, chunks = chunk_document(root / "note.md", (root / "note.md").read_text())
            assert metadata["title"] == "Local RAG"
            assert "agent" in metadata["tags"]
            assert "Hermes" in metadata["links"]
            assert chunks and "OpenClaw" in " ".join(chunk.text for chunk in chunks)
        finally:
            os.environ.clear()
            os.environ.update(previous)
    print("rag self-test ok")


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Local LanceDB RAG for Obsidian/text files.")
    sub = parser.add_subparsers(dest="command", required=True)
    sub.add_parser("doctor")
    sub.add_parser("index").add_argument("--no-prune", action="store_true")
    search_parser = sub.add_parser("search")
    search_parser.add_argument("query", nargs="*")
    search_parser.add_argument("--query", dest="query_opt")
    search_parser.add_argument("--top-k", type=int)
    search_parser.add_argument("--json", action="store_true")
    search_parser.add_argument("--path")
    search_parser.add_argument("--extension")
    search_parser.add_argument("--tag")
    search_parser.add_argument("--modified-after")
    sub.add_parser("serve")
    sub.add_parser("health")
    sub.add_parser("self-test")
    args = parser.parse_args(argv)

    try:
        if args.command == "doctor":
            return doctor()
        if args.command == "index":
            print(json.dumps(index_documents(prune=not args.no_prune), ensure_ascii=False, indent=2))
            return 0
        if args.command == "search":
            query = args.query_opt or " ".join(args.query).strip()
            if not query:
                raise RuntimeError("query is required")
            filters = {
                key: value
                for key, value in {
                    "path": args.path,
                    "extension": args.extension,
                    "tag": args.tag,
                    "modified_after": args.modified_after,
                }.items()
                if value
            }
            payload = search(query, top_k=args.top_k, filters=filters)
            if args.json:
                print(json.dumps(payload, ensure_ascii=False, indent=2))
            else:
                print(render_markdown(payload))
            return 0
        if args.command == "serve":
            serve()
            return 0
        if args.command == "health":
            print(json.dumps(health(), ensure_ascii=False, indent=2, sort_keys=True))
            return 0
        if args.command == "self-test":
            self_test()
            return 0
    except Exception as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 1
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
