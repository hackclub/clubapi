local driver = require("database")

local db = {}

local conn = nil

local MIGRATIONS = {
    "CREATE TABLE IF NOT EXISTS api_keys (key text PRIMARY KEY, name text, perms text NOT NULL)",
    "ALTER TABLE api_keys ADD COLUMN IF NOT EXISTS id bigserial",
    "CREATE UNIQUE INDEX IF NOT EXISTS api_keys_id_idx ON api_keys (id)",
    "ALTER TABLE api_keys ADD COLUMN IF NOT EXISTS created_at timestamptz",
    "ALTER TABLE api_keys ALTER COLUMN created_at SET DEFAULT now()",
    "ALTER TABLE api_keys ADD COLUMN IF NOT EXISTS rotated_at timestamptz",
    "CREATE TABLE IF NOT EXISTS api_requests (" ..
        "id bigserial PRIMARY KEY, " ..
        "key_id bigint, " ..
        "key_name text, " ..
        "auth_state text NOT NULL, " ..
        "method text NOT NULL, " ..
        "path text NOT NULL, " ..
        "query text, " ..
        "status integer NOT NULL, " ..
        "duration_ms integer, " ..
        "ip text, " ..
        "created_at timestamptz NOT NULL DEFAULT now())",
    "CREATE INDEX IF NOT EXISTS api_requests_created_at_idx ON api_requests (created_at)",
    "CREATE INDEX IF NOT EXISTS api_requests_key_id_idx ON api_requests (key_id, id)",
    "CREATE TABLE IF NOT EXISTS admin_sessions (" ..
        "token_hash text PRIMARY KEY, " ..
        "email text NOT NULL, " ..
        "created_at timestamptz NOT NULL DEFAULT now(), " ..
        "expires_at timestamptz NOT NULL)",
    "CREATE TABLE IF NOT EXISTS admins (" ..
        "id bigserial PRIMARY KEY, " ..
        "name text NOT NULL, " ..
        "is_superadmin boolean NOT NULL DEFAULT false, " ..
        "created_at timestamptz NOT NULL DEFAULT now())",
    "CREATE UNIQUE INDEX IF NOT EXISTS admins_single_superadmin_idx ON admins (is_superadmin) WHERE is_superadmin",
    "CREATE TABLE IF NOT EXISTS admin_emails (" ..
        "email text PRIMARY KEY, " ..
        "admin_id bigint NOT NULL REFERENCES admins (id) ON DELETE CASCADE, " ..
        "created_at timestamptz NOT NULL DEFAULT now())",
    "CREATE INDEX IF NOT EXISTS admin_emails_admin_id_idx ON admin_emails (admin_id)",
    "ALTER TABLE api_keys ADD COLUMN IF NOT EXISTS owner_admin_id bigint REFERENCES admins (id) ON DELETE SET NULL",
    "ALTER TABLE api_keys ADD COLUMN IF NOT EXISTS created_by_admin_id bigint REFERENCES admins (id) ON DELETE SET NULL",
    "ALTER TABLE admin_sessions ADD COLUMN IF NOT EXISTS impersonate_admin_id bigint REFERENCES admins (id) ON DELETE SET NULL",
    "CREATE TABLE IF NOT EXISTS admin_audit (" ..
        "id bigserial PRIMARY KEY, " ..
        "actor_email text NOT NULL, " ..
        "action text NOT NULL, " ..
        "key_id bigint, " ..
        "key_name text, " ..
        "detail text, " ..
        "created_at timestamptz NOT NULL DEFAULT now())",
}

function db.get()
    if conn then
        return conn
    end

    local connStr = os.getenv("DATABASE_URL")
    if not connStr or connStr == "" then
        print({ error = "missing_database_url", message = "DATABASE_URL not set in environment or .env file" })
        return nil
    end

    local ok, connection = pcall(driver.new, "postgres", connStr)
    if not ok or not connection then
        print({ error = "database_connection_failed", message = connection })
        return nil
    end

    conn = connection
    return conn
end

function db.migrate()
    local connection = db.get()
    if not connection then
        return false
    end

    for _, statement in ipairs(MIGRATIONS) do
        local ok, err = pcall(function()
            connection:execute(statement, {})
        end)
        if not ok then
            print({ error = "migration_failed", statement = statement, message = tostring(err) })
            return false
        end
    end

    return true
end

return db
