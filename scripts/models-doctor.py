#!/usr/bin/env python3
"""Scan local model stores for incomplete downloads and optionally prune them."""

from __future__ import annotations

import argparse
import json
import os
import shutil
import struct
import sys
import time
from pathlib import Path


TEMP_SUFFIXES = (
    ".aria2",
    ".crdownload",
    ".download",
    ".downloading",
    ".incomplete",
    ".part",
    ".partial",
    ".tmp",
)
TEMP_NAMES = {
    ".download",
    ".download.lock",
    ".incomplete",
    ".partial",
    ".tmp",
    "download.lock",
}
WEIGHT_SUFFIXES = (".safetensors", ".gguf", ".bin", ".pt", ".pth")


def load_env(path: Path) -> dict[str, str]:
    values: dict[str, str] = {}
    if not path.exists():
        return values
    for raw in path.read_text(errors="ignore").splitlines():
        line = raw.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, value = line.split("=", 1)
        value = value.strip().strip('"').strip("'")
        value = value.replace("$HOME", str(Path.home()))
        values[key.strip()] = os.path.expandvars(os.path.expanduser(value))
    return values


def is_temp_path(path: Path) -> bool:
    name = path.name.lower()
    return name in TEMP_NAMES or any(name.endswith(suffix) for suffix in TEMP_SUFFIXES)


def is_old_enough(path: Path, min_age_seconds: float) -> bool:
    try:
        return (time.time() - path.stat().st_mtime) >= min_age_seconds
    except FileNotFoundError:
        return False


def validate_safetensors(path: Path) -> tuple[bool, str]:
    try:
        size = path.stat().st_size
        if size < 9:
            return False, "safetensors file too small"
        with path.open("rb") as fh:
            raw = fh.read(8)
            header_len = struct.unpack("<Q", raw)[0]
            if header_len <= 0 or header_len > 128 * 1024 * 1024:
                return False, "invalid safetensors header length"
            if size < 8 + header_len:
                return False, "truncated safetensors header"
            header = fh.read(header_len)
            json.loads(header.decode("utf-8"))
        return True, "ok"
    except Exception as exc:  # noqa: BLE001 - this is a diagnostic scanner.
        return False, f"invalid safetensors: {exc}"


def validate_gguf(path: Path) -> tuple[bool, str]:
    try:
        if path.stat().st_size < 64:
            return False, "gguf file too small"
        with path.open("rb") as fh:
            magic = fh.read(4)
        if magic not in {b"GGUF", b"FUGG"}:
            return False, "invalid gguf magic"
        return True, "ok"
    except Exception as exc:  # noqa: BLE001
        return False, f"invalid gguf: {exc}"


def remove_path(path: Path) -> str:
    try:
        if path.is_symlink() or path.is_file():
            path.unlink()
        elif path.is_dir():
            shutil.rmtree(path)
        return "removed"
    except FileNotFoundError:
        return "already-missing"
    except Exception as exc:  # noqa: BLE001
        return f"remove-failed:{exc}"


class Reporter:
    def __init__(self, delete: bool, min_age_seconds: float) -> None:
        self.delete = delete
        self.min_age_seconds = min_age_seconds
        self.issues = 0
        self.removed = 0

    def issue(self, kind: str, path: Path, detail: str, removable: bool = False) -> None:
        self.issues += 1
        action = "kept"
        if self.delete and removable and is_old_enough(path, self.min_age_seconds):
            action = remove_path(path)
            if action in {"removed", "already-missing"}:
                self.removed += 1
        elif self.delete and removable:
            action = "kept-young"
        print(f"{kind}\t{action}\t{path}\t{detail}")

    def ok(self, kind: str, path: Path, detail: str) -> None:
        print(f"{kind}\tok\t{path}\t{detail}")


def scan_model_dir(root: Path, label: str, reporter: Reporter) -> None:
    if not root.exists():
        reporter.ok(label, root, "missing")
        return

    reporter.ok(label, root, "scan-start")
    valid_weights = 0
    invalid_weights: list[tuple[Path, str]] = []
    temp_paths: list[Path] = []
    empty_dirs: list[Path] = []

    for dirpath, dirnames, filenames in os.walk(root):
        current = Path(dirpath)
        for dirname in list(dirnames):
            path = current / dirname
            if is_temp_path(path):
                temp_paths.append(path)
        for filename in filenames:
            path = current / filename
            lower = filename.lower()
            if is_temp_path(path):
                temp_paths.append(path)
                continue
            if path.is_symlink():
                continue
            if lower.endswith(".safetensors"):
                ok, detail = validate_safetensors(path)
                if ok:
                    valid_weights += 1
                else:
                    invalid_weights.append((path, detail))
            elif lower.endswith(".gguf"):
                ok, detail = validate_gguf(path)
                if ok:
                    valid_weights += 1
                else:
                    invalid_weights.append((path, detail))
            elif lower.endswith(WEIGHT_SUFFIXES):
                if path.stat().st_size > 0:
                    valid_weights += 1
                else:
                    invalid_weights.append((path, "zero-byte weight file"))
        try:
            if current != root and not any(current.iterdir()):
                empty_dirs.append(current)
        except OSError:
            pass

    for path in sorted(temp_paths):
        reporter.issue(f"{label}:temp", path, "temporary/incomplete download artifact", removable=True)
    for path, detail in invalid_weights:
        reporter.issue(f"{label}:invalid-weight", path, detail, removable=(valid_weights == 0))
    for path in sorted(empty_dirs, reverse=True):
        reporter.issue(f"{label}:empty-dir", path, "empty model directory", removable=True)

    reporter.ok(label, root, f"valid_weights={valid_weights} issues={len(temp_paths) + len(invalid_weights) + len(empty_dirs)}")


def scan_omlx_runtime(root: Path, reporter: Reporter) -> None:
    if not root.exists():
        reporter.ok("omlx-runtime", root, "missing")
        return
    for path in sorted(root.iterdir()):
        if path.is_symlink() and not path.exists():
            reporter.issue("omlx-runtime:broken-symlink", path, "symlink target missing", removable=True)
    scan_model_dir(root, "omlx-runtime", reporter)


def ollama_blob_path(root: Path, digest: str) -> Path:
    algo, value = digest.split(":", 1)
    return root / "blobs" / f"{algo}-{value}"


def scan_ollama(root: Path, reporter: Reporter) -> None:
    if not root.exists():
        reporter.ok("ollama", root, "missing")
        return

    manifests = root / "manifests"
    referenced: set[Path] = set()
    if manifests.exists():
        for manifest in manifests.rglob("*"):
            if not manifest.is_file():
                continue
            try:
                data = json.loads(manifest.read_text())
            except Exception as exc:  # noqa: BLE001
                reporter.issue("ollama:bad-manifest", manifest, f"invalid json: {exc}", removable=True)
                continue
            digests = []
            config = data.get("config")
            if isinstance(config, dict) and isinstance(config.get("digest"), str):
                digests.append(config["digest"])
            for layer in data.get("layers", []):
                if isinstance(layer, dict) and isinstance(layer.get("digest"), str):
                    digests.append(layer["digest"])
            missing = []
            for digest in digests:
                try:
                    blob = ollama_blob_path(root, digest)
                except ValueError:
                    missing.append(digest)
                    continue
                referenced.add(blob)
                if not blob.exists() or blob.stat().st_size == 0:
                    missing.append(digest)
            if missing:
                reporter.issue("ollama:incomplete-manifest", manifest, "missing blobs=" + ",".join(missing), removable=True)

    blobs = root / "blobs"
    if blobs.exists():
        for path in blobs.iterdir():
            if is_temp_path(path) or path.stat().st_size == 0:
                reporter.issue("ollama:temp-blob", path, "temporary or zero-byte blob", removable=True)
    reporter.ok("ollama", root, "scan-complete")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--delete", action="store_true", help="remove safely identified incomplete artifacts")
    parser.add_argument("--strict", action="store_true", help="exit non-zero when issues are found")
    args = parser.parse_args()

    project_root = Path(__file__).resolve().parents[1]
    env = load_env(project_root / ".env")
    min_age_hours = float(os.environ.get("MODEL_CLEAN_MIN_AGE_HOURS", env.get("MODEL_CLEAN_MIN_AGE_HOURS", "1")))
    reporter = Reporter(args.delete or os.environ.get("DELETE") == "1", min_age_hours * 3600)

    lm_dirs = [
        Path(env.get("MODEL_DIR", str(Path.home() / ".lmstudio/models"))),
        Path.home() / ".lmstudio/models",
        Path.home() / "Library/Application Support/LM Studio/models",
    ]
    seen: set[Path] = set()
    for root in lm_dirs:
        root = root.expanduser().resolve()
        if root in seen:
            continue
        seen.add(root)
        scan_model_dir(root, "lmstudio", reporter)

    scan_omlx_runtime(project_root / ".runtime/omlx-models", reporter)
    scan_ollama(Path(os.environ.get("OLLAMA_MODELS", env.get("OLLAMA_MODELS", str(Path.home() / ".ollama/models")))).expanduser(), reporter)

    print(f"summary\tissues={reporter.issues}\tremoved={reporter.removed}\tdelete={str(reporter.delete).lower()}")
    if args.strict and reporter.issues:
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
