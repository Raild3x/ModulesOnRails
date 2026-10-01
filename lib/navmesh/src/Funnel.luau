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

	**Agent radius (SR4):** each portal end that is a wall vertex is moved along the portal,
	towards its other end, by min(r, half the portal's length). Free-space vertices (tile, area,
	seam) are not offset, but a seam portal's end that is a wall vertex on either of its floors
	is: the corner where a seam meets a wall.

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
				if denom == 0 then
					continue -- the segment runs along this portal: its ends are on it
				end
				local wx, wz = p.X - l.X, p.Z - l.Z
				local s = math.clamp((wx * dz - wz * dx) / denom, 0, 1)
				u = math.clamp((wx * ez - wz * ex) / denom, 0, 1)
				c, owner = vector.create(p.X + dx * u, l.Y + (r.Y - l.Y) * s, p.Z + dz * u), owners[i]
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

-- Whether `p` is a wall vertex of triangle `t`, matched in (X, Z) only (a seam point has one
-- height per floor) and well inside a grid pixel (vertices are on the 1/256 grid).
local function wallAt(s: Storage.State, t: number, p: vector): boolean
	for _, v in { Storage.GetTriangle(s, t) } do
		local q = Storage.GetVertex(s, v)
		if math.abs(q.X - p.X) < 1e-3 and math.abs(q.Z - p.Z) < 1e-3 then
			return Storage.IsWallVertex(s, v)
		end
	end
	return false
end

--[=[
	@within NavMeshFunnel
	The path from `startP` to `endP` through `corridor` (entered as `vias` says, see Search),
	as points, the triangle each point was taken from (for its floor), and the label of each
	point where a link starts (by point index).

	Seam portals are portals like shared edges, and their wall-corner ends are offset the same
	way. A link
	breaks the string: the path runs to the link's start, which carries its label, then on from
	where it lands.
]=]
function Funnel.StringPull(
	s: Storage.State,
	corridor: { number },
	vias: { number },
	startP: vector,
	endP: vector,
	radius: number
): ({ vector }, { number }, { [number]: string })
	local points, from, labels = {}, {}, {}
	local lefts, rights, owners = { startP }, { startP }, { corridor[1] }
	local function finish(stop: vector, owner: number)
		table.insert(lefts, stop)
		table.insert(rights, stop)
		table.insert(owners, owner)
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
				local label = select(7, Storage.GetLink(s, ref))
				if label ~= "" then
					labels[#points] = label
				end
				lefts, rights, owners = { b }, { b }, { nextT }
			else
				-- A seam portal's end is a wall corner when it is a wall vertex on either floor.
				local offset = radius > 0
				push(
					a,
					b,
					offset and (wallAt(s, t, a) or wallAt(s, nextT, a)),
					offset and (wallAt(s, t, b) or wallAt(s, nextT, b)),
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
					Storage.IsWallVertex(s, lv),
					Storage.IsWallVertex(s, rv),
					t
				)
				break
			end
		end
	end
	finish(endP, corridor[#corridor])
	return points, from, labels
end

return Funnel
