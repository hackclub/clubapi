local db = require("utils/db")

local requestlog = {}

local DEFAULT_PAGE_SIZE = 50
local MAX_PAGE_SIZE = 200
local REDACTED_PARAMS = { key = true, apikey = true, api_key = true, token = true }

local function redactQuery(query)
    if type(query) ~= "string" or query == "" then
        return query
    end
    return (query:gsub("([^&=]+)=([^&]*)", function(name)
        if REDACTED_PARAMS[name:lower()] then
            return name .. "=[redacted]"
        end
    end))
end

local function text(value)
    if value == nil then
        return ""
    end
    return tostring(value)
end

local function wholeNumber(value)
    local n = tonumber(value)
    if not n then
        return "0"
    end
    return string.format("%d", math.floor(n))
end

local function ownerScope(ownerId)
    local value = text(ownerId)
    if value:match("^%d+$") then
        return value
    end
    return ""
end

local OWNED_BY = "(NULLIF($1, '') IS NULL OR key_id IN (SELECT id FROM api_keys WHERE owner_admin_id = NULLIF($1, '')::bigint))"
local OWNED_BY_R = "(NULLIF($1, '') IS NULL OR r.key_id IN (SELECT id FROM api_keys WHERE owner_admin_id = NULLIF($1, '')::bigint))"

function requestlog.record(entry)
    local conn = db.get()
    if not conn then
        return false
    end

    local ok, err = pcall(function()
        conn:execute(
            "INSERT INTO api_requests (key_id, key_name, auth_state, method, path, query, status, duration_ms, ip) " ..
            "VALUES (NULLIF($1, '')::bigint, NULLIF($2, ''), $3, $4, $5, NULLIF($6, ''), $7::int, $8::int, NULLIF($9, ''))",
            {
                text(entry.key_id),
                text(entry.key_name),
                text(entry.auth_state),
                text(entry.method),
                text(entry.path),
                text(redactQuery(entry.query)),
                wholeNumber(entry.status),
                wholeNumber(entry.duration_ms),
                text(entry.ip),
            }
        )
    end)
    if not ok then
        print({ error = "request_log_failed", message = tostring(err) })
        return false
    end

    return true
end

function requestlog.list(filter)
    local conn = db.get()
    if not conn then
        return nil
    end

    local limit = tonumber(filter.limit) or DEFAULT_PAGE_SIZE
    if limit < 1 then
        limit = DEFAULT_PAGE_SIZE
    end
    if limit > MAX_PAGE_SIZE then
        limit = MAX_PAGE_SIZE
    end

    local key = text(filter.key)
    if key == "" then
        key = "all"
    end
    local before = text(filter.before)
    if not before:match("^%d*$") then
        before = ""
    end

    local ok, rows = pcall(function()
        return conn:query_all(
            "SELECT id, key_id, key_name, auth_state, method, path, query, status, duration_ms, ip, created_at " ..
            "FROM api_requests WHERE " .. OWNED_BY .. " " ..
            "AND ($2 = 'all' OR ($2 = 'anonymous' AND auth_state = 'none') OR ($2 = 'invalid' AND auth_state = 'invalid') OR key_id::text = $2) " ..
            "AND (NULLIF($3, '') IS NULL OR id < NULLIF($3, '')::bigint) " ..
            "AND ($4 = '' OR path ILIKE '%' || $4 || '%') " ..
            "AND ($5 = '' OR ($5 = 'errors' AND status >= 400) OR ($5 = 'ok' AND status < 400)) " ..
            "ORDER BY id DESC LIMIT $6::int",
            { ownerScope(filter.owner), key, before, text(filter.path), text(filter.status), wholeNumber(limit) }
        )
    end)
    if not ok then
        print({ error = "request_list_failed", message = tostring(rows) })
        return nil
    end

    return rows or {}, limit
end

function requestlog.overview(ownerId)
    local conn = db.get()
    if not conn then
        return nil
    end

    local scope = { ownerScope(ownerId) }

    local ok, result = pcall(function()
        local totals = conn:query_one(
            "SELECT count(*) AS total, " ..
            "count(*) FILTER (WHERE created_at > now() - interval '24 hours') AS last_24h, " ..
            "count(*) FILTER (WHERE created_at > now() - interval '24 hours' AND status >= 400) AS errors_24h, " ..
            "count(*) FILTER (WHERE created_at > now() - interval '24 hours' AND auth_state = 'invalid') AS invalid_keys_24h, " ..
            "count(*) FILTER (WHERE created_at > now() - interval '24 hours' AND status = 429) AS rate_limited_24h, " ..
            "(SELECT count(*) FROM api_keys WHERE NULLIF($1, '') IS NULL OR owner_admin_id = NULLIF($1, '')::bigint) AS keys " ..
            "FROM api_requests WHERE " .. OWNED_BY,
            scope
        )
        local daily = conn:query_all(
            "SELECT to_char(day, 'YYYY-MM-DD') AS day, count(r.id) AS requests, " ..
            "count(r.id) FILTER (WHERE r.status >= 400) AS errors " ..
            "FROM generate_series(date_trunc('day', now()) - interval '13 days', date_trunc('day', now()), interval '1 day') AS day " ..
            "LEFT JOIN api_requests r ON r.created_at >= day AND r.created_at < day + interval '1 day' AND " .. OWNED_BY_R .. " " ..
            "GROUP BY day ORDER BY day",
            scope
        )
        local paths = conn:query_all(
            "SELECT path, count(*) AS requests, count(*) FILTER (WHERE status >= 400) AS errors " ..
            "FROM api_requests WHERE created_at > now() - interval '7 days' AND " .. OWNED_BY .. " " ..
            "GROUP BY path ORDER BY requests DESC LIMIT 10",
            scope
        )
        local callers = conn:query_all(
            "SELECT CASE auth_state WHEN 'valid' THEN coalesce(key_name, 'Deleted key') WHEN 'invalid' THEN 'Invalid key' ELSE 'Anonymous' END AS caller, " ..
            "count(*) AS requests FROM api_requests WHERE created_at > now() - interval '7 days' AND " .. OWNED_BY .. " " ..
            "GROUP BY 1 ORDER BY requests DESC LIMIT 10",
            scope
        )
        return { totals = totals or {}, daily = daily or {}, paths = paths or {}, callers = callers or {} }
    end)
    if not ok then
        print({ error = "request_overview_failed", message = tostring(result) })
        return nil
    end

    return result
end

function requestlog.prune(retentionDays)
    local conn = db.get()
    if not conn then
        return false
    end

    local ok, err = pcall(function()
        conn:execute(
            "DELETE FROM api_requests WHERE created_at < now() - ($1::int * interval '1 day')",
            { wholeNumber(retentionDays) }
        )
    end)
    if not ok then
        print({ error = "request_prune_failed", message = tostring(err) })
        return false
    end

    return true
end

return requestlog
