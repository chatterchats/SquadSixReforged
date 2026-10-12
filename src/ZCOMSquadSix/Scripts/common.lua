-- Shared by every Squad Six module: the target size, asset paths, logging, and the
-- reflection and vector helpers.
-- Why each rule exists, with the reports behind it: docs/runtime-notes.md.

local TARGET_SIZE = 6
local SLOT_LIST_ASSET = "/Game/Game/UI/Strategy/GalaxyMap/BPs/VM_ActivitySlotList"
local HOLOGRAM_MANAGER_ASSET = "/Game/Game/UI/AC_HologramManager"
local AUTHORED_SIZE = 4
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

return {
    TARGET_SIZE = TARGET_SIZE,
    SLOT_LIST_ASSET = SLOT_LIST_ASSET,
    HOLOGRAM_MANAGER_ASSET = HOLOGRAM_MANAGER_ASSET,
    AUTHORED_SIZE = AUTHORED_SIZE,
    log = log,
    unwrap = unwrap,
    valid = valid,
    full_name = full_name,
    object_key = object_key,
    array_count = array_count,
    snapshot_array = snapshot_array,
    actor_location = actor_location,
    actor_rotation = actor_rotation,
    actor_scale = actor_scale,
    copy_vector = copy_vector,
    scales_match = scales_match,
    copy_rotator = copy_rotator,
    distance_squared = distance_squared,
}
