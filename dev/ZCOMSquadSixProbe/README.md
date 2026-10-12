# Squad Six probe (development only)

Never shipped: it lives outside `src/`, so `tools/package.py` can't pick it up.

In a mission it logs:

- **Spot checks** for every deployment area, 10 seconds after it appears (so the navmesh has
  streamed in):
  - the authored destinations, as a control, since they're known-good;
  - the fallback spots `placement.lua` derives for the lane;
  - any destinations Squad Six adds at combat preparation.

  Each is checked against the navmesh and a floor trace.
  `unchecked` means the call couldn't be made, not that the spot is bad.
- **Staging positions:** where every squad member stands during the first 30 seconds after the
  squad appears, logged whenever someone moves more than 50 uu.
- **A timeline** of when deployment areas, destinations and squad members appear.

It watches for the first two minutes of each mission, which is while the mission loads, so it
keeps object searches rare: one search for deployment areas every 5 seconds. Version 0.1.0 also
searched for grid volumes once per destination every second (no mission ever had one), which
caused heavy hitching on mission load.

It registers no hooks and writes nothing to the game.

## Install

Copy `ZCOMSquadSixProbe` into `SWZeroCompany/Binaries/Win64/ue4ss/Mods/`, next to `ZCOMSquadSix`.
It loads Squad Six's own `common.lua` and `placement.lua` from there. `enabled.txt` makes UE4SS
load it. Use a game copy (see the simtest notes), not your main install.

## Output

All three go in the mod folder (`Mods/ZCOMSquadSixProbe/`):

- `UE4SS.log` lines tagged `[SQUADSIX_PROBE]`;
- `squadsix_probe.log`, the same lines with timestamps;
- `squadsix_probe.jsonl`, one JSON record per area check (`type: "area"`) and per squad snapshot
  (`type: "squad"`), for feeding back into `tests/placement_maps_test.lua`.

Type `squadsixprobe` in the UE4SS console to check every loaded area immediately.
