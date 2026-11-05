--[[
    FieldClick.lua -- the big map: a click on a field (its ground, no label needed) gives the same popup as the farmland tag: Farmland, size, value, Visit, Sell, Tag place.
    Visit takes you to the spot you clicked, in that field, not to the middle of the farmland. The popup's empty line under its title says what grows there ("Wheat, growing").

    Why: the field labels (TaskMap) exist only where there is something to do, and a map made field by field after the fact has no field numbers at all, so there was nothing to click.

    How (read from the game's InGameMenuMapFrame): the map reports a click on the bare map to onClickMap; in the overview mode the game then deselects. After that, when the point is
    field ground (the same FieldState test the game's hover box uses) the farmland's own map hotspot is selected, which makes the game show its farmland popup. Visit
    (onClickVisitPlace) is overwritten only while that selection is ours. Everything in a pcall: if it does not fit, the map behaves as it did and a line says why.
]]
FieldClick = {}

local function say(format, ...)
    print(string.format("[TaskMap] " .. format, ...))
end

-- "Wheat, growing": what stands on the field at the spot, or nil when it is bare (nothing worth a line).
function FieldClick.statusText(fieldInfo)
    local fruitTypeIndex = fieldInfo.fruitTypeIndex
    if fruitTypeIndex == nil or fruitTypeIndex == FruitType.UNKNOWN then
        return nil
    end
    local desc = g_fruitTypeManager:getFruitTypeByIndex(fruitTypeIndex)
    if desc == nil then
        return nil
    end
    local state = fieldInfo.growthState
    local key
    if desc:getIsCut(state) then
        key = "ui_growthMapCut"
    elseif desc:getIsWithered(state) then
        key = "ui_growthMapWithered"
    elseif desc:getIsGrowing(state) then
        key = "ui_growthMapGrowing"
    elseif desc:getIsPreparable(state) then
        key = "ui_growthMapReadyToPrepareForHarvest"
    elseif desc:getIsHarvestable(state) then
        key = "ui_growthMapReadyToHarvest"
    end
    local title = desc.fillType ~= nil and desc.fillType.title or desc.name
    if key == nil then
        return title
    end
    return string.format("%s, %s", title, g_i18n:getText(key))
end

-- The popup's free line: after the farm name (multiplayer) when there is one.
local function setStatusLine(frame, text)
    local box = frame.contextBoxFarmland
    local element = box ~= nil and box:getDescendantByName("farm") or nil
    if element == nil or text == nil then
        return
    end
    local old = element.text
    if type(old) == "string" and old ~= "" then
        text = old .. " - " .. text
    end
    element:setText(text)
end

-- A click on the bare map at (worldX, worldZ): select the field's farmland. true when it did.
function FieldClick.onClickMap(frame, worldX, worldZ)
    if frame.isPickingLocation or frame.isPickingRotation then
        return false
    end
    if frame.mapOverviewSelector ~= nil and frame.mapOverviewSelector:getState() == InGameMenuMapFrame.MAP_FARMLANDS then
        return false                                    -- (the farmland overview: the game handles its own clicks)
    end
    if frame.mode ~= InGameMenuMapFrame.AI_MODE_OVERVIEW then
        return false
    end
    FieldClick.fieldState = FieldClick.fieldState or FieldState.new()
    local fieldInfo = FieldClick.fieldState
    fieldInfo:update(worldX, worldZ)
    if fieldInfo.groundType == FieldGroundType.NONE then
        return false
    end
    local farmland = g_farmlandManager:getFarmlandAtWorldPosition(worldX, worldZ)
    local hotspot = farmland ~= nil and farmland:getMapHotspot() or nil
    if hotspot == nil then
        return false
    end
    FieldClick.internal = true
    frame:setMapSelectionItem(hotspot)
    FieldClick.internal = false
    frame.tmField = { hotspot = hotspot, x = worldX, z = worldZ }
    setStatusLine(frame, FieldClick.statusText(fieldInfo))
    return true
end

-- Visit while the selection is ours: to the clicked spot. false when it is not (the game's own Visit then runs).
function FieldClick.visit(frame)
    local field = frame.tmField
    if field == nil or frame.currentHotspot ~= field.hotspot then
        return false
    end
    local y = getTerrainHeightAtWorldPos(g_terrainNode, field.x, 0, field.z)
    frame.onClickBackCallback()
    if g_localPlayer:getCurrentVehicle() ~= nil then
        g_localPlayer:leaveVehicle()
    end
    g_localPlayer:teleportTo(field.x, y, field.z)
    return true
end

if InGameMenuMapFrame ~= nil and not FieldClick.hooked then
    FieldClick.hooked = true
    InGameMenuMapFrame.onClickMap = Utils.appendedFunction(InGameMenuMapFrame.onClickMap, function(self, element, worldX, worldZ)
        local ok, err = pcall(FieldClick.onClickMap, self, worldX, worldZ)
        if not ok then
            say("field click: %s", tostring(err))
        end
    end)
    -- any other selection (a tag, a vehicle, nothing) ends ours
    InGameMenuMapFrame.setMapSelectionItem = Utils.prependedFunction(InGameMenuMapFrame.setMapSelectionItem, function(self)
        if not FieldClick.internal then
            self.tmField = nil
        end
    end)
    InGameMenuMapFrame.onClickVisitPlace = Utils.overwrittenFunction(InGameMenuMapFrame.onClickVisitPlace, function(self, superFunc)
        local ok, handled = pcall(FieldClick.visit, self)
        if ok and handled then
            return true
        end
        if not ok then
            say("field click, visit: %s", tostring(handled))
        end
        return superFunc(self)
    end)
end
