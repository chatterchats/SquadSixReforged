"""Scan the game's maps for deployment areas and the destination points they author.

  python3 tools/map_scan.py --retoc /path/to/retoc --paks ".../SWZeroCompany/Content/Paks" [--cache DIR]

Every BP_CombatPreparationArea in every map package under /Game/Game/Maps is read straight from
the cooked level: its PlayerDestinations (the TacticalPoints the map author marked for player
deployment) and where each one stands (its root component's RelativeLocation). The result is
written to data/mapscan.json, the input placement.lua's rules were derived from (arctco's own scan
was never published).

The scan then checks what placement.lua assumes about the maps:
  - each hard-coded PLACEMENT_PROFILES fingerprint matches exactly one area (as the runtime matches
    them: any translation and yaw, all four points within 50 uu);
  - the lane statistics the runtime's constants are based on (see docs/runtime-notes.md).
Run it after a game update: a profile that no longer matches exactly once must be re-derived.

Coordinates are as cooked in each level package. A sublevel streamed in with a transform would
shift its points in the world; the runtime's matcher tolerates translation and yaw for that reason.
Missions are associated by folder: every mission whose Level lives in the same map folder.
"""
from pathlib import Path
from concurrent.futures import ThreadPoolExecutor
import argparse
import json
import math
import re
import statistics
import sys
import tempfile

sys.path.insert(0, str(Path(__file__).resolve().parent))
import zen  # noqa: E402
from retoc import Retoc, link_base_game  # noqa: E402

ROOT = Path(__file__).resolve().parents[1]
OUTPUT = ROOT / "data" / "mapscan.json"
MAP_SCHEMA = ROOT / "tools" / "data" / "map_schema.json"
MISSION_SCHEMA = ROOT / "tools" / "data" / "schema.json"
PLACEMENT = ROOT / "src" / "Runtime" / "ZCOMSquadSix" / "Scripts" / "placement.lua"
MAPS_ROOT = "/Game/Game/Maps/"
MISSION_ROOT = "/Game/Game/GameData/MissionData/"
AREA_CLASS = "BP_CombatPreparationArea_C"
POINT_CLASS = "TacticalPoint"
# placement.lua's matcher: PLACEMENT_PROFILE_MATCH_RADIUS_SQ = 2500 (50 uu), scale within 5%.
PROFILE_MATCH_RADIUS = 50.0


def script_classes(retoc, paks):
    """Script object global index -> name, from the game's global container."""
    names, current = {}, None
    for line in retoc.run("print-script-objects", Path(paks) / "global.utoc").decode().splitlines():
        if not line.startswith(" "):
            current = line.rstrip()[:-1]
            continue
        match = re.match(r"\s+global_index:\s+Some\((\d+)\)", line)
        if match:
            names[int(match.group(1))] = current
    return names


def fetch_all(retoc, base, chunks, cache):
    """Fetch packages into the cache directory (by chunk id), eight at a time."""
    cache.mkdir(parents=True, exist_ok=True)

    def fetch(chunk):
        target = cache / chunk
        if not target.exists() or target.stat().st_size == 0:
            target.write_bytes(retoc.get(base, chunk))
        return chunk

    with ThreadPoolExecutor(max_workers=8) as pool:
        list(pool.map(fetch, chunks))


def rounded(vector):
    return [round(vector[axis], 3) for axis in ("X", "Y", "Z")]


def scan_package(path, package, classes, schema):
    """Every deployment area in one level package."""
    areas = []
    for export in package.exports:
        if not export["name"].startswith(AREA_CLASS):
            continue
        props, label = zen.read_actor(package, export, AREA_CLASS, schema)
        props = {prop["name"]: value for prop, _, _, value in props}
        area = {"package": path, "area": export["name"], "label": label, "destinations": []}
        root = props.get("RootComponent")
        if root and root > 0:
            component = package.exports[root - 1]
            component_props = {prop["name"]: value for prop, _, _, value in zen.read_properties(
                package, component, classes[component["class"]], schema, trailer="component")}
            if "RelativeLocation" in component_props:
                area["location"] = rounded(component_props["RelativeLocation"])
        for reference in props.get("PlayerDestinations") or []:
            if reference <= 0:
                raise zen.FormatError(f"{path}: {export['name']} has a destination in another package")
            point = package.exports[reference - 1]
            point_props, point_label = zen.read_actor(package, point, POINT_CLASS, schema)
            point_props = {prop["name"]: value for prop, _, _, value in point_props}
            component = package.exports[point_props["RootComponent"] - 1]
            component_class = classes[component["class"]]
            root_props = {prop["name"]: value for prop, _, _, value in zen.read_properties(
                package, component, component_class, schema, trailer="component")}
            if root_props.get("AttachParent"):
                raise zen.FormatError(f"{path}: {point['name']} is attached to something; "
                                      "its RelativeLocation isn't a level position")
            area["destinations"].append({
                "point": point["name"],
                "label": point_label,
                "location": rounded(root_props.get("RelativeLocation", {"X": 0, "Y": 0, "Z": 0})),
            })
        areas.append(area)
    return areas


def mission_levels(retoc, base, mission_chunks, schema):
    """Mission name -> its Level's folder."""
    levels = {}
    for path, chunk in mission_chunks.items():
        package = zen.ZenPackage(retoc.get(base, chunk))
        try:
            props = {prop["name"]: value for prop, _, _, value in zen.read_properties(
                package, package.export(path.rsplit("/", 1)[1]), "BrunoMissionData", schema)}
        except zen.FormatError:
            continue  # mission tables
        level = props.get("Level")
        if level:
            levels[path.rsplit("/", 1)[1]] = level.split(".", 1)[0].rsplit("/", 1)[0]
    return levels


def hull(points):
    """XY convex hull, counter-clockwise; each corner keeps its Z (as placement.lua builds it)."""
    unique, seen = [], set()
    for point in points:
        key = (round(point[0], 1), round(point[1], 1))
        if key not in seen:
            seen.add(key)
            unique.append(point)
    unique.sort(key=lambda p: (p[0], p[1]))
    if len(unique) < 3:
        return None

    def cross(o, a, b):
        return (a[0] - o[0]) * (b[1] - o[1]) - (a[1] - o[1]) * (b[0] - o[0])

    lower, upper = [], []
    for point in unique:
        while len(lower) >= 2 and cross(lower[-2], lower[-1], point) <= 0:
            lower.pop()
        lower.append(point)
    for point in reversed(unique):
        while len(upper) >= 2 and cross(upper[-2], upper[-1], point) <= 0:
            upper.pop()
        upper.append(point)
    corners = lower[:-1] + upper[:-1]
    return corners if len(corners) >= 3 else None


def placement_profiles():
    """PLACEMENT_PROFILES from placement.lua: name -> four (X, Y, Z) destinations."""
    text = PLACEMENT.read_text()
    block = text[text.index("local PLACEMENT_PROFILES = {"):]
    block = block[:block.index("\n}\n")]
    profiles = {}
    for match in re.finditer(r'name = "(\w+)".*?destinations = \{(.*?)\n\s*\}', block, re.S):
        points = re.findall(r"\{X = ([-\d.]+), Y = ([-\d.]+), Z = ([-\d.]+)\}", match.group(2))
        profiles[match.group(1)] = [tuple(map(float, point)) for point in points]
    return profiles


def profile_matches(profile, destinations):
    """placement.lua's match_placement_profile: a 2-D rigid transform from two points, then all
    four within 50 uu of distinct destinations."""
    first, second = profile[0], profile[1]
    ex, ey = second[0] - first[0], second[1] - first[1]
    expected = math.hypot(ex, ey)
    for i, a in enumerate(destinations):
        for j, b in enumerate(destinations):
            if i == j:
                continue
            ax, ay = b[0] - a[0], b[1] - a[1]
            actual = math.hypot(ax, ay)
            scale = actual / expected
            if not 0.95 <= scale <= 1.05:
                continue
            cos = (ex * ax + ey * ay) / (expected * actual)
            sin = (ex * ay - ey * ax) / (expected * actual)
            tx = a[0] - scale * (cos * first[0] - sin * first[1])
            ty = a[1] - scale * (sin * first[0] + cos * first[1])
            used, complete = set(), True
            for point in profile:
                px = tx + scale * (cos * point[0] - sin * point[1])
                py = ty + scale * (sin * point[0] + cos * point[1])
                best = min((k for k in range(len(destinations)) if k not in used),
                           key=lambda k: math.hypot(destinations[k][0] - px, destinations[k][1] - py),
                           default=None)
                if best is None or math.hypot(destinations[best][0] - px,
                                              destinations[best][1] - py) > PROFILE_MATCH_RADIUS:
                    complete = False
                    break
                used.add(best)
            if complete:
                return True
    return False


def report(areas):
    """Check placement.lua's assumptions against the scan. Returns False if a profile is off."""
    ok = True
    playable = [area for area in areas if "/Maps/Test/" not in area["package"]]
    print(f"{len(areas)} deployment areas in {len({a['package'] for a in areas})} packages "
          f"({len(areas) - len(playable)} in test maps)")
    counts = {}
    for area in playable:
        counts[len(area["destinations"])] = counts.get(len(area["destinations"]), 0) + 1
    print("  destinations per area: " + ", ".join(f"{n}: {c}" for n, c in sorted(counts.items())))

    for name, profile in placement_profiles().items():
        matched = [f"{a['package'].rsplit('/', 1)[1]}:{a['area']}" for a in areas
                   if profile_matches(profile, [d["location"] for d in a["destinations"]])]
        state = "ok" if len(matched) == 1 else "CHECK"
        ok = ok and len(matched) == 1
        print(f"  profile {name}: matches {len(matched)} area(s) {matched} [{state}]")

    spans, rises, edges, no_lane = [], [], 0, []
    for area in playable:
        points = [d["location"] for d in area["destinations"]]
        spans.append(max(math.hypot(a[0] - b[0], a[1] - b[1]) for a in points for b in points))
        corners = hull(points)
        if not corners:
            # Collinear or coincident points: the runtime has no lane and uses its distance test.
            no_lane.append(f"{area['package'].rsplit('/', 1)[1]}:{area['area']}")
        else:
            for index, corner in enumerate(corners):
                following = corners[(index + 1) % len(corners)]
                edges += 1
                rise = abs(corner[2] - following[2])
                if rise >= 0.5:  # below that is float noise in the cooked positions
                    rises.append(rise)
    print(f"  lane span (widest destination pair): median {statistics.median(spans):.0f} uu, "
          f"{sum(1 for s in spans if s < 2000)} of {len(spans)} under 2000 uu")
    print(f"  hull edges: {edges}; {len(rises)} rise, {sum(1 for r in rises if r < 25)} by under 25 uu;"
          f" rises above 220 uu: {sorted(round(r) for r in rises if r > 220)}")
    print(f"  areas with no lane (collinear points): {no_lane or 'none'}")
    return ok


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--retoc", required=True)
    parser.add_argument("--paks", required=True, type=Path)
    parser.add_argument("--cache", type=Path, help="keep fetched map packages here between runs")
    args = parser.parse_args()
    retoc = Retoc(args.retoc)
    schema = zen.Schema(json.loads(MAP_SCHEMA.read_text())["schemas"])
    mission_schema = zen.Schema(json.loads(MISSION_SCHEMA.read_text())["schemas"])
    with tempfile.TemporaryDirectory(prefix="squadsix-maps-") as temporary:
        base = link_base_game(args.paks, Path(temporary) / "base")
        chunks = retoc.chunks(base)
        maps = {path: chunk for path, chunk in retoc.chunks(base, suffix=".umap").items()
                if path.startswith(MAPS_ROOT)}
        cache = args.cache or Path(temporary) / "maps"
        print(f"Reading {len(maps)} map packages...", file=sys.stderr)
        fetch_all(retoc, base, sorted(set(maps.values())), cache)
        classes = script_classes(retoc, args.paks)
        areas = []
        for path, chunk in sorted(maps.items()):
            package = zen.ZenPackage((cache / chunk).read_bytes())
            if any(export["name"].startswith(AREA_CLASS) for export in package.exports):
                areas += scan_package(path, package, classes, schema)
        missions = mission_levels(retoc, base, {p: c for p, c in chunks.items()
                                                if p.startswith(MISSION_ROOT)}, mission_schema)
    for area in areas:
        folder = area["package"].rsplit("/", 1)[0]
        area["missions"] = sorted(name for name, level_folder in missions.items() if level_folder == folder)
    # One coordinate triple per line, so a diff after a game patch shows exactly which point moved.
    text = json.dumps({"areas": areas}, indent=1)
    text = re.sub(r"\[\s+(-?[\d.e+-]+),\s+(-?[\d.e+-]+),\s+(-?[\d.e+-]+)\s+\]", r"[\1, \2, \3]", text)
    OUTPUT.write_text(text + "\n")
    print(f"Wrote {OUTPUT.relative_to(ROOT)}")
    raise SystemExit(0 if report(areas) else 1)


if __name__ == "__main__":
    main()
