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
local Quantize = require("./Quantize")
local Storage = require("./Storage")
local Types = require("./Types")

type Polygon = Types.Polygon
type FloorDesc = Types.FloorDesc
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

local function quantizeRing(polygon: Polygon, context: string): Ring
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
	-- pinch a thin neck into a false error. A ring that folds back on itself counts too.
	for i = 1, n do
		local p, q, r = (i - 2) % n + 1, i, i % n + 1
		if
			Orient2D(xs[p], zs[p], xs[q], zs[q], xs[r], zs[r]) == 0
			and (xs[q] - xs[p]) * (xs[r] - xs[q]) + (zs[q] - zs[p]) * (zs[r] - zs[q]) < 0
		then
			fail(context, `the ring folds back on itself at point {i} ({fmt(xs[q] / GRID)}, {fmt(zs[q] / GRID)})`)
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
				fail(context, `the ring intersects itself (edges {i} and {j})`)
			end
		end
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

	-- Planar iff every point lies on the plane through the first three non-collinear points.
	local planar = true
	for k = 3, n do
		local det = (xs[2] - xs[1]) * (zs[k] - zs[1]) - (xs[k] - xs[1]) * (zs[2] - zs[1])
		if det ~= 0 then
			for i = 1, n do
				local w2 = ((xs[i] - xs[1]) * (zs[k] - zs[1]) - (xs[k] - xs[1]) * (zs[i] - zs[1])) / det
				local w3 = ((xs[2] - xs[1]) * (zs[i] - zs[1]) - (xs[i] - xs[1]) * (zs[2] - zs[1])) / det
				local h = ys[1] + w2 * (ys[2] - ys[1]) + w3 * (ys[k] - ys[1])
				if math.abs(h - ys[i]) > PLANAR_TOLERANCE then
					planar = false
				end
			end
			break
		end
	end
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

local function buildFloor(s: Storage.State, name: string, floor: FloorDesc, explicitTileSize: number?)
	local floorContext = `floor '{name}'`
	if type(floor) ~= "table" or type(floor.Walkable) ~= "table" or #floor.Walkable == 0 then
		fail(floorContext, "needs at least one Walkable ring")
	end
	local defaultArea = if floor.Area == nil then 1 else checkArea(floor.Area, floorContext)

	-- 1. Quantize and validate.
	local walkable: { Ring } = {}
	for i, polygon in floor.Walkable do
		walkable[i] = quantizeRing(polygon, `{floorContext} walkable ring {i}`)
	end
	local obstacles: { Ring } = {}
	for i, polygon in floor.Obstacles or {} do
		obstacles[i] = quantizeRing(polygon, `{floorContext} obstacle {i}`)
	end
	local areas: { Ring } = {}
	local areaIds: { number } = {}
	for i, areaDesc in floor.Areas or {} do
		local context = `{floorContext} area {i}`
		areas[i] = quantizeRing(areaDesc.Polygon, context)
		areaIds[i] = checkArea(areaDesc.Area, context)
	end

	-- 2. Height surfaces.
	local surfaces: { Surface } = {}
	for i, ring in walkable do
		surfaces[i] = makeSurface(ring)
	end

	-- 3. Snap rounding, once per floor (SR3): rings, creases and the tile grid lines together.
	-- Afterwards every ring crosses a tile line only at a snapped vertex on that line, so tiles
	-- can be cut apart without any new rounding.
	local coords, edges = {}, {}
	local ringFirstEdge, ringEdgeCount, ringGroup = {}, {}, {}
	-- Bounds of every ring, not just the walkable ones: the tile lines must span any place a
	-- ring can cross them, and obstacles or areas may reach past the walkable surface.
	local minX, minZ, maxX, maxZ = math.huge, math.huge, -math.huge, -math.huge
	local function addRing(ring: Ring, group: number): number
		local offset = #coords // 2
		for i = 1, #ring.X do
			table.insert(coords, ring.X[i])
			table.insert(coords, ring.Z[i])
			minX, maxX = math.min(minX, ring.X[i]), math.max(maxX, ring.X[i])
			minZ, maxZ = math.min(minZ, ring.Z[i]), math.max(maxZ, ring.Z[i])
		end
		table.insert(ringFirstEdge, #edges // 2 + 1)
		table.insert(ringEdgeCount, #ring.X)
		table.insert(ringGroup, group)
		ringEdges(#ring.X, offset, edges)
		return offset
	end
	local walkableOffsets = {}
	for i, ring in walkable do
		walkableOffsets[i] = addRing(ring, GROUP_WALKABLE)
	end
	for _, ring in obstacles do
		addRing(ring, GROUP_OBSTACLE)
	end
	for i, ring in areas do
		addRing(ring, GROUP_FIRST_AREA + i - 1)
	end
	local tileSize: number = explicitTileSize
		or adaptiveTileSize((maxX - minX) * (maxZ - minZ) / (GRID * GRID), #edges // 2)
	local creaseFirst = #edges // 2 + 1
	for i, surface in surfaces do
		if surface.Planar then
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
					table.insert(edges, walkableOffsets[i] + (CDT.InputVertexOf(tri, verts[e % 3 + 1]) :: number))
					table.insert(edges, walkableOffsets[i] + (CDT.InputVertexOf(tri, verts[(e + 1) % 3 + 1]) :: number))
				end
			end
		end
	end
	local creaseLast = #edges // 2
	-- The tile grid, aligned to the world origin, as full-length lines over the floor.
	local ix0, ix1 = math.floor(minX / tileSize), math.ceil(maxX / tileSize)
	local iz0, iz1 = math.floor(minZ / tileSize), math.ceil(maxZ / tileSize)
	local function addLine(ax: number, az: number, bx: number, bz: number)
		table.insert(coords, ax)
		table.insert(coords, az)
		table.insert(coords, bx)
		table.insert(coords, bz)
		table.insert(edges, #coords // 2 - 1)
		table.insert(edges, #coords // 2)
	end
	for i = ix0, ix1 do
		addLine(i * tileSize, iz0 * tileSize, i * tileSize, iz1 * tileSize)
	end
	for j = iz0, iz1 do
		addLine(ix0 * tileSize, j * tileSize, ix1 * tileSize, j * tileSize)
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
	for r = 1, #ringGroup do
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
		local i0 = math.max(ix0, math.ceil(bx0 / tileSize) - 1)
		local i1 = math.min(ix1 - 1, math.floor(bx1 / tileSize))
		local j0 = math.max(iz0, math.ceil(bz0 / tileSize) - 1)
		local j1 = math.min(iz1 - 1, math.floor(bz1 / tileSize))
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
	for r = 1, #ringGroup do
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
		if x % tileSize == 0 or z % tileSize == 0 then
			bucket(tileBorder, v, x, z, x, z)
		end
	end

	-- 4-5. Per tile: triangulate, keep, heights, copy out.
	local floorId = Storage.InsertFloor(s, name)
	local vertexHeight: { [number]: number } = {} -- by grid point key
	local vertexFrom: { [number]: number } = {}
	local meshVertex: { [number]: number } = {} -- grid point key -> mesh vertex (interned per floor)
	local openEdges: { [number]: number } = {} -- directed edge key -> triangle * 4 + edge
	for tj = iz0, iz1 - 1 do
		for ti = ix0, ix1 - 1 do
			local x0, z0 = ti * tileSize, tj * tileSize
			local x1, z1 = x0 + tileSize, z0 + tileSize
			local tc, te, tg = {}, {}, {}
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
					end
				end
			end
			local index = (tj - iz0) * columns + (ti - ix0) + 1
			for _, r in tileRings[index] or {} do
				local xs, zs = clipToRect(chainX[r], chainZ[r], x0, z0, x1, z1)
				if xs then
					hasWalkable = hasWalkable or ringGroup[r] == GROUP_WALKABLE
					addPoints(xs, zs, ringGroup[r])
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
				end
			end
			addPoints({ x0, x1, x1, x0 }, { z0, z0, z1, z1 }, GROUP_TILE)
			local borderX, borderZ = {}, {}
			for _, v in tileBorder[index] or {} do
				local x, z = snapped[2 * v - 1], snapped[2 * v]
				if x == x0 or x == x1 or z == z0 or z == z1 then
					table.insert(borderX, x)
					table.insert(borderZ, z)
				end
			end
			addPoints(borderX, borderZ)

			local tri = CDT.Triangulate { Coords = tc, Edges = te, EdgeGroups = tg }
			for v = 1, CDT.VertexCount(tri) do
				if CDT.InputVertexOf(tri, v) == nil then
					fail(
						floorContext,
						"internal error: the triangulator added a vertex, so snap rounding missed a crossing"
					)
				end
			end

			-- Keep rule and areas.
			local kept: { number } = {}
			local keptArea: { number } = {}
			-- A tile only has the area groups up to the highest one clipped into it.
			local lastArea = math.min(#areas, CDT.GroupCount(tri) - GROUP_FIRST_AREA + 1)
			for t = 1, CDT.TriangleCount(tri) do
				if
					CDT.GetWinding(tri, t, GROUP_WALKABLE) > 0
					and CDT.GetWinding(tri, t, GROUP_OBSTACLE) == 0
					and CDT.GetWinding(tri, t, GROUP_TILE) > 0
				then
					local area = defaultArea
					for i = lastArea, 1, -1 do
						if CDT.GetWinding(tri, t, GROUP_FIRST_AREA + i - 1) > 0 then
							area = areaIds[i]
							break
						end
					end
					table.insert(kept, t)
					table.insert(keptArea, area)
				end
			end
			if #kept == 0 then
				continue
			end

			-- Heights. Each kept triangle takes its heights from the first walkable surface that
			-- contains it. Every other surface containing it must agree, and so must every
			-- triangle sharing a vertex, in any tile (a step inside one floor is an error).
			for _, t in kept do
				local a, b, c = CDT.GetTriangle(tri, t)
				local ax, az = CDT.GetVertex(tri, a)
				local bx, bz = CDT.GetVertex(tri, b)
				local cx, cz = CDT.GetVertex(tri, c)
				local px, pz = (ax + bx + cx) / 3, (az + bz + cz) / 3
				local h1, h2, h3, from = nil :: number?, 0, 0, 0
				for i, surface in surfaces do
					local s1, s2, s3, inside = surfaceHeights(surface, px, pz, ax, az, bx, bz, cx, cz)
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
					-- A sliver whose centre snapped just outside every ring (by under half a
					-- grid pixel): extend the plane of the nearest inside surface triangle.
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

			-- Copy out. Vertices are interned per floor by grid point, so a shared border's
			-- vertices are the same mesh vertices on both sides.
			local tile = Storage.InsertTile(s, floorId, x0 / GRID, z0 / GRID, x1 / GRID, z1 / GRID)
			local first = Storage.AllocTileRange(s, tile, #kept)
			local meshTriangle: { [number]: number } = {}
			for i, t in kept do
				meshTriangle[t] = first + i - 1
			end
			for i, t in kept do
				local id = first + i - 1
				local ids = {}
				for k, v in { CDT.GetTriangle(tri, t) } do
					local gx, gz = CDT.GetVertex(tri, v)
					local key = pointKey(gx, gz)
					local m = meshVertex[key]
					if m == nil then
						m = Storage.AddVertex(s, vector.create(gx / GRID, vertexHeight[key], gz / GRID))
						meshVertex[key] = m
					end
					ids[k] = m
				end
				Storage.SetTriangle(s, id, ids[1], ids[2], ids[3])
				Storage.SetTriangleArea(s, id, keptArea[i])
				for e = 1, 3 do
					local n = meshTriangle[CDT.GetNeighbor(tri, t, e)] or 0
					Storage.SetNeighbor(s, id, e, n)
					if n == 0 then
						openEdges[ids[e % 3 + 1] * EDGE_KEY + ids[(e + 1) % 3 + 1]] = id * 4 + e
					end
				end
				-- Degeneracy guard (SR2): CCW with positive area in stored coordinates.
				local pa, pb, pc =
					Storage.GetVertex(s, ids[1]), Storage.GetVertex(s, ids[2]), Storage.GetVertex(s, ids[3])
				if Orient2D(pa.X, pa.Z, pb.X, pb.Z, pc.X, pc.Z) <= 0 then
					fail(floorContext, `a triangle degenerates after quantization near ({fmt(pa.X)}, {fmt(pa.Z)})`)
				end
			end
		end
	end

	-- Cross-tile adjacency: an open edge meets the reversed open edge of the next tile.
	for key, packed in openEdges do
		local other = openEdges[(key % EDGE_KEY) * EDGE_KEY + key // EDGE_KEY]
		if other ~= nil then
			Storage.SetNeighbor(s, packed // 4, packed % 4, other // 4)
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
	for _, field in { "Seams", "Links" } do
		local value = (desc :: any)[field]
		if value ~= nil and next(value) ~= nil then
			error(`NavMesh.Build: {field} are not implemented yet`, 2)
		end
	end
	local tileStuds = desc.TileSize
	if tileStuds ~= nil and (type(tileStuds) ~= "number" or not (tileStuds >= 1 / GRID and tileStuds <= LIMIT)) then
		error(`NavMesh.Build: TileSize must be a number of studs from 1/{GRID} to {LIMIT}, got {tileStuds}`, 2)
	end
	table.sort(names)
	local s = Storage.New()
	for _, name in names do
		buildFloor(s, name, desc.Floors[name], if tileStuds == nil then nil else Quantize.ToGrid(tileStuds))
	end
	return s
end

return Build
