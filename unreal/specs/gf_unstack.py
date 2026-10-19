"""Operators the game spawns on top of each other at a mission's start, for BP_SquadSixBrain (a small version of
Reforged's spawn watch, on its own 0.5 s timer).

The full sweep (tools/gf_sweep.py, 2026-10-18) found five missions that spawn two or three of the six on one spot before
any deployment (HM_Cly_020, HM_TrickLuco_020, MM_05_010_UmbaraRescue, MM_04_050_ANewOrder, SK_Sullust_015); the
destinations can't help there. For the first UNSTACK_PASSES passes of a mission, an operator within STACKED of an
earlier one in the squad, and standing where it stood on the previous pass (so nobody is moved mid-walk or mid-scene),
is teleported, once, to the first free tile a tile or two away: on the navmesh, within a step of its own floor, a tile
from every operator. Once only: HM_Cly_020, HM_TrickLuco_020 and MM_04_050_ANewOrder hold three of their staged squad on
one spot (collision off) and put a moved operator back every frame; their deployment separates them.
"""
from gf_graph import Graph, KSL, KML, KAL, GS

NAV = "/Script/NavigationSystem.NavigationSystemV1"
TACTICAL_STATE = "/Script/BitReactorGame.TacticalGameState"
SQUAD = "/Script/BitReactorGame.BitReactorGameSquad"
ACTOR = "/Script/Engine.Actor"
STACKED = 50.0
STILL = 5.0
SEPARATION = 75.0
STEP = 100.0
SNAP = 30.0
UNSTACK_PASSES = 60  # 0.5 s each: the first 30 s of a mission


def variables():
    return [
        {"name": "SquadUnits", "type": f"object:{ACTOR}[]"},
        {"name": "LastPositions", "type": "vector[]"},
        {"name": "NewPositions", "type": "vector[]"},
        {"name": "UnstackPasses", "type": "int", "default": "0"},
        {"name": "UnstackMoves", "type": "int", "default": "0"},
        {"name": "Nearest", "type": "float"},
        {"name": "MovedAside", "type": "bool"},
        {"name": "FreeOk", "type": "bool"},
        {"name": "TriedUnits", "type": f"object:{ACTOR}[]"},
    ]


def event(g):
    """Adds the Unstack timer (to BeginPlay's chain end) and its custom event to the event graph `g`."""
    g.node("unstack", "custom_event", name="Unstack")
    g.node("ugetpasses", "get", var="UnstackPasses")
    g.call("uearly", f"{KML}:Less_IntInt", {"B": UNSTACK_PASSES})
    g.node("uisearly", "branch")
    g.call("uaddpasses", f"{KML}:Add_IntInt", {"B": 1})
    g.node("usetpasses", "set", var="UnstackPasses")
    g.call("upass", "self:UnstackPass")
    g.chain("unstack", "uisearly")
    g.chain("uisearly", "usetpasses", "upass")
    g.wire(("ugetpasses.UnstackPasses", "uearly.A"), ("uearly.ReturnValue", "uisearly.Condition"),
           ("ugetpasses.UnstackPasses", "uaddpasses.A"), ("uaddpasses.ReturnValue", "usetpasses.UnstackPasses"))


def unstack_pass():
    """UnstackPass: the squad, each stacked and still operator moved aside, then everyone's position kept."""
    g = Graph()
    g.call("states", f"{GS}:GetAllActorsOfClass", {"ActorClass": TACTICAL_STATE})
    g.node("first", "array_call", function=f"{KAL}:Array_Get", defaults={"Index": 0})
    g.node("state", "cast", **{"class": TACTICAL_STATE})
    g.node("getsquad", "get", var=f"{TACTICAL_STATE}:PlayerSquad")
    g.call("hassquad", f"{KSL}:IsValid")
    g.node("anysquad", "branch")
    g.call("members", f"{SQUAD}:GetSquadMembers")
    g.node("setunits", "set", var="SquadUnits")
    g.node("getunits", "get", var="SquadUnits")
    g.node("loop", "macro", macro="ForEachLoop")
    g.call("check", "self:CheckUnit")
    g.node("getnew", "get", var="NewPositions")
    g.node("clearnew", "array_call", function=f"{KAL}:Array_Clear")
    g.node("keeploop", "macro", macro="ForEachLoop")
    g.call("loc", f"{ACTOR}:K2_GetActorLocation")
    g.node("getnew2", "get", var="NewPositions")
    g.node("keep", "array_call", function=f"{KAL}:Array_Add")
    g.node("getnew3", "get", var="NewPositions")
    g.node("setlast", "set", var="LastPositions")
    g.chain("entry", "states", "state")
    g.chain("state", "anysquad")
    g.chain("anysquad", "setunits", "loop.Exec")
    g.chain("loop.LoopBody", "check")
    g.chain("loop.Completed", "clearnew", "keeploop.Exec")
    g.chain("keeploop.LoopBody", "keep")
    g.chain("keeploop.Completed", "setlast")
    g.wire(("states.OutActors", "first.TargetArray"), ("first.Item", "state.Object"),
           ("state.AsTactical Game State", "getsquad.self"), ("getsquad.PlayerSquad", "hassquad.Object"),
           ("hassquad.ReturnValue", "anysquad.Condition"), ("getsquad.PlayerSquad", "members.self"),
           ("members.ReturnValue", "setunits.SquadUnits"), ("getunits.SquadUnits", "loop.Array"),
           ("loop.Array Element", "check.Unit"), ("loop.Array Index", "check.Index"),
           ("getnew.NewPositions", "clearnew.TargetArray"), ("getunits.SquadUnits", "keeploop.Array"),
           ("keeploop.Array Element", "loc.self"), ("getnew2.NewPositions", "keep.TargetArray"),
           ("loc.ReturnValue", "keep.NewItem"), ("getnew3.NewPositions", "setlast.LastPositions"))
    return {"name": "UnstackPass", "inputs": [], "outputs": [], **g.spec()}


def check_unit():
    """CheckUnit(Unit, Index): moved aside when within STACKED of an earlier operator and still since the last pass."""
    g = Graph()
    g.node("setfar", "set", var="Nearest", defaults={"Nearest": 1.0e12})
    g.node("getunits", "get", var="SquadUnits")
    g.node("loop", "macro", macro="ForEachLoop")
    g.call("earlier", f"{KML}:Less_IntInt")
    g.node("isearlier", "branch")
    g.call("here", f"{ACTOR}:K2_GetActorLocation")
    g.call("there", f"{ACTOR}:K2_GetActorLocation")
    g.call("dist", f"{KML}:Vector_Distance2D")
    g.node("getnearest", "get", var="Nearest")
    g.call("closer", f"{KML}:Less_DoubleDouble")
    g.node("isclose", "branch")
    g.node("setnearest", "set", var="Nearest")
    # Stacked and still: the previous pass saw it at the same place (none on the first pass: index out of range).
    g.node("getnearest2", "get", var="Nearest")
    g.call("stacked", f"{KML}:Less_DoubleDouble", {"B": STACKED})
    g.node("getlast", "get", var="LastPositions")
    g.node("lastlen", "array_call", function=f"{KAL}:Array_Length")
    g.call("known", f"{KML}:Less_IntInt")
    g.node("last", "array_call", function=f"{KAL}:Array_Get")
    g.call("moved", f"{KML}:Vector_Distance")
    g.call("still", f"{KML}:Less_DoubleDouble", {"B": STILL})
    g.call("and1", f"{KML}:BooleanAND")
    g.call("and2", f"{KML}:BooleanAND")
    # Once per operator: some missions hold their staged squad on one spot and put a moved operator back every frame.
    g.node("gettried", "get", var="TriedUnits")
    g.node("tried", "array_call", function=f"{KAL}:Array_Contains")
    g.call("untried", f"{KML}:Not_PreBool")
    g.call("and3", f"{KML}:BooleanAND")
    g.node("doit", "branch")
    g.node("gettried2", "get", var="TriedUnits")
    g.node("remember", "array_call", function=f"{KAL}:Array_Add")
    g.call("aside", "self:MoveAside")
    g.chain("entry", "setfar", "loop.Exec")
    g.chain("loop.LoopBody", "isearlier")
    g.chain("isearlier", "isclose")
    g.chain("isclose", "setnearest")
    g.chain("loop.Completed", "doit")
    g.chain("doit", "remember", "aside")
    g.wire(("getunits.SquadUnits", "loop.Array"), ("loop.Array Index", "earlier.A"), ("entry.Index", "earlier.B"),
           ("earlier.ReturnValue", "isearlier.Condition"), ("entry.Unit", "here.self"),
           ("loop.Array Element", "there.self"), ("here.ReturnValue", "dist.V1"), ("there.ReturnValue", "dist.V2"),
           ("dist.ReturnValue", "closer.A"), ("getnearest.Nearest", "closer.B"),
           ("closer.ReturnValue", "isclose.Condition"), ("dist.ReturnValue", "setnearest.Nearest"),
           ("getnearest2.Nearest", "stacked.A"), ("getlast.LastPositions", "lastlen.TargetArray"),
           ("entry.Index", "known.A"), ("lastlen.ReturnValue", "known.B"),
           ("getlast.LastPositions", "last.TargetArray"), ("entry.Index", "last.Index"),
           ("here.ReturnValue", "moved.V1"), ("last.Item", "moved.V2"), ("moved.ReturnValue", "still.A"),
           ("stacked.ReturnValue", "and1.A"), ("known.ReturnValue", "and1.B"),
           ("and1.ReturnValue", "and2.A"), ("still.ReturnValue", "and2.B"),
           ("gettried.TriedUnits", "tried.TargetArray"), ("entry.Unit", "tried.ItemToFind"), ("tried.ReturnValue", "untried.A"),
           ("and2.ReturnValue", "and3.A"), ("untried.ReturnValue", "and3.B"), ("and3.ReturnValue", "doit.Condition"),
           ("gettried2.TriedUnits", "remember.TargetArray"), ("entry.Unit", "remember.NewItem"),
           ("entry.Unit", "aside.Unit"))
    return {"name": "CheckUnit", "inputs": [{"name": "Unit", "type": f"object:{ACTOR}"},
                                            {"name": "Index", "type": "int"}], "outputs": [], **g.spec()}


def move_aside():
    """MoveAside(Unit): to the first free tile among ImproveOffsets (a tile or two in eight directions)."""
    g = Graph()
    g.node("setnot", "set", var="MovedAside", defaults={"MovedAside": "false"})
    g.call("base", f"{ACTOR}:K2_GetActorLocation")
    g.call("basefloor", f"{NAV}:K2_ProjectPointToNavigation", {"QueryExtent": f"{SNAP + 20},{SNAP + 20},250"})
    g.call("basebreak", f"{KML}:BreakVector")
    g.call("floorbreak", f"{KML}:BreakVector")
    g.call("lift", f"{KML}:Subtract_DoubleDouble")
    g.node("getoffsets", "get", var="ImproveOffsets")
    g.node("loop", "macro", macro="ForEachLoop")
    g.call("cand", f"{KML}:Add_VectorVector")
    g.call("candfloor", f"{NAV}:K2_ProjectPointToNavigation", {"QueryExtent": f"{SNAP},{SNAP},{STEP + 50}"})
    g.call("candbreak", f"{KML}:BreakVector")
    g.call("rise", f"{KML}:Subtract_DoubleDouble")
    g.call("riseabs", f"{KML}:Abs")
    g.call("level", f"{KML}:LessEqual_DoubleDouble", {"B": STEP})
    g.call("free", "self:FreeOfUnits")
    g.node("getfree", "get", var="FreeOk")
    g.node("getmoved", "get", var="MovedAside")
    g.call("notyet", f"{KML}:Not_PreBool")
    g.call("and1", f"{KML}:BooleanAND")
    g.call("and2", f"{KML}:BooleanAND")
    g.call("and3", f"{KML}:BooleanAND")
    g.call("and4", f"{KML}:BooleanAND")
    g.node("take", "branch")
    g.call("standz", f"{KML}:Add_DoubleDouble")
    g.call("target", f"{KML}:MakeVector")
    g.call("teleport", f"{ACTOR}:K2_SetActorLocation", {"bTeleport": "true"})
    g.node("setmoved", "set", var="MovedAside", defaults={"MovedAside": "true"})
    g.node("getcount", "get", var="UnstackMoves")
    g.call("addcount", f"{KML}:Add_IntInt", {"B": 1})
    g.node("setcount", "set", var="UnstackMoves")
    g.chain("entry", "setnot", "loop.Exec")
    g.chain("loop.LoopBody", "free", "take")
    g.chain("take", "teleport", "setmoved", "setcount")
    g.wire(("entry.Unit", "base.self"), ("base.ReturnValue", "basefloor.Point"), ("base.ReturnValue", "basebreak.InVec"),
           ("basefloor.ProjectedLocation", "floorbreak.InVec"), ("basebreak.Z", "lift.A"), ("floorbreak.Z", "lift.B"),
           ("getoffsets.ImproveOffsets", "loop.Array"), ("base.ReturnValue", "cand.A"), ("loop.Array Element", "cand.B"),
           ("cand.ReturnValue", "candfloor.Point"), ("candfloor.ProjectedLocation", "candbreak.InVec"),
           ("candbreak.Z", "rise.A"), ("floorbreak.Z", "rise.B"), ("rise.ReturnValue", "riseabs.A"),
           ("riseabs.ReturnValue", "level.A"), ("candfloor.ProjectedLocation", "free.Point"),
           ("getmoved.MovedAside", "notyet.A"),
           ("basefloor.ReturnValue", "and1.A"), ("candfloor.ReturnValue", "and1.B"),
           ("and1.ReturnValue", "and2.A"), ("level.ReturnValue", "and2.B"),
           ("and2.ReturnValue", "and3.A"), ("getfree.FreeOk", "and3.B"),
           ("and3.ReturnValue", "and4.A"), ("notyet.ReturnValue", "and4.B"), ("and4.ReturnValue", "take.Condition"),
           ("candbreak.Z", "standz.A"), ("lift.ReturnValue", "standz.B"),
           ("candbreak.X", "target.X"), ("candbreak.Y", "target.Y"), ("standz.ReturnValue", "target.Z"),
           ("entry.Unit", "teleport.self"), ("target.ReturnValue", "teleport.NewLocation"),
           ("getcount.UnstackMoves", "addcount.A"), ("addcount.ReturnValue", "setcount.UnstackMoves"))
    return {"name": "MoveAside", "inputs": [{"name": "Unit", "type": f"object:{ACTOR}"}], "outputs": [], **g.spec()}


def functions():
    # FreeOfUnits first: MoveAside calls it.
    return [free_units(), unstack_pass(), check_unit(), move_aside()]


def free_units():
    """FreeOfUnits(Point): FreeOk when Point is SEPARATION from every operator. No output pin: a loop in a function
    with one cooked into an unloadable brain once (zcomauthoring-cook-gotchas)."""
    g = Graph()
    g.node("setmin", "set", var="MinD", defaults={"MinD": 1.0e12})
    g.node("getunits", "get", var="SquadUnits")
    g.node("loop", "macro", macro="ForEachLoop")
    g.call("loc", f"{ACTOR}:K2_GetActorLocation")
    g.call("dist", f"{KML}:Vector_Distance2D")
    g.node("getmin", "get", var="MinD")
    g.call("closer", f"{KML}:Less_DoubleDouble")
    g.node("isclose", "branch")
    g.node("setmin2", "set", var="MinD")
    g.node("getmin2", "get", var="MinD")
    g.call("apart", f"{KML}:GreaterEqual_DoubleDouble", {"B": SEPARATION})
    g.node("setfree", "set", var="FreeOk")
    g.chain("entry", "setmin", "loop.Exec")
    g.chain("loop.LoopBody", "isclose")
    g.chain("isclose", "setmin2")
    g.chain("loop.Completed", "setfree")
    g.wire(("getunits.SquadUnits", "loop.Array"), ("loop.Array Element", "loc.self"), ("entry.Point", "dist.V1"),
           ("loc.ReturnValue", "dist.V2"), ("dist.ReturnValue", "closer.A"), ("getmin.MinD", "closer.B"),
           ("closer.ReturnValue", "isclose.Condition"), ("dist.ReturnValue", "setmin2.MinD"),
           ("getmin2.MinD", "apart.A"), ("apart.ReturnValue", "setfree.FreeOk"))
    return {"name": "FreeOfUnits", "inputs": [{"name": "Point", "type": "vector"}], "outputs": [], **g.spec()}
