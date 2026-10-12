#!/usr/bin/env python3
"""Bump Squad Six's version and promote Unreleased notes."""

from __future__ import annotations

import argparse
import json
import os
import re
import stat
import tempfile
from pathlib import Path
from re import Match, Pattern

ROOT = Path(__file__).resolve().parent.parent
CHANGELOG = ROOT / "CHANGELOG.md"
MODINFO = ROOT / "src/SquadSixReforged/modinfo.json"
ZCOM_MOD = ROOT / "src/SquadSixReforged/zcom-mod.json"
CORE_MODINFO = ROOT / "src/SquadSixReforged_Core/modinfo.json"
CORE_ZCOM_MOD = ROOT / "src/SquadSixReforged_Core/zcom-mod.json"
JSON_FILES = (MODINFO, ZCOM_MOD, CORE_MODINFO, CORE_ZCOM_MOD)
MAIN = ROOT / "src/SquadSixReforged/Scripts/main.lua"
README = ROOT / "src/SquadSixReforged/README.md"

SEMVER_PATTERN = re.compile(r"(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)")
JSON_VERSION_PATTERN = re.compile(
    r'^(?P<prefix>\s*"version"\s*:\s*")(?P<version>[^"]+)(?P<suffix>".*)$',
    re.MULTILINE,
)
MAIN_VERSION_PATTERN = re.compile(
    r'^(?P<prefix>\s*local\s+VERSION\s*=\s*")(?P<version>[^"]+)(?P<suffix>".*)$',
    re.MULTILINE,
)
# The player guide's title (tools/package.py checks it too).
README_HEADER_PATTERN = re.compile(
    r'^(?P<prefix># Squad Six Reforged v)(?P<version>[^\s]+)(?P<suffix> .*)$',
    re.MULTILINE,
)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Bump the mod version and promote CHANGELOG.md's Unreleased notes."
    )
    parser.add_argument(
        "part",
        type=str.lower,
        choices=("major", "minor", "patch"),
        help="semantic version component to bump (case-insensitive)",
    )
    return parser.parse_args()


def read_text(path: Path) -> str:
    try:
        return path.read_bytes().decode("utf-8")
    except FileNotFoundError as error:
        raise SystemExit(f"Required file does not exist: {path.relative_to(ROOT)}") from error
    except UnicodeDecodeError as error:
        raise SystemExit(f"Required file is not UTF-8: {path.relative_to(ROOT)}") from error


def extract_version(path: Path, text: str, pattern: Pattern[str]) -> str:
    matches = list(pattern.finditer(text))
    if len(matches) != 1:
        raise SystemExit(
            f"Expected exactly one version declaration in {path.relative_to(ROOT)}, "
            f"found {len(matches)}"
        )
    return matches[0].group("version")


def replace_version(
    path: Path,
    text: str,
    pattern: Pattern[str],
    current_version: str,
    next_version: str,
) -> str:
    def replacement(match: Match[str]) -> str:
        if match.group("version") != current_version:
            raise SystemExit(
                f"Version changed unexpectedly in {path.relative_to(ROOT)}: "
                f"{match.group('version')} != {current_version}"
            )
        return f"{match.group('prefix')}{next_version}{match.group('suffix')}"

    updated, count = pattern.subn(replacement, text)
    if count != 1:
        raise SystemExit(
            f"Expected exactly one version declaration in {path.relative_to(ROOT)}, "
            f"found {count}"
        )
    return updated


def bump_version(current_version: str, part: str) -> str:
    match = SEMVER_PATTERN.fullmatch(current_version)
    if match is None:
        raise SystemExit(
            f"Version must use semantic X.Y.Z without leading zeroes, got {current_version!r}"
        )

    major, minor, patch = (int(component) for component in match.groups())
    if part == "major":
        return f"{major + 1}.0.0"
    if part == "minor":
        return f"{major}.{minor + 1}.0"
    return f"{major}.{minor}.{patch + 1}"


def promote_unreleased(changelog: str, next_version: str) -> str:
    newline = "\r\n" if "\r\n" in changelog else "\n"
    heading_pattern = re.compile(r"^## \[Unreleased\][^\r\n]*(?:\r?\n|$)", re.MULTILINE)
    matches = list(heading_pattern.finditer(changelog))
    if len(matches) != 1:
        raise SystemExit(
            "Expected exactly one '## [Unreleased]' section in CHANGELOG.md, "
            f"found {len(matches)}"
        )

    if re.search(rf"^## \[{re.escape(next_version)}\](?:[^\r\n]*)$", changelog, re.MULTILINE):
        raise SystemExit(f"CHANGELOG.md already contains a [{next_version}] section")

    unreleased = matches[0]
    next_heading = re.search(r"^## ", changelog[unreleased.end() :], re.MULTILINE)
    section_end = (
        unreleased.end() + next_heading.start() if next_heading is not None else len(changelog)
    )
    release_notes = changelog[unreleased.end() : section_end].strip()
    if not release_notes:
        raise SystemExit("CHANGELOG.md's [Unreleased] section is empty")

    replacement = (
        f"## [Unreleased]{newline}{newline}"
        f"## [{next_version}]{newline}{newline}"
        f"{release_notes}{newline}{newline}"
    )
    return changelog[: unreleased.start()] + replacement + changelog[section_end:]


def write_updates(updates: dict[Path, str]) -> None:
    temporary_files: list[tuple[Path, Path]] = []
    try:
        for path, content in updates.items():
            descriptor, temporary_name = tempfile.mkstemp(
                dir=path.parent, prefix=f".{path.name}.", suffix=".tmp"
            )
            temporary_path = Path(temporary_name)
            temporary_files.append((temporary_path, path))
            os.chmod(temporary_path, stat.S_IMODE(path.stat().st_mode))
            with os.fdopen(descriptor, "wb") as stream:
                stream.write(content.encode("utf-8"))
                stream.flush()
                os.fsync(stream.fileno())

        for temporary_path, path in temporary_files:
            os.replace(temporary_path, path)
    finally:
        for temporary_path, _ in temporary_files:
            temporary_path.unlink(missing_ok=True)


def main() -> None:
    args = parse_args()
    texts = {path: read_text(path) for path in JSON_FILES}
    texts.update({
        MAIN: read_text(MAIN),
        README: read_text(README),
        CHANGELOG: read_text(CHANGELOG),
    })

    try:
        parsed = {path: json.loads(texts[path]) for path in JSON_FILES}
    except json.JSONDecodeError as error:
        raise SystemExit(f"Invalid JSON: {error}") from error

    versions = {path: extract_version(path, texts[path], JSON_VERSION_PATTERN) for path in JSON_FILES}
    versions[MAIN] = extract_version(MAIN, texts[MAIN], MAIN_VERSION_PATTERN)
    readme_version = extract_version(README, texts[README], README_HEADER_PATTERN)

    for path in JSON_FILES:
        if parsed[path].get("version") != versions[path]:
            raise SystemExit(f"Parsed {path.relative_to(ROOT)} version does not match its declaration")

    unique_versions = set(versions.values()) | {readme_version}
    if len(unique_versions) != 1:
        details = ", ".join(
            f"{path.relative_to(ROOT)}: {version}" for path, version in versions.items()
        )
        details += f", {README.relative_to(ROOT)} title: {readme_version}"
        raise SystemExit(f"Version declarations do not match: {details}")

    current_version = unique_versions.pop()
    next_version = bump_version(current_version, args.part)

    updates = {
        path: replace_version(path, texts[path], JSON_VERSION_PATTERN, current_version, next_version)
        for path in JSON_FILES
    }
    updates.update({
        MAIN: replace_version(
            MAIN, texts[MAIN], MAIN_VERSION_PATTERN, current_version, next_version
        ),
        README: replace_version(
            README, texts[README], README_HEADER_PATTERN, current_version, next_version
        ),
        CHANGELOG: promote_unreleased(texts[CHANGELOG], next_version),
    })
    write_updates(updates)
    print(f"Bumped version from {current_version} to {next_version}.")


if __name__ == "__main__":
    main()
