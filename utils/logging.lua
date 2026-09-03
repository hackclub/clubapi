local url = require("utils/urlparams")
local auth = require("utils/auth")

local log = {}

function log.request(uri, headers)
    local key = headers.authorization
    local keyname
if key then
    keyname = auth.getKeyName(key)
else 
    keyname = "None"
end
print("Request made to " ..uri .." With API Key: " ..keyname)
end




return log
