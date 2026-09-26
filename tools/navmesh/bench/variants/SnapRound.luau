--!strict
--!native
-- A/B prototype of Quantize.SnapRound (bench only, never shipped from here). Generated from
-- lib/navmesh/src/Quantize.luau with its two linear scans replaced: crossing candidates come
-- from grid buckets or an x sweep, and route() looks hot pixels up in grid buckets of CELL grid
-- units. Everything else is the shipped algorithm, so outputs must match it exactly.
return function(Orient2D: (number, number, number, number, number, number) -> number, options: { Cell: number, Crossings: string })
	local CELL = options.Cell
	local SWEEP = options.Crossings == "sweep"
	local GRID = 256 -- grid points per stud (N2)
	local LIMIT = 32768 -- |coordinate| bound in studs (U-d)
	-- Rounding error of a crossing's f64 position, in grid units, is below 2^-26 at the coordinate
	-- limit. This margin is far above that.
	local BOUNDARY_EPS = 1e-6
	-- Each level of rerouting is a fragment between two distinct hot pixels, so a correct run is
	-- shallow. Hitting this means a bug, not a hard input.
	local MAX_DEPTH = 256

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

		-- Candidate pairs: grid buckets (segments sharing a cell), or a sweep over x (active list).
		local function testPair(i: number, j: number)
			local a, b = edges[2 * i - 1], edges[2 * i]
			local ax, ay, bx, by = coords[2 * a - 1], coords[2 * a], coords[2 * b - 1], coords[2 * b]
			local c, d = edges[2 * j - 1], edges[2 * j]
			local cx, cy, dx, dy = coords[2 * c - 1], coords[2 * c], coords[2 * d - 1], coords[2 * d]
			if
				math.max(ax, bx) < math.min(cx, dx)
				or math.max(cx, dx) < math.min(ax, bx)
				or math.max(ay, by) < math.min(cy, dy)
				or math.max(cy, dy) < math.min(ay, by)
			then
				return
			end
			local o1, o2 = Orient2D(ax, ay, bx, by, cx, cy), Orient2D(ax, ay, bx, by, dx, dy)
			if o1 * o2 >= 0 then
				return
			end
			local o3, o4 = Orient2D(cx, cy, dx, dy, ax, ay), Orient2D(cx, cy, dx, dy, bx, by)
			if o3 * o4 >= 0 then
				return
			end
			local ex, ey = bx - ax, by - ay
			local fx, fy = dx - cx, dy - cy
			local t = ((cx - ax) * fy - (cy - ay) * fx) / (ex * fy - ey * fx)
			local x0, x1 = pixelRange(ax + t * ex)
			local y0, y1 = pixelRange(ay + t * ey)
			for x = x0, x1 do
				for y = y0, y1 do
					addHot(x, y)
				end
			end
		end
		local segMinX, segMaxX = table.create(segCount), table.create(segCount)
		local segMinY, segMaxY = table.create(segCount), table.create(segCount)
		for k = 1, segCount do
			local a, b = edges[2 * k - 1], edges[2 * k]
			segMinX[k], segMaxX[k] = math.min(coords[2 * a - 1], coords[2 * b - 1]), math.max(coords[2 * a - 1], coords[2 * b - 1])
			segMinY[k], segMaxY[k] = math.min(coords[2 * a], coords[2 * b]), math.max(coords[2 * a], coords[2 * b])
		end
		if SWEEP then
			local order = table.create(segCount)
			for k = 1, segCount do
				order[k] = k
			end
			table.sort(order, function(l: number, r: number): boolean
				return segMinX[l] < segMinX[r]
			end)
			local active: { number } = {}
			for _, i in order do
				local x = segMinX[i]
				local kept = 0
				for _, j in active do
					if segMaxX[j] >= x then
						kept += 1
						active[kept] = j
					end
				end
				for n = #active, kept + 1, -1 do
					active[n] = nil
				end
				for _, j in active do
					if segMaxY[j] >= segMinY[i] and segMinY[j] <= segMaxY[i] then
						testPair(math.min(i, j), math.max(i, j))
					end
				end
				table.insert(active, i)
			end
		else
			local cells: { [number]: { number } } = {}
			for k = 1, segCount do
				for cx = segMinX[k] // CELL, segMaxX[k] // CELL do
					for cy = segMinY[k] // CELL, segMaxY[k] // CELL do
						local key = (cx + 1048576) * 2097152 + (cy + 1048576)
						local list = cells[key]
						if list == nil then
							list = {}
							cells[key] = list
						end
						table.insert(list, k)
					end
				end
			end
			local stamp = table.create(segCount, 0)
			for i = 1, segCount do
				for cx = segMinX[i] // CELL, segMaxX[i] // CELL do
					for cy = segMinY[i] // CELL, segMaxY[i] // CELL do
						for _, j in cells[(cx + 1048576) * 2097152 + (cy + 1048576)] do
							if j > i and stamp[j] ~= i then
								stamp[j] = i
								testPair(i, j)
							end
						end
					end
				end
			end
		end

		local hotCount = #hotX
		local hotCells: { [number]: { number } } = {}
		for h = 1, hotCount do
			local key = (hotX[h] // CELL + 1048576) * 2097152 + (hotY[h] // CELL + 1048576)
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
			for cx = minX // CELL, maxX // CELL do
				for cy = minY // CELL, maxY // CELL do
					local list = hotCells[(cx + 1048576) * 2097152 + (cy + 1048576)]
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

	return Quantize.SnapRound
end
