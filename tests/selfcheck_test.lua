-- The self-check against a game update that broke names: the slot index field got a new GUID
-- suffix, a Blueprint relocation function was renamed, and reflection fails on one class.
--   luajit tests/selfcheck_test.lua <Scripts dir>
local scripts = assert(arg[1], "usage: selfcheck_test.lua <Scripts dir>")
local here = string.match(arg[0], "^(.*[/\\])") or "./"
local mock = dofile(here .. "ue4ss_mock.lua")

local properties = {}
for owner, names in pairs(mock.game_properties) do properties[owner] = names end
properties["/Game/Game/UI/Strategy/GalaxyMap/BPs/BrunoActivitySlotData.BrunoActivitySlotData"] =
    {"index_7_0123456789ABCDEF0123456789ABCDEF"}

mock.install({
    properties = properties,
    missing = {
        ["/Game/Game/Core/Blueprints/BP_CombatPreparationArea.BP_CombatPreparationArea_C:ExternalMovePlayerUnitsIntoPosition"] = true,
    },
    missions = {mock.mission("SK_Kaller_020", 6, 0)},
})
-- Reflection unavailable on one class: ForEachProperty raises.
local find = StaticFindObject
StaticFindObject = function(path)
    local found = find(path)
    if path == "/Script/BitReactorGame.TacticalPoint" then
        rawset(found, "ForEachProperty", function() error("ForEachProperty unavailable") end)
    end
    return found
end

mock.load(scripts)
mock.run_until(1000)
mock.notify("/Script/BitReactorGame.TacticalGameState")
mock.run_until(mock.now() + 40000)

mock.expect("selfcheck phase=startup ok=23 missing=BrunoActivitySlotData%.index_7_31948AF04E3D570FC0E4BBBEA45BB788 unchecked=TacticalPoint%.OwningTeam",
    "a re-keyed field is missing and a failed reflection call is unchecked")
mock.expect("selfcheck phase=mission ok=2 missing=BP_CombatPreparationArea_C:ExternalMovePlayerUnitsIntoPosition unchecked=none",
    "a renamed Blueprint function is reported after the last mission attempt")
-- Reported once: retries stop after the last attempt.
local _, mission_lines = mock.text():gsub("selfcheck phase=mission", "")
if mission_lines ~= 1 then
    io.stderr:write("expected one mission line, got ", mission_lines, "\n", mock.text(), "\n")
    os.exit(1)
end
io.stdout:write("ok\n")
