--!strict
--!native
--[=[
	@class Quantize
	@private

	The N2 grid and iterated snap rounding (spec SR2). Authored coordinates are quantized to a
	1/256-stud grid. Snap rounding then reroutes every constraint segment through each hot pixel
	it touches, so the CDT is fed only grid points and edges that never cross. That means the
	CDT never has to add a Steiner vertex.

	**Hot pixels** are the unit grid cells, half-open, [i - 1/2, i + 1/2) on each axis, that
	contain a segment endpoint or a crossing between two segments. Because the cells are
	half-open, they partition the plane, so a segment meets them in a strict order.

	**Iterated snap rounding** (Halperin & Packer): each segment becomes the polyline through the
	centres of the hot pixels it meets, in order. Every new fragment is rerouted again, until no
	fragment meets a hot pixel other than its own two ends.

	**Exactness:**
	- Whether a segment meets a pixel is decided exactly. The test is Liang-Barsky clipping on
	  doubled grid integers. With the ±32,768-stud guard, every product stays below 2^50, so all
	  of the f64 arithmetic is exact.
	- Crossings are detected with the CDT's exact `Orient2D`.
	- The only rounded value is a crossing's position, which picks its hot pixel. When that
	  position is within `BOUNDARY_EPS` of a pixel edge, every pixel it could be in is marked
	  hot. A superset of hot pixels is always safe for snap rounding.
]=]

local CDT = require("../ConstrainedDelaunay")

local Orient2D = CDT.Orient2D

local GRID = 256 -- grid points per stud (N2)
local LIMIT = 32768 -- |coordinate| bound in studs (U-d)
-- Rounding error of a crossing's f64 position, in grid units, is below 2^-26 at the coordinate
-- limit. This margin is far above that.
local BOUNDARY_EPS = 1e-6
-- Each level of rerouting is a fragment between two distinct hot pixels, so a correct run is
-- shallow. Hitting this means a bug, not a hard input.
local MAX_DEPTH = 256
-- Grid-bucket cell bounds in grid units (1/4 stud to 128 studs), and the cell key packing:
-- cell indices stay within 2^17 of zero for coordinates within 2^23 and cells of at least 64.
local MIN_CELL, MAX_CELL = 64, 32768
local CELL_KEY_OFFSET, CELL_KEY_STRIDE = 1048576, 2097152

local Quantize = {}

Quantize.GRID = GRID
Quantize.LIMIT = LIMIT

--[=[
	Converts a coordinate in studs to grid units (an integer). Errors outside ±32,768 studs,
	and on NaN.
]=]
function Quantize.ToGrid(value: number): number
	if not (math.abs(value) <= LIMIT) then
		error(`coordinate {value} is outside the supported range of ±{LIMIT} studs`, 2)
	end
	return math.round(value * GRID)
end

local function pointKey(x: number, y: number): number
	-- Grid coordinates are integers within ±2^23, so this key is exact and unique.
	return (x + 8388608) * 16777216 + (y + 8388608)
end

-- The pixel indices a rounded coordinate could truly lie in: one index, or two when it is
-- within BOUNDARY_EPS of a pixel edge.
local function pixelRange(v: number): (number, number)
	return math.floor(v - BOUNDARY_EPS + 0.5), math.floor(v + BOUNDARY_EPS + 0.5)
end

--[=[
	Tests whether the segment (px, py)→(qx, qy) meets the half-open pixel centred on (cx, cy),
	exactly. All arguments are doubled grid coordinates, so pixel edges are at cx ± 1. The caller
	guarantees the centre is inside the segment's bounding box, so an axis-aligned segment
	always lies within the pixel's span on its fixed axis.

	Returns hit, then the entry parameter t = n/d (d > 0) along the segment and whether that
	entry is open (1) or closed (0), for ordering.
]=]
local function hitPixel(
	px: number,
	py: number,
	qx: number,
	qy: number,
	cx: number,
	cy: number
): (boolean, number, number, number)
	local dx, dy = qx - px, qy - py
	-- The feasible t is an interval, bounded by rationals n/d with d > 0. It starts as [0, 1].
	local loN, loD, loOpen = 0, 1, false
	local hiN, hiD, hiOpen = 1, 1, false

	-- Tightens the interval by the constraint a + t*b >= 0 (closed) or > 0 (open). Endpoints are
	-- pixel centres and edges are odd, so a is never 0 and only pixel corners make bounds tie.
	-- - Two lower bounds tie when the segment enters through a corner. The entry is open if
	--   either one is, which decides the ordering.
	-- - Upper-bound ties never matter. A corner touch has one lower and one upper bound at the
	--   corner, and two tied upper bounds only happen on an interior crossing.
	local function clip(a: number, b: number, open: boolean)
		if b > 0 then
			local n = -a -- t >= n / b
			local c = n * loD - loN * b
			if c > 0 then
				loN, loD, loOpen = n, b, open
			elseif c == 0 then
				loOpen = loOpen or open
			end
		elseif b < 0 then
			local d = -b -- t <= a / d
			if a * hiD < hiN * d then
				hiN, hiD, hiOpen = a, d, open
			end
		end
	end

	clip(px - (cx - 1), dx, false) -- x >= left edge
	clip((cx + 1) - px, -dx, true) -- x < right edge
	clip(py - (cy - 1), dy, false) -- y >= bottom edge
	clip((cy + 1) - py, -dy, true) -- y < top edge
	local c = loN * hiD - hiN * loD
	return c < 0 or (c == 0 and not loOpen and not hiOpen), loN, loD, if loOpen then 1 else 0
end

--[=[
	Snap-rounds a set of constraint segments.

	`coords` holds flat grid-integer points {x1, y1, x2, y2, …}; `edges` holds flat 1-based
	vertex pairs {a1, b1, …}. Returns:
	- the output coords: the input vertices first, with their indices kept, then any new
	  hot-pixel vertices;
	- the output edges: the fragments, each directed like its source segment;
	- the source input edge of each fragment.

	The fragments never cross, and none meets a hot pixel other than its two ends. A segment
	with zero length is dropped.
]=]
function Quantize.SnapRound(coords: { number }, edges: { number }): ({ number }, { number }, { number })
	local outCoords = table.clone(coords)
	local keyToVertex: { [number]: number } = {}
	for v = 1, #coords // 2 do
		local key = pointKey(coords[2 * v - 1], coords[2 * v])
		if keyToVertex[key] == nil then
			keyToVertex[key] = v
		end
	end

	-- Hot pixels, by centre (grid units).
	local hotX, hotY = {}, {}
	local hotKey: { [number]: boolean } = {}
	local function addHot(x: number, y: number)
		local key = pointKey(x, y)
		if not hotKey[key] then
			hotKey[key] = true
			table.insert(hotX, x)
			table.insert(hotY, y)
		end
	end

	local segCount = #edges // 2
	for k = 1, segCount do
		local a, b = edges[2 * k - 1], edges[2 * k]
		addHot(coords[2 * a - 1], coords[2 * a])
		addHot(coords[2 * b - 1], coords[2 * b])
	end

	-- Grid buckets for both scans (bench.md, experiments 1 and 1b). A cell is about the typical
	-- spacing between segments, sqrt(bounds area / segment count), rounded up to a power of
	-- two: dense scenes get small cells and sparse ones large. Any fixed size was up to 54% off
	-- the best on some scene; this rule stayed within 11%.
	local segMinX, segMaxX = table.create(segCount), table.create(segCount)
	local segMinY, segMaxY = table.create(segCount), table.create(segCount)
	local boundsX0, boundsY0, boundsX1, boundsY1 = math.huge, math.huge, -math.huge, -math.huge
	for k = 1, segCount do
		local a, b = edges[2 * k - 1], edges[2 * k]
		local ax, ay, bx, by = coords[2 * a - 1], coords[2 * a], coords[2 * b - 1], coords[2 * b]
		segMinX[k], segMaxX[k] = math.min(ax, bx), math.max(ax, bx)
		segMinY[k], segMaxY[k] = math.min(ay, by), math.max(ay, by)
		boundsX0, boundsX1 = math.min(boundsX0, segMinX[k]), math.max(boundsX1, segMaxX[k])
		boundsY0, boundsY1 = math.min(boundsY0, segMinY[k]), math.max(boundsY1, segMaxY[k])
	end
	local spacing = math.sqrt(math.max(1, (boundsX1 - boundsX0) * (boundsY1 - boundsY0)) / math.max(1, segCount))
	local cell = math.clamp(2 ^ math.ceil(math.log(spacing, 2)), MIN_CELL, MAX_CELL)
	local function cellKey(cx: number, cy: number): number
		return (cx + CELL_KEY_OFFSET) * CELL_KEY_STRIDE + (cy + CELL_KEY_OFFSET)
	end

	-- Crossing candidates: segments sharing a cell, each pair tested once.
	local segCells: { [number]: { number } } = {}
	for k = 1, segCount do
		for cx = segMinX[k] // cell, segMaxX[k] // cell do
			for cy = segMinY[k] // cell, segMaxY[k] // cell do
				local key = cellKey(cx, cy)
				local list = segCells[key]
				if list == nil then
					list = {}
					segCells[key] = list
				end
				table.insert(list, k)
			end
		end
	end
	local stamp = table.create(segCount, 0)
	for i = 1, segCount do
		local a, b = edges[2 * i - 1], edges[2 * i]
		local ax, ay, bx, by = coords[2 * a - 1], coords[2 * a], coords[2 * b - 1], coords[2 * b]
		for cx = segMinX[i] // cell, segMaxX[i] // cell do
			for cy = segMinY[i] // cell, segMaxY[i] // cell do
				for _, j in segCells[cellKey(cx, cy)] do
					if j <= i or stamp[j] == i then
						continue
					end
					stamp[j] = i
					if
						segMaxX[i] < segMinX[j]
						or segMaxX[j] < segMinX[i]
						or segMaxY[i] < segMinY[j]
						or segMaxY[j] < segMinY[i]
					then
						continue
					end
					local c, d = edges[2 * j - 1], edges[2 * j]
					local cx2, cy2, dx, dy = coords[2 * c - 1], coords[2 * c], coords[2 * d - 1], coords[2 * d]
					-- Only proper crossings add hot pixels. Touching, T-junction and collinear
					-- overlap all meet at a segment endpoint, which is already hot.
					local o1, o2 = Orient2D(ax, ay, bx, by, cx2, cy2), Orient2D(ax, ay, bx, by, dx, dy)
					if o1 * o2 >= 0 then
						continue
					end
					local o3, o4 = Orient2D(cx2, cy2, dx, dy, ax, ay), Orient2D(cx2, cy2, dx, dy, bx, by)
					if o3 * o4 >= 0 then
						continue
					end
					local ex, ey = bx - ax, by - ay
					local fx, fy = dx - cx2, dy - cy2
					local t = ((cx2 - ax) * fy - (cy2 - ay) * fx) / (ex * fy - ey * fx)
					local x0, x1 = pixelRange(ax + t * ex)
					local y0, y1 = pixelRange(ay + t * ey)
					for x = x0, x1 do
						for y = y0, y1 do
							addHot(x, y)
						end
					end
				end
			end
		end
	end

	local hotCount = #hotX
	local hotCells: { [number]: { number } } = {}
	for h = 1, hotCount do
		local key = cellKey(hotX[h] // cell, hotY[h] // cell)
		local list = hotCells[key]
		if list == nil then
			list = {}
			hotCells[key] = list
		end
		table.insert(list, h)
	end
	local hotVertex = table.create(hotCount, 0)
	local function vertexOfHot(h: number): number
		local v = hotVertex[h]
		if v == 0 then
			local key = pointKey(hotX[h], hotY[h])
			v = keyToVertex[key]
			if v == nil then
				table.insert(outCoords, hotX[h])
				table.insert(outCoords, hotY[h])
				v = #outCoords // 2
				keyToVertex[key] = v
			end
			hotVertex[h] = v
		end
		return v
	end

	local outEdges, outSource = {}, {}

	-- Routes the fragment between the hot-pixel centres (px, py) and (qx, qy), grid units.
	local function route(source: number, p: number, q: number, depth: number)
		if depth > MAX_DEPTH then
			error("snap rounding did not converge (internal error)")
		end
		local px, py = outCoords[2 * p - 1], outCoords[2 * p]
		local qx, qy = outCoords[2 * q - 1], outCoords[2 * q]
		-- A pixel centre outside the fragment's bounding box can't be hit: centres are integers
		-- and pixels extend 1/2 on each side.
		local minX, maxX = math.min(px, qx), math.max(px, qx)
		local minY, maxY = math.min(py, qy), math.max(py, qy)

		local hits: { { number } }? = nil
		for cx = minX // cell, maxX // cell do
			for cy = minY // cell, maxY // cell do
				local list = hotCells[cellKey(cx, cy)]
				if list == nil then
					continue
				end
				for _, h in list do
					local hx, hy = hotX[h], hotY[h]
					if hx < minX or hx > maxX or hy < minY or hy > maxY then
						continue
					end
					if (hx == px and hy == py) or (hx == qx and hy == qy) then
						continue
					end
					local hit, n, d, open = hitPixel(2 * px, 2 * py, 2 * qx, 2 * qy, 2 * hx, 2 * hy)
					if hit then
						hits = hits or {}
						table.insert(hits :: { { number } }, { h, n, d, open })
					end
				end
			end
		end

		if hits == nil then
			table.insert(outEdges, p)
			table.insert(outEdges, q)
			table.insert(outSource, source)
			return
		end
		-- Half-open pixels are disjoint, but two can share an entry value. The segment then passes
		-- exactly through a corner: it touches one pixel only at that point (closed entry), and
		-- enters the next just after it (open entry). Closed comes first.
		table.sort(hits, function(l, r)
			local c = l[2] * r[3] - r[2] * l[3]
			return c < 0 or (c == 0 and l[4] < r[4])
		end)
		local prev = p
		for _, hit in hits do
			local v = vertexOfHot(hit[1])
			route(source, prev, v, depth + 1)
			prev = v
		end
		route(source, prev, q, depth + 1)
	end

	for k = 1, segCount do
		local a, b = edges[2 * k - 1], edges[2 * k]
		if coords[2 * a - 1] == coords[2 * b - 1] and coords[2 * a] == coords[2 * b] then
			continue
		end
		route(k, a, b, 0)
	end

	return outCoords, outEdges, outSource
end

return Quantize
