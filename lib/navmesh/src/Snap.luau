--!strict
--!native
-- Authors: Logan Hunt (Raildex)
-- September 27, 2026
--[=[
	@class NavMeshSnap
	@private

	The single snap step every query uses (R6, U-b): a **feet** position onto the mesh.

	Candidates are triangles whose closest (X, Z) point lies inside the extents box and whose
	surface height there is within the vertical extent. A floor is one surface, so each floor
	offers one candidate: the triangle under the point's column if there is one, otherwise the
	nearest in (X, Z). Across floors the nearest by vertical distance wins, and ties go below.
	Triangles in an excluded area (cost `math.huge`) are never candidates.
]=]

local Storage = require("./Storage")

local Snap = {}

-- The point of CCW triangle (a, b, c) nearest to (px, pz) in (X, Z), and the surface height
-- there. Returns (x, z, height).
local function closest(a: vector, b: vector, c: vector, px: number, pz: number): (number, number, number)
	local ax, az, bx, bz, cx, cz = a.X, a.Z, b.X, b.Z, c.X, c.Z
	local wa = (bx - px) * (cz - pz) - (bz - pz) * (cx - px)
	local wb = (cx - px) * (az - pz) - (cz - pz) * (ax - px)
	local wc = (ax - px) * (bz - pz) - (az - pz) * (bx - px)
	local x, z = px, pz
	if wa < 0 or wb < 0 or wc < 0 then
		-- Outside: the nearest point lies on one of the three edges.
		local best = math.huge
		for k = 1, 3 do
			local p, q = if k == 1 then a elseif k == 2 then b else c, if k == 1 then b elseif k == 2 then c else a
			local dx, dz = q.X - p.X, q.Z - p.Z
			local u = math.clamp(((px - p.X) * dx + (pz - p.Z) * dz) / (dx * dx + dz * dz), 0, 1)
			local ex, ez = p.X + u * dx, p.Z + u * dz
			local d = (ex - px) ^ 2 + (ez - pz) ^ 2
			if d < best then
				best, x, z = d, ex, ez
			end
		end
		wa = (bx - x) * (cz - z) - (bz - z) * (cx - x)
		wb = (cx - x) * (az - z) - (cz - z) * (ax - x)
		wc = (ax - x) * (bz - z) - (az - z) * (bx - x)
	end
	return x, z, (wa * a.Y + wb * b.Y + wc * c.Y) / (wa + wb + wc)
end

--[=[
	@within NavMeshSnap
	Snaps feet position `p` within half-size `extents`. Returns the triangle and the snapped
	point on its surface, or `0, nil` when nothing is in range.
]=]
function Snap.Snap(s: Storage.State, p: vector, extents: vector, costs: { [number]: number }): (number, vector?)
	local px, py, pz = p.X, p.Y, p.Z
	local ex, ey, ez = extents.X, extents.Y, extents.Z
	-- Per floor: the best triangle so far, its squared (X, Z) offset, and its snapped point.
	local floorTri: { [number]: number } = {}
	local floorOff: { [number]: number } = {}
	local floorDy: { [number]: number } = {}
	local floorPoint: { [number]: vector } = {}
	-- ponytail: scans every tile's bounds, O(tiles) per snap; a tile grid lookup when that shows up.
	for tile = 1, Storage.TileCount(s) do
		local x0, z0, x1, z1 = Storage.GetTileBounds(s, tile)
		if x1 < px - ex or x0 > px + ex or z1 < pz - ez or z0 > pz + ez then
			continue
		end
		local first, count = Storage.GetTileRange(s, tile)
		for t = first, first + count - 1 do
			if (costs[Storage.GetTriangleArea(s, t)] or 1) == math.huge then
				continue
			end
			local ia, ib, ic = Storage.GetTriangle(s, t)
			local a, b, c = Storage.GetVertex(s, ia), Storage.GetVertex(s, ib), Storage.GetVertex(s, ic)
			local x, z, h = closest(a, b, c, px, pz)
			local dy = h - py
			if math.abs(x - px) > ex or math.abs(z - pz) > ez or math.abs(dy) > ey then
				continue
			end
			local off = (x - px) ^ 2 + (z - pz) ^ 2
			local floor = Storage.GetTriangleFloor(s, t)
			local held = floorOff[floor]
			if held == nil or off < held or (off == held and math.abs(dy) < math.abs(floorDy[floor])) then
				floorTri[floor], floorOff[floor], floorDy[floor] = t, off, dy
				floorPoint[floor] = vector.create(x, h, z)
			end
		end
	end
	local bestFloor, bestDy = 0, math.huge
	for floor, dy in floorDy do
		local ad, ab = math.abs(dy), math.abs(bestDy)
		if ad < ab or (ad == ab and (dy < bestDy or (dy == bestDy and floor < bestFloor))) then
			bestFloor, bestDy = floor, dy
		end
	end
	if bestFloor == 0 then
		return 0, nil
	end
	return floorTri[bestFloor], floorPoint[bestFloor]
end

--[=[
	@within NavMeshSnap
	The point of triangle `t` nearest to `p` in (X, Z), on the triangle's surface.
]=]
function Snap.ClosestOnTriangle(s: Storage.State, t: number, p: vector): vector
	local ia, ib, ic = Storage.GetTriangle(s, t)
	local x, z, h = closest(Storage.GetVertex(s, ia), Storage.GetVertex(s, ib), Storage.GetVertex(s, ic), p.X, p.Z)
	return vector.create(x, h, z)
end

return Snap
