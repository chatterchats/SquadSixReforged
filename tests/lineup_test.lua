-- A six-operator lineup on the squad-selection diorama. The Blueprint places the first four
-- proxies on its authored slots; the runtime must fit all six into that span, scale them by the
-- same ratio, and log one line describing the pool as it was before the pass.
--   luajit tests/lineup_test.lua <Scripts dir>
local scripts = assert(arg[1], "usage: lineup_test.lua <Scripts dir>")
local here = string.match(arg[0], "^(.*[/\\])") or "./"
local mock = dofile(here .. "ue4ss_mock.lua")

mock.install({missions = {mock.mission("SK_Kaller_020", 6, 0)}})
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
io.stdout:write("ok\n")
