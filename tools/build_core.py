"""Build the Core pak (pakchunk99-ZCOMSquadSix_P) from the installed game's own packages.

  python3 tools/build_core.py --retoc /path/to/retoc --paks ".../SWZeroCompany/Content/Paks"
  python3 tools/build_core.py ... --check     build to a temporary folder and compare with src/ZCOMSquadSix_Core

No editor and no cook: every package in the pak is the game's cooked package with one value
changed, exactly as in arctco's releases.
  - Mission definitions: MaxSquadSize set to the `squad` column of data/missions.tsv. Only rows
    where it differs from `game` are packed. The value is located by parsing the package's
    unversioned properties (zen.py), never by searching for bytes.
  - AC_HologramManager: the lineup loop's last index, the package's only EX_IntConst 3, becomes 5.
Pipeline: retoc to-legacy -> patch the .uexp -> retoc to-zen (UE5_6). retoc round-trips the game's
mission packages byte for byte, so the built packages differ from the game's only in the patch.

Every build is verified before it's written: each package is compared with the same package
packed unpatched (only the 4 patched bytes may differ), the unpatched missions must equal the
game's byte for byte, and each mission is re-parsed to confirm its squad limit. The result and the inputs it was built from are recorded in
data/core-build.sha256, which tools/package.py checks.
"""
from pathlib import Path
import argparse
import hashlib
import json
import shutil
import struct
import sys
import tempfile

sys.path.insert(0, str(Path(__file__).resolve().parent))
import zen  # noqa: E402
from retoc import Retoc, legacy_path, link_base_game  # noqa: E402

ROOT = Path(__file__).resolve().parents[1]
MISSIONS = ROOT / "data" / "missions.tsv"
SCHEMA = ROOT / "tools" / "data" / "schema.json"
RECORD = ROOT / "data" / "core-build.sha256"
OUTPUT = ROOT / "src" / "ZCOMSquadSix_Core"
STEM = "pakchunk99-ZCOMSquadSix_P"
PAK_FILES = [f"{STEM}.{extension}" for extension in ("pak", "ucas", "utoc")]
MISSION_ROOT = "/Game/Game/GameData/MissionData/"
MISSION_CLASS = "BrunoMissionData"
# Packages under MissionData that aren't mission definitions.
NOT_MISSIONS = ("MissionTables/", "MissionTable_")
HOLOGRAM = "/Game/Game/UI/AC_HologramManager"
INT_CONST = 0x1D  # EX_IntConst, followed by an int32
LINEUP_LAST_INDEX = (3, 5)
# Inputs whose change means the pak must be rebuilt.
RECORDED_INPUTS = ["data/missions.tsv", "tools/build_core.py", "tools/zen.py", "tools/retoc.py",
                   "tools/data/schema.json"]


def read_missions():
    rows = {}
    lines = [line for line in MISSIONS.read_text().splitlines() if line and not line.startswith("#")]
    header = lines[0].split("\t")
    assert header == ["mission", "game", "squad", "note"], f"unexpected columns {header}"
    for line in lines[1:]:
        mission, game, squad, note = (line.split("\t") + [""])[:4]
        assert mission not in rows, f"{mission} is listed twice"
        if squad != game and not squad.isdigit():
            raise SystemExit(f"{mission}: squad must be a number when it differs from game")
        rows[MISSION_ROOT + mission] = (game, squad, note)
    return rows


def sha256(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def plan(retoc, base, schema, rows):
    """Check every game mission against missions.tsv; return {path: (export offset, game, squad)}
    for the ones to patch. Offsets are relative to the start of the export data (= the .uexp)."""
    chunks = retoc.chunks(base)
    missions = {path: chunk for path, chunk in chunks.items()
                if path.startswith(MISSION_ROOT)
                and not any(marker in path for marker in NOT_MISSIONS)}
    unlisted = sorted(set(missions) - set(rows))
    missing = sorted(set(rows) - set(missions))
    if unlisted or missing:
        raise SystemExit("data/missions.tsv doesn't match the game's missions:\n"
                         + "".join(f"  new in the game, add a row: {p[len(MISSION_ROOT):]}\n" for p in unlisted)
                         + "".join(f"  no longer in the game: {p[len(MISSION_ROOT):]}\n" for p in missing))
    patches, changed = {}, []
    for path, chunk in sorted(missions.items()):
        game, squad, _ = rows[path]
        package = zen.ZenPackage(retoc.get(base, chunk))
        found = {prop["name"]: (offset, size, value) for prop, offset, size, value in
                 zen.read_properties(package, package.export(path.rsplit("/", 1)[1]), MISSION_CLASS, schema)}
        offset, size, value = found.get("MaxSquadSize", (None, 0, None))
        actual = "default" if value is None else str(value)
        if actual != game:
            changed.append(f"  {path[len(MISSION_ROOT):]}: missions.tsv says {game}, the game has {actual}")
            continue
        if squad != game:
            if size != 4:
                raise SystemExit(f"{path}: MaxSquadSize isn't serialized here, so it can't be patched")
            patches[path] = (offset - package.header_size, int(game), int(squad))
    if changed:
        raise SystemExit("The game's squad limits changed; review these rows:\n" + "\n".join(changed))
    return patches


def patch_int32(data, offset, before, after, what):
    (current,) = struct.unpack_from("<i", data, offset)
    if current != before:
        raise SystemExit(f"{what}: expected {before} at {offset}, found {current}")
    struct.pack_into("<i", data, offset, after)


def patch_hologram(data):
    """Returns the patched int32's offset. The literal must be the package's only EX_IntConst 3."""
    before, after = LINEUP_LAST_INDEX
    pattern = bytes([INT_CONST]) + struct.pack("<i", before)
    hits = [i for i in range(len(data)) if data.startswith(pattern, i)]
    if len(hits) != 1:
        raise SystemExit(f"{HOLOGRAM}: expected one EX_IntConst {before}, found {len(hits)}; "
                         "the Blueprint changed, so find the lineup loop again")
    patch_int32(data, hits[0] + 1, before, after, HOLOGRAM)
    return hits[0] + 1


def build(retoc, base, work, patches):
    """Stage patched legacy packages and pack them; also pack the same packages unpatched, as a
    reference that went through exactly the same pipeline."""
    legacy = work / "legacy"
    retoc.to_legacy(base, legacy, "GameData/MissionData")
    retoc.to_legacy(base, legacy, "AC_HologramManager")
    patchers = {path: (lambda data, o=offset, b=before, a=after, p=path: patch_int32(data, o, b, a, p) or o)
                for path, (offset, before, after) in patches.items()}
    patchers[HOLOGRAM] = patch_hologram
    changed = {}
    for path, patcher in patchers.items():
        changed[path] = stage(legacy, work / "stage", path, patcher)
        stage(legacy, work / "reference_stage", path, None)
    output, reference = work / "out", work / "reference"
    for folder, staged in ((output, "stage"), (reference, "reference_stage")):
        folder.mkdir()
        retoc.to_zen(work / staged, folder / f"{STEM}.utoc")
    return output, reference, changed


def stage(legacy, root, path, patcher):
    """Copy a legacy package into root, patching its .uexp; returns the patched .uexp offset."""
    source, target = legacy_path(legacy, path), legacy_path(root, path)
    target.parent.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(source.with_suffix(".uasset"), target.with_suffix(".uasset"))
    data = bytearray(source.with_suffix(".uexp").read_bytes())
    offset = patcher(data) if patcher else None
    target.with_suffix(".uexp").write_bytes(data)
    return offset


def verify(retoc, base, output, reference, schema, patches, changed):
    """Each built package must equal its unpatched reference except for the 4 patched bytes, and
    the reference must equal the game's package (retoc's round trip is exact for the missions)."""
    utoc, reference_utoc = output / f"{STEM}.utoc", reference / f"{STEM}.utoc"
    built, game = retoc.chunks(utoc), retoc.chunks(base)
    expected = set(patches) | {HOLOGRAM}
    if set(built) != expected:
        raise SystemExit(f"verify: container holds {sorted(set(built) ^ expected)} unexpectedly")
    inexact = []
    for path in sorted(expected):
        ours = retoc.get(utoc, built[path])
        unpatched = retoc.get(reference_utoc, built[path])
        header = zen.ZenPackage(ours).header_size
        allowed = range(header + changed[path], header + changed[path] + 4)
        if len(ours) != len(unpatched) or any(
                ours[i] != unpatched[i] for i in range(len(ours)) if i not in allowed):
            raise SystemExit(f"verify: {path} differs from its unpatched build outside the patch")
        original = retoc.get(base, game[path])
        if unpatched != original:
            if path in patches:
                raise SystemExit(f"verify: retoc doesn't round-trip {path} exactly")
            inexact.append(f"{path} ({len(original)} -> {len(unpatched)} bytes)")
    for path, (_, _, squad) in patches.items():
        package = zen.ZenPackage(retoc.get(utoc, built[path]))
        value = {prop["name"]: value for prop, _, _, value in
                 zen.read_properties(package, package.export(path.rsplit("/", 1)[1]), MISSION_CLASS, schema)
                 }.get("MaxSquadSize")
        if value != squad:
            raise SystemExit(f"verify: {path} reads MaxSquadSize {value}, wanted {squad}")
    return inexact


def compare(retoc, built, committed):
    """Package by package: the container files themselves may differ in layout."""
    ours = retoc.chunks(built / f"{STEM}.utoc")
    theirs = retoc.chunks(committed / f"{STEM}.utoc")
    differ = sorted(path for path in set(ours) & set(theirs)
                    if retoc.get(built / f"{STEM}.utoc", ours[path])
                    != retoc.get(committed / f"{STEM}.utoc", theirs[path]))
    only_ours, only_theirs = sorted(set(ours) - set(theirs)), sorted(set(theirs) - set(ours))
    identical = all((built / name).read_bytes() == (committed / name).read_bytes() for name in PAK_FILES)
    print(f"src/ZCOMSquadSix_Core: {len(set(ours) & set(theirs)) - len(differ)} packages identical, "
          f"{len(differ)} different, {len(only_ours)} only in this build, {len(only_theirs)} only in src/ZCOMSquadSix_Core"
          + ("; container files identical" if identical else "; container files differ in layout"))
    for path in differ:
        print(f"  different: {path}")
    for path in only_ours:
        print(f"  only in this build: {path}")
    for path in only_theirs:
        print(f"  only in src/ZCOMSquadSix_Core: {path}")
    return not (differ or only_ours or only_theirs)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--retoc", required=True)
    parser.add_argument("--paks", required=True, type=Path, help="the game's SWZeroCompany/Content/Paks")
    parser.add_argument("--check", action="store_true", help="compare with src/ZCOMSquadSix_Core instead of writing it")
    args = parser.parse_args()
    retoc = Retoc(args.retoc)
    schema = zen.Schema(json.loads(SCHEMA.read_text())["schemas"])
    rows = read_missions()
    with tempfile.TemporaryDirectory(prefix="squadsix-core-") as temporary:
        work = Path(temporary)
        base = link_base_game(args.paks, work / "base")
        patches = plan(retoc, base, schema, rows)
        output, reference, changed = build(retoc, base, work, patches)
        inexact = verify(retoc, base, output, reference, schema, patches, changed)
        print(f"Built and verified {len(patches)} missions + AC_HologramManager")
        for path in inexact:
            # AC_HologramManager: retoc drops 6 preload-dependency entries; 1.1.4 shipped the same.
            print(f"  note: retoc's round trip isn't byte-exact for {path}")
        if args.check:
            raise SystemExit(0 if compare(retoc, output, OUTPUT) else 1)
        for name in PAK_FILES:
            shutil.copyfile(output / name, OUTPUT / name)
    lines = [f"{sha256(OUTPUT / name)}  {name}" for name in PAK_FILES]
    lines += [f"{sha256(ROOT / name)}  {name}" for name in RECORDED_INPUTS]
    RECORD.write_text("\n".join(lines) + "\n")
    print(f"Wrote src/ZCOMSquadSix_Core/{STEM}.* and {RECORD.relative_to(ROOT)}")


if __name__ == "__main__":
    main()
