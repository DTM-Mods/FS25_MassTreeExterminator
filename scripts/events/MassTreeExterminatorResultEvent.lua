-- Mass Tree Exterminator: server -> requesting client "this is what was bulldozed and what it cost".
-- Only shows a message at that player's cursor.
MassTreeExterminatorResultEvent = {}
local MassTreeExterminatorResultEvent_mt = Class(MassTreeExterminatorResultEvent, Event)

InitEventClass(MassTreeExterminatorResultEvent, "MassTreeExterminatorResultEvent")

local REASON_BITS = 3
local COUNT_BITS = 20   -- up to about a million trees

function MassTreeExterminatorResultEvent.emptyNew()
    return Event.new(MassTreeExterminatorResultEvent_mt)
end

--- @param result table {reason=, numTrees=, numDenied=, bushM2=, cost=}
function MassTreeExterminatorResultEvent.new(result)
    local self = MassTreeExterminatorResultEvent.emptyNew()
    self.result = result
    return self
end

local function clampCount(v)
    return math.max(0, math.min(math.floor(v or 0), 2 ^ COUNT_BITS - 1))
end

function MassTreeExterminatorResultEvent:readStream(streamId, connection)
    self.result = {
        reason = streamReadUIntN(streamId, REASON_BITS),
        numTrees = streamReadUIntN(streamId, COUNT_BITS),
        numDenied = streamReadUIntN(streamId, COUNT_BITS),
        bushM2 = streamReadFloat32(streamId),
        cost = streamReadFloat32(streamId),
    }
    self:run(connection)
end

function MassTreeExterminatorResultEvent:writeStream(streamId, connection)
    local r = self.result
    streamWriteUIntN(streamId, math.max(0, math.min(r.reason or 0, 2 ^ REASON_BITS - 1)), REASON_BITS)
    streamWriteUIntN(streamId, clampCount(r.numTrees), COUNT_BITS)
    streamWriteUIntN(streamId, clampCount(r.numDenied), COUNT_BITS)
    streamWriteFloat32(streamId, r.bushM2 or 0)
    streamWriteFloat32(streamId, r.cost or 0)
end

function MassTreeExterminatorResultEvent:run(connection)
    if MassTreeExterminator ~= nil then
        MassTreeExterminator.onResult(self.result)
    end
end
