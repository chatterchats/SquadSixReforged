-- Squad Six test limits: a development tool, never shipped (it lives outside src/).
--
-- Sets one mission's squad limit for a test, e.g. a three-operator mission at five, without
-- touching the shipped mod or its pak. Nothing happens until it's asked from the UE4SS console:
--   squadsixlimit                       list loaded missions whose limit isn't six
--   squadsixlimit <mission> <size>      set that mission's limit (1-6) for this session
-- <mission> is matched against the definition's name, e.g. MM_05_010_UmbaraRescue. A definition
-- that loads again later (after garbage collection) gets the override re-applied. The mission's
-- galaxy-map view model keeps its own copy of the limit, so that's set too. Nothing is
-- saved: restart the game, or set the size back, to undo it.
local TAG = "[SQUADSIX_TESTLIMITS]"
local MISSION_CLASS = "BrunoMissionData"
local MISSION_CLASS_PATH = "/Script/Bruno.BrunoMissionData"
-- Squad select reads the limit from the mission's view model, which copies it from the
-- definition when the mission reaches the galaxy map; both are set.
local VIEW_MODEL_CLASS = "BrunoMissionViewModel"
local MAXIMUM, MINIMUM = "MaxSquadSize", "MinSquadSize"
local LARGEST = 6         -- squad select has six slots with Squad Six Reforged
local REAPPLY_DELAY_MS = 1000  -- a new definition's properties load after it's constructed

local overrides = {}      -- mission name -> size

local function log(message, output)
    print(TAG .. " " .. message)
    if output ~= nil then pcall(function() output:Log(TAG .. " " .. message) end) end
end

local function unwrap(value)
    if type(value) ~= "userdata" then return value end
    local ok, inner = pcall(function() return value:get() end)
    if ok and inner ~= nil then return inner end
    return value
end

local function name_of(object)
    local ok, name = pcall(function() return object:GetFullName() end)
    return ok and tostring(name) or ""
end

local function read(object, property)
    local ok, value = pcall(function() return unwrap(object:GetPropertyValue(property)) end)
    if ok and type(value) == "number" then return value end
    return nil
end

local function is_default_object(name)
    return name:find("Default__", 1, true) ~= nil
end

local function missions()
    local found = {}
    for _, object in pairs(FindAllOf(MISSION_CLASS) or {}) do
        local name = name_of(object)
        if name ~= "" and not is_default_object(name) then found[#found + 1] = {object, name} end
    end
    return found
end

-- Returns the limit before and after.
local function apply(object, size)
    local before = read(object, MAXIMUM)
    pcall(function() object[MAXIMUM] = size end)
    return before, read(object, MAXIMUM)
end

-- The view models of the mission, matched by asset name (FPrimaryAssetId.PrimaryAssetName).
local function view_models(mission)
    local found = {}
    for _, object in pairs(FindAllOf(VIEW_MODEL_CLASS) or {}) do
        local ok, asset = pcall(function()
            return unwrap(object:GetPropertyValue("AssetId")).PrimaryAssetName:ToString()
        end)
        if ok and asset == mission then found[#found + 1] = object end
    end
    return found
end

local function list(output)
    local shown = 0
    for _, entry in ipairs(missions()) do
        local maximum = read(entry[1], MAXIMUM)
        if maximum ~= nil and maximum ~= LARGEST then
            log(string.format("max=%d min=%s %s", maximum, tostring(read(entry[1], MINIMUM)), entry[2]), output)
            shown = shown + 1
        end
    end
    log(string.format("%d loaded missions below six", shown), output)
end

local function set(pattern, size, output)
    local hits = {}
    for _, entry in ipairs(missions()) do
        if entry[2]:find(pattern, 1, true) then hits[#hits + 1] = entry end
    end
    if #hits ~= 1 then
        log(string.format("'%s' matches %d loaded missions; nothing changed%s", pattern, #hits,
            #hits == 0 and " (is it on the galaxy map yet?)" or ""), output)
        for _, entry in ipairs(hits) do log("  " .. entry[2], output) end
        return
    end
    local object, name = hits[1][1], hits[1][2]
    local minimum = read(object, MINIMUM)
    if minimum ~= nil and size < minimum then
        log(string.format("%s needs at least %d; nothing changed", name, minimum), output)
        return
    end
    local before, after = apply(object, size)
    overrides[pattern] = size
    log(string.format("set max %s -> %s (min=%s) %s", tostring(before), tostring(after),
        tostring(minimum), name), output)
    local mission = name:match("%.([^.]+)$") or pattern
    for _, view_model in ipairs(view_models(mission)) do
        local vm_before, vm_after = apply(view_model, size)
        log(string.format("  view model max %s -> %s %s", tostring(vm_before), tostring(vm_after),
            name_of(view_model)), output)
    end
end

RegisterConsoleCommandHandler("squadsixlimit", function(_, parameters, output)
    if parameters == nil or #parameters == 0 then
        list(output)
        return true
    end
    local size = tonumber(parameters[2])
    if #parameters ~= 2 or size == nil or size ~= math.floor(size) or size < 1 or size > LARGEST then
        log("usage: squadsixlimit [<mission> <size 1-" .. LARGEST .. ">]", output)
        return true
    end
    set(parameters[1], size, output)
    return true
end)

NotifyOnNewObject(MISSION_CLASS_PATH, function(created)
    if next(overrides) == nil then return end
    ExecuteWithDelay(REAPPLY_DELAY_MS, function()
        ExecuteInGameThread(function()
            local name = name_of(created)
            if name == "" or is_default_object(name) then return end
            for pattern, size in pairs(overrides) do
                if name:find(pattern, 1, true) then
                    local before, after = apply(created, size)
                    log(string.format("reapplied max %s -> %s %s", tostring(before), tostring(after), name))
                end
            end
        end)
    end)
end)

log("loaded; type squadsixlimit in the UE4SS console")
