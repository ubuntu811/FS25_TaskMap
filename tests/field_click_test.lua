-- plain Lua with a fake map frame: a click on a field's ground selects its farmland (popup with Visit), Visit goes to the spot, other selections end it
local passed, failed = 0, 0
local realPrint = print
local function check(name, ok) if ok then passed = passed + 1 else failed = failed + 1; realPrint("  FAIL " .. name) end end
local log = {}
print = function(text) log[#log + 1] = text end

Utils = {
    appendedFunction = function(old, new) return function(...) local r = old(...); new(...); return r end end,
    prependedFunction = function(old, new) return function(...) new(...); return old(...) end end,
    overwrittenFunction = function(old, new) return function(self, ...) return new(self, old, ...) end end,
}
FruitType = { UNKNOWN = 0 }
FieldGroundType = { NONE = 0, PLOWED = 1 }
g_i18n = { getText = function(_, key) return "<" .. key .. ">" end }
local fruit = { fillType = { title = "Wheat" }, name = "WHEAT", getIsCut = function() return false end, getIsWithered = function() return false end,
    getIsGrowing = function(_, s) return s < 5 end, getIsPreparable = function() return false end, getIsHarvestable = function(_, s) return s == 5 end }
g_fruitTypeManager = { getFruitTypeByIndex = function(_, i) return i == 1 and fruit or nil end }

local fieldAt = {}           -- "x,z" -> { groundType, fruitTypeIndex, growthState }
FieldState = { new = function() return { update = function(self, x, z)
    local f = fieldAt[x .. "," .. z] or { groundType = FieldGroundType.NONE, fruitTypeIndex = 0, growthState = 0 }
    self.groundType, self.fruitTypeIndex, self.growthState = f.groundType, f.fruitTypeIndex, f.growthState
end } end }

local farmHotspot = { name = "hotspot of farmland 24" }
local farmlandAt = {}
g_farmlandManager = { getFarmlandAtWorldPosition = function(_, x, z) return farmlandAt[x .. "," .. z] end }
g_terrainNode = 1
getTerrainHeightAtWorldPos = function() return 77 end

local teleported, left, backs = nil, 0, 0
local vehicle = {}
g_localPlayer = { getCurrentVehicle = function() return vehicle end, leaveVehicle = function() left = left + 1; vehicle = nil end, teleportTo = function(_, x, y, z) teleported = { x, y, z } end }

local selected = "none"
InGameMenuMapFrame = {
    MAP_FARMLANDS = 5, AI_MODE_OVERVIEW = 1,
    onClickMap = function(self, element, x, z) selected = nil end,                    -- (the game: deselects in the overview)
    setMapSelectionItem = function(self, hotspot) selected = hotspot; self.currentHotspot = hotspot end,
    onClickVisitPlace = function(self) selected = "the game's own visit"; return true end,
}
dofile("scripts/FieldClick.lua")

local function newFrame()
    local line = { text = "", setText = function(self, t) self.text = t end }
    local box = { getDescendantByName = function(_, name) return name == "farm" and line or nil end }
    local frame = { mode = 1, mapOverviewSelector = { getState = function() return 1 end }, contextBoxFarmland = box, onClickBackCallback = function() backs = backs + 1 end }
    frame.line = line
    return setmetatable(frame, { __index = InGameMenuMapFrame })
end
local function click(frame, x, z) InGameMenuMapFrame.onClickMap(frame, nil, x, z) end

farmlandAt["10,20"] = { getMapHotspot = function() return farmHotspot end }
fieldAt["10,20"] = { groundType = FieldGroundType.PLOWED, fruitTypeIndex = 1, growthState = 2 }
local f = newFrame()
click(f, 10, 20)
check("a click on field ground selects the farmland's hotspot (the farmland popup)", selected == farmHotspot and f.tmField ~= nil)
check("... and the popup's free line says what grows there", f.line.text == "Wheat, <ui_growthMapGrowing>")

fieldAt["10,20"].growthState = 5
f = newFrame()
click(f, 10, 20)
check("a harvestable crop says so", f.line.text == "Wheat, <ui_growthMapReadyToHarvest>")

fieldAt["10,20"].fruitTypeIndex = 0
f = newFrame()
click(f, 10, 20)
check("bare field ground: still selected, the line stays empty", selected == farmHotspot and f.line.text == "")

f = newFrame()
f.line.text = "Farm Kuckuck"
fieldAt["10,20"].fruitTypeIndex = 1
click(f, 10, 20)
check("with a farm name in the line (multiplayer) the status comes after it", f.line.text == "Farm Kuckuck - Wheat, <ui_growthMapReadyToHarvest>")

selected = "none"
f = newFrame()
click(f, 30, 40)
check("a click on bare ground (no field): the game's deselect stands, nothing is selected", selected == nil and f.tmField == nil)

fieldAt["50,60"] = { groundType = FieldGroundType.PLOWED, fruitTypeIndex = 0, growthState = 0 }
selected = "none"
f = newFrame()
click(f, 50, 60)
check("field ground in no farmland: nothing is selected", selected == nil)

f = newFrame()
f.mapOverviewSelector = { getState = function() return InGameMenuMapFrame.MAP_FARMLANDS end }
selected = "none"
click(f, 10, 20)
check("in the farmland overview the game's own click handling is left alone", selected == nil and f.tmField == nil)
f = newFrame(); f.mode = 2
selected = "none"
click(f, 10, 20)
check("not in the overview mode (the AI worker lists): nothing happens", selected == nil)
f = newFrame(); f.isPickingLocation = true
selected = "none"
click(f, 10, 20)
check("while the map picks a location the click is the game's alone", selected == nil)

-- visit
f = newFrame()
click(f, 10, 20)
InGameMenuMapFrame.onClickVisitPlace(f)
check("Visit goes to the clicked spot in the field, the game's own is not run", teleported ~= nil and teleported[1] == 10 and teleported[2] == 77 and teleported[3] == 20 and selected == farmHotspot)
check("... leaving the vehicle and closing the menu first", left == 1 and backs == 1)

-- another selection ends ours
f = newFrame()
click(f, 10, 20)
f:setMapSelectionItem(nil)
InGameMenuMapFrame.setMapSelectionItem(f, { name = "a vehicle" })
check("another selection (a vehicle, a tag) ends the field selection", f.tmField == nil)
InGameMenuMapFrame.onClickVisitPlace(f)
check("... and Visit is then the game's own", selected == "the game's own visit")

-- an error inside ours leaves the map as it was
FieldState = { new = function() error("boom") end }
FieldClick.fieldState = nil
log = {}
f = newFrame()
click(f, 10, 20)
check("a failure in ours: one line says so, nothing breaks", #log == 1 and log[1]:find("field click", 1, true) ~= nil)

print = realPrint
print(string.format("field_click_test: %d/%d passed", passed, passed + failed))
os.exit(failed == 0 and 0 or 1)
