-- The dev probe (dev/ZCOMSquadSixProbe) under the UE4SS stand-in: a mission on Lothal 035's real
-- deployment area with a navmesh and floor that answer, a squad being staged, and Squad Six adding
-- two destinations later. The probe runs while missions load, so it also mustn't search all
-- objects often.
--   luajit tests/probe_test.lua <Scripts dir>
local scripts = assert(arg[1], "usage: probe_test.lua <Scripts dir>")
local here = string.match(arg[0], "^(.*[/\\])") or "./"
local mock = dofile(here .. "ue4ss_mock.lua")

local output = os.tmpname()
SquadSixProbeRuntimeScripts = scripts .. "/"
SquadSixProbeOutputDir = output .. "-"

mock.install({})
local generic_find = StaticFindObject

-- Lothal 035 (data/mapscan.json): four destinations close to a line.
local destinations = {}
for index, p in ipairs({{449.0, 935.0, 7.3}, {892.7, 635.3, 52.3}, {431.9, 1164.7, 149.6}, {1368.0, 240.0, 7.3}}) do
    destinations[index] = mock.actor("TacticalPoint TacticalPoint_" .. index, {X = p[1], Y = p[2], Z = p[3]})
end
local destination_array = mock.array(destinations)
local area = mock.object("BP_CombatPreparationArea_C /Game/Game/Maps/Skirmish/SK_Lothal_035/"
    .. "SK_Lothal_035_Gameplay.SK_Lothal_035_Gameplay:PersistentLevel.BP_CombatPreparationArea_C_0",
    {PlayerDestinations = destination_array})

-- The floor is at each point's own height; the navmesh projects onto the point.
local navigation = mock.object("NavigationSystemV1 Default__NavigationSystemV1", {}, {
    K2_ProjectPointToNavigation = function(_, _, point, projected)
        projected.X, projected.Y, projected.Z = point.X, point.Y, point.Z
        return true
    end,
})
local kismet = mock.object("KismetSystemLibrary Default__KismetSystemLibrary", {}, {
    LineTraceSingle = function(_, _, start, finish, _, _, _, _, hit)
        hit.ImpactPoint = {X = start.X, Y = start.Y, Z = finish.Z + 1000}
        return true
    end,
})
StaticFindObject = function(path)
    if path == "/Script/NavigationSystem.Default__NavigationSystemV1" then return navigation end
    if path == "/Script/Engine.Default__KismetSystemLibrary" then return kismet end
    return generic_find(path)
end
local searches = {}
FindAllOf = function(class)
    searches[class] = (searches[class] or 0) + 1
    if class == "BP_CombatPreparationArea_C" then return {area} end
    return nil
end

dofile(here .. "../dev/ZCOMSquadSixProbe/Scripts/main.lua")

-- The mission starts after the probe has loaded.
local units = {}
for index = 1, 6 do units[index] = mock.actor("Operator Operator" .. index, {X = 2000 + index * 120, Y = 500, Z = 100}) end
mock.first_of["TacticalGameState"] = mock.object("TacticalGameState /Game/Game/Maps/Skirmish/SK_Lothal_035/SK_Lothal_035_Root", {
    PlayerSquad = mock.object("BitReactorGameSquad", {SquadMembers = mock.array(units)}),
})
mock.notify("/Script/BitReactorGame.TacticalGameState", mock.first_of["TacticalGameState"])
mock.run_until(mock.now() + 1)
local find_first = FindFirstOf
local first_searches = 0
FindFirstOf = function(class) first_searches = first_searches + 1 return find_first(class) end
mock.run_loops(2)
-- Combat preparation: Squad Six appends two destinations, and the relocation moves the squad.
destination_array[5] = mock.actor("TacticalPoint Added1", {X = 1130, Y = 438, Z = 29})
destination_array[6] = mock.actor("TacticalPoint Added2", {X = 671, Y = 785, Z = 29})
for index, unit in ipairs(units) do unit.at = {X = 500 + index * 150, Y = 900, Z = 100} end
mock.run_loops(1)
mock.run_loops(8)

local expect = mock.expect
expect("loaded version=[%d.]+", "the probe loads Squad Six's scripts")
expect("mission start: ", "mission start")
expect("timeline t=1s areas=1\n", "timeline of areas")
expect("area SK_Lothal_035_Gameplay:BP_CombatPreparationArea_C_0 %(settled, t=11s%): 4 authored destinations",
    "the area is checked once it has been there for 10 s")
expect("derived derived1 [%d-]+/[%d-]+/[%d-]+ nav=ok d=0 floor=hit dz=0",
    "a derived spot is checked against navmesh and floor")
expect("summary: authored 4: nav 4, floor within 50 uu 4; derived 2: nav 2, floor within 50 uu 2; added 2: nav 2, floor within 50 uu 2",
    "the area summary")
expect("squad t=1s members=6 Operator1=2120/500/100", "staging positions")
expect("destinations=6 %(runtime added 2%)", "destinations Squad Six adds are noticed")
expect("added added2 671/785/29", "and checked")
-- Eleven seconds of watching: area searches at 1, 6 and 11 s, nothing else.
local other = 0
for class, count in pairs(searches) do if class ~= "BP_CombatPreparationArea_C" then other = other + count end end
if searches.BP_CombatPreparationArea_C ~= 3 or other ~= 0 or first_searches ~= 0 then
    error(string.format("object searches: areas %s, other %d, FindFirstOf %d",
        tostring(searches.BP_CombatPreparationArea_C), other, first_searches))
end
expect("squad t=3s members=6 Operator1=650/900/100", "the relocation is recorded")

local results = assert(io.open(output .. "-squadsix_probe.jsonl")):read("*a")
assert(results:find('"type":"area"') and results:find('"type":"squad"'), "JSON lines written:\n" .. results)
os.remove(output .. "-squadsix_probe.jsonl")
os.remove(output .. "-squadsix_probe.log")
os.remove(output)
io.stdout:write("ok\n")
