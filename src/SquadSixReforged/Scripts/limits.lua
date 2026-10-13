-- Mission squad limits: raise each mission definition's MaxSquadSize to six at runtime
-- and keep the missions that deploy a scripted cast at their authored four.
-- Why each rule exists, with the reports behind it: docs/runtime-notes.md.
local Common = require("common")
local TARGET_SIZE = Common.TARGET_SIZE
local AUTHORED_SIZE = Common.AUTHORED_SIZE
local log = Common.log
local unwrap = Common.unwrap
local full_name = Common.full_name

local MAXIMUM_PROPERTY = "Max" .. "Squad" .. "Size"
-- Every mission definition in the game is a BrunoMissionData (all 125, read from the cooked
-- packages). Up to 1.1.4 the sweep enumerated every DataAsset and probed each one for
-- MaxSquadSize inside a pcall, so every non-mission asset cost a thrown error per pass.
local MISSION_CLASS = "BrunoMissionData"
local MISSION_CLASS_PATH = "/Script/Bruno.BrunoMissionData"
-- The startup sweep latches once it has read more than ten mission definitions;
-- until then the maintenance loop retries it. Capped so it can't keep
-- enumerating objects through level transitions; healthy runs latch within
-- about five attempts.
local LIMIT_ATTEMPT_CAP = 40
local REQUIREMENTS_PROPERTY = "CharacterRequirements"
local AUTO_ASSIGN_PROPERTY = "bAutoAssign"
-- Missions that auto-assign characters beyond the player commander, so six
-- selected operators would add bodies the deployment area wasn't built for.
-- Normally caught by reflection in guards_authored_maximum; this exact-name
-- list is the fallback when the requirements can't be read.
local GUARDED_MISSION_NAMES = {
    "HM_Kabb_010", "HM_Telrea_010", "HM_Telrea_020", "HM_TrickLuco_020",
}

-- Missions whose story characters join through mission logic rather than
-- through CharacterRequirements, so six selected operators become seven or
-- eight units: duplicated named operators, or a save that never finishes
-- writing. Kept at their authored four by exact name: Slug HQ and the
-- AuthoredHero missions, listed so they stay guarded even where reflection
-- can't read their requirements. HM_Jae_020 left the list once it was played
-- at six with saves at seven units finishing (docs/live-tests.md).
local SCRIPTED_COMPANION_MISSION_NAMES = {
    "MM_02_050_SlugHQ",
    "HM_Cly_010", "HM_Cly_020", "HM_Jae_010",
    "HM_Kabb_020", "HM_Luco_010", "HM_Trick_010",
}
-- Missions whose squad the player doesn't choose. The Serolonis Job is the
-- opening tutorial: its squad is set by the game, so six slots add nothing
-- and only risk the scripted roster setup. Kept at the authored four.
local FIXED_SQUAD_MISSION_NAMES = {
    "MM_01_010_SerolonisJob",
}

local limit_reported = false
local data_container = "unknown"
local guard_reflection_hits = 0
local guard_name_hits = 0
local limit_attempts = 0
local limit_abandoned = false
local function guard_summary()
    return "reflection=" .. tostring(guard_reflection_hits)
        .. "/names=" .. tostring(guard_name_hits)
end

-- Reflection first: a mission that auto-assigns a second character must keep
-- its authored maximum. Falls back to the exact name list when struct array
-- elements cannot be read.
local function guards_authored_maximum(object)
    local name = full_name(object)
    for _, list in ipairs({SCRIPTED_COMPANION_MISSION_NAMES, FIXED_SQUAD_MISSION_NAMES}) do
        for _, mission in ipairs(list) do
            if string.find(name, mission, 1, true) then
                guard_name_hits = guard_name_hits + 1
                return true
            end
        end
    end

    local read_ok, requirements = pcall(function()
        return object:GetPropertyValue(REQUIREMENTS_PROPERTY)
    end)
    if read_ok and requirements ~= nil then
        local count_ok, count = pcall(function() return requirements:GetArrayNum() end)
        if count_ok and type(count) == "number" then
            local readable = false
            local auto_assigned = 0
            for index = 1, count do
                local entry_ok, flag = pcall(function()
                    return unwrap(unwrap(requirements[index]):GetPropertyValue(AUTO_ASSIGN_PROPERTY))
                end)
                if entry_ok and type(flag) == "boolean" then
                    readable = true
                    if flag then auto_assigned = auto_assigned + 1 end
                end
            end
            -- An empty array is a definitive "no requirements", not a failure.
            if readable or count == 0 then
                -- Every definition that carries requirements auto-assigns the
                -- player commander. One entry is therefore the commander
                -- alone, who takes an ordinary squad slot. Two or more add a
                -- body the deployment area was not built to hold beside six.
                if auto_assigned > 1 then
                    guard_reflection_hits = guard_reflection_hits + 1
                    return true
                end
                return false
            end
        end
    end

    if name == "" then return false end
    for _, mission in ipairs(GUARDED_MISSION_NAMES) do
        if string.find(name, mission, 1, true) then
            guard_name_hits = guard_name_hits + 1
            return true
        end
    end
    return false
end

-- The write pass on its own, with no latching and no logging, so the startup
-- sweep and the per-screen re-sweep cannot drift apart. Returns nil when the
-- object list could not be read at all, which the callers report differently.
local function sweep_data_limits()
    local objects = FindAllOf(MISSION_CLASS)
    if objects == nil then return nil end

    local counts = {
        matched = 0, writes = 0, at_six = 0,
        already_six = 0, guarded = 0, restored = 0,
    }
    for _, object in pairs(objects) do
        local read_ok, value = pcall(function()
            return unwrap(object:GetPropertyValue(MAXIMUM_PROPERTY))
        end)
        if read_ok and type(value) == "number" then
            counts.matched = counts.matched + 1
            if value == TARGET_SIZE then counts.already_six = counts.already_six + 1 end
            if guards_authored_maximum(object) then
                counts.guarded = counts.guarded + 1
                -- The container may already have raised this one; put it back.
                if value ~= AUTHORED_SIZE then
                    local restore_ok = pcall(function()
                        object[MAXIMUM_PROPERTY] = AUTHORED_SIZE
                    end)
                    if restore_ok then counts.restored = counts.restored + 1 end
                end
            elseif value == AUTHORED_SIZE then
                local write_ok = pcall(function() object[MAXIMUM_PROPERTY] = TARGET_SIZE end)
                if write_ok then counts.writes = counts.writes + 1 end
            end
            local verify_ok, after = pcall(function()
                return unwrap(object:GetPropertyValue(MAXIMUM_PROPERTY))
            end)
            if verify_ok and after == TARGET_SIZE then counts.at_six = counts.at_six + 1 end
        end
    end
    return counts
end

local function apply_data_limits()
    if limit_reported or limit_abandoned then return end

    -- Bounded, so the sweep cannot run for the whole session. Giving up is
    -- logged rather than silent: without a line saying so, a mod that had
    -- stopped trying would be indistinguishable from one that never started.
    limit_attempts = limit_attempts + 1
    if limit_attempts > LIMIT_ATTEMPT_CAP then
        limit_abandoned = true
        log("limits_abandoned=true attempts=" .. tostring(limit_attempts - 1)
            .. " reason=no_data_assets_read")
        return
    end

    local counts = sweep_data_limits()
    if counts == nil then return end

    if not limit_reported and counts.matched > 10 then
        limit_reported = true
        if counts.already_six > 0 and counts.writes == 0 then
            data_container = "loaded"
        elseif counts.already_six > 0 then
            data_container = "partial"
        else
            data_container = "missing"
        end
        log("limits matched=" .. tostring(counts.matched)
            .. " fallback_writes=" .. tostring(counts.writes)
            .. " already_six=" .. tostring(counts.already_six)
            .. " at_six=" .. tostring(counts.at_six)
            .. " guarded=" .. tostring(counts.guarded)
            .. " restored=" .. tostring(counts.restored)
            .. " guard=" .. guard_summary()
            .. " data_container=" .. data_container)
    end
end

-- A mission definition that loads after the startup sweep would stay at four,
-- so the sweep runs again whenever a squad-slot list is built, just before the
-- limit is read. The cap counts consecutive passes that changed nothing; any
-- write or restore resets it.
local RESWEEP_CAP = 60
local resweeps = 0
local idle_resweeps = 0
local resweep_abandoned = false

local function resweep_data_limits()
    if resweep_abandoned then return end
    -- Nothing to re-apply until the first sweep has established a baseline.
    if not limit_reported then return end

    resweeps = resweeps + 1
    if idle_resweeps >= RESWEEP_CAP then
        resweep_abandoned = true
        log("limits_resweep_abandoned=true count=" .. tostring(resweeps - 1)
            .. " idle=" .. tostring(idle_resweeps))
        return
    end

    local counts = sweep_data_limits()
    -- A read that returned no object list at all is idle in the sense the cap
    -- cares about: it cost an enumeration and changed nothing.
    if counts ~= nil and (counts.writes > 0 or counts.restored > 0) then
        idle_resweeps = 0
    else
        idle_resweeps = idle_resweeps + 1
    end
    if counts == nil then return end
    -- Silent when there was nothing left to fix, which is the healthy case
    -- and the common one. A line here means a mission definition loaded after
    -- the startup sweep and would otherwise have been capped at four.
    if counts.writes > 0 or counts.restored > 0 then
        log("limits_resweep=" .. tostring(resweeps)
            .. " late_writes=" .. tostring(counts.writes)
            .. " restored=" .. tostring(counts.restored)
            .. " matched=" .. tostring(counts.matched)
            .. " at_six=" .. tostring(counts.at_six))
    end
end

return {
    -- Every game name this module depends on, for selfcheck.lua.
    game_names = {
        {"class", MISSION_CLASS_PATH},
        {"property", "/Script/BitReactorGame.BitReactorMissionData", MAXIMUM_PROPERTY},
        {"property", "/Script/BitReactorGame.BitReactorMissionData", REQUIREMENTS_PROPERTY},
        {"property", "/Script/BitReactorGame.CharacterRequirement", AUTO_ASSIGN_PROPERTY},
    },
    guard_summary = guard_summary,
    apply_data_limits = apply_data_limits,
    resweep_data_limits = resweep_data_limits,
    -- Read-only view of the flags main.lua reports and waits on.
    state = function()
        return {
            limit_reported = limit_reported,
            limit_abandoned = limit_abandoned,
            data_container = data_container,
        }
    end,
}
