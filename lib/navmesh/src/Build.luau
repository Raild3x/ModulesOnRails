--!strict
--!native
-- Authors: Logan Hunt (Raildex)
-- September 25, 2026
--[=[
	@class NavMeshBuild
	@private

	`NavMesh.Build`: authored description → mesh state (spec "Build" steps 1-5).

	Per floor (one tile per floor until tiling lands):
	1. Quantize every ring to the grid, validate it, and orient it CCW.
	2. Triangulate each walkable ring on its own. That is the ring's height surface (SR6). A
	   non-planar ring's diagonals become open (group 0) constraints, which keeps its creases.
	3. Snap-round walkable (1), obstacle (2), tile (3) and area (4+) rings together with the
	   diagonals (SR2), then run one `CDT.Triangulate`.
	4. Keep a triangle iff walkable > 0, obstacle == 0 and tile > 0. Its area is the last area
	   group it lies in, otherwise the floor's default.
	5. Take heights from the walkable ring surfaces, check that overlapping rings agree, and
	   copy out through Storage with the degeneracy guard.
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
-- (px, pz). Returns nil when that point is outside the surface's hull; `inside` says whether
-- it is inside the ring.
local function surfaceHeights(
	surface: Surface,
	px: number,
	pz: number,
	x1: number,
	z1: number,
	x2: number,
	z2: number,
	x3: number,
	z3: number
): (number?, number, number, boolean)
	local tri = surface.Tri
	local t = CDT.Locate(tri, px, pz)
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

local function buildFloor(s: Storage.State, name: string, floor: FloorDesc)
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

	-- 3. Constraints, snap rounding, triangulation.
	local coords, edges, groups = {}, {}, {}
	local function addRing(ring: Ring, group: number): number
		local offset = #coords // 2
		for i = 1, #ring.X do
			table.insert(coords, ring.X[i])
			table.insert(coords, ring.Z[i])
		end
		local before = #edges // 2
		ringEdges(#ring.X, offset, edges)
		for _ = before + 1, #edges // 2 do
			table.insert(groups, group)
		end
		return offset
	end
	local minX, minZ, maxX, maxZ = math.huge, math.huge, -math.huge, -math.huge
	local walkableOffsets = {}
	for i, ring in walkable do
		walkableOffsets[i] = addRing(ring, GROUP_WALKABLE)
		for k = 1, #ring.X do
			minX, maxX = math.min(minX, ring.X[k]), math.max(maxX, ring.X[k])
			minZ, maxZ = math.min(minZ, ring.Z[k]), math.max(maxZ, ring.Z[k])
		end
	end
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
					table.insert(groups, GROUP_OPEN)
				end
			end
		end
	end
	for _, ring in obstacles do
		addRing(ring, GROUP_OBSTACLE)
	end
	addRing({ X = { minX, maxX, maxX, minX }, Z = { minZ, minZ, maxZ, maxZ }, Y = {} }, GROUP_TILE)
	for i, ring in areas do
		addRing(ring, GROUP_FIRST_AREA + i - 1)
	end

	local snapped, fragments, source = Quantize.SnapRound(coords, edges)
	local fragmentGroups = table.create(#source)
	for f, k in source do
		fragmentGroups[f] = groups[k]
	end
	local tri = CDT.Triangulate { Coords = snapped, Edges = fragments, EdgeGroups = fragmentGroups }
	for v = 1, CDT.VertexCount(tri) do
		if CDT.InputVertexOf(tri, v) == nil then
			fail(floorContext, "internal error: the triangulator added a vertex, so snap rounding missed a crossing")
		end
	end

	-- 4. Keep rule and areas.
	local kept: { number } = {}
	local keptArea: { number } = {}
	for t = 1, CDT.TriangleCount(tri) do
		if
			CDT.GetWinding(tri, t, GROUP_WALKABLE) > 0
			and CDT.GetWinding(tri, t, GROUP_OBSTACLE) == 0
			and CDT.GetWinding(tri, t, GROUP_TILE) > 0
		then
			local area = defaultArea
			for i = #areas, 1, -1 do
				if CDT.GetWinding(tri, t, GROUP_FIRST_AREA + i - 1) > 0 then
					area = areaIds[i]
					break
				end
			end
			table.insert(kept, t)
			table.insert(keptArea, area)
		end
	end

	-- 5. Heights. Each kept triangle takes its heights from the first walkable surface that
	-- contains it. Every other surface containing it must agree, and so must every triangle
	-- sharing a vertex (a step inside one floor is an error).
	local vertexHeight: { [number]: number } = {}
	local vertexFrom: { [number]: number } = {}
	for _, t in kept do
		local a, b, c = CDT.GetTriangle(tri, t)
		local ax, az = CDT.GetVertex(tri, a)
		local bx, bz = CDT.GetVertex(tri, b)
		local cx, cz = CDT.GetVertex(tri, c)
		local px, pz = (ax + bx + cx) / 3, (az + bz + cz) / 3
		local h1, h2, h3, from = nil :: number?, 0, 0, 0
		local fallback: number? = nil
		for i, surface in surfaces do
			local s1, s2, s3, inside = surfaceHeights(surface, px, pz, ax, az, bx, bz, cx, cz)
			if s1 == nil then
				continue
			end
			if not inside then
				fallback = fallback or i
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
			-- A sliver whose centre snapped just outside every ring: extend the nearest surface.
			-- ponytail: first surface whose hull contains it; a snapped sliver is always within
			-- half a grid pixel of a ring.
			local surface = surfaces[fallback or 1]
			h1, h2, h3 = surfaceHeights(surface, px, pz, ax, az, bx, bz, cx, cz)
			if h1 == nil then
				h1, h2, h3 = surface.Ring.Y[1], surface.Ring.Y[1], surface.Ring.Y[1]
			end
			from = fallback or 1
		end
		for k, v in { a, b, c } do
			local h = if k == 1 then h1 :: number elseif k == 2 then h2 else h3
			local previous = vertexHeight[v]
			if previous == nil then
				vertexHeight[v] = h
				vertexFrom[v] = from
			elseif math.abs(previous - h) > HEIGHT_TOLERANCE then
				local vx, vz = CDT.GetVertex(tri, v)
				fail(
					floorContext,
					`walkable rings {vertexFrom[v]} and {from} meet at different heights at ({fmt(vx / GRID)}, {fmt(
						vz / GRID
					)}); split them into separate floors joined by a seam`
				)
			end
		end
	end
	-- Copy out.
	local floorId = Storage.InsertFloor(s, name)
	local tile = Storage.InsertTile(s, floorId, minX / GRID, minZ / GRID, maxX / GRID, maxZ / GRID)
	local first = Storage.AllocTileRange(s, tile, #kept)
	local meshVertex: { [number]: number } = {}
	local meshTriangle: { [number]: number } = {}
	for i, t in kept do
		meshTriangle[t] = first + i - 1
	end
	for i, t in kept do
		local id = first + i - 1
		local a, b, c = CDT.GetTriangle(tri, t)
		local ids = {}
		for k, v in { a, b, c } do
			local m = meshVertex[v]
			if m == nil then
				local gx, gz = CDT.GetVertex(tri, v)
				m = Storage.AddVertex(s, vector.create(gx / GRID, vertexHeight[v], gz / GRID))
				meshVertex[v] = m
			end
			ids[k] = m
		end
		Storage.SetTriangle(s, id, ids[1], ids[2], ids[3])
		Storage.SetTriangleArea(s, id, keptArea[i])
		for e = 1, 3 do
			Storage.SetNeighbor(s, id, e, meshTriangle[CDT.GetNeighbor(tri, t, e)] or 0)
		end
		-- Degeneracy guard (SR2): CCW with positive area in stored coordinates.
		local pa, pb, pc = Storage.GetVertex(s, ids[1]), Storage.GetVertex(s, ids[2]), Storage.GetVertex(s, ids[3])
		if Orient2D(pa.X, pa.Z, pb.X, pb.Z, pc.X, pc.Z) <= 0 then
			fail(floorContext, `a triangle degenerates after quantization near ({fmt(pa.X)}, {fmt(pa.Z)})`)
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
	table.sort(names)
	local s = Storage.New()
	for _, name in names do
		buildFloor(s, name, desc.Floors[name])
	end
	return s
end

return Build
