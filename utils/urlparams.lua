
local url = {}

function url.parse_query(uri)
    -- extract the part after "?"
    local query = uri:match("%?(.*)")
    if not query then
        return {} -- no params
    end

    local params = {}

    local preservePlus = {email = true, new_email = true, old_email = true, message = true}

    for key, value in query:gmatch("([^&=?]+)=([^&=?]+)") do
        -- decode percent encoding if needed
        key = key:gsub("%+", " ")
        key = key:gsub("%%(%x%x)", function(h) return string.char(tonumber(h, 16)) end)
        if not preservePlus[key] then
            value = value:gsub("%+", " ")
        end
        value = value:gsub("%%(%x%x)", function(h) return string.char(tonumber(h, 16)) end)

        if not (value:sub(1, 1) == '"' and value:sub(-1) == '"') then
            value = '"' .. value .. '"'
        end

        params[key] = value
    end

    return params
end

function url.strip_quotes(str)
    if type(str) ~= "string" then return str end
    local first = str:sub(1, 1)
    local last = str:sub(-1)
    if (first == '"' and last == '"') or (first == "'" and last == "'") then
        return str:sub(2, -2)
    end
    return str
end




return url
