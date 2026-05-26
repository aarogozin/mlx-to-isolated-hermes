#!/usr/bin/env python3
"""Fail when tracked public files contain Cyrillic text."""

from __future__ import annotations

import re
import subprocess
import sys
from pathlib import Path


CYRILLIC_RE = re.compile(r"[\u0400-\u04FF]")


def tracked_files() -> list[Path]:
    output = subprocess.check_output(["git", "ls-files"], text=True)
    return [Path(line) for line in output.splitlines() if line.strip()]


def main() -> int:
    found = False
    for path in tracked_files():
        if not path.is_file():
            continue
        text = path.read_bytes().decode("utf-8", errors="ignore")
        for line_number, line in enumerate(text.splitlines(), start=1):
            if CYRILLIC_RE.search(line):
                print(f"{path}:{line_number}:{line}")
                found = True
    if found:
        print("ERROR: tracked files contain Cyrillic text; public docs/scripts should be English-only.", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
