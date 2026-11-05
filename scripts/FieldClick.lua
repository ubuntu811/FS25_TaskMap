--[[
    FieldClick.lua -- the big map: a click on a field (anywhere inside its polygon) or on the "i" at its corner opens a popup about THAT FIELD: "Field 7", its size (from WAILA's own traced polygon), what
    grows there, and Visit (to a point inside the field). Not the farmland popup: the buyable original farmlands and the fields a map has after it was changed have no relation, so a farmland's name,
    size and price say nothing about the field you clicked, and Sell / Tag place would act on the farmland.

    How (read from the game's InGameMenuMapFrame): the popup with a Visit button is the farmland popup (contextBoxFarmland), shown for a FarmlandHotspot. So the farmland under the field is selected
    (the game builds the popup), then everything is replaced: the title, the size, the second row (the crop instead of the value), the buttons (Visit only: setMapInputContext) and the
    farmland highlight on the map (selectedFarmland nil). The popup sits at the field's "i". Visit (onClickVisitPlace) is overwritten only while the selection is ours (and the frame's captured Visit callback is pointed at it). Everything in a pcall: if it does
    not fit, the map behaves as it did and a line says why.
]]
FieldClick = {}
FieldClick.modName = g_currentModName

local function say(format, ...)
    print(string.format("[TaskMap] " .. format, ...))
end

local function text(key, ...)
    local value = g_i18n:getText(key, FieldClick.modName)
    if select("#", ...) > 0 then
        return string.format(value, ...)
    end
    return value
end

-- ===== plain geometry =====

-- Is (x, z) inside the polygon (a list of { x, z })?
function FieldClick.pointInPolygon(points, x, z)
    local inside = false
    local n = #points
    local j = n
    for i = 1, n do
        local xi, zi, xj, zj = points[i][1], points[i][2], points[j][1], points[j][2]
        if (zi > z) ~= (zj > z) and x < (xj - xi) * (z - zi) / (zj - zi) + xi then
            inside = not inside
        end
        j = i
    end
    return inside
end

-- The area of the polygon in hectares (the shoelace formula; world coordinates are metres).
function FieldClick.polygonAreaHa(points)
    local sum = 0
    local n = #points
    local j = n
    for i = 1, n do
        sum = sum + (points[j][1] + points[i][1]) * (points[j][2] - points[i][2])
        j = i
    end
    return math.abs(sum) * 0.5 / 10000
end

-- The WAILA field (its registry entry) whose traced polygon contains (x, z), or nil.
function FieldClick.entryAt(x, z)
    local waila = g_currentMission ~= nil and g_currentMission.waila or nil
    local entries = waila ~= nil and waila.getAll("field") or nil
    for _, entry in ipairs(entries or {}) do
        if entry.boundaryPositions ~= nil and #entry.boundaryPositions >= 3 and FieldClick.pointInPolygon(entry.boundaryPositions, x, z) then
            return entry
        end
    end
    return nil
end

-- The hotspot (the "i") TaskMap keeps for an entry.
function FieldClick.hotspotOf(entry)
    for _, hotspot in ipairs(g_taskMap ~= nil and g_taskMap.activeHotspots or {}) do
        if hotspot.entry == entry then
            return hotspot
        end
    end
    return nil
end

-- ===== the popup =====

-- "Wheat, growing": what stands on the field at the spot; nil when nothing does.
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

-- The static "Value:" label of the farmland popup (an unnamed Text next to the farmlandValue one): found by its text.
local function findValueLabel(box)
    local wanted = string.lower((g_i18n:getText("ui_sellValue") or ""):gsub(":", ""))
    if wanted == "" then
        return nil
    end
    for _, element in ipairs(box.elements or {}) do
        local value = element.text
        if type(value) == "string" and string.lower(value:gsub(":", "")) == wanted then
            return element
        end
    end
    return nil
end

-- Select the field's farmland (the game builds its popup), then make the popup the field's.
function FieldClick.show(frame, hotspot)
    local entry = hotspot.entry
    -- Visit goes to the "i" itself; when that lies outside the field's polygon (a corner on the headland edge) to a point WAILA found inside it
    local visitX, visitZ = hotspot.worldX, hotspot.worldZ
    if entry ~= nil and entry.boundaryPositions ~= nil and #entry.boundaryPositions >= 3 and not FieldClick.pointInPolygon(entry.boundaryPositions, visitX, visitZ) then
        visitX, visitZ = hotspot.visitX or visitX, hotspot.visitZ or visitZ
    end
    -- the farmland that hosts the popup: under the "i", else under the point WAILA found inside the field
    local farmland = g_farmlandManager:getFarmlandAtWorldPosition(visitX, visitZ)
    if farmland == nil and hotspot.visitX ~= nil then
        farmland = g_farmlandManager:getFarmlandAtWorldPosition(hotspot.visitX, hotspot.visitZ)
    end
    local farmHotspot = farmland ~= nil and farmland:getMapHotspot() or nil
    if farmHotspot == nil then
        return false                                    -- (a field outside every farmland: nothing to host the popup)
    end
    FieldClick.internal = true
    local ok, err = pcall(frame.setMapSelectionItem, frame, farmHotspot)
    FieldClick.internal = false
    if not ok then
        error(err)
    end
    frame.selectedFarmland = nil                        -- (no farmland highlight on the map: it is not the farmland that was clicked)
    frame.needsOverlayUpdate = true
    if frame.ingameMapBase ~= nil then
        frame.ingameMapBase:setSelectedHotspot(hotspot)
    end
    frame:setMapInputContext(false, false, false, true, false, false, false, false, false)       -- Visit only (Sell and Tag place would act on the farmland)
    frame:refreshContextInput()
    local box = frame.contextBoxFarmland
    InGameMenuMapUtil.showContextBox(box, hotspot, text("tm_fieldTitle", entry ~= nil and entry.wailaFieldId or 0), nil, nil, nil, nil, false, false, false)
    local sizeElement = box:getDescendantByName("farmlandSize")
    local valueElement = box:getDescendantByName("farmlandValue")
    if sizeElement ~= nil and entry ~= nil and entry.boundaryPositions ~= nil then
        sizeElement:setText(g_i18n:formatArea(FieldClick.polygonAreaHa(entry.boundaryPositions), 2))
    end
    FieldClick.fieldState = FieldClick.fieldState or FieldState.new()
    FieldClick.fieldState:update(visitX, visitZ)
    local status = FieldClick.statusText(FieldClick.fieldState) or text("tm_bare")
    if valueElement ~= nil then
        valueElement:setText(status)
    end
    local label = findValueLabel(box)
    if label ~= nil then
        label:setText(text("tm_crop"))
    end
    -- the frame took the Visit callback (the game's own function) when it was built, before this file patched the class: point it at the patched one, or the game's Visit runs and goes to the farmland tag
    local action = frame.contextActions ~= nil and frame.contextActions[InGameMenuMapFrame.ACTIONS.VISIT_PLACE] or nil
    if action ~= nil then
        action.callback = frame.onClickVisitPlace
    end
    frame.tmField = { hotspot = farmHotspot, x = visitX, z = visitZ }
    return true
end

-- A click on the bare map at (worldX, worldZ): inside a WAILA field's polygon, select that field.
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
    local entry = FieldClick.entryAt(worldX, worldZ)
    local hotspot = entry ~= nil and FieldClick.hotspotOf(entry) or nil
    if hotspot == nil then
        return false
    end
    return FieldClick.show(frame, hotspot)
end

-- Visit while the selection is ours: to a point inside the field. false when it is not (the game's own Visit then runs).
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
    -- a click on an "i" selects the field; any other selection (a tag, a vehicle, nothing) ends ours
    InGameMenuMapFrame.setMapSelectionItem = Utils.overwrittenFunction(InGameMenuMapFrame.setMapSelectionItem, function(self, superFunc, hotspot)
        if not FieldClick.internal then
            self.tmField = nil
            if hotspot ~= nil and hotspot.isFieldInfoHotspot then
                local ok, shown = pcall(FieldClick.show, self, hotspot)
                if ok and shown then
                    return
                end
                if not ok then
                    say("field click, selecting: %s", tostring(shown))
                end
                return superFunc(self, nil)                -- (it cannot be shown: deselect, as a click on nothing does)
            end
        end
        return superFunc(self, hotspot)
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
