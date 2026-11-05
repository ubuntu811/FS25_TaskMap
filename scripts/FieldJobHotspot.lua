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
FieldJobHotspot.CLICK_RADIUS_FACTOR = 0.55     -- of the (scaled) width: the "i" badge is clickable a little beyond its outline
FieldJobHotspot.BADGE_RADIUS_FACTOR = 0.42
local function isMinimapLayout(layout)
    return layout ~= nil and (layout:isa(IngameMapLayoutCircle) or layout:isa(IngameMapLayoutSquare) or layout:isa(IngameMapLayoutSquareLarge))
end

function FieldJobHotspot.new(customMt)
    local self = MapHotspot.new(customMt or FieldJobHotspot_mt)
    self.width, self.height = getNormalizedScreenValues(28, 28)
    local _, minFullscreenTextSize = getNormalizedScreenValues(0, 16)
    self.minFullscreenTextSize = minFullscreenTextSize
    self.label = ""
    self.forceNoRotation = true
    self.isFieldInfoHotspot = true                                   -- (FieldClick: a click on the "i" selects the field's farmland popup)
    self.clickArea = MapHotspot.getClickCircle(FieldJobHotspot.CLICK_RADIUS_FACTOR)   -- (no click area = no mouse events at all, which is why the labels never reacted)
    return self
end

function FieldJobHotspot:setJob(label, r, g, b)
    self.label = label
    self:setColor(r, g, b)
end

function FieldJobHotspot:getCategory()
    return MapHotspot.CATEGORY_FIELD
end

-- (the size as drawn: the click area is measured from it, so it must follow the zoom like the drawing does)
function FieldJobHotspot:getWidth()
    return self.width * (self.scale or 1)
end

function FieldJobHotspot:getHeight()
    return self.height * (self.scale or 1)
end

function FieldJobHotspot:getDimension()
    return self:getWidth(), self:getHeight()
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
    local color = self.color
    local a = self.isBlinking and self:getCanBlink() and IngameMap.alpha or 1
    local hasLetters = self.label ~= ""
    local minimap = isMinimapLayout(self.lastScreenLayout)

    setTextBold(true)
    if minimap then
        -- the minimap is not clickable: the letters only, centred on the corner as before; a field with nothing to do shows nothing
        if hasLetters then
            local textSize = height * 0.8 * FieldJobHotspot.MINIMAP_SCALE_MULTIPLIER
            setTextAlignment(RenderText.ALIGN_CENTER)
            setTextColor(0, 0, 0, a)
            renderText(x + width * 0.5 + g_pixelSizeX, y - g_pixelSizeY, textSize, self.label)
            setTextColor(color[1], color[2], color[3], a)
            renderText(x + width * 0.5, y, textSize, self.label)
        end
    else
        -- the big map: a small "i" badge (the clickable part, centred on the hotspot) and the job letters to its right
        local textSize = math.max(height * 0.8, self.minFullscreenTextSize)
        local centerX, centerY = x + width * 0.5, y + height * 0.5
        local radius = width * FieldJobHotspot.BADGE_RADIUS_FACTOR
        drawOutlineCircle2D(centerX + g_pixelSizeX, centerY - g_pixelSizeY, radius, 0.0022, 24, 0, 0, 0, a)
        drawOutlineCircle2D(centerX, centerY, radius, 0.0016, 24, 1, 1, 1, a)
        setTextAlignment(RenderText.ALIGN_CENTER)
        local iSize = radius * 1.5
        setTextColor(0, 0, 0, a)
        renderText(centerX + g_pixelSizeX, centerY - iSize * 0.36 - g_pixelSizeY, iSize, "i")
        setTextColor(1, 1, 1, a)
        renderText(centerX, centerY - iSize * 0.36, iSize, "i")
        if hasLetters then
            setTextAlignment(RenderText.ALIGN_LEFT)
            local textX = centerX + radius + width * 0.2
            local textY = centerY - textSize * 0.36
            setTextColor(0, 0, 0, a)
            renderText(textX + g_pixelSizeX, textY - g_pixelSizeY, textSize, self.label)
            setTextColor(color[1], color[2], color[3], a)
            renderText(textX, textY, textSize, self.label)
        end
    end
    setTextAlignment(RenderText.ALIGN_LEFT)
    setTextBold(false)
    setTextColor(1, 1, 1, 1)
end
