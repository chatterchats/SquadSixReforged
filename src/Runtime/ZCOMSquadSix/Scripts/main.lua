local VERSION = "1.1.4"
local TARGET_SIZE = 6
local SLOT_LIST_ASSET = "/Game/Game/UI/Strategy/GalaxyMap/BPs/VM_ActivitySlotList"
local SLOT_LIST_CLASS = SLOT_LIST_ASSET .. ".VM_ActivitySlotList_C"
local HOLOGRAM_MANAGER_ASSET = "/Game/Game/UI/AC_HologramManager"
local HOLOGRAM_MANAGER_CLASS = HOLOGRAM_MANAGER_ASSET .. ".AC_HologramManager_C"
local SLOT_LIST_FUNCTION = "/Game/Game/UI/Strategy/GalaxyMap/BPs/VM_ActivitySlotList.VM_ActivitySlotList_C:CreateActivitySlotVMs"
local GENERATE_PROXIES_FUNCTION = "/Game/Game/UI/AC_HologramManager.AC_HologramManager_C:GenerateCustomizationProxies"
local SHOW_LINEUP_FUNCTION = "/Game/Game/UI/AC_HologramManager.AC_HologramManager_C:ShowLineupHologramActors"
local PLACEMENT_TRIGGER_FUNCTIONS = {
    "/Script/BitReactorGame.CombatPreparationArea:TriggerPreCombat",
    "/Script/BitReactorGame.CombatPreparationArea:TriggerCombatInit",
}
-- The relocation itself. ACombatPreparationArea::MovePlayerUnitsIntoPosition
-- is the native function that reads PlayerDestinations and moves the squad, so
-- its pre-hook is the exact instant before the squad is disturbed and its
-- post-hook the exact instant after. That beats guessing from a delay ladder.
-- BP_CombatPreparationArea overrides it, so the UFunction that actually runs
-- belongs to the Blueprint class, not to the native base. Hooking the base
-- registered cleanly and never fired once: a verified run logged
-- relocation_hook=true with relocation_pre=false. The BP asset carries both
-- names; hook whatever resolves and let the log say which one ran.
local MOVE_UNITS_FUNCTIONS = {
    "/Game/Game/Core/Blueprints/BP_CombatPreparationArea.BP_CombatPreparationArea_C:MovePlayerUnitsIntoPosition",
    "/Game/Game/Core/Blueprints/BP_CombatPreparationArea.BP_CombatPreparationArea_C:ExternalMovePlayerUnitsIntoPosition",
    "/Script/BitReactorGame.CombatPreparationArea:MovePlayerUnitsIntoPosition",
}
local PREPARATION_AREA_CLASS_PATH =
    "/Game/Game/Core/Blueprints/BP_CombatPreparationArea.BP_CombatPreparationArea_C"
local LINKED_AREA_FUNCTION = "GetLinkedTacticalArea"
local INSIDE_AREA_FUNCTION = "IsActorInsideTacticalArea"
local SLOT_BOX_CLASS = "MDVMDynamicEntryBox"
local SLOT_BOX_CLASS_PATH = "/Script/MDViewModel.MDVMDynamicEntryBox"
local MANAGER_CLASS = "AC_HologramManager_C"
local PROXY_ARRAY_PROPERTY = "Customization Proxy Actors"
local MAXIMUM_PROPERTY = "Max" .. "Squad" .. "Size"
local SLOT_INDEX_PROPERTY = "index_7_31948AF04E3D570FC0E4BBBEA45BB788"
local AUTHORED_SIZE = 4
-- The lineup diorama has four authored attachment slots.
local AUTHORED_SLOTS = 4
-- A capture is only believable when consecutive authored slots are really
-- apart. Before the Blueprint places them the pool sits at the origin, or one
-- actor holds a stale transform while the rest are still at 0/0/0; 1.0.4
-- cached exactly that and scattered the models. This is the only condition
-- the reports actually evidence, so it is the only one enforced.
local MIN_SLOT_SEPARATION_SQ = 100.0
-- A menu world holds plenty of cameras. The census exists to identify the
-- diorama rig, not to inventory the level, so it stops well short of a line
-- no one can read.
local CAMERA_CENSUS_LIMIT = 8
-- apply_data_limits sweeps every DataAsset in the process and only latches
-- once it has read more than ten. Until it latches the maintenance loop
-- re-runs that sweep every five seconds for as long as the game is open --
-- which means it can be enumerating UObjects during a level transition,
-- when the engine is tearing an array down and rebuilding it. A crash
-- report showed exactly that: an access violation inside UE4SS.dll reading
-- 0x219, seventeen seconds after the last hook registered, with no limits
-- line yet and a PlayerController being constructed in the same instant.
-- Causality is not proven -- the callstack is ntdll only -- but an
-- unbounded rescan is worth removing on its own merits. Every healthy run
-- on record latches within about five attempts; this is far past that, so
-- it cannot cost a slow machine its fallback writes.
local LIMIT_ATTEMPT_CAP = 40
local REQUIREMENTS_PROPERTY = "CharacterRequirements"
local AUTO_ASSIGN_PROPERTY = "bAutoAssign"
local SQUAD_CLASS = "BitReactorGameSquad"
local SQUAD_MEMBERS_PROPERTY = "SquadMembers"
local PREPARATION_CLASS = "BP_CombatPreparationArea_C"
local DESTINATIONS_PROPERTY = "PlayerDestinations"
local ACTIVITY_CHARACTER_PROPERTY = "characterVM"
local TACTICAL_GAME_STATE_CLASS = "TacticalGameState"
local PLAYER_SQUAD_PROPERTY = "PlayerSquad"
local PLAYER_TEAM_PROPERTY = "OwningTeam"
-- One tactical step. 1.0.4 used 25 uu, which accepted a second destination
-- close enough to the first that two operators were relocated on top of
-- each other.
local MIN_DESTINATION_SEPARATION_SQ = 10000.0
-- How far from an authored destination an operator can stand and still be
-- read as part of *this* deployment. This is a membership question, not a
-- judgement about the position: the operators worth rescuing are exactly the
-- ones standing somewhere wrong, so this stays generous.
local MAX_DESTINATION_DISTANCE_SQ = 4000000.0
-- Whether a position is somewhere an operator can usefully be, though, is a
-- different question, and until 1.0.9 the same 2000 uu radius answered both.
-- Deployment lanes are far smaller than that: across the 89 preparation areas
-- in the game the authored destinations span a median of 1064 uu and 86 of
-- the 89 span less than 2000. So a staged position most of a lane's width
-- outside the lane passed as "near the deployment area" and was promoted to
-- a permanent destination. SK_Serolonis_020 is the reported case -- one
-- operator staged 906 uu outside the authored shape, in a rock, and the mod
-- made that its destination.
--
-- The area itself carries the answer. Its PlayerDestinations are the points
-- the map author marked for player deployment, so their convex hull is the
-- deployment lane, and a position is acceptable when it lies inside that hull
-- or within one tactical step of its edge.
local DEPLOYMENT_EDGE_TOLERANCE = 100.0
-- Two operators closer together than one tactical step are on the same tile.
local MIN_UNIT_SEPARATION_SQ = 10000.0
-- An actor sitting this close to the world origin was never placed. Every
-- 1.0.5 report of an operator that could not move at all logged one, and
-- SK_Kaller_020 authors no destination anywhere near 0/0.
local ORIGIN_RADIUS_SQ = 10000.0
-- Staged positions are only believable before the game relocates the squad.
-- The relocation lands somewhere between the trigger and eight seconds after
-- it, so only the rungs inside this window contribute a snapshot.
local STAGING_WINDOW_MS = 500
-- Two automatic attempts per operator. If the game moves it back a third time,
-- fighting it in a loop would be worse than the bug. An explicit console
-- invocation bypasses this budget because the player confirms the failure.
local MAX_REPAIRS_PER_UNIT = 2
-- Enough lines for a report to show the whole ladder without flooding one
-- deployment. The count is reset by begin_deployment so an early encounter
-- cannot make every later encounter in the same session silent.
-- Raised from four in 1.0.9. A relocation can now schedule more than one
-- ladder, and four was already being spent inside a single mission: an
-- attached MM_06_090 log used all four on its first two encounters and every
-- fight after that was silent, which is the opposite of what this cap is for.
local MAX_REPAIR_REPORTS = 8
-- Repairs run this long after the relocation and no longer. The window has to
-- cover a relocation that settles slowly, and has to close before the player
-- has control -- two operators standing a tile apart in normal play look
-- exactly like the pair this pass exists to separate.
local REPAIR_DELAYS_MS = {100, 500, 2000}
-- Prorp's 1.0.9 Serolonis log was clean through post2000, then showed an
-- operator at 0/0/-5513 in the eight-second final census without another
-- relocation firing. These later checks cover that proven gap, but use only
-- hard-invalid signatures so they cannot pull back an operator who has begun
-- moving normally after control is returned.
local WATCHDOG_DELAYS_MS = {3500, 5000, 7000, 7500}
-- The manual peer fallback exists only for Sambuco's literal spawn-bad
-- shape: exactly two hard-invalid outliers, far from all remaining distinct
-- operators forming one compact live cluster. It refuses looser guesses.
local MANUAL_PEER_CLUSTER_RADIUS_SQ = 1000000.0
local MANUAL_PEER_OUTLIER_DISTANCE_SQ = 4000000.0
-- BP_CombatPreparationArea carries two names for the relocation, and both
-- hooks fire for a single event within a few milliseconds of each other. A
-- second, genuinely separate relocation is seconds later: on SK_Kaller_025 the
-- squad is correct at the last repair pass, 2 s after the first relocation,
-- and two operators are on the rocks and at the world origin by 5 s after it.
-- Coalescing on time rather than on the area tells those two cases apart,
-- where 1.0.8's one-ladder-per-area rule could not.
local RELOCATION_COALESCE_MS = 250
-- Each ladder is bounded, and MAX_REPAIRS_PER_UNIT still caps how often its
-- automatic passes can move one operator, so this limits pathological firing.
local MAX_RELOCATION_LADDERS = 4

-- Cold Metal (SK_Kaller_020_Gameplay_Alt) authors its skirmish-intro capsule
-- inside the broad linked tactical volume but 513 uu outside the four-point
-- deployment quadrilateral. One of its six initial spawn transforms can
-- instead put Hawks at 0/0 on the snowy hill, outside that tactical volume.
-- The other overflow operator has been observed at 45/-1607/96, 113 uu away,
-- so this is also a distinct tactical step.
--
-- Match the authored PlayerDestinations rather than a localized mission name
-- or a brittle UObject path. This keeps the exception pinned to the one map
-- whose cooked geometry proves the replacement location is intentional.
local PLACEMENT_PROFILE_MATCH_RADIUS_SQ = 2500.0
local PLACEMENT_PROFILE_MEMBER_RADIUS_SQ = 40000.0
-- The geometry of a derived rescue point, grouped into one table the way
-- REPAIR is. It was four separate locals until 1.1.4, when the file turned
-- out to sit exactly on Lua's 200 top-level local limit and the two heights
-- below would not fit beside them.
local RESCUE = {}
-- K2_SetActorLocationAndRotation can settle a few units away from the exact
-- request. Ten uu is enough to treat that as the same rescue point while
-- remaining below the smallest derived point's 29.8 uu interior clearance.
-- Keep this separate from MIN_UNIT_SEPARATION_SQ: one tactical tile is wider
-- than the inset and would accept a point that is still outside the lane.
RESCUE.settled_radius_sq = 100.0
-- The midpoint of an authored edge is *on* the deployment shape's boundary,
-- not inside it, and a boundary point is exactly where a strict inside test
-- or a tile snap can round the wrong way -- which is the failure being
-- repaired. Every derived rescue point is therefore pulled this far towards
-- the centroid of the four authored points. On the shortest edge any profile
-- uses, Kaller 025's 360 uu left edge, that is a 34 uu step inwards, which
-- still leaves it 174 uu from the nearest authored destination: comfortably
-- past MIN_DESTINATION_SEPARATION_SQ and nowhere near the next operator.
-- A rescue the map itself authors carries its own evidence and is used as
-- written, so this applies only where inset_rescues says so.
RESCUE.inset = 0.15
-- A derived rescue point takes its height by interpolating between the two
-- authored destinations whose edge it sits on. Where the edge is a ramp or a
-- staircase that is right; where it spans a cliff, nothing along it is on any
-- surface and interpolating invents a height in mid-air. Reject the edge
-- rather than guess.
--
-- Measured across the hulls of all 89 authored deployment lanes -- 335 edges,
-- from lab/private/destination-point-scan/mapscan.json -- the rise is under
-- 25 uu on 56 of the 128 edges that rise at all, and runs continuously up to
-- about 220 with no gap that separates a slope from a step. There is no
-- threshold that tells those apart, so this does not try to be one: above 220
-- the data *is* gapped (250, 318, 400, 500, 600), and those six edges are
-- lanes that straddle a drop. 250 uu keeps every edge the interpolation can
-- reasonably serve, including Fathom's 200 uu staircase, and refuses only the
-- handful where it plainly cannot.
RESCUE.level_tolerance = 250.0
-- An operator standing on a destination sits a capsule height above it, and
-- the offset is normally measured from the operators who are doing exactly
-- that. When none of them is -- which is precisely the deployment that needs
-- rescuing, because every operator is somewhere wrong -- the measurement has
-- no sample and used to fall back to zero, placing every derived point one
-- capsule height *below* the floor. Harakiri's Fathom operator landed in a
-- crate and then on a ledge over the void; MortisVenunum's log asked for
-- Z=750 on a floor at 850-864 and the capsule settled at 865, one recovery
-- that happened to have something underneath it.
--
-- 100 uu is the measured offset on Kaller and the larger of the two heights
-- the 1.0.8 profile work recorded (Fathom is nearer 70), so an unsampled
-- guess errs upwards: a point slightly above the floor drops onto it, a point
-- below it is inside geometry.
RESCUE.capsule_height = 100.0
local PLACEMENT_PROFILES = {
    {
        name = "ColdMetal",
        -- The fifth staged position is valid on this map; rescue only an
        -- operator the linked tactical volume conclusively rejects.
        outside_volume_only = true,
        -- This rescue is the cooked map's own skirmish-intro capsule
        -- transform, not a point derived from the deployment quadrilateral --
        -- it sits 513 uu outside it -- so it is used exactly as authored and
        -- is not inset. Its evidence is that the map spawns a player there;
        -- the tactical-volume check after the move is what confirms it.
        destinations = {
            {X = 700, Y = -2500, Z = 30},
            {X = 950, Y = -2150, Z = 0},
            {X = 950, Y = -1650, Z = 0},
            {X = 650, Y = -1350, Z = 0},
        },
        rescues = {
            {X = 150, Y = -1650, Z = 100},
        },
    },
    {
        name = "Kaller025",
        -- The reported six-unit staging was the four points below, one
        -- operator at 6369/-1393 on the rocks, and one at 0/0/261. Keep both
        -- overflow operators inside the quadrilateral the map authors marked
        -- for player deployment: these are the midpoints of its left and
        -- right edges, drawn in towards the centre by RESCUE.inset. Z=500 is
        -- the capsule centre observed at the four surrounding 400-Z
        -- TacticalPoints.
        inset_rescues = true,
        destinations = {
            {X = 5000, Y = -1140, Z = 400},
            {X = 5460, Y = -1200, Z = 400},
            {X = 5000, Y = -1500, Z = 400},
            {X = 5450, Y = -1700, Z = 400},
        },
        rescues = {
            {X = 5000, Y = -1320, Z = 500},
            {X = 5455, Y = -1450, Z = 500},
        },
    },
    {
        name = "FathomFinale",
        -- MM_06_090, preparation area 2. The report's four ordinary units
        -- match these cooked points exactly; the two overflow positions at
        -- 22009/9775 and 22683/9694 were outside the deployment zone -- one
        -- by 33 uu, the other by 287, which is the reported difference
        -- between an operator that can walk back in and one that cannot.
        -- These replacements are the midpoints of the lane's two 575 uu side
        -- edges, drawn in by RESCUE.inset. Neither extrapolates beyond the
        -- authored four-point shape.
        inset_rescues = true,
        destinations = {
            {X = 22650, Y = 9150, Z = 27130},
            {X = 22650, Y = 10250, Z = 27130},
            {X = 22296.464466, Y = 9603.535534, Z = 27130},
            {X = 22296.464466, Y = 9796.464466, Z = 27130},
        },
        rescues = {
            {X = 22473.232233, Y = 9376.767767, Z = 27200},
            {X = 22473.232233, Y = 10023.232233, Z = 27200},
        },
    },
}

-- Missions that auto-assign a character *in addition to* the player
-- commander. Only those put a body into the deployment area that the squad
-- selection did not choose, so only those keep their authored maximum.
--
-- Read from the cooked mission definitions: of 125, exactly 18 carry
-- CharacterRequirements and every requirement is bAutoAssign. Fourteen of
-- the eighteen require the player commander alone, who occupies an ordinary
-- squad slot and costs no extra body. These four are the entire remainder.
--
-- The 1.0.4 list plus its "/AuthoredHero/" and "HM_" substring fallback
-- matched twenty-one definitions, six of which carry no requirements at all.
-- That, not a game limit, is why free-form-looking missions were still
-- capped at four.
local GUARDED_MISSION_NAMES = {
    "HM_Kabb_010", "HM_Telrea_010", "HM_Telrea_020", "HM_TrickLuco_020",
}

-- Slug HQ injects Tal Rea from mission Blueprint logic rather than declaring
-- her in CharacterRequirements. Its cooked definition therefore looked like
-- an ordinary four-to-six candidate, but a live 1.1.1 report settled the
-- behavior: six selected operators became eight player units at combat start
-- and Tal Rea appeared twice. Keep these exact missions at their authored
-- four even when the empty/missing requirements array is readable.
--
-- The six AuthoredHero entries are the same shape as Slug HQ, established by
-- reading all 125 cooked definitions rather than by guessing:
--
--   * Five HM definitions carry readable CharacterRequirements. Four of the
--     five auto-assign two or three characters -- HM_Kabb_010, HM_Telrea_010,
--     HM_Telrea_020, HM_TrickLuco_020 -- and are already guarded by
--     reflection.
--   * The other six are among the ten definitions UAssetAPI parses as
--     RawExport. They declare nothing at all: no MaxSquadSize, and no
--     requirements either. A hero mission that names no cast in its
--     definition has to receive one from mission logic, which is precisely
--     the route that produced two Tal Reas on Slug HQ.
--
-- HM_Jae_020 was the eleventh, and until 1.1.4 it was deliberately left out:
-- its requirement array reads one auto-assign, which the census recorded as
-- the commander alone. The array under-reports it. Reading the definitions'
-- own cast tags settles it -- every AuthoredHero mission names Hawks plus at
-- least one companion, and in every readable case the tag count equals the
-- requirement count except this one:
--
--     HM_Jae_010   Hawks, JaeMordant   RawExport   guarded
--     HM_Jae_020   Hawks, JaeMordant   reqs 1/1    NOT guarded
--
-- The two Jae missions are identical in shape, down to Facts.States.InRoster
-- .Jae. Jae therefore arrives through mission logic rather than through the
-- requirement array -- the Slug HQ route again. MortisVenunum reported six
-- selected operators becoming seven on cycle 29 when she joins at the start,
-- which hangs the save. With HM_Jae_020 listed the guard covers all eleven
-- AuthoredHero missions, which is what the cast census supports directly:
-- none of them deploys a free six.
--
-- 1.1.0 removed the old "HM_" substring fallback because it over-matched
-- twenty-one definitions, six of which carried no requirements. This is not
-- that fallback: it is six exact names, chosen from the requirement census,
-- and it leaves every non-hero mission and HM_Jae_020 free to reach six.
--
-- Before 1.1.2 these six were left at four by accident -- they are reachable
-- only by the fallback write, and the startup sweep latched before most of
-- them had loaded. Making that write reliable is what exposed them: Tesel and
-- FoxFlight both reported duplicated named operators on 1.1.2, on missions
-- that deploy a fixed authored cast.
local SCRIPTED_COMPANION_MISSION_NAMES = {
    "MM_02_050_SlugHQ",
    "HM_Cly_010", "HM_Cly_020", "HM_Jae_010", "HM_Jae_020",
    "HM_Kabb_020", "HM_Luco_010", "HM_Trick_010",
}

local registered_slot_hook = false
local registered_proxy_hook = false
local registered_lineup_hook = false
local registered_placement_hook = false
local registered_relocation_hook = false
local registered_area_notification = false
local registered_rescue_command = false
local relocation_posthook_ran = false
local relocation_prehook_ran = false
local registered_relocation_names = {}
local relocation_fired_name = ""
local relocation_fired_names = {}
local relocation_firing_count = 0
local relocation_ladders = {}
local relocation_scheduled = {}
local active_deployment_key = ""
local active_deployment_area = nil
-- A silent pass has to be distinguishable from a pass that never ran.
local repair_passes = 0
local repair_units_seen = 0
local repair_restored_total = 0
local registered_placement_triggers = {}
local registered_layout_notification = false
local registered_manager_notification = false
local target_assets_loaded = false
local slot_reentry = false
local slot_expansion_reported = false
local proxy_expansion_reported = false
local reported_layout_results = {}
local lineup_widths = {}
local layout_reported = false
local destination_expansion_reported = false
local placement_failure_reported = false
local reported_placement_triggers = {}
local maintenance_complete = false
local limit_reported = false
local status_reported = false
local status_complete_reported = false
local container_warning_reported = false
local data_container = "unknown"
local slot_notify_reported = false
local slot_widget_reported = false
local guard_reflection_hits = 0
local guard_name_hits = 0
local reported_squads = {}
local camera_census_reported = {}
local limit_attempts = 0
local limit_abandoned = false
-- Per proxy actor: the scale the fit was derived from, and the scale the
-- fit wrote. Keeping both is what lets a pass tell its own last write
-- apart from a scale the Blueprint has since put there for a different
-- character, without ever compounding its own work.
local fitted_scales = {}
local lineup_layouts = {}
local proxies_hidden_by_mod = {}
local fitted_slot_boxes = {}
local lineup_reentry = {}
local placement_attempts = {}
local last_member_stats = {raw = 0, valid = 0, in_world = 0, located = 0, near = 0, route = "none"}
local staged_positions = {}
local staging_window_open = false
local repair_counts = {}
local repair_reported = 0
local placement_rescue_reported = {}

local function log(message)
    print("[ZCOM_SQUAD_SIX] " .. message)
end

local function unwrap(value)
    if type(value) ~= "userdata" then return value end
    local ok, inner = pcall(function() return value:get() end)
    if ok and inner ~= nil then return inner end
    return value
end

local function valid(value)
    if value == nil then return false end
    local ok, result = pcall(function() return value:IsValid() end)
    return ok and result == true
end

local function full_name(value)
    local ok, result = pcall(function() return value:GetFullName() end)
    if not ok or result == nil then return "" end
    return tostring(result)
end

local function object_key(value)
    local ok, address = pcall(function() return value:GetAddress() end)
    if ok and type(address) == "number" and address ~= 0 then
        return tostring(address)
    end
    return full_name(value)
end

local function guard_summary()
    return "reflection=" .. tostring(guard_reflection_hits)
        .. "/names=" .. tostring(guard_name_hits)
end

-- Reflection first: a mission that auto-assigns a second character must keep
-- its authored maximum. Falls back to the exact name list when struct array
-- elements cannot be read.
local function guards_authored_maximum(object)
    local name = full_name(object)
    for _, mission in ipairs(SCRIPTED_COMPANION_MISSION_NAMES) do
        if string.find(name, mission, 1, true) then
            guard_name_hits = guard_name_hits + 1
            return true
        end
    end

    local read_ok, requirements = pcall(function()
        return object:GetPropertyValue(REQUIREMENTS_PROPERTY)
    end)
    if read_ok and requirements ~= nil then
        local count_ok, count = pcall(function() return requirements:GetArrayNum() end)
        if count_ok and type(count) == "number" then
            local readable = false
            local auto_assigned = 0
            for index = 1, count do
                local entry_ok, flag = pcall(function()
                    return unwrap(unwrap(requirements[index]):GetPropertyValue(AUTO_ASSIGN_PROPERTY))
                end)
                if entry_ok and type(flag) == "boolean" then
                    readable = true
                    if flag then auto_assigned = auto_assigned + 1 end
                end
            end
            -- An empty array is a definitive "no requirements", not a failure.
            if readable or count == 0 then
                -- Every definition that carries requirements auto-assigns the
                -- player commander. One entry is therefore the commander
                -- alone, who takes an ordinary squad slot. Two or more add a
                -- body the deployment area was not built to hold beside six.
                if auto_assigned > 1 then
                    guard_reflection_hits = guard_reflection_hits + 1
                    return true
                end
                return false
            end
        end
    end

    if name == "" then return false end
    for _, mission in ipairs(GUARDED_MISSION_NAMES) do
        if string.find(name, mission, 1, true) then
            guard_name_hits = guard_name_hits + 1
            return true
        end
    end
    return false
end

-- The write pass on its own, with no latching and no logging, so the startup
-- sweep and the per-screen re-sweep cannot drift apart. Returns nil when the
-- object list could not be read at all, which the callers report differently.
local function sweep_data_limits()
    local objects = FindAllOf("DataAsset")
    if objects == nil then return nil end

    local counts = {
        matched = 0, writes = 0, at_six = 0,
        already_six = 0, guarded = 0, restored = 0,
    }
    for _, object in pairs(objects) do
        local read_ok, value = pcall(function()
            return unwrap(object:GetPropertyValue(MAXIMUM_PROPERTY))
        end)
        if read_ok and type(value) == "number" then
            counts.matched = counts.matched + 1
            if value == TARGET_SIZE then counts.already_six = counts.already_six + 1 end
            if guards_authored_maximum(object) then
                counts.guarded = counts.guarded + 1
                -- The container may already have raised this one; put it back.
                if value ~= AUTHORED_SIZE then
                    local restore_ok = pcall(function()
                        object[MAXIMUM_PROPERTY] = AUTHORED_SIZE
                    end)
                    if restore_ok then counts.restored = counts.restored + 1 end
                end
            elseif value == AUTHORED_SIZE then
                local write_ok = pcall(function() object[MAXIMUM_PROPERTY] = TARGET_SIZE end)
                if write_ok then counts.writes = counts.writes + 1 end
            end
            local verify_ok, after = pcall(function()
                return unwrap(object:GetPropertyValue(MAXIMUM_PROPERTY))
            end)
            if verify_ok and after == TARGET_SIZE then counts.at_six = counts.at_six + 1 end
        end
    end
    return counts
end

local function apply_data_limits()
    if limit_reported or limit_abandoned then return end

    -- Bounded, so the sweep cannot run for the whole session. Giving up is
    -- logged rather than silent: without a line saying so, a mod that had
    -- stopped trying would be indistinguishable from one that never started.
    limit_attempts = limit_attempts + 1
    if limit_attempts > LIMIT_ATTEMPT_CAP then
        limit_abandoned = true
        log("limits_abandoned=true attempts=" .. tostring(limit_attempts - 1)
            .. " reason=no_data_assets_read")
        return
    end

    local counts = sweep_data_limits()
    if counts == nil then return end

    if not limit_reported and counts.matched > 10 then
        limit_reported = true
        if counts.already_six > 0 and counts.writes == 0 then
            data_container = "loaded"
        elseif counts.already_six > 0 then
            data_container = "partial"
        else
            data_container = "missing"
        end
        log("limits matched=" .. tostring(counts.matched)
            .. " fallback_writes=" .. tostring(counts.writes)
            .. " already_six=" .. tostring(counts.already_six)
            .. " at_six=" .. tostring(counts.at_six)
            .. " guarded=" .. tostring(counts.guarded)
            .. " restored=" .. tostring(counts.restored)
            .. " guard=" .. guard_summary()
            .. " data_container=" .. data_container)
    end
end

-- Ten of the 125 mission definitions serialize no MaxSquadSize override at
-- all -- both Cly hero missions, HM_Jae_010, HM_Kabb_020, HM_Luco_010,
-- HM_Trick_010, SK_Serolonis_020, SK_Vandor_015, MM_02_010_CoilReunion and
-- the main-story placeholder. The container cannot reach them: UAssetAPI
-- parses those packages as RawExport, so there is no property node to edit
-- and nothing to inject one beside. Their only route to six is the fallback
-- write, and the startup sweep latches after one pass -- so whether a mission
-- got six came down to whether its DataAsset happened to be resident during
-- that single pass, roughly thirty seconds in. kamilastone's log caught it
-- exactly: fallback_writes=7 against the ten that need one, and Best Served
-- Cold left at four while the same install handed six to everything else.
-- "It works on an old save" is that race, not a per-mission limit.
--
-- So the sweep runs again when the squad-selection viewmodel is constructed,
-- which is the moment the value is about to be read and is necessarily after
-- the chosen mission's definition has loaded. This is not a return to 1.0.x's
-- unbounded rescan: that one enumerated UObjects every five seconds forever,
-- including through level transitions, which is what LIMIT_ATTEMPT_CAP was
-- added to stop. This one is edge-triggered by a UI object being built, and
-- still capped.
--
-- The cap counts *idle* re-sweeps, not constructions. 1.1.2 counted every
-- viewmodel the galaxy map built, so a long campaign session could exhaust
-- sixty of them on screens where there was nothing to fix and then spend the
-- rest of the session unable to raise a late definition or restore a guarded
-- one. What the cap exists to prevent is an enumeration that runs forever
-- while achieving nothing; a pass that wrote or restored a value is by
-- definition not that, so it resets the budget. A healthy install still
-- stops after sixty consecutive quiet passes.
local RESWEEP_CAP = 60
local resweeps = 0
local idle_resweeps = 0
local resweep_abandoned = false

local function resweep_data_limits()
    if resweep_abandoned then return end
    -- Nothing to re-apply until the first sweep has established a baseline.
    if not limit_reported then return end

    resweeps = resweeps + 1
    if idle_resweeps >= RESWEEP_CAP then
        resweep_abandoned = true
        log("limits_resweep_abandoned=true count=" .. tostring(resweeps - 1)
            .. " idle=" .. tostring(idle_resweeps))
        return
    end

    local counts = sweep_data_limits()
    -- A read that returned no object list at all is idle in the sense the cap
    -- cares about: it cost an enumeration and changed nothing.
    if counts ~= nil and (counts.writes > 0 or counts.restored > 0) then
        idle_resweeps = 0
    else
        idle_resweeps = idle_resweeps + 1
    end
    if counts == nil then return end
    -- Silent when there was nothing left to fix, which is the healthy case
    -- and the common one. A line here means a mission definition loaded after
    -- the startup sweep and would otherwise have been capped at four.
    if counts.writes > 0 or counts.restored > 0 then
        log("limits_resweep=" .. tostring(resweeps)
            .. " late_writes=" .. tostring(counts.writes)
            .. " restored=" .. tostring(counts.restored)
            .. " matched=" .. tostring(counts.matched)
            .. " at_six=" .. tostring(counts.at_six))
    end
end

-- One line that answers "is Squad Six actually running, and is it complete?"
-- Support triage reads this from UE4SS.log; nothing else in the log is needed.
--
-- Reported twice: once as soon as the data limits are known, so a log pasted
-- before the mission screen is opened still proves the mod is running, and
-- again when every hook is up. 1.0.4 reported only the early line, and
-- VM_ActivitySlotList does not exist until the mission screen opens, so that
-- line permanently recorded slot_hook=false on healthy installs. Every 1.0.4
-- report carries that false negative in the one line meant to settle whether
-- the install is sound.
local function report_status()
    if not limit_reported then return end
    local complete = registered_slot_hook
        and registered_proxy_hook
        and registered_lineup_hook
        and registered_placement_hook
    if status_reported and (status_complete_reported or not complete) then return end
    status_reported = true
    if complete then status_complete_reported = true end
    log("status version=" .. VERSION
        .. " complete=" .. tostring(complete)
        .. " data_container=" .. data_container
        .. " slot_hook=" .. tostring(registered_slot_hook)
        .. " proxy_hook=" .. tostring(registered_proxy_hook)
        .. " lineup_hook=" .. tostring(registered_lineup_hook)
        .. " placement_hook=" .. tostring(registered_placement_hook)
        .. " guard=" .. guard_summary())
    if data_container == "missing" and not container_warning_reported then
        container_warning_reported = true
        log("WARNING: the pakchunk99-ZCOMSquadSix_P container is not mounted."
            .. " Copy the three pakchunk99-ZCOMSquadSix_P files into"
            .. " SWZeroCompany/Content/Paks/~mods/")
    end
end

-- The old probes appended null UObject references after construction. Here we
-- copy complete slot-data structs, then ask the Blueprint's factory to rebuild.
local function expand_slot_definitions(context, definitions_param)
    if slot_reentry or definitions_param == nil then return end
    local definitions = unwrap(definitions_param)
    if definitions == nil then return end

    local count_ok, count = pcall(function() return definitions:GetArrayNum() end)
    if not count_ok or count < 4 or count >= TARGET_SIZE then return end

    local original_count = count
    local index_writes = 0
    local copy_ok = pcall(function()
        while count < TARGET_SIZE do
            definitions[count + 1] = definitions[count]
            local new_definition = unwrap(definitions[count + 1])
            local index_ok = pcall(function()
                new_definition[SLOT_INDEX_PROPERTY] = count
            end)
            if index_ok then index_writes = index_writes + 1 end
            count = count + 1
        end
    end)
    local verify_ok, after = pcall(function() return definitions:GetArrayNum() end)
    if not copy_ok or not verify_ok or after ~= TARGET_SIZE then
        log("slot_definition_expansion_failed count=" .. tostring(verify_ok and after or -1))
        return
    end

    local owner = unwrap(context)
    if not valid(owner) then return end
    slot_reentry = true
    local rebuild_ok = pcall(function() owner:CreateActivitySlotVMs(definitions) end)
    slot_reentry = false

    if not slot_expansion_reported then
        slot_expansion_reported = true
        log("slot_definitions=" .. tostring(original_count) .. "->6"
            .. " index_writes=" .. tostring(index_writes)
            .. " factory_rebuild=" .. tostring(rebuild_ok))
    end
end

local function proxy_array(owner)
    local ok, value = pcall(function() return owner:GetPropertyValue(PROXY_ARRAY_PROPERTY) end)
    if not ok then return nil end
    return value
end

local function ensure_proxy_pool(owner)
    if not valid(owner) then return false end
    local proxies = proxy_array(owner)
    if proxies == nil then return false end

    local count_ok, count = pcall(function() return proxies:GetArrayNum() end)
    if not count_ok then return false end
    if count >= TARGET_SIZE then return false end
    -- Refuse unexpected baselines. A five-object pool is accepted so one
    -- failed spawn can be retried on the next bounded maintenance pass.
    if count < 4 or count > 5 then return false end

    local template = unwrap(proxies[1])
    if not valid(template) then return false end
    local world_ok, world = pcall(function() return owner:GetWorld() end)
    local class_ok, proxy_class = pcall(function() return template:GetClass() end)
    if not world_ok or not class_ok or not valid(world) or not valid(proxy_class) then return false end

    local added = 0
    while count < TARGET_SIZE do
        local spawn_ok, actor = pcall(function() return world:SpawnActor(proxy_class, {}, {}) end)
        if not spawn_ok or not valid(actor) then break end
        pcall(function() actor:SetActorHiddenInGame(true) end)
        local append_ok = pcall(function() proxies[count + 1] = actor end)
        if not append_ok then
            pcall(function() actor:K2_DestroyActor() end)
            break
        end
        count = count + 1
        added = added + 1
    end

    if added > 0 and not proxy_expansion_reported then
        proxy_expansion_reported = true
        log("presentation_proxies=" .. tostring(count) .. " spawned=" .. tostring(added))
    end
    return added > 0
end

local function array_count(value)
    value = unwrap(value)
    if value == nil then return -1 end
    local ok, count = pcall(function() return value:GetArrayNum() end)
    return ok and count or -1
end

-- Hook parameters are RemoteParam wrappers owned by UE4SS and are valid only
-- while the hook is running. In particular, retaining a reflected TArray for
-- an ExecuteWithDelay callback can leave value:get() indexing memory whose
-- parameter frame has already gone away. Snapshot the UObject elements while
-- the frame is live; the resulting Lua table and UObject handles are safe to
-- inspect on the deferred game-thread pass.
local function snapshot_array(value, count)
    value = unwrap(value)
    if value == nil or count == nil or count < 1 then return {} end

    local snapshot = {}
    for index = 1, count do
        local ok, element = pcall(function() return unwrap(value[index]) end)
        if ok then snapshot[index] = element end
    end
    return snapshot
end

local function actor_location(actor)
    local ok, location = pcall(function() return actor:K2_GetActorLocation() end)
    if not ok or location == nil then return nil end
    local fields_ok = type(location.X) == "number"
        and type(location.Y) == "number"
        and type(location.Z) == "number"
    return fields_ok and location or nil
end

local function actor_rotation(actor)
    local ok, rotation = pcall(function() return actor:K2_GetActorRotation() end)
    return ok and rotation or nil
end

local function actor_scale(actor)
    local ok, scale = pcall(function() return actor:GetActorScale3D() end)
    if not ok or scale == nil then return nil end
    local fields_ok = type(scale.X) == "number"
        and type(scale.Y) == "number"
        and type(scale.Z) == "number"
    return fields_ok and scale or nil
end

local function copy_vector(value)
    return {X = value.X, Y = value.Y, Z = value.Z}
end

-- Scales come back from the engine as floats that have been through a
-- multiply, so this asks whether a scale is the one this mod wrote
-- rather than whether it is bit-identical.
local function scales_match(left, right)
    if left == nil or right == nil then return false end
    return math.abs(left.X - right.X) < 0.0005
        and math.abs(left.Y - right.Y) < 0.0005
        and math.abs(left.Z - right.Z) < 0.0005
end

local function copy_rotator(value)
    return {Pitch = value.Pitch, Yaw = value.Yaw, Roll = value.Roll}
end

local function distance_squared(left, right)
    local x = left.X - right.X
    local y = left.Y - right.Y
    local z = left.Z - right.Z
    return x * x + y * y + z * z
end

-- An actor the placement pass never reached sits at the world origin plus its
-- own capsule height -- EvilPoptart1987 logged 0/0/261 for the operator that
-- could not move -- so the test has to ignore Z. The closest authored player
-- destination in the game is 224 uu from the XY origin (HM_Kabb_020), so a
-- 100 uu radius cannot mistake a real deployment point for this.
local function at_world_origin(location)
    if location == nil then return false end
    return location.X * location.X + location.Y * location.Y <= ORIGIN_RADIUS_SQ
end

-- nil means the reflected test was unavailable; only a conclusive false is
-- allowed to reject a position. This preserves the distance fallback on game
-- builds where the tactical-volume call cannot be made through UE4SS.
local function actor_inside_tactical_area(volume, actor)
    if volume == nil or not valid(actor) then return nil end
    local ok, inside = pcall(function()
        return volume[INSIDE_AREA_FUNCTION](volume, actor)
    end)
    if ok and type(inside) == "boolean" then return inside end
    return nil
end

-- Where the game itself stood this operator up before combat. That position
-- is the one thing about a deployment we can trust: the game chose it, so it
-- is on ground the map author approved and on the tactical grid. The scan of
-- the cooked levels says there is no alternative to fall back on -- 53 of the
-- 89 deployment areas author no spare TacticalPoint anywhere near the squad,
-- and MM_02_030, HM_Jae_010 and SK_Kaller_020, the three maps the 1.0.5
-- reports actually name, author none at all.
--
-- First reading wins, and only inside the staging window: once the relocation
-- has run, the position on offer is the broken one we are trying to undo.
-- `trusted` marks a position this mod chose rather than one the game staged.
-- The repair tests an untrusted snapshot against the authored lane before
-- restoring anybody to it; a trusted one is used as written, because the
-- rescue that produced it already argued for the location -- Cold Metal's is
-- the cooked map's own skirmish-intro capsule, 513 uu outside the deployment
-- quadrilateral.
local function remember_staged_position(member, entry, volume, trusted)
    if not staging_window_open then return end
    local key = object_key(member)
    if key == "" or staged_positions[key] ~= nil then return end
    if entry.location == nil then return end
    -- An operator already at the origin was never placed; do not enshrine it.
    if at_world_origin(entry.location) then return end
    -- Cold Metal proves that an initial spawn is not automatically safe: it
    -- can put Hawks on the snowy hill outside the playable volume. Never turn
    -- a position the game itself rejects into either a repair target or a
    -- destination candidate.
    if actor_inside_tactical_area(volume, member) == false then return end
    staged_positions[key] = {
        actor = member,
        location = copy_vector(entry.location),
        rotation = entry.rotation ~= nil and copy_rotator(entry.rotation) or nil,
        trusted = trusted and true or false,
    }
end

-- Collect the player units standing in this deployment area, and record how
-- the count was arrived at.
--
-- The filter is proximity to an authored destination, not world identity. A
-- verified mission launch logged raw=12 valid=12 in_world=0: every squad
-- member was readable and every one was rejected by comparing
-- member:GetWorld() against area:GetWorld() by name. That comparison is what
-- left a six-operator squad on a four-destination map with two units
-- relocated onto the same tile. Distance does the job the world check was
-- meant to do -- a unit standing in the deployment area is in the right
-- world, in the playable space, and on ground the map author approved -- and
-- unlike the world check it demonstrably works. The world name is still
-- recorded, as a number in the log rather than a gate on behaviour.
local function collect_members(members, area_world_name, anchors, volume, stats)
    local result = {}
    local count = array_count(members)
    if count < 0 then return result end
    stats.raw = stats.raw + count
    for index = 1, count do
        local member = unwrap(members[index])
        if valid(member) then
            stats.valid = stats.valid + 1

            local world_ok, member_world = pcall(function() return member:GetWorld() end)
            if world_ok and valid(member_world)
                and full_name(member_world) == area_world_name then
                stats.in_world = stats.in_world + 1
            end

            local location = actor_location(member)
            if location ~= nil then
                stats.located = stats.located + 1
                local nearest = math.huge
                for _, anchor in ipairs(anchors) do
                    nearest = math.min(nearest, distance_squared(location, anchor))
                end
                if nearest <= MAX_DESTINATION_DISTANCE_SQ then
                    stats.near = stats.near + 1
                    local entry = {
                        actor = member,
                        location = copy_vector(location),
                        rotation = actor_rotation(member),
                        inside_volume = actor_inside_tactical_area(volume, member),
                    }
                    result[#result + 1] = entry
                    remember_staged_position(member, entry, volume)
                end
            end
        end
    end
    return result
end

-- Route two: the squad objects themselves, for the case where the game state
-- has no player squad to offer yet.
local function squads_near(area_world_name, anchors, volume, stats)
    local found_ok, squads = pcall(function() return FindAllOf(SQUAD_CLASS) end)
    if not found_ok or squads == nil then return {} end

    local result = {}
    for _, squad in pairs(squads) do
        if valid(squad) then
            local members_ok, members = pcall(function()
                return squad:GetPropertyValue(SQUAD_MEMBERS_PROPERTY)
            end)
            if members_ok and members ~= nil then
                for _, member in ipairs(collect_members(
                    members, area_world_name, anchors, volume, stats)) do
                    result[#result + 1] = member
                end
            end
        end
    end
    return result
end

local function player_squad_members(area, anchors)
    local stats = {raw = 0, valid = 0, in_world = 0, located = 0, near = 0, route = "none"}
    if anchors == nil or #anchors < 1 then return {}, stats end

    local world_ok, world = pcall(function() return area:GetWorld() end)
    local world_name = (world_ok and valid(world)) and full_name(world) or ""
    local volume = nil
    local volume_ok, linked = pcall(function()
        return area[LINKED_AREA_FUNCTION](area)
    end)
    if volume_ok and valid(linked) then volume = linked end

    local state_ok, state = pcall(function() return FindFirstOf(TACTICAL_GAME_STATE_CLASS) end)
    if state_ok and valid(state) then
        local squad_ok, squad = pcall(function()
            return unwrap(state:GetPropertyValue(PLAYER_SQUAD_PROPERTY))
        end)
        if squad_ok and valid(squad) then
            local members_ok, members = pcall(function()
                return squad:GetPropertyValue(SQUAD_MEMBERS_PROPERTY)
            end)
            if members_ok and members ~= nil then
                local result = collect_members(members, world_name, anchors, volume, stats)
                if #result > 0 then
                    stats.route = "player_squad"
                    -- How many operators the squad actually holds, as opposed
                    -- to how many passed the proximity filter. Only this route
                    -- can say: the fallback sweeps every squad in the level,
                    -- enemies included.
                    stats.squad_size = array_count(members)
                    return result, stats
                end
            end
        end
    end

    local nearby = squads_near(world_name, anchors, volume, stats)
    if #nearby > 0 then
        stats.route = "squad_objects"
        return nearby, stats
    end
    return {}, stats
end

local function member_stats_text(stats)
    return "route=" .. stats.route
        .. " raw=" .. tostring(stats.raw)
        .. " valid=" .. tostring(stats.valid)
        .. " in_world=" .. tostring(stats.in_world)
        .. " located=" .. tostring(stats.located)
        .. " near=" .. tostring(stats.near)
end

-- Every player unit in the level, unfiltered. The repair pass has to see the
-- operators the proximity filter throws away, because being thrown away is
-- exactly the symptom it exists to fix.
local function every_player_unit()
    local state_ok, state = pcall(function() return FindFirstOf(TACTICAL_GAME_STATE_CLASS) end)
    if not state_ok or not valid(state) then return {} end
    local squad_ok, squad = pcall(function()
        return unwrap(state:GetPropertyValue(PLAYER_SQUAD_PROPERTY))
    end)
    if not squad_ok or not valid(squad) then return {} end
    local members_ok, members = pcall(function()
        return squad:GetPropertyValue(SQUAD_MEMBERS_PROPERTY)
    end)
    if not members_ok or members == nil then return {} end

    local result = {}
    local count = array_count(members)
    for index = 1, count do
        local member = unwrap(members[index])
        if valid(member) then
            local location = actor_location(member)
            if location ~= nil then
                result[#result + 1] = {
                    actor = member,
                    key = object_key(member),
                    location = copy_vector(location),
                }
            end
        end
    end
    return result
end

-- Destination actors this mod spawned, by object key. The authored lane is
-- the map author's four points; once two more have been appended, the hull of
-- "every current destination" is a shape nobody designed. Keeping the two
-- apart lets a rescue derive its targets from the lane the mission actually
-- authored rather than from the lane the mod just widened.
local synthesised_destinations = {}

local function destination_anchors(area, authored_only)
    local list_ok, destinations = pcall(function()
        return area:GetPropertyValue(DESTINATIONS_PROPERTY)
    end)
    if not list_ok or destinations == nil then return {} end

    local anchors = {}
    local count = array_count(destinations)
    for index = 1, count do
        local point = unwrap(destinations[index])
        local location = valid(point) and actor_location(point) or nil
        if location ~= nil
            and not (authored_only and synthesised_destinations[object_key(point)]) then
            anchors[#anchors + 1] = copy_vector(location)
        end
    end
    return anchors
end

-- The tactical volume the deployment area belongs to, or nil. Worth having
-- because it can answer "is this operator still in the playable space?"
-- itself, which is the question the out-of-bounds reports are really asking.
local function linked_tactical_area(area)
    local ok, volume = pcall(function() return area[LINKED_AREA_FUNCTION](area) end)
    if ok and valid(volume) then return volume end
    return nil
end

local function xy_distance_squared(left, right)
    local x = left.X - right.X
    local y = left.Y - right.Y
    return x * x + y * y
end

local function transform_profile_point(transform, point)
    return {
        X = transform.tx + transform.scale
            * (transform.cos * point.X - transform.sin * point.Y),
        Y = transform.ty + transform.scale
            * (transform.sin * point.X + transform.cos * point.Y),
        Z = point.Z + transform.tz,
    }
end

-- The deployment lane: the convex hull, in XY, of the area's own authored
-- destinations. Returned counter-clockwise. Fewer than three distinct points
-- cannot bound anything, so the caller falls back to the distance test.
--
-- The hull is built in XY and every test against it ignores Z, but each
-- corner keeps the Z of the destination it came from. derive_rescue_points
-- needs it: a point invented on an edge whose two ends sit at different
-- heights is not on either level, and without the corner heights there is no
-- way to notice. Duplicate XY keeps the first Z, which is arbitrary only for
-- destinations stacked exactly on top of each other.
local function deployment_polygon(locations)
    local points, seen = {}, {}
    for _, location in ipairs(locations) do
        local key = string.format("%.1f/%.1f", location.X, location.Y)
        if not seen[key] then
            seen[key] = true
            points[#points + 1] =
                {X = location.X, Y = location.Y, Z = location.Z or 0}
        end
    end
    if #points < 3 then return nil end
    table.sort(points, function(left, right)
        if left.X ~= right.X then return left.X < right.X end
        return left.Y < right.Y
    end)

    local function cross(origin, first, second)
        return (first.X - origin.X) * (second.Y - origin.Y)
            - (first.Y - origin.Y) * (second.X - origin.X)
    end

    local lower = {}
    for _, point in ipairs(points) do
        while #lower >= 2
            and cross(lower[#lower - 1], lower[#lower], point) <= 0 do
            lower[#lower] = nil
        end
        lower[#lower + 1] = point
    end
    local upper = {}
    for index = #points, 1, -1 do
        local point = points[index]
        while #upper >= 2
            and cross(upper[#upper - 1], upper[#upper], point) <= 0 do
            upper[#upper] = nil
        end
        upper[#upper + 1] = point
    end

    local hull = {}
    for index = 1, #lower - 1 do hull[#hull + 1] = lower[index] end
    for index = 1, #upper - 1 do hull[#hull + 1] = upper[index] end
    if #hull < 3 then return nil end
    return hull
end

local function distance_to_segment(point, first, second)
    local dx, dy = second.X - first.X, second.Y - first.Y
    local length = dx * dx + dy * dy
    local t = 0.0
    if length > 0 then
        t = ((point.X - first.X) * dx + (point.Y - first.Y) * dy) / length
        if t < 0 then t = 0 elseif t > 1 then t = 1 end
    end
    local nx, ny = first.X + t * dx - point.X, first.Y + t * dy - point.Y
    return math.sqrt(nx * nx + ny * ny)
end

-- Inside the deployment lane, or within one tactical step of its edge. The
-- tolerance is there because an operator standing on an authored destination
-- sits on the hull boundary, and because a capsule settles a little off the
-- point it was placed on.
local function inside_deployment(polygon, point)
    if polygon == nil or point == nil then return nil end
    local sign = nil
    local inside = true
    for index = 1, #polygon do
        local first = polygon[index]
        local second = polygon[index % #polygon + 1]
        local side = (second.X - first.X) * (point.Y - first.Y)
            - (second.Y - first.Y) * (point.X - first.X)
        if side ~= 0 then
            local positive = side > 0
            if sign == nil then sign = positive
            elseif positive ~= sign then inside = false break end
        end
    end
    if inside then return true end
    for index = 1, #polygon do
        local first = polygon[index]
        local second = polygon[index % #polygon + 1]
        if distance_to_segment(point, first, second) <= DEPLOYMENT_EDGE_TOLERANCE then
            return true
        end
    end
    return false
end

-- Where to put an overflow operator on a map that has no hand-verified
-- profile. The three profiles hardcode inset midpoints of authored edges;
-- this derives the same shape from whatever destinations the area actually
-- carries, so it works on all 89 preparation areas instead of three.
--
-- Z is self-calibrating. An operator standing on a destination sits a capsule
-- height above it -- about 100 uu on Kaller, 70 on Fathom -- so rather than
-- guess, take the offset from the operators who are already standing on their
-- destinations in this very deployment. Where none of them is, fall back to
-- RESCUE.capsule_height rather than to zero.
--
-- `ignore_units` drops the unit-proximity *rejection* while keeping units in
-- the clearance used for ordering. The repair fallback needs it: it rebuilds
-- this pool after the rescue has already stood operators on the points it
-- derived, and rejecting those points leaves it with nothing to offer. Where
-- a point is genuinely occupied the caller checks that itself. The expansion
-- path leaves it off, because a new *destination* on top of a standing
-- operator is a different and worse mistake.
local function derive_rescue_points(polygon, destinations, units, wanted, ignore_units)
    if polygon == nil or wanted < 1 then return {} end

    local cx, cy = 0, 0
    for _, corner in ipairs(polygon) do cx, cy = cx + corner.X, cy + corner.Y end
    cx, cy = cx / #polygon, cy / #polygon

    local offsets = {}
    for _, unit in ipairs(units) do
        local nearest, best = math.huge, nil
        for _, destination in ipairs(destinations) do
            local distance = xy_distance_squared(unit.location, destination)
            if distance < nearest then nearest, best = distance, destination end
        end
        if best ~= nil and nearest <= MIN_UNIT_SEPARATION_SQ then
            offsets[#offsets + 1] = unit.location.Z - best.Z
        end
    end
    local offset = RESCUE.capsule_height
    if #offsets > 0 then
        table.sort(offsets)
        offset = offsets[math.floor((#offsets + 1) / 2)]
    end

    -- One candidate per authored edge, drawn in off the boundary exactly as
    -- the profiles are. A boundary point is where a strict inside test or a
    -- tile snap can round back out of the lane.
    local candidates = {}
    for index = 1, #polygon do
        local first = polygon[index]
        local second = polygon[index % #polygon + 1]
        local mx, my = (first.X + second.X) / 2, (first.Y + second.Y) / 2
        local point = {
            X = mx + (cx - mx) * RESCUE.inset,
            Y = my + (cy - my) * RESCUE.inset,
        }
        -- Interpolate between the two ends of the edge rather than take the
        -- height of the nearest destination. On a lane whose corners sit at
        -- different heights the nearest destination to an inset midpoint can
        -- be the one on the other level, and two points a couple of hundred
        -- uu apart then get heights a couple of hundred uu apart -- at least
        -- one of them inside the geometry. Harakiri's Fathom stairs are the
        -- reported case: 1.1.3 derived 13074/2050 at Z=-200 and 12845/2050 at
        -- Z=0 off the same staircase, and put an operator in a crate.
        local rise = math.abs((first.Z or 0) - (second.Z or 0))
        local clearance = math.huge
        for _, destination in ipairs(destinations) do
            clearance = math.min(clearance, xy_distance_squared(point, destination))
        end
        local separated = clearance >= MIN_DESTINATION_SEPARATION_SQ
        for _, unit in ipairs(units) do
            clearance = math.min(clearance, xy_distance_squared(point, unit.location))
        end
        if not ignore_units then
            separated = separated and clearance >= MIN_DESTINATION_SEPARATION_SQ
        end
        if separated and rise <= RESCUE.level_tolerance then
            point.Z = ((first.Z or 0) + (second.Z or 0)) / 2 + offset
            point.clearance = clearance
            candidates[#candidates + 1] = point
        end
    end

    -- Furthest from anything already occupied first, so two rescued operators
    -- do not end up crowding the same corner of the lane.
    table.sort(candidates, function(left, right)
        if left.clearance ~= right.clearance then
            return left.clearance > right.clearance
        end
        if left.X ~= right.X then return left.X < right.X end
        return left.Y < right.Y
    end)

    local chosen = {}
    for _, point in ipairs(candidates) do
        if #chosen >= wanted then break end
        local clear = true
        for _, taken in ipairs(chosen) do
            if xy_distance_squared(point, taken) < MIN_DESTINATION_SEPARATION_SQ then
                clear = false
                break
            end
        end
        if clear then chosen[#chosen + 1] = point end
    end
    return chosen
end

-- A rescue point in the profile's own coordinates, drawn in towards the
-- centroid of its four authored destinations when the profile asks for it.
-- Z is left alone: it is a capsule height read off the map, not a position
-- inside the deployment shape.
local function inset_rescue(profile, rescue)
    if not profile.inset_rescues then return rescue end
    local x, y = 0, 0
    for _, point in ipairs(profile.destinations) do
        x, y = x + point.X, y + point.Y
    end
    local count = #profile.destinations
    x, y = x / count, y / count
    return {
        X = rescue.X + (x - rescue.X) * RESCUE.inset,
        Y = rescue.Y + (y - rescue.Y) * RESCUE.inset,
        Z = rescue.Z,
    }
end

-- Match a cooked four-point fingerprint after any level-instance translation
-- or yaw rotation. The old Cold Metal comparison used absolute coordinates,
-- so it silently stopped matching as soon as the same sublevel was instanced
-- elsewhere. Two points establish the 2-D rigid transform; all four must then
-- match distinct live destinations within 50 uu before a profile can act.
local function match_placement_profile(profile, destinations)
    if destinations == nil or #destinations < #profile.destinations then return nil end

    local first = profile.destinations[1]
    local second = profile.destinations[2]
    local expected_x = second.X - first.X
    local expected_y = second.Y - first.Y
    local expected_length = math.sqrt(expected_x * expected_x + expected_y * expected_y)
    if expected_length < 1 then return nil end

    for first_index, first_destination in ipairs(destinations) do
        for second_index, second_destination in ipairs(destinations) do
            if first_index ~= second_index
                and first_destination.location ~= nil
                and second_destination.location ~= nil then
                local actual_x = second_destination.location.X - first_destination.location.X
                local actual_y = second_destination.location.Y - first_destination.location.Y
                local actual_length = math.sqrt(actual_x * actual_x + actual_y * actual_y)
                local scale = actual_length / expected_length
                if scale >= 0.95 and scale <= 1.05 then
                    local divisor = expected_length * actual_length
                    local cos = (expected_x * actual_x + expected_y * actual_y) / divisor
                    local sin = (expected_x * actual_y - expected_y * actual_x) / divisor
                    local transform = {
                        cos = cos,
                        sin = sin,
                        scale = scale,
                        tx = first_destination.location.X
                            - scale * (cos * first.X - sin * first.Y),
                        ty = first_destination.location.Y
                            - scale * (sin * first.X + cos * first.Y),
                        tz = first_destination.location.Z - first.Z,
                    }

                    local matched, used = {}, {}
                    local complete = true
                    for expected_index, expected in ipairs(profile.destinations) do
                        local transformed = transform_profile_point(transform, expected)
                        local best_index, best_distance = nil, math.huge
                        for destination_index, destination in ipairs(destinations) do
                            if not used[destination_index] and destination.location ~= nil then
                                local distance = xy_distance_squared(
                                    transformed, destination.location)
                                if distance < best_distance then
                                    best_index, best_distance = destination_index, distance
                                end
                            end
                        end
                        if best_index == nil
                            or best_distance > PLACEMENT_PROFILE_MATCH_RADIUS_SQ then
                            complete = false
                            break
                        end
                        used[best_index] = true
                        matched[expected_index] = destinations[best_index].location
                    end
                    if complete then return transform, matched end
                end
            end
        end
    end
    return nil
end

-- Pair as many free targets and candidates as possible while minimizing the
-- total XY travel. Profiles currently carry at most two rescues, but the
-- bounded search is also cheap for every possible subset of a six-unit squad.
-- Enumeration order breaks exact ties deterministically.
local function minimum_distance_assignments(targets, candidates, wanted)
    local pair_count = math.min(#targets, #candidates, wanted or math.huge)
    if pair_count < 1 then return {} end

    local best, best_cost = nil, math.huge
    local used, current = {}, {}

    local function search(target_index, cost)
        if #current == pair_count then
            if cost < best_cost then
                best_cost = cost
                best = {}
                for index, pair in ipairs(current) do best[index] = pair end
            end
            return
        end
        if target_index > #targets or cost >= best_cost then return end

        local needed = pair_count - #current
        local remaining_targets = #targets - target_index + 1
        if remaining_targets < needed then return end

        local target = targets[target_index]
        for candidate_index, candidate in ipairs(candidates) do
            if not used[candidate_index] then
                used[candidate_index] = true
                current[#current + 1] = {
                    target = target,
                    unit = candidate,
                }
                search(target_index + 1, cost
                    + math.sqrt(xy_distance_squared(target, candidate.location)))
                current[#current] = nil
                used[candidate_index] = nil
            end
        end

        -- A target may be skipped only when enough later targets remain to
        -- produce the same maximum-cardinality assignment.
        if remaining_targets > needed then search(target_index + 1, cost) end
    end

    search(1, 0)
    return best or {}
end

-- Some maps stage overflow operators somewhere that is technically inside
-- the broad tactical volume but outside the small player deployment lane.
-- Act only on exact cooked four-point fingerprints and place the overflow
-- inside that authored shape before turning those positions into destinations.
--
-- Every profile is tried, not just profiles up to the first match. The three
-- shipped fingerprints are provably non-congruent -- each one matches exactly
-- one of the game's 89 preparation areas, at scale 1 and yaw 0 -- but that is
-- a property of this list, not of the matcher, and a fourth profile could
-- quietly break it. Two profiles claiming one map means the evidence for
-- which correction belongs here is gone, so nothing is moved.
local function rescue_known_staging(destinations, volume)
    if not staging_window_open then return 0 end

    local units = every_player_unit()
    if #units < 1 then return 0 end
    for _, unit in ipairs(units) do unit.rotation = actor_rotation(unit.actor) end
    -- A deployment with four authored points and six operators needs two safe
    -- additions, not permission to move every operator whose pre-relocation
    -- staging strip happens to sit outside the later destination polygon.
    -- Prorp's Serolonis log proved that distinction: 1.0.9 moved four staged
    -- operators even though only two destinations were missing.
    local missing = math.min(#units, TARGET_SIZE) - #destinations
    if missing < 1 then return 0 end

    local profile, transform, stock_destinations = nil, nil, nil
    for _, candidate_profile in ipairs(PLACEMENT_PROFILES) do
        local candidate_transform, candidate_destinations =
            match_placement_profile(candidate_profile, destinations)
        if candidate_transform ~= nil then
            if profile ~= nil then
                if not placement_rescue_reported.ambiguous then
                    placement_rescue_reported.ambiguous = true
                    log("placement_rescue=none reason=ambiguous_profiles"
                        .. " matched=" .. profile.name .. "," .. candidate_profile.name)
                end
                return 0
            end
            profile, transform, stock_destinations =
                candidate_profile, candidate_transform, candidate_destinations
        end
    end
    -- No profile: derive the lane and its rescue points from the area's own
    -- authored destinations. A profile stays preferred where one matches --
    -- its points come from the cooked map and are reproduced in the tests --
    -- but every other preparation area now gets the same treatment.
    local authored = {}
    for _, destination in ipairs(destinations) do
        if destination.location ~= nil then
            authored[#authored + 1] = destination.location
        end
    end
    local polygon = deployment_polygon(authored)

    local candidates = {}
    for _, unit in ipairs(units) do
        local eligible
        if profile == nil then
            eligible = inside_deployment(polygon, unit.location) == false
        elseif profile.outside_volume_only then
            eligible = actor_inside_tactical_area(volume, unit.actor) == false
        else
            local nearest = math.huge
            for _, stock in ipairs(stock_destinations) do
                nearest = math.min(nearest, xy_distance_squared(unit.location, stock))
            end
            eligible = nearest > PLACEMENT_PROFILE_MEMBER_RADIUS_SQ
        end
        if eligible then candidates[#candidates + 1] = unit end
    end
    if #candidates < 1 then return 0 end

    local targets = {}
    if profile ~= nil then
        for _, rescue in ipairs(profile.rescues) do
            targets[#targets + 1] = transform_profile_point(
                transform, inset_rescue(profile, rescue))
        end
    else
        targets = derive_rescue_points(polygon, authored, units, missing)
    end
    if #targets < 1 then return 0 end

    -- Resolve occupancy before assignment. Otherwise an occupied first target
    -- can claim the only candidate, fail the later blocked check, and starve a
    -- free second target. A candidate within ten XY units is already settled;
    -- any non-candidate inside a tactical tile simply makes that target
    -- unavailable. Candidates farther than ten units are allowed to claim and
    -- move onto their nearby target, which closes the old outside-but-skipped
    -- band between the 30-34 uu inset and the 100 uu separation radius.
    local candidate_set, settled = {}, {}
    for _, candidate in ipairs(candidates) do candidate_set[candidate] = true end

    local free_targets = {}
    for _, target in ipairs(targets) do
        local occupied = false
        for _, unit in ipairs(units) do
            if xy_distance_squared(target, unit.location)
                <= RESCUE.settled_radius_sq then
                occupied = true
                if candidate_set[unit] then settled[unit] = true end
            elseif not candidate_set[unit]
                and distance_squared(target, unit.location)
                    < MIN_UNIT_SEPARATION_SQ then
                occupied = true
            end
        end
        if not occupied then free_targets[#free_targets + 1] = target end
    end

    local unsettled_candidates = {}
    for _, candidate in ipairs(candidates) do
        if not settled[candidate] then
            unsettled_candidates[#unsettled_candidates + 1] = candidate
        end
    end

    local assignments = minimum_distance_assignments(
        free_targets, unsettled_candidates, missing)
    local rescued, moves, placed = 0, {}, {}
    for _, assignment in ipairs(assignments) do
        local target, unit = assignment.target, assignment.unit
        local blocked = false
        for _, other in ipairs(units) do
            if other ~= unit
                and distance_squared(target, other.location)
                    < MIN_UNIT_SEPARATION_SQ then
                blocked = true
                break
            end
        end
        if not blocked then
            local original = copy_vector(unit.location)
            local moved, accepted = pcall(function()
                return unit.actor:K2_SetActorLocationAndRotation(
                    target, unit.rotation or {}, false, {}, true)
            end)
            if moved and accepted ~= false
                and actor_inside_tactical_area(volume, unit.actor) ~= false then
                unit.location = copy_vector(target)
                remember_staged_position(unit.actor, unit, volume, true)
                rescued = rescued + 1
                placed[#placed + 1] = copy_vector(target)
                moves[#moves + 1] = string.format(
                    "%.0f/%.0f/%.0f->%.0f/%.0f/%.0f",
                    original.X, original.Y, original.Z,
                    target.X, target.Y, target.Z)
            else
                -- The map fingerprint matched but this runtime rejected the
                -- target. Put the actor back and let the existing placement
                -- diagnostics report the refusal.
                pcall(function()
                    unit.actor:K2_SetActorLocationAndRotation(
                        original, unit.rotation or {}, false, {}, true)
                end)
            end
        end
    end
    local label = profile ~= nil and profile.name or "deployment_lane"
    if rescued > 0 and not placement_rescue_reported[label] then
        placement_rescue_reported[label] = true
        log("placement_rescue=" .. label
            .. " moved=" .. table.concat(moves, ","))
    end
    -- Hand back where the operators were deliberately put. The lane test that
    -- follows exists to reject positions the *game* staged badly; a position
    -- this pass chose on evidence -- Cold Metal's rescue is the cooked map's
    -- own skirmish-intro capsule, 513 uu outside its deployment
    -- quadrilateral -- must not be thrown out by it.
    return rescued, placed
end

-- Why this operator cannot be where it is, or nil if it is fine. Ordered so
-- the log names the most specific cause.
local function strand_reason(unit, index, units, anchors, volume, polygon)
    if at_world_origin(unit.location) then return "origin" end

    -- The first occupant of a tile keeps it; anyone who arrived on top of it
    -- is the one that has to move.
    for earlier = 1, index - 1 do
        if distance_squared(unit.location, units[earlier].location) < MIN_UNIT_SEPARATION_SQ then
            return "shared_tile"
        end
    end

    -- Prefer the game's own answer. ATacticalAreaVolume::IsActorInsideTacticalArea
    -- is what "out of bounds" means to the game; a radius around the authored
    -- destinations is only ever an approximation of it. York117's operators
    -- ended up under the map, which a distance test can easily call fine.
    -- The deployment lane is asked first, because the tactical volume is the
    -- wrong instrument for this question and three maps now prove it. It
    -- accepted SK_Serolonis_020's operator 906 uu outside the authored shape,
    -- in a rock, and Kaller 025's on the rocks at 6369/-1393. It describes
    -- the battlefield the fight happens on, not the lane the squad deploys
    -- into, so a conclusive "inside" from it is not evidence the operator can
    -- be commanded.
    if inside_deployment(polygon, unit.location) == false then return "off_lane" end

    if volume ~= nil then
        local inside = actor_inside_tactical_area(volume, unit.actor)
        if inside == false then return "outside_volume" end
        if inside == true then return nil end
    end

    local nearest = math.huge
    for _, anchor in ipairs(anchors) do
        nearest = math.min(nearest, distance_squared(unit.location, anchor))
    end
    if nearest > MAX_DESTINATION_DISTANCE_SQ then return "off_area" end
    return nil
end

-- Hard-invalid reasons are safe after control may have returned. Compute the
-- entire squad before moving anybody: restoring the first member of a broken
-- pair must not make the second member look valid halfway through the pass.
local function hard_strand_reasons(units, volume, polygon)
    local reasons = {}
    for index, unit in ipairs(units) do
        if at_world_origin(unit.location) then
            reasons[index] = "origin"
        else
            local shared_earlier, shared_any = false, false
            for other_index, other in ipairs(units) do
                if other_index ~= index
                    and distance_squared(unit.location, other.location)
                        < MIN_UNIT_SEPARATION_SQ then
                    shared_any = true
                    if other_index < index then shared_earlier = true end
                end
            end
            -- A normal shared tile has one valid first occupant. If the tile
            -- is also outside the authored lane, neither occupant has a
            -- defensible claim to it. Ordinary off-lane movement alone is
            -- intentionally not a hard late-watchdog reason.
            if shared_any and inside_deployment(polygon, unit.location) == false then
                reasons[index] = "stacked_off_lane"
            elseif shared_earlier then
                reasons[index] = "shared_tile"
            elseif volume ~= nil
                and actor_inside_tactical_area(volume, unit.actor) == false then
                reasons[index] = "outside_volume"
            end
        end
    end
    return reasons
end

-- The signatures an operator cannot have arrived at by playing. `off_lane`
-- and `off_area` are deliberately absent: after control returns they describe
-- an operator the player walked somewhere, and teleporting that operator back
-- into the deployment lane would be the mod breaking a working mission.
-- One table rather than three top-level locals: the main chunk is at Lua's
-- 200-local ceiling.
local REPAIR = {}
REPAIR.lane_fallback = {
    origin = true,
    shared_tile = true,
    stacked_off_lane = true,
    outside_volume = true,
}

-- How far outside the authored lane a staged snapshot may sit and still be
-- somewhere to put an operator back. Beyond this it is not the edge of the
-- deployment, it is a different place on the map.
--
-- The overflow operators the game stages just outside a four-point lane are
-- the normal case and must keep working: Sambuco's fifth and sixth on
-- HM_Kabb_010 sit 185 and 215 uu outside a lane 395 uu across. prorp's
-- HM_Kabb_020 logs are the failure -- the game stages that squad on a strip
-- 1470 to 1825 uu outside its lane, well inside the tactical volume, so every
-- snapshot was accepted and the repair spent the deployment hauling operators
-- back out to it.
--
-- 1000 uu is about one whole deployment lane: across the 89 authored areas
-- the widest destination pair spans a median of 1060 uu. A snapshot further
-- outside the lane than the lane is wide is not a staging position for it.
-- That leaves 4.6x headroom over Sambuco and rejects prorp by 1.5x.
REPAIR.max_staging_offset = 1000.0

-- The reason an operator can hold for a moment on its way somewhere legal.
-- MovePlayerUnitsIntoPosition walks the squad rather than teleporting it, and
-- an operator mid-walk is outside the authored lane exactly as a stranded one
-- is. A live 1.1.2 log caught the consequence: the post500 and post2000 rungs
-- repaired the same three operators 1.5 seconds apart, to identical targets
-- but from very different live positions, and the squad still came to rest at
-- Z 11 against staged targets of Z 60-99. Both repairs fought the walk and
-- neither stuck.
--
-- So these two reasons now require the operator to have settled -- the same
-- position as the previous pass -- before anything moves it. A genuinely
-- stranded operator does not move, so this costs a real failure nothing; the
-- hard signatures below are unaffected and still repair on first sight.
-- `off_lane` only. `off_area` means further than 2000 uu from every authored
-- destination, which is a relocation that went wrong rather than a walk in
-- progress -- no operator walks there -- so it is still repaired on sight.
REPAIR.soft_settle = {
    off_lane = true,
}
REPAIR.settled_radius_sq = 100.0
local observed_positions = {}

-- Undo a relocation that went wrong.
--
-- BP_CombatPreparationArea asks CalculateRushTargets_V2 for one target per
-- player unit and then moves everyone. With six operators it can return the
-- same target twice, or none at all, and the operator is left on a squadmate's
-- tile, at the world origin, or outside the deployment area. It can still
-- shoot and use abilities from there; it cannot move. That is every 1.0.5
-- report: two units at -12958/-20209 on MM_02_030, two at -25/-1112 on
-- HM_Jae_010, one at 0/0/261 on SK_Kaller_020.
--
-- The staged position is the first choice and stays the first choice: the
-- cooked levels author no spare TacticalPoint near the squad in 53 of 89
-- deployment areas, and none at all in the three maps above, so a staged
-- repair does not invent a position -- it returns the operator to one the
-- game itself put a unit on.
--
-- An operator with no staged position used to get nothing at all. That is
-- Darkened0Sky's whole mission: `staged=4` against six operators, and every
-- rung from post100 to watch3500 reporting `restored=0` with the two broken
-- operators listed as `:unstaged`. It is also Xywzel's, and it is what
-- `repairable=false` in the deployment_state line has been announcing since
-- 1.1.2 without being able to act on it.
--
-- remember_staged_position refuses to enshrine a position the tactical volume
-- rejects, which is correct and is exactly why those two operators have no
-- snapshot: they were already outside when the squad was staged. So the
-- fallback cannot come from the squad's own history. It comes from the
-- authored lane instead -- the same inset edge midpoints derive_rescue_points
-- has been placing operators on since 1.1.0, derived from the mission's own
-- destinations rather than from the ones this mod appended.
--
-- Deliberately narrow: it applies only to the hard-invalid signatures, never
-- to `off_lane` alone, so an operator the player has walked out of the lane
-- is never teleported back. The two-repair budget still applies.
local function repair_stranded_units(area, via, hard_only, ignore_budget)
    area = unwrap(area)
    if not valid(area) then return 0 end

    local units = every_player_unit()
    if #units < 1 then return 0 end

    local anchors = destination_anchors(area)
    if #anchors < 1 then return 0 end

    repair_passes = repair_passes + 1
    repair_units_seen = #units

    local volume = linked_tactical_area(area)
    local polygon = deployment_polygon(anchors)
    local hard_reasons = hard_only
        and hard_strand_reasons(units, volume, polygon) or {}

    -- Derived lazily: most passes find nothing to repair, and the ones that
    -- do usually have a staged position to repair to. The pool is built from
    -- the mission's own destinations, never from the ones this mod appended,
    -- because those are the positions the operator is stranded on.
    --
    -- Derived ignoring where the operators currently stand. By the time a
    -- repair rung runs, the rescue has usually already put operators on these
    -- very points, and deriving against live positions rejected every one of
    -- them -- which is why Harakiri's shared_tile operator read `:unstaged`
    -- on every rung with an empty pool behind it. Occupancy is still honored,
    -- just below, where a point can be skipped rather than never offered.
    -- The mission's own lane, derived once and shared by the fallback below
    -- and by the staged-position test above it.
    local authored_points, authored_lane, authored_built = nil, nil, false
    local function authored_shape()
        if not authored_built then
            authored_built = true
            authored_points = destination_anchors(area, true)
            authored_lane = deployment_polygon(authored_points)
        end
        return authored_lane, authored_points
    end

    -- How far outside the authored lane a point lies; 0 when it is inside or
    -- within the edge tolerance. nil when there is no lane to measure against,
    -- which leaves the caller to accept the point as it always has.
    local function lane_offset(point)
        local lane = authored_shape()
        if lane == nil or point == nil then return nil end
        if inside_deployment(lane, point) ~= false then return 0 end
        local nearest = math.huge
        for index = 1, #lane do
            nearest = math.min(nearest, distance_to_segment(
                point, lane[index], lane[index % #lane + 1]))
        end
        return nearest
    end

    local lane_pool, lane_pool_built = nil, false
    local function claim_lane_point(unit)
        if not lane_pool_built then
            lane_pool_built = true
            local lane, authored = authored_shape()
            if lane ~= nil then
                lane_pool = derive_rescue_points(
                    lane, authored, units, #units, true)
            end
        end
        if lane_pool == nil then return nil end
        -- Nearest free point, so two rescued operators do not cross paths and
        -- the shorter teleport is the one that happens.
        local best, best_index, best_distance = nil, nil, math.huge
        for index, point in ipairs(lane_pool) do
            local occupied = false
            for _, other in ipairs(units) do
                if xy_distance_squared(point, other.location)
                    < MIN_UNIT_SEPARATION_SQ then
                    occupied = true
                    break
                end
            end
            if not occupied then
                local distance = xy_distance_squared(point, unit.location)
                if distance < best_distance then
                    best, best_index, best_distance = point, index, distance
                end
            end
        end
        if best == nil then return nil end
        table.remove(lane_pool, best_index)
        return {location = {X = best.X, Y = best.Y, Z = best.Z}, rotation = nil}
    end

    -- Where each operator stood at the previous pass, captured before this
    -- pass moves anybody. A repaired operator therefore reads as "moved" on
    -- the following pass, which is the right answer: it has just been put
    -- somewhere and has not yet had a chance to settle there.
    local previous_positions = observed_positions
    observed_positions = {}
    for _, unit in ipairs(units) do
        observed_positions[unit.key] = copy_vector(unit.location)
    end

    local restored, stranded, reasons, moves = 0, 0, {}, {}
    for index, unit in ipairs(units) do
        local reason
        if hard_only then
            reason = hard_reasons[index]
        else
            reason = strand_reason(unit, index, units, anchors, volume, polygon)
        end
        if reason ~= nil then
            stranded = stranded + 1
            local moving = false
            if REPAIR.soft_settle[reason] then
                local previous = previous_positions[unit.key]
                moving = previous == nil
                    or distance_squared(previous, unit.location) >= REPAIR.settled_radius_sq
            end
            local staged, fallback, off_lane_staging = nil, false, false
            if not moving then
                staged = staged_positions[unit.key]
                -- A snapshot taken outside the authored lane is not a place to
                -- put anybody back. prorp's HM_Kabb_020 logs are the reported
                -- case: the game stages that squad on a strip around X=2200 to
                -- 2650, more than a thousand uu outside a lane that spans
                -- X=-200 to 1045, and the strip is inside the tactical volume,
                -- so remember_staged_position accepted all six. Two seconds
                -- after the game had correctly relocated the squad into the
                -- lane, post2000 moved four operators back out to it and
                -- called them restored -- seven such restorations across the
                -- run, every one of them undone by the game afterwards.
                --
                -- A position this mod deliberately chose is exempt: Cold
                -- Metal's authored rescue sits 513 uu outside its own
                -- deployment quadrilateral and is trusted on the evidence
                -- that the map spawns a player there.
                local offset = staged ~= nil and not staged.trusted
                    and lane_offset(staged.location) or nil
                if offset ~= nil and offset > REPAIR.max_staging_offset then
                    staged, off_lane_staging = nil, true
                end
                if staged == nil and REPAIR.lane_fallback[reason] then
                    staged = claim_lane_point(unit)
                    fallback = staged ~= nil
                end
            end
            local attempts = repair_counts[unit.key] or 0
            if moving then
                -- Still on its way. Say so rather than staying silent: a run
                -- of `:moving` across the whole ladder is the signature of a
                -- walk that never ends, which is worth seeing.
                reasons[#reasons + 1] = reason .. ":moving"
            elseif staged == nil then
                reasons[#reasons + 1] = reason
                    .. (off_lane_staging and ":off_lane_staging" or ":unstaged")
            elseif not ignore_budget and attempts >= MAX_REPAIRS_PER_UNIT then
                reasons[#reasons + 1] = reason .. ":exhausted"
            elseif distance_squared(staged.location, unit.location) < MIN_UNIT_SEPARATION_SQ then
                -- It is already standing where it was staged; something else
                -- is wrong and moving it there again would not help.
                reasons[#reasons + 1] = reason .. ":already_staged"
            else
                -- Never restore onto a tile another operator now holds; that
                -- would trade one shared tile for another.
                local blocked = false
                for other_index, other in ipairs(units) do
                    if other_index ~= index
                        and distance_squared(staged.location, other.location) < MIN_UNIT_SEPARATION_SQ then
                        blocked = true
                        break
                    end
                end
                if blocked then
                    reasons[#reasons + 1] = reason .. ":blocked"
                else
                    -- Take the return value, not just the absence of an
                    -- error. A teleport the engine declines returns false
                    -- and throws nothing, and a silent decline is how an
                    -- operator ends up somewhere nobody chose.
                    local moved, accepted = pcall(function()
                        return unit.actor:K2_SetActorLocationAndRotation(
                            staged.location, staged.rotation or {}, false, {}, true)
                    end)
                    if moved and accepted ~= false then
                        repair_counts[unit.key] = attempts + 1
                        restored = restored + 1
                        repair_restored_total = repair_restored_total + 1
                        reasons[#reasons + 1] = reason
                            .. (fallback and ":lane" or "")
                        moves[#moves + 1] = string.format("%.0f/%.0f/%.0f->%.0f/%.0f/%.0f",
                            unit.location.X, unit.location.Y, unit.location.Z,
                            staged.location.X, staged.location.Y, staged.location.Z)
                        unit.location = copy_vector(staged.location)
                    else
                        reasons[#reasons + 1] = reason .. ":refused"
                    end
                end
            end
        end
    end

    -- Report every pass that found something, up to a cap. A one-shot line
    -- would hide the case that matters most: a later rung fixing what an
    -- earlier one could not, or failing to.
    if stranded > 0 and repair_reported < MAX_REPAIR_REPORTS then
        repair_reported = repair_reported + 1
        local staged = 0
        for _, unit in ipairs(units) do
            if staged_positions[unit.key] ~= nil then staged = staged + 1 end
        end
        log("placement_repair via=" .. tostring(via or "?")
            .. " units=" .. tostring(#units)
            .. " staged=" .. tostring(staged)
            .. " stranded=" .. tostring(stranded)
            .. " restored=" .. tostring(restored)
            .. " reasons=" .. table.concat(reasons, ",")
            .. " moves=" .. table.concat(moves, ","))
    end
    return restored, stranded
end

-- Sambuco's two operators spawned at -80.6/40.8/-764.4, which is inside the
-- XY origin signature and is therefore correctly refused as a staged repair
-- target. His proven synchronous workaround used two different live squad
-- peers instead. Reproduce that only for the same tightly constrained shape:
-- two hard-invalid outliers, more than 2000 uu from every remaining distinct
-- operator, whose entire cluster is at most 1000 uu wide. The destinations
-- are occupied on purpose; this is an explicit command, not automatic repair.
local function manual_peer_rescue(area, units)
    local anchors = destination_anchors(area)
    if #anchors < 1 then return 0, "no_destinations" end
    local volume = linked_tactical_area(area)
    local polygon = deployment_polygon(anchors)
    local hard = hard_strand_reasons(units, volume, polygon)
    local bad, good = {}, {}
    for index, unit in ipairs(units) do
        if hard[index] ~= nil then
            bad[#bad + 1] = unit
        else
            good[#good + 1] = unit
        end
    end
    if #bad ~= 2 or #good ~= TARGET_SIZE - 2 then
        return 0, "shape hard=" .. tostring(#bad) .. " good=" .. tostring(#good)
    end

    for left = 1, #good do
        for right = left + 1, #good do
            local distance = distance_squared(good[left].location, good[right].location)
            if distance < MIN_UNIT_SEPARATION_SQ then
                return 0, "good_cluster_shared"
            end
            if distance > MANUAL_PEER_CLUSTER_RADIUS_SQ then
                return 0, "good_cluster_wide"
            end
        end
    end
    for _, outlier in ipairs(bad) do
        for _, peer in ipairs(good) do
            if distance_squared(outlier.location, peer.location)
                < MANUAL_PEER_OUTLIER_DISTANCE_SQ then
                return 0, "outlier_not_remote"
            end
        end
    end

    local originals, rotations, moved, moves = {}, {}, {}, {}
    for index, outlier in ipairs(bad) do
        local target = good[index].location
        originals[index] = copy_vector(outlier.location)
        rotations[index] = actor_rotation(outlier.actor) or {}
        local call_ok, accepted = pcall(function()
            return outlier.actor:K2_SetActorLocationAndRotation(
                target, rotations[index], false, {}, true)
        end)
        local actual = actor_location(outlier.actor)
        if not call_ok or accepted == false or actual == nil
            or distance_squared(actual, target) >= MIN_UNIT_SEPARATION_SQ then
            for rollback = 1, #moved do
                pcall(function()
                    bad[rollback].actor:K2_SetActorLocationAndRotation(
                        originals[rollback], rotations[rollback], false, {}, true)
                end)
            end
            return 0, "teleport_refused"
        end
        moved[index] = true
        outlier.location = copy_vector(actual)
        moves[#moves + 1] = string.format(
            "%.0f/%.0f/%.0f->%.0f/%.0f/%.0f",
            originals[index].X, originals[index].Y, originals[index].Z,
            actual.X, actual.Y, actual.Z)
    end
    repair_restored_total = repair_restored_total + #moved
    return #moved, nil, table.concat(moves, ",")
end

-- BP_CombatPreparationArea gathers only PlayerDestinations and then asks
-- CalculateRushTargets_V2 for one result per player unit. Several maps author
-- only four destinations. Units five and six are initially in a valid spawn
-- area, but the later combat-prep relocation receives no valid targets for
-- them and can send them to an invalid/default location. Preserve those safe
-- initial positions as real, distinct TacticalPoint destinations before the
-- relocation is calculated.
--
-- Every destination added here is a position a player unit is already
-- standing on. Nothing is extrapolated or interpolated, because a synthesised
-- point has no navigation check behind it and can land inside terrain.
local function ensure_player_destinations(area)
    area = unwrap(area)
    if not valid(area) then return false end

    local area_key = full_name(area)
    if area_key == "" then return false end

    local list_ok, destinations = pcall(function()
        return area:GetPropertyValue(DESTINATIONS_PROPERTY)
    end)
    if not list_ok or destinations == nil then return false end

    local raw_count = array_count(destinations)
    if raw_count < 0 then return false end

    local valid_destinations = {}
    local anchors = {}
    for index = 1, raw_count do
        local point = unwrap(destinations[index])
        local location = valid(point) and actor_location(point) or nil
        if location ~= nil then
            valid_destinations[#valid_destinations + 1] = {
                actor = point,
                location = copy_vector(location),
            }
            anchors[#anchors + 1] = copy_vector(location)
        end
    end
    if #valid_destinations < 1 then return false end

    -- 1.0.4 asked for six destinations unconditionally, and TriggerPreCombat
    -- can fire before the squad is populated. On a two-unit tutorial that
    -- added two destinations the mission never authored, and the relocation
    -- pass then moved an authored unit onto one of them, leaving it short of
    -- the action points the script expects. A squad we cannot read is a squad
    -- we do not touch; the bounded retries at the hook site run again once it
    -- is populated.
    -- Run exact map-profile rescues before the proximity-filtered squad read.
    -- The Kaller report's sixth operator was at 0/0, more than 2000 uu from
    -- every destination, so the old order filtered it out before the rescue
    -- code could ever see it.
    local staging_rescued, rescued_positions = rescue_known_staging(
        valid_destinations, linked_tactical_area(area))

    local members, stats = player_squad_members(area, anchors)
    last_member_stats = stats
    if members == nil or #members < 1 then return false end
    -- Ask for one destination per operator in the squad, not one per operator
    -- that happened to pass the proximity filter. On MM_02_030 the filter read
    -- five of six (near=5 raw=6), so the first pass -- the only pass
    -- guaranteed to run before the game relocates anybody -- settled for five
    -- destinations and stopped. The filter still decides which positions are
    -- safe to reuse; it no longer decides how many are needed.
    local squad_size = stats.squad_size or #members
    if squad_size < #members then squad_size = #members end
    local desired = math.min(squad_size, TARGET_SIZE)

    if #valid_destinations >= desired then
        return false
    end

    -- Prefer current unit positions furthest from an authored destination.
    -- This naturally chooses the two overflow units on maps where the stock
    -- four are already standing on their four authored points.
    local candidates = {}
    for _, member in ipairs(members) do
        -- A conclusive tactical-volume rejection is stronger than proximity.
        -- In particular, 0/0 on Cold Metal is less than 2000 uu from an
        -- authored point, so the old distance-only filter accepted the hill.
        if member.inside_volume ~= false then
            local nearest = math.huge
            for _, destination in ipairs(valid_destinations) do
                nearest = math.min(nearest,
                    distance_squared(member.location, destination.location))
            end
            local rescued = false
            for _, placed in ipairs(rescued_positions or {}) do
                if xy_distance_squared(member.location, placed)
                    <= MIN_UNIT_SEPARATION_SQ then
                    rescued = true
                    break
                end
            end
            candidates[#candidates + 1] = {
                location = member.location,
                rotation = member.rotation,
                nearest = nearest,
                rescued = rescued,
            }
        end
    end
    -- Positions this pass deliberately moved inside the lane are the safest
    -- destination additions available, so consume them first. Without this,
    -- the generic rescue moved the two candidates nearest its targets and the
    -- furthest two untouched staging-strip positions won the descending sort
    -- below, becoming the actual destinations instead.
    table.sort(candidates, function(left, right)
        if left.rescued ~= right.rescued then return left.rescued end
        return left.nearest > right.nearest
    end)

    local template = valid_destinations[1].actor
    local class_ok, point_class = pcall(function() return template:GetClass() end)
    local world_ok, world = pcall(function() return area:GetWorld() end)
    if not class_ok or not world_ok or not valid(point_class) or not valid(world) then return false end

    local team = nil
    pcall(function() team = unwrap(template:GetPropertyValue(PLAYER_TEAM_PROPERTY)) end)

    local lane_points = {}
    for _, destination in ipairs(valid_destinations) do
        lane_points[#lane_points + 1] = destination.location
    end
    local lane = deployment_polygon(lane_points)

    -- Darkened0Sky's Lothal crisis: four authored points, six operators, and
    -- both additions taken from positions outside the authored lane. Two
    -- operators deployed where the tactical volume went on to refuse them,
    -- and neither could be commanded again -- `outside_lane=2` in the
    -- expansion line, then `outside_volume:unstaged restored=0` on every
    -- repair rung.
    --
    -- Cold Metal is the case that says an off-lane position is not
    -- automatically wrong. One of its two additions is a position this pass
    -- deliberately rescued into the lane; the other sits 605 uu outside a
    -- quadrilateral that understates the map's real deployment area, and has
    -- never been reported as stuck. So the discriminator is not "this
    -- candidate is off-lane". It is "every position this pass is about to
    -- add is off-lane, and not one of them was rescued there" -- no evidence
    -- left that the authored lane is wider than its four points. Cold Metal
    -- keeps a trusted addition and keeps its behaviour; Darkened0Sky's had
    -- none, and gets interior points derived from the authored shape instead.
    --
    -- Derived points are prepended rather than substituted. If the lane
    -- yields fewer than are needed, the original candidates still get their
    -- turn: an operator with a destination somewhere is better off than an
    -- operator the game never assigned one to.
    local missing = desired - #valid_destinations
    if lane ~= nil and missing > 0 and #candidates > 0 then
        local considered, off_lane_only = 0, true
        for _, candidate in ipairs(candidates) do
            if considered >= missing then break end
            local nearest = math.huge
            for _, destination in ipairs(valid_destinations) do
                nearest = math.min(nearest,
                    distance_squared(candidate.location, destination.location))
            end
            if nearest >= MIN_DESTINATION_SEPARATION_SQ
                and nearest <= MAX_DESTINATION_DISTANCE_SQ then
                considered = considered + 1
                if candidate.rescued
                    or inside_deployment(lane, candidate.location) ~= false then
                    off_lane_only = false
                    break
                end
            end
        end
        if considered > 0 and off_lane_only then
            local derived = derive_rescue_points(lane, lane_points, members, missing)
            local preferred = {}
            for _, point in ipairs(derived) do
                preferred[#preferred + 1] = {
                    location = {X = point.X, Y = point.Y, Z = point.Z},
                    rotation = nil,
                    nearest = point.clearance or 0,
                    rescued = true,
                    derived = true,
                }
            end
            for _, candidate in ipairs(candidates) do
                preferred[#preferred + 1] = candidate
            end
            candidates = preferred
        end
    end

    local added, outside_lane, derived_added = 0, 0, 0
    for _, candidate in ipairs(candidates) do
        if #valid_destinations >= desired then break end

        local nearest = math.huge
        for _, destination in ipairs(valid_destinations) do
            nearest = math.min(nearest, distance_squared(candidate.location, destination.location))
        end
        -- Count, but do not reject, a position outside the authored lane.
        -- Rescued positions are explicitly consumed first, so a four-to-six
        -- expansion that produced two safe interior points finishes before an
        -- untouched staging-strip position can become a destination.
        --
        -- Rejecting here as well would cost more than it saves. Cold Metal's
        -- second overflow operator stages 605 uu outside its quadrilateral,
        -- next to the map's own skirmish-intro capsule, and has never been
        -- reported as stuck -- four authored points understate that map's
        -- real deployment area. Refusing it a destination would take away a
        -- working position and give nothing back. The count makes the case
        -- visible in a log instead of guessing at it.
        if lane ~= nil and inside_deployment(lane, candidate.location) == false then
            local trusted = false
            for _, placed in ipairs(rescued_positions or {}) do
                if xy_distance_squared(candidate.location, placed)
                    <= MIN_UNIT_SEPARATION_SQ then
                    trusted = true
                    break
                end
            end
            if not trusted then outside_lane = outside_lane + 1 end
        end
        if nearest >= MIN_DESTINATION_SEPARATION_SQ
            and nearest <= MAX_DESTINATION_DISTANCE_SQ then
            local spawn_ok, point = pcall(function()
                return world:SpawnActor(point_class, candidate.location, candidate.rotation or {})
            end)
            if spawn_ok and valid(point) then
                if team ~= nil then
                    pcall(function() point[PLAYER_TEAM_PROPERTY] = team end)
                end
                -- 1.0.5 accepted any call that did not throw. A teleport the
                -- engine declines returns false silently, leaving the point
                -- at the origin it was spawned at -- which is where
                -- EvilPoptart1987's fifth operator was found, at 0/0/261.
                local moved, accepted = pcall(function()
                    return point:K2_SetActorLocationAndRotation(
                        candidate.location, candidate.rotation or {}, false, {}, true)
                end)
                moved = moved and accepted ~= false
                    and not at_world_origin(actor_location(point) or candidate.location)
                local append_ok = moved and pcall(function()
                    destinations[raw_count + 1] = point
                end)
                if append_ok then
                    raw_count = raw_count + 1
                    added = added + 1
                    if candidate.derived then derived_added = derived_added + 1 end
                    synthesised_destinations[object_key(point)] = true
                    valid_destinations[#valid_destinations + 1] = {
                        actor = point,
                        location = copy_vector(candidate.location),
                    }
                else
                    pcall(function() point:K2_DestroyActor() end)
                end
            end
        end
    end

    if added > 0 and not destination_expansion_reported then
        destination_expansion_reported = true
        log("player_destinations=" .. tostring(#valid_destinations - added)
            .. "->" .. tostring(#valid_destinations)
            .. " squad_members=" .. tostring(#members)
            .. " added_safe_points=" .. tostring(added)
            .. " derived_points=" .. tostring(derived_added)
            .. " outside_lane=" .. tostring(outside_lane)
            .. " staging_rescued=" .. tostring(staging_rescued)
            .. " " .. member_stats_text(stats))
    end
    return added > 0
end

local function placement_state(area)
    area = unwrap(area)
    if not valid(area) then return -1, -1, -1 end

    local list_ok, destinations = pcall(function()
        return area:GetPropertyValue(DESTINATIONS_PROPERTY)
    end)
    if not list_ok or destinations == nil then return -1, -1, -1 end

    local raw_count = array_count(destinations)
    local valid_count = 0
    local anchors = {}
    for index = 1, raw_count do
        local point = unwrap(destinations[index])
        if valid(point) then
            valid_count = valid_count + 1
            local location = actor_location(point)
            if location ~= nil then anchors[#anchors + 1] = copy_vector(location) end
        end
    end

    local members, stats = player_squad_members(area, anchors)
    last_member_stats = stats
    local member_count = members ~= nil and #members or -1
    return member_count, raw_count, valid_count
end

-- The stock lineup diorama has four authored attachment slots. ShowLineup
-- iterates every selected character and clones every proxy actor, but its Set
-- Diorama Slot calls cannot place indexes 4 and 5. Reuse the four authored
-- positions and extrapolate along the same row so a five- or six-model lineup
-- stays centred and keeps character/nameplate order from left to right.
--
-- A four-model lineup is left exactly where the Blueprint put it. 1.0.4
-- applied the six-wide layout unconditionally, which on every four-slot
-- mission pushed each model one slot away from its own name plate and parked
-- a stale full-scale proxy outside the diorama.
-- Returns the layout, or nil plus a short reason for the log. The reason is
-- what makes a report decisive: it says whether a lineup was left alone
-- because the pool was unplaced or because something else refused.
local function capture_authored_layout(actors)
    local locations, rotations = {}, {}
    for index = 1, AUTHORED_SLOTS do
        locations[index] = actor_location(actors[index])
        rotations[index] = actor_rotation(actors[index])
        if locations[index] == nil or rotations[index] == nil then
            return nil, "unreadable_transform"
        end
    end

    -- The one condition the reports evidence: an unplaced pool has its slots
    -- sitting on top of each other.
    for index = 1, AUTHORED_SLOTS - 1 do
        if distance_squared(locations[index], locations[index + 1]) < MIN_SLOT_SEPARATION_SQ then
            return nil, "coincident_slots"
        end
    end

    -- Each proxy carries its own character's scale, so this is not compared
    -- across the row. It is only copied onto the overflow proxies, which the
    -- Blueprint never places and therefore never scales.
    local overflow_scale = actor_scale(actors[AUTHORED_SLOTS])
    if overflow_scale == nil then return nil, "unreadable_scale" end

    local locations_copy, rotations_copy = {}, {}
    for index = 1, AUTHORED_SLOTS do
        locations_copy[index] = copy_vector(locations[index])
        rotations_copy[index] = copy_rotator(rotations[index])
    end
    return {
        locations = locations_copy,
        rotations = rotations_copy,
        overflow_scale = copy_vector(overflow_scale),
        step = {
            X = (locations[AUTHORED_SLOTS].X - locations[1].X) / (AUTHORED_SLOTS - 1),
            Y = (locations[AUTHORED_SLOTS].Y - locations[1].Y) / (AUTHORED_SLOTS - 1),
            Z = (locations[AUTHORED_SLOTS].Z - locations[1].Z) / (AUTHORED_SLOTS - 1),
        },
    }
end

-- allow_capture is false in the pre-hook, where the pool has not been placed
-- yet and only an already-validated layout may be reapplied.
local function place_lineup_models(owner, proxies, used, allow_capture)
    local proxy_count = array_count(proxies)
    if proxy_count < AUTHORED_SLOTS then return false, "short_pool" end

    local actors = {}
    for index = 1, math.min(proxy_count, TARGET_SIZE) do
        actors[index] = unwrap(proxies[index])
    end
    for index = 1, AUTHORED_SLOTS do
        if not valid(actors[index]) then return false, "invalid_proxy" end
    end

    local layout_key = object_key(owner)
    if layout_key == "" then return false, "no_owner_key" end

    -- Capture at most once per manager. After the first pass has moved the
    -- proxies, an authored row and a row this mod already shifted look alike:
    -- both are evenly spaced with the same step. Re-deriving would therefore
    -- shift the lineup one slot further left on every pass, which is the
    -- cumulative Edit Squad drift fixed in 1.0.0. The 1.0.5 validation is what
    -- makes the single capture trustworthy; 1.0.4 cached whatever it saw.
    local captured, reason = nil, nil
    if allow_capture and used >= AUTHORED_SLOTS
        and lineup_layouts[layout_key] == nil then
        captured, reason = capture_authored_layout(actors)
        if captured ~= nil then lineup_layouts[layout_key] = captured end
    end

    if used <= AUTHORED_SLOTS then return false, "authored_width" end
    local layout = captured or lineup_layouts[layout_key]
    if layout == nil then return false, reason or "no_layout" end

    -- Validate the whole row before moving any of it. A short pool must leave
    -- the lineup as the Blueprint left it rather than half-relaid out.
    for index = 1, used do
        if not valid(actors[index]) then return false, "invalid_overflow_proxy" end
    end

    -- Fit the row into the space the game framed, rather than growing past
    -- it. Up to 1.0.6 the overflow straddled the authored row -- six models
    -- spanned 225 uu where the authored four span 135 -- and the outer two
    -- were kept on screen by widening every camera in the world by 22
    -- degrees. That widening was never scoped and never restored, so it also
    -- widened the Appearance/Outfits camera, whose zoom is driven by moving
    -- the camera rather than by field of view: the editor zoomed out much too
    -- far and would not zoom in past full body. Squad select and the editor
    -- share this stage -- these proxies are the manager's customization proxy
    -- actors -- so the fix is to stop needing the camera at all.
    --
    -- The step shrinks by exactly the ratio of the gaps, so whatever the
    -- width the outermost two models land on the authored outer slots: six
    -- models step 27 uu where four step 45, and both rows span -68..67.
    local fit = (AUTHORED_SLOTS - 1) / (used - 1)
    local centre_offset = (used - 1) / 2.0
    -- The authored row's own centre, so the fitted row stays concentric with
    -- it instead of being anchored to slot one.
    local centre = {
        X = (layout.locations[1].X + layout.locations[AUTHORED_SLOTS].X) / 2.0,
        Y = (layout.locations[1].Y + layout.locations[AUTHORED_SLOTS].Y) / 2.0,
        Z = (layout.locations[1].Z + layout.locations[AUTHORED_SLOTS].Z) / 2.0,
    }
    for index = 1, used do
        local actor = actors[index]
        local offset = ((index - 1) - centre_offset) * fit
        local location = {
            X = centre.X + layout.step.X * offset,
            Y = centre.Y + layout.step.Y * offset,
            Z = centre.Z + layout.step.Z * offset,
        }
        -- Where this model sits along the authored row, so it takes the
        -- rotation of the authored slot it stands closest to.
        local authored_index = 1 + (index - 1) * fit
        local nearest = math.max(1, math.min(AUTHORED_SLOTS,
            math.floor(authored_index + 0.5)))
        -- Each proxy keeps its own character's scale, reduced by the same
        -- ratio as the step so the models close up without overlapping. The
        -- base is re-read whenever the Blueprint has put a new scale on the
        -- actor -- swapping an operator into a slot brings that character's
        -- own scale with it, and a base cached once for the manager would
        -- keep showing the previous occupant's size. It is only reused when
        -- the actor still carries exactly what this mod last wrote, which is
        -- what stops the fit compounding into a row that shrinks a little on
        -- every pass. The Blueprint never places proxies past the authored
        -- four, so those take slot four's scale as their base, as always.
        local actor_key = object_key(actor)
        local record = fitted_scales[actor_key]
        local live = actor_scale(actor)
        local base
        if record ~= nil and scales_match(live, record.applied) then
            base = record.base
        elseif index <= AUTHORED_SLOTS and live ~= nil then
            base = live
        else
            base = (record ~= nil and record.base) or layout.overflow_scale
        end
        local scale = {X = base.X * fit, Y = base.Y * fit, Z = base.Z * fit}
        local moved = pcall(function()
            actor:SetActorScale3D(scale)
            actor:K2_SetActorLocationAndRotation(
                location, layout.rotations[nearest], false, {}, true)
        end)
        if not moved then return false, "move_failed" end
        if actor_key ~= "" then
            fitted_scales[actor_key] = {
                base = copy_vector(base),
                applied = copy_vector(scale),
            }
        end
    end
    return true, "applied"
end

local function activity_slot_character(slot)
    slot = unwrap(slot)
    if slot == nil then return false, nil end

    -- This inherited generated-class field is reliable through direct access;
    -- GetPropertyValue alone returned nil for all six slots in 1.0.3.
    local direct_ok, character = pcall(function()
        return slot[ACTIVITY_CHARACTER_PROPERTY]
    end)
    if direct_ok then return true, unwrap(character) end

    local getter_ok, fallback = pcall(function()
        return slot:GetPropertyValue(ACTIVITY_CHARACTER_PROPERTY)
    end)
    if getter_ok then return true, unwrap(fallback) end
    return false, nil
end

-- Hide every proxy the current lineup does not use: the ones past the incoming
-- slot count, and the ones whose slot holds no character. 1.0.4 bailed out
-- unless the incoming count was exactly six, so a four-slot mission kept the
-- previous lineup's fifth and sixth models on screen next to four name plates.
local function trim_lineup_proxies(activity_slots, proxies, owner_key, used)
    activity_slots = unwrap(activity_slots)
    proxies = unwrap(proxies)
    local proxy_count = array_count(proxies)
    if proxy_count < 1 then return 0 end

    -- Never repeat the 1.0.3 failure mode: reflection must positively resolve
    -- every incoming slot, and find at least one occupant, before an occupied
    -- proxy may be hidden. Otherwise only the surplus indexes are touched.
    local assignments = nil
    local known, assigned = 0, 0
    local read = {}
    for index = 1, used do
        local read_ok, character = activity_slot_character(activity_slots[index])
        if read_ok then
            known = known + 1
            read[index] = valid(character)
            if read[index] then assigned = assigned + 1 end
        end
    end
    -- 1.0.4 required four positively resolved occupants before hiding
    -- anything inside the used range. Keep that margin rather than the
    -- weaker "at least one" test.
    if known == used and assigned >= math.min(used, AUTHORED_SIZE) then
        assignments = read
    end

    local hidden_here = proxies_hidden_by_mod[owner_key]
    if hidden_here == nil then
        hidden_here = {}
        proxies_hidden_by_mod[owner_key] = hidden_here
    end

    local hidden = 0
    for index = 1, proxy_count do
        local actor = unwrap(proxies[index])
        if valid(actor) then
            local wanted = index <= used
                and (assignments == nil or assignments[index] == true)
            if not wanted then
                if pcall(function() actor:SetActorHiddenInGame(true) end) then
                    hidden_here[index] = true
                    hidden = hidden + 1
                end
            elseif hidden_here[index] then
                -- Only ever unhide a proxy this mod hid.
                if pcall(function() actor:SetActorHiddenInGame(false) end) then
                    hidden_here[index] = nil
                end
            end
        end
    end
    return hidden
end

-- One lineup pass: lay the models out and hide the ones this lineup does not
-- use. Idempotent, so it is safe to run from the pre-hook, the post-hook and a
-- deferred tick, and it needs to be: 1.0.4 did this work only in the pre-hook,
-- and moving it to the post-hook alone left operators 5 and 6 unplaced.
--
-- `source` and the deduplicated result line are what make a report decisive
-- about which of those three paths actually did the work.
-- Describes the pool as it stands before this pass touches it. This used to
-- live in the post-hook, which meant it was never logged at all: UE4SS
-- registers script hooks with one id for both halves and only calls the
-- pre-hook, so no report could ever show the proxy positions or scales.
-- Diagnostics only: this builds the before_positions/before_scales text and
-- nothing else. It crashed the game anyway, twice on one install.
--
-- `GetClonedFromCharacter` is declared with parameters -- the cooked
-- Blueprint calls it as an EX_LocalVirtualFunction with a Parameters list --
-- and this called it with none. UE4SS answers that with
-- "[UFunction::setup_metamethods -> __call] UFunction expected {} parameters,
-- received {}", and then access-violates inside its own error formatting. The
-- surrounding pcall never had a chance: UE4SS raises in C++ and dies building
-- the message, before Lua sees an error to catch. Two live crash reports have
-- that exact frame (`UFunction __call` under `TArray:ForEach`), and the
-- `cloned_proxies=` counter it fed read 0 in every log line it ever produced.
-- The call is gone and the field with it.
--
-- The `ForEach` is gone too, in favour of the indexed read the rest of this
-- file uses. It is a second UE4SS path that raises on its own terms -- "Tried
-- iterating an array but the unreal property has no registered handler" --
-- and reaching it costs the same crash. Nothing here is worth a crash.
local function describe_proxies(proxies, proxy_count)
    local counts = {valid = 0, hidden = 0}
    local positions, scales = {}, {}
    if proxies == nil or proxy_count < 1 then return counts, positions, scales end
    for index = 1, proxy_count do
        local read_ok, element = pcall(function() return proxies[index] end)
        local actor = read_ok and unwrap(element) or nil
        if valid(actor) then
            counts.valid = counts.valid + 1
            local hidden_ok, hidden = pcall(function() return actor:IsHidden() end)
            if hidden_ok and hidden then counts.hidden = counts.hidden + 1 end
            local location = actor_location(actor)
            positions[#positions + 1] = location ~= nil
                and string.format("%.0f/%.0f/%.0f", location.X, location.Y, location.Z)
                or "?/?/?"
            local scale = actor_scale(actor)
            scales[#scales + 1] = scale ~= nil
                and string.format("%.3f/%.3f/%.3f", scale.X, scale.Y, scale.Z)
                or "?/?/?"
        end
    end
    return counts, positions, scales
end

local function run_lineup_pass(owner, activity_slots_param, used, source)
    if not valid(owner) then return end
    if used == nil or used < 1 then return end
    if used > TARGET_SIZE then used = TARGET_SIZE end

    local owner_key = object_key(owner)
    local proxies = proxy_array(owner)
    local proxy_count = array_count(proxies)
    -- Described before the pass touches anything, because the result is only
    -- known afterwards and the key includes it. The first pass legitimately
    -- refuses an unplaced pool; keying on source alone hid whether a later
    -- pass ever succeeded, which is why a verified log showed only refusals.
    local counts, positions, scales = describe_proxies(proxies, proxy_count)

    local applied, result = place_lineup_models(owner, proxies, used, true)
    local trimmed = trim_lineup_proxies(activity_slots_param, proxies, owner_key, used)


    local report_key = source .. ":" .. tostring(used) .. ":" .. tostring(result)
    if not reported_layout_results[report_key] then
        reported_layout_results[report_key] = true
        log("lineup source=" .. source
            .. " used=" .. tostring(used)
            .. " layout=" .. tostring(result)
            .. " applied=" .. tostring(applied)
            -- The ratio the row was closed up by, so a report says whether
            -- the models were fitted into the authored span or left alone.
            .. " fit=" .. (used > AUTHORED_SLOTS
                and string.format("%.2f", (AUTHORED_SLOTS - 1) / (used - 1))
                or "1.00")
            .. " hidden_by_mod=" .. tostring(trimmed)
            .. " proxies=" .. tostring(proxy_count)
            .. " valid_proxies=" .. tostring(counts.valid)
            .. " hidden_proxies=" .. tostring(counts.hidden)
            .. " before_positions=" .. table.concat(positions, ",")
            .. " before_scales=" .. table.concat(scales, ","))
    end
end

-- Pre-hook. The pool must hold six actors before the Blueprint starts cloning.
-- The layout also runs here, which is where 1.0.4 ran it and where six models
-- demonstrably appeared: on the first pass the pool is unplaced and the
-- capture is refused, and on every later pass the proxies still carry the
-- transforms the Blueprint gave them last time. The capture validation added
-- in 1.0.5 is what makes reading them here safe.
local function lineup_prehook(context, activity_slots_param, clear_previous_param)
    local owner = unwrap(context)
    if not valid(owner) then return end

    local expanded = ensure_proxy_pool(owner)
    local owner_key = object_key(owner)
    if expanded and not lineup_reentry[owner_key] then
        lineup_reentry[owner_key] = true
        local clear_previous = unwrap(clear_previous_param)
        if type(clear_previous) ~= "boolean" then clear_previous = false end
        local replay_ok = pcall(function()
            owner:ShowLineupHologramActors(activity_slots_param, clear_previous)
        end)
        lineup_reentry[owner_key] = nil
        log("lineup_replayed_after_proxy_expand=" .. tostring(replay_ok))
        return
    end

    -- Read the width here and remember it. The pre-hook parameter is the one
    -- 1.0.4 read successfully on every report; the post-hook's copy is not
    -- proven, and a width of -1 there would silently skip the whole pass.
    local used = array_count(activity_slots_param)
    if used >= 0 then lineup_widths[owner_key] = used end

    -- Never let the deferred closure retain activity_slots_param itself. The
    -- crash dump from 1.1.0 records "TArray index out of range" at unwrap()
    -- after source=pre and before source=deferred, which is the exact lifetime
    -- failure produced by reading a hook-owned RemoteParam after return.
    local activity_slots_snapshot = snapshot_array(activity_slots_param, used)
    run_lineup_pass(owner, activity_slots_snapshot, used, "pre")

    -- The Blueprint places the authored slots during the call this hook
    -- precedes. Running once more on the next tick captures that fresh row
    -- even if the post-hook never fires or arrives with an unusable parameter.
    ExecuteWithDelay(0, function()
        ExecuteInGameThread(function()
            if not valid(owner) then return end
            run_lineup_pass(owner, activity_slots_snapshot,
                lineup_widths[owner_key], "deferred")
        end)
    end)
end

-- Post-hook. UE4SS registers script hooks with a single id for both halves
-- and, on the build this mod targets, never calls this one -- a verified run
-- logs source=pre and source=deferred and no source=post. It is kept because
-- it is the correct place for the work and costs nothing when it does not
-- fire; the pre-hook and the deferred tick are what carry the layout.
local function lineup_posthook(context, activity_slots_param, clear_previous_param)
    local owner = unwrap(context)
    if not valid(owner) then return end

    local owner_key = object_key(owner)
    if lineup_reentry[owner_key] then return end

    -- Fall back to the width the pre-hook read if this parameter is unusable.
    local used = array_count(activity_slots_param)
    if used < 1 then used = lineup_widths[owner_key] or 0 end
    run_lineup_pass(owner, snapshot_array(activity_slots_param, used), used, "post")
end

local function squad_slot_box()
    local boxes = FindAllOf(SLOT_BOX_CLASS)
    if boxes == nil then return nil end
    for _, box in pairs(boxes) do
        local name = full_name(box)
        if string.find(name, "WBP_Menu_MissionSquadSelect", 1, true)
            and string.find(name, "CharacterSlots", 1, true) then
            return box
        end
    end
    return nil
end

-- Read-only. Up to 1.0.6 the mod widened the field of view of every active
-- CameraComponent in the world and logged nothing about it, so the log that
-- was meant to settle a camera report could not: the report of a broken
-- Appearance/Outfits zoom had to be diagnosed from the source instead. This
-- writes nothing and only records what the cameras are. Logged once per tag,
-- so comparing the squad_select line against the customization line says
-- whether the two screens share one camera object or hold their own.
local function camera_census(tag)
    if camera_census_reported[tag] then return end
    local cameras = FindAllOf("CameraComponent")
    if cameras == nil then return end

    local seen = {}
    for _, camera in pairs(cameras) do
        local active_ok, active = pcall(function() return camera:IsActive() end)
        if active_ok and active and #seen < CAMERA_CENSUS_LIMIT then
            local read_ok, fov = pcall(function()
                return unwrap(camera:GetPropertyValue("FieldOfView"))
            end)
            -- The short name identifies the rig, the address identifies the
            -- object; both are needed to tell one rig reused from two rigs
            -- that happen to be named alike.
            local name = full_name(camera)
            local short = string.match(name, "([^%.:/]+)$") or "?"
            seen[#seen + 1] = short
                .. "@" .. object_key(camera)
                .. "=" .. (read_ok and type(fov) == "number"
                    and string.format("%.1f", fov) or "?")
        end
    end

    if #seen < 1 then return end
    camera_census_reported[tag] = true
    log("cameras source=" .. tag .. " active=" .. tostring(#seen)
        .. " " .. table.concat(seen, ","))
end

local function fit_squad_screen(box)
    if not valid(box) then return end
    local box_key = object_key(box)
    if box_key == "" then return end
    local first_fit = not fitted_slot_boxes[box_key]
    local transform_ok = true
    local spacing_ok = true
    if first_fit then
        transform_ok = pcall(function()
            box:SetRenderTransformPivot({X = 0.5, Y = 0.5})
            box:SetRenderScale({X = 1.0, Y = 1.0})
            box:SetRenderTranslation({X = 0.0, Y = 0.0})
        end)
        spacing_ok = pcall(function()
            box:SetEntrySpacing({X = -100.0, Y = 0.0})
        end)
        if not spacing_ok then
            spacing_ok = pcall(function()
                box:SetPropertyValue("EntrySpacing", {X = -100.0, Y = 0.0})
            end)
        end
        if transform_ok then
            fitted_slot_boxes[box_key] = true
            if not layout_reported then
                layout_reported = true
                log("character_slot_entry_spacing=" .. tostring(spacing_ok))
            end
        end
    end

    camera_census("squad_select")
end

local function report_slot_widget_state()
    if slot_widget_reported then return end

    local widget_count = 0
    local widgets = FindAllOf("WBP_CharacterSlot_C")
    if widgets ~= nil then
        for _, widget in pairs(widgets) do
            local name = full_name(widget)
            if valid(widget)
                and string.find(name, "Engine/Transient", 1, true)
                and string.find(name, "WBP_Menu_MissionSquadSelect", 1, true) then
                widget_count = widget_count + 1
            end
        end
    end

    local activity_vm_count = -1
    local lists = FindAllOf("VM_ActivitySlotList_C")
    if lists ~= nil then
        for _, list in pairs(lists) do
            local name = full_name(list)
            if valid(list) and string.find(name, "Engine/Transient", 1, true) then
                local read_ok, slots = pcall(function()
                    return list:GetPropertyValue("ActivitySlots")
                end)
                if read_ok then
                    activity_vm_count = math.max(activity_vm_count, array_count(slots))
                end
            end
        end
    end

    if widget_count > 0 then
        slot_widget_reported = true
        log("slot_widgets=" .. tostring(widget_count)
            .. " activity_slot_vms=" .. tostring(activity_vm_count))
    end
end

local function register_layout_notification()
    if registered_layout_notification then return end
    local ok = pcall(function()
        NotifyOnNewObject(SLOT_BOX_CLASS_PATH, function(box)
            local candidate = unwrap(box)
            local name = full_name(candidate)
            if not string.find(name, "WBP_Menu_MissionSquadSelect", 1, true)
                or not string.find(name, "CharacterSlots", 1, true) then
                return
            end
            local delays = {100, 250, 750, 1500}
            for attempt = 1, #delays do
                local delay = delays[attempt]
                ExecuteWithDelay(delay, function()
                    ExecuteInGameThread(function()
                        fit_squad_screen(candidate)
                        report_slot_widget_state()
                    end)
                end)
            end
        end)
    end)
    registered_layout_notification = ok
    log("layout_notification=" .. tostring(registered_layout_notification))
end

local function prepare_hologram_manager(manager)
    manager = unwrap(manager)
    if not valid(manager) then return end
    local manager_key = object_key(manager)
    if manager_key ~= "" then
        lineup_layouts[manager_key] = nil
        proxies_hidden_by_mod[manager_key] = nil
        lineup_widths[manager_key] = nil
        -- Keyed by proxy actor, not by manager, so it is dropped wholesale: a
        -- new manager brings a new pool and the bases are re-read from
        -- whatever the Blueprint has placed by the next pass.
        fitted_scales = {}
    end
    local delays = {0, 100, 500, 1500}
    for attempt = 1, #delays do
        local delay = delays[attempt]
        ExecuteWithDelay(delay, function()
            ExecuteInGameThread(function()
                if valid(manager) then ensure_proxy_pool(manager) end
            end)
        end)
    end
end

local function register_manager_notification()
    if registered_manager_notification then return end
    local ok = pcall(function()
        NotifyOnNewObject(HOLOGRAM_MANAGER_CLASS, prepare_hologram_manager)
    end)
    registered_manager_notification = ok
    log("manager_notification=" .. tostring(registered_manager_notification))

    -- Cover the manager that may already exist when Lua finishes loading.
    if ok then
        local managers = FindAllOf(MANAGER_CLASS)
        if managers ~= nil then
            for _, manager in pairs(managers) do prepare_hologram_manager(manager) end
        end
    end
end

local function register_slot_hook()
    if registered_slot_hook then return end
    local function_object = StaticFindObject(SLOT_LIST_FUNCTION)
    if valid(function_object) then
        local ok, first_id = pcall(function()
            return RegisterHook(SLOT_LIST_FUNCTION, expand_slot_definitions)
        end)
        registered_slot_hook = ok and first_id ~= nil
        log("slot_factory_hook=" .. tostring(registered_slot_hook))
    end
end

-- Read-only. A second reporter hit an out-of-bounds spawn on an ordinary
-- mission, so the auto-assign guard alone does not explain every case. This
-- records the numbers needed to decide the real fix: how many units the squad
-- actually has, how many destinations the deployment area authored, and where
-- each unit ended up. It writes nothing and hooks nothing; the gate is a
-- single FindFirstOf so it costs almost nothing outside a mission.
local function report_mission_placement()
    local gate_ok, squad = pcall(function() return FindFirstOf(SQUAD_CLASS) end)
    if not gate_ok or not valid(squad) then return end

    local key = full_name(squad)
    if key == "" or reported_squads[key] then return end

    local members_ok, members = pcall(function()
        return squad:GetPropertyValue(SQUAD_MEMBERS_PROPERTY)
    end)
    if not members_ok then return end
    local count = array_count(members)
    if count < 1 then return end
    reported_squads[key] = true

    local positions = {}
    for index = 1, math.min(count, TARGET_SIZE + 4) do
        local member = unwrap(members[index])
        local location = valid(member) and actor_location(member) or nil
        if location ~= nil then
            positions[#positions + 1] = string.format("%.0f/%.0f/%.0f",
                location.X, location.Y, location.Z)
        else
            positions[#positions + 1] = "?/?/?"
        end
    end

    local areas = 0
    local destinations = {}
    local found = FindAllOf(PREPARATION_CLASS)
    if found ~= nil then
        for _, area in pairs(found) do
            if valid(area) then
                areas = areas + 1
                local read_ok, list = pcall(function()
                    return area:GetPropertyValue(DESTINATIONS_PROPERTY)
                end)
                destinations[#destinations + 1] =
                    tostring(read_ok and array_count(list) or -1)
            end
        end
    end

    log("mission squad_members=" .. tostring(count)
        .. " preparation_areas=" .. tostring(areas)
        .. " player_destinations=" .. table.concat(destinations, ",")
        .. " unit_positions=" .. table.concat(positions, ","))
end

-- MovePlayerUnitsIntoPosition is the relocation. Bracketing it removes the
-- guesswork the delay ladder was standing in for: the pre-hook fires with the
-- squad still staged, the post-hook with the damage already done.
--
-- The ladder still runs the same two steps on a timer. This codebase already
-- found that a post-hook id can come back without the callback ever being
-- called, so nothing here is allowed to be the only path.
local function relocation_ladder_total()
    local total = 0
    for _, count in pairs(relocation_ladders) do total = total + count end
    return total
end

-- Relocation observations and staged positions belong to one deployment, not
-- to the lifetime of the Lua mod. In particular, relocation_prehook_ran must
-- be re-armed here: otherwise the first mission to relocate a squad prevents
-- every later mission from taking its own pre-relocation snapshot and also
-- disables those missions' fallback repair rungs.
local function begin_deployment(area)
    local key = object_key(area)
    if key == "" then return "" end

    active_deployment_key = key
    active_deployment_area = area
    staged_positions = {}
    repair_counts = {}
    observed_positions = {}
    staging_window_open = true
    relocation_posthook_ran = false
    relocation_prehook_ran = false
    relocation_fired_name = ""
    relocation_fired_names = {}
    relocation_firing_count = 0
    relocation_scheduled[key] = nil
    relocation_ladders[key] = nil
    repair_passes = 0
    repair_units_seen = 0
    repair_restored_total = 0
    placement_failure_reported = false
    reported_placement_triggers = {}
    destination_expansion_reported = false
    placement_rescue_reported = {}
    repair_reported = 0
    return key
end

-- GetAddress() is only unique while an object is alive. UE can later create a
-- new preparation area at the same address, so its new-object notification
-- must invalidate every address-keyed gate that would otherwise make the new
-- instance look as though it had already deployed and exhausted its ladders.
local function prepare_new_area(area)
    area = unwrap(area)
    local key = object_key(area)
    if key == "" then return end
    placement_attempts[key] = nil
    relocation_scheduled[key] = nil
    relocation_ladders[key] = nil
    if active_deployment_key == key then
        active_deployment_key = ""
        active_deployment_area = nil
    end
end

-- A synchronous, deliberately narrow escape hatch for a player who can see
-- that deployment has failed. A complete snapshot uses the normal repair but
-- ignores the automatic two-attempt budget: explicit player confirmation is
-- the safeguard that budget otherwise substitutes for. If the bad operators
-- spawned at the origin and could never be staged, the tightly gated peer
-- fallback above reproduces Sambuco's proven live workaround.
local function register_rescue_command()
    if registered_rescue_command then return end
    local ok = pcall(function()
        RegisterConsoleCommandHandler("squadsixrescue", function()
            local area = unwrap(active_deployment_area)
            if not valid(area) or active_deployment_key == "" then
                log("manual_rescue=refused reason=no_active_deployment")
                return true
            end

            local units = every_player_unit()
            if #units ~= TARGET_SIZE then
                log("manual_rescue=refused reason=squad_size"
                    .. " members=" .. tostring(#units))
                return true
            end

            local staged = 0
            for _, unit in ipairs(units) do
                if staged_positions[unit.key] ~= nil then staged = staged + 1 end
            end

            -- Run the repair whatever the snapshot looks like. An incomplete
            -- snapshot used to skip straight to the peer fallback and, when
            -- that did not match, refuse -- which is what Darkened0Sky got:
            -- `staged=4 fallback=shape hard=0 good=6`, twice, with two
            -- operators still off the map. The repair now has a lane-derived
            -- target for exactly the operators a snapshot could never cover,
            -- so the case that most needs this command is no longer the one
            -- case that never reaches it.
            local restored, stranded = repair_stranded_units(
                area, "console", false, true)
            -- strand_reason answers "off_lane" before it asks the tactical
            -- volume, so an operator that is both off-lane and outside the
            -- volume gets the softer label and the lane fallback declines it.
            -- That is the ordinary rungs behaving correctly -- an off-lane
            -- operator may simply have walked there -- but this is an explicit
            -- command, and the hard signatures are what the peer fallback
            -- below already runs on. Darkened0Sky's log shows the difference
            -- exactly: `off_lane:unstaged` on every early rung, then
            -- `outside_volume:unstaged` once the late watchdog asked.
            -- The soft pass keeps the last word on `stranded`: it is the
            -- wider question, and a deployment it still calls broken must not
            -- be reported as having had nothing wrong with it.
            if restored == 0 and stranded > 0 then
                restored = repair_stranded_units(
                    area, "console_hard", true, true)
            end
            if restored > 0 then
                log("manual_rescue=complete"
                    .. " mode=" .. (staged == TARGET_SIZE and "staged" or "lane")
                    .. " staged=" .. tostring(staged)
                    .. " restored=" .. tostring(restored))
                return true
            end
            if stranded == 0 then
                log("manual_rescue=noop reason=no_stranded_units")
                return true
            end

            local peer_restored, peer_reason, moves =
                manual_peer_rescue(area, units)
            if peer_restored > 0 then
                log("manual_rescue=complete mode=peer_fallback"
                    .. " restored=" .. tostring(peer_restored)
                    .. " warning=shared_tiles"
                    .. " moves=" .. tostring(moves or ""))
            elseif staged ~= TARGET_SIZE then
                log("manual_rescue=refused reason=incomplete_snapshot"
                    .. " staged=" .. tostring(staged)
                    .. " fallback=" .. tostring(peer_reason or "unavailable"))
            else
                log("manual_rescue=failed restored=0"
                    .. " stranded=" .. tostring(stranded)
                    .. " fallback=" .. tostring(peer_reason or "unavailable"))
            end
            return true
        end)
    end)
    registered_rescue_command = ok
    log("rescue_command=" .. tostring(registered_rescue_command))
end

local function on_relocation_starting(context, name)
    local area = unwrap(context)
    if not valid(area) then return end

    local key = object_key(area)
    -- Whether a placement trigger had already opened this deployment.
    -- "adopted" means none had: the relocation is the first thing the mod saw
    -- of this mission.
    local adopted = false
    if key ~= "" and active_deployment_key == "" then
        adopted = true
        begin_deployment(area)
    end

    -- Report every invocation, including a name already seen in this
    -- deployment. The repeated name is the important case: a genuinely later
    -- relocation can use the same Blueprint entry point as the first one.
    -- `ladder` and `coalesced` distinguish that event from the companion hook
    -- name that fires within the 250 ms gate.
    local short = (string.find(name, "^/Script/") and "script:" or "bp:")
        .. (string.match(name, ":([^:]+)$") or name)
    if key ~= "" and active_deployment_key ~= key then
        -- A relocation callback for some other preparation area must not
        -- replace the live deployment's staged snapshot. The normal placement
        -- trigger activates a new area; without that boundary this firing is
        -- observable but deliberately receives no repair ladder.
        relocation_firing_count = relocation_firing_count + 1
        log("relocation_fired=" .. short
            .. " event=" .. tostring(relocation_firing_count)
            .. " ladder=none coalesced=false scheduled=false"
            .. " reason=inactive_area")
        return
    end
    if not relocation_fired_names[short] then
        relocation_fired_names[short] = true
        if relocation_fired_name == "" then relocation_fired_name = short end
    end

    -- Only the first relocation gets to record where the squad was staged.
    -- A later one is reading positions the first has already disturbed, and
    -- the whole value of a staged snapshot is that it predates the damage.
    if not relocation_prehook_ran then
        relocation_prehook_ran = true
        staging_window_open = true
        local members, raw_destinations, usable_destinations = placement_state(area)
        staging_window_open = false

        -- One line saying whether the mod is in a position to help this
        -- mission at all, emitted once per deployment.
        --
        -- Xywzel's operators ended up off the map after what their log
        -- suggested was a mid-session UE4SS reload, and the session could not
        -- be reconstructed afterwards: a runtime that has lost its staged
        -- snapshot repairs nothing and, until now, said nothing about it
        -- either. Every automatic repair moves a unit only to its own staged
        -- position, so `staged` short of `squad` is the whole story -- those
        -- operators cannot be recovered no matter what goes wrong next.
        -- `deployment=adopted` is the matching cause: no placement trigger
        -- opened this deployment, which is what a reset mid-mission looks
        -- like from here.
        local staged = 0
        for _ in pairs(staged_positions) do staged = staged + 1 end
        log("deployment_state=" .. (adopted and "adopted" or "tracked")
            .. " squad=" .. tostring(members)
            .. " destinations=" .. tostring(usable_destinations)
            .. "/" .. tostring(raw_destinations)
            .. " staged=" .. tostring(staged)
            .. " repairable=" .. tostring(members > 0 and staged >= members))
    end

    local coalesced = key ~= "" and relocation_scheduled[key] == true
    local capped = key ~= ""
        and (relocation_ladders[key] or 0) >= MAX_RELOCATION_LADDERS
    local scheduled = key ~= "" and not coalesced and not capped
    if scheduled then
        relocation_scheduled[key] = true
        relocation_ladders[key] = (relocation_ladders[key] or 0) + 1
    end

    relocation_firing_count = relocation_firing_count + 1
    local ladder = key ~= "" and (relocation_ladders[key] or 0) or 0
    log("relocation_fired=" .. short
        .. " event=" .. tostring(relocation_firing_count)
        .. " ladder=" .. (ladder > 0 and tostring(ladder) or "none")
        .. " coalesced=" .. tostring(coalesced)
        .. " scheduled=" .. tostring(scheduled))

    if not scheduled then return end

    -- Hold the gate just long enough to swallow the second hook name for this
    -- same relocation, then re-arm so a later one gets its own repairs.
    ExecuteWithDelay(RELOCATION_COALESCE_MS, function()
        relocation_scheduled[key] = nil
    end)

    -- The relocation happens the moment this returns, so these delays are
    -- measured from it rather than from the trigger.
    ladder = relocation_ladders[key]
    for _, delay in ipairs(REPAIR_DELAYS_MS) do
        local at = delay
        ExecuteWithDelay(at, function()
            ExecuteInGameThread(function()
                if not valid(area) or active_deployment_key ~= key then return end
                repair_stranded_units(area,
                    "post" .. tostring(at) .. (ladder > 1 and ("#" .. ladder) or ""))
            end)
        end)
    end
    for _, delay in ipairs(WATCHDOG_DELAYS_MS) do
        local at = delay
        ExecuteWithDelay(at, function()
            ExecuteInGameThread(function()
                if not valid(area) or active_deployment_key ~= key then return end
                repair_stranded_units(area,
                    "watch" .. tostring(at) .. (ladder > 1 and ("#" .. ladder) or ""),
                    true)
            end)
        end)
    end
end

-- No early return on "one of them registered". The native name resolves at
-- startup and the Blueprint names only once a mission level loads, so exiting
-- as soon as anything was registered meant the Blueprint override -- the one
-- that actually runs -- was never attempted. A verified run logged
-- relocation_hook for the native name and relocation_fired=none.
local function register_relocation_hook()
    local count = 0
    for _, function_name in ipairs(MOVE_UNITS_FUNCTIONS) do
        if not registered_relocation_names[function_name] then
            if valid(StaticFindObject(function_name)) then
                local name = function_name
                local ok, pre_id = pcall(function()
                    return RegisterHook(name,
                        function(context) on_relocation_starting(context, name) end,
                        function(context)
                            local area = unwrap(context)
                            if not valid(area) then return end
                            relocation_posthook_ran = true
                            repair_stranded_units(area, "relocation_post")
                        end)
                end)
                registered_relocation_names[function_name] = ok and pre_id ~= nil
                if registered_relocation_names[function_name] then
                    local origin = string.find(name, "^/Script/") and "script" or "bp"
                    log("relocation_hook=" .. origin .. ":"
                        .. (string.match(name, ":([^:]+)$") or name))
                end
            end
        end
        if registered_relocation_names[function_name] then count = count + 1 end
    end
    -- One is enough; the Blueprint names only exist once a mission level has
    -- loaded, so this keeps being retried until then.
    registered_relocation_hook = count > 0
end

local function register_hooks()
    register_slot_hook()
    register_relocation_hook()

    if not registered_placement_hook then
        local count = 0
        for _, function_name in ipairs(PLACEMENT_TRIGGER_FUNCTIONS) do
            if not registered_placement_triggers[function_name] then
                local function_object = StaticFindObject(function_name)
                if valid(function_object) then
                    local trigger_name = function_name
                    local ok, first_id = pcall(function()
                        return RegisterHook(trigger_name, function(context)
                            local area = unwrap(context)
                            local area_key = object_key(area)
                            local first_trigger =
                                area_key ~= "" and not placement_attempts[area_key]
                            -- Open the staging window before anything reads
                            -- the squad, so the very first read -- the one
                            -- most likely to precede the relocation -- is the
                            -- snapshot the repair pass restores to.
                            if first_trigger then
                                begin_deployment(area)
                            end
                            local expanded = ensure_player_destinations(area)
                            local members, raw_destinations, valid_destinations =
                                placement_state(area)
                            if not reported_placement_triggers[trigger_name] then
                                reported_placement_triggers[trigger_name] = true
                                local short_name = string.match(trigger_name, ":([^:]+)$")
                                    or trigger_name
                                log("placement_trigger=" .. short_name
                                    .. " squad_members=" .. tostring(members)
                                    .. " destinations=" .. tostring(raw_destinations)
                                    .. " valid_destinations=" .. tostring(valid_destinations)
                                    .. " expanded=" .. tostring(expanded)
                                    .. " " .. member_stats_text(last_member_stats))
                            end
                            -- Always retry: at trigger time the squad is
                            -- frequently still empty, which is now a refusal
                            -- rather than a guess.
                            if first_trigger then
                                placement_attempts[area_key] = true
                                -- A verified run read no squad members at
                                -- any point inside two seconds, so the ladder
                                -- reaches further. Each rung is a cheap
                                -- property read and stops mattering as soon
                                -- as the expansion succeeds.
                                local delays = {0, 50, 100, 250, 500, 1000,
                                    2000, 3000, 5000, 8000}
                                for attempt = 1, #delays do
                                    local retry_index = attempt
                                    local retry_delay = delays[attempt]
                                    ExecuteWithDelay(retry_delay, function()
                                        ExecuteInGameThread(function()
                                            if not valid(area) then return end
                                            -- Past this point a position read
                                            -- off a unit may be the relocated
                                            -- one, so it is no longer evidence
                                            -- of where the game staged it.
                                            if retry_delay > STAGING_WINDOW_MS then
                                                staging_window_open = false
                                            end
                                            ensure_player_destinations(area)
                                            local retry_members, _, retry_valid = placement_state(area)
                                            -- The relocation has run by the
                                            -- time the squad has been readable
                                            -- for a second, so from here on
                                            -- every rung checks the result and
                                            -- puts back anyone it stranded.
                                            -- Fallback only. When the
                                            -- relocation pre-hook fires it
                                            -- schedules its own repairs off
                                            -- the relocation itself, and
                                            -- repeating them this late risks
                                            -- moving an operator the player
                                            -- has already taken control of.
                                            if retry_delay >= 1000
                                                and not relocation_prehook_ran then
                                                repair_stranded_units(area, "rung" .. tostring(retry_delay))
                                            end
                                            -- Report how the last rung ended
                                            -- whatever the outcome. 1.0.4
                                            -- only warned when it had already
                                            -- read a squad, so the case that
                                            -- actually happens -- never
                                            -- reading one -- logged nothing.
                                            if retry_index == #delays
                                                and not placement_failure_reported then
                                                placement_failure_reported = true
                                                log("placement_final"
                                                    .. " squad_members=" .. tostring(retry_members)
                                                    .. " valid_destinations=" .. tostring(retry_valid)
                                                    .. " relocation_hook=" .. tostring(registered_relocation_hook)
                                                    .. " relocation_pre=" .. tostring(relocation_prehook_ran)
                                                    .. " relocation_fired=" .. (relocation_fired_name == "" and "none" or relocation_fired_name)
                                                    .. " relocation_ladders=" .. tostring(relocation_ladder_total())
                                                    .. " relocation_post=" .. tostring(relocation_posthook_ran)
                                                    .. " repair_passes=" .. tostring(repair_passes)
                                                    .. " repair_units=" .. tostring(repair_units_seen)
                                                    .. " repair_restored=" .. tostring(repair_restored_total)
                                                    .. " " .. member_stats_text(last_member_stats))
                                                report_mission_placement()
                                                if retry_members > retry_valid then
                                                    log("WARNING: fewer destinations than deployed"
                                                        .. " operators; two may share a start tile")
                                                end
                                            end
                                        end)
                                    end)
                                end
                            end
                        end)
                    end)
                    registered_placement_triggers[function_name] = ok and first_id ~= nil
                end
            end
            if registered_placement_triggers[function_name] then count = count + 1 end
        end
        registered_placement_hook = count == #PLACEMENT_TRIGGER_FUNCTIONS
        if count > 0 then
            log("placement_hooks=" .. tostring(count)
                .. "/" .. tostring(#PLACEMENT_TRIGGER_FUNCTIONS))
        end
    end

    if not registered_proxy_hook then
        local function_object = StaticFindObject(GENERATE_PROXIES_FUNCTION)
        if valid(function_object) then
            local ok, first_id = pcall(function()
                return RegisterHook(GENERATE_PROXIES_FUNCTION, function(context)
                    ensure_proxy_pool(unwrap(context))
                    -- This is the customization screen opening. Reading the
                    -- cameras here and at squad select is what will settle
                    -- whether the two screens share one camera object.
                    camera_census("customization")
                end)
            end)
            registered_proxy_hook = ok and first_id ~= nil
            log("proxy_factory_hook=" .. tostring(registered_proxy_hook))
        end
    end


    if not registered_lineup_hook then
        local function_object = StaticFindObject(SHOW_LINEUP_FUNCTION)
        if valid(function_object) then
            local ok, pre_id, post_id = pcall(function()
                return RegisterHook(SHOW_LINEUP_FUNCTION, lineup_prehook, lineup_posthook)
            end)
            -- Only the pre-hook id is required. The post-hook is a bonus that
            -- this UE4SS build never calls, and demanding its id would leave
            -- maintenance_complete false forever, so the five-second
            -- maintenance loop would never stop.
            registered_lineup_hook = ok and pre_id ~= nil
            log("lineup_hook=" .. tostring(registered_lineup_hook)
                .. " post_hook_id=" .. tostring(post_id ~= nil))
        end
    end
end

-- BP_CombatPreparationArea_C only exists once a mission level has loaded,
-- which is long after the maintenance loop has finished and stopped. Without
-- this the relocation hook would only ever be attempted while the class does
-- not exist yet.
local function register_area_notification()
    if registered_area_notification then return end
    local ok = pcall(function()
        NotifyOnNewObject(PREPARATION_AREA_CLASS_PATH, function(area)
            prepare_new_area(area)
            register_relocation_hook()
        end)
    end)
    registered_area_notification = ok
    log("area_notification=" .. tostring(registered_area_notification))
end

local function register_early_slot_notification()
    local ok = pcall(function()
        NotifyOnNewObject(SLOT_LIST_CLASS, function()
            -- Before the hook, not after: the re-sweep has to have written
            -- six by the time the slot factory reads the mission's maximum.
            resweep_data_limits()
            register_slot_hook()
        end)
    end)
    if not slot_notify_reported then
        slot_notify_reported = true
        log("slot_class_notification=" .. tostring(ok))
    end
end

local function load_target_assets()
    if target_assets_loaded then return end
    local slot_ok = pcall(function() LoadAsset(SLOT_LIST_ASSET) end)
    local manager_ok = pcall(function() LoadAsset(HOLOGRAM_MANAGER_ASSET) end)
    target_assets_loaded = slot_ok and manager_ok
    log("target_assets_loaded=" .. tostring(target_assets_loaded))
end

local function maintain_runtime_state()
    apply_data_limits()
    load_target_assets()
    register_manager_notification()
    register_hooks()
    register_rescue_command()
    report_status()

    if not registered_layout_notification and (not layout_reported or not slot_widget_reported) then
        local box = squad_slot_box()
        if box ~= nil then
            fit_squad_screen(box)
            report_slot_widget_state()
        end
    end

    -- Abandoning the sweep has to satisfy this too. Otherwise the loop that
    -- the cap exists to stop would keep running forever on a machine where
    -- the limits never read, which is the one case the cap is for.
    maintenance_complete = (limit_reported or limit_abandoned)
        and target_assets_loaded
        and registered_slot_hook
        and registered_proxy_hook
        and registered_lineup_hook
        and registered_placement_hook
        and registered_layout_notification
        and registered_manager_notification
end

log("loaded version=" .. VERSION .. " target_size=" .. tostring(TARGET_SIZE))

register_early_slot_notification()
register_layout_notification()
register_area_notification()
register_rescue_command()

ExecuteWithDelay(1000, function()
    ExecuteInGameThread(maintain_runtime_state)
end)

LoopAsync(5000, function()
    if maintenance_complete then return true end
    ExecuteInGameThread(maintain_runtime_state)
    return false
end)
