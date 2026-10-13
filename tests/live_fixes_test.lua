-- The placement fixes from the Retake Luunata runs (docs/live-tests.md), against a navmesh
-- stand-in: a flat floor at Z 0 with one hole in it.
--   1. A stock squad (four operators, four authored destinations) is left to the game, even
--      with two operators on one tile.
--   2. With six: overflow operators rescued onto derived points stand on the floor, not at the
--      height interpolated from a floating authored destination; an operator passing over a
--      squadmate's tile while the squad walks in isn't teleported; operators the repair puts
--      back have their walk cancelled; one that later wanders off is reported. A derived point
--      over a hole in the navmesh (Dark Waters: under a prop) is skipped for another one. Two
--      operators on neighbouring tiles, 91 uu apart (Distress Call), aren't sharing a tile.
--   3. At mission start, an operator standing still in the hole is moved beside a squadmate,
--      but not while the whole squad is off the navmesh (an intro), and not in a stock squad.
--   luajit tests/live_fixes_test.lua <Scripts dir>
local scripts = assert(arg[1], "usage: live_fixes_test.lua <Scripts dir>")
local here = string.match(arg[0], "^(.*[/\\])") or "./"
local mock = dofile(here .. "ue4ss_mock.lua")

local TRIGGER = "/Script/BitReactorGame.CombatPreparationArea:TriggerPreCombat"
local RELOCATION = "/Game/Game/Core/Blueprints/BP_CombatPreparationArea.BP_CombatPreparationArea_C:MovePlayerUnitsIntoPosition"
local CAPSULE = 90
local HOLE = {X = 2370, Y = 0, R = 120}
local holes = {HOLE}

mock.install({missions = {mock.mission("SK_Kaller_020", 6, 0)}})
local navigation = mock.object("NavigationSystemV1 Default__NavigationSystemV1", {}, {
    K2_ProjectPointToNavigation = function(_, _, point, projected)
        for _, hole in ipairs(holes) do
            if (point.X - hole.X) ^ 2 + (point.Y - hole.Y) ^ 2 <= hole.R ^ 2 then return false end
        end
        if math.abs(point.Z) > 250 then return false end
        projected.X, projected.Y, projected.Z = point.X, point.Y, 0
        return true
    end,
})
local find = StaticFindObject
StaticFindObject = function(path)
    if path == "/Script/NavigationSystem.Default__NavigationSystemV1" then return navigation end
    return find(path)
end
mock.load(scripts)
mock.run_until(1000)
mock.run_loops(3)

local function fail(message)
    io.stderr:write(message, "\n\n", mock.text(), "\n")
    os.exit(1)
end
local function count(pattern)
    local _, found = mock.text():gsub(pattern, "")
    return found
end
local function squad(units)
    mock.first_of["TacticalGameState"] = mock.object("TacticalGameState", {
        PlayerSquad = mock.object("BitReactorGameSquad", {SquadMembers = mock.array(units)}),
    })
end
local function unit(name, x, y, z) return mock.actor(name, {X = x, Y = y, Z = z or CAPSULE}) end
-- A 400 uu square lane at 5000/5000, clear of the world origin, on a flat floor. Its first two
-- destinations float 180 uu above the floor (one of Retake Luunata's lower-level destinations
-- sits 92 uu up), so heights interpolated between destinations are wrong across the lane.
local B = 5000
local LANE = {{X = B, Y = B, Z = 180}, {X = B + 400, Y = B, Z = 180}, {X = B + 400, Y = B + 400, Z = 0},
    {X = B, Y = B + 400, Z = 0}}
local function area(name)
    local points = {}
    for index, point in ipairs(LANE) do points[index] = mock.actor("TacticalPoint " .. name .. index, point) end
    local list = mock.array(points)
    return mock.object("BP_CombatPreparationArea_C /Game/Maps/Test.Test:PersistentLevel." .. name,
        {PlayerDestinations = list}, {GetWorld = function() return mock.world end}), list
end
local function on_lane(index) return unit("Operator" .. index, LANE[index].X, LANE[index].Y) end

-- 1. Stock squad.
local stock = {on_lane(1), on_lane(2), on_lane(3), on_lane(4)}
squad(stock)
local stock_area = area("Stock")
mock.hooks[TRIGGER].pre(stock_area)
mock.run_until(mock.now() + 600)
mock.hooks[RELOCATION].pre(stock_area)
stock[4].at = {X = B + 400, Y = B + 400, Z = CAPSULE}   -- on operator 3's tile
mock.run_until(mock.now() + 9000)
mock.expect("placement_repair=skipped reason=stock_squad units=4 authored=4", "a stock squad is skipped")
if count("placement_repair via=") ~= 0 then fail("a stock squad was repaired") end
if stock[4].at.X ~= B + 400 or stock[4].at.Y ~= B + 400 or stock[4].halts ~= 0 then fail("operator 4 was moved") end

-- 2. Six operators: two staged outside the lane.
local six = {on_lane(1), on_lane(2), on_lane(3), on_lane(4), unit("Operator5", B + 200, B - 600), unit("Operator6", B + 1000, B + 200)}
squad(six)
local six_area, destinations = area("Six")
mock.hooks[TRIGGER].pre(six_area)
mock.run_until(mock.now() + 600)
if destinations:GetArrayNum() ~= 6 then fail("expected six destinations") end
for index = 5, 6 do
    local at = six[index].at
    if at.X < B or at.X > B + 400 or at.Y < B or at.Y > B + 400 then fail("Operator" .. index .. " not rescued into the lane") end
    if at.Z ~= CAPSULE then fail(string.format("Operator%d rescued at Z %g, expected %d", index, at.Z, CAPSULE)) end
    if six[index].halts < 1 then fail("Operator" .. index .. "'s walk wasn't cancelled after the rescue") end
end
for index = 5, 6 do
    if destinations[index].at.Z ~= CAPSULE then fail("an added destination isn't on the floor") end
end
mock.expect("placement_rescue=deployment_lane moved=[^\n]* floor_settled=2/2 largest_shift=", "the rescue reports the floor snap")
local rescued = {}
for index = 5, 6 do rescued[index] = {X = six[index].at.X, Y = six[index].at.Y, Z = six[index].at.Z} end

-- The relocation: operator 2 walks over operator 1's tile, and the overflow operators are
-- stranded at the world origin.
local teleported = false
six[2].move = function(target) teleported = true return target, true end
mock.hooks[RELOCATION].pre(six_area)
six[2].at = {X = B, Y = B, Z = CAPSULE}
six[5].at = {X = 40, Y = -30, Z = 261}
six[6].at = {X = 80, Y = -60, Z = 261}
mock.run_until(mock.now() + 300)
six[2].at = {X = B + 400, Y = B, Z = CAPSULE}   -- and walks on to its own destination
mock.run_until(mock.now() + 9000)
mock.expect("shared_tile:moving", "a squadmate's tile crossed while walking is left alone")
if teleported then fail("operator 2 was teleported while walking") end
mock.expect("placement_repair via=post100 units=6 staged=6 stranded=3 restored=2 halted=2", "the stranded operators are put back and stopped")
for index = 5, 6 do
    local at = six[index].at
    if at.X ~= rescued[index].X or at.Y ~= rescued[index].Y then fail("Operator" .. index .. " not back where it was rescued to") end
end
-- One wanders off before the first drift check.
six[5].at = {X = B + 3700, Y = B + 200, Z = CAPSULE}
mock.run_until(mock.now() + 12000)
mock.expect("placement_drift via=drift10000 units=1 moves=", "an operator that walks off after the repair is reported")
if count("off_navmesh_skipped") ~= 0 then fail("a derived point was skipped with no hole under it") end

-- The same deployment with a hole under the spot operator 5 was rescued to: it gets another one.
local prop = {X = rescued[5].X, Y = rescued[5].Y, R = 40}
holes[#holes + 1] = prop
local holed = {on_lane(1), on_lane(2), on_lane(3), on_lane(4), unit("Operator5", B + 200, B - 600), unit("Operator6", B + 1000, B + 200)}
squad(holed)
mock.hooks[TRIGGER].pre(area("Holed"))
mock.run_until(mock.now() + 600)
mock.expect("placement_rescue=deployment_lane moved=[^\n]* floor_settled=2/2 largest_shift=[%d-]+ off_navmesh_skipped=1",
    "the rescue skips the spot over the hole")
for index = 5, 6 do
    local at = holed[index].at
    if (at.X - prop.X) ^ 2 + (at.Y - prop.Y) ^ 2 <= prop.R ^ 2 then fail("Operator" .. index .. " was put over the hole") end
    if at.X < B or at.X > B + 400 or at.Y < B or at.Y > B + 400 then fail("Operator" .. index .. " not rescued into the lane") end
    if at.Z ~= CAPSULE then fail(string.format("Operator%d rescued at Z %g, expected %d", index, at.Z, CAPSULE)) end
end
mock.run_until(mock.now() + 30000)
holes[#holes] = nil

-- Distress Call: an added operator in the cover tile beside a destination that stands 9 uu off its
-- own tile, 91 uu from the operator on it. The repair left both alone only once it measured a
-- tile as the cover choice does.
local neighbours = {on_lane(1), on_lane(2), on_lane(3), on_lane(4), unit("Operator5", B + 200, B - 600),
    unit("Operator6", B + 1000, B + 200)}
squad(neighbours)
local neighbours_area = area("Neighbours")
mock.hooks[TRIGGER].pre(neighbours_area)
mock.run_until(mock.now() + 600)
mock.hooks[RELOCATION].pre(neighbours_area)
neighbours[1].at = {X = B + 9, Y = B, Z = CAPSULE}
neighbours[5].at = {X = B + 100, Y = B + 10, Z = CAPSULE}
neighbours[6].at = {X = B + 200, Y = B + 200, Z = CAPSULE}
local shared_before = count("shared_tile")
local halts = {neighbours[1].halts, neighbours[5].halts}
mock.run_until(mock.now() + 9000)
if count("shared_tile") ~= shared_before then fail("operators on neighbouring tiles were taken for sharing one") end
if neighbours[1].at.X ~= B + 9 or neighbours[5].at.X ~= B + 100 or neighbours[1].halts ~= halts[1]
    or neighbours[5].halts ~= halts[2] then
    fail("an operator on a neighbouring tile was moved")
end
mock.run_until(mock.now() + 30000)

-- 3. Mission start.
local function mission(units)
    squad(units)
    mock.notify("/Script/BitReactorGame.TacticalGameState")
    mock.run_until(mock.now())
    mock.run_loops(6)
end
local stuck = unit("Stuck", HOLE.X, HOLE.Y)
local start = {unit("Start1", 2000, 0), unit("Start2", 2000, 200), unit("Start3", 2200, 0),
    unit("Start4", 2200, 200), unit("Start5", 1800, 0), stuck}
mission(start)
mock.expect("spawn_rescue=moved from=2370/0/90 to=", "the operator in the hole is moved")
local at = stuck.at
if (at.X - HOLE.X) ^ 2 + (at.Y - HOLE.Y) ^ 2 <= HOLE.R ^ 2 then fail("still in the hole") end
if at.Z ~= CAPSULE or stuck.halts ~= 1 then fail("moved, but not onto the floor or not stopped") end
for index = 1, 5 do
    if start[index].halts ~= 0 then fail("Start" .. index .. " was touched") end
end

-- An intro holds the whole squad off the navmesh; a stock squad is the game's.
mission({unit("Intro1", 2000, 0, 5000), unit("Intro2", 2000, 200, 5000), unit("Intro3", 2200, 0, 5000),
    unit("Intro4", 2200, 200, 5000), unit("Intro5", 1800, 0, 5000), unit("Intro6", HOLE.X, HOLE.Y, 5000)})
mission({unit("Four1", 2000, 0), unit("Four2", 2000, 200), unit("Four3", 2200, 0), unit("Four4", HOLE.X, HOLE.Y)})
if count("spawn_rescue=") ~= 1 then fail("only the first mission's operator should have been moved") end
io.stdout:write("ok\n")
