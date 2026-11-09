-- plain Lua with a fake map frame: a click inside a WAILA field's polygon (or on its "i") opens a popup about that field, Visit goes into the field
local passed, failed = 0, 0
local realPrint = print
local function check(name, ok) if ok then passed = passed + 1 else failed = failed + 1; realPrint("  FAIL " .. name) end end
local log = {}
print = function(text) log[#log + 1] = text end

Utils = {
    appendedFunction = function(old, new) return function(...) local r = old(...); new(...); return r end end,
    overwrittenFunction = function(old, new) return function(self, ...) return new(self, old, ...) end end,
}
FruitType = { UNKNOWN = 0 }
g_i18n = {
    getText = function(_, key) local t = { tm_fieldTitle = "Field %d", tm_crop = "Crop", tm_bare = "nothing growing", ui_sellValue = "Value" }; return t[key] or ("<" .. key .. ">") end,
    formatArea = function(_, ha, digits) return string.format("%." .. digits .. "f ha", ha) end,
}
local fruit = { fillType = { title = "Wheat" }, name = "WHEAT", getIsCut = function() return false end, getIsWithered = function() return false end,
    getIsGrowing = function(_, s) return s < 5 end, getIsPreparable = function() return false end, getIsHarvestable = function(_, s) return s == 5 end }
g_fruitTypeManager = { getFruitTypeByIndex = function(_, i) return i == 1 and fruit or nil end }
local fieldAt = {}
FieldState = { new = function() return { update = function(self, x, z)
    local f = fieldAt["50,50"] or { fruitTypeIndex = 0, growthState = 0 }     -- (one crop for the whole fake field)
    self.fruitTypeIndex, self.growthState = f.fruitTypeIndex, f.growthState
end } end }

local farmHotspot = { name = "the 24 tag" }
local farmlandOfPoint = { ["50,50"] = { getMapHotspot = function() return farmHotspot end } }
g_farmlandManager = { getFarmlandAtWorldPosition = function(_, x, z) return farmlandOfPoint[x .. "," .. z] end }
g_terrainNode = 1
getTerrainHeightAtWorldPos = function() return 77 end
local teleported, left, backs = nil, 0, 0
local vehicle = {}
g_localPlayer = { getCurrentVehicle = function() return vehicle end, leaveVehicle = function() left = left + 1; vehicle = nil end, teleportTo = function(_, x, y, z) teleported = { x, y, z } end }

-- a square field of 100 x 100 m (1 ha) at x 0..100, z 0..100, and one far away
local square = { { 0, 0 }, { 100, 0 }, { 100, 100 }, { 0, 100 } }
local entry1 = { wailaFieldId = 7, boundaryPositions = square, sampleX = 50, sampleZ = 50, labelX = 5, labelZ = 5 }
local entry2 = { wailaFieldId = 8, boundaryPositions = { { 500, 500 }, { 600, 500 }, { 600, 600 } }, sampleX = 560, sampleZ = 520, labelX = 505, labelZ = 505 }
local noPolygon = { wailaFieldId = 9, sampleX = 900, sampleZ = 900 }
g_currentMission = { waila = { getAll = function(kind) return kind == "field" and { noPolygon, entry1, entry2 } or nil end } }
local hotspot1 = { entry = entry1, isFieldInfoHotspot = true, visitX = 50, visitZ = 50, worldX = 5, worldZ = 5 }
local hotspot2 = { entry = entry2, isFieldInfoHotspot = true, visitX = 560, visitZ = 520, worldX = 505, worldZ = 505 }
g_taskMap = { activeHotspots = { hotspot2, hotspot1 } }

local selected = "none"
local shown, highlight, inputContext, refreshed = nil, nil, nil, 0
InGameMenuMapUtil = { showContextBox = function(box, hotspot, description, ...) shown = { box = box, hotspot = hotspot, description = description, isFarmland = select(6, ...) } end }
InGameMenuMapFrame = {
    MAP_FARMLANDS = 5, AI_MODE_OVERVIEW = 1, ACTIONS = { VISIT_PLACE = 7, SET_MARKER = 9 },
    onClickMap = function(self, element, x, z) selected = nil end,
    setMapSelectionItem = function(self, hotspot) selected = hotspot; self.currentHotspot = hotspot; self.selectedFarmland = hotspot ~= nil and "the farmland" or nil end,
    onClickVisitPlace = function(self) selected = "the game's own visit"; return true end,
    onClickTagPlace = function(self) selected = "the game's own tag" end,
}
dofile("scripts/FieldClick.lua")

local capturedVisit = function() selected = "captured, unpatched visit" end     -- (what the frame took when it was built)
local function newFrame()
    local sizeEl = { text = "", setText = function(self, t) self.text = t end }
    local valueEl = { text = "", setText = function(self, t) self.text = t end }
    local label = { text = "Value:", setText = function(self, t) self.text = t end }
    local other = { text = "Size:", setText = function(self, t) self.text = t end }
    local box = { elements = { other, label }, getDescendantByName = function(_, name) return ({ farmlandSize = sizeEl, farmlandValue = valueEl })[name] end }
    local frame = {
        mode = 1, mapOverviewSelector = { getState = function() return 1 end }, contextBoxFarmland = box,
        onClickBackCallback = function() backs = backs + 1 end,
        ingameMapBase = { setSelectedHotspot = function(_, h) highlight = h end },
        setMapInputContext = function(_, ...) inputContext = { ... } end,
        refreshContextInput = function() refreshed = refreshed + 1 end,
        contextActions = { [7] = { callback = capturedVisit }, [9] = { text = "action_tag", callback = function() end } },
    }
    frame.sizeEl, frame.valueEl, frame.label = sizeEl, valueEl, label
    return setmetatable(frame, { __index = InGameMenuMapFrame })
end
local function click(frame, x, z) InGameMenuMapFrame.onClickMap(frame, nil, x, z) end

-- geometry
check("a point inside the polygon, and outside", FieldClick.pointInPolygon(square, 50, 50) and not FieldClick.pointInPolygon(square, 150, 50) and not FieldClick.pointInPolygon(square, 50, -1))
local lShape = { { 0, 0 }, { 100, 0 }, { 100, 40 }, { 40, 40 }, { 40, 100 }, { 0, 100 } }
check("a concave polygon (an L): the notch is outside", FieldClick.pointInPolygon(lShape, 20, 80) and FieldClick.pointInPolygon(lShape, 80, 20) and not FieldClick.pointInPolygon(lShape, 80, 80))
check("the area in hectares: 100 x 100 m is one, either winding", math.abs(FieldClick.polygonAreaHa(square) - 1) < 1e-9 and math.abs(FieldClick.polygonAreaHa({ square[4], square[3], square[2], square[1] }) - 1) < 1e-9 and math.abs(FieldClick.polygonAreaHa(lShape) - 0.64) < 1e-9)
check("the field at a point is the one whose polygon holds it (an entry without a polygon is skipped)", FieldClick.entryAt(50, 50) == entry1 and FieldClick.entryAt(520, 510) == entry2 and FieldClick.entryAt(300, 300) == nil)
check("the hotspot of an entry is found", FieldClick.hotspotOf(entry1) == hotspot1 and FieldClick.hotspotOf(noPolygon) == nil)

-- a click inside a field
fieldAt["50,50"] = { fruitTypeIndex = 1, growthState = 2 }
local f = newFrame()
click(f, 30, 30)
check("a click inside the polygon opens the popup of that field: its title, not the farmland's", shown ~= nil and shown.description == "Field 7" and shown.isFarmland == false and shown.hotspot == hotspot1)
check("... the size is the polygon's own area, not the farmland's", f.sizeEl.text == "1.00 ha")
check("... the second row is the crop, its label no longer says Value", f.valueEl.text == "Wheat, <ui_growthMapGrowing>" and f.label.text == "Crop")
check("... Visit and Recenter (the tag slot): nothing to sell, buy or manage", inputContext ~= nil and inputContext[4] == true and not inputContext[1] and not inputContext[2] and not inputContext[3] and inputContext[5] == true and not inputContext[6] and not inputContext[7] and not inputContext[8] and not inputContext[9] and refreshed >= 1)
check("... no farmland highlight on the map, the \"i\" is the selected hotspot", f.selectedFarmland == nil and f.needsOverlayUpdate == true and highlight == hotspot1)

fieldAt["50,50"] = { fruitTypeIndex = 1, growthState = 5 }
f = newFrame(); click(f, 30, 30)
check("a harvestable crop says so", f.valueEl.text == "Wheat, <ui_growthMapReadyToHarvest>")
fieldAt["50,50"] = { fruitTypeIndex = 0, growthState = 0 }
f = newFrame(); click(f, 30, 30)
check("nothing growing says so", f.valueEl.text == "nothing growing")

-- Recenter label: the "Tag place" slot of the popup
f = newFrame(); click(f, 30, 30)
local slot = f.contextActions[9]
check("the tag slot is Recenter while the field is selected", slot.title == "<tm_recenter>" and slot.callback ~= nil)
local cleared, saved, rebuilt = 0, 0, 0
MarkerOverrides = { clear = function() cleared = cleared + 1; return true end, save = function() saved = saved + 1 end }
g_taskMap.labelCache = { [7] = { x = 1, z = 1 } }
g_taskMap.rebuildAllHotspots = function() rebuilt = rebuilt + 1 end
shown = nil
slot.callback()
check("Recenter drops the saved spot and the cached one, rebuilds, and the popup comes back", cleared == 1 and saved == 1 and rebuilt == 1 and g_taskMap.labelCache[7] == nil and shown ~= nil and shown.description == "Field 7")
f:setMapSelectionItem(nil)
check("a selection that is not ours gives the slot back to the game", slot.title == nil and slot.callback == f.onClickTagPlace)
MarkerOverrides = nil

-- a click on the "i"
farmlandOfPoint["560,520"] = farmlandOfPoint["50,50"]
f = newFrame()
selected = "none"
shown = nil
f:setMapSelectionItem(hotspot2)
check("a click on an \"i\" (the game selects the hotspot) opens the same popup for its field", shown ~= nil and shown.description == "Field 8")

-- no farmland to host the popup
farmlandOfPoint["560,520"] = nil
f = newFrame()
shown = nil
selected = "none"
f:setMapSelectionItem(hotspot2)
check("a field in no farmland cannot show the popup: the click deselects, nothing breaks", shown == nil and selected == nil)

-- clicks that are not ours
shown = nil
f = newFrame(); selected = "none"
click(f, 300, 300)
check("a click outside every field polygon: the game's deselect stands", selected == nil and shown == nil and f.tmField == nil)
f = newFrame(); f.mapOverviewSelector = { getState = function() return InGameMenuMapFrame.MAP_FARMLANDS end }
click(f, 30, 30)
check("in the farmland overview the game's own click handling is left alone", shown == nil)
f = newFrame(); f.mode = 2
click(f, 30, 30)
check("not in the overview mode (the AI worker lists): nothing happens", shown == nil)
f = newFrame(); f.isPickingLocation = true
click(f, 30, 30)
check("while the map picks a location the click is the game's alone", shown == nil)

-- visit
f = newFrame()
click(f, 30, 30)
check("the frame's captured Visit callback now is the patched one (the game's own would go to the farmland tag)", f.contextActions[7].callback == InGameMenuMapFrame.onClickVisitPlace)
f.contextActions[7].callback(f)
check("Visit goes to the \"i\" itself (it lies inside the polygon), the game's own is not run", teleported ~= nil and teleported[1] == 5 and teleported[2] == 77 and teleported[3] == 5)
check("... leaving the vehicle and closing the menu first", left == 1 and backs == 1)

-- an "i" outside its polygon: Visit goes to the sample point
local outside = { entry = entry1, isFieldInfoHotspot = true, visitX = 50, visitZ = 50, worldX = 300, worldZ = 300 }
farmlandOfPoint["300,300"] = nil
f = newFrame()
teleported = nil
f:setMapSelectionItem(outside)
f.contextActions[7].callback(f)
check("an \"i\" outside the field's polygon: Visit goes to the sample point inside it", teleported ~= nil and teleported[1] == 50 and teleported[3] == 50)

-- another selection ends ours
f = newFrame()
click(f, 30, 30)
InGameMenuMapFrame.setMapSelectionItem(f, { name = "a vehicle" })
check("another selection (a vehicle, a tag) ends the field selection", f.tmField == nil)
InGameMenuMapFrame.onClickVisitPlace(f)
check("... and Visit is then the game's own", selected == "the game's own visit")

-- an error inside ours leaves the map as it was
InGameMenuMapUtil.showContextBox = function() error("boom") end
log = {}
f = newFrame()
click(f, 30, 30)
check("a failure in ours: one line says so, nothing breaks", #log == 1 and log[1]:find("field click", 1, true) ~= nil)

print = realPrint
print(string.format("field_click_test: %d/%d passed", passed, passed + failed))
os.exit(failed == 0 and 0 or 1)
