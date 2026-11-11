#!/usr/bin/env python3
"""The one tool behind every mod repo's `make` targets.

SHARED FILE: owned by ModTemplate and copied in by `make sync`. Edit it in ModTemplate,
never in a mod repo (`make check` reports local edits). Per-repo behaviour comes from
release.json and the Makefile's hook targets; see ModTemplate/STANDARD.md.
"""
from __future__ import annotations

import argparse
import datetime
import fnmatch
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import zipfile
from pathlib import Path

ROOT = Path.cwd()
SEMVER = re.compile(r"(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)")
SHARED_MANIFEST = Path("tools/.shared.sha256")
CONFIG_FILE = Path.home() / ".config" / "zcom" / "main-install"
INSTALL_ENV = "ZCOM_MAIN_INSTALL"
TEMPLATE_ENV = "MODTEMPLATE"
INSTALL_MARKER = ".installed-by-modtool"
# Where each kind of shipped folder lives, relative to the game's SWZeroCompany folder.
KIND_DEST = {
    "ue4ss": "Binaries/Win64/ue4ss/Mods",
    "pak": "Content/Paks/~mods",
}
ZIP_LAYOUTS = ("folder", "game")
# Top level of a mod repo. Required items must exist; the rest are allowed.
REQUIRED_FILES = ("Makefile", "README.md", "CHANGELOG.md", "CLAUDE.md", "release.json")
REQUIRED_DIRS = ("src", "tests", "tools", "docs", "docs/nexus", ".github/workflows")
OPTIONAL = {"LICENSE", "CREDITS.md", "dev", "unreal", "native", "dist",
            ".git", ".github", ".gitignore", ".gitattributes", ".claude"}
FIXED_TIME = (1980, 1, 1, 0, 0, 0)  # zip timestamps, so a tag always rebuilds the same zip


class Fail(Exception):
    pass


# ---------------------------------------------------------------- release.json

def load_release(root: Path = ROOT) -> dict:
    path = root / "release.json"
    if not path.is_file():
        raise Fail("release.json is missing (see ModTemplate/STANDARD.md)")
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except json.JSONDecodeError as error:
        raise Fail(f"release.json is not valid JSON: {error}") from error
    for key in ("name", "title", "version", "shipped"):
        if key not in data:
            raise Fail(f"release.json needs '{key}'")
    if not SEMVER.fullmatch(data["version"]):
        raise Fail(f"release.json version must be X.Y.Z, got {data['version']!r}")
    data.setdefault("zipLayout", "folder")
    if data["zipLayout"] not in ZIP_LAYOUTS:
        raise Fail(f"release.json zipLayout must be one of {ZIP_LAYOUTS}")
    if not data["shipped"]:
        raise Fail("release.json 'shipped' lists no folders")
    for item in data["shipped"]:
        item.setdefault("kind", "ue4ss")
        item.setdefault("install", "link")
        item.setdefault("exclude", [])
        item.setdefault("notices", item["kind"] == "ue4ss")
        if item["kind"] not in KIND_DEST:
            raise Fail(f"shipped folder {item.get('folder')!r}: kind must be one of {sorted(KIND_DEST)}")
        if item["install"] not in ("link", "copy"):
            raise Fail(f"shipped folder {item['folder']!r}: install must be 'link' or 'copy'")
    return data


# ---------------------------------------------------------------- version spots

def formatted(version: str, fmt: str) -> str:
    """A version as a spot stores it: "plain" X.Y.Z, or "packed" major*10000+minor*100+patch."""
    if fmt == "packed":
        major, minor, patch = map(int, SEMVER.fullmatch(version).groups())
        return str(major * 10000 + minor * 100 + patch)
    return version


def version_spots(release: dict, root: Path = ROOT) -> list[tuple[Path, re.Pattern, str]]:
    """Every place the version is written: (file, pattern with one capture group, format)."""
    spots = []
    for item in release["shipped"]:
        folder = root / "src" / item["folder"]
        for name in ("modinfo.json", "zcom-mod.json"):
            if (folder / name).is_file():
                spots.append((folder / name, re.compile(r'"version"\s*:\s*"([^"]*)"'), "plain"))
        main = folder / "Scripts" / "main.lua"
        if main.is_file():
            spots.append((main, re.compile(r'^local VERSION\s*=\s*"([^"]*)"', re.M), "plain"))
        settings = folder / "MXM" / "settings.lua"
        if settings.is_file() and re.search(r'^\s*version\s*=\s*"', settings.read_text(encoding="utf-8"), re.M):
            spots.append((settings, re.compile(r'^\s*version\s*=\s*"([^"]*)"', re.M), "plain"))
    for extra in release.get("versionSpots", []):
        spots.append((root / extra["file"], re.compile(extra["pattern"], re.M), extra.get("format", "plain")))
    return spots


def read_versions(release: dict, root: Path = ROOT) -> list[tuple[Path, str, str]]:
    found = []
    for path, pattern, fmt in version_spots(release, root):
        if not path.is_file():
            raise Fail(f"version spot {path.relative_to(root)} does not exist")
        matches = pattern.findall(path.read_text(encoding="utf-8"))
        if len(matches) != 1:
            raise Fail(f"{path.relative_to(root)}: expected one version, found {len(matches)}")
        found.append((path, matches[0], fmt))
    return found


def version_problems(release: dict, root: Path = ROOT) -> list[str]:
    return [f"{path.relative_to(root)} says {found}, release.json says {release['version']}"
            for path, found, fmt in read_versions(release, root)
            if found != formatted(release["version"], fmt)]


# ---------------------------------------------------------------- changelog

def changelog_section(version: str, root: Path = ROOT) -> str:
    text = (root / "CHANGELOG.md").read_text(encoding="utf-8")
    match = re.search(rf"^## \[{re.escape(version)}\][^\n]*\n(?P<body>.*?)(?=^## \[|\Z)",
                      text, re.M | re.S)
    if match is None or not match.group("body").strip():
        raise Fail(f"CHANGELOG.md has no non-empty [{version}] section")
    return match.group("body").strip()


def plain(value: str) -> str:
    value = re.sub(r"`([^`]*)`", r"\1", value)
    value = re.sub(r"\[([^]]+)]\([^)]+\)", r"\1", value)
    return " ".join(value.replace("**", "").replace("__", "").split())


def nexus_text(body: str) -> str:
    """A changelog section as Nexus plain text: one line per entry, category-prefixed."""
    entries, category, current = [], None, []

    def finish():
        if current:
            entries.append((category, plain(" ".join(current))))
            current.clear()

    for line in (raw.strip() for raw in body.splitlines()):
        if not line:
            continue
        heading = re.fullmatch(r"###\s+(.+)", line)
        if heading:
            finish()
            category = plain(heading.group(1))
        elif line.startswith("- "):
            finish()
            current.append(line[2:])
        else:
            current.append(line)
    finish()
    return "\n".join(f"{cat}: {entry}" if cat else entry for cat, entry in entries)


def promote_unreleased(text: str, version: str, today: str) -> str:
    heads = list(re.finditer(r"^## \[Unreleased\][^\n]*\n?", text, re.M))
    if len(heads) != 1:
        raise Fail(f"CHANGELOG.md needs exactly one '## [Unreleased]' heading, found {len(heads)}")
    if re.search(rf"^## \[{re.escape(version)}\]", text, re.M):
        raise Fail(f"CHANGELOG.md already has a [{version}] section")
    head = heads[0]
    following = re.search(r"^## ", text[head.end():], re.M)
    end = head.end() + following.start() if following else len(text)
    notes = text[head.end():end].strip()
    if not notes:
        raise Fail("CHANGELOG.md's [Unreleased] section is empty: write the notes first")
    return (text[:head.start()] + f"## [Unreleased]\n\n## [{version}] - {today}\n\n{notes}\n\n"
            + text[end:])


# ---------------------------------------------------------------- packaging

def git(*args: str, root: Path = ROOT, check: bool = True) -> str:
    result = subprocess.run(["git", *args], cwd=root, capture_output=True, text=True)
    if check and result.returncode != 0:
        raise Fail(f"git {' '.join(args)} failed: {result.stderr.strip()}")
    return result.stdout


def shipped_files(item: dict, root: Path = ROOT) -> list[Path]:
    """A shipped folder's git-tracked files, minus its excludes and logs."""
    folder = root / "src" / item["folder"]
    if not folder.is_dir():
        raise Fail(f"shipped folder src/{item['folder']} does not exist")
    listed = git("ls-files", "-z", "--", f"src/{item['folder']}", root=root).split("\0")
    files = []
    for name in sorted(filter(None, listed)):
        path = root / name
        inside = path.relative_to(folder).as_posix()
        if inside.endswith(".log") or any(fnmatch.fnmatch(inside, pat) for pat in item["exclude"]):
            continue
        if not path.is_file() or path.is_symlink():
            raise Fail(f"{name} is tracked but missing or a symlink")
        files.append(path)
    if not files:
        raise Fail(f"src/{item['folder']} has no tracked files to ship")
    return files


def archive_prefix(release: dict, item: dict) -> str:
    if release["zipLayout"] == "game":
        return f"{KIND_DEST[item['kind']]}/{item['folder']}"
    return item["folder"]


def package_entries(release: dict, root: Path = ROOT) -> dict[str, Path]:
    entries: dict[str, Path] = {}
    notices = [root / name for name in ("LICENSE", "CREDITS.md") if (root / name).is_file()]
    for item in release["shipped"]:
        prefix = archive_prefix(release, item)
        folder = root / "src" / item["folder"]
        for path in shipped_files(item, root):
            entries[f"{prefix}/{path.relative_to(folder).as_posix()}"] = path
        if item["notices"]:  # copies keep the licence and credits
            for notice in notices:
                entries.setdefault(f"{prefix}/{notice.name}", notice)
    return entries


def zip_name(release: dict) -> str:
    return f"{release['name']}-{release['version']}.zip"


def write_zip(entries: dict[str, Path], output: Path) -> None:
    output.parent.mkdir(parents=True, exist_ok=True)
    temporary = output.with_suffix(".zip.tmp")
    with zipfile.ZipFile(temporary, "w", zipfile.ZIP_DEFLATED, compresslevel=9) as archive:
        for name in sorted(entries):
            info = zipfile.ZipInfo(name, FIXED_TIME)
            info.compress_type = zipfile.ZIP_DEFLATED
            info.external_attr = 0o644 << 16
            archive.writestr(info, entries[name].read_bytes())
    os.replace(temporary, output)


def zip_matches(output: Path, entries: dict[str, Path]) -> bool:
    with zipfile.ZipFile(output) as archive:
        return (set(archive.namelist()) == set(entries)
                and all(archive.read(name) == path.read_bytes() for name, path in entries.items()))


def package(root: Path = ROOT, out_dir: Path | None = None, force: bool = False) -> Path:
    release = load_release(root)
    problems = version_problems(release, root)
    if problems:
        raise Fail("versions disagree (run `make bump`):\n  " + "\n  ".join(problems))
    entries = package_entries(release, root)
    output = (out_dir or root / "dist") / zip_name(release)
    if output.exists() and not force and not zip_matches(output, entries):
        raise Fail(f"{output.name} already exists with different contents: bump the version "
                   "(or `make package FORCE=1` for a throwaway test build)")
    write_zip(entries, output)
    if not zip_matches(output, entries):
        raise Fail("zip verification failed")
    digest = hashlib.sha256(output.read_bytes()).hexdigest()
    output.with_name(output.name + ".sha256").write_text(f"{digest}  {output.name}\n", encoding="utf-8")
    print(f"{output.relative_to(root) if output.is_relative_to(root) else output}: "
          f"{len(entries)} files, sha256 {digest}")
    return output


# ---------------------------------------------------------------- install

def main_install() -> Path:
    raw = os.environ.get(INSTALL_ENV, "").strip()
    if not raw and CONFIG_FILE.is_file():
        raw = CONFIG_FILE.read_text(encoding="utf-8").strip()
    if not raw:
        raise Fail(f"main install unknown: put the game's SWZeroCompany folder path in {CONFIG_FILE} "
                   f"(or set {INSTALL_ENV})")
    path = Path(raw).expanduser()
    if not (path / "Binaries").is_dir():
        raise Fail(f"{path} doesn't look like the game's SWZeroCompany folder (no Binaries/)")
    return path


def install(root: Path = ROOT) -> None:
    release, game = load_release(root), main_install()
    for item in release["shipped"]:
        source = (root / "src" / item["folder"]).resolve()
        target = game / KIND_DEST[item["kind"]] / item["folder"]
        target.parent.mkdir(parents=True, exist_ok=True)
        if item["install"] == "link":
            if target.is_symlink():
                if target.resolve() == source:
                    print(f"already linked: {target}")
                    continue
                print(f"relinking {target} (was {os.readlink(target)})")
                target.unlink()
            elif target.exists():
                raise Fail(f"{target} exists and is not a link: move it aside first")
            target.symlink_to(source, target_is_directory=True)
            print(f"linked {target} -> {source}")
        else:
            if target.is_symlink():
                target.unlink()
            elif target.exists():
                if not (target / INSTALL_MARKER).exists():
                    raise Fail(f"{target} exists and wasn't installed by modtool: move it aside first")
                shutil.rmtree(target)
            folder = root / "src" / item["folder"]
            for path in shipped_files(item, root):
                dest = target / path.relative_to(folder)
                dest.parent.mkdir(parents=True, exist_ok=True)
                shutil.copy2(path, dest)
            (target / INSTALL_MARKER).write_text(f"{root}\n", encoding="utf-8")
            print(f"copied src/{item['folder']} -> {target}")


def uninstall(root: Path = ROOT) -> None:
    release, game = load_release(root), main_install()
    for item in release["shipped"]:
        source = (root / "src" / item["folder"]).resolve()
        target = game / KIND_DEST[item["kind"]] / item["folder"]
        if target.is_symlink():
            if target.resolve() != source:
                print(f"left alone: {target} links elsewhere ({os.readlink(target)})")
                continue
            target.unlink()
            print(f"removed link {target}")
        elif (target / INSTALL_MARKER).exists():
            shutil.rmtree(target)
            print(f"removed copy {target}")
        elif target.exists():
            print(f"left alone: {target} wasn't installed by modtool")
        else:
            print(f"not installed: {target}")


# ---------------------------------------------------------------- tests

def run_tests(root: Path = ROOT, names: list[str] | None = None) -> None:
    tests = sorted((root / "tests").glob("*_test.lua")) + sorted((root / "tests").glob("*_test.py"))
    if names:
        tests = [t for t in tests if t.stem in names or t.name in names]
    if os.environ.get("SKIP_LUA_TESTS") == "1":
        skipped = [t for t in tests if t.suffix == ".lua"]
        if skipped:
            print(f"warning: SKIP_LUA_TESTS=1, skipping {len(skipped)} Lua tests")
            tests = [t for t in tests if t.suffix != ".lua"]
    if not tests:
        print("no tests found (tests/*_test.lua, tests/*_test.py)")
        return
    failed = []
    for test in tests:
        command = ["luajit" if test.suffix == ".lua" else sys.executable, str(test.relative_to(root))]
        result = subprocess.run(command, cwd=root, capture_output=True, text=True)
        if result.returncode == 0:
            print(f"ok    {test.name}")
        else:
            failed.append(test.name)
            print(f"FAIL  {test.name}")
            print("\n".join("      " + line for line in (result.stdout + result.stderr).splitlines()[-30:]))
    print(f"{len(tests) - len(failed)} passed, {len(failed)} failed")
    if failed:
        raise Fail("tests failed: " + ", ".join(failed))


# ---------------------------------------------------------------- shared files

def template_root(root: Path = ROOT) -> Path | None:
    raw = os.environ.get(TEMPLATE_ENV)
    candidate = Path(raw).expanduser() if raw else root.parent / "ModTemplate"
    return candidate if (candidate / "shared").is_dir() else None


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def read_manifest(root: Path = ROOT) -> dict[str, str]:
    path = root / SHARED_MANIFEST
    if not path.is_file():
        return {}
    entries = {}
    for line in path.read_text(encoding="utf-8").splitlines():
        if line and not line.startswith("#"):
            digest, name = line.split(None, 1)
            entries[name] = digest
    return entries


def sync(root: Path = ROOT) -> None:
    template = template_root(root)
    if template is None:
        raise Fail(f"ModTemplate not found at {root.parent / 'ModTemplate'} (set {TEMPLATE_ENV})")
    shared = template / "shared"
    previous = read_manifest(root)
    names = sorted(p.relative_to(shared).as_posix() for p in shared.rglob("*")
                   if p.is_file() and "__pycache__" not in p.parts)
    for name in names:
        source, target = shared / name, root / name
        if target.is_file() and name in previous and sha256(target) != previous[name]:
            raise Fail(f"{name} was edited in this repo: move the change to ModTemplate, then sync")
        target.parent.mkdir(parents=True, exist_ok=True)
        if not target.is_file() or target.read_bytes() != source.read_bytes():
            shutil.copy2(source, target)
            print(f"updated {name}")
    for gone in sorted(set(previous) - set(names)):
        if (root / gone).is_file():
            (root / gone).unlink()
            print(f"removed {gone} (no longer shared)")
    commit = git("rev-parse", "--short", "HEAD", root=template, check=False).strip() or "uncommitted"
    lines = [f"# Shared files from ModTemplate {commit}. Written by `make sync`; do not edit."]
    lines += [f"{sha256(root / name)}  {name}" for name in names]
    (root / SHARED_MANIFEST).write_text("\n".join(lines) + "\n", encoding="utf-8")
    print(f"in sync with ModTemplate {commit}")


# ---------------------------------------------------------------- check

def check(root: Path = ROOT, ci: bool = False) -> None:
    errors: list[str] = []
    warnings: list[str] = []
    try:
        release = load_release(root)
    except Fail as error:
        raise Fail(f"drift: {error}") from error

    if root.resolve().name != release["name"] and not ci:
        errors.append(f"folder is named {root.resolve().name!r} but release.json name is {release['name']!r}")
    for name in REQUIRED_FILES:
        if not (root / name).is_file():
            errors.append(f"missing {name}")
    for name in REQUIRED_DIRS:
        if not (root / name).is_dir():
            errors.append(f"missing {name}/")
    if not (root / "LICENSE").is_file():
        if not release.get("licence"):
            errors.append("missing LICENSE (or a 'licence' exemption in release.json)")
        elif not (root / "CREDITS.md").is_file():
            errors.append("release.json exempts LICENSE, so CREDITS.md is required")
    allowed = set(REQUIRED_FILES) | {d.split("/")[0] for d in REQUIRED_DIRS} | OPTIONAL
    for entry in sorted(root.iterdir()):
        if entry.name not in allowed:
            errors.append(f"non-standard top-level item: {entry.name}"
                          + (" (merge into tools/)" if entry.name == "scripts" else ""))
    if release.get("nexusModId"):
        for name in ("description.bbcode", "summary.txt"):
            if not (root / "docs" / "nexus" / name).is_file():
                errors.append(f"missing docs/nexus/{name} (release.json has a nexusModId)")
    makefile = root / "Makefile"
    if makefile.is_file() and not re.search(r"^include tools/mod\.mk\s*$", makefile.read_text(encoding="utf-8"), re.M):
        errors.append("Makefile must 'include tools/mod.mk'")
    if subprocess.run(["git", "check-ignore", "-q", "dist/x.zip"], cwd=root).returncode != 0:
        errors.append("dist/ is not gitignored")
    tracked_dist = git("ls-files", "dist", root=root, check=False).strip()
    if tracked_dist:
        errors.append("files under dist/ are committed")

    for item in release["shipped"]:
        if not (root / "src" / item["folder"]).is_dir():
            errors.append(f"shipped folder src/{item['folder']} does not exist")
    try:
        errors += version_problems(release, root)
    except Fail as error:
        errors.append(str(error))
    changelog = root / "CHANGELOG.md"
    if changelog.is_file():
        text = changelog.read_text(encoding="utf-8")
        if not re.search(r"^## \[Unreleased\]", text, re.M):
            errors.append("CHANGELOG.md has no '## [Unreleased]' heading")
        if not re.search(rf"^## \[{re.escape(release['version'])}\]", text, re.M):
            errors.append(f"CHANGELOG.md has no [{release['version']}] section")

    manifest = read_manifest(root)
    if not manifest:
        errors.append(f"{SHARED_MANIFEST} is missing: run `make sync`")
    for name, digest in manifest.items():
        path = root / name
        if not path.is_file():
            errors.append(f"shared file {name} is missing: run `make sync`")
        elif sha256(path) != digest:
            errors.append(f"shared file {name} was edited here: change it in ModTemplate, then `make sync`")
    template = None if ci else template_root(root)
    if template is not None:
        shared = template / "shared"
        current = {p.relative_to(shared).as_posix(): sha256(p) for p in shared.rglob("*")
                   if p.is_file() and "__pycache__" not in p.parts}
        if current != manifest:
            warnings.append("ModTemplate has newer shared files: run `make sync`")

    for warning in warnings:
        print(f"warning: {warning}")
    if errors:
        raise Fail("drift from the standard:\n  " + "\n  ".join(errors))
    print(f"{release['name']} {release['version']}: conforms to the standard")


# ---------------------------------------------------------------- bump / release

def bump(spec: str, root: Path = ROOT, today: str | None = None) -> None:
    release = load_release(root)
    current = release["version"]
    if spec in ("major", "minor", "patch"):
        major, minor, patch = map(int, SEMVER.fullmatch(current).groups())
        spec = {"major": f"{major + 1}.0.0", "minor": f"{major}.{minor + 1}.0",
                "patch": f"{major}.{minor}.{patch + 1}"}[spec]
    if not SEMVER.fullmatch(spec):
        raise Fail(f"V must be X.Y.Z or major/minor/patch, got {spec!r}")
    problems = version_problems(release, root)
    if problems:
        print("fixing versions that disagreed:\n  " + "\n  ".join(problems))
    updates: dict[Path, str] = {}
    for path, pattern, fmt in version_spots(release, root):
        text = updates.get(path, path.read_text(encoding="utf-8"))
        value = formatted(spec, fmt)
        updates[path] = pattern.sub(lambda m: m.group(0)[:m.start(1) - m.start(0)] + value
                                    + m.group(0)[m.end(1) - m.start(0):], text, count=1)
        # "-- <Title> vX.Y.Z" header lines in main.lua follow along
        if path.name == "main.lua":
            updates[path] = re.sub(r"^(--.* v)" + re.escape(current) + r"\b", r"\g<1>" + spec,
                                   updates[path], count=1, flags=re.M)
    release_text = (root / "release.json").read_text(encoding="utf-8")
    updates[root / "release.json"] = re.sub(r'("version"\s*:\s*")[^"]*(")', rf"\g<1>{spec}\2",
                                            release_text, count=1)
    changelog = root / "CHANGELOG.md"
    updates[changelog] = promote_unreleased(changelog.read_text(encoding="utf-8"), spec,
                                            today or datetime.date.today().isoformat())
    for path, text in updates.items():
        path.write_text(text, encoding="utf-8")
    print(f"{release['name']}: {current} -> {spec}")


def release_cmd(root: Path = ROOT, push: bool = True) -> None:
    release = load_release(root)
    tag = f"v{release['version']}"
    if git("status", "--porcelain", root=root).strip():
        raise Fail("working tree has uncommitted changes")
    branch = git("branch", "--show-current", root=root).strip()
    if branch != "main":
        raise Fail(f"release from main, not {branch or 'a detached HEAD'}")
    if git("tag", "--list", tag, root=root).strip():
        raise Fail(f"{tag} already exists: `make bump` first")
    check(root)
    changelog_section(release["version"], root)
    run_tests(root)
    package(root)
    git("tag", "-a", tag, "-m", f"{release['title']} {release['version']}", root=root)
    print(f"tagged {tag}")
    if push:
        git("push", "origin", "main", tag, root=root)
        print(f"pushed main and {tag}: CI builds the GitHub release"
              + (" and uploads to Nexus" if release.get("nexusModId") else ""))
    else:
        print(f"not pushed: git push origin main {tag}")


# ---------------------------------------------------------------- CI helpers

def ci_meta(root: Path = ROOT) -> None:
    """Release facts for the workflow, as GITHUB_OUTPUT lines; fails if the tag doesn't match."""
    release = load_release(root)
    ref = os.environ.get("RELEASE_TAG", "")
    if ref and ref != f"v{release['version']}":
        raise Fail(f"tag {ref} doesn't match release.json version {release['version']}")
    body = changelog_section(release["version"], root)
    (root / "dist").mkdir(exist_ok=True)
    (root / "dist" / "notes.md").write_text(body + "\n", encoding="utf-8")
    lines = {
        "version": release["version"],
        "title": release["title"],
        "zip": zip_name(release),
        "nexus_mod_id": str(release.get("nexusModId") or ""),
    }
    delimiter = "EOF_" + hashlib.sha256(body.encode()).hexdigest()[:16]
    out = "".join(f"{key}={value}\n" for key, value in lines.items())
    out += f"nexus_changelog<<{delimiter}\n{nexus_text(body)}\n{delimiter}\n"
    target = os.environ.get("GITHUB_OUTPUT")
    if target:
        with open(target, "a", encoding="utf-8") as stream:
            stream.write(out)
    else:
        print(out, end="")


def nexus_ids(root: Path = ROOT) -> None:
    """Resolve the Nexus mod's unique ID and its single active file, as GITHUB_OUTPUT lines."""
    from urllib.error import HTTPError
    from urllib.parse import quote
    from urllib.request import Request, urlopen

    release = load_release(root)
    key = os.environ.get("NEXUSMODS_API_KEY", "").strip()
    if not key:
        raise Fail("NEXUSMODS_API_KEY is empty")

    def get(path: str) -> dict:
        request = Request(f"https://api.nexusmods.com/v3{path}",
                          headers={"apikey": key, "User-Agent": f"{release['name']} release workflow"})
        try:
            with urlopen(request, timeout=30) as response:
                return json.load(response)
        except HTTPError as error:
            raise Fail(f"Nexus API {path}: {error.code} {error.read().decode(errors='replace')}") from error

    mod_id = get(f"/games/starwarszerocompany/mods/{release['nexusModId']}").get("data", {}).get("id")
    if not mod_id:
        raise Fail("Nexus API returned no mod ID")
    files = [f for f in get(f"/mods/{quote(mod_id, safe='')}/files").get("data", {}).get("mod_files", [])
             if f.get("is_active")]
    if len(files) != 1:
        raise Fail(f"expected one active Nexus file, found {len(files)}: "
                   + ", ".join(str(f.get("name")) for f in files))
    out = f"mod_id={mod_id}\nfile_id={files[0]['id']}\n"
    target = os.environ.get("GITHUB_OUTPUT")
    if target:
        with open(target, "a", encoding="utf-8") as stream:
            stream.write(out)
    else:
        print(out, end="")


# ---------------------------------------------------------------- help / main

def make_help(makefiles: list[str]) -> None:
    """List every Makefile target documented with '## text', standard ones first."""
    rows = []
    for name in makefiles:
        path = Path(name)
        if not path.is_file():
            continue
        for match in re.finditer(r"^([A-Za-z0-9_.-]+):[^=\n]*?##\s*(.+)$", path.read_text(encoding="utf-8"), re.M):
            rows.append((match.group(1), match.group(2), path.name == "mod.mk"))
    release = load_release()
    print(f"{release['title']} {release['version']}  ({release['name']})\n")
    for heading, standard in (("Standard targets", True), ("This repo's extras", False)):
        group = [(t, d) for t, d, s in rows if s == standard]
        if group:
            print(heading + ":")
            for target, description in group:
                print(f"  make {target:<14} {description}")
            print()


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(prog="modtool", description=__doc__.splitlines()[0])
    sub = parser.add_subparsers(dest="command", required=True)
    sub.add_parser("version")
    sub.add_parser("check").add_argument("--ci", action="store_true")
    sub.add_parser("test").add_argument("names", nargs="*")
    sub.add_parser("package").add_argument("--force", action="store_true")
    sub.add_parser("install")
    sub.add_parser("uninstall")
    sub.add_parser("bump").add_argument("version")
    sub.add_parser("release").add_argument("--no-push", action="store_true")
    sub.add_parser("sync")
    notes = sub.add_parser("notes")
    notes.add_argument("version", nargs="?")
    notes.add_argument("--nexus", action="store_true")
    sub.add_parser("ci-meta")
    sub.add_parser("nexus-ids")
    sub.add_parser("help").add_argument("makefiles", nargs="*")
    args = parser.parse_args(argv)
    try:
        if args.command == "version":
            print(load_release()["version"])
        elif args.command == "check":
            check(ci=args.ci)
        elif args.command == "test":
            run_tests(names=args.names)
        elif args.command == "package":
            package(force=args.force)
        elif args.command == "install":
            install()
        elif args.command == "uninstall":
            uninstall()
        elif args.command == "bump":
            bump(args.version)
        elif args.command == "release":
            release_cmd(push=not args.no_push)
        elif args.command == "sync":
            sync()
        elif args.command == "notes":
            body = changelog_section(args.version or load_release()["version"])
            print(nexus_text(body) if args.nexus else body)
        elif args.command == "ci-meta":
            ci_meta()
        elif args.command == "nexus-ids":
            nexus_ids()
        elif args.command == "help":
            make_help(args.makefiles)
    except Fail as error:
        print(f"error: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
