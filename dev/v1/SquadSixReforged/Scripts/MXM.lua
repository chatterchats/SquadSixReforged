--[[
    MXM.lua - client library for Mixamoo Mod Config Manager
    ------------------------------------------------------
    Drop this file into your mod's Scripts folder, unmodified, and put your
    schema in <YourMod>/MXM/settings.lua.

        local Settings = require("MXM")

        local step = Settings.Get("rotate_step")

        Settings.OnChange(function(values, changed)
            -- called when the player edits your settings in the menu
        end)

    If Mixamoo Mod Config Manager is not installed, every call still works and returns the
    defaults from your schema. Your mod must never depend on the framework being
    there, and with this library it does not.

    Version 1.0.0 - keep this file as-is so it can be updated in place.
]]

-- Path separator for this platform: "\\" on Windows.
local SEP = package.config:sub(1, 1)


local MXM = {}

local FRAMEWORK_FOLDER = "MixamooModConfigManager"
local POLL_MS = 1000

--------------------------------------------------------------------------------
-- paths
--------------------------------------------------------------------------------

local function ThisFileDir()
    local src = (debug.getinfo(1, "S").source or ""):gsub("^@", "")
    return src:match("^(.*)[/\\][^/\\]+$")
end

local SCRIPT_DIR   = ThisFileDir()
local MOD_DIR      = SCRIPT_DIR and SCRIPT_DIR:match("^(.*)[/\\][^/\\]+$") or nil
local MODS_DIR     = MOD_DIR and MOD_DIR:match("^(.*)[/\\][^/\\]+$") or nil
local SETTINGS_DIR = MOD_DIR and (MOD_DIR .. SEP .. "MXM") or nil

--------------------------------------------------------------------------------
-- state
--------------------------------------------------------------------------------

local schema        = nil
local defaults      = {}
local values        = {}
local actionCounts  = {}
local changeHandlers = {}
local actionHandlers = {}
local started       = false
local lastRaw       = nil

local function Note(msg)
    local id = schema and schema.id or (MOD_DIR and MOD_DIR:match("([^/\\]+)$")) or "?"
    print(string.format("[MXM:%s] %s\n", tostring(id), msg))
end

--------------------------------------------------------------------------------
-- file helpers
--------------------------------------------------------------------------------

local function ReadFile(path)
    if not path then return nil end
    local f = io.open(path, "r")
    if not f then return nil end
    local s = f:read("*a")
    f:close()
    return s
end

local function LoadTable(path)
    if not path then return nil end
    local chunk = loadfile(path)
    if not chunk then return nil end
    local ok, result = pcall(chunk)
    if not ok or type(result) ~= "table" then return nil end
    return result
end

--------------------------------------------------------------------------------
-- registration
--------------------------------------------------------------------------------

-- Announce ourselves to the framework by appending one line to its registry.
-- If the framework is not installed the open fails and we carry on regardless.
local function Register()
    if not (MODS_DIR and SETTINGS_DIR and schema) then return false end
    local regPath = MODS_DIR .. SEP .. FRAMEWORK_FOLDER .. SEP .. "registry.txt"

    local existing = ReadFile(regPath)
    if existing == nil then return false end            -- framework not installed

    local line = schema.id .. "|" .. SETTINGS_DIR
    for l in existing:gmatch("[^\r\n]+") do
        if l == line then return true end               -- already registered
    end

    local f = io.open(regPath, "a")
    if not f then return false end
    -- guard against a previous line that lacked a trailing newline
    if existing:sub(-1) ~= "\n" and #existing > 0 then f:write("\n") end
    f:write(line .. "\n")
    f:close()
    return true
end

--------------------------------------------------------------------------------
-- loading
--------------------------------------------------------------------------------

local function CollectDefaults()
    defaults = {}
    if not (schema and type(schema.settings) == "table") then return end
    for i = 1, #schema.settings do
        local s = schema.settings[i]
        if type(s) == "table" and s.key ~= nil and s.type ~= "header" then
            if s.type == "action" then
                defaults[s.key] = 0
            else
                defaults[s.key] = s.default
            end
        end
    end
end

local function ApplyValues(loaded, announce)
    local changed = {}
    for key, def in pairs(defaults) do
        local v = loaded and loaded[key]
        if v == nil or (def ~= nil and type(v) ~= type(def)) then v = def end
        if values[key] ~= v then
            changed[#changed + 1] = key
            values[key] = v
        end
    end

    -- action counters: a bump means the player pressed the button in the menu
    for key, handler in pairs(actionHandlers) do
        local n = tonumber(values[key]) or 0
        if actionCounts[key] == nil then
            actionCounts[key] = n
        elseif n > actionCounts[key] then
            actionCounts[key] = n
            local ok, err = pcall(handler)
            if not ok then Note("action handler error: " .. tostring(err)) end
        end
    end

    if announce and #changed > 0 then
        for i = 1, #changeHandlers do
            local ok, err = pcall(changeHandlers[i], values, changed)
            if not ok then Note("change handler error: " .. tostring(err)) end
        end
    end
    return changed
end

function MXM.Reload(announce)
    if not SETTINGS_DIR then return end
    local valuesPath = SETTINGS_DIR .. SEP .. "values.lua"
    local raw = ReadFile(valuesPath)
    if raw == lastRaw and announce then return end       -- nothing on disk changed
    lastRaw = raw
    ApplyValues(LoadTable(valuesPath), announce)
end

--------------------------------------------------------------------------------
-- public
--------------------------------------------------------------------------------

function MXM.Init()
    if started then return MXM end
    started = true

    if SETTINGS_DIR then
        schema = LoadTable(SETTINGS_DIR .. SEP .. "settings.lua")
    end
    if schema == nil then
        Note("no MXM/settings.lua found - running on built-in defaults")
        return MXM
    end

    CollectDefaults()
    for k, v in pairs(defaults) do values[k] = v end
    MXM.Reload(false)

    local registered = Register()
    Note(string.format("%d setting(s), %s",
        #schema.settings,
        registered and "registered with the settings menu" or "settings menu not installed, using defaults"))

    -- Pick up edits made in the menu without a restart.
    if type(LoopAsync) == "function" then
        LoopAsync(POLL_MS, function()
            pcall(function() MXM.Reload(true) end)
            return false
        end)
    end

    return MXM
end

--- Current value of a setting, or its default.
function MXM.Get(key, fallback)
    if not started then MXM.Init() end
    local v = values[key]
    if v == nil then v = defaults[key] end
    if v == nil then v = fallback end
    return v
end

--- Every value, as a copy you can keep.
function MXM.All()
    if not started then MXM.Init() end
    local out = {}
    for k, v in pairs(values) do out[k] = v end
    return out
end

--- fn(values, changedKeys) whenever the player edits your settings.
function MXM.OnChange(fn)
    if type(fn) == "function" then changeHandlers[#changeHandlers + 1] = fn end
    if not started then MXM.Init() end
end

--- fn() whenever the player presses an "action" button in your settings.
function MXM.OnAction(key, fn)
    if type(fn) == "function" then actionHandlers[key] = fn end
    if not started then MXM.Init() end
    actionCounts[key] = tonumber(values[key]) or 0
end

--- True when the settings menu is installed and knows about this mod.
function MXM.IsAvailable()
    if not started then MXM.Init() end
    return schema ~= nil and MODS_DIR ~= nil
        and ReadFile(MODS_DIR .. SEP .. FRAMEWORK_FOLDER .. SEP .. "registry.txt") ~= nil
end

return MXM
