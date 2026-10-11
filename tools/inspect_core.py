"""Compare every package in the Core container with the game's own copy, byte for byte.

  python3 tools/inspect_core.py --retoc /path/to/retoc --paks ".../SWZeroCompany/Content/Paks"

Each override is fetched by chunk ID from src/Core and from the game's base containers
(pakchunk*-Windows plus global, never ~mods), and the differing bytes are listed. In 1.1.4 every
mission package is the game's package with one byte changed (MaxSquadSize 4 -> 6), so after a game
patch this shows at once whether the overrides still match the game they replace: a package that
now differs in more than that byte is a stale copy and would undo the patch's changes to it.
"""
from pathlib import Path
import argparse
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
CONTAINER = ROOT / "src" / "Core" / "pakchunk99-ZCOMSquadSix_P.utoc"

parser = argparse.ArgumentParser()
parser.add_argument("--retoc", required=True, help="retoc_cli 0.1.5 or later")
parser.add_argument("--paks", required=True, type=Path, help="the game's SWZeroCompany/Content/Paks")
args = parser.parse_args()


def retoc(*command):
    return subprocess.run([args.retoc, *map(str, command)], check=True, capture_output=True).stdout


chunks = []
for line in retoc("list", "--path", CONTAINER).decode().splitlines():
    fields = line.split()
    if len(fields) >= 4 and fields[2] == "ExportBundleData":
        chunks.append((fields[1], Path(fields[3]).stem))

with tempfile.TemporaryDirectory() as temporary:
    # Only the base game: a directory input would otherwise pick up installed mods.
    base = Path(temporary) / "base"
    base.mkdir()
    for path in args.paks.iterdir():
        if path.is_file() and (path.name.startswith("global.") or "-Windows." in path.name):
            (base / path.name).symlink_to(path.resolve())
    stale = resized = 0
    for chunk, name in sorted(chunks, key=lambda item: item[1]):
        ours = retoc("get", CONTAINER, chunk)
        try:
            theirs = retoc("get", base, chunk)
        except subprocess.CalledProcessError:
            print(f"{name:34} not in the game any more")
            stale += 1
            continue
        if len(ours) != len(theirs):
            print(f"{name:34} size {len(theirs)} -> {len(ours)} (inspect with retoc to-legacy)")
            resized += 1
            continue
        changes = [(i, theirs[i], ours[i]) for i in range(len(ours)) if ours[i] != theirs[i]]
        listed = ", ".join(f"@{i}: {before}->{after}" for i, before, after in changes[:4])
        print(f"{name:34} {len(changes)} byte(s): {listed}")
        stale += len(changes) != 1
    print(f"{len(chunks)} packages: {stale} not a single-byte change from the installed game,"
          f" {resized} resized (check by hand)")
