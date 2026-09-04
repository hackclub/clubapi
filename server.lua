local server = require("http").server.new()
local airtable = require("utils/airtable")
local url = require("utils/urlparams")
local auth = require("utils/auth")
local log = require("utils/logging")

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


-----------------
-- GET RECORDS --
-----------------


server:static_file("/", "docs.html")
server:static_file("/openapi.yaml", "openapi.yaml")


-- CLUB MANAGEMENT

server:get("/clubs", function(req)
    log.request(req:uri(), req:headers())
    return {totalClubs = airtable.count_records("Clubs")}
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
    local formula = airtable.safeFormula("venue_addr_country", params.country)
    return {clubs = airtable.count_records("Clubs", formula)}
end)

server:get("/clubs/level", function(req)
    log.request(req:uri(), req:headers())
    local params = url.parse_query(req:uri())
    if params.level == nil then
        return {error = "Missing level parameter"}
    end
    local stripped = url.strip_quotes(params.level)
    local levelValue = "level " .. airtable.sanitizeFormulaValue(stripped)
    local formula = airtable.safeFormula("level", levelValue)
    return {clubs = airtable.count_records("Clubs", formula)}
end)

server:get("/club/code", function(req, res)
    log.request(req:uri(), req:headers())
    return notImplemented(res)
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

server:get("/member/code", function(req, res)
    log.request(req:uri(), req:headers())
    return notImplemented(res)
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
        return clubName and clubName[1] or nil
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
        return clubName and clubName[1] or nil
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
        local fields = {"rel_members"}
        local club = airtable.list_records("Clubs", nil, {filterByFormula = formula, timeZone = "America/New_York", fields = fields}).records[1]
        if club == nil then
            return {error = "Club not found"}
        end
        local memberIds = club.fields.rel_members
        if memberIds == nil then
            return {members = {}}
        end
        local memberNames = {}
        for _, memberId in ipairs(memberIds) do
            local member = airtable.get_record("Members", memberId)
            if member then
                table.insert(memberNames, member.fields.name)
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

server:get("/suspension", function(req, res)
    log.request(req:uri(), req:headers())
    return notImplemented(res)
end)

server:get("/tokens", function(req, res)
    log.request(req:uri(), req:headers())
    return notImplemented(res)
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

server:post("/suspension", function(req, res)
    log.request(req:uri(), req:headers())
    return notImplemented(res)
end)

server:post("/tokens", function(req, res)
    log.request(req:uri(), req:headers())
    return notImplemented(res)
end)

-- ANNOUNCEMENT MANAGEMENT

server:post("/announce", function(req, res)
    log.request(req:uri(), req:headers())
    return notImplemented(res)
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
        local created, err = auth.createKey(name, perms)
        if created then
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
        local revoked = auth.revokeKey(url.strip_quotes(params.key))
        if revoked then
            return {success = true, owner_email = revoked.name or ""}
        else
            return {success = false}
        end
    else
        return unauthorized(res)
    end
end)

server.port = os.getenv("PORT")
server.hostname = os.getenv("HOST")
print("Server running on port " .. server.port .. " at " .. server.hostname)
server:run()
