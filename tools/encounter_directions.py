"""Work out which way each deployment area's enemies are, from the enemy spawners in its level.

  python3 tools/encounter_directions.py --retoc /path/to/retoc --paks ".../SWZeroCompany/Content/Paks" [--cache DIR]

placement.lua's cover rules need the direction of the encounter. At runtime the only thing it can
see before the fight starts is the tactical volume, and the volume's centre misleads where the
deployment lane sits at one end of a large volume: in HM_Cly_010 ("Best Served Cold") it pointed
almost opposite the enemies. The levels say where the enemies are: every enemy is spawned by an
actor spawner (no level places enemies directly), and a spawner that places the fight's opening
enemies lists where they stand (SpawnDestinations, TacticalPoints). A spawner with no destinations
spawned nobody at the start in either fight checked live: it is a reinforcement, and one in Origin
of Infection (HM_TelRea_010) stands inside the deployment lane, so spawner positions alone gave a
direction 130 degrees off. The designers also label spawners, for example BP_ActorSpawner_Enemy1.3
where 1 is the wave. Labels are editor data the game doesn't load, so the direction is worked out
here and written to src/SquadSixReforged/Scripts/directions.lua.

For each deployment area: the destinations of the spawners labelled as enemies (not neutral,
crisis, rescue or named story characters), of the lowest wave, whose destinations' centre is
nearest that area among the areas of the same map folder. The direction is the sum of the unit
vectors from the lane's centre to each destination, weighted by 1/distance. An area gets no entry,
and placement keeps the volume's centre, when no spawner qualifies or the destinations surround
the lane (the weighted sum is under MIN_AGREEMENT of the weights). Checked against the live
enemies: Best Served Cold 190 degrees, Origin of Infection 86 (2026-10-13).
Run it after a game update, like tools/map_scan.py.
"""
from pathlib import Path
import argparse
import json
import math
import re
import sys
import tempfile
from collections import defaultdict

sys.path.insert(0, str(Path(__file__).resolve().parent))
import zen  # noqa: E402
import map_scan  # noqa: E402
from retoc import Retoc, link_base_game  # noqa: E402

ROOT = Path(__file__).resolve().parents[1]
OUTPUT = ROOT / "src" / "SquadSixReforged" / "Scripts" / "directions.lua"
SCHEMA = ROOT / "tools" / "data" / "direction_schema.json"
AREA_CLASS = "BP_CombatPreparationArea_C"
SPAWNER_CLASS = "BP_ActorSpawner_C"
ENEMY_LABEL = re.compile(r"enem|enc\d|spawner\d", re.I)
NOT_ENEMY_LABEL = re.compile(r"neutral|crisis|ally|friendly|rescue|civil", re.I)
WAVE = re.compile(r"(?:Enemy|EnemySpawner|Enc|Spawner)_?(\d+)", re.I)
MIN_AGREEMENT = 0.5


def component_location(package, actor_index, classes, schema):
    """An actor's position: its root scene component's RelativeLocation (a child component with no
    AttachParent). Cooked levels keep the components as exports whose outer is the actor."""
    for export in package.exports:
        if export["outer"] != actor_index:
            continue
        class_name = classes.get(export["class"])
        if class_name not in schema.schemas:
            continue
        try:
            props = {prop["name"]: value for prop, _, _, value in zen.read_properties(
                package, export, class_name, schema, trailer="component")}
        except zen.FormatError:
            continue
        if "RelativeLocation" in props and not props.get("AttachParent"):
            location = props["RelativeLocation"]
            return location["X"], location["Y"]
    return None


def wave(label):
    match = WAVE.search(label)
    return int(match.group(1)) if match else None


def read_levels(retoc, paks, cache):
    with tempfile.TemporaryDirectory(prefix="squadsix-directions-") as temporary:
        base = link_base_game(paks, Path(temporary) / "base")
        maps = {path: chunk for path, chunk in retoc.chunks(base, suffix=".umap").items()
                if path.startswith(map_scan.MAPS_ROOT)}
        cache = cache or Path(temporary) / "maps"
        print(f"Reading {len(maps)} map packages...", file=sys.stderr)
        map_scan.fetch_all(retoc, base, sorted(set(maps.values())), cache)
        classes = map_scan.script_classes(retoc, paks)
        schema = zen.Schema(json.loads(SCHEMA.read_text())["schemas"])
        areas, spawners = [], []
        for path, chunk in sorted(maps.items()):
            if "/LevelInstances/" in path or "/Level_Instances/" in path:
                continue
            package = zen.ZenPackage((cache / chunk).read_bytes())
            folder = "/".join(path.split("/")[:6])  # /Game/Game/Maps/<kind>/<map>
            level = path.rsplit("/", 1)[1]
            for index, export in enumerate(package.exports):
                if export["name"].startswith(AREA_CLASS):
                    props, _ = zen.read_actor(package, export, AREA_CLASS, schema)
                    props = {prop["name"]: value for prop, _, _, value in props}
                    points = [component_location(package, reference - 1, classes, schema)
                              for reference in props.get("PlayerDestinations") or [] if reference > 0]
                    points = [point for point in points if point is not None]
                    if points:
                        areas.append({"key": f"{level}:{export['name']}", "folder": folder,
                                      "centre": (sum(p[0] for p in points) / len(points),
                                                 sum(p[1] for p in points) / len(points))})
                elif export["name"].startswith(SPAWNER_CLASS):
                    try:
                        props, label = zen.read_actor(package, export, SPAWNER_CLASS, schema)
                    except zen.FormatError as error:
                        # Without its label a spawner can't be told apart; leave it out.
                        print(f"  unreadable spawner {path}:{export['name']}: {error}", file=sys.stderr)
                        continue
                    props = {prop["name"]: value for prop, _, _, value in props}
                    points = [component_location(package, reference - 1, classes, schema)
                              for reference in props.get("SpawnDestinations") or []
                              if isinstance(reference, int) and reference > 0]
                    points = [point for point in points if point is not None]
                    if points:
                        spawners.append({"label": label or "", "folder": folder, "points": points,
                                         "centre": (sum(p[0] for p in points) / len(points),
                                                    sum(p[1] for p in points) / len(points))})
        return areas, spawners


def directions(areas, spawners):
    by_folder = defaultdict(list)
    for area in areas:
        by_folder[area["folder"]].append(area)
    assigned = defaultdict(list)
    for spawner in spawners:
        label = spawner["label"]
        if not ENEMY_LABEL.search(label) or NOT_ENEMY_LABEL.search(label):
            continue
        candidates = by_folder.get(spawner["folder"])
        if not candidates:
            continue
        x, y = spawner["centre"]
        nearest = min(candidates, key=lambda a: (a["centre"][0] - x) ** 2 + (a["centre"][1] - y) ** 2)
        assigned[nearest["key"]].append(spawner)

    result, skipped = {}, {}
    for area in areas:
        chosen = assigned.get(area["key"], [])
        waves = [w for w in (wave(s["label"]) for s in chosen) if w is not None]
        if waves:
            chosen = [s for s in chosen if wave(s["label"]) in (min(waves), None)]
        if not chosen:
            skipped[area["key"]] = "no enemy spawner with destinations"
            continue
        cx, cy = area["centre"]
        sx = sy = weights = 0.0
        points = [point for spawner in chosen for point in spawner["points"]]
        for x, y in points:
            dx, dy = x - cx, y - cy
            distance = math.hypot(dx, dy) or 1.0
            sx += dx / distance / distance
            sy += dy / distance / distance
            weights += 1 / distance
        length = math.hypot(sx, sy)
        if length < MIN_AGREEMENT * weights:
            skipped[area["key"]] = f"enemies on several sides ({length / weights:.2f})"
            continue
        result[area["key"]] = {"x": sx / length, "y": sy / length, "spawners": len(chosen),
                               "points": len(points),
                               "degrees": round(math.degrees(math.atan2(sy, sx)) % 360)}
    return result, skipped


def write_lua(result):
    lines = [
        "-- Generated by tools/encounter_directions.py from the game's levels; regenerate it after a",
        "-- game update rather than editing it. Which way each deployment area's opening enemies are,",
        "-- as a unit vector from the lane's centre towards where their spawners place them, keyed by",
        '-- "<level package>:<area>". Areas without an entry use their tactical volume\'s centre.',
        "return {",
    ]
    for key in sorted(result):
        entry = result[key]
        lines.append(f'    ["{key}"] = {{X = {entry["x"]:.4f}, Y = {entry["y"]:.4f}}},'
                     f'  -- {entry["degrees"]} deg, {entry["points"]} enemies from {entry["spawners"]} spawners')
    lines.append("}")
    OUTPUT.write_text("\n".join(lines) + "\n")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--retoc", required=True)
    parser.add_argument("--paks", required=True, type=Path)
    parser.add_argument("--cache", type=Path, help="keep fetched map packages here between runs")
    args = parser.parse_args()
    areas, spawners = read_levels(Retoc(args.retoc), args.paks, args.cache)
    result, skipped = directions(areas, spawners)
    write_lua(result)
    print(f"{len(areas)} areas, {len(spawners)} spawners: {len(result)} directions written to "
          f"{OUTPUT.relative_to(ROOT)}")
    for key, reason in sorted(skipped.items()):
        print(f"  no entry: {key} ({reason})")


if __name__ == "__main__":
    main()
