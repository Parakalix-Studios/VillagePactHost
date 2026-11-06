-- BWCoop balance settings (loaded by main.lua, host only; 0.7.12, 2026-10-14).
--
-- 2026-10-14: the host sets these per world; every world starts at the game's own values, and changing one
-- needs no Workshop update. Values are kept in the owners file (balance lines) and applied on the host after every
-- load (nothing here is saved by the game). Where each value lives: research/logistics-levers-2026-10-13.md.
--
--   carts    space per caravan cart (game: 50; a log takes 9). NpcConfig CaravanPartyCapacity.PerCart (planning,
--            auto-send) + each cart's containers' MaxVolume (what physically fits). Neutral trader caravans use
--            PerCart too. Friends' route screens keep showing the game's numbers (the "expected delivery" preview
--            multiplies carts by a fixed 50 in the game's code); the host decides what actually moves.
--   storage  storage capacity multiplier (game: 1): MaxVolume of every storage building, from its own base value.
--            Not below 1: lowering capacity under what is stored is untested.
--   hiring   hiring renown cost multiplier (game: 1): the game's own recruitment cost multiplier (cheat function,
--            called on the host's cheat component).
--   roads    road speed bonus (game: 1.2): SpeedMultiplier of the road nav areas (highway, path, player-built road),
--            replicated to everyone through each character's road speed.
--   carry    villager carry size multiplier (game: 1): the game's own carrying capacity multiplier (cheat function).

return function(core)
    local log, valid = core.log, core.valid
    local M = {}

    local SETTINGS = {
        carts = { label = "cart space", game = 50, min = 10, max = 5000, whole = true },
        storage = { label = "storage capacity", game = 1, min = 1, max = 100, mult = true },
        hiring = { label = "hiring renown cost", game = 1, min = 0, max = 10, mult = true },
        roads = { label = "road speed bonus", game = 1.2, min = 1, max = 5 },
        carry = { label = "villager carry size", game = 1, min = 1, max = 10, mult = true },
    }
    local ORDER = { "carts", "storage", "hiring", "roads", "carry" }
    local NPC_CONFIG = "/Game/Mist/Data/Configs/NpcConfig.NpcConfig"
    local ROAD_AREAS = {
        "/Game/Mist/Logic/Navigation/NavArea_Highway.Default__NavArea_Highway_C",
        "/Game/Mist/Logic/Navigation/NavArea_Path.Default__NavArea_Path_C",
        "/Game/Mist/Logic/Navigation/NavArea_PlayerBuiltDirtRoad.Default__NavArea_PlayerBuiltDirtRoad_C",
    }
    local SETTLE = 20 -- s after a load before applying (the world's objects are in place by then)

    -- Game values as first seen, so "default" can put them back: object full name -> number.
    local base = {}
    local function fullName(o)
        local ok, s = pcall(function() return o:GetFullName() end)
        return ok and s or nil
    end
    local function setNumber(o, prop, want, key)
        local cur = nil
        pcall(function() cur = o[prop] end)
        if type(cur) ~= "number" then return false end
        key = key or ((fullName(o) or "?") .. "." .. prop)
        if base[key] == nil then base[key] = cur end
        local target = want
        if target == nil then target = base[key] end
        if math.abs(cur - target) < 1e-6 then return false end
        local ok = pcall(function() o[prop] = target end)
        return ok
    end

    local function value(key)
        local v = core.values()[key]
        return type(v) == "number" and v or nil
    end

    local function applyCarts()
        local n = value("carts")
        local cfg = StaticFindObject(NPC_CONFIG)
        if valid(cfg) then
            -- the whole struct is assigned (a field written through a struct copy might not reach the object)
            pcall(function()
                local cap = cfg.CaravanPartyCapacity
                local npc, cur, animal = cap.PerNpc, cap.PerCart, cap.PerAnimalCart
                local key = NPC_CONFIG .. ".PerCart"
                if base[key] == nil then base[key] = cur end
                local want = n or base[key]
                if cur ~= want then
                    cfg.CaravanPartyCapacity = { PerNpc = npc, PerCart = want, PerAnimalCart = animal }
                end
            end)
        end
        for _, cart in ipairs(FindAllOf("MistCaravanCart") or {}) do
            pcall(function()
                local name = fullName(cart) or "?"
                pcall(function() setNumber(cart.CartContainer, "MaxVolume", n, name .. ".CartContainer") end)
                pcall(function()
                    setNumber(cart.InteractableInventoryComponent.InstanceContainer, "MaxVolume", n, name .. ".Inventory")
                end)
            end)
        end
    end

    local function applyStorage()
        local m = value("storage")
        -- containers found by caravans.lua (the access point's own pointer is empty on the host, 2026-10-14)
        for _, s in ipairs(core.storages and core.storages() or {}) do
            pcall(function()
                local c = s.container
                if not valid(c) then return end
                local key = fullName(c)
                if not key then return end
                key = key .. ".MaxVolume"
                local cur = c.MaxVolume
                if type(cur) ~= "number" then return end
                if base[key] == nil then base[key] = cur end
                local want = m and math.floor(base[key] * m + 0.5) or base[key]
                if cur ~= want then c.MaxVolume = want end
            end)
        end
    end

    local function applyRoads()
        local r = value("roads")
        for _, path in ipairs(ROAD_AREAS) do
            local cdo = StaticFindObject(path)
            if valid(cdo) then setNumber(cdo, "SpeedMultiplier", r, path) end
        end
    end

    -- The two cheat multipliers live on the game state (not saved): set once per load and on every change.
    local cheatsSet = {}
    local function applyCheat(key, fn)
        -- never set in this world and not asked for: leave the game alone
        if value(key) == nil and cheatsSet[key] == nil then return end
        local v = value(key) or 1
        if cheatsSet[key] == v then return end
        local cc = nil
        pcall(function() cc = core.hostController().CheatingComponent end)
        if not valid(cc) then return end
        local ok, err = pcall(function() cc[fn](cc, v) end)
        if ok then
            cheatsSet[key] = v
            if v ~= 1 or value(key) ~= nil then log(string.format("BALANCE %s x%g (%s)", key, v, fn)) end
        else
            log("BALANCE " .. key .. " failed: " .. tostring(err))
        end
    end

    -- Midnight deliveries (2026-10-14: a host option, off by default): the game's old instant daily deliveries
    -- between player villages, switched by the console variable mist.LegacyDeliveries (not a cheat variable; read at
    -- each new day and when the village screen opens). Stored as balance value "deliveries" (1 on). Friends see the
    -- Deliveries tab only when their own game has the variable on too (the client mod's part).
    local deliveriesSet = nil
    local function applyDeliveries()
        local on = value("deliveries") == 1
        if value("deliveries") == nil and deliveriesSet == nil then return end
        if deliveriesSet == on then return end
        local ok, err = pcall(function()
            local lib = StaticFindObject("/Script/Engine.Default__KismetSystemLibrary")
            local pc = core.hostController()
            lib:ExecuteConsoleCommand(pc, "mist.LegacyDeliveries " .. (on and "1" or "0"), pc)
        end)
        if ok then
            deliveriesSet = on
            log("BALANCE midnight deliveries " .. (on and "on" or "off"))
        else
            log("BALANCE midnight deliveries failed: " .. tostring(err))
        end
    end

    local world = nil
    -- Called every 10 s by main.lua (and right after a change): applies every setting to what exists now.
    function M.apply()
        local holder = FindFirstOf("MistWorldDataHolder")
        if not valid(holder) then world = nil; return end
        local key = holder:GetAddress()
        if not world or world.key ~= key then
            world, cheatsSet = { key = key, t = os.time() }, {}
            return
        end
        if os.time() - world.t < SETTLE then return end
        applyCarts()
        applyStorage()
        applyRoads()
        applyCheat("hiring", "ServerSetNpcRecruitmentRenownMultiplier")
        applyCheat("carry", "ServerSetNpcCarryingCapacityMultiplier")
        applyDeliveries()
    end

    -- bwcoop deliveries [on|off]
    function M.deliveries(say, arg)
        local a = arg:lower()
        if a == "" then
            return say("midnight deliveries: " .. (value("deliveries") == 1 and "on" or "off") ..
                " (bwcoop deliveries on|off; orders are set in a village's Deliveries tab)")
        end
        if a ~= "on" and a ~= "off" then return say("usage: bwcoop deliveries on|off") end
        core.setValue("deliveries", a == "on" and 1 or nil)
        M.applyNow()
        say("midnight deliveries " .. a .. (a == "on" and
            ": each night villages receive their delivery orders instantly (up to 20 items per resident a day)" or ""))
    end

    local function show(key)
        local s = SETTINGS[key]
        local v = value(key)
        local shown = v and ((s.mult and "x" or "") .. string.format("%g", v)) or
            ((s.mult and "x" or "") .. string.format("%g", s.game) .. " (game)")
        return string.format("  %-8s %-20s %s", key, s.label, shown)
    end

    -- bwcoop balance [<setting> <value>|default]
    function M.command(say, arg)
        local key, rest = arg:lower():match("^(%S*)%s*(.-)%s*$")
        if key == "" then
            say("balance (this world; the game's own values until set):")
            for _, k in ipairs(ORDER) do say(show(k)) end
            say("  set: bwcoop balance carts 250 | storage x3 | hiring x0.5 | roads 1.5 | carry x2 | <setting> default")
            return
        end
        local s = SETTINGS[key]
        if not s then return say("balance: unknown setting " .. key .. " (carts, storage, hiring, roads, carry)") end
        if rest == "" then return say(show(key)) end
        if rest == "default" then
            core.setValue(key, nil)
            M.applyNow()
            return say(string.format("%s back to the game's %s%g", s.label, s.mult and "x" or "", s.game))
        end
        local n = tonumber((rest:gsub("^x", "")))
        if not n then return say("balance: " .. key .. " needs a number, e.g. " .. (s.mult and "x2" or tostring(s.game * 2))) end
        if s.whole then n = math.floor(n + 0.5) end
        if n < s.min or n > s.max then
            return say(string.format("balance: %s from %g to %g", key, s.min, s.max))
        end
        core.setValue(key, n)
        M.applyNow()
        say(string.format("%s now %s%g (game %s%g)", s.label, s.mult and "x" or "", n, s.mult and "x" or "", s.game))
        log(string.format("BALANCE set %s = %g", key, n))
    end

    -- Apply at once after a change (skips the settle wait when the world is already running).
    function M.applyNow()
        if world then world.t = os.time() - SETTLE end
        M.apply()
    end

    return M
end
