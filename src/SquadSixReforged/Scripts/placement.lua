-- Tactical deployment: extra player destinations for operators 5 and 6, rescue of
-- badly staged operators, the post-relocation repair and watchdog passes, and the
-- squadsixrescue console command.
-- Why each rule exists, with the reports behind it: docs/runtime-notes.md.
local Common = require("common")
-- Player settings (MXM/settings.lua), read where they are used: they can change mid-game.
local Settings = require("MXM")
local TARGET_SIZE = Common.TARGET_SIZE
local log = Common.log
local unwrap = Common.unwrap
local valid = Common.valid
local full_name = Common.full_name
local object_key = Common.object_key
local array_count = Common.array_count
local actor_location = Common.actor_location
local actor_rotation = Common.actor_rotation
local copy_vector = Common.copy_vector
local copy_rotator = Common.copy_rotator
local distance_squared = Common.distance_squared

local PLACEMENT_TRIGGER_FUNCTIONS = {
    "/Script/BitReactorGame.CombatPreparationArea:TriggerPreCombat",
    "/Script/BitReactorGame.CombatPreparationArea:TriggerCombatInit",
}
-- The relocation: its pre-hook is the instant before the squad is moved.
-- BP_CombatPreparationArea overrides the native function, so the Blueprint
-- names are the ones that run; all three are hooked and the log says which
-- fired.
local MOVE_UNITS_FUNCTIONS = {
    "/Game/Game/Core/Blueprints/BP_CombatPreparationArea.BP_CombatPreparationArea_C:MovePlayerUnitsIntoPosition",
    "/Game/Game/Core/Blueprints/BP_CombatPreparationArea.BP_CombatPreparationArea_C:ExternalMovePlayerUnitsIntoPosition",
    "/Script/BitReactorGame.CombatPreparationArea:MovePlayerUnitsIntoPosition",
}
local PREPARATION_AREA_CLASS_PATH =
    "/Game/Game/Core/Blueprints/BP_CombatPreparationArea.BP_CombatPreparationArea_C"
local LINKED_AREA_FUNCTION = "GetLinkedTacticalArea"
local INSIDE_AREA_FUNCTION = "IsActorInsideTacticalArea"
local SQUAD_CLASS = "BitReactorGameSquad"
local SQUAD_MEMBERS_PROPERTY = "SquadMembers"
local PREPARATION_CLASS = "BP_CombatPreparationArea_C"
local DESTINATIONS_PROPERTY = "PlayerDestinations"
local TACTICAL_GAME_STATE_CLASS = "TacticalGameState"
local PLAYER_SQUAD_PROPERTY = "PlayerSquad"
local PLAYER_TEAM_PROPERTY = "OwningTeam"
-- One tactical step. 1.0.4 used 25 uu, which accepted a second destination
-- close enough to the first that two operators were relocated on top of
-- each other.
local MIN_DESTINATION_SEPARATION_SQ = 10000.0
-- How far from an authored destination an operator can stand and still be
-- read as part of *this* deployment. This is a membership question, not a
-- judgement about the position: the operators worth rescuing are exactly the
-- ones standing somewhere wrong, so this stays generous.
local MAX_DESTINATION_DISTANCE_SQ = 4000000.0
-- Whether a position is usable is a different question from membership. The
-- deployment lane is the convex hull of the area's authored PlayerDestinations,
-- and a position is acceptable inside it or within one tactical step of its
-- edge. Lanes span a median of about 1,060 uu, so the 2,000 uu membership
-- radius would accept positions well outside them.
local DEPLOYMENT_EDGE_TOLERANCE = 100.0
-- Two operators closer together than one tactical step are on the same tile.
local MIN_UNIT_SEPARATION_SQ = 10000.0
-- An actor sitting this close to the world origin was never placed. Every
-- 1.0.5 report of an operator that could not move at all logged one, and
-- SK_Kaller_020 authors no destination anywhere near 0/0.
local ORIGIN_RADIUS_SQ = 10000.0
-- Staged positions are only believable before the game relocates the squad.
-- The relocation lands somewhere between the trigger and eight seconds after
-- it, so only the rungs inside this window contribute a snapshot.
local STAGING_WINDOW_MS = 500
-- Two automatic attempts per operator. If the game moves it back a third time,
-- fighting it in a loop would be worse than the bug. An explicit console
-- invocation bypasses this budget because the player confirms the failure.
local MAX_REPAIRS_PER_UNIT = 2
-- Enough repair lines to show a whole ladder without flooding the log. Reset
-- per deployment, so later encounters in a session are still reported.
local MAX_REPAIR_REPORTS = 8
-- Repairs run this long after the relocation and no longer. The window has to
-- cover a relocation that settles slowly, and has to close before the player
-- has control -- two operators standing a tile apart in normal play look
-- exactly like the pair this pass exists to separate.
local REPAIR_DELAYS_MS = {100, 500, 2000}
-- Late checks after the repair ladder, for operators displaced after it ends.
-- They act only on hard-invalid signatures, so they never pull back an operator
-- the player has started moving.
local WATCHDOG_DELAYS_MS = {3500, 5000, 7000, 7500}
-- The manual peer fallback exists only for Sambuco's literal spawn-bad
-- shape: exactly two hard-invalid outliers, far from all remaining distinct
-- operators forming one compact live cluster. It refuses looser guesses.
local MANUAL_PEER_CLUSTER_RADIUS_SQ = 1000000.0
local MANUAL_PEER_OUTLIER_DISTANCE_SQ = 4000000.0
-- Both relocation hook names fire for one event within milliseconds; a
-- genuinely separate relocation comes seconds later. Coalescing on time tells
-- the two apart.
local RELOCATION_COALESCE_MS = 250
-- Each ladder is bounded, and MAX_REPAIRS_PER_UNIT still caps how often its
-- automatic passes can move one operator, so this limits pathological firing.
local MAX_RELOCATION_LADDERS = 4

-- Placement profiles: exact corrections for maps whose staging is known to be
-- bad. Each is matched by the area's authored PlayerDestinations, not by a
-- mission name or object path, so it applies only to the map whose cooked
-- geometry justifies it.
local PLACEMENT_PROFILE_MATCH_RADIUS_SQ = 2500.0
local PLACEMENT_PROFILE_MEMBER_RADIUS_SQ = 40000.0
-- The geometry of a derived rescue point, in one table to stay clear of Lua's
-- 200-local limit.
local RESCUE = {}
-- A teleport can settle a few uu from the request; within 10 uu counts as the
-- same rescue point. Deliberately smaller than a tactical tile, which would
-- accept a point still outside the lane.
RESCUE.settled_radius_sq = 100.0
-- An edge midpoint lies on the lane's boundary, where an inside test or a tile
-- snap can round the wrong way, so derived points are pulled this fraction of
-- the way to the centroid. A profile's rescues are inset only when it sets
-- inset_rescues; one the map itself authors is used as written.
RESCUE.inset = 0.15
-- A derived point takes its height by interpolating along its edge. An edge
-- that rises more than this spans a drop rather than a slope or stairs (across
-- all 89 lanes the rises are continuous up to about 220 uu, then gapped), so it
-- is rejected rather than given a height in mid-air.
RESCUE.level_tolerance = 250.0
-- An operator's capsule height above its destination, used when no operator in
-- this deployment stands on one to measure from. Erring high is safe: a point
-- slightly above the floor drops onto it, one below it is inside geometry.
RESCUE.capsule_height = 100.0
-- Where a lane is too narrow for its inset edge midpoints (they land within a
-- tile of a destination), derive_rescue_points also tries these points along
-- the segment between every pair of authored destinations.
RESCUE.pair_fractions = {1 / 3, 0.5, 2 / 3}
-- Destinations are added for every unit at deployment, story characters that join through the
-- mission included (Stillwatch: six selected plus Trick on six authored points left one
-- operator standing in the open), up to this many in all.
RESCUE.max_destinations = 8
-- Cover for added points: the game's nearest cover pocket within this range of a derived point
-- replaces it when it's in the lane, on the navmesh, a tile from everyone and facing the
-- encounter (within acos(cover_facing) of the direction from the lane to its tactical volume's
-- centre). cover_pool derived points are searched around, besides the ones wanted.
RESCUE.cover_range = 250.0
RESCUE.cover_facing = 0.5
RESCUE.cover_pool = 8
-- The lane is also searched on a grid this far apart (a tactical tile), so cover the derived
-- points don't happen to be near is found too: Smugglers' Den's first area showed three pockets
-- around the derived points, two facing sideways. At most cover_grid_max grid points.
RESCUE.cover_grid = 100.0
RESCUE.cover_grid_max = 80
-- The game's own destinations (the improve_game_spots setting): one already in cover facing the
-- encounter is kept, found by a search this close to it; otherwise it moves to the best usable
-- cover within cover_improve_range, searched around it at cover_improve_offsets in eight
-- directions.
RESCUE.cover_here_range = 60.0
RESCUE.cover_improve_range = 200.0
RESCUE.cover_improve_offsets = {100.0, 200.0}
-- A volume centre closer than this to the lane's centroid gives no usable direction, so any
-- cover is taken.
RESCUE.cover_min_forward = 300.0
-- The navmesh, used as the floor under a derived point and to tell whether an
-- operator can walk at all.
local FLOOR = {}
FLOOR.system_path = "/Script/NavigationSystem.Default__NavigationSystemV1"
FLOOR.project_function = "/Script/NavigationSystem.NavigationSystemV1:K2_ProjectPointToNavigation"
-- How far from a point to look for the navmesh: a tile's half-width sideways,
-- and up and down by the most a derived point's height has been seen to be off
-- (155 uu, Retake Luunata's lower level).
FLOOR.extent = {X = 50, Y = 50, Z = 250}
-- A projection that slides further than this sideways found the navmesh beside
-- the point, not under it.
FLOOR.max_slide_sq = 2500.0
-- Mission start: the map's spawn transforms past the stock four aren't always
-- usable. Squads up to this size are left to the game.
local SPAWN = {}
SPAWN.stock_squad = 4
SPAWN.interval_ms = 2000
-- Retake Luunata's intro alone holds the squad for about 70 s.
SPAWN.watch_ms = 300000
-- Checks an operator must stand still across before it counts as stuck rather
-- than on its way somewhere.
SPAWN.settle_checks = 3
-- The squadmate an operator is moved beside must be within this distance.
SPAWN.peer_radius_sq = 4000000.0
-- Distances from that squadmate to try, each in eight directions.
SPAWN.offsets = {150, 250}
-- Most the floor beside the squadmate may differ from its own: further is a
-- ledge or a different level.
SPAWN.max_step = 100.0
local PLACEMENT_PROFILES = {
    {
        name = "ColdMetal",
        -- The fifth staged position is valid on this map; rescue only an
        -- operator the linked tactical volume conclusively rejects.
        outside_volume_only = true,
        -- The map's own skirmish-intro capsule transform, 513 uu outside the
        -- quadrilateral, used as authored; the tactical-volume check after the
        -- move confirms it.
        destinations = {
            {X = 700, Y = -2500, Z = 30},
            {X = 950, Y = -2150, Z = 0},
            {X = 950, Y = -1650, Z = 0},
            {X = 650, Y = -1350, Z = 0},
        },
        rescues = {
            {X = 150, Y = -1650, Z = 100},
        },
    },
    {
        name = "Kaller025",
        -- Midpoints of the left and right edges, drawn in by RESCUE.inset. Z is
        -- the capsule centre measured at the surrounding TacticalPoints.
        inset_rescues = true,
        destinations = {
            {X = 5000, Y = -1140, Z = 400},
            {X = 5460, Y = -1200, Z = 400},
            {X = 5000, Y = -1500, Z = 400},
            {X = 5450, Y = -1700, Z = 400},
        },
        rescues = {
            {X = 5000, Y = -1320, Z = 500},
            {X = 5455, Y = -1450, Z = 500},
        },
    },
    {
        name = "FathomFinale",
        -- MM_06_090, preparation area 2: midpoints of the lane's two side
        -- edges, drawn in by RESCUE.inset.
        inset_rescues = true,
        destinations = {
            {X = 22650, Y = 9150, Z = 27130},
            {X = 22650, Y = 10250, Z = 27130},
            {X = 22296.464466, Y = 9603.535534, Z = 27130},
            {X = 22296.464466, Y = 9796.464466, Z = 27130},
        },
        rescues = {
            {X = 22473.232233, Y = 9376.767767, Z = 27200},
            {X = 22473.232233, Y = 10023.232233, Z = 27200},
        },
    },
}
-- Hand-picked deployment spots that replace an area's own: when an area's authored destinations
-- match `destinations` (the same fingerprint match as the profiles), its destination list becomes
-- `spots`, in order, whatever the squad size. The game's relocation then walks the squad onto
-- them like onto its own; which unit takes which spot is still the game's choice. The mod's
-- repair passes leave a fixed area alone: its spots were checked by playing them, and some sit
-- outside the authored lane on purpose. Z is a destination's height, about 74 uu below the
-- standing operator it was read from.
-- One table rather than separate locals: the main chunk is near Lua's 200-local ceiling.
local FIXED = {
    layouts = {
        {
            name = "DeepCover",
            -- MM_05_010_UmbaraRescue ("Deep Cover"), its only area: four authored points and Rex's.
            destinations = {
                {X = -1350, Y = -1060, Z = 224.753},
                {X = -1600, Y = -1070, Z = 220.563},
                {X = -1994.73, Y = -660.889, Z = 336.141},
                {X = -2554.776, Y = -232.604, Z = 400},
                {X = -1800, Y = -696.672, Z = 211.157},
            },
            -- Picked by the user in game (2026-10-12), in their order of preference.
            spots = {
                {X = -320.771, Y = -340.116, Z = 227},       -- forward, beside the area's centre
                {X = -849.179, Y = -555.740, Z = 31},        -- lower ground
                {X = -1549.245, Y = -410.000, Z = 132},      -- lower ground
                {X = -1800, Y = -696.672, Z = 211.157},      -- authored: TacticalPoint_Rex
                {X = -751.056, Y = -1060.000, Z = 220},
                {X = -1600, Y = -1070, Z = 220.563},         -- authored: PlayerTacticalPoint_1.2
                {X = -1350, Y = -1060, Z = 224.753},         -- authored: PlayerTacticalPoint_1.1
            },
        },
        {
            name = "Stillwatch",
            -- MM_04_050_DenBattle ("Stillwatch"), its only area: six authored points, two named for
            -- Trick and Tel-Rea. Trick joins through the mission, so six selected are seven units.
            destinations = {
                {X = 3177.759, Y = 7543.714, Z = -700},
                {X = 2172.991, Y = 7556.39, Z = -691.807},
                {X = 2908.868, Y = 7947.725, Z = -700},
                {X = 2100, Y = 8000, Z = -700},
                {X = 3485.689, Y = 8044.545, Z = -700},
                {X = 2856.959, Y = 7351.71, Z = -700},
            },
            -- The authored six, then a seventh picked by the user in game (2026-10-12).
            spots = {
                {X = 3177.759, Y = 7543.714, Z = -700},
                {X = 2172.991, Y = 7556.39, Z = -691.807},
                {X = 2908.868, Y = 7947.725, Z = -700},
                {X = 2100, Y = 8000, Z = -700},
                {X = 3485.689, Y = 8044.545, Z = -700},
                {X = 2856.959, Y = 7351.71, Z = -700},
                {X = 2700, Y = 7847, Z = -700},              -- same floor as authored 4
            },
        },
        {
            name = "SmugglersDen2",
            -- MM_02_050_SlugHQ ("Smugglers' Den"), the second area: four authored points, enemies
            -- to +X. Tel-Rea joins after the trigger and keeps the mission's own spot, so six.
            destinations = {
                {X = 2400, Y = 12100, Z = -400},
                {X = 2100, Y = 12300, Z = -400},
                {X = 2350, Y = 12650, Z = -400},
                {X = 2550, Y = 13000, Z = -400},
            },
            -- The authored four, which the user kept, then two picked in game (2026-10-12).
            spots = {
                {X = 2400, Y = 12100, Z = -400},
                {X = 2100, Y = 12300, Z = -400},
                {X = 2350, Y = 12650, Z = -400},
                {X = 2550, Y = 13000, Z = -400},
                {X = 2034.652, Y = 12956.393, Z = -400},
                {X = 2440, Y = 12448.3, Z = -400},
            },
        },
    },
    -- Areas whose destinations were replaced, by object key, for the repair passes.
    applied = {},
    -- A spot this close to an authored destination is that destination.
    same_point_sq = 25.0,
}

local registered_placement_hook = false
local registered_relocation_hook = false
local registered_area_notification = false
local registered_rescue_command = false
local relocation_prehook_ran = false
local registered_relocation_names = {}
local relocation_fired_name = ""
local relocation_fired_names = {}
local relocation_firing_count = 0
local relocation_ladders = {}
local relocation_scheduled = {}
local active_deployment_key = ""
local active_deployment_area = nil
-- A silent pass has to be distinguishable from a pass that never ran.
local repair_passes = 0
local repair_units_seen = 0
local repair_restored_total = 0
local registered_placement_triggers = {}
local destination_expansion_reported = false
local placement_failure_reported = false
local reported_placement_triggers = {}
local reported_squads = {}
local placement_attempts = {}
local last_member_stats = {raw = 0, valid = 0, in_world = 0, located = 0, near = 0, route = "none"}
local staged_positions = {}
local staging_window_open = false
local repair_counts = {}
local repair_reported = 0
local placement_rescue_reported = {}
-- Where the repair put each operator this deployment, by unit key, for the
-- drift check.
local restored_positions = {}
-- Deployments opened since load; the spawn watch stops when this changes.
local deployments_begun = 0

-- An actor the placement never reached sits at the world origin, plus its
-- capsule height, so the test ignores Z. No authored destination is within 224
-- uu of the XY origin.
local function at_world_origin(location)
    if location == nil then return false end
    return location.X * location.X + location.Y * location.Y <= ORIGIN_RADIUS_SQ
end

-- nil means the reflected test was unavailable; only a conclusive false is
-- allowed to reject a position. This preserves the distance fallback on game
-- builds where the tactical-volume call cannot be made through UE4SS.
local function actor_inside_tactical_area(volume, actor)
    if volume == nil or not valid(actor) then return nil end
    local ok, inside = pcall(function()
        return volume[INSIDE_AREA_FUNCTION](volume, actor)
    end)
    if ok and type(inside) == "boolean" then return inside end
    return nil
end

-- Where the game itself stood each operator before combat: on approved ground
-- and on the grid, and most deployment areas author no spare TacticalPoint to
-- fall back on. First reading wins, and only inside the staging window.
-- `trusted` marks a position this mod chose; the repair tests untrusted
-- snapshots against the authored lane before using them.
local function remember_staged_position(member, entry, volume, trusted)
    if not staging_window_open then return end
    local key = object_key(member)
    if key == "" or staged_positions[key] ~= nil then return end
    if entry.location == nil then return end
    -- An operator already at the origin was never placed; do not enshrine it.
    if at_world_origin(entry.location) then return end
    -- An initial spawn can itself be outside the playable volume (Cold Metal),
    -- so never keep a position the game rejects.
    if actor_inside_tactical_area(volume, member) == false then return end
    staged_positions[key] = {
        actor = member,
        location = copy_vector(entry.location),
        rotation = entry.rotation ~= nil and copy_rotator(entry.rotation) or nil,
        trusted = trusted and true or false,
    }
end

-- The player units standing in this deployment area, and how the count was
-- reached. The filter is distance to an authored destination; comparing worlds
-- by name rejected every unit, so the world match is only counted for the log.
local function collect_members(members, area_world_name, anchors, volume, stats)
    local result = {}
    local count = array_count(members)
    if count < 0 then return result end
    stats.raw = stats.raw + count
    for index = 1, count do
        local member = unwrap(members[index])
        if valid(member) then
            stats.valid = stats.valid + 1

            local world_ok, member_world = pcall(function() return member:GetWorld() end)
            if world_ok and valid(member_world)
                and full_name(member_world) == area_world_name then
                stats.in_world = stats.in_world + 1
            end

            local location = actor_location(member)
            if location ~= nil then
                stats.located = stats.located + 1
                local nearest = math.huge
                for _, anchor in ipairs(anchors) do
                    nearest = math.min(nearest, distance_squared(location, anchor))
                end
                if nearest <= MAX_DESTINATION_DISTANCE_SQ then
                    stats.near = stats.near + 1
                    local entry = {
                        actor = member,
                        location = copy_vector(location),
                        rotation = actor_rotation(member),
                        inside_volume = actor_inside_tactical_area(volume, member),
                    }
                    result[#result + 1] = entry
                    remember_staged_position(member, entry, volume)
                end
            end
        end
    end
    return result
end

-- Route two: the squad objects themselves, for the case where the game state
-- has no player squad to offer yet.
local function squads_near(area_world_name, anchors, volume, stats)
    local found_ok, squads = pcall(function() return FindAllOf(SQUAD_CLASS) end)
    if not found_ok or squads == nil then return {} end

    local result = {}
    for _, squad in pairs(squads) do
        if valid(squad) then
            local members_ok, members = pcall(function()
                return squad:GetPropertyValue(SQUAD_MEMBERS_PROPERTY)
            end)
            if members_ok and members ~= nil then
                for _, member in ipairs(collect_members(
                    members, area_world_name, anchors, volume, stats)) do
                    result[#result + 1] = member
                end
            end
        end
    end
    return result
end

local function player_squad_members(area, anchors)
    local stats = {raw = 0, valid = 0, in_world = 0, located = 0, near = 0, route = "none"}
    if anchors == nil or #anchors < 1 then return {}, stats end

    local world_ok, world = pcall(function() return area:GetWorld() end)
    local world_name = (world_ok and valid(world)) and full_name(world) or ""
    local volume = nil
    local volume_ok, linked = pcall(function()
        return area[LINKED_AREA_FUNCTION](area)
    end)
    if volume_ok and valid(linked) then volume = linked end

    local state_ok, state = pcall(function() return FindFirstOf(TACTICAL_GAME_STATE_CLASS) end)
    if state_ok and valid(state) then
        local squad_ok, squad = pcall(function()
            return unwrap(state:GetPropertyValue(PLAYER_SQUAD_PROPERTY))
        end)
        if squad_ok and valid(squad) then
            local members_ok, members = pcall(function()
                return squad:GetPropertyValue(SQUAD_MEMBERS_PROPERTY)
            end)
            if members_ok and members ~= nil then
                local result = collect_members(members, world_name, anchors, volume, stats)
                if #result > 0 then
                    stats.route = "player_squad"
                    -- How many operators the squad actually holds, as opposed
                    -- to how many passed the proximity filter. Only this route
                    -- can say: the fallback sweeps every squad in the level,
                    -- enemies included.
                    stats.squad_size = array_count(members)
                    return result, stats
                end
            end
        end
    end

    local nearby = squads_near(world_name, anchors, volume, stats)
    if #nearby > 0 then
        stats.route = "squad_objects"
        return nearby, stats
    end
    return {}, stats
end

local function member_stats_text(stats)
    return "route=" .. stats.route
        .. " raw=" .. tostring(stats.raw)
        .. " valid=" .. tostring(stats.valid)
        .. " in_world=" .. tostring(stats.in_world)
        .. " located=" .. tostring(stats.located)
        .. " near=" .. tostring(stats.near)
end

-- Every player unit in the level, unfiltered. The repair pass has to see the
-- operators the proximity filter throws away, because being thrown away is
-- exactly the symptom it exists to fix.
local function every_player_unit()
    local state_ok, state = pcall(function() return FindFirstOf(TACTICAL_GAME_STATE_CLASS) end)
    if not state_ok or not valid(state) then return {} end
    local squad_ok, squad = pcall(function()
        return unwrap(state:GetPropertyValue(PLAYER_SQUAD_PROPERTY))
    end)
    if not squad_ok or not valid(squad) then return {} end
    local members_ok, members = pcall(function()
        return squad:GetPropertyValue(SQUAD_MEMBERS_PROPERTY)
    end)
    if not members_ok or members == nil then return {} end

    local result = {}
    local count = array_count(members)
    for index = 1, count do
        local member = unwrap(members[index])
        if valid(member) then
            local location = actor_location(member)
            if location ~= nil then
                result[#result + 1] = {
                    actor = member,
                    key = object_key(member),
                    location = copy_vector(location),
                }
            end
        end
    end
    return result
end

-- Destination actors this mod spawned, by object key. The authored lane is
-- the map author's four points; once two more have been appended, the hull of
-- "every current destination" is a shape nobody designed. Keeping the two
-- apart lets a rescue derive its targets from the lane the mission actually
-- authored rather than from the lane the mod just widened.
local synthesised_destinations = {}

local function destination_anchors(area, authored_only)
    local list_ok, destinations = pcall(function()
        return area:GetPropertyValue(DESTINATIONS_PROPERTY)
    end)
    if not list_ok or destinations == nil then return {} end

    local anchors = {}
    local count = array_count(destinations)
    for index = 1, count do
        local point = unwrap(destinations[index])
        local location = valid(point) and actor_location(point) or nil
        if location ~= nil
            and not (authored_only and synthesised_destinations[object_key(point)]) then
            anchors[#anchors + 1] = copy_vector(location)
        end
    end
    return anchors
end

-- The tactical volume the deployment area belongs to, or nil. Worth having
-- because it can answer "is this operator still in the playable space?"
-- itself, which is the question the out-of-bounds reports are really asking.
local function linked_tactical_area(area)
    local ok, volume = pcall(function() return area[LINKED_AREA_FUNCTION](area) end)
    if ok and valid(volume) then return volume end
    return nil
end

local function xy_distance_squared(left, right)
    local x = left.X - right.X
    local y = left.Y - right.Y
    return x * x + y * y
end

-- The navmesh under or near a point, or nil when there is none within
-- FLOOR.extent or the call can't be made (an older build, or the navmesh not
-- loaded yet). Callers treat nil as "no answer", never as proof of anything on
-- its own.
local function navigation_floor(context, point)
    local system = StaticFindObject(FLOOR.system_path)
    if not valid(system) or not valid(context) or point == nil then return nil end
    local projected = {}
    local ok, found = pcall(function()
        return system:K2_ProjectPointToNavigation(context, point, projected, nil, nil, FLOOR.extent)
    end)
    if not ok or found ~= true or type(projected.Z) ~= "number" then return nil end
    local floor = {X = projected.X, Y = projected.Y, Z = projected.Z}
    if xy_distance_squared(floor, point) > FLOOR.max_slide_sq then return nil end
    return floor
end

-- How high an operator's location (its capsule's centre) stands above the
-- navmesh: the median over the squad, else RESCUE.capsule_height.
local function capsule_above_floor(context, units)
    local heights = {}
    for _, unit in ipairs(units) do
        if unit.location ~= nil and not at_world_origin(unit.location) then
            local floor = navigation_floor(context, unit.location)
            local height = floor ~= nil and unit.location.Z - floor.Z or nil
            if height ~= nil and height > 0 and height < FLOOR.extent.Z then
                heights[#heights + 1] = height
            end
        end
    end
    if #heights < 1 then return RESCUE.capsule_height end
    table.sort(heights)
    return heights[math.floor((#heights + 1) / 2)]
end

-- Put derived points on the floor. derive_rescue_points interpolates a point's
-- height between authored destinations, and those can sit well above the floor
-- themselves (one of Retake Luunata's lower-level points is 92 uu up), so a
-- derived point can float: 105 and 155 uu there, about 117 on SK_Lothal_035.
-- Where the navmesh answers under a point, it goes to the navmesh plus the
-- squad's capsule height; elsewhere it keeps its interpolated height, which
-- errs high and drops. Returns how many points moved and the largest change.
local function settle_on_floor(context, points, units)
    local settled, largest, capsule = 0, 0, nil
    for _, point in ipairs(points) do
        if point.lift ~= nil then
            local guess = {X = point.X, Y = point.Y, Z = point.Z - point.lift}
            local floor = navigation_floor(context, guess)
            if floor ~= nil and math.abs(floor.Z - guess.Z) <= RESCUE.level_tolerance then
                capsule = capsule or capsule_above_floor(context, units)
                local z = floor.Z + capsule
                if math.abs(z - point.Z) > math.abs(largest) then largest = z - point.Z end
                point.Z = z
                settled = settled + 1
            end
            point.lift = nil
        end
    end
    return settled, largest
end

-- A test for derived points: is there navmesh under the floor they assume?
-- In Dark Waters one derived point sat under a prop with no navmesh; the
-- operator rescued onto it only reached the floor because the game's
-- relocation walked them off it. nil, so no test, when the navmesh answers
-- under none of the authored destinations: then it isn't loaded here, or the
-- call can't be made, and a missing answer proves nothing.
local function walkable_test(context, destinations)
    local answered = false
    for _, destination in ipairs(destinations) do
        if navigation_floor(context, destination) ~= nil then
            answered = true
            break
        end
    end
    if not answered then return nil end
    return function(point)
        return navigation_floor(context,
            {X = point.X, Y = point.Y, Z = point.Z - (point.lift or 0)}) ~= nil
    end
end

-- Cancel the walk the game gave an operator. A teleport moves the actor but
-- not its controller's path: in Retake Luunata two operators the watchdog put
-- back on the lane then walked about 3,500 uu to wherever the relocation had
-- sent them. Returns whether the controller took the call.
local function halt(actor)
    local ok = pcall(function()
        local controller = unwrap(actor:GetController())
        controller:StopMovement()
    end)
    return ok
end

local function transform_profile_point(transform, point)
    return {
        X = transform.tx + transform.scale
            * (transform.cos * point.X - transform.sin * point.Y),
        Y = transform.ty + transform.scale
            * (transform.sin * point.X + transform.cos * point.Y),
        Z = point.Z + transform.tz,
    }
end

-- The deployment lane: the convex hull, in XY, of the area's own authored
-- destinations. Returned counter-clockwise. Fewer than three distinct points
-- cannot bound anything, so the caller falls back to the distance test.
--
-- The hull is built in XY and every test against it ignores Z, but each
-- corner keeps the Z of the destination it came from. derive_rescue_points
-- needs it: a point invented on an edge whose two ends sit at different
-- heights is not on either level, and without the corner heights there is no
-- way to notice. Duplicate XY keeps the first Z, which is arbitrary only for
-- destinations stacked exactly on top of each other.
local function deployment_polygon(locations)
    local points, seen = {}, {}
    for _, location in ipairs(locations) do
        local key = string.format("%.1f/%.1f", location.X, location.Y)
        if not seen[key] then
            seen[key] = true
            points[#points + 1] =
                {X = location.X, Y = location.Y, Z = location.Z or 0}
        end
    end
    if #points < 3 then return nil end
    table.sort(points, function(left, right)
        if left.X ~= right.X then return left.X < right.X end
        return left.Y < right.Y
    end)

    local function cross(origin, first, second)
        return (first.X - origin.X) * (second.Y - origin.Y)
            - (first.Y - origin.Y) * (second.X - origin.X)
    end

    local lower = {}
    for _, point in ipairs(points) do
        while #lower >= 2
            and cross(lower[#lower - 1], lower[#lower], point) <= 0 do
            lower[#lower] = nil
        end
        lower[#lower + 1] = point
    end
    local upper = {}
    for index = #points, 1, -1 do
        local point = points[index]
        while #upper >= 2
            and cross(upper[#upper - 1], upper[#upper], point) <= 0 do
            upper[#upper] = nil
        end
        upper[#upper + 1] = point
    end

    local hull = {}
    for index = 1, #lower - 1 do hull[#hull + 1] = lower[index] end
    for index = 1, #upper - 1 do hull[#hull + 1] = upper[index] end
    if #hull < 3 then return nil end
    return hull
end

local function distance_to_segment(point, first, second)
    local dx, dy = second.X - first.X, second.Y - first.Y
    local length = dx * dx + dy * dy
    local t = 0.0
    if length > 0 then
        t = ((point.X - first.X) * dx + (point.Y - first.Y) * dy) / length
        if t < 0 then t = 0 elseif t > 1 then t = 1 end
    end
    local nx, ny = first.X + t * dx - point.X, first.Y + t * dy - point.Y
    return math.sqrt(nx * nx + ny * ny)
end

-- Inside the deployment lane, or within one tactical step of its edge. The
-- tolerance is there because an operator standing on an authored destination
-- sits on the hull boundary, and because a capsule settles a little off the
-- point it was placed on.
local function inside_deployment(polygon, point)
    if polygon == nil or point == nil then return nil end
    local sign = nil
    local inside = true
    for index = 1, #polygon do
        local first = polygon[index]
        local second = polygon[index % #polygon + 1]
        local side = (second.X - first.X) * (point.Y - first.Y)
            - (second.Y - first.Y) * (point.X - first.X)
        if side ~= 0 then
            local positive = side > 0
            if sign == nil then sign = positive
            elseif positive ~= sign then inside = false break end
        end
    end
    if inside then return true end
    for index = 1, #polygon do
        local first = polygon[index]
        local second = polygon[index % #polygon + 1]
        if distance_to_segment(point, first, second) <= DEPLOYMENT_EDGE_TOLERANCE then
            return true
        end
    end
    return false
end

-- Pick up to `wanted` points from `pool`, none within a tile of another,
-- fitting as many as possible: repeatedly take the point that blocks the fewest
-- others, then the most open one. (Taking the most open point first can block
-- two that would both have fit, as in a corridor.)
local function spread_points(pool, wanted)
    local chosen, remaining = {}, {}
    for index, point in ipairs(pool) do remaining[index] = point end
    while #chosen < wanted and #remaining > 0 do
        local best, best_conflicts = nil, nil
        for _, point in ipairs(remaining) do
            local conflicts = 0
            for _, other in ipairs(remaining) do
                if other ~= point
                    and xy_distance_squared(point, other) < MIN_DESTINATION_SEPARATION_SQ then
                    conflicts = conflicts + 1
                end
            end
            local better = best == nil or conflicts < best_conflicts
                or (conflicts == best_conflicts and (point.clearance > best.clearance
                    or (point.clearance == best.clearance and (point.X < best.X
                        or (point.X == best.X and point.Y < best.Y)))))
            if better then best, best_conflicts = point, conflicts end
        end
        chosen[#chosen + 1] = best
        local kept = {}
        for _, point in ipairs(remaining) do
            if point ~= best
                and xy_distance_squared(point, best) >= MIN_DESTINATION_SEPARATION_SQ then
                kept[#kept + 1] = point
            end
        end
        remaining = kept
    end
    return chosen
end

-- Rescue points for a map without a profile: inset midpoints of the authored
-- lane's edges. Height is the median offset of operators already standing on
-- destinations, else RESCUE.capsule_height; `lift` on each point records that
-- offset for settle_on_floor.
--
-- `ignore_units` keeps occupied points in the pool, for the repair, which
-- checks occupancy itself; the destination expansion leaves it off, since a
-- destination on a standing operator is worse.
--
-- A lane whose edge points can't hold the operators past its authored
-- destinations also gets points between pairs of destinations
-- (RESCUE.pair_fractions), chosen by spread_points. Lanes the edge points
-- already serve get exactly the edge points, as before.
--
-- `walkable` (from walkable_test) drops candidates with no navmesh under them,
-- so the pair points can stand in. `slots` is how many destinations the lane
-- must hold in all (TARGET_SIZE unless the expansion passes the squad's size).
-- Returns the points and how many candidates it dropped.
local function derive_rescue_points(polygon, destinations, units, wanted, ignore_units, walkable, slots)
    if polygon == nil or wanted < 1 then return {}, 0 end
    local unwalkable = 0
    local function walkable_point(point)
        if walkable == nil or walkable(point) then return true end
        unwalkable = unwalkable + 1
        return false
    end

    local cx, cy = 0, 0
    for _, corner in ipairs(polygon) do cx, cy = cx + corner.X, cy + corner.Y end
    cx, cy = cx / #polygon, cy / #polygon

    local offsets = {}
    for _, unit in ipairs(units) do
        local nearest, best = math.huge, nil
        for _, destination in ipairs(destinations) do
            local distance = xy_distance_squared(unit.location, destination)
            if distance < nearest then nearest, best = distance, destination end
        end
        if best ~= nil and nearest <= MIN_UNIT_SEPARATION_SQ then
            offsets[#offsets + 1] = unit.location.Z - best.Z
        end
    end
    local offset = RESCUE.capsule_height
    if #offsets > 0 then
        table.sort(offsets)
        offset = offsets[math.floor((#offsets + 1) / 2)]
    end

    -- Squared clearance from the destinations and units, and whether a point is
    -- at least a tile from every destination (and unit, unless ignored).
    local function clearance_of(point)
        local clearance = math.huge
        for _, destination in ipairs(destinations) do
            clearance = math.min(clearance, xy_distance_squared(point, destination))
        end
        local separated = clearance >= MIN_DESTINATION_SEPARATION_SQ
        for _, unit in ipairs(units) do
            clearance = math.min(clearance, xy_distance_squared(point, unit.location))
        end
        if not ignore_units then
            separated = separated and clearance >= MIN_DESTINATION_SEPARATION_SQ
        end
        return clearance, separated
    end

    -- One candidate per authored edge, drawn in off the boundary exactly as
    -- the profiles are. A boundary point is where a strict inside test or a
    -- tile snap can round back out of the lane.
    local candidates = {}
    for index = 1, #polygon do
        local first = polygon[index]
        local second = polygon[index % #polygon + 1]
        local mx, my = (first.X + second.X) / 2, (first.Y + second.Y) / 2
        local point = {
            X = mx + (cx - mx) * RESCUE.inset,
            Y = my + (cy - my) * RESCUE.inset,
        }
        -- Interpolate the height along the edge rather than take the nearest
        -- destination's: on a lane with corners at two heights the nearest can
        -- be on the other level.
        local rise = math.abs((first.Z or 0) - (second.Z or 0))
        local clearance, separated = clearance_of(point)
        if separated and rise <= RESCUE.level_tolerance then
            point.Z = ((first.Z or 0) + (second.Z or 0)) / 2 + offset
            point.lift = offset
            point.clearance = clearance
            if walkable_point(point) then candidates[#candidates + 1] = point end
        end
    end

    -- Furthest from anything already occupied first, so two rescued operators
    -- do not end up crowding the same corner of the lane.
    table.sort(candidates, function(left, right)
        if left.clearance ~= right.clearance then
            return left.clearance > right.clearance
        end
        if left.X ~= right.X then return left.X < right.X end
        return left.Y < right.Y
    end)

    local chosen = {}
    for _, point in ipairs(candidates) do
        if #chosen >= wanted then break end
        local clear = true
        for _, taken in ipairs(chosen) do
            if xy_distance_squared(point, taken) < MIN_DESTINATION_SEPARATION_SQ then
                clear = false
                break
            end
        end
        if clear then chosen[#chosen + 1] = point end
    end

    -- Narrow lanes: enough for the operators past the authored destinations?
    local needed = math.min(wanted, (slots or TARGET_SIZE) - #destinations)
    if #chosen >= needed then return chosen, unwalkable end
    local pool = {}
    for _, point in ipairs(candidates) do pool[#pool + 1] = point end
    for i = 1, #destinations do
        for j = i + 1, #destinations do
            local first, second = destinations[i], destinations[j]
            local rise = (second.Z or 0) - (first.Z or 0)
            if math.abs(rise) <= RESCUE.level_tolerance then
                for _, fraction in ipairs(RESCUE.pair_fractions) do
                    local point = {
                        X = first.X + (second.X - first.X) * fraction,
                        Y = first.Y + (second.Y - first.Y) * fraction,
                    }
                    local clearance, separated = clearance_of(point)
                    if separated and inside_deployment(polygon, point) ~= false then
                        point.Z = (first.Z or 0) + rise * fraction + offset
                        point.lift = offset
                        point.clearance = clearance
                        if walkable_point(point) then pool[#pool + 1] = point end
                    end
                end
            end
        end
    end
    local spread = spread_points(pool, wanted)
    if #spread > #chosen then return spread, unwalkable end
    return chosen, unwalkable
end

-- A new destination actor like `template` (its class, team and facing) at `location`, or nil.
-- A declined teleport returns false and leaves the actor at the origin, so that spawn is
-- destroyed rather than listed.
local function spawn_destination(template, world, location)
    local class_ok, point_class = pcall(function() return template:GetClass() end)
    if not class_ok or not valid(point_class) or not valid(world) then return nil end
    local facing = actor_rotation(template)
    facing = facing ~= nil and copy_rotator(facing) or {}
    local spawn_ok, point = pcall(function() return world:SpawnActor(point_class, location, facing) end)
    if not spawn_ok or not valid(point) then return nil end
    local team = nil
    pcall(function() team = unwrap(template:GetPropertyValue(PLAYER_TEAM_PROPERTY)) end)
    if team ~= nil then pcall(function() point[PLAYER_TEAM_PROPERTY] = team end) end
    local moved, accepted = pcall(function()
        return point:K2_SetActorLocationAndRotation(location, facing, false, {}, true)
    end)
    if moved and accepted ~= false and not at_world_origin(actor_location(point) or location) then
        return point
    end
    pcall(function() point:K2_DestroyActor() end)
    return nil
end

-- The game's cover, for the points the mod adds (RESCUE.cover_*).
local COVER = {
    library = "/Script/BitReactorGame.Default__BRG_TargetingFunctionLibrary",
    -- Areas whose own destinations were already considered, by object key (prepare_new_area
    -- clears it).
    improved = {},
}

-- The cover pocket nearest `point`, as {X, Y, Z (its floor), tier = 2 full or 1 half, nx, ny
-- (the cover's normal: from whoever uses it towards the cover, the side it protects)}, or nil.
-- The direction was read the other way round first, and the mod chose exposed spots: in
-- Smugglers' Den's second area, against enemies to +X, the player moved exactly the three
-- operators whose pockets had normal -X and kept the three with +X.
function COVER.nearest(library, actor, point, stats, range)
    local out = {}
    local ok, found = pcall(function()
        return library:GetNearestCoverForPoint(actor, {X = point.X, Y = point.Y, Z = point.Z},
            out, range or RESCUE.cover_range)
    end)
    stats.queries = stats.queries + 1
    if not ok then
        stats.errors = stats.errors + 1
        return nil
    end
    if found ~= true then return nil end
    local read_ok, pocket = pcall(function()
        local floor, normal = out.FloorLocation, out.CoverNormal
        return {X = floor.X, Y = floor.Y, Z = floor.Z, nx = normal.X, ny = normal.Y,
                kind = tonumber(unwrap(out.PocketPointType)) or 0}
    end)
    if not read_ok or type(pocket.X) ~= "number" or type(pocket.nx) ~= "number" then
        stats.unreadable = stats.unreadable + 1
        return nil
    end
    -- EBrunoCoverPointType flags: 1 LowCover, 2 HighCover (step-out flags above).
    pocket.tier = math.floor(pocket.kind / 2) % 2 == 1 and 2 or (pocket.kind % 2 == 1 and 1 or 0)
    if pocket.tier == 0 then return nil end
    return pocket
end

-- Which way the encounter lies from the lane: towards the linked tactical volume's centre, or
-- nil when that centre is unknown or too close to the lane to say.
function COVER.forward(polygon, volume)
    local centre = valid(volume) and actor_location(volume) or nil
    if centre == nil or polygon == nil or #polygon < 1 then return nil end
    local cx, cy = 0, 0
    for _, corner in ipairs(polygon) do cx, cy = cx + corner.X / #polygon, cy + corner.Y / #polygon end
    local dx, dy = centre.X - cx, centre.Y - cy
    local length = math.sqrt(dx * dx + dy * dy)
    if length < RESCUE.cover_min_forward then return nil end
    return {X = dx / length, Y = dy / length}
end

-- The debug_cover_markers setting (off by default): every cover pocket the mod considers is
-- shown with the game's own cover marker, recoloured: green usable, yellow crowded (within a
-- tile of a destination or unit), red outside the lane or with no navmesh. Cover facing away
-- from the encounter gets none. Unreal's debug drawing is stripped from the shipping build;
-- the marker (BP_UI_CoverPoint_ScriptCreated) draws its walls from RepresentedPocket, and its
-- wall material (M_UI_CoverWall) takes "Base Color", fading with "NormalizedDistance" from the
-- cursor unless that is 1. Tried by hand through ZC Sandbox in Smugglers' Den (2026-10-12).
COVER.markers = {
    class = "/Game/Game/UI/Cover/BP_UI_CoverPoint_ScriptCreated.BP_UI_CoverPoint_ScriptCreated_C",
    package = "/Game/Game/UI/Cover/BP_UI_CoverPoint_ScriptCreated",
    seconds = 60,
    colors = {
        usable = {R = 0, G = 1, B = 0, A = 1},
        crowded = {R = 1, G = 0.85, B = 0, A = 1},
        outside = {R = 1, G = 0, B = 0, A = 1},
        unwalkable = {R = 1, G = 0, B = 0, A = 1},
    },
    -- What this deployment marked, by category, for the log; reset by COVER.markers.report.
    counts = {},
    -- Pockets already marked this deployment, so a second search over the same lane doesn't
    -- stack markers: the first verdict stands. Reset by begin_deployment.
    shown = {},
    failed = nil,
    queue = {},
    scheduled = false,
    draw_delay_ms = 100,
    -- A wall VisualizePocket placed stands on its pocket (the hand test's was exactly on it).
    wall_radius_sq = 10000.0,
    statics = "/Script/Engine.Default__GameplayStatics",
    -- ESpawnActorCollisionHandlingMethod::AlwaysSpawn, ESpawnActorScaleMethod::MultiplyWithRoot.
    always_spawn = 1,
    multiply_with_root = 1,
}

function COVER.markers.enabled()
    return Settings.Get("debug_cover_markers", false) == true
end

-- A material parameter name as an FName, or nil. UE4SS's FName isn't a plain Lua function, so
-- the first version's `type(FName) == "function"` test passed the bare string instead, and the
-- game crashed in SetVectorParameterValue (access violation, Serolonis 030, 2026-10-12). Called
-- the way Colors+ calls it, and checked by reading the text back.
local function marker_name(text)
    local ok, name = pcall(function() return FName(text) end)
    if not ok or name == nil then return nil end
    local text_ok, back = pcall(function() return name:ToString() end)
    if not text_ok or back ~= text then return nil end
    return name
end

-- Spawn one recoloured marker for `pocket` (from COVER.nearest) in `category`.
function COVER.markers.mark(world, pocket, category)
    local markers = COVER.markers
    local color = markers.colors[category]
    if color == nil or not markers.enabled() then return end
    local tag = string.format("%.0f/%.0f", pocket.X, pocket.Y)
    if markers.shown[tag] then return end
    markers.shown[tag] = true
    markers.counts[category] = (markers.counts[category] or 0) + 1
    -- Drawn after the hook that found the pocket has returned: the first version spawned
    -- (and loaded the marker class) inside TriggerPreCombat and crashed the game twice at the
    -- same address. Queued here, drawn by COVER.markers.flush on the next game-thread pass.
    markers.queue[#markers.queue + 1] = {world = world, pocket = pocket, color = color}
    if not markers.scheduled then
        markers.scheduled = true
        ExecuteWithDelay(markers.draw_delay_ms, function()
            ExecuteInGameThread(function()
                markers.scheduled = false
                markers.flush()
            end)
        end)
    end
end

-- Load the marker Blueprint at mission start, outside any hook, when the setting is on.
function COVER.markers.preload()
    if not COVER.markers.enabled() or valid(StaticFindObject(COVER.markers.class)) then return end
    ExecuteWithDelay(COVER.markers.draw_delay_ms, function()
        ExecuteInGameThread(function()
            pcall(function() LoadAsset(COVER.markers.package) end)
        end)
    end)
end

-- Draw the queued markers. The first marker of a session logs each step, so a failure in the
-- game shows where it stopped.
function COVER.markers.flush()
    local markers = COVER.markers
    local queue = markers.queue
    markers.queue = {}
    for _, entry in ipairs(queue) do
        if markers.failed ~= nil then return end
        markers.draw(entry.world, entry.pocket, entry.color)
    end
end

function COVER.markers.draw(world, pocket, color)
    local markers = COVER.markers
    local function step(name)
        if not markers.traced then log("debug_markers step=" .. name) end
    end
    step("find_class")
    local class = StaticFindObject(markers.class)
    if not valid(class) then
        step("load_class")
        pcall(function() LoadAsset(markers.package) end)
        class = StaticFindObject(markers.class)
    end
    if not valid(class) or not valid(world) then
        markers.failed = "no_marker_class"
        return
    end
    -- Spawned as the hand test through ZC Sandbox did, with the engine's deferred spawn.
    step("spawn")
    local floor = {X = pocket.X, Y = pocket.Y, Z = pocket.Z}
    local transform = {Rotation = {X = 0, Y = 0, Z = 0, W = 1}, Translation = floor,
                       Scale3D = {X = 1, Y = 1, Z = 1}}
    local statics = StaticFindObject(markers.statics)
    local spawn_ok, marker = pcall(function()
        local actor = statics:BeginDeferredActorSpawnFromClass(world, class, transform,
            markers.always_spawn, nil, markers.multiply_with_root)
        return statics:FinishSpawningActor(actor, transform, markers.multiply_with_root)
    end)
    if not spawn_ok or not valid(marker) then
        markers.failed = "spawn:" .. tostring(spawn_ok and "invalid" or marker)
        return
    end
    -- The pocket goes in through the engine's own text import, as ZC Sandbox's `set` did:
    -- appending a segment from a Lua table left its CoverActor pointer uninitialised, and
    -- VisualizePocket crashed reading it (access violation, Serolonis 030, 2026-10-12).
    step("find_property")
    local property = markers.pocket_property(marker)
    step("import")
    local import_ok, import_error = false, "no RepresentedPocket property"
    if property ~= nil then
        import_ok, import_error = pcall(function()
            property:ImportText(markers.pocket_text(pocket), property:ContainerPtrToValuePtr(marker), 0, marker)
        end)
    end
    step("read_back")
    local count_ok, segments = pcall(function() return marker.RepresentedPocket.PocketSegments:GetArrayNum() end)
    if not import_ok or not count_ok or segments ~= 1 then
        markers.failed = "pocket:" .. tostring(import_ok and ("segments=" .. tostring(segments)) or import_error)
        pcall(function() marker:K2_DestroyActor() end)
        return
    end
    step("visualize")
    pcall(function() marker:VisualizePocket() end)
    -- Only the walls VisualizePocket placed on this pocket, and only a material that is its own
    -- dynamic instance. The marker keeps a pool of walls; the unused ones wait at the origin
    -- with the plain material asset, and tinting every wall in the pool crashed the game three
    -- times (access violation, Serolonis 030, 2026-10-12; the trace stopped at this step).
    step("tint")
    local walls, tinted = {}, 0
    pcall(function()
        local list = marker.Walls
        for index = 1, list:GetArrayNum() do
            local wall = unwrap(list[index])
            if valid(wall) then walls[#walls + 1] = wall end
        end
    end)
    for _, wall in ipairs(walls) do
        local at = actor_location(wall)
        if at ~= nil and xy_distance_squared(at, pocket) <= markers.wall_radius_sq then
            local material_ok, material = pcall(function() return unwrap(wall.Wall:GetMaterial(0)) end)
            local name = material_ok and valid(material) and full_name(material) or ""
            step("tint_material=" .. (name:match("^(%S+)") or "none"))
            local base_color, distance = marker_name("Base Color"), marker_name("NormalizedDistance")
            if base_color == nil or distance == nil then
                markers.failed = "parameter_names"
            elseif name:find("^MaterialInstanceDynamic ") then
                step("tint_color")
                pcall(function() material:SetVectorParameterValue(base_color, color) end)
                step("tint_distance")
                pcall(function() material:SetScalarParameterValue(distance, 1.0) end)
                tinted = tinted + 1
            end
        end
    end
    step("drawn walls=" .. tostring(#walls) .. " tinted=" .. tostring(tinted))
    markers.traced = true
    ExecuteWithDelay(markers.seconds * 1000, function()
        ExecuteInGameThread(function()
            for _, wall in ipairs(walls) do
                pcall(function() wall:Hide() end)
                pcall(function() wall:K2_DestroyActor() end)
            end
            pcall(function() marker:K2_DestroyActor() end)
        end)
    end)
end

-- The marker's RepresentedPocket property (declared on BRG_CoverVisualizationActor), found once
-- by walking the class chain, as selfcheck.lua does.
function COVER.markers.pocket_property(marker)
    if COVER.markers.property ~= nil then return COVER.markers.property end
    local class_ok, struct = pcall(function() return marker:GetClass() end)
    local depth = 0
    while class_ok and struct ~= nil and valid(struct) and depth < 32 do
        local found = nil
        pcall(function()
            struct:ForEachProperty(function(property)
                if property:GetFName():ToString() == "RepresentedPocket" then
                    found = property
                    return true
                end
            end)
        end)
        if found ~= nil then
            COVER.markers.property = found
            return found
        end
        class_ok, struct = pcall(function() return struct:GetSuperStruct() end)
        depth = depth + 1
    end
    return nil
end

-- A cover pocket as engine text: one segment across it, a tile wide and 60 uu up, as the game's
-- own pockets have. Enum flag combinations have no names, so the type is just high or low.
function COVER.markers.pocket_text(pocket)
    local function vector(x, y, z) return string.format("(X=%.3f,Y=%.3f,Z=%.3f)", x, y, z) end
    local kind = pocket.tier == 2 and "HighCover" or "LowCover"
    local tx, ty = -pocket.ny, pocket.nx
    local floor = vector(pocket.X, pocket.Y, pocket.Z)
    local cz = pocket.Z + 60
    local cover = vector(pocket.X, pocket.Y, cz)
    local normal = vector(pocket.nx, pocket.ny, 0)
    local segment = "(ExtentLeft=" .. vector(pocket.X + tx * 50, pocket.Y + ty * 50, cz)
        .. ",ExtentRight=" .. vector(pocket.X - tx * 50, pocket.Y - ty * 50, cz)
        .. ",PointType=" .. kind .. ",LeftStepOutLocation=" .. floor .. ",RightStepOutLocation=" .. floor
        .. ",CoverLocation=" .. cover .. ",CoverNormal=" .. normal .. ",FloorLocation=" .. floor .. ")"
    return "(PocketSegments=(" .. segment .. "),LeftStepOutLocation=" .. floor
        .. ",RightStepOutLocation=" .. floor .. ",PocketPointType=" .. kind .. ",CoverLocation=" .. cover
        .. ",FloorLocation=" .. floor .. ",CoverNormal=" .. normal .. ")"
end

-- One log line per deployment of what was marked, or why marking stopped.
function COVER.markers.report(site)
    local markers = COVER.markers
    if not markers.enabled() then return end
    local counts = markers.counts
    log(string.format("debug_markers site=%s usable=%d crowded=%d outside=%d unwalkable=%d%s", site,
        counts.usable or 0, counts.crowded or 0, counts.outside or 0, counts.unwalkable or 0,
        markers.failed and (" failed=" .. markers.failed) or ""))
    markers.counts = {}
end

-- The points to add, preferring cover: `derived` (from derive_rescue_points) where no usable
-- cover is found, so a map without cover, or a game where the call fails, gets exactly what it
-- got before. Full cover first, then half, then the derived points; each a tile from the
-- destinations, the units and each other. Logs once per deployment what it found.
function COVER.choose(site, actor, polygon, authored, units, wanted, derived, walkable, volume, slots)
    if wanted < 1 or polygon == nil or not valid(actor) then return derived end
    local found_ok, library = pcall(StaticFindObject, COVER.library)
    if not found_ok or not valid(library) then return derived end
    local forward = COVER.forward(polygon, volume)
    local world = nil
    if COVER.markers.enabled() then pcall(function() world = actor:GetWorld() end) end
    local stats = {queries = 0, errors = 0, unreadable = 0, pockets = 0, facing_away = 0, refused = 0,
                   outside = 0, crowded = 0, unwalkable = 0}

    local centres = {}
    for _, point in ipairs(derived) do centres[#centres + 1] = point end
    local pool = derive_rescue_points(polygon, authored, units, RESCUE.cover_pool, false, walkable, slots)
    for _, point in ipairs(pool) do centres[#centres + 1] = point end
    for _, point in ipairs(COVER.grid(polygon, authored)) do centres[#centres + 1] = point end

    local function clear_of(point, others, location)
        for _, other in ipairs(others) do
            local at = location and other.location or other
            if at ~= nil and xy_distance_squared(point, at) < MIN_DESTINATION_SEPARATION_SQ then return false end
        end
        return true
    end
    local covers, seen = {}, {}
    for _, centre in ipairs(centres) do
        local pocket = COVER.nearest(library, actor, centre, stats)
        if pocket ~= nil then
            local key = string.format("%.0f/%.0f", pocket.X, pocket.Y)
            if not seen[key] then
                seen[key] = true
                stats.pockets = stats.pockets + 1
                local facing = forward and (pocket.nx * forward.X + pocket.ny * forward.Y) or 1
                local point = {X = pocket.X, Y = pocket.Y, Z = pocket.Z + RESCUE.capsule_height,
                               lift = RESCUE.capsule_height, cover = pocket.tier, facing = facing,
                               order = #covers}
                local category = nil
                if facing < RESCUE.cover_facing then
                    stats.facing_away = stats.facing_away + 1
                elseif inside_deployment(polygon, point) == false then
                    stats.refused, stats.outside = stats.refused + 1, stats.outside + 1
                    category = "outside"
                elseif not clear_of(point, authored) or not clear_of(point, units, true) then
                    stats.refused, stats.crowded = stats.refused + 1, stats.crowded + 1
                    category = "crowded"
                elseif walkable ~= nil and not walkable(point) then
                    stats.refused, stats.unwalkable = stats.refused + 1, stats.unwalkable + 1
                    category = "unwalkable"
                else
                    covers[#covers + 1] = point
                    category = "usable"
                end
                if category ~= nil and COVER.markers.enabled() then
                    COVER.markers.mark(world, pocket, category)
                end
            end
        end
    end
    -- Full before half, then cover facing the encounter more squarely.
    table.sort(covers, function(left, right)
        if left.cover ~= right.cover then return left.cover > right.cover end
        if math.abs(left.facing - right.facing) > 0.01 then return left.facing > right.facing end
        return left.order < right.order
    end)

    local chosen, used = {}, {full = 0, half = 0}
    for _, list in ipairs({covers, derived}) do
        for _, point in ipairs(list) do
            if #chosen >= wanted then break end
            if clear_of(point, chosen) then
                chosen[#chosen + 1] = point
                if point.cover == 2 then used.full = used.full + 1 elseif point.cover == 1 then used.half = used.half + 1 end
            end
        end
    end
    if not placement_rescue_reported["cover_" .. site] then
        placement_rescue_reported["cover_" .. site] = true
        log(string.format("cover site=" .. site .. " queries=%d pockets=%d usable=%d facing_away=%d refused=%d"
            .. " chosen_full=%d chosen_half=%d of=%d facing=%s errors=%d unreadable=%d"
            .. " refused_outside=%d refused_crowded=%d refused_unwalkable=%d",
            stats.queries, stats.pockets, #covers, stats.facing_away, stats.refused,
            used.full, used.half, #chosen, forward and "checked" or "unknown",
            stats.errors, stats.unreadable, stats.outside, stats.crowded, stats.unwalkable))
        COVER.markers.report(site)
    end
    if used.full + used.half == 0 then return derived end
    for _, point in ipairs(chosen) do point.order, point.facing = nil, nil end
    return chosen
end

-- The improve_game_spots setting: before the relocation walks anyone in, each of the area's own
-- destinations that has no cover facing the encounter moves to the best usable cover within
-- RESCUE.cover_improve_range: full before half, then facing more squarely, then nearer. The
-- authored actors stay in the level, unlisted, and their replacements count as authored, so the
-- repair still leaves a stock squad alone. Needs the encounter's direction; once per area. Not
-- called for an area a PLACEMENT_PROFILES entry matches: the profile knows its map by these
-- destinations, and its rescues sit where they are.
-- Smugglers' Den's second area: the game's own points sat beside cover with its back to the
-- enemies.
function COVER.improve(area, destinations, valid_destinations, anchors)
    local key = object_key(area)
    if key == "" or COVER.improved[key] or relocation_prehook_ran then return end
    COVER.improved[key] = true
    if Settings.Get("improve_game_spots", true) ~= true then return end

    local units = every_player_unit()
    local actor = units[1] and units[1].actor
    local found_ok, library = pcall(StaticFindObject, COVER.library)
    if not found_ok or not valid(library) or not valid(actor) then return end
    local world_ok, world = pcall(function() return area:GetWorld() end)
    if not world_ok or not valid(world) then return end

    local points = {}
    for index, destination in ipairs(valid_destinations) do points[index] = destination.location end
    local polygon = deployment_polygon(points)
    local forward = COVER.forward(polygon, linked_tactical_area(area))
    if forward == nil then
        log("improve_spots=skipped reason=no_direction destinations=" .. tostring(#points))
        return
    end
    local walkable = walkable_test(area, points)
    local stats = {queries = 0, errors = 0, unreadable = 0}
    local function facing(pocket) return pocket.nx * forward.X + pocket.ny * forward.Y end

    local kept, moved, unmoved, moves = 0, 0, 0, {}
    for index, destination in ipairs(valid_destinations) do
        local origin = destination.location
        local here = COVER.nearest(library, actor, origin, stats, RESCUE.cover_here_range)
        if here ~= nil and facing(here) >= RESCUE.cover_facing then
            kept = kept + 1
        else
            local best, seen = nil, {}
            local function consider(pocket)
                if pocket == nil then return end
                local tag = string.format("%.0f/%.0f", pocket.X, pocket.Y)
                if seen[tag] then return end
                seen[tag] = true
                local distance = xy_distance_squared(pocket, origin)
                if distance > RESCUE.cover_improve_range ^ 2 then return end
                pocket.facing, pocket.distance = facing(pocket), distance
                if pocket.facing < RESCUE.cover_facing then return end
                local point = {X = pocket.X, Y = pocket.Y, Z = pocket.Z}
                local function refuse(category)
                    if COVER.markers.enabled() then COVER.markers.mark(world, pocket, category) end
                end
                if inside_deployment(polygon, point) == false then return refuse("outside") end
                if walkable ~= nil and not walkable(point) then return refuse("unwalkable") end
                for other, location in ipairs(points) do
                    if other ~= index and xy_distance_squared(point, location) < MIN_DESTINATION_SEPARATION_SQ then
                        return refuse("crowded")
                    end
                end
                refuse("usable")
                if best == nil or pocket.tier > best.tier
                    or (pocket.tier == best.tier and (pocket.facing > best.facing + 0.01
                        or (math.abs(pocket.facing - best.facing) <= 0.01 and distance < best.distance))) then
                    best = pocket
                end
            end
            for _, offset in ipairs(RESCUE.cover_improve_offsets) do
                for step = 0, 7 do
                    local angle = step * math.pi / 4
                    consider(COVER.nearest(library, actor, {X = origin.X + offset * math.cos(angle),
                        Y = origin.Y + offset * math.sin(angle), Z = origin.Z}, stats, RESCUE.cover_here_range * 2))
                end
            end
            local point = nil
            if best ~= nil then
                -- The destination's own height above its floor, carried to the new floor.
                local floor = navigation_floor(area, origin)
                local lift = floor ~= nil and origin.Z - floor.Z or 0
                local location = {X = best.X, Y = best.Y, Z = best.Z + lift}
                point = spawn_destination(destination.actor, world, location)
                if point ~= nil and pcall(function() destinations[destination.index] = point end) then
                    moves[#moves + 1] = string.format("%.0f/%.0f->%.0f/%.0f%s", origin.X, origin.Y,
                        location.X, location.Y, best.tier == 2 and "full" or "half")
                    destination.actor, destination.location = point, location
                    points[index], anchors[index] = location, copy_vector(location)
                    moved = moved + 1
                elseif point ~= nil then
                    pcall(function() point:K2_DestroyActor() end)
                    point = nil
                end
            end
            if point == nil then unmoved = unmoved + 1 end
        end
    end
    log(string.format("improve_spots kept=%d moved=%d no_better_cover=%d queries=%d errors=%d"
        .. " unreadable=%d moves=%s", kept, moved, unmoved, stats.queries, stats.errors,
        stats.unreadable, #moves > 0 and table.concat(moves, ",") or "none"))
    COVER.markers.report("improve")
end

-- Search centres covering the lane: tile-spaced points strictly inside it, each at the height of
-- its nearest authored destination plus a capsule (the search looks around the point anyway).
function COVER.grid(polygon, authored)
    local points = {}
    if polygon == nil or #polygon < 3 then return points end
    local min_x, max_x, min_y, max_y = math.huge, -math.huge, math.huge, -math.huge
    for _, corner in ipairs(polygon) do
        min_x, max_x = math.min(min_x, corner.X), math.max(max_x, corner.X)
        min_y, max_y = math.min(min_y, corner.Y), math.max(max_y, corner.Y)
    end
    local step = RESCUE.cover_grid
    local x = min_x + step / 2
    while x < max_x and #points < RESCUE.cover_grid_max do
        local y = min_y + step / 2
        while y < max_y and #points < RESCUE.cover_grid_max do
            local point = {X = x, Y = y}
            if inside_deployment(polygon, point) == true then
                local nearest, height = math.huge, 0
                for _, destination in ipairs(authored) do
                    local distance = xy_distance_squared(point, destination)
                    if distance < nearest then nearest, height = distance, destination.Z or 0 end
                end
                point.Z = height + RESCUE.capsule_height
                points[#points + 1] = point
            end
            y = y + step
        end
        x = x + step
    end
    return points
end

-- A rescue point in the profile's own coordinates, drawn in towards the
-- centroid of its four authored destinations when the profile asks for it.
-- Z is left alone: it is a capsule height read off the map, not a position
-- inside the deployment shape.
local function inset_rescue(profile, rescue)
    if not profile.inset_rescues then return rescue end
    local x, y = 0, 0
    for _, point in ipairs(profile.destinations) do
        x, y = x + point.X, y + point.Y
    end
    local count = #profile.destinations
    x, y = x / count, y / count
    return {
        X = rescue.X + (x - rescue.X) * RESCUE.inset,
        Y = rescue.Y + (y - rescue.Y) * RESCUE.inset,
        Z = rescue.Z,
    }
end

-- Match a profile's four-point fingerprint under any level-instance translation
-- or yaw rotation: two points give the transform, then all four must match
-- distinct live destinations within 50 uu.
local function match_placement_profile(profile, destinations)
    if destinations == nil or #destinations < #profile.destinations then return nil end

    local first = profile.destinations[1]
    local second = profile.destinations[2]
    local expected_x = second.X - first.X
    local expected_y = second.Y - first.Y
    local expected_length = math.sqrt(expected_x * expected_x + expected_y * expected_y)
    if expected_length < 1 then return nil end

    for first_index, first_destination in ipairs(destinations) do
        for second_index, second_destination in ipairs(destinations) do
            if first_index ~= second_index
                and first_destination.location ~= nil
                and second_destination.location ~= nil then
                local actual_x = second_destination.location.X - first_destination.location.X
                local actual_y = second_destination.location.Y - first_destination.location.Y
                local actual_length = math.sqrt(actual_x * actual_x + actual_y * actual_y)
                local scale = actual_length / expected_length
                if scale >= 0.95 and scale <= 1.05 then
                    local divisor = expected_length * actual_length
                    local cos = (expected_x * actual_x + expected_y * actual_y) / divisor
                    local sin = (expected_x * actual_y - expected_y * actual_x) / divisor
                    local transform = {
                        cos = cos,
                        sin = sin,
                        scale = scale,
                        tx = first_destination.location.X
                            - scale * (cos * first.X - sin * first.Y),
                        ty = first_destination.location.Y
                            - scale * (sin * first.X + cos * first.Y),
                        tz = first_destination.location.Z - first.Z,
                    }

                    local matched, used = {}, {}
                    local complete = true
                    for expected_index, expected in ipairs(profile.destinations) do
                        local transformed = transform_profile_point(transform, expected)
                        local best_index, best_distance = nil, math.huge
                        for destination_index, destination in ipairs(destinations) do
                            if not used[destination_index] and destination.location ~= nil then
                                local distance = xy_distance_squared(
                                    transformed, destination.location)
                                if distance < best_distance then
                                    best_index, best_distance = destination_index, distance
                                end
                            end
                        end
                        if best_index == nil
                            or best_distance > PLACEMENT_PROFILE_MATCH_RADIUS_SQ then
                            complete = false
                            break
                        end
                        used[best_index] = true
                        matched[expected_index] = destinations[best_index].location
                    end
                    if complete then return transform, matched end
                end
            end
        end
    end
    return nil
end

-- Pair as many free targets and candidates as possible while minimizing the
-- total XY travel. Profiles currently carry at most two rescues, but the
-- bounded search is also cheap for every possible subset of a six-unit squad.
-- Enumeration order breaks exact ties deterministically.
local function minimum_distance_assignments(targets, candidates, wanted)
    local pair_count = math.min(#targets, #candidates, wanted or math.huge)
    if pair_count < 1 then return {} end

    local best, best_cost = nil, math.huge
    local used, current = {}, {}

    local function search(target_index, cost)
        if #current == pair_count then
            if cost < best_cost then
                best_cost = cost
                best = {}
                for index, pair in ipairs(current) do best[index] = pair end
            end
            return
        end
        if target_index > #targets or cost >= best_cost then return end

        local needed = pair_count - #current
        local remaining_targets = #targets - target_index + 1
        if remaining_targets < needed then return end

        local target = targets[target_index]
        for candidate_index, candidate in ipairs(candidates) do
            if not used[candidate_index] then
                used[candidate_index] = true
                current[#current + 1] = {
                    target = target,
                    unit = candidate,
                }
                search(target_index + 1, cost
                    + math.sqrt(xy_distance_squared(target, candidate.location)))
                current[#current] = nil
                used[candidate_index] = nil
            end
        end

        -- A target may be skipped only when enough later targets remain to
        -- produce the same maximum-cardinality assignment.
        if remaining_targets > needed then search(target_index + 1, cost) end
    end

    search(1, 0)
    return best or {}
end

-- Move overflow operators the game staged inside the tactical volume but
-- outside the deployment lane, before their positions become destinations.
-- Every profile is tried; if two match one map, nothing is moved.
local function rescue_known_staging(destinations, volume)
    if not staging_window_open then return 0 end

    local units = every_player_unit()
    if #units < 1 then return 0 end
    for _, unit in ipairs(units) do unit.rotation = actor_rotation(unit.actor) end
    -- Only as many moves as destinations are missing: four authored points and
    -- six operators means at most two.
    local missing = math.min(#units, RESCUE.max_destinations) - #destinations
    if missing < 1 then return 0 end

    local profile, transform, stock_destinations = nil, nil, nil
    for _, candidate_profile in ipairs(PLACEMENT_PROFILES) do
        local candidate_transform, candidate_destinations =
            match_placement_profile(candidate_profile, destinations)
        if candidate_transform ~= nil then
            if profile ~= nil then
                if not placement_rescue_reported.ambiguous then
                    placement_rescue_reported.ambiguous = true
                    log("placement_rescue=none reason=ambiguous_profiles"
                        .. " matched=" .. profile.name .. "," .. candidate_profile.name)
                end
                return 0
            end
            profile, transform, stock_destinations =
                candidate_profile, candidate_transform, candidate_destinations
        end
    end
    -- No profile: derive the lane and its rescue points from the area's own
    -- destinations.
    local authored = {}
    for _, destination in ipairs(destinations) do
        if destination.location ~= nil then
            authored[#authored + 1] = destination.location
        end
    end
    local polygon = deployment_polygon(authored)

    local candidates = {}
    for _, unit in ipairs(units) do
        local eligible
        if profile == nil then
            eligible = inside_deployment(polygon, unit.location) == false
        elseif profile.outside_volume_only then
            eligible = actor_inside_tactical_area(volume, unit.actor) == false
        else
            local nearest = math.huge
            for _, stock in ipairs(stock_destinations) do
                nearest = math.min(nearest, xy_distance_squared(unit.location, stock))
            end
            eligible = nearest > PLACEMENT_PROFILE_MEMBER_RADIUS_SQ
        end
        if eligible then candidates[#candidates + 1] = unit end
    end
    if #candidates < 1 then return 0 end

    local targets, floor_note = {}, ""
    if profile ~= nil then
        for _, rescue in ipairs(profile.rescues) do
            targets[#targets + 1] = transform_profile_point(
                transform, inset_rescue(profile, rescue))
        end
    else
        local context = destinations[1].actor
        local unwalkable
        local walkable = walkable_test(context, authored)
        targets, unwalkable = derive_rescue_points(polygon, authored, units, missing, false,
            walkable, RESCUE.max_destinations)
        targets = COVER.choose("staging", units[1].actor, polygon, authored, units, missing, targets,
            walkable, volume, RESCUE.max_destinations)
        local settled, shift = settle_on_floor(context, targets, units)
        floor_note = string.format(" floor_settled=%d/%d largest_shift=%.0f",
            settled, #targets, shift)
        if unwalkable > 0 then
            floor_note = floor_note .. " off_navmesh_skipped=" .. unwalkable
        end
    end
    if #targets < 1 then return 0 end

    -- Resolve occupancy before assignment, so an occupied first target can't
    -- claim the only candidate and starve a free one. A candidate within 10 uu
    -- of a target is already settled there.
    local candidate_set, settled = {}, {}
    for _, candidate in ipairs(candidates) do candidate_set[candidate] = true end

    local free_targets = {}
    for _, target in ipairs(targets) do
        local occupied = false
        for _, unit in ipairs(units) do
            if xy_distance_squared(target, unit.location)
                <= RESCUE.settled_radius_sq then
                occupied = true
                if candidate_set[unit] then settled[unit] = true end
            elseif not candidate_set[unit]
                and distance_squared(target, unit.location)
                    < MIN_UNIT_SEPARATION_SQ then
                occupied = true
            end
        end
        if not occupied then free_targets[#free_targets + 1] = target end
    end

    local unsettled_candidates = {}
    for _, candidate in ipairs(candidates) do
        if not settled[candidate] then
            unsettled_candidates[#unsettled_candidates + 1] = candidate
        end
    end

    local assignments = minimum_distance_assignments(
        free_targets, unsettled_candidates, missing)
    local rescued, moves, placed = 0, {}, {}
    for _, assignment in ipairs(assignments) do
        local target, unit = assignment.target, assignment.unit
        local blocked = false
        for _, other in ipairs(units) do
            if other ~= unit
                and distance_squared(target, other.location)
                    < MIN_UNIT_SEPARATION_SQ then
                blocked = true
                break
            end
        end
        if not blocked then
            local original = copy_vector(unit.location)
            local moved, accepted = pcall(function()
                return unit.actor:K2_SetActorLocationAndRotation(
                    target, unit.rotation or {}, false, {}, true)
            end)
            if moved and accepted ~= false
                and actor_inside_tactical_area(volume, unit.actor) ~= false then
                halt(unit.actor)
                unit.location = copy_vector(target)
                remember_staged_position(unit.actor, unit, volume, true)
                rescued = rescued + 1
                placed[#placed + 1] = copy_vector(target)
                moves[#moves + 1] = string.format(
                    "%.0f/%.0f/%.0f->%.0f/%.0f/%.0f",
                    original.X, original.Y, original.Z,
                    target.X, target.Y, target.Z)
            else
                -- The map fingerprint matched but this runtime rejected the
                -- target. Put the actor back and let the existing placement
                -- diagnostics report the refusal.
                pcall(function()
                    unit.actor:K2_SetActorLocationAndRotation(
                        original, unit.rotation or {}, false, {}, true)
                end)
            end
        end
    end
    local label = profile ~= nil and profile.name or "deployment_lane"
    if rescued > 0 and not placement_rescue_reported[label] then
        placement_rescue_reported[label] = true
        log("placement_rescue=" .. label
            .. " moved=" .. table.concat(moves, ",") .. floor_note)
    end
    -- Return the rescued positions: the lane test that follows rejects
    -- positions the game staged badly, and must not reject one this pass chose
    -- deliberately.
    return rescued, placed
end

-- Why this operator cannot be where it is, or nil if it is fine. Ordered so
-- the log names the most specific cause.
local function strand_reason(unit, index, units, anchors, volume, polygon)
    if at_world_origin(unit.location) then return "origin" end

    -- The first occupant of a tile keeps it; anyone who arrived on top of it
    -- is the one that has to move.
    for earlier = 1, index - 1 do
        if distance_squared(unit.location, units[earlier].location) < MIN_UNIT_SEPARATION_SQ then
            return "shared_tile"
        end
    end

    -- Ask the deployment lane first, then the game's tactical volume. The
    -- volume describes the whole battlefield, so "inside" from it doesn't mean
    -- the operator can be commanded.
    if inside_deployment(polygon, unit.location) == false then return "off_lane" end

    if volume ~= nil then
        local inside = actor_inside_tactical_area(volume, unit.actor)
        if inside == false then return "outside_volume" end
        if inside == true then return nil end
    end

    local nearest = math.huge
    for _, anchor in ipairs(anchors) do
        nearest = math.min(nearest, distance_squared(unit.location, anchor))
    end
    if nearest > MAX_DESTINATION_DISTANCE_SQ then return "off_area" end
    return nil
end

-- Hard-invalid reasons are safe after control may have returned. Compute the
-- entire squad before moving anybody: restoring the first member of a broken
-- pair must not make the second member look valid halfway through the pass.
local function hard_strand_reasons(units, volume, polygon)
    local reasons = {}
    for index, unit in ipairs(units) do
        if at_world_origin(unit.location) then
            reasons[index] = "origin"
        else
            local shared_earlier, shared_any = false, false
            for other_index, other in ipairs(units) do
                if other_index ~= index
                    and distance_squared(unit.location, other.location)
                        < MIN_UNIT_SEPARATION_SQ then
                    shared_any = true
                    if other_index < index then shared_earlier = true end
                end
            end
            -- A normal shared tile has one valid first occupant. If the tile
            -- is also outside the authored lane, neither occupant has a
            -- defensible claim to it. Ordinary off-lane movement alone is
            -- intentionally not a hard late-watchdog reason.
            if shared_any and inside_deployment(polygon, unit.location) == false then
                reasons[index] = "stacked_off_lane"
            elseif shared_earlier then
                reasons[index] = "shared_tile"
            elseif volume ~= nil
                and actor_inside_tactical_area(volume, unit.actor) == false then
                reasons[index] = "outside_volume"
            end
        end
    end
    return reasons
end

-- Signatures an operator can't reach by playing. `off_lane` and `off_area` are
-- absent: after control returns they describe an operator the player walked
-- somewhere.
local REPAIR = {}
REPAIR.lane_fallback = {
    origin = true,
    shared_tile = true,
    stacked_off_lane = true,
    outside_volume = true,
}

-- How far outside the authored lane a staged snapshot may be and still be a
-- place to put an operator back: about one lane's width. Overflow operators
-- staged just outside the lane are normal; a squad staged on a strip far
-- outside it is not a target.
REPAIR.max_staging_offset = 1000.0

-- A reason that also describes an operator still walking into place, since the
-- relocation walks the squad. Repaired only once the operator has stopped
-- moving between passes; the other signatures are repaired on sight.
-- `shared_tile` is here because two operators walking past each other share a
-- tile for a moment: repaired on sight, one was teleported off its own path
-- twice on each of Retake Luunata's deployments.
REPAIR.soft_settle = {
    off_lane = true,
    shared_tile = true,
}
REPAIR.settled_radius_sq = 100.0
-- After the ladder, when to look at whether operators the repair put somewhere
-- are still there, and how far one may be before that is reported.
REPAIR.drift_checks_ms = {10000, 20000}
REPAIR.drift_radius_sq = 90000.0
local observed_positions = {}

-- Undo a relocation that went wrong. CalculateRushTargets_V2 can give two
-- operators the same target, or one none, leaving it on a squadmate's tile, at
-- the world origin or outside the area: it can still shoot but can't move.
--
-- Each operator goes back to its staged position. Without one, the hard-invalid
-- signatures fall back to an inset point of the authored lane; `off_lane` alone
-- never does, since the player may have walked there. At most two automatic
-- repairs per operator.
local function repair_stranded_units(area, via, hard_only, ignore_budget)
    area = unwrap(area)
    if not valid(area) then return 0 end

    -- Hand-picked spots, some outside the authored lane on purpose: nothing to repair.
    local fixed = FIXED.applied[object_key(area)]
    if fixed then
        if not placement_rescue_reported.fixed then
            placement_rescue_reported.fixed = true
            log("placement_repair=skipped reason=fixed_spots layout=" .. fixed)
        end
        return 0, 0
    end

    local units = every_player_unit()
    if #units < 1 then return 0 end

    local anchors = destination_anchors(area)
    if #anchors < 1 then return 0 end

    -- A squad no bigger than the area's authored destinations is the game's own
    -- deployment: this mod added nothing to it, so there is nothing of its own
    -- to repair.
    local authored_count = #destination_anchors(area, true)
    if #units <= authored_count then
        if not placement_rescue_reported.stock_squad then
            placement_rescue_reported.stock_squad = true
            log("placement_repair=skipped reason=stock_squad units=" .. tostring(#units)
                .. " authored=" .. tostring(authored_count))
        end
        return 0, 0
    end

    repair_passes = repair_passes + 1
    repair_units_seen = #units

    local volume = linked_tactical_area(area)
    local polygon = deployment_polygon(anchors)
    local hard_reasons = hard_only
        and hard_strand_reasons(units, volume, polygon) or {}

    -- The authored lane and its fallback points, derived lazily and from the
    -- mission's own destinations only. Derived ignoring where operators stand,
    -- since the rescue may already have put them there; occupancy is checked
    -- per point below.
    local authored_points, authored_lane, authored_built = nil, nil, false
    local function authored_shape()
        if not authored_built then
            authored_built = true
            authored_points = destination_anchors(area, true)
            authored_lane = deployment_polygon(authored_points)
        end
        return authored_lane, authored_points
    end

    -- How far outside the authored lane a point lies; 0 when it is inside or
    -- within the edge tolerance. nil when there is no lane to measure against,
    -- which leaves the caller to accept the point as it always has.
    local function lane_offset(point)
        local lane = authored_shape()
        if lane == nil or point == nil then return nil end
        if inside_deployment(lane, point) ~= false then return 0 end
        local nearest = math.huge
        for index = 1, #lane do
            nearest = math.min(nearest, distance_to_segment(
                point, lane[index], lane[index % #lane + 1]))
        end
        return nearest
    end

    local lane_pool, lane_pool_built = nil, false
    local function claim_lane_point(unit)
        if not lane_pool_built then
            lane_pool_built = true
            local lane, authored = authored_shape()
            if lane ~= nil then
                lane_pool = derive_rescue_points(
                    lane, authored, units, #units, true, walkable_test(area, authored))
                settle_on_floor(area, lane_pool, units)
            end
        end
        if lane_pool == nil then return nil end
        -- Nearest free point, so two rescued operators do not cross paths and
        -- the shorter teleport is the one that happens.
        local best, best_index, best_distance = nil, nil, math.huge
        for index, point in ipairs(lane_pool) do
            local occupied = false
            for _, other in ipairs(units) do
                if xy_distance_squared(point, other.location)
                    < MIN_UNIT_SEPARATION_SQ then
                    occupied = true
                    break
                end
            end
            if not occupied then
                local distance = xy_distance_squared(point, unit.location)
                if distance < best_distance then
                    best, best_index, best_distance = point, index, distance
                end
            end
        end
        if best == nil then return nil end
        table.remove(lane_pool, best_index)
        return {location = {X = best.X, Y = best.Y, Z = best.Z}, rotation = nil}
    end

    -- Where each operator stood at the previous pass, captured before this
    -- pass moves anybody. A repaired operator therefore reads as "moved" on
    -- the following pass, which is the right answer: it has just been put
    -- somewhere and has not yet had a chance to settle there.
    local previous_positions = observed_positions
    observed_positions = {}
    for _, unit in ipairs(units) do
        observed_positions[unit.key] = copy_vector(unit.location)
    end

    local restored, stranded, halted, reasons, moves = 0, 0, 0, {}, {}
    for index, unit in ipairs(units) do
        local reason
        if hard_only then
            reason = hard_reasons[index]
        else
            reason = strand_reason(unit, index, units, anchors, volume, polygon)
        end
        if reason ~= nil then
            stranded = stranded + 1
            local moving = false
            if REPAIR.soft_settle[reason] then
                local previous = previous_positions[unit.key]
                moving = previous == nil
                    or distance_squared(previous, unit.location) >= REPAIR.settled_radius_sq
            end
            local staged, fallback, off_lane_staging = nil, false, false
            if not moving then
                staged = staged_positions[unit.key]
                -- A snapshot far outside the authored lane isn't a place to put
                -- anyone back. Positions this mod chose are exempt.
                local offset = staged ~= nil and not staged.trusted
                    and lane_offset(staged.location) or nil
                if offset ~= nil and offset > REPAIR.max_staging_offset then
                    staged, off_lane_staging = nil, true
                end
                if staged == nil and REPAIR.lane_fallback[reason] then
                    staged = claim_lane_point(unit)
                    fallback = staged ~= nil
                end
            end
            local attempts = repair_counts[unit.key] or 0
            if moving then
                -- Still on its way. Say so rather than staying silent: a run
                -- of `:moving` across the whole ladder is the signature of a
                -- walk that never ends, which is worth seeing.
                reasons[#reasons + 1] = reason .. ":moving"
            elseif staged == nil then
                reasons[#reasons + 1] = reason
                    .. (off_lane_staging and ":off_lane_staging" or ":unstaged")
            elseif not ignore_budget and attempts >= MAX_REPAIRS_PER_UNIT then
                reasons[#reasons + 1] = reason .. ":exhausted"
            elseif distance_squared(staged.location, unit.location) < MIN_UNIT_SEPARATION_SQ then
                -- It is already standing where it was staged; something else
                -- is wrong and moving it there again would not help.
                reasons[#reasons + 1] = reason .. ":already_staged"
            else
                -- Never restore onto a tile another operator now holds; that
                -- would trade one shared tile for another.
                local blocked = false
                for other_index, other in ipairs(units) do
                    if other_index ~= index
                        and distance_squared(staged.location, other.location) < MIN_UNIT_SEPARATION_SQ then
                        blocked = true
                        break
                    end
                end
                if blocked then
                    reasons[#reasons + 1] = reason .. ":blocked"
                else
                    -- Take the return value, not just the absence of an
                    -- error. A teleport the engine declines returns false
                    -- and throws nothing, and a silent decline is how an
                    -- operator ends up somewhere nobody chose.
                    local moved, accepted = pcall(function()
                        return unit.actor:K2_SetActorLocationAndRotation(
                            staged.location, staged.rotation or {}, false, {}, true)
                    end)
                    if moved and accepted ~= false then
                        if halt(unit.actor) then halted = halted + 1 end
                        restored_positions[unit.key] = copy_vector(staged.location)
                        repair_counts[unit.key] = attempts + 1
                        restored = restored + 1
                        repair_restored_total = repair_restored_total + 1
                        reasons[#reasons + 1] = reason
                            .. (fallback and ":lane" or "")
                        moves[#moves + 1] = string.format("%.0f/%.0f/%.0f->%.0f/%.0f/%.0f",
                            unit.location.X, unit.location.Y, unit.location.Z,
                            staged.location.X, staged.location.Y, staged.location.Z)
                        unit.location = copy_vector(staged.location)
                    else
                        reasons[#reasons + 1] = reason .. ":refused"
                    end
                end
            end
        end
    end

    -- Report every pass that found something, up to a cap. A one-shot line
    -- would hide the case that matters most: a later rung fixing what an
    -- earlier one could not, or failing to.
    if stranded > 0 and repair_reported < MAX_REPAIR_REPORTS then
        repair_reported = repair_reported + 1
        local staged = 0
        for _, unit in ipairs(units) do
            if staged_positions[unit.key] ~= nil then staged = staged + 1 end
        end
        log("placement_repair via=" .. tostring(via or "?")
            .. " units=" .. tostring(#units)
            .. " staged=" .. tostring(staged)
            .. " stranded=" .. tostring(stranded)
            .. " restored=" .. tostring(restored)
            .. " halted=" .. tostring(halted)
            .. " reasons=" .. table.concat(reasons, ",")
            .. " moves=" .. table.concat(moves, ","))
    end
    return restored, stranded
end

-- Last resort for squadsixrescue: two hard-invalid operators far from a tight
-- cluster of the other four are placed on two live squadmates' tiles, a
-- workaround a player proved in a live mission. Only that exact shape; the
-- shared tiles are deliberate.
local function manual_peer_rescue(area, units)
    local anchors = destination_anchors(area)
    if #anchors < 1 then return 0, "no_destinations" end
    local volume = linked_tactical_area(area)
    local polygon = deployment_polygon(anchors)
    local hard = hard_strand_reasons(units, volume, polygon)
    local bad, good = {}, {}
    for index, unit in ipairs(units) do
        if hard[index] ~= nil then
            bad[#bad + 1] = unit
        else
            good[#good + 1] = unit
        end
    end
    if #bad ~= 2 or #good ~= TARGET_SIZE - 2 then
        return 0, "shape hard=" .. tostring(#bad) .. " good=" .. tostring(#good)
    end

    for left = 1, #good do
        for right = left + 1, #good do
            local distance = distance_squared(good[left].location, good[right].location)
            if distance < MIN_UNIT_SEPARATION_SQ then
                return 0, "good_cluster_shared"
            end
            if distance > MANUAL_PEER_CLUSTER_RADIUS_SQ then
                return 0, "good_cluster_wide"
            end
        end
    end
    for _, outlier in ipairs(bad) do
        for _, peer in ipairs(good) do
            if distance_squared(outlier.location, peer.location)
                < MANUAL_PEER_OUTLIER_DISTANCE_SQ then
                return 0, "outlier_not_remote"
            end
        end
    end

    local originals, rotations, moved, moves = {}, {}, {}, {}
    for index, outlier in ipairs(bad) do
        local target = good[index].location
        originals[index] = copy_vector(outlier.location)
        rotations[index] = actor_rotation(outlier.actor) or {}
        local call_ok, accepted = pcall(function()
            return outlier.actor:K2_SetActorLocationAndRotation(
                target, rotations[index], false, {}, true)
        end)
        local actual = actor_location(outlier.actor)
        if not call_ok or accepted == false or actual == nil
            or distance_squared(actual, target) >= MIN_UNIT_SEPARATION_SQ then
            -- This outlier may have moved too: an accepted teleport can land more than a
            -- tile from its target. Put it back with the others.
            pcall(function()
                outlier.actor:K2_SetActorLocationAndRotation(
                    originals[index], rotations[index], false, {}, true)
            end)
            for rollback = 1, #moved do
                pcall(function()
                    bad[rollback].actor:K2_SetActorLocationAndRotation(
                        originals[rollback], rotations[rollback], false, {}, true)
                end)
            end
            return 0, "teleport_refused"
        end
        moved[index] = true
        outlier.location = copy_vector(actual)
        moves[#moves + 1] = string.format(
            "%.0f/%.0f/%.0f->%.0f/%.0f/%.0f",
            originals[index].X, originals[index].Y, originals[index].Z,
            actual.X, actual.Y, actual.Z)
    end
    repair_restored_total = repair_restored_total + #moved
    return #moved, nil, table.concat(moves, ",")
end

-- The relocation asks CalculateRushTargets_V2 for one target per unit from
-- PlayerDestinations, and many maps author only four, so operators five and six
-- can be sent somewhere invalid. Add destinations at positions operators
-- already stand on, before the relocation is calculated; nothing is
-- extrapolated, since an invented point has no navigation check.
-- Replace the destinations of an area that matches a FIXED layout with its spots, written over the
-- list in the layout's order. A spot on an authored destination keeps that actor; the others are
-- new destination actors of the authored class, team and facing. Authored actors no spot uses
-- stay in the level, unlisted. Returns true once the list holds the spots, or
-- nil when no layout matches or a spot can't be placed, so the usual expansion runs instead.
function FIXED.apply(area, destinations, raw_count, valid_destinations)
    local layout, transform = nil, nil
    for _, candidate in ipairs(FIXED.layouts) do
        local candidate_transform = match_placement_profile(candidate, valid_destinations)
        if candidate_transform ~= nil then
            if layout ~= nil then
                log("fixed_spots=none reason=ambiguous_layouts matched="
                    .. layout.name .. "," .. candidate.name)
                return nil
            end
            layout, transform = candidate, candidate_transform
        end
    end
    if layout == nil then return nil end
    -- Every listed destination is overwritten, so none of the authored ones stays in use.
    if raw_count > #layout.spots then
        log("fixed_spots=none reason=more_destinations_than_spots layout=" .. layout.name
            .. " destinations=" .. tostring(raw_count))
        return nil
    end

    local template = valid_destinations[1].actor
    local world_ok, world = pcall(function() return area:GetWorld() end)
    if not world_ok or not valid(world) then return nil end

    local points, spawned, reused = {}, {}, {}
    for index, spot in ipairs(layout.spots) do
        local location = transform_profile_point(transform, spot)
        -- A spot on an authored destination keeps that actor: the mission may know it by name
        -- (Stillwatch's PlayerTacticalPoint_1.2_Trick).
        for candidate, destination in ipairs(valid_destinations) do
            if not reused[candidate]
                and distance_squared(destination.location, location) <= FIXED.same_point_sq then
                reused[candidate] = true
                points[index] = destination.actor
                break
            end
        end
        if points[index] == nil then
            points[index] = spawn_destination(template, world, location)
            spawned[#spawned + 1] = points[index]
        end
        if points[index] == nil then
            for _, point in ipairs(spawned) do
                pcall(function() point:K2_DestroyActor() end)
            end
            log("fixed_spots=none reason=spot_not_placed layout=" .. layout.name
                .. " spot=" .. tostring(index))
            return nil
        end
    end

    local written = 0
    local write_ok = pcall(function()
        for index, point in ipairs(points) do
            destinations[index] = point
            written = index
        end
    end)
    for _, point in ipairs(spawned) do
        synthesised_destinations[object_key(point)] = true
    end
    FIXED.applied[object_key(area)] = layout.name
    log("fixed_spots=" .. layout.name .. " destinations=" .. tostring(raw_count)
        .. "->" .. tostring(array_count(destinations))
        .. " added=" .. tostring(#spawned)
        .. " written=" .. tostring(written) .. "/" .. tostring(#points)
        .. (write_ok and "" or " write_failed=true"))
    return true
end

local function ensure_player_destinations(area)
    area = unwrap(area)
    if not valid(area) then return false end

    local area_key = full_name(area)
    if area_key == "" then return false end

    local list_ok, destinations = pcall(function()
        return area:GetPropertyValue(DESTINATIONS_PROPERTY)
    end)
    if not list_ok or destinations == nil then return false end

    local raw_count = array_count(destinations)
    if raw_count < 0 then return false end

    local valid_destinations = {}
    local anchors = {}
    for index = 1, raw_count do
        local point = unwrap(destinations[index])
        local location = valid(point) and actor_location(point) or nil
        if location ~= nil then
            valid_destinations[#valid_destinations + 1] = {
                actor = point,
                location = copy_vector(location),
                index = index,
            }
            anchors[#anchors + 1] = copy_vector(location)
        end
    end
    if #valid_destinations < 1 then return false end

    local fixed = FIXED.applied[object_key(area)]
    if fixed then return false end
    fixed = FIXED.apply(area, destinations, raw_count, valid_destinations)
    if fixed ~= nil then return fixed end
    local profiled = nil
    for _, profile in ipairs(PLACEMENT_PROFILES) do
        if match_placement_profile(profile, valid_destinations) ~= nil then profiled = profile.name end
    end
    if profiled == nil then
        COVER.improve(area, destinations, valid_destinations, anchors)
    elseif not COVER.improved[object_key(area)] then
        COVER.improved[object_key(area)] = true
        log("improve_spots=skipped reason=profile profile=" .. profiled)
    end

    -- A squad that can't be read yet is left alone; the retries at the hook
    -- site run again. Profile rescues run before the proximity-filtered read,
    -- which would drop an operator far from every destination.
    local staging_rescued, rescued_positions = rescue_known_staging(
        valid_destinations, linked_tactical_area(area))

    local members, stats = player_squad_members(area, anchors)
    last_member_stats = stats
    if members == nil or #members < 1 then return false end
    -- One destination per operator in the squad, not per operator that passed
    -- the proximity filter.
    local squad_size = stats.squad_size or #members
    if squad_size < #members then squad_size = #members end
    local desired = math.min(squad_size, RESCUE.max_destinations)

    if #valid_destinations >= desired then
        return false
    end

    -- Prefer current unit positions furthest from an authored destination.
    -- This naturally chooses the two overflow units on maps where the stock
    -- four are already standing on their four authored points.
    local candidates = {}
    for _, member in ipairs(members) do
        -- A conclusive tactical-volume rejection is stronger than proximity.
        -- In particular, 0/0 on Cold Metal is less than 2000 uu from an
        -- authored point, so the old distance-only filter accepted the hill.
        if member.inside_volume ~= false then
            local nearest = math.huge
            for _, destination in ipairs(valid_destinations) do
                nearest = math.min(nearest,
                    distance_squared(member.location, destination.location))
            end
            local rescued = false
            for _, placed in ipairs(rescued_positions or {}) do
                if xy_distance_squared(member.location, placed)
                    <= MIN_UNIT_SEPARATION_SQ then
                    rescued = true
                    break
                end
            end
            candidates[#candidates + 1] = {
                location = member.location,
                rotation = member.rotation,
                nearest = nearest,
                rescued = rescued,
            }
        end
    end
    -- Positions this pass rescued into the lane are the safest additions, so
    -- they come first.
    table.sort(candidates, function(left, right)
        if left.rescued ~= right.rescued then return left.rescued end
        return left.nearest > right.nearest
    end)

    local template = valid_destinations[1].actor
    local class_ok, point_class = pcall(function() return template:GetClass() end)
    local world_ok, world = pcall(function() return area:GetWorld() end)
    if not class_ok or not world_ok or not valid(point_class) or not valid(world) then return false end

    local team = nil
    pcall(function() team = unwrap(template:GetPropertyValue(PLAYER_TEAM_PROPERTY)) end)

    local lane_points = {}
    for _, destination in ipairs(valid_destinations) do
        lane_points[#lane_points + 1] = destination.location
    end
    local lane = deployment_polygon(lane_points)

    -- If every position about to be added is outside the authored lane and none
    -- was rescued there, prepend points derived from the lane. The off-lane
    -- candidates still follow, since a destination somewhere beats none.
    local missing = desired - #valid_destinations
    local off_lane_derived = false
    if lane ~= nil and missing > 0 and #candidates > 0 then
        local considered, off_lane_only = 0, true
        for _, candidate in ipairs(candidates) do
            if considered >= missing then break end
            local nearest = math.huge
            for _, destination in ipairs(valid_destinations) do
                nearest = math.min(nearest,
                    distance_squared(candidate.location, destination.location))
            end
            if nearest >= MIN_DESTINATION_SEPARATION_SQ
                and nearest <= MAX_DESTINATION_DISTANCE_SQ then
                considered = considered + 1
                if candidate.rescued
                    or inside_deployment(lane, candidate.location) ~= false then
                    off_lane_only = false
                    break
                end
            end
        end
        if considered > 0 and off_lane_only then
            local walkable = walkable_test(area, lane_points)
            local derived, unwalkable = derive_rescue_points(lane, lane_points, members, missing,
                false, walkable, RESCUE.max_destinations)
            derived = COVER.choose("off_lane", members[1].actor, lane, lane_points, members, missing, derived,
                walkable, linked_tactical_area(area), RESCUE.max_destinations)
            local settled, shift = settle_on_floor(area, derived, members)
            if #derived > 0 and not placement_rescue_reported.derived_floor then
                placement_rescue_reported.derived_floor = true
                log(string.format("derived_floor settled=%d/%d largest_shift=%.0f off_navmesh_skipped=%d",
                    settled, #derived, shift, unwalkable))
            end
            local preferred = {}
            for _, point in ipairs(derived) do
                preferred[#preferred + 1] = {
                    location = {X = point.X, Y = point.Y, Z = point.Z},
                    rotation = nil,
                    nearest = point.clearance or 0,
                    rescued = true,
                    derived = true,
                }
            end
            for _, candidate in ipairs(candidates) do
                preferred[#preferred + 1] = candidate
            end
            candidates = preferred
            off_lane_derived = true
        end
    end
    -- A position inside the lane is wherever the game staged someone, cover or
    -- not. For the destinations a rescue hasn't already filled, the game's
    -- cover comes first; with no usable cover nothing changes.
    if lane ~= nil and missing > 0 and not off_lane_derived and #members > 0 then
        local merged, rescued_count = {}, 0
        for _, candidate in ipairs(candidates) do
            if candidate.rescued then
                rescued_count = rescued_count + 1
                merged[#merged + 1] = candidate
            end
        end
        local wanted = missing - rescued_count
        local covered = wanted > 0 and COVER.choose("in_lane", members[1].actor, lane, lane_points,
            members, wanted, {}, walkable_test(area, lane_points), linked_tactical_area(area),
            RESCUE.max_destinations) or {}
        if #covered > 0 then
            settle_on_floor(area, covered, members)
            for _, point in ipairs(covered) do
                merged[#merged + 1] = {
                    location = {X = point.X, Y = point.Y, Z = point.Z},
                    rotation = nil,
                    nearest = 0,
                    rescued = true,
                    derived = true,
                }
            end
            for _, candidate in ipairs(candidates) do
                if not candidate.rescued then merged[#merged + 1] = candidate end
            end
            candidates = merged
        end
    end

    local added, outside_lane, derived_added = 0, 0, 0
    for _, candidate in ipairs(candidates) do
        if #valid_destinations >= desired then break end

        local nearest = math.huge
        for _, destination in ipairs(valid_destinations) do
            nearest = math.min(nearest, distance_squared(candidate.location, destination.location))
        end
        -- Count, but don't reject, positions outside the authored lane: four
        -- points can understate a map's real deployment area (Cold Metal), and
        -- the count makes the case visible in the log.
        if lane ~= nil and inside_deployment(lane, candidate.location) == false then
            local trusted = false
            for _, placed in ipairs(rescued_positions or {}) do
                if xy_distance_squared(candidate.location, placed)
                    <= MIN_UNIT_SEPARATION_SQ then
                    trusted = true
                    break
                end
            end
            if not trusted then outside_lane = outside_lane + 1 end
        end
        if nearest >= MIN_DESTINATION_SEPARATION_SQ
            and nearest <= MAX_DESTINATION_DISTANCE_SQ then
            local spawn_ok, point = pcall(function()
                return world:SpawnActor(point_class, candidate.location, candidate.rotation or {})
            end)
            if spawn_ok and valid(point) then
                if team ~= nil then
                    pcall(function() point[PLAYER_TEAM_PROPERTY] = team end)
                end
                -- Check the return value: a declined teleport returns false
                -- without an error and leaves the point at the origin.
                local moved, accepted = pcall(function()
                    return point:K2_SetActorLocationAndRotation(
                        candidate.location, candidate.rotation or {}, false, {}, true)
                end)
                moved = moved and accepted ~= false
                    and not at_world_origin(actor_location(point) or candidate.location)
                local append_ok = moved and pcall(function()
                    destinations[raw_count + 1] = point
                end)
                if append_ok then
                    raw_count = raw_count + 1
                    added = added + 1
                    if candidate.derived then derived_added = derived_added + 1 end
                    synthesised_destinations[object_key(point)] = true
                    valid_destinations[#valid_destinations + 1] = {
                        actor = point,
                        location = copy_vector(candidate.location),
                    }
                else
                    pcall(function() point:K2_DestroyActor() end)
                end
            end
        end
    end

    if added > 0 and not destination_expansion_reported then
        destination_expansion_reported = true
        log("player_destinations=" .. tostring(#valid_destinations - added)
            .. "->" .. tostring(#valid_destinations)
            .. " squad_members=" .. tostring(#members)
            .. " added_safe_points=" .. tostring(added)
            .. " derived_points=" .. tostring(derived_added)
            .. " outside_lane=" .. tostring(outside_lane)
            .. " staging_rescued=" .. tostring(staging_rescued)
            .. " " .. member_stats_text(stats))
    end
    return added > 0
end

local function placement_state(area)
    area = unwrap(area)
    if not valid(area) then return -1, -1, -1 end

    local list_ok, destinations = pcall(function()
        return area:GetPropertyValue(DESTINATIONS_PROPERTY)
    end)
    if not list_ok or destinations == nil then return -1, -1, -1 end

    local raw_count = array_count(destinations)
    local valid_count = 0
    local anchors = {}
    for index = 1, raw_count do
        local point = unwrap(destinations[index])
        if valid(point) then
            valid_count = valid_count + 1
            local location = actor_location(point)
            if location ~= nil then anchors[#anchors + 1] = copy_vector(location) end
        end
    end

    local members, stats = player_squad_members(area, anchors)
    last_member_stats = stats
    local member_count = members ~= nil and #members or -1
    return member_count, raw_count, valid_count
end

-- Read-only: logs the squad size, the authored destinations and where each unit
-- ended up, for diagnosing placement reports.
local function report_mission_placement()
    local gate_ok, squad = pcall(function() return FindFirstOf(SQUAD_CLASS) end)
    if not gate_ok or not valid(squad) then return end

    local key = full_name(squad)
    if key == "" or reported_squads[key] then return end

    local members_ok, members = pcall(function()
        return squad:GetPropertyValue(SQUAD_MEMBERS_PROPERTY)
    end)
    if not members_ok then return end
    local count = array_count(members)
    if count < 1 then return end
    reported_squads[key] = true

    local positions = {}
    for index = 1, math.min(count, TARGET_SIZE + 4) do
        local member = unwrap(members[index])
        local location = valid(member) and actor_location(member) or nil
        if location ~= nil then
            positions[#positions + 1] = string.format("%.0f/%.0f/%.0f",
                location.X, location.Y, location.Z)
        else
            positions[#positions + 1] = "?/?/?"
        end
    end

    local areas = 0
    local destinations = {}
    local found = FindAllOf(PREPARATION_CLASS)
    if found ~= nil then
        for _, area in pairs(found) do
            if valid(area) then
                areas = areas + 1
                local read_ok, list = pcall(function()
                    return area:GetPropertyValue(DESTINATIONS_PROPERTY)
                end)
                destinations[#destinations + 1] =
                    tostring(read_ok and array_count(list) or -1)
            end
        end
    end

    log("mission squad_members=" .. tostring(count)
        .. " preparation_areas=" .. tostring(areas)
        .. " player_destinations=" .. table.concat(destinations, ",")
        .. " unit_positions=" .. table.concat(positions, ","))
end

-- MovePlayerUnitsIntoPosition is the relocation, and its pre-hook fires with
-- the squad still staged. The repairs after it run on timers measured from
-- that instant: UE4SS never calls post-hooks on Blueprint functions, and the
-- native name never runs because the Blueprint overrides it.
local function relocation_ladder_total()
    local total = 0
    for _, count in pairs(relocation_ladders) do total = total + count end
    return total
end

-- Relocation observations and staged positions belong to one deployment, not
-- to the lifetime of the Lua mod. In particular, relocation_prehook_ran must
-- be re-armed here: otherwise the first mission to relocate a squad prevents
-- every later mission from taking its own pre-relocation snapshot and also
-- disables those missions' fallback repair rungs.
local function begin_deployment(area)
    local key = object_key(area)
    if key == "" then return "" end

    active_deployment_key = key
    active_deployment_area = area
    deployments_begun = deployments_begun + 1
    staged_positions = {}
    repair_counts = {}
    observed_positions = {}
    staging_window_open = true
    relocation_prehook_ran = false
    relocation_fired_name = ""
    relocation_fired_names = {}
    relocation_firing_count = 0
    relocation_scheduled[key] = nil
    relocation_ladders[key] = nil
    repair_passes = 0
    repair_units_seen = 0
    repair_restored_total = 0
    placement_failure_reported = false
    reported_placement_triggers = {}
    destination_expansion_reported = false
    placement_rescue_reported = {}
    restored_positions = {}
    repair_reported = 0
    COVER.markers.shown = {}
    return key
end

-- GetAddress() is only unique while an object is alive. UE can later create a
-- new preparation area at the same address, so its new-object notification
-- must invalidate every address-keyed gate that would otherwise make the new
-- instance look as though it had already deployed and exhausted its ladders.
local function prepare_new_area(area)
    area = unwrap(area)
    local key = object_key(area)
    if key == "" then return end
    placement_attempts[key] = nil
    relocation_scheduled[key] = nil
    relocation_ladders[key] = nil
    FIXED.applied[key] = nil
    COVER.improved[key] = nil
    if active_deployment_key == key then
        active_deployment_key = ""
        active_deployment_area = nil
    end
end

-- squadsixrescue: a synchronous escape hatch for a deployment the player can
-- see has failed. Runs the normal repair without the two-attempt budget, then
-- the hard-signature pass, then the peer fallback.
local function register_rescue_command()
    if registered_rescue_command then return end
    local ok = pcall(function()
        RegisterConsoleCommandHandler("squadsixrescue", function()
            local area = unwrap(active_deployment_area)
            if not valid(area) or active_deployment_key == "" then
                log("manual_rescue=refused reason=no_active_deployment")
                return true
            end

            local units = every_player_unit()
            if #units ~= TARGET_SIZE then
                log("manual_rescue=refused reason=squad_size"
                    .. " members=" .. tostring(#units))
                return true
            end

            local staged = 0
            for _, unit in ipairs(units) do
                if staged_positions[unit.key] ~= nil then staged = staged + 1 end
            end

            -- Run the repair whatever the snapshot looks like: the lane
            -- fallback covers operators a snapshot could never include.
            local restored, stranded = repair_stranded_units(
                area, "console", false, true)
            -- strand_reason gives an operator that is both off-lane and outside
            -- the volume the soft label, which the lane fallback declines. This
            -- is an explicit command, so try the hard signatures too; the soft
            -- pass keeps the last word on `stranded`.
            if restored == 0 and stranded > 0 then
                restored = repair_stranded_units(
                    area, "console_hard", true, true)
            end
            if restored > 0 then
                log("manual_rescue=complete"
                    .. " mode=" .. (staged == TARGET_SIZE and "staged" or "lane")
                    .. " staged=" .. tostring(staged)
                    .. " restored=" .. tostring(restored))
                return true
            end
            if stranded == 0 then
                log("manual_rescue=noop reason=no_stranded_units")
                return true
            end

            local peer_restored, peer_reason, moves =
                manual_peer_rescue(area, units)
            if peer_restored > 0 then
                log("manual_rescue=complete mode=peer_fallback"
                    .. " restored=" .. tostring(peer_restored)
                    .. " warning=shared_tiles"
                    .. " moves=" .. tostring(moves or ""))
            elseif staged ~= TARGET_SIZE then
                log("manual_rescue=refused reason=incomplete_snapshot"
                    .. " staged=" .. tostring(staged)
                    .. " fallback=" .. tostring(peer_reason or "unavailable"))
            else
                log("manual_rescue=failed restored=0"
                    .. " stranded=" .. tostring(stranded)
                    .. " fallback=" .. tostring(peer_reason or "unavailable"))
            end
            return true
        end)
    end)
    registered_rescue_command = ok
    log("rescue_command=" .. tostring(registered_rescue_command))
end

-- Read-only: whether operators the repair put somewhere are still there. One
-- line per check that finds any; it can't tell a walk the game started from one
-- the player ordered, so it only reports.
local function report_drift(via)
    local drifted = {}
    for _, unit in ipairs(every_player_unit()) do
        local restored = restored_positions[unit.key]
        if restored ~= nil
            and distance_squared(restored, unit.location) > REPAIR.drift_radius_sq then
            drifted[#drifted + 1] = string.format("%.0f/%.0f/%.0f->%.0f/%.0f/%.0f",
                restored.X, restored.Y, restored.Z,
                unit.location.X, unit.location.Y, unit.location.Z)
        end
    end
    if #drifted > 0 then
        log("placement_drift via=" .. via .. " units=" .. tostring(#drifted)
            .. " moves=" .. table.concat(drifted, ","))
    end
end

local function on_relocation_starting(context, name)
    local area = unwrap(context)
    if not valid(area) then return end

    local key = object_key(area)
    -- Whether a placement trigger had already opened this deployment.
    -- "adopted" means none had: the relocation is the first thing the mod saw
    -- of this mission.
    local adopted = false
    if key ~= "" and active_deployment_key == "" then
        adopted = true
        begin_deployment(area)
    end

    -- Log every invocation, including a repeated name: a later relocation can
    -- use the same entry point. `ladder` and `coalesced` tell it apart from the
    -- companion name within the 250 ms gate.
    local short = (string.find(name, "^/Script/") and "script:" or "bp:")
        .. (string.match(name, ":([^:]+)$") or name)
    if key ~= "" and active_deployment_key ~= key then
        -- A relocation for some other preparation area must not replace the
        -- live deployment's snapshot; it is logged but gets no repair ladder.
        relocation_firing_count = relocation_firing_count + 1
        log("relocation_fired=" .. short
            .. " event=" .. tostring(relocation_firing_count)
            .. " ladder=none coalesced=false scheduled=false"
            .. " reason=inactive_area")
        return
    end
    if not relocation_fired_names[short] then
        relocation_fired_names[short] = true
        if relocation_fired_name == "" then relocation_fired_name = short end
    end

    -- Only the first relocation gets to record where the squad was staged.
    -- A later one is reading positions the first has already disturbed, and
    -- the whole value of a staged snapshot is that it predates the damage.
    if not relocation_prehook_ran then
        relocation_prehook_ran = true
        staging_window_open = true
        local members, raw_destinations, usable_destinations = placement_state(area)
        staging_window_open = false

        -- One line per deployment saying whether the mod can help. Every
        -- automatic repair needs a staged position, so `staged` short of
        -- `squad` means those operators can't be recovered; `adopted` means no
        -- placement trigger opened the deployment, as after a mid-mission UE4SS
        -- reload.
        local staged = 0
        for _ in pairs(staged_positions) do staged = staged + 1 end
        log("deployment_state=" .. (adopted and "adopted" or "tracked")
            .. " squad=" .. tostring(members)
            .. " destinations=" .. tostring(usable_destinations)
            .. "/" .. tostring(raw_destinations)
            .. " staged=" .. tostring(staged)
            .. " repairable=" .. tostring(members > 0 and staged >= members))
    end

    local coalesced = key ~= "" and relocation_scheduled[key] == true
    local capped = key ~= ""
        and (relocation_ladders[key] or 0) >= MAX_RELOCATION_LADDERS
    local scheduled = key ~= "" and not coalesced and not capped
    if scheduled then
        relocation_scheduled[key] = true
        relocation_ladders[key] = (relocation_ladders[key] or 0) + 1
    end

    relocation_firing_count = relocation_firing_count + 1
    local ladder = key ~= "" and (relocation_ladders[key] or 0) or 0
    log("relocation_fired=" .. short
        .. " event=" .. tostring(relocation_firing_count)
        .. " ladder=" .. (ladder > 0 and tostring(ladder) or "none")
        .. " coalesced=" .. tostring(coalesced)
        .. " scheduled=" .. tostring(scheduled))

    if not scheduled then return end

    -- Hold the gate just long enough to swallow the second hook name for this
    -- same relocation, then re-arm so a later one gets its own repairs.
    ExecuteWithDelay(RELOCATION_COALESCE_MS, function()
        relocation_scheduled[key] = nil
    end)

    -- The relocation happens the moment this returns, so these delays are
    -- measured from it rather than from the trigger.
    ladder = relocation_ladders[key]
    for _, delay in ipairs(REPAIR_DELAYS_MS) do
        local at = delay
        ExecuteWithDelay(at, function()
            ExecuteInGameThread(function()
                if not valid(area) or active_deployment_key ~= key then return end
                repair_stranded_units(area,
                    "post" .. tostring(at) .. (ladder > 1 and ("#" .. ladder) or ""))
            end)
        end)
    end
    for _, delay in ipairs(WATCHDOG_DELAYS_MS) do
        local at = delay
        ExecuteWithDelay(at, function()
            ExecuteInGameThread(function()
                if not valid(area) or active_deployment_key ~= key then return end
                repair_stranded_units(area,
                    "watch" .. tostring(at) .. (ladder > 1 and ("#" .. ladder) or ""),
                    true)
            end)
        end)
    end
    for _, delay in ipairs(REPAIR.drift_checks_ms) do
        local at = delay
        ExecuteWithDelay(at, function()
            ExecuteInGameThread(function()
                if active_deployment_key ~= key then return end
                report_drift("drift" .. tostring(at) .. (ladder > 1 and ("#" .. ladder) or ""))
            end)
        end)
    end
end

-- No early return once one name registers: the native name resolves at startup,
-- but the Blueprint names, the ones that actually run, only once a mission
-- level loads.
local function register_relocation_hook()
    local count = 0
    for _, function_name in ipairs(MOVE_UNITS_FUNCTIONS) do
        if not registered_relocation_names[function_name] then
            if valid(StaticFindObject(function_name)) then
                local name = function_name
                local ok, pre_id = pcall(function()
                    return RegisterHook(name,
                        function(context) on_relocation_starting(context, name) end)
                end)
                registered_relocation_names[function_name] = ok and pre_id ~= nil
                if registered_relocation_names[function_name] then
                    local origin = string.find(name, "^/Script/") and "script" or "bp"
                    log("relocation_hook=" .. origin .. ":"
                        .. (string.match(name, ":([^:]+)$") or name))
                end
            end
        end
        if registered_relocation_names[function_name] then count = count + 1 end
    end
    -- One is enough; the Blueprint names only exist once a mission level has
    -- loaded, so this keeps being retried until then.
    registered_relocation_hook = count > 0
end

-- BP_CombatPreparationArea_C only exists once a mission level has loaded,
-- which is long after the maintenance loop has finished and stopped. Without
-- this the relocation hook would only ever be attempted while the class does
-- not exist yet.
local function register_area_notification()
    if registered_area_notification then return end
    local ok = pcall(function()
        NotifyOnNewObject(PREPARATION_AREA_CLASS_PATH, function(area)
            prepare_new_area(area)
            register_relocation_hook()
        end)
    end)
    registered_area_notification = ok
    log("area_notification=" .. tostring(registered_area_notification))
end

local function register_placement_triggers()
    if not registered_placement_hook then
        local count = 0
        for _, function_name in ipairs(PLACEMENT_TRIGGER_FUNCTIONS) do
            if not registered_placement_triggers[function_name] then
                local function_object = StaticFindObject(function_name)
                if valid(function_object) then
                    local trigger_name = function_name
                    local ok, first_id = pcall(function()
                        return RegisterHook(trigger_name, function(context)
                            local area = unwrap(context)
                            local area_key = object_key(area)
                            local first_trigger =
                                area_key ~= "" and not placement_attempts[area_key]
                            -- Open the staging window before anything reads
                            -- the squad, so the very first read -- the one
                            -- most likely to precede the relocation -- is the
                            -- snapshot the repair pass restores to.
                            if first_trigger then
                                begin_deployment(area)
                            end
                            local expanded = ensure_player_destinations(area)
                            local members, raw_destinations, valid_destinations =
                                placement_state(area)
                            if not reported_placement_triggers[trigger_name] then
                                reported_placement_triggers[trigger_name] = true
                                local short_name = string.match(trigger_name, ":([^:]+)$")
                                    or trigger_name
                                log("placement_trigger=" .. short_name
                                    .. " squad_members=" .. tostring(members)
                                    .. " destinations=" .. tostring(raw_destinations)
                                    .. " valid_destinations=" .. tostring(valid_destinations)
                                    .. " expanded=" .. tostring(expanded)
                                    .. " " .. member_stats_text(last_member_stats))
                            end
                            -- Always retry: at trigger time the squad is
                            -- frequently still empty, which is now a refusal
                            -- rather than a guess.
                            if first_trigger then
                                placement_attempts[area_key] = true
                                -- The squad can take seconds to become
                                -- readable, so the retries reach eight seconds.
                                -- Each rung is a cheap read.
                                local delays = {0, 50, 100, 250, 500, 1000,
                                    2000, 3000, 5000, 8000}
                                for attempt = 1, #delays do
                                    local retry_index = attempt
                                    local retry_delay = delays[attempt]
                                    ExecuteWithDelay(retry_delay, function()
                                        ExecuteInGameThread(function()
                                            if not valid(area) then return end
                                            -- Past this point a position read
                                            -- off a unit may be the relocated
                                            -- one, so it is no longer evidence
                                            -- of where the game staged it.
                                            if retry_delay > STAGING_WINDOW_MS then
                                                staging_window_open = false
                                            end
                                            ensure_player_destinations(area)
                                            local retry_members, _, retry_valid = placement_state(area)
                                            -- After a second the relocation has run,
                                            -- so later rungs repair what it stranded:
                                            -- only as a fallback when the relocation
                                            -- pre-hook never fired, since repairing
                                            -- this late could move an operator the
                                            -- player already controls.
                                            if retry_delay >= 1000
                                                and not relocation_prehook_ran then
                                                repair_stranded_units(area, "rung" .. tostring(retry_delay))
                                            end
                                            -- Report how the last rung ended whatever
                                            -- the outcome, including never reading a
                                            -- squad.
                                            if retry_index == #delays
                                                and not placement_failure_reported then
                                                placement_failure_reported = true
                                                log("placement_final"
                                                    .. " squad_members=" .. tostring(retry_members)
                                                    .. " valid_destinations=" .. tostring(retry_valid)
                                                    .. " relocation_hook=" .. tostring(registered_relocation_hook)
                                                    .. " relocation_pre=" .. tostring(relocation_prehook_ran)
                                                    .. " relocation_fired=" .. (relocation_fired_name == "" and "none" or relocation_fired_name)
                                                    .. " relocation_ladders=" .. tostring(relocation_ladder_total())
                                                    .. " repair_passes=" .. tostring(repair_passes)
                                                    .. " repair_units=" .. tostring(repair_units_seen)
                                                    .. " repair_restored=" .. tostring(repair_restored_total)
                                                    .. " " .. member_stats_text(last_member_stats))
                                                report_mission_placement()
                                                if retry_members > retry_valid then
                                                    log("WARNING: fewer destinations than deployed"
                                                        .. " operators; two may share a start tile")
                                                end
                                            end
                                        end)
                                    end)
                                end
                            end
                        end)
                    end)
                    registered_placement_triggers[function_name] = ok and first_id ~= nil
                end
            end
            if registered_placement_triggers[function_name] then count = count + 1 end
        end
        registered_placement_hook = count == #PLACEMENT_TRIGGER_FUNCTIONS
        if count > 0 then
            log("placement_hooks=" .. tostring(count)
                .. "/" .. tostring(#PLACEMENT_TRIGGER_FUNCTIONS))
        end
    end
end

-- Mission start (see SPAWN): the squad is watched from the moment the tactical
-- game state exists until the mission's first deployment opens.
local spawn_watch = nil
local registered_spawn_watch = false

-- Somewhere on the navmesh beside `peer`, clear of every operator, or nil.
local function spot_beside(peer, peer_floor, units)
    for _, radius in ipairs(SPAWN.offsets) do
        for step = 0, 7 do
            local angle = step * math.pi / 4
            local floor = navigation_floor(peer.actor, {
                X = peer_floor.X + radius * math.cos(angle),
                Y = peer_floor.Y + radius * math.sin(angle),
                Z = peer_floor.Z,
            })
            if floor ~= nil and math.abs(floor.Z - peer_floor.Z) <= SPAWN.max_step then
                local clear = true
                for _, other in ipairs(units) do
                    if xy_distance_squared(floor, other.location) < MIN_UNIT_SEPARATION_SQ then
                        clear = false
                        break
                    end
                end
                if clear then
                    return {X = floor.X, Y = floor.Y,
                            Z = floor.Z + (peer.location.Z - peer_floor.Z)}
                end
            end
        end
    end
    return nil
end

-- An operator standing still off the navmesh, with a squadmate on it within
-- reach, goes beside that squadmate. Retake Luunata puts one of six at
-- 159338/-576078, off the navmesh: that operator never follows the squad, in
-- both six-operator runs, and the combat-preparation relocation can't move it
-- either. Once per operator per mission, whatever the outcome.
local function check_spawned_squad(watch)
    local units = every_player_unit()
    if #units <= SPAWN.stock_squad then return end
    watch.squad = #units

    local floors, on_floor = {}, 0
    for index, unit in ipairs(units) do
        local previous = watch.positions[unit.key]
        if previous ~= nil
            and distance_squared(previous, unit.location) < REPAIR.settled_radius_sq then
            watch.still[unit.key] = (watch.still[unit.key] or 0) + 1
        else
            watch.still[unit.key] = 0
        end
        watch.positions[unit.key] = copy_vector(unit.location)
        if not at_world_origin(unit.location) then
            floors[index] = navigation_floor(unit.actor, unit.location)
            if floors[index] ~= nil then on_floor = on_floor + 1 end
        end
    end
    -- Half the squad on the navmesh at least: an intro can park the whole squad
    -- somewhere without one, and "off the navmesh" then means nothing.
    if on_floor * 2 < #units then return end

    for index, unit in ipairs(units) do
        if floors[index] == nil and not watch.moved[unit.key]
            and not at_world_origin(unit.location)
            and watch.still[unit.key] >= SPAWN.settle_checks then
            local peer, peer_floor, nearest = nil, nil, SPAWN.peer_radius_sq
            for other_index, other in ipairs(units) do
                local distance = distance_squared(other.location, unit.location)
                if floors[other_index] ~= nil and distance <= nearest then
                    peer, peer_floor, nearest = other, floors[other_index], distance
                end
            end
            if peer ~= nil then
                watch.moved[unit.key] = true
                local from = copy_vector(unit.location)
                local target = spot_beside(peer, peer_floor, units)
                local result = "no_spot"
                if target ~= nil then
                    local moved, accepted = pcall(function()
                        return unit.actor:K2_SetActorLocationAndRotation(
                            target, actor_rotation(unit.actor) or {}, false, {}, true)
                    end)
                    if moved and accepted ~= false then
                        halt(unit.actor)
                        unit.location = copy_vector(target)
                        watch.rescued = watch.rescued + 1
                        result = "moved"
                    else
                        result = "refused"
                    end
                end
                log(string.format("spawn_rescue=%s from=%.0f/%.0f/%.0f to=%s"
                    .. " beside=%.0f/%.0f/%.0f squad=%d on_navmesh=%d",
                    result, from.X, from.Y, from.Z,
                    target ~= nil and string.format("%.0f/%.0f/%.0f",
                        target.X, target.Y, target.Z) or "none",
                    peer.location.X, peer.location.Y, peer.location.Z,
                    #units, on_floor))
            end
        end
    end
end

local function start_spawn_watch(game_state)
    COVER.markers.preload()
    local watch = {state = game_state, deployment = deployments_begun,
        elapsed = 0, squad = 0, rescued = 0, positions = {}, still = {}, moved = {}}
    spawn_watch = watch
    local function finish(reason)
        spawn_watch = nil
        if watch.squad > SPAWN.stock_squad then
            log("spawn_watch=done reason=" .. reason
                .. " after=" .. tostring(math.floor(watch.elapsed / 1000)) .. "s"
                .. " squad=" .. tostring(watch.squad)
                .. " rescued=" .. tostring(watch.rescued))
        end
    end
    LoopAsync(SPAWN.interval_ms, function()
        if spawn_watch ~= watch then return true end
        watch.elapsed = watch.elapsed + SPAWN.interval_ms
        if deployments_begun ~= watch.deployment then
            finish("deployment")
            return true
        end
        if watch.elapsed > SPAWN.watch_ms then
            finish("timeout")
            return true
        end
        ExecuteInGameThread(function()
            if spawn_watch ~= watch then return end
            if not valid(watch.state) then
                finish("mission_ended")
                return
            end
            local ok, err = pcall(check_spawned_squad, watch)
            if not ok then
                log("spawn_watch=error " .. tostring(err))
                finish("error")
            end
        end)
        return false
    end)
end

local function register_spawn_watch()
    if registered_spawn_watch then return end
    local ok = pcall(function()
        NotifyOnNewObject("/Script/BitReactorGame." .. TACTICAL_GAME_STATE_CLASS, function(game_state)
            ExecuteWithDelay(0, function()
                ExecuteInGameThread(function() start_spawn_watch(game_state) end)
            end)
        end)
    end)
    registered_spawn_watch = ok
    log("spawn_watch=" .. tostring(registered_spawn_watch))
    -- A UE4SS reload in the middle of a mission: watch the squad already there.
    local found_ok, existing = pcall(function() return FindFirstOf(TACTICAL_GAME_STATE_CLASS) end)
    if found_ok and valid(existing) then start_spawn_watch(existing) end
end

return {
    -- Every game name this module depends on, for selfcheck.lua.
    game_names = {
        {"function", PLACEMENT_TRIGGER_FUNCTIONS[1]},
        {"function", PLACEMENT_TRIGGER_FUNCTIONS[2]},
        {"function", MOVE_UNITS_FUNCTIONS[3]},
        {"function", "/Script/BitReactorGame.CombatPreparationArea:" .. LINKED_AREA_FUNCTION},
        {"function", "/Script/BitReactorGame.TacticalAreaVolume:" .. INSIDE_AREA_FUNCTION},
        {"function", FLOOR.project_function},
        {"function", "/Script/Engine.Pawn:GetController"},
        {"function", "/Script/Engine.Controller:StopMovement"},
        {"property", "/Script/BitReactorGame.CombatPreparationArea", DESTINATIONS_PROPERTY},
        {"property", "/Script/BitReactorGame.TacticalPoint", PLAYER_TEAM_PROPERTY},
        {"property", "/Script/BitReactorGame." .. SQUAD_CLASS, SQUAD_MEMBERS_PROPERTY},
        {"property", "/Script/BitReactorGame." .. TACTICAL_GAME_STATE_CLASS, PLAYER_SQUAD_PROPERTY},
        -- The Blueprint override only loads with a mission level.
        {"class", PREPARATION_AREA_CLASS_PATH, when = "mission"},
        {"function", MOVE_UNITS_FUNCTIONS[1], when = "mission"},
        {"function", MOVE_UNITS_FUNCTIONS[2], when = "mission"},
    },
    register_rescue_command = register_rescue_command,
    register_relocation_hook = register_relocation_hook,
    register_area_notification = register_area_notification,
    register_placement_triggers = register_placement_triggers,
    register_spawn_watch = register_spawn_watch,
    -- The lane geometry, for tests/placement_maps_test.lua, which runs it over every
    -- deployment area in the game (data/mapscan.json), and for the dev probe
    -- (dev/SquadSixReforgedProbe). Not used by the runtime.
    internals = {
        RESCUE = RESCUE,
        PLACEMENT_PROFILES = PLACEMENT_PROFILES,
        FIXED = FIXED,
        deployment_polygon = deployment_polygon,
        inside_deployment = inside_deployment,
        derive_rescue_points = derive_rescue_points,
        match_placement_profile = match_placement_profile,
    },
    -- Read-only view of the flags main.lua reports and waits on.
    state = function()
        return {
            registered_placement_hook = registered_placement_hook,
        }
    end,
}
