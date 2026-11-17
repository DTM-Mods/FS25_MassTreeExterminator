"""Offline test of the Mass Tree Exterminator Lua on real Lua 5.1 (python lupa's lua51), with stubs for the game engine.

A fake world: standing trees, a felled stump, a lying log, trees on another farm's land and one just outside the area
whose crown reaches in; a bush foliage layer; two farmlands. Marks an area, counts it, bulldozes it, and checks that
only the right trees and bushes went, that the farm paid the bulldozer's fee per tree plus the bush rate, in single
player, through the two network events (client/server round trip), through the construction brush, and in the refusal
cases (no money, no permission, area too large, nothing there). Also checks how the tree fee is found (game getter,
constant, fallback).

Usage: python tools/test/run_stub.py
"""
import re
import sys
from pathlib import Path

from lupa import lua51

MOD_DIR = Path(__file__).resolve().parent.parent.parent

PRELUDE = r"""
-- ---------------------------------------------------------------- engine / game stubs
g_currentModName = "FS25_MassTreeExterminator"
g_currentModDirectory = "MODDIR/"
LOG = {}
local function fmt(f, ...) if select("#", ...) > 0 then return string.format(f, ...) end return tostring(f) end
Logging = {
    info = function(f, ...) LOG[#LOG+1] = "I " .. fmt(f, ...) end,
    warning = function(f, ...) LOG[#LOG+1] = "W " .. fmt(f, ...) end,
}
function Class(members, baseClass)
    if baseClass ~= nil then setmetatable(members, {__index = baseClass}) end
    members.superClass = function() return baseClass end
    return {__index = members}
end
Event = {}
function Event.new(mt) return setmetatable({}, mt) end
EVENT_CLASSES = {}
function InitEventClass(cls, name) EVENT_CLASSES[name] = cls; cls.className = name end

STREAMS = {}
local function q(id) STREAMS[id] = STREAMS[id] or {}; return STREAMS[id] end
function streamWriteUIntN(id, v, bits) assert(v >= 0 and v < 2^bits, "uint out of range"); table.insert(q(id), v) end
function streamReadUIntN(id, bits) return table.remove(q(id), 1) end
function streamWriteBool(id, v) table.insert(q(id), v) end
function streamReadBool(id) return table.remove(q(id), 1) end
function streamWriteFloat32(id, v) table.insert(q(id), v) end
function streamReadFloat32(id) return table.remove(q(id), 1) end
FarmManager = {FARM_ID_SEND_NUM_BITS = 4}

TEXTS = TEXTS or {}
g_i18n = {
    getText = function(_, key) return TEXTS[key] or ("<" .. key .. ">") end,
    formatMoney = function(_, v) return string.format("$%d", math.floor(v + 0.5)) end,
}
CONSOLE = {}
function addConsoleCommand(name, desc, fn, target) CONSOLE[name] = {fn = fn, target = target} end
function removeConsoleCommand(name) CONSOLE[name] = nil end
LISTENERS = {}
function addModEventListener(l) LISTENERS[#LISTENERS+1] = l end
BRUSH_TYPES = {}
g_constructionBrushTypeManager = {
    addBrushType = function(_, name, className, filename) BRUSH_TYPES[name] = {className = className, filename = filename} end,
    getClassObjectByTypeName = function(_, name) if name == "destruct" then return ConstructionBrushDestruct end end,
}

-- ---------------------------------------------------------------- trees (split shapes)
ClassIds = {MESH_SPLIT_SHAPE = 11, SHAPE = 12}
RigidBodyType = {STATIC = 1, DYNAMIC = 2, KINEMATIC = 3}
CollisionFlag = {TREE = 2^8}
TREES = {}           -- shape -> {x, y, z, splitType, rigid, split, crown, price}
DELETED = {}
REMOVING = {}
NEXT_SHAPE = 1000
function addTree(x, z, opts)
    opts = opts or {}
    NEXT_SHAPE = NEXT_SHAPE + 1
    TREES[NEXT_SHAPE] = {x = x, y = 100, z = z, splitType = opts.splitType or 3, rigid = opts.rigid or RigidBodyType.STATIC,
                         split = opts.split or false, crown = opts.crown or 3, price = opts.price or 100}
    return NEXT_SHAPE
end
function entityExists(id) return TREES[id] ~= nil end
function getHasClassId(id, classId) return TREES[id] ~= nil and classId == ClassIds.MESH_SPLIT_SHAPE end
function getSplitType(id) return TREES[id].splitType end
function getRigidBodyType(id) return TREES[id].rigid end
function getIsSplitShapeSplit(id) return TREES[id].split end
function getWorldTranslation(id) local t = TREES[id]; return t.x, t.y, t.z end
function delete(id) error("trees must be removed with deleteSplitShape (a plain delete leaves the LOD1 model standing)") end
-- like in game (1.25.1.0): deleting a whole standing tree leaves a stump behind, a new static split shape
STUMPS = {}
function deleteSplitShape(id)
    local t = TREES[id]
    assert(t ~= nil, "delete of a missing node")
    DELETED[#DELETED+1] = id
    TREES[id] = nil
    if not t.split and not t.isStump then
        local stump = addTree(t.x + 0.2, t.z, {split = true, crown = 0.4})
        TREES[stump].isStump = true
        STUMPS[#STUMPS+1] = stump
    end
end
function overlapSphere(x, y, z, r, cbName, target, mask, incDyn, incKin, incStatic, exact)
    assert(mask == CollisionFlag.TREE, "tree mask")
    local ids = {}
    for id in pairs(TREES) do ids[#ids+1] = id end
    table.sort(ids)
    for _, id in ipairs(ids) do
        local t = TREES[id]
        if t ~= nil and math.sqrt((t.x - x)^2 + (t.z - z)^2) <= r + t.crown then target[cbName](target, id, 0) end
    end
end
function finishJobs()   -- runs the server's jobs to the end (acts as the server while it does)
    local saved = g_server
    g_server = g_server or {}
    for i = 1, 30 do
        if #MassTreeExterminator.jobs == 0 then break end
        g_time = g_time + 300; MassTreeExterminator:update(300)
    end
    g_server = saved
end
function stumpsLeft() local n = 0 for _, s in ipairs(STUMPS) do if TREES[s] ~= nil then n = n + 1 end end return n end
OVERLAP_CALLS = 0
function overlapBox(cx, cy, cz, rx, ry, rz, ex, ey, ez, cbName, target, mask, incDyn, incKin, incStatic, exact)
    assert(mask == CollisionFlag.TREE, "tree mask")
    assert(type(target[cbName]) == "function", "callback")
    OVERLAP_CALLS = OVERLAP_CALLS + 1
    local ids = {}
    for id in pairs(TREES) do ids[#ids+1] = id end
    table.sort(ids)
    local n = 0
    for _, id in ipairs(ids) do
        local t = TREES[id]
        -- the box hits a tree when its crown (AABB) reaches in, like the engine
        if math.abs(t.x - cx) <= ex + t.crown and math.abs(t.z - cz) <= ez + t.crown then
            n = n + 1
            local stop = target[cbName](target, id, 0)
            if stop == true then break end
        end
    end
    return n
end
g_treePlantManager = {removingSplitShape = function(_, shape) REMOVING[#REMOVING+1] = shape end}
DIRTY = {}
g_densityMapHeightManager = {setCollisionMapAreaDirty = function(_, x1, z1, x2, z2, b) DIRTY[#DIRTY+1] = "collision" end}

-- ---------------------------------------------------------------- farmland: farm 1 owns x < 100, farm 2 the rest
g_farmlandManager = {getOwnerIdAtWorldPosition = function(_, x, z) if x < 100 then return 1 end return 2 end}

-- ---------------------------------------------------------------- bush layer: one point = one pixel (0.25 m2)
g_terrainNode = 1
function getTerrainHeightAtWorldPos() return 100 end
BUSH = {}   -- list of {x, z, v}
function addBushes(x0, z0, x1, z1, step)
    local x = x0
    while x < x1 do
        local z = z0
        while z < z1 do BUSH[#BUSH+1] = {x = x, z = z, v = 3}; z = z + step end
        x = x + step
    end
end
function bushCount(pred) local n = 0 for _, p in ipairs(BUSH) do if p.v > 0 and (pred == nil or pred(p)) then n = n + 1 end end return n end
function getTerrainDataPlaneByName(terrain, name) if name == "decoBush" then return 77 end return 0 end
function getTerrainDetailNumChannels(id) return 4 end
function getDensityMapSize(id) return 4096 end
DensityCoordType = {POINT_POINT_POINT = 0}
DensityValueCompareType = {EQUAL = 1, GREATER = 2, BETWEEN = 3}
DensityMapModifier = {}
DensityMapModifier.__index = DensityMapModifier
function DensityMapModifier.new(id, first, num, terrain)
    assert(id == 77 and first == 0 and num == 4 and terrain == 1, "bush modifier args")
    return setmetatable({}, DensityMapModifier)
end
function DensityMapModifier:setParallelogramWorldCoords(sx, sz, wx, wz, hx, hz, t)
    assert(t == 0 and wz == sz and hx == sx, "axis-aligned strip")
    self.x0, self.z0, self.x1, self.z1 = sx, sz, wx, hz
end
function DensityMapModifier:inside(p) return p.x >= self.x0 and p.x < self.x1 and p.z >= self.z0 and p.z < self.z1 end
function DensityMapModifier:executeGet(filter)
    assert(filter.mode == DensityValueCompareType.GREATER and filter.a == 0)
    local n = 0
    for _, p in ipairs(BUSH) do if p.v > 0 and self:inside(p) then n = n + 1 end end
    return 0, n, 0
end
function DensityMapModifier:executeSet(value, filter)
    for _, p in ipairs(BUSH) do if p.v > 0 and self:inside(p) then p.v = value end end
end
DensityMapFilter = {}
DensityMapFilter.__index = DensityMapFilter
function DensityMapFilter.new(m) return setmetatable({}, DensityMapFilter) end
function DensityMapFilter:setValueCompareParams(mode, a, b) self.mode, self.a, self.b = mode, a, b end
Landscaping = {PAINT_BASE_COST_PER_M2 = 2}

-- ---------------------------------------------------------------- the game's demolition brush (1.25.1.0 tree fee)
ConstructionBrush = {}
local ConstructionBrush_mt = Class(ConstructionBrush)
function ConstructionBrush.new(mt, cursor)
    return setmetatable({isActive = false, cursor = cursor, inputTextDirty = true}, mt or ConstructionBrush_mt)
end
function ConstructionBrush:activate() self.isActive = true end
function ConstructionBrush:deactivate() self.isActive = false end
function ConstructionBrush:setInputTextDirty() self.inputTextDirty = true end
ConstructionBrushDestruct = {}
local ConstructionBrushDestruct_mt = Class(ConstructionBrushDestruct, ConstructionBrush)
function ConstructionBrushDestruct.new(mt, cursor)
    return ConstructionBrush.new(mt or ConstructionBrushDestruct_mt, cursor)
end
function ConstructionBrushDestruct:onButtonPrimary() error("must never be called by the mod") end
FEE_MODE = "argument"
function ConstructionBrushDestruct:getTreeRemovalPrice(tree)
    if FEE_MODE == "cursor" then tree = self.cursor:getHitNode() end
    local t = TREES[tree]
    return t ~= nil and t.price or nil
end

-- ---------------------------------------------------------------- mission, farms, money
MoneyType = {OTHER = "other", SHOP_PROPERTY_BUY = "propertyBuy"}
MONEY = {}
BALANCE = {[1] = 100000, [2] = 100000}
Farm = {PERMISSION = {LANDSCAPING = "landscaping"}}
PERMISSION = true
PLAYERS = {}
g_farmManager = {getFarmById = function(_, id) return {getBalance = function() return BALANCE[id] end} end}
g_currentMission = {
    terrainSize = 2048,
    foliageSystem = {paintableFoliages = {{layerName = "meadow"}, {layerName = "decoBush"}}},
    aiSystem = {setAreaDirty = function() DIRTY[#DIRTY+1] = "ai" end},
    playerSystem = {getPlayerByConnection = function(_, c) return PLAYERS[c] end},
    addMoney = function(_, amount, farmId, moneyType, addChange, force)
        MONEY[#MONEY+1] = {amount = amount, farmId = farmId, moneyType = moneyType}
        BALANCE[farmId] = BALANCE[farmId] + amount
    end,
    getHasPlayerPermission = function(_, perm, connection) assert(perm == "landscaping"); return PERMISSION end,
    getFarmId = function() return 1 end,
}
g_localPlayer = {farmId = 1}
g_time = 0
DRAWN = 0
function drawDebugLine() DRAWN = DRAWN + 1 end

-- network: the client connection serialises the event and runs it on the "server" with the client's connection
SERVER_CONN = {}
CLIENT_CONN = {}
function SERVER_CONN:sendEvent(event)   -- server -> client
    event:writeStream("s2c", CLIENT_CONN)
    local copy = EVENT_CLASSES[event.className or getmetatable(event).__index.className].emptyNew()
    local savedServer = g_server
    g_server = nil
    copy:readStream("s2c", SERVER_CONN)
    g_server = savedServer
end
function CLIENT_CONN:sendEvent(event)   -- client -> server
    event:writeStream("c2s", SERVER_CONN)
    local cls = getmetatable(event).__index
    local copy = cls.emptyNew()
    local savedServer = g_server
    g_server = {}
    copy:readStream("c2s", SERVER_CONN)
    g_server = savedServer
end
g_client = {getServerConnection = function() return CLIENT_CONN end}

-- dialogs and cursor
DIALOG_ANSWER = true
DIALOGS = {}
YesNoDialog = {show = function(callback, target, text) DIALOGS[#DIALOGS+1] = text; callback(DIALOG_ANSWER) end}
GuiTopDownCursor = {SHAPES = {CIRCLE = 1}, SHAPES_COLORS = {SUCCESS = 1, SELECT = 2}}
function makeCursor()
    local c = {x = 0, y = 100, z = 0, messages = {}, errors = {}}
    function c:getPosition() return self.x, self.y, self.z end
    function c:setMessage(m) self.messages[#self.messages+1] = m end
    function c:setErrorMessage(m) self.errors[#self.errors+1] = m end
    function c:setRotationEnabled() end
    function c:setShape() end
    function c:setShapeSize() end
    function c:setColorMode(m) self.colorMode = m end
    function c:setTerrainOnly() end
    return c
end
"""


def load_texts(lua):
    xml = (MOD_DIR / "translations" / "translation_en.xml").read_text(encoding="utf-8")
    texts = lua.eval("{}")
    for name, value in re.findall(r'<text name="([^"]+)" text="([^"]*)"', xml):
        texts[name] = value.replace("&amp;", "&")
    lua.globals().TEXTS = texts


def fresh():
    lua = lua51.LuaRuntime(unpack_returned_tuples=True)
    load_texts(lua)
    lua.execute(PRELUDE)
    for rel in ("scripts/events/MassTreeExterminatorRemoveEvent.lua", "scripts/events/MassTreeExterminatorResultEvent.lua",
                "scripts/MassTreeExterminator.lua", "scripts/ConstructionBrushMassTreeExterminator.lua"):
        lua.execute((MOD_DIR / rel).read_text(encoding="utf-8"))
    lua.execute("MassTreeExterminator:loadMap('test')")
    return lua


def world(lua):
    """The test area is x 0..150, z 0..50. Farm 1 owns x < 100."""
    return lua.execute(r"""
        local W = {}
        W.own1 = addTree(10, 10, {price = 100})
        W.own2 = addTree(20, 20, {price = 120})
        W.own3 = addTree(90, 40, {price = 130})
        W.other = addTree(120, 10, {price = 500})                       -- farm 2's land
        W.outside = addTree(-2, 10, {price = 999})                      -- own land, crown reaches in, trunk outside
        W.log = addTree(30, 30, {rigid = RigidBodyType.DYNAMIC})        -- a felled log lying around
        W.stump = addTree(40, 40, {split = true})                       -- a felled tree's stump
        W.noSplit = addTree(50, 10, {splitType = 0})                    -- not a tree
        W.far = addTree(500, 500, {price = 1})
        addBushes(60, 0, 65, 5, 0.5)     -- own land: 100 pixels = 25 m2
        addBushes(110, 0, 112, 5, 0.5)   -- farm 2's land: 40 pixels
        addBushes(-10, 0, -5, 5, 0.5)    -- outside the area: 100 pixels
        return W
    """)


def check(cond, message):
    if not cond:
        raise AssertionError(message)


def log_lines(lua):
    return list(lua.globals().LOG.values())


def test_single_player():
    lua = fresh()
    g = lua.globals()
    lua.execute("g_server = {}")
    w = world(lua)
    MTE = g.MassTreeExterminator
    MTE.addCorner(0, 100, 0)
    check(MTE.rect is None, "one corner: no area yet")
    MTE.addCorner(150, 100, 50)
    p = MTE.preview
    check(len(p.trees) == 3, f"3 own trees counted, got {len(p.trees)}")
    check(len(p.denied) == 1, "1 tree on farm 2's land")
    check(abs(p.bushM2 - 25) < 1e-6, f"25 m2 bushes on own land, got {p.bushM2}")
    check(abs(p.treeCost - 350) < 1e-6, f"tree fee = the game's price per tree, got {p.treeCost}")
    check(abs(p.cost - (350 + 25 * 2)) < 1e-6, f"total cost, got {p.cost}")
    check(MTE.fee.kind == "method" and "getTreeRemovalPrice" in MTE.fee.label, "fee from the game's getter")
    check(MTE.hasWork(), "something to do")
    status = MTE.drawSelection(None, None)
    check("3 trees" in status and "25 m² bushes" in status and "$400" in status and "1 trees on land" in status, status)

    MTE.requestRemove()
    check(len(g.MONEY) == 0, "charged only when the job is done")
    lua.execute("finishJobs()")
    gone = {k for k in (w.own1, w.own2, w.own3, w.other, w.outside, w.log, w.stump, w.noSplit, w.far) if g.TREES[k] is None}
    check(gone == {w.own1, w.own2, w.own3}, f"exactly the own standing trees went: {gone}")
    check(lua.eval("#STUMPS") == 3 and lua.eval("stumpsLeft()") == 0, "the stumps they left behind went too")
    check(set(g.REMOVING.values()) == set(g.DELETED.values()), "tree manager told about each removed shape")
    check(any("stump left at a removed tree" in l for l in log_lines(lua)), "stump logged once")
    check(len(g.MONEY) == 1 and g.MONEY[1].amount == -400 and g.MONEY[1].farmId == 1, "farm 1 paid 400 once")
    check(lua.eval("bushCount(function(p) return p.x >= 60 and p.x < 65 end)") == 0, "own bushes cleared")
    check(lua.eval("bushCount(function(p) return p.x >= 110 end)") == 40, "farm 2's bushes stay")
    check(lua.eval("bushCount(function(p) return p.x < 0 end)") == 100, "bushes outside the area stay")
    check(lua.eval("#DIRTY") == 2, "collision map and AI marked dirty")
    msg = MTE.lastMessage
    check(msg is not None and not msg.isWarning and "Bulldozed 3 trees and 25 m²" in msg.text and "$400" in msg.text, msg and msg.text)

    # counting again after the removal: only the other farm's tree is left
    MTE.refreshPreview()
    check(len(MTE.preview.trees) == 0 and len(MTE.preview.denied) == 1 and not MTE.hasWork(), "nothing left to do")
    MTE.requestRemove()
    check(g.MassTreeExterminator.lastMessage.isWarning and "Nothing to bulldoze" in MTE.lastMessage.text, "nothing message")
    check(len(g.MONEY) == 1, "nothing charged the second time")


def test_multiplayer_round_trip():
    lua = fresh()
    g = lua.globals()
    lua.execute("g_server = nil; PLAYERS[SERVER_CONN] = {farmId = 1}; g_localPlayer = {farmId = 2}")  # the client claims farm 2
    w = world(lua)
    MTE = g.MassTreeExterminator
    MTE.addCorner(150, 100, 50)
    MTE.addCorner(0, 100, 0)
    MTE.requestRemove()
    lua.execute("finishJobs()")
    gone = {k for k in (w.own1, w.own2, w.own3, w.other) if g.TREES[k] is None}
    check(gone == {w.own1, w.own2, w.own3}, f"server took the farm from the connection (farm 1): {gone}")
    check(g.MONEY[1].amount == -400 and g.MONEY[1].farmId == 1, "farm 1 charged")
    check("Bulldozed 3 trees" in MTE.lastMessage.text, "result reached the client")


def test_refusals():
    lua = fresh()
    g = lua.globals()
    lua.execute("g_server = nil; PLAYERS[SERVER_CONN] = {farmId = 1}")
    w = world(lua)
    MTE = g.MassTreeExterminator
    MTE.addCorner(0, 100, 0)
    MTE.addCorner(150, 100, 50)

    lua.execute("BALANCE[1] = 399")
    MTE.requestRemove()
    check(len(g.DELETED) == 0 and len(g.MONEY) == 0, "not enough money: nothing removed or charged")
    check(MTE.lastMessage.isWarning and "$400" in MTE.lastMessage.text, MTE.lastMessage.text)
    check(lua.eval("bushCount()") == 240, "no bush touched")

    lua.execute("BALANCE[1] = 100000; PERMISSION = false")
    MTE.requestRemove()
    check(len(g.DELETED) == 0 and "permission" in MTE.lastMessage.text, "no permission refused")

    lua.execute("PERMISSION = true")
    MTE.clearSelection()
    MTE.addCorner(0, 100, 0)
    MTE.addCorner(1200, 100, 10)
    check(MTE.preview.tooLarge and not MTE.hasWork(), "too large in the preview")
    check("too large" in MTE.drawSelection(None, None), "too large message")
    MTE.requestRemove()
    check(len(g.DELETED) == 0 and "too large" in MTE.lastMessage.text, "too large refused by the server")


def test_fee_sources():
    # the fee getter that reads the tree under the cursor
    lua = fresh()
    g = lua.globals()
    lua.execute("g_server = {}; FEE_MODE = 'cursor'")
    world(lua)
    MTE = g.MassTreeExterminator
    MTE.addCorner(0, 100, 0)
    MTE.addCorner(150, 100, 50)
    check(abs(MTE.preview.treeCost - 350) < 1e-6, f"cursor-based getter priced each tree, got {MTE.preview.treeCost}")

    # the 1.25.1.0 way: no getter, the bulldozer prices the tree it hovers and formats it for the cursor
    lua = fresh()
    g = lua.globals()
    lua.execute(r"""
        g_server = {}
        ConstructionBrushDestruct.getTreeRemovalPrice = nil
        HIGHLIGHTED = {}
        function ConstructionBrushDestruct:visualizeTreeMouseOver(tree)
            if tree == self.hoveredTree then return end
            if self.hoveredTree ~= nil then HIGHLIGHTED[self.hoveredTree] = nil end
            self.hoveredTree = tree
            if tree ~= nil and TREES[tree] ~= nil then
                HIGHLIGHTED[tree] = true
                -- like 1.25.1.0: formatted without g_i18n:formatMoney, e.g. "$ 1,818" (seen in the game's log)
                local p = TREES[tree].price * 2 + 1000
                self.cursor:setMessage(string.format("$ %d,%03d", math.floor(p / 1000), p % 1000))
            end
        end
    """)
    world(lua)
    MTE = g.MassTreeExterminator
    MTE.addCorner(0, 100, 0)
    MTE.addCorner(150, 100, 50)
    check(MTE.fee.kind == "hover", f"hover price used, got {MTE.fee.kind}")
    check(abs(MTE.preview.treeCost - 3700) < 1e-6, f"each tree at the bulldozer's hover price, got {MTE.preview.treeCost}")
    check(lua.eval("next(HIGHLIGHTED)") is None, "the probe left no tree highlighted")
    check(lua.eval("rawget(g_i18n, 'formatMoney') ~= nil and g_i18n:formatMoney(5) == '$5'"), "formatMoney restored")
    check(any("hover price probe:" in l and "cursor:setMessage($ 1,200)" in l for l in log_lines(lua)), "first probe logged")
    check(not MTE.isFeeEstimated(), "not an estimate")
    for text, value in (("$ 1,818", 1818), ("1.818 €", 1818), ("1 818 $", 1818), ("£ 250", 250), ("1'234'567 CHF", 1234567),
                        ("no price", None)):
        got = MTE.parseMoneyText(text)
        check(got == value, f"parseMoneyText({text!r}) = {got}, expected {value}")

    # a constant only
    lua = fresh()
    g = lua.globals()
    lua.execute("g_server = {}; ConstructionBrushDestruct.getTreeRemovalPrice = nil; ConstructionBrushDestruct.TREE_REMOVAL_PRICE = 300")
    world(lua)
    MTE = g.MassTreeExterminator
    MTE.addCorner(0, 100, 0)
    MTE.addCorner(150, 100, 50)
    check(MTE.fee.kind == "constant" and abs(MTE.preview.treeCost - 900) < 1e-6, "constant fee per tree")

    # nothing in the game (older than 1.25.1.0): fallback, flagged as estimated and logged
    lua = fresh()
    g = lua.globals()
    lua.execute("g_server = {}; ConstructionBrushDestruct = nil")
    world(lua)
    MTE = g.MassTreeExterminator
    MTE.addCorner(0, 100, 0)
    MTE.addCorner(150, 100, 50)
    check(MTE.fee.kind == "fallback" and abs(MTE.preview.treeCost - 3 * MTE.FALLBACK_TREE_FEE) < 1e-6, "fallback fee")
    check("estimated" in MTE.drawSelection(None, None), "estimated fee shown")
    check(any(line.startswith("W ") and "tree fee was not found" in line for line in log_lines(lua)), "fallback warned in the log")


def raises(fn, text):
    try:
        fn()
    except Exception as e:  # noqa: BLE001 - lupa.LuaError
        return text in str(e)
    return False


def test_fee_errors_show_and_recover():
    # the bulldozer's hover price raises an error: it is not hidden, the next count undoes the probe and uses the getter
    lua = fresh()
    g = lua.globals()
    lua.execute(r"""
        g_server = {}
        ORIGINAL_FORMAT_MONEY = g_i18n.formatMoney
        function ConstructionBrushDestruct:visualizeTreeMouseOver(tree)
            if tree ~= nil then error("hover broke") end
        end
    """)
    world(lua)
    MTE = g.MassTreeExterminator
    MTE.addCorner(0, 100, 0)
    check(raises(lambda: MTE.addCorner(150, 100, 50), "hover broke"), "the hover error is raised, not swallowed")
    MTE.refreshPreview()
    check(lua.eval("g_i18n.formatMoney == ORIGINAL_FORMAT_MONEY"), "formatMoney restored after the failed probe")
    check(MTE.fee.kind == "method" and abs(MTE.preview.treeCost - 350) < 1e-6, "fee from the getter after the failed hover")
    check(any(line.startswith("W ") and "hover price raised an error" in line for line in log_lines(lua)), "failed hover warned")

    # a fee getter that raises an error: shown once, then skipped (here: the constant is used)
    lua = fresh()
    g = lua.globals()
    lua.execute(r"""
        g_server = {}
        function ConstructionBrushDestruct:getTreeRemovalPrice(tree) error("getter broke") end
        ConstructionBrushDestruct.TREE_REMOVAL_PRICE = 300
    """)
    world(lua)
    MTE = g.MassTreeExterminator
    MTE.addCorner(0, 100, 0)
    check(raises(lambda: MTE.addCorner(150, 100, 50), "getter broke"), "the getter error is raised, not swallowed")
    MTE.refreshPreview()
    check(MTE.fee.kind == "constant" and abs(MTE.preview.treeCost - 900) < 1e-6, "failed getter skipped, constant used")
    MTE.refreshPreview()
    check(abs(MTE.preview.treeCost - 900) < 1e-6, "counts again without an error")

    # a translation with a wrong placeholder: the text is shown unformatted instead of an error
    check(MTE.text("mte_hud_denied", "x") == g.TEXTS["mte_hud_denied"], "mismatched argument: raw text")
    check(MTE.canFormat("%d trees, %s", 3, "a") and not MTE.canFormat("%d trees", None) and not MTE.canFormat("%s %s", "a"),
          "canFormat")


def test_batches_and_bushes_off():
    lua = fresh()
    g = lua.globals()
    lua.execute("g_server = {}")
    lua.execute("for i = 1, 250 do addTree(i * 0.3, 5, {price = 10}) end")
    lua.execute("addBushes(1, 20, 3, 22, 0.5)")
    MTE = g.MassTreeExterminator
    g.CONSOLE.mteBushes.target.consoleBushes(g.CONSOLE.mteBushes.target)
    check(not MTE.removeBushes, "bushes off")
    MTE.addCorner(0, 100, 0)
    MTE.addCorner(99, 100, 30)
    check(len(MTE.preview.trees) == 250 and MTE.preview.bushM2 == 0, "bushes not counted when off")
    MTE.requestRemove()
    check(len(g.DELETED) == 0, "first frames: the wood around the trees is recorded first")
    for _ in range(2):   # 250 trees: three scan batches, the last frame of scanning also deletes the first 100
        MTE.update(MTE, 16)
    check(len(g.DELETED) == 100 and len(g.MONEY) == 0, "first batch of 100, charged at the end")
    MTE.update(MTE, 16)
    check(len(g.DELETED) == 200, "second batch")
    MTE.update(MTE, 16)
    check(lua.eval("stumpsLeft()") == 0 and len(g.MONEY) == 0, "last batch, stumps of close trees swept, waiting for the second sweep")
    lua.execute("finishJobs()")
    check(len(g.MONEY) == 1 and g.MONEY[1].amount == -2500, "done and charged 250 x 10")
    check(lua.eval("bushCount()") == 16, "bushes untouched when off")


def test_brush():
    lua = fresh()
    g = lua.globals()
    lua.execute("g_server = {}")
    world(lua)
    check(g.BRUSH_TYPES.massTreeExterminator.className == "ConstructionBrushMassTreeExterminator", "brush type registered")
    lua.execute("CURSOR = makeCursor(); BRUSH = ConstructionBrushMassTreeExterminator.new(nil, CURSOR); BRUSH:activate()")
    brush, cursor = g.BRUSH, g.CURSOR
    check(brush.getButtonPrimaryText(brush) == "Set first corner", "first corner text")
    brush.onButtonPrimary(brush)
    check(brush.getButtonPrimaryText(brush) == "Set opposite corner", "second corner text")
    check(brush.getButtonSecondaryText(brush) == "Remove last corner", "right click text")
    cursor.x, cursor.z = 150, 50
    brush.draw(brush)
    brush.onButtonPrimary(brush)
    brush.update(brush, 16)
    check(brush.getButtonPrimaryText(brush) == "Bulldoze area ($400)", brush.getButtonPrimaryText(brush))
    check(cursor.colorMode == 2, "select colour with work to do")
    brush.draw(brush)
    check(g.DRAWN > 0, "area and markers drawn")

    lua.execute("DIALOG_ANSWER = false")
    brush.onButtonPrimary(brush)
    check(len(g.DIALOGS) == 1 and "Bulldoze 3 trees and 25 m² of bushes for $400?" == g.DIALOGS[1], g.DIALOGS[1])
    check(len(g.DELETED) == 0, "answered no: nothing removed")
    lua.execute("DIALOG_ANSWER = true")
    brush.onButtonPrimary(brush)
    lua.execute("finishJobs()")
    check(lua.eval("#STUMPS") == 3 and g.MONEY[1].amount == -400, "answered yes: bulldozed and charged")
    brush.draw(brush)
    check(any("Bulldozed 3 trees" in m for m in cursor.messages.values()), "result shown at the cursor")

    check(brush.canCancel(brush), "Esc can clear")
    brush.cancel(brush)
    check(len(g.MassTreeExterminator.corners) == 0, "cleared")
    brush.deactivate(brush)


def test_console():
    lua = fresh()
    g = lua.globals()
    lua.execute("g_server = {}")
    world(lua)
    info = g.CONSOLE.mteInfo
    out = info.target[info.fn](info.target)
    check("log.txt" in out, out)
    lines = log_lines(lua)
    check(any("fee getter candidates: ConstructionBrushDestruct:getTreeRemovalPrice" in l for l in lines), "getter listed")
    check(any("bush layers: decoBush" in l for l in lines), "bush layer found")
    trace = g.CONSOLE.mteTrace
    out = trace.target[trace.fn](trace.target)
    check("trace ON" in out, out)
    lua.execute("ConstructionBrushDestruct.getTreeRemovalPrice(ConstructionBrushDestruct.new(nil, makeCursor()), next(TREES))")
    lua.execute("g_currentMission:addMoney(-5, 1, MoneyType.OTHER)")
    lua.execute("CLIENT_CONN:sendEvent(MassTreeExterminatorRemoveEvent.new({farmId = 1, rect = {0, 0, 1, 1}, bushes = false}))")
    lines = log_lines(lua)
    check(any("trace destruct:getTreeRemovalPrice" in l for l in lines), "brush call traced")
    check(any("trace addMoney(-5, farm 1" in l for l in lines), "money traced")
    check(any("trace sendEvent <MassTreeExterminatorRemoveEvent>" in l for l in lines), "event traced")
    out = trace.target[trace.fn](trace.target)
    check("OFF" in out and lua.eval("rawget(CLIENT_CONN, 'sendEvent') ~= nil"), "trace off restores the connection")
    g.MassTreeExterminator.deleteMap(g.MassTreeExterminator)
    check(lua.eval("next(CONSOLE)") is None, "console commands removed")


def test_stump_sweep_spares_neighbours():
    lua = fresh()
    g = lua.globals()
    lua.execute("g_server = {}")
    own = lua.eval("addTree(0.5, 20, {price = 100})")
    neighbour = lua.eval("addTree(-0.6, 20, {price = 100})")          # 1.1 m away, trunk outside the area
    old_stump = lua.eval("addTree(1.2, 20.5, {split = true})")         # an old stump right next to it
    MTE = g.MassTreeExterminator
    MTE.addCorner(0, 100, 0)
    MTE.addCorner(50, 100, 50)
    check(len(MTE.preview.trees) == 1, "only the tree inside the area")
    MTE.requestRemove()
    lua.execute("finishJobs()")
    check(g.TREES[own] is None and lua.eval("stumpsLeft()") == 0, "tree and its new stump gone")
    check(g.TREES[neighbour] is not None, "neighbouring tree within the sweep radius untouched")
    check(g.TREES[old_stump] is not None, "wood that was there before untouched")
    check(g.MONEY[1].amount == -100, "stump free, tree at its fee")


TESTS = [test_single_player, test_stump_sweep_spares_neighbours, test_multiplayer_round_trip, test_refusals, test_fee_sources,
         test_fee_errors_show_and_recover, test_batches_and_bushes_off,
         test_brush, test_console]


def main():
    failed = 0
    for test in TESTS:
        try:
            test()
            print(f"ok      {test.__name__}")
        except Exception as e:  # noqa: BLE001 - report every failing test
            failed += 1
            print(f"FAILED  {test.__name__}: {e}")
    if failed:
        print(f"{failed} of {len(TESTS)} failed")
        return 1
    print(f"all {len(TESTS)} passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
