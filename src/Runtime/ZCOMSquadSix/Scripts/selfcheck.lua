-- Startup self-check: does every game name the runtime depends on still resolve?
--
-- A game update can rename a Blueprint function, rename or re-key a Blueprint variable, or
-- move an asset. Most of the runtime treats a missing name as "nothing to do" and carries on
-- quietly, so without this the first sign of a broken name is a player report. One line per
-- phase answers it from the log instead:
--
--   selfcheck phase=startup ok=22 missing=none unchecked=none
--   selfcheck phase=mission ok=3 missing=BP_CombatPreparationArea_C:MovePlayerUnitsIntoPosition unchecked=none
--
-- `missing` means the check ran and the name is gone. `unchecked` means it couldn't run (a UE4SS
-- reflection call failed), which says nothing about the game either way.
--
-- Names come from each module's `game_names`, built from the same constants the code uses, so
-- the list can't drift from the code. Startup names are checked once main.lua has loaded the two
-- UI assets; mission names (BP_CombatPreparationArea) only exist once a mission level loads, so
-- they are checked a few seconds after a TacticalGameState appears.
local Common = require("common")
local log = Common.log
local valid = Common.valid

local MISSION_TRIGGER_CLASS = "/Script/BitReactorGame.TacticalGameState"
-- Seconds after the game state appears; the level's Blueprints may still be streaming in.
local MISSION_CHECK_DELAYS_MS = {3000, 10000, 30000}

local function find(path)
    local ok, found = pcall(function() return StaticFindObject(path) end)
    if ok and valid(found) then return found end
    return nil
end

-- true / false, or nil when reflection is unavailable. Walks the super chain, since a property
-- may be declared on a parent, and compares case-insensitively, as FName lookups do (the
-- runtime reads `characterVM`; VM_ActivitySlot_C declares `CharacterVM`).
local function has_property(owner, name)
    local wanted = string.lower(name)
    local struct = owner
    local depth = 0
    while struct ~= nil and valid(struct) and depth < 32 do
        local found = false
        local ok = pcall(function()
            struct:ForEachProperty(function(property)
                if string.lower(property:GetFName():ToString()) == wanted then
                    found = true
                    return true
                end
            end)
        end)
        if not ok then return nil end
        if found then return true end
        local super_ok, super = pcall(function() return struct:GetSuperStruct() end)
        if not super_ok then return nil end
        struct = super
        depth = depth + 1
    end
    return false
end

-- "ok", "missing" or "unchecked", and a short label for the log.
local function check(entry)
    local kind, path, name = entry[1], entry[2], entry[3]
    local label = string.match(path, "[^/.]+$") or path
    if kind == "property" then
        label = label .. "." .. name
        local owner = find(path)
        if owner == nil then return "missing", label end
        local found = has_property(owner, name)
        if found == nil then return "unchecked", label end
        return found and "ok" or "missing", label
    end
    -- "function" and "class" are both UObjects.
    return find(path) and "ok" or "missing", label
end

local function run(phase, entries)
    local ok, missing, unchecked = 0, {}, {}
    for _, entry in ipairs(entries) do
        local state, label = check(entry)
        if state == "ok" then
            ok = ok + 1
        elseif state == "missing" then
            missing[#missing + 1] = label
        else
            unchecked[#unchecked + 1] = label
        end
    end
    log("selfcheck phase=" .. phase
        .. " ok=" .. tostring(ok)
        .. " missing=" .. (#missing > 0 and table.concat(missing, ",") or "none")
        .. " unchecked=" .. (#unchecked > 0 and table.concat(unchecked, ",") or "none"))
    return #missing == 0 and #unchecked == 0
end

local startup, mission = {}, {}
local startup_done, mission_registered = false, false
local mission_started, mission_reported = false, false

-- Collect every module's names, split by when they can exist.
local function add(names)
    for _, entry in ipairs(names) do
        if entry.when == "mission" then
            mission[#mission + 1] = entry
        else
            startup[#startup + 1] = entry
        end
    end
end

local function check_startup()
    if startup_done then return end
    startup_done = true
    run("startup", startup)
end

-- Once per session: the first mission is enough to see whether its names survived.
local function register_mission_check()
    if mission_registered or #mission == 0 then return end
    local ok = pcall(function()
        NotifyOnNewObject(MISSION_TRIGGER_CLASS, function()
            if mission_started then return end
            mission_started = true
            for attempt, delay in ipairs(MISSION_CHECK_DELAYS_MS) do
                ExecuteWithDelay(delay, function()
                    ExecuteInGameThread(function()
                        if mission_reported then return end
                        -- Report once everything resolves, or on the last attempt whatever
                        -- the result, so a genuinely missing name is still logged.
                        local all_found = true
                        for _, entry in ipairs(mission) do
                            if check(entry) ~= "ok" then all_found = false break end
                        end
                        if all_found or attempt == #MISSION_CHECK_DELAYS_MS then
                            mission_reported = true
                            run("mission", mission)
                        end
                    end)
                end)
            end
        end)
    end)
    mission_registered = ok
end

return {
    add = add,
    check_startup = check_startup,
    register_mission_check = register_mission_check,
}
