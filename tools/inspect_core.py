"""Compare every package in the Core container with the game's own copy, byte for byte.

  python3 tools/inspect_core.py --retoc /path/to/retoc --paks ".../SWZeroCompany/Content/Paks"

Each override is fetched from src/SquadSixReforged_Core and from the game's base containers (pakchunk*-Windows plus
global, never ~mods), and the differing bytes are listed. Every mission package should be the
game's package with MaxSquadSize changed, so after a game patch this shows at once whether the
overrides still match the game they replace: one that differs in more than that is a stale copy
and would undo the patch's changes to it. tools/build_core.py rebuilds them.
"""
from pathlib import Path
import argparse
import sys
import tempfile

sys.path.insert(0, str(Path(__file__).resolve().parent))
from retoc import Retoc, link_base_game  # noqa: E402

ROOT = Path(__file__).resolve().parents[1]
CONTAINER = ROOT / "src" / "SquadSixReforged_Core" / "pakchunk99-SquadSixReforged_P.utoc"

parser = argparse.ArgumentParser()
parser.add_argument("--retoc", required=True, help="retoc_cli 0.1.5 or later")
parser.add_argument("--paks", required=True, type=Path, help="the game's SWZeroCompany/Content/Paks")
args = parser.parse_args()
retoc = Retoc(args.retoc)

with tempfile.TemporaryDirectory() as temporary:
    base = link_base_game(args.paks, Path(temporary) / "base")
    game = retoc.chunks(base)
    ours = retoc.chunks(CONTAINER)
    stale = resized = 0
    for path, chunk in sorted(ours.items(), key=lambda item: item[0].rsplit("/", 1)[1]):
        name = path.rsplit("/", 1)[1]
        if path not in game:
            print(f"{name:34} not in the game any more")
            stale += 1
            continue
        mine, theirs = retoc.get(CONTAINER, chunk), retoc.get(base, game[path])
        if len(mine) != len(theirs):
            print(f"{name:34} size {len(theirs)} -> {len(mine)} (inspect with retoc to-legacy)")
            resized += 1
            continue
        changes = [(i, theirs[i], mine[i]) for i in range(len(mine)) if mine[i] != theirs[i]]
        listed = ", ".join(f"@{i}: {before}->{after}" for i, before, after in changes[:4])
        print(f"{name:34} {len(changes)} byte(s): {listed}")
        stale += len(changes) != 1
    print(f"{len(ours)} packages: {stale} not a single-byte change from the installed game,"
          f" {resized} resized (check by hand)")
