local http = require("http")
local json = require("serde").json
local platform = {}

platform.url = os.getenv("CLUBS_PLATFORM_URL") or "https://clubs.hackclub.com"

local function hydrate(data, index)
	if type(index) ~= "number" or index < 0 then
		return nil
	end
	local value = data[index + 1]
	if type(value) ~= "table" then
		return value
	end
	if type(value[1]) == "string" then
		if value[1] == "Date" then
			return value[2]
		end
		return nil
	end
	local out = {}
	if value[1] ~= nil then
		for i, item in ipairs(value) do
			out[i] = hydrate(data, item)
		end
	else
		for key, item in pairs(value) do
			out[key] = hydrate(data, item)
		end
	end
	return out
end

local function str(value)
	if type(value) == "string" and value ~= "" then
		return value
	end
	return nil
end

local function num(value)
	if type(value) == "number" and value == value then
		return value
	end
	return nil
end

platform.str = str
platform.num = num

local function pageData(path, key)
	local ok, res = pcall(function()
		return http.request({ url = platform.url .. path .. "/__data.json", method = "GET" }):execute()
	end)
	if not ok or not res then
		return nil, "request_failed"
	end
	local status = res:status_code()
	if status == 404 then
		return nil, "not_found"
	end
	if status ~= 200 then
		return nil, "status_" .. tostring(status)
	end
	local decoded, body = pcall(function()
		return json.decode(res:body():text())
	end)
	if not decoded or type(body) ~= "table" then
		return nil, "invalid_json"
	end
	if body.type == "redirect" then
		return nil, "not_public"
	end
	if body.type ~= "data" or type(body.nodes) ~= "table" then
		return nil, "unexpected_response"
	end
	for _, node in pairs(body.nodes) do
		if type(node) == "table" and node.type == "data" and type(node.data) == "table"
			and type(node.data[1]) == "table" and node.data[1][key] ~= nil then
			return hydrate(node.data, 0)
		end
	end
	return nil, "missing_" .. key
end

function platform.mapPins()
	local root, err = pageData("/explore/map", "pins")
	if not root then
		return nil, err
	end
	if type(root.pins) ~= "table" then
		return nil, "invalid_pins"
	end
	local pins = {}
	for _, pin in ipairs(root.pins) do
		if type(pin) == "table" and str(pin.name) and num(pin.lat) and num(pin.lng) then
			table.insert(pins, {
				id = str(pin.id),
				handle = str(pin.handle),
				name = pin.name,
				place = str(pin.place),
				country = str(pin.country),
				lat = pin.lat,
				lng = pin.lng,
				shipCount = num(pin.shipCount) or 0,
				linkable = pin.linkable == true,
			})
		end
	end
	return {
		pins = pins,
		hiddenByClub = num(root.hiddenByClub) or 0,
		unlocated = num(root.unlocated) or 0,
	}
end

function platform.clubProfile(handle)
	if type(handle) ~= "string" or not handle:match("^[%w%-_]+$") then
		return nil, "invalid_handle"
	end
	local root, err = pageData("/clubs/" .. handle, "profile")
	if not root then
		return nil, err
	end
	if type(root.profile) ~= "table" then
		return nil, "invalid_profile"
	end
	return root.profile
end

function platform.profileUrl(handle)
	return platform.url .. "/clubs/" .. handle
end

return platform
