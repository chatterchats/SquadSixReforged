-- A minimal UE4SS stand-in for loading the Squad Six runtime outside the game.
--
--   local mock = dofile("tests/ue4ss_mock.lua")
--   mock.install({missing = {[path] = true}, properties = {[owner] = {...}}})
--   mock.load(scripts_dir)      -- runs main.lua
--   mock.run_until(ms)          -- fires delayed actions due by then (simulated time)
--   mock.notify(class_path)     -- constructs an object of that class (NotifyOnNewObject)
--   mock.hooks[path].pre(...)   -- calls a registered hook; mock.commands[name]() a console command
--   mock.actor(name, location)  -- an actor that can be moved; mock.first_of[class] = object
--   mock.transcript             -- log lines and registrations, in order
local mock = {transcript = {}, missions = {}, hooks = {}, commands = {}, first_of = {}}

local function record(line) mock.transcript[#mock.transcript + 1] = line end

-- Fake UObjects: tables with the methods the runtime calls; properties are plain fields.
local next_address = 0x1000
local function object(full_name, properties, methods)
    next_address = next_address + 0x10
    local address = next_address
    local self = {properties = properties or {}}
    return setmetatable(self, {
        __index = function(_, key)
            if methods and methods[key] then return methods[key] end
            if key == "IsValid" then return function() return true end end
            if key == "GetFullName" then return function() return full_name end end
            if key == "GetAddress" then return function() return address end end
            if key == "GetPropertyValue" then
                return function(_, name)
                    local value = self.properties[name]
                    if value == nil then error("no property " .. name) end
                    return value
                end
            end
            return self.properties[key]
        end,
        __newindex = function(_, key, value) self.properties[key] = value end,
    })
end
mock.object = object

local invalid = setmetatable({}, {__index = function(_, key)
    if key == "IsValid" then return function() return false end end
    error("invalid object accessed: " .. key)
end})

function mock.array(items)
    return setmetatable({}, {
        __index = function(_, key)
            if key == "GetArrayNum" then return function() return #items end end
            return items[key]
        end,
    })
end

function mock.mission(name, max, auto_assigns)
    local requirements = {}
    for index = 1, auto_assigns or 0 do
        requirements[index] = object("CharacterRequirement", {bAutoAssign = true})
    end
    return object("BrunoMissionData /Game/Game/GameData/MissionData/" .. name .. "." .. name,
        {MaxSquadSize = max, CharacterRequirements = mock.array(requirements)})
end

-- The properties the runtime reads, as the game declares them (note CharacterVM's case).
mock.game_properties = {
    ["/Script/BitReactorGame.BitReactorMissionData"] = {"MaxSquadSize", "CharacterRequirements"},
    ["/Script/BitReactorGame.CharacterRequirement"] = {"bAutoAssign"},
    ["/Game/Game/UI/AC_HologramManager.AC_HologramManager_C"] = {"Customization Proxy Actors"},
    ["/Game/Game/UI/Strategy/GalaxyMap/BPs/BrunoActivitySlotData.BrunoActivitySlotData"] =
        {"index_7_31948AF04E3D570FC0E4BBBEA45BB788", "isRequired_1_4623050849AF7EE2701092888815BE0F"},
    ["/Game/Game/UI/Strategy/GalaxyMap/BPs/VM_ActivitySlot.VM_ActivitySlot_C"] = {"Index", "CharacterVM"},
    ["/Game/Game/UI/Strategy/GalaxyMap/BPs/VM_ActivitySlotList.VM_ActivitySlotList_C"] = {"ActivitySlots"},
    ["/Script/UMG.DynamicEntryBoxBase"] = {"EntrySpacing"},
    ["/Script/BitReactorGame.CombatPreparationArea"] = {"PlayerDestinations"},
    ["/Script/BitReactorGame.TacticalPoint"] = {"OwningTeam"},
    ["/Script/BitReactorGame.BitReactorGameSquad"] = {"SquadMembers"},
    ["/Script/BitReactorGame.TacticalGameState"] = {"PlayerSquad"},
}

-- An actor with a location. `move` decides where a teleport lands and what it returns; by
-- default the actor goes exactly where it was asked to and the call reports success.
function mock.actor(name, location)
    local self
    self = object(name, {}, {
        K2_GetActorLocation = function() return {X = self.at.X, Y = self.at.Y, Z = self.at.Z} end,
        K2_GetActorRotation = function() return {Pitch = 0, Yaw = 0, Roll = 0} end,
        K2_SetActorLocationAndRotation = function(_, target)
            local landed, result = target, true
            if self.move then landed, result = self.move(target) end
            self.at = {X = landed.X, Y = landed.Y, Z = landed.Z}
            return result
        end,
    })
    rawset(self, "at", {X = location.X, Y = location.Y, Z = location.Z})
    return self
end

local delayed, loops, notifications, now = {}, {}, {}, 0

function mock.install(options)
    options = options or {}
    local missing = options.missing or {}
    local properties = options.properties or mock.game_properties
    for _, value in ipairs(options.missions or {}) do
        mock.missions[#mock.missions + 1] = value
    end

    local function struct(path)
        return object(path, {}, {
            ForEachProperty = function(_, callback)
                for _, name in ipairs(properties[path] or {}) do
                    local fname = {ToString = function() return name end}
                    if callback({GetFName = function() return fname end}) == true then return end
                end
            end,
            GetSuperStruct = function() return nil end,
        })
    end

    print = function(message) record("log " .. tostring(message)) end
    RegisterHook = function(path, pre, post)
        record("hook " .. path .. (post and " +post" or ""))
        mock.hooks[path] = {pre = pre, post = post}
        return 1, post and 2 or nil
    end
    StaticFindObject = function(path)
        if missing[path] then return invalid end
        return struct(path)
    end
    NotifyOnNewObject = function(class, callback)
        record("notify " .. class)
        notifications[class] = notifications[class] or {}
        table.insert(notifications[class], callback)
    end
    RegisterConsoleCommandHandler = function(name, callback)
        record("command " .. name)
        mock.commands[name] = callback
    end
    ExecuteWithDelay = function(ms, callback) delayed[#delayed + 1] = {at = now + ms, callback = callback} end
    ExecuteInGameThread = function(callback) callback() end
    LoopAsync = function(ms, callback) loops[#loops + 1] = {every = ms, callback = callback} end
    LoadAsset = function(path) record("load " .. path) end
    FindFirstOf = function(class) return mock.first_of[class] end
    FindAllOf = function(class)
        if class == "BrunoMissionData" then return mock.missions end
        return nil
    end
end

function mock.load(scripts) dofile(scripts .. "/main.lua") end

function mock.run_until(limit)
    while true do
        table.sort(delayed, function(a, b) return a.at < b.at end)
        local due = delayed[1]
        if due == nil or due.at > limit then break end
        table.remove(delayed, 1)
        now = due.at
        due.callback()
    end
    now = limit
end

-- Runs each maintenance loop up to `times` times; returns whether every loop stopped.
function mock.run_loops(times)
    local stopped = true
    for _, loop in ipairs(loops) do
        for _ = 1, times do
            if loop.stopped then break end
            if loop.callback() == true then loop.stopped = true end
        end
        stopped = stopped and loop.stopped == true
    end
    return stopped
end

function mock.notify(class)
    for _, callback in ipairs(notifications[class] or {}) do
        callback(object(class))
    end
end

function mock.now() return now end

function mock.text() return table.concat(mock.transcript, "\n") end

-- Fails the test with the transcript when `pattern` isn't in it.
function mock.expect(pattern, why)
    if not mock.text():find(pattern) then
        io.stderr:write("missing: ", why, "\n  pattern: ", pattern, "\n\n", mock.text(), "\n")
        os.exit(1)
    end
end

return mock
