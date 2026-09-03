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
-- Bold, maximally-distinct debug colors, not a polished final palette -
-- this is drawDebugLine output meant to answer "is the sweep classifying
-- path vs area correctly," not something meant to look good on a real
-- map. Muted tan/gray (the original choice) both read as the same
-- off-white blur at a distance - yellow/magenta don't occur naturally in
-- terrain, so neither can be mistaken for the other or for scenery.
TaskMap.TRAIL_PATH_COLOR = { 1, 1, 0 }
TaskMap.TRAIL_AREA_COLOR = { 1, 0, 1 }

-- Real hang found live: addDots creates one actual MapHotspot GUI object
-- per point, no cap anywhere. WailaTrailTracer's own Douglas-Peucker
-- simplification has no hard output-size limit either -- a messy,
-- non-converging area trace (real, logged case: "unable to close
-- boundary loop, giving up at 15001 positions") isn't guaranteed to
-- simplify down to anything small, since a wildly irregular boundary can
-- have plenty of large, "significant" deviations the simplifier judges
-- worth keeping. Result: thousands of synchronous addMapHotspot calls in
-- one frame, game frozen with no error logged at all (silence after the
-- scan-summary print line was the only symptom). This cap is the actual
-- safety net, independent of whatever produces an oversized point list.
TaskMap.MAX_TRAIL_DOTS = 500

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
    self.activeTrailHotspots = {}
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

-- Clears every currently-shown trail dot and redraws from a fresh
-- WailaTrailTracer.scanRegion result - same wipe-and-rebuild shape
-- rebuildAllHotspots already uses for job labels. One dot per already-
-- simplified path/area point (see WailaTrailTracer's own comment on why
-- dots, not connected rotated segments, for this first version).
-- TEMPORARY diagnostics throughout this function - "did we detect
-- anything at all" debug pass, matching WailaTrailTracer.scanRegion's
-- own new logging. Every early-return below now logs WHY, so a silent
-- "no dots ever appeared" report can actually be traced to a specific
-- cause instead of guessed at.
function TaskMap:rebuildTrailHotspots()
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
        print("[TaskMap] rebuildTrailHotspots: g_currentMission.wailaTrailTracer is nil (WAILA not loaded/too early?) - skipping")
        return
    end

    local ingameMap = g_currentMission.hud ~= nil and g_currentMission.hud.ingameMap
    if ingameMap == nil then
        print("[TaskMap] rebuildTrailHotspots: g_currentMission.hud.ingameMap not available yet - skipping")
        return
    end

    local centerX, centerZ = self:getScanCenter()
    if centerX == nil then
        print("[TaskMap] rebuildTrailHotspots: getScanCenter() returned nil (player/rootNode not available) - skipping")
        return
    end

    for _, hotspot in ipairs(self.activeTrailHotspots) do
        ingameMap:removeMapHotspot(hotspot)
    end
    self.activeTrailHotspots = {}

    local result = wailaTrailTracer.scanRegion(centerX, centerZ)
    print(string.format("[TaskMap] rebuildTrailHotspots: scan center=(%.1f,%.1f) -> %d path(s), %d area(s)",
        centerX, centerZ, #result.paths, #result.areas))

    -- Real hang found live: addDots (below, disabled for now) creates one
    -- actual MapHotspot GUI object per point with zero cap -- a messy,
    -- non-converging area trace can produce thousands of simplified
    -- points (Douglas-Peucker has no hard output-size limit), and
    -- thousands of synchronous addMapHotspot calls froze the game with
    -- no error logged at all. Storing the raw result for cheap, transient
    -- drawDebugLine visualization instead (see tickTrailDebugLines) --
    -- verify the tracer's actual output is sane BEFORE trusting it to a
    -- GUI system that can hang, not after.
    self.lastTrailScanResult = result

    -- local function addDots(pointLists, color)
    --     for _, points in ipairs(pointLists) do
    --         for _, point in ipairs(points) do
    --             if TaskMap.MAX_TRAIL_DOTS <= #self.activeTrailHotspots then
    --                 return
    --             end
    --             local hotspot = TrailPointHotspot.new()
    --             hotspot:setColor3(color[1], color[2], color[3])
    --             hotspot:setWorldPosition(point[1], point[2])
    --             ingameMap:addMapHotspot(hotspot)
    --             table.insert(self.activeTrailHotspots, hotspot)
    --         end
    --     end
    -- end
    --
    -- addDots(result.paths, TaskMap.TRAIL_PATH_COLOR)
    -- addDots(result.areas, TaskMap.TRAIL_AREA_COLOR)
    --
    -- print(string.format("[TaskMap] rebuildTrailHotspots: created %d trail dot hotspot(s) total", #self.activeTrailHotspots))
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

    local function drawLines(pointLists, r, g, b)
        for _, points in ipairs(pointLists) do
            for i = 1, #points - 1 do
                local ax, az = points[i][1], points[i][2]
                local bx, bz = points[i + 1][1], points[i + 1][2]
                local ay = getTerrainHeightAtWorldPos(g_terrainNode, ax, 0, az) + 0.3
                local by = getTerrainHeightAtWorldPos(g_terrainNode, bx, 0, bz) + 0.3
                drawDebugLine(ax, ay, az, r, g, b, bx, by, bz, r, g, b, false)
            end
        end
    end

    drawLines(result.paths, TaskMap.TRAIL_PATH_COLOR[1], TaskMap.TRAIL_PATH_COLOR[2], TaskMap.TRAIL_PATH_COLOR[3])
    drawLines(result.areas, TaskMap.TRAIL_AREA_COLOR[1], TaskMap.TRAIL_AREA_COLOR[2], TaskMap.TRAIL_AREA_COLOR[3])
end

function TaskMap:tickTrailScan(dt)
    self.trailScanTimer = self.trailScanTimer + dt
    if self.trailScanTimer >= TaskMap.TRAIL_SCAN_INTERVAL then
        self.trailScanTimer = 0
        self:rebuildTrailHotspots()
    end
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
    self:tickTrailScan(dt)
    self:tickTrailDebugLines()
end

g_taskMap = TaskMap.new()
addModEventListener(g_taskMap)
