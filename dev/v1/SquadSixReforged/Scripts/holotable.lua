-- The holotable's mission panel: show the squad range ("4 - 6 OPERATORS") and an icon for each
-- optional operator, tinted, after the required ones.
-- Why each rule exists, with the reports behind it: docs/runtime-notes.md.
local Common = require("common")
local log = Common.log
local unwrap = Common.unwrap
local valid = Common.valid
local full_name = Common.full_name
local object_key = Common.object_key
local array_count = Common.array_count

local PANEL_CLASS = "/Game/Game/UI/Strategy/GalaxyMap/Widgets/WBP_GalaxyMap_LocationInfoPanel"
    .. ".WBP_GalaxyMap_LocationInfoPanel_C"
local EVENT_PREFIX = PANEL_CLASS .. ":BndEvt__WBP_GalaxyMap_LocationInfoPanel_"
-- Every panel event after which the Blueprint may have rebuilt the mission's operator row. The
-- row shows the mission's MinSquadSize, so the Core pak's maximum of six never reaches it.
-- The panel's mission view model being replaced; its parameters are the old and the new one.
local CHANGED_EVENT = EVENT_PREFIX .. "BrunoMissionViewModel_MDVMNode_ViewModelChanged_2_Changed"
local PANEL_EVENTS = {
    EVENT_PREFIX .. "BrunoMissionViewModel_MDVMNode_ViewModelFieldNotify_5_MinSquadSize",
    CHANGED_EVENT,
    EVENT_PREFIX .. "VM_CurrentActivity_C_MDVMNode_ViewModelFieldNotify_22_CurrentMissionVM",
    -- Switches the panel between mission and operation; for a mission it resets the row.
    PANEL_CLASS .. ":SetupTypeState",
}
local CURRENT_ACTIVITY_CLASS = "VM_CurrentActivity_C"
local CURRENT_ACTIVITY_CLASS_PATH = "/Game/Game/UI/Strategy/_Common/BPs/VM_CurrentActivity.VM_CurrentActivity_C"
local MISSION_VM_CLASS_PATH = "/Script/Bruno.BrunoMissionViewModel"
-- The holotable's own accent orange, as on the Critical Mission tag.
local EXTRA_ICON_COLOR = {R = 0.95, G = 0.6, B = 0.2, A = 1.0}
local PLAIN_ICON_COLOR = {R = 1.0, G = 1.0, B = 1.0, A = 1.0}

local registered_events = {}
local registered_count = 0
local hooks_reported = false
local registered_notification = false
local range_reported = false
-- The first few passes that change nothing say why, so a panel still showing four can be
-- diagnosed from the log; healthy passes after the first are silent.
local MAX_SKIP_REPORTS = 8
local skip_reports = 0
local skip_reasons = {}
local fired_events = {}
-- Icons this module tinted, by object key. The entry box pools its widgets, so a tinted icon can
-- come back as a required one, or in an operation's row, and is then restored.
local tinted_icons = {}

local function report_skip(reason)
    if range_reported or skip_reasons[reason] or skip_reports >= MAX_SKIP_REPORTS then return end
    skip_reasons[reason] = true
    skip_reports = skip_reports + 1
    log("holotable_skip reason=" .. reason)
end

local function property(owner, name)
    local ok, value = pcall(function() return unwrap(owner:GetPropertyValue(name)) end)
    if ok then return value end
    return nil
end

local function limits_of(mission)
    if not valid(mission) then return nil end
    local minimum = property(mission, "MinSquadSize")
    local maximum = property(mission, "MaxSquadSize")
    if type(minimum) == "number" and type(maximum) == "number" then return minimum, maximum end
    return nil
end

-- The mission view model the panel last bound, from its Changed event. Once that event has
-- handed one over, it is the only source: no object scan is needed.
local bound_mission = nil
local bound_from_event = false

local function note_bound_mission(new_view_model)
    local mission = unwrap(new_view_model)
    if limits_of(mission) ~= nil then
        bound_mission = mission
        if not bound_from_event then
            bound_from_event = true
            log("holotable_vm_source=event")
        end
    elseif bound_from_event then
        bound_mission = nil
    end
end

-- The fallback: the current-activity view model the panel follows. UE4SS can't use the engine's
-- object hash tables in this game, so FindAllOf walks every object (a few hundred milliseconds
-- each); the result is kept, and a failed search isn't repeated for a few seconds.
local SCAN_RETRY_SECONDS = 3
local current_activity = nil
local next_scan_at = 0
local scan_reported = false

local function find_current_activity()
    if valid(current_activity) then return current_activity end
    current_activity = nil
    if os.time() < next_scan_at then return nil end
    next_scan_at = os.time() + SCAN_RETRY_SECONDS
    local activities = FindAllOf(CURRENT_ACTIVITY_CLASS)
    if activities == nil then return nil end
    for _, activity in pairs(activities) do
        activity = unwrap(activity)
        if valid(activity) and not string.find(full_name(activity), "Default__", 1, true) then
            current_activity = activity
            if not scan_reported then
                scan_reported = true
                log("holotable_vm_source=scan")
            end
            return activity
        end
    end
    return nil
end

-- The selected mission's squad limits.
local function mission_limits()
    if bound_from_event then return limits_of(bound_mission) end
    local activity = find_current_activity()
    if activity == nil then return nil end
    return limits_of(property(activity, "CurrentMissionVM"))
end

local function shown_text(text_block)
    local ok, text = pcall(function() return text_block:GetText():ToString() end)
    if ok and type(text) == "string" then return text end
    return nil
end

-- The row's icons in order, or nil and why not. UE4SS returns a called function's TArray as a
-- plain Lua table, which has no GetArrayNum: reading it as a TArray found no icons at all.
local function row_icons(list)
    local ok, value = pcall(function() return list:GetAllEntries() end)
    if not ok then return nil, "error:" .. tostring(value) end
    if value == nil then return nil, "nil" end
    local count = array_count(value)
    if count < 0 and type(value) == "table" then count = #value end
    if count < 0 then return nil, type(value) end
    local icons = {}
    for index = 1, count do
        local read_ok, icon = pcall(function() return unwrap(value[index]) end)
        icons[index] = read_ok and icon or false
    end
    return icons
end

-- Tints an optional operator's icon, or restores one this module tinted before. True when the
-- icon is now tinted.
local function set_extra(icon, extra)
    if not valid(icon) then return false end
    local key = object_key(icon)
    if not extra and not tinted_icons[key] then return false end
    local color = extra and EXTRA_ICON_COLOR or PLAIN_ICON_COLOR
    if not pcall(function() icon:SetColorAndOpacity(color) end) then return false end
    tinted_icons[key] = extra or nil
    return extra
end

local function restore_row(icons)
    for index = 1, #icons do set_extra(icons[index], false) end
end

local function show_range(panel)
    if not valid(panel) then return end
    local count_text = property(panel, "OperatorCount")
    local list = property(panel, "RequiredUnitList")
    if not valid(count_text) or not valid(list) then return report_skip("no_panel_widgets") end
    local icons, why = row_icons(list)
    if icons == nil then return report_skip("icons=" .. why) end

    local minimum, maximum = mission_limits()
    if minimum == nil then
        restore_row(icons)
        return report_skip("no_mission_view_model")
    end
    if maximum <= minimum then return restore_row(icons) end
    -- Only the mission row: for a mission the Blueprint writes the minimum here, while an
    -- operation uses its own text (OperatorCountText).
    local range = tostring(minimum) .. " - " .. tostring(maximum)
    local shown = shown_text(count_text)
    if shown ~= tostring(minimum) and shown ~= range then
        restore_row(icons)
        return report_skip("text=" .. tostring(shown) .. " min=" .. tostring(minimum))
    end
    -- Fewer than the minimum: the Blueprint hasn't built its row yet; a later event will.
    if #icons < minimum then
        return report_skip("icons=" .. tostring(#icons) .. " min=" .. tostring(minimum))
    end

    local added, create_error = 0, nil
    while #icons < maximum do
        local ok, icon = pcall(function() return unwrap(list:BP_CreateEntry()) end)
        if not ok or not valid(icon) then
            create_error = ok and "invalid" or tostring(icon)
            break
        end
        icons[#icons + 1] = icon
        added = added + 1
    end
    local tinted = 0
    for index = 1, #icons do
        if set_extra(icons[index], index > minimum) then tinted = tinted + 1 end
    end
    local text_ok = pcall(function() count_text:SetText(FText(range)) end)

    if not range_reported then
        range_reported = true
        log("holotable_range=" .. range .. " added_icons=" .. tostring(added)
            .. " tinted=" .. tostring(tinted) .. " text=" .. tostring(text_ok)
            .. (create_error and (" create_error=" .. create_error) or ""))
    end
end

-- Pre-hooks only (UE4SS never calls post-hooks on Blueprint functions): the deferred passes run
-- once the event has rebuilt the row, the second in case the Blueprint fills it a frame later.
-- Switching missions fires several of the events at once; they share one pass per delay.
local PASS_DELAYS_MS = {0, 250}
local pending_passes = {}

local function schedule_pass(panel, delay)
    local key = object_key(panel) .. "@" .. tostring(delay)
    if pending_passes[key] then return end
    pending_passes[key] = true
    ExecuteWithDelay(delay, function()
        ExecuteInGameThread(function()
            pending_passes[key] = nil
            show_range(panel)
        end)
    end)
end

local function panel_prehook(event)
    return function(context, _, new_view_model)
        if not fired_events[event] then
            fired_events[event] = true
            log("holotable_event=" .. (string.match(event, "[^_:]+$") or event))
        end
        -- Read now: the parameters are valid only while the hook runs.
        if event == CHANGED_EVENT then note_bound_mission(new_view_model) end
        local panel = unwrap(context)
        if not valid(panel) then return end
        for _, delay in ipairs(PASS_DELAYS_MS) do schedule_pass(panel, delay) end
    end
end

local function register_panel_hooks()
    for _, path in ipairs(PANEL_EVENTS) do
        if not registered_events[path] and valid(StaticFindObject(path)) then
            local ok, pre_id = pcall(function() return RegisterHook(path, panel_prehook(path)) end)
            if ok and pre_id ~= nil then
                registered_events[path] = true
                registered_count = registered_count + 1
            end
        end
    end
    if registered_count > 0 and not hooks_reported then
        hooks_reported = true
        log("holotable_hooks=" .. tostring(registered_count) .. "/" .. tostring(#PANEL_EVENTS))
    end
end

-- The panel's class loads with the galaxy map, so its functions only exist from then on.
local function register_panel_notification()
    if registered_notification then return end
    registered_notification = pcall(function()
        NotifyOnNewObject(PANEL_CLASS, function() register_panel_hooks() end)
    end)
end

local game_names = {
    {"property", MISSION_VM_CLASS_PATH, "MinSquadSize"},
    {"property", MISSION_VM_CLASS_PATH, "MaxSquadSize"},
    {"property", PANEL_CLASS, "OperatorCount", when = "holotable"},
    {"property", PANEL_CLASS, "RequiredUnitList", when = "holotable"},
    {"property", CURRENT_ACTIVITY_CLASS_PATH, "CurrentMissionVM", when = "holotable"},
}
for _, path in ipairs(PANEL_EVENTS) do
    game_names[#game_names + 1] = {"function", path, when = "holotable"}
end

return {
    -- Every game name this module depends on, for selfcheck.lua.
    game_names = game_names,
    PANEL_CLASS = PANEL_CLASS,
    register_panel_hooks = register_panel_hooks,
    register_panel_notification = register_panel_notification,
}
