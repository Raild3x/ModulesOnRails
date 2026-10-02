--!strict
--!native
-- Authors: Logan Hunt (Raildex)
-- September 25, 2026
--[=[
	@class NavMeshBuild
	@private

	`NavMesh.Build`: authored description → mesh state (spec "Build" steps 1-5).

	Per floor:
	1. Quantize every ring to the grid, validate it, and orient it CCW.
	2. Triangulate each walkable ring on its own. That is the ring's height surface (SR6). A
	   non-planar ring's diagonals become open (group 0) constraints, which keeps its creases.
	3. Snap-round every ring, the creases and the origin-aligned tile grid lines together,
	   once (SR2, SR3).
	Then per tile:
	4. Clip the snapped rings to the tile: walkable (1), obstacle (2), area (4+). Add the tile
	   rectangle (3) and every snapped vertex on its border, and run one `CDT.Triangulate`.
	5. Keep a triangle iff walkable > 0, obstacle == 0 and tile > 0. Its area is the last area
	   group it lies in, otherwise the floor's default.
	6. Take heights from the walkable ring surfaces, check that overlapping rings agree, and
	   copy out through Storage with the degeneracy guard. Vertices are interned per floor by
	   grid point.
	Finally, link neighbours across tile borders by matching reversed open edges.
]=]

local CDT = require("../ConstrainedDelaunay")
local Clearance = require("./Clearance")
local Quantize = require("./Quantize")
local Snap = require("./Snap")
local Storage = require("./Storage")
local Types = require("./Types")

type Polygon = Types.Polygon
type FloorDesc = Types.FloorDesc
-- A seam as one floor sees it: its index and quantized ends (grid units).
type FloorSeam = { Id: number, AX: number, AZ: number, BX: number, BZ: number }
-- A triangle edge lying on a seam.
type SeamPiece = { Tri: number, Edge: number }
type NavMeshDesc = Types.NavMeshDesc
type Triangulation = CDT.Triangulation

local Orient2D = CDT.Orient2D

local GRID = Quantize.GRID
local LIMIT = Quantize.LIMIT

local GROUP_OPEN = 0
local GROUP_WALKABLE = 1
local GROUP_OBSTACLE = 2
local GROUP_TILE = 3
local GROUP_FIRST_AREA = 4

-- Walkable rings that overlap or touch must give the same height within this (studs). Snapped
-- vertices sit up to half a grid pixel off a ring edge, so this allows a slope of 12 there.
local HEIGHT_TOLERANCE = 0.05
-- A ring counts as planar when every point is within this of its plane (studs). Authored
-- heights are f32 (Vector3), so a tilted planar ring misses its plane by f32 rounding; a crease
-- this small is invisible and well under HEIGHT_TOLERANCE.
local PLANAR_TOLERANCE = 1e-3
-- NavMeshDesc.SimplifyTolerance when not given (studs; Track F R1, simplification-plan.md D1;
-- ruled 2026-10-02 from the measured 1/16, 1/10 and 1/4: bench.md "Simplification").
local DEFAULT_SIMPLIFY_TOLERANCE = 0.25
-- NavMeshDesc.MaxAgentRadius when not given (studs; math.huge = no cap). Ruled 2026-10-02: an
-- uncapped width searches walls across the whole room, so one crate near a long outline cost
-- seconds per Update; capped, milliseconds (bench.md "Huge rings").
local DEFAULT_MAX_AGENT_RADIUS = 8
-- The default TileSize adapts to each floor (bench.md, "TileSize re-run over scenes"): about 36
-- constraint edges per tile balanced a tile's rebuild time (1-2 ms) against the triangles its
-- borders add (about 15%) in every scene. Rounded to a power of two from 4 to 256 studs.
local EDGES_PER_TILE = 36
local MIN_TILE_POW, MAX_TILE_POW = 2, 8

-- Default tile size in grid units for a floor whose rings span `areaStuds` and have
-- `edgeCount` edges.
local function adaptiveTileSize(areaStuds: number, edgeCount: number): number
	local studs = math.sqrt(EDGES_PER_TILE * math.max(areaStuds, 1) / math.max(edgeCount, 1))
	return 2 ^ math.clamp(math.round(math.log(studs, 2)), MIN_TILE_POW, MAX_TILE_POW) * GRID
end

-- A ring after quantization: grid X and Z, authored height, CCW, no repeated consecutive point.
type Ring = { X: { number }, Z: { number }, Y: { number } }

local function fail(context: string, message: string): never
	error(`NavMesh.Build: {context}: {message}`, 0)
end

local function fmt(n: number): string
	return string.format("%.3f", n)
end

-- Whether the closed segments a-b and c-d share any point (exact on grid integers).
local function segmentsTouch(
	ax: number,
	az: number,
	bx: number,
	bz: number,
	cx: number,
	cz: number,
	dx: number,
	dz: number
): boolean
	local o1, o2 = Orient2D(ax, az, bx, bz, cx, cz), Orient2D(ax, az, bx, bz, dx, dz)
	local o3, o4 = Orient2D(cx, cz, dx, dz, ax, az), Orient2D(cx, cz, dx, dz, bx, bz)
	if o1 * o2 < 0 and o3 * o4 < 0 then
		return true
	end
	-- A collinear point of one segment lying within the other's bounding box is on it.
	local function within(px: number, pz: number, qx: number, qz: number, rx: number, rz: number): boolean
		return math.min(px, qx) <= rx and rx <= math.max(px, qx) and math.min(pz, qz) <= rz and rz <= math.max(pz, qz)
	end
	return (o1 == 0 and within(ax, az, bx, bz, cx, cz))
		or (o2 == 0 and within(ax, az, bx, bz, dx, dz))
		or (o3 == 0 and within(cx, cz, dx, dz, ax, az))
		or (o4 == 0 and within(cx, cz, dx, dz, bx, bz))
end

-- Why a closed ring of grid points (no repeated consecutive point) isn't simple, or nil. A ring
-- that folds back on itself counts too.
local function ringProblem(xs: { number }, zs: { number }): string?
	local n = #xs
	for i = 1, n do
		local p, q, r = (i - 2) % n + 1, i, i % n + 1
		if
			Orient2D(xs[p], zs[p], xs[q], zs[q], xs[r], zs[r]) == 0
			and (xs[q] - xs[p]) * (xs[r] - xs[q]) + (zs[q] - zs[p]) * (zs[r] - zs[q]) < 0
		then
			return `the ring folds back on itself at point {i} ({fmt(xs[q] / GRID)}, {fmt(zs[q] / GRID)})`
		end
	end
	-- ponytail: all-pairs O(n^2) per ring; a sweep if authored rings get large.
	for i = 1, n do
		local i2 = i % n + 1
		for j = i + 2, n do
			local j2 = j % n + 1
			if j2 == i then
				continue
			end
			if segmentsTouch(xs[i], zs[i], xs[i2], zs[i2], xs[j], zs[j], xs[j2], zs[j2]) then
				return `the ring intersects itself (edges {i} and {j})`
			end
		end
	end
	return nil
end

-- The plane through three well-spread points of a ring (point 1, the point furthest from it, and
-- the point furthest from their line: neighbours on a dense ring would magnify the f32 noise in
-- authored heights), as a height at grid (x, z), and whether every point lies on it within
-- PLANAR_TOLERANCE.
local function planeOf(xs: { number }, zs: { number }, ys: { number }): ((number, number) -> number, boolean)
	local n = #xs
	local j, k, far, det = 1, 1, 0, 0
	for i = 2, n do
		local d = (xs[i] - xs[1]) ^ 2 + (zs[i] - zs[1]) ^ 2
		if d > far then
			j, far = i, d
		end
	end
	for i = 2, n do
		local d = (xs[j] - xs[1]) * (zs[i] - zs[1]) - (xs[i] - xs[1]) * (zs[j] - zs[1])
		if math.abs(d) > math.abs(det) then
			k, det = i, d
		end
	end
	if det == 0 then
		-- Every point collinear: a valid ring never is.
		return function()
			return ys[1]
		end, false
	end
	local function at(x: number, z: number): number
		local wj = ((x - xs[1]) * (zs[k] - zs[1]) - (xs[k] - xs[1]) * (z - zs[1])) / det
		local wk = ((xs[j] - xs[1]) * (z - zs[1]) - (x - xs[1]) * (zs[j] - zs[1])) / det
		return ys[1] + wj * (ys[j] - ys[1]) + wk * (ys[k] - ys[1])
	end
	-- Heights were authored at the unquantized points, up to half a grid step away on each axis,
	-- so each point misses the true plane by up to half its rise per step on each axis, and the
	-- plane through three of them, extrapolated, by a few times that (still far under
	-- HEIGHT_TOLERANCE).
	local slack = PLANAR_TOLERANCE
		+ 2 * (math.abs(at(xs[1] + 1, zs[1]) - ys[1]) + math.abs(at(xs[1], zs[1] + 1) - ys[1]))
	for i = 1, n do
		if math.abs(at(xs[i], zs[i]) - ys[i]) > slack then
			return at, false
		end
	end
	return at, true
end

-- Squared distance from (px, pz) to the segment a-b.
local function pointSegment2(px: number, pz: number, ax: number, az: number, bx: number, bz: number): number
	local dx, dz = bx - ax, bz - az
	local len2 = dx * dx + dz * dz
	local t = if len2 > 0 then math.clamp(((px - ax) * dx + (pz - az) * dz) / len2, 0, 1) else 0
	local ex, ez = ax + t * dx - px, az + t * dz - pz
	return ex * ex + ez * ez
end

--[[
	One-sided ring simplification (Track F R1; simplification-plan.md C2 and G1/G2). `eps` is in
	grid units. `side` 1 (an obstacle) only lets the ring grow, -1 (a walkable ring) only shrink.
	Two moves, each judged exactly with Orient2D on grid points:
	- Removal: a run of points becomes the chord over it when each lies on the permitted side of
	  the chord and within eps of it.
	- Collapse: edge b-c becomes a grid point q near where the lines through its neighbouring
	  edges meet, when b and c then lie on the permitted side of the new edges a-q and q-d and q is
	  within eps of b-c. That is the only move a convex ring (a cylinder's 24-gon) admits.
	Every point an edge replaces is checked against that edge, so each lies within eps of the new
	ring and on its permitted side. Pinned points (`pinned`, by ring index) stay. `heightAt` gives
	a collapsed point's height. A result that isn't simple falls back to the ring as given.
]]
local function simplifyRing(
	ring: Ring,
	eps: number,
	side: number,
	pinned: { [number]: boolean }?,
	heightAt: (number, number) -> number
): Ring
	local xs, zs, ys = ring.X, ring.Z, ring.Y
	local n = #xs
	if eps <= 0 or n <= 3 then
		return ring
	end
	-- Rotated to start at the lexicographically smallest point, the anchor: convex, never removed
	-- or collapsed. Original points are then 1..n, and n + 1 is the anchor again, so runs never
	-- wrap.
	local m = 1
	for i = 2, n do
		if xs[i] < xs[m] or (xs[i] == xs[m] and zs[i] < zs[m]) then
			m = i
		end
	end
	local ox, oz, oy, pin = table.create(n + 1), table.create(n + 1), table.create(n + 1), table.create(n + 1, false)
	for k = 1, n do
		local i = (m + k - 2) % n + 1
		ox[k], oz[k], oy[k], pin[k] = xs[i], zs[i], ys[i], pinned ~= nil and pinned[i] == true
	end
	ox[n + 1], oz[n + 1] = ox[1], oz[1]
	local eps2 = eps * eps
	-- Whether original points first..last may all go under the edge u-w: each on the permitted
	-- side of it, and within eps of it. (A removed run and its chord then bound one region,
	-- wholly on the permitted side.)
	local function under(ux: number, uz: number, wx: number, wz: number, first: number, last: number): boolean
		if ux == wx and uz == wz then
			return false
		end
		for k = first, last do
			if
				pin[k]
				or Orient2D(ux, uz, wx, wz, ox[k], oz[k]) * side < 0
				or pointSegment2(ox[k], oz[k], ux, uz, wx, wz) > eps2
			then
				return false
			end
		end
		return true
	end
	-- Whether original points first..last all lie on the permitted side of the line u-w.
	local function beside(ux: number, uz: number, wx: number, wz: number, first: number, last: number): boolean
		for k = first, last do
			if Orient2D(ux, uz, wx, wz, ox[k], oz[k]) * side < 0 then
				return false
			end
		end
		return true
	end

	-- Removal, greedily from the anchor: the original indices of the points kept.
	-- ponytail: each run is re-checked whole as it grows, O(run^2); a wedge test if long
	-- near-straight runs show up in profiles.
	local kept = { 1 }
	local a = 1
	while a <= n do
		local best = a + 1
		for j = a + 2, n + 1 do
			if not under(ox[a], oz[a], ox[j], oz[j], a + 1, j - 1) then
				break
			end
			best = j
		end
		if best <= n then
			table.insert(kept, best)
		end
		a = best
	end

	-- Collapse, one pass over the kept edges b-c that are original edges away from the anchor.
	-- Output points carry the original points they stand on: lo == hi for an original point; a
	-- collapsed one stands on edge lo-hi. The edge out of a point covers the original points after
	-- it (from hi itself, for a collapsed one); the edge into one covers those up to it.
	local rx, rz, ry, rlo, rhi = { ox[1] }, { oz[1] }, { oy[1] }, { 1 }, { 1 }
	local k = 2
	while k <= #kept do
		local b0, c0 = kept[k], kept[k + 1]
		local collapsed = false
		if c0 == b0 + 1 then
			local r = #rx
			local ax, az = rx[r], rz[r]
			local aOut = rhi[r] + (if rlo[r] == rhi[r] then 1 else 0)
			local d0 = kept[k + 2] or n + 1
			local dx, dz = ox[d0], oz[d0]
			local bx, bz, cx, cz = ox[b0], oz[b0], ox[c0], oz[c0]
			-- Where line a-b meets line c-d.
			local ux, uz, vx, vz = bx - ax, bz - az, dx - cx, dz - cz
			local denom = ux * vz - uz * vx
			if denom ~= 0 then
				local t = ((cx - ax) * vz - (cz - az) * vx) / denom
				local px, pz = ax + t * ux, az + t * uz
				if pointSegment2(px, pz, bx, bz, cx, cz) <= eps2 then
					local fx, fz = math.floor(px), math.floor(pz)
					-- The four grid points round it, nearest first.
					local cands = { { fx, fz }, { fx + 1, fz }, { fx, fz + 1 }, { fx + 1, fz + 1 } }
					table.sort(cands, function(p: { number }, q: { number }): boolean
						return (p[1] - px) ^ 2 + (p[2] - pz) ^ 2 < (q[1] - px) ^ 2 + (q[2] - pz) ^ 2
					end)
					for _, q in cands do
						-- q turns toward the kept side (a convex corner of an obstacle, a reflex one
						-- of a walkable ring), so the points it replaces must be beside both new edges.
						local qx, qz = q[1], q[2]
						if
							pointSegment2(qx, qz, bx, bz, cx, cz) <= eps2
							and Orient2D(ax, az, qx, qz, dx, dz) * side > 0
							and under(ax, az, qx, qz, aOut, b0)
							and under(qx, qz, dx, dz, c0, d0 - 1)
							and beside(ax, az, qx, qz, c0, d0 - 1)
							and beside(qx, qz, dx, dz, aOut, b0)
						then
							table.insert(rx, qx)
							table.insert(rz, qz)
							table.insert(ry, heightAt(qx, qz))
							table.insert(rlo, b0)
							table.insert(rhi, c0)
							collapsed = true
							break
						end
					end
				end
			end
		end
		if collapsed then
			k += 2
		else
			table.insert(rx, ox[b0])
			table.insert(rz, oz[b0])
			table.insert(ry, oy[b0])
			table.insert(rlo, b0)
			table.insert(rhi, b0)
			k += 1
		end
	end

	if #rx == n or #rx < 3 or ringProblem(rx, rz) ~= nil then
		return ring
	end
	return { X = rx, Z = rz, Y = ry }
end

local function quantizeRing(polygon: Polygon, context: string): Ring
	-- A point where a ring belongs: usually one ring given where a list of rings goes. A point is
	-- a vector (a Vector3 on Roblox) or, under Lune, a Vector3 shim table with a numeric X.
	local value = polygon :: any
	if type(value) == "vector" or (type(value) == "table" and type(value.X) == "number") then
		fail(context, "expected a ring (a list of points), got a point; Walkable and Obstacles take a list of rings")
	end
	if type(polygon) ~= "table" or #polygon < 3 then
		fail(context, "a ring needs at least 3 points")
	end
	local xs, zs, ys = {}, {}, {}
	for i, point in polygon do
		local x, y, z = point.X, point.Y, point.Z
		if not (math.abs(x) <= LIMIT and math.abs(z) <= LIMIT) then
			fail(context, `point {i} ({x}, {z}) is outside the supported range of ±{LIMIT} studs`)
		end
		if y ~= y or math.abs(y) == math.huge then
			fail(context, `point {i} has a non-finite height`)
		end
		local gx, gz = Quantize.ToGrid(x), Quantize.ToGrid(z)
		local n = #xs
		if n == 0 or xs[n] ~= gx or zs[n] ~= gz then
			table.insert(xs, gx)
			table.insert(zs, gz)
			table.insert(ys, y)
		end
	end
	while #xs > 1 and xs[#xs] == xs[1] and zs[#zs] == zs[1] do
		table.remove(xs)
		table.remove(zs)
		table.remove(ys)
	end
	local n = #xs
	if n < 3 then
		fail(context, "the ring degenerates after quantization to the 1/256-stud grid")
	end

	-- Self-intersection (SR6): the quantized ring, before snap rounding, so rounding can't
	-- pinch a thin neck into a false error.
	local problem = ringProblem(xs, zs)
	if problem ~= nil then
		fail(context, problem)
	end

	-- Orient CCW. The lexicographically smallest vertex is convex, so its turn gives the
	-- orientation exactly (a straight turn there is impossible once folds are rejected).
	local m = 1
	for i = 2, n do
		if xs[i] < xs[m] or (xs[i] == xs[m] and zs[i] < zs[m]) then
			m = i
		end
	end
	local p, r = (m - 2) % n + 1, m % n + 1
	if Orient2D(xs[p], zs[p], xs[m], zs[m], xs[r], zs[r]) < 0 then
		for i = 1, n // 2 do
			local j = n + 1 - i
			xs[i], xs[j] = xs[j], xs[i]
			zs[i], zs[j] = zs[j], zs[i]
			ys[i], ys[j] = ys[j], ys[i]
		end
	end
	return { X = xs, Z = zs, Y = ys }
end

-- An obstacle ring, quantized, then simplified to grow by at most `tolerance` studs (R1). Build
-- and AddObstacle both come here, so a dynamic obstacle is simplified like a baked one.
-- The points of a ring (grid units) on edges within `eps` (plus a pixel) of one of `seams`:
-- moving them could move the ring's edge onto or off a seam (G6), which opens or closes it.
local function seamPins(ring: Ring, eps: number, seams: { FloorSeam }): { [number]: boolean }
	local xs, zs = ring.X, ring.Z
	local n = #xs
	local pinned: { [number]: boolean } = {}
	local reach2 = (eps + 1) ^ 2
	for _, seam in seams do
		for i = 1, n do
			local j = i % n + 1
			-- Segment distance: the closer of the four end-to-segment distances, 0 if they cross.
			if
				segmentsTouch(xs[i], zs[i], xs[j], zs[j], seam.AX, seam.AZ, seam.BX, seam.BZ)
				or pointSegment2(xs[i], zs[i], seam.AX, seam.AZ, seam.BX, seam.BZ) <= reach2
				or pointSegment2(xs[j], zs[j], seam.AX, seam.AZ, seam.BX, seam.BZ) <= reach2
				or pointSegment2(seam.AX, seam.AZ, xs[i], zs[i], xs[j], zs[j]) <= reach2
				or pointSegment2(seam.BX, seam.BZ, xs[i], zs[i], xs[j], zs[j]) <= reach2
			then
				pinned[i], pinned[j] = true, true
			end
		end
	end
	return pinned
end

-- An obstacle ring, quantized, then simplified to grow by at most `tolerance` studs (R1), with
-- points near the floor's seams pinned. Build and AddObstacle both come here with the floor's
-- seams, so a dynamic obstacle is simplified like a baked one.
local function obstacleRing(polygon: Polygon, context: string, tolerance: number, seams: { FloorSeam }?): Ring
	local ring = quantizeRing(polygon, context)
	local eps = tolerance * GRID
	if eps <= 0 then
		return ring
	end
	local ys = ring.Y
	return simplifyRing(ring, eps, 1, seamPins(ring, eps, seams or {}), function()
		return ys[1]
	end)
end

-- A walkable ring, quantized, then simplified to shrink by at most `tolerance` studs (R1) when
-- it is planar (a non-planar ring's points carry its creases), with points near the floor's
-- seams pinned, so the ring still meets each seam.
local function walkableRing(polygon: Polygon, context: string, tolerance: number, seams: { FloorSeam }): Ring
	local ring = quantizeRing(polygon, context)
	local eps = tolerance * GRID
	if eps <= 0 then
		return ring
	end
	local heightAt, planar = planeOf(ring.X, ring.Z, ring.Y)
	if not planar then
		return ring
	end
	return simplifyRing(ring, eps, -1, seamPins(ring, eps, seams), heightAt)
end

local function checkArea(area: any, context: string): number
	if type(area) ~= "number" or area < 1 or math.floor(area) ~= area then
		fail(context, `area id must be an integer >= 1, got {area}`)
	end
	return area
end

-- A walkable ring's own triangulation, its height surface (SR6).
type Surface = { Ring: Ring, Tri: Triangulation, Planar: boolean }

local function ringEdges(n: number, offset: number, edges: { number })
	for i = 1, n do
		table.insert(edges, offset + i)
		table.insert(edges, offset + i % n + 1)
	end
end

local function makeSurface(ring: Ring): Surface
	local xs, zs, ys = ring.X, ring.Z, ring.Y
	local n = #xs
	local coords = table.create(2 * n)
	for i = 1, n do
		coords[2 * i - 1] = xs[i]
		coords[2 * i] = zs[i]
	end
	local edges = {}
	ringEdges(n, 0, edges)
	local tri = CDT.Triangulate { Coords = coords, Edges = edges, EdgeGroups = table.create(n, GROUP_WALKABLE) }

	local _, planar = planeOf(xs, zs, ys)
	return { Ring = ring, Tri = tri, Planar = planar }
end

-- Heights at (x1, z1)..(x3, z3) extended from the plane of the surface triangle containing
-- (px, pz), or of `forced` when given. Returns nil when that point is outside the surface's
-- hull; `inside` says whether it is inside the ring.
local function surfaceHeights(
	surface: Surface,
	px: number,
	pz: number,
	x1: number,
	z1: number,
	x2: number,
	z2: number,
	x3: number,
	z3: number,
	forced: number?
): (number?, number, number, boolean)
	local tri = surface.Tri
	local t = forced or CDT.Locate(tri, px, pz)
	if t == 0 then
		return nil, 0, 0, false
	end
	local a, b, c = CDT.GetTriangle(tri, t)
	local ax, az = CDT.GetVertex(tri, a)
	local bx, bz = CDT.GetVertex(tri, b)
	local cx, cz = CDT.GetVertex(tri, c)
	local ys = surface.Ring.Y
	-- A simple ring's triangulation adds no vertex, so each vertex is one input point.
	local ya = ys[CDT.InputVertexOf(tri, a) :: number]
	local yb = ys[CDT.InputVertexOf(tri, b) :: number]
	local yc = ys[CDT.InputVertexOf(tri, c) :: number]
	local det = (bx - ax) * (cz - az) - (cx - ax) * (bz - az)
	local function at(x: number, z: number): number
		local wa = ((bx - x) * (cz - z) - (cx - x) * (bz - z)) / det
		local wb = ((cx - x) * (az - z) - (ax - x) * (cz - z)) / det
		return wa * ya + wb * yb + (1 - wa - wb) * yc
	end
	return at(x1, z1), at(x2, z2), at(x3, z3), CDT.GetWinding(tri, t, GROUP_WALKABLE) > 0
end

local function pointKey(x: number, z: number): number
	-- Grid coordinates are integers within ±2^23, so this key is exact and unique.
	return (x + 8388608) * 16777216 + (z + 8388608)
end

-- Directed mesh edge key a * EDGE_KEY + b (vertex ids stay far below 2^26).
local EDGE_KEY = 67108864

-- Clips a closed chain (grid coordinates) to the closed rectangle, Sutherland-Hodgman style,
-- keeping winding inside the rectangle. Snap rounding ran with the tile lines, so the chain
-- crosses them only at its own vertices; the only new points are tile corners, where clipped
-- runs along one tile line meet the next. Returns nil when nothing of area-carrying shape
-- remains (fewer than 3 distinct points).
local function clipToRect(
	xs: { number },
	zs: { number },
	x0: number,
	z0: number,
	x1: number,
	z1: number
): ({ number }?, { number })
	local function half(inX: { number }, inZ: { number }, onX: boolean, bound: number, below: boolean)
		local outX, outZ = {}, {}
		local n = #inX
		for i = 1, n do
			local j = i % n + 1
			local pv = if onX then inX[i] else inZ[i]
			local qv = if onX then inX[j] else inZ[j]
			local sp = if below then pv - bound else bound - pv -- <= 0 means inside
			local sq = if below then qv - bound else bound - qv
			if sp <= 0 then
				table.insert(outX, inX[i])
				table.insert(outZ, inZ[i])
			end
			if (sp < 0 and sq > 0) or (sp > 0 and sq < 0) then
				local t = sp / (sp - sq)
				local other = if onX then inZ[i] + t * (inZ[j] - inZ[i]) else inX[i] + t * (inX[j] - inX[i])
				local rounded = math.round(other)
				if math.abs(other - rounded) > 1e-6 then
					error("NavMesh.Build: internal error: a ring crosses a tile line between snapped vertices", 0)
				end
				table.insert(outX, if onX then bound else rounded)
				table.insert(outZ, if onX then rounded else bound)
			end
		end
		return outX, outZ
	end
	local cx, cz = half(xs, zs, true, x1, true)
	cx, cz = half(cx, cz, true, x0, false)
	cx, cz = half(cx, cz, false, z1, true)
	cx, cz = half(cx, cz, false, z0, false)
	local outX, outZ = {}, {}
	for i = 1, #cx do
		local n = #outX
		if n == 0 or outX[n] ~= cx[i] or outZ[n] ~= cz[i] then
			table.insert(outX, cx[i])
			table.insert(outZ, cz[i])
		end
	end
	while #outX > 1 and outX[#outX] == outX[1] and outZ[#outZ] == outZ[1] do
		table.remove(outX)
		table.remove(outZ)
	end
	if #outX < 3 then
		return nil, outZ
	end
	return outX, outZ
end

-- Per surface list (weak keys): for each tile (`size` in grid units, origin-aligned), the indices
-- of the surfaces whose box meets its closed rectangle, ascending. A tile asks only those for
-- heights and planes: asking every ring's surface for every triangle made Build and Update
-- O(triangles x walkable rings) on a floor (known-gaps.md, Track H).
local nearCache: { [any]: { [number]: { number } } } = setmetatable({}, { __mode = "k" }) :: any

local function nearSurfaces(surfaces: { Surface }, size: number, x0: number, z0: number): { number }
	local byTile = nearCache[surfaces]
	if byTile == nil then
		byTile = {}
		for i, surface in surfaces do
			local xs, zs = surface.Ring.X, surface.Ring.Z
			local bx0, bz0, bx1, bz1 = math.huge, math.huge, -math.huge, -math.huge
			for k = 1, #xs do
				bx0, bx1 = math.min(bx0, xs[k]), math.max(bx1, xs[k])
				bz0, bz1 = math.min(bz0, zs[k]), math.max(bz1, zs[k])
			end
			-- A bound on a tile line belongs to the tiles on both sides of it.
			for j = math.ceil(bz0 / size) - 1, math.floor(bz1 / size) do
				for k = math.ceil(bx0 / size) - 1, math.floor(bx1 / size) do
					local key = pointKey(k, j)
					local list = byTile[key]
					if list == nil then
						list = {}
						byTile[key] = list
					end
					table.insert(list, i)
				end
			end
		end
		for _, list in byTile do
			table.sort(list)
		end
		nearCache[surfaces] = byTile
	end
	return byTile[pointKey(x0 // size, z0 // size)] or {}
end

-- What triangulating a tile needs to know about its floor.
type FloorData = {
	Context: string,
	Surfaces: { Surface },
	TileSize: number, -- grid units
	AreaIds: { number },
	DefaultArea: number,
	-- Heights by grid point key, shared by the floor's tiles, so a vertex gets one height.
	Heights: { [number]: number },
	HeightFrom: { [number]: number },
}

-- A kept triangle of a tile: its vertices as grid points (CCW), its area, and its neighbours
-- within the tile (indices into the tile's list, 0 = none).
type TileTriangle = { X: { number }, Z: { number }, Keys: { number }, Area: number, Neighbors: { number } }

-- R2's switch (on by default): specs turn it off to compare a dissolved tile with the plain one.
local DISSOLVE = { Enabled = true }

--[[
	R2 (Track F; simplification-plan.md C1): when constraint edges run inside one class of a
	tile's first triangulation (kept, same area, same height plane), the input for a second one
	from the class boundaries only. Floors authored in overlapping pieces leave such edges, and
	the hot pixels where they cross.
	- Kept triangles are joined by balanced loops (CCW round the kept region, group 1), each
	  non-default area by loops of its own group; a boundary between two planes stays as an open
	  edge, so two walkable rings at different heights never merge.
	- Open edges (creases, seams), the tile rectangle and every border vertex next to a kept
	  triangle stay (G6).
	It is exact (G5): every boundary is an edge of the first triangulation, so the kept region, each
	area and every wall are unchanged, and no edge crosses another, so no vertex is added (G8).
	Returns nil when nothing dissolves.
]]
local function dissolve(
	tri: Triangulation,
	kept: { number },
	keptArea: { number },
	tg: { number },
	floor: FloorData,
	near: { number }
): { Coords: { number }, Edges: { number }, Groups: { number } }?
	local class = table.create(CDT.TriangleCount(tri), false) :: { any } -- area, then plane key
	for i, t in kept do
		class[t] = keptArea[i]
	end
	-- Whether edge e of t carries a constraint, and whether one that always stays (open or tile).
	local function covered(t: number, e: number): (boolean, boolean)
		local n, stays = CDT.GetCoveringEdgeCount(tri, t, e), false
		for k = 1, n do
			local g = tg[CDT.GetCoveringEdge(tri, t, e, k)]
			stays = stays or g == GROUP_OPEN or g == GROUP_TILE
		end
		return n > 0, stays
	end
	local function anyDissolvable(): boolean
		for _, t in kept do
			for e = 1, 3 do
				local m = CDT.GetNeighbor(tri, t, e)
				if m ~= 0 and class[m] == class[t] then
					local constrained, stays = covered(t, e)
					if constrained and not stays then
						return true
					end
				end
			end
		end
		return false
	end
	-- First by area alone, which is cheap: most tiles stop here.
	if not anyDissolvable() then
		return nil
	end
	local x0, z0, x1, z1 = math.huge, math.huge, -math.huge, -math.huge
	for v = 1, CDT.VertexCount(tri) do
		local x, z = CDT.GetVertex(tri, v)
		x0, z0, x1, z1 = math.min(x0, x), math.min(z0, z), math.max(x1, x), math.max(z1, z)
	end
	-- The planes under each kept triangle: the distinct planes of every surface containing it,
	-- each as its heights at the tile corner and a grid step along each axis. Coplanar pieces
	-- share one; an overlap of rings at different heights is a class of its own, so it never
	-- dissolves into either ring (and the heights below still report it). Rounded: float noise can
	-- only split one plane in two, which keeps an edge.
	local areaOf: { [number]: number } = {}
	for i, t in kept do
		local a, b, c = CDT.GetTriangle(tri, t)
		local ax, az = CDT.GetVertex(tri, a)
		local bx, bz = CDT.GetVertex(tri, b)
		local cx, cz = CDT.GetVertex(tri, c)
		local px, pz = (ax + bx + cx) / 3, (az + bz + cz) / 3
		local planes: { string } = {}
		for _, s in near do
			local h0, hx, hz, inside = surfaceHeights(floor.Surfaces[s], px, pz, x0, z0, x0 + 1, z0, x0, z0 + 1)
			if h0 ~= nil and inside then
				-- Integers, so a tiny negative can't print as "-0".
				local key = string.format(
					"%d/%d/%d",
					math.round(h0 * 1e3),
					math.round((hx - h0) * 1e6),
					math.round((hz - h0) * 1e6)
				)
				if not table.find(planes, key) then
					table.insert(planes, key)
				end
			end
		end
		table.sort(planes)
		areaOf[t] = keptArea[i]
		-- Outside every surface (a sliver, see the heights below): dissolves with nothing.
		class[t] = if #planes == 0 then `-{t}` else `{keptArea[i]}:{table.concat(planes, "|")}`
	end
	if not anyDissolvable() then
		return nil
	end

	local areaGroup: { [number]: number } = {}
	for i = #floor.AreaIds, 1, -1 do
		areaGroup[floor.AreaIds[i]] = GROUP_FIRST_AREA + i - 1
	end
	local coords, edges, groups = {}, {}, {}
	local ids: { [number]: number } = {}
	local function id(v: number): number
		local out = ids[v]
		if out == nil then
			local x, z = CDT.GetVertex(tri, v)
			table.insert(coords, x)
			table.insert(coords, z)
			out = #coords // 2
			ids[v] = out
		end
		return out
	end
	local function add(u: number, w: number, group: number)
		table.insert(edges, id(u))
		table.insert(edges, id(w))
		table.insert(groups, group)
	end
	-- Tile-border vertices next to kept triangles stay (G6): the tile's edge is the hull, so the
	-- kept loops run along it through every one of them.
	for t = 1, CDT.TriangleCount(tri) do
		local verts = { CDT.GetTriangle(tri, t) }
		for e = 1, 3 do
			local m = CDT.GetNeighbor(tri, t, e)
			-- CCW round t: from the vertex after e to the one after that.
			local u, w = verts[e % 3 + 1], verts[(e + 1) % 3 + 1]
			if m < t then -- once per edge (a hull edge has m = 0)
				for k = 1, CDT.GetCoveringEdgeCount(tri, t, e) do
					if tg[CDT.GetCoveringEdge(tri, t, e, k)] == GROUP_OPEN then
						add(u, w, GROUP_OPEN)
						break
					end
				end
				if class[t] and m ~= 0 and class[m] and class[t] ~= class[m] and areaOf[t] == areaOf[m] then
					add(u, w, GROUP_OPEN) -- a change of plane only
				end
			end
			if class[t] then
				local outside = m == 0 or not class[m]
				if outside then
					add(u, w, GROUP_WALKABLE)
				end
				local area = areaOf[t]
				if area ~= floor.DefaultArea and (outside or areaOf[m] ~= area) then
					add(u, w, areaGroup[area])
				end
			end
		end
	end
	local corner = #coords // 2
	for _, p in { { x0, z0 }, { x1, z0 }, { x1, z1 }, { x0, z1 } } do
		table.insert(coords, p[1])
		table.insert(coords, p[2])
	end
	for i = 1, 4 do
		table.insert(edges, corner + i)
		table.insert(edges, corner + i % 4 + 1)
		table.insert(groups, GROUP_TILE)
	end
	return { Coords = coords, Edges = edges, Groups = groups }
end

-- Triangulates one tile's input and applies the keep rule, areas and heights (SR6). Errors
-- (with the floor's context) on an authoring mistake. Used by Build and by Update.
local function triangulateTile(tc: { number }, te: { number }, tg: { number }, floor: FloorData): { TileTriangle }
	local floorContext = floor.Context
	local surfaces, vertexHeight, vertexFrom = floor.Surfaces, floor.Heights, floor.HeightFrom
	-- The tile's min corner: its rectangle's corners are among the input points.
	local tx0, tz0 = math.huge, math.huge
	for k = 1, #tc, 2 do
		tx0, tz0 = math.min(tx0, tc[k]), math.min(tz0, tc[k + 1])
	end
	local near = nearSurfaces(surfaces, floor.TileSize, tx0, tz0)
	local function run(c: { number }, e: { number }, g: { number }): Triangulation
		local t = CDT.Triangulate { Coords = c, Edges = e, EdgeGroups = g }
		for v = 1, CDT.VertexCount(t) do
			if CDT.InputVertexOf(t, v) == nil then
				fail(
					floorContext,
					"internal error: the triangulator added a vertex, so snap rounding missed a crossing"
				)
			end
		end
		return t
	end
	-- Keep rule and areas: the kept triangles and their areas.
	local function classify(t: Triangulation): ({ number }, { number })
		local kept: { number }, keptArea: { number } = {}, {}
		-- A tile only has the area groups up to the highest one clipped into it.
		local lastArea = math.min(#floor.AreaIds, CDT.GroupCount(t) - GROUP_FIRST_AREA + 1)
		for k = 1, CDT.TriangleCount(t) do
			if
				CDT.GetWinding(t, k, GROUP_WALKABLE) > 0
				and CDT.GetWinding(t, k, GROUP_OBSTACLE) == 0
				and CDT.GetWinding(t, k, GROUP_TILE) > 0
			then
				local area = floor.DefaultArea
				for i = lastArea, 1, -1 do
					if CDT.GetWinding(t, k, GROUP_FIRST_AREA + i - 1) > 0 then
						area = floor.AreaIds[i]
						break
					end
				end
				table.insert(kept, k)
				table.insert(keptArea, area)
			end
		end
		return kept, keptArea
	end
	local tri = run(tc, te, tg)
	local kept, keptArea = classify(tri)
	local again = if DISSOLVE.Enabled then dissolve(tri, kept, keptArea, tg, floor, near) else nil
	if again then
		tri = run(again.Coords, again.Edges, again.Groups)
		kept, keptArea = classify(tri)
	end

	-- Heights. Each kept triangle takes its heights from the first walkable surface that
	-- contains it. Every other surface containing it must agree, and so must every triangle
	-- sharing a vertex, in any tile (a step inside one floor is an error).
	for _, t in kept do
		local a, b, c = CDT.GetTriangle(tri, t)
		local ax, az = CDT.GetVertex(tri, a)
		local bx, bz = CDT.GetVertex(tri, b)
		local cx, cz = CDT.GetVertex(tri, c)
		local px, pz = (ax + bx + cx) / 3, (az + bz + cz) / 3
		local h1, h2, h3, from = nil :: number?, 0, 0, 0
		for _, i in near do
			local s1, s2, s3, inside = surfaceHeights(surfaces[i], px, pz, ax, az, bx, bz, cx, cz)
			if s1 == nil or not inside then
				continue
			end
			if h1 == nil then
				h1, h2, h3, from = s1, s2, s3, i
			elseif
				math.abs(s1 - h1) > HEIGHT_TOLERANCE
				or math.abs(s2 - h2) > HEIGHT_TOLERANCE
				or math.abs(s3 - h3) > HEIGHT_TOLERANCE
			then
				fail(
					floorContext,
					`walkable rings {from} and {i} overlap with different heights near ({fmt(px / GRID)}, {fmt(
						pz / GRID
					)}); split them into separate floors`
				)
			end
		end
		if h1 == nil then
			-- A sliver whose centre snapped just outside every ring (by under half a grid
			-- pixel): extend the plane of the nearest inside surface triangle.
			-- ponytail: linear scan; slivers are rare.
			local best, bestSurface, bestTriangle = math.huge, 1, 1
			for i, surface in surfaces do
				local stri = surface.Tri
				for st = 1, CDT.TriangleCount(stri) do
					if CDT.GetWinding(stri, st, GROUP_WALKABLE) > 0 then
						local sa, sb, sc = CDT.GetTriangle(stri, st)
						local sax, saz = CDT.GetVertex(stri, sa)
						local sbx, sbz = CDT.GetVertex(stri, sb)
						local scx, scz = CDT.GetVertex(stri, sc)
						local dx, dz = (sax + sbx + scx) / 3 - px, (saz + sbz + scz) / 3 - pz
						if dx * dx + dz * dz < best then
							best, bestSurface, bestTriangle = dx * dx + dz * dz, i, st
						end
					end
				end
			end
			h1, h2, h3 = surfaceHeights(surfaces[bestSurface], px, pz, ax, az, bx, bz, cx, cz, bestTriangle)
			from = bestSurface
		end
		for k, v in { a, b, c } do
			local h = if k == 1 then h1 :: number elseif k == 2 then h2 else h3
			local vx, vz = CDT.GetVertex(tri, v)
			local key = pointKey(vx, vz)
			local previous = vertexHeight[key]
			if previous == nil then
				vertexHeight[key] = h
				vertexFrom[key] = from
			elseif math.abs(previous - h) > HEIGHT_TOLERANCE then
				fail(
					floorContext,
					`walkable rings {vertexFrom[key]} and {from} meet at different heights at ({fmt(vx / GRID)}, {fmt(
						vz / GRID
					)}); split them into separate floors joined by a seam`
				)
			end
		end
	end

	local index: { [number]: number } = {}
	for i, t in kept do
		index[t] = i
	end
	local out: { TileTriangle } = table.create(#kept)
	for i, t in kept do
		local xs, zs, keys = {}, {}, {}
		for k, v in { CDT.GetTriangle(tri, t) } do
			xs[k], zs[k] = CDT.GetVertex(tri, v)
			keys[k] = pointKey(xs[k], zs[k])
		end
		out[i] = {
			X = xs,
			Z = zs,
			Keys = keys,
			Area = keptArea[i],
			Neighbors = {
				index[CDT.GetNeighbor(tri, t, 1)] or 0,
				index[CDT.GetNeighbor(tri, t, 2)] or 0,
				index[CDT.GetNeighbor(tri, t, 3)] or 0,
			},
		}
	end
	return out
end

-- Copies a tile's triangles into storage as tile `tile` of floor `floorId`, interning vertices
-- per floor by grid point, and records open edges for cross-tile linking and seam pieces
-- (edges whose grid ends match a seam fragment in `seamOfFragment`).
local function copyOut(
	s: Storage.State,
	floorContext: string,
	tile: number,
	triangles: { TileTriangle },
	heights: { [number]: number },
	meshVertex: { [number]: number },
	openEdges: { [number]: number },
	seamOfFragment: { [string]: number }
)
	local first = Storage.AllocTileRange(s, tile, #triangles)
	for i, tri in triangles do
		local id = first + i - 1
		local ids = {}
		for k = 1, 3 do
			local key = tri.Keys[k]
			local m = meshVertex[key]
			if m == nil then
				m = Storage.AddVertex(s, vector.create(tri.X[k] / GRID, heights[key], tri.Z[k] / GRID))
				meshVertex[key] = m
			end
			ids[k] = m
		end
		Storage.SetTriangle(s, id, ids[1], ids[2], ids[3])
		Storage.SetTriangleArea(s, id, tri.Area)
		if next(seamOfFragment) ~= nil then
			for e = 1, 3 do
				local ka, kb = tri.Keys[e % 3 + 1], tri.Keys[(e + 1) % 3 + 1]
				local seamId = seamOfFragment[if ka < kb then `{ka}:{kb}` else `{kb}:{ka}`]
				if seamId ~= nil then
					Storage.InsertPiece(s, seamId, id, e)
				end
			end
		end
		for e = 1, 3 do
			local n = tri.Neighbors[e]
			Storage.SetNeighbor(s, id, e, if n == 0 then 0 else first + n - 1)
			if n == 0 then
				openEdges[ids[e % 3 + 1] * EDGE_KEY + ids[(e + 1) % 3 + 1]] = id * 4 + e
			end
		end
		-- Degeneracy guard (SR2): CCW with positive area in stored coordinates.
		local pa, pb, pc = Storage.GetVertex(s, ids[1]), Storage.GetVertex(s, ids[2]), Storage.GetVertex(s, ids[3])
		if Orient2D(pa.X, pa.Z, pb.X, pb.Z, pc.X, pc.Z) <= 0 then
			fail(floorContext, `a triangle degenerates after quantization near ({fmt(pa.X)}, {fmt(pa.Z)})`)
		end
	end
end

-- Links cross-tile neighbours: each open edge meets the reversed open edge of the next tile.
local function linkOpenEdges(s: Storage.State, openEdges: { [number]: number })
	for key, packed in openEdges do
		local other = openEdges[(key % EDGE_KEY) * EDGE_KEY + key // EDGE_KEY]
		if other ~= nil then
			Storage.SetNeighbor(s, packed // 4, packed % 4, other // 4)
		end
	end
end

-- The seam fragments of a tile input, by unordered grid-end key.
local function seamFragments(tc: { number }, te: { number }, ts: { number }): { [string]: number }
	local out = {}
	for k, seamId in ts do
		if seamId ~= 0 then
			local a, b = te[2 * k - 1], te[2 * k]
			local ka, kb = pointKey(tc[2 * a - 1], tc[2 * a]), pointKey(tc[2 * b - 1], tc[2 * b])
			out[if ka < kb then `{ka}:{kb}` else `{kb}:{ka}`] = seamId
		end
	end
	return out
end

-- A ring fed to snap rounding: its winding group, and a walkable ring's surface (whose creases
-- go in too).
type SourceRing = { Ring: Ring, Group: number, Surface: Surface? }
-- One tile's triangulation input: its min corner (grid units), then flat grid points, point
-- pairs, and a group and seam id (0 = none) per pair.
type TileInput = {
	X0: number,
	Z0: number,
	Coords: { number },
	Edges: { number },
	Groups: { number },
	Seams: { number },
}

-- Steps 3-4 (SR2, SR3): snap-rounds the rings, the creases of their surfaces, the seams and the
-- origin-aligned tile lines together, then clips it all to each tile. Returns the input of every
-- tile a walkable ring reaches, row by row, and the tile size (`tileSize` nil = adaptive).
-- `only` (flat tile min corners, grid units) limits which tiles get an input, and the tile
-- lines to the ones bounding them: no other line meets a pixel centred in those tiles.
--
-- Update calls this with only the rings and seams whose boxes come within a pixel of its dirty
-- tiles (SR14), and gets Build's input for them:
-- - Snap rounding routes a fragment only through hot pixels centred in its own box, and its ends
--   are such centres, so every fragment stays in its segment's box: a segment further than a
--   pixel from a tile never reaches it, however far rounding drifts.
-- - A hot pixel centred in a tile's closed rectangle is an endpoint or a crossing (marked in
--   one of at most two pixels) of segments within a pixel of the tile, so they are all given.
-- - The lines bounding a wanted tile are given, and span every given ring.
-- Creases are picked the same way, one segment at a time, so a non-planar ring's whole crease
-- fan isn't re-snapped for a change at one end of it.
local function tileInputs(
	sources: { SourceRing },
	seams: { FloorSeam },
	tileSize: number?,
	only: { number }?
): ({ TileInput }, number)
	-- Snap rounding, once (SR3): rings, creases and the tile grid lines together. Afterwards
	-- every ring crosses a tile line only at a snapped vertex on that line, so tiles can be cut
	-- apart without any new rounding.
	local coords, edges = {}, {}
	local ringFirstEdge, ringEdgeCount = {}, {}
	local ringOffset = {}
	-- Bounds of every ring, not just the walkable ones: the tile lines must span any place a
	-- ring can cross them, and obstacles or areas may reach past the walkable surface.
	local minX, minZ, maxX, maxZ = math.huge, math.huge, -math.huge, -math.huge
	for r, source in sources do
		local ring = source.Ring
		ringOffset[r] = #coords // 2
		for i = 1, #ring.X do
			table.insert(coords, ring.X[i])
			table.insert(coords, ring.Z[i])
			minX, maxX = math.min(minX, ring.X[i]), math.max(maxX, ring.X[i])
			minZ, maxZ = math.min(minZ, ring.Z[i]), math.max(maxZ, ring.Z[i])
		end
		table.insert(ringFirstEdge, #edges // 2 + 1)
		table.insert(ringEdgeCount, #ring.X)
		ringEdges(#ring.X, ringOffset[r], edges)
	end
	for _, seam in seams do
		minX, maxX = math.min(minX, seam.AX, seam.BX), math.max(maxX, seam.AX, seam.BX)
		minZ, maxZ = math.min(minZ, seam.AZ, seam.BZ), math.max(maxZ, seam.AZ, seam.BZ)
	end
	local size: number = tileSize or adaptiveTileSize((maxX - minX) * (maxZ - minZ) / (GRID * GRID), #edges // 2)
	-- With `only`: whether a box comes within a pixel of a wanted tile.
	local function wantedNear(bx0: number, bz0: number, bx1: number, bz1: number): boolean
		for k = 1, #(only :: { number }), 2 do
			local x0, z0 = (only :: { number })[k], (only :: { number })[k + 1]
			if bx0 <= x0 + size + 1 and x0 - 1 <= bx1 and bz0 <= z0 + size + 1 and z0 - 1 <= bz1 then
				return true
			end
		end
		return false
	end
	local creaseFirst = #edges // 2 + 1
	for r, source in sources do
		local surface = source.Surface
		if surface == nil or surface.Planar then
			continue
		end
		-- Creases: every interior diagonal of a non-planar ring's surface.
		local tri = surface.Tri
		for t = 1, CDT.TriangleCount(tri) do
			if CDT.GetWinding(tri, t, GROUP_WALKABLE) <= 0 then
				continue
			end
			local verts = { CDT.GetTriangle(tri, t) }
			for e = 1, 3 do
				local nb = CDT.GetNeighbor(tri, t, e)
				if nb > t and CDT.GetCoveringEdgeCount(tri, t, e) == 0 then
					local a = ringOffset[r] + (CDT.InputVertexOf(tri, verts[e % 3 + 1]) :: number)
					local b = ringOffset[r] + (CDT.InputVertexOf(tri, verts[(e + 1) % 3 + 1]) :: number)
					local ax, az, bx, bz = coords[2 * a - 1], coords[2 * a], coords[2 * b - 1], coords[2 * b]
					if
						only == nil
						or wantedNear(math.min(ax, bx), math.min(az, bz), math.max(ax, bx), math.max(az, bz))
					then
						table.insert(edges, a)
						table.insert(edges, b)
					end
				end
			end
		end
	end
	-- Seams: open constraints like creases, so each seam lines up with triangle edges (ticket 16).
	local seamOfEdge: { [number]: number } = {}
	for _, seam in seams do
		table.insert(coords, seam.AX)
		table.insert(coords, seam.AZ)
		table.insert(coords, seam.BX)
		table.insert(coords, seam.BZ)
		table.insert(edges, #coords // 2 - 1)
		table.insert(edges, #coords // 2)
		seamOfEdge[#edges // 2] = seam.Id
	end
	local creaseLast = #edges // 2
	-- The tile grid, aligned to the world origin, as full-length lines over the rings.
	local ix0, ix1 = math.floor(minX / size), math.ceil(maxX / size)
	local iz0, iz1 = math.floor(minZ / size), math.ceil(maxZ / size)
	-- The tiles to fill (by index), their index bounds, and the lines bounding them.
	local wanted: { [number]: boolean } = {}
	local lineX: { [number]: boolean } = {}
	local lineZ: { [number]: boolean } = {}
	local ti0, tj0, ti1, tj1 = ix0, iz0, ix1 - 1, iz1 - 1
	if only then
		ti0, tj0, ti1, tj1 = math.huge, math.huge, -math.huge, -math.huge
		for k = 1, #only, 2 do
			local i, j = only[k] // size, only[k + 1] // size
			wanted[pointKey(i, j)] = true
			lineX[i], lineX[i + 1], lineZ[j], lineZ[j + 1] = true, true, true, true
			ti0, tj0, ti1, tj1 = math.min(ti0, i), math.min(tj0, j), math.max(ti1, i), math.max(tj1, j)
		end
	end
	local function addLine(ax: number, az: number, bx: number, bz: number)
		table.insert(coords, ax)
		table.insert(coords, az)
		table.insert(coords, bx)
		table.insert(coords, bz)
		table.insert(edges, #coords // 2 - 1)
		table.insert(edges, #coords // 2)
	end
	for i = ix0, ix1 do
		if only == nil or lineX[i] then
			addLine(i * size, iz0 * size, i * size, iz1 * size)
		end
	end
	for j = iz0, iz1 do
		if only == nil or lineZ[j] then
			addLine(ix0 * size, j * size, ix1 * size, j * size)
		end
	end

	local snapped, fragments, source = Quantize.SnapRound(coords, edges)
	-- The fragments of one source edge are contiguous and in order along it.
	local fragFirst, fragLast = {}, {}
	for f, k in source do
		if fragFirst[k] == nil then
			fragFirst[k] = f
		end
		fragLast[k] = f
	end
	-- Each ring as its snapped closed chain (grid coordinates).
	local chainX, chainZ = {}, {}
	for r = 1, #sources do
		local xs, zs = {}, {}
		for k = ringFirstEdge[r], ringFirstEdge[r] + ringEdgeCount[r] - 1 do
			for f = fragFirst[k], fragLast[k] do
				local v = fragments[2 * f - 1]
				table.insert(xs, snapped[2 * v - 1])
				table.insert(zs, snapped[2 * v])
			end
		end
		chainX[r], chainZ[r] = xs, zs
	end
	-- Bucket each ring, crease fragment and on-line vertex into every tile its bounding box
	-- touches (closed rectangles), so each tile only looks at its own content.
	local columns = ix1 - ix0
	local tileRings: { [number]: { number } } = {}
	local tileCreases: { [number]: { number } } = {}
	local tileBorder: { [number]: { number } } = {}
	local function bucket(
		lists: { [number]: { number } },
		item: number,
		bx0: number,
		bz0: number,
		bx1: number,
		bz1: number
	)
		-- A bound on a tile line belongs to the tiles on both sides of it.
		local i0 = math.max(ti0, math.ceil(bx0 / size) - 1)
		local i1 = math.min(ti1, math.floor(bx1 / size))
		local j0 = math.max(tj0, math.ceil(bz0 / size) - 1)
		local j1 = math.min(tj1, math.floor(bz1 / size))
		for j = j0, j1 do
			for i = i0, i1 do
				local index = (j - iz0) * columns + (i - ix0) + 1
				local list = lists[index]
				if list == nil then
					list = {}
					lists[index] = list
				end
				table.insert(list, item)
			end
		end
	end
	for r = 1, #sources do
		local xs, zs = chainX[r], chainZ[r]
		local bx0, bz0, bx1, bz1 = math.huge, math.huge, -math.huge, -math.huge
		for i = 1, #xs do
			bx0, bx1 = math.min(bx0, xs[i]), math.max(bx1, xs[i])
			bz0, bz1 = math.min(bz0, zs[i]), math.max(bz1, zs[i])
		end
		bucket(tileRings, r, bx0, bz0, bx1, bz1)
	end
	for f = 1, #source do
		local k = source[f]
		if k >= creaseFirst and k <= creaseLast then
			local a, b = fragments[2 * f - 1], fragments[2 * f]
			local ax, az, bx, bz = snapped[2 * a - 1], snapped[2 * a], snapped[2 * b - 1], snapped[2 * b]
			bucket(tileCreases, f, math.min(ax, bx), math.min(az, bz), math.max(ax, bx), math.max(az, bz))
		end
	end
	-- Snapped vertices on any tile line: each tile adds those on its border, so both tiles on
	-- a shared border split it at the same points (no T-junctions).
	for v = 1, #snapped // 2 do
		local x, z = snapped[2 * v - 1], snapped[2 * v]
		if x % size == 0 or z % size == 0 then
			bucket(tileBorder, v, x, z, x, z)
		end
	end

	-- 4. Per tile: the clipped rings, creases, tile rectangle and border vertices.
	local inputs: { TileInput } = {}
	for tj = tj0, tj1 do
		for ti = ti0, ti1 do
			if only and not wanted[pointKey(ti, tj)] then
				continue
			end
			local x0, z0 = ti * size, tj * size
			local x1, z1 = x0 + size, z0 + size
			local tc, te, tg, ts = {}, {}, {}, {}
			local hasWalkable = false
			local function addPoints(xs: { number }, zs: { number }, group: number?)
				local offset = #tc // 2
				for i = 1, #xs do
					table.insert(tc, xs[i])
					table.insert(tc, zs[i])
				end
				if group ~= nil then
					ringEdges(#xs, offset, te)
					for _ = 1, #xs do
						table.insert(tg, group)
						table.insert(ts, 0)
					end
				end
			end
			local index = (tj - iz0) * columns + (ti - ix0) + 1
			for _, r in tileRings[index] or {} do
				local xs, zs = clipToRect(chainX[r], chainZ[r], x0, z0, x1, z1)
				if xs then
					hasWalkable = hasWalkable or sources[r].Group == GROUP_WALKABLE
					addPoints(xs, zs, sources[r].Group)
				end
			end
			if not hasWalkable then
				continue
			end
			for _, f in tileCreases[index] or {} do
				local a, b = fragments[2 * f - 1], fragments[2 * f]
				local mx, mz = (snapped[2 * a - 1] + snapped[2 * b - 1]) / 2, (snapped[2 * a] + snapped[2 * b]) / 2
				if x0 <= mx and mx <= x1 and z0 <= mz and mz <= z1 then
					addPoints({ snapped[2 * a - 1], snapped[2 * b - 1] }, { snapped[2 * a], snapped[2 * b] })
					table.insert(te, #tc // 2 - 1)
					table.insert(te, #tc // 2)
					table.insert(tg, GROUP_OPEN)
					table.insert(ts, seamOfEdge[source[f]] or 0)
				end
			end
			addPoints({ x0, x1, x1, x0 }, { z0, z0, z1, z1 }, GROUP_TILE)
			-- Sorted by position: snapped vertex ids depend on which rings went in, and the
			-- triangulator's order (so its choice among cocircular points) on its input's order.
			local border = {}
			for _, v in tileBorder[index] or {} do
				local x, z = snapped[2 * v - 1], snapped[2 * v]
				if x == x0 or x == x1 or z == z0 or z == z1 then
					table.insert(border, { x, z })
				end
			end
			table.sort(border, function(p: { number }, q: { number }): boolean
				return p[1] < q[1] or (p[1] == q[1] and p[2] < q[2])
			end)
			local borderX, borderZ = {}, {}
			for i, p in border do
				borderX[i], borderZ[i] = p[1], p[2]
			end
			addPoints(borderX, borderZ)
			table.insert(inputs, { X0 = x0, Z0 = z0, Coords = tc, Edges = te, Groups = tg, Seams = ts })
		end
	end
	return inputs, size
end

local function buildFloor(
	s: Storage.State,
	name: string,
	floor: FloorDesc,
	explicitTileSize: number?,
	seams: { FloorSeam },
	tolerance: number
)
	local floorContext = `floor '{name}'`
	if type(floor) ~= "table" or type(floor.Walkable) ~= "table" or #floor.Walkable == 0 then
		fail(floorContext, "needs at least one Walkable ring")
	end
	local defaultArea = if floor.Area == nil then 1 else checkArea(floor.Area, floorContext)

	-- 1. Quantize and validate.
	local walkable: { Ring } = {}
	for i, polygon in floor.Walkable do
		walkable[i] = walkableRing(polygon, `{floorContext} walkable ring {i}`, tolerance, seams)
	end
	local obstacles: { Ring } = {}
	for i, polygon in floor.Obstacles or {} do
		obstacles[i] = obstacleRing(polygon, `{floorContext} obstacle {i}`, tolerance, seams)
	end
	local areas: { Ring } = {}
	local areaIds: { number } = {}
	for i, areaDesc in floor.Areas or {} do
		local context = `{floorContext} area {i}`
		areas[i] = quantizeRing(areaDesc.Polygon, context)
		areaIds[i] = checkArea(areaDesc.Area, context)
	end

	-- 2. Height surfaces.
	local sources: { SourceRing } = {}
	local surfaces: { Surface } = {}
	for i, ring in walkable do
		surfaces[i] = makeSurface(ring)
		table.insert(sources, { Ring = ring, Group = GROUP_WALKABLE, Surface = surfaces[i] })
	end
	for _, ring in obstacles do
		table.insert(sources, { Ring = ring, Group = GROUP_OBSTACLE })
	end
	for i, ring in areas do
		table.insert(sources, { Ring = ring, Group = GROUP_FIRST_AREA + i - 1 })
	end

	-- 3-4. Snap rounding and the tile inputs.
	local inputs, tileSize = tileInputs(sources, seams, explicitTileSize, nil)

	-- 5-6. Per tile: triangulate, keep, heights, copy out.
	local floorId = Storage.InsertFloor(s, name)
	local rings, groups = {}, {}
	for i, source in sources do
		rings[i], groups[i] = source.Ring, source.Group
	end
	Storage.SetFloorSources(s, floorId, tileSize, defaultArea, areaIds, rings, groups)
	local floorData: FloorData = {
		Context = floorContext,
		Surfaces = surfaces,
		TileSize = tileSize,
		AreaIds = areaIds,
		DefaultArea = defaultArea,
		Heights = {},
		HeightFrom = {},
	}
	local meshVertex: { [number]: number } = {} -- grid point key -> mesh vertex (interned per floor)
	local openEdges: { [number]: number } = {} -- directed edge key -> triangle * 4 + edge
	for _, input in inputs do
		local tc, te, tg, ts = input.Coords, input.Edges, input.Groups, input.Seams
		local triangles = triangulateTile(tc, te, tg, floorData)
		if #triangles == 0 then
			continue
		end
		local x0, z0 = input.X0, input.Z0
		local tile =
			Storage.InsertTile(s, floorId, x0 / GRID, z0 / GRID, (x0 + tileSize) / GRID, (z0 + tileSize) / GRID)
		copyOut(s, floorContext, tile, triangles, floorData.Heights, meshVertex, openEdges, seamFragments(tc, te, ts))
	end

	linkOpenEdges(s, openEdges)
end

-- The ends of edge e of triangle t.
local function edgeEnds(s: Storage.State, t: number, e: number): (vector, vector)
	local verts = { Storage.GetTriangle(s, t) }
	return Storage.GetVertex(s, verts[e % 3 + 1]), Storage.GetVertex(s, verts[(e + 1) % 3 + 1])
end

-- Does the seam from (ax, az) to (bx, bz) (grid units) lie on one of the floor's authored
-- walkable rings: is a point a pixel to either side of its middle inside one (even-odd)?
local function onWalkable(s: Storage.State, floor: number, ax: number, az: number, bx: number, bz: number): boolean
	local len = math.sqrt((bx - ax) ^ 2 + (bz - az) ^ 2)
	local mx, mz, nx, nz = (ax + bx) / 2, (az + bz) / 2, (az - bz) / len, (bx - ax) / len
	local _, _, _, rings, groups = Storage.GetFloorSources(s, floor)
	for r, ring in rings do
		if groups[r] ~= GROUP_WALKABLE then
			continue
		end
		for _, side in { 1, -1 } do
			local x, z, odd = mx + nx * side, mz + nz * side, false
			for i = 1, #ring.X do
				local j = i % #ring.X + 1
				local px, pz, qx, qz = ring.X[i], ring.Z[i], ring.X[j], ring.Z[j]
				if (pz > z) ~= (qz > z) and x < px + (z - pz) / (qz - pz) * (qx - px) then
					odd = not odd
				end
			end
			if odd then
				return true
			end
		end
	end
	return false
end

-- Joins two floors across seam `id` (ruling: overlap portals). Every piece on floor A pairs
-- with every piece on floor B that overlaps it along the seam and whose triangle lies on the
-- other side of it, so walking across leads onto the other floor. Each pairing is a portal in
-- both directions, on the crossing triangle's own edge. Seam edges without a neighbour become
-- open (walkable, not walls).
--
-- Obstacles can cut a seam away on a floor (a crate at a ramp's foot): then it is closed where
-- cut, or wholly (no portals). A seam that never lay on a floor, or whose floors meet it on the
-- same side, is an authoring error.
local function joinSeam(s: Storage.State, id: number, a: { SeamPiece }?, b: { SeamPiece }?)
	local context = `seam {id}`
	local floorA, floorB, ax, az, bx, bz = Storage.GetSeam(s, id)
	local desc = { FloorA = Storage.GetFloorName(s, floorA), FloorB = Storage.GetFloorName(s, floorB) }
	if a == nil or b == nil then
		local floor = if a == nil then floorA else floorB
		if onWalkable(s, floor, ax, az, bx, bz) then
			return -- cut away by obstacles: closed
		end
		fail(context, `does not lie on floor '{Storage.GetFloorName(s, floor)}'`)
	end
	local sx, sz = ax / GRID, az / GRID
	local dx, dz = bx / GRID - sx, bz / GRID - sz
	local len2 = dx * dx + dz * dz
	local function param(p: vector): number
		return ((p.X - sx) * dx + (p.Z - sz) * dz) / len2
	end
	local function side(t: number): number
		local verts = { Storage.GetTriangle(s, t) }
		local cx, cz = 0, 0
		for _, v in verts do
			local p = Storage.GetVertex(s, v)
			cx += p.X / 3
			cz += p.Z / 3
		end
		return if dx * (cz - sz) - dz * (cx - sx) > 0 then 1 else -1
	end
	-- The portal crossing out of piece p, over the seam interval [t0, t1] (left, right).
	local function portal(piece: SeamPiece, t0: number, t1: number): (vector, vector)
		local u, v = edgeEnds(s, piece.Tri, piece.Edge)
		local tu, tv = param(u), param(v)
		local function at(t: number): vector
			return u + (v - u) * ((t - tu) / (tv - tu))
		end
		-- Crossing out of a CCW triangle, the edge's second end is on the left.
		if tu < tv then
			return at(t1), at(t0)
		end
		return at(t0), at(t1)
	end
	local joined, overlapped = 0, false
	for _, pa in a :: { SeamPiece } do
		local ua, va = edgeEnds(s, pa.Tri, pa.Edge)
		local a0, a1 = math.min(param(ua), param(va)), math.max(param(ua), param(va))
		local sideA = side(pa.Tri)
		for _, pb in b :: { SeamPiece } do
			local ub, vb = edgeEnds(s, pb.Tri, pb.Edge)
			local t0 = math.max(a0, math.min(param(ub), param(vb)))
			local t1 = math.min(a1, math.max(param(ub), param(vb)))
			if t1 - t0 <= 1e-9 then
				continue
			end
			overlapped = true
			if side(pb.Tri) == sideA then
				continue
			end
			local leftA, rightA = portal(pa, t0, t1)
			local leftB, rightB = portal(pb, t0, t1)
			-- The same seam point on both floors: leftA meets rightB, rightA meets leftB.
			if math.abs(leftA.Y - rightB.Y) > HEIGHT_TOLERANCE or math.abs(rightA.Y - leftB.Y) > HEIGHT_TOLERANCE then
				fail(
					context,
					`floors '{desc.FloorA}' and '{desc.FloorB}' are at different heights along it near ({fmt(leftA.X)}, {fmt(
						leftA.Z
					)})`
				)
			end
			Storage.AddExtra(s, pa.Tri, pb.Tri, Storage.EXTRA_SEAM, pa.Edge, leftA, rightA)
			Storage.AddExtra(s, pb.Tri, pa.Tri, Storage.EXTRA_SEAM, pb.Edge, leftB, rightB)
			for _, piece in { pa, pb } do
				if Storage.GetNeighbor(s, piece.Tri, piece.Edge) == 0 then
					Storage.SetEdgeOpen(s, piece.Tri, piece.Edge)
				end
			end
			joined += 1
		end
	end
	-- Nothing paired: an error only if both floors keep the whole seam (so they are on one side).
	-- Pieces overlapping but none across: the floors are on one side of the seam. None
	-- overlapping: obstacles cut them apart, so the seam is closed.
	if joined == 0 and overlapped then
		fail(context, `floors '{desc.FloorA}' and '{desc.FloorB}' don't meet across it`)
	end
end

local LINK_EXTENTS = vector.create(0.5, 4, 0.5)

-- Checks link description `link` (`context` names it in errors). Returns its two points, its
-- cost (nil = the default, the 3D distance between its snapped ends), area, label ("" = none),
-- whether it runs both ways, and its name ("" = none).
local function checkLink(link: any, context: string): (vector, vector, number?, number, string, boolean, string)
	if type(link) ~= "table" then
		fail(context, "must be a table")
	end
	local ends = {}
	for k, field in { "From", "To" } do
		local p = link[field]
		if typeof(p) ~= "Vector3" and type(p) ~= "vector" then
			fail(context, `{field} must be a Vector3`)
		end
		ends[k] = vector.create(p.X, p.Y, p.Z)
	end
	local cost = link.Cost
	if cost ~= nil and (type(cost) ~= "number" or not (cost >= 0 and cost < math.huge)) then
		fail(context, "Cost must be a finite number >= 0")
	end
	local area = if link.Area == nil then 1 else checkArea(link.Area, context)
	local label = link.Label
	if label ~= nil and type(label) ~= "string" then
		fail(context, "Label must be a string")
	end
	local both = link.Bidirectional
	if both ~= nil and type(both) ~= "boolean" then
		fail(context, "Bidirectional must be a boolean")
	end
	local name = link.Name
	if name ~= nil and type(name) ~= "string" then
		fail(context, "Name must be a string")
	end
	return ends[1], ends[2], cost, area, label or "", both ~= false, name or ""
end

-- Snaps link point `p` (field `field` of the link `context` names) onto the mesh: its triangle
-- and snapped point. Errors when it is not on the mesh.
local function snapLinkEnd(s: Storage.State, p: vector, field: string, context: string): (number, vector)
	local t, snapped = Snap.Snap(s, p, LINK_EXTENTS, {})
	if snapped == nil then
		fail(context, `{field} ({fmt(p.X)}, {fmt(p.Y)}, {fmt(p.Z)}) is not on the mesh`)
	end
	return t, snapped :: vector
end

-- Snaps and records link `id` of the description.
local function addLink(s: Storage.State, id: number, link: any)
	local context = `link {id}`
	local fromP, toP, cost, area, label, both, name = checkLink(link, context)
	local fromTri, from = snapLinkEnd(s, fromP, "From", context)
	local toTri, to = snapLinkEnd(s, toP, "To", context)
	Storage.InsertLink(s, fromTri, from, toTri, to, cost or vector.magnitude(to - from), area, label, both, name)
end

-- (Re)builds every extra link: seam portals from the stored seam pieces, then links from their
-- stored ends. A link end snapped off the mesh (by an obstacle, after an Update) leaves that
-- link out until it is back on the mesh.
local function connect(s: Storage.State)
	Storage.ClearExtras(s)
	local bySeam: { [number]: { [number]: { SeamPiece } } } = {}
	for piece = 1, Storage.PieceCount(s) do
		local seam, tri, edge = Storage.GetPiece(s, piece)
		local floor = Storage.GetTriangleFloor(s, tri)
		local lists = bySeam[seam] or {}
		bySeam[seam] = lists
		local list = lists[floor] or {}
		lists[floor] = list
		table.insert(list, { Tri = tri, Edge = edge })
	end
	for seam = 1, Storage.SeamCount(s) do
		local floorA, floorB = Storage.GetSeam(s, seam)
		local lists = bySeam[seam] or {}
		joinSeam(s, seam, lists[floorA], lists[floorB])
	end
	for id = 1, Storage.LinkCount(s) do
		local fromTri, from, toTri, to, _, _, _, both = Storage.GetLink(s, id)
		if fromTri ~= 0 and toTri ~= 0 then
			Storage.AddExtra(s, fromTri, toTri, Storage.EXTRA_LINK, id, from, to)
			if both then
				Storage.AddExtra(s, toTri, fromTri, Storage.EXTRA_LINK, id, to, from)
			end
		end
	end
end

local Build = {}

--[=[
	Builds mesh state from a description. Errors, with a message naming the floor and ring, on
	an authoring mistake.
]=]
function Build.Build(desc: NavMeshDesc): Storage.State
	if type(desc) ~= "table" or type(desc.Floors) ~= "table" then
		error("NavMesh.Build: the description needs a Floors table", 2)
	end
	local names = {}
	for name in desc.Floors do
		if type(name) ~= "string" then
			error("NavMesh.Build: floor names must be strings", 2)
		end
		table.insert(names, name)
	end
	if #names == 0 then
		error("NavMesh.Build: the description has no floors", 2)
	end
	-- Seams, quantized, and grouped by the floors they join.
	local seamDescs: { Types.SeamDesc } = desc.Seams or {}
	local floorSeams: { [string]: { FloorSeam } } = {}
	local seamRecords: { FloorSeam } = {}
	for i, seam in seamDescs do
		local context = `seam {i}`
		if type(seam) ~= "table" then
			fail(context, "must be a table")
		end
		for _, field in { "FloorA", "FloorB" } do
			local floorName = seam[field]
			if type(floorName) ~= "string" or desc.Floors[floorName] == nil then
				fail(context, `{field} '{floorName}' is not a floor of this description`)
			end
		end
		if seam.FloorA == seam.FloorB then
			fail(context, "joins a floor to itself")
		end
		local ends = {}
		for _, field in { "From", "To" } do
			local p = seam[field]
			if typeof(p) ~= "Vector3" and type(p) ~= "vector" then
				fail(context, `{field} must be a Vector3`)
			end
			if not (math.abs(p.X) <= LIMIT and math.abs(p.Z) <= LIMIT) then
				fail(context, `{field} is outside the supported range of ±{LIMIT} studs`)
			end
			table.insert(ends, Quantize.ToGrid(p.X))
			table.insert(ends, Quantize.ToGrid(p.Z))
		end
		if ends[1] == ends[3] and ends[2] == ends[4] then
			fail(context, "has zero length on the 1/256-stud grid")
		end
		local record = { Id = i, AX = ends[1], AZ = ends[2], BX = ends[3], BZ = ends[4] }
		seamRecords[i] = record
		for _, floorName in { seam.FloorA, seam.FloorB } do
			local list = floorSeams[floorName] or {}
			floorSeams[floorName] = list
			table.insert(list, record)
		end
	end
	local tileStuds = desc.TileSize
	if tileStuds ~= nil and (type(tileStuds) ~= "number" or not (tileStuds >= 1 / GRID and tileStuds <= LIMIT)) then
		error(`NavMesh.Build: TileSize must be a number of studs from 1/{GRID} to {LIMIT}, got {tileStuds}`, 2)
	end
	local cap = desc.MaxAgentRadius
	if cap == nil then
		cap = DEFAULT_MAX_AGENT_RADIUS
	elseif type(cap) ~= "number" or not (cap > 0 and (cap <= LIMIT or cap == math.huge)) then
		error(`NavMesh.Build: MaxAgentRadius must be a number of studs above 0, got {cap}`, 2)
	end
	local tolerance = desc.SimplifyTolerance
	if tolerance == nil then
		tolerance = DEFAULT_SIMPLIFY_TOLERANCE
	elseif type(tolerance) ~= "number" or not (tolerance >= 0 and tolerance <= LIMIT) then
		error(`NavMesh.Build: SimplifyTolerance must be a number of studs from 0 to {LIMIT}, got {tolerance}`, 2)
	end
	table.sort(names)
	local s = Storage.New()
	Storage.SetSimplifyTolerance(s, tolerance)
	local floorIds: { [string]: number } = {}
	for _, name in names do
		buildFloor(
			s,
			name,
			desc.Floors[name],
			if tileStuds == nil then nil else Quantize.ToGrid(tileStuds),
			floorSeams[name] or {},
			tolerance
		)
		floorIds[name] = Storage.FloorCount(s)
	end
	for i, seam in seamDescs do
		local record = seamRecords[i]
		Storage.InsertSeam(s, floorIds[seam.FloorA], floorIds[seam.FloorB], record.AX, record.AZ, record.BX, record.BZ)
	end
	local linkDescs: { Types.LinkDesc } = desc.Links or {}
	for i, link in linkDescs do
		addLink(s, i, link)
	end
	connect(s)
	Clearance.Compute(s, if cap == math.huge then 0 else cap) -- 0 = uncapped
	return s
end

-- The pieces `Update` (Tiles.luau) reuses, so a rebuilt tile goes through exactly Build's steps.
Build.Internal = {
	GRID = GRID,
	Dissolve = DISSOLVE,
	GROUP_WALKABLE = GROUP_WALKABLE,
	GROUP_OBSTACLE = GROUP_OBSTACLE,
	EDGE_KEY = EDGE_KEY,
	Fail = fail,
	Fmt = fmt,
	ObstacleRing = obstacleRing,
	MakeSurface = makeSurface,
	TileInputs = tileInputs,
	TriangulateTile = triangulateTile,
	CopyOut = copyOut,
	LinkOpenEdges = linkOpenEdges,
	SeamFragments = seamFragments,
	ClipToRect = clipToRect,
	PointKey = pointKey,
	Connect = connect,
	CheckLink = checkLink,
	SnapLinkEnd = snapLinkEnd,
}

return Build
