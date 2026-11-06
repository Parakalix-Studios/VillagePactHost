-- BWCoop newcomers (loaded by main.lua, host only; 0.7.28, needs BWCoopNative 0.4.5). Rules, 2026-10-17:
--
--   * The game's own immigration is inactive in this build (no ImmigrantSpawn points on the map), so the host brings
--     newcomers itself: every 60 minutes of play (counted from the load) 2 newcomers arrive, each at a random
--     qualifying village; both may go to the same one.
--   * A village qualifies with a finished Village Hall (or Town Hall) and a free bed, and with fewer than 2 newcomers
--     already waiting there (each waiting one counts against the free beds). The host's village takes part too.
--   * A newcomer is a villager (random low, medium or high villager template) with the game's hiring talk, priced by
--     the game's own formula (mostly 100 renown per resident of all player villages).
--   * Only the village's owner, players it trusts, or the host may recruit one (others can't start the talk and get a
--     message), and it joins the village it waited at. An unrecruited newcomer walks off after 30 minutes (or is
--     removed at once when no player is near). It runs whether or not the owner is online.
--   * On arrival the owner (the host when the owner is offline) sees "A traveler is resting by the Hall" (0.7.29).
--   * Where they wait (0.7.30): a spot the host picks per hall kind with `bwcoop newcomers spot`, turned with each
--     hall; without one, about 7 m from the hall toward the village (often against a wall, 2026-10-19).
--
-- research/immigrants-2026-10-17.md has the game code behind this (GenerateImmigrant, the hiring talk, the price).
-- The list of waiting newcomers (NPC GUID -> village GUID, arrival time) is saved in data\<save>.tsv.
return function(core)
    local log, valid, guidStr, arrLen, arrGet = core.log, core.valid, core.guidStr, core.arrLen, core.arrGet
    local villageLabel = core.villageLabel
    local M = {}

    local ROUND_EVERY = 3600 -- s of play between arrivals
    local PER_ROUND = 2       -- newcomers per arrival
    local CAP = 2             -- waiting newcomers per village
    local WAIT = 1800         -- s an unrecruited newcomer waits
    local NEAR = 10000        -- cm: a player this close sees it walk away; otherwise it is removed at once

    local TEMPLATES = {
        "/Game/Mist/Characters/NPC/Villager/LowSkill/LowVillagerIdleNPCTemplate",
        "/Game/Mist/Characters/NPC/Villager/MediumSkill/MediumVillagerIdleNPCTemplate",
        "/Game/Mist/Characters/NPC/Villager/HighSkill/HighVillagerIdleNPCTemplate",
    }
    local TALK = "/Game/Mist/Data/Npcs/Talk/New/NPCTalk/VillagerNPCHiringTalk"
    local START = {
        "/Script/Mist.MistInteractorComponent:ServerStartInteraction",
        "/Script/Mist.MistInteractorComponent:ServerStartInteractionInternal",
    }
    local RECRUIT = "/Script/Mist.MistBlueprintLibrary:RecruitNpc"

    local function nativeReady()
        return type(BWNative_NewcomerReady) == "function" and BWNative_NewcomerReady() == true
    end

    -- A Blueprint asset's class and default object ("/Game/X/Y" -> Y_C, Default__Y_C), loading it when needed.
    local function blueprint(path)
        local name = path:match("([^/]+)$")
        local cls = StaticFindObject(path .. "." .. name .. "_C")
        if not valid(cls) then
            -- UE4SS's LoadAsset takes the asset's object path ("/Game/X/Y.Y"), game thread only
            local ok, err = pcall(LoadAsset, path .. "." .. name)
            if not ok then log("NEWCOMER LoadAsset " .. name .. " failed: " .. tostring(err)) end
            cls = StaticFindObject(path .. "." .. name .. "_C")
        end
        if not valid(cls) then return nil, nil end
        return cls, StaticFindObject(path .. ".Default__" .. name .. "_C")
    end

    local cdos, talkClass, houseClass = nil, nil, nil
    local function assets()
        if cdos and talkClass then return true end
        cdos = {}
        for _, p in ipairs(TEMPLATES) do
            local _, cdo = blueprint(p)
            if valid(cdo) then cdos[#cdos + 1] = { cdo = cdo, kind = p:match("/(%a+)VillagerIdle") or "?" } end
        end
        talkClass = blueprint(TALK)
        if #cdos == 0 or not valid(talkClass) then
            log(string.format("NEWCOMER assets missing (%d templates, talk %s)", #cdos, tostring(valid(talkClass))))
            cdos, talkClass = nil, nil
            return false
        end
        return true
    end

    -- Waiting newcomers: GUID -> { village = GUID, born = os.time() }, saved by main.lua.
    local function list() return core.newcomerList() end

    local function villageByKey(key)
        for _, v in ipairs(core.playerVillages()) do
            if guidStr(v.PersistentGuid) == key then return v end
        end
        return nil
    end

    local function npcsByGuid()
        local out = {}
        for _, npc in ipairs(FindAllOf("MistTownNpc") or {}) do
            pcall(function() out[guidStr(npc.PersistentGuid)] = npc end)
        end
        return out
    end

    function M.isNewcomer(npc)
        local key = nil
        pcall(function() key = guidStr(npc.PersistentGuid) end)
        return key ~= nil and list()[key] ~= nil
    end

    local function waitingAt(key)
        local n = 0
        for _, e in pairs(list()) do
            if e.village == key then n = n + 1 end
        end
        return n
    end

    -- Free beds: each house's slots minus its residents.
    local function freeBeds(v)
        if not houseClass then pcall(function() houseClass = StaticFindObject("/Script/Mist.MistTownHouseComponent") end) end
        local free = 0
        pcall(function()
            local st = v.Data.Structures
            for i = 1, arrLen(st) do
                pcall(function()
                    local lc = arrGet(st, i).PlaceableActor.LogicComponent
                    if valid(lc) and valid(houseClass) and lc:IsA(houseClass) then
                        free = free + math.max(0, (lc.MaxWorkforce or 0) - arrLen(lc.Npcs))
                    end
                end)
            end
        end)
        return free
    end

    -- The village's finished hall (Town Hall before Village Hall) and its kind ("townhall"/"villagehall"), or nil.
    local function hallOf(v)
        local best, bestRank, bestKind = nil, 0, nil
        pcall(function()
            local st = v.Data.Structures
            for i = 1, arrLen(st) do
                pcall(function()
                    local a = arrGet(st, i).PlaceableActor
                    if not valid(a) then return end
                    local t = core.buildingType(a)
                    local kind = t.name:lower()
                    local rank = (kind == "townhall" and 2) or (kind == "villagehall" and 1) or 0
                    if rank > bestRank and t.group ~= "ConstructionSite" then best, bestRank, bestKind = a, rank, kind end
                end)
            end
        end)
        return best, bestKind
    end

    -- Waiting spots the host picks (0.7.30, `bwcoop newcomers spot`): per hall kind, an offset in the hall's own frame
    -- (x forward, y right, z up from the hall's origin; cm), so every hall of that kind uses the same spot, turned
    -- with the building. Kept for every world in data\newcomer-spots.tsv ("<kind>\t<x>\t<y>\t<z>").
    -- 0.7.32: a hall kind without a picked spot uses BUILT_IN (the Village Hall spot picked and tested 2026-10-20, in
    -- front of the hall); a kind with neither waits about 7 m from the hall. Only picked spots are saved.
    local HALL_NAMES = { villagehall = "Village Hall", townhall = "Town Hall" }
    local BUILT_IN = { villagehall = { x = -635, y = 282, z = 126 } }
    local SPOT_FILE = core.modDir .. "\\data\\newcomer-spots.tsv"
    local spots = {}
    do
        local f = io.open(SPOT_FILE, "r")
        if f then
            for line in f:lines() do
                local k, x, y, z = line:match("^(%a+)\t(%-?[%d%.]+)\t(%-?[%d%.]+)\t(%-?[%d%.]+)")
                if k then spots[k:lower()] = { x = tonumber(x), y = tonumber(y), z = tonumber(z) } end
            end
            f:close()
        end
    end
    local function saveSpots()
        local f = io.open(SPOT_FILE, "w")
        if not f then return false end
        for k, s in pairs(spots) do f:write(string.format("%s\t%.0f\t%.0f\t%.0f\n", k, s.x, s.y, s.z)) end
        f:close()
        return true
    end

    local function yawOf(a)
        local yaw = nil
        pcall(function() yaw = a:K2_GetActorRotation().Yaw end)
        return yaw
    end

    -- The picked or built-in spot at this hall: world x, y, z and the yaw that faces away from the hall; nil when none.
    local function chosenSpot(hall, kind)
        local s = kind and (spots[kind] or BUILT_IN[kind])
        local h, yaw = core.locationOf(hall), yawOf(hall)
        if not s or not h or not yaw then return nil end
        local r = math.rad(yaw)
        local wx, wy = s.x * math.cos(r) - s.y * math.sin(r), s.x * math.sin(r) + s.y * math.cos(r)
        return h.X + wx, h.Y + wy, h.Z + s.z + 20, math.deg(math.atan(wy, wx))
    end

    -- A spot near the hall, about 7 m toward the village's buildings, spread a little.
    local function spotNear(v, hall)
        local h = core.locationOf(hall)
        if not h then return nil end
        local sx, sy, n = 0, 0, 0
        pcall(function()
            local st = v.Data.Structures
            for i = 1, arrLen(st) do
                pcall(function()
                    local l = core.locationOf(arrGet(st, i).PlaceableActor)
                    if l then sx, sy, n = sx + l.X, sy + l.Y, n + 1 end
                end)
            end
        end)
        local dx, dy = 1, 0
        if n > 0 then
            dx, dy = sx / n - h.X, sy / n - h.Y
            local d = math.sqrt(dx * dx + dy * dy)
            if d < 1 then dx, dy = 1, 0 else dx, dy = dx / d, dy / d end
        end
        local jitter = function() return (math.random() - 0.5) * 300 end
        return h.X + dx * 700 + jitter(), h.Y + dy * 700 + jitter(), h.Z + 50
    end

    local function qualifies(v)
        local key = guidStr(v.PersistentGuid)
        local waiting = waitingAt(key)
        if waiting >= CAP then return false, "already has " .. waiting .. " waiting" end
        if not hallOf(v) then return false, "no finished Village Hall" end
        if freeBeds(v) <= waiting then return false, "no free bed" end
        return true
    end

    -- Tell the village's owner that a newcomer arrived, or the host when the owner is offline (0.7.29;
    -- wording 2026-10-19). One message per player every 3 s (tell), so two arrivals at once show one message.
    local ARRIVAL_TEXT = "A traveler is resting by the Hall"
    local function announce(v)
        local owner = core.villageOwner(v)
        local target, host = nil, nil
        for _, pc in ipairs(FindAllOf("MistOasisPlayerController") or {}) do
            local info = { pc = pc, name = "?", isHost = false }
            pcall(function() info.name = pc.PlayerState:GetPlayerName():ToString() end)
            pcall(function() info.isHost = pc:IsLocalController() == true end)
            if owner and info.name == owner then target = info end
            if info.isHost then host = info end
        end
        target = target or host
        if not target then return "nobody" end
        core.tell(target, ARRIVAL_TEXT)
        return target.name
    end

    -- Spawn one newcomer at village v. Returns a message.
    local function spawnAt(v)
        if not nativeReady() then return "the BWCoopNative add-on (0.4.5) isn't ready" end
        if not assets() then return "the villager templates or the hiring talk didn't load" end
        local hall, kind = hallOf(v)
        local anchor = hall
        if not anchor then
            pcall(function() anchor = arrGet(v.Data.Structures, 1).PlaceableActor end)
        end
        if not valid(anchor) then return villageLabel(v) .. " has no building to stand by" end
        local x, y, z, face = nil, nil, nil, nil
        if hall then x, y, z, face = chosenSpot(hall, kind) end
        if not x then x, y, z = spotNear(v, anchor) end
        if not x then return "no spot near " .. villageLabel(v) end
        local pick = cdos[math.random(#cdos)]
        local ctx = core.hostController()
        local addr = 0
        local ok, err = pcall(function()
            addr = BWNative_SpawnNewcomer(ctx:GetAddress(), pick.cdo:GetAddress(), x, y, z)
        end)
        if not ok or not addr or addr == 0 then return "the game spawned nothing (" .. tostring(err or "refused") .. ")" end
        local npc = nil
        for _, n in ipairs(FindAllOf("MistTownNpc") or {}) do
            local a = 0
            pcall(function() a = n:GetAddress() end)
            if a == addr then npc = n break end
        end
        if not valid(npc) then return "spawned, but the new NPC wasn't found" end
        if face then pcall(function() npc:K2_SetActorRotation({ Pitch = 0, Yaw = face, Roll = 0 }, false) end) end
        local talkOk = pcall(function() npc.TalkComponent:MulticastSetEntryTalk(talkClass) end)
        local key = guidStr(npc.PersistentGuid)
        list()[key] = { village = guidStr(v.PersistentGuid), born = os.time() }
        core.saveData()
        local told = announce(v)
        log(string.format("NEWCOMER %s arrived at %s (%s villager%s; told %s)", key:sub(1, 8), villageLabel(v), pick.kind,
            talkOk and "" or ", hiring talk NOT set", told))
        return string.format("a newcomer (%s villager) arrived at %s", pick.kind, villageLabel(v))
    end

    local function playerNear(l)
        for _, pc in ipairs(FindAllOf("MistOasisPlayerController") or {}) do
            local p = nil
            pcall(function() p = core.locationOf(pc.Pawn) end)
            if p and (p.X - l.X) ^ 2 + (p.Y - l.Y) ^ 2 <= NEAR * NEAR then return true end
        end
        return false
    end

    -- Drop recruited or vanished newcomers; send away those that waited too long. Re-apply the hiring talk after a load.
    local talkSetFor = {}
    local function tidy()
        local now, npcs, changed = os.time(), npcsByGuid(), false
        for key, e in pairs(list()) do
            local npc = npcs[key]
            local recruited = false
            if valid(npc) then pcall(function() recruited = valid(npc.AssignedSettlement) end) end
            if not valid(npc) or recruited then
                list()[key] = nil
                changed = true
                talkSetFor[key] = nil
            elseif now - e.born >= WAIT then
                local l = core.locationOf(npc)
                local v = villageByKey(e.village)
                local away = l and playerNear(l)
                local ok = pcall(function()
                    if away then npc:MakeTravelingAway() else npc:K2_DestroyActor() end
                end)
                log(string.format("NEWCOMER %s left %s (not recruited in %d min; %s)", key:sub(1, 8),
                    v and villageLabel(v) or "?", WAIT // 60, ok and (away and "walking away" or "removed") or "FAILED"))
                list()[key] = nil
                changed = true
                talkSetFor[key] = nil
            elseif not talkSetFor[key] and assets() then
                talkSetFor[key] = pcall(function() npc.TalkComponent:MulticastSetEntryTalk(talkClass) end)
            end
        end
        if changed then core.saveData() end
    end

    local lastWorld, nextRound = nil, 0
    -- a new world load makes a new host controller
    local function worldKey()
        local k = nil
        pcall(function() k = core.hostController():GetAddress() end)
        return k
    end

    function M.tick()
        if core.newcomersOff() or not nativeReady() or not core.ensureLoaded() then return end
        local w = worldKey()
        if w == nil then return end
        if w ~= lastWorld then
            lastWorld, nextRound, talkSetFor = w, os.time() + ROUND_EVERY, {}
            return
        end
        tidy()
        if os.time() < nextRound then return end
        nextRound = os.time() + ROUND_EVERY
        for i = 1, PER_ROUND do
            local cands = {}
            for _, v in ipairs(core.playerVillages()) do
                if qualifies(v) then cands[#cands + 1] = v end
            end
            if #cands == 0 then
                if i == 1 then
                    log("NEWCOMER none this hour: no village has a finished Village Hall, a free bed and room to wait")
                else
                    log(string.format("NEWCOMER only %d this hour: no other free bed in a village with a finished Village Hall",
                        i - 1))
                end
                break
            end
            spawnAt(cands[math.random(#cands)])
        end
    end

    -- Only the owner, players the village trusts, or the host may talk a newcomer into joining.
    local function mayRecruit(req, v)
        if req.isHost then return true end
        local o = core.villageOwner(v)
        if o == nil or o == req.name then return true end
        return core.isTrusted(v, req.name)
    end

    local function npcOf(target)
        if not valid(target) then return nil end
        local cn = core.className(target)
        if cn:find("TownNpc", 1, true) then return target end
        local owner = nil
        pcall(function() owner = target:GetOwner() end)
        if valid(owner) and core.className(owner):find("TownNpc", 1, true) then return owner end
        return nil
    end

    for _, path in ipairs(START) do
        pcall(function()
            RegisterHook(path, function(ctx, interactable)
                if next(list()) == nil then return end
                local ok, e = pcall(function()
                    local req = core.requester(ctx)
                    if req == nil or req.isHost then return end
                    local target = nil
                    pcall(function() target = interactable:get().Target end)
                    local npc = npcOf(target)
                    if not npc then return end
                    local key = guidStr(npc.PersistentGuid)
                    local entry = list()[key]
                    if not entry then return end
                    local v = villageByKey(entry.village)
                    if not v or mayRecruit(req, v) then return end
                    local owner = core.villageOwner(v) or "its owner"
                    local msg = string.format("This newcomer is waiting for %s. Only %s (or players %s trusts) can recruit them.",
                        villageLabel(v), owner, owner)
                    if core.skipCall(path) then
                        log(string.format("NEWCOMER talk refused: %s at %s's newcomer", req.name, villageLabel(v)))
                    else
                        log(string.format("NEWCOMER talk not refused (no add-on or warn mode): %s at %s", req.name, villageLabel(v)))
                    end
                    core.tell(req, msg)
                end)
                if not ok then log("NEWCOMER talk check error: " .. tostring(e)) end
            end)
        end)
    end

    -- Recruited: the game put it in the main village; move it to the village it waited at (next tick, outside the
    -- game's call). main.lua's homeRecruit leaves newcomers alone.
    pcall(function()
        RegisterHook(RECRUIT, function() end, function(ctx, player, npcArg)
            local npc, recruiter = nil, "?"
            pcall(function() npc = npcArg:get() end)
            pcall(function() recruiter = player:get().PlayerState:GetPlayerName():ToString() end)
            if not valid(npc) or not M.isNewcomer(npc) then return end
            local key = guidStr(npc.PersistentGuid)
            local entry = list()[key]
            pcall(ExecuteInGameThread, function()
                local ok, e = pcall(function()
                    local v = villageByKey(entry.village)
                    list()[key] = nil
                    core.saveData()
                    if not v then
                        log(string.format("NEWCOMER %s recruited by %s; its village is gone", key:sub(1, 8), recruiter))
                        return
                    end
                    local cur = nil
                    pcall(function() cur = guidStr(npc.AssignedSettlement.PersistentGuid) end)
                    if cur ~= entry.village then
                        core.hostController().DataBrokerComponent:ServerSetNpcSettlement(npc.PersistentGuid, v.PersistentGuid)
                    end
                    log(string.format("NEWCOMER %s recruited by %s -> %s", key:sub(1, 8), recruiter, villageLabel(v)))
                end)
                if not ok then log("NEWCOMER recruit move error: " .. tostring(e)) end
            end)
        end)
    end)

    -- bwcoop newcomers spot [reset]: the host stands where newcomers should wait, near a finished hall (within 50 m).
    local function pickSpot(say, rest)
        if rest:lower() == "reset" then
            spots = {}
            say("newcomers spot: reset; a Village Hall uses the built-in spot again, a Town Hall about 7 m from the hall" ..
                (saveSpots() and "" or " (NOT saved: can't write " .. SPOT_FILE .. ")"))
            log("NEWCOMER spots reset")
            return
        end
        local p = nil
        pcall(function() p = core.locationOf(core.hostController().Pawn) end)
        if not p then say("newcomers spot: can't find where you are"); return end
        local best, bestKind, bestD2 = nil, nil, 5000 * 5000
        for _, v in ipairs(core.playerVillages()) do
            local h, k = hallOf(v)
            local l = h and core.locationOf(h)
            if l then
                local d2 = (p.X - l.X) ^ 2 + (p.Y - l.Y) ^ 2
                if d2 < bestD2 then best, bestKind, bestD2 = h, k, d2 end
            end
        end
        if not best then say("newcomers spot: stand within 50 m of a finished Village Hall or Town Hall"); return end
        local h, yaw = core.locationOf(best), yawOf(best)
        if not yaw then say("newcomers spot: can't read which way the hall faces"); return end
        local r, dx, dy = math.rad(yaw), p.X - h.X, p.Y - h.Y
        spots[bestKind] = { x = dx * math.cos(r) + dy * math.sin(r), y = -dx * math.sin(r) + dy * math.cos(r), z = p.Z - h.Z }
        local saved = saveSpots()
        local s = spots[bestKind]
        log(string.format("NEWCOMER spot for %s: %.0f %.0f %.0f (hall frame, cm)%s", HALL_NAMES[bestKind], s.x, s.y, s.z,
            saved and "" or "; NOT saved"))
        say(string.format("newcomers spot: newcomers at every %s now wait here, %.0f m from the hall, facing away from it%s",
            HALL_NAMES[bestKind], math.sqrt(bestD2) / 100, saved and "" or " (NOT saved: can't write " .. SPOT_FILE .. ")"))
    end

    -- bwcoop newcomers [on|off|now [village]|spot [reset]]
    function M.command(say, arg)
        local verb, rest = arg:match("^(%S*)%s*(.-)$")
        verb = (verb or ""):lower()
        if verb == "spot" then
            pickSpot(say, rest)
        elseif verb == "on" or verb == "off" then
            core.setNewcomersOff(verb == "off")
            say("newcomers " .. verb .. (verb == "on" and " (2 arrive every 60 minutes of play)" or ""))
        elseif verb == "now" then
            if rest ~= "" then
                local v = core.findVillage(rest)
                if not v then say("newcomers now: no village matches '" .. rest .. "'"); return end
                say("newcomers now: " .. spawnAt(v) .. " (test: hall and bed rules not checked)")
            else
                local cands = {}
                for _, v in ipairs(core.playerVillages()) do
                    if qualifies(v) then cands[#cands + 1] = v end
                end
                if #cands == 0 then say("newcomers now: no village qualifies (finished Village Hall, free bed, room)"); return end
                say("newcomers now: " .. spawnAt(cands[math.random(#cands)]))
            end
        elseif verb == "" or verb == "list" then
            say(string.format("newcomers %s; add-on %s; next arrival in %d min", core.newcomersOff() and "off" or "on",
                nativeReady() and "ready" or "NOT ready", math.max(0, nextRound - os.time()) // 60))
            local npcs, n = npcsByGuid(), 0
            for key, e in pairs(list()) do
                local v = villageByKey(e.village)
                n = n + 1
                say(string.format("  %s at %s, waiting %d of %d min%s", key:sub(1, 8), v and villageLabel(v) or "?",
                    (os.time() - e.born) // 60, WAIT // 60, valid(npcs[key]) and "" or " (not found)"))
            end
            if n == 0 then say("  none waiting") end
            for _, v in ipairs(core.playerVillages()) do
                local ok, why = qualifies(v)
                say(string.format("  %s: %s (free beds %d)", villageLabel(v), ok and "qualifies" or why, freeBeds(v)))
            end
            for _, k in ipairs({ "villagehall", "townhall" }) do
                say(string.format("  waiting spot at a %s: %s", HALL_NAMES[k],
                    spots[k] and "picked (bwcoop newcomers spot)" or BUILT_IN[k] and "built-in, in front of the hall"
                    or "not picked, about 7 m from the hall"))
            end
        else
            say("usage: bwcoop newcomers [on|off|now [village]|spot [reset]]")
        end
    end

    return M
end
