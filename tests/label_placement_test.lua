-- plain Lua: the "i" of a field goes inside it, away from the farmland number tags
local passed, failed = 0, 0
local realPrint = print
local function check(name, ok) if ok then passed = passed + 1 else failed = failed + 1; realPrint("  FAIL " .. name) end end
dofile("scripts/LabelPlacement.lua")

local square = { { 0, 0 }, { 200, 0 }, { 200, 200 }, { 0, 200 } }
local function inside(poly, x, z) -- (ray casting, as the module's own)
    local r = false; local j = #poly
    for i = 1, #poly do
        local xi, zi, xj, zj = poly[i][1], poly[i][2], poly[j][1], poly[j][2]
        if (zi > z) ~= (zj > z) and x < (xj - xi) * (z - zi) / (zj - zi) + xi then r = not r end
        j = i
    end
    return r
end
local function dist(ax, az, bx, bz) return math.sqrt((ax - bx) ^ 2 + (az - bz) ^ 2) end

-- a tag in the middle of the field (where the label used to be: the "i" sat on it)
local x, z = LabelPlacement.pick(square, { { 100, 100 } }, 100, 100, 100, 100)
check("a tag in the middle: the i leaves it by at least 60 m and stays inside the field", inside(square, x, z) and dist(x, z, 100, 100) >= 60)

-- no tags: the old spot stays (nothing pushes it away)
x, z = LabelPlacement.pick(square, {}, 100, 100, 100, 100)
check("no tags near: it stays where it was (the middle is the farthest from the edge)", dist(x, z, 100, 100) < 25)

-- two tags: the i keeps clear of both
x, z = LabelPlacement.pick(square, { { 50, 50 }, { 150, 150 } }, 100, 100, 100, 100)
check("two tags: the i keeps at least 50 m from both", dist(x, z, 50, 50) >= 50 and dist(x, z, 150, 150) >= 50 and inside(square, x, z))

-- it keeps off the field's own edge too (a corner is far from a middle tag but on the edge)
x, z = LabelPlacement.pick(square, { { 100, 100 } }, 100, 100, 100, 100)
check("... and not on the edge itself (at least 15 m inside)", math.min(x, z, 200 - x, 200 - z) >= 15)

-- an L-shaped field: the notch is not a candidate
local ell = { { 0, 0 }, { 200, 0 }, { 200, 80 }, { 80, 80 }, { 80, 200 }, { 0, 200 } }
x, z = LabelPlacement.pick(ell, { { 40, 40 } }, 40, 40, 40, 40)
check("an L-shaped field: the point is inside the L (never in the notch), clear of the tag", inside(ell, x, z) and dist(x, z, 40, 40) >= 60)

-- no outline (a field WAILA has not traced yet): the old spot
x, z = LabelPlacement.pick(nil, { { 1, 1 } }, 7, 8, 7, 8)
check("no polygon: the old position, untouched", x == 7 and z == 8)
x, z = LabelPlacement.pick({ { 0, 0 }, { 1, 1 } }, {}, 7, 8, nil, nil)
check("fewer than three points: the old position", x == 7 and z == 8)

-- deterministic
local x2, z2 = LabelPlacement.pick(square, { { 100, 100 } }, 100, 100, 100, 100)
x, z = LabelPlacement.pick(square, { { 100, 100 } }, 100, 100, 100, 100)
check("the same input gives the same spot", x == x2 and z == z2)

print(string.format("label_placement_test: %d/%d passed", passed, passed + failed))
os.exit(failed == 0 and 0 or 1)
