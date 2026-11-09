--[[
    MarkerOverrides.lua -- where the player put the "i" of a field by hand (right click it on the big map, click inside the field), kept per savegame.

    An override is just a point; it belongs to the field whose traced outline contains it, so it survives the field being traced again and does not need a field id. A point that lies outside every field
    (the field was reshaped) is simply not used. Pure apart from the file: modSettings/FS25_TaskMap/markers_<savegame folder>.xml.
]]
MarkerOverrides = {}
MarkerOverrides.points = {}
MarkerOverrides.path = nil
MarkerOverrides.BADGE_SLACK = 1.25      -- a right click this far outside the drawn badge (as a share of its radius) still picks it up
MarkerOverrides.BADGE_FRESH_MS = 300    -- the badge position is the one of the last frame drawn

local function inside(polygon, x, z)
    local result, n, j = false, #polygon, #polygon
    for i = 1, n do
        local xi, zi, xj, zj = polygon[i][1], polygon[i][2], polygon[j][1], polygon[j][2]
        if (zi > z) ~= (zj > z) and x < (xj - xi) * (z - zi) / (zj - zi) + xi then
            result = not result
        end
        j = i
    end
    return result
end
MarkerOverrides.inside = inside

-- The saved point inside `polygon` (a list of { x, z }), or nil.
function MarkerOverrides.find(polygon)
    if polygon == nil or #polygon < 3 then
        return nil
    end
    for _, p in ipairs(MarkerOverrides.points) do
        if inside(polygon, p[1], p[2]) then
            return p[1], p[2]
        end
    end
    return nil
end

-- Puts the field's marker at (x, z); a point outside the polygon is refused (false). An earlier point of that field is replaced.
function MarkerOverrides.set(polygon, x, z)
    if polygon == nil or #polygon < 3 or not inside(polygon, x, z) then
        return false
    end
    MarkerOverrides.clear(polygon)
    MarkerOverrides.points[#MarkerOverrides.points + 1] = { x, z }
    return true
end

-- Back to the automatic position. Returns true when there was a saved point.
function MarkerOverrides.clear(polygon)
    local removed = false
    for i = #MarkerOverrides.points, 1, -1 do
        local p = MarkerOverrides.points[i]
        if polygon ~= nil and #polygon >= 3 and inside(polygon, p[1], p[2]) then
            table.remove(MarkerOverrides.points, i)
            removed = true
        end
    end
    return removed
end

-- Is the screen point (mx, my) on the badge a hotspot drew last frame? The hotspot keeps badgeCX/CY (centre) and badgeRX/RY (radii) in screen units and badgeTime.
function MarkerOverrides.hitsBadge(hotspot, mx, my, now)
    if hotspot == nil or hotspot.badgeCX == nil or now - (hotspot.badgeTime or -1e9) > MarkerOverrides.BADGE_FRESH_MS then
        return false
    end
    local dx = (mx - hotspot.badgeCX) / (hotspot.badgeRX * MarkerOverrides.BADGE_SLACK)
    local dy = (my - hotspot.badgeCY) / (hotspot.badgeRY * MarkerOverrides.BADGE_SLACK)
    return dx * dx + dy * dy <= 1
end

-- ===== the file =====

local SCHEMA = nil
local function schema()
    if SCHEMA == nil and XMLSchema ~= nil then
        SCHEMA = XMLSchema.new("FS25_TaskMapMarkers")
        SCHEMA:register(XMLValueType.FLOAT, "markers.point(?)#x")
        SCHEMA:register(XMLValueType.FLOAT, "markers.point(?)#z")
    end
    return SCHEMA
end

local function currentPath()
    local info = g_currentMission ~= nil and g_currentMission.missionInfo or nil
    local directory = info ~= nil and info.savegameDirectory or nil
    local name = tostring(directory or "savegame"):gsub("[/\\]+$", ""):match("([^/\\]+)$") or "savegame"
    name = name:gsub("[^%w_]", "_")
    local folder = getUserProfileAppPath() .. "modSettings/FS25_TaskMap/"
    createFolder(folder)
    return folder .. "markers_" .. name .. ".xml"
end

-- Reads the file of the current savegame when it is not the one in memory already (a different save was loaded).
function MarkerOverrides.ensureLoaded()
    if getUserProfileAppPath == nil or schema() == nil then
        return
    end
    local path = currentPath()
    if path == MarkerOverrides.path then
        return
    end
    MarkerOverrides.path = path
    MarkerOverrides.points = {}
    local xmlFile = XMLFile.loadIfExists("TaskMapMarkers", path, schema())
    if xmlFile ~= nil then
        xmlFile:iterate("markers.point", function(_, key)
            local x, z = xmlFile:getValue(key .. "#x"), xmlFile:getValue(key .. "#z")
            if x ~= nil and z ~= nil then
                MarkerOverrides.points[#MarkerOverrides.points + 1] = { x, z }
            end
        end)
        xmlFile:delete()
    end
end

function MarkerOverrides.save()
    if MarkerOverrides.path == nil or schema() == nil then
        return false
    end
    local xmlFile = XMLFile.create("TaskMapMarkers", MarkerOverrides.path, "markers", schema())
    if xmlFile == nil then
        return false
    end
    for i, p in ipairs(MarkerOverrides.points) do
        local key = string.format("markers.point(%d)", i - 1)
        xmlFile:setValue(key .. "#x", p[1])
        xmlFile:setValue(key .. "#z", p[2])
    end
    xmlFile:save()
    xmlFile:delete()
    return true
end
