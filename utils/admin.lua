local http = require("http")
local json = require("serde").json
local crypto = require("crypto")
local db = require("utils/db")

local admin = {}

local HCA_ISSUER = "https://auth.hackclub.com"
local HCA_AUTHORIZE_URL = "https://auth.hackclub.com/oauth/authorize"
local HCA_TOKEN_URL = "https://auth.hackclub.com/oauth/token"
local HCA_USERINFO_URL = "https://auth.hackclub.com/oauth/userinfo"

admin.SESSION_COOKIE = "clubapi_admin_session"
admin.STATE_COOKIE = "clubapi_admin_state"
admin.SESSION_TTL_SECONDS = 12 * 60 * 60
admin.STATE_TTL_SECONDS = 10 * 60

local MAX_ADMIN_NAME_LENGTH = 100

-- The one place that says what each role may do. Every /admin route asks admin.can() and the
-- dashboard renders from the same table (sent by /admin/api/me), so nothing else compares role names.
-- "all" and "own" are scopes, true is a plain yes, and a missing entry is a no.
local CAPABILITIES = {
    superadmin = {
        view_keys = "all",
        view_requests = "all",
        create_keys = true,
        manage_keys = "all",
        reveal_keys = true,
        assign_keys = true,
        grant_admin_perms = true,
        view_audit = true,
        manage_people = true,
        impersonate = true,
    },
    admin = {
        view_keys = "all",
        view_requests = "all",
        create_keys = true,
        manage_keys = "own",
    },
    keyholder = {
        view_keys = "own",
        view_requests = "own",
    },
}

-- Roles the superadmin can hand out. There is exactly one superadmin, set up by scripts/superadmin.lua.
local ASSIGNABLE_ROLES = { admin = true, keyholder = true }

local LOCAL_HOSTS = { localhost = true, ["127.0.0.1"] = true, ["[::1]"] = true }

local function trim(value)
    return (value:gsub("^%s+", ""):gsub("%s+$", ""))
end

local function idText(value)
    local text = tostring(value or "")
    if text:match("^%d+$") then
        return text
    end
    return nil
end

local function urlEncode(value)
    return (tostring(value):gsub("[^%w%-%._~]", function(c)
        return string.format("%%%02X", string.byte(c))
    end))
end

local function publicUrl()
    local base = os.getenv("PUBLIC_URL") or ""
    return (base:gsub("/+$", ""))
end

function admin.can(actor, capability)
    local granted = type(actor) == "table" and CAPABILITIES[actor.role]
    return granted and granted[capability] or false
end

function admin.capabilities(role)
    local copy = {}
    for capability, value in pairs(CAPABILITIES[role] or {}) do
        copy[capability] = value
    end
    return copy
end

function admin.isAssignableRole(role)
    return ASSIGNABLE_ROLES[role] == true
end

-- True for "localhost", "127.0.0.1" or "[::1]" with an optional port, and nothing else.
function admin.isLocalHost(hostAndPort)
    if type(hostAndPort) ~= "string" then
        return false
    end
    local host = hostAndPort:lower():gsub(":%d+$", "")
    return LOCAL_HOSTS[host] == true
end

-- The dev login skips Hack Club Auth, so it needs both the flag and a PUBLIC_URL that can only be
-- a developer's machine. A deployed instance has its real hostname there, or OAuth wouldn't work.
function admin.devLoginEnabled()
    local flag = (os.getenv("ADMIN_DEV_LOGIN") or ""):lower()
    if flag ~= "1" and flag ~= "true" then
        return false
    end
    return admin.isLocalHost(publicUrl():match("^https?://(.+)$"))
end

function admin.redirectUri()
    return publicUrl() .. "/admin/callback"
end

function admin.isConfigured()
    local clientId = os.getenv("HCA_CLIENT_ID")
    local clientSecret = os.getenv("HCA_CLIENT_SECRET")
    return clientId ~= nil and clientId ~= ""
        and clientSecret ~= nil and clientSecret ~= ""
        and publicUrl() ~= ""
end

function admin.normalizeEmail(value)
    if type(value) ~= "string" then
        return nil
    end
    local email = trim(value):lower()
    if #email > 254 or not email:match("^[^%s@]+@[^%s@]+%.[^%s@]+$") then
        return nil
    end
    return email
end

function admin.normalizeName(value)
    if type(value) ~= "string" then
        return nil
    end
    local name = trim(value)
    if name == "" or #name > MAX_ADMIN_NAME_LENGTH then
        return nil
    end
    return name
end

function admin.bootstrapSuperadmin(name, emails)
    local conn = db.get()
    if not conn then
        return false, "no_database_connection"
    end
    local ok, err = pcall(function()
        conn:execute(
            "INSERT INTO admins (name, role) SELECT $1, 'superadmin' " ..
            "WHERE NOT EXISTS (SELECT 1 FROM admins WHERE role = 'superadmin')",
            { name }
        )
        for _, email in ipairs(emails) do
            conn:execute(
                "INSERT INTO admin_emails (email, admin_id) SELECT $1, id FROM admins WHERE role = 'superadmin' " ..
                "ON CONFLICT (email) DO UPDATE SET admin_id = EXCLUDED.admin_id",
                { email }
            )
        end
    end)
    if not ok then
        return false, tostring(err)
    end
    return true
end

function admin.findByEmail(email)
    local normalized = admin.normalizeEmail(email)
    if not normalized then
        return nil
    end
    local conn = db.get()
    if not conn then
        return nil
    end
    local ok, row = pcall(function()
        return conn:query_one(
            "SELECT a.id, a.name, a.role FROM admin_emails e JOIN admins a ON a.id = e.admin_id WHERE e.email = $1",
            { normalized }
        )
    end)
    if not ok or type(row) ~= "table" or row.id == nil then
        return nil
    end
    return row
end

function admin.exists(adminId)
    local id = idText(adminId)
    if not id then
        return false
    end
    local conn = db.get()
    if not conn then
        return false
    end
    local ok, row = pcall(function()
        return conn:query_one("SELECT id FROM admins WHERE id = $1::bigint", { id })
    end)
    return ok and type(row) == "table" and row.id ~= nil
end

function admin.listAdmins()
    local conn = db.get()
    if not conn then
        return nil
    end
    local ok, result = pcall(function()
        local admins = conn:query_all(
            "SELECT a.id, a.name, a.role, a.created_at, " ..
            "(SELECT count(*) FROM api_keys k WHERE k.owner_admin_id = a.id) AS key_count " ..
            "FROM admins a ORDER BY array_position(ARRAY['superadmin', 'admin', 'keyholder'], a.role), a.name",
            {}
        ) or {}
        local emails = conn:query_all(
            "SELECT email, admin_id FROM admin_emails ORDER BY created_at, email",
            {}
        ) or {}
        local byAdmin = {}
        for _, row in ipairs(emails) do
            local key = tostring(row.admin_id)
            byAdmin[key] = byAdmin[key] or {}
            table.insert(byAdmin[key], row.email)
        end
        for _, row in ipairs(admins) do
            row.emails = byAdmin[tostring(row.id)] or {}
        end
        return admins
    end)
    if not ok then
        print({ error = "admin_list_failed", message = tostring(result) })
        return nil
    end
    return result
end

function admin.createAdmin(name, email, role)
    if not ASSIGNABLE_ROLES[role] then
        return nil, "invalid_role"
    end
    local conn = db.get()
    if not conn then
        return nil, "no_database_connection"
    end
    if admin.findByEmail(email) then
        return nil, "email_taken"
    end
    local ok, row = pcall(function()
        return conn:query_one(
            "WITH created AS (INSERT INTO admins (name, role) VALUES ($1, $3) RETURNING id, name, role), " ..
            "linked AS (INSERT INTO admin_emails (email, admin_id) SELECT $2, id FROM created RETURNING email) " ..
            "SELECT created.id, created.name, created.role FROM created, linked",
            { name, email, role }
        )
    end)
    if not ok or type(row) ~= "table" then
        return nil, "insert_failed"
    end
    return row
end

function admin.addEmail(adminId, email)
    local id = idText(adminId)
    if not id then
        return nil, "invalid_id"
    end
    if admin.findByEmail(email) then
        return nil, "email_taken"
    end
    local conn = db.get()
    if not conn then
        return nil, "no_database_connection"
    end
    local ok, row = pcall(function()
        return conn:query_one(
            "INSERT INTO admin_emails (email, admin_id) SELECT $1, id FROM admins WHERE id = $2::bigint " ..
            "RETURNING email, admin_id",
            { email, id }
        )
    end)
    if not ok or type(row) ~= "table" or row.email == nil then
        return nil, "not_found"
    end
    return row
end

function admin.removeEmail(email)
    local conn = db.get()
    if not conn then
        return nil, "no_database_connection"
    end
    local ok, row = pcall(function()
        return conn:query_one(
            "DELETE FROM admin_emails e WHERE e.email = $1 " ..
            "AND (SELECT count(*) FROM admin_emails o WHERE o.admin_id = e.admin_id) > 1 " ..
            "RETURNING e.email, e.admin_id",
            { email }
        )
    end)
    if not ok or type(row) ~= "table" or row.email == nil then
        return nil, "not_removable"
    end
    return row
end

function admin.renameAdmin(adminId, name)
    local id = idText(adminId)
    if not id then
        return nil, "invalid_id"
    end
    local conn = db.get()
    if not conn then
        return nil, "no_database_connection"
    end
    local ok, row = pcall(function()
        return conn:query_one("UPDATE admins SET name = $2 WHERE id = $1::bigint RETURNING id, name", { id, name })
    end)
    if not ok or type(row) ~= "table" or row.id == nil then
        return nil, "not_found"
    end
    return row
end

function admin.setRole(adminId, role)
    local id = idText(adminId)
    if not id then
        return nil, "invalid_id"
    end
    if not ASSIGNABLE_ROLES[role] then
        return nil, "invalid_role"
    end
    local conn = db.get()
    if not conn then
        return nil, "no_database_connection"
    end
    local ok, row = pcall(function()
        return conn:query_one(
            "UPDATE admins a SET role = $2 FROM (SELECT id, role AS old_role FROM admins WHERE id = $1::bigint) old " ..
            "WHERE a.id = old.id AND old.old_role <> 'superadmin' RETURNING a.id, a.name, a.role, old.old_role",
            { id, role }
        )
    end)
    if not ok or type(row) ~= "table" or row.id == nil then
        return nil, "not_found"
    end
    return row
end

function admin.removeAdmin(adminId)
    local id = idText(adminId)
    if not id then
        return nil, "invalid_id"
    end
    local conn = db.get()
    if not conn then
        return nil, "no_database_connection"
    end
    local ok, row = pcall(function()
        return conn:query_one(
            "DELETE FROM admins WHERE id = $1::bigint AND role <> 'superadmin' RETURNING id, name",
            { id }
        )
    end)
    if not ok or type(row) ~= "table" or row.id == nil then
        return nil, "not_found"
    end
    return row
end

function admin.readCookie(req, name)
    local header = req:headers().cookie
    if type(header) ~= "string" then
        return nil
    end
    for pair in header:gmatch("[^;]+") do
        local key, value = pair:match("^%s*([^=]+)=(.*)$")
        if key and trim(key) == name then
            return trim(value)
        end
    end
    return nil
end

function admin.cookieHeader(name, value, maxAge)
    local parts = {
        name .. "=" .. value,
        "Path=/admin",
        "Max-Age=" .. tostring(maxAge),
        "HttpOnly",
        "SameSite=Lax",
    }
    if publicUrl():match("^https://") then
        table.insert(parts, "Secure")
    end
    return table.concat(parts, "; ")
end

function admin.randomToken()
    local conn = db.get()
    if not conn then
        return nil
    end
    local ok, row = pcall(function()
        return conn:query_one(
            "SELECT replace(gen_random_uuid()::text, '-', '') || replace(gen_random_uuid()::text, '-', '') AS token",
            {}
        )
    end)
    if not ok or type(row) ~= "table" or type(row.token) ~= "string" then
        return nil
    end
    return row.token
end

function admin.authorizeUrl(state)
    return HCA_AUTHORIZE_URL
        .. "?client_id=" .. urlEncode(os.getenv("HCA_CLIENT_ID"))
        .. "&redirect_uri=" .. urlEncode(admin.redirectUri())
        .. "&response_type=code"
        .. "&scope=" .. urlEncode("openid email")
        .. "&state=" .. urlEncode(state)
end

local function decodeBody(res)
    local ok, decoded = pcall(function()
        return json.decode(res:body():text())
    end)
    if ok and type(decoded) == "table" then
        return decoded
    end
    return nil
end

function admin.exchangeCode(code)
    local ok, res = pcall(function()
        return http.request {
            url = HCA_TOKEN_URL,
            method = "POST",
            headers = { ["Content-Type"] = "application/json", ["Accept"] = "application/json" },
            body = json.encode({
                client_id = os.getenv("HCA_CLIENT_ID"),
                client_secret = os.getenv("HCA_CLIENT_SECRET"),
                redirect_uri = admin.redirectUri(),
                code = code,
                grant_type = "authorization_code",
            })
        }:execute()
    end)
    if not ok or not res then
        return nil, "token_request_failed"
    end
    if res:status_code() ~= 200 then
        return nil, "token_exchange_rejected"
    end
    local body = decodeBody(res)
    if not body or type(body.access_token) ~= "string" then
        return nil, "token_response_invalid"
    end
    return body.access_token, body.id_token
end

local function base64UrlDecode(segment)
    local padded = segment .. string.rep("=", (4 - #segment % 4) % 4)
    local ok, decoded = pcall(crypto.base64.decode_urlsafe, padded)
    if ok and type(decoded) == "string" then
        return decoded
    end
    return nil
end

local function audienceMatches(aud, clientId)
    if aud == clientId then
        return true
    end
    if type(aud) == "table" then
        for _, value in ipairs(aud) do
            if value == clientId then
                return true
            end
        end
    end
    return false
end

function admin.claimsFromIdToken(idToken)
    if type(idToken) ~= "string" then
        return nil, "id_token_missing"
    end
    local payload = idToken:match("^[%w%-_]+%.([%w%-_]+)%.[%w%-_]+$")
    local decoded = payload and base64UrlDecode(payload)
    if not decoded then
        return nil, "id_token_malformed"
    end
    local ok, claims = pcall(json.decode, decoded)
    if not ok or type(claims) ~= "table" then
        return nil, "id_token_malformed"
    end
    if claims.iss ~= HCA_ISSUER or not audienceMatches(claims.aud, os.getenv("HCA_CLIENT_ID")) then
        return nil, "id_token_wrong_issuer_or_audience"
    end
    if tonumber(claims.exp) == nil or tonumber(claims.exp) < os.time() then
        return nil, "id_token_expired"
    end
    if type(claims.email) ~= "string" then
        return nil, "id_token_missing_email"
    end
    return claims
end

function admin.fetchUser(accessToken)
    local ok, res = pcall(function()
        return http.request {
            url = HCA_USERINFO_URL,
            method = "GET",
            headers = { ["Authorization"] = "Bearer " .. accessToken, ["Accept"] = "application/json" }
        }:execute()
    end)
    if not ok or not res then
        return nil, "userinfo_request_failed"
    end
    local status = res:status_code()
    if status ~= 200 then
        local bodyText = ""
        pcall(function()
            bodyText = res:body():text() or ""
        end)
        return nil, "userinfo_rejected (status " .. tostring(status) .. "): " .. bodyText:sub(1, 300)
    end
    local body = decodeBody(res)
    if not body or type(body.email) ~= "string" then
        return nil, "userinfo_missing_email"
    end
    return body
end

function admin.createSession(email)
    local token = admin.randomToken()
    if not token then
        return nil
    end
    local conn = db.get()
    local ok = pcall(function()
        conn:execute(
            "INSERT INTO admin_sessions (token_hash, email, expires_at) " ..
            "VALUES (encode(sha256(convert_to($1, 'UTF8')), 'hex'), $2, now() + ($3::int * interval '1 second'))",
            { token, email:lower(), tostring(admin.SESSION_TTL_SECONDS) }
        )
    end)
    if not ok then
        return nil
    end
    return token
end

function admin.session(req)
    local token = admin.readCookie(req, admin.SESSION_COOKIE)
    if not token or token == "" then
        return nil
    end
    local conn = db.get()
    if not conn then
        return nil
    end
    local ok, row = pcall(function()
        return conn:query_one(
            "SELECT s.email, a.id, a.name, a.role, t.id AS target_id, t.name AS target_name, t.role AS target_role " ..
            "FROM admin_sessions s " ..
            "JOIN admin_emails e ON e.email = s.email " ..
            "JOIN admins a ON a.id = e.admin_id " ..
            "LEFT JOIN admins t ON t.id = s.impersonate_admin_id " ..
            "WHERE s.token_hash = encode(sha256(convert_to($1, 'UTF8')), 'hex') AND s.expires_at > now()",
            { token }
        )
    end)
    if not ok or type(row) ~= "table" or row.id == nil then
        return nil
    end

    -- real is who signed in; actor is who the panel is being shown as. They only differ while the
    -- superadmin is using "view as", and every permission check except the impersonation routes uses actor.
    local real = { id = row.id, name = row.name, role = row.role }
    local context = { email = row.email, real = real, actor = real, impersonating = false }
    if admin.can(real, "impersonate") and row.target_id ~= nil then
        local role = row.target_role
        if role == "superadmin" then
            role = "admin"
        end
        context.actor = { id = row.target_id, name = row.target_name, role = role }
        context.impersonating = true
    end
    return context
end

function admin.setImpersonation(req, adminId)
    local token = admin.readCookie(req, admin.SESSION_COOKIE)
    if not token or token == "" then
        return false
    end
    local conn = db.get()
    if not conn then
        return false
    end
    local ok = pcall(function()
        conn:execute(
            "UPDATE admin_sessions SET impersonate_admin_id = NULLIF($2, '')::bigint " ..
            "WHERE token_hash = encode(sha256(convert_to($1, 'UTF8')), 'hex')",
            { token, idText(adminId) or "" }
        )
    end)
    return ok
end

function admin.destroySession(req)
    local token = admin.readCookie(req, admin.SESSION_COOKIE)
    if not token or token == "" then
        return
    end
    local conn = db.get()
    if not conn then
        return
    end
    pcall(function()
        conn:execute(
            "DELETE FROM admin_sessions WHERE token_hash = encode(sha256(convert_to($1, 'UTF8')), 'hex')",
            { token }
        )
    end)
end

function admin.pruneSessions()
    local conn = db.get()
    if not conn then
        return
    end
    pcall(function()
        conn:execute("DELETE FROM admin_sessions WHERE expires_at < now()", {})
    end)
end

function admin.audit(email, action, key, detail)
    local conn = db.get()
    if not conn then
        return
    end
    key = key or {}
    local ok, err = pcall(function()
        conn:execute(
            "INSERT INTO admin_audit (actor_email, action, key_id, key_name, detail) " ..
            "VALUES ($1, $2, NULLIF($3, '')::bigint, NULLIF($4, ''), NULLIF($5, ''))",
            { email, action, tostring(key.id or ""), tostring(key.name or ""), tostring(detail or "") }
        )
    end)
    if not ok then
        print({ error = "audit_failed", message = tostring(err) })
    end
end

function admin.auditLog()
    local conn = db.get()
    if not conn then
        return nil
    end
    local ok, rows = pcall(function()
        return conn:query_all(
            "SELECT id, actor_email, action, key_id, key_name, detail, created_at " ..
            "FROM admin_audit ORDER BY id DESC LIMIT 200",
            {}
        )
    end)
    if not ok then
        return nil
    end
    return rows or {}
end

return admin
