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

-- Separate, longer interval - a trail scan (WailaTrailTracer.scanRegion)
-- is real per-tile terrain sampling work, not a cheap index readback
-- like the job-hotspot rebuild above. First-version scope is a bounded
-- radius around the player (see WailaTrailTracer's own comment on why),
-- so this only ever needs to re-run occasionally, not on the same
-- cadence as the job labels.
TaskMap.TRAIL_SCAN_INTERVAL = 15000
-- Real request, testing-only for now: the automatic interval above kept
-- re-running mid-investigation -- results changed out from under a
-- screenshot taken between pressing print-screen and it actually
-- capturing, making a "look at this weird shape" report impossible to
-- pin down. true disables the automatic interval trigger entirely
-- (tickTrailScan below still advances an in-progress scan every tick,
-- just never STARTS a new one on its own) -- TASKMAP_TRAIL_SCAN_NOW
-- (Left Shift+R) is then the only thing that starts one, so results stay
-- stable until deliberately asked to change. Flip back to false once
-- investigation settles down -- this isn't meant to be the permanent
-- default, just a temporary testing mode.
TaskMap.MANUAL_RESCAN_ONLY = true
-- Real lag spike found live: a trail scan used to be one big synchronous
-- call (blocking one frame for however long it took, even after WAILA's
-- own sweep deadline bounded that worst case to 10s -- still one frame
-- stalling for up to 10 seconds, not spread out). WailaTrailTracer now
-- exposes an incremental scanner (newScanner/:update(budget), same real
-- shape WailaFieldGridScanner already proves out) instead of the old
-- one-shot scanRegion -- driven here every tick with a tiny budget
-- instead of one big blocking call. Same proven value
-- WailaFieldIndex.SCAN_BUDGET_SEC already uses for the identical reason.
TaskMap.TRAIL_SCAN_BUDGET_SEC = 0.003
-- Bold, maximally-distinct debug colors, not a polished final palette -
-- this is drawDebugLine output meant to answer "is the sweep classifying
-- path vs area correctly," not something meant to look good on a real
-- map. Muted tan/gray (the original choice) both read as the same
-- off-white blur at a distance - yellow/magenta don't occur naturally in
-- terrain, so neither can be mistaken for the other or for scenery.
TaskMap.TRAIL_PATH_COLOR = { 1, 1, 0 }
TaskMap.TRAIL_AREA_COLOR = { 1, 0, 1 }
-- Real request: an "island" rejection (closed fine, just around the
-- WRONG region -- WailaTrailScanner's own seed-containment check) and an
-- "incomplete" rejection (never really closed at all -- hit a structure,
-- stalled, or capped out) are different findings, not the same gray blur
-- they used to be -- one topologically succeeded and got the wrong
-- answer, the other just didn't finish. Orange for islands: distinct from
-- accepted magenta and from the dim gray incomplete color below, and
-- reads as "this closed, but on the wrong thing" at a glance.
TaskMap.TRAIL_AREA_ISLAND_COLOR = { 1, 0.5, 0 }
-- Dim gray, deliberately unlike every other color above -- still drawn
-- for debugging (real, confirmed-live problem when a true boundary keeps
-- failing to close/qualify: every nearby candidate tile independently
-- re-attempts and re-fails it, and with no visual distinction from an
-- accepted area that pile of near-misses just reads as an unreadable
-- tangled mess), but never mistakable for a real accepted area.
TaskMap.TRAIL_AREA_INCOMPLETE_COLOR = { 0.5, 0.5, 0.5 }

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
    self.trailScanTimer = 0
    -- nil when idle (between scans); a real WailaTrailScanner instance
    -- (via newScanner, see TaskMap.TRAIL_SCAN_BUDGET_SEC's own comment)
    -- while a scan is incrementally in progress.
    self.trailScanner = nil
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

-- First version: reads the player's own current world position as the
-- scan center (matches WailaTrailTracer.scanRegion's own bounded-radius
-- scope) - not the camera/map-cursor position, since the player is who
-- actually cares "what's worn near me right now." Falls through to a
-- no-op if the player entity isn't available yet (same defensive shape
-- as rebuildAllHotspots' own g_currentMission.waila nil-guard).
-- g_currentMission.player.rootNode was never real -- confirmed live
-- (always nil, never resolving no matter how long the session ran).
-- g_localPlayer:getPosition() is the actual, confirmed-real API (same
-- one FieldManager.getFieldIdAtPlayerPosition itself uses internally,
-- per the base game's own decompiled source), no rootNode lookup at all.
function TaskMap:getScanCenter()
    if g_localPlayer == nil then
        return nil
    end

    local x, _, z = g_localPlayer:getPosition()
    return x, z
end

-- Starts a new incremental scan if none is currently running -- called
-- once TRAIL_SCAN_INTERVAL has elapsed since the last one finished (see
-- tickTrailScan). Every early-return here logs WHY, same reasoning the
-- old synchronous version already established: a silent "no dots ever
-- appeared" report needs to be traceable to a specific cause, not
-- guessed at.
function TaskMap:startTrailScan()
    -- Real bug found live: the bare WailaTrailTracer global is never nil
    -- because of timing -- it's PERMANENTLY invisible from this mod,
    -- because WAILA's own WailaTrailTracer.lua declares it as a bare
    -- top-level global (only exists inside WAILA's own mod sandbox),
    -- never published for cross-mod use. Same rule as every other WAILA
    -- API this file already reads via g_currentMission.waila -- WAILA's
    -- own loadMap() now also publishes g_currentMission.wailaTrailTracer,
    -- so read it from there instead of the bare name.
    local wailaTrailTracer = g_currentMission.wailaTrailTracer
    if wailaTrailTracer == nil then
        print("[TaskMap] startTrailScan: g_currentMission.wailaTrailTracer is nil (WAILA not loaded/too early?) - skipping")
        return
    end

    local centerX, centerZ = self:getScanCenter()
    if centerX == nil then
        print("[TaskMap] startTrailScan: getScanCenter() returned nil (player/rootNode not available) - skipping")
        return
    end

    -- newScanner, not WailaTrailScanner.new directly -- WailaTrailScanner
    -- itself is a bare global, invisible cross-mod for the identical
    -- reason the bare WailaTrailTracer global was (see above); newScanner
    -- is a thin factory on the already-published wailaTrailTracer table.
    self.trailScanner = wailaTrailTracer.newScanner(centerX, centerZ)
end

-- Advances the in-progress scan (if any) by TRAIL_SCAN_BUDGET_SEC. Once
-- it reports complete, swaps the result in for tickTrailDebugLines to
-- draw and clears self.trailScanner back to idle.
function TaskMap:advanceTrailScan()
    if self.trailScanner == nil then
        return
    end

    local isComplete = self.trailScanner:update(TaskMap.TRAIL_SCAN_BUDGET_SEC)
    if isComplete then
        -- Real hang found live (addDots, since removed as dead code):
        -- creating one actual MapHotspot GUI object per point had no
        -- cap, and a messy area trace could produce thousands of
        -- simplified points -- thousands of synchronous addMapHotspot
        -- calls froze the game with no error logged at all. Storing the
        -- raw result for cheap, transient drawDebugLine visualization
        -- instead (see tickTrailDebugLines) -- verify the tracer's
        -- actual output is sane before trusting it to a GUI system that
        -- can hang, not after.
        self.lastTrailScanResult = self.trailScanner.result
        self.trailScanner = nil
    end
end

-- Cheap, transient, per-frame debug visualization -- drawDebugLine
-- directly, same real, confirmed-working primitive WailaDeclaredArea's
-- own drawDebug already uses, not a GUI object of any kind. Redrawn
-- every frame on purpose: debug draw calls aren't persistent scene
-- objects, they only last the frame they're issued in. Connects each
-- path/area's own point sequence as a line strip instead of isolated
-- dots -- shows the actual traced shape, not just scattered points.
function TaskMap:tickTrailDebugLines()
    local result = self.lastTrailScanResult
    if result == nil then
        return
    end

    -- Real bug this fixes: getSimplifiedPoints() deliberately returns an
    -- OPEN ring (its own comment: "callers doing line-segment rendering
    -- want that, not a Polygon2D") -- but this function only ever
    -- connected consecutive pairs, never wrapping the last point back to
    -- the first. Every "closed" area shape drawn all session has
    -- actually had a small missing edge at the seam, confirmed live via
    -- a visibly open gap in a traced shape. closed=true draws that final
    -- wrap-around edge too -- only for actual closed shapes (areas), not
    -- for paths/ribbons, which are genuinely open lines, not polygons.
    local function drawLines(pointLists, r, g, b, closed)
        for _, points in ipairs(pointLists) do
            local segmentCount = closed and #points or (#points - 1)
            for i = 1, segmentCount do
                local j = (i % #points) + 1
                local ax, az = points[i][1], points[i][2]
                local bx, bz = points[j][1], points[j][2]
                local ay = getTerrainHeightAtWorldPos(g_terrainNode, ax, 0, az) + 0.3
                local by = getTerrainHeightAtWorldPos(g_terrainNode, bx, 0, bz) + 0.3
                drawDebugLine(ax, ay, az, r, g, b, bx, by, bz, r, g, b, false)
            end
        end
    end

    -- Real request: a path is a centerline plus a real width, not just a
    -- bare line -- draw the actual two-edge ribbon (result.pathEdges,
    -- WailaTrailTracer.offsetChain's own output) instead of the raw
    -- centerline (result.paths), so what's on screen matches what the
    -- area wall-follower now actually treats as a path's real footprint.
    -- `or {}` on the newer fields -- a hot-reload can leave an OLDER
    -- result table (built before this deploy) sitting in
    -- self.lastTrailScanResult until the next scan completes, and that
    -- older shape won't have these keys -- ipairs(nil) would hard-error
    -- every frame until then instead of just drawing nothing for a tick.
    for _, edges in ipairs(result.pathEdges or {}) do
        drawLines({ edges.left }, TaskMap.TRAIL_PATH_COLOR[1], TaskMap.TRAIL_PATH_COLOR[2], TaskMap.TRAIL_PATH_COLOR[3])
        drawLines({ edges.right }, TaskMap.TRAIL_PATH_COLOR[1], TaskMap.TRAIL_PATH_COLOR[2], TaskMap.TRAIL_PATH_COLOR[3])
    end
    -- closed=true only for areas/rejectedIslands -- both genuinely
    -- closedNaturally=true (an island rejection still closed, just
    -- around the wrong thing). rejectedIncomplete (structure hit /
    -- stall / position cap) never closed at all -- drawing a wrap-around
    -- edge for those would falsely make an open, unfinished fragment
    -- look like a real closed shape, exactly backwards from what that
    -- color is supposed to communicate.
    drawLines(result.areas or {}, TaskMap.TRAIL_AREA_COLOR[1], TaskMap.TRAIL_AREA_COLOR[2], TaskMap.TRAIL_AREA_COLOR[3], true)
    drawLines(result.rejectedIslands or {}, TaskMap.TRAIL_AREA_ISLAND_COLOR[1], TaskMap.TRAIL_AREA_ISLAND_COLOR[2], TaskMap.TRAIL_AREA_ISLAND_COLOR[3], true)
    drawLines(result.rejectedIncomplete or {}, TaskMap.TRAIL_AREA_INCOMPLETE_COLOR[1], TaskMap.TRAIL_AREA_INCOMPLETE_COLOR[2], TaskMap.TRAIL_AREA_INCOMPLETE_COLOR[3])
end

-- Advances any in-progress scan first, every tick, regardless of the
-- interval timer below -- that's the whole point of the incremental
-- redesign (see TRAIL_SCAN_BUDGET_SEC's own comment). Only considers
-- starting a NEW scan once the current one (if any) has actually
-- finished -- TRAIL_SCAN_INTERVAL governs how often a fresh scan starts,
-- not how long one takes, and a scan can legitimately span many ticks
-- depending on how much real work a busy area needs.
function TaskMap:tickTrailScan(dt)
    self:advanceTrailScan()

    if self.trailScanner ~= nil then
        return
    end

    -- See MANUAL_RESCAN_ONLY's own comment -- while true, only
    -- onRescanTrailNow (the keybind) starts a new scan; the timer still
    -- accumulates for free so flipping the flag back off later doesn't
    -- need any other change here.
    if TaskMap.MANUAL_RESCAN_ONLY then
        return
    end

    self.trailScanTimer = self.trailScanTimer + dt
    if self.trailScanTimer >= TaskMap.TRAIL_SCAN_INTERVAL then
        self.trailScanTimer = 0
        self:startTrailScan()
    end
end

-- Real request: the full window scan fires many independent seeds at
-- once with no way to tell which rendered line came from which one --
-- genuinely impossible to build a "does the algorithm do what I expect
-- FROM THIS SPECIFIC SPOT" debug loop out of that, just an unreadable
-- pile of lines ("graffiti"). This button now runs WailaTrailTracer's
-- own debugTraceAt -- the SAME real classification/tracing code, but
-- exactly once, seeded at exactly the player's current position, with no
-- other seeds and no window/path state to confuse the result. Logs a
-- clear, specific summary of what happened so the console output alone
-- (not just the drawn line) answers "what did the algorithm actually do
-- here."
function TaskMap:onRescanTrailNow(actionName, inputValue, callbackState, isAnalog)
    local wailaTrailTracer = g_currentMission.wailaTrailTracer
    if wailaTrailTracer == nil then
        print("[TaskMap] debug trace: g_currentMission.wailaTrailTracer is nil (WAILA not loaded/too early?)")
        return
    end

    local x, z = self:getScanCenter()
    if x == nil then
        print("[TaskMap] debug trace: getScanCenter() returned nil (player/rootNode not available)")
        return
    end

    local result = wailaTrailTracer.debugTraceAt(x, z)
    self.lastDebugTrace = result

    -- Real, explicit removal: WAILA's own debugTraceAt used to return a
    -- list of region "shapes" -- gone, along with the whole region-
    -- grouping concept. Real follow-up fix ("delete the lines between
    -- any squares that meet"): per-CELL edge/interior classification is
    -- gone too -- WailaTrailTracer now classifies per EDGE, emitting
    -- only the sides of a filled cell that border an unfilled neighbor.
    -- result.segments is that flat list of 2-point border segments.
    print(string.format("[TaskMap] debug trace at (%.1f, %.1f): %d cell(s), %d border segment(s), %d polygon(s), touchesTileEdge=%s%s",
        x, z, result.cellCount, #result.segments, #(result.polygons or {}), tostring(result.touchesTileEdge),
        result.truncated and string.format(" (TRUNCATED -- over the %d segment cap, WailaTrailTracer.DEBUG_MAX_CELL_BOXES)", wailaTrailTracer.DEBUG_MAX_CELL_BOXES) or ""))

    -- Real request ("absolutely" -- switch to one DensityMapModifier
    -- polygon fill per region instead of one write per cell, confirmed
    -- real against FieldManager.lua's own clearPolygonPoints/
    -- addPolygonPointWorldCoords usage). See
    -- WailaTrailTracer.testDensityMapWrite's own header.
    if result.densityWriteMs ~= nil then
        print(string.format("[TaskMap]   density map write test: %d polygon(s) written in %.2fms",
            result.densityWritePolygonCount, result.densityWriteMs))
    end
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

-- Renders self.lastDebugTrace (onRescanTrailNow's own result). No region
-- grouping -- just the tile-boundary marker, the raw border segments
-- (WailaTrailTracer's collectBorderSegments), and the smoothed closed
-- polygons (chainBorderLoops + smoothClosedLoop) drawn on top of them.
TaskMap.DEBUG_TRACE_RADIUS_COLOR = { 0.2, 1, 0.2 }
TaskMap.DEBUG_TRACE_EDGE_COLOR = { 1, 1, 0 }
-- "Step 2": result.polygons, the real deliverable -- an actually-closed
-- polygon per connected region, drawn ON TOP of the border segments
-- rather than replacing them -- real request ("leave these in place
-- until we have that sorted") so the two can be compared directly. Same
-- pink used in the reference screenshot for this exact idea.
TaskMap.DEBUG_TRACE_POLYGON_COLOR = { 1, 0.4, 0.7 }

function TaskMap:tickDebugTraceLine()
    local result = self.lastDebugTrace
    if result == nil then
        return
    end

    local function drawSegment(points, color, closed)
        local segmentCount = closed and #points or (#points - 1)
        for i = 1, segmentCount do
            local j = (i % #points) + 1
            local ax, az = points[i][1], points[i][2]
            local bx, bz = points[j][1], points[j][2]
            local ay = getTerrainHeightAtWorldPos(g_terrainNode, ax, 0, az) + 0.3
            local by = getTerrainHeightAtWorldPos(g_terrainNode, bx, 0, bz) + 0.3
            drawDebugLine(ax, ay, az, color[1], color[2], color[3], bx, by, bz, color[1], color[2], color[3], false)
        end
    end

    -- Real bug this fixes: the debug tool's own grid rasterization
    -- (WailaTrailTracer.rasterizeRegion) has always bounded itself with
    -- a SQUARE (centerX/Z +/- radius on each axis), never a circle --
    -- the old drawn circle never matched what the algorithm was really
    -- bounded by (a radius-60 square's own corners reach ~85m out, well
    -- past a 60-radius circle). result.debugBounds is the honest square,
    -- a closed 5-point ring (first point repeated at the end) -- drawn
    -- open (no extra wrap segment needed, it's already closed).
    if result.debugBounds ~= nil then
        drawSegment(result.debugBounds, TaskMap.DEBUG_TRACE_RADIUS_COLOR)
    end

    -- Each segment is just its own 2-point {a, b} -- drawSegment on a
    -- 2-point list with closed=false (the default) draws exactly that
    -- one line, no extra helper needed.
    for _, segment in ipairs(result.segments or {}) do
        drawSegment(segment, TaskMap.DEBUG_TRACE_EDGE_COLOR)
    end

    -- "Step 2" -- each polygon IS a real closed ring (chainBorderLoops
    -- only ever returns closed loops), so closed=true here.
    for _, polygon in ipairs(result.polygons or {}) do
        drawSegment(polygon, TaskMap.DEBUG_TRACE_POLYGON_COLOR, true)
    end
end

-- Real, confirmed pattern -- mirrors FS25WhatAmILookingAt's own
-- registerActionEvents/PlayerInputComponent hook exactly (see that mod's
-- own comment on why category="ONFOOT" isn't used and this global hook is
-- the real, working alternative).
function TaskMap:registerActionEvents()
    local _, rescanId = g_inputBinding:registerActionEvent(
        InputAction.TASKMAP_TRAIL_SCAN_NOW,
        self,
        self.onRescanTrailNow,
        false, true, false, true, nil, true
    )
    if rescanId ~= nil then
        g_inputBinding:setActionEventTextPriority(rescanId, GS_PRIO_LOW)
        g_inputBinding:setActionEventTextVisibility(rescanId, true)
    end

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
        -- g_taskMap, NOT the bare TaskMap class table -- g_taskMap (see
        -- its own `= TaskMap.new()` below) is the actual instance holding
        -- trailScanner/trailScanTimer; registering the bare class table
        -- as the action-event target would read/write those fields on
        -- the wrong table entirely.
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
    self:tickTrailScan(dt)
    self:tickTrailDebugLines()
    self:tickDebugTraceLine()
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

-- Real request ("would be nice to have a progress bar somewhere") --
-- plain on-screen text, not tied to IngameMap/drawFields at all (this
-- doesn't need to be positioned relative to the map, just visible).
-- Reads WailaTrailTracer.wholeMapScanState directly -- a plain field,
-- same cross-mod-safe access every other wailaTrailTracer.* read in
-- this file already uses. Only drawn while a scan is actually running.
function TaskMap:draw()
    local wailaTrailTracer = g_currentMission.wailaTrailTracer
    if wailaTrailTracer == nil then
        return
    end

    local state = wailaTrailTracer.wholeMapScanState
    if state ~= nil then
        local total = state.chunksPerSide * state.chunksPerSide
        local done = state.row * state.chunksPerSide + state.col
        local percent = total > 0 and (done / total * 100) or 0

        -- Real bug this fixes, confirmed live: (0.02, 0.9) sat right on
        -- top of the game's own keybind hint list (top-left), unreadable.
        -- Moved to the top-right corner, right-aligned, away from both
        -- that list and the minimap (bottom corners).
        setTextColor(1, 1, 1, 1)
        setTextAlignment(RenderText.ALIGN_RIGHT)
        renderText(0.98, 0.88, 0.02, string.format("WAILA whole-map scan: %d / %d chunks (%.0f%%)", done, total, percent))
    end

    self:drawTrailPersistenceProgress()
end

-- Real request ("~2m10s human loses patience... suppose we'd need
-- another progress bar"): a restore this size (confirmed live, 133s for
-- 42,631 polygons) has no visible sign of life otherwise -- the only
-- existing feedback was tickLoadFromXML's own log-only progress line,
-- invisible unless you're watching log.txt. Same bar shape/position
-- convention as the scan progress bar above, just one line lower so
-- both could show at once without overlapping (unlikely in practice,
-- but harmless to allow). Save gets the same treatment for the same
-- reason, even though nobody's complained about it specifically yet --
-- it's the same class of "long tick-budgeted operation with zero visual
-- feedback" problem, just currently faster (was 24-29s for these
-- polygon counts) so less likely to be noticed.
function TaskMap:drawTrailPersistenceProgress()
    local wailaTrailTracer = g_currentMission.wailaTrailTracer
    if wailaTrailTracer == nil then
        return
    end

    setTextColor(1, 1, 1, 1)
    setTextAlignment(RenderText.ALIGN_RIGHT)

    local loadState = wailaTrailTracer.loadState
    if loadState ~= nil then
        local total = #loadState.workItems
        local percent = total > 0 and (loadState.index / total * 100) or 0
        renderText(0.98, 0.85, 0.02, string.format("WAILA trail restore: %d / %d polygons (%.0f%%)", loadState.index, total, percent))
    end

    local saveState = wailaTrailTracer.saveState
    if saveState ~= nil then
        local total = #saveState.workItems
        local percent = total > 0 and (saveState.index / total * 100) or 0
        renderText(0.98, 0.82, 0.02, string.format("WAILA trail save: %d / %d polygons (%.0f%%)", saveState.index, total, percent))
    end
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
local OVERLAY_LOG_HEARTBEAT_SEC = 2.0
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

-- Shared render path for any density-map-visualization overlay drawn
-- onto IngameMap -- factored out once a SECOND overlay (the real-road-
-- spline proof, see WailaTrailTracer.buildRoadSplineOverlay) needed the
-- exact same position/clip math as the trail overlay already had, so the
-- two copies wouldn't drift apart from each other over time. logKey
-- keeps each overlay's diagnostic dedup state independent (loggedOverlayStates
-- is shared storage, keyed per overlay, not per literal state string).
local function renderMapOverlay(self, overlay, logKey, logLabel)
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
        string.format("rendering_%.3f_%.3f_%.3f_%.3f_%.3f_%.3f_%s", width, height, posX, posY, sizeX, sizeY, tostring(self.clipX1)),
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
    setOverlayColor(overlay, 1, 1, 1, 1)
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
    renderMapOverlay(self, wailaTrailTracer.testOverlay, "trail", "drawWailaTrailOverlay")
end

-- Real request ("prove to me you can write splines to the minimap"):
-- separate draw hook for the real-road-spline overlay
-- (WailaTrailTracer.buildRoadSplineOverlay) -- deliberately its OWN
-- independent hook, not folded into drawWailaTrailOverlay, so it can
-- succeed or fail independently and stay cleanly separable for the
-- planned "dedup discovered trails vs declared roads" step.
local function drawWailaRoadOverlay(self)
    local wailaTrailTracer = g_currentMission.wailaTrailTracer
    if wailaTrailTracer == nil then
        logOverlayStateOnce("road", "noTracer", "[TaskMap] drawWailaRoadOverlay: g_currentMission.wailaTrailTracer is nil")
        return
    end
    if wailaTrailTracer.roadOverlay == nil then
        logOverlayStateOnce("road", "noOverlay", "[TaskMap] drawWailaRoadOverlay: wailaTrailTracer.roadOverlay is nil (run 'Build road overlay' from the debug hub first)")
        return
    end
    if not getIsDensityMapVisualizationOverlayReady(wailaTrailTracer.roadOverlay) then
        logOverlayStateOnce("road", "notReady", "[TaskMap] drawWailaRoadOverlay: overlay exists but getIsDensityMapVisualizationOverlayReady returned false")
        return
    end
    renderMapOverlay(self, wailaTrailTracer.roadOverlay, "road", "drawWailaRoadOverlay")
end

-- Real request ("go ahead, make sure both are drawn in distinct
-- colors"): third independent overlay for WailaTrailTracer.buildFeatureOverlay
-- (tree/water, via real CollisionFlag.TREE/WATER raycasts) -- same
-- independent-hook reasoning as drawWailaRoadOverlay above.
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

-- Real request ("just a simple diagonal line... prove we're not chasing
-- a complexity problem in the minimap"): fourth, deliberately trivial
-- overlay for WailaTrailTracer.buildDiagonalTestOverlay -- same
-- independent-hook pattern as the other three, but the SIMPLEST possible
-- data (one polygon, no scanning/sampling of any kind) -- isolates
-- "does our render pipeline reach the minimap at all" from "is something
-- wrong with our data."
local function drawWailaDiagonalTestOverlay(self)
    local wailaTrailTracer = g_currentMission.wailaTrailTracer
    if wailaTrailTracer == nil then
        logOverlayStateOnce("diagonal", "noTracer", "[TaskMap] drawWailaDiagonalTestOverlay: g_currentMission.wailaTrailTracer is nil")
        return
    end
    if wailaTrailTracer.diagonalOverlay == nil then
        logOverlayStateOnce("diagonal", "noOverlay", "[TaskMap] drawWailaDiagonalTestOverlay: wailaTrailTracer.diagonalOverlay is nil (run 'Build diagonal test overlay' from the debug hub first)")
        return
    end
    if not getIsDensityMapVisualizationOverlayReady(wailaTrailTracer.diagonalOverlay) then
        logOverlayStateOnce("diagonal", "notReady", "[TaskMap] drawWailaDiagonalTestOverlay: overlay exists but getIsDensityMapVisualizationOverlayReady returned false")
        return
    end
    renderMapOverlay(self, wailaTrailTracer.diagonalOverlay, "diagonal", "drawWailaDiagonalTestOverlay")
end

-- Real request ("classify space first... go ahead with the forests"):
-- fifth overlay, for WailaTrailTracer.buildForestOverlay -- the material-
-- diversity classifier prototype, same independent-hook pattern as the
-- other four.
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
    renderMapOverlay(self, wailaTrailTracer.forestOverlay, "forest", "drawWailaForestOverlay")
end

-- Real request ("draw the forest patches underneath, so roads going
-- through forest patches are visible"): draw order here IS layering
-- order (painter's algorithm -- each appended function draws on top of
-- everything before it). Forest goes first (bottom layer) specifically
-- so real roads -- drawn after -- stay visible cutting through a forest
-- patch instead of being covered by it.
IngameMap.drawFields = Utils.appendedFunction(IngameMap.drawFields, drawWailaForestOverlay)
IngameMap.drawFields = Utils.appendedFunction(IngameMap.drawFields, drawWailaTrailOverlay)
IngameMap.drawFields = Utils.appendedFunction(IngameMap.drawFields, drawWailaRoadOverlay)
IngameMap.drawFields = Utils.appendedFunction(IngameMap.drawFields, drawWailaFeatureOverlay)
IngameMap.drawFields = Utils.appendedFunction(IngameMap.drawFields, drawWailaDiagonalTestOverlay)

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
        drawWailaForestOverlay(self)
        drawWailaTrailOverlay(self)
        drawWailaRoadOverlay(self)
        drawWailaFeatureOverlay(self)
        drawWailaDiagonalTestOverlay(self)
    end)
    hasPatchedInstanceOnce = true
    lastKnownInstanceDrawFields = rawget(ingameMap, "drawFields")
    print("[TaskMap] (re-)patched ingameMap's instance-level drawFields -- keeps our overlays last in the chain regardless of what other mods (e.g. minimapPlus) do to it")
end

g_taskMap = TaskMap.new()
addModEventListener(g_taskMap)
