-- Squad selection: six activity slots, two extra presentation proxies, the six-model
-- lineup on the diorama, and room for six nameplates.
-- Why each rule exists, with the reports behind it: docs/runtime-notes.md.
local Common = require("common")
local TARGET_SIZE = Common.TARGET_SIZE
local HOLOGRAM_MANAGER_ASSET = Common.HOLOGRAM_MANAGER_ASSET
local AUTHORED_SIZE = Common.AUTHORED_SIZE
local log = Common.log
local unwrap = Common.unwrap
local valid = Common.valid
local full_name = Common.full_name
local object_key = Common.object_key
local array_count = Common.array_count
local snapshot_array = Common.snapshot_array
local actor_location = Common.actor_location
local actor_rotation = Common.actor_rotation
local actor_scale = Common.actor_scale
local copy_vector = Common.copy_vector
local scales_match = Common.scales_match
local copy_rotator = Common.copy_rotator
local distance_squared = Common.distance_squared

local HOLOGRAM_MANAGER_CLASS = HOLOGRAM_MANAGER_ASSET .. ".AC_HologramManager_C"
local SLOT_LIST_FUNCTION = "/Game/Game/UI/Strategy/GalaxyMap/BPs/VM_ActivitySlotList.VM_ActivitySlotList_C:CreateActivitySlotVMs"
local GENERATE_PROXIES_FUNCTION = "/Game/Game/UI/AC_HologramManager.AC_HologramManager_C:GenerateCustomizationProxies"
local SHOW_LINEUP_FUNCTION = "/Game/Game/UI/AC_HologramManager.AC_HologramManager_C:ShowLineupHologramActors"
local SLOT_BOX_CLASS = "MDVMDynamicEntryBox"
local SLOT_BOX_CLASS_PATH = "/Script/MDViewModel.MDVMDynamicEntryBox"
local MANAGER_CLASS = "AC_HologramManager_C"
local PROXY_ARRAY_PROPERTY = "Customization Proxy Actors"
local SLOT_INDEX_PROPERTY = "index_7_31948AF04E3D570FC0E4BBBEA45BB788"
-- The lineup diorama has four authored attachment slots.
local AUTHORED_SLOTS = 4
-- A captured layout is only trusted when consecutive authored slots are really
-- apart: an unplaced pool sits at the origin or holds stale transforms.
local MIN_SLOT_SEPARATION_SQ = 100.0
local ACTIVITY_CHARACTER_PROPERTY = "characterVM"
local registered_slot_hook = false
local registered_proxy_hook = false
local registered_lineup_hook = false
local registered_layout_notification = false
local registered_manager_notification = false
local slot_reentry = false
local slot_expansion_reported = false
local proxy_expansion_reported = false
local reported_layout_results = {}
local lineup_widths = {}
local layout_reported = false
local slot_widget_reported = false
-- Per proxy actor: the scale the fit was derived from, and the scale the
-- fit wrote. Keeping both is what lets a pass tell its own last write
-- apart from a scale the Blueprint has since put there for a different
-- character, without ever compounding its own work.
local fitted_scales = {}
local lineup_layouts = {}
local proxies_hidden_by_mod = {}
-- Per owner key: the indexes past the authored four that the last lineup pass wants shown, and
-- the generation of the watch that keeps them shown (keep_extra_models_shown).
local extra_models_wanted = {}
local extra_models_watch = {}
local fitted_slot_boxes = {}
local lineup_reentry = {}
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

-- The diorama has four authored slots, and the Blueprint can't place indexes 4
-- and 5, so a five- or six-model row is derived from the four authored
-- positions, keeping character and nameplate order. A four-model lineup is left
-- exactly where the Blueprint put it.
--
-- Returns the layout, or nil and a short reason for the log.
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

    -- Capture at most once per manager: after the first pass, a row this mod
    -- shifted looks just like an authored one, and re-deriving from it would
    -- drift the lineup on every Edit Squad.
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

    -- Fit the row into the span of the authored four rather than widening it,
    -- so no camera has to change (squad select shares this stage with the
    -- character editor). Step and scale both shrink by (4 - 1) / (used - 1), so
    -- the outer models land on the authored outer slots.
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
        -- ratio. The base is re-read when the Blueprint has put a new scale on
        -- the actor, and reused only while the actor still carries this mod's
        -- last write, so the fit never compounds. Overflow proxies take slot
        -- four's scale.
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

-- Hide every proxy this lineup doesn't use: past the slot count, or whose slot
-- holds no character, so a four-slot mission doesn't keep the previous lineup's
-- fifth and sixth models.
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
    local extra_wanted = {}
    extra_models_wanted[owner_key] = extra_wanted
    for index = 1, proxy_count do
        local actor = unwrap(proxies[index])
        if valid(actor) then
            local wanted = index <= used
                and (assignments == nil or assignments[index] == true)
            if wanted and index > AUTHORED_SLOTS then extra_wanted[index] = true end
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

-- One lineup pass lays the models out and hides the unused ones. It is
-- idempotent and runs from the pre-hook and again on the next tick; `source` in
-- its log line says which did the work.
--
-- describe_proxies records the pool as it stands before the pass, for the log.
-- Diagnostics only, and kept to plain indexed reads: calling
-- GetClonedFromCharacter or TArray:ForEach from here crashed the game inside
-- UE4SS, where pcall can't catch it.
-- Whether an actor is hidden, or nil if that can't be read. AActor::IsHidden isn't a reflected
-- function, so UE4SS can't call it (every call failed, and the lineup's hidden count always read
-- 0); bHidden is a property.
local function actor_hidden(actor)
    local ok, hidden = pcall(function() return unwrap(actor:GetPropertyValue("bHidden")) end)
    if ok and type(hidden) == "boolean" then return hidden end
    return nil
end

local function describe_proxies(proxies, proxy_count)
    local counts = {valid = 0, hidden = 0}
    local positions, scales = {}, {}
    if proxies == nil or proxy_count < 1 then return counts, positions, scales end
    for index = 1, proxy_count do
        local read_ok, element = pcall(function() return proxies[index] end)
        local actor = read_ok and unwrap(element) or nil
        if valid(actor) then
            counts.valid = counts.valid + 1
            if actor_hidden(actor) == true then counts.hidden = counts.hidden + 1 end
            -- Copies, read now: the pass is about to move these actors. They
            -- are only turned into text if the line is logged.
            local location = actor_location(actor)
            positions[#positions + 1] = location ~= nil and copy_vector(location) or false
            local scale = actor_scale(actor)
            scales[#scales + 1] = scale ~= nil and copy_vector(scale) or false
        end
    end
    return counts, positions, scales
end

local function vectors_text(vectors, format)
    local text = {}
    for index, vector in ipairs(vectors) do
        text[index] = vector and string.format(format, vector.X, vector.Y, vector.Z) or "?/?/?"
    end
    return table.concat(text, ",")
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

-- Another mod can hide the fifth and sixth models after this mod has laid them out: ZC Unlocked
-- trims the lineup to four even with its squad extension off (squad=0 still arms it at size 4),
-- so two operators had no model on the squad screen (2026-10-14). For a while after each pass,
-- while the squad screen is open, a hidden extra model the pass wants shown is shown again.
-- Only the models past the authored four, and only while the screen's slot box is valid and
-- visible: the game's own hiding of the lineup, and any model this mod hid, are left alone.
local KEEP_SHOWN = {interval_ms = 250, seconds = 15}

-- Whether a squad-select slot box is on screen now. Looked up each time: the first lineup pass
-- runs before the screen is shown, and an earlier screen's box can still exist, not visible.
local function squad_screen_visible()
    local boxes = FindAllOf(SLOT_BOX_CLASS)
    if boxes == nil then return false end
    for _, box in pairs(boxes) do
        local name = full_name(box)
        if string.find(name, "WBP_Menu_MissionSquadSelect", 1, true)
            and string.find(name, "CharacterSlots", 1, true) then
            local open_ok, open = pcall(function() return box:IsVisible() end)
            if open_ok and open == true then return true end
        end
    end
    return false
end

local function keep_extra_models_shown(owner, owner_key)
    if next(extra_models_wanted[owner_key] or {}) == nil then return end
    local generation = (extra_models_watch[owner_key] or 0) + 1
    extra_models_watch[owner_key] = generation
    if not reported_layout_results["keep_shown"] then
        reported_layout_results["keep_shown"] = true
        local indexes = {}
        for index in pairs(extra_models_wanted[owner_key]) do indexes[#indexes + 1] = index end
        table.sort(indexes)
        log("lineup_keep_shown indexes=" .. table.concat(indexes, ",") .. " screen_visible="
            .. tostring(squad_screen_visible()))
    end
    local ticks = 0
    LoopAsync(KEEP_SHOWN.interval_ms, function()
        ticks = ticks + 1
        if extra_models_watch[owner_key] ~= generation
            or ticks * KEEP_SHOWN.interval_ms > KEEP_SHOWN.seconds * 1000 then
            return true
        end
        ExecuteInGameThread(function()
            -- Nothing is shown while the squad screen isn't on screen, before it opens or after
            -- it closes; the watch waits rather than stopping.
            if extra_models_watch[owner_key] ~= generation or not valid(owner)
                or not squad_screen_visible() then
                return
            end
            local proxies = proxy_array(owner)
            for index in pairs(extra_models_wanted[owner_key] or {}) do
                local actor = unwrap(proxies[index])
                if valid(actor) and actor_hidden(actor) == true and not (proxies_hidden_by_mod[owner_key] or {})[index]
                    and pcall(function() actor:SetActorHiddenInGame(false) end) then
                    if not reported_layout_results["reshown:" .. index] then
                        reported_layout_results["reshown:" .. index] = true
                        log("lineup_reshown index=" .. index .. " after_ms=" .. (ticks * KEEP_SHOWN.interval_ms)
                            .. " (something else hid a model this lineup shows)")
                    end
                end
            end
        end)
        return false
    end)
end

local function run_lineup_pass(owner, activity_slots_param, used, source)
    if not valid(owner) then return end
    if used == nil or used < 1 then return end
    if used > TARGET_SIZE then used = TARGET_SIZE end

    local owner_key = object_key(owner)
    local proxies = proxy_array(owner)
    local proxy_count = array_count(proxies)
    -- Read before the pass moves anything. The result is only known afterwards
    -- and is part of the log key, so each new outcome is logged once.
    local counts, positions, scales = describe_proxies(proxies, proxy_count)

    local applied, result = place_lineup_models(owner, proxies, used, true)
    local trimmed = trim_lineup_proxies(activity_slots_param, proxies, owner_key, used)
    keep_extra_models_shown(owner, owner_key)


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
            .. " before_positions=" .. vectors_text(positions, "%.0f/%.0f/%.0f")
            .. " before_scales=" .. vectors_text(scales, "%.3f/%.3f/%.3f"))
    end
end

-- Pre-hook. Grows the pool to six before the Blueprint starts cloning, then
-- lays out the row from the transforms the proxies carry from the last pass;
-- the capture check rejects an unplaced pool.
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

    -- Read the width here and remember it for the deferred pass, which cannot
    -- read this hook's parameter after the hook returns.
    local used = array_count(activity_slots_param)
    if used >= 0 then lineup_widths[owner_key] = used end

    -- Never let the deferred closure keep activity_slots_param: hook parameters
    -- are only valid while the hook runs, and reading one afterwards crashed.
    local activity_slots_snapshot = snapshot_array(activity_slots_param, used)
    run_lineup_pass(owner, activity_slots_snapshot, used, "pre")

    -- The Blueprint places the authored slots during the call this hook
    -- precedes. Running once more on the next tick captures that fresh row;
    -- it stands in for the post-hook, which UE4SS never calls here.
    ExecuteWithDelay(0, function()
        ExecuteInGameThread(function()
            if not valid(owner) then return end
            run_lineup_pass(owner, activity_slots_snapshot,
                lineup_widths[owner_key], "deferred")
        end)
    end)
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

local function register_proxy_hook()
    if not registered_proxy_hook then
        local function_object = StaticFindObject(GENERATE_PROXIES_FUNCTION)
        if valid(function_object) then
            local ok, first_id = pcall(function()
                return RegisterHook(GENERATE_PROXIES_FUNCTION, function(context)
                    ensure_proxy_pool(unwrap(context))
                end)
            end)
            registered_proxy_hook = ok and first_id ~= nil
            log("proxy_factory_hook=" .. tostring(registered_proxy_hook))
        end
    end
end

local function register_lineup_hook()
    if not registered_lineup_hook then
        local function_object = StaticFindObject(SHOW_LINEUP_FUNCTION)
        if valid(function_object) then
            -- Pre-hook only: UE4SS never calls post-hooks on Blueprint
            -- functions, so the deferred pass the pre-hook schedules does the
            -- work that would belong there.
            local ok, pre_id = pcall(function()
                return RegisterHook(SHOW_LINEUP_FUNCTION, lineup_prehook)
            end)
            registered_lineup_hook = ok and pre_id ~= nil
            log("lineup_hook=" .. tostring(registered_lineup_hook))
        end
    end
end

return {
    -- Every game name this module depends on, for selfcheck.lua.
    game_names = {
        -- VM_ActivitySlotList only loads when the squad screen first opens.
        {"function", SLOT_LIST_FUNCTION, when = "squad_select"},
        {"function", GENERATE_PROXIES_FUNCTION},
        {"function", SHOW_LINEUP_FUNCTION},
        {"class", SLOT_BOX_CLASS_PATH},
        {"property", HOLOGRAM_MANAGER_CLASS, PROXY_ARRAY_PROPERTY},
        -- The slot-definition struct that CreateActivitySlotVMs takes. Its field names carry a
        -- GUID suffix, which changes whenever the struct is edited.
        {"property", "/Game/Game/UI/Strategy/GalaxyMap/BPs/BrunoActivitySlotData.BrunoActivitySlotData",
            SLOT_INDEX_PROPERTY},
        {"property", "/Game/Game/UI/Strategy/GalaxyMap/BPs/VM_ActivitySlot.VM_ActivitySlot_C",
            ACTIVITY_CHARACTER_PROPERTY},
        {"property", string.match(SLOT_LIST_FUNCTION, "^(.-):"), "ActivitySlots", when = "squad_select"},
        -- No SetEntrySpacing exists on this class, so the property is what fit_squad_screen sets.
        {"property", "/Script/UMG.DynamicEntryBoxBase", "EntrySpacing"},
    },
    squad_slot_box = squad_slot_box,
    fit_squad_screen = fit_squad_screen,
    report_slot_widget_state = report_slot_widget_state,
    register_layout_notification = register_layout_notification,
    register_manager_notification = register_manager_notification,
    register_slot_hook = register_slot_hook,
    register_proxy_hook = register_proxy_hook,
    register_lineup_hook = register_lineup_hook,
    -- Read-only view of the flags main.lua reports and waits on.
    state = function()
        return {
            registered_slot_hook = registered_slot_hook,
            registered_proxy_hook = registered_proxy_hook,
            registered_lineup_hook = registered_lineup_hook,
            registered_layout_notification = registered_layout_notification,
            registered_manager_notification = registered_manager_notification,
            layout_reported = layout_reported,
            slot_widget_reported = slot_widget_reported,
        }
    end,
}
