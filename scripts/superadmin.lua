local db = require("utils/db")
local admin = require("utils/admin")

local USAGE = 'Usage: SUPERADMIN_NAME="Your Name" SUPERADMIN_EMAILS="you@hackclub.com,you@example.com" astra run scripts/superadmin.lua'

local name = admin.normalizeName(os.getenv("SUPERADMIN_NAME") or "")
local emails = {}
for entry in (os.getenv("SUPERADMIN_EMAILS") or ""):gmatch("[^,]+") do
    local email = admin.normalizeEmail(entry)
    if not email then
        print("Invalid email: " .. entry)
        os.exit(1)
    end
    table.insert(emails, email)
end

if not name or #emails == 0 then
    print(USAGE)
    os.exit(1)
end

if not db.migrate() then
    print("Database migrations failed, check DATABASE_URL")
    os.exit(1)
end

local ok, err = admin.bootstrapSuperadmin(name, emails)
if not ok then
    print("Failed to set up the superadmin: " .. tostring(err))
    os.exit(1)
end

print("Superadmin ready. Emails linked: " .. table.concat(emails, ", "))
print("If a superadmin already existed, its name was kept and these emails were added to it.")
