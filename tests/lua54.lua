-- Loaded before a test by tools/run-tests.sh's second pass: takes away what LuaJIT has and the
-- Lua 5.4 inside UE4SS doesn't, so code that only runs under LuaJIT fails the tests. In 5.4,
-- math.atan takes (y, x) instead of math.atan2; a call to math.atan2 broke a deployment in game
-- (2026-10-13) while every test passed.
local atan = math.atan
math.atan = function(y, x)
    if x == nil then return atan(y) end
    if x > 0 then return atan(y / x) end
    if x < 0 then return atan(y / x) + (y >= 0 and math.pi or -math.pi) end
    return y > 0 and math.pi / 2 or (y < 0 and -math.pi / 2 or 0)
end
for _, name in ipairs({"atan2", "pow", "ldexp", "frexp", "cosh", "sinh", "tanh", "log10", "mod"}) do
    math[name] = nil
end
table.getn, table.maxn, unpack, setfenv, getfenv, loadstring = nil, nil, nil, nil, nil, nil
