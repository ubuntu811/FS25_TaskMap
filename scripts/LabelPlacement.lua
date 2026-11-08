--[[
    LabelPlacement.lua -- where a field's "i" (and the job letters beside it) goes on the map: a point INSIDE the field's polygon, away from the game's farmland number tags (which sit at the farmland's own spot:
    the "i" used to land on top of them), away from the field's own edge, and, when that is a tie, near where the label always was. Pure: no engine calls; the tags and the polygon are passed in.
]]
LabelPlacement = {}

LabelPlacement.GRID = 9                  -- candidates: a 9 x 9 grid over the polygon's bounding box (those inside it), plus the old label and the WAILA sample point
LabelPlacement.TAG_CLEAR_M = 80          -- further than this from a tag is as good as any distance
LabelPlacement.EDGE_CLEAR_M = 30         -- the same for the distance to the field's edge
LabelPlacement.EDGE_WEIGHT = 0.5
LabelPlacement.HOME_WEIGHT = 0.01        -- (a pull towards the old position, small: only breaks ties)

local function inside(points, x, z)
    local result = false
    local n = #points
    local j = n
    for i = 1, n do
        local xi, zi, xj, zj = points[i][1], points[i][2], points[j][1], points[j][2]
        if (zi > z) ~= (zj > z) and x < (xj - xi) * (z - zi) / (zj - zi) + xi then
            result = not result
        end
        j = i
    end
    return result
end

local function distanceToSegment(px, pz, ax, az, bx, bz)
    local dx, dz = bx - ax, bz - az
    local lengthSq = dx * dx + dz * dz
    local t = lengthSq > 1e-9 and math.max(0, math.min(1, ((px - ax) * dx + (pz - az) * dz) / lengthSq)) or 0
    local cx, cz = ax + dx * t, az + dz * t
    return math.sqrt((px - cx) ^ 2 + (pz - cz) ^ 2)
end

local function edgeDistance(points, x, z)
    local best = math.huge
    local n = #points
    local j = n
    for i = 1, n do
        best = math.min(best, distanceToSegment(x, z, points[j][1], points[j][2], points[i][1], points[i][2]))
        j = i
    end
    return best
end

local function polygonArea(points)
    local sum, n = 0, #points
    local j = n
    for i = 1, n do
        sum = sum + (points[j][1] + points[i][1]) * (points[j][2] - points[i][2])
        j = i
    end
    return math.abs(sum) / 2
end

-- Which field entries get no "i" of their own: an entry whose sample point lies inside the outline of a BIGGER entry (of equal ones the lower id stays) is a piece of that field (ground plowed bit by bit
-- is first registered as fields of its own, until WAILA's next trace merges them), so the map shows one "i" for the field. Entries without an outline can be hidden but never hide another.
-- entries: list of { wailaFieldId, sampleX, sampleZ, labelX, labelZ, boundaryPositions }. Returns a set (entry -> true).
function LabelPlacement.coveredEntries(entries)
    local areas, hidden = {}, {}
    for _, entry in ipairs(entries) do
        local poly = entry.boundaryPositions
        if poly ~= nil and #poly >= 3 then
            areas[entry] = polygonArea(poly)
        end
    end
    for _, a in ipairs(entries) do
        local x, z = a.sampleX or a.labelX, a.sampleZ or a.labelZ
        if x ~= nil and z ~= nil then
            for _, b in ipairs(entries) do
                if b ~= a and areas[b] ~= nil then
                    local bigger = areas[a] == nil or areas[a] < areas[b] or (areas[a] == areas[b] and (a.wailaFieldId or 0) > (b.wailaFieldId or 0))
                    if bigger and inside(b.boundaryPositions, x, z) then
                        hidden[a] = true
                        break
                    end
                end
            end
        end
    end
    return hidden
end

-- polygon: list of { x, z } (nil or under 3 points: no polygon); tags: list of { x, z }; homeX, homeZ: the old label position; sampleX, sampleZ: a point WAILA found inside the field (may be nil).
-- Returns x, z.
function LabelPlacement.pick(polygon, tags, homeX, homeZ, sampleX, sampleZ)
    if polygon == nil or #polygon < 3 then
        return homeX, homeZ
    end
    local minX, maxX, minZ, maxZ = math.huge, -math.huge, math.huge, -math.huge
    for _, p in ipairs(polygon) do
        minX, maxX = math.min(minX, p[1]), math.max(maxX, p[1])
        minZ, maxZ = math.min(minZ, p[2]), math.max(maxZ, p[2])
    end
    local candidates = {}
    local steps = LabelPlacement.GRID
    for i = 1, steps do
        for k = 1, steps do
            local x = minX + (maxX - minX) * (i - 0.5) / steps
            local z = minZ + (maxZ - minZ) * (k - 0.5) / steps
            if inside(polygon, x, z) then
                candidates[#candidates + 1] = { x, z }
            end
        end
    end
    if homeX ~= nil and inside(polygon, homeX, homeZ) then
        candidates[#candidates + 1] = { homeX, homeZ }
    end
    if sampleX ~= nil then
        candidates[#candidates + 1] = { sampleX, sampleZ }
    end
    if #candidates == 0 then
        return homeX, homeZ
    end
    local bestScore, bestX, bestZ = -math.huge, homeX, homeZ
    for _, c in ipairs(candidates) do
        local tagDistance = LabelPlacement.TAG_CLEAR_M
        for _, tag in ipairs(tags or {}) do
            tagDistance = math.min(tagDistance, math.sqrt((c[1] - tag[1]) ^ 2 + (c[2] - tag[2]) ^ 2))
        end
        local score = tagDistance
            + math.min(edgeDistance(polygon, c[1], c[2]), LabelPlacement.EDGE_CLEAR_M) * LabelPlacement.EDGE_WEIGHT
        if homeX ~= nil then
            score = score - math.sqrt((c[1] - homeX) ^ 2 + (c[2] - homeZ) ^ 2) * LabelPlacement.HOME_WEIGHT
        end
        if score > bestScore then
            bestScore, bestX, bestZ = score, c[1], c[2]
        end
    end
    return bestX, bestZ
end
