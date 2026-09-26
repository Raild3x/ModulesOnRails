--!strict
-- Scene module for the screenshot loop: seeded segment soups before and after iterated snap
-- rounding (NavMesh Quantize, spec SR2). Coordinates are grid units (1 = 1/256 stud), and the
-- hot pixels are drawn as the unit squares they are.
--   lune run tools/navmesh/render.luau tools/navmesh/scenes/snap <out-dir>

local CDT = require("../../../lib/constraineddelaunay/src/ConstrainedDelaunay")
local Quantize = require("../../../lib/navmesh/src/Quantize")

type DrawList = CDT.DrawList

-- The same LCG as the Quantize spec (high bits).
local function makeRng(seed: number): (number, number) -> number
	local state = seed
	return function(lo: number, hi: number): number
		state = (state * 1103515245 + 12345) % 2147483648
		return lo + math.floor(state / 2147483648 * (hi - lo + 1))
	end
end

local RAW, CROSSING, HOT, SNAPPED, VERTEX = "#9e9e9e", "#e53935", "#ffb300", "#1e88e5", "#212121"

local function line(list: DrawList, ax: number, ay: number, bx: number, by: number, color: string, layer: string)
	table.insert(list, { Kind = "Line", Points = { ax, 0, ay, bx, 0, by }, Color = color, Layer = layer })
end

local function square(list: DrawList, cx: number, cy: number)
	local x0, x1, y0, y1 = cx - 0.5, cx + 0.5, cy - 0.5, cy + 0.5
	table.insert(list, { Kind = "Tri", Points = { x0, 0, y0, x1, 0, y0, x1, 0, y1 }, Color = HOT, Layer = "HotPixels" })
	table.insert(list, { Kind = "Tri", Points = { x0, 0, y0, x1, 0, y1, x0, 0, y1 }, Color = HOT, Layer = "HotPixels" })
end

local function soup(seed: number, count: number, span: number, shallow: boolean): ({ number }, { number })
	local rng = makeRng(seed)
	local coords, edges = {}, {}
	for s = 1, count do
		local ax, ay, bx, by = rng(0, span), rng(0, span), rng(0, span), rng(0, span)
		if shallow and s % 2 == 0 then
			ax, bx = 0, span
			by = ay + rng(-2, 2)
		end
		table.insert(coords, ax)
		table.insert(coords, ay)
		table.insert(coords, bx)
		table.insert(coords, by)
		table.insert(edges, 2 * s - 1)
		table.insert(edges, 2 * s)
	end
	return coords, edges
end

-- Before: the raw segments, with their proper crossings marked (each would force a Steiner
-- vertex in the CDT).
local function before(coords: { number }, edges: { number }): DrawList
	local list: DrawList = {}
	for i = 1, #edges // 2 do
		local a, b = edges[2 * i - 1], edges[2 * i]
		line(list, coords[2 * a - 1], coords[2 * a], coords[2 * b - 1], coords[2 * b], RAW, "Input")
	end
	for i = 1, #edges // 2 do
		local a, b = edges[2 * i - 1], edges[2 * i]
		local ax, ay, bx, by = coords[2 * a - 1], coords[2 * a], coords[2 * b - 1], coords[2 * b]
		for j = i + 1, #edges // 2 do
			local c, d = edges[2 * j - 1], edges[2 * j]
			local cx, cy, dx, dy = coords[2 * c - 1], coords[2 * c], coords[2 * d - 1], coords[2 * d]
			if
				CDT.Orient2D(ax, ay, bx, by, cx, cy) * CDT.Orient2D(ax, ay, bx, by, dx, dy) < 0
				and CDT.Orient2D(cx, cy, dx, dy, ax, ay) * CDT.Orient2D(cx, cy, dx, dy, bx, by) < 0
			then
				local t = ((cx - ax) * (dy - cy) - (cy - ay) * (dx - cx))
					/ ((bx - ax) * (dy - cy) - (by - ay) * (dx - cx))
				local x, y = ax + t * (bx - ax), ay + t * (by - ay)
				table.insert(list, { Kind = "Point", Points = { x, 0, y }, Color = CROSSING, Layer = "Crossings" })
			end
		end
	end
	return list
end

-- After: hot pixels, the raw segments faintly, then the snapped fragments and their vertices.
local function after(coords: { number }, edges: { number }): DrawList
	local outCoords, outEdges = Quantize.SnapRound(coords, edges)
	local list: DrawList = {}
	local used: { [number]: boolean } = {}
	for f = 1, #outEdges do
		used[outEdges[f]] = true
	end
	for v in used do
		square(list, outCoords[2 * v - 1], outCoords[2 * v])
	end
	for i = 1, #edges // 2 do
		local a, b = edges[2 * i - 1], edges[2 * i]
		line(list, coords[2 * a - 1], coords[2 * a], coords[2 * b - 1], coords[2 * b], RAW, "Input")
	end
	for f = 1, #outEdges // 2 do
		local a, b = outEdges[2 * f - 1], outEdges[2 * f]
		line(list, outCoords[2 * a - 1], outCoords[2 * a], outCoords[2 * b - 1], outCoords[2 * b], SNAPPED, "Snapped")
	end
	for v in used do
		table.insert(list, {
			Kind = "Point",
			Points = { outCoords[2 * v - 1], 0, outCoords[2 * v] },
			Color = VERTEX,
			Layer = "Vertices",
		})
	end
	return list
end

local scenes = {}
local function add(name: string, coords: { number }, edges: { number })
	table.insert(scenes, { Name = `{name}_1Before`, List = before(coords, edges) })
	table.insert(scenes, { Name = `{name}_2After`, List = after(coords, edges) })
end

add("Soup7", soup(7, 14, 24, false))
add("Soup12", soup(12, 20, 24, false))
add("Shallow8", soup(8, 12, 60, true))
-- The corner cases from the spec, zoomed in: a hot pixel at the origin and lines touching
-- each of its corners (only the bottom-left one is inside a half-open pixel).
add(
	"Corners",
	{ 0, 0, 0, 0, -1, 2, 2, -1, -2, -1, 1, 2, -1, -2, 2, 1, -2, 1, 1, -2 },
	{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10 }
)

return scenes
