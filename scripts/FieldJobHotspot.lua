--[[
    FieldJobHotspot.lua

    A MapHotspot that renders a text glyph at a field's position. Reuses the
    exact pipeline the base game already uses for vehicle/mission icons
    (IngameMap:addMapHotspot, which then drives IngameMap:drawHotspot ->
    hotspot:render(x, y, rotation, small) every frame with the screen
    position already computed) -- we only override render() to draw text
    instead of an icon texture.

    One hotspot per field, not one per active job -- the label is all
    active job letters space-joined into a single string ("P R", "W S L",
    ...), set via setJob(). Simpler than stacking multiple hotspots in rows
    (tried first, fighting row-offset/clearance math the whole way) and
    sidesteps it entirely.

    Positioned at a field corner (TaskMap:getFieldCornerPosition),
    not the field's center -- the center is exactly where the field-number
    badge, the player's own map pin, and vehicle icons all cluster, which
    is what motivated the whole badge-clearance tuning fight in the first
    place. At a corner there's nothing to clear, so no offset is needed at
    all anymore.

    Color: fixed red (TaskMap.LABEL_COLOR), passed in via setJob().
    Tried the owning farm's color first (matching FarmlandHotspot's own
    field-number text) but farm colors are player-chosen and often land in
    the same green/brown range the map itself is, so contrast wasn't
    guaranteed. Black is apparently a no-op in this render path (confirmed
    by two failed attempts, likely additive blending), white vanishes on
    light/yellow fields -- red reads as rare/alarming against basically
    every vanilla ground/crop/foliage color instead.

    Shadow technique (single black offset behind the main color, drawn
    first) copied directly from FarmlandHotspot:render()'s own confirmed-
    working code, not invented.
]]

FieldJobHotspot = {}
local FieldJobHotspot_mt = Class(FieldJobHotspot, MapHotspot)

-- IngameMapLayoutSquare/Circle:getIconZoom() return a flat 0.5 regardless
-- of anything; IngameMapLayoutFullscreen:getIconZoom() ranges 0.25-0.75
-- with the map's own zoom level (confirmed via dataS.gar). One base size
-- can't read well across both: flat 0.5 on the small minimap reads as too
-- big/cluttered, while fullscreen's low end (0.25, zoomed all the way out)
-- reads as too small -- but fullscreen's high end (0.75, zoomed all the
-- way in) already looks right unscaled, confirmed live. So: shrink
-- uniformly on the minimap, but only floor the *minimum* size on
-- fullscreen instead of multiplying the whole range, so the already-good
-- zoomed-in end doesn't get blown up just to fix the zoomed-out end.
FieldJobHotspot.MINIMAP_SCALE_MULTIPLIER = 0.6
local function isMinimapLayout(layout)
    return layout ~= nil and (layout:isa(IngameMapLayoutCircle) or layout:isa(IngameMapLayoutSquare) or layout:isa(IngameMapLayoutSquareLarge))
end

function FieldJobHotspot.new(customMt)
    local self = MapHotspot.new(customMt or FieldJobHotspot_mt)
    self.width, self.height = getNormalizedScreenValues(28, 28)
    local _, minFullscreenTextSize = getNormalizedScreenValues(0, 16)
    self.minFullscreenTextSize = minFullscreenTextSize
    self.label = "?"
    self.forceNoRotation = true
    return self
end

function FieldJobHotspot:setJob(label, r, g, b)
    self.label = label
    self:setColor(r, g, b)
end

function FieldJobHotspot:getCategory()
    return MapHotspot.CATEGORY_FIELD
end

function FieldJobHotspot:getWidth()
    return self.width
end

function FieldJobHotspot:getHeight()
    return self.height
end

function FieldJobHotspot:getDimension()
    return self.width, self.height
end

function FieldJobHotspot:render(x, y, rotation, small)
    -- self.scale is kept in sync by the inherited MapHotspot:setScale,
    -- called every frame from IngameMap:drawHotspot with the current
    -- layout:getIconZoom() value -- FarmlandHotspot's own number shrinks
    -- with it (self.textSize * (0.25 + self.scale * 0.75)), so everything
    -- of ours has to scale the same way or the gap grows/shrinks as you zoom.
    -- self.lastScreenLayout is set by IngameMap:drawHotspot immediately
    -- before this call, every frame -- always populated by the time we get
    -- here, not something we set ourselves.
    local scale = self.scale or 1
    local width = self.width * scale
    local height = self.height * scale
    local textY = y
    local textX = x + width * 0.5
    local textSize = height * 0.8
    if isMinimapLayout(self.lastScreenLayout) then
        textSize = textSize * FieldJobHotspot.MINIMAP_SCALE_MULTIPLIER
    else
        textSize = math.max(textSize, self.minFullscreenTextSize)
    end
    local color = self.color
    local a = self.isBlinking and self:getCanBlink() and IngameMap.alpha or 1

    setTextBold(true)
    setTextAlignment(RenderText.ALIGN_CENTER)
    setTextColor(0, 0, 0, a)
    renderText(textX + g_pixelSizeX, textY - g_pixelSizeY, textSize, self.label)
    setTextColor(color[1], color[2], color[3], a)
    renderText(textX, textY, textSize, self.label)
    setTextAlignment(RenderText.ALIGN_LEFT)
    setTextBold(false)
    setTextColor(1, 1, 1, 1)
end
