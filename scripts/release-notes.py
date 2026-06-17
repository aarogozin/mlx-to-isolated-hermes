#!/usr/bin/env python3
"""Generate a concise release-note draft from git history."""

from __future__ import annotations

import argparse
import subprocess
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


def git(*args: str) -> str:
    return subprocess.check_output(["git", "-C", str(ROOT), *args], text=True).strip()


def latest_tag() -> str:
    try:
        return git("describe", "--tags", "--abbrev=0")
    except subprocess.CalledProcessError:
        return ""


def commit_lines(base: str, head: str) -> list[str]:
    range_arg = f"{base}..{head}" if base else head
    try:
        output = git("log", "--no-merges", "--pretty=format:%s", range_arg)
    except subprocess.CalledProcessError:
        return []
    return [line.strip() for line in output.splitlines() if line.strip()]


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--version", default=(ROOT / "VERSION").read_text().strip())
    parser.add_argument("--from", dest="base", default="")
    parser.add_argument("--to", dest="head", default="HEAD")
    args = parser.parse_args()

    base = args.base or latest_tag()
    commits = commit_lines(base, args.head)

    print(f"## {args.version}")
    print()
    if base:
        print(f"_Changes since `{base}`._")
        print()

    if not commits:
        print("- Maintenance release.")
        return 0

    seen: set[str] = set()
    for subject in commits:
        if subject in seen:
            continue
        seen.add(subject)
        print(f"- {subject}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
