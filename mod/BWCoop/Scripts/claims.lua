-- BWCoop land claims (loaded by main.lua, host only). Rule, decided 2026-10-12:
--
--   * Land belongs to the village that claimed it first. A building claims the unclaimed land
--     within 100 m of it (a town hall: the unclaimed part of its influence circle). Claimed land
--     stays with its village while that village still reaches it, so borders touch but never
--     cross and no village grows into another's land.
--   * When buildings go, land the village's remaining buildings still reach stays; the rest is
--     released at once and goes to a village that reaches it, else it becomes free.
--   * Contested land (released land reached by several villages; overlaps on the first load of an
--     existing world) goes by priority: the host's villages first, then founding order.
--
-- Claims are kept per 10 m square and saved per save in data\<save>.claims.tsv (runs of squares
-- per row per village). main.lua uses them to decide building (guards), which village a new
-- building joins, the map dots and the build-mode line (bridge).

return function(core)
    local log, valid, guidStr, arrLen, arrGet = core.log, core.valid, core.guidStr, core.arrLen, core.arrGet
    local CELL = 1000                -- cm: claims are kept per 10 m square
    local OFF, SHIFT = 1048576, 2097152
    local FULL_EVERY = 30            -- s: recompute even when no village's building count changed

    local function key(cx, cy) return (cx + OFF) * SHIFT + (cy + OFF) end
    local function unkey(k) return k // SHIFT - OFF, k % SHIFT - OFF end
    local function cellOf(x, y) return math.floor(x / CELL), math.floor(y / CELL) end

    local M = { version = 0 }
    local claims = {}     -- square key -> village key (GUID string)
    local heights = {}    -- square key -> z of a building that reaches it (map dots)
    local villages = {}   -- village key -> village actor, from the last update
    local loadedFor = nil -- save name the claims belong to
    local fresh = false   -- no claims file yet: the first update claims today's land by priority
    local lastSig, lastFull = nil, 0
    local worldKey, worldSince = nil, 0
    local SETTLE = 20                -- s after a world loads before claims are taken (villages load gradually)

    local function path(name)
        return (core.dataPath(name):gsub("%.tsv$", ".claims.tsv"))
    end

    function M.load(name)
        claims, heights, villages, loadedFor, lastSig = {}, {}, {}, name, nil
        local f = io.open(path(name), "r")
        if not f then
            fresh = true
            log("claims: none saved for \"" .. name .. "\" yet; the first update claims today's land by priority")
            return
        end
        fresh = false
        local cur, n = nil, 0
        for line in f:lines() do
            local tag, a, b, c = line:match("^(%a+)\t([^\t]*)\t?([^\t]*)\t?([^\t]*)$")
            if tag == "village" and a ~= "" then
                cur = a
            elseif tag == "run" and cur then
                local cy, x0, x1 = tonumber(a), tonumber(b), tonumber(c)
                if cy and x0 and x1 then
                    for cx = x0, x1 do
                        claims[key(cx, cy)] = cur
                        n = n + 1
                    end
                end
            end
        end
        f:close()
        log(string.format("claims: %d squares loaded for \"%s\"", n, name))
    end

    -- Per village: rows (cy -> sorted list of cx).
    local function rowsByVillage()
        local byV = {}
        for k, vk in pairs(claims) do
            local cx, cy = unkey(k)
            local rows = byV[vk]
            if not rows then rows = {}; byV[vk] = rows end
            local r = rows[cy]
            if not r then r = {}; rows[cy] = r end
            r[#r + 1] = cx
        end
        return byV
    end

    -- Calls fn(vk, cy, x0, x1) for every run of consecutive squares.
    local function eachRun(fn)
        for vk, rows in pairs(rowsByVillage()) do
            local ys = {}
            for cy in pairs(rows) do ys[#ys + 1] = cy end
            table.sort(ys)
            for _, cy in ipairs(ys) do
                local xs = rows[cy]
                table.sort(xs)
                local s, p = xs[1], xs[1]
                for i = 2, #xs + 1 do
                    local x = xs[i]
                    if x ~= p + 1 then
                        fn(vk, cy, s, p)
                        s = x
                    end
                    p = x
                end
            end
        end
    end

    function M.save()
        if not loadedFor then return end
        local f = io.open(path(loadedFor), "w")
        if not f then log("claims: could not write " .. path(loadedFor)); return end
        f:write("# BWCoop land claims for save \"" .. loadedFor .. "\": per village, runs of claimed 10 m squares " ..
            "(row, first, last). Edit only while the game is closed.\n")
        local cur = nil
        eachRun(function(vk, cy, x0, x1)
            if vk ~= cur then
                f:write("village\t" .. vk .. "\n")
                cur = vk
            end
            f:write(string.format("run\t%d\t%d\t%d\n", cy, x0, x1))
        end)
        f:close()
    end

    local function structuresOf(v)
        local list = {}
        pcall(function()
            local st = v.Data.Structures
            for i = 1, arrLen(st) do
                pcall(function()
                    local a = arrGet(st, i).PlaceableActor
                    local l = a:K2_GetActorLocation()
                    list[#list + 1] = { l.X, l.Y, l.Z, core.claimRange(a) }
                end)
            end
        end)
        return list
    end

    -- Marks every square whose center lies within r of (x, y), and always the square under (x, y)
    -- itself (a range of 0 claims only the building's own spot); set: square key -> z.
    local function addDisc(set, x, y, z, r)
        local own = key(cellOf(x, y))
        if set[own] == nil then set[own] = z end
        if r <= 0 then return end
        local r2 = r * r
        local x0, x1 = math.floor((x - r) / CELL), math.floor((x + r) / CELL)
        local y0, y1 = math.floor((y - r) / CELL), math.floor((y + r) / CELL)
        for cx = x0, x1 do
            local dx = (cx + 0.5) * CELL - x
            local dx2 = dx * dx
            if dx2 <= r2 then
                for cy = y0, y1 do
                    local dy = (cy + 0.5) * CELL - y
                    if dx2 + dy * dy <= r2 then
                        local k = key(cx, cy)
                        if set[k] == nil then set[k] = z end
                    end
                end
            end
        end
    end

    -- Brings the claims up to date with today's buildings. Cheap when no village's building count
    -- changed (then at most every FULL_EVERY seconds). Returns true when claims changed.
    function M.update()
        local wk = core.worldKey()
        if not wk then return false end
        if wk ~= worldKey then
            worldKey, worldSince, villages, lastSig = wk, os.time(), {}, nil
        end
        if os.time() - worldSince < SETTLE then return false end
        local name = core.saveName()
        if not name then return false end
        if name ~= loadedFor then M.load(name) end
        local list = core.playerVillages()
        local parts = {}
        for _, v in ipairs(list) do
            local n = 0
            pcall(function() n = arrLen(v.Data.Structures) end)
            parts[#parts + 1] = guidStr(v.PersistentGuid) .. "=" .. n
        end
        local sig = table.concat(parts, ",")
        local now = os.time()
        if sig == lastSig and now - lastFull < FULL_EVERY then return false end
        lastSig, lastFull = sig, now

        local reach = {}
        villages = {}
        for _, v in ipairs(list) do
            local vk = guidStr(v.PersistentGuid)
            villages[vk] = v
            local set, seen = {}, {}
            -- per building type range (0.7.2): one disc per square and range, the largest first
            local list = structuresOf(v)
            table.sort(list, function(a, b) return a[4] > b[4] end)
            for _, p in ipairs(list) do
                local k = key(cellOf(p[1], p[2]))
                if p[4] < 0 then
                    -- a neutral building (fast travel sign) claims no land
                elseif seen[k] == nil or p[4] > seen[k] then
                    seen[k] = p[4]
                    addDisc(set, p[1], p[2], p[3], p[4])
                end
            end
            local tx, ty, r, tz = core.townHallArea(v)
            if tx then addDisc(set, tx, ty, tz or 0, r) end
            reach[vk] = set
        end

        local released, claimed = 0, 0
        for k, vk in pairs(claims) do
            if not (reach[vk] and reach[vk][k]) then
                claims[k] = nil
                released = released + 1
            end
        end
        for _, v in ipairs(core.priority(list)) do
            local vk = guidStr(v.PersistentGuid)
            for k in pairs(reach[vk] or {}) do
                if claims[k] == nil then
                    claims[k] = vk
                    claimed = claimed + 1
                end
            end
        end
        heights = {}
        for k, vk in pairs(claims) do heights[k] = reach[vk][k] end

        if released + claimed > 0 or fresh then
            M.version = M.version + 1
            M.save()
            log(string.format("CLAIMS %s%d squares claimed, %d released", fresh and "first claims from today's buildings: " or "",
                claimed, released))
            fresh = false
            return true
        end
        return false
    end

    function M.ready() return loadedFor ~= nil and next(villages) ~= nil end

    -- The village owning the land at (x, y), or nil for free land.
    function M.ownerAt(x, y)
        local vk = claims[key(cellOf(x, y))]
        local v = vk and villages[vk]
        if v and valid(v) then return v end
        return nil
    end

    -- Squares per village key.
    function M.counts()
        local c = {}
        for _, vk in pairs(claims) do c[vk] = (c[vk] or 0) + 1 end
        return c
    end

    -- Map dots: the border squares of each village's land (a neighbor square isn't theirs).
    -- numOf: village key -> village number. Returns { x, y, z, n, ... }.
    function M.edges(numOf)
        local out = {}
        for k, vk in pairs(claims) do
            local n = numOf[vk]
            if n then
                local cx, cy = unkey(k)
                if claims[key(cx + 1, cy)] ~= vk or claims[key(cx - 1, cy)] ~= vk
                    or claims[key(cx, cy + 1)] ~= vk or claims[key(cx, cy - 1)] ~= vk then
                    out[#out + 1], out[#out + 2], out[#out + 3], out[#out + 4] =
                        (cx + 0.5) * CELL, (cy + 0.5) * CELL, math.floor(heights[k] or 0), n
                end
            end
        end
        return out
    end

    -- Build-mode line: runs of claimed squares { row, first, last, 2 * n, ... } (squares of CELL cm;
    -- n = village number, 2 * n = its index into the bridge's Villages array).
    function M.runs(numOf)
        local out = {}
        eachRun(function(vk, cy, x0, x1)
            local n = numOf[vk]
            if n then out[#out + 1], out[#out + 2], out[#out + 3], out[#out + 4] = cy, x0, x1, 2 * n end
        end)
        return out
    end

    -- Every building standing on another village's land: { village, owner village, class, x, y }.
    function M.misplaced(className)
        local out = {}
        for vk, v in pairs(villages) do
            pcall(function()
                local st = v.Data.Structures
                for i = 1, arrLen(st) do
                    pcall(function()
                        local a = arrGet(st, i).PlaceableActor
                        local l = a:K2_GetActorLocation()
                        local ok = claims[key(cellOf(l.X, l.Y))]
                        if ok and ok ~= vk and villages[ok] then
                            out[#out + 1] = { v = v, land = villages[ok], cls = className(a), x = l.X, y = l.Y }
                        end
                    end)
                end
            end)
        end
        return out
    end

    -- Recompute at the next update (claim ranges changed).
    function M.invalidate() lastSig = nil end

    -- Forget the saved claims and claim today's land again by priority (host command).
    function M.reset()
        claims, lastSig, fresh = {}, nil, true
        return M.update()
    end

    M.CELL = CELL
    return M
end
