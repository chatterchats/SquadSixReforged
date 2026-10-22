#!/usr/bin/env python3
"""Generate unreal/specs/gf/*.json, the Game Feature trial's ZComAuthoring specs (tools/build_gf.sh runs this first).

BP_SquadSixBrain is the component the plugin's AddComponents action puts on every BitReactorGameState. Three timers:
- Sweep (2 s): the missions Squad Six ships at six (data/missions.tsv) raised to six.
- Deploy (0.25 s): every CombatPreparationArea not seen before (once its navmesh and the cover data are in) first has
  its own destinations improved as Reforged's improve_game_spots does (snapped onto the centre of the cover they stand
  in, or moved to facing cover nearby), then gets player destinations up to six. A new point is, as in Reforged's COVER.choose, the game's nearest cover pocket around a tile or two off an
  existing destination that is real cover, faces the encounter (its tactical volume), keeps a tile from every point,
  stays with the group and is on the navmesh: high before low, then facing more squarely, then nearer the centroid.
  With no such cover, the candidate tile that lands on the navmesh, within a step of its neighbour's floor, a tile
  from everyone and nearest the centroid. The game's own BP_CombatPreparationArea walks operators five and six on.
- Unstack (0.5 s, a mission's first 30 s): operators spawned on top of each other moved a tile apart (gf_unstack.py).
- Lineup (0.1 s): the squad screen's lineup at six (gf_lineup.py) and the holotable's "4 - 6" (gf_holotable.py).
Counters (Sweeps, Seen, Raised, AreasSeen, AreasExpanded, PointsAdded, CoveredPoints, SpotsKept, SpotsSnapped, SpotsMoved) are for reading back from outside: shipping
builds have no log.
"""
import json
import math
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))  # run with python3 -I, which leaves the script's dir out
import gf_holotable  # noqa: E402
import gf_maps  # noqa: E402
import gf_unstack  # noqa: E402
import gf_spawn  # noqa: E402
import gf_lineup  # noqa: E402
from gf_graph import GS, KAL, KML, KSL, TARGET, Graph  # noqa: E402

OUT = Path(__file__).resolve().parent / "gf"
REPO = Path(__file__).resolve().parents[2]


def raised_missions():
    """The missions Squad Six ships at six that the game doesn't (data/missions.tsv, Reforged's own table): Deep Cover
    from 3, the rest from 4. The solo Bespin, the three-operator missions and the Serolonis Job tutorial aren't listed."""
    names = []
    for line in (REPO / "data/missions.tsv").read_text().splitlines():
        if line.startswith("#") or line.startswith("mission\t") or not line.strip():
            continue
        path, game, squad = line.split("\t")[:3]
        if squad == "6" and game != "6":
            names.append(path.rsplit("/", 1)[-1])
    return names

NAV = "/Script/NavigationSystem.NavigationSystemV1"
AREA = "/Script/BitReactorGame.CombatPreparationArea"
POINT = "/Script/BitReactorGame.TacticalPoint"
MISSION = "/Script/BitReactorGame.BitReactorMissionData"

TARGETING = "/Script/BitReactorGame.BRG_TargetingFunctionLibrary"
TILE = 100
# Whole tiles off an existing destination, nearest first.
OFFSETS = [(TILE, 0), (-TILE, 0), (0, TILE), (0, -TILE),
           (TILE, TILE), (TILE, -TILE), (-TILE, TILE), (-TILE, -TILE),
           (2 * TILE, 0), (-2 * TILE, 0), (0, 2 * TILE), (0, -2 * TILE)]
# A bounded local grid supplements the broad nearest-pocket queries. A smaller query radius
# exposes free pockets hidden behind a nearer occupied pocket (Belly of the Beast, area 2).
COVER_GRID = [(x * TILE, y * TILE) for x in range(-3, 4) for y in range(-3, 4)]
COVER_GRID_RANGE = 120.0
SAME_TILE = 75.0        # closer than this to another point is the same tile
SNAP = 30.0             # the navmesh may move a candidate this far sideways
STEP = 100.0            # most a candidate's floor may differ from its neighbour's
NO_CANDIDATE = 1.0e12
COVER_RANGE = 250.0     # RESCUE.cover_range: nearest cover pocket this far from a search point
COVER_FACING = 0.5      # RESCUE.cover_facing: pocket normal . direction to the encounter, at least
NEAR_GROUP = 300.0
HERE_RANGE = 60.0       # RESCUE.cover_here_range: the cover a destination stands in
COVER_SNAP = 30.0       # RESCUE.cover_snap: further than this off its cover's centre, a destination moves onto it
IMPROVE_RANGE = 200.0   # RESCUE.cover_improve_range
IMPROVE_RADII = (100.0, 200.0)  # RESCUE.cover_improve_offsets, each in eight directions
SEPARATION = 100.0      # MIN_DESTINATION_SEPARATION_SQ's root: two destinations at least this far apart
MIN_FORWARD = 300.0     # RESCUE.cover_min_forward: a volume centre nearer the group gives no direction
SCRIPTED_MAP = "SerolonisJob"  # COVER.scripted_maps: the tutorial's scripted overwatch needs its own spots
COVER_WAIT_PASSES = 40  # Deploy passes (0.25 s) an area waits for the game's cover data before using open ground      # a pocket further than this from every point is someone else's cover


def event_graph():
    g = Graph()
    g.node("begin", "event", name="ReceiveBeginPlay")
    g.node("me", "self")
    g.call("sweep_timer", f"{KSL}:K2_SetTimer", {"FunctionName": "Sweep", "Time": "2.0", "bLooping": "true"})
    g.call("deploy_timer", f"{KSL}:K2_SetTimer", {"FunctionName": "Deploy", "Time": "0.25", "bLooping": "true"})
    g.call("lineup_timer", f"{KSL}:K2_SetTimer", {"FunctionName": "Lineup", "Time": "0.1", "bLooping": "true"})
    g.call("unstack_timer", f"{KSL}:K2_SetTimer", {"FunctionName": "Unstack", "Time": "0.5", "bLooping": "true"})
    g.call("spawn_timer", f"{KSL}:K2_SetTimer", {"FunctionName": "SpawnRescue", "Time": "2.0", "bLooping": "true"})
    g.chain("begin", "sweep_timer", "deploy_timer", "lineup_timer", "unstack_timer", "spawn_timer")
    g.wire(("me.self", "spawn_timer.Object"))
    g.wire(("me.self", "sweep_timer.Object"), ("me.self", "deploy_timer.Object"), ("me.self", "lineup_timer.Object"),
           ("me.self", "unstack_timer.Object"))
    gf_lineup.event(g)
    gf_unstack.event(g)
    gf_spawn.event(g)

    # Sweep: mission squad limits.
    g.node("sweep", "custom_event", name="Sweep")
    g.call("registry", "/Script/AssetRegistry.AssetRegistryHelpers:GetAssetRegistry")
    g.call("byclass", "/Script/AssetRegistry.AssetRegistry:GetAssetsByClass",
           {"ClassPathName": "/Script/Bruno.BrunoMissionData"})
    g.node("setfound", "set", var="Found")
    g.node("getfound", "get", var="Found")
    g.node("count", "array_call", function=f"{KAL}:Array_Length")
    g.node("setseen", "set", var="Seen")
    g.node("loop", "macro", macro="ForEachLoop")
    g.call("asset", "/Script/AssetRegistry.AssetRegistryHelpers:GetAsset")
    g.node("mission", "cast", **{"class": MISSION})
    g.call("name", f"{KSL}:GetObjectName")
    g.node("getraise", "get", var="RaiseNames")
    g.node("listed", "array_call", function=f"{KAL}:Array_Contains")
    g.call("unlisted", f"{KML}:Not_PreBool")
    g.node("guarded", "branch")
    g.node("getkept", "get", var="Kept")
    g.node("keep", "array_call", function=f"{KAL}:Array_AddUnique")
    g.node("getmax", "get", var=f"{MISSION}:MaxSquadSize")
    g.call("below", f"{KML}:Less_IntInt", {"B": TARGET})
    g.node("raise", "branch")
    # The kit compiles MaxSquadSize BlueprintReadOnly (flags 0x15), so no Set node; the game doesn't check.
    g.call("setmax", f"{KSL}:SetIntPropertyByName", {"PropertyName": "MaxSquadSize", "Value": TARGET})
    g.node("getraised", "get", var="Raised")
    g.call("addraised", f"{KML}:Add_IntInt", {"B": 1})
    g.node("setraised", "set", var="Raised")
    g.node("getsweeps", "get", var="Sweeps")
    g.call("addsweeps", f"{KML}:Add_IntInt", {"B": 1})
    g.node("setsweeps", "set", var="Sweeps")
    g.chain("sweep", "byclass", "setfound", "setseen", "loop.Exec")
    g.chain("loop.LoopBody", "mission")
    g.chain("mission", "guarded")
    g.chain("guarded.else", "keep", "raise")
    g.chain("raise", "setmax", "setraised")
    g.chain("loop.Completed", "setsweeps")
    cast = "mission.AsBit Reactor Mission Data"
    g.wire(("registry.ReturnValue", "byclass.self"), ("byclass.OutAssetData", "setfound.Found"),
           ("getfound.Found", "count.TargetArray"), ("count.ReturnValue", "setseen.Seen"),
           ("getfound.Found", "loop.Array"), ("loop.Array Element", "asset.InAssetData"),
           ("asset.ReturnValue", "mission.Object"), (cast, "name.Object"),
           ("getraise.RaiseNames", "listed.TargetArray"), ("name.ReturnValue", "listed.ItemToFind"),
           ("listed.ReturnValue", "unlisted.A"), ("unlisted.ReturnValue", "guarded.Condition"), ("getkept.Kept", "keep.TargetArray"), (cast, "keep.NewItem"),
           (cast, "getmax.self"), ("getmax.MaxSquadSize", "below.A"), ("below.ReturnValue", "raise.Condition"),
           (cast, "setmax.Object"), ("getraised.Raised", "addraised.A"), ("addraised.ReturnValue", "setraised.Raised"),
           ("getsweeps.Sweeps", "addsweeps.A"), ("addsweeps.ReturnValue", "setsweeps.Sweeps"))

    # Deploy: each preparation area once.
    g.node("deploy", "custom_event", name="Deploy")
    g.call("areas", f"{GS}:GetAllActorsOfClass", {"ActorClass": AREA})
    g.node("arealoop", "macro", macro="ForEachLoop")
    g.node("area", "cast", **{"class": AREA})
    g.node("getdone", "get", var="Done")
    g.node("seen_before", "array_call", function=f"{KAL}:Array_Contains")
    g.node("isnew", "branch")
    g.node("getdone2", "get", var="Done")
    g.node("remember", "array_call", function=f"{KAL}:Array_Add")
    g.node("getareas", "get", var="AreasSeen")
    g.call("addareas", f"{KML}:Add_IntInt", {"B": 1})
    g.node("setareas", "set", var="AreasSeen")
    g.call("expand", "self:ExpandArea")
    g.node("getpasses", "get", var="DeployPasses")
    g.call("addpasses", f"{KML}:Add_IntInt", {"B": 1})
    g.node("setpasses", "set", var="DeployPasses")
    g.chain("deploy", "setpasses", "areas", "arealoop.Exec")
    g.chain("arealoop.LoopBody", "area")
    g.chain("area", "isnew")
    # The navmesh streams in after the level: an area waits until its first destination projects onto it,
    # else every candidate fails and the area would be written off (seen in SK_Brentaal_030, 2026-10-18).
    g.call("near", "self:AreaNearby")
    g.node("isnear", "branch")
    g.call("ready", "self:NavReady")
    g.node("isready", "branch")
    g.chain("isnew.else", "near", "isnear")
    g.chain("isnear", "ready", "isready")
    g.chain("isready", "remember", "setareas", "expand")
    acast = "area.AsCombat Preparation Area"
    g.wire(("areas.OutActors", "arealoop.Array"), ("arealoop.Array Element", "area.Object"),
           ("getdone.Done", "seen_before.TargetArray"), (acast, "seen_before.ItemToFind"),
           ("seen_before.ReturnValue", "isnew.Condition"), ("getdone2.Done", "remember.TargetArray"),
           (acast, "remember.NewItem"), ("getareas.AreasSeen", "addareas.A"),
           ("addareas.ReturnValue", "setareas.AreasSeen"), (acast, "expand.Area"), (acast, "ready.Area"), ("ready.Ready", "isready.Condition"),
           ("getpasses.DeployPasses", "addpasses.A"), ("addpasses.ReturnValue", "setpasses.DeployPasses"),
           (acast, "near.Area"), ("near.Nearby", "isnear.Condition"))
    return g.spec()


def expand_area():
    """ExpandArea(Area): the area's destinations for six, as Reforged's ensure_player_destinations.

    Destinations are read once into Dests, changed there, and written back by name (the kit's PlayerDestinations is
    read-only). The encounter's direction is the area's from directions.lua, else from the authored points' centroid to
    the linked tactical volume. Then, first match wins: a fixed layout replaces the destinations outright; a profile
    adds its rescues and then cover points, without improving the game's own; any other area has its own improved
    (not on the scripted tutorial, and only with a direction) and points added around them.
    """
    g = Graph()
    g.node("getpd", "get", var=f"{AREA}:PlayerDestinations")
    g.node("setdests", "set", var="Dests")
    g.node("getdests", "get", var="Dests")
    g.node("len", "array_call", function=f"{KAL}:Array_Length")
    g.call("hasany", f"{KML}:Greater_IntInt", {"B": 0})
    g.node("anydest", "branch")
    g.node("first", "array_call", function=f"{KAL}:Array_Get", defaults={"Index": 0})
    g.node("settemplate", "set", var="Template")
    g.node("getteam", "get", var=f"{POINT}:OwningTeam")
    g.node("setteam", "set", var="Team")
    g.call("group1", "self:Group")
    # The encounter's direction: from the centroid to the linked tactical volume, if that's far enough to mean one.
    g.call("volume", f"{AREA}:GetLinkedTacticalArea")
    g.call("hasvolume", f"{KSL}:IsValid")
    g.call("volloc", "/Script/Engine.Actor:K2_GetActorLocation")
    g.node("getcentre", "get", var="Centroid")
    g.call("towards", f"{KML}:Subtract_VectorVector")
    g.call("span", f"{KML}:VSizeXY")
    g.call("farenough", f"{KML}:GreaterEqual_DoubleDouble", {"B": MIN_FORWARD})
    g.call("direction", f"{KML}:BooleanAND")
    g.call("nodirection", f"{KML}:Not_PreBool")
    g.call("missing", f"{KML}:Conv_BoolToDouble")
    g.node("setmissing", "set", var="Missing")
    g.call("forward", f"{KML}:Normal2D")
    g.node("setforward", "set", var="Forward")
    # improve_game_spots: not on the scripted tutorial, and only with a direction to face.
    g.call("path", f"{KSL}:GetPathName")
    g.call("scripted", "/Script/Engine.KismetStringLibrary:Contains", {"Substring": SCRIPTED_MAP})
    g.call("notscripted", f"{KML}:Not_PreBool")
    g.call("improvable", f"{KML}:BooleanAND")
    g.call("lookup", "self:LookupDirection")
    g.node("getmissing", "get", var="Missing")
    g.call("hasdirection", f"{KML}:Less_DoubleDouble", {"B": 0.5})
    # Fixed layouts, then profiles (gf_maps.py).
    g.node("getfixeddests", "get", var="FixedDests")
    g.node("getfixedof", "get", var="FixedDestOf")
    g.node("getfixedcount", "get", var="FixedCount")
    g.call("fixed", "self:FindSet")
    g.call("isfixed", f"{KML}:GreaterEqual_IntInt", {"B": 0})
    g.node("dofixed", "branch")
    g.call("applyfixed", "self:ApplyFixed")
    g.node("writeback3", "array_call", function=f"{KAL}:SetArrayPropertyByName",
           defaults={"PropertyName": "PlayerDestinations"})
    g.node("setexp3", "set", var="AreasExpanded")
    g.node("getprofdests", "get", var="ProfDests")
    g.node("getprofof", "get", var="ProfDestOf")
    g.node("getprofcount", "get", var="ProfCount")
    g.call("profile", "self:FindSet")
    g.call("isprofile", f"{KML}:GreaterEqual_IntInt", {"B": 0})
    g.node("doprofile", "branch")
    g.call("profspots", "self:AddProfileSpots")
    g.node("getprofapplied", "get", var="ProfilesApplied")
    g.call("addprofapplied", f"{KML}:Add_IntInt", {"B": 1})
    g.node("setprofapplied", "set", var="ProfilesApplied")
    g.call("group3", "self:Group")
    g.call("add3", "self:AddPoints")
    g.node("writeback4", "array_call", function=f"{KAL}:SetArrayPropertyByName",
           defaults={"PropertyName": "PlayerDestinations"})
    g.node("setexp4", "set", var="AreasExpanded")
    g.node("doimprove", "branch")
    g.call("improve", "self:ImprovePoints")
    g.call("group2", "self:Group")
    g.call("add", "self:AddPoints")
    g.call("add2", "self:AddPoints")
    g.node("getdests2", "get", var="Dests")
    g.node("writeback", "array_call", function=f"{KAL}:SetArrayPropertyByName",
           defaults={"PropertyName": "PlayerDestinations"})
    g.node("writeback2", "array_call", function=f"{KAL}:SetArrayPropertyByName",
           defaults={"PropertyName": "PlayerDestinations"})
    g.node("getexp", "get", var="AreasExpanded")
    g.call("addexp", f"{KML}:Add_IntInt", {"B": 1})
    g.node("setexp", "set", var="AreasExpanded")
    g.node("setexp2", "set", var="AreasExpanded")
    g.chain("entry", "setdests", "anydest")
    g.chain("anydest", "settemplate", "setteam", "group1", "setmissing", "setforward", "lookup", "fixed", "dofixed")
    g.chain("dofixed", "applyfixed", "writeback3", "setexp3")
    g.chain("dofixed.else", "profile", "doprofile")
    g.chain("doprofile", "profspots", "setprofapplied", "group3", "add3", "writeback4", "setexp4")
    g.chain("doprofile.else", "doimprove")
    g.chain("doimprove", "improve", "group2", "add", "writeback", "setexp")
    g.chain("doimprove.else", "add2", "writeback2", "setexp2")
    g.wire(("entry.Area", "getpd.self"), ("getpd.PlayerDestinations", "setdests.Dests"),
           ("getdests.Dests", "len.TargetArray"), ("len.ReturnValue", "hasany.A"),
           ("hasany.ReturnValue", "anydest.Condition"),
           ("getdests.Dests", "first.TargetArray"), ("first.Item", "settemplate.Template"),
           ("first.Item", "getteam.self"), ("getteam.OwningTeam", "setteam.Team"),
           ("entry.Area", "volume.self"), ("volume.ReturnValue", "hasvolume.Object"),
           ("volume.ReturnValue", "volloc.self"), ("volloc.ReturnValue", "towards.A"),
           ("getcentre.Centroid", "towards.B"), ("towards.ReturnValue", "span.A"), ("span.ReturnValue", "farenough.A"),
           ("hasvolume.ReturnValue", "direction.A"), ("farenough.ReturnValue", "direction.B"),
           ("direction.ReturnValue", "nodirection.A"), ("nodirection.ReturnValue", "missing.InBool"),
           ("missing.ReturnValue", "setmissing.Missing"),
           ("towards.ReturnValue", "forward.A"), ("forward.ReturnValue", "setforward.Forward"),
           ("entry.Area", "path.Object"), ("path.ReturnValue", "scripted.SearchIn"),
           ("scripted.ReturnValue", "notscripted.A"), ("notscripted.ReturnValue", "improvable.A"),
           ("getmissing.Missing", "hasdirection.A"), ("hasdirection.ReturnValue", "improvable.B"),
           ("improvable.ReturnValue", "doimprove.Condition"), ("entry.Area", "lookup.Area"),
           ("getfixeddests.FixedDests", "fixed.Points"), ("getfixedof.FixedDestOf", "fixed.Of"),
           ("getfixedcount.FixedCount", "fixed.Count"), ("fixed.Index", "isfixed.A"),
           ("isfixed.ReturnValue", "dofixed.Condition"), ("fixed.Index", "applyfixed.Layout"),
           ("entry.Area", "writeback3.Object"), ("getdests2.Dests", "writeback3.Value"),
           ("addexp.ReturnValue", "setexp3.AreasExpanded"),
           ("getprofdests.ProfDests", "profile.Points"), ("getprofof.ProfDestOf", "profile.Of"),
           ("getprofcount.ProfCount", "profile.Count"), ("profile.Index", "isprofile.A"),
           ("isprofile.ReturnValue", "doprofile.Condition"), ("profile.Index", "profspots.Profile"),
           ("getprofapplied.ProfilesApplied", "addprofapplied.A"),
           ("addprofapplied.ReturnValue", "setprofapplied.ProfilesApplied"),
           ("entry.Area", "writeback4.Object"), ("getdests2.Dests", "writeback4.Value"),
           ("addexp.ReturnValue", "setexp4.AreasExpanded"),
           ("entry.Area", "writeback.Object"), ("getdests2.Dests", "writeback.Value"),
           ("entry.Area", "writeback2.Object"), ("getdests2.Dests", "writeback2.Value"),
           ("getexp.AreasExpanded", "addexp.A"), ("addexp.ReturnValue", "setexp.AreasExpanded"),
           ("addexp.ReturnValue", "setexp2.AreasExpanded"))
    return {"name": "ExpandArea", "inputs": [{"name": "Area", "type": f"object:{AREA}"}], "outputs": [],
            **g.spec()}


def group():
    """Group: Taken and Centroid from the current Dests."""
    g = Graph()
    g.node("gettaken", "get", var="Taken")
    g.node("clear", "array_call", function=f"{KAL}:Array_Clear")
    g.call("zero", f"{KML}:MakeVector", {"X": 0, "Y": 0, "Z": 0})
    g.node("setcentre0", "set", var="Centroid")
    g.node("getdests", "get", var="Dests")
    g.node("destloop", "macro", macro="ForEachLoop")
    g.call("loc", "/Script/Engine.Actor:K2_GetActorLocation")
    g.node("gettaken2", "get", var="Taken")
    g.node("take", "array_call", function=f"{KAL}:Array_Add")
    g.node("getcentre", "get", var="Centroid")
    g.call("sum", f"{KML}:Add_VectorVector")
    g.node("setcentre", "set", var="Centroid")
    g.node("getcentre2", "get", var="Centroid")
    g.node("len", "array_call", function=f"{KAL}:Array_Length")
    g.call("count", f"{KML}:Conv_IntToDouble")
    g.call("mean", f"{KML}:Divide_VectorFloat")
    g.node("setcentre2", "set", var="Centroid")
    g.chain("entry", "clear", "setcentre0", "destloop.Exec")
    g.chain("destloop.LoopBody", "take", "setcentre")
    g.chain("destloop.Completed", "setcentre2")
    g.wire(("gettaken.Taken", "clear.TargetArray"), ("zero.ReturnValue", "setcentre0.Centroid"),
           ("getdests.Dests", "destloop.Array"), ("destloop.Array Element", "loc.self"),
           ("gettaken2.Taken", "take.TargetArray"), ("loc.ReturnValue", "take.NewItem"),
           ("getcentre.Centroid", "sum.A"), ("loc.ReturnValue", "sum.B"), ("sum.ReturnValue", "setcentre.Centroid"),
           ("getcentre2.Centroid", "mean.A"), ("getdests.Dests", "len.TargetArray"), ("len.ReturnValue", "count.InInt"),
           ("count.ReturnValue", "mean.B"), ("mean.ReturnValue", "setcentre2.Centroid"))
    return {"name": "Group", "inputs": [], "outputs": [], **g.spec()}


def add_points():
    """AddPoints: one AddOnePoint per missing destination. The loop's end is read every pass and Dests grows inside it,
    so the count is fixed in Need first (the first build stopped after one point)."""
    g = Graph()
    g.node("getdests", "get", var="Dests")
    g.node("len", "array_call", function=f"{KAL}:Array_Length")
    g.call("need", f"{KML}:Subtract_IntInt", {"A": TARGET})
    g.node("setneed", "set", var="Need")
    g.node("getneed", "get", var="Need")
    g.node("addloop", "macro", macro="ForLoop", defaults={"FirstIndex": 1})
    g.call("addone", "self:AddOnePoint")
    g.chain("entry", "setneed", "addloop.execute")
    g.chain("addloop.LoopBody", "addone")
    g.wire(("getdests.Dests", "len.TargetArray"), ("len.ReturnValue", "need.B"), ("need.ReturnValue", "setneed.Need"),
           ("getneed.Need", "addloop.LastIndex"))
    return {"name": "AddPoints", "inputs": [], "outputs": [], **g.spec()}


def improve_points():
    """ImprovePoints: ImproveOne for every destination the game authored (all of Dests at this point)."""
    g = Graph()
    g.node("getdests", "get", var="Dests")
    g.node("loop", "macro", macro="ForEachLoop")
    g.call("one", "self:ImproveOne")
    g.chain("entry", "loop.Exec")
    g.chain("loop.LoopBody", "one")
    g.wire(("getdests.Dests", "loop.Array"), ("loop.Array Index", "one.Index"))
    return {"name": "ImprovePoints", "inputs": [], "outputs": [], **g.spec()}


def facing_nodes(g, prefix, normal_pin):
    """Nodes for 'facing = normal . Forward (+2 with no direction)'; returns the facing output pin."""
    g.node(f"{prefix}getforward", "get", var="Forward")
    g.call(f"{prefix}dot", f"{KML}:Dot_VectorVector")
    g.node(f"{prefix}getmissing", "get", var="Missing")
    g.call(f"{prefix}anyway", f"{KML}:Multiply_DoubleDouble", {"B": 2})
    g.call(f"{prefix}facing", f"{KML}:Add_DoubleDouble")
    g.wire((normal_pin, f"{prefix}dot.A"), (f"{prefix}getforward.Forward", f"{prefix}dot.B"),
           (f"{prefix}getmissing.Missing", f"{prefix}anyway.A"), (f"{prefix}dot.ReturnValue", f"{prefix}facing.A"),
           (f"{prefix}anyway.ReturnValue", f"{prefix}facing.B"))
    return f"{prefix}facing.ReturnValue"


def tier_nodes(g, prefix, type_pin):
    """Nodes for the cover tier from EBrunoCoverPointType's flags (2 high, 1 low, 0 none); returns the tier pin."""
    g.call(f"{prefix}typeint", f"{KML}:Conv_ByteToInt")
    g.call(f"{prefix}highbit", f"{KML}:And_IntInt", {"B": 2})
    g.call(f"{prefix}lowbit", f"{KML}:And_IntInt", {"B": 1})
    g.call(f"{prefix}ishigh", f"{KML}:Greater_IntInt", {"B": 0})
    g.call(f"{prefix}islow", f"{KML}:Greater_IntInt", {"B": 0})
    g.call(f"{prefix}highval", f"{KML}:Conv_BoolToDouble")
    g.call(f"{prefix}lowval", f"{KML}:Conv_BoolToDouble")
    g.call(f"{prefix}high2", f"{KML}:Multiply_DoubleDouble", {"B": 2})
    g.call(f"{prefix}tier", f"{KML}:Add_DoubleDouble")
    g.wire((type_pin, f"{prefix}typeint.InByte"), (f"{prefix}typeint.ReturnValue", f"{prefix}highbit.A"),
           (f"{prefix}typeint.ReturnValue", f"{prefix}lowbit.A"), (f"{prefix}highbit.ReturnValue", f"{prefix}ishigh.A"),
           (f"{prefix}lowbit.ReturnValue", f"{prefix}islow.A"), (f"{prefix}ishigh.ReturnValue", f"{prefix}highval.InBool"),
           (f"{prefix}islow.ReturnValue", f"{prefix}lowval.InBool"), (f"{prefix}highval.ReturnValue", f"{prefix}high2.A"),
           (f"{prefix}high2.ReturnValue", f"{prefix}tier.A"), (f"{prefix}lowval.ReturnValue", f"{prefix}tier.B"))
    return f"{prefix}tier.ReturnValue"


def improve_one():
    """ImproveOne(Index): Reforged's COVER.improve for one destination.

    In cover facing the encounter (a pocket within HERE_RANGE): kept, but moved onto that pocket's centre when further
    than COVER_SNAP off it, since between two tiles it crowds both. Otherwise moved to the best usable cover within
    IMPROVE_RANGE, searched at IMPROVE_RADII in eight directions: high before low, then facing, then nearer. A move
    spawns a new TacticalPoint at the pocket's floor plus the destination's own height above its floor and swaps it into
    Dests; the authored actor stays in the level, unlisted.
    """
    g = Graph()
    g.node("getdests", "get", var="Dests")
    g.node("dest", "array_call", function=f"{KAL}:Array_Get")
    g.call("origin", "/Script/Engine.Actor:K2_GetActorLocation")
    g.call("originfloor", f"{NAV}:K2_ProjectPointToNavigation", {"QueryExtent": f"{SNAP + 20},{SNAP + 20},250"})
    g.call("originbreak", f"{KML}:BreakVector")
    g.call("floorbreak", f"{KML}:BreakVector")
    g.call("lift", f"{KML}:Subtract_DoubleDouble")
    g.node("setlift", "set", var="Lift")
    g.node("setorigin", "set", var="Origin")
    g.node("gettemplate", "get", var="Template")
    g.call("here", f"{TARGETING}:GetNearestCoverForPoint", {"SearchRange": HERE_RANGE})
    g.node("herepocket", "break_struct", struct="/Script/BitReactorGame.CoverPocketResult")
    herefacing = facing_nodes(g, "h", "herepocket.CoverNormal")
    g.call("herefaces", f"{KML}:GreaterEqual_DoubleDouble", {"B": COVER_FACING})
    g.call("incover", f"{KML}:BooleanAND")
    g.node("isincover", "branch")
    # In cover: snap onto its centre if off it and the centre is usable.
    g.call("offcentre", f"{KML}:Vector_Distance2D")
    g.call("needsnap", f"{KML}:Greater_DoubleDouble", {"B": COVER_SNAP})
    g.call("snapok", "self:Usable")
    g.call("dosnap", f"{KML}:BooleanAND")
    g.node("snapit", "branch")
    g.call("snapmove", "self:MoveDestination")
    g.node("getsnapped", "get", var="SpotsSnapped")
    g.call("addsnapped", f"{KML}:Add_IntInt", {"B": 1})
    g.node("setsnapped", "set", var="SpotsSnapped")
    g.node("getkept", "get", var="SpotsKept")
    g.call("addkept", f"{KML}:Add_IntInt", {"B": 1})
    g.node("setkept", "set", var="SpotsKept")
    # Not in facing cover: search around it.
    g.node("setscore0", "set", var="BestScore", defaults={"BestScore": -NO_CANDIDATE})
    g.node("getoffsets", "get", var="ImproveOffsets")
    g.node("offloop", "macro", macro="ForEachLoop")
    g.call("trymove", "self:TryImprove")
    g.node("getscore", "get", var="BestScore")
    g.call("found", f"{KML}:Greater_DoubleDouble", {"B": -NO_CANDIDATE / 10})
    g.node("anyfound", "branch")
    g.node("getbest", "get", var="Best")
    g.call("bestmove", "self:MoveDestination")
    g.node("getmoved", "get", var="SpotsMoved")
    g.call("addmoved", f"{KML}:Add_IntInt", {"B": 1})
    g.node("setmoved", "set", var="SpotsMoved")
    g.chain("entry", "setlift", "setorigin", "here", "isincover")
    g.chain("isincover", "snapok", "snapit")
    g.chain("snapit", "snapmove", "setsnapped")
    g.chain("snapit.else", "setkept")
    g.chain("isincover.else", "setscore0", "offloop.Exec")
    g.chain("offloop.LoopBody", "trymove")
    g.chain("offloop.Completed", "anyfound")
    g.chain("anyfound", "bestmove", "setmoved")
    g.wire(("getdests.Dests", "dest.TargetArray"), ("entry.Index", "dest.Index"), ("dest.Item", "origin.self"),
           ("origin.ReturnValue", "originfloor.Point"), ("origin.ReturnValue", "originbreak.InVec"),
           ("originfloor.ProjectedLocation", "floorbreak.InVec"), ("originbreak.Z", "lift.A"), ("floorbreak.Z", "lift.B"),
           ("lift.ReturnValue", "setlift.Lift"), ("origin.ReturnValue", "setorigin.Origin"),
           ("gettemplate.Template", "here.MovingActor"), ("origin.ReturnValue", "here.MoveToLocation"),
           ("here.NearestCover", "herepocket.CoverPocketResult"), (herefacing, "herefaces.A"),
           ("here.ReturnValue", "incover.A"), ("herefaces.ReturnValue", "incover.B"),
           ("incover.ReturnValue", "isincover.Condition"),
           ("herepocket.FloorLocation", "offcentre.V1"), ("origin.ReturnValue", "offcentre.V2"),
           ("offcentre.ReturnValue", "needsnap.A"), ("herepocket.FloorLocation", "snapok.Point"),
           ("entry.Index", "snapok.Index"), ("needsnap.ReturnValue", "dosnap.A"), ("snapok.Ok", "dosnap.B"),
           ("dosnap.ReturnValue", "snapit.Condition"), ("entry.Index", "snapmove.Index"),
           ("herepocket.FloorLocation", "snapmove.Floor"),
           ("getsnapped.SpotsSnapped", "addsnapped.A"), ("addsnapped.ReturnValue", "setsnapped.SpotsSnapped"),
           ("getkept.SpotsKept", "addkept.A"), ("addkept.ReturnValue", "setkept.SpotsKept"),
           ("getoffsets.ImproveOffsets", "offloop.Array"), ("offloop.Array Element", "trymove.Offset"),
           ("entry.Index", "trymove.Index"),
           ("getscore.BestScore", "found.A"), ("found.ReturnValue", "anyfound.Condition"),
           ("entry.Index", "bestmove.Index"), ("getbest.Best", "bestmove.Floor"),
           ("getmoved.SpotsMoved", "addmoved.A"), ("addmoved.ReturnValue", "setmoved.SpotsMoved"))
    return {"name": "ImproveOne", "inputs": [{"name": "Index", "type": "int"}], "outputs": [], **g.spec()}


def try_improve():
    """TryImprove(Index, Offset): the cover pocket nearest Origin + Offset (range 2 x HERE_RANGE); kept in Best/BestScore
    when real cover, within IMPROVE_RANGE of Origin, facing the encounter, usable for destination Index and better."""
    g = Graph()
    g.node("getorigin", "get", var="Origin")
    g.call("probe", f"{KML}:Add_VectorVector")
    g.node("gettemplate", "get", var="Template")
    g.call("cover", f"{TARGETING}:GetNearestCoverForPoint", {"SearchRange": 2 * HERE_RANGE})
    g.node("pocket", "break_struct", struct="/Script/BitReactorGame.CoverPocketResult")
    g.call("usable", "self:Usable")
    tier = tier_nodes(g, "t", "pocket.PocketPointType")
    facing = facing_nodes(g, "f", "pocket.CoverNormal")
    g.call("hascover", f"{KML}:Greater_DoubleDouble", {"B": 0})
    g.call("faces", f"{KML}:GreaterEqual_DoubleDouble", {"B": COVER_FACING})
    g.call("away", f"{KML}:Vector_Distance2D")
    g.call("inrange", f"{KML}:LessEqual_DoubleDouble", {"B": IMPROVE_RANGE})
    g.call("tierscore", f"{KML}:Multiply_DoubleDouble", {"B": 1000})
    g.call("facescore", f"{KML}:Multiply_DoubleDouble", {"B": 100})
    g.call("distscore", f"{KML}:Multiply_DoubleDouble", {"B": -0.01})
    g.call("score1", f"{KML}:Add_DoubleDouble")
    g.call("score", f"{KML}:Add_DoubleDouble")
    g.node("getbestscore", "get", var="BestScore")
    g.call("better", f"{KML}:Greater_DoubleDouble")
    for i in range(1, 6):
        g.call(f"and{i}", f"{KML}:BooleanAND")
    g.node("accept", "branch")
    g.node("setbestscore", "set", var="BestScore")
    g.node("setbest", "set", var="Best")
    g.chain("entry", "cover", "usable", "accept")
    g.chain("accept", "setbestscore", "setbest")
    g.wire(("getorigin.Origin", "probe.A"), ("entry.Offset", "probe.B"),
           ("gettemplate.Template", "cover.MovingActor"), ("probe.ReturnValue", "cover.MoveToLocation"),
           ("cover.NearestCover", "pocket.CoverPocketResult"),
           ("pocket.FloorLocation", "usable.Point"), ("entry.Index", "usable.Index"),
           (tier, "hascover.A"), (facing, "faces.A"),
           ("pocket.FloorLocation", "away.V1"), ("getorigin.Origin", "away.V2"), ("away.ReturnValue", "inrange.A"),
           (tier, "tierscore.A"), (facing, "facescore.A"), ("away.ReturnValue", "distscore.A"),
           ("tierscore.ReturnValue", "score1.A"), ("facescore.ReturnValue", "score1.B"),
           ("score1.ReturnValue", "score.A"), ("distscore.ReturnValue", "score.B"),
           ("score.ReturnValue", "better.A"), ("getbestscore.BestScore", "better.B"),
           ("cover.ReturnValue", "and1.A"), ("hascover.ReturnValue", "and1.B"),
           ("and1.ReturnValue", "and2.A"), ("faces.ReturnValue", "and2.B"),
           ("and2.ReturnValue", "and3.A"), ("inrange.ReturnValue", "and3.B"),
           ("and3.ReturnValue", "and4.A"), ("usable.Ok", "and4.B"),
           ("and4.ReturnValue", "and5.A"), ("better.ReturnValue", "and5.B"), ("and5.ReturnValue", "accept.Condition"),
           ("score.ReturnValue", "setbestscore.BestScore"), ("pocket.FloorLocation", "setbest.Best"))
    return {"name": "TryImprove", "inputs": [{"name": "Index", "type": "int"}, {"name": "Offset", "type": "vector"}],
            "outputs": [], **g.spec()}


def usable():
    """Usable(Point, Index) -> Ok: Point is on the navmesh and SEPARATION from every destination but Index."""
    g = Graph()
    g.call("floor", f"{NAV}:K2_ProjectPointToNavigation", {"QueryExtent": f"{SNAP},{SNAP},{STEP + 50}"})
    g.node("setok", "set", var="UsableOk")
    g.node("getdests", "get", var="Dests")
    g.node("loop", "macro", macro="ForEachLoop")
    g.call("loc", "/Script/Engine.Actor:K2_GetActorLocation")
    g.call("dist", f"{KML}:Vector_Distance2D")
    g.call("close", f"{KML}:Less_DoubleDouble", {"B": SEPARATION})
    g.call("other", f"{KML}:NotEqual_IntInt")
    g.call("crowds", f"{KML}:BooleanAND")
    g.node("crowded", "branch")
    g.node("setno", "set", var="UsableOk", defaults={"UsableOk": "false"})
    g.node("getok", "get", var="UsableOk")
    g.chain("entry", "setok", "loop.Exec")
    g.chain("loop.LoopBody", "crowded")
    g.chain("crowded", "setno")
    g.chain("loop.Completed", "result")
    g.wire(("entry.Point", "floor.Point"), ("floor.ReturnValue", "setok.UsableOk"),
           ("getdests.Dests", "loop.Array"), ("loop.Array Element", "loc.self"),
           ("entry.Point", "dist.V1"), ("loc.ReturnValue", "dist.V2"), ("dist.ReturnValue", "close.A"),
           ("loop.Array Index", "other.A"), ("entry.Index", "other.B"),
           ("close.ReturnValue", "crowds.A"), ("other.ReturnValue", "crowds.B"), ("crowds.ReturnValue", "crowded.Condition"),
           ("getok.UsableOk", "result.Ok"))
    return {"name": "Usable", "inputs": [{"name": "Point", "type": "vector"}, {"name": "Index", "type": "int"}],
            "outputs": [{"name": "Ok", "type": "bool"}], **g.spec()}


def move_destination():
    """MoveDestination(Index, Floor): a new TacticalPoint at Floor + Lift, facing and team as destination Index's, swapped
    into Dests at Index."""
    g = Graph()
    g.node("getdests", "get", var="Dests")
    g.node("dest", "array_call", function=f"{KAL}:Array_Get")
    g.call("facing", "/Script/Engine.Actor:K2_GetActorRotation")
    g.call("floorbreak", f"{KML}:BreakVector")
    g.node("getlift", "get", var="Lift")
    g.call("standz", f"{KML}:Add_DoubleDouble")
    g.call("at", f"{KML}:MakeVector")
    g.call("one", f"{KML}:MakeVector", {"X": 1, "Y": 1, "Z": 1})
    g.call("where", f"{KML}:MakeTransform")
    g.call("spawn", f"{GS}:BeginDeferredActorSpawnFromClass",
           {"ActorClass": POINT, "CollisionHandlingOverride": "AlwaysSpawn"})
    g.node("getteam", "get", var=f"{POINT}:OwningTeam")
    g.call("team", f"{KSL}:SetClassPropertyByName", {"PropertyName": "OwningTeam"})
    g.call("finish", f"{GS}:FinishSpawningActor")
    g.node("point", "cast", **{"class": POINT})
    g.node("getdests2", "get", var="Dests")
    g.node("swap", "array_call", function=f"{KAL}:Array_Set")
    g.chain("entry", "spawn", "team", "finish", "point")
    g.chain("point", "swap")
    g.wire(("getdests.Dests", "dest.TargetArray"), ("entry.Index", "dest.Index"), ("dest.Item", "facing.self"),
           ("entry.Floor", "floorbreak.InVec"), ("floorbreak.Z", "standz.A"), ("getlift.Lift", "standz.B"),
           ("floorbreak.X", "at.X"), ("floorbreak.Y", "at.Y"), ("standz.ReturnValue", "at.Z"),
           ("at.ReturnValue", "where.Location"), ("facing.ReturnValue", "where.Rotation"),
           ("one.ReturnValue", "where.Scale"), ("where.ReturnValue", "spawn.SpawnTransform"),
           ("dest.Item", "getteam.self"), ("spawn.ReturnValue", "team.Object"), ("getteam.OwningTeam", "team.Value"),
           ("spawn.ReturnValue", "finish.Actor"), ("where.ReturnValue", "finish.SpawnTransform"),
           ("finish.ReturnValue", "point.Object"), ("getdests2.Dests", "swap.TargetArray"),
           ("entry.Index", "swap.Index"), ("point.AsTactical Point", "swap.Item"))
    return {"name": "MoveDestination", "inputs": [{"name": "Index", "type": "int"}, {"name": "Floor", "type": "vector"}],
            "outputs": [], **g.spec()}


def add_one_point():
    """AddOnePoint: the best candidate around every taken point, spawned as a TacticalPoint on the template's team."""
    g = Graph()
    g.node("setscore0", "set", var="BestScore", defaults={"BestScore": -NO_CANDIDATE})
    g.node("setbest0", "set", var="BestDist", defaults={"BestDist": NO_CANDIDATE})
    g.node("gettaken0", "get", var="Taken")
    g.node("coverloop", "macro", macro="ForEachLoop")
    g.call("trycover", "self:TryCover")
    g.node("getscore", "get", var="BestScore")
    g.call("covered", f"{KML}:Greater_DoubleDouble", {"B": -NO_CANDIDATE / 10})
    g.node("anycover", "branch")
    g.node("gettaken", "get", var="Taken")
    g.node("baseloop", "macro", macro="ForEachLoop")
    g.call("trybase", "self:TryBase")
    g.node("getbestdist", "get", var="BestDist")
    g.call("found", f"{KML}:Less_DoubleDouble", {"B": NO_CANDIDATE / 10})
    g.node("anyfound", "branch")
    g.node("getcovered", "get", var="CoveredPoints")
    g.call("addcovered", f"{KML}:Add_IntInt", {"B": 1})
    g.node("setcovered", "set", var="CoveredPoints")
    g.node("getbest", "get", var="Best")
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
    g.node("getdests", "get", var="Dests")
    g.node("adddest", "array_call", function=f"{KAL}:Array_Add")
    g.node("gettaken2", "get", var="Taken")
    g.node("addtaken", "array_call", function=f"{KAL}:Array_Add")
    g.node("getadded", "get", var="PointsAdded")
    g.call("addadded", f"{KML}:Add_IntInt", {"B": 1})
    g.node("setadded", "set", var="PointsAdded")
    g.chain("entry", "setscore0", "setbest0", "coverloop.Exec")
    g.chain("coverloop.LoopBody", "trycover")
    g.chain("coverloop.Completed", "anycover")
    g.chain("anycover", "setcovered", "spawn")
    g.chain("anycover.else", "baseloop.Exec")
    g.chain("baseloop.LoopBody", "trybase")
    g.chain("baseloop.Completed", "anyfound")
    g.chain("anyfound", "spawn", "team", "finish", "point")
    g.chain("point", "adddest", "addtaken", "setadded")
    g.wire(("gettaken0.Taken", "coverloop.Array"), ("coverloop.Array Element", "trycover.Base"),
           ("getscore.BestScore", "covered.A"), ("covered.ReturnValue", "anycover.Condition"),
           ("getcovered.CoveredPoints", "addcovered.A"), ("addcovered.ReturnValue", "setcovered.CoveredPoints"),
           ("gettaken.Taken", "baseloop.Array"), ("baseloop.Array Element", "trybase.Base"),
           ("getbestdist.BestDist", "found.A"), ("found.ReturnValue", "anyfound.Condition"),
           ("gettemplate.Template", "facing.self"), ("getbest.Best", "where.Location"),
           ("facing.ReturnValue", "where.Rotation"), ("one.ReturnValue", "where.Scale"),
           ("where.ReturnValue", "spawn.SpawnTransform"), ("spawn.ReturnValue", "team.Object"),
           ("getteam.Team", "team.Value"), ("spawn.ReturnValue", "finish.Actor"),
           ("where.ReturnValue", "finish.SpawnTransform"), ("finish.ReturnValue", "point.Object"),
           ("getdests.Dests", "adddest.TargetArray"), ("point.AsTactical Point", "adddest.NewItem"),
           ("gettaken2.Taken", "addtaken.TargetArray"), ("getbest.Best", "addtaken.NewItem"),
           ("getadded.PointsAdded", "addadded.A"), ("addadded.ReturnValue", "setadded.PointsAdded"))
    return {"name": "AddOnePoint", "inputs": [], "outputs": [], **g.spec()}


def try_base():
    """TryBase(Base): every offset around one taken point; keeps the best candidate in Best/BestDist."""
    g = Graph()
    # K2_ProjectPointToNavigation is pure in this build.
    g.call("basefloor", f"{NAV}:K2_ProjectPointToNavigation", {"QueryExtent": f"{SNAP + 20},{SNAP + 20},250"})
    g.node("onmesh", "branch")
    g.call("basebreak", f"{KML}:BreakVector")
    g.call("floorbreak", f"{KML}:BreakVector")
    g.call("lift", f"{KML}:Subtract_DoubleDouble")
    g.node("setlift", "set", var="Lift")
    g.node("getoffsets", "get", var="Offsets")
    g.node("offloop", "macro", macro="ForEachLoop")
    g.call("cand", f"{KML}:Add_VectorVector")
    g.call("candfloor", f"{NAV}:K2_ProjectPointToNavigation", {"QueryExtent": f"{SNAP},{SNAP},{STEP + 50}"})
    g.call("candxy", f"{KML}:BreakVector")
    g.call("mindist", "self:MinDistance2D")
    # Conditions: on the navmesh, barely moved sideways, a step from the base's floor, a tile from everyone,
    # and nearer the centroid than the best so far.
    g.call("drift", f"{KML}:Vector_Distance2D")
    g.call("steady", f"{KML}:LessEqual_DoubleDouble", {"B": SNAP})
    g.call("candbreak", f"{KML}:BreakVector")
    g.call("rise", f"{KML}:Subtract_DoubleDouble")
    g.call("riseabs", f"{KML}:Abs")
    g.call("level", f"{KML}:LessEqual_DoubleDouble", {"B": STEP})
    g.call("apart", f"{KML}:GreaterEqual_DoubleDouble", {"B": SAME_TILE})
    g.node("getcentre", "get", var="Centroid")
    g.call("tocentre", f"{KML}:Vector_Distance2D")
    g.node("getbestdist", "get", var="BestDist")
    g.call("better", f"{KML}:Less_DoubleDouble")
    g.call("and1", f"{KML}:BooleanAND")
    g.call("and2", f"{KML}:BooleanAND")
    g.call("and3", f"{KML}:BooleanAND")
    g.call("and4", f"{KML}:BooleanAND")
    g.node("accept", "branch")
    g.node("setbestdist", "set", var="BestDist")
    g.node("getlift", "get", var="Lift")
    g.call("standz", f"{KML}:Add_DoubleDouble")
    g.call("bestpoint", f"{KML}:MakeVector")
    g.node("setbest", "set", var="Best")
    g.chain("entry", "onmesh")
    g.chain("onmesh", "setlift", "offloop.Exec")
    g.chain("offloop.LoopBody", "mindist", "accept")
    g.chain("accept", "setbestdist", "setbest")
    g.wire(("entry.Base", "basefloor.Point"), ("basefloor.ReturnValue", "onmesh.Condition"),
           ("entry.Base", "basebreak.InVec"), ("basefloor.ProjectedLocation", "floorbreak.InVec"),
           ("basebreak.Z", "lift.A"), ("floorbreak.Z", "lift.B"), ("lift.ReturnValue", "setlift.Lift"),
           ("getoffsets.Offsets", "offloop.Array"), ("entry.Base", "cand.A"), ("offloop.Array Element", "cand.B"),
           ("cand.ReturnValue", "candfloor.Point"), ("cand.ReturnValue", "mindist.Point"),
           ("cand.ReturnValue", "drift.V1"), ("candfloor.ProjectedLocation", "drift.V2"),
           ("drift.ReturnValue", "steady.A"), ("candfloor.ProjectedLocation", "candbreak.InVec"),
           ("candbreak.Z", "rise.A"), ("floorbreak.Z", "rise.B"), ("rise.ReturnValue", "riseabs.A"),
           ("riseabs.ReturnValue", "level.A"), ("mindist.Result", "apart.A"),
           ("cand.ReturnValue", "tocentre.V1"), ("getcentre.Centroid", "tocentre.V2"),
           ("tocentre.ReturnValue", "better.A"), ("getbestdist.BestDist", "better.B"),
           ("candfloor.ReturnValue", "and1.A"), ("steady.ReturnValue", "and1.B"),
           ("and1.ReturnValue", "and2.A"), ("level.ReturnValue", "and2.B"),
           ("and2.ReturnValue", "and3.A"), ("apart.ReturnValue", "and3.B"),
           ("and3.ReturnValue", "and4.A"), ("better.ReturnValue", "and4.B"), ("and4.ReturnValue", "accept.Condition"),
           ("tocentre.ReturnValue", "setbestdist.BestDist"),
           ("candbreak.Z", "standz.A"), ("getlift.Lift", "standz.B"),
           ("cand.ReturnValue", "candxy.InVec"),
           ("candxy.X", "bestpoint.X"), ("candxy.Y", "bestpoint.Y"), ("standz.ReturnValue", "bestpoint.Z"),
           ("bestpoint.ReturnValue", "setbest.Best"))
    return {"name": "TryBase", "inputs": [{"name": "Base", "type": "vector"}], "outputs": [], **g.spec()}


def consider_pocket():
    """ConsiderPocket(Found, Pocket): a cover pocket kept in Best/BestScore when it is low or high cover facing the
    encounter, a tile from every point, with the group, on the navmesh and better than the best so far. Score: high
    cover 2000, low 1000, plus 100 x facing, minus a hundredth of its distance to the centroid (Reforged's COVER.choose
    order: full before half, then facing, then nearer)."""
    g = Graph()
    g.node("pocket", "break_struct", struct="/Script/BitReactorGame.CoverPocketResult")
    g.call("mindist", "self:MinDistance2D")
    # Tier from EBrunoCoverPointType's flags: 1 LowCover, 2 HighCover.
    g.call("typeint", f"{KML}:Conv_ByteToInt")
    g.call("highbit", f"{KML}:And_IntInt", {"B": 2})
    g.call("lowbit", f"{KML}:And_IntInt", {"B": 1})
    g.call("ishigh", f"{KML}:Greater_IntInt", {"B": 0})
    g.call("islow", f"{KML}:Greater_IntInt", {"B": 0})
    g.call("highval", f"{KML}:Conv_BoolToDouble")
    g.call("lowval", f"{KML}:Conv_BoolToDouble")
    g.call("high2", f"{KML}:Multiply_DoubleDouble", {"B": 2})
    g.call("tier", f"{KML}:Add_DoubleDouble")
    g.call("hascover", f"{KML}:Greater_DoubleDouble", {"B": 0})
    # Facing: the pocket's normal against the encounter's direction (always passes when the area has no direction).
    g.node("getforward", "get", var="Forward")
    g.call("dot", f"{KML}:Dot_VectorVector")
    g.node("getmissing", "get", var="Missing")
    g.call("anyway", f"{KML}:Multiply_DoubleDouble", {"B": 2})
    g.call("facing", f"{KML}:Add_DoubleDouble")
    g.call("faces", f"{KML}:GreaterEqual_DoubleDouble", {"B": COVER_FACING})
    g.call("apart", f"{KML}:GreaterEqual_DoubleDouble", {"B": SAME_TILE})
    g.call("withgroup", f"{KML}:LessEqual_DoubleDouble", {"B": NEAR_GROUP})
    g.call("pocketfloor", f"{NAV}:K2_ProjectPointToNavigation", {"QueryExtent": f"{SNAP},{SNAP},{STEP + 50}"})
    g.node("getcentre", "get", var="Centroid")
    g.call("tocentre", f"{KML}:Vector_Distance2D")
    g.call("tierscore", f"{KML}:Multiply_DoubleDouble", {"B": 1000})
    g.call("facescore", f"{KML}:Multiply_DoubleDouble", {"B": 100})
    g.call("distscore", f"{KML}:Multiply_DoubleDouble", {"B": -0.01})
    g.call("score1", f"{KML}:Add_DoubleDouble")
    g.call("score", f"{KML}:Add_DoubleDouble")
    g.node("getbestscore", "get", var="BestScore")
    g.call("better", f"{KML}:Greater_DoubleDouble")
    for i in range(1, 7):
        g.call(f"and{i}", f"{KML}:BooleanAND")
    g.node("accept", "branch")
    g.node("setbestscore", "set", var="BestScore")
    g.call("floorxyz", f"{KML}:BreakVector")
    g.node("getlift", "get", var="Lift")
    g.call("standz", f"{KML}:Add_DoubleDouble")
    g.call("bestpoint", f"{KML}:MakeVector")
    g.node("setbest", "set", var="Best")
    g.chain("entry", "mindist", "accept")
    g.chain("accept", "setbestscore", "setbest")
    p = "pocket"
    g.wire(("entry.Pocket", f"{p}.CoverPocketResult"), (f"{p}.FloorLocation", "mindist.Point"),
           (f"{p}.PocketPointType", "typeint.InByte"), ("typeint.ReturnValue", "highbit.A"),
           ("typeint.ReturnValue", "lowbit.A"), ("highbit.ReturnValue", "ishigh.A"), ("lowbit.ReturnValue", "islow.A"),
           ("ishigh.ReturnValue", "highval.InBool"), ("islow.ReturnValue", "lowval.InBool"),
           ("highval.ReturnValue", "high2.A"), ("high2.ReturnValue", "tier.A"), ("lowval.ReturnValue", "tier.B"),
           ("tier.ReturnValue", "hascover.A"),
           (f"{p}.CoverNormal", "dot.A"), ("getforward.Forward", "dot.B"), ("getmissing.Missing", "anyway.A"),
           ("dot.ReturnValue", "facing.A"), ("anyway.ReturnValue", "facing.B"), ("facing.ReturnValue", "faces.A"),
           ("mindist.Result", "apart.A"), ("mindist.Result", "withgroup.A"),
           (f"{p}.FloorLocation", "pocketfloor.Point"),
           (f"{p}.FloorLocation", "tocentre.V1"), ("getcentre.Centroid", "tocentre.V2"),
           ("tier.ReturnValue", "tierscore.A"), ("facing.ReturnValue", "facescore.A"),
           ("tocentre.ReturnValue", "distscore.A"), ("tierscore.ReturnValue", "score1.A"),
           ("facescore.ReturnValue", "score1.B"), ("score1.ReturnValue", "score.A"), ("distscore.ReturnValue", "score.B"),
           ("score.ReturnValue", "better.A"), ("getbestscore.BestScore", "better.B"),
           ("entry.Found", "and1.A"), ("hascover.ReturnValue", "and1.B"),
           ("and1.ReturnValue", "and2.A"), ("faces.ReturnValue", "and2.B"),
           ("and2.ReturnValue", "and3.A"), ("apart.ReturnValue", "and3.B"),
           ("and3.ReturnValue", "and4.A"), ("withgroup.ReturnValue", "and4.B"),
           ("and4.ReturnValue", "and5.A"), ("pocketfloor.ReturnValue", "and5.B"),
           ("and5.ReturnValue", "and6.A"), ("better.ReturnValue", "and6.B"), ("and6.ReturnValue", "accept.Condition"),
           ("score.ReturnValue", "setbestscore.BestScore"),
           (f"{p}.FloorLocation", "floorxyz.InVec"), ("floorxyz.Z", "standz.A"), ("getlift.Lift", "standz.B"),
           ("floorxyz.X", "bestpoint.X"), ("floorxyz.Y", "bestpoint.Y"), ("standz.ReturnValue", "bestpoint.Z"),
           ("bestpoint.ReturnValue", "setbest.Best"))
    return {"name": "ConsiderPocket", "inputs": [{"name": "Found", "type": "bool"},
                                                 {"name": "Pocket", "type": "struct:/Script/BitReactorGame.CoverPocketResult"}],
            "outputs": [], **g.spec()}


def query_and_consider():
    """QueryAndConsider(Point, Range): the cover pocket nearest Point within Range, through ConsiderPocket."""
    g = Graph()
    g.node("gettemplate", "get", var="Template")
    g.call("cover", f"{TARGETING}:GetNearestCoverForPoint")
    g.call("consider", "self:ConsiderPocket")
    g.chain("entry", "cover", "consider")
    g.wire(("gettemplate.Template", "cover.MovingActor"), ("entry.Point", "cover.MoveToLocation"),
           ("entry.Range", "cover.SearchRange"), ("cover.ReturnValue", "consider.Found"),
           ("cover.NearestCover", "consider.Pocket"))
    return {"name": "QueryAndConsider", "inputs": [{"name": "Point", "type": "vector"}, {"name": "Range", "type": "float"}],
            "outputs": [], **g.spec()}


def line_search():
    """LineSearch(Base): the tiles beside the cover Base stands in, along that cover (Reforged's cover-line search). The
    game returns only the nearest pocket to a point, so beside an authored spot it returns that spot's own cover, and the
    free tile next to it along the same crate never came up: an added operator stood in the open (2026-10-18, as Best
    Served Cold did for Reforged on 2026-10-13)."""
    g = Graph()
    g.node("gettemplate", "get", var="Template")
    g.call("here", f"{TARGETING}:GetNearestCoverForPoint", {"SearchRange": HERE_RANGE})
    g.node("incover", "branch")
    g.node("pocket", "break_struct", struct="/Script/BitReactorGame.CoverPocketResult")
    g.call("normal", f"{KML}:BreakVector")
    g.call("negy", f"{KML}:Multiply_DoubleDouble", {"B": -1})
    g.call("along", f"{KML}:MakeVector", {"Z": 0})
    steps = []
    for i, t in enumerate((TILE, -TILE, 2 * TILE, -2 * TILE)):
        g.call(f"shift{i}", f"{KML}:Multiply_VectorFloat", {"B": t})
        g.call(f"point{i}", f"{KML}:Add_VectorVector")
        g.call(f"try{i}", "self:QueryAndConsider", {"Range": HERE_RANGE})
        g.wire(("along.ReturnValue", f"shift{i}.A"), ("pocket.FloorLocation", f"point{i}.A"),
               (f"shift{i}.ReturnValue", f"point{i}.B"), (f"point{i}.ReturnValue", f"try{i}.Point"))
        steps.append(f"try{i}")
    g.chain("entry", "here", "incover")
    g.chain("incover", *steps)
    g.wire(("gettemplate.Template", "here.MovingActor"), ("entry.Base", "here.MoveToLocation"),
           ("here.ReturnValue", "incover.Condition"), ("here.NearestCover", "pocket.CoverPocketResult"),
           ("pocket.CoverNormal", "normal.InVec"), ("normal.Y", "negy.A"),
           ("negy.ReturnValue", "along.X"), ("normal.X", "along.Y"))
    return {"name": "LineSearch", "inputs": [{"name": "Base", "type": "vector"}], "outputs": [], **g.spec()}


def try_cover():
    """TryCover(Base): cover pockets around one taken point into Best/BestScore (ConsiderPocket): the nearest pocket
    around every offset a tile or two off it, a 7-by-7 tile grid with shorter queries, then the cover line (LineSearch). Lift
    (the point's height above its floor) is kept for the chosen pocket's height. The query's moving actor is the area's
    first destination (same pockets as an operator, tested in SK_Brentaal_030)."""
    g = Graph()
    g.call("basefloor", f"{NAV}:K2_ProjectPointToNavigation", {"QueryExtent": f"{SNAP + 20},{SNAP + 20},250"})
    g.node("onmesh", "branch")
    g.call("basebreak", f"{KML}:BreakVector")
    g.call("floorbreak", f"{KML}:BreakVector")
    g.call("lift", f"{KML}:Subtract_DoubleDouble")
    g.node("setlift", "set", var="Lift")
    g.node("getoffsets", "get", var="Offsets")
    g.node("offloop", "macro", macro="ForEachLoop")
    g.call("cand", f"{KML}:Add_VectorVector")
    g.call("query", "self:QueryAndConsider", {"Range": COVER_RANGE})
    g.node("getgrid", "get", var="CoverGrid")
    g.node("gridloop", "macro", macro="ForEachLoop")
    g.call("gridpoint", f"{KML}:Add_VectorVector")
    g.call("gridquery", "self:QueryAndConsider", {"Range": COVER_GRID_RANGE})
    g.call("line", "self:LineSearch")
    g.chain("entry", "onmesh")
    g.chain("onmesh", "setlift", "offloop.Exec")
    g.chain("offloop.LoopBody", "query")
    g.chain("offloop.Completed", "gridloop.Exec")
    g.chain("gridloop.LoopBody", "gridquery")
    g.chain("gridloop.Completed", "line")
    g.wire(("entry.Base", "basefloor.Point"), ("basefloor.ReturnValue", "onmesh.Condition"),
           ("entry.Base", "basebreak.InVec"), ("basefloor.ProjectedLocation", "floorbreak.InVec"),
           ("basebreak.Z", "lift.A"), ("floorbreak.Z", "lift.B"), ("lift.ReturnValue", "setlift.Lift"),
           ("getoffsets.Offsets", "offloop.Array"), ("entry.Base", "cand.A"), ("offloop.Array Element", "cand.B"),
           ("cand.ReturnValue", "query.Point"), ("entry.Base", "line.Base"),
           ("getgrid.CoverGrid", "gridloop.Array"), ("entry.Base", "gridpoint.A"),
           ("gridloop.Array Element", "gridpoint.B"), ("gridpoint.ReturnValue", "gridquery.Point"))
    return {"name": "TryCover", "inputs": [{"name": "Base", "type": "vector"}], "outputs": [], **g.spec()}


def min_distance():
    """MinDistance2D(Point) -> Result: the smallest sideways distance from Point to a taken point."""
    g = Graph()
    g.node("setmin0", "set", var="MinD", defaults={"MinD": NO_CANDIDATE})
    g.node("gettaken", "get", var="Taken")
    g.node("loop", "macro", macro="ForEachLoop")
    g.call("dist", f"{KML}:Vector_Distance2D")
    g.node("getmin", "get", var="MinD")
    g.call("closer", f"{KML}:Less_DoubleDouble")
    g.node("isclose", "branch")
    g.node("setmin", "set", var="MinD")
    g.node("getmin2", "get", var="MinD")
    g.chain("entry", "setmin0", "loop.Exec")
    g.chain("loop.LoopBody", "isclose")
    g.chain("isclose", "setmin")
    g.chain("loop.Completed", "result")
    g.wire(("gettaken.Taken", "loop.Array"), ("entry.Point", "dist.V1"), ("loop.Array Element", "dist.V2"),
           ("dist.ReturnValue", "closer.A"), ("getmin.MinD", "closer.B"), ("closer.ReturnValue", "isclose.Condition"),
           ("dist.ReturnValue", "setmin.MinD"), ("getmin2.MinD", "result.Result"))
    return {"name": "MinDistance2D", "inputs": [{"name": "Point", "type": "vector"}],
            "outputs": [{"name": "Result", "type": "float"}], **g.spec()}


def nav_ready():
    """NavReady(Area) -> Ready: the area has a destination, the first one projects onto the navmesh, and the game's
    cover data is in (a cover query beside that destination succeeded, here or for an earlier area). Cover arrives after
    the navmesh: SK_Brentaal_030's first pass found the mesh but no pockets, and both added points went to open ground
    (2026-10-18). Any of the area's own destinations will do: in HM_Cly_010 cover arrives 4 s after the mission loads.
    COVER_WAIT_PASSES Deploy passes after the area was first seen the cover condition is dropped, so an area with no
    cover nearby still gets its open-ground points.
    """
    g = Graph()
    g.node("getpd", "get", var=f"{AREA}:PlayerDestinations")
    g.node("len", "array_call", function=f"{KAL}:Array_Length")
    g.call("hasany", f"{KML}:Greater_IntInt", {"B": 0})
    g.node("first", "array_call", function=f"{KAL}:Array_Get", defaults={"Index": 0})
    g.call("loc", "/Script/Engine.Actor:K2_GetActorLocation")
    g.call("floor", f"{NAV}:K2_ProjectPointToNavigation", {"QueryExtent": f"{SNAP + 20},{SNAP + 20},250"})
    g.node("anydest", "branch")
    g.call("probe", "self:ProbeCover")
    g.call("wait", "self:AreaWait")
    g.node("getcoverup", "get", var="AreaCoverOk")
    g.node("getpasses", "get", var="AreaWaited")
    g.call("waited", f"{KML}:GreaterEqual_IntInt", {"B": COVER_WAIT_PASSES})
    g.call("coverok", f"{KML}:BooleanOR")
    g.call("both", f"{KML}:BooleanAND")
    g.call("all", f"{KML}:BooleanAND")
    g.chain("entry", "anydest")
    g.chain("anydest", "wait", "probe", "result")
    g.chain("anydest.else", "result")
    g.wire(("entry.Area", "getpd.self"), ("getpd.PlayerDestinations", "len.TargetArray"),
           ("len.ReturnValue", "hasany.A"), ("hasany.ReturnValue", "anydest.Condition"),
           ("getpd.PlayerDestinations", "first.TargetArray"), ("first.Item", "loc.self"),
           ("loc.ReturnValue", "floor.Point"), ("entry.Area", "probe.Area"), ("entry.Area", "wait.Area"),
           ("getcoverup.AreaCoverOk", "coverok.A"), ("getpasses.AreaWaited", "waited.A"), ("waited.ReturnValue", "coverok.B"),
           ("hasany.ReturnValue", "both.A"), ("floor.ReturnValue", "both.B"),
           ("both.ReturnValue", "all.A"), ("coverok.ReturnValue", "all.B"), ("all.ReturnValue", "result.Ready"))
    return {"name": "NavReady", "inputs": [{"name": "Area", "type": f"object:{AREA}"}],
            "outputs": [{"name": "Ready", "type": "bool"}], **g.spec()}


def area_nearby():
    """AreaNearby: defer distant encounters until a squad member is within 10000 uu of a destination.

    A late encounter can have navmesh and some cover at mission start while other cover pockets
    remain streamed out (Belly of the Beast area 2). Starting its cover wait only on approach
    prevents freezing an open-ground fallback a whole encounter before that cover loads.
    """
    g = Graph()
    g.node("reset", "set", var="NearbyArea", defaults={"NearbyArea": "false"})
    g.call("states", f"{GS}:GetAllActorsOfClass", {"ActorClass": gf_unstack.TACTICAL_STATE})
    g.node("statesloop", "macro", macro="ForEachLoop")
    g.node("state", "cast", **{"class": gf_unstack.TACTICAL_STATE})
    g.node("squad", "get", var=f"{gf_unstack.TACTICAL_STATE}:PlayerSquad")
    g.call("valid", f"{KSL}:IsValid")
    g.node("hassquad", "branch")
    g.call("members", f"{gf_unstack.SQUAD}:GetSquadMembers")
    g.node("units", "macro", macro="ForEachLoop")
    g.call("unitloc", "/Script/Engine.Actor:K2_GetActorLocation")
    g.node("dests", "get", var=f"{AREA}:PlayerDestinations")
    g.node("points", "macro", macro="ForEachLoop")
    g.call("pointloc", "/Script/Engine.Actor:K2_GetActorLocation")
    g.call("dist", f"{KML}:Vector_Distance")
    g.call("close", f"{KML}:Less_DoubleDouble", {"B": 10000})
    g.node("isclose", "branch")
    g.node("yes", "set", var="NearbyArea", defaults={"NearbyArea": "true"})
    g.node("getnear", "get", var="NearbyArea")
    g.chain("entry", "reset", "states", "statesloop.Exec")
    g.chain("statesloop.LoopBody", "state")
    g.chain("state", "hassquad")
    g.chain("hassquad", "units.Exec")
    g.chain("units.LoopBody", "points.Exec")
    g.chain("points.LoopBody", "isclose")
    g.chain("isclose", "yes")
    g.chain("statesloop.Completed", "result")
    g.wire(("states.OutActors", "statesloop.Array"), ("statesloop.Array Element", "state.Object"),
           ("state.AsTactical Game State", "squad.self"), ("squad.PlayerSquad", "valid.Object"),
           ("valid.ReturnValue", "hassquad.Condition"), ("squad.PlayerSquad", "members.self"),
           ("members.ReturnValue", "units.Array"), ("units.Array Element", "unitloc.self"),
           ("entry.Area", "dests.self"), ("dests.PlayerDestinations", "points.Array"),
           ("points.Array Element", "pointloc.self"), ("pointloc.ReturnValue", "dist.V1"),
           ("unitloc.ReturnValue", "dist.V2"), ("dist.ReturnValue", "close.A"),
           ("close.ReturnValue", "isclose.Condition"), ("getnear.NearbyArea", "result.Nearby"))
    return {"name": "AreaNearby", "inputs": [{"name": "Area", "type": f"object:{AREA}"}],
            "outputs": [{"name": "Nearby", "type": "bool"}], **g.spec()}


def area_wait():
    """AreaWait(Area): AreaWaited = Deploy passes since the area was first seen (SeenAreas/SeenAt), so an area that
    loads late still gets its own wait for cover."""
    g = Graph()
    g.node("getseen", "get", var="SeenAreas")
    g.node("find", "array_call", function=f"{KAL}:Array_Find")
    g.call("isnew", f"{KML}:Less_IntInt", {"B": 0})
    g.node("new", "branch")
    g.node("getseen2", "get", var="SeenAreas")
    g.node("addarea", "array_call", function=f"{KAL}:Array_Add")
    g.node("getat", "get", var="SeenAt")
    g.node("getpasses", "get", var="DeployPasses")
    g.node("addat", "array_call", function=f"{KAL}:Array_Add")
    g.node("getseen3", "get", var="SeenAreas")
    g.node("find2", "array_call", function=f"{KAL}:Array_Find")
    g.node("getat2", "get", var="SeenAt")
    g.node("since", "array_call", function=f"{KAL}:Array_Get")
    g.call("waited", f"{KML}:Subtract_IntInt")
    g.node("setwaited", "set", var="AreaWaited")
    g.chain("entry", "new")
    g.chain("new", "addarea", "addat", "setwaited")
    g.chain("new.else", "setwaited")
    g.wire(("getseen.SeenAreas", "find.TargetArray"), ("entry.Area", "find.ItemToFind"), ("find.ReturnValue", "isnew.A"),
           ("isnew.ReturnValue", "new.Condition"), ("getseen2.SeenAreas", "addarea.TargetArray"),
           ("entry.Area", "addarea.NewItem"), ("getat.SeenAt", "addat.TargetArray"), ("getpasses.DeployPasses", "addat.NewItem"),
           ("getseen3.SeenAreas", "find2.TargetArray"), ("entry.Area", "find2.ItemToFind"),
           ("getat2.SeenAt", "since.TargetArray"), ("find2.ReturnValue", "since.Index"),
           ("getpasses.DeployPasses", "waited.A"), ("since.Item", "waited.B"), ("waited.ReturnValue", "setwaited.AreaWaited"))
    return {"name": "AreaWait", "inputs": [{"name": "Area", "type": f"object:{AREA}"}], "outputs": [], **g.spec()}


def probe_cover():
    """ProbeCover(Area): AreaCoverOk when a cover query beside any of the area's own destinations succeeds. Per area:
    a second area's cover streams in with its part of the map, and a mission-wide flag set by the first area let
    MM_05_030_BellyBeast's second area expand with no cover data (0 of 4 points in cover one run, 3 of 4 the next).
    The first destination (the first may have
    none nearby; in HM_Cly_010 cover arrives 4 s after the mission loads). Its own function: the same loop inline in
    NavReady cooked into a brain the game couldn't load ("Bad name index" in CaptureLayout, 2026-10-18)."""
    g = Graph()
    g.node("getpd", "get", var=f"{AREA}:PlayerDestinations")
    g.node("first", "array_call", function=f"{KAL}:Array_Get", defaults={"Index": 0})
    g.node("loop", "macro", macro="ForEachLoop")
    g.call("loc", "/Script/Engine.Actor:K2_GetActorLocation")
    g.call("cover", f"{TARGETING}:GetNearestCoverForPoint", {"SearchRange": COVER_RANGE})
    g.node("hascover", "branch")
    g.node("setcoverup", "set", var="AreaCoverOk", defaults={"AreaCoverOk": "true"})
    g.node("clearcover", "set", var="AreaCoverOk", defaults={"AreaCoverOk": "false"})
    g.chain("entry", "clearcover", "loop.Exec")
    g.chain("loop.LoopBody", "cover", "hascover")
    g.chain("hascover", "setcoverup")
    g.wire(("entry.Area", "getpd.self"), ("getpd.PlayerDestinations", "first.TargetArray"),
           ("getpd.PlayerDestinations", "loop.Array"), ("loop.Array Element", "loc.self"),
           ("first.Item", "cover.MovingActor"), ("loc.ReturnValue", "cover.MoveToLocation"),
           ("cover.ReturnValue", "hascover.Condition"))
    return {"name": "ProbeCover", "inputs": [{"name": "Area", "type": f"object:{AREA}"}], "outputs": [], **g.spec()}


def brain():
    offsets = ",".join(f"(X={x}.0,Y={y}.0,Z=0.0)" for x, y in OFFSETS)
    improve = ",".join(f"(X={r * math.cos(k * math.pi / 4):.3f},Y={r * math.sin(k * math.pi / 4):.3f},Z=0.0)"
                       for r in IMPROVE_RADII for k in range(8))
    return {
        "kind": "blueprint",
        "path": "/SquadSixGF/BP_SquadSixBrain",
        "parent": "/Script/Engine.ActorComponent",
        "variables": [
            {"name": "Sweeps", "type": "int", "default": "0"},
            {"name": "Seen", "type": "int", "default": "0"},
            {"name": "Raised", "type": "int", "default": "0"},
            {"name": "Found", "type": "struct:/Script/CoreUObject.AssetData[]"},
            {"name": "Kept", "type": f"object:{MISSION}[]"},
            {"name": "RaiseNames", "type": "string[]"},
            {"name": "AreasSeen", "type": "int", "default": "0"},
            {"name": "AreasExpanded", "type": "int", "default": "0"},
            {"name": "PointsAdded", "type": "int", "default": "0"},
            {"name": "Done", "type": f"object:{AREA}[]"},
            {"name": "Dests", "type": f"object:{POINT}[]"},
            {"name": "Template", "type": f"object:{POINT}"},
            {"name": "Team", "type": "class:/Script/BitReactorGame.TeamGameFlag"},
            {"name": "Taken", "type": "vector[]"},
            {"name": "Offsets", "type": "vector[]"},
            {"name": "CoverGrid", "type": "vector[]"},
            {"name": "Centroid", "type": "vector"},
            {"name": "Best", "type": "vector"},
            {"name": "BestDist", "type": "float"},
            {"name": "Lift", "type": "float"},
            {"name": "MinD", "type": "float"},
            {"name": "BestScore", "type": "float"},
            {"name": "Forward", "type": "vector"},
            {"name": "Missing", "type": "float"},
            {"name": "Need", "type": "int"},
            {"name": "CoveredPoints", "type": "int", "default": "0"},
            {"name": "CoverUp", "type": "bool", "default": "false"},
            {"name": "AreaCoverOk", "type": "bool", "default": "false"},
            {"name": "NearbyArea", "type": "bool", "default": "false"},
            {"name": "AreaWaited", "type": "int", "default": "0"},
            {"name": "SeenAreas", "type": f"object:{AREA}[]"},
            {"name": "SeenAt", "type": "int[]"},
            {"name": "DeployPasses", "type": "int", "default": "0"},
            {"name": "Origin", "type": "vector"},
            {"name": "ImproveOffsets", "type": "vector[]"},
            {"name": "UsableOk", "type": "bool"},
            {"name": "SpotsKept", "type": "int", "default": "0"},
            {"name": "SpotsSnapped", "type": "int", "default": "0"},
            {"name": "SpotsMoved", "type": "int", "default": "0"},
            *gf_lineup.variables(),
            *gf_holotable.variables(),
            *gf_maps.variables(),
            *gf_unstack.variables(),
            *gf_spawn.variables(),
        ],
        # Functions first: the event graph calls ExpandArea, which calls the others.
        "functions": [area_nearby(), area_wait(), probe_cover(), nav_ready(), min_distance(), usable(), move_destination(), try_base(), consider_pocket(), query_and_consider(), line_search(),
                      try_cover(), try_improve(), improve_one(), improve_points(), add_one_point(), add_points(), group(), expand_area(),
                      *gf_lineup.functions(), *gf_holotable.functions(),
                      *gf_maps.functions(), *gf_unstack.functions(), *gf_spawn.functions()],
        "graph": event_graph(),
        "defaults": {"CoverGrid": "(" + ",".join(f"(X={x},Y={y},Z=0)" for x,y in COVER_GRID) + ")", "Offsets": f"({offsets})", "ImproveOffsets": f"({improve})", **gf_maps.defaults(), **gf_spawn.defaults(),
                     "RaiseNames": "(" + ",".join(f'"{n}"' for n in raised_missions()) + ")"},
    }


def main():
    OUT.mkdir(exist_ok=True)
    for old in OUT.glob("*.json"):
        old.unlink()
    (OUT / "01_BP_SquadSixBrain.json").write_text(json.dumps(brain(), indent=2) + "\n")
    print(f"wrote {OUT / '01_BP_SquadSixBrain.json'}")


if __name__ == "__main__":
    main()
