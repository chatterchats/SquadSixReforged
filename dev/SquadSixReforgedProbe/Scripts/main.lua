-- Squad Six probe v0.2.0: a development tool, never shipped (it lives outside src/).
--
-- In a mission it checks, against the game's own data, the spots Squad Six would put operators 5
-- and 6 on, and records how a deployment unfolds:
--   - every deployment area's authored destinations (a control: these are known-good), the
--     fallback spots placement.lua derives for its lane, and any destinations the runtime adds,
--     each checked against the navmesh and a floor trace;
--   - where the squad's operators stand during the first seconds of the mission (the staging
--     positions the relocation starts from);
--   - a timeline of when areas, destinations and squad members appear.
-- It runs while missions load, so it keeps object searches rare: deployment areas are searched for
-- every AREA_SCAN_SECONDS, and the squad is read from the mission's own game state. (0.1.0 also
-- searched for grid volumes, once per destination every second; no mission ever had one.)
-- Read-only: it registers no hooks (only one mod's hook on a Blueprint function survives, so it
-- must not compete with Squad Six's) and writes nothing to the game. Output goes to UE4SS.log,
-- squadsix_probe.log and squadsix_probe.jsonl in the mod folder. `squadsixprobe` in the UE4SS
-- console checks every area immediately.
local VERSION = "0.2.0"
local TAG = "[SQUADSIX_PROBE]"
local WATCH_INTERVAL_MS = 1000
local WATCH_SECONDS = 120          -- per mission
local AREA_SCAN_SECONDS = 5        -- how often to search for deployment areas
local CHECK_AFTER_SECONDS = 10     -- an area's spots are checked this long after it appears
local STAGING_SECONDS = 30         -- how long squad positions are recorded
local MOVED = 50                   -- uu; smaller position changes aren't logged again
local TRACE_ABOVE, TRACE_BELOW = 300, 1000
local NAV_EXTENT = {X = 50, Y = 50, Z = 250}

local source = debug.getinfo(1, "S").source:gsub("^@", "")
local directory = assert(source:match("^(.*[/\\])"), "Scripts directory unavailable")
-- Squad Six's own placement code, so the probe checks exactly the spots the runtime uses.
-- Installed, Mods/SquadSixReforgedProbe sits next to Mods/SquadSixReforged; tests point elsewhere.
local runtime_scripts = SquadSixProbeRuntimeScripts or (directory .. "../../SquadSixReforged/Scripts/")
local output_dir = SquadSixProbeOutputDir or (directory .. "../")
package.path = runtime_scripts .. "?.lua;" .. package.path
for _, module in ipairs({"common", "placement"}) do package.loaded[module] = nil end

local log_file = io.open(output_dir .. "squadsix_probe.log", "a")
local results_file = io.open(output_dir .. "squadsix_probe.jsonl", "a")

local function log(message)
    local line = TAG .. " " .. message
    print(line)
    if log_file then
        log_file:write(os.date("%Y-%m-%d %H:%M:%S "), line, "\n")
        log_file:flush()
    end
end

local function encode(value)
    local kind = type(value)
    if kind == "table" then
        if #value > 0 or next(value) == nil then
            local items = {}
            for index, item in ipairs(value) do items[index] = encode(item) end
            return "[" .. table.concat(items, ",") .. "]"
        end
        local keys, items = {}, {}
        for key in pairs(value) do keys[#keys + 1] = tostring(key) end
        table.sort(keys)
        for _, key in ipairs(keys) do items[#items + 1] = string.format("%q:%s", key, encode(value[key])) end
        return "{" .. table.concat(items, ",") .. "}"
    elseif kind == "number" then
        return value == math.floor(value) and string.format("%d", value) or string.format("%.3f", value)
    elseif kind == "string" then
        return string.format("%q", value)
    elseif kind == "boolean" then
        return tostring(value)
    end
    return "null"
end

local function record(entry)
    if results_file then
        results_file:write(encode(entry), "\n")
        results_file:flush()
    end
end

local loaded, Common = pcall(require, "common")
local placement_loaded, Placement = pcall(require, "placement")
if not loaded or not placement_loaded then
    log("ERROR: can't load Squad Six's scripts from " .. runtime_scripts .. ": "
        .. tostring(loaded and Placement or Common))
    return
end
local geometry = Placement.internals
local valid, unwrap, full_name = Common.valid, Common.unwrap, Common.full_name
local actor_location, array_count = Common.actor_location, Common.array_count

-- Whole units, and never "-0".
local function whole(value)
    local rounded = math.floor(value + 0.5)
    return string.format("%d", rounded == 0 and 0 or rounded)
end

local function xyz(point)
    return whole(point.X) .. "/" .. whole(point.Y) .. "/" .. whole(point.Z)
end

local function vector(point) return {X = point.X, Y = point.Y, Z = point.Z} end

-- "SK_Lothal_035_Gameplay:BP_CombatPreparationArea_C_0", as data/mapscan.json names areas.
local function area_key(area)
    local name = full_name(area)
    local package = name:match("%s(/[^%.]+)%.") or name
    return (package:match("[^/]+$") or package) .. ":" .. (name:match("[%.:]([^%.:]+)$") or name)
end

------------------------------------------------------------------------------------------------
-- The game's answers about one point (at floor level).

local function nav_check(context, point)
    local navigation = StaticFindObject("/Script/NavigationSystem.Default__NavigationSystemV1")
    if not valid(navigation) then return {nav = "unchecked"} end
    local projected = {}
    local ok, found = pcall(function()
        return navigation:K2_ProjectPointToNavigation(context, point, projected, nil, nil, NAV_EXTENT)
    end)
    if not ok or type(found) ~= "boolean" then return {nav = "unchecked"} end
    if not found then return {nav = "none"} end
    local result = {nav = "ok"}
    if type(projected.X) == "number" then
        result.nav_point = vector(projected)
        result.nav_d = math.sqrt((projected.X - point.X) ^ 2 + (projected.Y - point.Y) ^ 2
            + (projected.Z - point.Z) ^ 2)
    end
    return result
end

local function floor_check(context, point)
    local kismet = StaticFindObject("/Script/Engine.Default__KismetSystemLibrary")
    if not valid(kismet) then return {floor = "unchecked"} end
    local hit = {}
    local colour = {R = 1, G = 0, B = 0, A = 1}
    local ok, blocked = pcall(function()
        return kismet:LineTraceSingle(context,
            {X = point.X, Y = point.Y, Z = point.Z + TRACE_ABOVE},
            {X = point.X, Y = point.Y, Z = point.Z - TRACE_BELOW},
            0, false, {}, 0, hit, true, colour, colour, 0)
    end)
    if not ok or type(blocked) ~= "boolean" then return {floor = "unchecked"} end
    if not blocked then return {floor = "none"} end
    local impact = hit.ImpactPoint or hit.Location
    if impact == nil or type(impact.Z) ~= "number" then return {floor = "hit"} end
    return {floor = "hit", floor_dz = impact.Z - point.Z}
end

local function check_point(context, label, point)
    local result = {label = label, point = vector(point)}
    for _, part in ipairs({nav_check(context, point), floor_check(context, point)}) do
        for key, value in pairs(part) do result[key] = value end
    end
    return result
end

local function describe(result)
    local parts = {result.label .. " " .. xyz(result.point)}
    parts[#parts + 1] = "nav=" .. result.nav .. (result.nav_d and " d=" .. whole(result.nav_d) or "")
    parts[#parts + 1] = "floor=" .. result.floor .. (result.floor_dz and " dz=" .. whole(result.floor_dz) or "")
    return table.concat(parts, " ")
end

------------------------------------------------------------------------------------------------
-- One mission.

local session = nil

local function destinations_of(area)
    local list_ok, list = pcall(function() return area:GetPropertyValue("PlayerDestinations") end)
    if not list_ok or list == nil then return nil end
    local points = {}
    for index = 1, array_count(list) do
        local point = unwrap(list[index])
        local location = valid(point) and actor_location(point) or nil
        if location ~= nil then points[#points + 1] = vector(location) end
    end
    return points
end

local function check_area(state, reason)
    local area = state.area
    if not valid(area) then return end
    local key, elapsed = state.key, session.elapsed
    local results = {authored = {}, derived = {}, added = {}}
    local counts = {}
    local function add(kind, label, point)
        local result = check_point(area, label, point)
        table.insert(results[kind], result)
        counts[kind] = counts[kind] or {total = 0, nav = 0, floor = 0}
        local c = counts[kind]
        c.total = c.total + 1
        if result.nav == "ok" then c.nav = c.nav + 1 end
        if result.floor_dz and math.abs(result.floor_dz) <= 50 then c.floor = c.floor + 1 end
        log("    " .. kind .. " " .. describe(result))
    end
    log(string.format("area %s (%s, t=%ds): %d authored destinations", key, reason, elapsed, #state.authored))
    for index, point in ipairs(state.authored) do add("authored", "authored" .. index, point) end
    local lane = geometry.deployment_polygon(state.authored)
    if lane == nil then
        log("    no lane: the destinations are collinear")
    else
        -- Nobody standing on a destination: heights use RESCUE.capsule_height, so subtracting it
        -- gives the floor height the spot assumes.
        local derived = geometry.derive_rescue_points(lane, state.authored, {}, 2)
        for index, point in ipairs(derived) do
            add("derived", "derived" .. index,
                {X = point.X, Y = point.Y, Z = point.Z - geometry.RESCUE.capsule_height})
        end
    end
    for index, point in ipairs(state.added) do add("added", "added" .. index, point) end
    local summary = {}
    for _, kind in ipairs({"authored", "derived", "added"}) do
        local c = counts[kind]
        if c then
            summary[#summary + 1] = string.format("%s %d: nav %d, floor within 50 uu %d",
                kind, c.total, c.nav, c.floor)
        end
    end
    log("    summary: " .. table.concat(summary, "; "))
    record({type = "area", version = VERSION, mission = session.mission, key = key, reason = reason,
            elapsed = elapsed, results = results})
end

local function squad_members()
    local state = session.game_state
    if not valid(state) then return {} end
    local squad_ok, squad = pcall(function() return unwrap(state:GetPropertyValue("PlayerSquad")) end)
    if not squad_ok or not valid(squad) then return {} end
    local members_ok, members = pcall(function() return squad:GetPropertyValue("SquadMembers") end)
    if not members_ok or members == nil then return {} end
    local result = {}
    for index = 1, array_count(members) do
        local member = unwrap(members[index])
        local location = valid(member) and actor_location(member) or nil
        if location ~= nil then
            local name = full_name(member)
            result[#result + 1] = {name = name:match("[%.:]([^%.:]+)$") or name:match("(%S+)$") or "?",
                                   location = vector(location)}
        end
    end
    return result
end

local function watch_squad()
    local members = squad_members()
    if #members == 0 then return end
    session.squad_seen = session.squad_seen or session.elapsed
    if session.elapsed - session.squad_seen > STAGING_SECONDS then return end
    local changed = #members ~= #session.positions
    for index, member in ipairs(members) do
        local previous = session.positions[index]
        if previous == nil or math.sqrt((previous.X - member.location.X) ^ 2
            + (previous.Y - member.location.Y) ^ 2 + (previous.Z - member.location.Z) ^ 2) > MOVED then
            changed = true
        end
    end
    if not changed then return end
    local text = {}
    for index, member in ipairs(members) do
        session.positions[index] = member.location
        text[#text + 1] = member.name .. "=" .. xyz(member.location)
    end
    log(string.format("squad t=%ds members=%d %s", session.elapsed, #members, table.concat(text, " ")))
    record({type = "squad", version = VERSION, mission = session.mission, elapsed = session.elapsed,
            members = members})
end

local function tick()
    -- Ticks already queued on the game thread when the watch finished must not run it again.
    if session == nil or session.done then return end
    session.elapsed = session.elapsed + WATCH_INTERVAL_MS / 1000
    local final = session.elapsed >= WATCH_SECONDS

    if session.elapsed >= session.next_scan or final then
        session.next_scan = session.elapsed + AREA_SCAN_SECONDS
        local found = {}
        for _, area in pairs(FindAllOf("BP_CombatPreparationArea_C") or {}) do
            if valid(area) then found[#found + 1] = area end
        end
        if #found ~= #session.found then
            log(string.format("timeline t=%ds areas=%d", session.elapsed, #found))
        end
        session.found = found
    end

    for _, area in ipairs(session.found) do
        if valid(area) then
            local key = area_key(area)
            local state = session.areas[key]
            local points = destinations_of(area)
            if state == nil and points ~= nil and #points > 0 then
                -- First sight, before combat preparation: these are the authored destinations.
                state = {key = key, area = area, authored = points, added = {}, checked = false,
                         seen = session.elapsed}
                session.areas[key] = state
                log(string.format("timeline t=%ds area %s destinations=%d", session.elapsed, key, #points))
            elseif state ~= nil and points ~= nil and #points > #state.authored + #state.added then
                for index = #state.authored + #state.added + 1, #points do
                    state.added[#state.added + 1] = points[index]
                end
                log(string.format("timeline t=%ds area %s destinations=%d (runtime added %d)",
                    session.elapsed, key, #points, #state.added))
                if state.checked then check_area(state, "destinations_added") end
            end
            if state ~= nil then
                state.area = area
                -- Give the navmesh time to stream in with the level before asking it.
                if not state.checked and (session.elapsed - state.seen >= CHECK_AFTER_SECONDS or final) then
                    state.checked = true
                    check_area(state, "settled")
                end
            end
        end
    end

    watch_squad()
    if final then
        log(string.format("mission watch finished after %ds", session.elapsed))
        session.done = true
    end
end

local function start_session(game_state)
    session = {mission = full_name(game_state), game_state = game_state, elapsed = 0, areas = {},
               positions = {}, found = {}, next_scan = 0}
    log("mission start: " .. session.mission)
    local current = session
    LoopAsync(WATCH_INTERVAL_MS, function()
        if session ~= current or current.done then return true end
        ExecuteInGameThread(function()
            if session == current then
                local ok, err = pcall(tick)
                if not ok then log("ERROR in watch: " .. tostring(err)) end
            end
        end)
        return false
    end)
end

------------------------------------------------------------------------------------------------

log(string.format("loaded version=%s runtime_scripts=%s", VERSION, runtime_scripts))

NotifyOnNewObject("/Script/BitReactorGame.TacticalGameState", function(game_state)
    ExecuteWithDelay(0, function()
        ExecuteInGameThread(function() start_session(game_state) end)
    end)
end)

RegisterConsoleCommandHandler("squadsixprobe", function()
    if session == nil then
        local game_state = FindFirstOf("TacticalGameState")
        if not valid(game_state) then
            log("squadsixprobe: not in a mission")
            return true
        end
        start_session(game_state)
    end
    for _, area in pairs(FindAllOf("BP_CombatPreparationArea_C") or {}) do
        local key = area_key(area)
        local state = session.areas[key]
        if state == nil then
            local points = destinations_of(area)
            if points ~= nil and #points > 0 then
                state = {key = key, area = area, authored = points, added = {}, checked = false,
                         seen = session.elapsed}
                session.areas[key] = state
            end
        end
        if state ~= nil then
            state.checked = true
            check_area(state, "console")
        end
    end
    return true
end)

-- A UE4SS mod reload in the middle of a mission: start watching straight away.
local existing = FindFirstOf("TacticalGameState")
if valid(existing) then start_session(existing) end
