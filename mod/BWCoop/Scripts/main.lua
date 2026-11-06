-- BWCoop: village ownership for Bellwright co-op. Host-only UE4SS Lua mod.
--
-- Each player village has an owner. A friend's request that would change a village
-- they don't own (buildings, villagers, priorities, jobs, building, demolishing) is
-- neutralized on the host before the game runs it. The host can change anything.
--
-- Owners live in ue4ss\Mods\BWCoop\data\<save name>.tsv. Log: ue4ss\Mods\BWCoop\BWCoop.log.
-- Console (~ or F10), host only:
--   bwcoop                              status: mode, villages and owners, players online
--   bwcoop assign <village> = <player>  set an owner (village by name or GUID prefix)
--   bwcoop unassign <village>           make a village open to everyone
--   bwcoop mode warn|enforce|dryrun|off warn: tell the player and log; enforce: block (needs
--                                       the native add-on, warns until then); dryrun: log only
--   bwcoop tags on|off                  owner name in village names, e.g. "Oakhold [Ann]"

local VERSION = "0.7.32"

-- (0.7.28: helpers inside do-blocks keep main.lua under Lua's limit of 200 top-level locals)
local modDir = (debug.getinfo(1, "S").source:sub(2):gsub("[/\\]Scripts[/\\]main%.lua$", ""))
local logPath = modDir .. "\\BWCoop.log"
local dataDir = modDir .. "\\data\\"

----------------------------------------------------------------------------- helpers

local function log(msg)
    print("[BWCoop] " .. msg .. "\n")
    local f = io.open(logPath, "a")
    if f then
        f:write(os.date("%Y-%m-%d %H:%M:%S ") .. msg .. "\n")
        f:close()
    end
end

local function valid(o)
    if o == nil then return false end
    local ok, v = pcall(function() return o:IsValid() end)
    return ok and v == true
end

local ZERO = "00000000-00000000-00000000-00000000"

local function guidStr(g)
    if g == nil then return ZERO end
    local ok, s = pcall(function()
        return string.format("%08X-%08X-%08X-%08X",
            g.A & 0xFFFFFFFF, g.B & 0xFFFFFFFF, g.C & 0xFFFFFFFF, g.D & 0xFFFFFFFF)
    end)
    return ok and s or ZERO
end

local function sameGuid(a, b)
    return a ~= nil and b ~= nil and a.A == b.A and a.B == b.B and a.C == b.C and a.D == b.D
end

local function objName(o)
    if not valid(o) then return "nil" end
    local ok, s = pcall(function() return o:GetFName():ToString() end)
    return ok and s or "?"
end

local function className(o)
    local ok, s = pcall(function() return o:GetClass():GetFName():ToString() end)
    return ok and s or ""
end

local function arrLen(arr)
    local ok, n = pcall(function() return #arr end)
    if ok and n then return n end
    ok, n = pcall(function() return arr:GetArrayNum() end)
    return ok and n or 0
end

local function arrGet(arr, i)
    local v = arr[i]
    pcall(function() if type(v.get) == "function" then v = v:get() end end)
    return v
end

local function trim(s) return (s:gsub("^%s+", ""):gsub("%s+$", "")) end

----------------------------------------------------------------------------- players

local controllerOf
do
-- Missing properties do not come back as nil in UE4SS, so decide by class name.
local function isController(o) return className(o):find("PlayerController") ~= nil end
local function isPlayerState(o) return className(o):find("PlayerState") ~= nil end

local function controllerFromActor(a)
    if not valid(a) then return nil end
    if isController(a) then return a end
    if isPlayerState(a) then
        local ok, o = pcall(function() return a:GetOwner() end)
        if ok and valid(o) and isController(o) then return o end
        return nil
    end
    local ok, c = pcall(function() return a.Controller end) -- pawn
    if ok and valid(c) and isController(c) then return c end
    return nil
end

-- The controller behind an RPC's context (controller, player state, pawn or component).
function controllerOf(ctx)
    if not valid(ctx) then return nil end
    local pc = controllerFromActor(ctx)
    if pc then return pc end
    local ok, owner = pcall(function() return ctx:GetOwner() end)
    if ok then return controllerFromActor(owner) end
    return nil
end
end

local function playerInfo(pc)
    if not valid(pc) then return nil end
    local info = { pc = pc, name = "?", isHost = false }
    pcall(function() info.isHost = pc:IsLocalController() == true end)
    pcall(function() info.name = pc.PlayerState:GetPlayerName():ToString() end)
    return info
end

-- Ways to put text on a player's screen. The host calls these on the player's controller;
-- each is a Client RPC, so it shows on that player's PC.
local CHANNELS = {
    chat = function(pc, text) pc.MessengerComponent:ClientAddNotificationChatMessage(1, FText(text)) end,
    info = function(pc, text) pc.MessengerComponent:ClientAddInformationMessage(FText(text)) end,
    announce = function(pc, text) pc.MessengerComponent:ClientAddAnnouncementMessage(FText(text)) end,
    popup = function(pc, text) pc:ClientOpenCustomPopup(FText("BWCoop"), FText(text), 0.0) end,
    hud = function(pc, text)
        pc:ClientAddHudMessage({ MessageText = FText(text), DisplayDuration = 6.0,
            bRequiresConfirmation = false, bCountEvenIfInvisible = false })
    end,
    mapchat = function(pc, text) pc.MessengerComponent:ClientAddMapChatMessage({ Name = "BWCoop" }, text) end,
    dialog = function(pc, text) pc.Pawn:ClientDisplayInfoDialog(FText(text)) end,
}
local CHANNEL_ORDER = { "chat", "info", "announce", "popup", "hud", "mapchat", "dialog" }

local function sendMessage(pc, channel, text)
    local fn = CHANNELS[channel]
    if not fn then return false, "unknown channel " .. tostring(channel) end
    return pcall(fn, pc, text)
end

-- Tell a player something (rate-limited to one message per player every 3 seconds).
local tell
do
local lastTold = {}
local failedChannel = {}
-- msgtest 2026-10-11: only popup, hud and dialog reach the screen (host and friend alike).
-- hud is the one that does not need a click to close.
local TELL_CHANNELS = { "hud" }
function tell(info, text)
    if not info or not valid(info.pc) then return end
    local now = os.time()
    if lastTold[info.name] and now - lastTold[info.name] < 3 then return end
    lastTold[info.name] = now
    for _, ch in ipairs(TELL_CHANNELS) do
        local ok, err = sendMessage(info.pc, ch, text)
        if not ok and not failedChannel[ch] then
            failedChannel[ch] = true
            log("message via " .. ch .. " failed: " .. tostring(err))
        end
    end
end
end

----------------------------------------------------------------------------- owners

local saveName = nil
local owners = {}       -- village GUID string -> owner character name
local mode = "warn"     -- warn | enforce | dryrun | off
local tagsOn = true     -- show the owner in village names: "Oakhold [Ann]"
local cheatsOpen = false -- false: only the host may use the game's cheat functions
local autoSetup = true   -- run the world setup (owners, villagers, squads, tags) after every load
local villageLimit = 1   -- villages a friend may own (the host can assign more)
local transfers = {}     -- villager GUID -> village GUID, replayed after every load
local playerRates = {}   -- player name -> { xp, speed, cost, build, read } (multipliers, 1 = normal; read 1 = instant books)
local trusted = {}       -- village GUID -> { [player name] = true }: may change that village like its owner
local playerColors = {}  -- player name -> { hex = "RRGGBB", auto = true when picked by the mod }: map area color
local claimRanges = {}   -- building type or group (lowercase) -> claim range in cm, set by the host (0.7.2)
local keep = {}          -- building GUID -> GUID of the village it belongs to (0.7.9: moved back if the game moves it)
local balance = {}       -- balance setting -> value, set by the host per world (0.7.12, balance.lua)
local stockRules = {}    -- keep-stocked rules (0.7.22, caravans.lua): { target, source, item, level, reserve } (village GUIDs)
local stockRoutes = {}   -- "source>target" -> GUID of the "Keep: <target>" caravan route made for that pair
-- newcomers (0.7.28, newcomers.lua): list = waiting ones, NPC GUID -> { village = GUID, born = os.time() };
-- off = "bwcoop newcomers off" for this world; mod = the module (set further down, homeRecruit asks it)
local newcomers = { list = {}, off = false, mod = nil }
local SLEEP_RULES = { all = true, half = true, one = true, host = true }
local sleepRule = "half" -- players in bed needed to skip the night: all | half | one | host (BWCoopNative 0.4.0)
local pendingFounder = nil
local warnedUnowned = {}

local function currentSaveName()
    local name = nil
    pcall(function()
        local gm = FindFirstOf("MistOasisGameMode")
        if valid(gm) then name = gm.OptionsString:ToString():match('%-SaveFile="([^"]+)"') end
    end)
    return name
end

local function dataPath(name)
    return dataDir .. name:gsub('[^%w%s%-_]', "_") .. ".tsv"
end

local function saveOwners()
    if not saveName then return end
    local f = io.open(dataPath(saveName), "w")
    if not f then log("could not write " .. dataPath(saveName)); return end
    f:write("# BWCoop owners for save \"" .. saveName .. "\". Tab separated; edit only while the game is closed.\n")
    f:write("mode\t" .. mode .. "\n")
    f:write("tags\t" .. (tagsOn and "on" or "off") .. "\n")
    f:write("cheats\t" .. (cheatsOpen and "open" or "host") .. "\n")
    f:write("auto\t" .. (autoSetup and "on" or "off") .. "\n")
    f:write("limit\t" .. villageLimit .. "\n")
    f:write("sleep\t" .. sleepRule .. "\n")
    local keys = {}
    for k in pairs(owners) do keys[#keys + 1] = k end
    table.sort(keys)
    for _, k in ipairs(keys) do
        local o = owners[k]
        f:write(string.format("village\t%s\t%s\t%s\n", k, o.owner, o.label or ""))
        if o.seq then f:write(string.format("founded\t%s\t%d\n", k, o.seq)) end
        local names = {}
        for name in pairs(trusted[k] or {}) do names[#names + 1] = name end
        table.sort(names)
        for _, name in ipairs(names) do f:write(string.format("trust\t%s\t%s\n", k, name)) end
    end
    local tkeys = {}
    for k in pairs(transfers) do tkeys[#tkeys + 1] = k end
    table.sort(tkeys)
    for _, k in ipairs(tkeys) do f:write(string.format("transfer\t%s\t%s\n", k, transfers[k])) end
    for name, r in pairs(playerRates) do
        f:write(string.format("rates\t%s\t%g\t%g\t%g\t%g\t%d\n", name, r.xp, r.speed, r.cost, r.build, r.read or 0))
    end
    local cnames = {}
    for name in pairs(playerColors) do cnames[#cnames + 1] = name end
    table.sort(cnames)
    for _, name in ipairs(cnames) do
        local c = playerColors[name]
        f:write(string.format("color\t%s\t%s\t%s\n", name, c.hex, c.auto and "auto" or "set"))
    end
    local rnames = {}
    for k in pairs(claimRanges) do rnames[#rnames + 1] = k end
    table.sort(rnames)
    for _, k in ipairs(rnames) do f:write(string.format("range\t%s\t%d\n", k, claimRanges[k])) end
    local bkeys = {}
    for k in pairs(keep) do bkeys[#bkeys + 1] = k end
    table.sort(bkeys)
    for _, k in ipairs(bkeys) do f:write(string.format("keep\t%s\t%s\n", k, keep[k])) end
    local balkeys = {}
    for k in pairs(balance) do balkeys[#balkeys + 1] = k end
    table.sort(balkeys)
    for _, k in ipairs(balkeys) do f:write(string.format("balance\t%s\t%g\n", k, balance[k])) end
    for _, r in ipairs(stockRules) do
        f:write(string.format("stock\t%s\t%s\t%s\t%d\t%d\n", r.target, r.source, r.item, r.level, r.reserve or 0))
    end
    local skeys = {}
    for k in pairs(stockRoutes) do skeys[#skeys + 1] = k end
    table.sort(skeys)
    for _, k in ipairs(skeys) do f:write(string.format("stockroute\t%s\t%s\n", k, stockRoutes[k])) end
    if newcomers.off then f:write("newcomers\toff\n") end
    local nkeys = {}
    for k in pairs(newcomers.list) do nkeys[#nkeys + 1] = k end
    table.sort(nkeys)
    for _, k in ipairs(nkeys) do
        f:write(string.format("newcomer\t%s\t%s\t%d\n", k, newcomers.list[k].village, newcomers.list[k].born))
    end
    f:close()
end

local function loadOwners(name)
    owners, warnedUnowned, pendingFounder = {}, {}, nil
    mode = "warn"
    tagsOn = true
    cheatsOpen = false
    autoSetup = true
    villageLimit = 1
    transfers = {}
    playerRates = {}
    trusted = {}
    playerColors = {}
    claimRanges = {}
    keep = {}
    balance = {}
    stockRules = {}
    stockRoutes = {}
    newcomers.list = {}
    newcomers.off = false
    sleepRule = "half"
    saveName = name
    local f = io.open(dataPath(name), "r")
    if not f then
        -- A new world: block from the start when the add-on can (warn otherwise).
        if type(BWNative_Skip) == "function" then mode = "enforce" end
        log("no owner file for save \"" .. name .. "\" yet; mode " .. mode)
        return
    end
    for line in f:lines() do
        local key, a, b, c = line:match("^(%w+)\t([^\t]*)\t?([^\t]*)\t?([^\t]*)$")
        -- rates lines have more fields than the generic pattern takes
        local rn, rx, rs, rc, rb, rr = line:match("^rates\t([^\t]+)\t([^\t]+)\t([^\t]+)\t([^\t]+)\t([^\t]+)\t?([^\t]*)$")
        local st, ss, si, sl, sr = line:match("^stock\t([^\t]+)\t([^\t]+)\t([^\t]+)\t(%d+)\t(%d+)$")
        if st then
            stockRules[#stockRules + 1] = { target = st, source = ss, item = si, level = tonumber(sl), reserve = tonumber(sr) }
        elseif rn then
            playerRates[rn] = { xp = tonumber(rx) or 1, speed = tonumber(rs) or 1, cost = tonumber(rc) or 1,
                build = tonumber(rb) or 1, read = tonumber(rr) or 0 }
        elseif key == "mode" and (a == "warn" or a == "enforce" or a == "dryrun" or a == "off") then
            mode = a
        elseif key == "tags" then
            tagsOn = a ~= "off"
        elseif key == "cheats" then
            cheatsOpen = a == "open"
        elseif key == "auto" then
            autoSetup = a ~= "off"
        elseif key == "limit" and tonumber(a) then
            villageLimit = math.max(0, math.floor(tonumber(a)))
        elseif key == "transfer" and a ~= "" and b ~= "" then
            transfers[a] = b
        elseif key == "trust" and a ~= "" and b ~= "" then
            trusted[a] = trusted[a] or {}
            trusted[a][b] = true
        elseif key == "sleep" and SLEEP_RULES[a] then
            sleepRule = a
        elseif key == "village" and a ~= "" and b ~= "" then
            owners[a] = { owner = b, label = c }
        elseif key == "founded" and owners[a] and tonumber(b) then
            owners[a].seq = math.floor(tonumber(b))
        elseif key == "balance" and a ~= "" and tonumber(b) then
            balance[a] = tonumber(b)
        elseif key == "keep" and a ~= "" and b ~= "" then
            keep[a] = b
        elseif key == "stockroute" and a ~= "" and b ~= "" then
            stockRoutes[a] = b
        elseif key == "newcomers" then
            newcomers.off = a == "off"
        elseif key == "newcomer" and a ~= "" and b ~= "" and tonumber(c) then
            newcomers.list[a] = { village = b, born = math.floor(tonumber(c)) }
        elseif key == "range" and a ~= "" and tonumber(b) then
            claimRanges[a] = math.floor(tonumber(b))
        elseif key == "color" and a ~= "" and b:match("^%x%x%x%x%x%x$") then
            playerColors[a] = { hex = b:upper(), auto = c == "auto" }
        end
    end
    f:close()
    local n = 0
    for _ in pairs(owners) do n = n + 1 end
    log(string.format("save \"%s\": %d village owners, mode %s", name, n, mode))
end

-- Founding order (0.7.1): the game's own village list changes order between loads, so each owned
-- village keeps a founding number (main settlement 0, then 1, 2, ... as villages are founded).
local function nextSeq()
    local m = 0
    for _, o in pairs(owners) do
        if o.seq and o.seq > m then m = o.seq end
    end
    return m + 1
end

local function ensureLoaded()
    local name = currentSaveName()
    if name and name ~= saveName then loadOwners(name) end
    return saveName ~= nil
end

----------------------------------------------------------------------------- villages

local function rawVillageName(v)
    local name = ""
    pcall(function() name = v.Data.Name.CustomName:ToString() or "" end)
    return name
end

-- "Oakhold [Ann]" -> "Oakhold"
local function baseName(name) return (name:gsub("%s*%[[^%]]*%]%s*$", "")) end

-- Village name without the owner tag, for logs, messages and matching.
local function villageLabel(v)
    local name = baseName(rawVillageName(v))
    if name == "" then name = "(unnamed " .. guidStr(v.PersistentGuid):sub(1, 8) .. ")" end
    return name
end

local function isPlayerVillage(v)
    local ok, f = pcall(function() return objName(v.Data.Faction) end)
    return ok and f == "Player"
end

-- All player villages: the main settlement plus outposts.
local function playerVillages()
    local list = {}
    pcall(function()
        local wd = FindFirstOf("MistWorldDataHolder").Data
        local main = wd.PlayerSettlement
        if valid(main) and valid(main.Actor) then list[#list + 1] = main.Actor end
        local outs = wd.PlayerOutposts
        for i = 1, arrLen(outs) do
            local sd = arrGet(outs, i)
            if valid(sd) and valid(sd.Actor) then list[#list + 1] = sd.Actor end
        end
    end)
    return list
end

local function locationOf(a)
    local ok, l = pcall(function() return a:K2_GetActorLocation() end)
    if ok and l then return l end
    return nil
end

-- Town hall position and influence radius (cm), or nil when unreadable.
local function townHallArea(v)
    local x, y, r, z = nil, nil, nil, nil
    pcall(function()
        local th = v.TownHallActor
        if valid(th) then
            local l = th:K2_GetActorLocation()
            x, y, r, z = l.X, l.Y, th.InfluenceRadius, l.Z
        end
    end)
    if x and r and r > 0 then return x, y, r, z end
    return nil
end

-- Building positions per village, refreshed every minute (buildings rarely move).
-- The game's own rule (FMistTownUtils::FindClosestPlayerSettlement, called from
-- AMistPlaceable::QueryForTownZone): a new building joins the village of the closest player
-- building within 100 m; with none in range it founds a new one.
local NEAR_BUILDING = 10000 -- cm
local buildingCache = {}

local function buildingPositions(v)
    local key = guidStr(v.PersistentGuid)
    local c = buildingCache[key]
    if c and os.time() - c.time < 60 then return c.list end
    local list = {}
    pcall(function()
        local structures = v.Data.Structures
        for i = 1, arrLen(structures) do
            local sd = arrGet(structures, i)
            pcall(function()
                local l = sd.PlaceableActor:K2_GetActorLocation()
                list[#list + 1] = { l.X, l.Y, l.Z }
            end)
        end
    end)
    buildingCache[key] = { time = os.time(), list = list }
    return list
end

-- Squared distance from (x, y) to the nearest building of v, or nil if none is known.
local function nearestBuilding2(v, x, y)
    local best = nil
    for _, p in ipairs(buildingPositions(v)) do
        local dx, dy = x - p[1], y - p[2]
        local d2 = dx * dx + dy * dy
        if best == nil or d2 < best then best = d2 end
    end
    return best
end

-- The game's own answer (BWCoopNative 0.2.0): the village a new building at x, y, z would join,
-- false when the game would found a new one, nil when the add-on can't ask.
local function gameVillageAt(x, y, z)
    if z == nil or type(BWNative_GameCallsReady) ~= "function" or not BWNative_GameCallsReady() then return nil end
    local ok, a = pcall(function()
        return BWNative_ClosestPlayerSettlement(FindFirstOf("MistWorldDataHolder"):GetAddress(), x, y, z)
    end)
    if not ok or type(a) ~= "number" then return nil end
    if a == 0 then return false end
    for _, v in ipairs(playerVillages()) do
        local okV, va = pcall(function() return v:GetAddress() end)
        if okV and va == a then return v end
    end
    return false
end

-- The player village a world position belongs to: inside a town hall's influence radius, or
-- else the village a new building there would join (the game's answer when available, else
-- within NEAR_BUILDING of one of a village's buildings, closest village wins).
local function villageAt(x, y, z)
    for _, v in ipairs(playerVillages()) do
        local tx, ty, r = townHallArea(v)
        if tx then
            local dx, dy = x - tx, y - ty
            if dx * dx + dy * dy <= r * r then return v end
        end
    end
    local g = gameVillageAt(x, y, z)
    if g ~= nil then return g or nil end
    local best, bestD2 = nil, NEAR_BUILDING * NEAR_BUILDING
    for _, v in ipairs(playerVillages()) do
        local d2 = nearestBuilding2(v, x, y)
        if d2 and d2 <= bestD2 then best, bestD2 = v, d2 end
    end
    return best
end

local caravanLookup = nil -- caravans.lua (0.7.11): route/stop/party GUID -> its caravan station

-- GUID -> actor, with a cache. Misses are remembered for a minute.
local findByGuid
do
local actorCache, missCache = {}, {}
local LOOKUP_CLASSES = { "MistTownStructure", "MistTownNpc", "MistSettlement" }
function findByGuid(g)
    local key = guidStr(g)
    if key == ZERO then return nil end
    local hit = actorCache[key]
    if hit and valid(hit.actor) then
        local ok, same = pcall(function() return sameGuid(hit.actor.PersistentGuid, g) end)
        if ok and same then return hit.actor, hit.kind end
    end
    -- Caravan routes, stops and parties are data objects, not actors: they belong to their station's village.
    if caravanLookup then
        local e = caravanLookup(key)
        if e and valid(e.station) then return e.station, "MistTownStructure" end
    end
    if missCache[key] and os.time() - missCache[key] < 60 then return nil end
    for _, cls in ipairs(LOOKUP_CLASSES) do
        local all = FindAllOf(cls)
        if all then
            for _, o in ipairs(all) do
                local ok, same = pcall(function() return sameGuid(o.PersistentGuid, g) end)
                if ok and same then
                    actorCache[key] = { actor = o, kind = cls }
                    return o, cls
                end
            end
        end
    end
    missCache[key] = os.time()
    return nil
end
end

-- The player village an actor belongs to, or nil (neutral villages and camps return nil).
local function villageOf(a, kind)
    if not valid(a) then return nil end
    local v = nil
    if kind == "MistSettlement" then
        v = a
    elseif kind == "MistTownNpc" then
        pcall(function() if valid(a.AssignedSettlement) then v = a.AssignedSettlement end end)
        if not v then pcall(function() if valid(a.NpcData.Settlement.Actor) then v = a.NpcData.Settlement.Actor end end) end
    else
        pcall(function() if valid(a.PlaceableData.Settlement.Actor) then v = a.PlaceableData.Settlement.Actor end end)
        if not v then
            local l = locationOf(a)
            if l then v = villageAt(l.X, l.Y, l.Z) end
        end
    end
    if v and isPlayerVillage(v) then return v end
    return nil
end

----------------------------------------------------------------------------- founders

local function hostName()
    local name = nil
    for _, pc in ipairs(FindAllOf("MistOasisPlayerController") or {}) do
        local info = playerInfo(pc)
        if info and info.isHost then name = info.name end
    end
    return name
end

-- Give unowned player villages an owner: the main settlement goes to the host, a new
-- outpost to whoever placed something outside every village shortly before it appeared.
local function claimUnowned()
    if not ensureLoaded() then return end
    local changed = false
    local main = nil
    pcall(function() main = FindFirstOf("MistWorldDataHolder").Data.PlayerSettlement.Actor end)
    for _, v in ipairs(playerVillages()) do
        local key = guidStr(v.PersistentGuid)
        if not owners[key] then
            local owner, why = nil, nil
            if valid(main) and sameGuid(main.PersistentGuid, v.PersistentGuid) then
                owner, why = hostName(), "main settlement"
            elseif pendingFounder and os.time() - pendingFounder.time < 300 then
                owner, why = pendingFounder.name, "founder"
            end
            if owner then
                owners[key] = { owner = owner, label = villageLabel(v), seq = why == "main settlement" and 0 or nextSeq() }
                changed = true
                log(string.format("CLAIM %s -> %s (%s)", villageLabel(v), owner, why))
            elseif not warnedUnowned[key] then
                warnedUnowned[key] = true
                log(string.format("unowned village %s %s: open to everyone until the host assigns it", villageLabel(v), key))
            end
        end
    end
    if changed then saveOwners() end
end

----------------------------------------------------------------------------- name tags

local function hostController()
    for _, pc in ipairs(FindAllOf("MistOasisPlayerController") or {}) do
        local info = playerInfo(pc)
        if info and info.isHost then return pc end
    end
    return nil
end

local renameFailed = {}

-- Rename through the game's own request so the new name syncs to everyone and is saved.
local function setVillageName(v, newName)
    local key = guidStr(v.PersistentGuid)
    if renameFailed[key] then return false end
    local pc = hostController()
    if not valid(pc) then return false end
    local before = rawVillageName(v)
    -- Preferred: a fresh name value (keeps the game's "name changed" check meaningful).
    local ok, err = pcall(function()
        local ref = v.Data.Name.ObjectReferenceGuid
        pc.DataBrokerComponent:ServerSetSettlementName(v.PersistentGuid, {
            ObjectReferenceGuid = { A = ref.A, B = ref.B, C = ref.C, D = ref.D },
            CustomName = FText(newName),
        })
    end)
    local method = "table"
    if not ok or rawVillageName(v) ~= newName then
        -- Fallback: edit the current value and send that.
        method = "in-place"
        ok, err = pcall(function()
            local ct = v.Data.Name
            ct.CustomName = FText(newName)
            pc.DataBrokerComponent:ServerSetSettlementName(v.PersistentGuid, ct)
        end)
    end
    if ok and rawVillageName(v) == newName then
        log(string.format("RENAME %s -> %s (%s)", before, newName, method))
        return true
    end
    renameFailed[key] = true
    log(string.format("rename failed for %s (%s): %s", before, method, tostring(err)))
    return false
end

-- Tag owned villages with their owner ("Oakhold [Ann]"); strip tags when off or unowned.
-- Villages that still have the game's default name are left alone.
local function applyTags()
    for _, v in ipairs(playerVillages()) do
        local raw = rawVillageName(v)
        if raw ~= "" then
            local base = baseName(raw)
            local o = owners[guidStr(v.PersistentGuid)]
            local want = (tagsOn and o) and (base .. " [" .. o.owner .. "]") or base
            if want ~= raw then setVillageName(v, want) end
        end
    end
end

----------------------------------------------------------------------------- decisions

-- Returns true when the request may go ahead: the host, the owner, or a friend the village trusts.
local function allowed(req, v)
    if req == nil or req.isHost then return true end
    local key = guidStr(v.PersistentGuid)
    local o = owners[key]
    if o == nil or o.owner == req.name then return true end
    if trusted[key] and trusted[key][req.name] then return true end
    return false, o.owner
end

local function fnName(path) return path:match(":([%w_]+)$") or path end

-- Blocking needs the BWCoopNative add-on, which can skip a game function cleanly. Never try to
-- block by emptying a request's IDs: the game uses them without a null check and the host
-- crashes (tested 2026-10-11, ServerSetStructurePriority). Without the add-on, "enforce" warns.
local function nativeReady() return type(BWNative_Skip) == "function" end

-- Ask the add-on to skip this one call of `path`. True when it will be skipped.
local function skipCall(path)
    if not nativeReady() then return false end
    local ok, skipped = pcall(BWNative_Skip, path)
    return ok and skipped == true
end

local warnedNoNative = false
-- Path of the call the guards just blocked, so later hooks on the same call can tell. Cleared at
-- the start of each data-broker guard (those run first for their call).
local justBlocked = nil

-- Shared ending for every village guard: log, tell the player, and block when possible.
local function refuse(path, req, v, owner, landMsg)
    local what = string.format("%s by %s in %s (owner %s)", fnName(path), req.name, villageLabel(v), owner)
    if mode == "dryrun" then
        log("WOULD BLOCK " .. what)
        return
    end
    if mode == "enforce" then
        if skipCall(path) then
            justBlocked = path
            log("BLOCKED " .. what)
            tell(req, landMsg or (villageLabel(v) .. " belongs to " .. owner .. ". Only they or the host can change it."))
            return
        end
        if not warnedNoNative then
            warnedNoNative = true
            log(nativeReady() and ("not armed in the add-on: " .. fnName(path) .. "; warning instead")
                or "enforce needs the BWCoopNative add-on; warning instead of blocking")
        end
    end
    log("WARNED " .. what)
    tell(req, landMsg or (villageLabel(v) .. " belongs to " .. owner .. ". Please leave changes there to them."))
end

local function requester(ctx)
    local pc = nil
    pcall(function() pc = controllerOf(ctx:get()) end)
    return playerInfo(pc)
end

local function safeHook(path, fn)
    local ok, err = pcall(function()
        RegisterHook(path, function(ctx, ...)
            if mode == "off" then return end
            local args = { ... }
            local ok2, e = pcall(fn, ctx, args)
            if not ok2 then log("guard error in " .. fnName(path) .. ": " .. tostring(e)) end
        end)
    end)
    if not ok then log("FAILED to hook " .. path .. ": " .. tostring(err)) end
    return ok
end

-- Data-broker requests: GUID params naming a building, villager or village.
local function guardGuids(path, idxs)
    return safeHook(path, function(ctx, args)
        justBlocked = nil
        local req = requester(ctx)
        if req == nil or req.isHost then return end
        ensureLoaded()
        for _, i in ipairs(idxs) do
            local p = args[i]
            if p then
                local a, kind = findByGuid(p:get())
                local v = villageOf(a, kind)
                if v then
                    local ok, owner = allowed(req, v)
                    if not ok then
                        refuse(path, req, v, owner)
                        return
                    end
                end
            end
        end
    end)
end

-- Building requests that name an existing object (demolish, plans).
local function guardObject(path, idx)
    return safeHook(path, function(ctx, args)
        local req = requester(ctx)
        if req == nil or req.isHost then return end
        ensureLoaded()
        local a = args[idx] and args[idx]:get()
        local v = villageOf(a, "placeable")
        if v then
            local ok, owner = allowed(req, v)
            if not ok then
                refuse(path, req, v, owner)
            end
        end
    end)
end

-- Rotate (x, y, z) by quaternion q.
local function rotateByQuat(q, x, y, z)
    local qx, qy, qz, qw = q.X, q.Y, q.Z, q.W
    local tx, ty, tz = 2 * (qy * z - qz * y), 2 * (qz * x - qx * z), 2 * (qx * y - qy * x)
    return x + qw * tx + (qy * tz - qz * ty),
        y + qw * ty + (qz * tx - qx * tz),
        z + qw * tz + (qx * ty - qy * tx)
end

-- World position of a placement request. FMistPlacementState.Transform is relative to the surface
-- being aimed at (UMistBuildingComponent::SetPlacementStateTransform and
-- FMistBuildingUtils::GetPlacementParentTransform): an instanced mesh's instance when Component is
-- an InstancedStaticMeshComponent, else the component's world transform, scale ignored; world
-- coordinates only when Component is empty. Falls back to the player's own position.
-- Returns x, y, z, how ("world", the component class, or "player position").
local function placementWorldXY(state, req)
    local rx, ry, rz, comp, idx = nil, nil, nil, nil, -1
    pcall(function()
        local t = state.Transform.Translation
        rx, ry, rz = t.X, t.Y, t.Z
    end)
    pcall(function() comp = state.Component end)
    pcall(function() idx = state.ItemIndex end)
    if rx ~= nil and not valid(comp) then return rx, ry, rz, "world" end
    local cls = valid(comp) and className(comp) or "?"
    if rx ~= nil then
        local parent = nil
        pcall(function()
            if cls:find("InstancedStaticMesh", 1, true) then
                local out = {}
                comp:GetInstanceTransform(idx, out, true)
                if out.OutInstanceTransform then out = out.OutInstanceTransform end
                if out.Translation then parent = out end
            else
                parent = comp:K2_GetComponentToWorld()
            end
        end)
        if parent then
            local ok, wx, wy, wz = pcall(function()
                local dx, dy, dz = rotateByQuat(parent.Rotation, rx, ry, rz)
                return parent.Translation.X + dx, parent.Translation.Y + dy, parent.Translation.Z + dz
            end)
            if ok and wx then return wx, wy, wz, cls end
        end
    end
    local pawn = nil
    pcall(function() pawn = req.pc.Pawn end)
    local l = valid(pawn) and locationOf(pawn)
    if l then return l.X, l.Y, l.Z, "player position (" .. cls .. " unreadable)" end
    return nil
end

----------------------------------------------------------------------------- land claims

-- Villages in claim priority: the host's first, then founding order (each owned village's founding
-- number; one founded before 0.7.1 gets the next number the first time it's seen, so the order stays
-- fixed from then on; "bwcoop founding" sets it). Unowned villages come last.
local function claimPriority(list)
    local host, owned, unowned, changed = hostName(), {}, {}, false
    for _, v in ipairs(list) do
        local o = owners[guidStr(v.PersistentGuid)]
        if o then
            if not o.seq then
                o.seq = nextSeq()
                changed = true
            end
            owned[#owned + 1] = v
        else
            unowned[#unowned + 1] = v
        end
    end
    if changed then saveOwners() end
    local function rank(v)
        local o = owners[guidStr(v.PersistentGuid)]
        return (host and o.owner == host) and 0 or 1, o.seq
    end
    table.sort(owned, function(a, b)
        local ha, sa = rank(a)
        local hb, sb = rank(b)
        if ha ~= hb then return ha < hb end
        return sa < sb
    end)
    for _, v in ipairs(unowned) do owned[#owned + 1] = v end
    return owned
end

-- Claim range per building type (0.7.2, 2026-10-12; tiers 0.7.7, 2026-10-13). A building claims the
-- unclaimed land within its tier's range; a town hall also claims its influence circle. Example: a logging camp out
-- in the woods claims 40 m (about 50 squares), not 100 m (about 310). The host changes a type, a game group or a
-- whole tier with "bwcoop range <type, group or tier> = <meters|default>" (saved per save).
-- A building's type comes from its template, so a construction site counts as what it will become. Type names are
-- the template names (lowercase, a "VM_"-style prefix dropped), listed from the ModKit's Data/Placeables 2026-10-13.
local TIERS = {
    { key = "neutral", range = -1, label = "no land (neutral)", types = { "fasttravelsign" } },
    { key = "large", range = 10000, label = "large", types = {
        "townhall", "villagehall", "warehouse", "tavern", "inn", "barn", "bigbarn", "livestockbarn", "grainfarm",
        "vegetablefarm", "smallfarm", "orchard", "cattlepen", "cattlepens", "animalhusbandry", "windmill", "watermill",
        "lumbermill", "dockyard", "dockyard_big", "riverdock", "fishingpier", "trainingground", "traininggrounds",
        "stagingground", "stables", "tentwarehouse" } },
    { key = "camps", range = 4000, label = "camp", types = {
        "loggingcamp", "lumberjack", "lumberjackspot", "miningcamp", "mininghut", "foragingcamp", "foraginghut",
        "foraginglodge", "hunterscamp", "hunterslodge", "trappercamp", "trapperstation", "fishingcamp", "forester",
        "mudcollector", "watercollector", "charcoalburner", "coalburner", "pit", "outpost", "campsite", "playershack",
        "playercabin", "playerlodge", "playertent", "armorytent", "companiontent", "kitchentent" } },
    { key = "defenses", range = 2500, label = "defense", types = {
        "fence", "gatesmall", "palisade", "palisadegate", "palisadegates", "palisadewalls", "palisadetower",
        "palisadetower_var3", "wall", "wallb", "wallc", "walld", "walle", "wallf", "temp_wallfence", "woodenfence",
        "woodenprimitivewalls", "woodenwalls", "stairs", "stairsonly", "stairssideways", "stairssideways_l",
        "guardhouse", "guardpost", "watchtower", "scoutslookout" } },
    { key = "small", range = 0, label = "own square", types = {
        "rabbittrap", "standingtorch", "campfire", "arrowrack", "boltrack", "weaponrack", "simpleworkbench",
        "advancedworkbench", "cartworkbench", "researchdesk", "advancedresearchdesk", "libraryledger", "cauldron",
        "cauldroninn", "cauldrontavern", "cheesecookingpot", "mixingbucket", "pitsaw", "advancedpitsaw",
        "butcherybench", "butcheryrack", "dryingrack", "smokingrack", "foragerrack", "weaverloom", "weavertable",
        "compostpile", "stockpile", "outhouse", "sleepingbag", "batteringram", "bigballista", "harpoonballista",
        "mangonel", "trebuchet", "villagelantern", "cabinchest", "lodgechest", "shackchest", "sharedchest", "dirtroad",
        "widedirtroad", "stoneroad", "demolishroad", "sapplingactor" } },
}
-- Unlisted types: decorations by their template folder, small things by a word in the name, defenses by their game
-- group; everything else gets the medium range (houses, workshops, crafting, research, village improvements).
local SMALL_FOLDERS = { "/Placeables/Decorations/", "/VillageDecorations/", "/Placeables/Containers/",
    "/Placeables/SiegeWeapons/", "/Placeables/Traps/", "/Placeables/Torches/" }
local SMALL_WORDS = { "trophy", "chest", "torch", "lantern", "banner", "rack", "trap" }
local MEDIUM_RANGE = 5000
local TIER_OF = {}
for _, t in ipairs(TIERS) do
    for _, n in ipairs(t.types) do TIER_OF[n] = t end
end

local typeCache = {} -- actor address -> { name = type, group = build group }

local function baseTypeName(s)
    s = s:match("([^%./]+)$") or s
    s = s:gsub("^Default__", ""):gsub("_C$", ""):gsub("_?[Tt]emplate$", ""):gsub("^[A-Z][A-Z]?_", "")
    return s
end

-- Defenses recognized by name where the class path doesn't say (construction sites, 0.7.4).
local DEFENSE_WORDS = { "fence", "gate", "palisade", "guardpost", "guardhouse", "wall", "tower" }

-- The building's type name and group (its folder under /Game/Mist/Props/TownBuilding, else "Other").
-- NEVER read the template's soft class fields (PlaceableActorClass): UE4SS crashes copying a soft path
-- whose data isn't set yet (2026-10-12 14:01, a friend's fresh mining camp site: push_softobjectproperty ->
-- FSoftObjectPath copy -> null read; Lua's pcall can't catch it). Only plain object names are read here.
local function buildingType(a)
    local addr, oname = 0, ""
    pcall(function() addr = a:GetAddress() end)
    pcall(function() oname = a:GetFName():ToString() end)
    local ck = tostring(addr) .. ":" .. oname -- addresses are reused after an actor is destroyed
    local c = typeCache[ck]
    if c then return c end
    local clsPath, tplFull, tplName = "", "", nil
    pcall(function() clsPath = a:GetClass():GetFullName() end)
    local tpl = nil
    pcall(function() tpl = a.PlaceableData.PlaceableTemplate end)
    if valid(tpl) then
        pcall(function() tplName = tpl:GetFName():ToString() end)
        pcall(function() tplFull = tpl:GetFullName() end)
    end
    local name = nil
    if tplName and tplName ~= "" then name = baseTypeName(tplName) end
    if not name or name == "" then name = baseTypeName(clsPath:match("%.([%w_]+)$") or clsPath) end
    local group = clsPath:match("/TownBuilding/([^/]+)/")
    if group == "ConstructionSite" or not group then
        group = tplFull:match("/TownBuilding/([^/]+)/")
        if not group then
            local n = name:lower()
            for _, w in ipairs(DEFENSE_WORDS) do
                if n:find(w, 1, true) then group = "Defenses" end
            end
        end
        group = group or (clsPath:find("/TownBuilding/ConstructionSite/", 1, true) and "ConstructionSite" or "Other")
    end
    c = { name = name, group = group, cls = clsPath, tpl = tplFull }
    typeCache[ck] = c
    return c
end

-- Range in cm and where it came from.
local function claimRangeOf(a)
    local t = buildingType(a)
    local n, g = t.name:lower(), t.group:lower()
    local tier = TIER_OF[n]
    if claimRanges[n] then return claimRanges[n], "set (type)" end
    if claimRanges[g] then return claimRanges[g], "set (group)" end
    if tier and claimRanges[tier.key] then return claimRanges[tier.key], "set (" .. tier.key .. ")" end
    if tier then return tier.range, tier.label end
    for _, f in ipairs(SMALL_FOLDERS) do
        if (t.tpl or ""):find(f, 1, true) then return claimRanges.small or 0, "own square (folder)" end
    end
    for _, w in ipairs(SMALL_WORDS) do
        if n:find(w, 1, true) then return claimRanges.small or 0, "own square (name)" end
    end
    if g == "defenses" then return claimRanges.defenses or 2500, "defense (group)" end
    return claimRanges.medium or MEDIUM_RANGE, "medium"
end

local claimsMod = nil
do
    local okC, mk = pcall(dofile, modDir .. "\\Scripts\\claims.lua")
    if okC and type(mk) == "function" then
        local okM, m = pcall(mk, {
            log = log, valid = valid, guidStr = guidStr, arrLen = arrLen, arrGet = arrGet,
            NEAR_BUILDING = NEAR_BUILDING, dataPath = dataPath, townHallArea = townHallArea,
            playerVillages = playerVillages, priority = claimPriority,
            claimRange = function(a) local r = claimRangeOf(a); return r end,
            saveName = function() return ensureLoaded() and saveName or nil end,
            worldKey = function()
                local ok, a = pcall(function() return FindFirstOf("MistWorldDataHolder"):GetAddress() end)
                return ok and a or nil
            end,
        })
        if okM and type(m) == "table" then claimsMod = m else log("claims.lua setup failed: " .. tostring(m)) end
    else
        log("could not load claims.lua: " .. tostring(mk))
    end
end

-- The village owning the land at (x, y, z) by the claims (nil = free land); without claims the
-- older rule (villageAt). Second result: true when the answer came from the claims.
local function landAt(x, y, z)
    if claimsMod then
        local ok = pcall(claimsMod.update)
        if ok and claimsMod.ready() then return claimsMod.ownerAt(x, y), true end
    end
    return villageAt(x, y, z), false
end

-- May req build on land owned by v? Its owner, a friend it trusts, or anyone on an unowned
-- village. The host follows the same rule (2026-10-12: to help a friend build, the host
-- adds himself to that village's trust list; what he builds there belongs to the friend).
local function mayBuild(req, v)
    local key = guidStr(v.PersistentGuid)
    local o = owners[key]
    if o == nil or o.owner == req.name then return true end
    if trusted[key] and trusted[key][req.name] then return true end
    return false, o.owner
end

local function landMessage(v, owner)
    return string.format("This land belongs to %s (%s). Build on your own or free land, or ask %s to trust you.",
        villageLabel(v), owner, owner)
end

-- Friends' buildings outside every village. With no player building within 100 m the game adds a
-- new building to the MAIN settlement (AMistSettlement::FindOrCreatePlayerSettlement returns the
-- host's main village whenever one exists), so a friend's lone fence or first outpost building
-- would become the host's. Right after such a placement the new object moves to the builder's
-- nearest own village (town structures through the game's "change" request, other placeables
-- through AMistPlaceable::SetSettlement). From there the builder can "change" it to a new
-- settlement themselves.
-- Since 0.7.0 (land claims) every placement is followed: on claimed land the new objects must join
-- the land's village (target), on free land the builder's own village (or found one).
local strayPlacing = nil -- during a placement: { req, x, y, target (village or nil = free land), objects }
local strayQueue = {}

local function nearestOwnedVillage(name, x, y)
    local best, bestD2 = nil, nil
    for _, v in ipairs(playerVillages()) do
        local o = owners[guidStr(v.PersistentGuid)]
        if o and o.owner == name then
            local d2 = nearestBuilding2(v, x, y) or math.huge
            if best == nil or d2 < bestD2 then best, bestD2 = v, d2 end
        end
    end
    return best
end

local townStructureClass = nil

local function isTownStructure(o)
    if not townStructureClass then
        pcall(function() townStructureClass = StaticFindObject("/Script/Mist.MistTownStructure") end)
    end
    local ok, r = pcall(function() return o:IsA(townStructureClass) end)
    return ok and r == true
end

local function ownedCount(name)
    local n = 0
    for _, v in ipairs(playerVillages()) do
        local o = owners[guidStr(v.PersistentGuid)]
        if o and o.owner == name then n = n + 1 end
    end
    return n
end

-- A friend's first village: the game's own "change -> new settlement" on their building (host side,
-- ServerSwitchStructureToNewSettlement -> AMistSettlement::CreatePlayerOutpost), owned by them.
local function foundVillage(db, obj, req)
    local ok, err = pcall(function()
        db:ServerSwitchStructureToNewSettlement(obj.PersistentGuid, {
            ObjectReferenceGuid = { A = 0, B = 0, C = 0, D = 0 },
            CustomName = FText("New Village"),
        })
    end)
    local v = nil
    pcall(function() v = obj.PlaceableData.Settlement.Actor end)
    if not ok or not valid(v) or not isPlayerVillage(v) or owners[guidStr(v.PersistentGuid)] then
        log("FOUND failed for " .. req.name .. ": " .. tostring(err))
        return nil
    end
    owners[guidStr(v.PersistentGuid)] = { owner = req.name, label = villageLabel(v), seq = nextSeq() }
    pendingFounder = nil
    saveOwners()
    log(string.format("FOUND %s by %s with %s", villageLabel(v), req.name, className(obj)))
    tell(req, "You founded your village: " .. villageLabel(v) .. ". Rename it in its dashboard if you like.")
    return v
end

local function moveTo(db, obj, target)
    return pcall(function()
        if isTownStructure(obj) then
            db:ServerSwitchStructureToSettlement(obj.PersistentGuid, target.PersistentGuid)
        else
            obj:SetSettlement(target)
        end
    end)
end

-- 0.7.9: record the village a building belongs to (see "buildings stay where they were built").
local keepSeen = {}  -- building GUID -> time first seen without a record
local function keepAs(obj, v)
    pcall(function()
        local bk = guidStr(obj.PersistentGuid)
        keep[bk] = guidStr(v.PersistentGuid)
        keepSeen[bk] = nil
        saveOwners()
    end)
end

local function settleStray(e)
    local db = nil
    pcall(function() db = hostController().DataBrokerComponent end)
    claimUnowned() -- a brand-new main settlement belongs to the host right away
    local main = nil
    pcall(function() main = FindFirstOf("MistWorldDataHolder").Data.PlayerSettlement.Actor end)
    -- Town structures first, so a building (or its construction site) can found the village that
    -- the rest of the placement then joins.
    table.sort(e.objects, function(a, b) return isTownStructure(a) and not isTownStructure(b) end)
    for _, obj in ipairs(e.objects) do
        if valid(obj) then
            local v = nil
            pcall(function() v = obj.PlaceableData.Settlement.Actor end)
            if e.target then
                -- Claimed land: the new object belongs to the land's village (the game picks the
                -- village of the closest building, which may be a neighbor's).
                if valid(v) and isPlayerVillage(v) and valid(e.target)
                    and not sameGuid(v.PersistentGuid, e.target.PersistentGuid) then
                    local ok, err = moveTo(db, obj, e.target)
                    if ok then keepAs(obj, e.target) end
                    log(string.format("JOIN %s by %s at %.0f, %.0f joined %s -> %s", className(obj), e.req.name, e.x, e.y,
                        villageLabel(v), ok and ("moved to " .. villageLabel(e.target) .. " (its land)")
                        or ("move FAILED: " .. tostring(err))))
                end
            else
                local o = valid(v) and owners[guidStr(v.PersistentGuid)] or nil
                -- The very first building of the main settlement stays (it IS the main settlement).
                local firstOfMain = false
                if valid(v) and valid(main) and sameGuid(v.PersistentGuid, main.PersistentGuid) then
                    pcall(function() firstOfMain = arrLen(v.Data.Structures) <= 1 end)
                end
                if valid(v) and isPlayerVillage(v) and o and not firstOfMain and o.owner ~= e.req.name then
                    local target = nearestOwnedVillage(e.req.name, e.x, e.y)
                    local what = string.format("%s by %s at %.0f, %.0f joined %s", className(obj), e.req.name, e.x, e.y,
                        villageLabel(v))
                    if target then
                        local ok, err = moveTo(db, obj, target)
                        if ok then keepAs(obj, target) end
                        log("STRAY " .. what .. (ok and (" -> moved to " .. villageLabel(target)) or (" -> move FAILED: " .. tostring(err))))
                        if ok then tell(e.req, "Built outside every village: added to your " .. villageLabel(target) .. ".") end
                    elseif isTownStructure(obj) and ownedCount(e.req.name) < villageLimit then
                        log("STRAY " .. what .. " -> founding " .. e.req.name .. "'s village")
                        local nv = foundVillage(db, obj, e.req)
                        if nv then keepAs(obj, nv) end
                    else
                        log("STRAY " .. what .. " -> stays (builder owns no village)")
                        tell(e.req, "That joined " .. villageLabel(v) .. ". To found your village, place a building outside every village.")
                    end
                end
            end
        end
    end
end

pcall(function()
    NotifyOnNewObject("/Script/Mist.MistPlaceable", function(obj)
        if strayPlacing then table.insert(strayPlacing.objects, obj) end
    end)
end)

for _, fn in ipairs({ "ServerPlace", "ServerPlaceNamed", "ServerPlacePlan" }) do
    pcall(function()
        RegisterHook("/Script/Mist.MistBuildingComponent:" .. fn, function() end, function()
            if strayPlacing then
                strayPlacing.time = os.time()
                if #strayPlacing.objects > 0 then table.insert(strayQueue, strayPlacing) end
                strayPlacing = nil
            end
        end)
    end)
end

if type(LoopInGameThreadWithDelay) == "function" then
    pcall(LoopInGameThreadWithDelay, 1000, function()
        if #strayQueue == 0 then return end
        local now, rest = os.time(), {}
        for _, e in ipairs(strayQueue) do
            if now - e.time >= 1 then
                local ok, err = pcall(settleStray, e)
                if not ok then log("stray error: " .. tostring(err)) end
            else
                rest[#rest + 1] = e
            end
        end
        strayQueue = rest
    end)
end

-- Buildings stay in the village they were built for (0.7.9). The game itself moves some buildings
-- to another village later: 2026-10-13 a friend's three rabbit traps, placed for their village on
-- 2026-10-12, turned up in another village with no player request (suspect: a trapper camp taking traps
-- in its search radius, UMistTrapComponent.BoundTrapperCamp). Every building's village is recorded
-- (at placement, after a player's own "change" request, or when first seen), and a building the game
-- moved is moved back through the same calls the placement rule uses. If the game keeps moving one
-- (KEEP_MAX_MOVES in 10 minutes) it is left where the game puts it and logged.
local KEEP_ADOPT_AFTER = 10 -- seconds a building without a record must be seen before its village is recorded
local KEEP_SETTLE = 20      -- seconds after a load before the first check
local KEEP_MAX_MOVES = 3
local keepMoves, keepGaveUp, keepWorld = {}, {}, nil
local trapComponentClass = nil

-- For the log: the village of the trapper camp a trap is bound to, if any.
local function trapCampVillage(obj)
    local label = nil
    pcall(function()
        if not trapComponentClass then trapComponentClass = StaticFindObject("/Script/Mist.MistTrapComponent") end
        local c = obj:GetComponentByClass(trapComponentClass)
        local camp = valid(c) and c.BoundTrapperCamp or nil
        local v = valid(camp) and camp.PlaceableData.Settlement.Actor or nil
        label = valid(v) and villageLabel(v) or (valid(c) and "none" or nil)
    end)
    return label
end

local function keepCheck()
    if mode == "off" or not saveName then return end
    local holder = FindFirstOf("MistWorldDataHolder")
    if not valid(holder) then keepWorld = nil; return end
    local wk = holder:GetAddress()
    if not keepWorld or keepWorld.key ~= wk then
        keepWorld, keepSeen, keepMoves, keepGaveUp = { key = wk, t = os.time() }, {}, {}, {}
        return
    end
    if os.time() - keepWorld.t < KEEP_SETTLE then return end
    if strayPlacing or #strayQueue > 0 then return end -- a placement is being settled
    local now = os.time()
    local where, villagesByKey = {}, {}
    for _, v in ipairs(playerVillages()) do
        local vk = guidStr(v.PersistentGuid)
        villagesByKey[vk] = v
        pcall(function()
            local st = v.Data.Structures
            for i = 1, arrLen(st) do
                pcall(function()
                    local a = arrGet(st, i).PlaceableActor
                    if valid(a) then where[guidStr(a.PersistentGuid)] = { obj = a, vk = vk } end
                end)
            end
        end)
    end
    if next(where) == nil then return end
    local changed = false
    local db = nil
    pcall(function() db = hostController().DataBrokerComponent end)
    for bk, w in pairs(where) do
        local want = keep[bk]
        if want and not villagesByKey[want] then
            keep[bk], want, changed = nil, nil, true -- its village is gone
        end
        if not want then
            keepSeen[bk] = keepSeen[bk] or now
            if now - keepSeen[bk] >= KEEP_ADOPT_AFTER then
                keep[bk], keepSeen[bk], changed = w.vk, nil, true
            end
        elseif want ~= w.vk and not keepGaveUp[bk] then
            local target, from = villagesByKey[want], villagesByKey[w.vk]
            local l = locationOf(w.obj)
            local what = string.format("%s at %.0f, %.0f", className(w.obj), l and l.X or 0, l and l.Y or 0)
            local camp = trapCampVillage(w.obj)
            local why = camp and (" (trapper camp: " .. camp .. ")") or ""
            local times = {}
            for _, t in ipairs(keepMoves[bk] or {}) do
                if now - t < 600 then times[#times + 1] = t end
            end
            if #times >= KEEP_MAX_MOVES then
                keepGaveUp[bk] = true
                log(string.format("KEEP %s: the game keeps moving it to %s%s; left there (bwcoop move fixes it by hand)",
                    what, villageLabel(from), why))
            elseif mode ~= "enforce" then
                log(string.format("KEEP %s: the game moved it from %s to %s%s; mode %s, not moved back", what,
                    villageLabel(target), villageLabel(from), why, mode))
                keepGaveUp[bk] = true
            else
                local ok, err = moveTo(db, w.obj, target)
                times[#times + 1] = now
                keepMoves[bk] = times
                keep[bk] = want -- the move's own "change" request forgets the record; restore it
                log(string.format("KEEP %s: the game moved it from %s to %s%s -> %s", what, villageLabel(target),
                    villageLabel(from), why, ok and "moved back" or ("move back FAILED: " .. tostring(err))))
            end
        end
    end
    for bk in pairs(keep) do
        if not where[bk] then keep[bk], changed = nil, true end -- gone (demolished, or not in this save)
    end
    if changed then saveOwners() end
end

-- A player's own "change" request on a building (allowed by the guard) is a real change: forget the
-- record so the building's new village is recorded once it settles.
for _, fn in ipairs({ "ServerSwitchStructureToSettlement", "ServerSwitchStructureToNewSettlement" }) do
    pcall(function()
        local pending = nil
        RegisterHook("/Script/Mist.MistDataBrokerPlayerComponent:" .. fn, function(ctx, structureGuid)
            pending = nil
            pcall(function() pending = guidStr(structureGuid:get()) end)
        end, function()
            local bk = pending
            pending = nil
            if bk and keep[bk] then
                keep[bk] = nil
                keepSeen[bk] = os.time()
                keepGaveUp[bk] = nil
            end
        end)
    end)
end

if type(LoopInGameThreadWithDelay) == "function" then
    pcall(LoopInGameThreadWithDelay, 5000, function()
        local ok, err = pcall(keepCheck)
        if not ok then log("keep error: " .. tostring(err)) end
    end)
end

-- Village halls per village (2026-10-17; 0.7.27 with BWCoopClient 0.7.10). The game allows one Village Hall and
-- one Town Hall per world (build menu and host check, research/village-halls-2026-10-17.md); the client mod makes both
-- ordinary buildings, so these rules take over, for everyone including the host: a hall only in the placer's own
-- village, one of each kind per village (construction sites count), a Town Hall only after that village's Village
-- Hall is finished. Moving an existing hall (relocation) keeps the plain land rule.
local HALL_KINDS = { villagehall = "Village Hall", townhall = "Town Hall" }

local hallRefusal, hallRefuse
do
local function hallsIn(v)
    local found = { villagehall = { built = 0, sites = 0 }, townhall = { built = 0, sites = 0 } }
    pcall(function()
        local st = v.Data.Structures
        for i = 1, arrLen(st) do
            pcall(function()
                local a = arrGet(st, i).PlaceableActor
                if not valid(a) then return end
                local t = buildingType(a)
                local f = found[t.name:lower()]
                if f then
                    if t.group == "ConstructionSite" then f.sites = f.sites + 1 else f.built = f.built + 1 end
                end
            end)
        end
    end)
    return found
end

-- nil when the hall may go at village v (nil = free land), else what to tell the player.
function hallRefusal(req, kind, v)
    local label = HALL_KINDS[kind]
    if v == nil then return string.format("A %s goes in your own village, not on free land.", label) end
    local o = owners[guidStr(v.PersistentGuid)]
    if not (o and o.owner == req.name) then
        return string.format("A %s goes in your own village; %s isn't yours.", label, villageLabel(v))
    end
    local h = hallsIn(v)
    if h[kind].built + h[kind].sites > 0 then
        return string.format("%s already has a %s%s.", villageLabel(v), label, h[kind].built == 0 and " being built" or "")
    end
    if kind == "townhall" and h.villagehall.built == 0 then
        return string.format("%s needs a finished Village Hall before a Town Hall.", villageLabel(v))
    end
    return nil
end

function hallRefuse(path, req, kind, v, why)
    local what = string.format("%s (%s) by %s at %s: %s", fnName(path), HALL_KINDS[kind], req.name,
        v and villageLabel(v) or "free land", why)
    if mode == "dryrun" then
        log("WOULD BLOCK HALL " .. what)
        return
    end
    if mode == "enforce" and skipCall(path) then
        justBlocked = path
        log("BLOCKED HALL " .. what)
        tell(req, why)
        return
    end
    log("WARNED HALL " .. what)
    tell(req, why)
end
end

-- Placing something: decide by where it goes. Outside every village it may found an outpost.
-- Relocating uses the same request plus the building being moved (sourceIdx: the building
-- actor, relocIdx: its GUID); moving a building out of someone else's village is a change to
-- that village, so the source is checked too.
local function guardPlacement(path, sourceIdx, relocIdx)
    return safeHook(path, function(ctx, args)
        local req = requester(ctx)
        if req == nil then return end
        ensureLoaded()

        if not req.isHost then
            local src = nil
            if relocIdx and args[relocIdx] then
                local a, kind = findByGuid(args[relocIdx]:get())
                src = villageOf(a, kind)
            end
            if not src and sourceIdx and args[sourceIdx] then
                src = villageOf(args[sourceIdx]:get(), "placeable")
            end
            if src then
                local ok, owner = allowed(req, src)
                if not ok then
                    refuse(path, req, src, owner)
                    return
                end
            end
        end

        local state = nil
        pcall(function() state = args[2]:get() end)
        local x, y, z, how = nil, nil, nil, nil
        if state then x, y, z, how = placementWorldXY(state, req) end
        if x == nil then
            log("placement check: no location in " .. fnName(path) .. " by " .. req.name)
            return
        end
        local v, byClaims = landAt(x, y, z)
        local away = ""
        pcall(function()
            local l = locationOf(req.pc.Pawn)
            if l then away = string.format(", %.0f m from them", math.sqrt((l.X - x) ^ 2 + (l.Y - y) ^ 2) / 100) end
        end)
        if byClaims or not req.isHost then
            log(string.format("PLACE %s by %s at %.0f, %.0f (%s%s) -> %s", fnName(path), req.name, x, y, how, away,
                v and (villageLabel(v) .. (byClaims and " land" or "")) or (byClaims and "free land" or "no village (new outpost)")))
        end
        -- village halls (0.7.27): the hall rules above, before the land rule
        local kind, reloc = nil, false
        pcall(function()
            local tpl = args[1]:get()
            if valid(tpl) then kind = baseTypeName(tpl:GetFName():ToString()):lower() end
        end)
        if relocIdx and args[relocIdx] then
            pcall(function() reloc = guidStr(args[relocIdx]:get()) ~= ZERO end)
        end
        if kind and HALL_KINDS[kind] and not reloc then
            local why = hallRefusal(req, kind, v)
            if why then
                hallRefuse(path, req, kind, v, why)
                return
            end
            log(string.format("HALL %s by %s in %s", HALL_KINDS[kind], req.name, villageLabel(v)))
        end
        if v == nil then
            pendingFounder = { name = req.name, time = os.time() }
            if byClaims or not req.isHost then strayPlacing = { req = req, x = x, y = y, objects = {} } end
            return
        end
        if not byClaims then
            -- older rule (claims unavailable): the host may build anywhere
            if req.isHost then return end
            local ok, owner = allowed(req, v)
            if not ok then refuse(path, req, v, owner) end
            return
        end
        local ok, owner = mayBuild(req, v)
        if not ok then
            refuse(path, req, v, owner, landMessage(v, owner))
            return
        end
        strayPlacing = { req = req, x = x, y = y, target = v, objects = {} }
    end)
end

-- Walls and fences are splines with no village of their own: decide by where their
-- points are (roads are open to everyone, see isRoad below). Any point inside another player's village makes the change theirs.
local MAX_SPLINE_POINTS = 64

local function buildRefusal(req, v, byClaims)
    if byClaims then return mayBuild(req, v) end
    if req.isHost then return true end
    return allowed(req, v)
end

local function splineVillageRefusal(req, spline)
    if not valid(spline) then return nil end
    local pts = {}
    pcall(function()
        local arr = spline.Points
        for i = 1, math.min(arrLen(arr), MAX_SPLINE_POINTS) do
            local l = arrGet(arr, i).Location
            pts[#pts + 1] = { l.X, l.Y, l.Z }
        end
    end)
    if #pts == 0 then
        local l = locationOf(spline)
        if l then pts[1] = { l.X, l.Y, l.Z } end
    end
    for _, p in ipairs(pts) do
        local v, byClaims = landAt(p[1], p[2], p[3])
        if v then
            local ok, owner = buildRefusal(req, v, byClaims)
            if not ok then return v, owner, byClaims end
        end
    end
    return nil
end

-- Roads are open to everyone (2026-10-14, 0.7.21): anyone may lay, extend, join, change or remove a road on
-- any land; walls and fences keep the land rule. A road is an AMistRoadActor, a new one comes from a UMistRoadTemplate.
local roadClasses = nil

local function isRoad(o)
    if not valid(o) then return false end
    if not roadClasses then
        local found = {}
        for _, p in ipairs({ "/Script/Mist.MistRoadActor", "/Script/Mist.MistRoadTemplate" }) do
            pcall(function()
                local c = StaticFindObject(p)
                if valid(c) then found[#found + 1] = c end
            end)
        end
        if #found < 2 then return false end
        roadClasses = found
    end
    for _, c in ipairs(roadClasses) do
        local ok, r = pcall(function() return o:IsA(c) end)
        if ok and r == true then return true end
    end
    return false
end

-- A road call: every spline actor it names is a road; with none named, its template is a road template.
local function roadCall(args, splineIdxs, tplIdx)
    local any = false
    for _, i in ipairs(splineIdxs) do
        local o = nil
        pcall(function() o = args[i] and args[i]:get() end)
        if valid(o) then
            if not isRoad(o) then return false end
            any = true
        end
    end
    if any then return true end
    if not tplIdx then return false end
    local t = nil
    pcall(function() t = args[tplIdx] and args[tplIdx]:get() end)
    return isRoad(t)
end

-- splineIdxs: params holding spline actors; posIdx: a new point's position (FVector), if any; tplIdx: the spline
-- template. With land claims the host follows the rule too (0.7.0). Roads are left alone (0.7.21).
local function guardSpline(path, splineIdxs, posIdx, tplIdx)
    return safeHook(path, function(ctx, args)
        local req = requester(ctx)
        if req == nil then return end
        if roadCall(args, splineIdxs, tplIdx) then
            if not req.isHost then log(string.format("ROAD %s by %s (roads are open to everyone)", fnName(path), req.name)) end
            return
        end
        ensureLoaded()
        if req.isHost and not (claimsMod and claimsMod.ready()) then return end
        for _, i in ipairs(splineIdxs) do
            local v, owner, byClaims = splineVillageRefusal(req, args[i] and args[i]:get())
            if v then
                refuse(path, req, v, owner, byClaims and landMessage(v, owner) or nil)
                return
            end
        end
        if posIdx and args[posIdx] then
            local x, y, z = nil, nil, nil
            pcall(function()
                local l = args[posIdx]:get()
                x, y, z = l.X, l.Y, l.Z
            end)
            if x == nil then
                log("spline check: no position in " .. fnName(path) .. " by " .. req.name)
                return
            end
            local v, byClaims = landAt(x, y, z)
            log(string.format("SPLINE %s by %s at %.0f, %.0f -> %s", fnName(path), req.name, x, y,
                v and villageLabel(v) or (byClaims and "free land" or "no village")))
            if v then
                local ok, owner = buildRefusal(req, v, byClaims)
                if not ok then refuse(path, req, v, owner, byClaims and landMessage(v, owner) or nil) end
            end
        end
    end)
end

----------------------------------------------------------------------------- hooks

local BLD = "/Script/Mist.MistBuildingComponent:"
local DB = "/Script/Mist.MistDataBrokerPlayerComponent:"

local count = 0
local okList, list = pcall(dofile, modDir .. "\\Scripts\\guarded_rpcs.lua")
if okList and type(list) == "table" then
    for _, entry in ipairs(list) do
        local fn = fnName(entry[1])
        -- squads.lua handles these: a friend's call to arms goes to their own village. Fast travel signs
        -- are open to everyone (2026-10-12): using one changes nothing about its village.
        if fn ~= "ServerMobilizeReservists" and fn ~= "ServerDismissReservists"
            and fn ~= "ServerExecuteTeleportToSign" and fn ~= "ServerExecuteGroupTeleport"
            and fn ~= "ServerSetNewPlayerSettlement" then
            -- Giving your own villager to another village is allowed: check only the villager. A caravan stop may
            -- point at a friend's village (drop-offs are free, 2026-10-14; caravans.lua checks pickups).
            local idxs = (fn == "ServerSetNpcSettlement" or fn == "Server_CaravanRouteStop_SetSettlementTarget")
                and { 1 } or entry[2]
            if guardGuids(entry[1], idxs) then count = count + 1 end
        end
    end
else
    log("could not load guarded_rpcs.lua: " .. tostring(list))
end

-- "Promote to main" changes the world's main settlement for everyone: host only (2026-10-12).
do
    local path = DB .. "ServerSetNewPlayerSettlement"
    if safeHook(path, function(ctx)
        local req = requester(ctx)
        if req == nil or req.isHost then return end
        if mode == "dryrun" then
            log("WOULD BLOCK ServerSetNewPlayerSettlement by " .. req.name .. " (promote to main is host-only)")
            return
        end
        if mode == "enforce" and skipCall(path) then
            justBlocked = path
            log("BLOCKED ServerSetNewPlayerSettlement by " .. req.name .. " (promote to main is host-only)")
            tell(req, "Only the host can change the main settlement.")
        else
            log("WARNED ServerSetNewPlayerSettlement by " .. req.name .. " (promote to main is host-only)")
            tell(req, "Only the host should change the main settlement; please leave it to them.")
        end
    end) then count = count + 1 end
end

for _, fn in ipairs({ "ServerDisassemble", "ServerDeconstruct", "ServerRemovePlan", "ServerConfirmPlan" }) do
    if guardObject(BLD .. fn, 1) then count = count + 1 end
end
-- ServerPlace(template, state, source, relocGuid); ServerPlaceNamed(template, state, name, source, relocGuid)
if guardPlacement(BLD .. "ServerPlace", 3, 4) then count = count + 1 end
if guardPlacement(BLD .. "ServerPlaceNamed", 4, 5) then count = count + 1 end
if guardPlacement(BLD .. "ServerPlacePlan") then count = count + 1 end
-- Splines: ServerCreateSpline(pos, tpl); ServerExtendSpline(spline, ver, pos, fromStart, tpl, ...);
-- ServerCombineSplines(spline1, v1, atStart1, spline2, v2, atStart2, tpl, ...); ServerCloseSpline(spline, ver, tpl);
-- the rest take (spline, ...).
if guardSpline(BLD .. "ServerCreateSpline", {}, 1, 2) then count = count + 1 end
if guardSpline(BLD .. "ServerExtendSpline", { 1 }, 3, 5) then count = count + 1 end
if guardSpline(BLD .. "ServerCombineSplines", { 1, 4 }, nil, 7) then count = count + 1 end
if guardSpline(BLD .. "ServerCloseSpline", { 1 }, nil, 3) then count = count + 1 end
if guardSpline(BLD .. "ServerRemoveSpline", { 1 }) then count = count + 1 end
if guardSpline(BLD .. "ServerRemoveSplineSegment", { 1 }) then count = count + 1 end

-- A structure moved into a brand-new outpost: the requester founds it.
-- One village per friend (villageLimit; the host can assign more): a friend at the limit can't found
-- another with "change -> new settlement".
safeHook(DB .. "ServerSwitchStructureToNewSettlement", function(ctx, args)
    local path = DB .. "ServerSwitchStructureToNewSettlement"
    if justBlocked == path then return end
    local req = requester(ctx)
    if req and not req.isHost and ensureLoaded() and ownedCount(req.name) >= villageLimit then
        if mode == "enforce" and skipCall(path) then
            justBlocked = path
            log(string.format("BLOCKED new settlement by %s (owns %d, limit %d)", req.name, ownedCount(req.name), villageLimit))
            tell(req, "One village per player: you already have yours. Ask the host if you need another.")
            return
        end
        log(string.format("WARNED new settlement by %s (owns %d, limit %d)", req.name, ownedCount(req.name), villageLimit))
    end
    if req then pendingFounder = { name = req.name, time = os.time() } end
end)

-- Villager transfers (the villager's "settlement" setting, ServerSetNpcSettlement): recorded as they
-- happen and redone after every load, since the save is reloaded like a snapshot. A friend may give
-- their own villager to any village (the guard checks only the villager); taking one needs its owner.
local pendingTransfer = nil
pcall(function()
    RegisterHook(DB .. "ServerSetNpcSettlement", function(ctx, npcGuid, settlementGuid)
        pendingTransfer = nil
        pcall(function()
            local npc = findByGuid(npcGuid:get())
            pendingTransfer = { npc = npc, key = guidStr(npcGuid:get()), to = guidStr(settlementGuid:get()) }
        end)
    end, function()
        local t = pendingTransfer
        pendingTransfer = nil
        if not t or justBlocked == DB .. "ServerSetNpcSettlement" or not ensureLoaded() then return end
        local now = nil
        pcall(function() now = guidStr(t.npc.AssignedSettlement.PersistentGuid) end)
        if now ~= t.to or transfers[t.key] == t.to then return end
        transfers[t.key] = t.to
        saveOwners()
        log(string.format("TRANSFER villager %s -> %s (recorded, redone after every load)", t.key:sub(1, 8), t.to:sub(1, 8)))
    end)
end)

-- The game registers every recruit in the main settlement (AMistTownNpc::Hire ->
-- FindOrCreatePlayerSettlement), whoever recruited them. A friend's recruit moves to the friend's own
-- village closest to it, through the game's own request (recorded like any transfer). True when the
-- recruit ends up in a village of theirs.
local function homeRecruit(name, npc)
    if not ensureLoaded() or not valid(npc) then return false end
    -- 0.7.28: a newcomer joins the village it waited at (newcomers.lua moves it)
    if newcomers.mod and newcomers.mod.isNewcomer(npc) then return false end
    local cur = nil
    pcall(function() cur = npc.AssignedSettlement end)
    local o = valid(cur) and owners[guidStr(cur.PersistentGuid)] or nil
    if o and o.owner == name then return true end
    local l = locationOf(npc)
    local target = nearestOwnedVillage(name, l and l.X or 0, l and l.Y or 0)
    if not target then
        log(string.format("RECRUIT by %s stays in %s (they own no village yet)", name, valid(cur) and villageLabel(cur) or "?"))
        return false
    end
    local db = nil
    pcall(function() db = hostController().DataBrokerComponent end)
    local ok, err = pcall(function() db:ServerSetNpcSettlement(npc.PersistentGuid, target.PersistentGuid) end)
    log(string.format("RECRUIT by %s -> %s%s", name, villageLabel(target), ok and "" or (" FAILED: " .. tostring(err))))
    return ok
end

-- Redo recorded transfers after a load. Returns how many villagers were moved.
local function replayTransfers()
    if next(transfers) == nil then return 0 end
    local db = nil
    pcall(function() db = hostController().DataBrokerComponent end)
    if not valid(db) then return 0 end
    local villages = {}
    for _, v in ipairs(playerVillages()) do villages[guidStr(v.PersistentGuid)] = v end
    local n = 0
    for _, npc in ipairs(FindAllOf("MistTownNpc") or {}) do
        local key = nil
        pcall(function() key = guidStr(npc.PersistentGuid) end)
        local to = key and transfers[key]
        if to and villages[to] then
            local cur = nil
            pcall(function() cur = guidStr(npc.AssignedSettlement.PersistentGuid) end)
            if cur ~= to then
                local ok, err = pcall(function() db:ServerSetNpcSettlement(npc.PersistentGuid, villages[to].PersistentGuid) end)
                log(string.format("TRANSFER %s -> %s %s", key:sub(1, 8), villageLabel(villages[to]), ok and "redone" or ("FAILED: " .. tostring(err))))
                if ok then n = n + 1 end
            end
        end
    end
    return n
end

-- Autosave (about every 2 minutes, game thread): claim new villages and save owners when
-- saving starts; update name tags once it has finished.
safeHook("/Script/Mist.MistOasisGameState:MulticastSetSavingState", function(ctx, args)
    if not args[1] then return end
    if args[1]:get() == true then
        claimUnowned()
        saveOwners()
    else
        applyTags()
    end
end)

-- Tell a friend which village is theirs once they finish loading.
safeHook("/Script/Mist.MistOasisPlayerState:ServerSetLoadingScreenActive", function(ctx, args)
    if not (args[1] and args[1]:get() == false) then return end
    local req = requester(ctx)
    if req == nil or req.isHost or not ensureLoaded() then return end
    local mine = {}
    for _, o in pairs(owners) do
        if o.owner == req.name then mine[#mine + 1] = o.label ~= "" and o.label or "?" end
    end
    local text = #mine > 0 and ("BWCoop: your village: " .. table.concat(mine, ", ") .. ". Other villages are read-only for you.")
        or "BWCoop: you don't own a village yet. Found an outpost or ask the host to assign one."
    tell(req, text)
end)

----------------------------------------------------------------------------- admin and squads

local api = { log = log, valid = valid, playerInfo = playerInfo, adminCalling = false, sendMessage = sendMessage,
    channelOrder = CHANNEL_ORDER }
local admin = {}
do
    local okA, mk = pcall(dofile, modDir .. "\\Scripts\\admin.lua")
    if okA and type(mk) == "function" then
        local okB, cmds = pcall(mk, api)
        if okB and type(cmds) == "table" then admin = cmds else log("admin.lua setup failed: " .. tostring(cmds)) end
    else
        log("could not load admin.lua: " .. tostring(mk))
    end
end

-- Companion squads per player (squads.lua).
local squadsMod = nil
do
    local core = {
        log = log, valid = valid, guidStr = guidStr, arrLen = arrLen, arrGet = arrGet,
        playerInfo = playerInfo, requester = requester, tell = tell, skipCall = skipCall, fnName = fnName,
        modDir = modDir, hostController = hostController,
        tagsOn = function() return tagsOn end,
        refuse = refuse, nearestOwnedVillage = nearestOwnedVillage, locationOf = locationOf, villageLabel = villageLabel,
        homeRecruit = homeRecruit,
        villageOfGuid = function(g) local a, kind = findByGuid(g); return villageOf(a, kind) end,
        mode = function() return mode end,
        -- Path of the call a village guard just blocked (fresh for paths in guarded_rpcs.lua).
        justBlocked = function() return justBlocked end,
        villageOwner = function(v)
            if not ensureLoaded() then return nil end
            local o = owners[guidStr(v.PersistentGuid)]
            return o and o.owner or nil
        end,
    }
    local okS, mk = pcall(dofile, modDir .. "\\Scripts\\squads.lua")
    if okS and type(mk) == "function" then
        local okM, m = pcall(mk, core)
        if okM and type(m) == "table" then squadsMod = m else log("squads.lua setup failed: " .. tostring(m)) end
    else
        log("could not load squads.lua: " .. tostring(mk))
    end
end

-- Caravans and village stock (0.7.11): route ownership, "pickups need trust", bwcoop stock / caravans.
local caravansMod = nil
local panelNow = nil -- set with the bridge code below: publish the Villages panel data on the next tick
do
    local okC, mk = pcall(dofile, modDir .. "\\Scripts\\caravans.lua")
    if okC and type(mk) == "function" then
        local okM, m = pcall(mk, {
            log = log, valid = valid, guidStr = guidStr, arrLen = arrLen, arrGet = arrGet, ZERO = ZERO,
            className = className, objName = objName, villageLabel = villageLabel, locationOf = locationOf,
            playerVillages = playerVillages, hostController = hostController,
            requester = requester, refuse = refuse, tell = tell,
            justBlocked = function() return justBlocked end,
            villageOfGuid = function(g) local a, kind = findByGuid(g); return villageOf(a, kind) end,
            villageOwner = function(v)
                if not ensureLoaded() then return nil end
                local o = owners[guidStr(v.PersistentGuid)]
                return o and o.owner or nil
            end,
            isTrusted = function(v, name)
                local t = trusted[guidStr(v.PersistentGuid)]
                return t ~= nil and t[name] == true
            end,
            playerByName = function(name)
                for _, pc in ipairs(FindAllOf("MistOasisPlayerController") or {}) do
                    local info = playerInfo(pc)
                    if info and info.name == name then return info end
                end
                return nil
            end,
            stockRules = function() return stockRules end,
            stockRoutes = function() return stockRoutes end,
            saveData = function() saveOwners() end,
            panelNow = function() if panelNow then panelNow() end end,
        })
        if okM and type(m) == "table" then
            caravansMod = m
            caravanLookup = m.lookup
        else
            log("caravans.lua setup failed: " .. tostring(m))
        end
    else
        log("could not load caravans.lua: " .. tostring(mk))
    end
end
if type(LoopInGameThreadWithDelay) == "function" then
    pcall(LoopInGameThreadWithDelay, 30000, function()
        if not caravansMod or mode == "off" or not saveName then return end
        local ok, err = pcall(caravansMod.audit, mode)
        if not ok then log("caravan audit error: " .. tostring(err)) end
        if ensureLoaded() then
            ok, err = pcall(caravansMod.keepApply)
            if not ok then log("keep-stocked error: " .. tostring(err)) end
        end
    end)
end

-- Balance settings (0.7.12): cart space, storage, hiring cost, road speed, carry size; host-set per world.
local balanceMod = nil
do
    local okB, mk = pcall(dofile, modDir .. "\\Scripts\\balance.lua")
    if okB and type(mk) == "function" then
        local okM, m = pcall(mk, {
            log = log, valid = valid, hostController = hostController,
            values = function() return balance end,
            setValue = function(k, v) balance[k] = v; saveOwners() end,
            storages = function() return caravansMod and caravansMod.storages() or {} end,
        })
        if okM and type(m) == "table" then balanceMod = m else log("balance.lua setup failed: " .. tostring(m)) end
    else
        log("could not load balance.lua: " .. tostring(mk))
    end
end
if type(LoopInGameThreadWithDelay) == "function" then
    pcall(LoopInGameThreadWithDelay, 10000, function()
        if not balanceMod or not ensureLoaded() then return end
        local ok, err = pcall(balanceMod.apply)
        if not ok then log("balance error: " .. tostring(err)) end
    end)
end

----------------------------------------------------------------------------- friend cheats

-- The game's cheat functions only check that the caller is a player, not the host, so a friend
-- who launches with -cheats could run them on the host. Only the host may use them, unless
-- "bwcoop cheats open". The host's own bwcoop admin commands are marked by api.adminCalling.
-- 0.7.23: requests from players' Villages panels (BWCoopClient 0.7.9) ride on the UnlockPerk console command: a
-- "BWCoop|..." perk name goes to caravans.lua's request handler and the real call is skipped, for everyone.
local cheatHooks = 0
local UNLOCK_PERK = "/Script/Mist.MistCheatingComponent:ServerUnlockPerk"
do
    local okC, cheatList = pcall(dofile, modDir .. "\\Scripts\\cheat_rpcs.lua")
    if okC and type(cheatList) == "table" then
        for _, path in ipairs(cheatList) do
            local ok = pcall(function()
                RegisterHook(path, function(ctx, ...)
                    if path == UNLOCK_PERK then
                        local text, args = nil, { ... }
                        pcall(function() text = args[1]:get():ToString() end)
                        -- "BWCoop;..." from BWCoopClient 0.7.9.3+ (the console runs "|" as a command separator
                        -- outside quotes); "BWCoop|..." still works when typed in quotes (0.7.25)
                        if text and (text:sub(1, 7) == "BWCoop|" or text:sub(1, 7) == "BWCoop;") then
                            local okR, e = pcall(function()
                                skipCall(path)
                                local req = requester(ctx)
                                if req and caravansMod then caravansMod.request(req, text) end
                            end)
                            if not okR then log("request error: " .. tostring(e)) end
                            return
                        end
                    end
                    if cheatsOpen or api.adminCalling then return end
                    local okH, e = pcall(function()
                        local req = requester(ctx)
                        if req == nil or req.isHost then return end
                        if skipCall(path) then
                            log("BLOCKED cheat " .. fnName(path) .. " by " .. req.name)
                            tell(req, "Cheats are host-only in this world.")
                        else
                            log("CHEAT NOT BLOCKED (no add-on) " .. fnName(path) .. " by " .. req.name)
                        end
                    end)
                    if not okH then log("cheat guard error in " .. fnName(path) .. ": " .. tostring(e)) end
                end)
            end)
            if ok then cheatHooks = cheatHooks + 1 end
        end
    else
        log("could not load cheat_rpcs.lua: " .. tostring(cheatList))
    end
end

----------------------------------------------------------------------------- console

local function findVillage(query)
    local q = query:lower()
    for _, v in ipairs(playerVillages()) do
        local key = guidStr(v.PersistentGuid)
        if villageLabel(v):lower() == q or key:lower():sub(1, #q) == q then return v end
    end
    return nil
end

-- Villagers registered away from where they live: report (arg ""), fix ("fix"), or list one
-- village's residents in detail (arg = village name). Returns the number of villagers moved.
local function people(say, arg)
    -- Villagers registered to one village but living (or, if homeless, working) in another.
    -- "Mobilize companions" and the call-to-arms screen use the village's own resident list
    -- (AMistSettlement::MobilizeReservists), and the village guards use the registration, so
    -- such villagers show up in the wrong player's call to arms. "people fix" re-registers
    -- them where they live, through the game's own request (ServerSetNpcSettlement ->
    -- AMistTownNpc::SetAssignedSettlement keeps house and job when they are in that village).
    local fix = trim(arg):lower() == "fix"
    local detail = (not fix and trim(arg) ~= "") and findVillage(trim(arg)) or nil
    if trim(arg) ~= "" and not fix and not detail then say("people: no village " .. trim(arg)); return 0 end
    local db = nil
    pcall(function() db = hostController().DataBrokerComponent end)
    local function placeVillage(sd)
        local v = nil
        pcall(function() v = sd.Settlement.Actor end)
        return valid(v) and isPlayerVillage(v) and v or nil
    end
    local function npcName(npc)
        local n = nil
        pcall(function() n = npc.NpcData.Nickname.CustomName:ToString() end)
        if not n or n == "" then pcall(function() n = guidStr(npc.PersistentGuid):sub(1, 8) end) end
        return n or "?"
    end
    if detail then
        -- Both lists the game keeps: the village data's residents (what its call-to-arms screen
        -- counts, UMistSettlementCallToArmsScreen::SetData) and the village actor's resident list
        -- (what "Mobilize companions" calls up, AMistSettlement::MobilizeReservists).
        local function where(x) return valid(x) and villageLabel(x) or "-" end
        local function show(listName, arr, getNpc)
            local n = arrLen(arr)
            say(string.format("%s %s: %d", villageLabel(detail), listName, n))
            for i = 1, n do
                local npc = getNpc(arrGet(arr, i))
                local reg, asg, house, job, squad = nil, nil, nil, nil, "-"
                pcall(function() reg = npc.NpcData.Settlement.Actor end)
                pcall(function() asg = npc.AssignedSettlement end)
                pcall(function() house = placeVillage(npc.NpcData.House) end)
                pcall(function() job = placeVillage(npc.NpcData.AssignedStructure) end)
                pcall(function() squad = npc.NpcData.CombatGroup.CombatGroupName.CustomName:ToString() end)
                say(string.format("  %-18s registered %s / assigned %s / lives %s / works %s / squad %s",
                    npcName(npc), where(reg), where(asg), where(house), where(job), squad))
            end
        end
        pcall(function() show("data residents (call-to-arms screen)", detail.Data.Residents, function(d) return d.NpcActor end) end)
        pcall(function() show("actor residents (mobilize)", detail.PopulationComponent.Residents, function(a) return a end) end)
        return
    end
    local moves, total = {}, 0
    for _, v in ipairs(playerVillages()) do
        local o = owners[guidStr(v.PersistentGuid)]
        local arr, n = nil, 0
        pcall(function() arr = v.PopulationComponent.Residents; n = arrLen(arr) end)
        total = total + n
        say(string.format("  %-24s %3d residents  owner: %s", villageLabel(v), n, o and o.owner or "(none)"))
        for i = 1, n do
            local npc = arrGet(arr, i)
            local home, why = nil, nil
            pcall(function() home = placeVillage(npc.NpcData.House) end)
            if home then why = "lives" else
                pcall(function() home = placeVillage(npc.NpcData.AssignedStructure) end)
                if home then why = "works" end
            end
            if home and not sameGuid(home.PersistentGuid, v.PersistentGuid) then
                moves[#moves + 1] = { npc = npc, from = v, to = home, why = why }
            end
        end
    end
    if #moves == 0 then
        say(string.format("people: %d residents, everyone is registered where they live", total))
    else
        for _, mv in ipairs(moves) do
            local line = string.format("  %s: registered %s, %s in %s", npcName(mv.npc), villageLabel(mv.from), mv.why,
                villageLabel(mv.to))
            if fix then
                local ok, err = pcall(function() db:ServerSetNpcSettlement(mv.npc.PersistentGuid, mv.to.PersistentGuid) end)
                line = line .. (ok and " -> moved" or (" -> FAILED: " .. tostring(err)))
                log("PEOPLE" .. line)
            end
            say(line)
        end
        say(fix and string.format("people fix: %d villagers re-registered where they live", #moves)
            or string.format("people: %d villagers registered away from home; \"bwcoop people fix\" moves them", #moves))
    end
    return fix and #moves or 0
end

-- World setup, run automatically ~15 s after every load (the save is used like a snapshot, so
-- whatever the mod set up in a session is gone after the next load) and by "bwcoop setup":
-- claim new villages, re-register villagers where they live, give each player's people their own
-- squads, and tag village names (squad names follow within seconds).
local function setup(say)
    if not ensureLoaded() then return say("setup: no save loaded") end
    claimUnowned()
    local redone = replayTransfers()
    local moved = people(function(s) log(s) end, "fix")
    local split = 0
    if squadsMod then split = squadsMod.split(function(s) log(s) end) or 0 end
    applyTags()
    saveOwners()
    local msg = string.format("BWCoop setup: %d transfers redone, %d villagers re-registered where they live, %d people moved to their own squads",
        redone, moved, split)
    log("SETUP " .. msg)
    say(msg)
end

local setupWorld, setupSeen = nil, nil
if type(LoopInGameThreadWithDelay) == "function" then
    pcall(LoopInGameThreadWithDelay, 5000, function()
        if mode == "off" then return end
        local ok, e = pcall(function()
            local holder = FindFirstOf("MistWorldDataHolder")
            if not valid(holder) then setupSeen = nil; return end
            local key = holder:GetAddress()
            if key == setupWorld then return end
            if not ensureLoaded() or not autoSetup or not valid(hostController()) then return end
            if not setupSeen or setupSeen.key ~= key then setupSeen = { key = key, t = os.time() }; return end
            if os.time() - setupSeen.t < 15 then return end
            setupWorld = key
            local host = playerInfo(hostController())
            setup(function(s) if host then tell(host, s) end end)
        end)
        if not ok then log("auto setup error: " .. tostring(e)) end
    end)
end

----------------------------------------------------------------------------- client mod bridge

-- BWCoopClient (the official mod every player installs) ships BP_BWCoopState, an actor the game
-- spawns on the host and replicates to every player. Its two arrays let each player's own game show
-- which village a spot belongs to in build mode (the same rule as villageAt):
--   Villages   = { name0, owner0, name1, owner1, ... }   (shown name with tag; "" = no owner)
--   AreaPoints = { x, y, r, v, ... } in cm: a town hall with r = -(influence radius), each building
--                with r = NEAR_BUILDING; v = the village's index into Villages (2 * n).
-- Buildings are thinned to one per 10 m cell per village; at most MAX_POINTS points (the client
-- checks them five times a second in build mode only).
local BRIDGE_CELL, MAX_POINTS = 1000, 500
local DOT_STEP, DOT_CELL, MAX_DOTS = 1200, 1000, 600
local bridge = { actor = nil, sig = nil, villages = 0, points = 0, dots = 0, rev = 0, err = nil }

-- Map area colors (0.6.5): the host can set one per player ("bwcoop color"); otherwise a player
-- gets the first palette color nobody has yet, kept in the save's data file so it never changes.
local COLOR_NAMES = { red = "D92626", blue = "2659E6", green = "26B333", purple = "9933CC", orange = "F2801A",
    cyan = "1ABFD9", pink = "F266B3", brown = "804D26", yellow = "F2CC1A", white = "FFFFFF", black = "1A1A1A",
    gray = "808080" }
local AUTO_COLORS = { "red", "blue", "green", "purple", "orange", "cyan", "pink", "brown" }
local UNOWNED_COLOR = "808080"

-- "red", "#2659E6" or "2659e6" -> "2659E6"; nil if unknown.
local function colorHex(text)
    local t = trim(text or ""):lower()
    if COLOR_NAMES[t] then return COLOR_NAMES[t] end
    local h = t:match("^#?(%x%x%x%x%x%x)$")
    return h and h:upper() or nil
end

local function playerColor(name)
    local c = playerColors[name]
    if c then return c.hex end
    local used, count = {}, 0
    for _, pc in pairs(playerColors) do
        used[pc.hex] = true
        count = count + 1
    end
    local hex = nil
    for _, cn in ipairs(AUTO_COLORS) do
        if not used[COLOR_NAMES[cn]] then
            hex = COLOR_NAMES[cn]
            break
        end
    end
    hex = hex or COLOR_NAMES[AUTO_COLORS[(count % #AUTO_COLORS) + 1]]
    playerColors[name] = { hex = hex, auto = true }
    saveOwners()
    return hex
end

local function hexRGB(hex)
    return tonumber(hex:sub(1, 2), 16) / 255, tonumber(hex:sub(3, 4), 16) / 255, tonumber(hex:sub(5, 6), 16) / 255
end

-- BWCoopClient (the official mod every player installs) ships BP_BWCoopState, an actor the game
-- spawns on the host and replicates to every player. Its arrays let each player's own game show
-- village areas (the same rule as villageAt):
--   Villages      = { name0, owner0, name1, owner1, ... }   (shown name with tag; "" = no owner)
--   AreaPoints    = { x, y, r, v, ... } in cm: a town hall with r = -(influence radius), each building
--                   with r = NEAR_BUILDING; v = the village's index into Villages (2 * n). Build-mode line.
--   AreaDots      = { x, y, z, n, ... }: the outline of each village's area (0.6.5), n = village number
--                   (0-based). Map and minimap dots.
--   VillageColors = { r, g, b, ... } per village (0..1): its owner's color, gray when unowned.
--   AreaRev       = bumped whenever the arrays change (clients redraw their dots).
-- Buildings are thinned to one per 10 m cell per village; at most MAX_POINTS points (the client
-- checks them five times a second in build mode only) and MAX_DOTS dots.
local function bridgeData()
    local names, pts, cols, discs, n = {}, {}, {}, {}, 0
    local function add(x, y, r, v)
        if n >= MAX_POINTS then return end
        n = n + 1
        pts[#pts + 1], pts[#pts + 2], pts[#pts + 3], pts[#pts + 4] = x, y, r, v
    end
    local list = playerVillages()
    for i, v in ipairs(list) do
        local o = owners[guidStr(v.PersistentGuid)]
        names[#names + 1] = rawVillageName(v) ~= "" and rawVillageName(v) or villageLabel(v)
        names[#names + 1] = o and o.owner or ""
        local cr, cg, cb = hexRGB(o and playerColor(o.owner) or UNOWNED_COLOR)
        cols[#cols + 1], cols[#cols + 2], cols[#cols + 3] = cr, cg, cb
        discs[i] = {}
        local tx, ty, r, tz = townHallArea(v)
        if tx then
            add(math.floor(tx), math.floor(ty), -math.floor(r), 2 * (i - 1))
            table.insert(discs[i], { tx, ty, r, tz or 0 })
        end
    end
    for i, v in ipairs(list) do
        local seen = {}
        for _, p in ipairs(buildingPositions(v)) do
            local cx, cy = math.floor(p[1] / BRIDGE_CELL), math.floor(p[2] / BRIDGE_CELL)
            local key = cx .. ":" .. cy
            if not seen[key] then
                seen[key] = true
                add(math.floor(p[1]), math.floor(p[2]), NEAR_BUILDING, 2 * (i - 1))
                table.insert(discs[i], { p[1], p[2], NEAR_BUILDING, p[3] or 0 })
            end
        end
    end
    local numOf = {}
    for i, v in ipairs(list) do numOf[guidStr(v.PersistentGuid)] = i - 1 end
    return names, pts, cols, discs, numOf
end

-- Outline of one village's area (the union of its town hall circle and the 100 m discs around its
-- buildings): points every ~12 m on each circle that no other circle of the village covers, one per
-- 10 m cell. Appends x, y, z, num to out.
local function outline(discs, out, num)
    local G = NEAR_BUILDING
    local grid, big = {}, {}
    for _, d in ipairs(discs) do
        if d[3] > G then
            big[#big + 1] = d
        else
            local k = math.floor(d[1] / G) .. ":" .. math.floor(d[2] / G)
            grid[k] = grid[k] or {}
            table.insert(grid[k], d)
        end
    end
    local function inside(d, x, y)
        local dx, dy = x - d[1], y - d[2]
        return dx * dx + dy * dy < (d[3] - 1) * (d[3] - 1)
    end
    local function covered(x, y, self)
        for _, d in ipairs(big) do
            if d ~= self and inside(d, x, y) then return true end
        end
        local cx, cy = math.floor(x / G), math.floor(y / G)
        for i = cx - 1, cx + 1 do
            for j = cy - 1, cy + 1 do
                for _, d in ipairs(grid[i .. ":" .. j] or {}) do
                    if d ~= self and inside(d, x, y) then return true end
                end
            end
        end
        return false
    end
    local seen = {}
    for _, d in ipairs(discs) do
        local steps = math.max(12, math.ceil(2 * math.pi * d[3] / DOT_STEP))
        for k = 0, steps - 1 do
            local ang = 2 * math.pi * k / steps
            local x, y = d[1] + d[3] * math.cos(ang), d[2] + d[3] * math.sin(ang)
            if not covered(x, y, d) then
                local key = math.floor(x / DOT_CELL) .. ":" .. math.floor(y / DOT_CELL)
                if not seen[key] then
                    seen[key] = true
                    out[#out + 1], out[#out + 2], out[#out + 3], out[#out + 4] =
                        math.floor(x), math.floor(y), math.floor(d[4]), num
                end
            end
        end
    end
end

local function thinDots(dots)
    local count = math.floor(#dots / 4)
    if count <= MAX_DOTS then return dots end
    local keep, step = {}, math.ceil(count / MAX_DOTS)
    for k = 0, count - 1, step do
        for j = 1, 4 do keep[#keep + 1] = dots[4 * k + j] end
    end
    return keep
end

-- Map dots: with land claims (0.7.0) the border squares of each village's land, else the outline of
-- each village's reach (0.6.5).
local function areaDots(discs, numOf)
    if claimsMod and claimsMod.ready() then return thinDots(claimsMod.edges(numOf)) end
    local dots = {}
    for i, ds in ipairs(discs) do outline(ds, dots, i - 1) end
    return thinDots(dots)
end

-- Call to arms (BWCoopClient 0.6+). G always opens the host's main village (game rule), so the
-- client mod overwrites a friend's G screen with their own village from:
--   CtaCounts = { guards, companions, dismiss, reservists, residents, ... }: 5 per village (Villages
--               order), counted like UMistSettlementCallToArmsScreen::SetData, over the residents
--               Mobilize calls up (AMistSettlement::MobilizeReservists uses the actor list)
--   CtaHome   = { player, n, ... }: the village (number as text) each player's Mobilize/Dismiss acts
--               on, the one REDIRECT picks (their nearest own village)
-- The reservist flag (UMistNpcData +0x69A, written by AMistTownNpc::SetIsGuardReservist) isn't a
-- reflected property; it is registered here so Lua can read it.
local ROLE_WORKER, ROLE_LEVY, ROLE_GUARD = 0, 1, 9
local reservistReady = type(RegisterCustomProperty) == "function" and type(PropertyTypes) == "table" and
    pcall(RegisterCustomProperty, { Name = "BWReservist", Type = PropertyTypes.ByteProperty,
        BelongsToClass = "/Script/Mist.MistNpcData", OffsetInternal = 0x69A })

local function ctaData(list)
    local counts, home, numOf = {}, {}, {}
    if not reservistReady then return counts, home end
    for i, v in ipairs(list) do
        numOf[guidStr(v.PersistentGuid)] = i - 1
        local g, c, d, r, n, arr = 0, 0, 0, 0, 0, nil
        pcall(function() arr = v.PopulationComponent.Residents; n = arrLen(arr) end)
        for k = 1, n do
            local npc = arrGet(arr, k)
            local flag, role = 0, -1
            pcall(function() flag = npc.NpcData.BWReservist end)
            pcall(function() role = npc:GetNpcRole() end)
            if flag ~= 0 then
                r = r + 1
                if role == ROLE_WORKER or role == ROLE_LEVY then g = g + 1 end
                if role == ROLE_WORKER or role == ROLE_GUARD then c = c + 1 end
                if role == ROLE_LEVY or role == ROLE_GUARD then d = d + 1 end
            end
        end
        for _, x in ipairs({ g, c, d, r, n }) do counts[#counts + 1] = x end
    end
    for _, pc in ipairs(FindAllOf("MistOasisPlayerController") or {}) do
        local info = playerInfo(pc)
        if info and info.name ~= "?" then
            local x, y = 0, 0
            pcall(function() local l = locationOf(pc.Pawn); x, y = l.X, l.Y end)
            local v = nearestOwnedVillage(info.name, x, y)
            if v then
                home[#home + 1] = info.name
                home[#home + 1] = tostring(numOf[guidStr(v.PersistentGuid)])
            end
        end
    end
    return counts, home
end

-- The game replicates with the push model (0.7.9): a variable written from Lua reaches friends only when marked
-- dirty, as a Blueprint "Set" node does. Returns an error text, or nil.
local function markDirty(a, props)
    local dirtyErr = nil
    pcall(function()
        local pm = StaticFindObject("/Script/Engine.Default__NetPushModelHelpers")
        if not valid(pm) then dirtyErr = "NetPushModelHelpers not found"; return end
        for _, prop in ipairs(props) do
            local ok, err = pcall(function() pm:MarkPropertyDirty(a, FName(prop)) end)
            if not ok and not dirtyErr then dirtyErr = prop .. ": " .. tostring(err) end
        end
    end)
    return dirtyErr
end

-- Villages panel data (BWCoopClient 0.7.5+, 2026-10-14): VPanel (per village "name@@info@@stock@@caravans" since 0.7.19 for client 0.7.7), VItems (item list per
-- village for the search), PanelRev, and BWDeliveries (1 when midnight deliveries are on, so friends' games show the
-- Deliveries tab). Stock changes all the time, so this goes out at most every 10 s and only when it changed; it has
-- its own revision so the map overlay doesn't redraw for it. Older client mods lack the variables: the writes fail
-- quietly.
local PANEL_EVERY = 10
local function publishPanel(a, addr)
    if not caravansMod then return end
    local now = os.time()
    if addr ~= bridge.panelActor then bridge.panelActor, bridge.panelSig, bridge.panelAt = addr, nil, 0 end
    if now - (bridge.panelAt or 0) < PANEL_EVERY then return end
    bridge.panelAt = now
    local list = playerVillages()
    local ok, panels, items = pcall(caravansMod.panelData, list)
    if not ok then
        if bridge.panelErr ~= tostring(panels) then log("panel error: " .. tostring(panels)) end
        bridge.panelErr = tostring(panels)
        return
    end
    -- 0.7.23: keep-stocked rules per village (VKeep) and the villages' GUIDs (VGuids) for the panel's rule form
    -- (BWCoopClient 0.7.9; older client mods lack the variables and these writes fail quietly)
    local okK, keeps = pcall(caravansMod.keepPanel, list)
    if not okK then keeps = {} end
    local guids = {}
    for i, v in ipairs(list) do guids[i] = guidStr(v.PersistentGuid) end
    local deliveries = balance.deliveries == 1 and 1 or 0
    local psig = table.concat(panels, "\1") .. "\2" .. table.concat(items, "\1") .. "\2" .. deliveries .. "\2" ..
        table.concat(keeps, "\1") .. "\2" .. table.concat(guids, "\1")
    if psig == bridge.panelSig then return end
    if pcall(function() a.VKeep = keeps; a.VGuids = guids end) then markDirty(a, { "VKeep", "VGuids" }) end
    local wrote = pcall(function()
        a.VPanel = panels
        a.VItems = items
        a.BWDeliveries = deliveries
        a.BWNewline = "\n" -- the panel's search joins its lines with it (pin defaults can't hold a newline)
        bridge.panelRev = (bridge.panelRev or 0) + 1
        a.PanelRev = bridge.panelRev
    end)
    if wrote then
        markDirty(a, { "VPanel", "VItems", "BWDeliveries", "BWNewline", "PanelRev" })
        bridge.panelErr = nil
    end
    bridge.panelSig = psig
end

local function publishBridge()
    local a = FindFirstOf("BP_BWCoopState_C")
    if not valid(a) then bridge.actor = nil; return end
    if not ensureLoaded() then return end
    if claimsMod then pcall(claimsMod.update) end
    local names, pts, cols, discs, numOf = bridgeData()
    local ctaCounts, ctaHome = ctaData(playerVillages())
    local sig = table.concat(names, "\1") .. "\2" .. table.concat(pts, ",") .. "\2" .. table.concat(cols, ",") ..
        "\2" .. (claimsMod and claimsMod.version or 0) .. "\2" .. table.concat(ctaCounts, ",") .. "\2" ..
        table.concat(ctaHome, "\1") ..
        -- 0.7.8: the land data goes out once the claims are ready (2026-10-13: a load with no claim changes left
        -- the first, pre-claims publish in place, so the map overlay and the build-mode line stayed empty)
        "\2" .. tostring(claimsMod ~= nil and claimsMod.ready())
    local addr = a:GetAddress()
    publishPanel(a, addr)
    if addr == bridge.actor and sig == bridge.sig then return end
    a.Villages = names
    a.AreaPoints = pts
    local okN, gotN = pcall(function() return a.Villages:GetArrayNum() end)
    local okP, gotP = pcall(function() return a.AreaPoints:GetArrayNum() end)
    if not okN or not okP or gotN ~= #names or gotP ~= #pts then
        bridge.err = string.format("bridge error: write check failed, villages %s/%d, points %s/%d",
            tostring(gotN), #names, tostring(gotP), #pts)
        if bridge.sig ~= "!" then log(bridge.err) end
        bridge.sig, bridge.actor = "!", addr
        return
    end
    -- map dots (BWCoopClient 0.4+; an older client mod has no such variables)
    local dots = areaDots(discs, numOf)
    -- build-mode line from the claims (BWCoopClient 0.5+: AreaRuns = row, first, last, 2 * n per run)
    if claimsMod and claimsMod.ready() then
        local runs = claimsMod.runs(numOf)
        if #runs > 4 * MAX_POINTS then
            local keep = {}
            for i = 1, 4 * MAX_POINTS do keep[i] = runs[i] end
            runs = keep
        end
        pcall(function() a.AreaRuns = runs end)
    end
    local okD, gotD = pcall(function()
        a.AreaDots = dots
        a.VillageColors = cols
        bridge.rev = bridge.rev + 1
        a.AreaRev = bridge.rev
        return a.AreaDots:GetArrayNum()
    end)
    if not okD or gotD ~= #dots then
        local msg = "bridge error: map dots not written (" .. tostring(gotD) .. "); BWCoopClient older than 0.4?"
        if msg ~= bridge.err then log(msg) end
        bridge.err = msg
    else
        bridge.err = nil
    end
    -- call to arms (BWCoopClient 0.6+; older client mods have no such variables)
    local okC, gotC = pcall(function()
        a.CtaCounts = ctaCounts
        a.CtaHome = ctaHome
        return a.CtaCounts:GetArrayNum()
    end)
    bridge.cta = (okC and gotC == #ctaCounts) and ctaCounts or nil
    -- 0.7.9: the game replicates with the push model (DefaultEngine.ini Net.IsPushModelEnabled=1), which makes
    -- Blueprint variables push-based: a change is sent only when the property is marked dirty, as a Blueprint "Set"
    -- node does. Writes from Lua don't mark it, so friends got the bridge data only when they joined (2026-10-13:
    -- a friend's map overlay still showed land from before the session's changes). Mark every written variable.
    local dirtyErr = markDirty(a, { "Villages", "AreaPoints", "AreaRuns", "AreaDots", "VillageColors", "AreaRev",
        "CtaCounts", "CtaHome" })
    if dirtyErr and dirtyErr ~= bridge.dirtyErr then log("bridge error: could not mark changes for friends: " .. dirtyErr) end
    bridge.dirtyErr = dirtyErr
    if bridge.actor ~= addr then log(string.format("BRIDGE found BP_BWCoopState (%d villages)", math.floor(#names / 2))) end
    bridge.actor, bridge.sig = addr, sig
    bridge.villages, bridge.points = math.floor(#names / 2), math.floor(#pts / 4)
    bridge.dots = (okD and gotD == #dots) and math.floor(#dots / 4) or 0
end

local function publishLogged()
    if mode == "off" then return end
    local ok, e = pcall(publishBridge)
    if not ok then
        local msg = "bridge error: " .. tostring(e)
        if msg ~= bridge.err then log(msg) end
        bridge.err = msg
    end
end

if type(LoopInGameThreadWithDelay) == "function" then
    pcall(LoopInGameThreadWithDelay, 5000, publishLogged)
end

-- 0.7.26: after a keep-stocked request the panel data goes out on the next tick instead of within 15 s
-- (2026-10-17: the host saw a new rule only after closing and reopening the village screen)
panelNow = function()
    bridge.panelAt = 0
    if type(ExecuteInGameThread) == "function" then pcall(ExecuteInGameThread, publishLogged) end
end

-- 0.7.9: after a call to arms (mobilize/dismiss, anyone's, redirected or not) publish every second for a few
-- seconds instead of waiting up to 5 s, so a friend's G screen gets the new numbers quickly (2026-10-13: a friend's
-- G screen sometimes still showed the old numbers). The game updates roles over the next moments, hence the burst.
local publishBurstUntil = 0
for _, fn in ipairs({ "ServerMobilizeReservists", "ServerDismissReservists" }) do
    pcall(function()
        RegisterHook("/Script/Mist.MistDataBrokerPlayerComponent:" .. fn, function() end, function()
            publishBurstUntil = os.time() + 4
        end)
    end)
end
if type(LoopInGameThreadWithDelay) == "function" then
    pcall(LoopInGameThreadWithDelay, 1000, function()
        if os.time() <= publishBurstUntil then publishLogged() end
    end)
end

local function status(say)
    say(string.format("BWCoop %s  mode=%s  cheats=%s  auto=%s  limit=%d  sleep=%s  native=%s  save=%s", VERSION, mode,
        cheatsOpen and "open" or "host", autoSetup and "on" or "off", villageLimit, sleepRule, nativeReady() and (BWNative_Version() ..
            ((type(BWNative_GameCallsReady) == "function" and BWNative_GameCallsReady()) and " (game calls ready)" or " (no game calls)") ..
            ((type(BWNative_RatesReady) == "function" and BWNative_RatesReady()) and " (rates ready)" or ""))
            or "missing", tostring(saveName)))
    for _, v in ipairs(playerVillages()) do
        local key = guidStr(v.PersistentGuid)
        local o = owners[key]
        local names = {}
        for name in pairs(trusted[key] or {}) do names[#names + 1] = name end
        table.sort(names)
        say(string.format("  %-20s %s  owner: %s%s", villageLabel(v), key:sub(1, 8), o and o.owner or "(none, open)",
            #names > 0 and ("  trusted: " .. table.concat(names, ", ")) or ""))
    end
    for _, pc in ipairs(FindAllOf("MistOasisPlayerController") or {}) do
        local info = playerInfo(pc)
        if info then say(string.format("  player %s%s", info.name, info.isHost and " (host)" or "")) end
    end
    say(bridge.err and ("  client mod bridge: " .. bridge.err)
        or bridge.actor and string.format("  client mod bridge: %d villages, %d area points, %d map dots", bridge.villages,
            bridge.points, bridge.dots)
        or "  client mod bridge: BP_BWCoopState not found (BWCoopClient 0.3+ not loaded on the host)")
    if not reservistReady then
        say("  call to arms data: off (the reservist flag could not be registered)")
    elseif bridge.actor and not bridge.cta then
        say("  call to arms data: not written (BWCoopClient older than 0.6?)")
    elseif bridge.cta then
        local parts = {}
        for i, v in ipairs(playerVillages()) do
            local b = 5 * (i - 1)
            if bridge.cta[b + 5] then
                parts[#parts + 1] = string.format("%s guards %d, companions %d, dismiss %d (reservists %d of %d)",
                    villageLabel(v), bridge.cta[b + 1], bridge.cta[b + 2], bridge.cta[b + 3], bridge.cta[b + 4],
                    bridge.cta[b + 5])
            end
        end
        say("  call to arms (G screen): " .. table.concat(parts, "; "))
    end
    if claimsMod and claimsMod.ready() then
        local c, parts = claimsMod.counts(), {}
        for _, v in ipairs(playerVillages()) do
            parts[#parts + 1] = string.format("%s %d", villageLabel(v), c[guidStr(v.PersistentGuid)] or 0)
        end
        say("  land claims (10 m squares): " .. table.concat(parts, ", "))
    end
end


----------------------------------------------------------------------------- per-player rates

-- XP, crafting speed and crafting cost are applied by BWCoopNative 0.3.0 inside that player's own
-- calls (rates.cpp); building cost is the game's global swapped around that player's own placement
-- requests below. Only the chosen player is affected, and nobody is told.
local function ratesFor(name)
    local r = playerRates[name]
    return r or { xp = 1, speed = 1, cost = 1, build = 1, read = 0 }
end

local function isDefault(r)
    return r.xp == 1 and r.speed == 1 and r.cost == 1 and r.build == 1 and (r.read or 0) == 0
end

local function applyRates()
    if type(BWNative_RatesReady) ~= "function" or not BWNative_RatesReady() then return end
    BWNative_ClearPlayerRates()
    for _, pc in ipairs(FindAllOf("MistOasisPlayerController") or {}) do
        local info = playerInfo(pc)
        local r = info and playerRates[info.name]
        if r and not isDefault(r) then
            pcall(function() BWNative_SetPlayerRates(pc.Pawn:GetAddress(), r.xp, r.speed, r.cost) end)
            -- Instant books (add-on 0.4.2): applied where the game adds the reading effect, at the end of the read.
            if (r.read or 0) == 1 and type(BWNative_SetPlayerInstantRead) == "function" then
                pcall(function() BWNative_SetPlayerInstantRead(pc.Pawn:GetAddress(), true) end)
            end
        end
    end
end

-- Night skip rule (BWCoopNative 0.4.0, sleep.cpp): how many players must be in bed. The host's pawn
-- is passed for the "host" rule.
local function applySleep()
    if type(BWNative_SleepReady) ~= "function" or not BWNative_SleepReady() then return end
    local host = 0
    pcall(function() host = hostController().Pawn:GetAddress() end)
    BWNative_SetSleepRule(sleepRule, host or 0)
end

if type(LoopInGameThreadWithDelay) == "function" then
    pcall(LoopInGameThreadWithDelay, 2000, function()
        local ok, e = pcall(applyRates)
        if not ok then log("rates error: " .. tostring(e)) end
        ok, e = pcall(applySleep)
        if not ok then log("sleep rule error: " .. tostring(e)) end
    end)
end

-- Free (or cheaper) building for one player: GBuildingCostMultiplier only while their placement runs.
local buildSaved = nil
for _, fn in ipairs({ "ServerPlace", "ServerPlaceNamed", "ServerPlacePlan", "ServerConfirmPlan", "ServerCreateSpline",
    "ServerExtendSpline", "ServerCloseSpline", "ServerCombineSplines" }) do
    pcall(function()
        RegisterHook("/Script/Mist.MistBuildingComponent:" .. fn, function(ctx)
            buildSaved = nil
            if type(BWNative_GetGlobal) ~= "function" then return end
            local req = requester(ctx)
            local r = req and playerRates[req.name]
            if r and r.build ~= 1 then
                local g = BWNative_GetGlobal("build_cost")
                if g and BWNative_SetGlobal("build_cost", g * r.build) then buildSaved = g end
            end
        end, function()
            if buildSaved then
                BWNative_SetGlobal("build_cost", buildSaved)
                buildSaved = nil
            end
        end)
    end)
end

-- Instant skill books for one player: while their own ServerReadBook runs, the add-on makes the
-- book's reading effect last 1 second (UMistKnowledgeItemStatusEffect::GetDuration).
pcall(function()
    RegisterHook("/Script/Mist.MistPlayer:ServerReadBook", function(ctx)
        if type(BWNative_SetInstantRead) ~= "function" then return end
        local req = requester(ctx)
        local r = req and playerRates[req.name]
        BWNative_SetInstantRead(r ~= nil and (r.read or 0) == 1)
    end, function()
        if type(BWNative_SetInstantRead) == "function" then BWNative_SetInstantRead(false) end
    end)
end)

-- One skill level up or down, for a player or for the villager the host is looking at
-- (AMistHuman::GetSkillLevel / SetSkill through the add-on; quiet).
local SKILL_IDS = { strength = 1, agility = 2, onehanded = 3, twohanded = 4, polearms = 5, shields = 6, archery = 7,
    harvesting = 8, farming = 9, animalhandling = 10, cooking = 11, crafting = 12, researching = 13, labourer = 14, laborer = 14 }

local function skillStep(target, skillName, delta, say)
    if type(BWNative_SetSkill) ~= "function" then return say("levels: needs BWCoopNative 0.3.1") end
    local id = SKILL_IDS[(skillName or ""):lower()]
    if not id then return say("levels: unknown skill " .. tostring(skillName)) end
    local addr, label = 0, target
    if target:lower() == "look" then
        pcall(function() addr = BWNative_LookAtActor(hostController().Pawn:GetAddress()) end)
        label = "the villager you're looking at"
    else
        for _, pc in ipairs(FindAllOf("MistOasisPlayerController") or {}) do
            local info = playerInfo(pc)
            if info and ((target:lower() == "me" and info.isHost) or info.name:lower():sub(1, #target) == target:lower()) then
                pcall(function() addr = pc.Pawn:GetAddress() end)
                label = info.name
            end
        end
    end
    if not addr or addr == 0 then return say("levels: nobody found for " .. target) end
    local cur = BWNative_GetSkill(addr, id)
    if not cur then return say("levels: that isn't a person") end
    local new = math.max(0, cur + delta)
    if BWNative_SetSkill(addr, id, new) then
        log(string.format("ADMIN level %s %s %d -> %d", label, skillName, cur, new))
        say(string.format("%s: %s %d -> %d", label, skillName, cur, new))
    else
        say("levels: could not set it")
    end
end

-- One "bwcoop ..." command (without the "bwcoop"), from the console or the admin window.
-- Newcomers (0.7.28, newcomers.lua, needs BWCoopNative 0.4.5): 2 recruitable villagers every 60 minutes of play at
-- random villages with a Village Hall and a free bed (2026-10-17).
do
    local okN, mk = pcall(dofile, modDir .. "\\Scripts\\newcomers.lua")
    if okN and type(mk) == "function" then
        local okM, m = pcall(mk, {
            log = log, valid = valid, guidStr = guidStr, arrLen = arrLen, arrGet = arrGet, className = className,
            villageLabel = villageLabel, playerVillages = playerVillages, buildingType = buildingType,
            locationOf = locationOf, hostController = hostController, ensureLoaded = ensureLoaded,
            requester = requester, skipCall = skipCall, tell = tell, findVillage = findVillage,
            modDir = modDir,
            newcomerList = function() return newcomers.list end,
            newcomersOff = function() return newcomers.off end,
            setNewcomersOff = function(off) newcomers.off = off; saveOwners() end,
            saveData = function() saveOwners() end,
            villageOwner = function(v)
                local o = owners[guidStr(v.PersistentGuid)]
                return o and o.owner or nil
            end,
            isTrusted = function(v, name)
                local t = trusted[guidStr(v.PersistentGuid)]
                return t ~= nil and t[name] == true
            end,
        })
        if okM and type(m) == "table" then
            newcomers.mod = m
            if type(LoopInGameThreadWithDelay) == "function" then
                pcall(LoopInGameThreadWithDelay, 60000, function()
                    local ok, e = pcall(m.tick)
                    if not ok then log("NEWCOMER error: " .. tostring(e)) end
                end)
            end
        else
            log("newcomers.lua setup failed: " .. tostring(m))
        end
    else
        log("could not load newcomers.lua: " .. tostring(mk))
    end
end

local function handleCommand(rest, say)
    local ok, err = pcall(function()
        ensureLoaded()
        if not saveName then say("BWCoop: load a save first"); return end
        local cmd, arg = rest:match("^(%S+)%s*(.*)$")
        cmd = cmd and cmd:lower() or ""
        if cmd == "" or cmd == "status" then
            claimUnowned()
            status(say)
        elseif cmd == "mode" then
            local m = trim(arg):lower()
            if m == "warn" or m == "enforce" or m == "dryrun" or m == "off" then
                mode = m
                saveOwners()
                say("BWCoop mode: " .. mode)
            else
                say("usage: bwcoop mode warn|enforce|dryrun|off")
            end
        elseif cmd == "assign" then
            local vq, who = arg:match("^(.-)%s*=%s*(.+)$")
            local v = vq and findVillage(trim(vq))
            if not v then say("usage: bwcoop assign <village name or GUID prefix> = <character name>"); return end
            local old = owners[guidStr(v.PersistentGuid)]
            owners[guidStr(v.PersistentGuid)] = { owner = trim(who), label = villageLabel(v), seq = old and old.seq or nextSeq() }
            trusted[guidStr(v.PersistentGuid)] = nil
            saveOwners()
            applyTags()
            say(string.format("%s now belongs to %s", villageLabel(v), trim(who)))
        elseif cmd == "unassign" then
            local v = findVillage(trim(arg))
            if not v then say("usage: bwcoop unassign <village name or GUID prefix>"); return end
            owners[guidStr(v.PersistentGuid)] = nil
            trusted[guidStr(v.PersistentGuid)] = nil
            warnedUnowned[guidStr(v.PersistentGuid)] = true
            saveOwners()
            applyTags()
            say(villageLabel(v) .. " is now open to everyone")
        elseif cmd == "trust" or cmd == "untrust" then
            -- trust <village> = <player>: that friend may change the village like its owner (squads stay
            -- with their owners). untrust takes it back. "trust" alone lists every village's list.
            local vq, who = arg:match("^(.-)%s*=%s*(.+)$")
            if cmd == "trust" and trim(arg) == "" then
                local any = false
                for _, v in ipairs(playerVillages()) do
                    local names = {}
                    for name in pairs(trusted[guidStr(v.PersistentGuid)] or {}) do names[#names + 1] = name end
                    table.sort(names)
                    if #names > 0 then
                        any = true
                        say(string.format("  %-20s trusts %s", villageLabel(v), table.concat(names, ", ")))
                    end
                end
                if not any then say("trust: no village trusts anyone") end
                return
            end
            local v = vq and findVillage(trim(vq))
            if not v then say("usage: bwcoop " .. cmd .. " <village name or GUID prefix> = <character name>"); return end
            local key = guidStr(v.PersistentGuid)
            if not owners[key] then say(villageLabel(v) .. " has no owner, so everyone may change it already"); return end
            who = trim(who)
            for _, pc in ipairs(FindAllOf("MistOasisPlayerController") or {}) do
                local info = playerInfo(pc)
                if info and info.name:lower() == who:lower() then who = info.name end
            end
            if cmd == "trust" then
                trusted[key] = trusted[key] or {}
                trusted[key][who] = true
            elseif trusted[key] then
                trusted[key][who] = nil
                if next(trusted[key]) == nil then trusted[key] = nil end
            end
            saveOwners()
            log(string.format("TRUST %s %s %s", villageLabel(v), cmd == "trust" and "+" or "-", who))
            say(string.format("%s %s %s", villageLabel(v), cmd == "trust" and "now trusts" or "no longer trusts", who))
        elseif cmd == "sleep" then
            local r = trim(arg):lower()
            if SLEEP_RULES[r] then
                sleepRule = r
                saveOwners()
                applySleep()
                local ready = type(BWNative_SleepReady) == "function" and BWNative_SleepReady()
                say("BWCoop night skip: " .. ({ all = "every player in bed (the game's rule)", half = "half of the players in bed",
                    one = "any one player in bed", host = "the host in bed is enough" })[r] ..
                    (ready and "" or "  (needs BWCoopNative 0.4.0; not active)"))
            else
                say("usage: bwcoop sleep all|half|one|host")
            end
        elseif cmd == "color" or cmd == "colors" then
            local who, c = arg:match("^(.-)%s*=%s*(.-)%s*$")
            local usage = "usage: bwcoop color <character name> = red|blue|green|purple|orange|cyan|pink|brown|" ..
                "yellow|white|black|gray|#RRGGBB|auto"
            if not who or trim(who) == "" then
                local list = {}
                for name, pc in pairs(playerColors) do
                    list[#list + 1] = string.format("%s #%s%s", name, pc.hex, pc.auto and " (auto)" or "")
                end
                table.sort(list)
                say(#list > 0 and ("BWCoop map area colors: " .. table.concat(list, ", "))
                    or "BWCoop map area colors: none picked yet")
                return say(usage)
            end
            who = trim(who)
            for _, o in pairs(owners) do
                if o.owner:lower() == who:lower() then who = o.owner end
            end
            if trim(c):lower() == "auto" then
                playerColors[who] = nil
                playerColor(who)
            else
                local hex = colorHex(c)
                if not hex then return say("color: unknown color \"" .. c .. "\"; " .. usage) end
                playerColors[who] = { hex = hex, auto = false }
                saveOwners()
            end
            log(string.format("ADMIN color %s #%s", who, playerColors[who].hex))
            say(string.format("BWCoop map area color for %s: #%s%s (shows within 5 seconds)", who, playerColors[who].hex,
                playerColors[who].auto and " (auto)" or ""))
        elseif cmd == "tags" then
            local t = trim(arg):lower()
            if t == "on" or t == "off" then
                tagsOn = t == "on"
                saveOwners()
                applyTags()
                say("BWCoop owner tags in village names: " .. t)
            else
                say("usage: bwcoop tags on|off")
            end
        elseif cmd == "cheats" then
            local c = trim(arg):lower()
            if c == "host" or c == "open" then
                cheatsOpen = c == "open"
                saveOwners()
                say("BWCoop cheats: " .. (cheatsOpen and "open to everyone" or "host only"))
            else
                say("usage: bwcoop cheats host|open")
            end
        elseif cmd == "squads" then
            if not squadsMod then
                say("squads: not loaded (see BWCoop.log)")
            elseif trim(arg):lower() == "split" then
                squadsMod.split(say)
            else
                squadsMod.report(say)
            end
        elseif cmd == "people" then
            people(say, arg)
        elseif cmd == "setup" then
            setup(say)
        elseif cmd == "rates" then
            -- rates                                   list
            -- rates <player name> xp=1.5 speed=10 cost=0 build=0   (any subset; 1 = normal)
            local name = trim((arg:gsub("%s*%w+=%S+", "")))
            if name == "" then
                local any = false
                for n, r in pairs(playerRates) do
                    any = true
                    say(string.format("  %-24s xp x%g  craft speed x%g  craft cost x%g  build cost x%g  instant books %s", n, r.xp, r.speed, r.cost, r.build, (r.read or 0) == 1 and "on" or "off"))
                end
                if not any then say("rates: everyone normal") end
                if type(BWNative_RatesReady) ~= "function" or not BWNative_RatesReady() then
                    say("rates: the add-on's rate hooks are off (needs BWCoopNative 0.3.0); XP/craft rates won't apply")
                end
                return
            end
            local who = nil
            for _, pc in ipairs(FindAllOf("MistOasisPlayerController") or {}) do
                local info = playerInfo(pc)
                if info and (info.name:lower() == name:lower() or (name:lower() == "me" and info.isHost)) then who = info.name end
            end
            who = who or name
            local r = ratesFor(who)
            r = { xp = r.xp, speed = r.speed, cost = r.cost, build = r.build, read = r.read or 0 }
            for k, v in arg:gmatch("(%w+)=(%S+)") do
                local n = tonumber(v)
                if n and r[k:lower()] ~= nil then r[k:lower()] = math.max(0, n) end
            end
            if r.speed <= 0 then r.speed = 0.01 end
            r.read = (r.read and r.read > 0) and 1 or 0
            playerRates[who] = (not isDefault(r)) and r or nil
            saveOwners()
            applyRates()
            log(string.format("RATES %s: xp x%g, craft speed x%g, craft cost x%g, build cost x%g, instant books %s", who, r.xp, r.speed, r.cost, r.build, r.read == 1 and "on" or "off"))
            say(string.format("rates for %s: xp x%g, craft speed x%g, craft cost x%g, build cost x%g, instant books %s", who, r.xp, r.speed, r.cost, r.build, r.read == 1 and "on" or "off"))
        elseif cmd == "levelup" or cmd == "leveldown" then
            -- levelup <player|me|look> <skill>     one level up (leveldown: one down)
            local t, sk = arg:match("^(%S+)%s+(%S+)")
            if not t then return say("usage: bwcoop " .. cmd .. " <player|me|look> <skill>") end
            skillStep(t, sk, cmd == "levelup" and 1 or -1, say)
        elseif cmd == "limit" then
            local n = tonumber(trim(arg))
            if n and n >= 0 then
                villageLimit = math.floor(n)
                saveOwners()
                say("BWCoop villages per friend: " .. villageLimit .. " (the host can still assign more)")
            else
                say("usage: bwcoop limit <villages per friend>")
            end
        elseif cmd == "auto" then
            local c = trim(arg):lower()
            if c == "on" or c == "off" then
                autoSetup = c == "on"
                saveOwners()
                say("BWCoop auto setup after load: " .. c)
            else
                say("usage: bwcoop auto on|off")
            end
        elseif cmd == "where" then
            -- Diagnose village areas from where the host is standing.
            local pawn = nil
            pcall(function() pawn = hostController().Pawn end)
            local l = valid(pawn) and locationOf(pawn)
            if not l then say("where: no host position"); return end
            say(string.format("you are at %.0f, %.0f -> village: %s", l.X, l.Y,
                (function() local v = villageAt(l.X, l.Y, l.Z); return v and villageLabel(v) or "none" end)()))
            if claimsMod and pcall(claimsMod.update) and claimsMod.ready() then
                local lv = claimsMod.ownerAt(l.X, l.Y)
                say("  land claim: " .. (lv and villageLabel(lv) or "free land"))
            end
            local g = gameVillageAt(l.X, l.Y, l.Z)
            say("  game's answer: " .. (g == nil and "unavailable (add-on game calls off)" or g == false and "new outpost"
                or villageLabel(g)))
            for _, v in ipairs(playerVillages()) do
                local tx, ty, r = townHallArea(v)
                local th = tx and string.format("town hall %.0f m away, radius %.0f m",
                    math.sqrt((l.X - tx) ^ 2 + (l.Y - ty) ^ 2) / 100, r / 100) or "town hall unreadable"
                local d2 = nearestBuilding2(v, l.X, l.Y)
                say(string.format("  %-12s %s; nearest of %d buildings %s", villageLabel(v), th,
                    #buildingPositions(v), d2 and string.format("%.0f m", math.sqrt(d2) / 100) or "n/a"))
            end
        elseif cmd == "balance" or cmd == "deliveries" then
            if not balanceMod then say(cmd .. ": balance.lua isn't loaded (see BWCoop.log)"); return end
            if cmd == "balance" then balanceMod.command(say, trim(arg)) else balanceMod.deliveries(say, trim(arg)) end
        elseif cmd == "newcomers" then
            if not newcomers.mod then say("newcomers: newcomers.lua isn't loaded (see BWCoop.log)"); return end
            newcomers.mod.command(say, trim(arg))
        elseif cmd == "stock" or cmd == "caravans" or cmd == "keep" then
            if not caravansMod then say(cmd .. ": caravans.lua isn't loaded (see BWCoop.log)"); return end
            caravansMod[cmd](say, trim(arg))
        elseif cmd == "move" then
            -- 0.7.9: the player building nearest the host (within 15 m) moves to a village and stays there.
            local v = findVillage(trim(arg))
            if not v then say("usage: bwcoop move <village name or GUID prefix> (moves the building nearest you, within 15 m)"); return end
            local here = locationOf(hostController().Pawn)
            if not here then say("move: can't find where you are"); return end
            local best, bestD2, bestV = nil, 1500 * 1500, nil
            for _, pv in ipairs(playerVillages()) do
                pcall(function()
                    local st = pv.Data.Structures
                    for i = 1, arrLen(st) do
                        pcall(function()
                            local a = arrGet(st, i).PlaceableActor
                            local l = locationOf(a)
                            local d2 = l and (l.X - here.X) ^ 2 + (l.Y - here.Y) ^ 2
                            if d2 and d2 < bestD2 then best, bestD2, bestV = a, d2, pv end
                        end)
                    end
                end)
            end
            if not best then say("move: no village building within 15 m of you"); return end
            if sameGuid(bestV.PersistentGuid, v.PersistentGuid) then
                say(string.format("move: the %s is already in %s", className(best), villageLabel(v)))
                return
            end
            local db = nil
            pcall(function() db = hostController().DataBrokerComponent end)
            local ok, err = moveTo(db, best, v)
            if ok then
                keepAs(best, v)
                keepGaveUp[guidStr(best.PersistentGuid)] = nil
            end
            log(string.format("MOVE %s %.0f m from the host: %s -> %s%s", className(best), math.sqrt(bestD2) / 100,
                villageLabel(bestV), villageLabel(v), ok and "" or (" FAILED: " .. tostring(err))))
            say(ok and string.format("Moved the %s from %s to %s", className(best), villageLabel(bestV), villageLabel(v))
                or ("move failed: " .. tostring(err)))
        elseif cmd == "founding" then
            -- Founding order for claim priority (after the host's villages). With names, sets it:
            -- the listed villages first in that order, the others after them as before.
            local list = trim(arg)
            if list ~= "" then
                local given, seen = {}, {}
                for part in list:gmatch("[^,]+") do
                    local v = findVillage(trim(part))
                    if not v then return say("founding: no village \"" .. trim(part) .. "\"") end
                    if not owners[guidStr(v.PersistentGuid)] then
                        return say("founding: " .. villageLabel(v) .. " has no owner yet (bwcoop assign first)")
                    end
                    given[#given + 1] = v
                    seen[guidStr(v.PersistentGuid)] = true
                end
                local order = {}
                for _, v in ipairs(given) do order[#order + 1] = v end
                for _, v in ipairs(claimPriority(playerVillages())) do
                    local k = guidStr(v.PersistentGuid)
                    if owners[k] and not seen[k] then order[#order + 1] = v end
                end
                for i, v in ipairs(order) do owners[guidStr(v.PersistentGuid)].seq = i end
                saveOwners()
                log("ADMIN founding " .. list)
            end
            say("BWCoop claim priority (host's villages first, then founding order):")
            for i, v in ipairs(claimPriority(playerVillages())) do
                local o = owners[guidStr(v.PersistentGuid)]
                say(string.format("  %d. %s (%s)", i, villageLabel(v), o and o.owner or "no owner"))
            end
        elseif cmd == "buildings" or cmd == "range" then
            -- range <type, group or tier> = <meters|default>: set; then (or with no arguments) list the
            -- building types standing in player villages with their claim range. Tiers (0.7.7): large, medium,
            -- camps, defenses, small.
            local what, val = arg:match("^(.-)%s*=%s*(.-)%s*$")
            if cmd == "range" and what and trim(what) ~= "" then
                local k = trim(what):lower()
                local v = trim(val):lower()
                if v == "default" or v == "auto" then
                    claimRanges[k] = nil
                else
                    local m = tonumber((v:gsub("%s*m$", "")))
                    if not m or m < -1 or m > 500 then
                        return say("usage: bwcoop range <type, group or tier> = <meters 0-500, -1 = no land|default>")
                    end
                    claimRanges[k] = m < 0 and -1 or math.floor(m * 100)
                end
                saveOwners()
                if claimsMod then claimsMod.invalidate() end
                log(string.format("ADMIN range %s = %s", k, v))
                say(string.format("claim range for %s: %s (applies within 5 seconds)", k,
                    claimRanges[k] and string.format("%.0f m", claimRanges[k] / 100) or "default"))
            elseif cmd == "range" and trim(arg) ~= "" then
                return say("usage: bwcoop range <type, group or tier> = <meters 0-500|default>   (bwcoop range alone lists them)")
            end
            local rows, order = {}, {}
            for _, v in ipairs(playerVillages()) do
                pcall(function()
                    local st = v.Data.Structures
                    for i = 1, arrLen(st) do
                        pcall(function()
                            local a = arrGet(st, i).PlaceableActor
                            local t = buildingType(a)
                            local key = t.group .. "/" .. t.name
                            if not rows[key] then
                                local r, why = claimRangeOf(a)
                                rows[key] = { t = t, n = 0, r = r, why = why }
                                order[#order + 1] = key
                                log(string.format("BUILDING type %s group %s range %.0f m (%s) class %s template %s", t.name,
                                    t.group, r / 100, why, t.cls, t.tpl))
                            end
                            rows[key].n = rows[key].n + 1
                        end)
                    end
                end)
            end
            table.sort(order)
            say("building types in player villages (group/type: count, claim range):")
            for _, key in ipairs(order) do
                local r = rows[key]
                say(string.format("  %-36s %3d  %s", key, r.n, r.r < 0 and "no land (neutral)" or r.r == 0 and "own square"
                    or string.format("%.0f m (%s)", r.r / 100, r.why)))
            end
            say("set one: bwcoop range <type, group or tier> = <meters|default>  (0 = own square only, -1 = no land; tiers: large 100, medium 50, camps 40, defenses 25, small 0)")
        elseif cmd == "claims" then
            if not claimsMod then return say("claims: claims.lua not loaded (see BWCoop.log)") end
            if trim(arg):lower() == "reset" then
                claimsMod.reset()
                log("ADMIN claims reset")
                say("claims: forgot the saved claims and claimed today's land again (host's villages first, then founding order)")
            else
                pcall(claimsMod.update)
            end
            local c = claimsMod.counts()
            for _, v in ipairs(claimPriority(playerVillages())) do
                local o = owners[guidStr(v.PersistentGuid)]
                say(string.format("  %-14s %-16s %5d squares (%.2f km2)", villageLabel(v), o and o.owner or "(none)",
                    c[guidStr(v.PersistentGuid)] or 0, (c[guidStr(v.PersistentGuid)] or 0) / 10000))
            end
            say("  (priority order; \"bwcoop claims reset\" claims today's land again from scratch)")
        elseif cmd == "overlaps" and claimsMod and pcall(claimsMod.update) and claimsMod.ready() then
            -- With land claims: buildings standing on another village's land (details in BWCoop.log).
            local list, byPair = claimsMod.misplaced(className), {}
            log("OVERLAPS check (land claims)")
            for _, m in ipairs(list) do
                local k = villageLabel(m.v) .. " on " .. villageLabel(m.land)
                byPair[k] = (byPair[k] or 0) + 1
                log(string.format("OVERLAP %s %s at %.0f, %.0f stands on %s land", villageLabel(m.v), m.cls, m.x, m.y,
                    villageLabel(m.land)))
            end
            if #list == 0 then
                say("overlaps: no building stands on another village's land")
            else
                for k, n in pairs(byPair) do say(string.format("overlaps: %d buildings of %s's land", n, k)) end
                say("overlaps: each one is in BWCoop.log (OVERLAP lines); they keep working, their owners can't build more there")
            end
        elseif cmd == "overlay" and trim(arg) ~= "" then
            -- Overlay tests on the host's own screen (BWCoopClient 0.7). "fill": paint the whole land texture
            -- red (tests the material and texture without the drawing code). "block": replace the land data
            -- with one 500 m x 200 m block starting 100 m east of you, in the host village's color (tests the
            -- drawing and its position). "reset": send the real land data again.
            local s = FindFirstOf("BP_BWCoopState_C")
            if not valid(s) then say("overlay: BP_BWCoopState not found"); return true end
            local what = trim(arg):lower()
            if what == "fill" then
                local ok, e = pcall(function()
                    local lib = StaticFindObject("/Script/Engine.Default__KismetRenderingLibrary")
                    local rt = StaticFindObject("/Game/Mods/BWCoopClient/RT_BWCoopClaims.RT_BWCoopClaims")
                    lib:ClearRenderTarget2D(s, rt, { R = 0.8, G = 0.1, B = 0.1, A = 1.0 })
                end)
                say(ok and "overlay fill: land texture painted red; open the map (bwcoop overlay reset to undo)"
                    or ("overlay fill failed: " .. tostring(e)))
            elseif what == "block" then
                local ok, e = pcall(function()
                    local l = locationOf(hostController().Pawn)
                    local cx, cy = math.floor(l.X / 1000) + 10, math.floor(l.Y / 1000)
                    local runs = {}
                    for row = cy, cy + 19 do
                        for _, v in ipairs({ row, cx, cx + 49, 0 }) do runs[#runs + 1] = v end
                    end
                    s.AreaRuns = runs
                    s.AreaRev = s.AreaRev + 1000
                    say(string.format("overlay block: squares x %d..%d, y %d..%d (you at %.0f, %.0f); open the map",
                        cx, cx + 49, cy, cy + 19, l.X, l.Y))
                end)
                if not ok then say("overlay block failed: " .. tostring(e)) end
            elseif what == "quad" then
                -- One quarter of the map: world X < 0 and Y < 0 (256 x 257 squares), in the host village's color.
                -- Tells whether the drawing works at all and which way the map is turned.
                local ok, e = pcall(function()
                    local runs = {}
                    for row = -257, -1 do
                        for _, v in ipairs({ row, -256, -1, 0 }) do runs[#runs + 1] = v end
                    end
                    s.AreaRuns = runs
                    s.AreaRev = s.AreaRev + 1000
                    say("overlay quad: painted the quarter of the map with world X < 0 and Y < 0; open the map zoomed out")
                end)
                if not ok then say("overlay quad failed: " .. tostring(e)) end
            elseif what == "read" then
                -- Read the land texture's pixels: an 8 x 8 grid plus the pixel under you (by the mapping the
                -- Blueprint measured). Shows whether the Blueprint's drawing reaches the texture at all.
                local ok, e = pcall(function()
                    local lib = StaticFindObject("/Script/Engine.Default__KismetRenderingLibrary")
                    local rt = StaticFindObject("/Game/Mods/BWCoopClient/RT_BWCoopClaims.RT_BWCoopClaims")
                    local function px(x, y)
                        local c = lib:ReadRenderTargetPixel(s, rt, x, y)
                        return string.format("%d,%d,%d,%d", c.R, c.G, c.B, c.A)
                    end
                    local lit, rows = 0, {}
                    for j = 0, 7 do
                        local line = {}
                        for i = 0, 7 do
                            local v = px(64 + 128 * i, 64 + 128 * j)
                            if v ~= "0,0,0,0" then lit = lit + 1 end
                            line[#line + 1] = (v == "0,0,0,0") and "." or "#"
                        end
                        rows[#rows + 1] = table.concat(line)
                    end
                    say("overlay read: grid of 64 pixels, # = painted: " .. lit)
                    for _, r in ipairs(rows) do say("    " .. r) end
                    local l = locationOf(hostController().Pawn)
                    local u = s.BWU0 + s.BWUX * l.X + s.BWUY * l.Y
                    local v = s.BWV0 + s.BWVX * l.X + s.BWVY * l.Y
                    local x, y = math.floor(u * 1024), math.floor(v * 1024)
                    say(string.format("  you: u %.4f v %.4f -> pixel %d,%d = %s; size %s x %s", u, v, x, y,
                        (x >= 0 and x < 1024 and y >= 0 and y < 1024) and px(x, y) or "outside",
                        tostring(rt.SizeX), tostring(rt.SizeY)))
                    say(string.format("  BWClaimsRev=%s AreaRev=%s AreaRuns=%s", tostring(s.BWClaimsRev),
                        tostring(s.AreaRev), tostring(s.AreaRuns:GetArrayNum())))
                end)
                if not ok then say("overlay read failed: " .. tostring(e)) end
            elseif what == "export" then
                -- Save the land texture as a picture (BWCoop data folder, bwcoop_overlay.png) plus the land data
                -- the Blueprint drew from (bwcoop_overlay.txt), to compare square by square.
                local ok, e = pcall(function()
                    local lib = StaticFindObject("/Script/Engine.Default__KismetRenderingLibrary")
                    local rt = StaticFindObject("/Game/Mods/BWCoopClient/RT_BWCoopClaims.RT_BWCoopClaims")
                    local dir = dataDir
                    lib:ExportRenderTarget(s, rt, dir, "bwcoop_overlay.png")
                    local f = io.open(dir .. "bwcoop_overlay.txt", "w")
                    local function arr(name)
                        local out, a = {}, s[name]
                        for i = 1, a:GetArrayNum() do out[#out + 1] = tostring(a[i]) end
                        return table.concat(out, ",")
                    end
                    for _, n in ipairs({ "BWU0", "BWV0", "BWUX", "BWVX", "BWUY", "BWVY", "BWClaimsRev", "AreaRev" }) do
                        f:write(n, "=", tostring(s[n]), "\n")
                    end
                    f:write("AreaRuns=", arr("AreaRuns"), "\n", "VillageColors=", arr("VillageColors"), "\n")
                    f:close()
                    say("overlay export: wrote " .. dir .. "bwcoop_overlay.png and .txt")
                end)
                if not ok then say("overlay export failed: " .. tostring(e)) end
            elseif what == "reset" then
                bridge.sig = nil
                pcall(publishBridge)
                say("overlay reset: real land data sent again")
            else
                say("overlay: use fill, block, quad, read, export or reset")
            end
        elseif cmd == "overlay" then
            -- Map overlay check (BWCoopClient 0.7): which material the map uses, and the land-drawing values
            -- BP_BWCoopState keeps (mapping, last drawn AreaRev). Read-only.
            local function nameOf(o)
                local ok, n = pcall(function() return o:GetFullName() end)
                return (ok and n) or "none"
            end
            local bgs = FindAllOf("MapBackground") or {}
            say(string.format("  map backgrounds: %d", #bgs))
            for i, bg in ipairs(bgs) do
                local m, h = nil, nil
                pcall(function() m = bg.BackgroundMaterial_UMG end)
                pcall(function() h = bg.BackgroundMaterial_UMG_HUD end)
                say(string.format("  [%d] %s", i, nameOf(bg)))
                say("      UMG material: " .. nameOf(m))
                say("      HUD material: " .. nameOf(h))
            end
            local widgets = {}
            for _, cls in ipairs({ "MistMapBackgroundWidget", "MapBackgroundWidget_C" }) do
                for _, w in ipairs(FindAllOf(cls) or {}) do widgets[#widgets + 1] = w end
            end
            say(string.format("  map background widgets: %d", #widgets))
            for _, w in ipairs(widgets) do
                local mi, parent, bg = nil, nil, nil
                pcall(function() mi = w.BackgroundMatInst end)
                pcall(function() parent = mi.Parent end)
                pcall(function() bg = w.MapBackground end)
                say("  widget " .. nameOf(w):sub(-70) .. "\n      material " .. nameOf(parent) .. "\n      background " ..
                    nameOf(bg):sub(-60))
            end
            local s = FindFirstOf("BP_BWCoopState_C")
            if not valid(s) then say("  BP_BWCoopState not found") else
                local parts = {}
                for _, n in ipairs({ "BWU0", "BWV0", "BWUX", "BWVX", "BWUY", "BWVY", "BWClaimsRev", "AreaRev" }) do
                    local ok, v = pcall(function() return s[n] end)
                    parts[#parts + 1] = n .. "=" .. ((ok and v ~= nil) and tostring(v) or "?")
                end
                local okR, runs = pcall(function() return s.AreaRuns:GetArrayNum() end)
                parts[#parts + 1] = "AreaRuns=" .. (okR and tostring(runs) or "?")
                say("  state: " .. table.concat(parts, " "))
            end
        elseif cmd == "overlaps" then
            -- Buildings standing inside another village's area by the guard's rule (villageAt), the
            -- building itself left out: inside another village's town hall circle (checked in village
            -- order, first match), else the closest other building within 100 m belongs to another
            -- village. Summary here, every building in BWCoop.log.
            local list = playerVillages()
            local info = {}
            for i, v in ipairs(list) do
                local tx, ty, r = townHallArea(v)
                local o = owners[guidStr(v.PersistentGuid)]
                info[i] = { label = villageLabel(v), owner = o and o.owner or "(none)", tx = tx, ty = ty, r = r,
                    b = buildingPositions(v) }
                say(string.format("  %-14s owner %-16s %s, %d buildings", info[i].label, info[i].owner,
                    tx and string.format("town hall radius %.0f m", r / 100) or "no town hall read", #info[i].b))
            end
            local host = hostName()
            local pairsSeen, total = {}, 0
            log("OVERLAPS check")
            for i, v in ipairs(list) do
                local A = info[i]
                pcall(function()
                    local structures = v.Data.Structures
                    for k = 1, arrLen(structures) do
                        pcall(function()
                            local sd = arrGet(structures, k)
                            local act = sd.PlaceableActor
                            local l = act:K2_GetActorLocation()
                            local hit, why = nil, nil
                            for j, B in ipairs(info) do
                                if B.tx then
                                    local dx, dy = l.X - B.tx, l.Y - B.ty
                                    if dx * dx + dy * dy <= B.r * B.r then
                                        if j ~= i then
                                            hit = j
                                            why = string.format("in its town hall circle, %.0f m from the hall",
                                                math.sqrt(dx * dx + dy * dy) / 100)
                                        end
                                        break
                                    end
                                end
                            end
                            if not hit then
                                local inOwnHall = A.tx and ((l.X - A.tx) ^ 2 + (l.Y - A.ty) ^ 2 <= A.r * A.r)
                                if not inOwnHall then
                                    local best, bestD2 = nil, NEAR_BUILDING * NEAR_BUILDING
                                    for j, B in ipairs(info) do
                                        for _, p in ipairs(B.b) do
                                            local dx, dy = l.X - p[1], l.Y - p[2]
                                            local d2 = dx * dx + dy * dy
                                            if d2 > 1 and d2 <= bestD2 then best, bestD2 = j, d2 end
                                        end
                                    end
                                    if best and best ~= i then
                                        hit = best
                                        why = string.format("%.0f m from its nearest building", math.sqrt(bestD2) / 100)
                                    end
                                end
                            end
                            if hit then
                                total = total + 1
                                local key = i .. ">" .. hit
                                pairsSeen[key] = (pairsSeen[key] or 0) + 1
                                log(string.format("OVERLAP %s (%s) %s at %.0f, %.0f is inside %s (%s): %s", A.label, A.owner,
                                    className(act), l.X, l.Y, info[hit].label, info[hit].owner, why))
                            end
                        end)
                    end
                end)
            end
            if total == 0 then
                say("overlaps: no building stands inside another village's area")
            else
                for key, n in pairs(pairsSeen) do
                    local i, j = key:match("^(%d+)>(%d+)$")
                    local A, B = info[tonumber(i)], info[tonumber(j)]
                    say(string.format("overlaps: %d of %s's buildings (%s) inside %s (%s)%s", n, A.label, A.owner, B.label,
                        B.owner, A.owner == host and "  [host: allowed]" or ""))
                end
                say("overlaps: each building, with the reason, is in BWCoop.log (OVERLAP lines)")
            end
        elseif admin[cmd] and cmd:sub(1, 1) ~= "_" then
            local words = {}
            for w in arg:gmatch("%S+") do words[#words + 1] = w end
            admin[cmd](words, say)
        else
            say("village: bwcoop | assign <village> = <player> | unassign <village> | trust [<village> = <player>] | untrust <village> = <player> | sleep all|half|one|host | mode warn|enforce|dryrun|off | tags on|off | cheats host|open | squads [split] | people [fix|<village>] | setup | auto on|off | limit <n> | rates [<player> xp= speed= cost= build= read=] | levelup/leveldown <player|me|look> <skill> | color [<player> = <color>] | where | overlaps | claims [reset] | founding [<village>, <village>, ...] | buildings | range [<type, group or tier> = <m|default>] | move <village> | stock [village] [n] | caravans [village] | keep [<village> <item> <n> from <village> [keeping <n>] | remove <village> <item>] | balance [<setting> <value>|default] | deliveries on|off")
            if admin._help then say("admin: " .. admin._help) end
        end
    end)
    if not ok then say("BWCoop error: " .. tostring(err)) end
end

RegisterConsoleCommandGlobalHandler("bwcoop", function(fullCommand, parameters, ar)
    local function say(s)
        log(s)
        pcall(function() ar:Log(s) end)
    end
    handleCommand(trim(fullCommand:gsub("^%s*[Bb][Ww][Cc][Oo][Oo][Pp]", "")), say)
    return true
end)

----------------------------------------------------------------------------- admin window

-- The "BWCoop" tab in the UE4SS window (Ctrl+O, host only; BWCoopNative 0.3.0). The window is a
-- remote control: it queues commands that run here like console commands, and shows a snapshot of
-- the state below. Nothing it does is announced to players.
local guiOn = type(BWNative_GuiSetState) == "function"

local function guiState()
    local lines = {
        "VER\t" .. VERSION .. "\t" .. tostring(saveName),
        "SET\tmode\t" .. mode,
        "SET\ttags\t" .. (tagsOn and "on" or "off"),
        "SET\tcheats\t" .. (cheatsOpen and "open" or "host"),
        "SET\tauto\t" .. (autoSetup and "on" or "off"),
        "SET\tlimit\t" .. villageLimit,
        "SET\tsleep\t" .. sleepRule,
    }
    for _, pc in ipairs(FindAllOf("MistOasisPlayerController") or {}) do
        local info = playerInfo(pc)
        if info then
            local r = playerRates[info.name] or {}
            local mine = {}
            for _, v in ipairs(playerVillages()) do
                local o = owners[guidStr(v.PersistentGuid)]
                if o and o.owner == info.name then mine[#mine + 1] = villageLabel(v) end
            end
            lines[#lines + 1] = string.format("PLR\t%s\t%d\t%s\t%g\t%g\t%g\t%g\t%d", info.name, info.isHost and 1 or 0,
                table.concat(mine, ", "), r.xp or 1, r.speed or 1, r.cost or 1, r.build or 1, r.read or 0)
        end
    end
    for _, v in ipairs(playerVillages()) do
        local key = guidStr(v.PersistentGuid)
        local o = owners[key]
        local names = {}
        for name in pairs(trusted[key] or {}) do names[#names + 1] = name end
        table.sort(names)
        lines[#lines + 1] = string.format("VIL\t%s\t%s\t%s", villageLabel(v), o and o.owner or "", key:sub(1, 8)) ..
            (#names > 0 and ("\t" .. table.concat(names, "\t")) or "")
    end
    return table.concat(lines, "\n")
end

if guiOn and type(LoopInGameThreadWithDelay) == "function" then
    local ticks = 0
    pcall(LoopInGameThreadWithDelay, 250, function()
        local ok, e = pcall(function()
            local ran = false
            for _ = 1, 5 do
                local cmd = BWNative_GuiTakeCommand()
                if not cmd then break end
                ran = true
                log("GUI " .. cmd)
                BWNative_GuiLog("> " .. cmd)
                handleCommand(cmd, function(s)
                    log(s)
                    BWNative_GuiLog(s)
                end)
            end
            ticks = ticks + 1
            if (ran or ticks % 4 == 0) and ensureLoaded() then BWNative_GuiSetState(guiState()) end
        end)
        if not ok then log("admin window error: " .. tostring(e)) end
    end)
end

log(string.format("BWCoop %s loaded, guarding %d server functions and %d cheat functions", VERSION, count, cheatHooks))
