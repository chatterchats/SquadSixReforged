#!/usr/bin/env python3
"""Sweep every mission with the Game Feature build (SquadSixGF): where the six spawn, and every deployment area's
destinations once the brain has handled it.

    tools/gf_sweep.py [--only NAME,NAME] [--out dist/sweep] [--restart]

Drives the main install's throwaway ZC Sandbox campaign (ZComDenDesigner/tools/dd.py) and reads the game with
PlagueNightConsole (ZComPlagueNight/tools/pn.py), so UE4SS must be on for the sweep itself; the mod under test doesn't
use it. Per mission: reset to the sandbox baseline, launch it with six, snapshot the spawn, wait until the
brain has expanded every loaded preparation area, snapshot again.

Deployments themselves can't be driven generically (most areas are started by the mission's script, not by walking
in), and the walk onto the destinations is the game's own, the same for points five and six as for the authored four,
so the checks are on what this mod decides:
- spawn: an operator at the world origin, or two on one tile (the game's own spawn of five and six, which the
  destinations can't fix);
- each area (against the authored destinations in data/mapscan.json): fewer than six destinations where no fixed
  layout applied, two on one tile, or a destination the mod placed too far from the authored ones or on another
  floor.
One JSON line per mission goes to results.jsonl (missions already there are skipped, so the sweep resumes), and a
summary to summary.txt. The game is relaunched after a crash or a hang.
"""
import argparse
import importlib.util
import json
import math
import re
import subprocess
import sys
import time
from pathlib import Path

REPO = Path(__file__).resolve().parents[1]
MODS = REPO.parent
PN = MODS / "ZComPlagueNight/tools/pn.py"
PROBE = (REPO / "tools/gf_sweep.lua").read_text()

spec = importlib.util.spec_from_file_location("dd", MODS / "ZComDenDesigner/tools/dd.py")
dd = importlib.util.module_from_spec(spec)
spec.loader.exec_module(dd)

GENTLE = False
ORIGIN = 100.0     # within this of 0/0 is the world origin
STACKED = 50.0     # two operators closer than this share a tile
SAME_TILE = 75.0   # two destinations closer than this share a tile
AUTHORED = 5.0     # a destination this close to an authored one is that one
FAR = 450.0        # a placed destination further than this from every authored one has left the lane
FLOOR = 250.0      # a placed destination this far above or below the authored one nearest it is on another floor
SCAN = {(a["package"].rsplit("/", 1)[-1], a["area"]): [d["location"] for d in a["destinations"]]
        for a in json.loads((REPO / "data/mapscan.json").read_text())["areas"]}


def say(text):
    print(time.strftime("%H:%M:%S"), text, flush=True)


def ok(reply):
    return reply is not None and " ok " in reply


def in_mission():
    """The sandbox says the game is in a mission and settled (checked before every probe: the probe's FindAllOf can
    hand UE4SS objects of a level being torn down, and touching one crashed the game inside UE4SS.dll, 2026-10-18)."""
    return ok(dd.send("wait phase=mission settled=1 timeout=20000", timeout=40))


def probe(trigger=False):
    if not in_mission():
        raise RuntimeError("not in a mission")
    code = ("SWEEP_TRIGGER = true\n" if trigger else "SWEEP_TRIGGER = nil\n") + PROBE
    r = subprocess.run([sys.executable, "-I", str(PN), "--instance", "1", "--timeout", "40", code],
                       capture_output=True, text=True, timeout=90)
    for line in r.stdout.splitlines():
        if line.startswith("SWEEP "):
            return json.loads(line[6:])
    raise RuntimeError("probe failed: " + (r.stdout + r.stderr).strip()[-300:])


CRASHES = Path("/run/media/chats/e0057d4a-fe46-43eb-a837-db51979c500f/Games/STAR WARS Zero Company (2026)/prefix/"
               "drive_c/users/steamuser/AppData/Local/SWZeroCompany/Saved/Crashes")


def crash_count():
    return len(list(CRASHES.iterdir())) if CRASHES.exists() else 0


def game_up():
    return bool(dd.game_pids())


def restart():
    say("restarting the game")
    dd.kill()
    time.sleep(3)
    before = crash_count()
    dd.launch()
    end = time.time() + 400
    while time.time() < end:
        line = dd.send("status", timeout=10)
        if line and " ok " in line:
            break
        if crash_count() > before:
            raise SystemExit("the game crashed while starting; see " + str(CRASHES))
        time.sleep(5)
    reply = dd.send("campaign load baseline", timeout=300)
    dd.send("wait phase=hub settled=1 timeout=240000", timeout=260)
    return ok(reply)


def all_missions():
    """Every mission definition, from data/missions.tsv (the sandbox's `missions` replies are cut at ~900 characters)."""
    names = []
    for line in (REPO / "data/missions.tsv").read_text().splitlines():
        if line.startswith("#") or line.startswith("mission\t") or not line.strip():
            continue
        names.append(line.split("\t", 1)[0].rsplit("/", 1)[-1])
    return names


def load_baseline():
    """`campaign load baseline`, retried while the game is still writing a save (it refuses then)."""
    for _ in range(12):
        reply = dd.send("campaign load baseline", timeout=300)
        if ok(reply):
            return reply
        if reply is None or "save is being written" not in reply:
            return reply
        time.sleep(5)
    return reply


def responsive():
    """The sandbox still answers (the game isn't hung, though a probe may have timed out across a level load)."""
    return dd.send("status", timeout=20) is not None


def judge_spawn(snap):
    flags = []
    units = snap["units"]
    for name, x, y, z in units:
        if math.hypot(x, y) < ORIGIN:
            flags.append(f"{name} origin")
    for i, (a, ax, ay, _) in enumerate(units):
        for b, bx, by, _ in units[i + 1:]:
            if math.hypot(ax - bx, ay - by) < STACKED:
                flags.append(f"{a}+{b} stacked")
    return flags


def area_key(full_name):
    """'HM_Jae_010_Gameplay.HM_Jae_010_Gameplay:PersistentLevel.BP_CombatPreparationArea_C_0' -> scan key."""
    return full_name.split(".", 1)[0], full_name.rsplit(".", 1)[-1]


def judge_areas(snap, fixed):
    flags, checked = [], 0
    for area in snap["areas"]:
        key = area_key(area["name"])
        authored = SCAN.get(key)
        dests = area["dests"]
        label = f"{key[0]}:{key[1].replace('BP_CombatPreparationArea_C_', 'area')}"
        if authored is None:
            flags.append(f"{label} not_in_scan")
            continue
        checked += 1
        if len(dests) < 6 and not fixed:
            flags.append(f"{label} short {len(dests)}")
        for i, a in enumerate(dests):
            for b in dests[i + 1:]:
                if math.hypot(a[0] - b[0], a[1] - b[1]) < SAME_TILE:
                    flags.append(f"{label} same_tile ({a[0]:.0f},{a[1]:.0f})")
            nearest = min(authored, key=lambda p: math.hypot(p[0] - a[0], p[1] - a[1]))
            off = math.hypot(nearest[0] - a[0], nearest[1] - a[1])
            # A hand-picked layout's spots are deliberately where the user put them.
            if off <= AUTHORED or fixed:
                continue
            if off > FAR:
                flags.append(f"{label} far {off:.0f} ({a[0]:.0f},{a[1]:.0f})")
            if abs(nearest[2] - a[2]) > FLOOR:
                flags.append(f"{label} floor {a[2] - nearest[2]:+.0f} ({a[0]:.0f},{a[1]:.0f})")
    return flags, checked


def expanded(snap):
    b = snap.get("brain", {})
    live = sum(1 for a in snap["areas"] if a["dests"])
    return (b.get("AreasExpanded") or 0) >= live


def run_mission(name):
    result = {"mission": name, "time": time.strftime("%Y-%m-%d %H:%M:%S")}
    reply = load_baseline()
    if not ok(reply):
        result["error"] = f"baseline: {reply}"
        return result
    dd.send("wait phase=hub settled=1 timeout=240000", timeout=260)
    reply = dd.send(f"mission launch {name}", timeout=240)
    result["launch"] = reply
    if not ok(reply):
        result["error"] = "launch refused"
        return result
    dd.send("wait phase=mission settled=1 timeout=240000", timeout=260)
    # Normal speed: the brain waits for the cover data in game time, which arrives in real time. A settle before the
    # first probe lets the Den's objects go before FindAllOf runs, and polls are few.
    time.sleep(5)
    if GENTLE:
        # One late look: fewer FindAllOf walks for UE4SS to trip over (its probe crashes were the sweep's, not the mod's).
        time.sleep(15)
        result["spawn"] = probe()
        snap = result["spawn"]
    else:
        result["spawn"] = probe()
        snap = result["spawn"]
        for _ in range(4):
            if expanded(snap):
                break
            time.sleep(5)
            snap = probe()
    result["areas"] = snap
    result["expanded_all"] = expanded(snap)
    fixed = (snap.get("brain", {}).get("FixedApplied") or 0) > 0
    area_flags, checked = judge_areas(snap, fixed)
    result["flags"] = {"spawn": judge_spawn(result["spawn"]), "areas": area_flags}
    result["checked_areas"] = checked
    return result


def summarise(path, out):
    lines, flagged = [], 0
    for line in path.read_text().splitlines():
        r = json.loads(line)
        if "error" in r:
            lines.append(f"{r['mission']:34} ERROR {r['error'][:90]}")
            continue
        b = r["areas"].get("brain", {})
        scan = sum(1 for k in SCAN if k[0] == (r["areas"]["map"].rsplit("/", 1)[-1].replace("_Root", "_Gameplay")))
        info = (f"units={len(r['spawn']['units'])} areas={r['checked_areas']}/{len(r['areas']['areas'])} "
                f"added={b.get('PointsAdded')} covered={b.get('CoveredPoints')} kept/snapped/moved="
                f"{b.get('SpotsKept')}/{b.get('SpotsSnapped')}/{b.get('SpotsMoved')} fixed={b.get('FixedApplied')} "
                f"profile={b.get('ProfilesApplied')} dir={b.get('DirectionsUsed')}"
                + ("" if r.get("expanded_all") else " NOT-ALL-EXPANDED"))
        flags = r["flags"]["spawn"] + r["flags"]["areas"]
        if flags:
            flagged += 1
            lines.append(f"{r['mission']:34} FLAGGED {info} :: " + "; ".join(flags))
        else:
            lines.append(f"{r['mission']:34} ok {info}")
    lines.append(f"\n{len(lines)} missions, {flagged} flagged")
    out.write_text("\n".join(lines) + "\n")
    return flagged


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--only", default="")
    ap.add_argument("--out", default=str(REPO / "dist/sweep"))
    ap.add_argument("--restart", action="store_true", help="restart the game before the first mission")
    ap.add_argument("--gentle", action="store_true", help="one probe per mission, 20 s in")
    a = ap.parse_args()
    global GENTLE
    GENTLE = a.gentle
    out = Path(a.out)
    out.mkdir(parents=True, exist_ok=True)
    results = out / "results.jsonl"
    done = set()
    if results.exists():
        done = {json.loads(l)["mission"] for l in results.read_text().splitlines() if l.strip()}
    if a.restart or not game_up():
        restart()
    missions = [m for m in a.only.split(",") if m] or all_missions()
    say(f"{len(missions)} missions, {len(done)} already done")
    errors_in_a_row = 0
    for name in missions:
        if name in done:
            continue
        say(f"{name}: start")
        try:
            result = run_mission(name)
        except Exception as error:
            result = {"mission": name, "error": f"{type(error).__name__}: {error}"}
            # A probe that timed out across a level load (an operation ending, a cinematic) leaves a game that still
            # answers: note it and go on; only a game that stopped answering is relaunched.
            if game_up() and responsive():
                result["error"] = "probe timeout, game responsive (likely left the mission): " + result["error"][:120]
                result["responsive"] = True
        with results.open("a") as f:
            f.write(json.dumps(result) + "\n")
        flags = result.get("flags", {}).get("spawn", []) + result.get("flags", {}).get("areas", [])
        say(f"{name}: " + ("ERROR " + result["error"][:120] if "error" in result
                           else ("FLAGGED " + "; ".join(flags) if flags else "ok")))
        errors_in_a_row = errors_in_a_row + 1 if "error" in result else 0
        if errors_in_a_row >= 3:
            raise SystemExit("three errors in a row; stopping (see results.jsonl)")
        if "error" in result and not result.get("responsive") and "launch refused" not in result["error"]:
            # A crash or a hang: start from a clean game.
            restart()
    flagged = summarise(results, out / "summary.txt")
    say(f"done: {flagged} flagged; {out / 'summary.txt'}")


if __name__ == "__main__":
    main()
