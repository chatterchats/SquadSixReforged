"""Build the release ZIP from src/, never the live mod directory.

The ZIP keeps the layout of the original author's releases, which Zero Mod Manager installs as
two entries:
  Core/       the IoStore override (pakchunk99-ZCOMSquadSix_P.pak/.ucas/.utoc), Content/Paks/~mods
  Runtime/    the UE4SS mod (ZCOMSquadSix/Scripts/*.lua), ue4ss/Mods
Each half carries its zcom-mod.json. The Core paks are built by tools/build_core.py, which records
them and the inputs they came from in data/core-build.sha256; packaging refuses paks that don't
match that record, or a record whose inputs have changed since (rebuild first).

  python3 tools/package.py            build dist/SquadSix-<version>.zip
  python3 tools/package.py --verify   also compare src/ with the upstream 1.1.4 hashes
"""
from pathlib import Path
import hashlib
import json
import re
import sys
import zipfile

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "src"
MAIN = SOURCE / "Runtime" / "ZCOMSquadSix" / "Scripts" / "main.lua"
MANIFESTS = [SOURCE / "Core" / "zcom-mod.json", SOURCE / "Runtime" / "zcom-mod.json"]
UPSTREAM = ROOT / "docs" / "upstream-1.1.4.sha256"
CORE_RECORD = ROOT / "data" / "core-build.sha256"


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def version():
    found = {json.loads(path.read_text())["version"] for path in MANIFESTS}
    assert len(found) == 1, f"Core and Runtime manifests disagree: {sorted(found)}"
    (value,) = found
    assert re.fullmatch(r"\d+\.\d+\.\d+", value), "Invalid package version"
    assert f'local VERSION = "{value}"' in MAIN.read_text(), "main.lua VERSION doesn't match the manifests"
    return value


def verify_upstream():
    """Report which src/ files still match the original 1.1.4 release."""
    for line in UPSTREAM.read_text().splitlines():
        digest, name = line.split()
        path = SOURCE / name
        state = "missing" if not path.is_file() else "unchanged" if sha(path) == digest else "changed"
        print(f"  {state:9} {name[2:] if name.startswith('./') else name}")


def check_core():
    """The committed paks are the last build_core.py output, built from the current inputs."""
    for line in CORE_RECORD.read_text().splitlines():
        digest, name = line.split()
        path = SOURCE / "Core" / name if name.endswith((".pak", ".ucas", ".utoc")) else ROOT / name
        assert path.is_file(), f"{name} is missing"
        assert sha(path) == digest, (f"{name} doesn't match data/core-build.sha256: "
                                     "run tools/build_core.py")


def build(value):
    files = sorted(p for p in SOURCE.rglob("*") if p.is_file())
    assert all(not p.is_symlink() for p in files)
    assert not any(p.suffix == ".log" for p in files)
    entries = {p.relative_to(SOURCE).as_posix(): p for p in files}
    assert all(name.startswith(("Core/", "Runtime/")) for name in entries)
    output = ROOT / "dist" / f"SquadSix-{value}.zip"
    output.parent.mkdir(exist_ok=True)
    if output.exists():
        # A released version is immutable: same version, same bytes, or bump it.
        with zipfile.ZipFile(output) as existing:
            same = set(existing.namelist()) == set(entries) and all(
                existing.read(name) == source.read_bytes() for name, source in entries.items())
        assert same, f"{output.name} already exists with different contents; bump the version"
    with zipfile.ZipFile(output, "w", compression=zipfile.ZIP_DEFLATED) as archive:
        for name, source in entries.items():
            archive.write(source, name)
    with zipfile.ZipFile(output) as archive:
        assert archive.testzip() is None
        assert set(archive.namelist()) == set(entries)
        for name, source in entries.items():
            assert archive.read(name) == source.read_bytes(), name
    digest = sha(output)
    output.with_suffix(".zip.sha256").write_text(f"{digest}  {output.name}\n")
    print(f"Verified {len(entries)} packaged files: {output}")
    print(f"SHA256: {digest}")


if "--verify" in sys.argv[1:]:
    print("src/ against the original 1.1.4 release:")
    verify_upstream()
check_core()
build(version())
