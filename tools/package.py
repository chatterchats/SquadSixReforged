"""Build the release ZIP from source, never the live mod directory.

The ZIP mirrors the game's SWZeroCompany folder, so a manual install is one extract and the
Vortex extension takes it as a combo mod (it needs both Binaries/ and Content/ at the root):
  Binaries/Win64/ue4ss/Mods/ZCOMSquadSix/      exactly src/ZCOMSquadSix's player files, plus
                                               CREDITS.md (arctco's credit travels with every copy)
  Content/Paks/~mods/ZCOMSquadSix_Core/        src/ZCOMSquadSix_Core: pakchunk99-ZCOMSquadSix_P
                                               .pak/.ucas/.utoc (committed build of tools/build_core.py)
Each component keeps its modinfo.json and zcom-mod.json beside its payload, so Zero Mod Manager and
Zero Company Mod Command still install the pair as two entries ("Squad Six - Runtime" and
"Squad Six - Core"). The paks get their own ~mods subfolder so Vortex doesn't deploy those manifests
loose into ~mods. dev/ZCOMSquadSixProbe is a developer tool and never ships.

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
SOURCE = ROOT / "src" / "ZCOMSquadSix"
SCRIPTS = SOURCE / "Scripts"
CORE = ROOT / "src" / "ZCOMSquadSix_Core"
# Archive paths are relative to the game's SWZeroCompany folder; nothing may sit at the root,
# or Vortex's combo installer deploys it loose into SWZeroCompany.
ARCHIVE_ROOTS = ("Binaries/", "Content/")
PACKAGE_ROOT = "Binaries/Win64/ue4ss/Mods/ZCOMSquadSix"  # installed folder name is the last part
PAKS_ROOT = "Content/Paks/~mods/ZCOMSquadSix_Core"
PAKS = [CORE / ("pakchunk99-ZCOMSquadSix_P." + extension) for extension in ("pak", "ucas", "utoc")]
CORE_RECORD = ROOT / "data" / "core-build.sha256"
UPSTREAM = ROOT / "docs" / "upstream-1.1.4.sha256"
# Where 1.1.4's files (named as in its Core/ and Runtime/ archive halves) live now.
UPSTREAM_PLACES = {"Core/": CORE, "Runtime/ZCOMSquadSix/": SOURCE, "Runtime/": SOURCE}

version = json.loads((SOURCE / "modinfo.json").read_text())["version"]
assert re.fullmatch(r"\d+\.\d+\.\d+", version), "Invalid package version"
for manifest in (SOURCE / "zcom-mod.json", CORE / "modinfo.json", CORE / "zcom-mod.json"):
    assert json.loads(manifest.read_text())["version"] == version, manifest.relative_to(ROOT)
assert f'local VERSION = "{version}"' in (SCRIPTS / "main.lua").read_text()
assert f"Squad Six v{version} " in (SOURCE / "README.md").read_text()


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def verify_upstream():
    """Report which of 1.1.4's files are still unchanged."""
    print("src/ against the original 1.1.4 release:")
    for line in UPSTREAM.read_text().splitlines():
        digest, name = line.split()
        name = name.removeprefix("./")
        prefix = next(p for p in UPSTREAM_PLACES if name.startswith(p))
        path = UPSTREAM_PLACES[prefix] / name[len(prefix):]
        state = "missing" if not path.is_file() else "unchanged" if sha(path) == digest else "changed"
        print(f"  {state:9} {path.relative_to(ROOT)}")


def checked_paks():
    """The committed paks are the last build_core.py output, built from the current inputs (the record
    holds hashes, not file times: a fresh checkout has no meaningful times)."""
    for line in CORE_RECORD.read_text().splitlines():
        digest, name = line.split()
        path = CORE / name if name.endswith((".pak", ".ucas", ".utoc")) else ROOT / name
        assert path.is_file(), f"{name} is missing: run tools/build_core.py"
        assert sha(path) == digest, f"{name} doesn't match data/core-build.sha256: run tools/build_core.py"
    return PAKS


COMMON = [SOURCE / leaf for leaf in ("enabled.txt", "modinfo.json", "zcom-mod.json", "README.md")]
REQUIRE = re.compile(r'require\("(\w+)"\)')


def player_scripts():
    """Every mod script, checked to be reachable from main.lua."""
    mod = {p.stem: p for p in SCRIPTS.glob("*.lua")}
    seen, pending = set(), ["main"]
    while pending:
        name = pending.pop()
        if name in seen:
            continue
        seen.add(name)
        for ref in REQUIRE.findall(mod[name].read_text()):
            assert ref in mod, f"{name}.lua needs missing script {ref}.lua"
            pending.append(ref)
    assert seen == mod.keys(), f"Unreachable mod scripts: {sorted(mod.keys() - seen)}"
    return sorted(mod.values())


def build(scripts, paks):
    files = COMMON + scripts
    assert all(p.is_file() and not p.is_symlink() for p in files)
    entries = {f"{PACKAGE_ROOT}/" + p.relative_to(SOURCE).as_posix(): p for p in files}
    entries[f"{PACKAGE_ROOT}/CREDITS.md"] = ROOT / "CREDITS.md"  # copies keep arctco's credit
    assert entries[f"{PACKAGE_ROOT}/CREDITS.md"].is_file()
    assert len(entries) == len(files) + 1
    for path in [CORE / "modinfo.json", CORE / "zcom-mod.json"] + paks:
        entries[f"{PAKS_ROOT}/{path.name}"] = path
    assert not any(name.endswith(".log") for name in entries)
    assert all(name.startswith(ARCHIVE_ROOTS) for name in entries)
    output = ROOT / "dist" / f"SquadSix-{version}.zip"
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
    print(f"Verified {len(entries)} packaged files ({len(scripts)} scripts, {len(paks)} paks): {output}")
    print(f"SHA256: {digest}")


if "--verify" in sys.argv[1:]:
    verify_upstream()
build(player_scripts(), checked_paks())
