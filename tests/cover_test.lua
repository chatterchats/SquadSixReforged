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
--   3b. Cover a tile along the line from a crowded pocket, which no search centre has as its
--      nearest, is found by searching beside the pocket, and used.
--   3c. Cover on the tile next to a destination that stands 10 uu off its own tile's centre is
--      used, though it is under a tile from the destination.
--   3d. In a lane containing the world origin, cover at the origin is used, not taken for an
--      operator the placement never reached.
--   (1-3 run with improve_game_spots off, so the authored destinations stay put.)
--   4. improve_game_spots on, a stock squad of four: an authored destination already in cover
--      facing the encounter stays; one beside cover facing away moves to cover facing it within
--      two tiles; one whose only nearby cover faces away, and one whose only good cover is
--      too far outside the lane (RESCUE.cover_outside), stay. The moved one is a new actor; the authored one is unlisted.
--      In the Serolonis Job (its tutorial is scripted around the game's spots) none moves. In an
--      area directions.lua lists, its enemies' direction is used instead of the volume's. One
--      in cover but 50 uu off the cover's centre (on the seam between two tiles) moves onto it.
--      One whose only good cover is 150 uu past the lane's edge moves there.
--   5. The same with the setting off: nothing moves.
--   6. debug_cover_markers on: each pocket considered gets one of the game's cover markers, its
--      pocket set from the cover and its walls recoloured by category (green usable, yellow
--      crowded, red outside), none for cover facing away; all removed after a minute.
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
-- Cover pockets: the encounter lies towards +Y, so cover protects against it when its normal
-- (from the unit towards the cover) points +Y.
local FULL, HALF = 2 + 12, 1   -- HighCover with both step-outs; LowCover
local pockets = {
    {name = "full", X = B + 200, Y = B + 130, nx = 0, ny = 1, kind = FULL},
    {name = "half", X = B + 100, Y = B + 250, nx = 0, ny = 1, kind = HALF},
    {name = "away", X = B + 250, Y = B + 330, nx = 0, ny = -1, kind = FULL},
    {name = "outside", X = B + 520, Y = B + 200, nx = 0, ny = 1, kind = FULL},   -- 120 uu past the edge
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
-- The generated table loads and holds unit vectors; the test areas get their own table.
local generated = dofile(scripts:gsub("[/\\]$", "") .. "/directions.lua")
local listed = 0
for key, direction in pairs(generated) do
    listed = listed + 1
    if math.abs(direction.X ^ 2 + direction.Y ^ 2 - 1) > 0.001 then
        io.stderr:write("directions.lua: " .. key .. " isn't a unit vector\n")
        os.exit(1)
    end
end
if listed < 30 then
    io.stderr:write(string.format("directions.lua lists only %d areas\n", listed))
    os.exit(1)
end
-- The enemies of area "Reversed" lie behind its lane (-Y), its tactical volume in front (+Y).
package.preload["directions"] = function() return {["Test:Reversed"] = {X = 0, Y = -1}} end
mock.load(scripts)
mock.run_until(1000)
-- Scenarios 1 and 6 refuse cover 120 uu past the edge, as when added points could lie only a tile
-- outside; 3b checks RESCUE.cover_outside itself.
local RESCUE = package.loaded.placement.internals.RESCUE
local COVER_OUTSIDE = RESCUE.cover_outside
RESCUE.cover_outside = 100
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
local function area(name, map)
    local points = {}
    for index, point in ipairs(LANE) do
        points[index] = mock.actor("TacticalPoint " .. name .. index, {X = point.X, Y = point.Y, Z = 0})
    end
    local list = mock.array(points)
    map = map or "/Game/Maps/Test.Test"
    return mock.object("BP_CombatPreparationArea_C " .. map .. ":PersistentLevel." .. name,
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
mock.settings.improve_game_spots = false
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
mock.expect("improve_spots=skipped reason=setting_off", "improve_game_spots off is logged")

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

-- 3b. One pocket on corner 3, where a game spot stands (crowded); the next tile along its cover
-- line is 120 uu past the lane's right edge, beyond a tile but within RESCUE.cover_outside, and the
-- one after it 240 uu past, beyond it. Every search centre inside the lane is nearer the first,
-- and a pocket facing sideways inside the lane is nearer still. One operator staged outside needs
-- a spot: it takes the tile 120 uu out.
RESCUE.cover_outside = COVER_OUTSIDE
cover_available = true
for index = #pockets, 1, -1 do pockets[index] = nil end
pockets[1] = {X = B + 400, Y = B + 400, nx = 0, ny = 1, kind = HALF}
pockets[2] = {X = B + 520, Y = B + 400, nx = 0, ny = 1, kind = HALF}
pockets[3] = {X = B + 330, Y = B + 330, nx = 1, ny = 0, kind = FULL}
pockets[4] = {X = B + 640, Y = B + 400, nx = 0, ny = 1, kind = HALF}
local beside = {on_lane(1), on_lane(2), on_lane(3), on_lane(4), unit("Operator5", B + 200, B - 600)}
list = deploy("Beside", beside)
if not at(beside[5].at, pockets[2]) then
    fail(string.format("beside: Operator5 at %.0f/%.0f, not on the tile beside the crowded one", beside[5].at.X, beside[5].at.Y))
end
mock.expect("cover site=staging queries=%d+ pockets=4 usable=1 facing_away=1 refused=2 chosen_full=0 chosen_half=1 of=1 .* refused_outside=1 refused_crowded=1 .* crowded_at=5400/5400<spot@5400/5400",
    "the tile beside a crowded pocket is found and used, and one too far out is refused")
mock.run_until(mock.now() + 30000)
RESCUE.cover_outside = 100

-- 3c. Distress Call's shape: the cover tile beside corner 1's is 91 uu from the destination,
-- which stands 10 uu off its own tile. The squad stands inside the lane, away from it.
for index = #pockets, 1, -1 do pockets[index] = nil end
pockets[1] = {X = B + 90, Y = B + 13, nx = 0, ny = 1, kind = HALF}
local next_tile = {unit("Operator1", B + 300, B + 300), unit("Operator2", B + 200, B + 300),
    unit("Operator3", B + 300, B + 200), unit("Operator4", B + 200, B + 200), unit("Operator5", B + 200, B - 600)}
list = deploy("NextTile", next_tile)
if not at(next_tile[5].at, pockets[1]) then
    fail(string.format("next tile: Operator5 at %.0f/%.0f, not on the cover beside corner 1", next_tile[5].at.X, next_tile[5].at.Y))
end
mock.run_until(mock.now() + 30000)

-- 3d. Kith and Kin: the lane contains the world origin, with a cover tile on it. The operator
-- rescued onto it keeps it, and the destination is there, not where the operator was staged.
for index = #pockets, 1, -1 do pockets[index] = nil end
pockets[1] = {X = 0, Y = 0, nx = 0, ny = 1, kind = HALF}
local origin_points = {}
for index, point in ipairs({{X = -200, Y = -200}, {X = 200, Y = -200}, {X = 200, Y = 200}, {X = -200, Y = 200}}) do
    origin_points[index] = mock.actor("TacticalPoint Origin" .. index, {X = point.X, Y = point.Y, Z = 0})
end
local origin_list = mock.array(origin_points)
local origin_area = mock.object("BP_CombatPreparationArea_C /Game/Maps/Test.Test:PersistentLevel.Origin",
    {PlayerDestinations = origin_list}, {
        GetWorld = function() return mock.world end,
        GetLinkedTacticalArea = function() return volume end,
    })
local origin_squad = {unit("Operator1", -200, -200), unit("Operator2", 200, -200), unit("Operator3", 200, 200),
    unit("Operator4", -200, 200), unit("Operator5", 2400, 200)}
squad(origin_squad)
mock.hooks[TRIGGER].pre(origin_area)
mock.run_until(mock.now() + 600)
if not at(origin_squad[5].at, pockets[1]) then
    fail(string.format("origin: Operator5 at %.0f/%.0f, not on the cover at the origin", origin_squad[5].at.X, origin_squad[5].at.Y))
end
if not destination_at(origin_list, pockets[1]) then fail("origin: no destination on the cover at the origin") end
if destination_at(origin_list, {X = 2400, Y = 200}) then fail("origin: a destination was left where Operator5 was staged") end
mock.run_until(mock.now() + 30000)

-- 4. The game's own destinations, improve_game_spots on. Corner 1 is in cover facing the
-- encounter; corner 2 is beside cover facing away, with good cover 117 uu off inside the lane;
-- corner 3's only nearby cover faces away; corner 4's good cover is 250 uu outside the lane, beyond RESCUE.cover_outside.
cover_available = true
mock.settings.improve_game_spots = true
for index = #pockets, 1, -1 do pockets[index] = nil end
local improve_pockets = {
    {X = B, Y = B, nx = 0, ny = 1, kind = FULL},
    {X = B + 400, Y = B, nx = 0, ny = -1, kind = FULL},
    {X = B + 300, Y = B + 60, nx = 0, ny = 1, kind = FULL},
    {X = B + 350, Y = B + 300, nx = 0, ny = -1, kind = FULL},
    {X = B - 250, Y = B + 400, nx = 0, ny = 1, kind = FULL},
}
for index, pocket in ipairs(improve_pockets) do pockets[index] = pocket end
local stock = {on_lane(1), on_lane(2), on_lane(3), on_lane(4)}
squad(stock)
local improved_area, improved = area("Improved")
local authored = {}
for index = 1, 4 do authored[index] = improved[index] end
mock.hooks[TRIGGER].pre(improved_area)
mock.run_until(mock.now() + 600)
if improved:GetArrayNum() ~= 4 then fail("improve: the destination count changed") end
if improved[1] ~= authored[1] or improved[3] ~= authored[3] or improved[4] ~= authored[4] then
    fail("improve: a destination with no better cover was replaced")
end
if improved[2] == authored[2] or not at(improved[2].at, improve_pockets[3]) then
    fail("improve: corner 2 didn't move to the cover facing the encounter")
end
mock.expect("improve_spots kept=1 snapped=0 moved=1 no_better_cover=2 queries=%d+ errors=0 unreadable=0 moves=5400/5000%->5300/5060full",
    "the improvement reports what it kept and moved")
for index = 1, 4 do
    if stock[index].halts ~= 0 then fail("improve: Operator" .. index .. " was moved or stopped") end
end

-- 4b. The same in the Serolonis Job: its tutorial is scripted around the game's spots, so none
-- moves.
squad({on_lane(1), on_lane(2), on_lane(3), on_lane(4)})
local tutorial_area, tutorial = area("Tutorial",
    "/Game/Game/Maps/StoryMissions/MM_01_010_TheSerolonisJob/MM_01_010_TheSerolonisJob_Gameplay.MM_01_010_TheSerolonisJob_Gameplay")
local tutorial_spots = {}
for index = 1, 4 do tutorial_spots[index] = tutorial[index] end
mock.hooks[TRIGGER].pre(tutorial_area)
mock.run_until(mock.now() + 600)
for index = 1, 4 do
    if tutorial[index] ~= tutorial_spots[index] then fail("Serolonis Job: destination " .. index .. " was replaced") end
end
mock.expect("improve_spots=skipped reason=scripted_map map=MM_01_010_TheSerolonisJob",
    "the Serolonis Job's spots are left alone")

-- 4c. An area directions.lua lists, with its enemies behind the lane: corner 2's cover faces them
-- now, so it stays, where in 4 it moved.
squad({on_lane(1), on_lane(2), on_lane(3), on_lane(4)})
local reversed_area, reversed = area("Reversed")
local reversed_spot = reversed[2]
mock.hooks[TRIGGER].pre(reversed_area)
mock.run_until(mock.now() + 600)
if reversed[2] ~= reversed_spot then fail("listed direction: corner 2 moved although its cover faces the enemies") end
mock.expect("encounter_direction area=Test:Reversed source=spawners degrees=270 volume_degrees=90",
    "a listed area uses its enemies' direction and logs the volume's")
mock.expect("encounter_direction area=Test:Improved source=volume degrees=90 volume_degrees=90",
    "an unlisted area uses its volume's centre")

-- 4d. Corner 1 is 50 uu from the centre of the half cover it's in (Best Served Cold's seam): it
-- moves onto it. No other corner has cover near it.
for index = #pockets, 1, -1 do pockets[index] = nil end
pockets[1] = {X = B + 50, Y = B, nx = 0, ny = 1, kind = HALF}
squad({on_lane(1), on_lane(2), on_lane(3), on_lane(4)})
local seam_area, seam = area("Seam")
local seam_spots = {}
for index = 1, 4 do seam_spots[index] = seam[index] end
mock.hooks[TRIGGER].pre(seam_area)
mock.run_until(mock.now() + 600)
if seam[1] == seam_spots[1] or not at(seam[1].at, pockets[1]) then fail("seam: corner 1 didn't move onto its cover") end
for index = 2, 4 do
    if seam[index] ~= seam_spots[index] then fail("seam: corner " .. index .. " was replaced") end
end
mock.expect("improve_spots kept=0 snapped=1 moved=0 no_better_cover=3 queries=%d+ errors=0 unreadable=0 moves=5000/5000%->5050/5000half@snap",
    "a spot on the seam between two tiles moves onto its cover")
for index = #pockets, 1, -1 do pockets[index] = nil end
for index, pocket in ipairs(improve_pockets) do pockets[index] = pocket end
-- Let this deployment's later repair passes run out before the next scenario's.
mock.run_until(mock.now() + 30000)

-- 4e. Buy Cheap, Never Sleep's corner: corner 4's only cover facing the encounter is 150 uu past the
-- lane's edge, within RESCUE.cover_outside: it moves there.
RESCUE.cover_outside = COVER_OUTSIDE
for index = #pockets, 1, -1 do pockets[index] = nil end
pockets[1] = {X = B - 150, Y = B + 400, nx = 0, ny = 1, kind = FULL}
squad({on_lane(1), on_lane(2), on_lane(3), on_lane(4)})
local edge_area, edge = area("Edge")
local edge_spots = {}
for index = 1, 4 do edge_spots[index] = edge[index] end
mock.hooks[TRIGGER].pre(edge_area)
mock.run_until(mock.now() + 600)
if edge[4] == edge_spots[4] or not at(edge[4].at, pockets[1]) then fail("edge: corner 4 didn't move to the cover past the edge") end
mock.expect("improve_spots kept=0 snapped=0 moved=1 no_better_cover=3 queries=%d+ errors=0 unreadable=0 moves=5000/5400%->4850/5400full",
    "a game spot moves to cover within two tiles past the lane's edge")
for index = #pockets, 1, -1 do pockets[index] = nil end
for index, pocket in ipairs(improve_pockets) do pockets[index] = pocket end
mock.run_until(mock.now() + 30000)
RESCUE.cover_outside = 100

-- 5. Setting off: the same area keeps every authored destination.
mock.settings.improve_game_spots = false
squad({on_lane(1), on_lane(2), on_lane(3), on_lane(4)})
local plain_area, untouched = area("NotImproved")
local before = {}
for index = 1, 4 do before[index] = untouched[index] end
mock.hooks[TRIGGER].pre(plain_area)
mock.run_until(mock.now() + 600)
for index = 1, 4 do
    if untouched[index] ~= before[index] then fail("setting off: destination " .. index .. " was replaced") end
end

-- 6. Debug markers, on scenario 1's pockets and squad.
local MARKER_CLASS = "/Game/Game/UI/Cover/BP_UI_CoverPoint_ScriptCreated.BP_UI_CoverPoint_ScriptCreated_C"
-- The engine's text import, as the runtime uses it: the pocket text is kept, and the segment
-- list then reads one element.
local imported = {}
local pocket_property = mock.object("StructProperty RepresentedPocket", {}, {
    GetFName = function() return {ToString = function() return "RepresentedPocket" end} end,
    ContainerPtrToValuePtr = function(_, owner) return owner end,
    ImportText = function(_, text, owner)
        imported[#imported + 1] = text
        owner.properties.RepresentedPocket.PocketSegments = mock.array({{}})
    end,
})
local parent_class = mock.object("Class BRG_CoverVisualizationActor", {}, {
    ForEachProperty = function(_, callback) callback(pocket_property) end,
    GetSuperStruct = function() return nil end,
})
local marker_class = mock.object("BlueprintGeneratedClass " .. MARKER_CLASS, {}, {
    ForEachProperty = function() end,
    GetSuperStruct = function() return parent_class end,
})
local markers = {}
local spawn = mock.world.SpawnActor
local real_world = mock.world
mock.world = mock.object("World /Game/Maps/Test.Test", {}, {
    SpawnActor = function(_, class, location, rotation)
        if class ~= marker_class then return spawn(real_world, class, location, rotation) end
        local materials = {}
        local walls = {}
        local entry = {at = location, materials = materials, walls_removed = 0}
        -- The pool: wall 1 placed on the pocket with its own dynamic material, wall 2 unused at
        -- the origin with the plain material asset, which must never be tinted.
        for index = 1, 2 do
            local placed = index == 1
            local material = mock.object(placed and "MaterialInstanceDynamic /Engine/Transient.MID_M_UI_CoverWall_1"
                or "Material /Game/Game/UI/Cover/Materials/M_UI_CoverWall.M_UI_CoverWall", {}, {
                SetVectorParameterValue = function(_, name, value)
                    if not placed then entry.plain_tinted = true end
                    materials[#materials + 1] = {name, value}
                end,
                SetScalarParameterValue = function(_, name, value)
                    if not placed then entry.plain_tinted = true end
                    materials[#materials + 1] = {name, value}
                end,
            })
            local component = mock.object("Wall", {}, {GetMaterial = function() return material end})
            local at = placed and {X = location.X, Y = location.Y, Z = location.Z} or {X = 0, Y = 0, Z = 0}
            walls[index] = mock.object("BP_UI_Cover_Wall_C", {Wall = component}, {
                K2_GetActorLocation = function() return at end,
                Hide = function() end,
                K2_DestroyActor = function() entry.walls_removed = entry.walls_removed + 1 end,
            })
        end
        local represented = {PocketSegments = mock.array({})}
        local marker = mock.object("BP_UI_CoverPoint_ScriptCreated_C", {RepresentedPocket = represented, Walls = mock.array(walls)}, {
            GetClass = function() return marker_class end,
            VisualizePocket = function(self)
                -- The game reads the segments it was given; none means a pocket that was never set.
                if self.properties.RepresentedPocket.PocketSegments:GetArrayNum() ~= 1 then error("no pocket") end
                self.properties.visualized = true
            end,
            K2_DestroyActor = function(self) self.properties.destroyed = true end,
        })
        entry.marker, entry.represented = marker, represented
        markers[#markers + 1] = entry
        return marker
    end,
})
-- The engine's deferred spawn, which the runtime uses for markers.
local statics = mock.object("GameplayStatics Default__GameplayStatics", {}, {
    BeginDeferredActorSpawnFromClass = function(_, world, class, transform)
        return world:SpawnActor(class, transform.Translation, {})
    end,
    FinishSpawningActor = function(_, actor) return actor end,
})
local find_marker = StaticFindObject
StaticFindObject = function(path)
    if path == MARKER_CLASS then return marker_class end
    if path == "/Script/Engine.Default__GameplayStatics" then return statics end
    return find_marker(path)
end
for index = #pockets, 1, -1 do pockets[index] = nil end
pockets[1] = {X = B + 200, Y = B + 130, nx = 0, ny = 1, kind = FULL}         -- usable
pockets[2] = {X = B + 100, Y = B + 250, nx = 0, ny = 1, kind = HALF}         -- usable
pockets[3] = {X = B + 250, Y = B + 330, nx = 0, ny = -1, kind = FULL}        -- facing away: no marker
pockets[4] = {X = B + 520, Y = B + 200, nx = 0, ny = 1, kind = FULL}         -- outside
mock.settings.debug_cover_markers = true
deploy("Markers", {on_lane(1), on_lane(2), on_lane(3), on_lane(4),
    unit("Operator5", B + 200, B - 600), unit("Operator6", B + 1000, B + 200), unit("Operator7", B - 600, B + 200)})
mock.expect("debug_markers site=staging usable=2 crowded=0 outside=1 unwalkable=0\n", "the markers report what they showed")
if #markers ~= 3 then fail(string.format("expected three markers, got %d", #markers)) end
local green, red = 0, 0
for _, entry in ipairs(markers) do
    if not entry.marker.properties.visualized then fail("a marker wasn't drawn") end
    if entry.represented.PocketSegments:GetArrayNum() ~= 1 then fail("a marker's pocket wasn't set") end
    local color = nil
    for _, setting in ipairs(entry.materials) do
        if type(setting[1]) == "string" then fail("a material parameter was passed as a plain string") end
        if setting[1]:ToString() == "Base Color" then color = setting[2] end
    end
    if color == nil then fail("a marker's walls weren't recoloured") end
    if entry.plain_tinted then fail("an unused wall's plain material was tinted") end
    if color.G == 1 and color.R == 0 then green = green + 1 elseif color.R == 1 and color.G == 0 then red = red + 1 end
    if entry.at.X == pockets[3].X and entry.at.Y == pockets[3].Y then fail("cover facing away was marked") end
end
if green ~= 2 or red ~= 1 then fail(string.format("expected two green markers and one red, got %d and %d", green, red)) end
if #imported ~= 3 then fail("expected three pockets imported as text") end
local expected_text = "(PocketSegments=((ExtentLeft=(X=5150.000,Y=5130.000,Z=60.000),ExtentRight=(X=5250.000,Y=5130.000,Z=60.000),"
    .. "PointType=HighCover,LeftStepOutLocation=(X=5200.000,Y=5130.000,Z=0.000),RightStepOutLocation=(X=5200.000,Y=5130.000,Z=0.000),"
    .. "CoverLocation=(X=5200.000,Y=5130.000,Z=60.000),CoverNormal=(X=0.000,Y=1.000,Z=0.000),FloorLocation=(X=5200.000,Y=5130.000,Z=0.000))),"
    .. "LeftStepOutLocation=(X=5200.000,Y=5130.000,Z=0.000),RightStepOutLocation=(X=5200.000,Y=5130.000,Z=0.000),PocketPointType=HighCover,"
    .. "CoverLocation=(X=5200.000,Y=5130.000,Z=60.000),FloorLocation=(X=5200.000,Y=5130.000,Z=0.000),CoverNormal=(X=0.000,Y=1.000,Z=0.000))"
local found_text = false
for _, text in ipairs(imported) do found_text = found_text or text == expected_text end
if not found_text then fail("the full-cover pocket's text isn't as expected:\n" .. table.concat(imported, "\n")) end
mock.run_until(mock.now() + 61000)
for _, entry in ipairs(markers) do
    if not entry.marker.properties.destroyed or entry.walls_removed ~= 2 then fail("a marker outlived its minute") end
end
mock.settings.debug_cover_markers = false

io.stdout:write("ok\n")
