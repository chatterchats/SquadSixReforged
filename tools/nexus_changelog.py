#!/usr/bin/env python3
"""Convert one Keep a Changelog release section to Nexus-friendly plain text."""

from __future__ import annotations

import argparse
from pathlib import Path
import re


def release_body(changelog: str, version: str) -> str:
    section = re.search(
        rf"^## \[{re.escape(version)}\][^\r\n]*(?:\r?\n)(?P<body>.*?)(?=^## \[|\Z)",
        changelog,
        flags=re.MULTILINE | re.DOTALL,
    )
    if section is None or not section.group("body").strip():
        raise ValueError(f"CHANGELOG.md has no non-empty [{version}] section")
    return section.group("body").strip()


def plain_text(value: str) -> str:
    value = re.sub(r"`([^`]*)`", r"\1", value)
    value = re.sub(r"\[([^]]+)]\([^)]+\)", r"\1", value)
    value = value.replace("**", "").replace("__", "")
    return " ".join(value.split())


def format_for_nexus(body: str) -> str:
    """Collapse Markdown categories and wrapped bullets into one plain line each."""
    entries: list[tuple[str | None, str]] = []
    category: str | None = None
    current: list[str] = []

    def finish_entry() -> None:
        nonlocal current
        if not current:
            return
        entries.append((category, plain_text(" ".join(current))))
        current = []

    for raw_line in body.splitlines():
        line = raw_line.strip()
        if not line:
            continue

        heading = re.fullmatch(r"###\s+(.+)", line)
        if heading is not None:
            finish_entry()
            category = plain_text(heading.group(1))
            continue

        if line.startswith("- "):
            finish_entry()
            current = [line[2:]]
        else:
            current.append(line)

    finish_entry()

    if not entries:
        raise ValueError("release section contains no changelog entries")

    return "\n".join(
        f"{entry_category}: {text}" if entry_category else text
        for entry_category, text in entries
    )


def nexus_changelog(changelog: str, version: str) -> str:
    return format_for_nexus(release_body(changelog, version))


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Print one CHANGELOG.md release in Nexus-friendly plain text."
    )
    parser.add_argument("version", help="release version to extract")
    parser.add_argument(
        "changelog",
        nargs="?",
        type=Path,
        default=Path("CHANGELOG.md"),
        help="changelog path (default: CHANGELOG.md)",
    )
    args = parser.parse_args()

    try:
        print(nexus_changelog(args.changelog.read_text(encoding="utf-8"), args.version))
    except (OSError, ValueError) as error:
        raise SystemExit(str(error)) from error


if __name__ == "__main__":
    main()
