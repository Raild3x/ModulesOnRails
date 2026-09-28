--!strict
--!native
-- Authors: Logan Hunt (Raildex)
-- September 27, 2026
--[=[
	@class NavMeshSearch
	@private

	A* over triangles, for `FindPath`.

	**Nodes (ticket 14 probe, bench.md):** a triangle's node sits at the midpoint of the edge it
	was entered by (as in Recast), the start triangle's at the snapped start, and the goal
	triangle's at the snapped goal. Against nodes at triangle centres this was as fast, and its
	funnelled paths were 3-5x closer to the shortest on average: centres pull the corridor
	towards small triangles, 56% longer in the worst case on the Courtyard. One node per
	(triangle, entry edge) had fixed positions but ran 3x slower for a smaller gain.

	**Costs:** crossing from t into m costs the 3D distance from t's node to m's node times the
	mean of the two areas' `AreaCosts` multipliers (default 1; `math.huge` excludes the area).

	**Heuristic (SR7):** the 3D distance to the goal point, scaled by
	`min(1, smallest AreaCosts multiplier)`, so it never overestimates. A zero multiplier makes
	it 0 (Dijkstra). Links (ticket 16) will add their own term to the scale. Because a node's
	position depends on how it was reached, the result is the best corridor A* finds, not a
	proven optimum over a fixed graph.

	**Agent radius (ticket 15, SR4):** passing through a triangle from its entry edge to an exit
	edge needs the corner width between them to be at least 2r. Leaving the start triangle needs
	the exit edge's portal width. A corner width already covers both of its portals, so the goal
	needs no extra check.

	**Scratch:** a per-mesh pool in a weak-keyed table, holding only arrays and the open list, so
	it never keeps a mesh alive.
]=]

local OpenList = require("./OpenList")
local Snap = require("./Snap")
local Storage = require("./Storage")

export type Status = "Success" | "Partial" | "Budget"

type Scratch = {
	G: { number },
	Pos: { vector },
	Entry: { number },
	Parent: { number },
	Seen: { number },
	Closed: { number },
	ClosedList: { number },
	Open: OpenList.OpenList,
	Stamp: number,
}

local pool: { [Storage.State]: Scratch } = setmetatable({}, { __mode = "k" }) :: any

local Search = {}

local function scratchFor(s: Storage.State): Scratch
	local scratch = pool[s]
	if scratch == nil then
		local n = Storage.TriangleCount(s)
		scratch = {
			G = table.create(n, 0),
			Pos = table.create(n, vector.zero),
			Entry = table.create(n, 0),
			Parent = table.create(n, 0),
			Seen = table.create(n, 0),
			Closed = table.create(n, 0),
			ClosedList = {},
			Open = OpenList.new(),
			Stamp = 0,
		}
		pool[s] = scratch
	end
	return scratch
end

--[=[
	@within NavMeshSearch
	`min(1, smallest AreaCosts multiplier)`: the SR7 heuristic scale.
]=]
function Search.HeuristicScale(costs: { [number]: number }): number
	local scale = 1
	for _, multiplier in costs do
		scale = math.min(scale, multiplier)
	end
	return scale
end

--[=[
	@within NavMeshSearch
	Searches from triangle `startT` at point `startP` to `goalT` at `goalP`.

	Returns the status, the triangle corridor from the start, the point the path ends at, and
	its cost. On `Partial` (the goal is unreachable) and `Budget` (`maxExpansions` triangles
	were expanded first), the corridor ends at the reached triangle holding the point nearest
	the goal, and the cost is that of reaching its node.
]=]
function Search.Run(
	s: Storage.State,
	startT: number,
	startP: vector,
	goalT: number,
	goalP: vector,
	costs: { [number]: number },
	maxExpansions: number,
	radius: number
): (Status, { number }, vector, number)
	if startT == goalT then
		return "Success",
			{ startT },
			goalP,
			vector.magnitude(goalP - startP) * (costs[Storage.GetTriangleArea(s, startT)] or 1)
	end
	local scratch = scratchFor(s)
	local stamp = scratch.Stamp + 1
	scratch.Stamp = stamp
	local g, pos, entry, parent, seen, closed, closedList, open =
		scratch.G,
		scratch.Pos,
		scratch.Entry,
		scratch.Parent,
		scratch.Seen,
		scratch.Closed,
		scratch.ClosedList,
		scratch.Open
	local width = 2 * radius
	table.clear(closedList)
	OpenList.Clear(open)
	local push, pop = OpenList.Push, OpenList.Pop
	local GetTriangle, GetTriangleArea, GetVertex = Storage.GetTriangle, Storage.GetTriangleArea, Storage.GetVertex
	local GetCornerWidth, GetPortalWidth, GetNeighbor =
		Storage.GetCornerWidth, Storage.GetPortalWidth, Storage.GetNeighbor
	local nb: buffer = s.TriNeighbors -- inlined: Storage.GetNeighbor (i32 x3 per triangle)
	local scale = Search.HeuristicScale(costs)

	g[startT], pos[startT], seen[startT], parent[startT] = 0, startP, stamp, 0
	push(open, startT, vector.magnitude(goalP - startP) * scale)
	local expansions = 0
	local status: Status = "Partial"
	while true do
		local t = pop(open)
		if t == 0 then
			break
		end
		if closed[t] == stamp then
			continue -- a stale entry: t was pushed again with a lower cost and already expanded
		end
		closed[t] = stamp
		if t == goalT then
			status = "Success"
			break
		end
		table.insert(closedList, t)
		if expansions >= maxExpansions then
			status = "Budget"
			break
		end
		expansions += 1
		local tp = pos[t]
		local tm = costs[GetTriangleArea(s, t)] or 1
		local gt = g[t]
		local ia, ib, ic = GetTriangle(s, t)
		local base = (t - 1) * 12
		for e = 1, 3 do
			local m = buffer.readi32(nb, base + (e - 1) * 4)
			if m == 0 or closed[m] == stamp then
				continue
			end
			local mm = costs[GetTriangleArea(s, m)] or 1
			if mm == math.huge then
				continue
			end
			if width > 0 then
				-- Edges e and entry[t] meet at the third vertex, 6 - e - entry[t].
				local clear = if t == startT then GetPortalWidth(s, t, e) else GetCornerWidth(s, t, 6 - e - entry[t])
				if clear < width then
					continue
				end
			end
			-- Edge e runs between the two vertices other than vertex e.
			local mp = if m == goalT
				then goalP
				elseif e == 1 then (GetVertex(s, ib) + GetVertex(s, ic)) * 0.5
				elseif e == 2 then (GetVertex(s, ic) + GetVertex(s, ia)) * 0.5
				else (GetVertex(s, ia) + GetVertex(s, ib)) * 0.5
			local ng = gt + vector.magnitude(mp - tp) * (tm + mm) * 0.5
			if seen[m] ~= stamp or ng < g[m] then
				g[m], pos[m], seen[m], parent[m] = ng, mp, stamp, t
				if width > 0 then
					entry[m] = if GetNeighbor(s, m, 1) == t then 1 elseif GetNeighbor(s, m, 2) == t then 2 else 3
				end
				push(open, m, ng + vector.magnitude(goalP - mp) * scale)
			end
		end
	end

	local last, endP = goalT, goalP
	if status ~= "Success" then
		-- The reached triangle holding the point nearest the goal (not the nearest node). The
		-- start is always in the list: it is popped first and is not the goal.
		local best = math.huge
		for _, t in closedList do
			local p = Snap.ClosestOnTriangle(s, t, goalP)
			local d = vector.magnitude(goalP - p)
			if d < best then
				best, last, endP = d, t, p
			end
		end
	end
	local corridor = {}
	local t = last
	while t ~= 0 do
		table.insert(corridor, t)
		t = parent[t]
	end
	local n = #corridor
	for i = 1, n // 2 do
		corridor[i], corridor[n + 1 - i] = corridor[n + 1 - i], corridor[i]
	end
	return status, corridor, endP, g[last]
end

return Search
