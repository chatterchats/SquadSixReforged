"""Per-map placement data for BP_SquadSixBrain, from Reforged's own sources (tools/export_placement_data.lua reads
placement.lua's FIXED layouts and PLACEMENT_PROFILES and directions.lua), so the two versions can't drift apart.

- Directions: which way each area's opening enemies are (directions.lua, from the game's spawners), keyed by level
  package and area name; used instead of the tactical volume's centre, which misleads where the lane sits at one end
  of a large volume (Best Served Cold).
- Fixed layouts: an area whose destinations are a layout's (every one within the match radius) gets the layout's
  hand-picked spots as its destinations, in order; a spot on an authored destination keeps that actor (the mission may
  know it by name, as Stillwatch's PlayerTacticalPoint_1.2_Trick). Nothing else is done to such an area.
- Profiles: an area matching a profile gets its rescues (inset towards the destinations' centroid where the profile
  says) as its first added destinations, then the usual cover search; its own destinations aren't improved.
Reforged matches layouts under any level-instance translation or yaw; every layout here was recorded in world
coordinates on a map that isn't instanced, so the brain matches them as they stand.
"""
import json
import subprocess
from pathlib import Path

from gf_graph import Graph, KSL, KML, KAL, GS, TARGET

REPO = Path(__file__).resolve().parents[2]
POINT = "/Script/BitReactorGame.TacticalPoint"
KSTR = "/Script/Engine.KismetStringLibrary"
SEPARATION = 100.0


def _data():
    out = subprocess.run(["luajit", str(REPO / "tools/export_placement_data.lua"),
                          str(REPO / "src/SquadSixReforged/Scripts")], capture_output=True, text=True, check=True)
    return json.loads(out.stdout)


DATA = _data()
MATCH_RADIUS = DATA["match_radius"]
SAME_POINT = DATA["same_point"]


def _inset(profile, rescue):
    if not profile.get("inset_rescues"):
        return rescue
    xs = [p["X"] for p in profile["destinations"]]
    ys = [p["Y"] for p in profile["destinations"]]
    cx, cy = sum(xs) / len(xs), sum(ys) / len(ys)
    return {"X": rescue["X"] + (cx - rescue["X"]) * DATA["inset"],
            "Y": rescue["Y"] + (cy - rescue["Y"]) * DATA["inset"], "Z": rescue["Z"]}


def _vectors(points):
    return "(" + ",".join(f"(X={p['X']:.4f},Y={p['Y']:.4f},Z={p.get('Z', 0.0):.4f})" for p in points) + ")"


def _ints(values):
    return "(" + ",".join(str(v) for v in values) + ")"


def _strings(values):
    return "(" + ",".join(f'"{v}"' for v in values) + ")"


def _flatten(sets, key, transform=lambda s, p: p):
    points, owners = [], []
    for index, item in enumerate(sets):
        for point in item[key]:
            points.append(transform(item, point))
            owners.append(index)
    return points, owners


def variables():
    return [
        {"name": "FixedDests", "type": "vector[]"}, {"name": "FixedDestOf", "type": "int[]"},
        {"name": "FixedSpots", "type": "vector[]"}, {"name": "FixedSpotOf", "type": "int[]"},
        {"name": "FixedCount", "type": "int", "default": str(len(DATA["fixed"]))},
        {"name": "ProfDests", "type": "vector[]"}, {"name": "ProfDestOf", "type": "int[]"},
        {"name": "ProfSpots", "type": "vector[]"}, {"name": "ProfSpotOf", "type": "int[]"},
        {"name": "ProfCount", "type": "int", "default": str(len(DATA["profiles"]))},
        {"name": "DirPkgs", "type": "string[]"}, {"name": "DirAreas", "type": "string[]"},
        {"name": "DirVecs", "type": "vector[]"},
        {"name": "MatchOk", "type": "bool"}, {"name": "FoundSet", "type": "int"},
        {"name": "NewDests", "type": f"object:{POINT}[]"}, {"name": "Reused", "type": f"object:{POINT}[]"},
        {"name": "NearFound", "type": f"object:{POINT}"}, {"name": "DirFound", "type": "bool"},
        {"name": "FixedApplied", "type": "int", "default": "0"},
        {"name": "ProfilesApplied", "type": "int", "default": "0"},
        {"name": "DirectionsUsed", "type": "int", "default": "0"},
    ]


def defaults():
    fixed_dests, fixed_dest_of = _flatten(DATA["fixed"], "destinations")
    fixed_spots, fixed_spot_of = _flatten(DATA["fixed"], "spots")
    prof_dests, prof_dest_of = _flatten(DATA["profiles"], "destinations")
    prof_spots, prof_spot_of = _flatten(DATA["profiles"], "rescues", _inset)
    keys = sorted(DATA["directions"])
    return {
        "FixedDests": _vectors(fixed_dests), "FixedDestOf": _ints(fixed_dest_of),
        "FixedSpots": _vectors(fixed_spots), "FixedSpotOf": _ints(fixed_spot_of),
        "ProfDests": _vectors(prof_dests), "ProfDestOf": _ints(prof_dest_of),
        "ProfSpots": _vectors(prof_spots), "ProfSpotOf": _ints(prof_spot_of),
        # "HM_Cly_010_Gameplay:BP_CombatPreparationArea_C_1" -> "/HM_Cly_010_Gameplay." in the area's path name.
        "DirPkgs": _strings(f"/{key.split(':')[0]}." for key in keys),
        "DirAreas": _strings(key.split(":")[1] for key in keys),
        "DirVecs": _vectors({**DATA["directions"][key], "Z": 0.0} for key in keys),
    }


def match_set():
    """MatchSet(Which, Points, Of) -> Matched: every point of set Which lies within MATCH_RADIUS of a current
    destination (Taken)."""
    g = Graph()
    g.node("setok", "set", var="MatchOk", defaults={"MatchOk": "true"})
    g.node("loop", "macro", macro="ForEachLoop")
    g.node("owner", "array_call", function=f"{KAL}:Array_Get")
    g.call("mine", f"{KML}:EqualEqual_IntInt")
    g.node("ismine", "branch")
    g.call("near", "self:MinDistance2D")
    g.call("far", f"{KML}:Greater_DoubleDouble", {"B": MATCH_RADIUS})
    g.node("isfar", "branch")
    g.node("setfail", "set", var="MatchOk", defaults={"MatchOk": "false"})
    g.node("getok", "get", var="MatchOk")
    g.chain("entry", "setok", "loop.Exec")
    g.chain("loop.LoopBody", "ismine")
    g.chain("ismine", "near", "isfar")
    g.chain("isfar", "setfail")
    g.chain("loop.Completed", "result")
    g.wire(("entry.Points", "loop.Array"), ("entry.Of", "owner.TargetArray"), ("loop.Array Index", "owner.Index"),
           ("owner.Item", "mine.A"), ("entry.Which", "mine.B"), ("mine.ReturnValue", "ismine.Condition"),
           ("loop.Array Element", "near.Point"), ("near.Result", "far.A"), ("far.ReturnValue", "isfar.Condition"),
           ("getok.MatchOk", "result.Matched"))
    return {"name": "MatchSet", "inputs": [{"name": "Which", "type": "int"}, {"name": "Points", "type": "vector[]"},
                                           {"name": "Of", "type": "int[]"}],
            "outputs": [{"name": "Matched", "type": "bool"}], **g.spec()}


def find_set():
    """FindSet(Points, Of, Count) -> Index: the set (layout or profile) the area's destinations match, or -1."""
    g = Graph()
    g.node("setnone", "set", var="FoundSet", defaults={"FoundSet": -1})
    g.call("last", f"{KML}:Subtract_IntInt", {"B": 1})
    g.node("loop", "macro", macro="ForLoop", defaults={"FirstIndex": 0})
    g.call("match", "self:MatchSet")
    g.node("matched", "branch")
    g.node("setfound", "set", var="FoundSet")
    g.node("getfound", "get", var="FoundSet")
    g.chain("entry", "setnone", "loop.execute")
    g.chain("loop.LoopBody", "match", "matched")
    g.chain("matched", "setfound")
    g.chain("loop.Completed", "result")
    g.wire(("entry.Count", "last.A"), ("last.ReturnValue", "loop.LastIndex"), ("loop.Index", "match.Which"),
           ("entry.Points", "match.Points"), ("entry.Of", "match.Of"), ("match.Matched", "matched.Condition"),
           ("loop.Index", "setfound.FoundSet"), ("getfound.FoundSet", "result.Index"))
    return {"name": "FindSet", "inputs": [{"name": "Points", "type": "vector[]"}, {"name": "Of", "type": "int[]"},
                                          {"name": "Count", "type": "int"}],
            "outputs": [{"name": "Index", "type": "int"}], **g.spec()}


def spawn_at():
    """SpawnAt(Location) -> Point: a TacticalPoint there, facing as the area's first destination, on its team."""
    g = Graph()
    g.node("gettemplate", "get", var="Template")
    g.call("facing", "/Script/Engine.Actor:K2_GetActorRotation")
    g.call("one", f"{KML}:MakeVector", {"X": 1, "Y": 1, "Z": 1})
    g.call("where", f"{KML}:MakeTransform")
    g.call("spawn", f"{GS}:BeginDeferredActorSpawnFromClass",
           {"ActorClass": POINT, "CollisionHandlingOverride": "AlwaysSpawn"})
    g.node("getteam", "get", var="Team")
    g.call("team", f"{KSL}:SetClassPropertyByName", {"PropertyName": "OwningTeam"})
    g.call("finish", f"{GS}:FinishSpawningActor")
    g.node("point", "cast", **{"class": POINT})
    g.chain("entry", "spawn", "team", "finish", "point")
    g.chain("point", "result")
    g.wire(("gettemplate.Template", "facing.self"), ("entry.Location", "where.Location"),
           ("facing.ReturnValue", "where.Rotation"), ("one.ReturnValue", "where.Scale"),
           ("where.ReturnValue", "spawn.SpawnTransform"), ("spawn.ReturnValue", "team.Object"),
           ("getteam.Team", "team.Value"), ("spawn.ReturnValue", "finish.Actor"),
           ("where.ReturnValue", "finish.SpawnTransform"), ("finish.ReturnValue", "point.Object"),
           ("point.AsTactical Point", "result.Point"))
    return {"name": "SpawnAt", "inputs": [{"name": "Location", "type": "vector"}],
            "outputs": [{"name": "Point", "type": f"object:{POINT}"}], **g.spec()}


def near_dest():
    """NearDest(Point) -> Dest: a destination not yet reused within SAME_POINT of Point (it is that destination)."""
    g = Graph()
    g.node("clear", "set", var="NearFound")
    g.node("getdests", "get", var="Dests")
    g.node("loop", "macro", macro="ForEachLoop")
    g.call("loc", "/Script/Engine.Actor:K2_GetActorLocation")
    g.call("dist", f"{KML}:Vector_Distance")
    g.call("close", f"{KML}:LessEqual_DoubleDouble", {"B": SAME_POINT})
    g.node("getreused", "get", var="Reused")
    g.node("taken", "array_call", function=f"{KAL}:Array_Contains")
    g.call("free", f"{KML}:Not_PreBool")
    g.call("both", f"{KML}:BooleanAND")
    g.node("isit", "branch")
    g.node("setnear", "set", var="NearFound")
    g.node("getnear", "get", var="NearFound")
    g.chain("entry", "clear", "loop.Exec")
    g.chain("loop.LoopBody", "isit")
    g.chain("isit", "setnear")
    g.chain("loop.Completed", "result")
    g.wire(("getdests.Dests", "loop.Array"), ("loop.Array Element", "loc.self"), ("loc.ReturnValue", "dist.V1"),
           ("entry.Point", "dist.V2"), ("dist.ReturnValue", "close.A"), ("getreused.Reused", "taken.TargetArray"),
           ("loop.Array Element", "taken.ItemToFind"), ("taken.ReturnValue", "free.A"),
           ("close.ReturnValue", "both.A"), ("free.ReturnValue", "both.B"), ("both.ReturnValue", "isit.Condition"),
           ("loop.Array Element", "setnear.NearFound"), ("getnear.NearFound", "result.Dest"))
    return {"name": "NearDest", "inputs": [{"name": "Point", "type": "vector"}],
            "outputs": [{"name": "Dest", "type": f"object:{POINT}"}], **g.spec()}


def apply_fixed():
    """ApplyFixed(Layout): Dests becomes the layout's spots, in order (authored actors kept where a spot is one)."""
    g = Graph()
    g.node("getnew", "get", var="NewDests")
    g.node("clearnew", "array_call", function=f"{KAL}:Array_Clear")
    g.node("getreused", "get", var="Reused")
    g.node("clearreused", "array_call", function=f"{KAL}:Array_Clear")
    g.node("getspots", "get", var="FixedSpots")
    g.node("loop", "macro", macro="ForEachLoop")
    g.node("getof", "get", var="FixedSpotOf")
    g.node("owner", "array_call", function=f"{KAL}:Array_Get")
    g.call("mine", f"{KML}:EqualEqual_IntInt")
    g.node("ismine", "branch")
    g.call("near", "self:NearDest")
    g.call("hasnear", f"{KSL}:IsValid")
    g.node("reuse", "branch")
    g.node("getreused2", "get", var="Reused")
    g.node("markreused", "array_call", function=f"{KAL}:Array_Add")
    g.node("getnew2", "get", var="NewDests")
    g.node("keep", "array_call", function=f"{KAL}:Array_Add")
    g.call("spawn", "self:SpawnAt")
    g.node("getnew3", "get", var="NewDests")
    g.node("addnew", "array_call", function=f"{KAL}:Array_Add")
    g.node("getnew4", "get", var="NewDests")
    g.node("setdests", "set", var="Dests")
    g.node("getapplied", "get", var="FixedApplied")
    g.call("addapplied", f"{KML}:Add_IntInt", {"B": 1})
    g.node("setapplied", "set", var="FixedApplied")
    g.chain("entry", "clearnew", "clearreused", "loop.Exec")
    g.chain("loop.LoopBody", "ismine")
    g.chain("ismine", "near", "reuse")
    g.chain("reuse", "markreused", "keep")
    g.chain("reuse.else", "spawn", "addnew")
    g.chain("loop.Completed", "setdests", "setapplied")
    g.wire(("getnew.NewDests", "clearnew.TargetArray"), ("getreused.Reused", "clearreused.TargetArray"),
           ("getspots.FixedSpots", "loop.Array"), ("getof.FixedSpotOf", "owner.TargetArray"),
           ("loop.Array Index", "owner.Index"), ("owner.Item", "mine.A"), ("entry.Layout", "mine.B"),
           ("mine.ReturnValue", "ismine.Condition"), ("loop.Array Element", "near.Point"),
           ("near.Dest", "hasnear.Object"), ("hasnear.ReturnValue", "reuse.Condition"),
           ("getreused2.Reused", "markreused.TargetArray"), ("near.Dest", "markreused.NewItem"),
           ("getnew2.NewDests", "keep.TargetArray"), ("near.Dest", "keep.NewItem"),
           ("loop.Array Element", "spawn.Location"), ("getnew3.NewDests", "addnew.TargetArray"),
           ("spawn.Point", "addnew.NewItem"), ("getnew4.NewDests", "setdests.Dests"),
           ("getapplied.FixedApplied", "addapplied.A"), ("addapplied.ReturnValue", "setapplied.FixedApplied"))
    return {"name": "ApplyFixed", "inputs": [{"name": "Layout", "type": "int"}], "outputs": [], **g.spec()}


def add_profile_spots():
    """AddProfileSpots(Profile): the profile's rescues become destinations, while the area has fewer than six and each
    is a tile from every point."""
    g = Graph()
    g.node("getspots", "get", var="ProfSpots")
    g.node("loop", "macro", macro="ForEachLoop")
    g.node("getof", "get", var="ProfSpotOf")
    g.node("owner", "array_call", function=f"{KAL}:Array_Get")
    g.call("mine", f"{KML}:EqualEqual_IntInt")
    g.node("getdests", "get", var="Dests")
    g.node("len", "array_call", function=f"{KAL}:Array_Length")
    g.call("room", f"{KML}:Less_IntInt", {"B": TARGET})
    g.call("near", "self:MinDistance2D")
    g.call("apart", f"{KML}:GreaterEqual_DoubleDouble", {"B": SEPARATION})
    g.call("and1", f"{KML}:BooleanAND")
    g.call("and2", f"{KML}:BooleanAND")
    g.node("useit", "branch")
    g.call("spawn", "self:SpawnAt")
    g.node("getdests2", "get", var="Dests")
    g.node("adddest", "array_call", function=f"{KAL}:Array_Add")
    g.node("gettaken", "get", var="Taken")
    g.node("addtaken", "array_call", function=f"{KAL}:Array_Add")
    g.node("getadded", "get", var="PointsAdded")
    g.call("addadded", f"{KML}:Add_IntInt", {"B": 1})
    g.node("setadded", "set", var="PointsAdded")
    g.chain("entry", "loop.Exec")
    g.chain("loop.LoopBody", "near", "useit")
    g.chain("useit", "spawn", "adddest", "addtaken", "setadded")
    g.wire(("getspots.ProfSpots", "loop.Array"), ("getof.ProfSpotOf", "owner.TargetArray"),
           ("loop.Array Index", "owner.Index"), ("owner.Item", "mine.A"), ("entry.Profile", "mine.B"),
           ("getdests.Dests", "len.TargetArray"), ("len.ReturnValue", "room.A"),
           ("loop.Array Element", "near.Point"), ("near.Result", "apart.A"),
           ("mine.ReturnValue", "and1.A"), ("room.ReturnValue", "and1.B"),
           ("and1.ReturnValue", "and2.A"), ("apart.ReturnValue", "and2.B"), ("and2.ReturnValue", "useit.Condition"),
           ("loop.Array Element", "spawn.Location"), ("getdests2.Dests", "adddest.TargetArray"),
           ("spawn.Point", "adddest.NewItem"), ("gettaken.Taken", "addtaken.TargetArray"),
           ("loop.Array Element", "addtaken.NewItem"),
           ("getadded.PointsAdded", "addadded.A"), ("addadded.ReturnValue", "setadded.PointsAdded"))
    return {"name": "AddProfileSpots", "inputs": [{"name": "Profile", "type": "int"}], "outputs": [], **g.spec()}


def lookup_direction():
    """LookupDirection(Area) -> Found: the area's encounter direction from directions.lua into Forward (and Missing 0)."""
    g = Graph()
    g.node("setnone", "set", var="DirFound", defaults={"DirFound": "false"})
    g.call("path", f"{KSL}:GetPathName")
    g.call("name", f"{KSL}:GetObjectName")
    g.node("getpkgs", "get", var="DirPkgs")
    g.node("loop", "macro", macro="ForEachLoop")
    g.call("inpkg", f"{KSTR}:Contains")
    g.node("getareas", "get", var="DirAreas")
    g.node("area", "array_call", function=f"{KAL}:Array_Get")
    g.call("samename", f"{KSTR}:EqualEqual_StrStr")
    g.call("both", f"{KML}:BooleanAND")
    g.node("isit", "branch")
    g.node("getvecs", "get", var="DirVecs")
    g.node("vec", "array_call", function=f"{KAL}:Array_Get")
    g.node("setforward", "set", var="Forward")
    g.node("setmissing", "set", var="Missing", defaults={"Missing": 0})
    g.node("setfound", "set", var="DirFound", defaults={"DirFound": "true"})
    g.node("getused", "get", var="DirectionsUsed")
    g.call("addused", f"{KML}:Add_IntInt", {"B": 1})
    g.node("setused", "set", var="DirectionsUsed")
    g.node("getfound", "get", var="DirFound")
    g.chain("entry", "setnone", "loop.Exec")
    g.chain("loop.LoopBody", "isit")
    g.chain("isit", "setforward", "setmissing", "setfound", "setused")
    g.chain("loop.Completed", "result")
    g.wire(("entry.Area", "path.Object"), ("entry.Area", "name.Object"), ("getpkgs.DirPkgs", "loop.Array"),
           ("path.ReturnValue", "inpkg.SearchIn"), ("loop.Array Element", "inpkg.Substring"),
           ("getareas.DirAreas", "area.TargetArray"), ("loop.Array Index", "area.Index"),
           ("name.ReturnValue", "samename.A"), ("area.Item", "samename.B"),
           ("inpkg.ReturnValue", "both.A"), ("samename.ReturnValue", "both.B"), ("both.ReturnValue", "isit.Condition"),
           ("getvecs.DirVecs", "vec.TargetArray"), ("loop.Array Index", "vec.Index"),
           ("vec.Item", "setforward.Forward"),
           ("getused.DirectionsUsed", "addused.A"), ("addused.ReturnValue", "setused.DirectionsUsed"),
           ("getfound.DirFound", "result.Found"))
    return {"name": "LookupDirection", "inputs": [{"name": "Area", "type": "object:/Script/BitReactorGame.CombatPreparationArea"}],
            "outputs": [{"name": "Found", "type": "bool"}], **g.spec()}


def functions():
    return [match_set(), find_set(), spawn_at(), near_dest(), apply_fixed(), add_profile_spots(), lookup_direction()]
