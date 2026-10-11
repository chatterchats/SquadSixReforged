-- A minimal JSON decoder for the test data (data/mapscan.json): objects, arrays, strings without
-- escapes beyond \" and \\, numbers, true, false and null.
local json = {}

function json.decode(text)
    local index = 1
    local function skip() index = text:find("[^ \t\r\n]", index) or #text + 1 end
    local value
    local function string_value()
        local start = index + 1
        local finish = start
        while true do
            local c = text:sub(finish, finish)
            if c == "\\" then finish = finish + 2
            elseif c == '"' then break
            else finish = finish + 1 end
        end
        index = finish + 1
        return (text:sub(start, finish - 1):gsub("\\(.)", "%1"))
    end
    function value()
        skip()
        local c = text:sub(index, index)
        if c == "{" then
            local result = {}
            index = index + 1; skip()
            if text:sub(index, index) == "}" then index = index + 1 return result end
            while true do
                skip()
                local key = string_value()
                skip(); assert(text:sub(index, index) == ":", "expected : at " .. index); index = index + 1
                result[key] = value()
                skip()
                local separator = text:sub(index, index); index = index + 1
                if separator == "}" then return result end
                assert(separator == ",", "expected , at " .. index)
            end
        elseif c == "[" then
            local result = {}
            index = index + 1; skip()
            if text:sub(index, index) == "]" then index = index + 1 return result end
            while true do
                result[#result + 1] = value()
                skip()
                local separator = text:sub(index, index); index = index + 1
                if separator == "]" then return result end
                assert(separator == ",", "expected , at " .. index)
            end
        elseif c == '"' then
            return string_value()
        elseif text:sub(index, index + 3) == "true" then index = index + 4 return true
        elseif text:sub(index, index + 4) == "false" then index = index + 5 return false
        elseif text:sub(index, index + 3) == "null" then index = index + 4 return nil
        else
            local number = text:match("^-?[%d.]+[eE]?[-+]?%d*", index)
            index = index + #number
            return tonumber(number)
        end
    end
    return value()
end

return json
