-- plain Lua with a fake map frame: right click an "i" to carry it, left click inside its field to put it down, right click again to put it back, Shift + right click to reset
local passed, failed = 0, 0
local realPrint = print
local function check(name, ok) if ok then passed = passed + 1 else failed = failed + 1; realPrint("  FAIL " .. name) end end
local said = {}
print = function(text) said[#said + 1] = text end

Utils = { appendedFunction = function(old, new) return function(...) local r = old(...); new(...); return r end end, overwrittenFunction = function(old, new) return function(self, ...) return new(self, old, ...) end end }
Input = { MOUSE_BUTTON_LEFT = 1, MOUSE_BUTTON_RIGHT = 3, KEY_lshift = 304, isKeyPressed = function(key) return Input.shift == true and key == 304 end }
g_time = 1000
g_i18n = { getText = function(_, key) return key end }
FruitType = { UNKNOWN = 0 }
InGameMenuMapUtil = {}
InGameMenuMapFrame = { MAP_FARMLANDS = 5, AI_MODE_OVERVIEW = 1, ACTIONS = { VISIT_PLACE = 7 },
    mouseEvent = function() end, onClickMap = function(self, e, x, z) self.clicked = { x, z } end,
    setMapSelectionItem = function() end, onClickVisitPlace = function() end }
dofile("scripts/MarkerOverrides.lua")
dofile("scripts/FieldClick.lua")

local saves = 0
MarkerOverrides.save = function() saves = saves + 1; return true end

local square = { { 0, 0 }, { 100, 0 }, { 100, 100 }, { 0, 100 } }
local entry = { wailaFieldId = 7, boundaryPositions = square }
local hotspot = { entry = entry, isFieldInfoHotspot = true, worldX = 5, worldZ = 5, badgeCX = 5, badgeCY = 5, badgeRX = 2, badgeRY = 2, badgeTime = 1000,
    setWorldPosition = function(self, x, z) self.worldX, self.worldZ = x, z end }
local rebuilt = 0
g_taskMap = { activeHotspots = { hotspot }, rebuildAllHotspots = function() rebuilt = rebuilt + 1 end }
-- the fake map: screen position = world position
local frame = setmetatable({ mode = 1, mapOverviewSelector = { getState = function() return 1 end },
    ingameMap = { getLocalPosition = function(_, x, y) return x, y end, localToWorldPos = function(_, x, y) return x, y end } }, { __index = InGameMenuMapFrame })
local function mouse(x, y, button, down) frame:mouseEvent(x, y, down == nil and (button ~= nil) or down, false, button) end

check("the hit test: on the badge, a little beyond it, and far away", MarkerOverrides.hitsBadge(hotspot, 5, 5, 1000) and MarkerOverrides.hitsBadge(hotspot, 7, 5, 1000) and not MarkerOverrides.hitsBadge(hotspot, 20, 5, 1000))
check("... a badge not drawn lately does not count", not MarkerOverrides.hitsBadge(hotspot, 5, 5, 2000))

mouse(50, 50, Input.MOUSE_BUTTON_RIGHT)
check("a right click away from every \"i\" does nothing", FieldClick.carrying == nil)
mouse(5, 5, Input.MOUSE_BUTTON_LEFT)
check("a left click on the \"i\" is not ours (the game selects the field)", FieldClick.carrying == nil)

mouse(5, 5, Input.MOUSE_BUTTON_RIGHT)
check("a right click on the \"i\" picks it up", FieldClick.carrying ~= nil and FieldClick.carrying.hotspot == hotspot)
mouse(40, 60)
check("moving the mouse: it follows the cursor", hotspot.worldX == 40 and hotspot.worldZ == 60)
mouse(150, 60)
check("the cursor leaves the field: it stays at the last spot inside", hotspot.worldX == 40 and hotspot.worldZ == 60)
mouse(150, 60, Input.MOUSE_BUTTON_LEFT)
check("a left click outside the field puts nothing down", FieldClick.carrying ~= nil and MarkerOverrides.find(square) == nil)
mouse(30, 70, Input.MOUSE_BUTTON_LEFT)
local sx, sz = MarkerOverrides.find(square)
check("a left click inside the field puts it down there, saved", FieldClick.carrying == nil and sx == 30 and sz == 70 and hotspot.worldX == 30 and saves == 1)
local ourClicks = 0
local ownClick = FieldClick.onClickMap
FieldClick.onClickMap = function(...) ourClicks = ourClicks + 1; return ownClick(...) end
frame.clicked = nil
g_time = 1100
InGameMenuMapFrame.onClickMap(frame, nil, 30, 70)
check("the click that put it down does not open the field popup (ours is skipped, the game's own still runs)", ourClicks == 0 and frame.clicked ~= nil)
g_time = 1500
InGameMenuMapFrame.onClickMap(frame, nil, 30, 70)
check("a click a moment later is an ordinary click again", ourClicks == 1)
FieldClick.onClickMap = ownClick

-- carry again and put it back
g_time = 2000
hotspot.badgeTime, hotspot.badgeCX, hotspot.badgeCY = 2000, 30, 70          -- (the badge is drawn where the hotspot is)
mouse(30, 70, Input.MOUSE_BUTTON_RIGHT)
check("a right click on the moved \"i\" picks it up again", FieldClick.carrying ~= nil)
mouse(60, 60)
check("... it follows", hotspot.worldX == 60)
mouse(60, 60, Input.MOUSE_BUTTON_RIGHT)
check("a right click while carrying puts it back where it was picked up", FieldClick.carrying == nil and hotspot.worldX == 30 and hotspot.worldZ == 70 and saves == 1)

-- Shift + right click resets
Input.shift = true
mouse(30, 70, Input.MOUSE_BUTTON_RIGHT)
check("Shift + right click: the saved point is gone, saved, the markers are rebuilt", MarkerOverrides.find(square) == nil and saves == 2 and rebuilt == 1 and FieldClick.carrying == nil)
mouse(30, 70, Input.MOUSE_BUTTON_RIGHT)
check("... and with no saved point nothing more happens", saves == 2 and rebuilt == 1)
Input.shift = false

-- a rebuild while carrying drops the carry
hotspot.worldX, hotspot.worldZ, hotspot.badgeCX, hotspot.badgeCY = 5, 5, 5, 5
mouse(5, 5, Input.MOUSE_BUTTON_RIGHT)
mouse(80, 80)
FieldClick.cancelCarry()
check("a rebuild of the markers ends the carry and the marker goes back", FieldClick.carrying == nil and hotspot.worldX == 5)

-- other map screens: the farmland overview and the picking modes are left alone
frame.mapOverviewSelector = { getState = function() return InGameMenuMapFrame.MAP_FARMLANDS end }
mouse(5, 5, Input.MOUSE_BUTTON_RIGHT)
check("the farmland overview: not ours", FieldClick.carrying == nil)

frame.mapOverviewSelector = { getState = function() return 1 end }
FieldClick.carrying = nil
FieldClick.carrying = nil
g_time = (g_time or 0) + 5; hotspot.badgeTime = g_time
mouse(5, 5, Input.MOUSE_BUTTON_RIGHT); mouse(5, 5, Input.MOUSE_BUTTON_RIGHT)
check("a doubled right click still picks the i up", FieldClick.carrying ~= nil)
g_time = (g_time or 0) + 10; hotspot.badgeTime = g_time
mouse(5, 5, Input.MOUSE_BUTTON_RIGHT); mouse(5, 5, Input.MOUSE_BUTTON_RIGHT)
check("a second (doubled) right click later cancels it", FieldClick.carrying == nil)

-- the file part, offline: a set point replaces the earlier one of the same field
MarkerOverrides.points = {}
check("a point outside the field is refused", MarkerOverrides.set(square, 150, 5) == false and #MarkerOverrides.points == 0)
MarkerOverrides.set(square, 10, 10); MarkerOverrides.set(square, 20, 20)
check("a second point in the same field replaces the first", #MarkerOverrides.points == 1 and select(1, MarkerOverrides.find(square)) == 20)
local other = { { 500, 500 }, { 600, 500 }, { 600, 600 }, { 500, 600 } }
MarkerOverrides.set(other, 550, 550)
check("another field keeps its own point, and clearing one leaves the other", #MarkerOverrides.points == 2 and MarkerOverrides.clear(square) and MarkerOverrides.find(other) == 550 and MarkerOverrides.find(square) == nil)
check("a point whose field was reshaped is not used", MarkerOverrides.find({ { 0, 0 }, { 10, 0 }, { 10, 10 } }) == nil)

print = realPrint
print(string.format("marker_move_test: %d/%d passed", passed, passed + failed))
os.exit(failed == 0 and 0 or 1)
