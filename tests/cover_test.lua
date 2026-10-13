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
--   (1-3 run with improve_game_spots off, so the authored destinations stay put.)
--   4. improve_game_spots on, a stock squad of four: an authored destination already in cover
--      facing the encounter stays; one beside cover facing away moves to cover facing it within
--      two tiles; one whose only nearby cover faces away, and one whose only good cover is
--      outside the lane, stay. The moved one is a new actor; the authored one is unlisted.
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

-- 4. The game's own destinations, improve_game_spots on. Corner 1 is in cover facing the
-- encounter; corner 2 is beside cover facing away, with good cover 117 uu off inside the lane;
-- corner 3's only nearby cover faces away; corner 4's good cover is 150 uu outside the lane.
cover_available = true
mock.settings.improve_game_spots = true
for index = #pockets, 1, -1 do pockets[index] = nil end
local improve_pockets = {
    {X = B, Y = B, nx = 0, ny = 1, kind = FULL},
    {X = B + 400, Y = B, nx = 0, ny = -1, kind = FULL},
    {X = B + 300, Y = B + 60, nx = 0, ny = 1, kind = FULL},
    {X = B + 350, Y = B + 300, nx = 0, ny = -1, kind = FULL},
    {X = B - 150, Y = B + 400, nx = 0, ny = 1, kind = FULL},
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
mock.expect("improve_spots kept=1 moved=1 no_better_cover=2 queries=%d+ errors=0 unreadable=0 moves=5400/5000%->5300/5060full",
    "the improvement reports what it kept and moved")
for index = 1, 4 do
    if stock[index].halts ~= 0 then fail("improve: Operator" .. index .. " was moved or stopped") end
end

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
local marker_class = mock.object("BlueprintGeneratedClass " .. MARKER_CLASS)
local markers = {}
local spawn = mock.world.SpawnActor
local real_world = mock.world
mock.world = mock.object("World /Game/Maps/Test.Test", {}, {
    SpawnActor = function(_, class, location, rotation)
        if class ~= marker_class then return spawn(real_world, class, location, rotation) end
        local materials = {}
        local walls = {}
        local entry = {at = location, materials = materials, walls_removed = 0}
        for index = 1, 2 do
            local material = mock.object("MID", {}, {
                SetVectorParameterValue = function(_, name, value) materials[#materials + 1] = {name, value} end,
                SetScalarParameterValue = function(_, name, value) materials[#materials + 1] = {name, value} end,
            })
            local component = mock.object("Wall", {}, {GetMaterial = function() return material end})
            walls[index] = mock.object("BP_UI_Cover_Wall_C", {Wall = component}, {
                Hide = function() end,
                K2_DestroyActor = function() entry.walls_removed = entry.walls_removed + 1 end,
            })
        end
        local represented = {PocketSegments = setmetatable({}, {__index = {GetArrayNum = function() return 1 end}})}
        local marker = mock.object("BP_UI_CoverPoint_ScriptCreated_C", {RepresentedPocket = represented, Walls = mock.array(walls)}, {
            VisualizePocket = function(self) self.properties.visualized = true end,
            K2_DestroyActor = function(self) self.properties.destroyed = true end,
        })
        entry.marker, entry.represented = marker, represented
        markers[#markers + 1] = entry
        return marker
    end,
})
local find_marker = StaticFindObject
StaticFindObject = function(path)
    if path == MARKER_CLASS then return marker_class end
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
    if entry.represented.CoverNormal == nil or entry.represented.PocketSegments[1] == nil then
        fail("a marker's pocket wasn't set")
    end
    local color = nil
    for _, setting in ipairs(entry.materials) do
        if setting[1] == "Base Color" then color = setting[2] end
    end
    if color == nil then fail("a marker's walls weren't recoloured") end
    if color.G == 1 and color.R == 0 then green = green + 1 elseif color.R == 1 and color.G == 0 then red = red + 1 end
    if entry.at.X == pockets[3].X and entry.at.Y == pockets[3].Y then fail("cover facing away was marked") end
end
if green ~= 2 or red ~= 1 then fail(string.format("expected two green markers and one red, got %d and %d", green, red)) end
mock.run_until(mock.now() + 61000)
for _, entry in ipairs(markers) do
    if not entry.marker.properties.destroyed or entry.walls_removed ~= 2 then fail("a marker outlived its minute") end
end
mock.settings.debug_cover_markers = false

io.stdout:write("ok\n")
