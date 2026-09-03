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



function airtable.list_records(table_name, view, params)
	-- validate inputs
	if type(table_name) ~= "string" or table_name == "" then
		print({ error = "invalid_table_name", provided = table_name })
		return nil
	end

	local base_id, err = get_base_id()
	if not base_id then
		print({ error = "missing_base_id", message = err })
		return nil
	end

	local headers, herr = build_headers()
	if not headers then
		print({ error = "missing_headers", message = herr })
		return nil
	end

	local url = "https://api.airtable.com/v0/" .. base_id .. "/" .. table_name .. "/listRecords"
	local body = {}
	if params and type(params) == "table" then
		for k, v in pairs(params) do
			body[k] = v
		end
		if body.filterByFormula then
			local valid, err = airtable.validateFormula(body.filterByFormula)
			if not valid then
				print({ error = "invalid_filter_formula", message = err })
				return nil
			end
		end
	end
	if view and type(view) == "string" and view ~= "" then
		body["view"] = view
	end

	local ok, res_or_err = pcall(function()
		return http.request {
			url = url,
			method = "POST",
			headers = headers,
			body = json.encode(body)
		}:execute()
	end)

	if not ok then
		print({ error = "request_exception", fn = "list_records", msg = res_or_err })
		return nil
	end

	local res = res_or_err

	if not res then
		print({ error = "Airtable list_records request failed", status = "no response", body = nil })
		return nil
	end

	local status = res:status_code()
	local body_text = nil
	local ok2, dec = pcall(function()
		body_text = res:body() and res:body():text() or nil
		return body_text and json.decode(body_text) or nil
	end)

	if status >= 400 then
		print({ error = "Airtable list_records request failed", status = status, body = body_text })
		return ok2 and dec or nil
	end

	return ok2 and dec or nil
end

function airtable.get_record(table_name, record_id)
	if type(table_name) ~= "string" or table_name == "" then
		print({ error = "invalid_table_name", provided = table_name })
		return nil
	end
	if type(record_id) ~= "string" or record_id == "" then
		print({ error = "invalid_record_id", provided = record_id })
		return nil
	end

	local base_id, err = get_base_id()
	if not base_id then
		print({ error = "missing_base_id", message = err })
		return nil
	end

	local headers, herr = build_headers()
	if not headers then
		print({ error = "missing_headers", message = herr })
		return nil
	end

	local url = "https://api.airtable.com/v0/" .. base_id .. "/" .. table_name .. "/" .. record_id

	local ok, res_or_err = pcall(function()
		return http.request {
			url = url,
			method = "GET",
			headers = headers
		}:execute()
	end)

	if not ok then
		print({ error = "request_exception", fn = "get_record", msg = res_or_err })
		return nil
	end

	local res = res_or_err

	if not res then
		print({ error = "Airtable get_record request failed", status = "no response", body = nil })
		return nil
	end

	local status = res:status_code()
	local body_text = nil
	local ok2, dec = pcall(function()
		body_text = res:body() and res:body():text() or nil
		return body_text and json.decode(body_text) or nil
	end)

	if status >= 400 then
		print({ error = "Airtable get_record request failed", status = status, body = body_text })
		return ok2 and dec or nil
	end

	return ok2 and dec or nil
end

function airtable.create_record(table_name, fields)
	if type(table_name) ~= "string" or table_name == "" then
		print({ error = "invalid_table_name", provided = table_name })
		return nil
	end
	if type(fields) ~= "table" then
		print({ error = "invalid_fields", provided = fields })
		return nil
	end

	local base_id, err = get_base_id()
	if not base_id then
		print({ error = "missing_base_id", message = err })
		return nil
	end

	local headers, herr = build_headers()
	if not headers then
		print({ error = "missing_headers", message = herr })
		return nil
	end

	local url = "https://api.airtable.com/v0/" .. base_id .. "/" .. table_name
	local body = json.encode({fields = fields})

	local ok, res_or_err = pcall(function()
		return http.request {
			url = url,
			method = "POST",
			headers = headers,
			body = body
		}:execute()
	end)

	if not ok then
		print({ error = "request_exception", fn = "create_record", msg = res_or_err })
		return nil
	end

	local res = res_or_err

	if not res then
		print({ error = "Airtable create_record request failed", status = "no response", body = nil })
		return nil
	end

	local status = res:status_code()
	local body_text = nil
	local ok2, dec = pcall(function()
		body_text = res:body() and res:body():text() or nil
		return body_text and json.decode(body_text) or nil
	end)

	if status >= 400 then
		print({ error = "Airtable create_record request failed", status = status, body = body_text })
		return ok2 and dec or nil
	end

	return ok2 and dec or nil
end

function airtable.update_record(table_name, record_id, fields)
	if type(table_name) ~= "string" or table_name == "" then
		print({ error = "invalid_table_name", provided = table_name })
		return nil
	end
	if type(record_id) ~= "string" or record_id == "" then
		print({ error = "invalid_record_id", provided = record_id })
		return nil
	end
	if type(fields) ~= "table" then
		print({ error = "invalid_fields", provided = fields })
		return nil
	end

	local base_id, err = get_base_id()
	if not base_id then
		print({ error = "missing_base_id", message = err })
		return nil
	end

	local headers, herr = build_headers()
	if not headers then
		print({ error = "missing_headers", message = herr })
		return nil
	end

	local url = "https://api.airtable.com/v0/" .. base_id .. "/" .. table_name .. "/" .. record_id
	local body = json.encode({fields = fields})

	local ok, res_or_err = pcall(function()
		return http.request {
			url = url,
			method = "PATCH",
			headers = headers,
			body = body
		}:execute()
	end)

	if not ok then
		print({ error = "request_exception", fn = "update_record", msg = res_or_err })
		return nil
	end

	local res = res_or_err

	if not res then
		print({ error = "Airtable update_record request failed", status = "no response", body = nil })
		return nil
	end

	local status = res:status_code()
	local body_text = nil
	local ok2, dec = pcall(function()
		body_text = res:body() and res:body():text() or nil
		return body_text and json.decode(body_text) or nil
	end)

	if status >= 400 then
		print({ error = "Airtable update_record request failed", status = status, body = body_text })
		return ok2 and dec or nil
	end

	return ok2 and dec or nil
end

function airtable.delete_record(table_name, record_id)
	if type(table_name) ~= "string" or table_name == "" then
		print({ error = "invalid_table_name", provided = table_name })
		return nil
	end
	if type(record_id) ~= "string" or record_id == "" then
		print({ error = "invalid_record_id", provided = record_id })
		return nil
	end

	local base_id, err = get_base_id()
	if not base_id then
		print({ error = "missing_base_id", message = err })
		return nil
	end

	local headers, herr = build_headers()
	if not headers then
		print({ error = "missing_headers", message = herr })
		return nil
	end

	local url = "https://api.airtable.com/v0/" .. base_id .. "/" .. table_name .. "/" .. record_id

	local ok, res_or_err = pcall(function()
		return http.request {
			url = url,
			method = "DELETE",
			headers = headers
		}:execute()
	end)

	if not ok then
		print({ error = "request_exception", fn = "delete_record", msg = res_or_err })
		return nil
	end

	local res = res_or_err

	if not res then
		print({ error = "Airtable delete_record request failed", status = "no response", body = nil })
		return nil
	end

	local status = res:status_code()
	local body_text = nil
	local ok2, dec = pcall(function()
		body_text = res:body() and res:body():text() or nil
		return body_text and json.decode(body_text) or nil
	end)

	if status >= 400 then
		print({ error = "Airtable delete_record request failed", status = status, body = body_text })
		return ok2 and dec or nil
	end

	return ok2 and dec or nil
end



function airtable.count_records(table_name, filter_formula)
	if type(table_name) ~= "string" or table_name == "" then
		print({ error = "invalid_table_name", provided = table_name })
		return nil
	end

	if filter_formula and type(filter_formula) == "string" and filter_formula ~= "" then
		local valid, err = airtable.validateFormula(filter_formula)
		if not valid then
			print({ error = "invalid_filter_formula", message = err })
			return nil
		end
	end

	local count = 0
	local offset = nil

	repeat
		local params = {
			pageSize = 100,
			offset = offset
		}
		if filter_formula and type(filter_formula) == "string" and filter_formula ~= "" then
			params.filterByFormula = filter_formula
		end

		local res = airtable.list_records(table_name, nil, params)

		if not res or not res.records then
			return nil
		end

		count = count + #res.records
		offset = res.offset
	until not offset

	return count
end

return airtable


