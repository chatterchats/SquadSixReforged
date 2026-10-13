-- Loads the Squad Six runtime under the UE4SS stand-in and checks what it registers and logs at
-- startup, including one pass of the mission squad-limit sweep and a clean self-check.
--   luajit tests/bootstrap_test.lua <Scripts dir> [--print]
-- With --print, writes the full transcript (log lines and registrations) to stdout instead of
-- asserting, so two builds of the runtime can be compared line for line.
local scripts = assert(arg[1], "usage: bootstrap_test.lua <Scripts dir> [--print]")
local here = string.match(arg[0], "^(.*[/\\])") or "./"
local mock = dofile(here .. "ue4ss_mock.lua")
local m = mock.mission

mock.install({missions = {
    m("SK_Kaller_020", 6, 0),            -- raised by the Core pak
    m("SK_Vandor_010", 6, 0),
    m("MM_04_050_ANewOrder", 6, 1),
    m("SK_Ryloth_035", 4, 0),            -- left at 4: the runtime raises it
    m("HM_Kabb_010", 4, 2),              -- guarded by reflection
    m("HM_Jae_010", 6, 1),               -- guarded by name; must be put back to 4
    m("HM_Jae_020", 6, 1),               -- no longer guarded: played at six
    m("MM_02_050_SlugHQ", 4, 1),         -- guarded by name
    m("SK_Dantooine_025", 3, 0),         -- three-operator mission, untouched
    m("MM_03_010_Bespin", 1, 1),         -- solo mission, untouched
    m("MM_01_010_SerolonisJob", 6, 1),   -- tutorial with a fixed squad: put back to 4
    m("SK_Filler_01", 6, 0), m("SK_Filler_02", 6, 0), m("SK_Filler_03", 6, 0), m("SK_Filler_04", 6, 0),
}})
mock.load(scripts)
mock.run_until(1000)
local stopped = mock.run_loops(3)
mock.transcript[#mock.transcript + 1] = "loops_stopped=" .. tostring(stopped)
-- The squad screen opens, then a mission starts: each phase of the self-check runs a few seconds
-- after its trigger appears.
mock.notify("/Game/Game/UI/Strategy/GalaxyMap/BPs/VM_ActivitySlotList.VM_ActivitySlotList_C")
mock.notify("/Script/BitReactorGame.TacticalGameState")
mock.run_until(mock.now() + 40000)
local limits = {}
for _, value in ipairs(mock.missions) do
    limits[#limits + 1] = value:GetFullName():match("%.(.+)$") .. "=" .. tostring(value.properties.MaxSquadSize)
end
mock.transcript[#mock.transcript + 1] = "limits " .. table.concat(limits, ",")

if arg[2] == "--print" then
    io.stdout:write(mock.text(), "\n")
    os.exit(0)
end

local expect = mock.expect
expect("log %[SQUAD_SIX_REFORGED%] loaded version=[%d.]+ target_size=6", "load line")
expect("hook /Game/Game/UI/Strategy/GalaxyMap/BPs/VM_ActivitySlotList%.VM_ActivitySlotList_C:CreateActivitySlotVMs", "slot hook")
expect("hook /Game/Game/UI/AC_HologramManager%.AC_HologramManager_C:ShowLineupHologramActors\n", "lineup hook (pre-hook only)")
expect("hook /Script/BitReactorGame%.CombatPreparationArea:TriggerPreCombat", "placement trigger")
expect("command squadsixrescue", "rescue command")
expect("status version=[%d.]+ complete=true data_container=partial", "status line")
expect("selfcheck phase=startup ok=23 missing=none unchecked=none", "every startup name resolves")
expect("selfcheck phase=squad_select ok=2 missing=none unchecked=none", "the squad screen's names resolve")
expect("selfcheck phase=mission ok=3 missing=none unchecked=none", "every mission name resolves")
expect("SK_Ryloth_035=6", "a mission left at 4 is raised at runtime")
expect("HM_Jae_010=4", "a guarded mission is put back to 4")
expect("HM_Jae_020=6", "Rescue Jae Mordant keeps six")
expect("HM_Kabb_010=4", "a reflection-guarded mission stays at 4")
expect("SK_Dantooine_025=3", "a three-operator mission is untouched")
expect("MM_03_010_Bespin=1", "a solo mission is untouched")
expect("MM_01_010_SerolonisJob=4", "the tutorial keeps its authored four")
expect("loops_stopped=true", "the maintenance loop stops once everything is registered")
io.stdout:write("ok\n")
