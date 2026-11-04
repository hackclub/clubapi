local server = require("http").server.new()
local fs = require("fs")
local clock = require("datetime")
local airtable = require("utils/airtable")
local url = require("utils/urlparams")
local auth = require("utils/auth")
local log = require("utils/logging")
local db = require("utils/db")
local admin = require("utils/admin")
local requestlog = require("utils/requestlog")

local function fuzzCoord(n)
    if type(n) ~= "number" then
        return n
    end
    return math.floor(n * 100 + 0.5) / 100
end

local function orFormula(fieldName, values)
    if not values or #values == 0 then
        return nil
    end
    local parts = {}
    for _, v in ipairs(values) do
        table.insert(parts, "{" .. fieldName .. "} = \"" .. airtable.sanitizeFormulaValue(v) .. "\"")
    end
    if #parts == 1 then
        return parts[1]
    end
    return "OR(" .. table.concat(parts, ",") .. ")"
end

local NOT_IMPLEMENTED = {
    error = "Not yet implemented — the Airtable field(s) this endpoint relied on were removed in a base migration and no replacement has been wired up yet"
}

local function notImplemented(res)
    res:set_status_code(501)
    return NOT_IMPLEMENTED
end

-- Distinguishes "no key sent" (legitimate anonymous access) from "a key was sent but it doesn't
-- validate" (should be a hard 401, not a silent downgrade to the public response shape).
local function keyProvided(req)
    local h = req:headers().authorization
    return h ~= nil and h ~= ""
end

local function unauthorized(res)
    res:set_status_code(401)
    return {error = "Unauthorized"}
end

local CLUBS_MAP_CACHE_TTL_SECONDS = 45
local clubsMapCache = { data = nil, expiresAt = 0 }

local COUNT_CACHE_TTL_SECONDS = 60
local countCache = { clubs = {}, country = {}, level = {} }

local function cachedCount(bucket, key, computeFn)
    local now = os.time()
    local entry = bucket[key]
    if entry and now < entry.expiresAt then
        return entry.count
    end
    local count = computeFn()
    bucket[key] = { count = count, expiresAt = now + COUNT_CACHE_TTL_SECONDS }
    return count
end

local RATE_LIMIT_WINDOW_SECONDS = 60
local RATE_LIMIT_MAX_REQUESTS = 10
local RATE_LIMIT_NEAR_LIMIT_REQUESTS = 8
local RATE_LIMIT_STRIKE_THRESHOLD = 3
local RATE_LIMIT_BLOCK_SECONDS = 600
local rateLimitState = {}

local function clientIp(req)
    local headers = req:headers()
    if headers["cf-connecting-ip"] and headers["cf-connecting-ip"] ~= "" then
        return headers["cf-connecting-ip"]
    end
    local forwarded = headers["x-forwarded-for"]
    if forwarded and forwarded ~= "" then
        local first = forwarded:match("^%s*([^,]+)")
        if first then
            return first
        end
    end
    local ipAddr = req:ip_address()
    return ipAddr and ipAddr.address or "unknown"
end

local function isRateLimited(ip)
    local now = os.time()
    local entry = rateLimitState[ip]

    if entry and entry.blockedUntil and now < entry.blockedUntil then
        return true
    end

    if not entry or now - entry.windowStart >= RATE_LIMIT_WINDOW_SECONDS then
        local strikes = entry and entry.strikes or 0
        if entry and entry.count >= RATE_LIMIT_NEAR_LIMIT_REQUESTS then
            strikes = strikes + 1
        else
            strikes = 0
        end
        local blockedUntil = nil
        if strikes >= RATE_LIMIT_STRIKE_THRESHOLD then
            blockedUntil = now + RATE_LIMIT_BLOCK_SECONDS
        end
        rateLimitState[ip] = { windowStart = now, count = 1, strikes = strikes, blockedUntil = blockedUntil }
        return blockedUntil ~= nil
    end

    entry.count = entry.count + 1
    return entry.count > RATE_LIMIT_MAX_REQUESTS
end

local function rateLimited(handler)
    return function(req, res)
        if not auth.checkRead(req:headers().authorization) then
            if isRateLimited(clientIp(req)) then
                res:set_status_code(429)
                return {error = "Too many requests"}
            end
        end
        return handler(req, res)
    end
end

local REQUEST_LOG_RETENTION_DAYS = tonumber(os.getenv("REQUEST_LOG_RETENTION_DAYS")) or 90
local PRUNE_INTERVAL_SECONDS = 60 * 60
local nextPruneAt = 0

local function pruneExpiredData()
    local now = os.time()
    if now < nextPruneAt then
        return
    end
    nextPruneAt = now + PRUNE_INTERVAL_SECONDS
    requestlog.prune(REQUEST_LOG_RETENTION_DAYS)
    admin.pruneSessions()
end

local function nowMs()
    return clock.new():get_epoch_milliseconds()
end

local function statusTracking(res)
    local tracker = { status = 200 }
    tracker.res = setmetatable({}, {
        __index = function(_, name)
            local member = res[name]
            if type(member) ~= "function" then
                return member
            end
            return function(_, ...)
                if name == "set_status_code" then
                    tracker.status = ...
                end
                return member(res, ...)
            end
        end
    })
    return tracker
end

local function recorded(handler)
    return function(req, res)
        local started = nowMs()
        local header = req:headers().authorization
        local keyRow = nil
        local authState = "none"
        if header ~= nil and header ~= "" then
            keyRow = auth.identify(header)
            authState = keyRow and "valid" or "invalid"
        end

        local tracker = statusTracking(res)
        local ok, result = pcall(handler, req, tracker.res)

        local uri = req:uri()
        pcall(requestlog.record, {
            key_id = keyRow and keyRow.id,
            key_name = keyRow and keyRow.name,
            auth_state = authState,
            method = req:method(),
            path = uri:match("^[^?]*"),
            query = uri:match("%?(.*)$"),
            status = ok and tracker.status or 500,
            duration_ms = nowMs() - started,
            ip = clientIp(req),
        })

        pcall(pruneExpiredData)

        if not ok then
            error(result, 0)
        end
        return result
    end
end

local rawGet = server.get
local rawPost = server.post
local rawDelete = server.delete

function server:get(path, callback, config)
    return rawGet(self, path, recorded(rateLimited(callback)), config)
end

function server:post(path, callback, config)
    return rawPost(self, path, recorded(rateLimited(callback)), config)
end

function server:delete(path, callback, config)
    return rawDelete(self, path, recorded(rateLimited(callback)), config)
end


-----------------
-- GET RECORDS --
-----------------


server:static_file("/", "docs.html")
server:static_file("/openapi.yaml", "openapi.yaml")


-- CLUB MANAGEMENT

server:get("/clubs", function(req)
    log.request(req:uri(), req:headers())
    local total = cachedCount(countCache.clubs, "total", function()
        return airtable.count_records("Clubs")
    end)
    return {totalClubs = total}
end)

server:get("/clubs/map", function(req, res)
    log.request(req:uri(), req:headers())
    res:set_header("Access-Control-Allow-Origin", "*")

    local now = os.time()
    if clubsMapCache.data and now < clubsMapCache.expiresAt then
        return clubsMapCache.data
    end

    local fields = {"club_name", "venue_lat", "venue_lng", "status", "club_website"}
    local result = {}
    local offset = nil
    repeat
        local data = airtable.list_records("Clubs", nil, {fields = fields, offset = offset})
        if data and data.records then
            for _, club in ipairs(data.records) do
                local clubFields = {
                    club_name = club.fields.club_name,
                    venue_lat_fuzz = fuzzCoord(club.fields.venue_lat),
                    venue_lng_fuzz = fuzzCoord(club.fields.venue_lng),
                    club_status = club.fields.status
                }
                if club.fields.club_website then
                    clubFields.club_website = club.fields.club_website
                end
                table.insert(result, {
                    id = club.id,
                    fields = clubFields
                })
            end
            offset = data.offset
        else
            offset = nil
        end
    until not offset

    clubsMapCache.data = result
    clubsMapCache.expiresAt = now + CLUBS_MAP_CACHE_TTL_SECONDS
    return result
end)

server:get("/clubs/country", function(req)
    log.request(req:uri(), req:headers())
    local params = url.parse_query(req:uri())
    if params.country == nil then
        return {error = "Missing country parameter"}
    end
    local stripped = url.strip_quotes(params.country)
    local count = cachedCount(countCache.country, stripped, function()
        local formula = airtable.safeFormula("venue_addr_country", params.country)
        return airtable.count_records("Clubs", formula)
    end)
    return {clubs = count}
end)

server:get("/clubs/level", function(req)
    log.request(req:uri(), req:headers())
    local params = url.parse_query(req:uri())
    if params.level == nil then
        return {error = "Missing level parameter"}
    end
    local stripped = url.strip_quotes(params.level)
    local count = cachedCount(countCache.level, stripped, function()
        local levelValue = "level " .. airtable.sanitizeFormulaValue(stripped)
        local formula = airtable.safeFormula("level", levelValue)
        return airtable.count_records("Clubs", formula)
    end)
    return {clubs = count}
end)

server:get("/club", function(req, res)
    log.request(req:uri(), req:headers())
    local params = url.parse_query(req:uri())
    if params.name == nil then
        return {error = "Missing name parameter"}
    end
    local formula = airtable.safeFormula("club_name", params.name)
    if auth.checkRead(req:headers().authorization) then
        local club = airtable.list_records("Clubs", nil, {filterByFormula = formula, timeZone = "America/New_York"}).records[1]
        if club == nil then
            return {club_name = nil}
        end
        return club
    elseif keyProvided(req) then
        return unauthorized(res)
    else
        local fields = {"club_name", "status", "club_website", "leader_slack_id", "venue_addr_country"}
        local club = airtable.list_records("Clubs", nil, {filterByFormula = formula, timeZone = "America/New_York", fields = fields}).records[1]
        if club == nil then
            return {club_name = nil}
        end
        return club
    end
end)

server:get("/club/ambassador", function(req)
    log.request(req:uri(), req:headers())
    local params = url.parse_query(req:uri())
    if params.name == nil then
        return {error = "Missing name parameter"}
    end
    local formula = airtable.safeFormula("club_name", params.name)
    local fields = {"rel_ambassador"}
    local club = airtable.list_records("Clubs", nil, {filterByFormula = formula, timeZone = "America/New_York", fields = fields}).records[1]
    if club == nil then
        return {error = "Club not found"}
    end
    local ambassadorId = club.fields.rel_ambassador
    if ambassadorId == nil then
        return {error = "No ambassador assigned"}
    end
    local ambassador = airtable.get_record("Ambassadors", ambassadorId[1])
    if ambassador == nil then
        return {error = "Ambassador not found"}
    end
    local pfp = ambassador.fields.pfp and ambassador.fields.pfp[1] and ambassador.fields.pfp[1].thumbnails and ambassador.fields.pfp[1].thumbnails.full.url or nil
    return {email = ambassador.fields.email, slackId = ambassador.fields.slack_id, pfp = pfp}
end)

-- LEADER MANAGEMENT

server:get("/leader", function(req, res)
    log.request(req:uri(), req:headers())
    local params = url.parse_query(req:uri())
    if params.email == nil then
        return {error = "Missing email parameter"}
    end
    local formula = airtable.safeFormula("contact_email", params.email)
    local fields = {"rel_clubs"}
    if auth.checkRead(req:headers().authorization) then
        local leader = airtable.list_records("Leaders", nil, {filterByFormula = formula, timeZone = "America/New_York", fields = fields}).records[1]
        if leader == nil then
            return {club_name = nil, club_status = nil}
        end
        local club = leader.fields.rel_clubs and leader.fields.rel_clubs[1] or nil
        if club == nil then
            return {club_name = nil, club_status = nil}
        end
        local clubRecord = airtable.get_record("Clubs", club)
        if clubRecord == nil then
            return {club_name = nil, club_status = nil}
        end
        return {club_name = clubRecord.fields.club_name, club_status = clubRecord.fields.status}
    elseif keyProvided(req) then
        return unauthorized(res)
    else
        local leader = airtable.list_records("Leaders", nil, {filterByFormula = formula, timeZone = "America/New_York", fields = fields})
        if leader.records[1] == nil then
            return {leader = false}
        else
            return {leader = true}
        end
    end
end)

server:get("/leader/slack", function(req, res)
    log.request(req:uri(), req:headers())
    local params = url.parse_query(req:uri())
    if params.slackid == nil then
        return {error = "Missing slackid parameter"}
    end
    local formula = airtable.safeFormula("contact_slack", params.slackid)
    local fields = {"rel_clubs"}
    if auth.checkRead(req:headers().authorization) then
        local leader = airtable.list_records("Leaders", nil, {filterByFormula = formula, timeZone = "America/New_York", fields = fields}).records[1]
        if leader == nil then
            return {club_name = nil, club_status = nil}
        end
        local club = leader.fields.rel_clubs and leader.fields.rel_clubs[1] or nil
        if club == nil then
            return {club_name = nil, club_status = nil}
        end
        local clubRecord = airtable.get_record("Clubs", club)
        if clubRecord == nil then
            return {club_name = nil, club_status = nil}
        end
        return {club_name = clubRecord.fields.club_name, club_status = clubRecord.fields.status}
    elseif keyProvided(req) then
        return unauthorized(res)
    else
        local leader = airtable.list_records("Leaders", nil, {filterByFormula = formula, timeZone = "America/New_York", fields = fields})
        if leader.records[1] == nil then
            return {leader = false}
        else
            return {leader = true}
        end
    end
end)

server:get("/leader/name", function(req, res)
    log.request(req:uri(), req:headers())
    if auth.checkRead(req:headers().authorization) then
        local params = url.parse_query(req:uri())
        if params.email == nil then
            return {error = "Missing email parameter"}
        end
        local formula = airtable.safeFormula("contact_email", params.email)
        local fields = {"name_first", "name_last"}
        local leader = airtable.list_records("Leaders", nil, {filterByFormula = formula, timeZone = "America/New_York", fields = fields}).records[1]
        if leader == nil then
            return {error = "Leader not found"}
        end
        local first = leader.fields.name_first
        local last = leader.fields.name_last
        local name
        if first and last then
            name = first .. " " .. last
        else
            name = first or last
        end
        return {name = name}
    else
        return unauthorized(res)
    end
end)

-- SHIP MANAGEMENT

server:get("/ships", function(req, res)
    log.request(req:uri(), req:headers())
    local params = url.parse_query(req:uri())
    if params.club_name == nil then
        return {error = "Missing club_name parameter"}
    end
    local memberFormula = airtable.safeFormula("club_name (from rel_club)", params.club_name)
    local memberResult = airtable.list_records("Members", nil, {filterByFormula = memberFormula, fields = {"email"}})
    if not memberResult or not memberResult.records then
        return {error = "Failed to look up club members"}
    end
    local emails = {}
    for _, member in ipairs(memberResult.records) do
        if member.fields.email then
            table.insert(emails, member.fields.email)
        end
    end
    if #emails == 0 then
        return {}
    end
    local formula = orFormula("Email", emails)
    if auth.checkRead(req:headers().authorization) then
        local ships = airtable.list_records("Unified DB Projects", nil, {filterByFormula = formula, timeZone = "America/New_York"}).records
        return ships
    elseif keyProvided(req) then
        return unauthorized(res)
    else
        local fields = {"YSWS", "Code URL", "Playable URL"}
        local ships = airtable.list_records("Unified DB Projects", nil, {filterByFormula = formula, timeZone = "America/New_York", fields = fields}).records
        return ships
    end
end)

-- MEMBER MANAGEMENT

server:get("/member/ships", function(req, res)
    log.request(req:uri(), req:headers())
    if auth.checkRead(req:headers().authorization) then
        local params = url.parse_query(req:uri())
        if params.email == nil then
            return {error = "Missing email parameter"}
        end
        local formula = airtable.safeFormula("Email", params.email)
        local ships = airtable.list_records("Unified DB Projects", nil, {filterByFormula = formula, timeZone = "America/New_York"}).records
        return ships
    else
        return unauthorized(res)
    end
end)

server:get("/member", function(req, res)
    log.request(req:uri(), req:headers())
    if auth.checkRead(req:headers().authorization) then
        local params = url.parse_query(req:uri())
        if params.name == nil then
            return {error = "Missing name parameter"}
        end
        local formula = airtable.safeFormula("name", params.name)
        local fields = {"name", "club_name (from rel_club)", "email"}
        local member = airtable.list_records("Members", nil, {filterByFormula = formula, timeZone = "America/New_York", fields = fields}).records[1]
        if member == nil then
            return {error = "Member not found"}
        end
        local clubName = member.fields["club_name (from rel_club)"]
        local name = clubName and clubName[1] or nil
        local email = member.fields.email
        return {name = name, email = email}
    else
        return unauthorized(res)
    end
end)

server:get("/member/email", function(req, res)
    log.request(req:uri(), req:headers())
    if auth.checkRead(req:headers().authorization) then
        local params = url.parse_query(req:uri())
        if params.email == nil then
            return {error = "Missing email parameter"}
        end
        local formula = airtable.safeFormula("email", params.email)
        local fields = {"name", "club_name (from rel_club)"}
        local member = airtable.list_records("Members", nil, {filterByFormula = formula, timeZone = "America/New_York", fields = fields}).records[1]
        if member == nil then
            return {error = "Member not found"}
        end
        local clubName = member.fields["club_name (from rel_club)"]
        return {club_name = clubName and clubName[1] or nil}
    else
        return unauthorized(res)
    end
end)

server:get("/member/name", function(req, res)
    log.request(req:uri(), req:headers())
    if auth.checkRead(req:headers().authorization) then
        local params = url.parse_query(req:uri())
        if params.email == nil then
            return {error = "Missing email parameter"}
        end
        local formula = airtable.safeFormula("email", params.email)
        local fields = {"name"}
        local member = airtable.list_records("Members", nil, {filterByFormula = formula, timeZone = "America/New_York", fields = fields}).records[1]
        if member == nil then
            return {error = "Member not found"}
        end
        return {name = member.fields.name}
    else
        return unauthorized(res)
    end
end)

server:get("/member/slack", function(req, res)
    log.request(req:uri(), req:headers())
    if auth.checkRead(req:headers().authorization) then
        local params = url.parse_query(req:uri())
        if params.slackid == nil then
            return {error = "Missing slackid parameter"}
        end
        local formula = airtable.safeFormula("contact_slack", params.slackid)
        local fields = {"name", "club_name (from rel_club)"}
        local member = airtable.list_records("Members", nil, {filterByFormula = formula, timeZone = "America/New_York", fields = fields}).records[1]
        if member == nil then
            return {error = "Member not found"}
        end
        local clubName = member.fields["club_name (from rel_club)"]
        return {club_name = clubName and clubName[1] or nil}
    else
        return unauthorized(res)
    end
end)

server:delete("/member", function(req, res)
    log.request(req:uri(), req:headers())
    if auth.checkWrite(req:headers().authorization) then
        local params = url.parse_query(req:uri())
        if params.name == nil then
            return {error = "Missing name parameter"}
        end
        local formula = airtable.safeFormula("name", params.name)
        local member = airtable.list_records("Members", nil, {filterByFormula = formula}).records[1]
        if member == nil then
            return {error = "Member not found"}
        end
        local result = airtable.delete_record("Members", member.id)
        if result and result.deleted then
            return {deleted = true, id = result.id}
        else
            return {error = "Failed to delete member"}
        end
    else
        return unauthorized(res)
    end
end)

server:post("/member", function(req, res)
    log.request(req:uri(), req:headers())
    if auth.checkWrite(req:headers().authorization) then
        local params = url.parse_query(req:uri())
        if params.name == nil then
            return {error = "Missing name parameter"}
        end
        local formula = airtable.safeFormula("name", params.name)
        local member = airtable.list_records("Members", nil, {filterByFormula = formula}).records[1]
        if member == nil then
            return {error = "Member not found"}
        end
        local updates = {}
        if params.new_name then
            updates["name"] = url.strip_quotes(params.new_name)
        end
        if params.new_email then
            updates["email"] = url.strip_quotes(params.new_email)
        end
        if next(updates) == nil then
            return {error = "No updates provided"}
        end
        local updated = airtable.update_record("Members", member.id, updates)
        if updated then
            return {name = updated.fields.name, email = updated.fields.email}
        else
            return {error = "Failed to update member"}
        end
    else
        return unauthorized(res)
    end
end)

server:post("/member/create", function(req, res)
    log.request(req:uri(), req:headers())
    return notImplemented(res)
end)


server:get("/members", function(req, res)
    log.request(req:uri(), req:headers())
    if auth.checkRead(req:headers().authorization) then
        local params = url.parse_query(req:uri())
        if params.club_name == nil then
            return {error = "Missing club_name parameter"}
        end
        local formula = airtable.safeFormula("club_name", params.club_name)
        local club = airtable.list_records("Clubs", nil, {filterByFormula = formula, timeZone = "America/New_York", fields = {"club_name"}}).records[1]
        if club == nil then
            return {error = "Club not found"}
        end
        local memberFormula = airtable.safeFormula("club_name (from rel_club)", params.club_name)
        local memberResult = airtable.list_records("Members", nil, {filterByFormula = memberFormula, fields = {"name"}})
        local memberNames = {}
        if memberResult and memberResult.records then
            for _, member in ipairs(memberResult.records) do
                if member.fields.name then
                    table.insert(memberNames, member.fields.name)
                end
            end
        end
        return {members = memberNames}
    else
        return unauthorized(res)
    end
end)

-- LEVEL/STATUS MANAGEMENT

server:get("/level", function(req)
    log.request(req:uri(), req:headers())
    local params = url.parse_query(req:uri())
    if params.club_name == nil then
        return {error = "Missing club_name parameter"}
    end
    local formula = airtable.safeFormula("club_name", params.club_name)
    local fields = {"level"}
    local level = airtable.list_records("Clubs", nil, {filterByFormula = formula, timeZone = "America/New_York", fields = fields}).records[1]
    if level == nil then
        return {level = "No club found"}
    end
    return {level = level.fields.level}
end)

server:get("/status", function(req)
    log.request(req:uri(), req:headers())
    local params = url.parse_query(req:uri())
    if params.club_name == nil then
        return {error = "Missing club_name parameter"}
    end
    local formula = airtable.safeFormula("club_name", params.club_name)
    local fields = {"status"}
    local status = airtable.list_records("Clubs", nil, {filterByFormula = formula, timeZone = "America/New_York", fields = fields}).records[1]
    if status == nil then
        return {status = "No club found"}
    end
    return {status = status.fields.status}
end)

server:get("/dormant", function(req)
    log.request(req:uri(), req:headers())
    local params = url.parse_query(req:uri())
    if params.club_name == nil then
        return {error = "Missing club_name parameter"}
    end
    local formula = airtable.safeFormula("club_name", params.club_name)
    local fields = {"status"}
    local club = airtable.list_records("Clubs", nil, {filterByFormula = formula, timeZone = "America/New_York", fields = fields}).records[1]
    if club == nil then
        return {error = "Club not found"}
    end
    return {club_name = url.strip_quotes(params.club_name), dormant = club.fields.status == "Dormant"}
end)

------------------
-- POST RECORDS --
------------------

-- LEADER MANAGEMENT

server:post("/leader", function(req, res)
    log.request(req:uri(), req:headers())
    if auth.checkWrite(req:headers().authorization) then
        local params = url.parse_query(req:uri())
        local email = params.email
        local new_email = params.new_email
        if email == nil or new_email == nil then
            return {error = "Missing email"}
        end
        local formula = airtable.safeFormula("contact_email", email)
        local leader = airtable.list_records("Leaders", nil, {filterByFormula = formula}).records[1]
        if leader == nil then
            return {error = "Leader not found"}
        end
        local id = leader.id
        local updateLeader = airtable.update_record("Leaders", id, {contact_email = url.strip_quotes(new_email)})
        return {new_email = updateLeader.fields.contact_email}
    else
        return unauthorized(res)
    end
end)

server:post("/leader/change", function(req, res)
    log.request(req:uri(), req:headers())
    if auth.checkWrite(req:headers().authorization) then
        local params = url.parse_query(req:uri())
        local club_name = params.club
        local new_email = params.new_email
        local old_email = params.old_email

        if club_name == nil or new_email == nil or old_email == nil then
            return {error = "Missing parameters (club, new_email, old_email)"}
        end

        local club_name_clean = url.strip_quotes(club_name)
        local new_email_clean = url.strip_quotes(new_email)
        local old_email_clean = url.strip_quotes(old_email)

        -- 1. Find the club to link
        local clubFormula = airtable.safeFormula("club_name", club_name_clean)
        local clubData = airtable.list_records("Clubs", nil, {filterByFormula = clubFormula})
        if not clubData or not clubData.records or #clubData.records == 0 then
            return {error = "Club not found"}
        end
        local club_id = clubData.records[1].id

        -- 2. Create the new leader record linked to the club
        local new_leader_fields = {
            ["contact_email"] = new_email_clean,
            ["rel_clubs"] = { club_id }
        }
        local created_leader = airtable.create_record("Leaders", new_leader_fields)
        if not created_leader then
            return {error = "Failed to create new leader record"}
        end

        -- 3. Clear the old leader's club relations
        local oldFormula = airtable.safeFormula("contact_email", old_email_clean)
        local oldData = airtable.list_records("Leaders", nil, {filterByFormula = oldFormula})
        if oldData and oldData.records and #oldData.records > 0 then
            airtable.update_record("Leaders", oldData.records[1].id, {
                ["rel_clubs"] = {}
            })
        end

        return {
            success = true,
            new_leader_id = created_leader.id
        }
    else
        return unauthorized(res)
    end
end)

-- LEVEL/STATUS MANAGEMENT

server:post("/status", function(req, res)
    log.request(req:uri(), req:headers())
    if auth.checkWrite(req:headers().authorization) then
        local params = url.parse_query(req:uri())
        local status = params.status
        local club_name = params.club_name
        if status == nil or club_name == nil then
            return {error = "Missing parameters"}
        end
        local formula = airtable.safeFormula("club_name", club_name)
        local club = airtable.list_records("Clubs", nil, {filterByFormula = formula}).records[1]
        if club == nil then
            return {error = "Club not found"}
        end
        local id = club.id
        local updateClub = airtable.update_record("Clubs", id, {status = url.strip_quotes(status)})
        return {new_status = updateClub.fields.status}
    else
        return unauthorized(res)
    end
end)

server:post("/level", function(req, res)
    log.request(req:uri(), req:headers())
    if auth.checkWrite(req:headers().authorization) then
        local params = url.parse_query(req:uri())
        local level = params.level
        local club_name = params.club_name
        if level == nil or club_name == nil then
            return {error = "Missing parameters"}
        end
        local formula = airtable.safeFormula("club_name", club_name)
        local club = airtable.list_records("Clubs", nil, {filterByFormula = formula}).records[1]
        if club == nil then
            return {error = "Club not found"}
        end
        local id = club.id
        local updateClub = airtable.update_record("Clubs", id, {level = url.strip_quotes(level)})
        return {new_level = updateClub.fields.level}
    else
        return unauthorized(res)
    end
end)

server:post("/dormant", function(req, res)
    log.request(req:uri(), req:headers())
    if auth.checkWrite(req:headers().authorization) then
        local params = url.parse_query(req:uri())
        local club_name = params.club_name
        local dormant = params.dormant
        if club_name == nil or dormant == nil then
            return {error = "Missing parameters (club_name, dormant)"}
        end
        local dormantClean = url.strip_quotes(dormant)
        if dormantClean ~= "true" and dormantClean ~= "false" then
            return {error = "Invalid dormant value, must be true or false"}
        end
        local formula = airtable.safeFormula("club_name", club_name)
        local club = airtable.list_records("Clubs", nil, {filterByFormula = formula}).records[1]
        if club == nil then
            return {error = "Club not found"}
        end
        local newStatus = dormantClean == "true" and "Dormant" or "Active"
        local updateClub = airtable.update_record("Clubs", club.id, {status = newStatus})
        return {club_name = url.strip_quotes(club_name), dormant = updateClub.fields.status == "Dormant"}
    else
        return unauthorized(res)
    end
end)

-- API KEY MANAGEMENT

server:post("/key/create", function(req, res)
    log.request(req:uri(), req:headers())
    if auth.checkAdmin(req:headers().authorization) then
        local params = url.parse_query(req:uri())
        if params.name == nil or params.perms == nil then
            return {error = "Missing parameters (name, perms)"}
        end
        local name = url.strip_quotes(params.name)
        local perms = url.strip_quotes(params.perms)
        if not auth.isDelegablePerms(perms) then
            return {success = false, error = "invalid_perms (must be read or write; admin keys can only be created in the admin panel)"}
        end
        local created, err = auth.createKey(name, perms)
        if created then
            admin.audit("api key: " .. auth.getKeyName(req:headers().authorization), "key.create", created, "perms: " .. created.perms)
            return {success = true, key = created.key, name = created.name, perms = created.perms}
        else
            return {success = false, error = err or "Failed to create key"}
        end
    else
        return unauthorized(res)
    end
end)

server:post("/key/revoke", function(req, res)
    log.request(req:uri(), req:headers())
    if auth.checkAdmin(req:headers().authorization) then
        local params = url.parse_query(req:uri())
        if params.key == nil then
            return {success = false}
        end
        local actor = "api key: " .. auth.getKeyName(req:headers().authorization)
        local revoked = auth.revokeKey(url.strip_quotes(params.key))
        if revoked then
            admin.audit(actor, "key.delete", revoked, "revoked via /key/revoke")
            return {success = true, owner_email = revoked.name or ""}
        else
            return {success = false}
        end
    else
        return unauthorized(res)
    end
end)

-----------------
-- ADMIN PANEL --
-----------------

local ADMIN_REQUEST_HEADER = "clubapi-admin"
local MAX_KEY_NAME_LENGTH = 200

local ADMIN_ERRORS = {
    email_taken = "That email already belongs to an admin",
    not_removable = "An admin needs at least one email; remove the admin instead",
}

local adminPages = {
    login = fs.read_file("admin/login.html"),
    dashboard = fs.read_file("admin/dashboard.html"),
}

local function html(res, body)
    res:set_header("Content-Type", "text/html; charset=utf-8")
    res:set_header("Cache-Control", "no-store")
    res:set_header("X-Frame-Options", "DENY")
    return body
end

local function redirect(res, location)
    res:set_status_code(302)
    res:set_header("Location", location)
    return ""
end

local function failure(res, status, message)
    res:set_status_code(status)
    return {error = message}
end

local function jsonBody(req)
    local ok, body = pcall(function()
        return req:body():json()
    end)
    if ok and type(body) == "table" then
        return body
    end
    return {}
end

local function keyName(value)
    if type(value) ~= "string" then
        return nil
    end
    local name = value:gsub("^%s+", ""):gsub("%s+$", "")
    if name == "" or #name > MAX_KEY_NAME_LENGTH then
        return nil
    end
    return name
end

local function sameId(a, b)
    return a ~= nil and b ~= nil and tostring(a) == tostring(b)
end

local function ownerScope(ctx)
    if ctx.actor.is_superadmin then
        return nil
    end
    return ctx.actor.id
end

local function managedKey(ctx, id)
    local key = auth.getKeyById(id)
    if not key then
        return nil
    end
    if ctx.actor.is_superadmin or sameId(key.owner_admin_id, ctx.actor.id) then
        return key
    end
    return nil
end

local function auditAs(ctx, action, key, detail)
    local note = detail
    if ctx.impersonating then
        local suffix = "viewing as " .. tostring(ctx.actor.name)
        note = note and (note .. " (" .. suffix .. ")") or suffix
    end
    admin.audit(ctx.email, action, key, note)
end

local function adminOnly(handler, options)
    options = options or {}
    return function(req, res)
        res:set_header("Cache-Control", "no-store")
        local ctx = admin.session(req)
        if not ctx then
            return failure(res, 401, "Not signed in")
        end
        if options.mutating and req:headers()["x-requested-with"] ~= ADMIN_REQUEST_HEADER then
            return failure(res, 403, "Missing admin request header")
        end
        if options.superadmin and not ctx.actor.is_superadmin then
            return failure(res, 403, "Only the superadmin can do that")
        end
        if options.realSuperadmin and not ctx.real.is_superadmin then
            return failure(res, 403, "Only the superadmin can do that")
        end
        return handler(req, res, ctx)
    end
end

local function validOwner(value)
    if value == nil or value == "" then
        return ""
    end
    if admin.exists(value) then
        return tostring(value)
    end
    return nil
end

rawGet(server, "/admin", function(req, res)
    if admin.session(req) then
        return html(res, adminPages.dashboard)
    end
    return html(res, adminPages.login)
end)

rawGet(server, "/admin/login", function(req, res)
    if not admin.isConfigured() then
        return redirect(res, "/admin?error=not_configured")
    end
    local stateToken = admin.randomToken()
    if not stateToken then
        return redirect(res, "/admin?error=auth_failed")
    end
    res:set_header("Set-Cookie", admin.cookieHeader(admin.STATE_COOKIE, stateToken, admin.STATE_TTL_SECONDS))
    return redirect(res, admin.authorizeUrl(stateToken))
end)

rawGet(server, "/admin/callback", function(req, res)
    local params = url.parse_query(req:uri())
    if params.error then
        return redirect(res, "/admin?error=auth_failed")
    end
    local code = url.strip_quotes(params.code)
    local returnedState = url.strip_quotes(params.state)
    local expectedState = admin.readCookie(req, admin.STATE_COOKIE)
    if not code or not returnedState or not expectedState or returnedState ~= expectedState then
        return redirect(res, "/admin?error=state_mismatch")
    end

    local accessToken, tokenErr = admin.exchangeCode(code)
    if not accessToken then
        print({ error = "admin_login_failed", reason = tokenErr })
        return redirect(res, "/admin?error=auth_failed")
    end
    local user, userErr = admin.fetchUser(accessToken)
    if not user then
        print({ error = "admin_login_failed", reason = userErr })
        return redirect(res, "/admin?error=auth_failed")
    end
    if user.email_verified == false then
        return redirect(res, "/admin?error=unverified")
    end
    local email = admin.normalizeEmail(user.email)
    if not email or not admin.findByEmail(email) then
        print({ error = "admin_login_rejected", reason = "email_not_an_admin" })
        return redirect(res, "/admin?error=not_allowed")
    end

    local session = admin.createSession(email)
    if not session then
        return redirect(res, "/admin?error=auth_failed")
    end
    admin.audit(email, "login")
    res:set_header("Set-Cookie", admin.cookieHeader(admin.SESSION_COOKIE, session, admin.SESSION_TTL_SECONDS))
    return redirect(res, "/admin")
end)

rawPost(server, "/admin/logout", adminOnly(function(req, res, ctx)
    admin.destroySession(req)
    admin.audit(ctx.email, "logout")
    res:set_header("Set-Cookie", admin.cookieHeader(admin.SESSION_COOKIE, "", 0))
    return {success = true}
end, {mutating = true}))

rawGet(server, "/admin/api/me", adminOnly(function(_, _, ctx)
    return {
        email = ctx.email,
        admin_id = ctx.actor.id,
        name = ctx.actor.name,
        is_superadmin = ctx.actor.is_superadmin,
        impersonating = ctx.impersonating,
        real_name = ctx.real.name,
        real_is_superadmin = ctx.real.is_superadmin,
    }
end))

rawPost(server, "/admin/api/impersonate", adminOnly(function(req, res, ctx)
    local target = jsonBody(req).id
    if not admin.exists(target) then
        return failure(res, 404, "Admin not found")
    end
    if not admin.setImpersonation(req, target) then
        return failure(res, 500, "Couldn't start impersonating")
    end
    admin.audit(ctx.email, "impersonate.start", nil, "admin #" .. tostring(target))
    return {success = true}
end, {mutating = true, realSuperadmin = true}))

rawPost(server, "/admin/api/impersonate/stop", adminOnly(function(req, res, ctx)
    if not admin.setImpersonation(req, nil) then
        return failure(res, 500, "Couldn't stop impersonating")
    end
    if ctx.impersonating then
        admin.audit(ctx.email, "impersonate.stop", nil, "was viewing as " .. tostring(ctx.actor.name))
    end
    return {success = true}
end, {mutating = true, realSuperadmin = true}))

rawGet(server, "/admin/api/overview", adminOnly(function(_, res, ctx)
    local overview = requestlog.overview(ownerScope(ctx))
    if not overview then
        return failure(res, 500, "Couldn't load overview")
    end
    return overview
end))

rawGet(server, "/admin/api/keys", adminOnly(function(_, res, ctx)
    local keys = auth.listKeys(ownerScope(ctx))
    if not keys then
        return failure(res, 500, "Couldn't load keys")
    end
    if not ctx.actor.is_superadmin then
        for _, key in ipairs(keys) do
            key.key_suffix = nil
            key.created_by_name = nil
        end
    end
    return {keys = keys}
end))

rawPost(server, "/admin/api/keys/create", adminOnly(function(req, res, ctx)
    local body = jsonBody(req)
    local name = keyName(body.name)
    if not name then
        return failure(res, 400, "Name is required (max " .. MAX_KEY_NAME_LENGTH .. " characters)")
    end

    local owner = ctx.actor.id
    if ctx.actor.is_superadmin then
        if not auth.isValidPerms(body.perms) then
            return failure(res, 400, "Perms must be read, write, or admin")
        end
        owner = validOwner(body.owner_id)
        if owner == nil then
            return failure(res, 400, "Owner must be one of your admins")
        end
    elseif not auth.isDelegablePerms(body.perms) then
        return failure(res, 403, "You can only create read or write keys")
    end

    local created, err = auth.createKey(name, body.perms, owner, ctx.real.id)
    if not created then
        return failure(res, 500, err or "Failed to create key")
    end
    auditAs(ctx, "key.create", created, "perms: " .. created.perms)
    return {id = created.id, name = created.name, perms = created.perms, key = created.key}
end, {mutating = true}))

rawPost(server, "/admin/api/keys/rotate", adminOnly(function(req, res, ctx)
    local key = managedKey(ctx, jsonBody(req).id)
    if not key then
        return failure(res, 404, "Key not found")
    end
    local rotated = auth.rotateKeyById(key.id)
    if not rotated then
        return failure(res, 500, "Failed to rotate key")
    end
    auditAs(ctx, "key.rotate", rotated)
    return {id = rotated.id, name = rotated.name, perms = rotated.perms, key = rotated.key}
end, {mutating = true}))

rawPost(server, "/admin/api/keys/perms", adminOnly(function(req, res, ctx)
    local body = jsonBody(req)
    local key = managedKey(ctx, body.id)
    if not key then
        return failure(res, 404, "Key not found")
    end
    if ctx.actor.is_superadmin then
        if not auth.isValidPerms(body.perms) then
            return failure(res, 400, "Perms must be read, write, or admin")
        end
    else
        if key.perms == "admin" then
            return failure(res, 403, "Only the superadmin can change an admin key's perms")
        end
        if not auth.isDelegablePerms(body.perms) then
            return failure(res, 403, "You can only set read or write")
        end
    end
    local updated = auth.setPermsById(key.id, body.perms)
    if not updated then
        return failure(res, 500, "Failed to update perms")
    end
    auditAs(ctx, "key.perms", updated, tostring(updated.old_perms) .. " -> " .. updated.perms)
    return {id = updated.id, name = updated.name, perms = updated.perms}
end, {mutating = true}))

rawPost(server, "/admin/api/keys/rename", adminOnly(function(req, res, ctx)
    local body = jsonBody(req)
    local name = keyName(body.name)
    if not name then
        return failure(res, 400, "Name is required (max " .. MAX_KEY_NAME_LENGTH .. " characters)")
    end
    local key = managedKey(ctx, body.id)
    if not key then
        return failure(res, 404, "Key not found")
    end
    local renamed = auth.renameKeyById(key.id, name)
    if not renamed then
        return failure(res, 500, "Failed to rename key")
    end
    auditAs(ctx, "key.rename", renamed, tostring(renamed.old_name) .. " -> " .. renamed.name)
    return {id = renamed.id, name = renamed.name, perms = renamed.perms}
end, {mutating = true}))

rawPost(server, "/admin/api/keys/delete", adminOnly(function(req, res, ctx)
    local key = managedKey(ctx, jsonBody(req).id)
    if not key then
        return failure(res, 404, "Key not found")
    end
    local deleted = auth.deleteKeyById(key.id)
    if not deleted then
        return failure(res, 500, "Failed to delete key")
    end
    auditAs(ctx, "key.delete", deleted, "perms: " .. deleted.perms)
    return {success = true, id = deleted.id}
end, {mutating = true}))

rawPost(server, "/admin/api/keys/owner", adminOnly(function(req, res, ctx)
    local body = jsonBody(req)
    local owner = validOwner(body.owner_id)
    if owner == nil then
        return failure(res, 400, "Owner must be one of your admins")
    end
    local updated, err = auth.setOwnerById(body.id, owner)
    if not updated then
        return failure(res, err == "invalid_id" and 400 or 404, "Key not found")
    end
    auditAs(ctx, "key.owner", updated, owner == "" and "unassigned" or ("admin #" .. owner))
    return {id = updated.id, owner_admin_id = updated.owner_admin_id}
end, {mutating = true, superadmin = true}))

rawPost(server, "/admin/api/keys/reveal", adminOnly(function(req, res, ctx)
    local revealed = auth.revealKeyById(jsonBody(req).id)
    if not revealed then
        return failure(res, 404, "Key not found")
    end
    auditAs(ctx, "key.reveal", revealed)
    return {id = revealed.id, name = revealed.name, perms = revealed.perms, key = revealed.key}
end, {mutating = true, superadmin = true}))

rawGet(server, "/admin/api/requests", adminOnly(function(req, res, ctx)
    local params = url.parse_query(req:uri())
    local rows, limit = requestlog.list({
        owner = ownerScope(ctx),
        key = url.strip_quotes(params.key),
        status = url.strip_quotes(params.status),
        path = url.strip_quotes(params.path),
        before = url.strip_quotes(params.before),
        limit = url.strip_quotes(params.limit),
    })
    if not rows then
        return failure(res, 500, "Couldn't load requests")
    end
    local nextBefore = nil
    if #rows == limit then
        nextBefore = rows[#rows].id
    end
    return {requests = rows, next_before = nextBefore}
end))

rawGet(server, "/admin/api/audit", adminOnly(function(_, res)
    local entries = admin.auditLog()
    if not entries then
        return failure(res, 500, "Couldn't load audit log")
    end
    return {entries = entries}
end, {superadmin = true}))

rawGet(server, "/admin/api/admins", adminOnly(function(_, res)
    local admins = admin.listAdmins()
    if not admins then
        return failure(res, 500, "Couldn't load admins")
    end
    return {admins = admins}
end, {superadmin = true}))

rawPost(server, "/admin/api/admins/create", adminOnly(function(req, res, ctx)
    local body = jsonBody(req)
    local name = admin.normalizeName(body.name)
    local email = admin.normalizeEmail(body.email)
    if not name or not email then
        return failure(res, 400, "A name and a valid email are required")
    end
    local created, err = admin.createAdmin(name, email)
    if not created then
        return failure(res, err == "email_taken" and 409 or 500, ADMIN_ERRORS[err] or "Failed to add admin")
    end
    auditAs(ctx, "admin.create", nil, created.name .. " <" .. email .. ">")
    return {id = created.id, name = created.name}
end, {mutating = true, superadmin = true}))

rawPost(server, "/admin/api/admins/rename", adminOnly(function(req, res, ctx)
    local body = jsonBody(req)
    local name = admin.normalizeName(body.name)
    if not name then
        return failure(res, 400, "A name is required")
    end
    local renamed = admin.renameAdmin(body.id, name)
    if not renamed then
        return failure(res, 404, "Admin not found")
    end
    auditAs(ctx, "admin.rename", nil, "admin #" .. tostring(renamed.id) .. " -> " .. renamed.name)
    return {id = renamed.id, name = renamed.name}
end, {mutating = true, superadmin = true}))

rawPost(server, "/admin/api/admins/delete", adminOnly(function(req, res, ctx)
    local removed = admin.removeAdmin(jsonBody(req).id)
    if not removed then
        return failure(res, 404, "Admin not found (the superadmin can't be removed)")
    end
    auditAs(ctx, "admin.delete", nil, removed.name)
    return {success = true, id = removed.id}
end, {mutating = true, superadmin = true}))

rawPost(server, "/admin/api/admins/emails/add", adminOnly(function(req, res, ctx)
    local body = jsonBody(req)
    local email = admin.normalizeEmail(body.email)
    if not email then
        return failure(res, 400, "A valid email is required")
    end
    local added, err = admin.addEmail(body.id, email)
    if not added then
        return failure(res, err == "email_taken" and 409 or 404, ADMIN_ERRORS[err] or "Admin not found")
    end
    auditAs(ctx, "admin.email.add", nil, email .. " -> admin #" .. tostring(added.admin_id))
    return {email = added.email, admin_id = added.admin_id}
end, {mutating = true, superadmin = true}))

rawPost(server, "/admin/api/admins/emails/remove", adminOnly(function(req, res, ctx)
    local email = admin.normalizeEmail(jsonBody(req).email)
    if not email then
        return failure(res, 400, "A valid email is required")
    end
    local removed, err = admin.removeEmail(email)
    if not removed then
        return failure(res, 409, ADMIN_ERRORS[err] or "Couldn't remove that email")
    end
    auditAs(ctx, "admin.email.remove", nil, email .. " from admin #" .. tostring(removed.admin_id))
    return {success = true}
end, {mutating = true, superadmin = true}))

db.migrate()
pruneExpiredData()

server.port = os.getenv("PORT")
server.hostname = os.getenv("HOST")
print("Server running on port " .. server.port .. " at " .. server.hostname)
server:run()
