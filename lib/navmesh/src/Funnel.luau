--!strict
--!native
-- Authors: Logan Hunt (Raildex)
-- September 27, 2026
--[=[
	@class NavMeshFunnel
	@private

	String-pulls a triangle corridor into the shortest path through it in (X, Z): the "simple
	stupid funnel" (Mononen). Corners are mesh vertices, so they keep their heights.

	**Drape (ticket 25):** where a straight stretch crosses a crease or a seam, a point on the
	surface is added, as few as keep a height lerped between consecutive points within 0.01
	studs of the surface. A flat floor gets none.

	**Area costs (ticket 25, weighted):** with `AreaCosts`, the path is pinned on each portal
	where the multiplier changes, and each pin slides along its portal to where the path through
	it costs least, which bends it at the border by Snell's law. The funnel pulls each run
	between pins straight, which is exact inside one multiplier. Without that, the funnel ignored
	costs: it could cut back across the mud the search went round. Against a weighted reference
	(4,350 routes) the mean excess cost went from 4.3% to 2.2% and the worst from 3.09x to
	1.99x; the rest comes from the corridor the search picks.

	**Agent radius (SR4):** each portal end that is a wall vertex is moved along the portal,
	towards its other end, by min(r, half the portal's length). Free-space vertices (tile, area,
	seam) are not offset, but a vertex that is a wall vertex on any floor meeting there is: the
	corner where a seam meets a wall, even on a floor that only meets the walled one at that
	vertex.

	That is the whole guarantee: where the path crosses a portal ending at a wall corner, it
	crosses at least that far from the corner, measured along the portal. It is not a distance
	to the walls:
	- the offset runs along the portal, not away from the wall, so at a crossing the path can be
	  as close as r sin(a) to a wall edge leaving the corner at angle a to the portal;
	- between crossings the straight segment is not offset at all, and can cut past a corner.
	No fixed fraction of r holds on every mesh. The measured worst clearance over random paths
	(ends at least 2r from walls) was 0.23-0.71 r on the Courtyard fixture and 0.06-0.11 r on
	the bench `walls` scene. In 79-100% of paths that worst point is within 1.5 r of a turn,
	where the portal runs nearly parallel to a wall (ticket 25). Whether an agent fits is
	decided by the search's clearance widths (SR4); the offset only keeps turns off the corners.
	Moving portal ends off their edge (a bisector offset) was measured and rejected, because it
	bends the corridor through walls. A radius-aware funnel is ticket 32.
]=]

local CDT = require("../ConstrainedDelaunay")
local Storage = require("./Storage")

local Funnel = {}

-- > 0 when c is left of a -> b in (X, Z) (the same sign as Storage's CCW triangles).
local function orient(a: vector, b: vector, c: vector): number
	return (b.X - a.X) * (c.Z - a.Z) - (b.Z - a.Z) * (c.X - a.X)
end

-- The simple stupid funnel over one run of portals (lefts[1] = rights[1] = the start, the last
-- pair = the end), then without exactly zero-turn corners. Returns the points and, for each,
-- the triangle it was taken from and the portal it lies on.
local function pull(lefts: { vector }, rights: { vector }, owners: { number }): ({ vector }, { number }, { number })
	local startP, endP = lefts[1], lefts[#lefts]
	local points, from, at = { startP }, { owners[1] }, { 1 }
	local apex, left, right = startP, startP, startP
	local apexI, leftI, rightI = 1, 1, 1
	local i = 2
	while i <= #lefts do
		local l, r = lefts[i], rights[i]
		-- Narrow the right side, unless it would cross the left (then the left is a corner). An
		-- unchanged endpoint only advances its index: with the apex on a portal (a snapped end on
		-- an edge) the funnel is flat, and its zero orientation would read as a crossing.
		if r == right then
			rightI = i
		elseif orient(apex, right, r) >= 0 then
			-- A side still at the apex can't be crossed: the other side may move freely.
			if apex == right or apex == left or orient(apex, left, r) < 0 then
				right, rightI = r, i
			else
				table.insert(points, left)
				table.insert(from, owners[leftI])
				table.insert(at, leftI)
				apex, apexI = left, leftI
				right, rightI = apex, apexI
				i = apexI + 1
				continue
			end
		end
		-- Narrow the left side, unless it would cross the right.
		if l == left then
			leftI = i
		elseif orient(apex, left, l) <= 0 then
			if apex == left or apex == right or orient(apex, right, l) > 0 then
				left, leftI = l, i
			else
				table.insert(points, right)
				table.insert(from, owners[rightI])
				table.insert(at, rightI)
				apex, apexI = right, rightI
				left, leftI = apex, apexI
				i = apexI + 1
				continue
			end
		end
		i += 1
	end
	if points[#points] ~= endP then
		table.insert(points, endP)
		table.insert(from, owners[#owners])
		table.insert(at, #lefts)
	end
	-- A line that grazes a vertex exactly leaves a zero-turn corner there: drop it (exact test).
	local kept, keptFrom, keptAt = { points[1] }, { from[1] }, { at[1] }
	for k = 2, #points - 1 do
		local a, q, c = kept[#kept], points[k], points[k + 1]
		if CDT.Orient2D(a.X, a.Z, q.X, q.Z, c.X, c.Z) ~= 0 then
			table.insert(kept, q)
			table.insert(keptFrom, from[k])
			table.insert(keptAt, at[k])
		end
	end
	if #points > 1 then
		table.insert(kept, points[#points])
		table.insert(keptFrom, from[#points])
		table.insert(keptAt, at[#points])
	end
	return kept, keptFrom, keptAt
end

-- How far (studs) a height lerped between two waypoints may stray from the surface.
local DRAPE = 0.01

-- Adds the surface points `drape` needs between the funnel's points: where a straight segment
-- crosses a portal between differently sloped triangles (a crease) or floors (a seam), so a
-- height lerped between consecutive waypoints stays within DRAPE of the surface. Portal ends
-- lie on the shared edge, so a crossing's height is exact; between crossings the surface and
-- the lerp are both linear, so checking at crossings is enough. A sleeve of allowed slopes from
-- the last kept point (as the funnel does in plan) keeps the fewest points, in one pass.
local function drape(
	lefts: { vector },
	rights: { vector },
	owners: { number },
	points: { vector },
	from: { number },
	at: { number }
): ({ vector }, { number })
	local out, outFrom = { points[1] }, { from[1] }
	for k = 1, #points - 1 do
		local p, q = points[k], points[k + 1]
		local dx, dz = q.X - p.X, q.Z - p.Z
		local length = math.sqrt(dx * dx + dz * dz)
		-- The sleeve from the anchor: its point, its distance along p-q, and the slope bounds.
		local anchor, anchorU = p, 0
		local lo, hi = -math.huge, math.huge
		local last, lastOwner, lastU = p, from[k], 0
		for i = at[k] + 1, at[k + 1] do
			local c, owner, u
			if i == at[k + 1] then
				c, owner, u = q, from[k + 1], 1
			else
				local l, r = lefts[i], rights[i]
				local ex, ez = r.X - l.X, r.Z - l.Z
				local denom = ex * dz - ez * dx
				if l == r and length > 0 then
					-- A pinned portal (see `refract`) the segment runs straight through.
					c, owner = l, owners[i]
					u = math.clamp(((l.X - p.X) * dx + (l.Z - p.Z) * dz) / (length * length), 0, 1)
				elseif denom == 0 then
					continue -- the segment runs along this portal: its ends are on it
				else
					local wx, wz = p.X - l.X, p.Z - l.Z
					local s = math.clamp((wx * dz - wz * dx) / denom, 0, 1)
					u = math.clamp((wx * ez - wz * ex) / denom, 0, 1)
					c, owner = vector.create(p.X + dx * u, l.Y + (r.Y - l.Y) * s, p.Z + dz * u), owners[i]
				end
			end
			local d = (u - anchorU) * length
			if d > 0 then
				local slope = (c.Y - anchor.Y) / d
				if slope < lo or slope > hi then
					-- c can't be reached in a straight lerp: the last crossing becomes a waypoint.
					table.insert(out, last)
					table.insert(outFrom, lastOwner)
					anchor, anchorU = last, lastU
					lo, hi = -math.huge, math.huge
					d = (u - anchorU) * length
				end
				lo = math.max(lo, (c.Y - DRAPE - anchor.Y) / d)
				hi = math.min(hi, (c.Y + DRAPE - anchor.Y) / d)
				last, lastOwner, lastU = c, owner, u
			end
		end
		table.insert(out, q)
		table.insert(outFrom, from[k + 1])
	end
	return out, outFrom
end

-- The point of segment a-b, as a fraction, minimising m1 |p - x| + m2 |x - q| (convex): golden
-- section to 1e-9 of the segment.
local PHI = (math.sqrt(5) - 1) / 2
local function snell(a: vector, b: vector, p: vector, q: vector, m1: number, m2: number): number
	local function f(u: number): number
		local x, z = a.X + (b.X - a.X) * u, a.Z + (b.Z - a.Z) * u
		return m1 * math.sqrt((x - p.X) ^ 2 + (z - p.Z) ^ 2) + m2 * math.sqrt((q.X - x) ^ 2 + (q.Z - z) ^ 2)
	end
	local lo, hi = 0, 1
	local x1, x2 = hi - PHI, PHI
	local f1, f2 = f(x1), f(x2)
	while hi - lo > 1e-9 do
		if f1 <= f2 then
			hi, x2, f2 = x2, x1, f1
			x1 = hi - PHI * (hi - lo)
			f1 = f(x1)
		else
			lo, x1, f1 = x1, x2, f2
			x2 = lo + PHI * (hi - lo)
			f2 = f(x2)
		end
	end
	return (lo + hi) / 2
end

-- The cost-aware funnel (ticket 25, weighted): pins the path on each portal between two
-- triangles of different `mult`, and moves each pin along its portal to where its two
-- neighbouring path points cost least through it (Snell's law at the boundary), sweeping until
-- the pins settle. The funnel pulls each run between pins straight, which is exact inside a run
-- (one multiplier). Pins are left in `lefts`/`rights` (both ends at the pin) for the final pull.
local function refract(lefts: { vector }, rights: { vector }, owners: { number }, mult: (number) -> number)
	local pins, a, b, u = {}, {}, {}, {}
	for j = 2, #lefts - 1 do
		if mult(owners[j]) ~= mult(owners[j + 1]) and lefts[j] ~= rights[j] then
			table.insert(pins, j)
			table.insert(a, lefts[j])
			table.insert(b, rights[j])
			table.insert(u, 0.5)
		end
	end
	if #pins == 0 then
		return
	end
	local function at(k: number): vector
		return a[k] + (b[k] - a[k]) * u[k]
	end
	-- ponytail: a full pull per sweep; pull only the runs next to moved pins if long corridors
	-- with many area changes get slow.
	-- Each sweep pulls the path through the pins, then settles the pins against the path points
	-- either side of them, or against each other where no corner lies between two (cheap 1-D
	-- steps, repeated: neighbouring pins move each other).
	local prev, next = {}, {}
	for _ = 1, 32 do
		for k, j in pins do
			lefts[j], rights[j] = at(k), at(k)
		end
		local points, _, on = pull(lefts, rights, owners)
		local first = 1 -- the first path point not before the current pin's portal
		for k, j in pins do
			while on[first] < j do
				first += 1
			end
			local before, after = first - 1, first
			while on[after] == j do
				after += 1
			end
			prev[k] = if k > 1 and on[before] <= pins[k - 1] then false else points[before]
			next[k] = if k < #pins and on[after] >= pins[k + 1] then false else points[after]
		end
		local settled = true
		for pass = 1, 200 do
			local moved = 0
			for k, j in pins do
				local old = at(k)
				u[k] =
					snell(a[k], b[k], prev[k] or at(k - 1), next[k] or at(k + 1), mult(owners[j]), mult(owners[j + 1]))
				moved = math.max(moved, vector.magnitude(at(k) - old))
			end
			if pass == 1 and moved >= 1e-6 then
				settled = false
			end
			if moved < 1e-7 then
				break
			end
		end
		if settled then
			break
		end
	end
	for k, j in pins do
		lefts[j], rights[j] = at(k), at(k)
	end
end

local PIXEL = 1 / 256 + 1e-9 -- a seam's two floors' copies of a vertex differ by up to this

-- Whether `p`, a vertex of triangle `t` matched in (X, Z) only (a seam point has one height per
-- floor), is a wall corner: a wall vertex of any floor meeting there. Turns round p's fan across
-- neighbours and seam portals, both ways, until it closes or ends, so a floor that meets t's
-- only at p, through other floors, counts too (a corner where four floors meet). `v` is p's
-- vertex id in t when known (0 when not), which spares the matching on t's floor.
local function wallAt(s: Storage.State, t: number, p: vector, v: number): boolean
	for side = 1, 2 do
		local at, vi = t, v
		for _ = 1, 64 do
			local v1, v2, v3 = Storage.GetTriangle(s, at)
			if vi == 0 then
				-- Just crossed a seam: find p among this floor's vertices.
				local best = PIXEL
				for k = 1, 3 do
					local w = if k == 1 then v1 elseif k == 2 then v2 else v3
					local q = Storage.GetVertex(s, w)
					local d = math.max(math.abs(q.X - p.X), math.abs(q.Z - p.Z))
					if d <= best then
						vi, best = w, d
					end
				end
				if vi == 0 then
					break
				elseif Storage.IsWallVertex(s, vi) then
					return true
				end
			elseif at == t and Storage.IsWallVertex(s, vi) then
				return true
			end
			local i = if v1 == vi then 1 elseif v2 == vi then 2 else 3
			-- The two edges at vertex i, one per turning direction.
			local e = if side == 1 then (i + 1) % 3 + 1 else i % 3 + 1
			local n = Storage.GetNeighbor(s, at, e)
			local id = if n == 0 then Storage.GetExtraHead(s, at) else 0
			while id ~= 0 do
				local nextId, target, kind, ref, a, b = Storage.GetExtra(s, id)
				local ends = math.min(
					math.max(math.abs(a.X - p.X), math.abs(a.Z - p.Z)),
					math.max(math.abs(b.X - p.X), math.abs(b.Z - p.Z))
				)
				if kind == Storage.EXTRA_SEAM and ref == e and ends <= PIXEL then
					n, vi = target, 0
					break
				end
				id = nextId
			end
			if n == t then
				return false -- the fan closed: p is inside free space
			elseif n == 0 then
				break
			end
			at = n
		end
	end
	return false
end

--[=[
	@within NavMeshFunnel
	The path from `startP` to `endP` through `corridor` (entered as `vias` says, see Search),
	as points, the triangle each point was taken from (for its floor), and the link slot of each
	point where a link starts (by point index).

	Seam portals are portals like shared edges, and their wall-corner ends are offset the same
	way. A link
	breaks the string: the path runs to the link's start, which carries the link, then on from
	where it lands.
]=]
function Funnel.StringPull(
	s: Storage.State,
	corridor: { number },
	vias: { number },
	startP: vector,
	endP: vector,
	radius: number,
	costs: { [number]: number }?
): ({ vector }, { number }, { [number]: number })
	local points, from, links = {}, {}, {}
	-- wallAt per vertex, for this call: consecutive portals share ends.
	local corners: { [number]: boolean } = {}
	local function corner(t: number, v: number): boolean
		local c = corners[v]
		if c == nil then
			c = wallAt(s, t, Storage.GetVertex(s, v), v)
			corners[v] = c
		end
		return c
	end
	local lefts, rights, owners = { startP }, { startP }, { corridor[1] }
	local function finish(stop: vector, owner: number)
		table.insert(lefts, stop)
		table.insert(rights, stop)
		table.insert(owners, owner)
		if costs then
			refract(lefts, rights, owners, function(t: number): number
				return costs[Storage.GetTriangleArea(s, t)] or 1
			end)
		end
		local segment, segmentFrom = drape(lefts, rights, owners, pull(lefts, rights, owners))
		for k, point in segment do
			table.insert(points, point)
			table.insert(from, segmentFrom[k])
		end
	end
	-- A portal end that is a wall corner moves r along the portal, towards its other end.
	local function push(l: vector, r: vector, lWall: boolean, rWall: boolean, owner: number)
		if radius > 0 and (lWall or rWall) then
			local length = vector.magnitude(r - l)
			local shift = math.min(radius, length * 0.5) / length
			l, r = if lWall then l + (r - l) * shift else l, if rWall then r + (l - r) * shift else r
		end
		table.insert(lefts, l)
		table.insert(rights, r)
		table.insert(owners, owner)
	end
	for i = 1, #corridor - 1 do
		local t, nextT, via = corridor[i], corridor[i + 1], vias[i + 1]
		if via ~= 0 then
			local _, _, kind, ref, a, b = Storage.GetExtra(s, via)
			if kind == Storage.EXTRA_LINK then
				finish(a, t)
				links[#points] = ref
				lefts, rights, owners = { b }, { b }, { nextT }
			else
				-- A seam portal's end is a wall corner when it is a wall vertex on either floor.
				local offset = radius > 0
				push(
					a,
					b,
					offset and (wallAt(s, t, a, 0) or wallAt(s, nextT, a, 0)),
					offset and (wallAt(s, t, b, 0) or wallAt(s, nextT, b, 0)),
					t
				)
			end
			continue
		end
		local verts = { Storage.GetTriangle(s, t) }
		for e = 1, 3 do
			if Storage.GetNeighbor(s, t, e) == nextT then
				local lv, rv = verts[(e + 1) % 3 + 1], verts[e % 3 + 1]
				push(
					Storage.GetVertex(s, lv),
					Storage.GetVertex(s, rv),
					radius > 0 and corner(t, lv),
					radius > 0 and corner(t, rv),
					t
				)
				break
			end
		end
	end
	finish(endP, corridor[#corridor])
	return points, from, links
end

return Funnel
