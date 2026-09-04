local driver = require("database")

local auth = {}

local VALID_PERMS = { read = true, write = true, admin = true }

local db = nil

local function getDb()
    if db then
        return db
    end

    local connStr = os.getenv("DATABASE_URL")
    if not connStr or connStr == "" then
        print({ error = "missing_database_url", message = "DATABASE_URL not set in environment or .env file" })
        return nil
    end

    local ok, conn = pcall(driver.new, "postgres", connStr)
    if not ok or not conn then
        print({ error = "database_connection_failed", message = conn })
        return nil
    end

    db = conn
    return db
end

local function lookupKey(apikey)
    if type(apikey) ~= "string" or apikey == "" then
        return nil
    end

    local conn = getDb()
    if not conn then
        return nil
    end

    local ok, row = pcall(function()
        return conn:query_one("SELECT key, name, perms FROM api_keys WHERE key = $1", { apikey })
    end)
    if not ok or type(row) ~= "table" then
        return nil
    end

    if row.key ~= apikey then
        return nil
    end

    return row
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

function auth.createKey(name, perms)
    if type(name) ~= "string" or name == "" then
        return nil, "invalid_name"
    end
    if not VALID_PERMS[perms] then
        return nil, "invalid_perms (must be read, write, or admin)"
    end

    local conn = getDb()
    if not conn then
        return nil, "no_database_connection"
    end

    local ok, row = pcall(function()
        return conn:query_one(
            "INSERT INTO api_keys (key, name, perms) " ..
            "VALUES (replace(gen_random_uuid()::text, '-', '') || replace(gen_random_uuid()::text, '-', ''), $1, $2) " ..
            "RETURNING key, name, perms",
            { name, perms }
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

    local conn = getDb()
    if not conn then
        return nil
    end

    local ok, row = pcall(function()
        return conn:query_one("DELETE FROM api_keys WHERE key = $1 RETURNING key, name", { apikey })
    end)
    if not ok or type(row) ~= "table" or row.key ~= apikey then
        return nil
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
