-- Mass Tree Exterminator: client -> server request "bulldoze the trees (and bushes) in this area".
-- The server does the work (split shape removal and density map writes only replicate from the server) and answers
-- the requesting client with a MassTreeExterminatorResultEvent. The farm is taken from the connection on the server.
MassTreeExterminatorRemoveEvent = {}
local MassTreeExterminatorRemoveEvent_mt = Class(MassTreeExterminatorRemoveEvent, Event)

InitEventClass(MassTreeExterminatorRemoveEvent, "MassTreeExterminatorRemoveEvent")

local FARM_ID_BITS = (FarmManager ~= nil and FarmManager.FARM_ID_SEND_NUM_BITS) or 4

function MassTreeExterminatorRemoveEvent.emptyNew()
    return Event.new(MassTreeExterminatorRemoveEvent_mt)
end

--- @param request table {farmId=, rect={minX, minZ, maxX, maxZ}, bushes=bool}
function MassTreeExterminatorRemoveEvent.new(request)
    local self = MassTreeExterminatorRemoveEvent.emptyNew()
    self.request = request
    return self
end

function MassTreeExterminatorRemoveEvent:readStream(streamId, connection)
    local request = {}
    request.farmId = streamReadUIntN(streamId, FARM_ID_BITS)
    request.bushes = streamReadBool(streamId)
    request.rect = {streamReadFloat32(streamId), streamReadFloat32(streamId), streamReadFloat32(streamId), streamReadFloat32(streamId)}
    self.request = request
    self:run(connection)
end

function MassTreeExterminatorRemoveEvent:writeStream(streamId, connection)
    local request = self.request
    streamWriteUIntN(streamId, request.farmId or 0, FARM_ID_BITS)
    streamWriteBool(streamId, request.bushes == true)
    local r = request.rect
    streamWriteFloat32(streamId, r[1])
    streamWriteFloat32(streamId, r[2])
    streamWriteFloat32(streamId, r[3])
    streamWriteFloat32(streamId, r[4])
end

function MassTreeExterminatorRemoveEvent:run(connection)
    -- only the server acts on it; connection is the requesting client's connection
    if g_server ~= nil and MassTreeExterminator ~= nil then
        MassTreeExterminator.serverRemove(self.request, connection)
    end
end
