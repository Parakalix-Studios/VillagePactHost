-- BWCoop caravans and village stock (loaded by main.lua, host only; 0.7.11, 2026-10-14).
--
-- Rule (2026-10-14): caravans between friends: drop-offs are free, pickups need trust. A route may
-- unload at any player village, but it may load only at villages its station's owner owns or is trusted in
-- (bwcoop trust). The host follows the rule too, like land claims. Routes, stops and parties belong to the
-- village of their caravan station: only its owner, a trusted friend or the host may change them (main.lua's
-- guards resolve their GUIDs through M.lookup).
--
-- Research: research/logistics-game-code-2026-10-13.md. Routes, stops and parties are UMistData objects; the
-- GUID their requests name sits at +0x78 (not reflected, registered below). Also read here: route auto-send
-- (+0x19C) and last send result (+0x1A8), party status (+0x140), a storage's used volume (+0x47C).
--
-- Console: bwcoop stock [village] [n]   item counts per village (the game's own village summary) and storage
--          bwcoop caravans [village]     stations, routes, stops, load/unload items, parties
--          bwcoop keep ...               keep-stocked rules (0.7.22, see the section below)

return function(core)
    local log, valid, guidStr, arrLen, arrGet = core.log, core.valid, core.guidStr, core.arrLen, core.arrGet
    local className, villageLabel, locationOf = core.className, core.villageLabel, core.locationOf
    local M = {}

    local DB = "/Script/Mist.MistDataBrokerPlayerComponent:"
    local DONT_LOAD = 6 -- EMistDeliveryOrderType: OneTime, Daily, Weekly, TopUp, LoadAll, LoadRequested, DontLoad
    local RESULTS = { [0] = "none yet", "below the auto-send threshold", "not enough carts", "not enough carriers",
        "not enough guards", "not enough money", "not enough animals", "sent" }
    local keepCalling = false -- true while the keep-stocked rules send their own caravan requests (not logged one by one)

    -- Hidden fields, read through UE4SS custom properties.
    local regOk, regErr = true, nil
    local function reg(name, cls, offset, ptype)
        local ok, err = pcall(RegisterCustomProperty, { Name = name, Type = ptype,
            BelongsToClass = "/Script/Mist." .. cls, OffsetInternal = offset })
        if not ok then regOk, regErr = false, name .. ": " .. tostring(err) end
    end
    if type(RegisterCustomProperty) == "function" and type(PropertyTypes) == "table" then
        for prefix, cls in pairs({ Route = "MistCaravanRouteData", Stop = "MistCaravanRouteStopData",
            Party = "MistCaravanPartyData" }) do
            for i, f in ipairs({ "A", "B", "C", "D" }) do
                reg("BW" .. prefix .. "Guid" .. f, cls, 0x78 + 4 * (i - 1), PropertyTypes.IntProperty)
            end
        end
        reg("BWAutoSend", "MistCaravanRouteData", 0x19C, PropertyTypes.ByteProperty)
        reg("BWLastResult", "MistCaravanRouteData", 0x1A8, PropertyTypes.ByteProperty)
        reg("BWPartyStatus", "MistCaravanPartyData", 0x140, PropertyTypes.ByteProperty)
        reg("BWUsedVolume", "MistVolumeContainerComponent", 0x47C, PropertyTypes.IntProperty)
    else
        regOk, regErr = false, "RegisterCustomProperty not available"
    end
    if not regOk then log("caravans: hidden fields not registered (" .. tostring(regErr) .. "); caravan rules off") end

    local function dataKey(o, prefix)
        local g = nil
        pcall(function()
            g = { A = o["BW" .. prefix .. "GuidA"], B = o["BW" .. prefix .. "GuidB"], C = o["BW" .. prefix .. "GuidC"],
                D = o["BW" .. prefix .. "GuidD"] }
        end)
        return g and guidStr(g) or nil
    end

    local function text(t)
        local s = nil
        pcall(function() s = t:ToString() end)
        return s or "?"
    end

    local function itemName(item)
        local s = nil
        pcall(function() s = item.Name:ToString() end)
        if s and s ~= "" then return s end
        return core.objName(item)
    end

    local function routeName(r)
        local s = ""
        pcall(function() s = r.Name.CustomName:ToString() or "" end)
        return s ~= "" and s or "(unnamed route)"
    end

    local function stopTarget(stop)
        local v, market = nil, nil
        pcall(function() if valid(stop.SettlementTarget) and valid(stop.SettlementTarget.Actor) then v = stop.SettlementTarget.Actor end end)
        if not v then pcall(function() if valid(stop.SupplyDemandTarget) then market = stop.SupplyDemandTarget end end) end
        return v, market
    end

    local function loadItems(stop)
        local out = {}
        pcall(function()
            local arr = stop.InternalLoadItemRequests
            for i = 1, arrLen(arr) do
                pcall(function() out[#out + 1] = itemName(arrGet(arr, i).Item) end)
            end
        end)
        return out
    end

    local function unloadItems(stop)
        local out = {}
        pcall(function()
            local arr = stop.InternalItemRequests
            for i = 1, arrLen(arr) do
                pcall(function() out[#out + 1] = itemName(arrGet(arr, i).Item) end)
            end
        end)
        return out
    end

    -- Every caravan station of the player villages: { village, station actor, data }.
    local function stations()
        local list = {}
        for _, v in ipairs(core.playerVillages()) do
            pcall(function()
                local st = v.Data.Structures
                for i = 1, arrLen(st) do
                    pcall(function()
                        local sd = arrGet(st, i)
                        if className(sd) == "MistTownCaravanStructureData" then
                            list[#list + 1] = { village = v, station = sd.PlaceableActor, data = sd }
                        end
                    end)
                end
            end)
        end
        return list
    end

    local function routesOf(s)
        local out = {}
        pcall(function()
            for i = 1, arrLen(s.data.Routes) do
                local r = arrGet(s.data.Routes, i)
                if valid(r) then out[#out + 1] = r end
            end
        end)
        return out
    end

    local function stopsOf(r)
        local out = {}
        pcall(function()
            for i = 1, arrLen(r.Stops) do
                local s = arrGet(r.Stops, i)
                if valid(s) then out[#out + 1] = s end
            end
        end)
        return out
    end

    -- GUID index: route/stop/party key -> { kind, obj, station, village, route }.
    local index, indexedAt = {}, 0
    local function rebuild()
        index, indexedAt = {}, os.time()
        if not regOk then return end
        for _, s in ipairs(stations()) do
            local base = { station = s.station, village = s.village }
            local function add(kind, o, route)
                local k = dataKey(o, kind == "route" and "Route" or kind == "stop" and "Stop" or "Party")
                if k and k ~= core.ZERO then
                    index[k] = { kind = kind, obj = o, station = base.station, village = base.village, route = route }
                end
            end
            for _, r in ipairs(routesOf(s)) do
                add("route", r, r)
                for _, st in ipairs(stopsOf(r)) do add("stop", st, r) end
                pcall(function() if valid(r.AssignedParty) then add("party", r.AssignedParty, r) end end)
            end
            pcall(function()
                for i = 1, arrLen(s.data.Parties) do
                    local p = arrGet(s.data.Parties, i)
                    if valid(p) then add("party", p, nil) end
                end
            end)
        end
    end

    -- The entry for a route/stop/party GUID string, or nil. Rebuilds the index on a miss (at most every 2 s).
    function M.lookup(key)
        local e = index[key]
        if e and valid(e.obj) then return e end
        if os.time() - indexedAt >= 2 then
            rebuild()
            e = index[key]
            if e and valid(e.obj) then return e end
        end
        return nil
    end

    -- May caravans of `stationVillage` load at `target`? Same owner, unowned target, or trusted there.
    local function mayLoad(stationVillage, target)
        if not valid(target) or not valid(stationVillage) then return true end
        if guidStr(target.PersistentGuid) == guidStr(stationVillage.PersistentGuid) then return true end
        local to = core.villageOwner(target)
        if to == nil then return true end
        local so = core.villageOwner(stationVillage)
        if so == to then return true end
        return so ~= nil and core.isTrusted(target, so)
    end

    -- First stop of a route that loads where it may not: returns the target village and its owner.
    local function forbiddenPickup(route, stationVillage)
        for _, st in ipairs(stopsOf(route)) do
            local v = stopTarget(st)
            if v and #loadItems(st) > 0 and not mayLoad(stationVillage, v) then
                return v, core.villageOwner(v)
            end
        end
        return nil
    end

    local function pickupMsg(v, owner)
        return string.format("Caravans may deliver to %s, but loading there needs %s's trust.", villageLabel(v), owner)
    end

    local function guard(fn, check)
        local path = DB .. fn
        local ok = pcall(function()
            RegisterHook(path, function(ctx, ...)
                if not regOk or core.justBlocked() == path then return end
                local req = core.requester(ctx)
                if req == nil then return end
                local args = { ... }
                local okC, err = pcall(check, path, req, args)
                if not okC then log("caravan guard error (" .. fn .. "): " .. tostring(err)) end
            end)
        end)
        if not ok then log("caravans: could not hook " .. fn) end
    end

    local function stopEntry(arg)
        local e = nil
        pcall(function() e = M.lookup(guidStr(arg:get())) end)
        return (e and e.kind == "stop") and e or nil
    end

    -- New load rule at a stop: only where the station's owner may load.
    guard("Server_CaravanRouteStop_ItemRequest_Add", function(path, req, args)
        local isLoad = false
        pcall(function() isLoad = args[2]:get() == true end)
        local e = isLoad and stopEntry(args[1]) or nil
        local v = e and stopTarget(e.obj)
        if v and not mayLoad(e.village, v) then
            local o = core.villageOwner(v)
            core.refuse(path, req, v, o, pickupMsg(v, o))
        end
    end)

    -- Changing a load rule to anything but "don't load".
    guard("Server_CaravanRouteStop_ItemRequest_SetOrderType", function(path, req, args)
        local isLoad, t = false, DONT_LOAD
        pcall(function() isLoad = args[2]:get() == true end)
        pcall(function() t = args[4]:get() end)
        local e = (isLoad and t ~= DONT_LOAD) and stopEntry(args[1]) or nil
        local v = e and stopTarget(e.obj)
        if v and not mayLoad(e.village, v) then
            local o = core.villageOwner(v)
            core.refuse(path, req, v, o, pickupMsg(v, o))
        end
    end)

    -- Pointing a stop at a friend's village is fine (drop-offs are free) unless the stop already loads.
    guard("Server_CaravanRouteStop_SetSettlementTarget", function(path, req, args)
        local e = stopEntry(args[1])
        if not e then return end
        local v = nil
        pcall(function() v = core.villageOfGuid(args[2]:get()) end)
        if v and #loadItems(e.obj) > 0 and not mayLoad(e.village, v) then
            local o = core.villageOwner(v)
            core.refuse(path, req, v, o, pickupMsg(v, o) .. " Remove this stop's load rules first.")
        end
    end)

    -- Sending a route (by hand or automatically) that would load where it may not.
    local function routeCheck(path, req, args)
        local e = nil
        pcall(function() e = M.lookup(guidStr(args[1]:get())) end)
        if not e or e.kind ~= "route" then return end
        if path:find("SetAutoSendEnabled", 1, true) then
            local on = false
            pcall(function() on = args[2]:get() == true end)
            if not on then return end
        end
        local v, o = forbiddenPickup(e.obj, e.village)
        if v then core.refuse(path, req, v, o, pickupMsg(v, o)) end
    end
    guard("Server_CaravanRoute_SendCaravan", routeCheck)
    guard("Server_CaravanRoute_SetAutoSendEnabled", routeCheck)

    -- Midnight deliveries (0.7.13): an order taking goods from another player's village needs that village's trust,
    -- like caravan pickups. Friends are already checked by the village guard (the source village is one of its
    -- parameters); this adds the host, who follows the rule too.
    guard("ServerSetSettlementDeliveryOrderSource", function(path, req, args)
        if not req.isHost then return end
        local v, s = nil, nil
        pcall(function() v = core.villageOfGuid(args[1]:get()) end)
        pcall(function() s = core.villageOfGuid(args[3]:get()) end)
        if v and s and not mayLoad(v, s) then
            local o = core.villageOwner(s)
            core.refuse(path, req, s, o, string.format("Deliveries from %s need %s's trust.", villageLabel(s), o))
        end
    end)

    -- Every caravan request, logged with the route it resolved to (checks the GUID reads in play).
    for _, fn in ipairs({ "Server_CaravanRoute_SetName", "Server_CaravanRoute_SetGuardsNum", "Server_CaravanRoute_SetCartsNum",
        "Server_CaravanRoute_SetAutoSendThreshold", "Server_CaravanRoute_SetAutoSendEnabled", "Server_CaravanRoute_SendCaravan",
        "Server_CaravanRoute_RecallCaravan", "Server_CaravanRoute_Remove", "Server_CaravanRouteStop_AddWithSettlementTarget",
        "Server_CaravanRouteStop_SetSettlementTarget", "Server_CaravanRouteStop_Remove", "Server_CaravanRouteStop_ChangeOrder",
        "Server_CaravanRouteStop_ItemRequest_Add", "Server_CaravanRouteStop_ItemRequest_SetOrderType",
        "Server_CaravanRouteStop_ItemRequest_SetQuantity", "Server_CaravanRouteStop_ItemRequest_Remove",
        "Server_CaravanParty_Recall" }) do
        pcall(function()
            RegisterHook(DB .. fn, function(ctx, g)
                if keepCalling then return end
                local req = core.requester(ctx)
                local e = nil
                pcall(function() e = M.lookup(guidStr(g:get())) end)
                log(string.format("CARAVAN %s by %s: %s", fn:gsub("^Server_", ""), req and req.name or "?",
                    e and string.format("%s of route '%s', station in %s", e.kind, e.route and routeName(e.route) or "?",
                        villageLabel(e.village)) or "not resolved"))
            end)
        end)
    end

    -- Every 30 s: a route with auto-send on that now loads where it may not (trust was taken back, or a rule
    -- from before 0.7.11) gets auto-send turned off, through the game's own request.
    local warned = {}
    function M.audit(mode)
        if not regOk then return end
        local db = nil
        pcall(function() db = core.hostController().DataBrokerComponent end)
        for _, s in ipairs(stations()) do
            for _, r in ipairs(routesOf(s)) do
                local on = 0
                pcall(function() on = r.BWAutoSend end)
                local v, o = nil, nil
                if on ~= 0 then v, o = forbiddenPickup(r, s.village) end
                local key = dataKey(r, "Route")
                if v and key then
                    local what = string.format("route '%s' (station in %s) loads at %s without %s's trust", routeName(r),
                        villageLabel(s.village), villageLabel(v), o or "?")
                    if mode == "enforce" and db then
                        local g = nil
                        pcall(function() g = { A = r.BWRouteGuidA, B = r.BWRouteGuidB, C = r.BWRouteGuidC, D = r.BWRouteGuidD } end)
                        local ok, err = pcall(function() db:Server_CaravanRoute_SetAutoSendEnabled(g, false) end)
                        log("CARAVAN AUDIT " .. what .. (ok and ": auto-send turned off" or (": turning auto-send off FAILED: " .. tostring(err))))
                        local owner = core.villageOwner(s.village)
                        local info = owner and core.playerByName(owner)
                        if ok and info then core.tell(info, pickupMsg(v, o) .. " Automatic sending is off for " .. routeName(r) .. ".") end
                    elseif not warned[key] then
                        warned[key] = true
                        log("CARAVAN AUDIT " .. what .. " (mode " .. tostring(mode) .. ", left on)")
                    end
                end
            end
        end
    end

    ------------------------------------------------------------------------- console

    -- A player village by name or GUID prefix (main.lua's findVillage is defined after this module loads).
    local function findVillage(query)
        local q = query:lower()
        for _, v in ipairs(core.playerVillages()) do
            if villageLabel(v):lower() == q or guidStr(v.PersistentGuid):lower():sub(1, #q) == q then return v end
        end
        return nil
    end

    -- Storage per village (every building with a warehouse component): village key -> { max, used, n }.
    -- Every storage building's volume container: { { warehouse, container, village }, ... }. The storage access point's
    -- InstanceContainer pointer is empty on the host (2026-10-14: "0 of 0" on the panel, and balance writes to a
    -- nullptr every 10 s), so the container is also looked up by the component name its ContainerRef holds
    -- (on ContainerRef.Actor or the building), else the building's only volume container. The route used is logged
    -- once (STORAGE line) so the first load shows which one works.
    local storageRoute = nil
    function M.storages()
        local byOwner = nil
        local function ownerContainers(actor)
            if not byOwner then
                byOwner = {}
                for _, c in ipairs(FindAllOf("MistVolumeContainerComponent") or {}) do
                    pcall(function()
                        local a = c:GetOwner():GetAddress()
                        byOwner[a] = byOwner[a] or {}
                        table.insert(byOwner[a], c)
                    end)
                end
            end
            local list = nil
            pcall(function() list = byOwner[actor:GetAddress()] end)
            return list or {}
        end
        local out, routes = {}, {}
        for _, w in ipairs(FindAllOf("MistTownWarehouseComponent") or {}) do
            pcall(function()
                local building = w:GetOwner()
                local v = building.PlaceableData.Settlement.Actor
                local ap = w.AP_Storage
                if not valid(ap) then return end
                local c, how = nil, nil
                pcall(function() if valid(ap.InstanceContainer) then c, how = ap.InstanceContainer, "pointer" end end)
                if not c then
                    local name, holder = nil, building
                    pcall(function() name = ap.ContainerRef.ComponentName:ToString() end)
                    pcall(function() if valid(ap.ContainerRef.Actor) then holder = ap.ContainerRef.Actor end end)
                    local list = ownerContainers(holder)
                    if name and name ~= "" and name ~= "None" then
                        for _, x in ipairs(list) do
                            local xn = nil
                            pcall(function() xn = x:GetFName():ToString() end)
                            if xn == name then c, how = x, "name"; break end
                        end
                    end
                    if not c and #list == 1 then c, how = list[1], "only" end
                end
                if valid(c) then
                    out[#out + 1] = { warehouse = w, container = c, village = v }
                    routes[how] = (routes[how] or 0) + 1
                else
                    routes.none = (routes.none or 0) + 1
                end
            end)
        end
        local parts = {}
        for _, k in ipairs({ "pointer", "name", "only", "none" }) do
            if routes[k] then parts[#parts + 1] = k .. " " .. routes[k] end
        end
        local summary = table.concat(parts, ", ")
        if summary ~= storageRoute then
            storageRoute = summary
            log("STORAGE containers found: " .. (summary ~= "" and summary or "no storage buildings"))
        end
        return out
    end

    local function storageByVillage()
        local cap = {}
        for _, s in ipairs(M.storages()) do
            pcall(function()
                local c = s.container
                local k = guidStr(s.village.PersistentGuid)
                cap[k] = cap[k] or { max = 0, used = 0, n = 0 }
                cap[k].max = cap[k].max + (c.MaxVolume or 0)
                cap[k].used = cap[k].used + (c.BWUsedVolume or 0)
                cap[k].n = cap[k].n + 1
            end)
        end
        return cap
    end

    -- The game's own summary of a village's items (what its storage screen shows), most first: { name, n (count),
    -- a (free), i (incoming), o (outgoing), p (made), u (used) }. Items in stock, on the way, or in use.
    local function ledgerRows(v)
        local rows = {}
        pcall(function()
            local arr = v.Data.LedgerResources
            for i = 1, arrLen(arr) do
                pcall(function()
                    local e = arrGet(arr, i)
                    if (e.ItemCount or 0) > 0 or (e.IncomingCount or 0) > 0 or (e.Consumption or 0) > 0 then
                        rows[#rows + 1] = { name = itemName(e.ItemTemplate), n = e.ItemCount or 0, a = e.AvailableCount or 0,
                            i = e.IncomingCount or 0, o = e.OutgoingCount or 0, p = e.Production or 0, u = e.Consumption or 0 }
                    end
                end)
            end
        end)
        table.sort(rows, function(a, b) return a.n > b.n end)
        return rows
    end

    function M.stock(say, arg)
        local vq, nq = arg:match("^(.-)%s*(%d*)$")
        local only = (vq and vq ~= "") and findVillage(vq) or nil
        if vq and vq ~= "" and not only then return say("stock: no village named " .. vq) end
        local top = tonumber(nq) or 12
        local cap = storageByVillage()
        for _, v in ipairs(core.playerVillages()) do
            if not only or guidStr(v.PersistentGuid) == guidStr(only.PersistentGuid) then
                local c = cap[guidStr(v.PersistentGuid)]
                say(string.format("%s: %s", villageLabel(v), c and string.format("%d storages, %d of %d space used (%d%%)",
                    c.n, c.used, c.max, c.max > 0 and math.floor(100 * c.used / c.max) or 0) or "no storages"))
                local rows = ledgerRows(v)
                for k = 1, math.min(top, #rows) do
                    local r = rows[k]
                    say(string.format("  %-24s %5d  (free %d, in %d, out %d, made %.1f, used %.1f)", r.name, r.n, r.a, r.i,
                        r.o, r.p or 0, r.u or 0))
                end
                if #rows > top then say(string.format("  ... %d more item types", #rows - top)) end
            end
        end
    end

    function M.caravans(say, arg)
        if not regOk then say("caravans: hidden fields not registered: " .. tostring(regErr)) end
        local only = (arg ~= "") and findVillage(arg) or nil
        if arg ~= "" and not only then return say("caravans: no village named " .. arg) end
        local list = stations()
        if #list == 0 then return say("caravans: no caravan stations") end
        rebuild()
        for _, s in ipairs(list) do
            if not only or guidStr(s.village.PersistentGuid) == guidStr(only.PersistentGuid) then
                local l = locationOf(s.station)
                local tc, mc = 0, 0
                pcall(function() tc, mc = s.data.TargetCartsNum, s.data.MaxCartsNum end)
                say(string.format("station in %s at %.0f, %.0f: carts %d (max %d)", villageLabel(s.village), l and l.X or 0,
                    l and l.Y or 0, tc, mc))
                local routes = routesOf(s)
                if #routes == 0 then say("  no routes") end
                for _, r in ipairs(routes) do
                    local carts, guards, thr, auto, res = 0, 0, 0, -1, -1
                    pcall(function() carts, guards = r.CaravanPartyPreset.NumberOfCarts, r.CaravanPartyPreset.NumberOfGuards end)
                    pcall(function() thr = r.MinCapacityToStart end)
                    pcall(function() auto = r.BWAutoSend end)
                    pcall(function() res = r.BWLastResult end)
                    say(string.format("  route '%s' [%s]: %d carts, %d guards, auto-send %s at %d, last: %s", routeName(r),
                        (dataKey(r, "Route") or "?"):sub(1, 8), carts, guards, auto == 0 and "off" or auto == -1 and "?" or "on",
                        thr, RESULTS[res] or tostring(res)))
                    for k, st in ipairs(stopsOf(r)) do
                        local v, market = stopTarget(st)
                        local where = v and villageLabel(v) or market and ("market " .. core.objName(market)) or "(no target)"
                        local ld, ul = loadItems(st), unloadItems(st)
                        local flag = (v and #ld > 0 and not mayLoad(s.village, v)) and "  <- loads without trust" or ""
                        say(string.format("    %d. %s  load: %s  unload: %s%s", k, where, #ld > 0 and table.concat(ld, ", ") or "-",
                            #ul > 0 and table.concat(ul, ", ") or "-", flag))
                    end
                    pcall(function()
                        local p = r.AssignedParty
                        if valid(p) then
                            local pl = locationOf(p.CaravanActor)
                            local st, items = -1, {}
                            pcall(function() st = p.BWPartyStatus end)
                            pcall(function()
                                p.PackedItems:ForEach(function(k, v) items[#items + 1] = itemName(k:get()) .. " " .. tostring(v:get()) end)
                            end)
                            say(string.format("    out now: status %d at %.0f, %.0f carrying %s", st, pl and pl.X or 0, pl and pl.Y or 0,
                                #items > 0 and table.concat(items, ", ") or "nothing"))
                        end
                    end)
                end
            end
        end
    end

    ------------------------------------------------------------------------- keep-stocked rules (0.7.22)

    -- 2026-10-15: "keep 200 planks in Riverside from Oakhold", moved by the game's own caravans. Each
    -- source/target pair gets a route named "Keep: <target>" on the source village's caravan station: stop 1 the source
    -- (load rule "load requested" per item), stop 2 the target (request "top up" to each rule's level), automatic
    -- sending on, leaving once it can carry a quarter of the smallest level (1 to 50). The game does the rest and keeps
    -- the reason a caravan didn't leave. Optional reserve ("keeping 100", 2026-10-15): the top-up level is lowered
    -- so the source keeps that many. Rules live in the save's data file (stock and stockroute lines) and are checked
    -- every 30 s, so a route lost to an older save or changed in the caravan screen is set up again. The IDs of a
    -- stop's item requests aren't reflected: BWCoopNative 0.4.4 reads them (BWNative_ItemRequests).
    local TOP_UP, LOAD_REQUESTED = 3, 5
    local keepStatus = {} -- "source>target" -> the last problem, or nil

    local function villageByKey(k)
        for _, v in ipairs(core.playerVillages()) do
            if guidStr(v.PersistentGuid) == k then return v end
        end
        return nil
    end

    -- FGuid fields are int32 in the game's reflection, so these pass as they are.
    local function guidOf(g)
        local t = nil
        pcall(function() t = { A = g.A, B = g.B, C = g.C, D = g.D } end)
        return t
    end

    local function dataGuid(o, prefix)
        local t = nil
        pcall(function()
            t = { A = o["BW" .. prefix .. "GuidA"], B = o["BW" .. prefix .. "GuidB"], C = o["BW" .. prefix .. "GuidC"],
                D = o["BW" .. prefix .. "GuidD"] }
        end)
        return t
    end

    -- A village's summary for one item (by shown name): count, free.
    local function itemCounts(v, name)
        local n, a, low = 0, 0, name:lower()
        pcall(function()
            local arr = v.Data.LedgerResources
            for i = 1, arrLen(arr) do
                local found = false
                pcall(function()
                    local e = arrGet(arr, i)
                    if itemName(e.ItemTemplate):lower() == low then n, a, found = e.ItemCount or 0, e.AvailableCount or 0, true end
                end)
                if found then break end
            end
        end)
        return n, a
    end

    -- Item templates in the given villages' summaries (any count): lowercase name -> { name, t }.
    local function knownItems(villages)
        local out = {}
        for _, v in ipairs(villages) do
            pcall(function()
                local arr = v.Data.LedgerResources
                for i = 1, arrLen(arr) do
                    pcall(function()
                        local t = arrGet(arr, i).ItemTemplate
                        if valid(t) then
                            local n = itemName(t)
                            if not out[n:lower()] then out[n:lower()] = { name = n, t = t } end
                        end
                    end)
                end
            end)
        end
        return out
    end

    -- An item by name: exact (also without a plural s/es), else the only one with a word starting with it, else the
    -- only one containing it. Returns the entry, or nil and the candidates.
    local function matchItem(known, query)
        local q0 = query:lower()
        local tries = { q0 }
        if q0:sub(-2) == "es" then tries[#tries + 1] = q0:sub(1, -3) end
        if q0:sub(-1) == "s" then tries[#tries + 1] = q0:sub(1, -2) end
        for _, q in ipairs(tries) do
            if known[q] then return known[q] end
        end
        local cands = {}
        for _, q in ipairs(tries) do
            local starts, has = {}, {}
            for k, e in pairs(known) do
                if k:sub(1, #q) == q or k:find(" " .. q, 1, true) then
                    starts[#starts + 1] = e
                elseif k:find(q, 1, true) then
                    has[#has + 1] = e
                end
            end
            local list = #starts > 0 and starts or has
            if #list == 1 then return list[1] end
            if #list > #cands then cands = list end
        end
        return nil, cands
    end

    -- The longest village name that `s` starts with: village, the rest of `s`.
    local function villagePrefix(s)
        local best, rest, sl = nil, nil, s:lower()
        for _, v in ipairs(core.playerVillages()) do
            local l = villageLabel(v):lower()
            if sl:sub(1, #l) == l and (#sl == #l or sl:sub(#l + 1, #l + 1) == " ") and
                (not best or #l > #villageLabel(best)) then
                best, rest = v, s:sub(#l + 2)
            end
        end
        return best, rest
    end

    -- A stop's item requests in order: { id = {A..D}, type, qty, item }; nil without BWCoopNative 0.4.4.
    local function itemRequests(stop, isLoad)
        if type(BWNative_ItemRequests) ~= "function" then return nil end
        local raw = nil
        pcall(function() raw = BWNative_ItemRequests(stop:GetAddress(), isLoad) end)
        if type(raw) ~= "string" then return nil end
        local arr = nil
        pcall(function() arr = isLoad and stop.InternalLoadItemRequests or stop.InternalItemRequests end)
        local out, i = {}, 0
        for part in raw:gmatch("[^;]+") do
            i = i + 1
            local a, b, c, d, t, q = part:match("^(%-?%d+),(%-?%d+),(%-?%d+),(%-?%d+),(%d+),(%-?%d+)$")
            local name = "?"
            pcall(function() name = itemName(arrGet(arr, i).Item) end)
            if a then
                out[#out + 1] = { id = { A = tonumber(a), B = tonumber(b), C = tonumber(c), D = tonumber(d) },
                    type = tonumber(t), qty = tonumber(q), item = name }
            end
        end
        return out
    end

    -- One request on the host's own data broker (the game's own path: dirty bits, saving and friends' screens stay right).
    local function call(db, fn, ...)
        local args = table.pack(...)
        keepCalling = true
        local ok, err = pcall(function() db[fn](db, table.unpack(args, 1, args.n)) end)
        keepCalling = false
        if not ok then error(fn:gsub("^Server_", "") .. " failed: " .. tostring(err), 0) end
    end

    local function pairLabel(key)
        local skey, tkey = key:match("^(.-)>(.+)$")
        local S, T = villageByKey(skey or ""), villageByKey(tkey or "")
        return string.format("%s -> %s", S and villageLabel(S) or "?", T and villageLabel(T) or "?")
    end

    local function pairRules(key)
        local out = {}
        for _, r in ipairs(core.stockRules()) do
            if r.source .. ">" .. r.target == key then out[#out + 1] = r end
        end
        return out
    end

    local function threshold(rules)
        local m = math.huge
        for _, r in ipairs(rules) do m = math.min(m, r.level) end
        return math.max(1, math.min(50, math.floor(m / 4)))
    end

    -- The route of a pair (by its recorded GUID, on a station of the source village): route, station.
    local function pairRoute(key, skey)
        local want = core.stockRoutes()[key]
        if not want then return nil end
        for _, s in ipairs(stations()) do
            if guidStr(s.village.PersistentGuid) == skey then
                for _, r in ipairs(routesOf(s)) do
                    if dataKey(r, "Route") == want then return r, s end
                end
            end
        end
        return nil
    end

    -- Make the pair's route match its rules. Returns nil when all is set, else what is missing.
    local function keepPair(db, key, rules)
        local skey, tkey = key:match("^(.-)>(.+)$")
        local routes = core.stockRoutes()
        local route = pairRoute(key, skey)
        if #rules == 0 then
            -- every rule of the pair removed: the route goes once its caravan is home
            if not route then
                if routes[key] then routes[key] = nil; core.saveData() end
                return nil
            end
            local rg = dataGuid(route, "Route")
            local out, auto = false, 0
            pcall(function() out = valid(route.AssignedParty) end)
            pcall(function() auto = route.BWAutoSend end)
            if out then
                if auto ~= 0 then call(db, "Server_CaravanRoute_SetAutoSendEnabled", rg, false) end
                return "rule removed; the route goes when its caravan is home"
            end
            call(db, "Server_CaravanRoute_Remove", rg)
            log(string.format("KEEPSTOCK %s: route '%s' removed (no rules left)", pairLabel(key), routeName(route)))
            routes[key] = nil
            core.saveData()
            return nil
        end
        local S, T = villageByKey(skey), villageByKey(tkey)
        if not S or not T then return "a village of this rule no longer exists" end
        local label = "Keep: " .. villageLabel(T)
        if not route then
            local st = nil
            for _, s in ipairs(stations()) do
                if not st and guidStr(s.village.PersistentGuid) == skey then st = s end
            end
            if not st then return villageLabel(S) .. " has no caravan station" end
            local before = {}
            for _, r in ipairs(routesOf(st)) do before[dataKey(r, "Route") or "?"] = true end
            call(db, "Server_CaravanRoute_Add", guidOf(st.station.PersistentGuid))
            for _, r in ipairs(routesOf(st)) do
                if not before[dataKey(r, "Route") or "?"] then route = r end
            end
            if not route then return "the game made no route on " .. villageLabel(S) .. "'s caravan station" end
            pcall(call, db, "Server_CaravanRoute_SetName", dataGuid(route, "Route"), { CustomName = FText(label) })
            routes[key] = dataKey(route, "Route")
            core.saveData()
            log(string.format("KEEPSTOCK %s: route '%s' made on %s's caravan station", pairLabel(key), routeName(route),
                villageLabel(S)))
        end
        local rg = dataGuid(route, "Route")
        -- stops: exactly the source, then the target
        local function targetKey(stop)
            local v = stop and stopTarget(stop)
            return v and guidStr(v.PersistentGuid) or nil
        end
        local function stopNames(list)
            local names = {}
            for _, x in ipairs(list) do
                local v, market = stopTarget(x)
                names[#names + 1] = v and villageLabel(v) or (market and "market" or "none")
            end
            return string.format("%d: %s", #list, #names > 0 and table.concat(names, ", ") or "-")
        end
        -- Source, then target; further stops only at the source. The game keeps a route's last stop at the station's
        -- village (2026-10-17: a new route had "Riverside, Riverside"; after removing both and adding two it had
        -- "Riverside, Oakhold, Riverside"), so demanding exactly two stops rebuilt them every 30 s (0.7.26).
        local function stopsOk(list)
            if #list < 2 or targetKey(list[1]) ~= skey or targetKey(list[2]) ~= tkey then return false end
            for k = 3, #list do
                if targetKey(list[k]) ~= skey then return false end
            end
            return true
        end
        local stops = stopsOf(route)
        if not stopsOk(stops) then
            -- 0.7.24: the 30 s check set the stops again 23 s after they were set (2026-10-16 19:04): log what it found
            log(string.format("KEEPSTOCK %s: stops found %s", pairLabel(key), stopNames(stops)))
            for _, x in ipairs(stops) do call(db, "Server_CaravanRouteStop_Remove", dataGuid(x, "Stop")) end
            call(db, "Server_CaravanRouteStop_AddWithSettlementTarget", rg)
            call(db, "Server_CaravanRouteStop_AddWithSettlementTarget", rg)
            stops = stopsOf(route)
            if #stops < 2 then return "the game added no stops to the route" end
            call(db, "Server_CaravanRouteStop_SetSettlementTarget", dataGuid(stops[1], "Stop"), guidOf(S.PersistentGuid))
            call(db, "Server_CaravanRouteStop_SetSettlementTarget", dataGuid(stops[2], "Stop"), guidOf(T.PersistentGuid))
            stops = stopsOf(route)
            if not stopsOk(stops) then
                return "the route's stops didn't take their villages"
            end
            log(string.format("KEEPSTOCK %s: stops set (%s, then %s; now %s)", pairLabel(key), villageLabel(S), villageLabel(T),
                stopNames(stops)))
        end
        -- item requests: load each rule's item at the source, top it up at the target
        local known = knownItems({ S, T })
        local want = {}
        for _, r in ipairs(rules) do want[r.item:lower()] = r end
        local missing = {}
        local function sync(stop, isLoad, wantType, qtyOf)
            local list = itemRequests(stop, isLoad)
            if not list then error("BWCoopNative 0.4.4 is needed to read caravan requests", 0) end
            local sg = dataGuid(stop, "Stop")
            local have = {}
            for _, e in ipairs(list) do
                local k = e.item:lower()
                if not want[k] or have[k] then
                    call(db, "Server_CaravanRouteStop_ItemRequest_Remove", sg, isLoad, e.id)
                else
                    have[k] = e
                end
            end
            for k, r in pairs(want) do
                local e = have[k]
                if not e then
                    local it = known[k]
                    if it then
                        call(db, "Server_CaravanRouteStop_ItemRequest_Add", sg, isLoad, it.t)
                        for _, x in ipairs(itemRequests(stop, isLoad) or {}) do
                            if x.item:lower() == k then e = x end
                        end
                    else
                        missing[r.item] = true
                    end
                end
                if e then
                    if e.type ~= wantType then call(db, "Server_CaravanRouteStop_ItemRequest_SetOrderType", sg, isLoad, e.id, wantType) end
                    local q = qtyOf and qtyOf(r)
                    if q and e.qty ~= q then call(db, "Server_CaravanRouteStop_ItemRequest_SetQuantity", sg, isLoad, e.id, q) end
                end
            end
        end
        sync(stops[1], true, LOAD_REQUESTED, nil)
        sync(stops[2], false, TOP_UP, function(r)
            if (r.reserve or 0) <= 0 then return r.level end
            local tn = itemCounts(T, r.item)
            local _, sa = itemCounts(S, r.item)
            return math.max(0, math.min(r.level, tn + math.max(0, sa - r.reserve)))
        end)
        -- automatic sending
        local thr, cur, auto = threshold(rules), -1, -1
        pcall(function() cur = route.MinCapacityToStart end)
        pcall(function() auto = route.BWAutoSend end)
        if cur ~= thr then call(db, "Server_CaravanRoute_SetAutoSendThreshold", rg, thr) end
        if auto == 0 then call(db, "Server_CaravanRoute_SetAutoSendEnabled", rg, true) end
        local names = {}
        for n in pairs(missing) do names[#names + 1] = n end
        if #names > 0 then
            return "not in either village's item list yet: " .. table.concat(names, ", ")
        end
        return nil
    end

    -- Every 30 s (main.lua), and right after a rule changes.
    function M.keepApply()
        if not regOk then return end
        local db = nil
        pcall(function() db = core.hostController().DataBrokerComponent end)
        if not valid(db) then return end
        local keys = {}
        for _, r in ipairs(core.stockRules()) do keys[r.source .. ">" .. r.target] = true end
        for k in pairs(core.stockRoutes()) do keys[k] = true end
        for k in pairs(keys) do
            local ok, res = pcall(keepPair, db, k, pairRules(k))
            -- not "ok and res or ...": a pair that is all set returns nil, which read as "error: nil" (0.7.24)
            local msg = res
            if not ok then msg = "error: " .. tostring(res) end
            if msg and msg ~= keepStatus[k] then log("KEEPSTOCK " .. pairLabel(k) .. ": " .. msg) end
            keepStatus[k] = msg
        end
    end

    -- Who may add or remove a rule (2026-10-15): it uses the source village's goods, caravan and carriers, so
    -- the source's owner, players the source trusts, and the host; the receiving village's owner may also remove one.
    -- A source without an owner is open to everyone, like any unowned village.
    local function mayTakeFrom(req, S)
        if req.isHost then return true end
        local o = core.villageOwner(S)
        return o == nil or o == req.name or core.isTrusted(S, req.name)
    end

    -- Add or change a rule. Returns ok, message (shown to the player who asked, or in the console).
    local function addRule(req, T, S, itemq, level, reserve)
        if not T or not S then return false, "That village no longer exists." end
        if guidStr(S.PersistentGuid) == guidStr(T.PersistentGuid) then
            return false, "Pick another village to send from."
        end
        if not level or level < 1 then return false, "Enter an amount of at least 1." end
        level = math.floor(level)
        reserve = math.max(0, math.floor(reserve or 0))
        if not mayTakeFrom(req, S) then
            return false, string.format("Taking from %s needs %s's trust.", villageLabel(S), core.villageOwner(S) or "?")
        end
        itemq = (itemq or ""):match("^%s*(.-)%s*$")
        if itemq == "" then return false, "Enter an item." end
        local it, cands = matchItem(knownItems({ S, T }), itemq)
        if not it then
            if cands and #cands > 0 then
                local names = {}
                for i = 1, math.min(8, #cands) do names[#names + 1] = cands[i].name end
                return false, string.format("'%s' could be: %s.", itemq, table.concat(names, ", "))
            end
            return false, string.format("No item '%s' in %s's or %s's stock list.", itemq, villageLabel(S), villageLabel(T))
        end
        local rules = core.stockRules()
        local tkey, skey = guidStr(T.PersistentGuid), guidStr(S.PersistentGuid)
        for i = #rules, 1, -1 do
            if rules[i].target == tkey and rules[i].item:lower() == it.name:lower() then table.remove(rules, i) end
        end
        rules[#rules + 1] = { target = tkey, source = skey, item = it.name, level = level, reserve = reserve }
        core.saveData()
        log(string.format("KEEPSTOCK rule by %s: %s keeps %d %s from %s%s", req.name or "host", villageLabel(T), level,
            it.name, villageLabel(S), reserve > 0 and (", keeping " .. reserve) or ""))
        pcall(M.keepApply)
        local st = keepStatus[skey .. ">" .. tkey]
        return true, string.format("%s keeps %d %s, sent from %s%s.%s", villageLabel(T), level, it.name, villageLabel(S),
            reserve > 0 and (" (keeping " .. reserve .. " there)") or "", st and (" " .. st) or "")
    end

    -- Remove the rule for an item at a village. Returns ok, message.
    local function removeRule(req, T, itemq)
        if not T then return false, "That village no longer exists." end
        local rules = core.stockRules()
        local tkey = guidStr(T.PersistentGuid)
        local known = {}
        for _, r in ipairs(rules) do
            if r.target == tkey then known[r.item:lower()] = { name = r.item } end
        end
        local it, cands = matchItem(known, itemq or "")
        if not it then
            local names = {}
            for _, c in ipairs(cands or {}) do names[#names + 1] = c.name end
            return false, string.format("%s has no rule for '%s'%s.", villageLabel(T), itemq or "",
                #names > 0 and (" (which one: " .. table.concat(names, ", ") .. ")") or "")
        end
        for i = #rules, 1, -1 do
            local r = rules[i]
            if r.target == tkey and r.item:lower() == it.name:lower() then
                local S = villageByKey(r.source)
                local ok = (S and mayTakeFrom(req, S)) or (not S) or req.isHost or core.villageOwner(T) == req.name
                if not ok then
                    return false, string.format("Only %s's owner, players it trusts, or %s's owner can remove this.",
                        S and villageLabel(S) or "?", villageLabel(T))
                end
                table.remove(rules, i)
            end
        end
        core.saveData()
        log(string.format("KEEPSTOCK rule removed by %s: %s %s", req.name or "host", villageLabel(T), it.name))
        pcall(M.keepApply)
        return true, string.format("%s no longer keeps %s stocked.", villageLabel(T), it.name)
    end

    -- A rule's status line for the panel: the count there and what the caravan is doing.
    local function ruleStatus(r)
        local key = r.source .. ">" .. r.target
        local T = villageByKey(r.target)
        local n = T and itemCounts(T, r.item) or 0
        if keepStatus[key] then return string.format("%d here, %s", n, keepStatus[key]) end
        local route = pairRoute(key, r.source)
        local out, res = false, -1
        if route then
            pcall(function() out = valid(route.AssignedParty) end)
            pcall(function() res = route.BWLastResult end)
        end
        if out then return string.format("%d here, caravan on the way", n) end
        if n >= r.level then return string.format("%d here, stocked", n) end
        if not route then return string.format("%d here, setting up", n) end
        if res == 1 then return string.format("%d here, waiting for enough to send", n) end
        if res >= 2 and res <= 6 then return string.format("%d here, waiting: %s", n, RESULTS[res]) end
        return string.format("%d here", n)
    end

    -- For the client's Villages panel (BWCoopClient 0.7.9): per village (the bridge's order), its rules as
    -- "text||item" joined by "@@", text = "Item to N from Village[, keeping R]\n<count> here, <status>".
    function M.keepPanel(villages)
        local out = {}
        for i, v in ipairs(villages) do
            local key, parts = guidStr(v.PersistentGuid), {}
            for _, r in ipairs(core.stockRules()) do
                if r.target == key then
                    local S = villageByKey(r.source)
                    parts[#parts + 1] = string.format("%s to %d from %s%s\n%s||%s", r.item, r.level,
                        S and villageLabel(S) or "?", (r.reserve or 0) > 0 and (", keeping " .. r.reserve) or "",
                        ruleStatus(r), r.item)
                end
            end
            out[i] = table.concat(parts, "@@")
        end
        return out
    end

    -- A request from a player's Villages panel (BWCoopClient 0.7.9), carried by the game's UnlockPerk console command
    -- (main.lua catches "BWCoop|..." texts on ServerUnlockPerk and skips the real call). Spaces in item names come
    -- as "~" (the console splits on spaces):
    --   BWCoop|keep|<target village GUID>|<item>|<amount>|<source village GUID>|<keep there>
    --   BWCoop|unkeep|<target village GUID>|<item>
    function M.request(req, text)
        local p = {}
        local sep = text:sub(7, 7) -- ";" from the panel (0.7.25), "|" when typed in quotes
        for part in (text .. sep):gmatch("([^%" .. sep .. "]*)%" .. sep) do p[#p + 1] = part end
        local function item(s) return ((s or ""):gsub("~", " ")) end
        local ok, msg
        if p[2] == "keep" then
            ok, msg = addRule(req, villageByKey(p[3] or ""), villageByKey(p[6] or ""), item(p[4]), tonumber(p[5]),
                tonumber(p[7]) or 0)
        elseif p[2] == "unkeep" then
            ok, msg = removeRule(req, villageByKey(p[3] or ""), item(p[4]))
        else
            log("REQUEST unknown from " .. tostring(req.name) .. ": " .. text)
            return
        end
        log(string.format("REQUEST %s by %s: %s", p[2], tostring(req.name), msg))
        core.tell(req, msg)
        -- the open panel shows the change at once, not after the next 10 s panel publish (0.7.26)
        if core.panelNow then pcall(core.panelNow) end
    end

    local KEEP_USAGE = "usage: bwcoop keep <village> <item> <n> from <village> [keeping <n>] | keep remove <village> <item> | keep"
    local HOST = { isHost = true, name = nil }

    function M.keep(say, arg)
        local rules = core.stockRules()
        if arg == "" then
            if #rules == 0 then
                return say("keep: no rules yet. Example: bwcoop keep Riverside planks 200 from Oakhold keeping 100")
            end
            local seen = {}
            for _, r in ipairs(rules) do
                local S, T = villageByKey(r.source), villageByKey(r.target)
                say(string.format("keep: %s %s at %d from %s%s: %s", T and villageLabel(T) or "?", r.item, r.level,
                    S and villageLabel(S) or "?", (r.reserve or 0) > 0 and (", keeping " .. r.reserve) or "", ruleStatus(r)))
                local key = r.source .. ">" .. r.target
                if not seen[key] then
                    seen[key] = true
                    local route = pairRoute(key, r.source)
                    if route then
                        local thr, auto = -1, -1
                        pcall(function() thr = route.MinCapacityToStart end)
                        pcall(function() auto = route.BWAutoSend end)
                        say(string.format("  route '%s' on %s's station: sends at %d, automatic %s", routeName(route),
                            S and villageLabel(S) or "?", thr, auto == 0 and "off" or "on"))
                    end
                end
            end
            return
        end
        local rm = arg:match("^[Rr]emove%s+(.+)$")
        if rm then
            local T, rest = villagePrefix(rm)
            if not T or not rest or rest == "" then return say("keep remove: start with the village, then the item. " .. KEEP_USAGE) end
            local _, msg = removeRule(HOST, T, rest)
            return say("keep: " .. msg)
        end
        local left, right = arg:match("^(.-)%s+[Ff][Rr][Oo][Mm]%s+(.+)$")
        if not left then return say(KEEP_USAGE) end
        local src, res = right:match("^(.-)%s+[Kk]eeping%s+(%d+)$")
        src = src or right
        local S = findVillage(src)
        if not S then return say("keep: no village named " .. src) end
        local T, rest = villagePrefix(left)
        if not T then return say("keep: start with the village to keep stocked. " .. KEEP_USAGE) end
        local itemq, n = (rest or ""):match("^(.-)%s+(%d+)$")
        if not itemq or itemq == "" then return say(KEEP_USAGE) end
        local _, msg = addRule(HOST, T, S, itemq, tonumber(n), tonumber(res) or 0)
        say("keep: " .. msg)
    end

    ------------------------------------------------------------------------- Villages panel (client mod)

    -- Data for the client mod's Villages panel (2026-10-14: shown with the village screen, all villages, own
    -- first, read-only). For each village of `villages` (the bridge's order): a text in four parts split by
    -- PANEL_SEP, "name@@info@@stock@@caravans" (client 0.7.7+: the name line sits on the game's header bar, the stock
    -- part in its own scroll box about 15 lines tall so a long list doesn't push the caravans down;
    -- 2026-10-14; host 0.7.16-0.7.18 sent "header@@stock@@caravans" for client 0.7.6), and an item list
    -- "Name count|Name count|..." for the panel's search. Counts only, no forecasts (2026-10-14: list what is
    -- there, don't guess when it runs out).
    local PANEL_SEP = "@@"
    function M.panelData(villages)
        local cap = storageByVillage()
        local byVillage = {}
        for _, s in ipairs(stations()) do
            local k = guidStr(s.village.PersistentGuid)
            byVillage[k] = byVillage[k] or {}
            table.insert(byVillage[k], s)
        end
        local panels, items = {}, {}
        for i, v in ipairs(villages) do
            local key = guidStr(v.PersistentGuid)
            local owner = core.villageOwner(v)
            local people = 0
            pcall(function() people = arrLen(v.PopulationComponent.Residents) end)
            -- the header bar holds only the village and its owner; people go on the first info line
            -- (2026-10-14: "Millbrook (Ann), 2 peo" was cut off with a long owner name)
            local name = string.format("%s%s", villageLabel(v), owner and (" (" .. owner .. ")") or "")
            local lines = { string.format("%d people", people) }
            local c = cap[key]
            lines[#lines + 1] = c and string.format("Storage: %d of %d used (%d%%)", c.used, c.max,
                c.max > 0 and math.floor(100 * c.used / c.max) or 0) or "Storage: none"
            local rows = ledgerRows(v)
            local list = {}
            for _, r in ipairs(rows) do
                if r.n > 0 then list[#list + 1] = r.name .. " " .. r.n end
            end
            lines[#lines + 1] = "Stock:"
            local caravanLines = {}
            for _, s in ipairs(byVillage[key] or {}) do
                for _, r in ipairs(routesOf(s)) do
                    local carts, res, out = 0, -1, nil
                    pcall(function() carts = r.CaravanPartyPreset.NumberOfCarts end)
                    pcall(function() res = r.BWLastResult end)
                    pcall(function()
                        local p = r.AssignedParty
                        if valid(p) then
                            local carried = {}
                            pcall(function()
                                p.PackedItems:ForEach(function(k, n) carried[#carried + 1] = itemName(k:get()) .. " " .. tostring(n:get()) end)
                            end)
                            out = "out, carrying " .. (#carried > 0 and table.concat(carried, ", ") or "nothing")
                        end
                    end)
                    local stops = {}
                    for _, st in ipairs(stopsOf(r)) do
                        local tv, market = stopTarget(st)
                        stops[#stops + 1] = tv and villageLabel(tv) or market and "market" or "?"
                    end
                    caravanLines[#caravanLines + 1] = string.format("Caravan %s (%d %s, %s): %s", routeName(r), carts, carts == 1 and "cart" or "carts",
                        #stops > 0 and table.concat(stops, " > ") or "no stops",
                        out or ("home, last: " .. (RESULTS[res] or "?")))
                end
            end
            -- The client shows each part in its own text; the caravans part ends with a blank line (space before the
            -- next village).
            panels[i] = name .. PANEL_SEP .. table.concat(lines, "\n") .. PANEL_SEP .. (#list > 0 and table.concat(list, "\n") or "empty") ..
                PANEL_SEP .. (#caravanLines > 0 and (table.concat(caravanLines, "\n") .. "\n") or "")
            items[i] = table.concat(list, "|")
        end
        return panels, items
    end

    return M
end
