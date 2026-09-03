--[[
    TrailPointHotspot.lua

    A MapHotspot that renders one small solid dot - used to draw a traced
    trail/area point sequence (WailaTrailTracer's output) as a chain of
    dots rather than connected rotated line segments. Deliberately the
    safer first version: reuses FieldJobHotspot's own confirmed-working
    non-rotating render pattern exactly (forceNoRotation = true, same
    world-to-screen pipeline via IngameMap:addMapHotspot), rather than
    building on MapHotspot's rotation-from-world-direction behavior,
    which isn't confirmed from any source available here. Upgrading to
    real connected segments is a real follow-up once that's confirmed,
    not a permanent design choice.
]]

TrailPointHotspot = {}
local TrailPointHotspot_mt = Class(TrailPointHotspot, MapHotspot)

function TrailPointHotspot.new(customMt)
    local self = MapHotspot.new(customMt or TrailPointHotspot_mt)
    self.width, self.height = getNormalizedScreenValues(6, 6)
    self.color = { 0.6, 0.6, 0.6 }
    self.forceNoRotation = true
    return self
end

function TrailPointHotspot:setColor3(r, g, b)
    self.color = { r, g, b }
end

function TrailPointHotspot:getCategory()
    return MapHotspot.CATEGORY_FIELD
end

function TrailPointHotspot:getWidth()
    return self.width
end

function TrailPointHotspot:getHeight()
    return self.height
end

function TrailPointHotspot:getDimension()
    return self.width, self.height
end

-- Plain filled square via text-free overlay rendering would need a real
-- image handle (createImageOverlay) - simpler and consistent with
-- FieldJobHotspot's own confirmed-working approach: draw it as a
-- rendered glyph instead of a texture quad, same renderText call. Plain
-- ASCII "#" instead of a Unicode block-drawing character - the same
-- character set every other label in this codebase (job letters,
-- field numbers) already renders successfully, not dependent on the
-- game's font actually having a glyph for something more exotic.
function TrailPointHotspot:render(x, y, rotation, small)
    local scale = self.scale or 1
    local textSize = self.height * scale
    local color = self.color
    local a = 1

    setTextAlignment(RenderText.ALIGN_CENTER)
    setTextColor(color[1], color[2], color[3], a)
    renderText(x + self.width * scale * 0.5, y, textSize, "#")
    setTextAlignment(RenderText.ALIGN_LEFT)
    setTextColor(1, 1, 1, 1)
end
