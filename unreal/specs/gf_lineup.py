"""The squad screen's lineup at six, for BP_SquadSixBrain (Reforged's lineup.lua without hooks: a 0.1 s Lineup timer).

Only native classes are referenced at compile time. The kit editor crashes loading most cooked game Blueprints (a cooked
ControlRig behind BP_CustomizationProxyCharacter, missing script imports behind the squad screen), so game Blueprint
classes are loaded at runtime by path and members of game Blueprints are reached by name.

- Pool: the Den's hologram manager (an AC_HologramManager component on the BrunoStrategyGameState, found by class name)
  spawns four presentation proxies. Once per manager, before any lineup, six hidden proxies of the same class are
  spawned and replace its "Customization Proxy Actors" by name (it can't be read without the class), so the game's own
  ShowLineupHologramActors clones all six operators into them. The game's four stay hidden at the origin, as they sit
  between lineups anyway. The diorama has four authored slots, so five and six stay where they spawned for the fit.
- Screen: while a WBP_Menu_MissionSquadSelect is visible, the models are fitted and, with five or six in the squad,
  every visible nameplate (WBP_CharacterSlot) gets -50 left and right padding: 100 less width per entry, the same layout as
  Reforged's EntrySpacing -100 on the CharacterSlots row, which can't be reached without the screen's class
  (GetWidgetFromName isn't Blueprint-callable, and the entries have no UMG parent).
- Squad: the screen's BrunoMissionViewModel ("Default") lists the slots, required then flexible, in the lineup's order;
  Used is one past the last with an AssignedCharacterVM (matched the lineup exactly in game, 2026-10-18); Filled says
  which slots have one, so an emptied fifth with the sixth still filled is a hole (in game, 2026-11-06).
- Row: Shown is how many nameplates the screen has up, at least Used. The game puts up one per slot of the mission,
  EMPTY ones included (six at every squad size in a six-slot mission, in game 2026-11-06); laying the models out by Used
  put five each half a slot right of its name (player report and in game, 2026-11-06).
- Fit: the four authored positions are captured once per manager. With more than four plates the models are laid
  along the authored row as a row of Shown, centred on it, ROW_STEP_RATIO of its step apart (so each stands over its squeezed
  nameplate; Reforged's 3 / (used - 1) left them 15% short) and scaled by 3 / (Shown - 1); no camera changes (the
  character editor shares this stage). Each takes the rotation of the authored slot nearest its place. Per proxy, the scale the fit started from and the one it wrote are kept, so it never compounds and
  a new character's scale is picked up; with four or fewer plates, a proxy still carrying the fit's scale gets its base
  back and, while it hangs in its diorama slot, the slot's own place (the game only snaps it there when it attaches).
  Empty overflow slots' proxies (past Used, or a hole) are hidden (the game never hides a proxy whose slot emptied, so a removed sixth, or a
  cancelled preview, stays standing over the EMPTY plate), but not while the picker is open and not until the squad has
  held for SETTLE_PASSES: the picker previews a character by cloning it into the proxy and showing it before Used counts
  it, and the game never shows that proxy again once its slot holds that character, so hiding it then hid a re-added
  sixth for good (in game, 2026-11-06). A hidden proxy is also parked at the origin, where the game parks one whose
  slot emptied: its weapons are actors of their own, attached, and stayed in the row when only the proxy was hidden.
  While the picker is open the slot being filled (Used) is placed too, if the game is showing it, so the preview stands
  in the row at the row's size rather than full size on the game's slot.
"""
from gf_graph import Graph, KSL, KML, KAL, GS, TARGET

PROXY_CLASS_PATH = ("/Game/Game/Cinematics/Blueprints/Hologram_Utility/BP_CustomizationPresentationFacilitator/"
                    "BP_CustomizationProxyCharacter.BP_CustomizationProxyCharacter_C")
SCREEN_CLASS_PATH = "/Game/Game/UI/Strategy/SquadSelect/WBP_Menu_MissionSquadSelect.WBP_Menu_MissionSquadSelect_C"
ENTRY_CLASS_PATH = "/Game/Game/UI/Strategy/SquadSelect/Widgets/WBP_CharacterSlot.WBP_CharacterSlot_C"
STRATEGY_STATE = "/Script/Bruno.BrunoStrategyGameState"
MANAGER_CLASS_NAME = "AC_HologramManager"
PROXY_LIST = "Customization Proxy Actors"
MISSION_VM = "/Script/Bruno.BrunoMissionViewModel"
SLOT_VM = "/Script/Bruno.BrunoMissionSquadSlotViewModel"
ACTOR = "/Script/Engine.Actor"
COMPONENT = "/Script/Engine.ActorComponent"
USER_WIDGET = "/Script/UMG.UserWidget"
AUTHORED = 4
NAMEPLATE_SQUEEZE = -50.0  # each side: Reforged's EntrySpacing -100, per entry (the row is centred, so identical)
# The models' step along the row, as a share of the authored step, with five or six in the squad: lines each model up
# over its squeezed nameplate (200 px apart at 1280 x 720, the 3/5 fit gave 173; measured 2026-10-18). The nameplates'
# spacing doesn't depend on the squad's size, so neither does this.
ROW_STEP_RATIO = 0.6926
MIN_SLOT_SEPARATION = 10.0  # MIN_SLOT_SEPARATION_SQ's root: an unplaced pool sits on top of itself
ASSIGNMENT = "/Script/MDViewModel.MDViewModelAssignmentReference"
IMC_SUBSYSTEM = "/Script/BitReactorGame.BitReactorIMCStateSubsystem"
# The squad screen's input state while its character picker is up (UpdateState -> ChangeIMCState; read in game with the
# picker open and closed, 2026-11-06). The picker previews the hovered character in the slot, cloned into its proxy,
# before the slot counts that character.
PICKER_STATE = "BR.UI.IMCState.Strategy.SquadSelect.Assign"
# Passes (0.1 s each) the squad has to stay the same, picker closed, before overflow proxies past it are hidden.
SETTLE_PASSES = 3


def variables():
    return [
        {"name": "Manager", "type": f"object:{COMPONENT}"},
        {"name": "ReplacedFor", "type": f"object:{COMPONENT}"},
        {"name": "ProxyClass", "type": f"class:{ACTOR}"},
        {"name": "ScreenClass", "type": f"class:{USER_WIDGET}"},
        {"name": "EntryClass", "type": f"class:{USER_WIDGET}"},
        {"name": "Proxies", "type": f"object:{ACTOR}[]"},
        {"name": "PoolSpawned", "type": "int", "default": "0"},
        {"name": "Screen", "type": f"object:{USER_WIDGET}"},
        {"name": "ScreenIsOpen", "type": "bool"},
        {"name": "Used", "type": "int"},
        {"name": "Shown", "type": "int"},
        {"name": "LastUsed", "type": "int", "default": "0"},
        {"name": "Settle", "type": "int", "default": "0"},
        {"name": "PickerIsOpen", "type": "bool"},
        {"name": "Filled", "type": "bool[]"},
        {"name": "RequiredCount", "type": "int"},
        {"name": "Captured", "type": "bool", "default": "false"},
        {"name": "AuthLocs", "type": "vector[]"},
        {"name": "AuthRots", "type": "rotator[]"},
        {"name": "OverflowScale", "type": "vector"},
        {"name": "RowBase", "type": "vector"},
        {"name": "PlaceBase", "type": "vector"},
        {"name": "FitProxies", "type": f"object:{ACTOR}[]"},
        {"name": "FitBases", "type": "vector[]"},
        {"name": "FitApplied", "type": "vector[]"},
        {"name": "Fit", "type": "float"},
        {"name": "LineupPasses", "type": "int", "default": "0"},
        {"name": "LineupFits", "type": "int", "default": "0"},
    ]


def event(g):
    """Adds the Lineup custom event to the event graph `g` (its timer is set in BeginPlay)."""
    g.node("lineup", "custom_event", name="Lineup")
    g.call("lfind", "self:FindManager")
    g.node("lgetmanager", "get", var="Manager")
    g.call("lhasmanager", f"{KSL}:IsValid")
    g.node("linhub", "branch")
    g.call("lpool", "self:EnsurePool")
    g.call("lholo", "self:Holotable")
    g.call("lscreen", "self:ScreenOpen")
    g.node("lisopen", "branch")
    g.call("lfit", "self:FitLineup")
    g.call("lpad", "self:PadNameplates")
    g.node("lgetpasses", "get", var="LineupPasses")
    g.call("laddpasses", f"{KML}:Add_IntInt", {"B": 1})
    g.node("lsetpasses", "set", var="LineupPasses")
    g.chain("lineup", "lfind", "linhub")
    g.chain("linhub", "lsetpasses", "lpool", "lholo", "lscreen", "lisopen")
    g.chain("lisopen", "lfit", "lpad")
    g.wire(("lgetmanager.Manager", "lhasmanager.Object"), ("lhasmanager.ReturnValue", "linhub.Condition"),
           ("lscreen.Open", "lisopen.Condition"), ("lgetpasses.LineupPasses", "laddpasses.A"),
           ("laddpasses.ReturnValue", "lsetpasses.LineupPasses"))


def load_class(g, prefix, path, var, base):
    """Nodes that load a game class by path at runtime into `var` (cast to `base`); returns (first, last) exec ids."""
    g.call(f"{prefix}path", f"{KSL}:MakeSoftClassPath", {"PathString": path})
    g.call(f"{prefix}ref", f"{KSL}:Conv_SoftClassPathToSoftClassRef")
    g.call(f"{prefix}load", f"{KSL}:LoadClassAsset_Blocking")
    g.node(f"{prefix}cast", "class_cast", **{"class": base})
    g.node(f"{prefix}set", "set", var=var)
    g.wire((f"{prefix}path.ReturnValue", f"{prefix}ref.SoftClassPath"),
           (f"{prefix}ref.ReturnValue", f"{prefix}load.AssetClass"),
           (f"{prefix}load.ReturnValue", f"{prefix}cast.Class"))
    return f"{prefix}load", f"{prefix}cast", f"{prefix}set"


def load_classes():
    """LoadClasses: the proxy and squad screen classes, once."""
    g = Graph()
    g.node("getproxyclass", "get", var="ProxyClass")
    g.call("haveproxy", f"{KSL}:IsValidClass")
    g.node("needproxy", "branch")
    load1, cast1, set1 = load_class(g, "p", PROXY_CLASS_PATH, "ProxyClass", ACTOR)
    g.node("getscreenclass", "get", var="ScreenClass")
    g.call("havescreen", f"{KSL}:IsValidClass")
    g.node("needscreen", "branch")
    load2, cast2, set2 = load_class(g, "s", SCREEN_CLASS_PATH, "ScreenClass", USER_WIDGET)
    g.node("getentryclass", "get", var="EntryClass")
    g.call("haveentry", f"{KSL}:IsValidClass")
    g.node("needentry", "branch")
    load3, cast3, set3 = load_class(g, "e", ENTRY_CLASS_PATH, "EntryClass", USER_WIDGET)
    g.chain("entry", "needproxy")
    g.chain("needproxy.else", load1, cast1)
    g.chain(cast1, set1, "needscreen")
    g.chain("needproxy", "needscreen")
    g.chain("needscreen.else", load2, cast2)
    g.chain(cast2, set2, "needentry")
    g.chain("needscreen", "needentry")
    g.chain("needentry.else", load3, cast3)
    g.chain(cast3, set3)
    g.wire(("getproxyclass.ProxyClass", "haveproxy.Class"), ("haveproxy.ReturnValue", "needproxy.Condition"),
           ("pcast.AsActor", "pset.ProxyClass"),
           ("getscreenclass.ScreenClass", "havescreen.Class"), ("havescreen.ReturnValue", "needscreen.Condition"),
           ("scast.AsUser Widget", "sset.ScreenClass"),
           ("getentryclass.EntryClass", "haveentry.Class"), ("haveentry.ReturnValue", "needentry.Condition"),
           ("ecast.AsUser Widget", "eset.EntryClass"))
    return {"name": "LoadClasses", "inputs": [], "outputs": [], **g.spec()}


def find_manager():
    """FindManager: the AC_HologramManager component on the Den's strategy game state (by class name), kept."""
    g = Graph()
    g.node("getmanager", "get", var="Manager")
    g.call("valid", f"{KSL}:IsValid")
    g.node("have", "branch")
    g.call("states", f"{GS}:GetAllActorsOfClass", {"ActorClass": STRATEGY_STATE})
    g.node("loop", "macro", macro="ForEachLoop")
    g.call("components", f"{ACTOR}:K2_GetComponentsByClass", {"ComponentClass": COMPONENT})
    g.node("comploop", "macro", macro="ForEachLoop")
    g.call("cls", f"{GS}:GetObjectClass")
    g.call("clsname", f"{KSL}:GetClassDisplayName")
    g.call("ismanager", "/Script/Engine.KismetStringLibrary:Contains", {"Substring": MANAGER_CLASS_NAME})
    g.node("found", "branch")
    g.node("setmanager", "set", var="Manager")
    g.chain("entry", "have")
    g.chain("have.else", "states", "loop.Exec")
    g.chain("loop.LoopBody", "comploop.Exec")
    g.chain("comploop.LoopBody", "found")
    g.chain("found", "setmanager")
    g.wire(("getmanager.Manager", "valid.Object"), ("valid.ReturnValue", "have.Condition"),
           ("states.OutActors", "loop.Array"), ("loop.Array Element", "components.self"),
           ("components.ReturnValue", "comploop.Array"), ("comploop.Array Element", "cls.Object"),
           ("cls.ReturnValue", "clsname.Class"), ("clsname.ReturnValue", "ismanager.SearchIn"),
           ("ismanager.ReturnValue", "found.Condition"), ("comploop.Array Element", "setmanager.Manager"))
    return {"name": "FindManager", "inputs": [], "outputs": [], **g.spec()}


def ensure_pool():
    """EnsurePool: once per manager, six hidden proxies of the game's class replace its proxy list (by name)."""
    g = Graph()
    g.call("classes", "self:LoadClasses")
    g.node("getmanager", "get", var="Manager")
    g.node("getreplaced", "get", var="ReplacedFor")
    g.call("fresh", f"{KML}:NotEqual_ObjectObject")
    g.node("getproxyclass", "get", var="ProxyClass")
    g.call("haveclass", f"{KSL}:IsValidClass")
    g.call("both", f"{KML}:BooleanAND")
    g.node("replace", "branch")
    g.node("getproxies", "get", var="Proxies")
    g.node("clear", "array_call", function=f"{KAL}:Array_Clear")
    g.node("loop", "macro", macro="ForLoop", defaults={"FirstIndex": 1, "LastIndex": TARGET})
    g.call("origin", f"{KML}:MakeTransform")
    g.call("spawn", f"{GS}:BeginDeferredActorSpawnFromClass", {"CollisionHandlingOverride": "AlwaysSpawn"})
    g.call("finish", f"{GS}:FinishSpawningActor")
    g.call("hide", f"{ACTOR}:SetActorHiddenInGame", {"bNewHidden": "true"})
    g.node("add", "array_call", function=f"{KAL}:Array_Add")
    g.node("getspawned", "get", var="PoolSpawned")
    g.call("addspawned", f"{KML}:Add_IntInt", {"B": 1})
    g.node("setspawned", "set", var="PoolSpawned")
    g.node("writeback", "array_call", function=f"{KAL}:SetArrayPropertyByName", defaults={"PropertyName": PROXY_LIST})
    g.node("setreplaced", "set", var="ReplacedFor")
    # A new pool means a new layout and new scales.
    g.node("setuncaptured", "set", var="Captured", defaults={"Captured": "false"})
    clears = []
    for var in ("FitProxies", "FitBases", "FitApplied"):
        g.node(f"get{var}", "get", var=var)
        g.node(f"clear{var}", "array_call", function=f"{KAL}:Array_Clear")
        g.link(f"get{var}.{var}", f"clear{var}.TargetArray")
        clears.append(f"clear{var}")
    g.chain("entry", "classes", "replace")
    g.chain("replace", "clear", "loop.execute")
    g.chain("loop.LoopBody", "spawn", "finish", "hide", "add", "setspawned")
    g.chain("loop.Completed", "writeback", "setreplaced", "setuncaptured", *clears)
    g.wire(("getmanager.Manager", "fresh.A"), ("getreplaced.ReplacedFor", "fresh.B"),
           ("getproxyclass.ProxyClass", "haveclass.Class"), ("fresh.ReturnValue", "both.A"),
           ("haveclass.ReturnValue", "both.B"), ("both.ReturnValue", "replace.Condition"),
           ("getproxies.Proxies", "clear.TargetArray"), ("getproxyclass.ProxyClass", "spawn.ActorClass"),
           ("origin.ReturnValue", "spawn.SpawnTransform"), ("spawn.ReturnValue", "finish.Actor"),
           ("origin.ReturnValue", "finish.SpawnTransform"), ("finish.ReturnValue", "hide.self"),
           ("getproxies.Proxies", "add.TargetArray"), ("finish.ReturnValue", "add.NewItem"),
           ("getspawned.PoolSpawned", "addspawned.A"), ("addspawned.ReturnValue", "setspawned.PoolSpawned"),
           ("getmanager.Manager", "writeback.Object"), ("getproxies.Proxies", "writeback.Value"),
           ("getmanager.Manager", "setreplaced.ReplacedFor"))
    return {"name": "EnsurePool", "inputs": [], "outputs": [], **g.spec()}


def screen_open():
    """ScreenOpen -> Open: a squad screen is visible (kept in Screen)."""
    g = Graph()
    g.node("setclosed", "set", var="ScreenIsOpen", defaults={"ScreenIsOpen": "false"})
    g.node("getscreenclass", "get", var="ScreenClass")
    g.call("widgets", "/Script/UMG.WidgetBlueprintLibrary:GetAllWidgetsOfClass", {"TopLevelOnly": "false"})
    g.node("loop", "macro", macro="ForEachLoop")
    g.call("visible", "/Script/UMG.Widget:IsVisible")
    g.node("isvisible", "branch")
    g.node("setopen", "set", var="ScreenIsOpen", defaults={"ScreenIsOpen": "true"})
    g.node("setscreen", "set", var="Screen")
    g.node("getopen", "get", var="ScreenIsOpen")
    g.chain("entry", "setclosed", "widgets", "loop.Exec")
    g.chain("loop.LoopBody", "isvisible")
    g.chain("isvisible", "setopen", "setscreen")
    g.chain("loop.Completed", "result")
    g.wire(("getscreenclass.ScreenClass", "widgets.WidgetClass"), ("widgets.FoundWidgets", "loop.Array"),
           ("loop.Array Element", "visible.self"), ("visible.ReturnValue", "isvisible.Condition"),
           ("loop.Array Element", "setscreen.Screen"), ("getopen.ScreenIsOpen", "result.Open"))
    return {"name": "ScreenOpen", "inputs": [], "outputs": [{"name": "Open", "type": "bool"}], **g.spec()}


def pad_nameplates():
    """PadNameplates: with five or six plates up, every visible nameplate gets NAMEPLATE_SQUEEZE left and right
    (Reforged's fit_squad_screen, per entry since the row itself can't be reached); with four or fewer, none, so they
    stay under the authored models. Set only where it differs. Reforged's vertical reset of the row is left out: per
    entry, +100 px pushed the names into the button bar (2026-10-18)."""
    g = Graph()
    g.node("getshown", "get", var="Shown")
    g.call("wide", f"{KML}:Greater_IntInt", {"B": AUTHORED})
    g.call("want", f"{KML}:SelectFloat", {"A": NAMEPLATE_SQUEEZE, "B": 0})
    g.node("getentryclass", "get", var="EntryClass")
    g.call("widgets", "/Script/UMG.WidgetBlueprintLibrary:GetAllWidgetsOfClass", {"TopLevelOnly": "false"})
    g.node("loop", "macro", macro="ForEachLoop")
    g.call("visible", "/Script/UMG.Widget:IsVisible")
    g.node("getpad", "get", var=f"{USER_WIDGET}:Padding")
    g.node("pad", "break_struct", struct="/Script/SlateCore.Margin")
    g.call("differs", f"{KML}:NotEqual_DoubleDouble")
    g.call("todo", f"{KML}:BooleanAND")
    g.node("dopad", "branch")
    g.node("margin", "make_struct", struct="/Script/SlateCore.Margin", defaults={"Top": 0, "Bottom": 0})
    g.call("setpad", f"{USER_WIDGET}:SetPadding")
    g.chain("entry", "widgets", "loop.Exec")
    g.chain("loop.LoopBody", "dopad")
    g.chain("dopad", "setpad")
    g.wire(("getshown.Shown", "wide.A"), ("wide.ReturnValue", "want.bPickA"),
           ("getentryclass.EntryClass", "widgets.WidgetClass"), ("widgets.FoundWidgets", "loop.Array"),
           ("loop.Array Element", "visible.self"), ("loop.Array Element", "getpad.self"),
           ("getpad.Padding", "pad.Margin"), ("pad.Left", "differs.A"), ("want.ReturnValue", "differs.B"),
           ("visible.ReturnValue", "todo.A"), ("differs.ReturnValue", "todo.B"), ("todo.ReturnValue", "dopad.Condition"),
           ("want.ReturnValue", "margin.Left"), ("want.ReturnValue", "margin.Right"),
           ("loop.Array Element", "setpad.self"), ("margin.Margin", "setpad.InPadding"))
    return {"name": "PadNameplates", "inputs": [], "outputs": [], **g.spec()}


def count_used():
    """CountUsed: Used = one past the last squad slot with a character, required slots then flexible ones; Filled[i] =
    slot i has one (false past the slots, up to the pool's TARGET)."""
    g = Graph()
    g.node("setzero", "set", var="Used", defaults={"Used": 0})
    g.node("getfilled", "get", var="Filled")
    g.node("clearfilled", "array_call", function=f"{KAL}:Array_Clear")
    g.node("getfilled2", "get", var="Filled")
    g.node("reqadd", "array_call", function=f"{KAL}:Array_Add")
    g.node("getfilled3", "get", var="Filled")
    g.node("flexadd", "array_call", function=f"{KAL}:Array_Add")
    g.node("getfilled4", "get", var="Filled")
    g.node("pad", "array_call", function=f"{KAL}:Array_Resize", defaults={"Size": TARGET})
    g.node("getscreen", "get", var="Screen")
    g.node("assignment", "make_struct", struct=ASSIGNMENT,
           defaults={"ViewModelClass": MISSION_VM, "ViewModelName": "Default"})
    g.call("getvm", "/Script/MDViewModel.MDViewModelFunctionLibrary:BP_GetViewModel")
    g.node("mission", "cast", **{"class": MISSION_VM})
    g.node("getreq", "get", var=f"{MISSION_VM}:RequiredSlotVMs")
    g.node("getflex", "get", var=f"{MISSION_VM}:FlexibleSlotVMs")
    g.node("reqlen", "array_call", function=f"{KAL}:Array_Length")
    g.node("setreqcount", "set", var="RequiredCount")
    g.node("reqloop", "macro", macro="ForEachLoop")
    g.node("reqchar", "get", var=f"{SLOT_VM}:AssignedCharacterVM")
    g.call("reqfilled", f"{KSL}:IsValid")
    g.node("reqif", "branch")
    g.call("reqnext", f"{KML}:Add_IntInt", {"B": 1})
    g.node("setreqused", "set", var="Used")
    g.node("flexloop", "macro", macro="ForEachLoop")
    g.node("flexchar", "get", var=f"{SLOT_VM}:AssignedCharacterVM")
    g.call("flexfilled", f"{KSL}:IsValid")
    g.node("flexif", "branch")
    g.node("getreqcount", "get", var="RequiredCount")
    g.call("flexat", f"{KML}:Add_IntInt")
    g.call("flexnext", f"{KML}:Add_IntInt", {"B": 1})
    g.node("setflexused", "set", var="Used")
    g.chain("entry", "setzero", "clearfilled", "getvm", "mission")
    g.chain("mission", "setreqcount", "reqloop.Exec")
    g.chain("reqloop.LoopBody", "reqadd", "reqif")
    g.chain("reqif", "setreqused")
    g.chain("reqloop.Completed", "flexloop.Exec")
    g.chain("flexloop.LoopBody", "flexadd", "flexif")
    g.chain("flexif", "setflexused")
    g.chain("flexloop.Completed", "pad")
    cast = "mission.AsBruno Mission View Model"
    g.wire(("getscreen.Screen", "getvm.Object"), ("assignment.MDViewModelAssignmentReference", "getvm.Assignment"),
           ("getvm.ReturnValue", "mission.Object"),
           (cast, "getreq.self"), (cast, "getflex.self"),
           ("getreq.RequiredSlotVMs", "reqlen.TargetArray"), ("reqlen.ReturnValue", "setreqcount.RequiredCount"),
           ("getreq.RequiredSlotVMs", "reqloop.Array"), ("reqloop.Array Element", "reqchar.self"),
           ("reqchar.AssignedCharacterVM", "reqfilled.Object"), ("reqfilled.ReturnValue", "reqif.Condition"),
           ("reqloop.Array Index", "reqnext.A"), ("reqnext.ReturnValue", "setreqused.Used"),
           ("getflex.FlexibleSlotVMs", "flexloop.Array"), ("flexloop.Array Element", "flexchar.self"),
           ("flexchar.AssignedCharacterVM", "flexfilled.Object"), ("flexfilled.ReturnValue", "flexif.Condition"),
           ("getreqcount.RequiredCount", "flexat.A"), ("flexloop.Array Index", "flexat.B"),
           ("flexat.ReturnValue", "flexnext.A"), ("flexnext.ReturnValue", "setflexused.Used"),
           ("getfilled.Filled", "clearfilled.TargetArray"),
           ("getfilled2.Filled", "reqadd.TargetArray"), ("reqfilled.ReturnValue", "reqadd.NewItem"),
           ("getfilled3.Filled", "flexadd.TargetArray"), ("flexfilled.ReturnValue", "flexadd.NewItem"),
           ("getfilled4.Filled", "pad.TargetArray"))
    return {"name": "CountUsed", "inputs": [], "outputs": [], **g.spec()}


def count_shown():
    """CountShown: Shown = the visible nameplates (WBP_CharacterSlot), never fewer than Used. The game puts up one per
    slot of the mission, EMPTY ones included, so this is the row the models have to line up with."""
    g = Graph()
    g.node("setzero", "set", var="Shown", defaults={"Shown": 0})
    g.node("getentryclass", "get", var="EntryClass")
    g.call("widgets", "/Script/UMG.WidgetBlueprintLibrary:GetAllWidgetsOfClass", {"TopLevelOnly": "false"})
    g.node("loop", "macro", macro="ForEachLoop")
    g.call("visible", "/Script/UMG.Widget:IsVisible")
    g.node("isvisible", "branch")
    g.node("getshown", "get", var="Shown")
    g.call("next", f"{KML}:Add_IntInt", {"B": 1})
    g.node("setnext", "set", var="Shown")
    g.node("getshown2", "get", var="Shown")
    g.node("getused", "get", var="Used")
    g.call("atleast", f"{KML}:Max")
    g.node("setatleast", "set", var="Shown")
    g.chain("entry", "setzero", "widgets", "loop.Exec")
    g.chain("loop.LoopBody", "isvisible")
    g.chain("isvisible", "setnext")
    g.chain("loop.Completed", "setatleast")
    g.wire(("getentryclass.EntryClass", "widgets.WidgetClass"), ("widgets.FoundWidgets", "loop.Array"),
           ("loop.Array Element", "visible.self"), ("visible.ReturnValue", "isvisible.Condition"),
           ("getshown.Shown", "next.A"), ("next.ReturnValue", "setnext.Shown"),
           ("getshown2.Shown", "atleast.A"), ("getused.Used", "atleast.B"), ("atleast.ReturnValue", "setatleast.Shown"))
    return {"name": "CountShown", "inputs": [], "outputs": [], **g.spec()}


def picker_open():
    """PickerOpen -> Open: the squad screen's character picker is up (the top input state is PICKER_STATE)."""
    g = Graph()
    g.call("pc", f"{GS}:GetPlayerController", {"PlayerIndex": 0})
    g.call("sub", "/Script/Engine.SubsystemBlueprintLibrary:GetLocalPlayerSubSystemFromPlayerController",
           {"Class": IMC_SUBSYSTEM})
    g.node("imc", "cast", **{"class": IMC_SUBSYSTEM})
    g.call("top", f"{IMC_SUBSYSTEM}:GetTopIMCStateTag")
    g.call("name", "/Script/GameplayTags.BlueprintGameplayTagLibrary:GetTagName")
    g.call("same", f"{KML}:EqualEqual_NameName", {"B": PICKER_STATE})
    g.node("setopen", "set", var="PickerIsOpen")
    g.node("setclosed", "set", var="PickerIsOpen", defaults={"PickerIsOpen": "false"})
    g.node("getopen", "get", var="PickerIsOpen")
    g.chain("entry", "setclosed", "imc")
    g.chain("imc", "top", "setopen", "result")
    g.chain("imc.CastFailed", "result")
    g.wire(("pc.ReturnValue", "sub.PlayerController"), ("sub.ReturnValue", "imc.Object"),
           ("imc.AsBit Reactor IMCState Subsystem", "top.self"), ("top.ReturnValue", "name.GameplayTag"),
           ("name.ReturnValue", "same.A"), ("same.ReturnValue", "setopen.PickerIsOpen"),
           ("getopen.PickerIsOpen", "result.Open"))
    return {"name": "PickerOpen", "inputs": [], "outputs": [{"name": "Open", "type": "bool"}], **g.spec()}


def capture_layout():
    """CaptureLayout: once per manager, the first four proxies' places when they're really apart (the Blueprint has
    placed them) and the squad fills them; slot four's scale for the overflow proxies, which the game never scales."""
    g = Graph()
    g.node("getproxies", "get", var="Proxies")
    g.node("len", "array_call", function=f"{KAL}:Array_Length")
    g.call("enough", f"{KML}:GreaterEqual_IntInt", {"B": AUTHORED})
    g.node("getused", "get", var="Used")
    g.call("full", f"{KML}:GreaterEqual_IntInt", {"B": AUTHORED})
    for i in range(AUTHORED):
        g.node(f"p{i}", "array_call", function=f"{KAL}:Array_Get", defaults={"Index": i})
        g.call(f"l{i}", "/Script/Engine.Actor:K2_GetActorLocation")
        g.call(f"r{i}", "/Script/Engine.Actor:K2_GetActorRotation")
        g.wire(("getproxies.Proxies", f"p{i}.TargetArray"), (f"p{i}.Item", f"l{i}.self"), (f"p{i}.Item", f"r{i}.self"))
    ands = ["enough.ReturnValue", "full.ReturnValue"]
    for i in range(AUTHORED - 1):
        g.call(f"d{i}", f"{KML}:Vector_Distance")
        g.call(f"apart{i}", f"{KML}:GreaterEqual_DoubleDouble", {"B": MIN_SLOT_SEPARATION})
        g.wire((f"l{i}.ReturnValue", f"d{i}.V1"), (f"l{i + 1}.ReturnValue", f"d{i}.V2"),
               (f"d{i}.ReturnValue", f"apart{i}.A"))
        ands.append(f"apart{i}.ReturnValue")
    previous = ands[0]
    for n, pin in enumerate(ands[1:]):
        g.call(f"and{n}", f"{KML}:BooleanAND")
        g.wire((previous, f"and{n}.A"), (pin, f"and{n}.B"))
        previous = f"and{n}.ReturnValue"
    g.node("placed", "branch")
    g.node("getlocs", "get", var="AuthLocs")
    g.node("clearlocs", "array_call", function=f"{KAL}:Array_Clear")
    g.node("getrots", "get", var="AuthRots")
    g.node("clearrots", "array_call", function=f"{KAL}:Array_Clear")
    steps = ["clearlocs", "clearrots"]
    for i in range(AUTHORED):
        g.node(f"addl{i}", "array_call", function=f"{KAL}:Array_Add")
        g.node(f"addr{i}", "array_call", function=f"{KAL}:Array_Add")
        g.wire(("getlocs.AuthLocs", f"addl{i}.TargetArray"), (f"l{i}.ReturnValue", f"addl{i}.NewItem"),
               ("getrots.AuthRots", f"addr{i}.TargetArray"), (f"r{i}.ReturnValue", f"addr{i}.NewItem"))
        steps += [f"addl{i}", f"addr{i}"]
    g.call("lastscale", "/Script/Engine.Actor:GetActorScale3D")
    g.node("setoverflow", "set", var="OverflowScale")
    g.node("setcaptured", "set", var="Captured", defaults={"Captured": "true"})
    g.chain("entry", "placed")
    g.chain("placed", *steps, "setoverflow", "setcaptured")
    g.wire(("getproxies.Proxies", "len.TargetArray"), ("len.ReturnValue", "enough.A"), ("getused.Used", "full.A"),
           (previous, "placed.Condition"), ("getlocs.AuthLocs", "clearlocs.TargetArray"),
           ("getrots.AuthRots", "clearrots.TargetArray"), (f"p{AUTHORED - 1}.Item", "lastscale.self"),
           ("lastscale.ReturnValue", "setoverflow.OverflowScale"))
    return {"name": "CaptureLayout", "inputs": [], "outputs": [], **g.spec()}


def place_proxy():
    """PlaceProxy(Index): model Index on a row of Shown, ROW_STEP_RATIO of the authored step apart and centred on the
    authored row, scaled by Fit from its tracked base (kept in PlaceBase before the scale is written); it takes the rotation of
    the authored slot nearest its place."""
    g = Graph()
    g.node("getlocs", "get", var="AuthLocs")
    g.node("a0", "array_call", function=f"{KAL}:Array_Get", defaults={"Index": 0})
    g.node("a3", "array_call", function=f"{KAL}:Array_Get", defaults={"Index": AUTHORED - 1})
    g.call("ends", f"{KML}:Add_VectorVector")
    g.call("centre", f"{KML}:Multiply_VectorFloat", {"B": 0.5})
    g.call("span", f"{KML}:Subtract_VectorVector")
    g.call("step", f"{KML}:Multiply_VectorFloat", {"B": 1.0 / (AUTHORED - 1)})
    g.node("getused", "get", var="Shown")
    g.call("usedf", f"{KML}:Conv_IntToDouble")
    g.call("last", f"{KML}:Subtract_DoubleDouble", {"B": 1})
    g.call("mid", f"{KML}:Multiply_DoubleDouble", {"B": 0.5})
    g.call("indexf", f"{KML}:Conv_IntToDouble")
    g.call("rel", f"{KML}:Subtract_DoubleDouble")
    g.node("getfit", "get", var="Fit")
    g.call("offset", f"{KML}:Multiply_DoubleDouble", {"B": ROW_STEP_RATIO})
    g.call("shift", f"{KML}:Multiply_VectorFloat")
    g.call("where", f"{KML}:Add_VectorVector")
    # The authored slot nearest this place gives the rotation.
    g.call("along", f"{KML}:Add_DoubleDouble", {"B": (AUTHORED - 1) / 2})
    g.call("round", f"{KML}:Round")
    g.call("nearest", f"{KML}:Clamp", {"Min": 0, "Max": AUTHORED - 1})
    g.node("getrots", "get", var="AuthRots")
    g.node("rot", "array_call", function=f"{KAL}:Array_Get")
    g.node("getproxies", "get", var="Proxies")
    g.node("proxy", "array_call", function=f"{KAL}:Array_Get")
    g.call("valid", f"{KSL}:IsValid")
    # An empty slot (past the squad, or a hole) only while the game is showing its proxy (the picker's preview): a
    # hidden proxy's weapons would come back into the row with it.
    g.node("getfilled", "get", var="Filled")
    g.node("insquad", "array_call", function=f"{KAL}:Array_Get")
    g.node("gethidden", "get", var=f"{ACTOR}:bHidden")
    g.call("shownnow", f"{KML}:Not_PreBool")
    g.call("wanted", f"{KML}:BooleanOR")
    g.call("go", f"{KML}:BooleanAND")
    g.node("isvalid", "branch")
    # Scale: the base the fit started from, unless the Blueprint has put a new one on the actor since.
    g.node("getfitp", "get", var="FitProxies")
    g.node("find", "array_call", function=f"{KAL}:Array_Find")
    g.call("known", f"{KML}:GreaterEqual_IntInt", {"B": 0})
    g.call("live", "/Script/Engine.Actor:GetActorScale3D")
    g.node("getapplied", "get", var="FitApplied")
    g.node("applied", "array_call", function=f"{KAL}:Array_Get")
    g.call("same", f"{KML}:EqualEqual_VectorVector", {"ErrorTolerance": 0.001})
    g.call("ours", f"{KML}:BooleanAND")
    g.node("getbases", "get", var="FitBases")
    g.node("base", "array_call", function=f"{KAL}:Array_Get")
    g.call("authoredidx", f"{KML}:Less_IntInt", {"B": AUTHORED})
    g.node("getrowbase", "get", var="RowBase")
    g.call("fresh", f"{KML}:SelectVector")
    g.call("oursauthored", f"{KML}:BooleanAND")
    g.call("chosen", f"{KML}:SelectVector")
    # Kept before the scale is written. Pure nodes run again for every impure node that reads them, so anything after
    # SetActorScale3D that read `chosen` would see the scale just written instead of the base, and record that as the
    # base: 2.0.3 stored the fitted scale, fitted it again (six stood at 0.36 of their size, not 0.6) and shrank the
    # row further on every change of squad size, until the models vanished.
    g.node("setplacebase", "set", var="PlaceBase")
    g.node("getplacebase", "get", var="PlaceBase")
    g.call("islast", f"{KML}:EqualEqual_IntInt", {"B": AUTHORED - 1})
    g.node("setrowbase", "branch")
    g.node("rowbase", "set", var="RowBase")
    g.call("scaled", f"{KML}:Multiply_VectorFloat")
    g.call("scale", "/Script/Engine.Actor:SetActorScale3D")
    g.call("move", "/Script/Engine.Actor:K2_SetActorLocationAndRotation", {"bTeleport": "true"})
    g.node("keeprecord", "branch")
    g.node("record", "branch")
    g.node("getbases2", "get", var="FitBases")
    g.node("setbase", "array_call", function=f"{KAL}:Array_Set")
    g.node("getapplied2", "get", var="FitApplied")
    g.node("setapplied", "array_call", function=f"{KAL}:Array_Set")
    g.node("getfitp2", "get", var="FitProxies")
    g.node("addproxy", "array_call", function=f"{KAL}:Array_Add")
    g.node("getbases3", "get", var="FitBases")
    g.node("addbase", "array_call", function=f"{KAL}:Array_Add")
    g.node("getapplied3", "get", var="FitApplied")
    g.node("addapplied", "array_call", function=f"{KAL}:Array_Add")
    g.chain("entry", "isvalid")
    g.chain("isvalid", "setplacebase", "setrowbase")
    g.chain("setrowbase", "rowbase", "scale")
    g.chain("setrowbase.else", "scale")
    g.chain("scale", "move", "keeprecord")
    g.chain("keeprecord", "record")
    g.chain("record", "setbase", "setapplied")
    g.chain("record.else", "addproxy", "addbase", "addapplied")
    g.wire(("getlocs.AuthLocs", "a0.TargetArray"), ("getlocs.AuthLocs", "a3.TargetArray"),
           ("a0.Item", "ends.A"), ("a3.Item", "ends.B"), ("ends.ReturnValue", "centre.A"),
           ("a3.Item", "span.A"), ("a0.Item", "span.B"), ("span.ReturnValue", "step.A"),
           ("getused.Shown", "usedf.InInt"), ("usedf.ReturnValue", "last.A"), ("last.ReturnValue", "mid.A"),
           ("entry.Index", "indexf.InInt"), ("indexf.ReturnValue", "rel.A"), ("mid.ReturnValue", "rel.B"),
           ("rel.ReturnValue", "offset.A"), ("step.ReturnValue", "shift.A"),
           ("offset.ReturnValue", "shift.B"), ("centre.ReturnValue", "where.A"), ("shift.ReturnValue", "where.B"),
           ("offset.ReturnValue", "along.A"), ("along.ReturnValue", "round.A"),
           ("round.ReturnValue", "nearest.Value"), ("getrots.AuthRots", "rot.TargetArray"),
           ("nearest.ReturnValue", "rot.Index"),
           ("getproxies.Proxies", "proxy.TargetArray"), ("entry.Index", "proxy.Index"),
           ("proxy.Item", "valid.Object"),
           ("getfilled.Filled", "insquad.TargetArray"), ("entry.Index", "insquad.Index"),
           ("proxy.Item", "gethidden.self"),
           ("gethidden.bHidden", "shownnow.A"), ("insquad.Item", "wanted.A"), ("shownnow.ReturnValue", "wanted.B"),
           ("valid.ReturnValue", "go.A"), ("wanted.ReturnValue", "go.B"), ("go.ReturnValue", "isvalid.Condition"),
           ("getfitp.FitProxies", "find.TargetArray"), ("proxy.Item", "find.ItemToFind"),
           ("find.ReturnValue", "known.A"), ("proxy.Item", "live.self"),
           ("getapplied.FitApplied", "applied.TargetArray"), ("find.ReturnValue", "applied.Index"),
           ("live.ReturnValue", "same.A"), ("applied.Item", "same.B"),
           ("known.ReturnValue", "ours.A"), ("same.ReturnValue", "ours.B"),
           ("getbases.FitBases", "base.TargetArray"), ("find.ReturnValue", "base.Index"),
           ("entry.Index", "authoredidx.A"),
           # fresh: an authored slot reads its live scale; an overflow one takes slot four's base from this pass
           # (the Blueprint never scales an overflow proxy; recording one once kept a zero scale for good)
           ("live.ReturnValue", "fresh.A"), ("getrowbase.RowBase", "fresh.B"),
           ("authoredidx.ReturnValue", "fresh.bPickA"),
           # chosen: an authored proxy still carrying our last write -> its recorded base, else fresh
           ("ours.ReturnValue", "oursauthored.A"), ("authoredidx.ReturnValue", "oursauthored.B"),
           ("base.Item", "chosen.A"), ("fresh.ReturnValue", "chosen.B"), ("oursauthored.ReturnValue", "chosen.bPickA"),
           ("chosen.ReturnValue", "setplacebase.PlaceBase"),
           ("entry.Index", "islast.A"), ("islast.ReturnValue", "setrowbase.Condition"),
           ("getplacebase.PlaceBase", "rowbase.RowBase"),
           ("getplacebase.PlaceBase", "scaled.A"), ("getfit.Fit", "scaled.B"),
           ("proxy.Item", "scale.self"), ("scaled.ReturnValue", "scale.NewScale3D"),
           ("proxy.Item", "move.self"), ("where.ReturnValue", "move.NewLocation"), ("rot.Item", "move.NewRotation"),
           ("known.ReturnValue", "record.Condition"),
           ("authoredidx.ReturnValue", "keeprecord.Condition"),
           ("getbases2.FitBases", "setbase.TargetArray"), ("find.ReturnValue", "setbase.Index"),
           ("getplacebase.PlaceBase", "setbase.Item"),
           ("getapplied2.FitApplied", "setapplied.TargetArray"), ("find.ReturnValue", "setapplied.Index"),
           ("scaled.ReturnValue", "setapplied.Item"),
           ("getfitp2.FitProxies", "addproxy.TargetArray"), ("proxy.Item", "addproxy.NewItem"),
           ("getbases3.FitBases", "addbase.TargetArray"), ("getplacebase.PlaceBase", "addbase.NewItem"),
           ("getapplied3.FitApplied", "addapplied.TargetArray"), ("scaled.ReturnValue", "addapplied.NewItem"))
    return {"name": "PlaceProxy", "inputs": [{"name": "Index", "type": "int"}], "outputs": [], **g.spec()}


def restore_scales():
    """RestoreScales: with four or fewer plates, a proxy still carrying the fit's scale gets its base back and, while it
    hangs in a diorama slot, the slot's own place: the slot attaches it snapped (relative zero) and never moves it again,
    so a model the fit had moved stayed on the squeezed row next to the wrong name (in game, 2026-11-06)."""
    g = Graph()
    g.node("getfitp", "get", var="FitProxies")
    g.node("loop", "macro", macro="ForEachLoop")
    g.call("valid", f"{KSL}:IsValid")
    g.call("live", "/Script/Engine.Actor:GetActorScale3D")
    g.node("getapplied", "get", var="FitApplied")
    g.node("applied", "array_call", function=f"{KAL}:Array_Get")
    g.call("same", f"{KML}:EqualEqual_VectorVector", {"ErrorTolerance": 0.001})
    g.call("both", f"{KML}:BooleanAND")
    g.node("ours", "branch")
    g.node("getbases", "get", var="FitBases")
    g.node("base", "array_call", function=f"{KAL}:Array_Get")
    g.call("scale", "/Script/Engine.Actor:SetActorScale3D")
    g.node("getapplied2", "get", var="FitApplied")
    g.node("forget", "array_call", function=f"{KAL}:Array_Set")
    g.call("parent", f"{ACTOR}:GetAttachParentActor")
    g.call("hasparent", f"{KSL}:IsValid")
    g.node("attached", "branch")
    g.call("relloc", f"{ACTOR}:K2_SetActorRelativeLocation", {"bTeleport": "true"})
    g.call("relrot", f"{ACTOR}:K2_SetActorRelativeRotation", {"bTeleport": "true"})
    g.chain("entry", "loop.Exec")
    g.chain("loop.LoopBody", "ours")
    g.chain("ours", "scale", "forget", "attached")
    g.chain("attached", "relloc", "relrot")
    g.wire(("getfitp.FitProxies", "loop.Array"), ("loop.Array Element", "valid.Object"),
           ("loop.Array Element", "live.self"), ("getapplied.FitApplied", "applied.TargetArray"),
           ("loop.Array Index", "applied.Index"), ("live.ReturnValue", "same.A"), ("applied.Item", "same.B"),
           ("valid.ReturnValue", "both.A"), ("same.ReturnValue", "both.B"), ("both.ReturnValue", "ours.Condition"),
           ("getbases.FitBases", "base.TargetArray"), ("loop.Array Index", "base.Index"),
           ("loop.Array Element", "scale.self"), ("base.Item", "scale.NewScale3D"),
           # Applied is set to the base too, so the next pass sees the actor as ours at its base and leaves it.
           ("getapplied2.FitApplied", "forget.TargetArray"), ("loop.Array Index", "forget.Index"),
           ("base.Item", "forget.Item"),
           ("loop.Array Element", "parent.self"), ("parent.ReturnValue", "hasparent.Object"),
           ("hasparent.ReturnValue", "attached.Condition"),
           ("loop.Array Element", "relloc.self"), ("loop.Array Element", "relrot.self"))
    return {"name": "RestoreScales", "inputs": [], "outputs": [], **g.spec()}


def fit_lineup():
    """FitLineup: Used from the activity slots and Shown from the nameplates, the authored layout once, then the fitted
    row of Shown (or restored scales and places)."""
    g = Graph()
    g.call("count", "self:CountUsed")
    g.call("shown", "self:CountShown")
    g.node("getshown", "get", var="Shown")
    g.node("getcaptured", "get", var="Captured")
    g.node("hascapture", "branch")
    g.call("capture", "self:CaptureLayout")
    g.node("getcaptured2", "get", var="Captured")
    g.node("getused", "get", var="Used")
    g.call("wide", f"{KML}:Greater_IntInt", {"B": AUTHORED})
    g.call("ready", f"{KML}:BooleanAND")
    g.node("dofit", "branch")
    g.call("usedf", f"{KML}:Conv_IntToDouble")
    g.call("gaps", f"{KML}:Subtract_DoubleDouble", {"B": 1})
    g.call("fit", f"{KML}:Divide_DoubleDouble", {"A": AUTHORED - 1})
    g.node("setfit", "set", var="Fit")
    # Through Used - 1, or Used while the picker is open (its preview slot), within the pool.
    g.call("previewing", f"{KML}:SelectInt", {"A": 0, "B": -1})
    g.call("lastwanted", f"{KML}:Add_IntInt")
    g.node("getproxies3", "get", var="Proxies")
    g.node("len3", "array_call", function=f"{KAL}:Array_Length")
    g.call("lastpool", f"{KML}:Subtract_IntInt", {"B": 1})
    g.call("lastindex", f"{KML}:Min")
    g.node("loop", "macro", macro="ForLoop", defaults={"FirstIndex": 0})
    g.call("place", "self:PlaceProxy")
    g.node("getfits", "get", var="LineupFits")
    g.call("addfits", f"{KML}:Add_IntInt", {"B": 1})
    g.node("setfits", "set", var="LineupFits")
    g.call("restore", "self:RestoreScales")
    # Overflow proxies of empty slots: hidden and parked once the squad has settled with the picker closed (see the
    # module docstring).
    g.node("getproxies2", "get", var="Proxies")
    g.node("len", "array_call", function=f"{KAL}:Array_Length")
    g.call("lasthide", f"{KML}:Subtract_IntInt", {"B": 1})
    g.call("picker", "self:PickerOpen")
    g.node("getlast", "get", var="LastUsed")
    g.call("changed", f"{KML}:NotEqual_IntInt")
    g.call("unsettled", f"{KML}:BooleanOR")
    g.node("restart", "branch")
    g.node("setsettlezero", "set", var="Settle", defaults={"Settle": 0})
    g.node("getsettle", "get", var="Settle")
    g.call("addsettle", f"{KML}:Add_IntInt", {"B": 1})
    g.node("setsettle", "set", var="Settle")
    g.node("setlast", "set", var="LastUsed")
    g.node("getsettle2", "get", var="Settle")
    g.call("settled", f"{KML}:GreaterEqual_IntInt", {"B": SETTLE_PASSES})
    g.node("dropped", "branch")
    g.node("hideloop", "macro", macro="ForLoop", defaults={"FirstIndex": AUTHORED})
    g.node("getfilled", "get", var="Filled")
    g.node("slotfilled", "array_call", function=f"{KAL}:Array_Get")
    g.call("empty", f"{KML}:Not_PreBool")
    g.call("tohide", f"{KML}:BooleanAND")
    g.node("extra", "array_call", function=f"{KAL}:Array_Get")
    g.call("valid", f"{KSL}:IsValid")
    g.node("isvalid", "branch")
    g.call("hide", "/Script/Engine.Actor:SetActorHiddenInGame", {"bNewHidden": "true"})
    g.call("park", f"{ACTOR}:K2_SetActorLocation", {"bTeleport": "true"})
    g.chain("entry", "count", "shown", "picker", "hascapture")
    g.chain("hascapture.else", "capture", "dofit")
    g.chain("hascapture", "dofit")
    g.chain("dofit", "setfit", "loop.execute")
    g.chain("loop.LoopBody", "place")
    g.chain("loop.Completed", "setfits", "restart")
    g.chain("dofit.else", "restore", "restart")
    g.chain("restart", "setsettlezero", "setlast")
    g.chain("restart.else", "setsettle", "setlast")
    g.chain("setlast", "dropped")
    g.chain("dropped", "hideloop.execute")
    g.chain("hideloop.LoopBody", "isvalid")
    g.chain("isvalid", "hide", "park")
    g.wire(("getcaptured.Captured", "hascapture.Condition"), ("getshown.Shown", "wide.A"),
           ("getcaptured2.Captured", "ready.A"), ("wide.ReturnValue", "ready.B"), ("ready.ReturnValue", "dofit.Condition"),
           ("getshown.Shown", "usedf.InInt"), ("usedf.ReturnValue", "gaps.A"), ("gaps.ReturnValue", "fit.B"),
           ("fit.ReturnValue", "setfit.Fit"), ("picker.Open", "previewing.bPickA"), ("getused.Used", "lastwanted.A"),
           ("previewing.ReturnValue", "lastwanted.B"), ("getproxies3.Proxies", "len3.TargetArray"),
           ("len3.ReturnValue", "lastpool.A"), ("lastwanted.ReturnValue", "lastindex.A"),
           ("lastpool.ReturnValue", "lastindex.B"), ("lastindex.ReturnValue", "loop.LastIndex"),
           ("loop.Index", "place.Index"), ("getfits.LineupFits", "addfits.A"), ("addfits.ReturnValue", "setfits.LineupFits"),
           ("getproxies2.Proxies", "len.TargetArray"), ("len.ReturnValue", "lasthide.A"),
           ("getused.Used", "changed.A"), ("getlast.LastUsed", "changed.B"),
           ("picker.Open", "unsettled.A"), ("changed.ReturnValue", "unsettled.B"),
           ("unsettled.ReturnValue", "restart.Condition"),
           ("getsettle.Settle", "addsettle.A"), ("addsettle.ReturnValue", "setsettle.Settle"),
           ("getused.Used", "setlast.LastUsed"),
           ("getsettle2.Settle", "settled.A"), ("settled.ReturnValue", "dropped.Condition"),
           ("lasthide.ReturnValue", "hideloop.LastIndex"), ("getproxies2.Proxies", "extra.TargetArray"),
           ("hideloop.Index", "extra.Index"), ("extra.Item", "valid.Object"),
           ("getfilled.Filled", "slotfilled.TargetArray"), ("hideloop.Index", "slotfilled.Index"),
           ("slotfilled.Item", "empty.A"), ("valid.ReturnValue", "tohide.A"), ("empty.ReturnValue", "tohide.B"),
           ("tohide.ReturnValue", "isvalid.Condition"),
           ("extra.Item", "hide.self"), ("extra.Item", "park.self"))
    return {"name": "FitLineup", "inputs": [], "outputs": [], **g.spec()}


def functions():
    return [load_classes(), find_manager(), ensure_pool(), screen_open(), pad_nameplates(), count_used(), count_shown(),
            picker_open(), capture_layout(),
            place_proxy(), restore_scales(), fit_lineup()]
