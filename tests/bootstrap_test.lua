-- Loads the Squad Six runtime under a minimal UE4SS stand-in and checks what it registers and
-- logs at startup, including one pass of the mission squad-limit sweep.
--   luajit tests/bootstrap_test.lua <Scripts dir> [--print]
-- With --print, writes the full transcript (log lines and registrations) to stdout instead of
-- asserting, so two builds of the runtime can be compared line for line.
local scripts = assert(arg[1], "usage: bootstrap_test.lua <Scripts dir> [--print]")
local print_only = arg[2] == "--print"

local transcript = {}
local function record(line) transcript[#transcript + 1] = line end

-- Fake UObjects: tables with the methods the runtime calls. Properties are plain fields.
local next_address = 0x1000
local function object(full_name, properties)
    next_address = next_address + 0x10
    local address = next_address
    local self = {properties = properties or {}}
    return setmetatable(self, {
        __index = function(_, key)
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
local function array(items)
    return setmetatable({}, {
        __index = function(_, key)
            if key == "GetArrayNum" then return function() return #items end end
            return items[key]
        end,
    })
end
local function requirement(auto) return object("CharacterRequirement", {bAutoAssign = auto}) end
local function mission(name, max, auto_assigns)
    local requirements = {}
    for index = 1, auto_assigns or 0 do requirements[index] = requirement(true) end
    return object("BrunoMissionData /Game/Game/GameData/MissionData/" .. name .. "." .. name,
        {MaxSquadSize = max, CharacterRequirements = array(requirements)})
end

local missions = {
    mission("SK_Kaller_020", 6, 0),            -- raised by the Core pak
    mission("SK_Vandor_010", 6, 0),
    mission("MM_04_050_ANewOrder", 6, 1),
    mission("SK_Ryloth_035", 4, 0),            -- left at 4: the runtime raises it
    mission("HM_Kabb_010", 4, 2),              -- guarded by reflection
    mission("HM_Jae_020", 6, 1),               -- guarded by name; must be put back to 4
    mission("MM_02_050_SlugHQ", 4, 1),         -- guarded by name
    mission("SK_Dantooine_025", 3, 0),         -- three-operator mission, untouched
    mission("MM_03_010_Bespin", 1, 1),         -- solo mission, untouched
}
for index = 1, 4 do missions[#missions + 1] = mission("SK_Filler_0" .. index, 6, 0) end
local data_assets = {object("DataAsset /Game/Other/NotAMission")}
for _, value in ipairs(missions) do data_assets[#data_assets + 1] = value end

-- UE4SS globals.
local delayed, loops, now = {}, {}, 0
function print(message) record("log " .. tostring(message)) end
function RegisterHook(path, pre, post)
    record("hook " .. path .. (post and " +post" or ""))
    return 1, post and 2 or nil
end
function StaticFindObject(path) return object(path) end
function NotifyOnNewObject(class, callback) record("notify " .. class) end
function RegisterConsoleCommandHandler(name, callback) record("command " .. name) end
function ExecuteWithDelay(ms, callback) delayed[#delayed + 1] = {at = now + ms, callback = callback} end
function ExecuteInGameThread(callback) callback() end
function LoopAsync(ms, callback) loops[#loops + 1] = {every = ms, callback = callback} end
function LoadAsset(path) record("load " .. path) end
function FindFirstOf() return nil end
function FindAllOf(class)
    if class == "DataAsset" then return data_assets end
    return nil
end

local function run_delayed_until(limit)
    while true do
        table.sort(delayed, function(a, b) return a.at < b.at end)
        local nextone = delayed[1]
        if nextone == nil or nextone.at > limit then break end
        table.remove(delayed, 1)
        now = nextone.at
        nextone.callback()
    end
    now = limit
end

dofile(scripts .. "/main.lua")
run_delayed_until(1000)
local loop_runs = 0
for _ = 1, 3 do
    for _, loop in ipairs(loops) do
        loop_runs = loop_runs + 1
        if loop.callback() == true then loop.stopped = true end
    end
end
record("loop_runs " .. loop_runs .. " stopped=" .. tostring(loops[1] and loops[1].stopped == true))
local limits = {}
for _, value in ipairs(missions) do
    limits[#limits + 1] = value:GetFullName():match("%.(.+)$") .. "=" .. tostring(value.properties.MaxSquadSize)
end
record("limits " .. table.concat(limits, ","))

if print_only then
    io.stdout:write(table.concat(transcript, "\n"), "\n")
    os.exit(0)
end

local text = table.concat(transcript, "\n")
local function expect(pattern, why)
    if not text:find(pattern) then
        io.stderr:write("missing: ", why, "\n  pattern: ", pattern, "\n\n", text, "\n")
        os.exit(1)
    end
end
expect("log %[ZCOM_SQUAD_SIX%] loaded version=[%d.]+ target_size=6", "load line")
expect("hook /Game/Game/UI/Strategy/GalaxyMap/BPs/VM_ActivitySlotList%.VM_ActivitySlotList_C:CreateActivitySlotVMs", "slot hook")
expect("hook /Game/Game/UI/AC_HologramManager%.AC_HologramManager_C:ShowLineupHologramActors %+post", "lineup hook")
expect("hook /Script/BitReactorGame%.CombatPreparationArea:TriggerPreCombat", "placement trigger")
expect("command squadsixrescue", "rescue command")
expect("status version=[%d.]+ complete=true data_container=partial", "status line")
expect("SK_Ryloth_035=6", "a mission left at 4 is raised at runtime")
expect("HM_Jae_020=4", "a guarded mission is put back to 4")
expect("HM_Kabb_010=4", "a reflection-guarded mission stays at 4")
expect("SK_Dantooine_025=3", "a three-operator mission is untouched")
expect("MM_03_010_Bespin=1", "a solo mission is untouched")
expect("stopped=true", "the maintenance loop stops once everything is registered")
print = function(...) io.stdout:write(table.concat({...}, " "), "\n") end
print("ok")
