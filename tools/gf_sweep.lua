-- One snapshot for tools/gf_sweep.py, run in the game through PlagueNightConsole (pn.py -f). Prints one line:
--   SWEEP {"map":..,"brain":{..},"units":[[name,x,y,z],..],"areas":[{"name":..,"dests":[[x,y,z],..]},..]}
-- With SWEEP_TRIGGER set (a global, from the line pn.py prepends), first calls TriggerPreCombat on the preparation area
-- nearest the squad's centre and prints which.
local function num(x) return string.format("%.1f", x) end
local function vec(l) return "[" .. num(l.X) .. "," .. num(l.Y) .. "," .. num(l.Z) .. "]" end
local function str(s) return string.format("%q", s) end
local function live(o) return o ~= nil and o:IsValid() and not o:GetFullName():find("Default__", 1, true) end

local brain
for _, b in ipairs(FindAllOf("BP_SquadSixBrain_C") or {}) do if live(b) then brain = b end end

local units = {}
local state
for _, s in ipairs(FindAllOf("TacticalGameState") or {}) do if live(s) then state = s end end
if state then
    local ok, squad = pcall(function() return state:GetPropertyValue("PlayerSquad") end)
    local members = ok and squad and squad:IsValid() and squad:GetPropertyValue("SquadMembers")
    if members then
        for i = 1, members:GetArrayNum() do
            local m = members[i]
            if m and m:IsValid() then
                units[#units + 1] = { name = m:GetFName():ToString(), loc = m:K2_GetActorLocation() }
            end
        end
    end
end

local areas = {}
for _, a in ipairs(FindAllOf("CombatPreparationArea") or {}) do
    if live(a) then
        local d = a:GetPropertyValue("PlayerDestinations")
        local dests = {}
        for i = 1, d:GetArrayNum() do
            local p = d[i]
            if p and p:IsValid() then dests[#dests + 1] = p:K2_GetActorLocation() end
        end
        areas[#areas + 1] = { obj = a, name = a:GetFullName():match("[^/]+$"), dests = dests }
    end
end

local triggered = "none"
if SWEEP_TRIGGER and #units > 0 then
    local cx, cy = 0, 0
    for _, u in ipairs(units) do cx, cy = cx + u.loc.X / #units, cy + u.loc.Y / #units end
    local best, best_d = nil, math.huge
    for _, a in ipairs(areas) do
        for _, p in ipairs(a.dests) do
            local d = (p.X - cx) ^ 2 + (p.Y - cy) ^ 2
            if d < best_d then best, best_d = a, d end
        end
    end
    if best then
        local ok, err = pcall(function() best.obj:TriggerPreCombat() end)
        triggered = best.name .. (ok and "" or (" error " .. tostring(err)))
    end
end

local parts = {}
parts[#parts + 1] = '"map":' .. str(brain and (brain:GetFullName():match("Maps/[^.]+") or "?") or "no-brain")
parts[#parts + 1] = '"triggered":' .. str(triggered)
if brain then
    local fields = {}
    for _, f in ipairs({ "AreasSeen", "AreasExpanded", "PointsAdded", "CoveredPoints", "SpotsKept", "SpotsSnapped",
                         "SpotsMoved", "FixedApplied", "ProfilesApplied", "DirectionsUsed", "DeployPasses" }) do
        local ok, value = pcall(function() return brain[f] end)
        fields[#fields + 1] = str(f) .. ":" .. (ok and tostring(value) or "null")
    end
    parts[#parts + 1] = '"brain":{' .. table.concat(fields, ",") .. "}"
end
local us = {}
for _, u in ipairs(units) do us[#us + 1] = "[" .. str(u.name) .. "," .. num(u.loc.X) .. "," .. num(u.loc.Y) .. "," .. num(u.loc.Z) .. "]" end
parts[#parts + 1] = '"units":[' .. table.concat(us, ",") .. "]"
local as = {}
for _, a in ipairs(areas) do
    local ds = {}
    for _, p in ipairs(a.dests) do ds[#ds + 1] = vec(p) end
    as[#as + 1] = '{"name":' .. str(a.name) .. ',"dests":[' .. table.concat(ds, ",") .. "]}"
end
parts[#parts + 1] = '"areas":[' .. table.concat(as, ",") .. "]"
print("SWEEP {" .. table.concat(parts, ",") .. "}")
