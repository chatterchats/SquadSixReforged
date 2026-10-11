-- squadsixrescue's peer fallback is all or nothing. Two operators are stuck at the world origin,
-- the four others stand in a tight cluster, and the area authors too few destinations to derive
-- a lane, so the command falls through to placing the two on live peers. The second teleport is
-- accepted by the engine but lands somewhere else: both operators must end up back where they
-- started, not one rolled back and the other left wherever the engine put it.
--   luajit tests/rescue_test.lua <Scripts dir>
local scripts = assert(arg[1], "usage: rescue_test.lua <Scripts dir>")
local here = string.match(arg[0], "^(.*[/\\])") or "./"
local mock = dofile(here .. "ue4ss_mock.lua")

mock.install({missions = {mock.mission("SK_Kaller_020", 6, 0)}})
mock.load(scripts)
mock.run_until(1000)
mock.run_loops(3)

local actor = mock.actor
local units = {
    actor("Operator1", {X = 5000, Y = 5000, Z = 100}),
    actor("Operator2", {X = 5200, Y = 5000, Z = 100}),
    actor("Operator3", {X = 5400, Y = 5000, Z = 100}),
    actor("Operator4", {X = 5000, Y = 5300, Z = 100}),
    actor("Stuck5", {X = 0, Y = 0, Z = 261}),
    actor("Stuck6", {X = 40, Y = -30, Z = 261}),
}
-- The engine accepts this operator's next teleport but puts it somewhere else entirely.
-- Later teleports (the rollback) behave.
units[6].move = function()
    units[6].move = nil
    return {X = 9000, Y = 9000, Z = 0}, true
end

local area = mock.object("BP_CombatPreparationArea_C /Game/Maps/Test.Test:PersistentLevel.Area", {
    PlayerDestinations = mock.array({
        actor("Destination1", {X = 5000, Y = 5000, Z = 0}),
        actor("Destination2", {X = 5400, Y = 5000, Z = 0}),
    }),
})
mock.first_of["TacticalGameState"] = mock.object("TacticalGameState", {
    PlayerSquad = mock.object("BitReactorGameSquad", {SquadMembers = mock.array(units)}),
})

-- Combat preparation opens the deployment; then the player runs the command.
mock.hooks["/Script/BitReactorGame.CombatPreparationArea:TriggerPreCombat"].pre(area)
mock.commands["squadsixrescue"]()

mock.expect("manual_rescue=refused reason=incomplete_snapshot staged=4 fallback=teleport_refused",
    "the peer fallback refuses after the bad teleport")
local function at(unit, x, y, z)
    local p = unit.at
    if p.X ~= x or p.Y ~= y or p.Z ~= z then
        io.stderr:write(string.format("%s is at %g/%g/%g, expected %g/%g/%g\n%s\n",
            unit:GetFullName(), p.X, p.Y, p.Z, x, y, z, mock.text()))
        os.exit(1)
    end
end
at(units[5], 0, 0, 261)     -- moved onto a peer, then rolled back
at(units[6], 40, -30, 261)  -- the teleport that went wrong is rolled back too
io.stdout:write("ok\n")
