-- Print Reforged's per-map placement data as JSON for the Game Feature build (unreal/specs/gf_maps.py), so both
-- versions read one source: placement.lua's FIXED layouts and PLACEMENT_PROFILES, RESCUE.inset, and directions.lua.
--   luajit tools/export_placement_data.lua <Scripts dir>
-- placement.lua needs UE4SS to run, so its two tables are cut out of the source text and evaluated on their own.
local scripts = assert(arg[1], "usage: export_placement_data.lua <Scripts dir>")

local function read(path)
    local file = assert(io.open(path, "r"))
    local text = file:read("*a")
    file:close()
    return text
end

-- The table literal assigned by `local <name> = {`, by brace matching (no braces in its strings or comments).
local function table_literal(source, name)
    local start = assert(source:find("local " .. name .. " = {", 1, true), name .. " not found")
    local open = source:find("{", start, true)
    local depth = 0
    for index = open, #source do
        local char = source:sub(index, index)
        if char == "{" then
            depth = depth + 1
        elseif char == "}" then
            depth = depth - 1
            if depth == 0 then return source:sub(open, index) end
        end
    end
    error(name .. " is unbalanced")
end

local function evaluate(literal)
    return assert(loadstring("return " .. literal))()
end

local function encode(value)
    local kind = type(value)
    if kind == "number" then return string.format("%.17g", value) end
    if kind == "string" then return string.format("%q", value) end
    if kind == "boolean" then return tostring(value) end
    if kind ~= "table" then return "null" end
    if #value > 0 or next(value) == nil then
        local items = {}
        for _, item in ipairs(value) do items[#items + 1] = encode(item) end
        return "[" .. table.concat(items, ",") .. "]"
    end
    local keys = {}
    for key in pairs(value) do keys[#keys + 1] = tostring(key) end
    table.sort(keys)
    local items = {}
    for _, key in ipairs(keys) do items[#items + 1] = string.format("%q", key) .. ":" .. encode(value[key]) end
    return "{" .. table.concat(items, ",") .. "}"
end

local placement = read(scripts .. "/placement.lua")
local fixed = evaluate(table_literal(placement, "FIXED"))
local inset = tonumber(placement:match("RESCUE%.inset = ([%d%.]+)"))
print(encode({
    fixed = fixed.layouts,
    same_point = math.sqrt(fixed.same_point_sq),
    profiles = evaluate(table_literal(placement, "PLACEMENT_PROFILES")),
    inset = assert(inset, "RESCUE.inset not found"),
    match_radius = math.sqrt(tonumber(placement:match("PLACEMENT_PROFILE_MATCH_RADIUS_SQ = ([%d%.]+)"))),
    directions = dofile(scripts .. "/directions.lua"),
}))
