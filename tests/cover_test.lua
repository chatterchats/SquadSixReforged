-- Destinations for every unit, and cover for the ones the mod adds, against a stand-in for the
-- game's cover search (BRG_TargetingFunctionLibrary.GetNearestCoverForPoint) on a flat floor.
--   1. Seven units on four authored destinations, three staged outside the lane: all three are
--      rescued into the lane and seven destinations result. Full cover facing the encounter is
--      used first, then half cover, then a derived point; cover facing away from the encounter
--      and cover outside the lane are not used.
--   2. The same with three staged inside the lane (Stillwatch's shape): seven destinations, the
--      cover spots among them, and the operators aren't moved.
--   3. With no cover search (the call fails), seven destinations still result and the rescue
--      lands on the derived points exactly as before.
--   luajit tests/cover_test.lua <Scripts dir>
local scripts = assert(arg[1], "usage: cover_test.lua <Scripts dir>")
local here = string.match(arg[0], "^(.*[/\\])") or "./"
local mock = dofile(here .. "ue4ss_mock.lua")

local TRIGGER = "/Script/BitReactorGame.CombatPreparationArea:TriggerPreCombat"
local LIBRARY = "/Script/BitReactorGame.Default__BRG_TargetingFunctionLibrary"
local CAPSULE = 90
local B = 5000

mock.install({missions = {mock.mission("SK_Kaller_020", 6, 0)}})
local navigation = mock.object("NavigationSystemV1 Default__NavigationSystemV1", {}, {
    K2_ProjectPointToNavigation = function(_, _, point, projected)
        if math.abs(point.Z) > 250 then return false end
        projected.X, projected.Y, projected.Z = point.X, point.Y, 0
        return true
    end,
})
-- Cover pockets: the encounter lies towards +Y, so cover used from its -Y side (normal -Y)
-- faces it.
local FULL, HALF = 2 + 12, 1   -- HighCover with both step-outs; LowCover
local pockets = {
    {name = "full", X = B + 200, Y = B + 130, nx = 0, ny = -1, kind = FULL},
    {name = "half", X = B + 100, Y = B + 250, nx = 0, ny = -1, kind = HALF},
    {name = "away", X = B + 250, Y = B + 330, nx = 0, ny = 1, kind = FULL},
    {name = "outside", X = B + 520, Y = B + 200, nx = 0, ny = -1, kind = FULL},   -- 120 uu past the edge
}
local cover_available = true
local library = mock.object("BRG_TargetingFunctionLibrary " .. LIBRARY, {}, {
    GetNearestCoverForPoint = function(_, _, point, out, range)
        if not cover_available then error("no such function") end
        local best, best_distance = nil, range * range
        for _, pocket in ipairs(pockets) do
            local distance = (pocket.X - point.X) ^ 2 + (pocket.Y - point.Y) ^ 2
            if distance <= best_distance then best, best_distance = pocket, distance end
        end
        if best == nil then return false end
        out.FloorLocation = {X = best.X, Y = best.Y, Z = 0}
        out.CoverNormal = {X = best.nx, Y = best.ny, Z = 0}
        out.PocketPointType = best.kind
        return true
    end,
})
local find = StaticFindObject
StaticFindObject = function(path)
    if path == "/Script/NavigationSystem.Default__NavigationSystemV1" then return navigation end
    if path == LIBRARY then return library end
    return find(path)
end
mock.load(scripts)
mock.run_until(1000)
mock.run_loops(3)

local function fail(message)
    io.stderr:write(message, "\n\n", mock.text(), "\n")
    os.exit(1)
end
local function unit(name, x, y) return mock.actor(name, {X = x, Y = y, Z = CAPSULE}) end
local function squad(units)
    mock.first_of["TacticalGameState"] = mock.object("TacticalGameState", {
        PlayerSquad = mock.object("BitReactorGameSquad", {SquadMembers = mock.array(units)}),
    })
end
-- A flat 400 uu lane; its tactical volume's centre lies 3,000 uu towards +Y.
local LANE = {{X = B, Y = B}, {X = B + 400, Y = B}, {X = B + 400, Y = B + 400}, {X = B, Y = B + 400}}
local volume = mock.object("TacticalVolume", {}, {
    K2_GetActorLocation = function() return {X = B + 200, Y = B + 3000, Z = 0} end,
    IsActorInsideTacticalArea = function() return true end,
})
local function area(name)
    local points = {}
    for index, point in ipairs(LANE) do
        points[index] = mock.actor("TacticalPoint " .. name .. index, {X = point.X, Y = point.Y, Z = 0})
    end
    local list = mock.array(points)
    return mock.object("BP_CombatPreparationArea_C /Game/Maps/Test.Test:PersistentLevel." .. name,
        {PlayerDestinations = list}, {
            GetWorld = function() return mock.world end,
            GetLinkedTacticalArea = function() return volume end,
        }), list
end
local function on_lane(index) return unit("Operator" .. index, LANE[index].X, LANE[index].Y) end
local function at(point, pocket) return point.X == pocket.X and point.Y == pocket.Y end
local function destination_at(list, pocket)
    for index = 1, list:GetArrayNum() do
        if at(list[index].at, pocket) then return true end
    end
    return false
end
local function deploy(name, units)
    squad(units)
    local deployment, list = area(name)
    mock.hooks[TRIGGER].pre(deployment)
    mock.run_until(mock.now() + 600)
    return list
end

-- 1. Seven units, three staged outside the lane.
local seven = {on_lane(1), on_lane(2), on_lane(3), on_lane(4),
    unit("Operator5", B + 200, B - 600), unit("Operator6", B + 1000, B + 200), unit("Operator7", B - 600, B + 200)}
local list = deploy("Outside", seven)
if list:GetArrayNum() ~= 7 then fail(string.format("expected seven destinations, found %d", list:GetArrayNum())) end
local on_full, on_half = 0, 0
for index = 5, 7 do
    local position = seven[index].at
    if position.X < B or position.X > B + 400 or position.Y < B or position.Y > B + 400 then
        fail("Operator" .. index .. " not rescued into the lane")
    end
    if position.Z ~= CAPSULE then fail(string.format("Operator%d at Z %g, expected %d", index, position.Z, CAPSULE)) end
    if at(position, pockets[1]) then on_full = on_full + 1 end
    if at(position, pockets[2]) then on_half = on_half + 1 end
    if at(position, pockets[3]) or at(position, pockets[4]) then fail("Operator" .. index .. " was put in unusable cover") end
end
if on_full ~= 1 or on_half ~= 1 then
    fail(string.format("expected one operator in full cover and one in half, got %d and %d", on_full, on_half))
end
mock.expect("cover site=staging queries=%d+ pockets=%d+ usable=2 facing_away=1 refused=1 chosen_full=1 chosen_half=1 of=3 facing=checked",
    "the staging rescue reports the cover it found and used")

-- 2. The same squad staged inside the lane: destinations go to the cover, nobody is moved.
local inside = {on_lane(1), on_lane(2), on_lane(3), on_lane(4),
    unit("Operator5", B + 330, B + 200), unit("Operator6", B + 200, B + 330), unit("Operator7", B + 70, B + 110)}
local staged = {}
for index = 5, 7 do staged[index] = {X = inside[index].at.X, Y = inside[index].at.Y} end
list = deploy("Inside", inside)
if list:GetArrayNum() ~= 7 then fail(string.format("in the lane: expected seven destinations, found %d", list:GetArrayNum())) end
if not destination_at(list, pockets[1]) or not destination_at(list, pockets[2]) then
    fail("in the lane: the cover spots aren't destinations")
end
for index = 5, 7 do
    if inside[index].at.X ~= staged[index].X or inside[index].at.Y ~= staged[index].Y then
        fail("in the lane: Operator" .. index .. " was moved")
    end
end
mock.expect("cover site=in_lane queries=%d+ pockets=%d+ usable=%d+ facing_away=%d+ refused=%d+ chosen_full=1 chosen_half=1 of=2",
    "the in-lane expansion reports the cover it used")

-- 3. No cover search: seven destinations, rescues on the derived points.
cover_available = false
local plain = {on_lane(1), on_lane(2), on_lane(3), on_lane(4),
    unit("Operator5", B + 200, B - 600), unit("Operator6", B + 1000, B + 200), unit("Operator7", B - 600, B + 200)}
list = deploy("Plain", plain)
if list:GetArrayNum() ~= 7 then fail(string.format("without cover: expected seven destinations, found %d", list:GetArrayNum())) end
for index = 5, 7 do
    for _, pocket in ipairs(pockets) do
        if at(plain[index].at, pocket) then fail("without cover: Operator" .. index .. " landed on a cover spot") end
    end
end
mock.expect("chosen_full=0 chosen_half=0 of=3 facing=checked errors=%d+", "a failing cover search is reported")
if mock.text():find("WARNING: fewer destinations") then fail("a seven-unit squad was left short of destinations") end

io.stdout:write("ok\n")
