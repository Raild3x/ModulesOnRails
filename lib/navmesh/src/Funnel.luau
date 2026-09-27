--!strict
--!native
-- Authors: Logan Hunt (Raildex)
-- September 27, 2026
--[=[
	@class NavMeshFunnel
	@private

	String-pulls a triangle corridor into the shortest path through it in (X, Z): the "simple
	stupid funnel" (Mononen). Corners are mesh vertices, so they keep their heights. Radius 0
	only; offsets at wall corners arrive with clearance (ticket 15, SR4).
]=]

local CDT = require("../ConstrainedDelaunay")
local Storage = require("./Storage")

local Funnel = {}

-- > 0 when c is left of a -> b in (X, Z) (the same sign as Storage's CCW triangles).
local function orient(a: vector, b: vector, c: vector): number
	return (b.X - a.X) * (c.Z - a.Z) - (b.Z - a.Z) * (c.X - a.X)
end

--[=[
	@within NavMeshFunnel
	The path from `startP` to `endP` through `corridor`, as points plus the triangle each point
	was taken from (for its floor).
]=]
function Funnel.StringPull(
	s: Storage.State,
	corridor: { number },
	startP: vector,
	endP: vector
): ({ vector }, { number })
	-- Portals: the start, each shared edge (left, right as seen when crossing it), the end.
	local lefts, rights, owners = { startP }, { startP }, { corridor[1] }
	for i = 1, #corridor - 1 do
		local t, nextT = corridor[i], corridor[i + 1]
		local verts = { Storage.GetTriangle(s, t) }
		for e = 1, 3 do
			if Storage.GetNeighbor(s, t, e) == nextT then
				table.insert(lefts, Storage.GetVertex(s, verts[(e + 1) % 3 + 1]))
				table.insert(rights, Storage.GetVertex(s, verts[e % 3 + 1]))
				table.insert(owners, t)
				break
			end
		end
	end
	table.insert(lefts, endP)
	table.insert(rights, endP)
	table.insert(owners, corridor[#corridor])

	local points, from = { startP }, { corridor[1] }
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
		table.insert(from, corridor[#corridor])
	end
	-- A line that grazes a vertex exactly leaves a zero-turn corner there: drop it (exact test).
	local kept, keptFrom = { points[1] }, { from[1] }
	for i = 2, #points - 1 do
		local p, q, r = kept[#kept], points[i], points[i + 1]
		if CDT.Orient2D(p.X, p.Z, q.X, q.Z, r.X, r.Z) ~= 0 then
			table.insert(kept, q)
			table.insert(keptFrom, from[i])
		end
	end
	if #points > 1 then
		table.insert(kept, points[#points])
		table.insert(keptFrom, from[#points])
	end
	return kept, keptFrom
end

return Funnel
