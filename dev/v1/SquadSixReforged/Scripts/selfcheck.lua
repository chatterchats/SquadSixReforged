-- Startup self-check: does every game name the runtime depends on still resolve?
--
-- A game update can rename a Blueprint function, rename or re-key a Blueprint variable, or
-- move an asset. Most of the runtime treats a missing name as "nothing to do" and carries on
-- quietly, so without this the first sign of a broken name is a player report. One line per
-- phase answers it from the log instead:
--
--   selfcheck phase=startup ok=20 missing=none unchecked=none
--   selfcheck phase=squad_select ok=2 missing=none unchecked=none
--   selfcheck phase=mission ok=3 missing=BP_CombatPreparationArea_C:MovePlayerUnitsIntoPosition unchecked=none
--
-- `missing` means the check ran and the name is gone. `unchecked` means it couldn't run (a UE4SS
-- reflection call failed), which says nothing about the game either way.
--
-- Names come from each module's `game_names`, built from the same constants the code uses, so
-- the list can't drift from the code. Startup names are checked once main.lua has loaded the two
-- UI assets. Names that only exist later have their own phase (PHASE_TRIGGERS): the squad screen's
-- view model when it first opens, and BP_CombatPreparationArea once a mission level loads.
local Common = require("common")
local log = Common.log
local valid = Common.valid

-- Names that only exist once something loads are checked a few seconds after it appears, retried
-- while Blueprints stream in: the mission's (BP_CombatPreparationArea, with the mission level) and
-- squad selection's (VM_ActivitySlotList, when the squad screen first opens), and the holotable
-- mission panel's (WBP_GalaxyMap_LocationInfoPanel, with the galaxy map).
local PHASE_TRIGGERS = {
    mission = "/Script/BitReactorGame.TacticalGameState",
    squad_select = Common.SLOT_LIST_ASSET .. ".VM_ActivitySlotList_C",
    holotable = "/Game/Game/UI/Strategy/GalaxyMap/Widgets/WBP_GalaxyMap_LocationInfoPanel"
        .. ".WBP_GalaxyMap_LocationInfoPanel_C",
}
local PHASE_DELAYS_MS = {3000, 10000, 30000}

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

local startup, phases = {}, {}
local startup_done, phases_registered = false, false

-- Collect every module's names, split by when they can exist.
local function add(names)
    for _, entry in ipairs(names) do
        if entry.when and PHASE_TRIGGERS[entry.when] then
            phases[entry.when] = phases[entry.when] or {}
            table.insert(phases[entry.when], entry)
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

-- Once per session per phase: its first appearance is enough to see whether its names survived.
local function register_phase(phase, entries)
    local started, reported = false, false
    return pcall(function()
        NotifyOnNewObject(PHASE_TRIGGERS[phase], function()
            if started then return end
            started = true
            for attempt, delay in ipairs(PHASE_DELAYS_MS) do
                ExecuteWithDelay(delay, function()
                    ExecuteInGameThread(function()
                        if reported then return end
                        -- Report once everything resolves, or on the last attempt whatever
                        -- the result, so a genuinely missing name is still logged.
                        local all_found = true
                        for _, entry in ipairs(entries) do
                            if check(entry) ~= "ok" then all_found = false break end
                        end
                        if all_found or attempt == #PHASE_DELAYS_MS then
                            reported = true
                            run(phase, entries)
                        end
                    end)
                end)
            end
        end)
    end)
end

local function register_phase_checks()
    if phases_registered then return end
    phases_registered = true
    for _, phase in ipairs({"holotable", "squad_select", "mission"}) do
        if phases[phase] then register_phase(phase, phases[phase]) end
    end
end

return {
    add = add,
    check_startup = check_startup,
    register_phase_checks = register_phase_checks,
}
