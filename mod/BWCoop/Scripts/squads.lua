-- BWCoop squads: companions per player (loaded by main.lua, host only).
--
-- In the game all players share one faction, so:
--   * "Mobilize companions" always fills the one squad flagged "call to arms" and makes it follow
--     whoever mobilized last (AMistCombatGroup::GetOrCreateCallToArmsCombatGroup).
--   * When a squad gets its first soldier, every player who commands no squad is handed it
--     (AMistCombatGroup::AddCombatant), so everyone sees its command bar and can order it.
--   * When a commanded squad empties, the player is handed the last squad that has soldiers
--     (UMistPlayerCommandComponent::FindAndSetCommandedCombatGroup).
--
-- What this does:
--   * A squad belongs to the owner of the village most of its people come from; an empty squad to
--     whoever created it; a squad with nobody from an owned village is open to everyone.
--   * The game's default squads (new hires, call to arms, common) are per player: during a squad
--     request, other owners' default squads lose their flag, so the requester gets their own.
--   * After every squad request, anyone just handed a squad that isn't theirs gets their previous
--     squad back, or none. Every 2 seconds the same check runs for everyone, the host included (a
--     squad can change owner after it was handed out, when its villagers move village).
--   * Friends can't order, rename, raise, dismiss or change someone else's squad.
--   * A friend's recruit moves to the friend's own village (the game puts every recruit in the main
--     settlement) and the friend commands its squad, as the game does for the host.
-- Needs BWCoopNative 0.2.1 (game calls, squad flags); with 0.2.0 only the call-to-arms squad is per
-- player.

return function(core)
    local log, valid, guidStr, arrLen, arrGet = core.log, core.valid, core.guidStr, core.arrLen, core.arrGet
    local playerInfo, requester, tell, skipCall, fnName = core.playerInfo, core.requester, core.tell, core.skipCall, core.fnName

    local function ready()
        return type(BWNative_GameCallsReady) == "function" and BWNative_GameCallsReady() == true
    end

    local function addr(o)
        local ok, a = pcall(function() return o:GetAddress() end)
        return ok and a or 0
    end

    local function same(a, b)
        if a == nil or b == nil then return a == b end
        return addr(a) ~= 0 and addr(a) == addr(b)
    end

    ------------------------------------------------------------------- squads and owners

    local function worldGroups()
        local list = {}
        pcall(function()
            local arr = FindFirstOf("MistWorldDataHolder").Data.PlayerCombatGroups
            for i = 1, arrLen(arr) do
                local g = arrGet(arr, i)
                if valid(g) then list[#list + 1] = g end
            end
        end)
        return list
    end

    local function groupKey(g)
        local s = nil
        pcall(function() s = guidStr(g.Actor.PersistentGuid) end)
        return s
    end

    local function groupName(g)
        local n = "?"
        pcall(function() n = g.CombatGroupName.CustomName:ToString() end)
        if n == "" then n = "(unnamed)" end
        return n
    end

    local function groupByGuid(guid)
        local key = guidStr(guid)
        for _, g in ipairs(worldGroups()) do
            if groupKey(g) == key then return g end
        end
        return nil
    end

    local function raisedCount(g)
        local n = 0
        pcall(function() n = arrLen(g.Combatants) end)
        return n
    end

    local creators = {} -- squad GUID -> creator name, for squads nobody has joined yet

    -- Owner name, or nil when open to everyone.
    local function squadOwner(g)
        local counts, seen = {}, {}
        local function tally(arr)
            for i = 1, arrLen(arr) do
                local npc = arrGet(arr, i)
                local a = addr(npc)
                if a ~= 0 and not seen[a] then
                    seen[a] = true
                    local v = nil
                    pcall(function() v = npc.Settlement.Actor end)
                    local o = valid(v) and core.villageOwner(v) or nil
                    if o then counts[o] = (counts[o] or 0) + 1 end
                end
            end
        end
        pcall(function() tally(g.Combatants) end)
        pcall(function() tally(g.AssignedCombatants) end)
        local best, bestN = nil, 0
        for name, n in pairs(counts) do
            if n > bestN or (n == bestN and best and name < best) then best, bestN = name, n end
        end
        if best then return best end
        local key = groupKey(g)
        return key and creators[key] or nil
    end

    local function owns(name, g)
        local o = squadOwner(g)
        return o == nil or o == name, o
    end

    ------------------------------------------------------------------- players

    local function players()
        local list = {}
        for _, pc in ipairs(FindAllOf("MistOasisPlayerController") or {}) do
            local info = playerInfo(pc)
            if info then
                pcall(function() info.cmd = pc.Pawn.CommandComponent end)
                if valid(info.cmd) then list[#list + 1] = info end
            end
        end
        return list
    end

    local function commanded(info)
        local g = nil
        pcall(function() g = info.cmd.CommandedCombatGroup end)
        if valid(g) then return g end
        return nil
    end

    local function setCommanded(info, g, why)
        if not ready() then return false end
        local ok, done = pcall(BWNative_SetCommandedGroup, addr(info.cmd), g and addr(g) or 0)
        if ok and done then
            log(string.format("SQUAD %s now commands %s (%s)", info.name, g and groupName(g) or "nothing", why))
            return true
        end
        log(string.format("SQUAD could not change what %s commands: %s", info.name, tostring(done)))
        return false
    end

    -- A squad of the player's own that has soldiers up, if any.
    local function ownRaisedSquad(info)
        for _, g in ipairs(worldGroups()) do
            if raisedCount(g) > 0 and squadOwner(g) == info.name then return g end
        end
        return nil
    end

    ------------------------------------------------------------------- undoing hand-outs

    local snapshot = nil

    local function takeSnapshot(req)
        snapshot = { req = req and req.name or "?", list = {} }
        for _, p in ipairs(players()) do
            snapshot.list[#snapshot.list + 1] = { info = p, group = commanded(p) }
        end
    end

    -- After a squad request: anyone handed a squad that isn't theirs gets their previous one back
    -- (if it still has soldiers and is theirs), else none. A squad the requester picked on purpose
    -- (select for control; friends can only pick their own or open squads) stays.
    local function restoreAfter(path)
        local snap = snapshot
        snapshot = nil
        if not snap then return end
        local picked = path:find("ServerSelectForControlCombatGroup", 1, true) ~= nil
        for _, e in ipairs(snap.list) do
            local now = commanded(e.info)
            if now and not same(now, e.group) and not owns(e.info.name, now)
                and not (picked and e.info.name == snap.req) then
                local back = e.group
                if back and not (valid(back) and raisedCount(back) > 0 and owns(e.info.name, back)) then back = nil end
                setCommanded(e.info, back, "handed " .. groupName(now) .. " by " .. fnName(path) .. " from " .. snap.req)
            end
        end
    end

    -- Everyone, host included: other game paths (hiring, raids, a squad emptying) hand squads around,
    -- and a squad handed out earlier changes owner when its villagers move village (2026-10-11: the
    -- host kept a friend's recruit squad after the recruit was transferred to that friend's village).
    local function watchdog()
        for _, p in ipairs(players()) do
            local g = commanded(p)
            if g then
                local mine, owner = owns(p.name, g)
                if not mine then
                    setCommanded(p, ownRaisedSquad(p), "watchdog: " .. groupName(g) .. " belongs to " .. owner)
                end
            end
        end
    end

    ------------------------------------------------------------------- guards

    local function refuseSquad(path, req, g, owner)
        local what = string.format("%s by %s on squad %s (owner %s)", fnName(path), req.name, groupName(g), owner)
        local m = core.mode()
        if m == "dryrun" then
            log("WOULD BLOCK " .. what)
            return
        end
        if m == "enforce" and skipCall(path) then
            log("BLOCKED " .. what)
            tell(req, "That squad belongs to " .. owner .. ". Only they can command it.")
            return
        end
        log("WARNED " .. what)
        tell(req, "That squad belongs to " .. owner .. ". Please leave it to them.")
    end

    local hooks = 0

    -- pre(ctx, args) and post(ctx, args) are both optional; errors are logged, never thrown.
    local function hook(path, pre, post)
        local function wrap(fn, label)
            return function(ctx, ...)
                if core.mode() == "off" then return end
                local args = { ... }
                local ok, e = pcall(fn, ctx, args)
                if not ok then log("squad " .. label .. " error in " .. fnName(path) .. ": " .. tostring(e)) end
            end
        end
        local ok, err = pcall(function()
            if post then
                RegisterHook(path, wrap(pre or function() end, "pre"), wrap(post, "post"))
            else
                RegisterHook(path, wrap(pre, "pre"))
            end
        end)
        if ok then hooks = hooks + 1 else log("FAILED to hook " .. path .. ": " .. tostring(err)) end
    end

    local okList, lists = pcall(dofile, core.modDir .. "\\Scripts\\squad_rpcs.lua")
    if not (okList and type(lists) == "table") then
        log("could not load squad_rpcs.lua: " .. tostring(lists))
        lists = { squads = {}, command = {}, other = {} }
    end

    -- Orders given through the requester's own command component: to the squad they command.
    for _, path in ipairs(lists.command) do
        hook(path, function(ctx, args)
            local req = requester(ctx)
            if req == nil or req.isHost then return end
            local g = nil
            pcall(function() g = ctx:get().CommandedCombatGroup end)
            if valid(g) then
                local mine, owner = owns(req.name, g)
                if not mine then refuseSquad(path, req, g, owner) end
            end
        end)
    end

    -- Default squads. The game keeps one squad of each kind for the whole faction and fills it
    -- whoever asks: new hires (0x1EC, "Newcomers"), call to arms (0x1ED, "Reservists", filled by
    -- "Mobilize companions") and common (0x1EE, "Common", where new companions go). Each lookup
    -- (AMistCombatGroup::GetOrCreate*) takes the first squad carrying its flag, else makes one. While
    -- the matching request runs, other owners' squads are hidden from that lookup, so the game picks
    -- or makes one of the requester's own; everything is put back when the request ends.
    --   call to arms (ServerMobilizeReservists): first squad with 0x1ED -> clear it on others' squads.
    --   new hires (RecruitNpc -> AMistTownNpc::Hire): first squad with 0x1EC -> clear it likewise.
    --   companion (ServerMakeNpcSoldier -> GetOrCreateCombatGroupForManuallySwitchedNpc): first an
    --     UNFLAGGED squad whose roster already lists the villager, then the first squad with 0x1EE.
    --     Others' common squads lose 0x1EE but get 0x1EC for the call, so neither step takes them
    --     (an unflagged shared Newcomers would otherwise count as the villager's own squad).
    local FLAGS = { { off = 0x1EC, name = "new-hires" }, { off = 0x1ED, name = "call-to-arms" }, { off = 0x1EE, name = "common" } }

    local function getFlag(g, off)
        if type(BWNative_GetSquadFlag) == "function" then return BWNative_GetSquadFlag(addr(g), off) == true end
        if off == 0x1ED and type(BWNative_GetCallToArms) == "function" then return BWNative_GetCallToArms(addr(g)) == true end
        return false
    end

    local function setFlag(g, off, on)
        if type(BWNative_SetSquadFlag) == "function" then return BWNative_SetSquadFlag(addr(g), off, on) end
        if off == 0x1ED and type(BWNative_SetCallToArms) == "function" then return BWNative_SetCallToArms(addr(g), on) end
        return false
    end

    local function flagOf(g)
        for _, f in ipairs(FLAGS) do
            if getFlag(g, f.off) then return f end
        end
        return nil
    end

    local MOBILIZE = "/Script/Mist.MistDataBrokerPlayerComponent:ServerMobilizeReservists"
    local MAKE_COMPANION = "/Script/Mist.MistDataBrokerPlayerComponent:ServerMakeNpcSoldier"
    local RECRUIT = "/Script/Mist.MistBlueprintLibrary:RecruitNpc"

    local changes = nil -- flag changes to undo: { g, off, was }

    local function change(g, off, on)
        local was = getFlag(g, off)
        if was ~= on then
            setFlag(g, off, on)
            changes[#changes + 1] = { g = g, off = off, was = was }
        end
    end

    local function setAsideFor(req, path)
        changes = {}
        if req == nil or not ready() then return end
        local ccLookup = path == MOBILIZE and 0x1ED or path == RECRUIT and 0x1EC or nil
        local companion = path == MAKE_COMPANION
        if not ccLookup and not companion then return end
        for _, g in ipairs(worldGroups()) do
            local o = squadOwner(g)
            if o ~= nil and o ~= req.name then
                if ccLookup and getFlag(g, ccLookup) then
                    change(g, ccLookup, false)
                elseif companion and getFlag(g, 0x1EE) then
                    change(g, 0x1EE, false)
                    if not getFlag(g, 0x1ED) then change(g, 0x1EC, true) end
                end
            end
        end
    end

    local function putBack()
        if not changes then return end
        for i = #changes, 1, -1 do
            local e = changes[i]
            if valid(e.g) then setFlag(e.g, e.off, e.was) end
        end
        changes = nil
    end

    local function beginRequest(req, path)
        takeSnapshot(req)
        setAsideFor(req, path)
    end

    local function endRequest(path)
        putBack()
        restoreAfter(path)
    end

    -- Requests naming a squad: only its owner (or the host).
    for _, entry in ipairs(lists.squads) do
        local path, idx = entry[1], entry[2]
        hook(path, function(ctx, args)
            local req = requester(ctx)
            beginRequest(req, path)
            if req == nil or req.isHost or core.justBlocked() == path then return end
            local g = args[idx] and groupByGuid(args[idx]:get())
            if g then
                local mine, owner = owns(req.name, g)
                if not mine then refuseSquad(path, req, g, owner) end
            end
        end, function(ctx, args) endRequest(path) end)
    end

    -- Call to arms for someone else's village. The G hotkey's call-to-arms screen always shows the
    -- host's main village (AMistOasisPlayerController::ToggleSettlementCallToArmsScreen uses
    -- GetPlayerSettlementData), so a friend's mobilize/dismiss from it names the host's village. Instead of
    -- blocking it, the mod skips it and sends the same request for the friend's own village (the one
    -- nearest to them). With no village of their own it is blocked.
    local DISMISS = "/Script/Mist.MistDataBrokerPlayerComponent:ServerDismissReservists"
    local redirect = nil

    local function redirectCallToArms(path, ctx, args, req)
        if req == nil or req.isHost or not args[1] then return false end
        local v = core.villageOfGuid(args[1]:get())
        if not v then return false end
        local o = core.villageOwner(v)
        if o == nil or o == req.name then return false end
        local x, y = 0, 0
        pcall(function() local l = core.locationOf(req.pc.Pawn); x, y = l.X, l.Y end)
        local target = core.nearestOwnedVillage(req.name, x, y)
        if not target then
            core.refuse(path, req, v, o)
            return true
        end
        if not skipCall(path) then
            core.refuse(path, req, v, o)
            return true
        end
        local isGuard = false
        pcall(function() isGuard = args[2]:get() == true end)
        redirect = { comp = ctx:get(), target = target, isGuard = isGuard, path = path }
        local label = core.villageLabel(target)
        log(string.format("REDIRECT %s by %s: %s -> %s", fnName(path), req.name, core.villageLabel(v), label))
        tell(req, (path == MOBILIZE and "Call to arms: mobilizing " or "Call to arms: dismissing ") .. label .. ".")
        return true
    end

    -- Squad requests without a squad parameter (mobilize, make companion, create squad, ...).
    local CREATE = "/Script/Mist.MistDataBrokerPlayerComponent:ServerCreateCombatGroup"
    local before = nil
    for _, path in ipairs(lists.other) do
        hook(path, function(ctx, args)
            local req = requester(ctx)
            -- Refused by a village guard (mobilize/dismiss are guarded here, not there): change nothing.
            if path ~= MOBILIZE and path ~= DISMISS and core.justBlocked() == path then req = nil end
            if (path == MOBILIZE or path == DISMISS) and redirectCallToArms(path, ctx, args, req) then
                req = nil -- skipped: the redirected request does the work
            end
            beginRequest(req, path)
            if path == CREATE then
                before = {}
                for _, g in ipairs(worldGroups()) do before[addr(g)] = true end
            end
            if path == MOBILIZE and req then
                log("MOBILIZE by " .. req.name .. (#changes > 0 and string.format(" (%d other squads set aside)", #changes) or ""))
            end
        end, function(ctx, args)
            if path == CREATE and before then
                local req = requester(ctx)
                for _, g in ipairs(worldGroups()) do
                    if not before[addr(g)] and req then
                        local key = groupKey(g)
                        if key then
                            creators[key] = req.name
                            log("SQUAD " .. groupName(g) .. " created by " .. req.name)
                        end
                    end
                end
                before = nil
            end
            endRequest(path)
            if redirect and redirect.path == path then
                -- Sent on the next game tick, outside this hook, so it runs through the hooks normally.
                local r = redirect
                redirect = nil
                local function send()
                    local ok, err = pcall(function()
                        if path == MOBILIZE then
                            r.comp:ServerMobilizeReservists(r.target.PersistentGuid, r.isGuard)
                        else
                            r.comp:ServerDismissReservists(r.target.PersistentGuid)
                        end
                    end)
                    if not ok then log("REDIRECT failed: " .. tostring(err)) end
                end
                if not pcall(ExecuteInGameThread, send) then log("REDIRECT could not be scheduled") end
            end
        end)
    end

    -- Recruiting an NPC (dialogue): the recruit joins the new-hires squad of the recruiting player.
    -- The game registers it in the main settlement; a friend's recruit moves to their own village next
    -- tick (not inside the game's call), and then they command its squad, as the game does for the host.
    hook(RECRUIT, function(ctx, args)
        local req = nil
        pcall(function() req = playerInfo(args[1]:get().Controller) end)
        beginRequest(req, RECRUIT)
    end, function(ctx, args)
        endRequest(RECRUIT)
        local req, npc = nil, nil
        pcall(function() req = playerInfo(args[1]:get().Controller) end)
        pcall(function() npc = args[2]:get() end)
        if req == nil or req.isHost or not valid(npc) or type(core.homeRecruit) ~= "function" then return end
        local name = req.name
        local scheduled = pcall(ExecuteInGameThread, function()
            local ok, e = pcall(function()
                if not core.homeRecruit(name, npc) then return end
                watchdog()
                for _, p in ipairs(players()) do
                    if p.name == name and commanded(p) == nil then
                        local g = ownRaisedSquad(p)
                        if g then setCommanded(p, g, "their recruit") end
                    end
                end
            end)
            if not ok then log("RECRUIT error: " .. tostring(e)) end
        end)
        if not scheduled then log("RECRUIT move could not be scheduled") end
    end)

    ------------------------------------------------------------------- names

    -- Every player sees every raised squad in the HUD squad list (it reads the shared world data;
    -- hiding others' squads needs the client mod), so squads carry their owner's name like villages
    -- do: "Companions [Ann]". Renamed through the game's own request so it syncs.
    local renameFailed = {}

    local function baseSquadName(n)
        return (n:gsub("%s*%[[^%]]*%]%s*$", ""))
    end

    local function nameSquads()
        if not core.tagsOn() then return end
        local db = nil
        pcall(function() db = core.hostController().DataBrokerComponent end)
        if not valid(db) then return end
        for _, g in ipairs(worldGroups()) do
            local key = groupKey(g)
            local o = squadOwner(g)
            local raw = groupName(g)
            if key and o and not renameFailed[key] and raw ~= "(unnamed)" and raw ~= "?" then
                local want = baseSquadName(raw) .. " [" .. o .. "]"
                if want ~= raw then
                    local ok, err = pcall(function()
                        local ref = g.CombatGroupName.ObjectReferenceGuid
                        db:ServerRenameCombatGroup(g.Actor.PersistentGuid, {
                            ObjectReferenceGuid = { A = ref.A, B = ref.B, C = ref.C, D = ref.D },
                            CustomName = FText(want),
                        })
                    end)
                    if ok and groupName(g) == want then
                        log("SQUAD rename " .. raw .. " -> " .. want)
                    else
                        renameFailed[key] = true
                        log("SQUAD rename failed for " .. raw .. ": " .. tostring(err))
                    end
                end
            end
        end
    end

    -- Watchdog, on the game thread (UE4SS engine-tick timer).
    local watchdogOn = false
    if type(LoopInGameThreadWithDelay) == "function" then
        local ok, e = pcall(LoopInGameThreadWithDelay, 2000, function()
            if core.mode() ~= "off" and ready() then
                local ok2, e2 = pcall(watchdog)
                if not ok2 then log("squad watchdog error: " .. tostring(e2)) end
                ok2, e2 = pcall(nameSquads)
                if not ok2 then log("squad names error: " .. tostring(e2)) end
            end
        end)
        watchdogOn = ok
        if not ok then log("squad watchdog not started: " .. tostring(e)) end
    end

    log(string.format("squads: %d hooks, game calls %s, squad flags %s, watchdog %s", hooks,
        ready() and "ready" or "NOT ready", type(BWNative_SetSquadFlag) == "function" and "all" or "call-to-arms only",
        watchdogOn and "on" or "off"))

    ------------------------------------------------------------------- reports and split

    -- Roster members by village owner: owner -> list of npc data ("(none)" for unowned villages).
    local function membersByOwner(g)
        local by, seen = {}, {}
        local function add(arr)
            for i = 1, arrLen(arr) do
                local npc = arrGet(arr, i)
                local a = addr(npc)
                if a ~= 0 and not seen[a] then
                    seen[a] = true
                    local v = nil
                    pcall(function() v = npc.Settlement.Actor end)
                    local o = valid(v) and core.villageOwner(v) or "(none)"
                    by[o] = by[o] or {}
                    table.insert(by[o], npc)
                end
            end
        end
        pcall(function() add(g.AssignedCombatants) end)
        pcall(function() add(g.Combatants) end)
        return by
    end

    local function isRaisedMember(g, npc)
        local found = false
        pcall(function()
            for i = 1, arrLen(g.Combatants) do
                if same(arrGet(g.Combatants, i), npc) then found = true end
            end
        end)
        return found
    end

    -- A squad of owner o with default flag f (or, with no flag, any squad o created), else a new one.
    local function squadFor(o, f, db, say)
        for _, g in ipairs(worldGroups()) do
            local gf = flagOf(g)
            if squadOwner(g) == o and ((f and gf and gf.off == f.off) or (not f and not gf)) then return g end
        end
        local had = {}
        for _, g in ipairs(worldGroups()) do had[addr(g)] = true end
        db:ServerCreateCombatGroup()
        for _, g in ipairs(worldGroups()) do
            if not had[addr(g)] then
                local key = groupKey(g)
                if key then creators[key] = o end
                if f then setFlag(g, f.off, true) end
                say(string.format("  new squad %s for %s%s", groupName(g), o, f and (" (" .. f.name .. ")") or ""))
                return g
            end
        end
        return nil
    end

    -- Move each player's people out of squads owned by someone else into a squad of their own of
    -- the same kind: add to its roster, then take them off the other one (a roster can list a
    -- villager in several squads, AMistCombatGroup::AddAssignedCombatant). Safe to run again.
    local function split(say)
        if not ready() then say("squads split: needs the add-on's game calls"); return 0 end
        local db = nil
        pcall(function() db = core.hostController().DataBrokerComponent end)
        if not valid(db) then say("squads split: no host"); return 0 end
        local moved, skipped = 0, 0
        for _, g in ipairs(worldGroups()) do
            local owner = squadOwner(g)
            for o, list in pairs(membersByOwner(g)) do
                if o ~= "(none)" and o ~= owner then
                    local target = squadFor(o, flagOf(g), db, say)
                    if target then
                        for _, npc in ipairs(list) do
                            if isRaisedMember(g, npc) then
                                skipped = skipped + 1
                            else
                                local ok, e = pcall(function()
                                    db:ServerAssignNpcToCombatGroupReserve(target.Actor.PersistentGuid, npc.NpcActor.PersistentGuid)
                                    db:ServerRemoveAssignedNpcFromCombatGroup(g.Actor.PersistentGuid, npc.NpcActor.PersistentGuid)
                                end)
                                if ok then moved = moved + 1 else say("  move failed: " .. tostring(e)) end
                            end
                        end
                        say(string.format("  %s: %d of %s's people -> %s", groupName(g), #list, o, groupName(target)))
                    end
                end
            end
        end
        log(string.format("SQUAD split: %d moved, %d raised ones left (dismiss first)", moved, skipped))
        say(string.format("squads split: %d moved, %d raised ones left where they are (dismiss them first)", moved, skipped))
        return moved
    end

    return {
        report = function(say)
            for _, g in ipairs(worldGroups()) do
                local f = flagOf(g)
                local roster = 0
                pcall(function() roster = arrLen(g.AssignedCombatants) end)
                local parts = {}
                for o, list in pairs(membersByOwner(g)) do parts[#parts + 1] = o .. " " .. #list end
                table.sort(parts)
                say(string.format("  squad %-16s %s owner=%s raised=%d roster=%d%s people: %s", groupName(g),
                    (groupKey(g) or "?"):sub(1, 8), squadOwner(g) or "(open)", raisedCount(g), roster,
                    f and (" " .. f.name) or "", #parts > 0 and table.concat(parts, ", ") or "-"))
            end
            for _, p in ipairs(players()) do
                local g = commanded(p)
                say(string.format("  player %s commands: %s", p.name, g and groupName(g) or "nothing"))
            end
        end,
        split = split,
    }
end
