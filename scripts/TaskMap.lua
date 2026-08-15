--[[
    TaskMap.lua -- entry point

    This file is the display layer ONLY -- it owns nothing about what a
    field actually needs, just how to turn WAILA's answer into a map
    label. Everything domain-related (world scanning, farmland/rice-field
    boundary handling, job thresholds, persistence, vehicle-leave-field
    tracking) lives entirely in WAILA now; this mod holds none of it, not
    even a fallback copy. What's left here is deliberately small: pick a
    color, map a job type to a letter (WAILA's own default, not
    reinvented here), turn a position into a MapHotspot, decide when to
    redraw. If you're looking for the actual "what does this field need"
    logic, it's not in this file at all -- see WAILA's WailaFieldIndex.lua
    / WailaJobDefinitions.lua.

    Used to run its own independent world scan (FieldGridScanner --
    later ported into WAILA as WailaFieldGridScanner, proven there
    first) -- now a pure consumer of WAILA's WailaFieldIndex instead.
    WAILA does the one full-map sweep, tracks vehicle-leave-field
    transitions, and merges rice-field-spanning blobs correctly (a real,
    confirmed live case -- one paddy placeable legitimately spanning two
    administratively-separate Field polygons underneath) -- none of that
    gets re-derived here anymore.

    Requires FS25_whatAmILookingAt (see modDesc.xml <dependencies>).
    Running the same expensive density-map sweep independently in two
    mods just to keep this one "standalone" was the wrong tradeoff --
    gameplay/performance cost beats architectural purity here.

    Letters come from g_currentMission.waila.getJobLetter(jobType) --
    WAILA's own optional default presentation for a job type (see
    WailaJobDefinitions.lua), not reinvented here. Not authoritative --
    a mod wanting different presentation (icons, colors, ...) would key
    off entry.field.jobs' type strings directly instead and ignore this.

    Purely additive: never touches drawFields or any base-game overlay,
    only adds hotspots via the same IngameMap:addMapHotspot pipeline
    vehicle/mission icons use, so nothing here can conflict with whatever
    overlay the player has selected (base game or another mod's).
]]

TaskMap = {}

-- WAILA's own index does the actual scanning/tracking on its own
-- schedule; this just periodically re-reads whatever it currently knows
-- and redraws. Doesn't need to be fast -- the VEHICLE_LEFT_FIELD
-- subscription below already gives a snappier redraw right after
-- something actually changes, this is just the reliable baseline.
TaskMap.REDRAW_INTERVAL = 3000

-- Fixed color rather than the owning farm's color (tried first, matching
-- FarmlandHotspot's own field-number text) -- farm colors are player-
-- chosen and land in the green/brown range a farm map already is half the
-- time, so contrast wasn't guaranteed. Red reads as rare/alarming against
-- basically every vanilla ground/crop/foliage color in this game, so it's
-- used unconditionally instead of trying to pick something that contrasts
-- with whatever's underneath.
TaskMap.LABEL_COLOR = { 1, 0.15, 0.15 }

local TaskMap_mt = Class(TaskMap)

function TaskMap.new()
    local self = setmetatable({}, TaskMap_mt)
    self.activeHotspots = {}
    self.redrawTimer = 0
    self.subscribedToEvents = false
    return self
end

-- entry: one of Waila.getAll("field")'s entries -- {wailaFieldId, labelX,
-- labelZ, sampleX, sampleZ, field, riceField}. field can be nil (WAILA
-- hasn't refreshed it yet, e.g. right after its own cache load) -- skip
-- silently, it'll show up on a later redraw once WAILA populates it.
function TaskMap:addHotspotIfNeeded(ingameMap, entry)
    if entry.field == nil then
        return
    end

    local letters = {}
    for _, jobType in ipairs(entry.field.jobs) do
        local letter = g_currentMission.waila.getJobLetter(jobType)
        if letter ~= nil then
            table.insert(letters, letter)
        end
    end
    if #letters == 0 then
        return
    end

    local color = TaskMap.LABEL_COLOR
    local hotspot = FieldJobHotspot.new()
    hotspot:setJob(table.concat(letters, " "), color[1], color[2], color[3])
    hotspot:setWorldPosition(entry.labelX, entry.labelZ)
    ingameMap:addMapHotspot(hotspot)
    table.insert(self.activeHotspots, hotspot)
end

-- Wipes every currently-shown label and rebuilds from
-- g_currentMission.waila.getAll("field") -- WAILA owns discovery/
-- tracking now, this only ever reads its current result and redraws,
-- never scans anything itself. Reads through g_currentMission, not a
-- bare Waila global -- a mod's own declared globals aren't actually
-- visible to OTHER mods' scripts (confirmed live: WAILA's own bare
-- Waila global read as nil from here despite WAILA having already
-- loaded -- same issue WAILA's own WailaHud/ImmersiveWeathering docking
-- hit earlier, g_currentMission is the fix both times). Missing
-- entirely (dependency somehow not present despite modDesc.xml, or not
-- loaded yet) degrades to doing nothing rather than crashing.
function TaskMap:rebuildAllHotspots()
    if g_currentMission == nil or g_currentMission.waila == nil then
        return
    end

    local ingameMap = g_currentMission.hud ~= nil and g_currentMission.hud.ingameMap
    if ingameMap == nil then
        return
    end

    for _, hotspot in ipairs(self.activeHotspots) do
        ingameMap:removeMapHotspot(hotspot)
    end
    self.activeHotspots = {}

    local entries = g_currentMission.waila.getAll("field")
    if entries == nil then
        return
    end

    for _, entry in ipairs(entries) do
        self:addHotspotIfNeeded(ingameMap, entry)
    end
end

-- g_currentMission.waila.events.vehicleLeftField handler -- redraw right
-- away instead of waiting up to REDRAW_INTERVAL for the next periodic
-- pass.
function TaskMap:onVehicleLeftField(vehicleOrPlayer, entry)
    self:rebuildAllHotspots()
end

function TaskMap:deleteMap()
    g_messageCenter:unsubscribeAll(self)
end

-- Retries once per frame until it succeeds, instead of a one-shot check
-- in loadMap() -- load order between this mod and WAILA isn't guaranteed
-- (see docs/engine-api/CrossMod.md), so loadMap() could run before
-- WAILA's g_currentMission.waila even exists yet.
function TaskMap:trySubscribeToWailaEvents()
    if self.subscribedToEvents or g_currentMission == nil or g_currentMission.waila == nil then
        return
    end
    g_messageCenter:subscribe(g_currentMission.waila.events.vehicleLeftField, self.onVehicleLeftField, self)
    self.subscribedToEvents = true
end

-- Redraws on a fixed cadence, independent of onVehicleLeftField (which
-- already redraws immediately when something changes) -- this is just
-- the fallback that keeps things honest even if that event doesn't fire.
function TaskMap:tickRedraw(dt)
    self.redrawTimer = self.redrawTimer + dt
    if self.redrawTimer >= TaskMap.REDRAW_INTERVAL then
        self.redrawTimer = 0
        self:rebuildAllHotspots()
    end
end

-- Engine callback, once per frame (registered via addModEventListener at
-- the bottom of this file -- not called from anywhere in this mod's own
-- code). The two jobs below are unrelated to each other -- they just
-- both need to happen every frame, and this is the only hook for that.
function TaskMap:update(dt)
    self:trySubscribeToWailaEvents()
    self:tickRedraw(dt)
end

g_taskMap = TaskMap.new()
addModEventListener(g_taskMap)
