local http = require("http")
local json = require("serde").json
local airtable = {}

local dangerousPatterns = {
	"IF%s*%(",
	"SWITCH%s*%(",
	"ERROR%s*%(",
	"RECORD_ID%s*%(",
	"CREATED_TIME%s*%(",
	"LAST_MODIFIED_TIME%s*%(",
	"REGEX_MATCH%s*%(",
	"REGEX_REPLACE%s*%(",
	"REGEX_EXTRACT%s*%(",
}

function airtable.sanitizeFormulaValue(value)
	if type(value) ~= "string" then
		return tostring(value)
	end
	local sanitized = value:gsub("\\", "\\\\")
	sanitized = sanitized:gsub('"', '\\"')
	sanitized = sanitized:gsub("'", "\\'")
	sanitized = sanitized:gsub("{", "")
	sanitized = sanitized:gsub("}", "")
	sanitized = sanitized:gsub("%(", "")
	sanitized = sanitized:gsub("%)", "")
	sanitized = sanitized:gsub("\n", " ")
	sanitized = sanitized:gsub("\r", " ")
	sanitized = sanitized:gsub("\t", " ")
	return sanitized
end

function airtable.safeFormula(fieldName, value)
	if value == nil then
		return nil, "value cannot be nil"
	end
	local strValue = tostring(value)
	if (strValue:sub(1, 1) == '"' and strValue:sub(-1) == '"') or 
	   (strValue:sub(1, 1) == "'" and strValue:sub(-1) == "'") then
		strValue = strValue:sub(2, -2)
	end
	local sanitized = airtable.sanitizeFormulaValue(strValue)
	return "{" .. fieldName .. "} = \"" .. sanitized .. "\""
end

function airtable.validateFormula(formula)
	if type(formula) ~= "string" then
		return false, "formula must be a string"
	end
	local upper = formula:upper()
	for _, pattern in ipairs(dangerousPatterns) do
		if upper:match(pattern:upper()) then
			return false, "potentially dangerous formula pattern detected: " .. pattern
		end
	end
	return true
end

local function get_api_key()
	local key = os.getenv("AIRTABLE_API_KEY")
	if not key or key == "" then
		return nil, "AIRTABLE_API_KEY not set in environment or .env file"
	end
	return key
end

local function get_base_id()
	local base_id = os.getenv("AIRTABLE_BASE_ID")
	if not base_id or base_id == "" then
		return nil, "AIRTABLE_BASE_ID not set in environment or .env file"
	end
	return base_id
end

local function build_headers()
	local api_key, err = get_api_key()
	if not api_key then
		print({ error = "missing_airtable_api_key", message = err })
		return nil, err
	end

	return {
		["Authorization"] = "Bearer " .. api_key,
		["Content-Type"] = "application/json"
	}
end



local FAILURE = {}

function airtable.isFailure(err)
	return type(err) == "table" and err.kind == FAILURE
end

local function fail(details)
	print(details)
	error({ kind = FAILURE, details = details }, 0)
end

local function table_url(table_name, base_override)
	if type(table_name) ~= "string" or table_name == "" then
		fail({ error = "invalid_table_name", provided = table_name })
	end
	local base_id, err = get_base_id()
	if base_override then
		base_id, err = base_override, nil
	end
	if not base_id then
		fail({ error = "missing_base_id", message = err })
	end
	return "https://api.airtable.com/v0/" .. base_id .. "/" .. table_name
end

local function record_url(table_name, record_id)
	if type(record_id) ~= "string" or record_id == "" then
		fail({ error = "invalid_record_id", provided = record_id })
	end
	return table_url(table_name) .. "/" .. record_id
end

local function send(fn, request, options)
	local headers, herr = build_headers()
	if not headers then
		fail({ error = "missing_headers", fn = fn, message = herr })
	end
	request.headers = headers

	local ok, res = pcall(function()
		return http.request(request):execute()
	end)
	if not ok then
		fail({ error = "request_exception", fn = fn, msg = res })
	end
	if not res then
		fail({ error = "Airtable " .. fn .. " request failed", status = "no response" })
	end

	local status = res:status_code()
	local body_text = nil
	local decoded, data = pcall(function()
		body_text = res:body() and res:body():text() or nil
		return body_text and json.decode(body_text) or nil
	end)

	if status == 404 and options and options.missing_ok then
		return nil
	end
	if status >= 400 then
		fail({ error = "Airtable " .. fn .. " request failed", status = status, body = body_text })
	end
	if not decoded or type(data) ~= "table" then
		fail({ error = "Airtable " .. fn .. " returned invalid JSON", status = status })
	end
	return data
end

function airtable.list_records(table_name, view, params, base_override)
	local url = table_url(table_name, base_override) .. "/listRecords"
	local body = {}
	if params and type(params) == "table" then
		for k, v in pairs(params) do
			body[k] = v
		end
		if body.filterByFormula then
			local valid, err = airtable.validateFormula(body.filterByFormula)
			if not valid then
				fail({ error = "invalid_filter_formula", message = err })
			end
		end
	end
	if view and type(view) == "string" and view ~= "" then
		body["view"] = view
	end

	local data = send("list_records", { url = url, method = "POST", body = json.encode(body) })
	if type(data.records) ~= "table" then
		fail({ error = "Airtable list_records returned no records list" })
	end
	return data
end

function airtable.list_all_records(table_name, view, params, base_override)
	local records = {}
	local offset = nil
	repeat
		local page_params = {}
		for k, v in pairs(params or {}) do
			page_params[k] = v
		end
		page_params.offset = offset
		local page = airtable.list_records(table_name, view, page_params, base_override)
		for _, record in ipairs(page.records) do
			table.insert(records, record)
		end
		offset = page.offset
	until not offset
	return { records = records }
end

function airtable.get_record(table_name, record_id)
	return send("get_record", { url = record_url(table_name, record_id), method = "GET" }, { missing_ok = true })
end

function airtable.create_record(table_name, fields)
	if type(fields) ~= "table" then
		fail({ error = "invalid_fields", provided = fields })
	end
	return send("create_record", {
		url = table_url(table_name),
		method = "POST",
		body = json.encode({fields = fields})
	})
end

function airtable.update_record(table_name, record_id, fields)
	if type(fields) ~= "table" then
		fail({ error = "invalid_fields", provided = fields })
	end
	return send("update_record", {
		url = record_url(table_name, record_id),
		method = "PATCH",
		body = json.encode({fields = fields})
	})
end

function airtable.delete_record(table_name, record_id)
	return send("delete_record", { url = record_url(table_name, record_id), method = "DELETE" })
end

function airtable.count_records(table_name, filter_formula)
	local params = { pageSize = 100 }
	if filter_formula and type(filter_formula) == "string" and filter_formula ~= "" then
		params.filterByFormula = filter_formula
	end
	local count = 0
	local offset = nil
	repeat
		params.offset = offset
		local page = airtable.list_records(table_name, nil, params)
		count = count + #page.records
		offset = page.offset
	until not offset
	return count
end

return airtable
