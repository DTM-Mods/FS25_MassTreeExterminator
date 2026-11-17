--[[
    Mass Tree Exterminator

    Bulldozes every standing tree and every bush in a marked area at once, from the construction screen
    (Shift-P > Landscaping > Mass Tree Exterminator). Each tree costs what the game's own bulldozer (demolition mode)
    charges for it; bushes cost the construction menu's landscaping rate per m2.

    Trees: since patch 1.25.1.0 the demolition brush (ConstructionBrushDestruct) removes non-felled trees for a fee.
    The trees are static, never-cut split shapes (CollisionFlag.TREE, the same test the game's gsTreeCut command uses).
    The server removes them like the stump cutter does (delete(shape)); the engine syncs split shape removal to every
    client. The fee is read from the game at runtime (MassTreeExterminator.resolveFee): a fee/price getter of the
    demolition brush or the tree manager, else a constant, else a fallback. mteInfo logs what was found, mteTrace logs
    what the game's bulldozer does when a tree is removed by hand.

    Bushes: on the base maps they are foliage layers (decoBush, decoBushUS, ...), painted with the construction menu's
    plant brush. They are cleared with a DensityMapModifier on the server (density map writes replicate), only in the
    strips of the area that are the farm's own land.

    Multiplayer: the client sends MassTreeExterminatorRemoveEvent (the area), the server checks permission, land and
    money, removes, charges the farm and answers with MassTreeExterminatorResultEvent. Marking, counting and drawing
    are local.
]]

MassTreeExterminator = {}
local MTE = MassTreeExterminator
local unpack = unpack or table.unpack

--- All return values of a call, nils included: {n = count, ...}
local function pack(...)
    return {n = select("#", ...), ...}
end

MTE.MOD_NAME = g_currentModName
MTE.MAX_SIDE = 1000                 -- m: a longer side is refused (server work)
MTE.PREVIEW_REFRESH_MS = 5000       -- the counts of a marked area are refreshed this often
MTE.RESULT_RECOUNT_MS = 1500        -- and this long after a removal (the removal needs a moment to sync)
MTE.DELETE_PER_FRAME = 100          -- trees the server deletes per frame
MTE.CELL = 2                        -- m: own-land resolution for bushes
MTE.MAX_DRAWN = 3000                -- tree markers drawn at most
MTE.FALLBACK_TREE_FEE = 250         -- per tree, only when the game's fee cannot be found (logged)
MTE.FALLBACK_BUSH_FEE_PER_M2 = 0.5  -- per m2, only when the game's landscaping rate cannot be found (logged)
MTE.BUSH_LAYER_NAMES = {"decoBush", "decoBushUS", "decoBushEU", "decoBushAS"}
MTE.MESSAGE_MS = 5000
MTE.DEBUG = false
MTE.removeBushes = true

-- result reasons (sent back with the result)
MTE.REASON_OK = 0
MTE.REASON_NOTHING = 1
MTE.REASON_NO_MONEY = 2
MTE.REASON_NO_PERMISSION = 3
MTE.REASON_TOO_LARGE = 4
MTE.REASON_INVALID = 5

MTE.corners = {}        -- up to two {x, y, z}
MTE.rect = nil          -- {minX, minZ, maxX, maxZ}
MTE.preview = nil       -- see MTE.refreshPreview
MTE.previewTimer = 0
MTE.recountTimer = nil
MTE.lastMessage = nil   -- {text, isWarning, time}
MTE.jobs = {}           -- server: running removals

--- Can string.format(fmt, ...) format these arguments? Every conversion needs an argument of a fitting type
--- (a translation with a wrong placeholder must not break the message).
local function canFormat(fmt, ...)
    if type(fmt) ~= "string" then
        return false
    end
    local n, i = select("#", ...), 0
    for conversion in string.gmatch(fmt, "%%[%-%+ #0]*%d*%.?%d*(.)") do
        if conversion ~= "%" then
            i = i + 1
            if i > n then
                return false
            end
            local arg = (select(i, ...))
            if string.find("cdiouxXeEfgG", conversion, 1, true) ~= nil then
                if tonumber(arg) == nil then
                    return false
                end
            elseif conversion == "s" or conversion == "q" then
                if type(arg) ~= "string" and type(arg) ~= "number" then
                    return false
                end
            else
                return false
            end
        end
    end
    return true
end
MTE.canFormat = canFormat

local function formatText(fmt, ...)
    if canFormat(fmt, ...) then
        return string.format(fmt, ...)
    end
    return tostring(fmt)
end

local function log(fmt, ...)
    Logging.info("[MassTreeExterminator] " .. formatText(fmt, ...))
end

local function warn(fmt, ...)
    Logging.warning("[MassTreeExterminator] " .. formatText(fmt, ...))
end

local function dbg(fmt, ...)
    if MTE.DEBUG then
        log(fmt, ...)
    end
end
MTE.log, MTE.warn = log, warn

local function text(key, ...)
    local s = g_i18n:getText(key)
    if select("#", ...) > 0 and canFormat(s, ...) then
        return string.format(s, ...)
    end
    return s
end
MTE.text = text

function MTE.formatMoney(amount)
    if g_i18n ~= nil and g_i18n.formatMoney ~= nil and type(amount) == "number" and amount == amount then
        local s = g_i18n:formatMoney(amount, 0, true, true)
        if type(s) == "string" then
            return s
        end
    end
    return string.format("%d", math.floor((amount or 0) + 0.5))
end

---------------------------------------------------------------------------------------------------------------------
-- world helpers
---------------------------------------------------------------------------------------------------------------------
function MTE.getTerrainNode()
    return g_terrainNode or (g_currentMission ~= nil and g_currentMission.terrainRootNode) or nil
end

function MTE.getTerrainHeight(x, z)
    local terrain = MTE.getTerrainNode()
    if terrain ~= nil then
        return getTerrainHeightAtWorldPos(terrain, x, 0, z)
    end
    return 0
end

function MTE.getFarmId()
    if g_localPlayer ~= nil and g_localPlayer.farmId ~= nil then
        return g_localPlayer.farmId
    end
    if g_currentMission ~= nil and g_currentMission.getFarmId ~= nil then
        return g_currentMission:getFarmId()
    end
    return 1
end

--- Is the land at (x, z) the farm's own land?
function MTE.isOwnLand(farmId, x, z)
    local manager = g_farmlandManager
    if manager == nil or type(x) ~= "number" or type(z) ~= "number" then
        return false
    end
    if manager.getOwnerIdAtWorldPosition ~= nil then
        return manager:getOwnerIdAtWorldPosition(x, z) == farmId
    end
    if manager.getIsOwnedByFarmAtWorldPosition ~= nil then
        return manager:getIsOwnedByFarmAtWorldPosition(farmId, x, z) == true
    end
    return false
end

--- Normalised rectangle {minX, minZ, maxX, maxZ} of two corners, or nil when not finite
function MTE.makeRect(x1, z1, x2, z2)
    for _, v in ipairs({x1, z1, x2, z2}) do
        if type(v) ~= "number" or v ~= v or v == math.huge or v == -math.huge then
            return nil
        end
    end
    return {math.min(x1, x2), math.min(z1, z2), math.max(x1, x2), math.max(z1, z2)}
end

function MTE.isRectTooLarge(rect)
    return rect[3] - rect[1] > MTE.MAX_SIDE or rect[4] - rect[2] > MTE.MAX_SIDE
end

---------------------------------------------------------------------------------------------------------------------
-- trees
---------------------------------------------------------------------------------------------------------------------

--- A standing, never-cut tree: the test of the game's gsTreeCut command (TreePlantManager)
function MTE.isStandingTree(shape)
    if shape == nil or shape == 0 or not entityExists(shape) then
        return false
    end
    if not getHasClassId(shape, ClassIds.MESH_SPLIT_SHAPE) then
        return false
    end
    if getSplitType(shape) == 0 then
        return false
    end
    if getRigidBodyType(shape) ~= RigidBodyType.STATIC then
        return false
    end
    return not getIsSplitShapeSplit(shape)
end

function MTE:onTreeOverlap(objectId)
    local hits = MTE.overlapHits
    if hits ~= nil and not hits.seen[objectId] then
        hits.seen[objectId] = true
        if MTE.isStandingTree(objectId) then
            hits.list[#hits.list + 1] = objectId
        end
    end
    -- nil: keep going (all trees in the box)
end

--- All standing trees whose trunk stands in the rectangle: list of {shape=, x=, y=, z=}
function MTE.findTrees(rect)
    local cx, cz = (rect[1] + rect[3]) * 0.5, (rect[2] + rect[4]) * 0.5
    local ex, ez = math.max((rect[3] - rect[1]) * 0.5, 0.1), math.max((rect[4] - rect[2]) * 0.5, 0.1)
    if overlapBox == nil or CollisionFlag == nil or CollisionFlag.TREE == nil then
        warn("overlapBox or CollisionFlag.TREE not available, no trees found")
        return {}
    end
    local cy = MTE.getTerrainHeight(cx, cz)
    MTE.overlapHits = {seen = {}, list = {}}
    -- statics only (trees are static rigid bodies); the trunk position is checked below because the box also hits
    -- crowns reaching into the area
    overlapBox(cx, cy, cz, 0, 0, 0, ex, 500, ez, "onTreeOverlap", MTE, CollisionFlag.TREE, false, false, true, false)
    local hits = MTE.overlapHits
    MTE.overlapHits = nil
    local trees = {}
    for _, shape in ipairs(hits.list) do
        local x, y, z = getWorldTranslation(shape)
        if x >= rect[1] and x <= rect[3] and z >= rect[2] and z <= rect[4] then
            trees[#trees + 1] = {shape = shape, x = x, y = y, z = z}
        end
    end
    return trees
end

--- Server: removes one tree the way the 1.25 stump cutter does (deleteSplitShape). A map tree is a LOD group:
--- LOD0 is the split shape, LOD1 the far model next to it; deleteSplitShape removes the whole tree, a plain delete()
--- of LOD0 left LOD1 standing (seen from the construction camera). Returns true when it was removed.
function MTE.deleteTree(shape)
    if not MTE.isStandingTree(shape) then
        return false
    end
    if deleteSplitShape ~= nil then
        deleteSplitShape(shape)
    else
        delete(shape)
    end
    if g_treePlantManager ~= nil and g_treePlantManager.removingSplitShape ~= nil then
        g_treePlantManager:removingSplitShape(shape)
    end
    return true
end

MTE.STUMP_RADIUS = 1.5          -- m around a removed tree's base searched for a stump left behind
MTE.STUMP_SECOND_PASS_MS = 1000 -- a second search this long after the removal (in case the stump appears later)

function MTE:onStumpOverlap(objectId)
    local hits = MTE.stumpHits
    if hits ~= nil and not hits.seen[objectId] then
        hits.seen[objectId] = true
        if entityExists(objectId) and getHasClassId(objectId, ClassIds.MESH_SPLIT_SHAPE) and getSplitType(objectId) ~= 0
            and getRigidBodyType(objectId) == RigidBodyType.STATIC then
            hits.list[#hits.list + 1] = objectId
        end
    end
end

--- Static wood around a tree's base (the tree itself included): list of shapes
function MTE.woodNear(p)
    if overlapSphere == nil or CollisionFlag == nil or CollisionFlag.TREE == nil or type(p.x) ~= "number" then
        return {}
    end
    MTE.stumpHits = {seen = {}, list = {}}
    overlapSphere(p.x, p.y + 0.5, p.z, MTE.STUMP_RADIUS, "onStumpOverlap", MTE, CollisionFlag.TREE, false, false, true, false)
    local hits = MTE.stumpHits
    MTE.stumpHits = nil
    return hits.list
end

--- Server: removes what is left where trees were removed (in game a stump stayed after deleteSplitShape of a whole
--- tree). Only static wood within STUMP_RADIUS of a removed tree's base that was NOT there before the removal
--- (existing = set of shapes seen before), so a neighbouring tree is never touched; free (the tree's fee covers it).
--- Returns the number removed; logs what it found the first time.
function MTE.removeStumps(positions, existing)
    local removed = 0
    for _, p in ipairs(positions) do
        for _, shape in ipairs(MTE.woodNear(p)) do
            local x, y, z = getWorldTranslation(shape)
            local dx, dz = x - p.x, z - p.z
            if not existing[shape] and dx * dx + dz * dz <= MTE.STUMP_RADIUS * MTE.STUMP_RADIUS then
                if not MTE.stumpLogged then
                    MTE.stumpLogged = true
                    local parent = getParent ~= nil and getParent(shape) or nil
                    log("stump left at a removed tree: %s '%s' (split %s, splitType %s, %.2f m from the tree, parent '%s')", tostring(shape),
                        tostring(getName ~= nil and getName(shape) or "?"), tostring(getIsSplitShapeSplit(shape)), tostring(getSplitType(shape)),
                        math.sqrt(dx * dx + dz * dz), tostring(parent ~= nil and parent ~= 0 and getName ~= nil and getName(parent) or "?"))
                end
                if deleteSplitShape ~= nil then
                    deleteSplitShape(shape)
                else
                    delete(shape)
                end
                if g_treePlantManager ~= nil and g_treePlantManager.removingSplitShape ~= nil then
                    g_treePlantManager:removingSplitShape(shape)
                end
                removed = removed + 1
            end
        end
    end
    return removed
end

--- Server: the ground under removed trees changed (collision map for heaps, AI paths)
function MTE.setAreaDirty(rect)
    local m = 10
    if g_densityMapHeightManager ~= nil and g_densityMapHeightManager.setCollisionMapAreaDirty ~= nil then
        g_densityMapHeightManager:setCollisionMapAreaDirty(rect[1] - m, rect[2] - m, rect[3] + m, rect[4] + m, true)
    end
    local aiSystem = g_currentMission ~= nil and g_currentMission.aiSystem or nil
    if aiSystem ~= nil and aiSystem.setAreaDirty ~= nil then
        aiSystem:setAreaDirty(rect[1] - m, rect[3] + m, rect[2] - m, rect[4] + m)
    end
end

---------------------------------------------------------------------------------------------------------------------
-- the tree fee: what the game's bulldozer charges, found at runtime
---------------------------------------------------------------------------------------------------------------------
MTE.fee = nil   -- {kind = "method"|"constant"|"fallback", label =, fn =, selfObj =, value =, sample =}

local FEE_WORDS = {"price", "cost", "fee", "charge"}

local function hasFeeWord(name)
    local lower = string.lower(name)
    for _, w in ipairs(FEE_WORDS) do
        if string.find(lower, w, 1, true) then
            return true
        end
    end
    return false
end

local function isGetterName(name)
    local lower = string.lower(name)
    return string.sub(lower, 1, 3) == "get" or string.sub(lower, 1, 4) == "calc" or string.sub(lower, 1, 7) == "compute"
end

--- name -> value of an object and its class chain (metatable __index tables)
function MTE.collectMembers(obj)
    local out, t, depth = {}, obj, 0
    while type(t) == "table" and depth < 10 do
        for k, v in pairs(t) do
            if type(k) == "string" and out[k] == nil then
                out[k] = v
            end
        end
        local mt = getmetatable(t)
        local index = type(mt) == "table" and rawget(mt, "__index") or nil
        t = type(index) == "table" and index or nil
        depth = depth + 1
    end
    return out
end

function MTE.getDestructClass()
    if ConstructionBrushDestruct ~= nil then
        return ConstructionBrushDestruct
    end
    local manager = g_constructionBrushTypeManager
    if manager ~= nil and manager.getClassObjectByTypeName ~= nil then
        local cls = manager:getClassObjectByTypeName("destruct")
        if type(cls) == "table" then
            return cls
        end
    end
    return nil
end

--- A cursor for probing the demolition brush: every getHit*() answers with the tree being priced. While
--- MTE.probeRecord is a table, every call is recorded there (for the log).
function MTE.makeProbeCursor()
    local cursor = {isProbeCursor = true}
    setmetatable(cursor, {__index = function(_, key)
        return function(_, ...)
            if key == "setMessage" and MTE.probeMessages ~= nil and type((...)) == "string" then
                MTE.probeMessages[#MTE.probeMessages + 1] = (...)
            end
            if MTE.probeRecord ~= nil and #MTE.probeRecord < 40 then
                local args = {}
                for i = 1, select("#", ...) do
                    args[#args + 1] = tostring((select(i, ...)))
                end
                MTE.probeRecord[#MTE.probeRecord + 1] = string.format("cursor:%s(%s)", tostring(key), table.concat(args, ", "))
            end
            local shape = MTE.probeShape
            if type(key) ~= "string" or shape == nil then
                return nil
            end
            if string.find(key, "Position") or key == "getPosition" then
                return getWorldTranslation(shape)
            end
            if string.sub(key, 1, 6) == "getHit" and not string.find(key, "Placeable") then
                return shape
            end
            return nil
        end
    end})
    return cursor
end

--- An instance of the game's demolition brush (never activated), to call its fee getters on
function MTE.getProbeBrush()
    if MTE.probeBrush == nil then
        local cls = MTE.getDestructClass()
        if cls == nil then
            MTE.probeBrush = false
            return nil
        end
        local cursor = MTE.makeProbeCursor()
        local instance = nil
        if type(cls.new) == "function" then
            local result = cls.new(nil, cursor)
            if type(result) == "table" then
                instance = result
            end
        end
        if instance == nil then
            instance = setmetatable({cursor = cursor, isActive = false}, {__index = cls})
        end
        instance.cursor = cursor
        MTE.probeBrush = instance
    end
    return MTE.probeBrush or nil
end

--- Places to look for the fee: {label, obj, selfObj}
function MTE.getFeeSources()
    local sources = {}
    local cls = MTE.getDestructClass()
    if cls ~= nil then
        sources[#sources + 1] = {label = "ConstructionBrushDestruct", obj = cls, selfObj = MTE.getProbeBrush(), isBrush = true}
    end
    if g_treePlantManager ~= nil then
        sources[#sources + 1] = {label = "g_treePlantManager", obj = g_treePlantManager, selfObj = g_treePlantManager}
    end
    if g_splitShapeManager ~= nil then
        sources[#sources + 1] = {label = "g_splitShapeManager", obj = g_splitShapeManager, selfObj = g_splitShapeManager}
    end
    return sources
end

--- Candidate fee getters, best first: tree-named getters, then (demolition brush only) other price getters
function MTE.findFeeMethods()
    local tier1, tier2 = {}, {}
    for _, source in ipairs(MTE.getFeeSources()) do
        local members = MTE.collectMembers(source.obj)
        local names = {}
        for name, value in pairs(members) do
            if type(value) == "function" and isGetterName(name) and hasFeeWord(name) then
                names[#names + 1] = name
            end
        end
        table.sort(names)
        for _, name in ipairs(names) do
            local candidate = {label = source.label .. ":" .. name, fn = members[name], selfObj = source.selfObj}
            if string.find(string.lower(name), "tree", 1, true) then
                tier1[#tier1 + 1] = candidate
            elseif source.isBrush then
                tier2[#tier2 + 1] = candidate
            end
        end
    end
    for _, c in ipairs(tier2) do
        tier1[#tier1 + 1] = c
    end
    return tier1
end

--- Numeric constants named like a tree fee: {label, value}
function MTE.findFeeConstants()
    local found = {}
    local objects = {}
    local cls = MTE.getDestructClass()
    if cls ~= nil then
        objects[#objects + 1] = {"ConstructionBrushDestruct", cls}
        local brush = MTE.getProbeBrush()
        if brush ~= nil then
            objects[#objects + 1] = {"destructBrush", brush}
        end
    end
    objects[#objects + 1] = {"TreePlantManager", TreePlantManager}
    objects[#objects + 1] = {"g_treePlantManager", g_treePlantManager}
    objects[#objects + 1] = {"Landscaping", Landscaping}
    objects[#objects + 1] = {"EconomyManager", EconomyManager}
    for _, entry in ipairs(objects) do
        local obj = entry[2]
        if type(obj) == "table" then
            local members = MTE.collectMembers(obj)
            local names = {}
            for name, value in pairs(members) do
                if type(value) == "number" and value > 0 and string.find(string.lower(name), "tree", 1, true) and hasFeeWord(name) then
                    names[#names + 1] = name
                end
            end
            table.sort(names)
            for _, name in ipairs(names) do
                found[#found + 1] = {label = entry[1] .. "." .. name, value = members[name]}
            end
        end
    end
    return found
end

local function validFee(v)
    return type(v) == "number" and v == v and v > 0 and v < 1e7
end

MTE.failedFeeMethods = {}   -- label -> true: getters that raised an error (shown in the log), never called again

--- Calls a fee getter for one tree (the tree is both the argument and what the probe cursor "hits"). The getters are
--- found by name in the game's classes; one that raises an error stops this call (the error is in the log), and the
--- next call marks it failed and skips it, so the search goes on with the next candidate.
function MTE.callFeeMethod(candidate, shape)
    if MTE.feeCallPending ~= nil then
        MTE.failedFeeMethods[MTE.feeCallPending] = true
        warn("tree fee getter %s raised an error (see above), not used", MTE.feeCallPending)
        MTE.feeCallPending = nil
        MTE.probeShape = nil
    end
    if MTE.failedFeeMethods[candidate.label] or type(candidate.fn) ~= "function" or candidate.selfObj == nil
        or not MTE.isStandingTree(shape) then
        return nil
    end
    MTE.probeShape = shape
    MTE.feeCallPending = candidate.label
    local value = candidate.fn(candidate.selfObj, shape)
    MTE.feeCallPending = nil
    MTE.probeShape = nil
    if validFee(value) then
        return value
    end
    return nil
end

--- The amount in a money text the bulldozer shows ("$ 1,818", "1.818 €", "1 818 $"): money is formatted without
--- decimals, so every digit of the first number belongs to it. nil without digits.
function MTE.parseMoneyText(s)
    if type(s) ~= "string" then
        return nil
    end
    -- the first run of digits and grouping separators (comma, dot, space, no-break/thin space, apostrophe)
    local number = string.match(s, "%d[%d%.,' \194\160\226\128\175\137]*")
    if number == nil then
        return nil
    end
    local digits = string.gsub(number, "%D", "")
    return tonumber(digits)
end

--- The fee the game's bulldozer shows for a tree: since 1.25.1.0 ConstructionBrushDestruct prices a tree in
--- visualizeTreeMouseOver(tree) (mteTrace: hovering the tree, then the click charged 1820 for one tree) and puts it
--- on its cursor (cursor:setMessage("$ 1,818")). The price is computed in a local helper, so it is read from that
--- message, hovering the tree on a never-activated bulldozer whose cursor is ours, then hovering nothing so its
--- highlight is reset. (Also caught if it goes through g_i18n:formatMoney.)
--- record = true logs everything the brush did (first time only).
--- If the game's function raises an error (it is in the log), the next call undoes what the probe had set up (the
--- formatMoney hook) and the hover price is not used again: the fee then comes from the first tree or the next source.
function MTE.priceByHover(shape, record)
    if MTE.hoverPending ~= nil then
        g_i18n.formatMoney = MTE.hoverPending.ownFormat
        MTE.hoverPending = nil
        MTE.probeShape, MTE.probeMessages, MTE.probeRecord = nil, nil, nil
        MTE.hoverFailed = true
        warn("the bulldozer's hover price raised an error (see above), not used any more")
    end
    if MTE.hoverFailed then
        return nil
    end
    local brush = MTE.getProbeBrush()
    if brush == nil or type(brush.visualizeTreeMouseOver) ~= "function" or g_i18n == nil or g_i18n.formatMoney == nil
        or not MTE.isStandingTree(shape) then
        return nil
    end
    local amounts = {}
    local ownFormat = rawget(g_i18n, "formatMoney")    -- nil: the class method, restored by removing ours
    local format = g_i18n.formatMoney
    g_i18n.formatMoney = function(i18n, amount, ...)
        if type(amount) == "number" and #amounts < 50 then
            amounts[#amounts + 1] = amount
        end
        return format(i18n, amount, ...)
    end
    MTE.hoverPending = {ownFormat = ownFormat}
    MTE.probeRecord = record and {} or nil
    MTE.probeMessages = {}
    MTE.probeShape = shape
    brush:visualizeTreeMouseOver(shape)
    MTE.probeShape = nil
    local messages = MTE.probeMessages
    MTE.probeMessages = nil
    brush:visualizeTreeMouseOver(nil)
    g_i18n.formatMoney = ownFormat
    MTE.hoverPending = nil
    local calls = MTE.probeRecord
    MTE.probeRecord = nil

    local price = nil
    for _, amount in ipairs(amounts) do
        if validFee(math.abs(amount)) then
            price = math.abs(amount)
            break
        end
    end
    if price == nil then
        for _, message in ipairs(messages) do
            local amount = MTE.parseMoneyText(message)
            if validFee(amount) then
                price = amount
                break
            end
        end
    end
    if record then
        local fields = {}
        for k, v in pairs(brush) do
            if type(k) == "string" and type(v) ~= "function" and type(v) ~= "table" then
                fields[#fields + 1] = k .. "=" .. tostring(v)
            end
        end
        table.sort(fields)
        local amountList = {}
        for _, a in ipairs(amounts) do
            amountList[#amountList + 1] = tostring(a)
        end
        log("hover price probe: tree %s -> %s; money formatted: %s; cursor calls: %s; brush fields: %s",
            tostring(shape), tostring(price),
            #amountList > 0 and table.concat(amountList, ", ") or "none", calls ~= nil and #calls > 0 and table.concat(calls, "; ") or "none",
            table.concat(fields, ", "))
    end
    return price
end

--- Decides once where the tree fee comes from, using a sample tree (one on the farm's land if there is one)
function MTE.resolveFee(sampleShape)
    if MTE.fee ~= nil then
        return MTE.fee
    end
    if sampleShape == nil then
        return nil
    end
    local hoverPrice = MTE.priceByHover(sampleShape, true)
    if hoverPrice ~= nil then
        MTE.fee = {kind = "hover", label = "ConstructionBrushDestruct:visualizeTreeMouseOver", sample = hoverPrice}
        log("tree fee from the game's bulldozer: %s for the first tree (priced per tree as the bulldozer shows it)", tostring(hoverPrice))
        return MTE.fee
    end
    for _, candidate in ipairs(MTE.findFeeMethods()) do
        local value = MTE.callFeeMethod(candidate, sampleShape)
        if value ~= nil then
            MTE.fee = {kind = "method", label = candidate.label, fn = candidate.fn, selfObj = candidate.selfObj, sample = value}
            log("tree fee from the game: %s (%s for the first tree)", candidate.label, tostring(value))
            return MTE.fee
        end
    end
    local constants = MTE.findFeeConstants()
    if #constants > 0 then
        MTE.fee = {kind = "constant", label = constants[1].label, value = constants[1].value, sample = constants[1].value}
        log("tree fee from the game: %s = %s per tree", constants[1].label, tostring(constants[1].value))
        return MTE.fee
    end
    MTE.fee = {kind = "fallback", label = "fallback", value = MTE.FALLBACK_TREE_FEE, sample = MTE.FALLBACK_TREE_FEE}
    warn("the bulldozer's tree fee was not found (game older than 1.25.1.0?), using %d per tree. The bulldozer's details follow; mteTrace shows what it does with a tree.",
        MTE.FALLBACK_TREE_FEE)
    -- what the bulldozer offers, so one test run is enough to find the fee
    MTE:consoleInfo()
    return MTE.fee
end

function MTE.getTreeFee(shape)
    local fee = MTE.resolveFee(shape)
    if fee == nil then
        return MTE.FALLBACK_TREE_FEE
    end
    if fee.kind == "hover" then
        return MTE.priceByHover(shape, false) or fee.sample
    end
    if fee.kind == "method" then
        return MTE.callFeeMethod(fee, shape) or fee.sample
    end
    return fee.value
end

function MTE.isFeeEstimated()
    return MTE.fee ~= nil and MTE.fee.kind == "fallback"
end

--- Prices a tree list: sets tree.fee, returns the sum. Resolves the fee with a tree on own land first.
function MTE.priceTrees(trees)
    if MTE.fee == nil and trees[1] ~= nil then
        MTE.resolveFee(trees[1].shape)
    end
    local total = 0
    for _, tree in ipairs(trees) do
        tree.fee = MTE.getTreeFee(tree.shape)
        total = total + tree.fee
    end
    return total
end

---------------------------------------------------------------------------------------------------------------------
-- bushes (foliage layers)
---------------------------------------------------------------------------------------------------------------------

--- Bush foliage layers of this map: {name=, id=, numChannels=, pixelArea=}
function MTE.getBushLayers()
    if MTE.bushLayers ~= nil then
        return MTE.bushLayers
    end
    local terrain = MTE.getTerrainNode()
    if type(terrain) ~= "number" or terrain == 0 or getTerrainDataPlaneByName == nil then
        return {}
    end
    local names, seen = {}, {}
    local function add(name)
        if type(name) == "string" and not seen[name] then
            seen[name] = true
            names[#names + 1] = name
        end
    end
    for _, name in ipairs(MTE.BUSH_LAYER_NAMES) do
        add(name)
    end
    -- layers the map declares itself (decoFoliages): any "deco...bush..." name in the foliage system
    local foliageSystem = g_currentMission ~= nil and g_currentMission.foliageSystem or nil
    if type(foliageSystem) == "table" then
        local visited = {}
        local function scan(t, depth)
            if visited[t] or depth > 3 then
                return
            end
            visited[t] = true
            for k, v in pairs(t) do
                for _, s in ipairs({k, v}) do
                    if type(s) == "string" then
                        local lower = string.lower(s)
                        if string.sub(lower, 1, 4) == "deco" and string.find(lower, "bush", 1, true) then
                            add(s)
                        end
                    end
                end
                if type(v) == "table" then
                    scan(v, depth + 1)
                end
            end
        end
        scan(foliageSystem, 0)
    end

    local layers, seenIds = {}, {}
    local terrainSize = (g_currentMission ~= nil and tonumber(g_currentMission.terrainSize)) or 2048
    for _, name in ipairs(names) do
        local id = getTerrainDataPlaneByName(terrain, name)
        if type(id) == "number" and id ~= 0 and not seenIds[id] then
            seenIds[id] = true
            local numChannels = 4
            if getTerrainDetailNumChannels ~= nil then
                local n = getTerrainDetailNumChannels(id)
                if type(n) == "number" and n > 0 then
                    numChannels = n
                end
            end
            local pixelArea = 0.25
            if getDensityMapSize ~= nil then
                local size = getDensityMapSize(id)
                if type(size) == "number" and size > 0 then
                    pixelArea = (terrainSize / size) ^ 2
                end
            end
            layers[#layers + 1] = {name = name, id = id, numChannels = numChannels, pixelArea = pixelArea}
        end
    end
    MTE.bushLayers = layers
    if #layers > 0 then
        local list = {}
        for _, l in ipairs(layers) do
            list[#list + 1] = string.format("%s (%.2f m2/pixel)", l.name, l.pixelArea)
        end
        log("bush layers: %s", table.concat(list, ", "))
    else
        log("no bush foliage layers on this map")
    end
    return layers
end

--- Counts (and with clear = true removes) the bush pixels of one layer in an axis-aligned strip. Returns m2.
function MTE.bushArea(layer, x0, z0, x1, z1, clear)
    if layer.modifier == nil then
        local terrain = MTE.getTerrainNode()
        local modifier = nil
        if DensityMapModifier ~= nil and DensityMapFilter ~= nil and terrain ~= nil and type(layer.id) == "number" and layer.id ~= 0 then
            modifier = DensityMapModifier.new(layer.id, 0, layer.numChannels, terrain)
        end
        if modifier == nil then
            layer.modifier = false
            warn("no DensityMapModifier for %s, its bushes are left alone", layer.name)
            return 0
        end
        local filter = DensityMapFilter.new(modifier)
        filter:setValueCompareParams(DensityValueCompareType.GREATER, 0)
        layer.modifier, layer.filter = modifier, filter
    end
    if layer.modifier == false then
        return 0
    end
    local modifier, filter = layer.modifier, layer.filter
    modifier:setParallelogramWorldCoords(x0, z0, x1, z0, x0, z1, DensityCoordType.POINT_POINT_POINT)
    local _, pixels = modifier:executeGet(filter)
    pixels = tonumber(pixels) or 0
    if clear and pixels > 0 then
        modifier:executeSet(0, filter)
    end
    return pixels * layer.pixelArea
end

--- Calls fn(x0, z0, x1, z1) for every strip of the rectangle that is the farm's own land (CELL m resolution)
function MTE.forOwnStrips(rect, farmId, fn)
    local cell = MTE.CELL
    local z = rect[2]
    while z < rect[4] - 1e-6 do
        local z1 = math.min(z + cell, rect[4])
        local runStart = nil
        local x = rect[1]
        while x < rect[3] - 1e-6 do
            local x1 = math.min(x + cell, rect[3])
            local own = MTE.isOwnLand(farmId, (x + x1) * 0.5, (z + z1) * 0.5)
            if own and runStart == nil then
                runStart = x
            elseif not own and runStart ~= nil then
                fn(runStart, z, x, z1)
                runStart = nil
            end
            x = x1
        end
        if runStart ~= nil then
            fn(runStart, z, rect[3], z1)
        end
        z = z1
    end
end

--- m2 of bushes on the farm's own land in the rectangle (clear = true removes them)
function MTE.bushesInRect(rect, farmId, clear)
    local layers = MTE.getBushLayers()
    if #layers == 0 then
        return 0
    end
    local total = 0
    MTE.forOwnStrips(rect, farmId, function(x0, z0, x1, z1)
        for _, layer in ipairs(layers) do
            total = total + MTE.bushArea(layer, x0, z0, x1, z1, clear)
        end
    end)
    return total
end

--- The construction menu's landscaping rate per m2 (what erasing foliage with the plant brush costs)
function MTE.getBushFeePerM2()
    if type(Landscaping) == "table" then
        for _, name in ipairs({"PAINT_BASE_COST_PER_M2", "FOLIAGE_BASE_COST_PER_M2"}) do
            if validFee(Landscaping[name]) then
                return Landscaping[name], "Landscaping." .. name
            end
        end
    end
    return MTE.FALLBACK_BUSH_FEE_PER_M2, "fallback"
end

---------------------------------------------------------------------------------------------------------------------
-- counting an area (shared by the preview and the server)
---------------------------------------------------------------------------------------------------------------------

--- {trees = own trees, denied = trees on other land, treeCost, bushM2, bushCost, cost}
function MTE.survey(rect, farmId, withBushes)
    local all = MTE.findTrees(rect)
    local own, denied = {}, {}
    for _, tree in ipairs(all) do
        if MTE.isOwnLand(farmId, tree.x, tree.z) then
            own[#own + 1] = tree
        else
            denied[#denied + 1] = tree
        end
    end
    local treeCost = MTE.priceTrees(own)
    local bushM2 = withBushes and MTE.bushesInRect(rect, farmId, false) or 0
    local bushRate = MTE.getBushFeePerM2()
    local bushCost = bushM2 * bushRate
    return {trees = own, denied = denied, treeCost = treeCost, bushM2 = bushM2, bushCost = bushCost, cost = treeCost + bushCost}
end

---------------------------------------------------------------------------------------------------------------------
-- marking an area (local)
---------------------------------------------------------------------------------------------------------------------
function MTE.notify(message, isWarning)
    if g_currentMission == nil or g_dedicatedServer ~= nil then
        log("%s", message)
        return
    end
    MTE.lastMessage = {text = message, isWarning = isWarning == true, time = g_time or 0}
    dbg("notify: %s", message)
end

--- Adds a corner; the second one makes the rectangle and counts it. A third starts a new area.
function MTE.addCorner(x, y, z)
    if #MTE.corners >= 2 then
        MTE.clearSelection()
    end
    local corners = MTE.corners
    corners[#corners + 1] = {x, y, z}
    if #corners == 2 then
        MTE.rect = MTE.makeRect(corners[1][1], corners[1][3], corners[2][1], corners[2][3])
        MTE.refreshPreview()
    end
end

function MTE.removeLastCorner()
    local corners = MTE.corners
    if #corners > 0 then
        corners[#corners] = nil
        MTE.rect = nil
        MTE.preview = nil
    end
end

function MTE.clearSelection()
    MTE.corners = {}
    MTE.rect = nil
    MTE.preview = nil
end

--- Recounts the marked area. Local: reads trees, land and the bush layers.
function MTE.refreshPreview()
    local rect = MTE.rect
    if rect == nil then
        MTE.preview = nil
        return
    end
    MTE.previewTimer = MTE.PREVIEW_REFRESH_MS
    if MTE.isRectTooLarge(rect) then
        MTE.preview = {tooLarge = true, trees = {}, denied = {}, treeCost = 0, bushM2 = 0, bushCost = 0, cost = 0}
        return
    end
    MTE.preview = MTE.survey(rect, MTE.getFarmId(), MTE.removeBushes)
    dbg("preview: %d trees (%d on other land), %.0f m2 bushes, cost %.0f", #MTE.preview.trees, #MTE.preview.denied,
        MTE.preview.bushM2, MTE.preview.cost)
end

--- Is there something to bulldoze in the marked, counted area?
function MTE.hasWork()
    local p = MTE.preview
    return MTE.rect ~= nil and p ~= nil and not p.tooLarge and (#p.trees > 0 or p.bushM2 >= 0.5)
end

---------------------------------------------------------------------------------------------------------------------
-- removing
---------------------------------------------------------------------------------------------------------------------

--- Asks "bulldoze N trees and M m2 of bushes for X?" (like the bulldozer does), then sends the request
function MTE.confirmAndRequest()
    local p = MTE.preview
    if not MTE.hasWork() then
        return
    end
    local question = text("mte_confirm", #p.trees, math.floor(p.bushM2 + 0.5), MTE.formatMoney(p.cost))
    local function onAnswer(a, b)
        local yes = a
        if type(a) == "table" then
            yes = b
        end
        if yes == true then
            MTE.requestRemove()
        end
    end
    if YesNoDialog ~= nil and YesNoDialog.show ~= nil then
        YesNoDialog.show(onAnswer, nil, question)
        return
    end
    if g_gui ~= nil and g_gui.showYesNoDialog ~= nil then
        g_gui:showYesNoDialog({text = question, callback = onAnswer})
        return
    end
    MTE.requestRemove()
end

--- Sends the marked area to the server (or removes directly in single player)
function MTE.requestRemove()
    local rect = MTE.rect
    if rect == nil then
        return
    end
    local request = {farmId = MTE.getFarmId(), rect = {rect[1], rect[2], rect[3], rect[4]}, bushes = MTE.removeBushes}
    if g_server ~= nil then
        MTE.serverRemove(request, nil)
    elseif g_client ~= nil then
        g_client:getServerConnection():sendEvent(MassTreeExterminatorRemoveEvent.new(request))
    end
end

--- Server: the player's farm and whether they may landscape
function MTE.getRequestFarm(request, connection)
    local farmId = request.farmId
    if connection ~= nil and g_currentMission.playerSystem ~= nil and g_currentMission.playerSystem.getPlayerByConnection ~= nil then
        local player = g_currentMission.playerSystem:getPlayerByConnection(connection)
        if type(player) == "table" and player.farmId ~= nil then
            farmId = player.farmId
        end
    end
    local allowed = true
    if connection ~= nil and g_currentMission.getHasPlayerPermission ~= nil and Farm ~= nil and Farm.PERMISSION ~= nil and Farm.PERMISSION.LANDSCAPING ~= nil then
        local has = g_currentMission:getHasPlayerPermission(Farm.PERMISSION.LANDSCAPING, connection)
        if has == false then
            allowed = false
        end
    end
    return farmId, allowed
end

function MTE.getFarmBalance(farmId)
    local farm = g_farmManager ~= nil and g_farmManager:getFarmById(farmId) or nil
    if farm == nil then
        return nil
    end
    if farm.getBalance ~= nil then
        local balance = farm:getBalance()
        if type(balance) == "number" then
            return balance
        end
    end
    return tonumber(farm.money)
end

function MTE.getMoneyType()
    if MoneyType == nil then
        return nil
    end
    return MoneyType.CONSTRUCTION or MoneyType.LANDSCAPING or MoneyType.SHOP_PROPERTY_BUY or MoneyType.OTHER
end

--- Server: check, clear the bushes, queue the trees. Answers the connection (nil = local player) when done.
function MTE.serverRemove(request, connection)
    local result = {reason = MTE.REASON_OK, numTrees = 0, numDenied = 0, bushM2 = 0, cost = 0}
    local function reply()
        if connection ~= nil then
            connection:sendEvent(MassTreeExterminatorResultEvent.new(result))
        else
            MTE.onResult(result)
        end
    end

    local farmId, allowed = MTE.getRequestFarm(request, connection)
    local rect = request.rect ~= nil and MTE.makeRect(request.rect[1], request.rect[2], request.rect[3], request.rect[4]) or nil
    if not allowed then
        result.reason = MTE.REASON_NO_PERMISSION
        reply()
        return
    end
    if rect == nil then
        result.reason = MTE.REASON_INVALID
        reply()
        return
    end
    if MTE.isRectTooLarge(rect) then
        result.reason = MTE.REASON_TOO_LARGE
        reply()
        return
    end

    local survey = MTE.survey(rect, farmId, request.bushes)
    result.numDenied = #survey.denied
    if #survey.trees == 0 and survey.bushM2 < 0.5 then
        result.reason = MTE.REASON_NOTHING
        reply()
        return
    end
    local balance = MTE.getFarmBalance(farmId)
    if balance ~= nil and balance < survey.cost then
        result.reason = MTE.REASON_NO_MONEY
        result.cost = survey.cost
        reply()
        return
    end

    -- bushes now (density map writes replicate), trees over the next frames
    if request.bushes then
        result.bushM2 = MTE.bushesInRect(rect, farmId, true)
    end
    local job = {trees = survey.trees, index = 1, farmId = farmId, rect = rect, result = result, reply = reply,
                 bushCost = result.bushM2 * MTE.getBushFeePerM2(), treeCost = 0, numStumps = 0, secondPassAt = 0,
                 existing = {}, removed = {}}
    MTE.jobs[#MTE.jobs + 1] = job
    MTE.updateJobs()
end

--- Server: delete the queued trees, a batch per frame; charge and answer when a job is done
function MTE.updateJobs()
    local job = MTE.jobs[1]
    if job == nil then
        return
    end
    job.existing = job.existing or {}
    job.removed = job.removed or {}
    job.scanIndex = job.scanIndex or 1
    if job.scanIndex <= #job.trees then
        -- first the wood around every tree of the job, before any of them goes (a stump left by one tree must not
        -- count as "there before" for its neighbour): whatever is new there afterwards is a stump
        local last = math.min(job.scanIndex + MTE.DELETE_PER_FRAME - 1, #job.trees)
        for i = job.scanIndex, last do
            for _, shape in ipairs(MTE.woodNear(job.trees[i])) do
                job.existing[shape] = true
            end
        end
        job.scanIndex = last + 1
        if job.scanIndex <= #job.trees then
            return
        end
    end
    if job.index <= #job.trees then
        local last = math.min(job.index + MTE.DELETE_PER_FRAME - 1, #job.trees)
        for i = job.index, last do
            local tree = job.trees[i]
            if MTE.deleteTree(tree.shape) then
                job.result.numTrees = job.result.numTrees + 1
                job.treeCost = job.treeCost + (tree.fee or 0)
                job.removed[#job.removed + 1] = tree
            end
        end
        job.index = last + 1
        if job.index <= #job.trees then
            return
        end
        -- the removed trees themselves are gone; an id the engine hands out again is new wood
        for _, tree in ipairs(job.removed) do
            job.existing[tree.shape] = nil
        end
        job.numStumps = MTE.removeStumps(job.removed, job.existing)
        job.secondPassAt = (g_time or 0) + MTE.STUMP_SECOND_PASS_MS
        return
    end
    if (g_time or 0) < job.secondPassAt then
        return
    end
    job.numStumps = job.numStumps + MTE.removeStumps(job.removed, job.existing)

    table.remove(MTE.jobs, 1)
    MTE.setAreaDirty(job.rect)
    local cost = job.treeCost + job.bushCost
    job.result.cost = cost
    if cost > 0 then
        g_currentMission:addMoney(-cost, job.farmId, MTE.getMoneyType(), true, true)
    end
    if job.result.numTrees == 0 and job.result.bushM2 < 0.5 then
        job.result.reason = MTE.REASON_NOTHING
    end
    log("bulldozed %d trees (%d stumps left behind removed too) and %.0f m2 of bushes for farm %s, cost %.0f (%d trees on other land left)",
        job.result.numTrees, job.numStumps, job.result.bushM2, tostring(job.farmId), cost, job.result.numDenied)
    job.reply()
end

--- Client: the server's answer
function MTE.onResult(result)
    local reason = result.reason
    if reason == MTE.REASON_OK then
        local message = text("mte_result_done", result.numTrees, math.floor(result.bushM2 + 0.5), MTE.formatMoney(result.cost))
        if result.numDenied > 0 then
            message = message .. text("mte_hud_denied", result.numDenied)
        end
        MTE.notify(message)
    elseif reason == MTE.REASON_NO_MONEY then
        MTE.notify(text("mte_result_noMoney", MTE.formatMoney(result.cost)), true)
    elseif reason == MTE.REASON_NO_PERMISSION then
        MTE.notify(text("mte_result_noPermission"), true)
    elseif reason == MTE.REASON_TOO_LARGE then
        MTE.notify(text("mte_hud_tooLarge", MTE.MAX_SIDE), true)
    else
        MTE.notify(text("mte_result_nothing"), true)
    end
    MTE.recountTimer = MTE.RESULT_RECOUNT_MS
end

---------------------------------------------------------------------------------------------------------------------
-- drawing (the construction brush calls this)
---------------------------------------------------------------------------------------------------------------------
local function drawPost(x, z, height, r, g, b)
    local y = MTE.getTerrainHeight(x, z)
    drawDebugLine(x, y, z, r, g, b, x, y + height, z, r, g, b)
end

local function drawGroundLine(x1, z1, x2, z2, r, g, b)
    local dx, dz = x2 - x1, z2 - z1
    local length = math.sqrt(dx * dx + dz * dz)
    local steps = math.max(1, math.min(64, math.ceil(length / 3)))
    local px, pz = x1, z1
    local py = MTE.getTerrainHeight(px, pz) + 0.3
    for i = 1, steps do
        local t = i / steps
        local nx, nz = x1 + dx * t, z1 + dz * t
        local ny = MTE.getTerrainHeight(nx, nz) + 0.3
        drawDebugLine(px, py, pz, r, g, b, nx, ny, nz, r, g, b)
        px, py, pz = nx, ny, nz
    end
end

local function drawGroundRect(minX, minZ, maxX, maxZ, r, g, b)
    drawGroundLine(minX, minZ, maxX, minZ, r, g, b)
    drawGroundLine(maxX, minZ, maxX, maxZ, r, g, b)
    drawGroundLine(maxX, maxZ, minX, maxZ, r, g, b)
    drawGroundLine(minX, maxZ, minX, minZ, r, g, b)
end

--- Draws the corners, the area (with one corner: up to the cursor) and the tree markers. Returns the status text, or
--- nil with nothing marked.
function MTE.drawSelection(cursorX, cursorZ)
    local corners = MTE.corners
    if #corners == 0 then
        return nil
    end
    for _, c in ipairs(corners) do
        drawPost(c[1], c[3], 4, 1, 0.85, 0)
    end
    local rect = MTE.rect
    if rect == nil then
        if cursorX ~= nil then
            local c = corners[1]
            drawGroundRect(math.min(c[1], cursorX), math.min(c[3], cursorZ), math.max(c[1], cursorX), math.max(c[3], cursorZ), 1, 1, 1)
        end
        return text("mte_hud_oneCorner")
    end
    drawGroundRect(rect[1], rect[2], rect[3], rect[4], 1, 0.85, 0)
    local p = MTE.preview
    if p == nil then
        return text("mte_hud_counting")
    end
    if p.tooLarge then
        return text("mte_hud_tooLarge", MTE.MAX_SIDE)
    end
    local drawn = 0
    for _, tree in ipairs(p.trees) do
        drawn = drawn + 1
        if drawn > MTE.MAX_DRAWN then
            break
        end
        drawPost(tree.x, tree.z, 3, 1, 0.15, 0.1)
    end
    for _, tree in ipairs(p.denied) do
        drawn = drawn + 1
        if drawn > MTE.MAX_DRAWN then
            break
        end
        drawPost(tree.x, tree.z, 1.5, 0.6, 0.6, 0.6)
    end
    if #p.trees == 0 and p.bushM2 < 0.5 then
        local message = text("mte_hud_nothing")
        if #p.denied > 0 then
            message = message .. text("mte_hud_denied", #p.denied)
        end
        return message
    end
    local message = text("mte_hud_selection", math.floor(rect[3] - rect[1] + 0.5), math.floor(rect[4] - rect[2] + 0.5), #p.trees,
        math.floor(p.bushM2 + 0.5), MTE.formatMoney(p.cost))
    if MTE.isFeeEstimated() and #p.trees > 0 then
        message = message .. text("mte_hud_feeEstimated")
    end
    if #p.denied > 0 then
        message = message .. text("mte_hud_denied", #p.denied)
    end
    if not MTE.removeBushes then
        message = message .. text("mte_hud_bushesOff")
    end
    return message
end

---------------------------------------------------------------------------------------------------------------------
-- console: info and trace (to check the fee against the game's bulldozer)
---------------------------------------------------------------------------------------------------------------------
local function describeValue(v)
    local t = type(v)
    if t == "number" then
        return string.format("%.6g", v)
    elseif t == "string" then
        return string.format("%q", string.sub(v, 1, 60))
    elseif t == "table" then
        local mt = getmetatable(v)
        local name = MTE.globalNameOf(v) or MTE.globalNameOf(type(mt) == "table" and rawget(mt, "__index") or nil)
        return name ~= nil and ("<" .. name .. ">") or "<table>"
    end
    return tostring(v)
end

--- The global name of a class table (cached reverse lookup of _G)
function MTE.globalNameOf(t)
    if type(t) ~= "table" then
        return nil
    end
    if MTE.globalNames == nil then
        MTE.globalNames = setmetatable({}, {__mode = "k"})
        for k, v in pairs(_G) do
            if type(k) == "string" and type(v) == "table" then
                MTE.globalNames[v] = k
            end
        end
    end
    return MTE.globalNames[t]
end

local function describeArgs(...)
    local parts = {}
    for i = 1, select("#", ...) do
        parts[#parts + 1] = describeValue((select(i, ...)))
    end
    return table.concat(parts, ", ")
end

function MTE:consoleInfo()
    local cls = MTE.getDestructClass()
    if cls == nil then
        log("no demolition brush class found")
    else
        local functions, numbers = {}, {}
        for k, v in pairs(cls) do
            if type(k) == "string" then
                if type(v) == "function" then
                    functions[#functions + 1] = k
                elseif type(v) == "number" or type(v) == "string" or type(v) == "boolean" then
                    numbers[#numbers + 1] = k .. "=" .. tostring(v)
                end
            end
        end
        table.sort(functions)
        table.sort(numbers)
        log("ConstructionBrushDestruct functions: %s", table.concat(functions, ", "))
        log("ConstructionBrushDestruct values: %s", table.concat(numbers, ", "))
        local brush = MTE.getProbeBrush()
        if brush ~= nil then
            local fields = {}
            for k, v in pairs(brush) do
                if type(k) == "string" and type(v) ~= "function" then
                    fields[#fields + 1] = k .. "=" .. describeValue(v)
                end
            end
            table.sort(fields)
            log("demolition brush instance fields: %s", table.concat(fields, ", "))
        end
    end
    local labels = {}
    for _, c in ipairs(MTE.findFeeMethods()) do
        labels[#labels + 1] = c.label
    end
    log("fee getter candidates: %s", #labels > 0 and table.concat(labels, ", ") or "none")
    labels = {}
    for _, c in ipairs(MTE.findFeeConstants()) do
        labels[#labels + 1] = c.label .. "=" .. tostring(c.value)
    end
    log("fee constant candidates: %s", #labels > 0 and table.concat(labels, ", ") or "none")
    local names = {}
    for k, v in pairs(_G) do
        if type(k) == "string" and type(v) == "table" and (string.find(k, "Tree") or string.find(k, "Destruct") or string.find(k, "Demoli")) then
            names[#names + 1] = k
        end
    end
    table.sort(names)
    log("tree/demolition globals: %s", table.concat(names, ", "))
    -- event classes are not always globals (the bulldozer's tree event is not): look in the event registry
    if type(EventIds) == "table" then
        local found, visited = {}, {}
        local function scan(t, path, depth)
            if visited[t] or depth > 2 then
                return
            end
            visited[t] = true
            for k, v in pairs(t) do
                local key = tostring(k)
                local name = type(v) == "string" and v or key
                if string.find(name, "Tree") or string.find(name, "Destr") or string.find(name, "SplitShape") then
                    found[#found + 1] = path .. "." .. key .. "=" .. describeValue(v)
                end
                if type(v) == "table" and (getmetatable(v) == nil or depth == 0) then
                    scan(v, path .. "." .. key, depth + 1)
                end
            end
        end
        scan(EventIds, "EventIds", 0)
        table.sort(found)
        log("tree events in EventIds: %s", #found > 0 and table.concat(found, ", ") or "none")
    end
    local fee = MTE.fee
    log("tree fee in use: %s", fee ~= nil and string.format("%s (%s, first tree %s)", fee.label, fee.kind, tostring(fee.sample)) or "not decided yet (mark an area with trees first)")
    local rate, rateSource = MTE.getBushFeePerM2()
    log("bush fee per m2: %s (%s), bushes %s", tostring(rate), rateSource, MTE.removeBushes and "on" or "off")
    MTE.bushLayers = nil
    MTE.getBushLayers()
    return "[MassTreeExterminator] details written to log.txt"
end

--- Logs every call of the game's demolition brush, every event sent to the server and every money change, so one
--- tree removed by hand with the bulldozer shows exactly how the game prices and removes it
function MTE:consoleTrace()
    if MTE.traceRestore ~= nil then
        for _, restore in ipairs(MTE.traceRestore) do
            restore()
        end
        MTE.traceRestore = nil
        return "[MassTreeExterminator] trace OFF"
    end
    local restores = {}
    local quiet = {update = true, draw = true}
    local lastLine = {}   -- per function: calls made every frame are logged once until something changes
    local cls = MTE.getDestructClass()
    if cls ~= nil then
        local names = {}
        for name, fn in pairs(cls) do
            if type(fn) == "function" and type(name) == "string" and name ~= "new" then
                names[#names + 1] = name
            end
        end
        for _, name in ipairs(names) do
            local original = cls[name]
            cls[name] = function(...)
                local results = pack(original(...))
                if not quiet[name] then
                    local line = string.format("trace destruct:%s(%s) -> %s", name, describeArgs(select(2, ...)), describeArgs(unpack(results, 1, results.n)))
                    if line ~= lastLine[name] then
                        lastLine[name] = line
                        log("%s", line)
                    end
                end
                return unpack(results, 1, results.n)
            end
            restores[#restores + 1] = function() cls[name] = original end
        end
    end
    if g_currentMission ~= nil and g_currentMission.addMoney ~= nil then
        local original = g_currentMission.addMoney
        g_currentMission.addMoney = function(mission, amount, farmId, moneyType, ...)
            log("trace addMoney(%s, farm %s, %s)", describeValue(amount), tostring(farmId), describeValue(moneyType))
            return original(mission, amount, farmId, moneyType, ...)
        end
        restores[#restores + 1] = function() g_currentMission.addMoney = original end
    end
    if g_client ~= nil and g_client.getServerConnection ~= nil then
        local connection = g_client:getServerConnection()
        if connection ~= nil and connection.sendEvent ~= nil then
            local own = rawget(connection, "sendEvent")    -- nil: the class method, restored by removing ours
            local original = connection.sendEvent
            connection.sendEvent = function(conn, event, ...)
                local fields = {}
                if type(event) == "table" then
                    for k, v in pairs(event) do
                        if type(k) == "string" and type(v) ~= "function" then
                            fields[#fields + 1] = k .. "=" .. describeValue(v)
                        end
                    end
                end
                table.sort(fields)
                log("trace sendEvent %s {%s}", describeValue(event), table.concat(fields, ", "))
                return original(conn, event, ...)
            end
            restores[#restores + 1] = function() connection.sendEvent = own end
        end
    end
    MTE.traceRestore = restores
    return "[MassTreeExterminator] trace ON: remove one tree with the game's bulldozer (Shift-P, demolition), then run mteTrace again and send log.txt"
end

function MTE:consoleBushes()
    MTE.removeBushes = not MTE.removeBushes
    if MTE.rect ~= nil then
        MTE.refreshPreview()
    end
    return "[MassTreeExterminator] bushes " .. (MTE.removeBushes and "ON: trees and bushes are removed" or "OFF: only trees are removed")
end

function MTE:consoleDebug()
    MTE.DEBUG = not MTE.DEBUG
    return "[MassTreeExterminator] debug " .. (MTE.DEBUG and "ON" or "OFF")
end

---------------------------------------------------------------------------------------------------------------------
-- mod event listener
---------------------------------------------------------------------------------------------------------------------
MTE.CONSOLE = {
    {"mteInfo", "Mass Tree Exterminator: write the bulldozer's tree fee details to the log", "consoleInfo"},
    {"mteTrace", "Mass Tree Exterminator: log what the game's bulldozer does (toggle)", "consoleTrace"},
    {"mteBushes", "Mass Tree Exterminator: also remove bushes on/off", "consoleBushes"},
    {"mteDebug", "Mass Tree Exterminator: debug logging on/off", "consoleDebug"},
}

function MTE:loadMap(name)
    MTE.clearSelection()
    MTE.fee = nil
    MTE.probeBrush = nil
    MTE.bushLayers = nil
    MTE.jobs = {}
    MTE.globalNames = nil
    if addConsoleCommand ~= nil then
        for _, c in ipairs(MTE.CONSOLE) do
            addConsoleCommand(c[1], c[2], c[3], MTE)
        end
    end
    log("loaded (%s)", g_dedicatedServer ~= nil and "dedicated server" or (g_server ~= nil and "server" or "client"))
end

function MTE:deleteMap()
    if removeConsoleCommand ~= nil then
        for _, c in ipairs(MTE.CONSOLE) do
            removeConsoleCommand(c[1])
        end
    end
    if MTE.traceRestore ~= nil then
        MTE:consoleTrace()
    end
    MTE.bushLayers = nil
    MTE.probeBrush = nil
    MTE.jobs = {}
end

function MTE:update(dt)
    if g_server ~= nil and #MTE.jobs > 0 then
        MTE.updateJobs()
    end
    if MTE.recountTimer ~= nil then
        MTE.recountTimer = MTE.recountTimer - dt
        if MTE.recountTimer <= 0 then
            MTE.recountTimer = nil
            if MTE.rect ~= nil then
                MTE.refreshPreview()
            end
        end
    end
    if MTE.rect ~= nil and MTE.preview ~= nil then
        MTE.previewTimer = MTE.previewTimer - dt
        if MTE.previewTimer <= 0 then
            MTE.refreshPreview()
        end
    end
end

-- construction screen tool (Shift-P > Landscaping > Mass Tree Exterminator); the store item
-- massTreeExterminatorTool.xml names the brush type "FS25_MassTreeExterminator.massTreeExterminator"
if g_constructionBrushTypeManager ~= nil and g_constructionBrushTypeManager.addBrushType ~= nil then
    g_constructionBrushTypeManager:addBrushType("massTreeExterminator", "ConstructionBrushMassTreeExterminator",
        g_currentModDirectory .. "scripts/ConstructionBrushMassTreeExterminator.lua")
else
    Logging.warning("[MassTreeExterminator] construction brush manager not found, the Shift-P tool is unavailable")
end

addModEventListener(MTE)
