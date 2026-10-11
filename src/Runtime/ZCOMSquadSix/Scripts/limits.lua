-- Mission squad limits: raise each mission definition's MaxSquadSize to six at runtime
-- and keep the missions that deploy a scripted cast at their authored four.
-- Moved verbatim from main.lua (1.1.4); main.lua loads this module.
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
-- apply_data_limits sweeps every mission definition in the process and only latches
-- once it has read more than ten. Until it latches the maintenance loop
-- re-runs that sweep every five seconds for as long as the game is open --
-- which means it can be enumerating UObjects during a level transition,
-- when the engine is tearing an array down and rebuilding it. A crash
-- report showed exactly that: an access violation inside UE4SS.dll reading
-- 0x219, seventeen seconds after the last hook registered, with no limits
-- line yet and a PlayerController being constructed in the same instant.
-- Causality is not proven -- the callstack is ntdll only -- but an
-- unbounded rescan is worth removing on its own merits. Every healthy run
-- on record latches within about five attempts; this is far past that, so
-- it cannot cost a slow machine its fallback writes.
local LIMIT_ATTEMPT_CAP = 40
local REQUIREMENTS_PROPERTY = "CharacterRequirements"
local AUTO_ASSIGN_PROPERTY = "bAutoAssign"
-- Missions that auto-assign a character *in addition to* the player
-- commander. Only those put a body into the deployment area that the squad
-- selection did not choose, so only those keep their authored maximum.
--
-- Read from the cooked mission definitions: of 125, exactly 18 carry
-- CharacterRequirements and every requirement is bAutoAssign. Fourteen of
-- the eighteen require the player commander alone, who occupies an ordinary
-- squad slot and costs no extra body. These four are the entire remainder.
--
-- The 1.0.4 list plus its "/AuthoredHero/" and "HM_" substring fallback
-- matched twenty-one definitions, six of which carry no requirements at all.
-- That, not a game limit, is why free-form-looking missions were still
-- capped at four.
local GUARDED_MISSION_NAMES = {
    "HM_Kabb_010", "HM_Telrea_010", "HM_Telrea_020", "HM_TrickLuco_020",
}

-- Slug HQ injects Tal Rea from mission Blueprint logic rather than declaring
-- her in CharacterRequirements. Its cooked definition therefore looked like
-- an ordinary four-to-six candidate, but a live 1.1.1 report settled the
-- behavior: six selected operators became eight player units at combat start
-- and Tal Rea appeared twice. Keep these exact missions at their authored
-- four even when the empty/missing requirements array is readable.
--
-- The six AuthoredHero entries are the same shape as Slug HQ, established by
-- reading all 125 cooked definitions rather than by guessing:
--
--   * Five HM definitions carry readable CharacterRequirements. Four of the
--     five auto-assign two or three characters -- HM_Kabb_010, HM_Telrea_010,
--     HM_Telrea_020, HM_TrickLuco_020 -- and are already guarded by
--     reflection.
--   * The other six are among the ten definitions UAssetAPI parses as
--     RawExport. They declare nothing at all: no MaxSquadSize, and no
--     requirements either. A hero mission that names no cast in its
--     definition has to receive one from mission logic, which is precisely
--     the route that produced two Tal Reas on Slug HQ.
--
-- HM_Jae_020 was the eleventh, and until 1.1.4 it was deliberately left out:
-- its requirement array reads one auto-assign, which the census recorded as
-- the commander alone. The array under-reports it. Reading the definitions'
-- own cast tags settles it -- every AuthoredHero mission names Hawks plus at
-- least one companion, and in every readable case the tag count equals the
-- requirement count except this one:
--
--     HM_Jae_010   Hawks, JaeMordant   RawExport   guarded
--     HM_Jae_020   Hawks, JaeMordant   reqs 1/1    NOT guarded
--
-- The two Jae missions are identical in shape, down to Facts.States.InRoster
-- .Jae. Jae therefore arrives through mission logic rather than through the
-- requirement array -- the Slug HQ route again. MortisVenunum reported six
-- selected operators becoming seven on cycle 29 when she joins at the start,
-- which hangs the save. With HM_Jae_020 listed the guard covers all eleven
-- AuthoredHero missions, which is what the cast census supports directly:
-- none of them deploys a free six.
--
-- 1.1.0 removed the old "HM_" substring fallback because it over-matched
-- twenty-one definitions, six of which carried no requirements. This is not
-- that fallback: it is six exact names, chosen from the requirement census,
-- and it leaves every non-hero mission and HM_Jae_020 free to reach six.
--
-- Before 1.1.2 these six were left at four by accident -- they are reachable
-- only by the fallback write, and the startup sweep latched before most of
-- them had loaded. Making that write reliable is what exposed them: Tesel and
-- FoxFlight both reported duplicated named operators on 1.1.2, on missions
-- that deploy a fixed authored cast.
local SCRIPTED_COMPANION_MISSION_NAMES = {
    "MM_02_050_SlugHQ",
    "HM_Cly_010", "HM_Cly_020", "HM_Jae_010", "HM_Jae_020",
    "HM_Kabb_020", "HM_Luco_010", "HM_Trick_010",
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
    for _, mission in ipairs(SCRIPTED_COMPANION_MISSION_NAMES) do
        if string.find(name, mission, 1, true) then
            guard_name_hits = guard_name_hits + 1
            return true
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

-- Ten of the 125 mission definitions serialize no MaxSquadSize override at
-- all -- both Cly hero missions, HM_Jae_010, HM_Kabb_020, HM_Luco_010,
-- HM_Trick_010, SK_Serolonis_020, SK_Vandor_015, MM_02_010_CoilReunion and
-- the main-story placeholder. The container cannot reach them: UAssetAPI
-- parses those packages as RawExport, so there is no property node to edit
-- and nothing to inject one beside. Their only route to six is the fallback
-- write, and the startup sweep latches after one pass -- so whether a mission
-- got six came down to whether its DataAsset happened to be resident during
-- that single pass, roughly thirty seconds in. kamilastone's log caught it
-- exactly: fallback_writes=7 against the ten that need one, and Best Served
-- Cold left at four while the same install handed six to everything else.
-- "It works on an old save" is that race, not a per-mission limit.
--
-- So the sweep runs again when the squad-selection viewmodel is constructed,
-- which is the moment the value is about to be read and is necessarily after
-- the chosen mission's definition has loaded. This is not a return to 1.0.x's
-- unbounded rescan: that one enumerated UObjects every five seconds forever,
-- including through level transitions, which is what LIMIT_ATTEMPT_CAP was
-- added to stop. This one is edge-triggered by a UI object being built, and
-- still capped.
--
-- The cap counts *idle* re-sweeps, not constructions. 1.1.2 counted every
-- viewmodel the galaxy map built, so a long campaign session could exhaust
-- sixty of them on screens where there was nothing to fix and then spend the
-- rest of the session unable to raise a late definition or restore a guarded
-- one. What the cap exists to prevent is an enumeration that runs forever
-- while achieving nothing; a pass that wrote or restored a value is by
-- definition not that, so it resets the budget. A healthy install still
-- stops after sixty consecutive quiet passes.
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
