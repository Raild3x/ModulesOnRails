--!strict
--!native
-- Authors: Logan Hunt (Raildex)
-- September 27, 2026
--[=[
	@class NavMeshQueries
	@private

	The spatial queries besides `FindPath` (ticket 17): a straight walk over the surface, sliding
	movement, the nearest wall, and random points. All work in (X, Z) on the mesh surface and
	take heights from the triangle they end in. Walls are `Storage.IsWallEdge` edges. Seam
	portals are crossed like neighbours; links are not taken.
]=]

local Snap = require("./Snap")
local Storage = require("./Storage")

local Queries = {}

local WALK_LIMIT = 100000 -- triangle steps per walk, a guard against a broken mesh
local SLIDES = 4

local function cross2(ax: number, az: number, bx: number, bz: number): number
	return ax * bz - az * bx
end

-- The triangle across edge e of t for a point at `hit` on that edge: the neighbour, or the
-- seam portal holding it, or 0 (a wall, or an excluded area).
local function across(s: Storage.State, t: number, e: number, hit: vector, costs: { [number]: number }): number
	local n = Storage.GetNeighbor(s, t, e)
	if n == 0 and Storage.IsEdgeOpen(s, t, e) then
		local id = Storage.GetExtraHead(s, t)
		while id ~= 0 do
			local nextId, target, kind, ref, a, b = Storage.GetExtra(s, id)
			if kind == Storage.EXTRA_SEAM and ref == e then
				local dx, dz = b.X - a.X, b.Z - a.Z
				local u = ((hit.X - a.X) * dx + (hit.Z - a.Z) * dz) / (dx * dx + dz * dz)
				if u >= -1e-9 and u <= 1 + 1e-9 then
					n = target
					break
				end
			end
			id = nextId
		end
	end
	if n ~= 0 and (costs[Storage.GetTriangleArea(s, n)] or 1) == math.huge then
		return 0
	end
	return n
end

--[=[
	@within NavMeshQueries
	Walks straight from `p` (on triangle `t`) towards `to` in (X, Z). Returns whether a wall or
	an excluded area stopped it, the point it stopped at (on the surface), the triangle, and the
	wall edge's direction (unit, X/Z) when blocked.
]=]
function Queries.Walk(
	s: Storage.State,
	t: number,
	p: vector,
	to: vector,
	costs: { [number]: number }
): (boolean, vector, number, vector?)
	local dx, dz = to.X - p.X, to.Z - p.Z
	local from = -1 -- the edge of t we entered through (never an exit)
	for _ = 1, WALK_LIMIT do
		local verts = { Storage.GetTriangle(s, t) }
		local P = { Storage.GetVertex(s, verts[1]), Storage.GetVertex(s, verts[2]), Storage.GetVertex(s, verts[3]) }
		-- The edge the ray leaves through: the nearest crossing among edges it heads out of.
		local exit, exitAt = 0, math.huge
		for e = 1, 3 do
			if e == from then
				continue
			end
			local u, w = P[e % 3 + 1], P[(e + 1) % 3 + 1]
			local ex, ez = w.X - u.X, w.Z - u.Z
			local denom = cross2(ex, ez, dx, dz)
			-- Leaving a CCW triangle, the ray crosses the edge from its left to its right.
			if denom >= 0 then
				continue -- parallel, or heading into the triangle across this edge
			end
			-- Ray p + k (dx, dz) meets the edge line at k = cross(e, u - p) / cross(e, d).
			local k = cross2(ex, ez, u.X - p.X, u.Z - p.Z) / denom
			if k < exitAt then
				exit, exitAt = e, k
			end
		end
		if exit == 0 or exitAt >= 1 then
			return false, Snap.ClosestOnTriangle(s, t, to), t, nil
		end
		local hit = Snap.ClosestOnTriangle(s, t, vector.create(p.X + exitAt * dx, 0, p.Z + exitAt * dz))
		local n = across(s, t, exit, hit, costs)
		if n == 0 then
			local u, w = P[exit % 3 + 1], P[(exit + 1) % 3 + 1]
			local wall = vector.create(w.X - u.X, 0, w.Z - u.Z)
			return true, hit, t, wall / vector.magnitude(wall)
		end
		-- Enter n through the edge that leads back to t (none for a seam portal).
		from = if Storage.GetNeighbor(s, n, 1) == t
			then 1
			elseif Storage.GetNeighbor(s, n, 2) == t then 2
			elseif Storage.GetNeighbor(s, n, 3) == t then 3
			else -1
		t = n
	end
	error("NavMesh: a surface walk did not terminate", 3)
end

--[=[
	@within NavMeshQueries
	The nearest wall to point `p` (on triangle `t`) within `maxRadius`, searching outwards over
	reachable triangles. Returns (distance, hit point, normal pointing away from the wall), or
	(maxRadius, nil, nil).
]=]
function Queries.DistanceToWall(
	s: Storage.State,
	t: number,
	p: vector,
	maxRadius: number,
	costs: { [number]: number }
): (number, vector?, vector?)
	local best, bestHit, bestNormal = maxRadius, nil :: vector?, nil :: vector?
	local seen = { [t] = true }
	local queue = { t }
	local head = 1
	local function segmentPoint(u: vector, w: vector): (vector, number)
		local ex, ez = w.X - u.X, w.Z - u.Z
		local k = math.clamp(((p.X - u.X) * ex + (p.Z - u.Z) * ez) / (ex * ex + ez * ez), 0, 1)
		local q = u + (w - u) * k
		return q, math.sqrt((q.X - p.X) ^ 2 + (q.Z - p.Z) ^ 2)
	end
	while head <= #queue do
		local tri = queue[head]
		head += 1
		local verts = { Storage.GetTriangle(s, tri) }
		for e = 1, 3 do
			local u, w = Storage.GetVertex(s, verts[e % 3 + 1]), Storage.GetVertex(s, verts[(e + 1) % 3 + 1])
			local q, d = segmentPoint(u, w)
			if d >= best then
				continue -- nothing past this edge can be nearer
			end
			local n = if Storage.IsWallEdge(s, tri, e) then 0 else across(s, tri, e, q, costs)
			if n == 0 then
				-- A wall (or an excluded area's border): the nearest so far.
				local normal = vector.create(p.X - q.X, 0, p.Z - q.Z)
				if d < 1e-9 then
					-- On the wall: its inward normal (CCW triangle: the interior is on the left).
					normal = vector.create(-(w.Z - u.Z), 0, w.X - u.X)
				end
				best, bestHit, bestNormal = d, q, normal / vector.magnitude(normal)
			elseif not seen[n] then
				seen[n] = true
				table.insert(queue, n)
			end
		end
	end
	return best, bestHit, bestNormal
end

--[=[
	@within NavMeshQueries
	Moves from `p` (on triangle `t`) towards `to`, sliding along walls, then keeps the result
	`radius` from the nearest wall where the mesh allows. Returns the point and its triangle.
]=]
function Queries.Move(
	s: Storage.State,
	t: number,
	p: vector,
	to: vector,
	radius: number,
	costs: { [number]: number }
): (vector, number)
	local target = to
	for _ = 1, SLIDES do
		local blocked, stop, at, wall = Queries.Walk(s, t, p, target, costs)
		t = at
		if not blocked then
			p = stop
			break
		end
		-- Stop just short of the wall, then slide what is left of the move along it.
		local step = vector.create(stop.X - p.X, 0, stop.Z - p.Z)
		local length = vector.magnitude(step)
		p = if length > 1e-6 then Snap.ClosestOnTriangle(s, t, stop - step / length * 1e-4) else p
		local w = wall :: vector
		local rest = vector.create(target.X - p.X, 0, target.Z - p.Z)
		local along = rest.X * w.X + rest.Z * w.Z
		if math.abs(along) < 1e-6 then
			break
		end
		target = vector.create(p.X + w.X * along, target.Y, p.Z + w.Z * along)
	end
	if radius > 0 then
		-- Keep the agent's radius from the nearest wall, without walking through another.
		for _ = 1, 2 do
			local d, _, normal = Queries.DistanceToWall(s, t, p, radius, costs)
			if normal == nil or d >= radius then
				break
			end
			local push = vector.create(p.X + normal.X * (radius - d), p.Y, p.Z + normal.Z * (radius - d))
			local _, stop, at = Queries.Walk(s, t, p, push, costs)
			p, t = stop, at
		end
	end
	return p, t
end

--[=[
	@within NavMeshQueries
	A random point on the mesh, uniform in plan (X, Z) over triangles not excluded by `costs`
	and, when `center` is given, within `radius` of it in plan. `rng` returns [0, 1). Returns the
	point and its triangle, or nil when nothing qualifies.
]=]
function Queries.RandomPoint(
	s: Storage.State,
	costs: { [number]: number },
	center: vector?,
	radius: number,
	rng: () -> number
): (vector?, number)
	local candidates, cumulative = {}, {}
	local total = 0
	for t = 1, Storage.TriangleCount(s) do
		if (costs[Storage.GetTriangleArea(s, t)] or 1) == math.huge then
			continue
		end
		local a, b, c = Storage.GetTriangle(s, t)
		local pa, pb, pc = Storage.GetVertex(s, a), Storage.GetVertex(s, b), Storage.GetVertex(s, c)
		if center then
			local near = Snap.ClosestOnTriangle(s, t, center)
			if (near.X - center.X) ^ 2 + (near.Z - center.Z) ^ 2 > radius * radius then
				continue
			end
		end
		total += cross2(pb.X - pa.X, pb.Z - pa.Z, pc.X - pa.X, pc.Z - pa.Z) * 0.5
		table.insert(candidates, t)
		table.insert(cumulative, total)
	end
	if #candidates == 0 then
		return nil, 0
	end
	-- ponytail: rejection sampling for the circle, 32 tries; a clipped-triangle sampler if that misses.
	for _ = 1, 32 do
		local pick = rng() * total
		local lo, hi = 1, #candidates
		while lo < hi do
			local mid = (lo + hi) // 2
			if cumulative[mid] <= pick then
				lo = mid + 1
			else
				hi = mid
			end
		end
		local t = candidates[lo]
		local a, b, c = Storage.GetTriangle(s, t)
		local pa, pb, pc = Storage.GetVertex(s, a), Storage.GetVertex(s, b), Storage.GetVertex(s, c)
		local r1, r2 = math.sqrt(rng()), rng()
		local p = pa * (1 - r1) + pb * (r1 * (1 - r2)) + pc * (r1 * r2)
		if center == nil or (p.X - center.X) ^ 2 + (p.Z - center.Z) ^ 2 <= radius * radius then
			return p, t
		end
	end
	return nil, 0
end

return Queries
