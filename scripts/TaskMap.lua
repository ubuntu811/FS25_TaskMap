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

-- Real, explicit fix, confirmed live: this used to call a single
-- blocking scanWholeMapOverlay() covering all 256 tiles in one call --
-- "either too slow or game got killed." Real project rule this broke:
-- every scan needs a real per-tick budget (see this session's own
-- feedback_waila_performance_is_non_negotiable memory). Now just starts
-- WailaTrailTracer's own incremental state machine -- see its
-- startWholeMapScan/tickWholeMapScan headers -- and TaskMap:update(dt)
-- below drives it one tile per frame until done. Still its own separate
-- keybind (TASKMAP_TRAIL_SCAN_WHOLE_MAP), not folded into
-- onRescanTrailNow, so it can never fire by accident.
function TaskMap:onRescanWholeMap(actionName, inputValue, callbackState, isAnalog)
    local wailaTrailTracer = g_currentMission.wailaTrailTracer
    if wailaTrailTracer == nil then
        print("[TaskMap] whole-map scan: g_currentMission.wailaTrailTracer is nil (WAILA not loaded/too early?)")
        return
    end

    wailaTrailTracer.startWholeMapScan()
end

-- Real, confirmed pattern -- mirrors FS25WhatAmILookingAt's own
-- registerActionEvents/PlayerInputComponent hook exactly (see that mod's
-- own comment on why category="ONFOOT" isn't used and this global hook is
-- the real, working alternative).
function TaskMap:registerActionEvents()
    local _, wholeMapId = g_inputBinding:registerActionEvent(
        InputAction.TASKMAP_TRAIL_SCAN_WHOLE_MAP,
        self,
        self.onRescanWholeMap,
        false, true, false, true, nil, true
    )
    if wholeMapId ~= nil then
        g_inputBinding:setActionEventTextPriority(wholeMapId, GS_PRIO_LOW)
        g_inputBinding:setActionEventTextVisibility(wholeMapId, true)
    end
end

PlayerInputComponent.registerGlobalPlayerActionEvents = Utils.appendedFunction(
    PlayerInputComponent.registerGlobalPlayerActionEvents,
    function()
        -- g_taskMap (the instance), not the bare TaskMap class table, is the
        -- action-event target.
        g_taskMap:registerActionEvents()
    end
)

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
    self:tickWholeMapScan()
    self:tryPatchAfterMinimapPlus()
end

-- Drives WailaTrailTracer's own incremental whole-map scan state
-- machine, one tile per frame -- see onRescanWholeMap's own comment for
-- why this exists (a single 256-tile blocking call froze/killed the
-- game). tickWholeMapScan() itself returns true (a safe, cheap no-op)
-- whenever no scan is actually running, so this can be called
-- unconditionally every frame without its own guard.
function TaskMap:tickWholeMapScan()
    local wailaTrailTracer = g_currentMission.wailaTrailTracer
    if wailaTrailTracer == nil then
        return
    end
    wailaTrailTracer.tickWholeMapScan()
end

-- Intentionally empty: see the comment inside.
function TaskMap:draw()
    -- Scan / field sweep / restore / save progress used to be drawn here (top right, on top of
    -- the contract bars). It lives in WAILA's HUD now: a strip under the mini panel
    -- (WailaHud.collectTaskRows), one place for every WAILA job.
end

-- Real, explicit removal: the fixed-screen-rect version ("does the baked
-- overlay show up as real pixels at all") is gone -- confirmed live, an
-- independent draw() hook guessing at both position AND draw timing
-- visibly broke things (the minimap's own content stopped rendering,
-- shapes floated in what looked like world space). Real request ("go
-- steal what the map is doing with fields"): hook directly into
-- IngameMap:drawFields itself via Utils.appendedFunction -- the same
-- base-game-method-patching pattern this whole mod family already uses
-- (PlayerInputComponent.registerGlobalPlayerActionEvents above,
-- FS25WhatAmILookingAt.lua's StoreManager/SavegameController hooks) --
-- so our overlay draws at the exact same point in the exact same
-- sequence the real fields overlay does, with the exact same position
-- math (self.layout:getMapSize/getMapPosition/getMapPivot/
-- getMapRotation, self.mapExtensionOffsetX/Z,
-- self.mapExtensionScaleFactor -- confirmed live against
-- IngameMap:drawFields' own body). No independent per-frame hook of our
-- own needed at all -- IngameMap calls its own drawFields every frame
-- already, and appendedFunction rides along with that.
-- Real request ("still nothing" after the minimap clip fix): rather than
-- guess again, log WHICH branch is actually bailing, once per distinct
-- state (not every frame) so a single log capture shows exactly what's
-- happening instead of another blind fix attempt. See
-- feedback_trust_live_evidence_over_code_reading.
-- Real, confirmed live gap: pure state-based dedup only logs the FIRST
-- time a given state occurs -- if the corner minimap rendered with its
-- own small size even ONCE early on, then never changed again, it would
-- log exactly once and then go silent forever, indistinguishable from
-- "never happened at all" in a log excerpt taken later. Confirmed this
-- was actually hiding evidence: every single "rendering" line captured
-- all session was the same fullscreen-scale size -- zero minimap-scale
-- renders ever logged -- but dedup alone can't tell us whether that's
-- because the minimap genuinely never renders, or because its one-time
-- log line is buried earlier than any excerpt looked at. Added a time
-- heartbeat alongside the state dedup: logs on a state CHANGE same as
-- before, but also unconditionally every OVERLAY_LOG_HEARTBEAT_SEC
-- regardless of whether the state repeats -- so "steady, unchanging,
-- still happening" and "never happening" are finally distinguishable in
-- a short log excerpt.
local loggedOverlayStates = {}
local lastOverlayLogTime = {}
local OVERLAY_LOG_HEARTBEAT_SEC = 300.0
local function logOverlayStateOnce(logKey, state, ...)
    local now = getTimeSec()
    local stateChanged = loggedOverlayStates[logKey] ~= state
    local heartbeatDue = lastOverlayLogTime[logKey] == nil or now - lastOverlayLogTime[logKey] >= OVERLAY_LOG_HEARTBEAT_SEC
    if stateChanged or heartbeatDue then
        loggedOverlayStates[logKey] = state
        lastOverlayLogTime[logKey] = now
        print(string.format(...))
    end
end

-- Real idea ("the base map already has its gray roads/paths ... if we
-- could grab those"): we can't lift the road layer out of the map's
-- single background image, but we don't have to -- draw the forest
-- semi-transparent and the base map's own roads/paths show through it.
-- 1.0 = opaque (old look).
TaskMap.FOREST_OVERLAY_ALPHA = 0.1
-- Worn trails / paths: a subtle dark line, about half transparent (opaque in
-- WAILA's debug colour mode).
TaskMap.TRAIL_OVERLAY_ALPHA = 0.5

-- Opacity / visibility per layer now come from WAILA's per-savegame map
-- settings (debug hub, Map layers tab) through the tracer; the constants
-- above are the fallback for an older WAILA without the accessors.
local function layerAlpha(tracer, layer, fallback)
    if tracer.getLayerAlpha ~= nil then
        return tracer.getLayerAlpha(layer)
    end
    return tracer.debugColors and 1.0 or fallback
end
local function layerVisible(tracer, layer)
    return tracer.isLayerVisible == nil or tracer.isLayerVisible(layer)
end

-- Shared render path for any density-map-visualization overlay drawn
-- onto IngameMap -- factored out once a SECOND overlay (the real-road-
-- spline proof, see WailaTrailTracer.buildRoadSplineOverlay) needed the
-- exact same position/clip math as the trail overlay already had, so the
-- two copies wouldn't drift apart from each other over time. logKey
-- keeps each overlay's diagnostic dedup state independent (loggedOverlayStates
-- is shared storage, keyed per overlay, not per literal state string).
local function renderMapOverlay(self, overlay, logKey, logLabel, alpha)
    local width, height = self.layout:getMapSize()
    local x, y = self.layout:getMapPosition()
    local px, py = self.layout:getMapPivot()
    px = px + x
    py = py + y
    x = x + width * self.mapExtensionOffsetX
    y = y + height * self.mapExtensionOffsetZ
    px = px - x
    py = py - y
    local posX = x
    local posY = y
    local sizeX = width * self.mapExtensionScaleFactor
    local sizeY = height * self.mapExtensionScaleFactor

    logOverlayStateOnce(
        logKey,
        "rendering", -- constant: the geometry changes every frame while panning/zooming, the heartbeat still logs the numbers
        "[TaskMap] %s: overlay ready, rendering (width=%.3f height=%.3f posX=%.3f posY=%.3f sizeX=%.3f sizeY=%.3f clipX1=%s)",
        logLabel, width, height, posX, posY, sizeX, sizeY, tostring(self.clipX1))

    -- Real, confirmed bug: the corner minimap (IngameMapLayoutCircle) sets
    -- self.clipX1/Y1/X2/Y2 to crop the fields overlay into its round
    -- shape -- drawFields' own body (confirmed via decompile) recomputes
    -- posX/posY/sizeX/sizeY AND the overlay's UVs for that clip via
    -- Overlay.getClippingUVs. This copy never replicated that branch, so
    -- it always drew with the un-clipped fullscreen-map math -- harmless
    -- on the fullscreen layout (clipX1 is nil there) but wrong position/
    -- size on the minimap, which is why nothing visible showed up there.
    if self.clipX1 ~= nil then
        local u1, v1, u2, v2, u3, v3, u4, v4
        posX, posY, sizeX, sizeY, u1, v1, u2, v2, u3, v3, u4, v4 = Overlay.getClippingUVs(Overlay.DEFAULT_UVS, posX, posY, sizeX, sizeY, self.clipX1, self.clipY1, self.clipX2, self.clipY2)
        if u1 == nil then
            return
        end
        setOverlayUVs(overlay, u1, v1, u2, v2, u3, v3, u4, v4)
    end

    setOverlayRotation(overlay, self.layout:getMapRotation(), px, py)
    setOverlayColor(overlay, 1, 1, 1, alpha or 1)
    renderOverlay(overlay, posX, posY, sizeX, sizeY)
    if self.clipX1 ~= nil then
        setOverlayUVs(overlay, unpack(Overlay.DEFAULT_UVS))
    end
end

local function drawWailaTrailOverlay(self)
    local wailaTrailTracer = g_currentMission.wailaTrailTracer
    if wailaTrailTracer == nil then
        logOverlayStateOnce("trail", "noTracer", "[TaskMap] drawWailaTrailOverlay: g_currentMission.wailaTrailTracer is nil")
        return
    end
    if wailaTrailTracer.testOverlay == nil then
        logOverlayStateOnce("trail", "noOverlay", "[TaskMap] drawWailaTrailOverlay: wailaTrailTracer.testOverlay is nil (no scan has run yet this session)")
        return
    end
    if not getIsDensityMapVisualizationOverlayReady(wailaTrailTracer.testOverlay) then
        logOverlayStateOnce("trail", "notReady", "[TaskMap] drawWailaTrailOverlay: overlay exists but getIsDensityMapVisualizationOverlayReady returned false")
        return
    end
    if layerVisible(wailaTrailTracer, "trail") then
        renderMapOverlay(self, wailaTrailTracer.testOverlay, "trail", "drawWailaTrailOverlay", layerAlpha(wailaTrailTracer, "trail", TaskMap.TRAIL_OVERLAY_ALPHA))
    end
end

-- Real request ("go ahead, make sure both are drawn in distinct
-- colors"): third independent overlay for WailaTrailTracer.buildFeatureOverlay
-- (tree/water, via real CollisionFlag.TREE/WATER raycasts) -- same
-- independent-hook reasoning as drawWailaTrailOverlay above.
local function drawWailaFeatureOverlay(self)
    local wailaTrailTracer = g_currentMission.wailaTrailTracer
    if wailaTrailTracer == nil then
        logOverlayStateOnce("feature", "noTracer", "[TaskMap] drawWailaFeatureOverlay: g_currentMission.wailaTrailTracer is nil")
        return
    end
    if wailaTrailTracer.featureOverlay == nil then
        logOverlayStateOnce("feature", "noOverlay", "[TaskMap] drawWailaFeatureOverlay: wailaTrailTracer.featureOverlay is nil (run 'Build tree/water overlay' from the debug hub first)")
        return
    end
    if not getIsDensityMapVisualizationOverlayReady(wailaTrailTracer.featureOverlay) then
        logOverlayStateOnce("feature", "notReady", "[TaskMap] drawWailaFeatureOverlay: overlay exists but getIsDensityMapVisualizationOverlayReady returned false")
        return
    end
    renderMapOverlay(self, wailaTrailTracer.featureOverlay, "feature", "drawWailaFeatureOverlay")
end

-- Real request ("classify space first... go ahead with the forests"):
-- fifth overlay, for WailaTrailTracer.buildForestOverlay -- the material-
-- diversity classifier prototype, same independent-hook pattern as the
-- other four.
local function drawWailaWaterLayerOverlay(self)
    local wailaTrailTracer = g_currentMission.wailaTrailTracer
    if wailaTrailTracer == nil or wailaTrailTracer.waterLayerOverlay == nil then
        return
    end
    if not getIsDensityMapVisualizationOverlayReady(wailaTrailTracer.waterLayerOverlay) then
        return
    end
    if layerVisible(wailaTrailTracer, "water") then
        renderMapOverlay(self, wailaTrailTracer.waterLayerOverlay, "waterLayer", "drawWailaWaterLayerOverlay", layerAlpha(wailaTrailTracer, "water", 0.7))
    end
end

local function drawWailaTreeLayerOverlay(self)
    local wailaTrailTracer = g_currentMission.wailaTrailTracer
    if wailaTrailTracer == nil or wailaTrailTracer.treeLayerOverlay == nil then
        return
    end
    if not getIsDensityMapVisualizationOverlayReady(wailaTrailTracer.treeLayerOverlay) then
        return
    end
    if layerVisible(wailaTrailTracer, "tree") then
        renderMapOverlay(self, wailaTrailTracer.treeLayerOverlay, "treeLayer", "drawWailaTreeLayerOverlay", layerAlpha(wailaTrailTracer, "tree", 0.9))
    end
end

local function drawWailaBuildingLayerOverlay(self)
    local wailaTrailTracer = g_currentMission.wailaTrailTracer
    if wailaTrailTracer == nil or wailaTrailTracer.buildingLayerOverlay == nil then
        return
    end
    if not getIsDensityMapVisualizationOverlayReady(wailaTrailTracer.buildingLayerOverlay) then
        return
    end
    if layerVisible(wailaTrailTracer, "building") then
        renderMapOverlay(self, wailaTrailTracer.buildingLayerOverlay, "buildingLayer", "drawWailaBuildingLayerOverlay", layerAlpha(wailaTrailTracer, "building", 1.0))
    end
end

local function drawWailaRoadLayerOverlay(self)
    local wailaTrailTracer = g_currentMission.wailaTrailTracer
    if wailaTrailTracer == nil or wailaTrailTracer.roadLayerOverlay == nil then
        return
    end
    if not getIsDensityMapVisualizationOverlayReady(wailaTrailTracer.roadLayerOverlay) then
        return
    end
    if layerVisible(wailaTrailTracer, "road") then
        renderMapOverlay(self, wailaTrailTracer.roadLayerOverlay, "roadLayer", "drawWailaRoadLayerOverlay", layerAlpha(wailaTrailTracer, "road", 1.0))
    end
end

local function drawWailaLayerClassOverlay(self)
    local wailaTrailTracer = g_currentMission.wailaTrailTracer
    if wailaTrailTracer == nil or wailaTrailTracer.layerClassOverlay == nil then
        return
    end
    if not getIsDensityMapVisualizationOverlayReady(wailaTrailTracer.layerClassOverlay) then
        return
    end
    renderMapOverlay(self, wailaTrailTracer.layerClassOverlay, "layerClass", "drawWailaLayerClassOverlay")
end

local function drawWailaForestOverlay(self)
    local wailaTrailTracer = g_currentMission.wailaTrailTracer
    if wailaTrailTracer == nil then
        logOverlayStateOnce("forest", "noTracer", "[TaskMap] drawWailaForestOverlay: g_currentMission.wailaTrailTracer is nil")
        return
    end
    if wailaTrailTracer.forestOverlay == nil then
        logOverlayStateOnce("forest", "noOverlay", "[TaskMap] drawWailaForestOverlay: wailaTrailTracer.forestOverlay is nil (run 'Build forest overlay' from the debug hub first)")
        return
    end
    if not getIsDensityMapVisualizationOverlayReady(wailaTrailTracer.forestOverlay) then
        logOverlayStateOnce("forest", "notReady", "[TaskMap] drawWailaForestOverlay: overlay exists but getIsDensityMapVisualizationOverlayReady returned false")
        return
    end
    -- debug colour mode (WAILA debug hub toggle): forest fully opaque so it is obvious
    if layerVisible(wailaTrailTracer, "forest") then
        renderMapOverlay(self, wailaTrailTracer.forestOverlay, "forest", "drawWailaForestOverlay", layerAlpha(wailaTrailTracer, "forest", TaskMap.FOREST_OVERLAY_ALPHA))
    end
end

-- Real request ("draw the forest patches underneath, so roads going
-- through forest patches are visible"): draw order here IS layering
-- order (painter's algorithm -- each appended function draws on top of
-- everything before it). Forest goes first (bottom layer) specifically
-- so real roads -- drawn after -- stay visible cutting through a forest
-- patch instead of being covered by it.
IngameMap.drawFields = Utils.appendedFunction(IngameMap.drawFields, drawWailaWaterLayerOverlay)
IngameMap.drawFields = Utils.appendedFunction(IngameMap.drawFields, drawWailaForestOverlay)
IngameMap.drawFields = Utils.appendedFunction(IngameMap.drawFields, drawWailaTreeLayerOverlay)
IngameMap.drawFields = Utils.appendedFunction(IngameMap.drawFields, drawWailaTrailOverlay)
IngameMap.drawFields = Utils.appendedFunction(IngameMap.drawFields, drawWailaBuildingLayerOverlay)
IngameMap.drawFields = Utils.appendedFunction(IngameMap.drawFields, drawWailaRoadLayerOverlay)
IngameMap.drawFields = Utils.appendedFunction(IngameMap.drawFields, drawWailaFeatureOverlay)
IngameMap.drawFields = Utils.appendedFunction(IngameMap.drawFields, drawWailaLayerClassOverlay)

-- Real, confirmed live find (2026-09-30, user + investigation of
-- FS25_minimapPlus's own source): the reason nothing ever showed on the
-- corner minimap all session, even the simplest possible test polygon,
-- is a genuine third-party mod conflict, not a bug in any of the above.
-- MMapPlus patches drawFields on the INSTANCE
-- (g_currentMission.hud.ingameMap.drawFields = Utils.overwrittenFunction(...)),
-- not the class table the four appends above target -- Lua instance
-- fields shadow class/metatable fields, so once minimapPlus's patch
-- runs, EVERY call to that one shared ingameMap's :drawFields() resolves
-- to ITS wrapper first, not ours. That wrapper only calls its own
-- captured oldFunc (which, by load order, already includes our whole
-- class-level chain above) for the FULLSCREEN layout; for any minimap
-- layout (Circle/Square/SquareLarge) it builds its own hardcoded 2-
-- overlay list and returns WITHOUT ever calling oldFunc -- our entire
-- chain silently skipped, every time, for every minimap shape, no matter
-- how simple the test data was.
--
-- Real fix: append AFTER minimapPlus's own instance-level patch, on the
-- SAME instance field -- Utils.appendedFunction always runs BOTH halves
-- unconditionally, regardless of what the first half's own internal
-- branching decided, so this fires for every layout, completely
-- independent of minimapPlus's logic (harmless if it also draws via the
-- fullscreen path's oldFunc -- same overlay drawn twice on the same
-- frame is a no-op visually, not a correctness bug).
--
-- Real, confirmed live bug in the FIRST version of this fix: it detected
-- "minimapPlus has patched" via MMapPlus.isIngameMapPatched -- a global
-- MMapPlus declares in ITS OWN mod. Confirmed live (empty log, the
-- success message never printed) that this is the exact same class of
-- bug this project's own fs25_cross_mod_globals memory already
-- documents: a mod's own declared globals are invisible from a DIFFERENT
-- mod's Lua sandbox, so MMapPlus read as nil from TaskMap regardless of
-- whether minimapPlus was actually loaded. Real fix: stop depending on
-- any mod-specific global at all. g_currentMission.hud.ingameMap is a
-- real, shared, base-game object (visible everywhere, unlike MMapPlus),
-- so watch ITS OWN drawFields field directly via rawget (true instance-
-- level presence, ignoring class/metatable inheritance) -- self-heals
-- against load order automatically: every time something ELSE re-patches
-- the instance (minimapPlus or, in principle, any other mod), the value
-- changes, and we re-append on top of whatever's there now, keeping our
-- draws last in the chain no matter when everyone else's patches land.
local hasPatchedInstanceOnce = false
local lastKnownInstanceDrawFields = nil
function TaskMap:tryPatchAfterMinimapPlus()
    if g_currentMission == nil or g_currentMission.hud == nil or g_currentMission.hud.ingameMap == nil then
        return
    end

    local ingameMap = g_currentMission.hud.ingameMap
    local current = rawget(ingameMap, "drawFields")
    if hasPatchedInstanceOnce and current == lastKnownInstanceDrawFields then
        return
    end

    ingameMap.drawFields = Utils.appendedFunction(ingameMap.drawFields, function(self)
        drawWailaWaterLayerOverlay(self)
        drawWailaForestOverlay(self)
        drawWailaTreeLayerOverlay(self)
        drawWailaTrailOverlay(self)
        drawWailaBuildingLayerOverlay(self)
        drawWailaRoadLayerOverlay(self)
        drawWailaFeatureOverlay(self)
        drawWailaLayerClassOverlay(self)
    end)
    hasPatchedInstanceOnce = true
    lastKnownInstanceDrawFields = rawget(ingameMap, "drawFields")
    print("[TaskMap] (re-)patched ingameMap's instance-level drawFields -- keeps our overlays last in the chain regardless of what other mods (e.g. minimapPlus) do to it")
end

g_taskMap = TaskMap.new()
addModEventListener(g_taskMap)
