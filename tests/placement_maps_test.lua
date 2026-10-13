-- placement.lua against every deployment area in the game (data/mapscan.json, from
-- tools/map_scan.py).
--
-- Geometry, for every playable lane:
--   - the lane polygon builds (one area's points are collinear; it has none);
--   - each PLACEMENT_PROFILES and FIXED layout fingerprint matches exactly its own area, using the
--     runtime's matcher;
--   - derive_rescue_points finds two interior points for operators 5 and 6, except on the lanes in
--     SHORT_LANES, and every point it returns is inside its lane.
-- A six-operator deployment on every lane, through the real hooks:
--   - the squad stands on the authored points, and the overflow operators are staged 600 uu
--     outside two different lane edges (the shape of the off-lane staging reports);
--   - the placement trigger must leave six destinations, none added within a tactical tile of
--     another, and must move the overflow operators into the lane wherever the lane allows it;
--   - the relocation then strands them at the world origin, and the repair ladder must put them
--     back: nobody at the origin, no overflow operator sharing a tile, and as many of them inside
--     the lane as before.
-- A FIXED area instead must end up with exactly its layout's spots, in order, and the repair must
-- leave its operators where the relocation put them.
-- Some maps author two destinations closer than a tile (Bespin, HM_TrickLuco_020; neither
-- deploys six), so only pairs involving something the runtime added or moved are checked.
-- The exact points derive_rescue_points returns for every lane (for the destination expansion, for
-- the repair pool, and with nobody standing on a destination) are pinned in tests/data/derived_points.txt, so any change to the geometry
-- shows up as a diff of that file, not just as a changed count.
--   luajit tests/placement_maps_test.lua <Scripts dir> [--print | --write-golden]
-- With --print, writes one line per area instead of asserting. With --write-golden, rewrites
-- tests/data/derived_points.txt from the current code (review the diff before committing it).
local scripts = assert(arg[1], "usage: placement_maps_test.lua <Scripts dir> [--print | --write-golden]")
local print_only = arg[2] == "--print"
local write_golden = arg[2] == "--write-golden"
local here = string.match(arg[0], "^(.*[/\\])") or "./"
local mock = dofile(here .. "ue4ss_mock.lua")
local json = dofile(here .. "json.lua")

-- Lanes where the generic fallback finds fewer than two interior points, with how many it finds.
-- Change this list only together with derive_rescue_points. Until the pair candidates were added
-- (docs/placement-coverage.md), SK_Lothal_035 found 0 and SK_Lothal_050 and SerolonisJob area 1
-- found 1.
local SHORT_LANES = {
    -- Three destinations 100 uu apart in a row: no room for two more. A three-operator mission.
    ["SK_Dantooine_025_gameplay:BP_CombatPreparationArea_C_1"] = 1,
    ["Blank_Gameplay:BP_CombatPreparationArea_C_0"] = 0,             -- collinear: no lane at all
}
local PROFILE_AREAS = {
    ColdMetal = "SK_Kaller_020_Gameplay_Alt:BP_CombatPreparationArea_C_0",
    Kaller025 = "SK_Kaller_025_Gameplay:BP_CombatPreparationArea_C_1",
    FathomFinale = "MM_06_090_FathomAndFinale_Gameplay:BP_CombatPreparationArea_C_2",
}
local FIXED_AREAS = {
    DeepCover = "MM_05_010_UmbaraRescue_Gameplay:BP_CombatPreparationArea_C_0",
    Stillwatch = "MM_04_050_DenBattle_Gameplay:BP_CombatPreparationArea_C_1",
    SmugglersDen2 = "MM_02_050_SlugHQ_Gameplay:BP_CombatPreparationArea_C_2",
}
local TRIGGER = "/Script/BitReactorGame.CombatPreparationArea:TriggerPreCombat"
local RELOCATION = "/Game/Game/Core/Blueprints/BP_CombatPreparationArea.BP_CombatPreparationArea_C:MovePlayerUnitsIntoPosition"
local SQUAD = 6
local CAPSULE = 100
local TILE = 100
local STAGED_OUTSIDE = 600

mock.install({missions = {mock.mission("SK_Kaller_020", 6, 0)}})
mock.load(scripts)
mock.run_until(1000)
mock.run_loops(3)
local P = package.loaded.placement.internals

local file = assert(io.open(here .. "../data/mapscan.json"))
local scan = json.decode(file:read("*a"))
file:close()

local failures, lines, golden = {}, {}, {}
-- Three decimals, halves rounded up in Lua first: LuaJIT builds format an exact tie such as
-- 206.0625 differently (2.1.0 of 2023 prints .063, the 2026 rolling 2.1 prints .062), and the
-- pinned file must read the same on the release workflow's runner as locally.
local function fixed(value)
    return string.format("%.3f", math.floor(value * 1000 + 0.5) / 1000)
end
local function points_text(points)
    local text = {}
    for _, point in ipairs(points) do
        text[#text + 1] = fixed(point.X) .. "/" .. fixed(point.Y) .. "/" .. fixed(point.Z)
    end
    return table.concat(text, " ")
end
local function fail(message) failures[#failures + 1] = message end
local function vector(location) return {X = location[1], Y = location[2], Z = location[3]} end
local function xy(a, b) return math.sqrt((a.X - b.X) ^ 2 + (a.Y - b.Y) ^ 2) end
local function d3(a, b) return math.sqrt((a.X - b.X) ^ 2 + (a.Y - b.Y) ^ 2 + (a.Z - b.Z) ^ 2) end

-- Where an overflow operator is staged: STAGED_OUTSIDE uu beyond the midpoint of a lane edge,
-- away from the centroid, at the edge's height.
local function outside_edge(lane, edge)
    local first, second = lane[edge], lane[edge % #lane + 1]
    local cx, cy = 0, 0
    for _, corner in ipairs(lane) do cx, cy = cx + corner.X / #lane, cy + corner.Y / #lane end
    local mx, my = (first.X + second.X) / 2, (first.Y + second.Y) / 2
    local nx, ny = second.Y - first.Y, -(second.X - first.X)
    local length = math.sqrt(nx * nx + ny * ny)
    nx, ny = nx / length, ny / length
    if nx * (mx - cx) + ny * (my - cy) < 0 then nx, ny = -nx, -ny end
    return {X = mx + nx * STAGED_OUTSIDE, Y = my + ny * STAGED_OUTSIDE,
            Z = ((first.Z or 0) + (second.Z or 0)) / 2 + CAPSULE}
end

for _, area in ipairs(scan.areas) do
    if not area.package:find("/Maps/Test/", 1, true) then
        local name = area.package:match("[^/]+$") .. ":" .. area.area
        local points = {}
        for index, destination in ipairs(area.destinations) do points[index] = vector(destination.location) end
        local lane = P.deployment_polygon(points)

        -- Geometry.
        local matched_by = {}
        local live = {}
        for index, point in ipairs(points) do live[index] = {location = point} end
        for _, profile in ipairs(P.PLACEMENT_PROFILES) do
            if P.match_placement_profile(profile, live) then matched_by[#matched_by + 1] = profile.name end
        end
        for _, profile in ipairs(matched_by) do
            if PROFILE_AREAS[profile] ~= name then fail(name .. ": matched profile " .. profile) end
        end
        local fixed = nil
        for _, layout in ipairs(P.FIXED.layouts) do
            if P.match_placement_profile(layout, live) then
                if FIXED_AREAS[layout.name] ~= name then fail(name .. ": matched fixed layout " .. layout.name) end
                fixed = layout
            elseif FIXED_AREAS[layout.name] == name then
                fail(name .. ": fixed layout " .. layout.name .. " no longer matches")
            end
        end
        for profile, owner in pairs(PROFILE_AREAS) do
            local found = false
            for _, matched in ipairs(matched_by) do found = found or matched == profile end
            if owner == name and not found then fail(name .. ": profile " .. profile .. " no longer matches") end
        end
        local standing = {}
        for index, point in ipairs(points) do
            standing[index] = {location = {X = point.X, Y = point.Y, Z = point.Z + CAPSULE}}
        end
        local derived = lane and P.derive_rescue_points(lane, points, standing, 2) or {}
        if lane then
            -- unsampled: nobody stands on a destination, so heights use RESCUE.capsule_height.
            golden[#golden + 1] = name .. " expansion=[" .. points_text(derived) .. "] repair=["
                .. points_text(P.derive_rescue_points(lane, points, standing, 6, true)) .. "] unsampled=["
                .. points_text(P.derive_rescue_points(lane, points, {}, 2)) .. "]"
        end
        local expected = SHORT_LANES[name] or 2
        if #derived ~= expected then
            fail(string.format("%s: derive_rescue_points found %d points, expected %d", name, #derived, expected))
        end
        for _, point in ipairs(derived) do
            if P.inside_deployment(lane, point) ~= true then fail(name .. ": a derived point is outside its lane") end
        end

        -- A six-operator deployment.
        if lane then
            local destination_actors, units = {}, {}
            for index, point in ipairs(points) do
                destination_actors[index] = mock.actor("TacticalPoint " .. name .. index, point)
                destination_actors[index].properties.OwningTeam = "PlayerTeam"
            end
            for index = 1, math.min(#points, SQUAD) do
                local point = points[index]
                units[index] = mock.actor("Operator" .. index, {X = point.X, Y = point.Y, Z = point.Z + CAPSULE})
            end
            local overflow = {}
            for index = #units + 1, SQUAD do
                local unit = mock.actor("Operator" .. index, outside_edge(lane, index - #points))
                units[index] = unit
                overflow[#overflow + 1] = unit
            end
            -- The array writes into its table, so keep the authored list apart.
            local authored_actors = {}
            for index, actor in ipairs(destination_actors) do authored_actors[index] = actor end
            local destinations = mock.array(destination_actors)
            local area_object = mock.object("BP_CombatPreparationArea_C " .. name,
                {PlayerDestinations = destinations}, {GetWorld = function() return mock.world end})
            mock.first_of["TacticalGameState"] = mock.object("TacticalGameState", {
                PlayerSquad = mock.object("BitReactorGameSquad", {SquadMembers = mock.array(units)}),
            })

            mock.hooks[TRIGGER].pre(area_object)
            mock.run_until(mock.now() + 600)

            if fixed then
                -- The layout's spots, in order, and nothing else.
                local count = destinations:GetArrayNum()
                if count ~= #fixed.spots then
                    fail(string.format("%s: %d destinations, expected the layout's %d", name, count, #fixed.spots))
                end
                local reused = 0
                for index, spot in ipairs(fixed.spots) do
                    local at = index <= count and destinations[index].at or nil
                    if at == nil or d3(at, spot) > 1 then fail(string.format("%s: destination %d isn't spot %d", name, index, index)) end
                    -- A spot on an authored point keeps the authored actor.
                    for authored, point in ipairs(points) do
                        if d3(point, spot) <= 1 then
                            if index <= count and destinations[index] == authored_actors[authored] then
                                reused = reused + 1
                            else
                                fail(string.format("%s: spot %d replaced authored destination %d", name, index, authored))
                            end
                        end
                    end
                end
                -- The relocation strands two operators; the repair must leave them be.
                mock.hooks[RELOCATION].pre(area_object)
                local stranded = {}
                for index = 1, 2 do
                    units[index].at = {X = 40 * index, Y = -30 * index, Z = 261}
                    stranded[index] = {X = 40 * index, Y = -30 * index, Z = 261}
                end
                mock.run_until(mock.now() + 9000)
                for index = 1, 2 do
                    if d3(units[index].at, stranded[index]) > 1 then
                        fail(string.format("%s: the repair moved Operator%d on a fixed area", name, index))
                    end
                end
                lines[#lines + 1] = string.format("%-70s dest=%d fixed=%s spots=%d reused=%d", name, #points, fixed.name, count, reused)
                goto continue
            end

            -- Destinations after the expansion.
            local after = {}
            for index = 1, destinations:GetArrayNum() do after[index] = destinations[index].at end
            if #after ~= SQUAD then fail(string.format("%s: %d destinations after expansion", name, #after)) end
            for i = #points + 1, #after do
                for j = 1, i - 1 do
                    if d3(after[i], after[j]) < TILE then fail(name .. ": an added destination shares a tile") end
                end
            end
            local added_inside = 0
            for index = #points + 1, #after do
                if P.inside_deployment(lane, after[index]) then added_inside = added_inside + 1 end
            end
            local overflow_inside = 0
            for _, unit in ipairs(overflow) do
                if P.inside_deployment(lane, unit.at) then overflow_inside = overflow_inside + 1 end
            end
            -- A profile that only rescues operators the tactical volume rejects leaves these alone:
            -- the stand-in has no volume to reject them (Cold Metal).
            local volume_only = false
            for _, profile in ipairs(P.PLACEMENT_PROFILES) do
                if profile.outside_volume_only and PROFILE_AREAS[profile.name] == name then volume_only = true end
            end
            local can_rescue = volume_only and 0 or math.min(#overflow, #derived)
            if overflow_inside ~= can_rescue then
                fail(string.format("%s: %d of %d overflow operators moved into the lane, expected %d",
                    name, overflow_inside, #overflow, can_rescue))
            end

            -- The relocation strands the overflow operators at the world origin.
            mock.hooks[RELOCATION].pre(area_object)
            for index, unit in ipairs(units) do
                if index <= #points then
                    local point = points[index]
                    unit.at = {X = point.X, Y = point.Y, Z = point.Z + CAPSULE}
                end
            end
            for index, unit in ipairs(overflow) do unit.at = {X = 40 * index, Y = -30 * index, Z = 261} end
            mock.run_until(mock.now() + 9000)

            for i = #points + 1, #units do
                local unit = units[i]
                if math.sqrt(unit.at.X ^ 2 + unit.at.Y ^ 2) <= TILE then
                    fail(string.format("%s: Operator%d left at the world origin", name, i))
                end
                for j = 1, #units do
                    if j ~= i and d3(unit.at, units[j].at) < TILE then
                        fail(string.format("%s: Operator%d and Operator%d share a tile", name, i, j))
                    end
                end
            end
            local repaired_inside = 0
            for _, unit in ipairs(overflow) do
                if P.inside_deployment(lane, unit.at) then repaired_inside = repaired_inside + 1 end
            end
            if repaired_inside ~= can_rescue then
                fail(string.format("%s: %d overflow operators back inside the lane after repair, expected %d",
                    name, repaired_inside, can_rescue))
            end
            lines[#lines + 1] = string.format("%-70s dest=%d derived=%d added=%d inside=%d rescued=%d/%d repaired_inside=%d/%d",
                name, #points, #derived, #after - #points, added_inside, overflow_inside, #overflow,
                repaired_inside, #overflow)
        else
            lines[#lines + 1] = string.format("%-70s dest=%d no lane", name, #points)
        end
    end
    ::continue::
end

local golden_path = here .. "data/derived_points.txt"
if write_golden then
    local out = assert(io.open(golden_path, "w"))
    out:write(table.concat(golden, "\n"), "\n")
    out:close()
    io.stdout:write("wrote ", golden_path, " (", #golden, " lanes)\n")
    os.exit(0)
end
local pinned = {}
for line in assert(io.open(golden_path)):lines() do pinned[#pinned + 1] = line end
for index = 1, math.max(#pinned, #golden) do
    if pinned[index] ~= golden[index] then
        fail("derived points differ from tests/data/derived_points.txt:\n  pinned: "
            .. tostring(pinned[index]) .. "\n  now:    " .. tostring(golden[index]))
    end
end

if print_only then
    io.stdout:write(table.concat(lines, "\n"), "\n")
    for _, message in ipairs(failures) do io.stdout:write("FAIL ", message, "\n") end
    os.exit(0)
end
if #failures > 0 then
    io.stderr:write(table.concat(failures, "\n"), "\n")
    os.exit(1)
end
io.stdout:write("ok (", #lines, " areas)\n")
