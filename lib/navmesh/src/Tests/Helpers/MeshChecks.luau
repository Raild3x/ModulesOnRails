-- Authors: Logan Hunt (Raildex)
-- September 25, 2026
-- Independent checks over built mesh state, for the NavMesh specs. Reads go through Storage
-- accessors only (never raw fields), so a layout swap keeps these valid. Each check returns a
-- list of violations; empty means it holds.

local Storage = require("../../Storage")
local CDT = require("../../../ConstrainedDelaunay")

local Orient2D = CDT.Orient2D

local MeshChecks = {}

local function edgeVerts(mesh: any, t: number, e: number): (number, number)
	local verts = { Storage.GetTriangle(mesh, t) }
	return verts[e % 3 + 1], verts[(e + 1) % 3 + 1]
end

--[=[
	Every triangle is CCW with positive area in stored (X, Z), and neighbours are symmetric:
	each neighbour points back across the same edge, with the edge's vertices reversed.
]=]
function MeshChecks.Structure(mesh: any): { string }
	local found = {}
	for t = 1, Storage.TriangleCount(mesh) do
		local a, b, c = Storage.GetTriangle(mesh, t)
		local pa, pb, pc = Storage.GetVertex(mesh, a), Storage.GetVertex(mesh, b), Storage.GetVertex(mesh, c)
		if Orient2D(pa.X, pa.Z, pb.X, pb.Z, pc.X, pc.Z) <= 0 then
			table.insert(found, `triangle {t} is not CCW`)
		end
		for e = 1, 3 do
			local n = Storage.GetNeighbor(mesh, t, e)
			if n == 0 then
				continue
			end
			local p, q = edgeVerts(mesh, t, e)
			local back = false
			for e2 = 1, 3 do
				if Storage.GetNeighbor(mesh, n, e2) == t then
					local p2, q2 = edgeVerts(mesh, n, e2)
					back = p2 == q and q2 == p
				end
			end
			if not back then
				table.insert(found, `triangle {t} edge {e}: neighbour {n} does not point back across the same edge`)
			end
		end
	end
	return found
end

-- Even-odd point in polygon.
function MeshChecks.Inside(ring: { any }, x: number, z: number): boolean
	local inside = false
	local n = #ring
	for i = 1, n do
		local p, q = ring[i], ring[i % n + 1]
		if (p.Z > z) ~= (q.Z > z) and x < p.X + (z - p.Z) * (q.X - p.X) / (q.Z - p.Z) then
			inside = not inside
		end
	end
	return inside
end

-- Distance from (x, z) to the ring's boundary.
function MeshChecks.EdgeDistance(ring: { any }, x: number, z: number): number
	local best = math.huge
	local n = #ring
	for i = 1, n do
		local p, q = ring[i], ring[i % n + 1]
		local dx, dz = q.X - p.X, q.Z - p.Z
		local len2 = dx * dx + dz * dz
		local s = if len2 > 0 then math.clamp(((x - p.X) * dx + (z - p.Z) * dz) / len2, 0, 1) else 0
		local ex, ez = p.X + s * dx - x, p.Z + s * dz - z
		best = math.min(best, math.sqrt(ex * ex + ez * ez))
	end
	return best
end

-- Whether the point is in walkable minus obstacles, and its distance to any of their edges.
local function classify(floor: any, x: number, z: number): (boolean, number)
	local near = math.huge
	local walk = false
	for _, ring in floor.Walkable do
		walk = walk or MeshChecks.Inside(ring, x, z)
		near = math.min(near, MeshChecks.EdgeDistance(ring, x, z))
	end
	local blocked = false
	for _, ring in floor.Obstacles or {} do
		blocked = blocked or MeshChecks.Inside(ring, x, z)
		near = math.min(near, MeshChecks.EdgeDistance(ring, x, z))
	end
	return walk and not blocked, near
end

--[=[
	The kept region matches the authored one (walkable rings minus obstacles), away from ring
	edges by more than `tolerance` (snapping moves edges by up to half a grid pixel), one-sided
	by `eps` (the ring simplification tolerance, G1/G2; default 0):
	- every triangle's centroid is inside it (kept within the region);
	- every sample point on a `step` lattice that is inside it, further than `eps` from its
	  edges, lies in some triangle of `floor` (the region eroded by eps within the kept one).
]=]
function MeshChecks.Region(
	mesh: any,
	floorId: number,
	floor: any,
	tolerance: number,
	step: number,
	eps: number?
): { string }
	local found = {}
	local minX, minZ, maxX, maxZ = math.huge, math.huge, -math.huge, -math.huge
	local tris = {}
	for t = 1, Storage.TriangleCount(mesh) do
		if Storage.GetTriangleFloor(mesh, t) ~= floorId then
			continue
		end
		local a, b, c = Storage.GetTriangle(mesh, t)
		local pa, pb, pc = Storage.GetVertex(mesh, a), Storage.GetVertex(mesh, b), Storage.GetVertex(mesh, c)
		table.insert(tris, { pa, pb, pc })
		local cx, cz = (pa.X + pb.X + pc.X) / 3, (pa.Z + pb.Z + pc.Z) / 3
		local keep, near = classify(floor, cx, cz)
		if not keep and near > tolerance then
			table.insert(found, `triangle {t} centroid ({cx}, {cz}) is outside the walkable region`)
		end
	end
	for _, ring in floor.Walkable do
		for _, p in ring do
			minX, maxX = math.min(minX, p.X), math.max(maxX, p.X)
			minZ, maxZ = math.min(minZ, p.Z), math.max(maxZ, p.Z)
		end
	end
	for x = minX + step / 2, maxX, step do
		for z = minZ + step / 2, maxZ, step do
			local keep, near = classify(floor, x, z)
			if not keep or near <= tolerance + (eps or 0) then
				continue
			end
			local covered = false
			for _, tri in tris do
				local pa, pb, pc = tri[1], tri[2], tri[3]
				if
					Orient2D(pa.X, pa.Z, pb.X, pb.Z, x, z) >= 0
					and Orient2D(pb.X, pb.Z, pc.X, pc.Z, x, z) >= 0
					and Orient2D(pc.X, pc.Z, pa.X, pa.Z, x, z) >= 0
				then
					covered = true
					break
				end
			end
			if not covered then
				table.insert(found, `walkable point ({x}, {z}) is not covered by any triangle`)
			end
		end
	end
	return found
end

--[=[
	Every wall (an edge with no neighbour) lies on an authored walkable or obstacle edge, within
	`tolerance` plus `eps` (the ring simplification tolerance; default 0). A tile border left
	unlinked, or split differently on its two sides (a T-junction), shows up as a wall off every
	authored edge.
]=]
function MeshChecks.Walls(mesh: any, floorId: number, floor: any, tolerance: number, eps: number?): { string }
	local found = {}
	local rings = table.clone(floor.Walkable)
	for _, ring in floor.Obstacles or {} do
		table.insert(rings, ring)
	end
	for t = 1, Storage.TriangleCount(mesh) do
		if Storage.GetTriangleFloor(mesh, t) ~= floorId then
			continue
		end
		for e = 1, 3 do
			if Storage.GetNeighbor(mesh, t, e) ~= 0 then
				continue
			end
			local a, b = edgeVerts(mesh, t, e)
			local pa, pb = Storage.GetVertex(mesh, a), Storage.GetVertex(mesh, b)
			for _, fraction in { 0.25, 0.5, 0.75 } do
				local x, z = pa.X + (pb.X - pa.X) * fraction, pa.Z + (pb.Z - pa.Z) * fraction
				local best = math.huge
				for _, ring in rings do
					best = math.min(best, MeshChecks.EdgeDistance(ring, x, z))
				end
				if best > tolerance + (eps or 0) then
					table.insert(found, `triangle {t} edge {e} is a wall off every authored edge near ({x}, {z})`)
					break
				end
			end
		end
	end
	return found
end

--[=[
	Every triangle lies within its tile's bounds.
]=]
function MeshChecks.InTiles(mesh: any): { string }
	local found = {}
	for t = 1, Storage.TriangleCount(mesh) do
		local x0, z0, x1, z1 = Storage.GetTileBounds(mesh, Storage.GetTriangleTile(mesh, t))
		for _, v in { Storage.GetTriangle(mesh, t) } do
			local p = Storage.GetVertex(mesh, v)
			if p.X < x0 or p.X > x1 or p.Z < z0 or p.Z > z1 then
				table.insert(found, `triangle {t} leaves its tile at ({p.X}, {p.Z})`)
			end
		end
	end
	return found
end

return MeshChecks
