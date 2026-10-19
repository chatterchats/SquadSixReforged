"""The holotable's mission panel at six, for BP_SquadSixBrain (Reforged's holotable.lua without hooks, on the Lineup tick).

WBP_GalaxyMap_LocationInfoPanel shows a mission's squad as "4" in OperatorCount and four icons in RequiredUnitList, both
from the mission's MinSquadSize, so a maximum of six never shows. Reforged writes "4 - 6" and adds an icon for each
optional operator, tinted. Neither widget can be reached by variable without the panel's class (which the kit editor
can't load), so they are found through the widget tree: the panel's ViewButton (a WBP_BoundActionButton) sits in
VerticalBox_0, which holds Oeprativestooltip > HorizontalBox_1 > OperatorCount and RequiredUnitList (read from the
cooked widget tree, 2026-10-18). GetParent and GetAllChildren are Blueprint-callable, and both widgets are native.

Only a mission's row is changed: for a mission the Blueprint writes the minimum into OperatorCount, while an operation
writes its own text. Fewer icons than the minimum means the Blueprint hasn't built the row yet; a later tick does it.
Icons this module tinted are restored when they come back as required ones (the entry box pools its widgets).
"""
from gf_graph import Graph, KSL, KML, KAL
from gf_lineup import load_class, USER_WIDGET, MISSION_VM, ASSIGNMENT

PANEL_CLASS_PATH = ("/Game/Game/UI/Strategy/GalaxyMap/Widgets/WBP_GalaxyMap_LocationInfoPanel."
                    "WBP_GalaxyMap_LocationInfoPanel_C")
BUTTON_CLASS_PATH = "/Game/Game/UI/Common/Buttons/WBP_BoundActionButton.WBP_BoundActionButton_C"
PANEL = "/Script/UMG.PanelWidget"
WIDGET = "/Script/UMG.Widget"
RICH_TEXT = "/Script/UMG.RichTextBlock"
ENTRY_BOX = "/Script/UMG.DynamicEntryBox"
KSTR = "/Script/Engine.KismetStringLibrary"
KTEXT = "/Script/Engine.KismetTextLibrary"
# Widget names along the path from ViewButton's parent.
PATH = ("Oeprativestooltip", "HorizontalBox_1")
# The holotable's own accent orange, as on the Critical Mission tag (Reforged's EXTRA_ICON_COLOR).
EXTRA_ICON = (0.95, 0.6, 0.2, 1.0)
PLAIN_ICON = (1.0, 1.0, 1.0, 1.0)


def variables():
    return [
        {"name": "PanelClass", "type": f"class:{USER_WIDGET}"},
        {"name": "ButtonClass", "type": f"class:{USER_WIDGET}"},
        {"name": "FoundChild", "type": f"object:{WIDGET}"},
        {"name": "HoloText", "type": f"object:{RICH_TEXT}"},
        {"name": "HoloList", "type": f"object:{ENTRY_BOX}"},
        {"name": "HoloMin", "type": "int"},
        {"name": "HoloMax", "type": "int"},
        {"name": "HoloCount", "type": "int"},
        {"name": "Tinted", "type": f"object:{USER_WIDGET}[]"},
        {"name": "HoloRanges", "type": "int", "default": "0"},
    ]


def load_holo_classes():
    """LoadHoloClasses: the info panel and ViewButton classes, once."""
    g = Graph()
    g.node("getpanel", "get", var="PanelClass")
    g.call("havepanel", f"{KSL}:IsValidClass")
    g.node("needpanel", "branch")
    load1, cast1, set1 = load_class(g, "p", PANEL_CLASS_PATH, "PanelClass", USER_WIDGET)
    g.node("getbutton", "get", var="ButtonClass")
    g.call("havebutton", f"{KSL}:IsValidClass")
    g.node("needbutton", "branch")
    load2, cast2, set2 = load_class(g, "b", BUTTON_CLASS_PATH, "ButtonClass", USER_WIDGET)
    g.chain("entry", "needpanel")
    g.chain("needpanel.else", load1, cast1)
    g.chain(cast1, set1, "needbutton")
    g.chain("needpanel", "needbutton")
    g.chain("needbutton.else", load2, cast2)
    g.chain(cast2, set2)
    g.wire(("getpanel.PanelClass", "havepanel.Class"), ("havepanel.ReturnValue", "needpanel.Condition"),
           ("pcast.AsUser Widget", "pset.PanelClass"),
           ("getbutton.ButtonClass", "havebutton.Class"), ("havebutton.ReturnValue", "needbutton.Condition"),
           ("bcast.AsUser Widget", "bset.ButtonClass"))
    return {"name": "LoadHoloClasses", "inputs": [], "outputs": [], **g.spec()}


def find_child():
    """FindChild(Panel, Name) -> Child: Panel's direct child with that object name, or none."""
    g = Graph()
    g.node("clear", "set", var="FoundChild")
    g.call("valid", f"{KSL}:IsValid")
    g.node("haspanel", "branch")
    g.call("children", f"{PANEL}:GetAllChildren")
    g.node("loop", "macro", macro="ForEachLoop")
    g.call("name", f"{KSL}:GetObjectName")
    g.call("same", f"{KSTR}:EqualEqual_StrStr")
    g.node("match", "branch")
    g.node("setfound", "set", var="FoundChild")
    g.node("getfound", "get", var="FoundChild")
    g.chain("entry", "clear", "haspanel")
    g.chain("haspanel", "loop.Exec")
    g.chain("haspanel.else", "result")
    g.chain("loop.LoopBody", "match")
    g.chain("match", "setfound")
    g.chain("loop.Completed", "result")
    g.wire(("entry.Panel", "valid.Object"), ("valid.ReturnValue", "haspanel.Condition"),
           ("entry.Panel", "children.self"), ("children.ReturnValue", "loop.Array"),
           ("loop.Array Element", "name.Object"), ("name.ReturnValue", "same.A"), ("entry.Name", "same.B"),
           ("same.ReturnValue", "match.Condition"), ("loop.Array Element", "setfound.FoundChild"),
           ("getfound.FoundChild", "result.Child"))
    return {"name": "FindChild", "inputs": [{"name": "Panel", "type": f"object:{PANEL}"},
                                            {"name": "Name", "type": "string"}],
            "outputs": [{"name": "Child", "type": f"object:{WIDGET}"}], **g.spec()}


def find_row():
    """FindRow: HoloText and HoloList from a ViewButton whose parent holds the operator row."""
    g = Graph()
    g.node("cleartext", "set", var="HoloText")
    g.node("clearlist", "set", var="HoloList")
    g.node("getbutton", "get", var="ButtonClass")
    g.call("buttons", "/Script/UMG.WidgetBlueprintLibrary:GetAllWidgetsOfClass", {"TopLevelOnly": "false"})
    g.node("loop", "macro", macro="ForEachLoop")
    g.call("name", f"{KSL}:GetObjectName")
    g.call("isview", f"{KSTR}:EqualEqual_StrStr", {"B": "ViewButton"})
    g.node("view", "branch")
    g.call("parent", f"{WIDGET}:GetParent")
    g.call("step1", "self:FindChild", {"Name": PATH[0]})
    g.node("panel1", "cast", **{"class": PANEL})
    g.call("step2", "self:FindChild", {"Name": PATH[1]})
    g.node("panel2", "cast", **{"class": PANEL})
    g.call("text", "self:FindChild", {"Name": "OperatorCount"})
    g.node("textcast", "cast", **{"class": RICH_TEXT})
    g.call("list", "self:FindChild", {"Name": "RequiredUnitList"})
    g.node("listcast", "cast", **{"class": ENTRY_BOX})
    g.node("settext", "set", var="HoloText")
    g.node("setlist", "set", var="HoloList")
    g.chain("entry", "cleartext", "clearlist", "buttons", "loop.Exec")
    g.chain("loop.LoopBody", "view")
    g.chain("view", "step1", "panel1")
    g.chain("panel1", "step2", "panel2")
    g.chain("panel2", "text", "textcast")
    g.chain("textcast", "list", "listcast")
    g.chain("listcast", "settext", "setlist")
    g.wire(("getbutton.ButtonClass", "buttons.WidgetClass"), ("buttons.FoundWidgets", "loop.Array"),
           ("loop.Array Element", "name.Object"), ("name.ReturnValue", "isview.A"),
           ("isview.ReturnValue", "view.Condition"), ("loop.Array Element", "parent.self"),
           ("parent.ReturnValue", "step1.Panel"), ("step1.Child", "panel1.Object"),
           ("panel1.AsPanel Widget", "step2.Panel"), ("step2.Child", "panel2.Object"),
           ("panel2.AsPanel Widget", "text.Panel"), ("text.Child", "textcast.Object"),
           ("panel2.AsPanel Widget", "list.Panel"), ("list.Child", "listcast.Object"),
           ("textcast.AsRich Text Block", "settext.HoloText"), ("listcast.AsDynamic Entry Box", "setlist.HoloList"))
    return {"name": "FindRow", "inputs": [], "outputs": [], **g.spec()}


def tint_icons():
    """TintIcons(Extra): with Extra, the row's icons past HoloMin are tinted; any other icon this module tinted is
    restored."""
    g = Graph()
    g.node("getlist", "get", var="HoloList")
    g.call("entries", "/Script/UMG.DynamicEntryBoxBase:GetAllEntries")
    g.node("loop", "macro", macro="ForEachLoop")
    g.node("getmin", "get", var="HoloMin")
    g.call("past", f"{KML}:GreaterEqual_IntInt")
    g.call("optional", f"{KML}:BooleanAND")
    g.node("isextra", "branch")
    g.call("orange", f"{KML}:MakeColor", dict(zip("RGBA", EXTRA_ICON)))
    g.call("tint", f"{USER_WIDGET}:SetColorAndOpacity")
    g.node("gettinted", "get", var="Tinted")
    g.node("remember", "array_call", function=f"{KAL}:Array_AddUnique")
    g.node("gettinted2", "get", var="Tinted")
    g.node("wastinted", "array_call", function=f"{KAL}:Array_Contains")
    g.node("restore", "branch")
    g.call("white", f"{KML}:MakeColor", dict(zip("RGBA", PLAIN_ICON)))
    g.call("untint", f"{USER_WIDGET}:SetColorAndOpacity")
    g.node("gettinted3", "get", var="Tinted")
    g.node("forget", "array_call", function=f"{KAL}:Array_RemoveItem")
    g.chain("entry", "loop.Exec")
    g.chain("loop.LoopBody", "isextra")
    g.chain("isextra", "tint", "remember")
    g.chain("isextra.else", "restore")
    g.chain("restore", "untint", "forget")
    g.wire(("getlist.HoloList", "entries.self"), ("entries.ReturnValue", "loop.Array"),
           ("loop.Array Index", "past.A"), ("getmin.HoloMin", "past.B"),
           ("entry.Extra", "optional.A"), ("past.ReturnValue", "optional.B"), ("optional.ReturnValue", "isextra.Condition"),
           ("loop.Array Element", "tint.self"), ("orange.ReturnValue", "tint.InColorAndOpacity"),
           ("gettinted.Tinted", "remember.TargetArray"), ("loop.Array Element", "remember.NewItem"),
           ("gettinted2.Tinted", "wastinted.TargetArray"), ("loop.Array Element", "wastinted.ItemToFind"),
           ("wastinted.ReturnValue", "restore.Condition"),
           ("loop.Array Element", "untint.self"), ("white.ReturnValue", "untint.InColorAndOpacity"),
           ("gettinted3.Tinted", "forget.TargetArray"), ("loop.Array Element", "forget.Item"))
    return {"name": "TintIcons", "inputs": [{"name": "Extra", "type": "bool"}], "outputs": [], **g.spec()}


def show_range():
    """ShowRange(Panel): the mission's MinSquadSize - MaxSquadSize in the row, with an icon per operator."""
    g = Graph()
    g.node("assignment", "make_struct", struct=ASSIGNMENT,
           defaults={"ViewModelClass": MISSION_VM, "ViewModelName": "Default"})
    g.call("getvm", "/Script/MDViewModel.MDViewModelFunctionLibrary:BP_GetViewModel")
    g.node("mission", "cast", **{"class": MISSION_VM})
    g.node("getmin", "get", var=f"{MISSION_VM}:MinSquadSize")
    g.node("getmax", "get", var=f"{MISSION_VM}:MaxSquadSize")
    g.node("setmin", "set", var="HoloMin")
    g.node("setmax", "set", var="HoloMax")
    g.call("row", "self:FindRow")
    g.node("gettext", "get", var="HoloText")
    g.call("hastext", f"{KSL}:IsValid")
    g.node("getlist", "get", var="HoloList")
    g.call("haslist", f"{KSL}:IsValid")
    g.call("haveboth", f"{KML}:BooleanAND")
    g.node("found", "branch")
    # The row's text, the minimum as text, and the range.
    g.call("shown", f"{RICH_TEXT}:GetText")
    g.call("shownstr", f"{KTEXT}:Conv_TextToString")
    g.node("getmin2", "get", var="HoloMin")
    g.node("getmax2", "get", var="HoloMax")
    g.call("minstr", f"{KSTR}:Conv_IntToString")
    g.call("maxstr", f"{KSTR}:Conv_IntToString")
    g.call("dash", f"{KSTR}:Concat_StrStr", {"B": " - "})
    g.call("range", f"{KSTR}:Concat_StrStr")
    g.call("isminimum", f"{KSTR}:EqualEqual_StrStr")
    g.call("isrange", f"{KSTR}:EqualEqual_StrStr")
    g.call("ismission", f"{KML}:BooleanOR")
    g.call("wider", f"{KML}:Greater_IntInt")
    g.call("worth", f"{KML}:BooleanAND")
    g.node("dorange", "branch")
    # Icons: at least the minimum built by the Blueprint, then one per optional operator.
    g.call("entries", "/Script/UMG.DynamicEntryBoxBase:GetAllEntries")
    g.node("count", "array_call", function=f"{KAL}:Array_Length")
    g.node("setcount", "set", var="HoloCount")
    g.node("getcount", "get", var="HoloCount")
    g.call("built", f"{KML}:GreaterEqual_IntInt")
    g.node("isbuilt", "branch")
    g.node("addloop", "macro", macro="ForLoop")
    g.call("first", f"{KML}:Add_IntInt", {"B": 1})
    g.call("create", f"{ENTRY_BOX}:BP_CreateEntry")
    g.call("tint", "self:TintIcons", {"Extra": "true"})
    g.call("same", f"{KSTR}:EqualEqual_StrStr")
    g.node("needtext", "branch")
    g.call("totext", f"{KTEXT}:Conv_StringToText")
    g.call("settextvalue", f"{RICH_TEXT}:SetText")
    g.node("getranges", "get", var="HoloRanges")
    g.call("addranges", f"{KML}:Add_IntInt", {"B": 1})
    g.node("setranges", "set", var="HoloRanges")
    g.call("untint", "self:TintIcons", {"Extra": "false"})
    g.chain("entry", "getvm", "mission")
    g.chain("mission", "setmin", "setmax", "row", "found")
    g.chain("found", "dorange")
    g.chain("dorange", "setcount", "isbuilt")
    g.chain("isbuilt", "addloop.execute")
    g.chain("addloop.LoopBody", "create")
    g.chain("addloop.Completed", "tint", "needtext")
    g.chain("needtext.else", "settextvalue", "setranges")
    g.chain("dorange.else", "untint")
    cast = "mission.AsBruno Mission View Model"
    g.wire(("entry.Panel", "getvm.Object"), ("assignment.MDViewModelAssignmentReference", "getvm.Assignment"),
           ("getvm.ReturnValue", "mission.Object"), (cast, "getmin.self"), (cast, "getmax.self"),
           ("getmin.MinSquadSize", "setmin.HoloMin"), ("getmax.MaxSquadSize", "setmax.HoloMax"),
           ("gettext.HoloText", "hastext.Object"), ("getlist.HoloList", "haslist.Object"),
           ("hastext.ReturnValue", "haveboth.A"), ("haslist.ReturnValue", "haveboth.B"),
           ("haveboth.ReturnValue", "found.Condition"),
           ("gettext.HoloText", "shown.self"), ("shown.ReturnValue", "shownstr.InText"),
           ("getmin2.HoloMin", "minstr.InInt"), ("getmax2.HoloMax", "maxstr.InInt"),
           ("minstr.ReturnValue", "dash.A"), ("dash.ReturnValue", "range.A"), ("maxstr.ReturnValue", "range.B"),
           ("shownstr.ReturnValue", "isminimum.A"), ("minstr.ReturnValue", "isminimum.B"),
           ("shownstr.ReturnValue", "isrange.A"), ("range.ReturnValue", "isrange.B"),
           ("isminimum.ReturnValue", "ismission.A"), ("isrange.ReturnValue", "ismission.B"),
           ("getmax2.HoloMax", "wider.A"), ("getmin2.HoloMin", "wider.B"),
           ("ismission.ReturnValue", "worth.A"), ("wider.ReturnValue", "worth.B"), ("worth.ReturnValue", "dorange.Condition"),
           ("getlist.HoloList", "entries.self"), ("entries.ReturnValue", "count.TargetArray"),
           ("count.ReturnValue", "setcount.HoloCount"), ("getcount.HoloCount", "built.A"), ("getmin2.HoloMin", "built.B"),
           ("built.ReturnValue", "isbuilt.Condition"),
           ("getcount.HoloCount", "first.A"), ("first.ReturnValue", "addloop.FirstIndex"),
           ("getmax2.HoloMax", "addloop.LastIndex"), ("getlist.HoloList", "create.self"),
           ("shownstr.ReturnValue", "same.A"), ("range.ReturnValue", "same.B"), ("same.ReturnValue", "needtext.Condition"),
           ("range.ReturnValue", "totext.InString"), ("gettext.HoloText", "settextvalue.self"),
           ("totext.ReturnValue", "settextvalue.InText"),
           ("getranges.HoloRanges", "addranges.A"), ("addranges.ReturnValue", "setranges.HoloRanges"))
    return {"name": "ShowRange", "inputs": [{"name": "Panel", "type": f"object:{USER_WIDGET}"}], "outputs": [],
            **g.spec()}


def holotable():
    """Holotable: ShowRange for each visible location info panel."""
    g = Graph()
    g.call("classes", "self:LoadHoloClasses")
    g.node("getpanel", "get", var="PanelClass")
    g.call("panels", "/Script/UMG.WidgetBlueprintLibrary:GetAllWidgetsOfClass", {"TopLevelOnly": "false"})
    g.node("loop", "macro", macro="ForEachLoop")
    g.call("visible", f"{WIDGET}:IsVisible")
    g.node("isvisible", "branch")
    g.call("show", "self:ShowRange")
    g.chain("entry", "classes", "panels", "loop.Exec")
    g.chain("loop.LoopBody", "isvisible")
    g.chain("isvisible", "show")
    g.wire(("getpanel.PanelClass", "panels.WidgetClass"), ("panels.FoundWidgets", "loop.Array"),
           ("loop.Array Element", "visible.self"), ("visible.ReturnValue", "isvisible.Condition"),
           ("loop.Array Element", "show.Panel"))
    return {"name": "Holotable", "inputs": [], "outputs": [], **g.spec()}


def functions():
    return [load_holo_classes(), find_child(), find_row(), tint_icons(), show_range(), holotable()]
