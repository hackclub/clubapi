local db = require("utils/db")

local auth = {}

local VALID_PERMS = { read = true, write = true, admin = true }
local DELEGABLE_PERMS = { read = true, write = true }

local NEW_KEY_SQL = "replace(gen_random_uuid()::text, '-', '') || replace(gen_random_uuid()::text, '-', '')"

local function validId(id)
    local text = tostring(id or "")
    if text:match("^%d+$") then
        return text
    end
    return nil
end

local function lookupKey(apikey)
    if type(apikey) ~= "string" or apikey == "" then
        return nil
    end

    local conn = db.get()
    if not conn then
        return nil
    end

    local ok, row = pcall(function()
        return conn:query_one("SELECT id, key, name, perms FROM api_keys WHERE key = $1", { apikey })
    end)
    if not ok or type(row) ~= "table" then
        return nil
    end

    if row.key ~= apikey then
        return nil
    end

    return row
end

function auth.isValidPerms(perms)
    return VALID_PERMS[perms] == true
end

function auth.isDelegablePerms(perms)
    return DELEGABLE_PERMS[perms] == true
end

function auth.identify(apikey)
    return lookupKey(apikey)
end

function auth.checkKey(apikey)
    local row = lookupKey(apikey)
    if not row then
        return false
    end

    return row.perms or false
end

function auth.getKeyName(apikey)
    local row = lookupKey(apikey)
    if not row then
        return "None"
    end

    return row.name or "None"
end

function auth.createKey(name, perms, ownerId, createdById)
    if type(name) ~= "string" or name == "" then
        return nil, "invalid_name"
    end
    if not VALID_PERMS[perms] then
        return nil, "invalid_perms (must be read, write, or admin)"
    end

    local conn = db.get()
    if not conn then
        return nil, "no_database_connection"
    end

    local ok, row = pcall(function()
        return conn:query_one(
            "INSERT INTO api_keys (key, name, perms, owner_admin_id, created_by_admin_id) " ..
            "VALUES (" .. NEW_KEY_SQL .. ", $1, $2, NULLIF($3, '')::bigint, NULLIF($4, '')::bigint) " ..
            "RETURNING id, key, name, perms, owner_admin_id",
            { name, perms, validId(ownerId) or "", validId(createdById) or "" }
        )
    end)
    if not ok or type(row) ~= "table" or type(row.key) ~= "string" or row.key == "" then
        return nil, "insert_failed"
    end

    return row
end

function auth.revokeKey(apikey)
    if type(apikey) ~= "string" or apikey == "" then
        return nil
    end

    local conn = db.get()
    if not conn then
        return nil
    end

    local ok, row = pcall(function()
        return conn:query_one("DELETE FROM api_keys WHERE key = $1 RETURNING id, key, name", { apikey })
    end)
    if not ok or type(row) ~= "table" or row.key ~= apikey then
        return nil
    end

    return row
end

function auth.listKeys(ownerId)
    local conn = db.get()
    if not conn then
        return nil
    end

    local ok, rows = pcall(function()
        return conn:query_all(
            "SELECT k.id, k.name, k.perms, k.created_at, k.rotated_at, k.owner_admin_id, " ..
            "o.name AS owner_name, c.name AS created_by_name, " ..
            "left(k.key, 6) AS key_prefix, right(k.key, 4) AS key_suffix, " ..
            "coalesce(s.total, 0) AS requests_total, coalesce(s.week, 0) AS requests_7d, " ..
            "coalesce(s.errors, 0) AS errors_7d, s.last_used_at " ..
            "FROM api_keys k " ..
            "LEFT JOIN admins o ON o.id = k.owner_admin_id " ..
            "LEFT JOIN admins c ON c.id = k.created_by_admin_id " ..
            "LEFT JOIN (" ..
            "SELECT key_id, count(*) AS total, " ..
            "count(*) FILTER (WHERE created_at > now() - interval '7 days') AS week, " ..
            "count(*) FILTER (WHERE created_at > now() - interval '7 days' AND status >= 400) AS errors, " ..
            "max(created_at) AS last_used_at " ..
            "FROM api_requests WHERE key_id IS NOT NULL GROUP BY key_id" ..
            ") s ON s.key_id = k.id " ..
            "WHERE NULLIF($1, '') IS NULL OR k.owner_admin_id = NULLIF($1, '')::bigint " ..
            "ORDER BY k.id",
            { validId(ownerId) or "" }
        )
    end)
    if not ok then
        return nil
    end

    return rows or {}
end

function auth.getKeyById(id)
    local keyId = validId(id)
    if not keyId then
        return nil
    end

    local conn = db.get()
    if not conn then
        return nil
    end

    local ok, row = pcall(function()
        return conn:query_one(
            "SELECT id, name, perms, owner_admin_id FROM api_keys WHERE id = $1::bigint",
            { keyId }
        )
    end)
    if not ok or type(row) ~= "table" or row.perms == nil then
        return nil
    end

    return row
end

function auth.revealKeyById(id)
    local keyId = validId(id)
    if not keyId then
        return nil
    end

    local conn = db.get()
    if not conn then
        return nil
    end

    local ok, row = pcall(function()
        return conn:query_one("SELECT id, key, name, perms FROM api_keys WHERE id = $1::bigint", { keyId })
    end)
    if not ok or type(row) ~= "table" or type(row.key) ~= "string" then
        return nil
    end

    return row
end

function auth.setOwnerById(id, ownerId)
    local keyId = validId(id)
    if not keyId then
        return nil, "invalid_id"
    end

    local conn = db.get()
    if not conn then
        return nil, "no_database_connection"
    end

    local ok, row = pcall(function()
        return conn:query_one(
            "UPDATE api_keys SET owner_admin_id = NULLIF($2, '')::bigint WHERE id = $1::bigint " ..
            "RETURNING id, name, perms, owner_admin_id",
            { keyId, validId(ownerId) or "" }
        )
    end)
    if not ok or type(row) ~= "table" or row.perms == nil then
        return nil, "not_found"
    end

    return row
end

function auth.rotateKeyById(id)
    local keyId = validId(id)
    if not keyId then
        return nil, "invalid_id"
    end

    local conn = db.get()
    if not conn then
        return nil, "no_database_connection"
    end

    local ok, row = pcall(function()
        return conn:query_one(
            "UPDATE api_keys SET key = " .. NEW_KEY_SQL .. ", rotated_at = now() " ..
            "WHERE id = $1::bigint RETURNING id, key, name, perms",
            { keyId }
        )
    end)
    if not ok or type(row) ~= "table" or type(row.key) ~= "string" then
        return nil, "not_found"
    end

    return row
end

function auth.setPermsById(id, perms)
    local keyId = validId(id)
    if not keyId then
        return nil, "invalid_id"
    end
    if not VALID_PERMS[perms] then
        return nil, "invalid_perms (must be read, write, or admin)"
    end

    local conn = db.get()
    if not conn then
        return nil, "no_database_connection"
    end

    local ok, row = pcall(function()
        return conn:query_one(
            "UPDATE api_keys k SET perms = $2 FROM (SELECT id, perms AS old_perms FROM api_keys WHERE id = $1::bigint) old " ..
            "WHERE k.id = old.id RETURNING k.id, k.name, k.perms, old.old_perms",
            { keyId, perms }
        )
    end)
    if not ok or type(row) ~= "table" or row.perms == nil then
        return nil, "not_found"
    end

    return row
end

function auth.renameKeyById(id, name)
    local keyId = validId(id)
    if not keyId then
        return nil, "invalid_id"
    end
    if type(name) ~= "string" or name == "" then
        return nil, "invalid_name"
    end

    local conn = db.get()
    if not conn then
        return nil, "no_database_connection"
    end

    local ok, row = pcall(function()
        return conn:query_one(
            "UPDATE api_keys k SET name = $2 FROM (SELECT id, name AS old_name FROM api_keys WHERE id = $1::bigint) old " ..
            "WHERE k.id = old.id RETURNING k.id, k.name, k.perms, old.old_name",
            { keyId, name }
        )
    end)
    if not ok or type(row) ~= "table" or row.perms == nil then
        return nil, "not_found"
    end

    return row
end

function auth.deleteKeyById(id)
    local keyId = validId(id)
    if not keyId then
        return nil, "invalid_id"
    end

    local conn = db.get()
    if not conn then
        return nil, "no_database_connection"
    end

    local ok, row = pcall(function()
        return conn:query_one("DELETE FROM api_keys WHERE id = $1::bigint RETURNING id, name, perms", { keyId })
    end)
    if not ok or type(row) ~= "table" or row.perms == nil then
        return nil, "not_found"
    end

    return row
end

function auth.checkRead(apikey)
    local perms = auth.checkKey(apikey)
    if type(perms) ~= "string" then
        return false
    end

    if perms == "admin" or perms == "read" or perms == "write" then
        return true
    end

    return false
end

function auth.checkWrite(apikey)
    local perms = auth.checkKey(apikey)
    if type(perms) ~= "string" then
        return false
    end

    if perms == "admin" or perms == "write" then
        return true
    end

    return false
end

function auth.checkAdmin(apikey)
    local perms = auth.checkKey(apikey)
    if type(perms) ~= "string" then
        return false
    end

    return perms == "admin"
end

return auth
