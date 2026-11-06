-- BWCoop admin commands: host-only tools driven through the game's own cheat component
-- (UMistCheatingComponent). Backend for the future in-game admin panel.
--
-- Every player controller has a cheat component. Called on the host, its Server functions
-- run locally, so calling a friend's component acts on that friend (items, XP, perk points),
-- and calling the host's own acts on the host or on whatever the host is looking at.
-- Shared things (money, renown, time, weather) use the host's component.
--
-- Loaded by main.lua: dofile(...)(api) returns a table of command handlers.

return function(api)
    local log, valid, playerInfo = api.log, api.valid, api.playerInfo

    local function allPlayers()
        local list = {}
        for _, pc in ipairs(FindAllOf("MistOasisPlayerController") or {}) do
            local info = playerInfo(pc)
            if info then list[#list + 1] = info end
        end
        table.sort(list, function(a, b) return a.name < b.name end)
        return list
    end

    local function host()
        for _, p in ipairs(allPlayers()) do
            if p.isHost then return p end
        end
        return nil
    end

    -- "me" = host; otherwise a case-insensitive prefix of the character name ("penny").
    local function findPlayer(q)
        if q == nil then return nil, "missing player" end
        q = q:lower()
        if q == "me" then return host() end
        local hit = nil
        for _, p in ipairs(allPlayers()) do
            if p.name:lower():sub(1, #q) == q then
                if hit then return nil, "more than one player matches '" .. q .. "'" end
                hit = p
            end
        end
        if not hit then return nil, "no player matches '" .. q .. "'" end
        return hit
    end

    local function cheats(p)
        local cc = p and p.pc.CheatingComponent
        if not valid(cc) then error("no cheat component for " .. (p and p.name or "?")) end
        return cc
    end

    -- Runs one admin action, marks it as ours (so a future friend-cheat block lets it
    -- through) and writes it to the audit log.
    local function act(say, what, fn)
        api.adminCalling = true
        local ok, err = pcall(fn)
        api.adminCalling = false
        if ok then
            log("ADMIN " .. what)
            say("done: " .. what)
        else
            log("ADMIN FAILED " .. what .. ": " .. tostring(err))
            say("failed: " .. what .. " (" .. tostring(err) .. ")")
        end
    end

    local function num(s, default)
        local n = tonumber(s)
        if n == nil then return default end
        return math.floor(n)
    end

    local SKILLS = { "Strength", "Agility", "OneHanded", "TwoHanded", "Polearms", "Shields", "Archery",
        "Harvesting", "Farming", "AnimalHandling", "Cooking", "Crafting", "Researching", "Labourer" }

    -- The game matches skill names by substring and the last match wins, so pass full names.
    local function skillName(s)
        if s == nil then return nil end
        if s:lower() == "laborer" then return "Labourer" end -- US spelling; the game's name is Labourer
        for _, k in ipairs(SKILLS) do
            if k:lower() == s:lower() then return k end
        end
        for _, k in ipairs(SKILLS) do
            if k:lower():sub(1, #s) == s:lower() then return k end
        end
        return nil
    end

    local C = {}

    C.players = function(a, say)
        for _, p in ipairs(allPlayers()) do say("  " .. p.name .. (p.isHost and " (host)" or "")) end
    end

    -- Items. The game's give cheat wants the asset name (the item class without "_C", e.g. SmokedPieceMeat);
    -- players know the shown name ("Piece of Smoked Meat"). Every item template's default object is loaded
    -- with the game data, so one scan indexes both names (built on first use, kept for the session).
    local itemIndex = nil
    local function itemList()
        if itemIndex then return itemIndex end
        local list, seen = {}, {}
        local function add(o)
            pcall(function()
                local id = o:GetClass():GetFName():ToString():gsub("_C$", "")
                if id == "" or seen[id] or id:find("^SKEL_") or id:find("^REINST_") or id:find("^TRASHCLASS") then return end
                local shown = ""
                pcall(function() shown = o.Name:ToString() end)
                seen[id] = true
                list[#list + 1] = { id = id, name = shown or "" }
            end)
        end
        -- Default objects (RF_ClassDefaultObject = 0x10) of MistItemTemplate and every subclass.
        local ok, objs = pcall(FindObjects, 0, "MistItemTemplate", nil, 0x10, 0, false)
        if ok and type(objs) == "table" then
            for _, o in ipairs(objs) do add(o) end
        end
        table.sort(list, function(x, y) return x.id:lower() < y.id:lower() end)
        if #list > 0 then itemIndex = list end
        log(string.format("items: indexed %d item types", #list))
        return list
    end

    -- Item search: every word must appear in the asset name or the shown name (case ignored).
    local function findItems(query)
        local words = {}
        for w in query:lower():gmatch("%S+") do words[#words + 1] = w end
        local hits = {}
        for _, it in ipairs(itemList()) do
            local hay = (it.id .. " " .. it.name):lower()
            local all = #words > 0
            for _, w in ipairs(words) do
                if not hay:find(w, 1, true) then all = false break end
            end
            if all then hits[#hits + 1] = it end
        end
        return hits
    end

    -- The asset name for what the host typed: an asset name, a shown name, or a search with one result.
    local function resolveItem(query, say)
        local q = query:lower():gsub("^%s+", ""):gsub("%s+$", "")
        for _, it in ipairs(itemList()) do
            if it.id:lower() == q or it.name:lower() == q then return it.id end
        end
        local hits = findItems(q)
        if #hits == 1 then return hits[1].id end
        if #hits == 0 then
            say("items: nothing matches '" .. query .. "' (try fewer words: bwcoop items <text>)")
        else
            say(string.format("items: %d match '%s', pick one:", #hits, query))
            for i = 1, math.min(#hits, 15) do say(string.format("  %s  (%s)", hits[i].id, hits[i].name)) end
            if #hits > 15 then say(string.format("  ... and %d more", #hits - 15)) end
        end
        return nil
    end

    -- items <text>   search item names (asset name and the name shown in game)
    C.items = function(a, say)
        local query = table.concat(a, " ")
        if query == "" then return say("usage: bwcoop items <text>   e.g. items smoked meat") end
        local hits = findItems(query)
        say(string.format("items: %d match '%s'", #hits, query))
        for i = 1, math.min(#hits, 25) do say(string.format("  %s  (%s)", hits[i].id, hits[i].name)) end
        if #hits > 25 then say(string.format("  ... and %d more; add a word", #hits - 25)) end
    end

    -- give <player> <item> [count]   item = asset name (SmokedPieceMeat) or shown name (Piece of Smoked Meat)
    C.give = function(a, say)
        local p, err = findPlayer(a[1])
        if not p then return say(err) end
        local last, n = #a, 1
        if last >= 3 and tonumber(a[last]) then
            n = num(a[last], 1)
            last = last - 1
        end
        local query = table.concat(a, " ", 2, last)
        if query == "" then return say("usage: bwcoop give <player> <item> [count]") end
        local item = resolveItem(query, say)
        if not item then return end
        act(say, string.format("give %s %d x %s", p.name, n, item), function() cheats(p):GiveItem(item, n) end)
    end

    -- money <amount> / renown <amount>  (shared by everyone)
    C.money = function(a, say)
        local n = num(a[1])
        if not n then return say("usage: bwcoop money <amount>") end
        act(say, "money +" .. n, function() cheats(host()):ServerGiveMoney(n) end)
    end
    C.renown = function(a, say)
        local n = num(a[1])
        if not n then return say("usage: bwcoop renown <amount>") end
        act(say, "renown +" .. n, function() cheats(host()):ServerGiveRenown(n) end)
    end

    -- perk <player> <warrior|rogue|explorer> <points>
    C.perk = function(a, say)
        local p, err = findPlayer(a[1])
        if not p then return say(err) end
        local tree = a[2] and a[2]:lower()
        local trees = { warrior = "Warrior", rogue = "Rogue", explorer = "Explorer" }
        local n = num(a[3])
        if not trees[tree or ""] or not n then return say("usage: bwcoop perk <player> warrior|rogue|explorer <points>") end
        act(say, string.format("perk %s %s +%d", p.name, trees[tree], n),
            function() cheats(p):ServerGivePerkPoints(trees[tree], n) end)
    end

    -- xp <player> <skill> <amount> / skill <player> <skill> <level>
    C.xp = function(a, say)
        local p, err = findPlayer(a[1])
        if not p then return say(err) end
        local s, n = skillName(a[2]), num(a[3])
        if not s or not n then return say("usage: bwcoop xp <player> <skill> <amount>; skills: " .. table.concat(SKILLS, " ")) end
        act(say, string.format("xp %s %s +%d", p.name, s, n), function() cheats(p):ServerAddPlayerSkillExp(s, n) end)
    end
    C.skill = function(a, say)
        local p, err = findPlayer(a[1])
        if not p then return say(err) end
        local s, n = skillName(a[2]), num(a[3])
        if not s or not n then return say("usage: bwcoop skill <player> <skill> <level>") end
        act(say, string.format("skill %s %s = %d", p.name, s, n), function() cheats(p):ServerSetPlayerSkill(s, n) end)
    end

    -- Villager commands act on whatever the host is looking at (about 5 m, center of screen).
    C.vxp = function(a, say)
        local s, n = skillName(a[1]), num(a[2])
        if not s or not n then return say("usage: bwcoop vxp <skill> <amount>  (look at the villager)") end
        act(say, string.format("villager xp %s +%d", s, n), function() cheats(host()):ServerAddNpcSkillExp(s, n) end)
    end
    C.vskill = function(a, say)
        local s, n = skillName(a[1]), num(a[2])
        if not s or not n then return say("usage: bwcoop vskill <skill> <level>  (look at the villager)") end
        act(say, string.format("villager skill %s = %d", s, n), function() cheats(host()):ServerSetNpcSkill(s, n) end)
    end
    C.vhappy = function(a, say)
        if a[1] == "off" then
            return act(say, "villager happiness override off", function() cheats(host()):ServerStopOverridingNpcHappiness() end)
        end
        local n = num(a[1])
        if not n then return say("usage: bwcoop vhappy <value>|off  (look at the villager)") end
        act(say, "villager happiness = " .. n, function() cheats(host()):ServerSetNpcHappiness(n, true) end)
    end

    -- Spawning happens in front of the host.
    C.spawnnpc = function(a, say)
        local t, n = a[1], num(a[2], 1)
        if not t then return say("usage: bwcoop spawnnpc <template> [count]  e.g. T1_Brigands_Melee_NpcTemplate") end
        act(say, string.format("spawn npc %d x %s", n, t), function() cheats(host()):SpawnNpcTemplate(t, 400.0, n, NAME_None) end)
    end
    C.spawn = function(a, say)
        local t, d = a[1], num(a[2], 400)
        if not t then return say("usage: bwcoop spawn <actor> [distance]  e.g. Deer, Boar, Fox") end
        act(say, string.format("spawn %s at %d", t, d), function() cheats(host()):SpawnActor(t, d + 0.0) end)
    end
    C.animal = function(a, say)
        local t = a[1]
        if not t then return say("usage: bwcoop animal <template> [female|male]  (needs a pen with space)") end
        local female = (a[2] or "female"):lower() ~= "male"
        act(say, "farm animal " .. t, function() cheats(host()):SpawnFarmAnimal(t, female, true) end)
    end

    -- World
    C.time = function(a, say)
        local h = num(a[1])
        if not h then return say("usage: bwcoop time <hours to advance>") end
        act(say, "advance time " .. h .. " h", function() cheats(host()):ServerAdvanceTime(h) end)
    end
    C.weather = function(a, say)
        if not a[1] then return say("usage: bwcoop weather <name>") end
        act(say, "weather " .. a[1], function() cheats(host()):ServerSetWeather(a[1]) end)
    end
    C.immigrants = function(a, say)
        local n = num(a[1])
        if not n then return say("usage: bwcoop immigrants <count>") end
        act(say, "immigrants +" .. n, function() cheats(host()):ServerHireNpcImmigrants(n) end)
    end

    -- msg <player> <chat|info|announce|popup> <text>   (to test which messages show on screen)
    C.msg = function(a, say)
        local p, err = findPlayer(a[1])
        if not p then return say(err) end
        local ch = a[2]
        local text = table.concat(a, " ", 3)
        if not ch or text == "" then return say("usage: bwcoop msg <player> chat|info|announce|popup <text>") end
        local ok, e = api.sendMessage(p.pc, ch, text)
        if ok then
            log("ADMIN msg " .. p.name .. " via " .. ch .. ": " .. text)
            say("sent via " .. ch .. " to " .. p.name)
        else
            log("ADMIN FAILED msg via " .. ch .. ": " .. tostring(e))
            say("failed via " .. ch .. ": " .. tostring(e))
        end
    end

    -- msgtest <player>: one numbered test message through every channel; the player reports
    -- which numbers they saw.
    C.msgtest = function(a, say)
        local p, err = findPlayer(a[1])
        if not p then return say(err) end
        for i, ch in ipairs(api.channelOrder) do
            local ok, e = api.sendMessage(p.pc, ch, string.format("BWCoop test %d (%s)", i, ch))
            local line = string.format("msgtest %s #%d %s: %s", p.name, i, ch, ok and "sent" or ("failed: " .. tostring(e)))
            log("ADMIN " .. line)
            say(line)
        end
    end

    C._help = "players | msgtest <player> | msg <player> <chat|info|announce|popup|hud|mapchat|dialog> <text> | give <player> <item> [n] | items <text> | money <n> | renown <n> | perk <player> <tree> <n> | " ..
        "xp <player> <skill> <n> | skill <player> <skill> <lvl> | vxp <skill> <n> | vskill <skill> <lvl> | " ..
        "vhappy <v>|off | spawnnpc <template> [n] | spawn <actor> [dist] | animal <template> [female|male] | " ..
        "time <h> | weather <name> | immigrants <n>   (player = name prefix or 'me')"

    return C
end
