local VERSION = "1.4.1"
-- Squad Six Reforged's runtime (a continuation of arctco's Squad Six). This file loads the modules and keeps registering hooks until every
-- target exists; the work itself is in limits.lua (mission squad limits), lineup.lua (squad
-- selection) and placement.lua (tactical deployment), with shared helpers in common.lua.
-- selfcheck.lua logs whether every game name those modules use still resolves.
--
-- Explicit path: never resolve another mod's module of the same name. Clearing the cache makes
-- a UE4SS mod reload pick up the current files.
local source = debug.getinfo(1, "S").source:gsub("^@", "")
local directory = assert(source:match("^(.*[/\\])"), "Scripts directory unavailable")
package.path = directory .. "?.lua;" .. package.path
for _, module in ipairs({"common", "limits", "lineup", "placement", "selfcheck"}) do
    package.loaded[module] = nil
end
local Common = require("common")
local Limits = require("limits")
local Lineup = require("lineup")
local Placement = require("placement")
local Selfcheck = require("selfcheck")
-- The Mixamoo Mod Config Manager page (MXM/settings.lua). Registering at load lists the mod in
-- the menu before the first mission; without the menu installed the defaults apply.
pcall(function() require("MXM").Init() end)
local TARGET_SIZE = Common.TARGET_SIZE
local SLOT_LIST_ASSET = Common.SLOT_LIST_ASSET
local HOLOGRAM_MANAGER_ASSET = Common.HOLOGRAM_MANAGER_ASSET
local log = Common.log
local resweep_data_limits = Limits.resweep_data_limits
local apply_data_limits = Limits.apply_data_limits
local guard_summary = Limits.guard_summary
local register_layout_notification = Lineup.register_layout_notification
local register_slot_hook = Lineup.register_slot_hook
local register_proxy_hook = Lineup.register_proxy_hook
local register_lineup_hook = Lineup.register_lineup_hook
local register_manager_notification = Lineup.register_manager_notification
local squad_slot_box = Lineup.squad_slot_box
local fit_squad_screen = Lineup.fit_squad_screen
local report_slot_widget_state = Lineup.report_slot_widget_state
local register_rescue_command = Placement.register_rescue_command
local register_area_notification = Placement.register_area_notification
local register_relocation_hook = Placement.register_relocation_hook
local register_placement_triggers = Placement.register_placement_triggers
local register_spawn_watch = Placement.register_spawn_watch

local SLOT_LIST_CLASS = SLOT_LIST_ASSET .. ".VM_ActivitySlotList_C"
local target_assets_loaded = false
local maintenance_passes = 0
local maintenance_complete = false
local status_reported = false
local status_complete_reported = false
local container_warning_reported = false
local slot_notify_reported = false
-- One line that answers whether Squad Six is running and complete. Logged as
-- soon as the squad limits are known, so an early log still proves the mod
-- loaded, and again once every hook is up (the slot hook only registers when
-- the mission screen opens).
local function report_status()
    local limits, lineup, placement = Limits.state(), Lineup.state(), Placement.state()
    if not limits.limit_reported then return end
    local complete = lineup.registered_slot_hook
        and lineup.registered_proxy_hook
        and lineup.registered_lineup_hook
        and placement.registered_placement_hook
    if status_reported and (status_complete_reported or not complete) then return end
    status_reported = true
    if complete then status_complete_reported = true end
    log("status version=" .. VERSION
        .. " complete=" .. tostring(complete)
        .. " data_container=" .. limits.data_container
        .. " slot_hook=" .. tostring(lineup.registered_slot_hook)
        .. " proxy_hook=" .. tostring(lineup.registered_proxy_hook)
        .. " lineup_hook=" .. tostring(lineup.registered_lineup_hook)
        .. " placement_hook=" .. tostring(placement.registered_placement_hook)
        .. " guard=" .. guard_summary())
    if limits.data_container == "missing" and not container_warning_reported then
        container_warning_reported = true
        log("WARNING: the pakchunk99-SquadSixReforged_P container is not mounted."
            .. " Install Squad Six Reforged - Core, or copy the SquadSixReforged_Core folder into"
            .. " SWZeroCompany/Content/Paks/~mods/")
    end
end

local function register_hooks()
    register_slot_hook()
    register_relocation_hook()
    register_placement_triggers()
    register_proxy_hook()
    register_lineup_hook()
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
    -- The Blueprint names exist once those assets are loaded. If loading keeps failing, check
    -- anyway after a few passes so the log says what is missing.
    maintenance_passes = maintenance_passes + 1
    if target_assets_loaded or maintenance_passes >= 6 then Selfcheck.check_startup() end
    register_manager_notification()
    register_hooks()
    register_rescue_command()
    report_status()

    -- Read after the calls above, which are what change these flags.
    local limits, lineup, placement = Limits.state(), Lineup.state(), Placement.state()

    if not lineup.registered_layout_notification and (not lineup.layout_reported or not lineup.slot_widget_reported) then
        local box = squad_slot_box()
        if box ~= nil then
            fit_squad_screen(box)
            report_slot_widget_state()
        end
    end

    -- Abandoning the sweep has to satisfy this too. Otherwise the loop that
    -- the cap exists to stop would keep running forever on a machine where
    -- the limits never read, which is the one case the cap is for.
    maintenance_complete = (limits.limit_reported or limits.limit_abandoned)
        and target_assets_loaded
        and lineup.registered_slot_hook
        and lineup.registered_proxy_hook
        and lineup.registered_lineup_hook
        and placement.registered_placement_hook
        and lineup.registered_layout_notification
        and lineup.registered_manager_notification
end

log("loaded version=" .. VERSION .. " target_size=" .. tostring(TARGET_SIZE))

-- Another squad-size mod beside this one would act on every deployment too. arctco's original
-- Squad Six has its own IDs, so mod managers don't replace it with this one.
for _, other in ipairs({{"ZCOMSquadSix", "arctco's original Squad Six"}, {"SquadExpansion", "Squad Expansion"}}) do
    local file = io.open(directory .. "../../" .. other[1] .. "/Scripts/main.lua", "r")
    if file then
        file:close()
        log("WARNING: " .. other[2] .. " is also installed (ue4ss/Mods/" .. other[1] .. ")."
            .. " Remove or disable it: two squad-size mods both act on every deployment.")
    end
end

-- ZC Unlocked (a C++ mod) has its own squad extension. Its squad=0 (the Squad row off in its menu)
-- arms it at size 4 anyway: it rewrites mission limits back to four, shows "4 operators" on the
-- mission board and trims the squad-screen lineup to four, which lineup.lua undoes by showing the
-- fifth and sixth models again. Played at six with squad=0 alone (2026-10-14): its placement did
-- nothing, all six deployed, and saving and completing worked. Its undocumented squad_limit_text=0
-- removes the board text. Its paks share no file with the Core pak.
do
    local file = io.open(directory .. "../../ZCUnlocked/dlls/settings.ini", "r")
    if file then
        local section, values = nil, {}
        for line in file:lines() do
            line = line:gsub("^\239\187\191", "")   -- a UTF-8 byte-order mark
            local header = line:match("^%s*%[([^%]]+)%]")
            if header then
                section = header
            elseif section == "Squad" then
                local key, value = line:match("^%s*([%w_]+)%s*=%s*(%-?%d+)")
                if key then values[key] = tonumber(value) end
            end
        end
        file:close()
        local settings = "ue4ss/Mods/ZCUnlocked/dlls/settings.ini, [Squad]"
        if values.squad ~= 0 then
            log("WARNING: ZC Unlocked's squad extension is on (" .. settings .. " squad="
                .. tostring(values.squad or "unset, default on") .. "). Switch the Squad row off in ZC"
                .. " Unlocked Menu (squad=0) and restart: two squad-size mods both act on squad select and"
                .. " every deployment.")
        else
            log("ZC Unlocked is installed with its squad extension off (squad=0). It still trims the squad"
                .. " screen to four models, which this mod shows again"
                .. (values.squad_limit_text == 0 and "."
                    or ", and may show \"4 operators\" on the mission board (squad_limit_text=0 hides that)."))
        end
    end
end

register_early_slot_notification()
register_layout_notification()
register_area_notification()
register_spawn_watch()
register_rescue_command()
Selfcheck.add(Limits.game_names)
Selfcheck.add(Lineup.game_names)
Selfcheck.add(Placement.game_names)
Selfcheck.register_phase_checks()

ExecuteWithDelay(1000, function()
    ExecuteInGameThread(maintain_runtime_state)
end)

LoopAsync(5000, function()
    if maintenance_complete then return true end
    ExecuteInGameThread(maintain_runtime_state)
    return false
end)
