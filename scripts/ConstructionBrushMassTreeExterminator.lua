--[[
    Mass Tree Exterminator - construction screen tool (Shift-P > Landscaping > Mass Tree Exterminator)

    Sourced by g_constructionBrushTypeManager:addBrushType (MassTreeExterminator.lua), not listed in modDesc. Uses the
    screen's top-down camera and cursor like the base game brushes:
      left click   first corner, opposite corner (the area is counted: trees get a red marker, trees on land that is
                   not yours a grey one), then "Bulldoze area": a confirmation with the total fee, like the game's
                   bulldozer asks for one tree. With a finished area that has nothing to remove, a left click starts a
                   new area.
      right click  remove the last corner
      Esc          clear the area
]]

ConstructionBrushMassTreeExterminator = {}
local ConstructionBrushMassTreeExterminator_mt = Class(ConstructionBrushMassTreeExterminator, ConstructionBrush)

function ConstructionBrushMassTreeExterminator.new(subclass_mt, cursor)
    local self = ConstructionBrush.new(subclass_mt or ConstructionBrushMassTreeExterminator_mt, cursor)
    self.supportsPrimaryButton = true
    self.supportsSecondaryButton = true
    if Farm ~= nil and Farm.PERMISSION ~= nil then
        self.requiredPermission = Farm.PERMISSION.LANDSCAPING
    end
    self.activatedTime = 0
    self.textState = nil
    return self
end

function ConstructionBrushMassTreeExterminator:activate()
    ConstructionBrushMassTreeExterminator:superClass().activate(self)
    self.cursor:setRotationEnabled(false)
    self.cursor:setShape(GuiTopDownCursor.SHAPES.CIRCLE)
    self.cursor:setShapeSize(1)
    self.cursor:setColorMode(GuiTopDownCursor.SHAPES_COLORS.SUCCESS)
    self.cursor:setTerrainOnly(true)
    MassTreeExterminator.clearSelection()
    self.activatedTime = g_time or 0
    self.textState = nil
    self:setInputTextDirty()
end

function ConstructionBrushMassTreeExterminator:deactivate()
    MassTreeExterminator.clearSelection()
    self.cursor:setTerrainOnly(false)
    self.cursor:setColorMode(GuiTopDownCursor.SHAPES_COLORS.SELECT, nil)
    ConstructionBrushMassTreeExterminator:superClass().deactivate(self)
end

function ConstructionBrushMassTreeExterminator:canCancel()
    return #MassTreeExterminator.corners > 0
end

function ConstructionBrushMassTreeExterminator:cancel()
    MassTreeExterminator.clearSelection()
    self:setInputTextDirty()
end

function ConstructionBrushMassTreeExterminator:update(dt)
    local MTE = MassTreeExterminator
    local p = MTE.preview
    -- the button texts depend on the corners and the counted fee
    local state = string.format("%d|%s|%s", #MTE.corners, tostring(MTE.hasWork()), tostring(p ~= nil and math.floor(p.cost) or nil))
    if state ~= self.textState then
        self.textState = state
        self:setInputTextDirty()
    end
    if MTE.hasWork() then
        self.cursor:setColorMode(GuiTopDownCursor.SHAPES_COLORS.SELECT)
    else
        self.cursor:setColorMode(GuiTopDownCursor.SHAPES_COLORS.SUCCESS)
    end
end

function ConstructionBrushMassTreeExterminator:draw()
    local MTE = MassTreeExterminator
    local x, _, z = self.cursor:getPosition()
    local status = MTE.drawSelection(x, z)

    local last = MTE.lastMessage
    local now = g_time or 0
    if last ~= nil and last.time >= self.activatedTime and now - last.time < MTE.MESSAGE_MS then
        if last.isWarning then
            self.cursor:setErrorMessage(last.text)
        else
            self.cursor:setMessage(last.text)
        end
    elseif status ~= nil then
        local p = MTE.preview
        if p ~= nil and p.tooLarge then
            self.cursor:setErrorMessage(status)
        else
            self.cursor:setMessage(status)
        end
    else
        self.cursor:setMessage(MTE.text("mte_brush_hint"))
    end
end

function ConstructionBrushMassTreeExterminator:onButtonPrimary()
    local MTE = MassTreeExterminator
    if MTE.hasWork() then
        MTE.confirmAndRequest()
    else
        local x, y, z = self.cursor:getPosition()
        if x == nil then
            return
        end
        MTE.addCorner(x, y, z)
    end
    self:setInputTextDirty()
end

function ConstructionBrushMassTreeExterminator:onButtonSecondary()
    MassTreeExterminator.removeLastCorner()
    self:setInputTextDirty()
end

function ConstructionBrushMassTreeExterminator:getButtonPrimaryText()
    local MTE = MassTreeExterminator
    local numCorners = #MTE.corners
    if numCorners == 0 then
        return MTE.text("mte_brush_firstCorner")
    elseif numCorners == 1 then
        return MTE.text("mte_brush_secondCorner")
    end
    if MTE.hasWork() then
        return MTE.text("mte_brush_bulldoze", MTE.formatMoney(MTE.preview.cost))
    end
    return MTE.text("mte_brush_newArea")
end

function ConstructionBrushMassTreeExterminator:getButtonSecondaryText()
    if #MassTreeExterminator.corners > 0 then
        return MassTreeExterminator.text("mte_brush_removeCorner")
    end
    return nil
end
