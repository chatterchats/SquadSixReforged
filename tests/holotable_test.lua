-- The holotable's mission panel. The Blueprint shows the mission's minimum ("4") and one icon per
-- required operator; after its event the runtime shows the range ("4 - 6") and adds a tinted icon
-- for each optional operator. Running again adds nothing, a pooled icon reused as a required one
-- loses its tint, an operation's panel is left alone, and so is a mission whose minimum is its
-- maximum. The current-activity view model is found by one object scan; once the panel's Changed
-- event has handed over the mission view model, no scan is needed at all.
--   luajit tests/holotable_test.lua <Scripts dir>
local scripts = assert(arg[1], "usage: holotable_test.lua <Scripts dir>")
local here = string.match(arg[0], "^(.*[/\\])") or "./"
local mock = dofile(here .. "ue4ss_mock.lua")

local PANEL_CLASS = "/Game/Game/UI/Strategy/GalaxyMap/Widgets/WBP_GalaxyMap_LocationInfoPanel"
    .. ".WBP_GalaxyMap_LocationInfoPanel_C"
local MIN_SQUAD_EVENT = PANEL_CLASS .. ":BndEvt__WBP_GalaxyMap_LocationInfoPanel_BrunoMissionViewModel"
    .. "_MDVMNode_ViewModelFieldNotify_5_MinSquadSize"
local CHANGED_EVENT = PANEL_CLASS .. ":BndEvt__WBP_GalaxyMap_LocationInfoPanel_BrunoMissionViewModel"
    .. "_MDVMNode_ViewModelChanged_2_Changed"

mock.install({missions = {mock.mission("MM_02_010_CoilReunion", 6, 1)}})
-- UE4SS's FText: a value whose ToString gives the text back.
FText = function(text) return {ToString = function() return text end} end

local mission = mock.object("BrunoMissionViewModel Eavesdropping", {MinSquadSize = 4, MaxSquadSize = 6})
local activity = mock.object("VM_CurrentActivity_C /Engine/Transient.VM_CurrentActivity_C_0",
    {CurrentMissionVM = mission})
local find_all = FindAllOf
local scans = 0
FindAllOf = function(class)
    if class == "VM_CurrentActivity_C" then
        scans = scans + 1
        return {activity}
    end
    return find_all(class)
end

-- The panel as the Blueprint leaves it: the count text and the row of icons. GetAllEntries returns
-- a plain Lua table, as UE4SS returns a called function's TArray.
local function panel_with(count, icons)
    local entries = {}
    local shown = FText(tostring(count))
    local function icon(index)
        return mock.object("WBP_UnitRequired_C Icon" .. index, {}, {
            SetColorAndOpacity = function(self, color) rawset(self, "tint", color) end,
        })
    end
    for index = 1, icons do entries[index] = icon(index) end
    local count_text = mock.object("BitReactorRichTextBlock OperatorCount", {}, {
        GetText = function() return shown end,
        SetText = function(_, text) shown = text end,
    })
    local list = mock.object("DynamicEntryBox RequiredUnitList", {}, {
        GetAllEntries = function()
            local copy = {}
            for index, entry in ipairs(entries) do copy[index] = entry end
            return copy
        end,
        BP_CreateEntry = function()
            entries[#entries + 1] = icon(#entries + 1)
            return entries[#entries]
        end,
    })
    local panel = mock.object(PANEL_CLASS .. " Panel", {OperatorCount = count_text, RequiredUnitList = list})
    local function set_shown(text) shown = FText(tostring(text)) end
    return panel, entries, function() return shown:ToString() end, set_shown
end

local function orange(icon)
    local tint = rawget(icon, "tint")
    return tint ~= nil and tint.R < 1.0
end

local function fail(message)
    io.stderr:write(message, "\n", mock.text(), "\n")
    os.exit(1)
end

mock.load(scripts)
mock.run_until(1000)
mock.notify(PANEL_CLASS)
local hook = mock.hooks[MIN_SQUAD_EVENT]
if hook == nil then fail("the panel's MinSquadSize event wasn't hooked") end

local panel, entries, shown, set_shown = panel_with(4, 4)
hook.pre(panel, 4)
mock.run_until(mock.now() + 10)
if shown() ~= "4 - 6" then fail("the count reads '" .. shown() .. "', expected '4 - 6'") end
if #entries ~= 6 then fail("the row has " .. #entries .. " icons, expected 6") end
for index = 1, 6 do
    local tinted = orange(entries[index])
    if tinted ~= (index > 4) then fail("icon " .. index .. (tinted and " was" or " wasn't") .. " tinted") end
end
mock.expect("holotable_range=4 %- 6 added_icons=2 tinted=2 text=true", "the first range shown is logged")

-- The same event again, with the row already extended: nothing more is added.
hook.pre(panel, 4)
mock.run_until(mock.now() + 10)
if #entries ~= 6 or shown() ~= "4 - 6" then fail("a second pass changed the panel") end

-- The Blueprint rebuilds the row from its widget pool, handing the two tinted icons back first.
local reused = {entries[5], entries[6], entries[1], entries[2]}
for index = #entries, 1, -1 do entries[index] = nil end
for index, icon in ipairs(reused) do entries[index] = icon end
set_shown(4)
hook.pre(panel, 4)
mock.run_until(mock.now() + 10)
if #entries ~= 6 or shown() ~= "4 - 6" then fail("the rebuilt row wasn't extended") end
for index = 1, 6 do
    local tinted = orange(entries[index])
    if tinted ~= (index > 4) then fail("rebuilt icon " .. index .. (tinted and " was" or " wasn't") .. " tinted") end
end

if scans ~= 1 then fail("the current activity was searched for " .. scans .. " times, expected once") end

-- An operation's panel: its text isn't the mission's minimum, so the row is left alone.
local operation, operation_entries, operation_shown = panel_with("1-2", 2)
hook.pre(operation, 4)
mock.run_until(mock.now() + 10)
if #operation_entries ~= 2 or operation_shown() ~= "1-2" then fail("an operation's panel was changed") end

-- A mission whose minimum is its maximum (the tutorial, three-operator missions): unchanged.
mission.MaxSquadSize = 4
local fixed, fixed_entries, fixed_shown = panel_with(4, 4)
hook.pre(fixed, 4)
mock.run_until(mock.now() + 10)
if #fixed_entries ~= 4 or fixed_shown() ~= "4" then fail("a fixed-size mission's panel was changed") end

-- The Changed event hands over (old, new) view models: the new one is used, with no scan.
local changed = mock.hooks[CHANGED_EVENT]
if changed == nil then fail("the panel's Changed event wasn't hooked") end
local other = mock.object("BrunoMissionViewModel Deep Cover", {MinSquadSize = 3, MaxSquadSize = 6})
local before = scans
local deep, deep_entries, deep_shown = panel_with(3, 3)
changed.pre(deep, mission, other)
hook.pre(deep, 3)
mock.run_until(mock.now() + 300)
if deep_shown() ~= "3 - 6" or #deep_entries ~= 6 then fail("the event's view model wasn't used: " .. deep_shown()) end
if scans ~= before then fail("the current activity was searched for after the Changed event") end
mock.expect("holotable_vm_source=event", "the event source is logged")
io.stdout:write("ok\n")
