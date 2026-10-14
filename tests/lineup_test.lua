-- A six-operator lineup on the squad-selection diorama. The Blueprint places the first four
-- proxies on its authored slots; the runtime must fit all six into that span, scale them by the
-- same ratio, and log one line describing the pool as it was before the pass. When another mod
-- hides the fifth or sixth model afterwards (ZC Unlocked's lineup trim), it is shown again while
-- the squad screen is open, and not once the screen has closed; a four-slot lineup's hidden extra
-- models stay hidden.
--   luajit tests/lineup_test.lua <Scripts dir>
local scripts = assert(arg[1], "usage: lineup_test.lua <Scripts dir>")
local here = string.match(arg[0], "^(.*[/\\])") or "./"
local mock = dofile(here .. "ue4ss_mock.lua")

mock.install({missions = {mock.mission("SK_Kaller_020", 6, 0)}})
-- The squad screen's slot box, for the keep-shown watch.
local screen_open = true
local slot_box = mock.object("MDVMDynamicEntryBox /Engine/Transient.WBP_Menu_MissionSquadSelect_C_0.WidgetTree.CharacterSlots",
    {}, {IsVisible = function() return screen_open end})
local find_all = FindAllOf
FindAllOf = function(class)
    if class == "MDVMDynamicEntryBox" then return {slot_box} end
    return find_all(class)
end
mock.load(scripts)
mock.run_until(1000)
mock.run_loops(3)

-- Four authored slots 40 uu apart along Y; the two overflow proxies were never placed.
local proxies = {}
for index, y in ipairs({-60, -20, 20, 60}) do
    proxies[index] = mock.actor("Proxy" .. index, {X = 0, Y = y, Z = 0})
end
proxies[5] = mock.actor("Proxy5", {X = 0, Y = 0, Z = 0})
proxies[6] = mock.actor("Proxy6", {X = 0, Y = 0, Z = 0})
local manager = mock.object("AC_HologramManager_C /Game/Maps/Hub.Hub:PersistentLevel.Manager",
    {["Customization Proxy Actors"] = mock.array(proxies)})
local slots = {}
for index = 1, 6 do
    slots[index] = mock.object("VM_ActivitySlot_C Slot" .. index,
        {characterVM = mock.object("Character" .. index)})
end

local show = "/Game/Game/UI/AC_HologramManager.AC_HologramManager_C:ShowLineupHologramActors"
mock.hooks[show].pre(manager, mock.array(slots), false)
mock.run_until(mock.now() + 100)

mock.expect("lineup source=pre used=6 layout=applied applied=true fit=0%.60 hidden_by_mod=0 proxies=6"
    .. " valid_proxies=6 hidden_proxies=0"
    .. " before_positions=0/%-60/0,0/%-20/0,0/20/0,0/60/0,0/0/0,0/0/0"
    .. " before_scales=1%.000/1%.000/1%.000,1%.000/1%.000/1%.000,1%.000/1%.000/1%.000,"
    .. "1%.000/1%.000/1%.000,1%.000/1%.000/1%.000,1%.000/1%.000/1%.000",
    "the pre pass lays out six and describes the pool as it was")
mock.expect("lineup source=deferred used=6 layout=applied", "the deferred pass reapplies the layout")

-- Six models across the same 120 uu span: a 24 uu step, every model scaled by 3/5.
for index, y in ipairs({-60, -36, -12, 12, 36, 60}) do
    local p, s = proxies[index].at, proxies[index].scale
    if math.abs(p.Y - y) > 1e-6 or p.X ~= 0 or math.abs(s.X - 0.6) > 1e-6 then
        io.stderr:write(string.format("Proxy%d at Y=%g scale %g, expected Y=%g scale 0.6\n%s\n",
            index, p.Y, s.X, y, mock.text()))
        os.exit(1)
    end
end

local function fail(message)
    io.stderr:write(message, "\n", mock.text(), "\n")
    os.exit(1)
end
-- Another mod hides the extra two after the pass; the watch shows them again.
proxies[5].bHidden, proxies[6].bHidden = true, true
mock.run_loops(2)
if proxies[5].bHidden or proxies[6].bHidden then fail("the extra models hidden by something else weren't shown again") end
mock.expect("lineup_reshown index=5 after_ms=%d+", "showing a model again is logged")
-- The screen closes: a model hidden now stays hidden while it's closed.
screen_open = false
proxies[6].bHidden = true
mock.run_loops(2)
if not proxies[6].bHidden then fail("a model was shown again after the squad screen closed") end
-- The first pass runs before the screen is shown: once it is, the watch shows the model.
screen_open = true
mock.run_loops(1)
if proxies[6].bHidden then fail("the watch stopped while the screen wasn't visible yet") end

-- A four-slot lineup: this mod hides the extra two itself, and nothing shows them again.
screen_open = true
mock.hooks[show].pre(manager, mock.array({slots[1], slots[2], slots[3], slots[4]}), false)
mock.run_until(mock.now() + 100)
mock.run_loops(4)
if not proxies[5].bHidden or not proxies[6].bHidden then fail("a four-slot lineup's extra models were shown") end
io.stdout:write("ok\n")
