#!/usr/bin/env python3
"""The cooked Game Feature paks in src/SquadSixReforged_Core and the record of what they were built from.

    python3 tools/gf_build.py record   after tools/build_gf.sh: copy its paks into src/ under the
                                       shipped names and write unreal/build.json  (make build-gf)
    python3 tools/gf_build.py check    refuse stale paks: every recorded input and pak must match,
                                       and the player docs must not describe the retired UE4SS
                                       placeholder  (make package runs it)

The paks are committed because cooking needs the Linux Unreal kit, which CI doesn't have. The record
hashes the cook's inputs, so a change to any of them without a re-cook is caught before packaging.
"""
import hashlib
import json
import shutil
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
CORE = ROOT / "src" / "SquadSixReforged_Core"
SHIPPED_STEM = "pakchunk99-SquadSixReforged_P"  # v1's container name, kept for manager upgrade matching
BUILT = ROOT / "dist" / "gf" / "own" / "SWZeroCompany" / "Content" / "Paks" / "~mods"
BUILT_STEM = "SquadSixGF_P"
SUMS = ROOT / "dist" / "gf" / "SHA256SUMS"
RECORD = ROOT / "unreal" / "build.json"
EXTENSIONS = ("pak", "ucas", "utoc")
PLATFORM = "Linux (shader-free Blueprint/data cook, not played in the Windows game)"
# Since 2.0.4 the release ships only Core; the docs must not tell players to install the placeholder.
RETIRED_PHRASES = ("stub", "both components", "harmless")


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def inputs():
    names = ["tools/data/missions.tsv", "tools/data/placement.json", "tools/build_gf.sh",
             "unreal/SquadSixGF/SquadSixGF.uplugin", "unreal/scripts/build_gf.py"]
    names += sorted(p.relative_to(ROOT).as_posix() for p in (ROOT / "unreal" / "specs").glob("gf*.py"))
    return names


def version():
    return json.loads((ROOT / "release.json").read_text())["version"]


def record():
    sums = SUMS.read_text()
    for ext in EXTENSIONS:
        built = BUILT / f"{BUILT_STEM}.{ext}"
        assert f"{sha(built)}  own/SWZeroCompany/Content/Paks/~mods/{built.name}" in sums, \
            f"{built.name} doesn't match {SUMS.relative_to(ROOT)}: rerun tools/build_gf.sh"
    for ext in EXTENSIONS:
        shutil.copyfile(BUILT / f"{BUILT_STEM}.{ext}", CORE / f"{SHIPPED_STEM}.{ext}")
    data = {
        "version": version(),
        "platform": PLATFORM,
        "inputs": {name: sha(ROOT / name) for name in inputs()},
        "paks": {f"{SHIPPED_STEM}.{ext}": sha(CORE / f"{SHIPPED_STEM}.{ext}") for ext in EXTENSIONS},
    }
    RECORD.write_text(json.dumps(data, indent=2) + "\n")
    print(f"copied the cooked paks into {CORE.relative_to(ROOT)} and wrote {RECORD.relative_to(ROOT)}")


def check():
    data = json.loads(RECORD.read_text())
    problems = []
    if data["version"] != version():
        problems.append(f"the paks were cooked for {data['version']}, release.json is {version()}: make build-gf")
    for name in sorted(set(inputs()) - set(data["inputs"])):
        problems.append(f"{name} is a cook input the record doesn't cover: make build-gf")
    for name, digest in data["inputs"].items():
        if not (ROOT / name).is_file() or sha(ROOT / name) != digest:
            problems.append(f"{name} changed since the paks were cooked: make build-gf")
    for name, digest in data["paks"].items():
        if sha(CORE / name) != digest:
            problems.append(f"src/SquadSixReforged_Core/{name} doesn't match the cook record")
    for name in ("README.md", "docs/nexus/description.bbcode"):
        text = (ROOT / name).read_text().lower()
        problems += [f'{name} still describes the retired UE4SS placeholder ("{phrase}")'
                     for phrase in RETIRED_PHRASES if phrase in text]
    if problems:
        sys.exit("error: " + "\n  ".join(["stale or inconsistent Game Feature build:", *problems]))
    print(f"Game Feature paks match their cook record ({data['version']})")


if __name__ == "__main__":
    command = sys.argv[1] if len(sys.argv) > 1 else ""
    if command == "record":
        record()
    elif command == "check":
        check()
    else:
        sys.exit(__doc__)
