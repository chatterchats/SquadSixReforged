-- The startup warning for other squad-size mods, against a copy of the runtime in a temporary
-- ue4ss/Mods tree: arctco's Squad Six, and ZC Unlocked with its squad extension on, unset (its
-- default is on), and off (squad=0), with and without squad_limit_text=0.
--   luajit tests/conflict_test.lua <Scripts dir>
local scripts = assert(arg[1], "usage: conflict_test.lua <Scripts dir>")
local here = string.match(arg[0], "^(.*[/\\])") or "./"

local root = os.tmpname()
os.remove(root)
local function run(command)
    local status = os.execute(command)   -- LuaJIT returns 0, Lua 5.4 true
    assert(status == 0 or status == true, command)
end
local function quote(path) return "'" .. path:gsub("'", "'\\''") .. "'" end

-- One run: a fresh Mods tree with this mod, the given files beside it, and the log it writes.
local function startup(files)
    run("rm -rf " .. quote(root) .. " && mkdir -p " .. quote(root .. "/Mods/SquadSixReforged"))
    run("cp -r " .. quote(scripts) .. " " .. quote(root .. "/Mods/SquadSixReforged/Scripts"))
    for path, text in pairs(files) do
        run("mkdir -p " .. quote((root .. "/Mods/" .. path):match("^(.*)/")))
        local out = assert(io.open(root .. "/Mods/" .. path, "w"))
        out:write(text)
        out:close()
    end
    local mock = dofile(here .. "ue4ss_mock.lua")
    mock.install({missions = {mock.mission("SK_Kaller_020", 6, 0)}})
    mock.load(root .. "/Mods/SquadSixReforged/Scripts")
    return mock.text()
end
local function fail(message, text)
    io.stderr:write(message, "\n\n", text or "", "\n")
    run("rm -rf " .. quote(root))
    os.exit(1)
end

local text = startup({})
if text:find("WARNING: arctco") or text:find("ZC Unlocked") then fail("a conflict was reported with no other mod", text) end

text = startup({["ZCOMSquadSix/Scripts/main.lua"] = "-- arctco's runtime\n"})
if not text:find("WARNING: arctco's original Squad Six is also installed", 1, true) then fail("Squad Six not reported", text) end

local on = "[Squad]\n# Six operators on missions instead of four.\nsquad=1\nsquad_autofill=0\n\n[Den and holograms]\nsquad=0\n"
text = startup({["ZCUnlocked/dlls/settings.ini"] = on})
if not text:find("WARNING: ZC Unlocked's squad extension is on", 1, true) or not text:find("squad=1)", 1, true) then
    fail("ZC Unlocked with squad=1 not reported", text)
end

text = startup({["ZCUnlocked/dlls/settings.ini"] = "[Squad]\nsquad_autofill=1\n"})
if not text:find("squad=unset, default on", 1, true) then fail("ZC Unlocked with no squad key not reported as on", text) end

-- squad=0 (the menu's Squad row off) is enough: no warning, and the board text is mentioned.
text = startup({["ZCUnlocked/dlls/settings.ini"] = "\239\187\191# ZCUnlocked\n[Squad]\nsquad = 0\nsquad_autofill=1\n"})
if text:find("WARNING: ZC Unlocked", 1, true)
    or not text:find("squad extension off (squad=0). It still trims the squad screen to four models,"
        .. " which this mod shows again, and may show \"4 operators\"", 1, true) then
    fail("ZC Unlocked with squad=0 reported wrongly", text)
end

-- With squad_limit_text=0 as well, and a byte-order mark right before [Squad] (CRLF lines).
text = startup({["ZCUnlocked/dlls/settings.ini"] = "\239\187\191[Squad]\r\nsquad=0\r\nsquad_limit_text=0\r\n\r\n[Den]\r\nsquad=1\r\n"})
if text:find("WARNING: ZC Unlocked", 1, true) or text:find("4 operators", 1, true)
    or not text:find("squad extension off (squad=0)", 1, true) then
    fail("ZC Unlocked with squad=0 and squad_limit_text=0 reported wrongly", text)
end

run("rm -rf " .. quote(root))
io.stdout:write("ok\n")
