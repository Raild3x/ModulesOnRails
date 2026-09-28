--!strict
--!native
-- Authors: Logan Hunt (Raildex)
-- September 27, 2026
--[=[
	@class NavMeshFunnel
	@private

	String-pulls a triangle corridor into the shortest path through it in (X, Z): the "simple
	stupid funnel" (Mononen). Corners are mesh vertices, so they keep their heights.

	**Agent radius (SR4):** each portal end that is a wall vertex is moved r along the portal,
	towards its other end, so corners are passed at distance r. Free-space vertices (tile, area,
	seam) are not offset. Between two offset corners the straight segment may cut inside the
	r-circle by up to r (1 - cos(half the turn)).
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
-- the triangle it was taken from.
local function pull(lefts: { vector }, rights: { vector }, owners: { number }): ({ vector }, { number })
	local startP, endP = lefts[1], lefts[#lefts]
	local points, from = { startP }, { owners[1] }
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
	end
	-- A line that grazes a vertex exactly leaves a zero-turn corner there: drop it (exact test).
	local kept, keptFrom = { points[1] }, { from[1] }
	for k = 2, #points - 1 do
		local a, q, c = kept[#kept], points[k], points[k + 1]
		if CDT.Orient2D(a.X, a.Z, q.X, q.Z, c.X, c.Z) ~= 0 then
			table.insert(kept, q)
			table.insert(keptFrom, from[k])
		end
	end
	if #points > 1 then
		table.insert(kept, points[#points])
		table.insert(keptFrom, from[#points])
	end
	return kept, keptFrom
end

--[=[
	@within NavMeshFunnel
	The path from `startP` to `endP` through `corridor` (entered as `vias` says, see Search),
	as points, the triangle each point was taken from (for its floor), and the label of each
	point where a link starts (by point index).

	Seam portals are portals like shared edges (their ends are not offset for radius). A link
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
		local segment, segmentFrom = pull(lefts, rights, owners)
		for k, point in segment do
			table.insert(points, point)
			table.insert(from, segmentFrom[k])
		end
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
				table.insert(lefts, a)
				table.insert(rights, b)
				table.insert(owners, t)
			end
			continue
		end
		local verts = { Storage.GetTriangle(s, t) }
		for e = 1, 3 do
			if Storage.GetNeighbor(s, t, e) == nextT then
				local lv, rv = verts[(e + 1) % 3 + 1], verts[e % 3 + 1]
				local l, r = Storage.GetVertex(s, lv), Storage.GetVertex(s, rv)
				if radius > 0 then
					local length = vector.magnitude(r - l)
					local shift = math.min(radius, length * 0.5) / length
					local l2 = if Storage.IsWallVertex(s, lv) then l + (r - l) * shift else l
					local r2 = if Storage.IsWallVertex(s, rv) then r + (l - r) * shift else r
					l, r = l2, r2
				end
				table.insert(lefts, l)
				table.insert(rights, r)
				table.insert(owners, t)
				break
			end
		end
	end
	finish(endP, corridor[#corridor])
	return points, from, labels
end

return Funnel
