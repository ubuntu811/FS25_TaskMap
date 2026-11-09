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

-- The popup's "Tag place" button (it would tag the farmland, not the field) is ours while a field is selected: "Recenter label". The game's own title and callback go back for every other selection.
function FieldClick.useTagSlot(frame, ours)
    local action = frame.contextActions ~= nil and frame.contextActions[InGameMenuMapFrame.ACTIONS.SET_MARKER] or nil
    if action == nil then
        return
    end
    if ours then
        action.title = text("tm_recenter")
        action.callback = function() FieldClick.recenter(frame) end
    else
        action.title = nil
        action.callback = frame.onClickTagPlace
    end
end

-- Recenter label: the saved spot (if any) is dropped, the automatic one is worked out again, the markers are rebuilt and the popup comes back on the new "i".
function FieldClick.recenter(frame)
    local field = frame.tmField
    local entry = field ~= nil and field.entry or nil
    if entry == nil or g_taskMap == nil then
        return
    end
    if entry.boundaryPositions ~= nil and MarkerOverrides.clear(entry.boundaryPositions) then
        MarkerOverrides.save()
    end
    if g_taskMap.labelCache ~= nil then
        g_taskMap.labelCache[entry.wailaFieldId] = nil
    end
    g_taskMap:rebuildAllHotspots()
    say("marker: field %s: recentered", tostring(entry.wailaFieldId))
    local hotspot = FieldClick.hotspotOf(entry)
    local ok, shown = false, false
    if hotspot ~= nil then
        ok, shown = pcall(FieldClick.show, frame, hotspot)
    end
    if not (ok and shown) then
        frame.tmField = nil
        FieldClick.useTagSlot(frame, false)
        frame:setMapSelectionItem(nil)
    end
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
    FieldClick.useTagSlot(frame, true)                  -- (the unused "Tag place" button becomes "Recenter label": its list is rebuilt inside setMapInputContext, so it is set up first)
    frame:setMapInputContext(false, false, false, true, true, false, false, false, false)       -- Visit and Recenter (Sell and Tag place would act on the farmland)
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
    frame.tmField = { hotspot = farmHotspot, x = visitX, z = visitZ, entry = entry }
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

-- ===== moving an "i" by hand =====
-- Right click on an "i" on the big map picks it up: it follows the cursor, but only inside its own field. A left click puts it there (saved, per savegame: MarkerOverrides), another right click puts it back.
-- Shift + right click on an "i" that is not carried takes it back to the automatic position.
FieldClick.carrying = nil
FieldClick.CLICK_SUPPRESS_MS = 300

function FieldClick.cancelCarry()
    local carried = FieldClick.carrying
    FieldClick.carrying = nil
    if carried ~= nil then
        carried.hotspot:setWorldPosition(carried.originX, carried.originZ)
    end
end

-- A rebuild of the markers replaces every hotspot: the carried "i" is handed to the new one of the same field and keeps following the cursor. `stash` is what FieldClick.carrying was before the rebuild.
function FieldClick.resumeCarry(stash)
    if stash == nil then
        return
    end
    local entry = stash.hotspot.entry
    local hotspot = FieldClick.hotspotOf(entry)
    if hotspot == nil and entry ~= nil then
        for _, h in ipairs(g_taskMap ~= nil and g_taskMap.activeHotspots or {}) do
            if h.entry ~= nil and h.entry.wailaFieldId == entry.wailaFieldId then
                hotspot = h
                break
            end
        end
    end
    if hotspot == nil or hotspot.entry == nil or hotspot.entry.boundaryPositions == nil then
        return                                              -- (the field is gone: nothing to carry)
    end
    local x, z = stash.hotspot.worldX, stash.hotspot.worldZ
    FieldClick.carrying = { hotspot = hotspot, originX = hotspot.worldX, originZ = hotspot.worldZ }
    hotspot:setWorldPosition(x, z)
end

local function mapIsOurs(frame)
    if frame.isPickingLocation or frame.isPickingRotation then
        return false
    end
    if frame.mapOverviewSelector ~= nil and frame.mapOverviewSelector:getState() == InGameMenuMapFrame.MAP_FARMLANDS then
        return false
    end
    return frame.mode == InGameMenuMapFrame.AI_MODE_OVERVIEW
end

local function cursorWorld(frame, posX, posY)
    local localX, localY = frame.ingameMap:getLocalPosition(posX, posY)
    return frame.ingameMap:localToWorldPos(localX, localY)
end

-- The "i" under the screen point, or nil.
function FieldClick.badgeAt(posX, posY)
    for _, hotspot in ipairs(g_taskMap ~= nil and g_taskMap.activeHotspots or {}) do
        if hotspot.isFieldInfoHotspot and MarkerOverrides.hitsBadge(hotspot, posX, posY, g_time) then
            return hotspot
        end
    end
    return nil
end

-- Every mouse event of the map frame. Returns true when it was one of ours (nothing else depends on it, the game's own handling goes on).
function FieldClick.onMouse(frame, posX, posY, isDown, isUp, button)
    -- the game hands the map frame every button event twice in the same instant: the second one must not undo the first (a pick-up and a cancel in one click)
    if isDown or isUp then
        local key = string.format("%s|%s|%s|%s|%s", tostring(g_time), tostring(posX), tostring(posY), tostring(isDown), tostring(button))
        if key == FieldClick.lastEventKey then
            return false
        end
        FieldClick.lastEventKey = key
    end
    if not mapIsOurs(frame) then
        return false
    end
    local carried = FieldClick.carrying
    if carried ~= nil then
        local polygon = carried.hotspot.entry ~= nil and carried.hotspot.entry.boundaryPositions or nil
        local x, z = cursorWorld(frame, posX, posY)
        local insideField = polygon ~= nil and MarkerOverrides.inside(polygon, x, z)
        if insideField then
            carried.hotspot:setWorldPosition(x, z)                    -- (it follows the cursor inside the field and stays at the last spot inside when the cursor leaves it)
        end
        if isDown and button == Input.MOUSE_BUTTON_LEFT and insideField then
            FieldClick.carrying = nil
            if MarkerOverrides.set(polygon, x, z) then
                MarkerOverrides.save()
                say("marker: field %s: the \"i\" is at %.0f %.0f now", tostring(carried.hotspot.entry.wailaFieldId), x, z)
            end
            FieldClick.suppressClickUntil = g_time + FieldClick.CLICK_SUPPRESS_MS      -- (the click that put it down is not a click on the map)
        elseif isDown and button == Input.MOUSE_BUTTON_RIGHT then
            FieldClick.cancelCarry()
        end
        return true
    end
    if isDown and button == Input.MOUSE_BUTTON_RIGHT then
        local hotspot = FieldClick.badgeAt(posX, posY)
        if hotspot == nil then
            return false
        end
        local polygon = hotspot.entry ~= nil and hotspot.entry.boundaryPositions or nil
        if Input.isKeyPressed(Input.KEY_lshift) then
            if polygon ~= nil and MarkerOverrides.clear(polygon) then
                MarkerOverrides.save()
                say("marker: field %s: the \"i\" is automatic again", tostring(hotspot.entry.wailaFieldId))
                if g_taskMap ~= nil and g_taskMap.rebuildAllHotspots ~= nil then
                    g_taskMap:rebuildAllHotspots()
                end
            end
            return true
        end
        if polygon ~= nil then
            FieldClick.carrying = { hotspot = hotspot, originX = hotspot.worldX, originZ = hotspot.worldZ }
            return true
        end
    end
    return false
end

if InGameMenuMapFrame ~= nil and not FieldClick.hooked then
    FieldClick.hooked = true
    InGameMenuMapFrame.onClickMap = Utils.appendedFunction(InGameMenuMapFrame.onClickMap, function(self, element, worldX, worldZ)
        if g_time ~= nil and g_time < (FieldClick.suppressClickUntil or 0) then
            return
        end
        local ok, err = pcall(FieldClick.onClickMap, self, worldX, worldZ)
        if not ok then
            say("field click: %s", tostring(err))
        end
    end)
    InGameMenuMapFrame.mouseEvent = Utils.appendedFunction(InGameMenuMapFrame.mouseEvent, function(self, posX, posY, isDown, isUp, button)
        local ok, err = pcall(FieldClick.onMouse, self, posX, posY, isDown, isUp, button)
        if not ok then
            say("marker move: %s", tostring(err))
        end
    end)
    -- closing the map is the only thing that drops a carried "i" by itself
    if InGameMenuMapFrame.onFrameClose ~= nil then
        InGameMenuMapFrame.onFrameClose = Utils.appendedFunction(InGameMenuMapFrame.onFrameClose, function()
            FieldClick.cancelCarry()
        end)
    end
    -- a click on an "i" selects the field; any other selection (a tag, a vehicle, nothing) ends ours
    InGameMenuMapFrame.setMapSelectionItem = Utils.overwrittenFunction(InGameMenuMapFrame.setMapSelectionItem, function(self, superFunc, hotspot)
        if not FieldClick.internal then
            self.tmField = nil
            FieldClick.useTagSlot(self, false)
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
