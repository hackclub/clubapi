-- Fills a local database with fake people, keys, requests and audit rows for testing /admin.
-- Usage: astra run scripts/seed.lua          (refuses if the database already has people in it)
--        SEED_RESET=1 astra run scripts/seed.lua   (wipes the admin tables first)
local db = require("utils/db")
local admin = require("utils/admin")
local auth = require("utils/auth")

local REQUEST_COUNT = 400
local AUDIT_COUNT = 150
local DAY = 24 * 60 * 60

local function fail(message)
    print(message)
    os.exit(1)
end

-- This script inserts junk and can truncate tables, so it only runs against a database and a
-- PUBLIC_URL that are both on this machine.
local databaseHost = (os.getenv("DATABASE_URL") or ""):match("^%w+://([^/?]*)") or ""
databaseHost = databaseHost:gsub("^.*@", "")
local publicHost = (os.getenv("PUBLIC_URL") or ""):gsub("/+$", ""):match("^https?://(.+)$")
if not admin.isLocalHost(databaseHost) or not admin.isLocalHost(publicHost) then
    fail("Refusing to seed: DATABASE_URL and PUBLIC_URL must both point at localhost.")
end

if not db.migrate() then
    fail("Database migrations failed, check DATABASE_URL")
end
local conn = db.get()

if os.getenv("SEED_RESET") == "1" then
    conn:execute("TRUNCATE admin_sessions, admin_audit, api_requests, api_keys, admin_emails, admins RESTART IDENTITY CASCADE", {})
elseif tonumber(conn:query_one("SELECT count(*) AS n FROM admins", {}).n) > 0 then
    fail("This database already has people in it. Run with SEED_RESET=1 to wipe the admin tables and reseed.")
end

math.randomseed(20261117)

local function pick(list)
    return list[math.random(#list)]
end

-- People

local superEmail = "super@example.test"
local ok, err = admin.bootstrapSuperadmin("Sam Super", { superEmail })
if not ok then
    fail("Couldn't create the superadmin: " .. tostring(err))
end

local people = { { name = "Sam Super", role = "superadmin", email = superEmail, id = admin.findByEmail(superEmail).id } }
for _, person in ipairs({
    { name = "Ada Admin", role = "admin", email = "ada@example.test" },
    { name = "Alan Admin", role = "admin", email = "alan@example.test" },
    { name = "Kim Keyholder", role = "keyholder", email = "kim@example.test" },
    { name = "Kai Keyholder", role = "keyholder", email = "kai@example.test" },
}) do
    local created, createErr = admin.createAdmin(person.name, person.email, person.role)
    if not created then
        fail("Couldn't create " .. person.name .. ": " .. tostring(createErr))
    end
    person.id = created.id
    table.insert(people, person)
end
local sam, ada, alan, kim, kai = people[1], people[2], people[3], people[4], people[5]

-- Keys: every role owns some, and one is unassigned.

local keys = {}
for _, spec in ipairs({
    { "Clubs dashboard", "admin", sam, sam },
    { "Data warehouse sync", "read", sam, sam },
    { "Ada's bot", "write", ada, ada },
    { "Ada's analytics", "read", ada, ada },
    { "Leaders portal", "write", ada, sam },
    { "Alan's script", "read", alan, alan },
    { "Onboarding flow", "write", alan, alan },
    { "Kim's club site", "read", kim, sam },
    { "Kim's attendance app", "write", kim, sam },
    { "Kai's ship tracker", "read", kai, sam },
    { "Kai's Slack bot", "read", kai, sam },
    { "Legacy integration", "read", nil, sam },
}) do
    local name, perms, owner, creator = spec[1], spec[2], spec[3], spec[4]
    local created, keyErr = auth.createKey(name, perms, owner and owner.id, creator.id)
    if not created then
        fail("Couldn't create key " .. name .. ": " .. tostring(keyErr))
    end
    created.owner = owner
    table.insert(keys, created)
end

-- Requests: spread over the last 14 days, mostly from valid keys with a few anonymous and invalid ones.

local PATHS = {
    { "GET", "/clubs", "" }, { "GET", "/clubs/map", "" }, { "GET", "/club", "name=Hack%20Club%20HQ" },
    { "GET", "/member/email", "email=someone%40example.test" }, { "GET", "/members", "club_name=Hack%20Club%20HQ" },
    { "GET", "/ships", "club_name=Hack%20Club%20HQ" }, { "GET", "/person", "email=someone%40example.test" },
    { "POST", "/member/ships", "" }, { "POST", "/club/status", "" },
}
local STATUSES = { 200, 200, 200, 200, 200, 200, 200, 200, 400, 404, 404, 429, 500, 502 }

for _ = 1, REQUEST_COUNT do
    local roll = math.random()
    local key = roll < 0.8 and pick(keys) or nil
    local authState = key and "valid" or (roll < 0.9 and "none" or "invalid")
    local route = pick(PATHS)
    local status = authState == "invalid" and 401 or pick(STATUSES)
    if (route[1] == "POST" and (authState == "none" or (key and key.perms == "read"))) then
        status = 401
    end
    conn:execute(
        "INSERT INTO api_requests (key_id, key_name, auth_state, method, path, query, status, duration_ms, ip, created_at) " ..
        "VALUES (NULLIF($1, '')::bigint, NULLIF($2, ''), $3, $4, $5, NULLIF($6, ''), $7::int, $8::int, $9, " ..
        "now() - ($10::int * interval '1 second'))",
        {
            key and tostring(key.id) or "", key and key.name or "", authState, route[1], route[2], route[3],
            tostring(status), tostring(math.random(8, 900)), "203.0.113." .. math.random(1, 40),
            -- Squaring the roll puts more of the traffic in the most recent days.
            tostring(math.floor(math.random() ^ 2 * 14 * DAY)),
        }
    )
end

-- Audit rows: logins from everyone, key changes only from the roles that can make them.

local managers = { sam, ada, alan }
for _ = 1, AUDIT_COUNT do
    local roll = math.random()
    local actor, action, key, detail
    if roll < 0.45 then
        actor, action = pick(people), pick({ "login", "login", "logout" })
    elseif roll < 0.55 then
        actor, action, key = sam, "key.reveal", pick(keys)
    else
        actor = pick(managers)
        key = pick(keys)
        while actor ~= sam and key.owner ~= actor do
            key = pick(keys)
        end
        action = pick({ "key.create", "key.rotate", "key.rename", "key.perms" })
        detail = (action == "key.create" and ("perms: " .. key.perms))
            or (action == "key.rename" and ("Old name -> " .. key.name))
            or (action == "key.perms" and "read -> write")
            or nil
    end
    conn:execute(
        "INSERT INTO admin_audit (actor_email, action, key_id, key_name, detail, created_at) " ..
        "VALUES ($1, $2, NULLIF($3, '')::bigint, NULLIF($4, ''), NULLIF($5, ''), now() - ($6::int * interval '1 second'))",
        { actor.email, action, key and tostring(key.id) or "", key and key.name or "", detail or "",
          tostring(math.random(0, 30 * DAY)) }
    )
end

print("Seeded " .. #people .. " people, " .. #keys .. " keys, " .. REQUEST_COUNT .. " requests and " .. AUDIT_COUNT .. " audit rows.")
print("With ADMIN_DEV_LOGIN=1 set, sign in as any of them at " .. os.getenv("PUBLIC_URL"):gsub("/+$", "") .. "/admin/dev-login")
for _, person in ipairs(people) do
    print(string.format("  %-10s %s", person.role, person.email))
end
os.exit(0)
