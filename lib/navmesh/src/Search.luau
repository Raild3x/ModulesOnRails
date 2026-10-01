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

	**Heron nodes (ticket 25):** when every walkable stud costs the same (no `AreaCosts`
	multiplier but 1 or excluded, and no link cheaper than walking), an edge node sits instead
	where a ray from the parent's node to the goal would bounce off the edge: the edge point
	minimising |parent - x| + |x - goal|. Midpoints sit beside the true line, so A* misjudged
	which side of an obstacle was shorter: against an exact shortest path (32k pairs), p95 went
	from 1.074 to 1.0036 and the worst from 2.33x to 1.23x, and FindPath got about 2x faster at
	r 0. With other costs, goal-ward nodes overprice a route heading away from the goal (round a
	dear area, back to a cheap link), so those queries keep midpoints. Seam portals keep
	midpoints too. Heron nodes depend on the route to them, so A* is no longer exactly Dijkstra
	over a fixed graph (it is with midpoints).

	**Costs:** a step from t's node to the node on the edge it leaves t by lies inside t, so it
	costs the 3D distance times t's `AreaCosts` multiplier (default 1; `math.huge` excludes the
	area). The last step, into the goal's triangle, is split where it crosses the edge
	(Detour's rule; ticket 25, weighted). It was the mean of the two multipliers.

	**Heuristic (SR7):** the 3D distance to the goal point, scaled by
	`min(1, smallest AreaCosts multiplier)`, so it never overestimates. A zero multiplier makes
	it 0 (Dijkstra). Links (ticket 16) will add their own term to the scale. Because a node's
	position depends on how it was reached, the result is the best corridor A* finds, not a
	proven optimum over a fixed graph.

	**Agent radius (ticket 15, SR4):** passing through a triangle from its entry edge to an exit
	edge needs the corner width between them to be at least 2r. Leaving the start triangle needs
	the exit edge's portal width. A corner width already covers both of its portals, so the goal
	needs no extra check.

	**Seams and links (ticket 16):** after its three edges, a triangle's extra links are tried.
	- A seam portal crosses like an edge, into another floor's triangle: the node sits at the
	  portal's midpoint, and the corner width to the seam edge applies.
	- A link walks to its start point, pays `Cost` times its area's multiplier, and lands at its
	  end point. Disabled links and excluded areas are skipped; agent radius is not checked on a
	  link.
	- A triangle entered by a seam or a link has no entry edge of its own, so leaving it needs
	  the exit edge's portal width, like the start.
	The corridor records how each triangle was entered (`Via`: 0 = an edge, else the extra link
	id), for the funnel.

	**Scratch:** a per-mesh pool in a weak-keyed table, holding only arrays and the open list, so
	it never keeps a mesh alive.
]=]

local Clearance = require("./Clearance")
local OpenList = require("./OpenList")
local Queries = require("./Queries")
local Snap = require("./Snap")
local Storage = require("./Storage")

export type Status = "Success" | "Partial" | "Budget"

type Scratch = {
	G: { number },
	Pos: { vector },
	Entry: { number },
	Via: { number },
	Parent: { number },
	Seen: { number },
	Closed: { number },
	ClosedList: { number },
	Open: OpenList.OpenList,
	Stamp: number,
}

local pool: { [Storage.State]: Scratch } = setmetatable({}, { __mode = "k" }) :: any

local Search = {}

-- The heron node on edge a-b for a search at p heading for g: the point of the edge minimising
-- |p - x| + |x - g| in plan, where a ray from p to g (mirrored across the edge when on p's
-- side, as light bounces) meets it. Mirroring leaves g's place along the edge as it is, so the
-- node splits p's and g's places along the edge in the ratio of their distances from it. Its
-- height is the edge's there.
local function heronPoint(a: vector, b: vector, p: vector, g: vector): vector
	local ex, ez = b.X - a.X, b.Z - a.Z
	local len2 = ex * ex + ez * ez
	local dp = math.abs(ex * (p.Z - a.Z) - ez * (p.X - a.X))
	local dg = math.abs(ex * (g.Z - a.Z) - ez * (g.X - a.X))
	local up = ((p.X - a.X) * ex + (p.Z - a.Z) * ez) / len2
	local ug = ((g.X - a.X) * ex + (g.Z - a.Z) * ez) / len2
	local u = if dp + dg > 0 then (up * dg + ug * dp) / (dp + dg) else 0.5
	return a + (b - a) * math.clamp(u, 0, 1)
end
Search.HeronPoint = heronPoint -- for the specs' node-chain oracle

-- The cost of the step from p (in triangle t, multiplier tm) to q over t's edge a-b (Detour's
-- rule): inside t when q is on the edge; split where it crosses the edge when q is past it, in
-- the next triangle (multiplier mm).
local function stepCost(p: vector, q: vector, a: vector, b: vector, tm: number, mm: number, past: boolean): number
	if not past or tm == mm then
		return vector.magnitude(q - p) * (if past then mm else tm)
	end
	local ex, ez = b.X - a.X, b.Z - a.Z
	local sp = ex * (p.Z - a.Z) - ez * (p.X - a.X)
	local sq = ex * (q.Z - a.Z) - ez * (q.X - a.X)
	local c = p + (q - p) * (if sp ~= sq then math.clamp(sp / (sp - sq), 0, 1) else 0)
	return vector.magnitude(c - p) * tm + vector.magnitude(q - c) * mm
end

-- The edge of m on the seam portal it shares with t (the slot its own seam extra back to t
-- names).
local function seamEdge(s: Storage.State, m: number, t: number): number
	local id = Storage.GetExtraHead(s, m)
	while id ~= 0 do
		local nextId, to, kind, ref = Storage.GetExtra(s, id)
		if to == t and kind == Storage.EXTRA_SEAM then
			return ref
		end
		id = nextId
	end
	error("NavMesh: internal error: a seam portal has no way back")
end

local function scratchFor(s: Storage.State): Scratch
	local scratch = pool[s]
	if scratch == nil then
		local n = Storage.TriangleCount(s)
		scratch = {
			G = table.create(n, 0),
			Pos = table.create(n, vector.zero),
			Entry = table.create(n, 0),
			Via = table.create(n, 0),
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
	The SR7 heuristic scale: `min(1, smallest AreaCosts multiplier, smallest enabled link
	(Cost x its area multiplier) / its 3D length)`, so the heuristic never overestimates.

	Links are read through `Storage.LinkPrices`, the cheapest Cost / length per link area, made
	once per link change: a query reads one entry per area. Looping over every link instead
	took 44-60 us of a 110-170 us `FindPath` at 1,000 links (bench.md, "Ticket 30").
]=]
function Search.HeuristicScale(s: Storage.State, costs: { [number]: number }): number
	local prices = s.LinkPrices
	if prices == nil then
		local made: { [number]: number } = {}
		for slot = 1, Storage.LinkCount(s) do
			local fromTri, from, toTri, to, cost, area, _, _, enabled = Storage.GetLink(s, slot)
			if enabled and fromTri ~= 0 and toTri ~= 0 then
				local length = vector.magnitude(to - from)
				local ratio = if length > 0 then cost / length elseif cost == 0 then 0 else nil
				if ratio then -- a dear zero-length link bounds nothing
					made[area] = math.min(made[area] or math.huge, ratio)
				end
			end
		end
		s.LinkPrices = made
		prices = made
	end
	local scale = 1
	for _, multiplier in costs do
		scale = math.min(scale, multiplier)
	end
	for area, ratio in prices :: { [number]: number } do
		local multiplier = costs[area] or 1
		if multiplier ~= math.huge then
			scale = math.min(scale, ratio * multiplier)
		end
	end
	return scale
end

--[=[
	@within NavMeshSearch
	Searches from triangle `startT` at point `startP` to `goalT` at `goalP`.

	Returns the status, the triangle corridor from the start, how each corridor triangle was
	entered (0 = an edge, else the extra link id; 0 for the first), the point the path ends at,
	and its cost. On `Partial` (the goal is unreachable) and `Budget` (`maxExpansions` triangles
	were expanded first), the corridor ends at the reached triangle holding the point nearest
	the goal, and the cost is that of reaching its node.

	`goalT` 0 (no goal triangle, `GoalFallback`) never succeeds: the search covers everything
	reachable (or stops at `maxExpansions`) and ends at the reached point nearest `goalP`.
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
): (Status, { number }, { number }, vector, number)
	local width = 2 * radius
	-- Nodes are triangles, the start being startT's. When a wall chain inside the start or goal
	-- triangle cuts its end off from one of its edges (ticket 27), a path may leave that
	-- triangle and come back into it past the chain, so two more nodes stand for them entered
	-- again: the start's and the goal's (passed through). The goal is goalT's node, or a third
	-- one when the ends share a triangle that a chain parts them in.
	local n = Storage.TriangleCount(s)
	local startAgain, goalAgain = n + 1, n + 2
	local goalNode = goalT
	if startT == goalT then
		if width == 0 or not Clearance.Separated(s, startT, radius, startP.X, startP.Z, goalP.X, goalP.Z) then
			return "Success",
				{ startT },
				{ 0 },
				goalP,
				vector.magnitude(goalP - startP) * (costs[Storage.GetTriangleArea(s, startT)] or 1)
		end
		goalNode = n + 3
	end
	local function triangleOf(u: number): number
		return if u <= n then u elseif u == goalAgain then goalT else startT
	end
	local startCut = false
	local cutOff = Clearance.CutOff
	local scratch = scratchFor(s)
	local stamp = scratch.Stamp + 1
	scratch.Stamp = stamp
	local g, pos, entry, via, parent, seen, closed, closedList, open =
		scratch.G,
		scratch.Pos,
		scratch.Entry,
		scratch.Via,
		scratch.Parent,
		scratch.Seen,
		scratch.Closed,
		scratch.ClosedList,
		scratch.Open
	table.clear(closedList)
	OpenList.Clear(open)
	local push, pop = OpenList.Push, OpenList.Pop
	local GetTriangle, GetTriangleArea, GetVertex = Storage.GetTriangle, Storage.GetTriangleArea, Storage.GetVertex
	local GetCornerWidth, GetPortalWidth, GetNeighbor =
		Storage.GetCornerWidth, Storage.GetPortalWidth, Storage.GetNeighbor
	local nb: buffer = s.TriNeighbors -- inlined: Storage.GetNeighbor (i32 x3 per triangle)
	local GetExtraHead, GetExtra, GetLink = Storage.GetExtraHead, Storage.GetExtra, Storage.GetLink
	local EXTRA_LINK = Storage.EXTRA_LINK
	local scale = Search.HeuristicScale(s, costs)
	-- Heron nodes only where every walkable stud costs the same: no multiplier but 1 (or
	-- excluded) and no link cheaper than walking. Goal-ward nodes overprice a route that heads
	-- away from the goal round a dear area, or back to a cheap link.
	local heron = scale >= 1
	for _, multiplier in costs do
		if multiplier ~= 1 and multiplier ~= math.huge then
			heron = false
		end
	end

	-- The node that entering triangle m leads to, given whether the goal is cut off from that
	-- entry.
	local function target(m: number, goalCut: boolean): number
		if m == goalT then
			return if not goalCut then goalNode elseif m == startT then startAgain else goalAgain
		end
		return if m == startT and startCut then startAgain else m
	end

	g[startT], pos[startT], seen[startT], parent[startT] = 0, startP, stamp, 0
	entry[startT], via[startT] = 0, 0
	push(open, startT, vector.magnitude(goalP - startP) * scale)
	local expansions = 0
	local status: Status = "Partial"
	while true do
		local u = pop(open)
		if u == 0 then
			break
		end
		if closed[u] == stamp then
			continue -- a stale entry: u was pushed again with a lower cost and already expanded
		end
		closed[u] = stamp
		if u == goalNode then
			status = "Success"
			break
		end
		table.insert(closedList, u)
		if expansions >= maxExpansions then
			status = "Budget"
			break
		end
		expansions += 1
		local t = triangleOf(u)
		local tp = pos[u]
		local tm = costs[GetTriangleArea(s, t)] or 1
		local gt = g[u]
		local ia, ib, ic = GetTriangle(s, t)
		local base = (t - 1) * 12
		for e = 1, 3 do
			local m = buffer.readi32(nb, base + (e - 1) * 4)
			if m == 0 or e == entry[u] then
				continue -- no neighbour, or back the way it came
			end
			local mm = costs[GetTriangleArea(s, m)] or 1
			if mm == math.huge then
				continue
			end
			local back = 0
			local goalCut = false
			if width > 0 then
				-- Edges e and entry[u] meet at the third vertex, 6 - e - entry[u].
				local clear = if entry[u] == 0 then GetPortalWidth(s, t, e) else GetCornerWidth(s, t, 6 - e - entry[u])
				if clear < width then
					continue
				end
				-- Inside the start and goal triangles the ends themselves must reach the edge.
				if u == startT and cutOff(s, t, e, radius, startP.X, startP.Z) then
					startCut = true
					continue
				end
				back = if GetNeighbor(s, m, 1) == t then 1 elseif GetNeighbor(s, m, 2) == t then 2 else 3
				goalCut = m == goalT and cutOff(s, m, back, radius, goalP.X, goalP.Z)
			end
			local node = target(m, goalCut)
			if closed[node] == stamp then
				continue
			end
			-- Edge e runs between the two vertices other than vertex e.
			local a = GetVertex(s, if e == 1 then ib elseif e == 2 then ic else ia)
			local b = GetVertex(s, if e == 1 then ic elseif e == 2 then ia else ib)
			local mp = goalP
			if node ~= goalNode then
				mp = if heron then heronPoint(a, b, tp, goalP) else (a + b) * 0.5
			end
			local ng = gt + stepCost(tp, mp, a, b, tm, mm, node == goalNode)
			if seen[node] ~= stamp or ng < g[node] then
				g[node], pos[node], seen[node], parent[node], via[node], entry[node] = ng, mp, stamp, u, 0, back
				push(open, node, ng + vector.magnitude(goalP - mp) * scale)
			end
		end
		-- Seam portals and links.
		local id = GetExtraHead(s, t)
		while id ~= 0 do
			local nextId, m, kind, ref, a, b = GetExtra(s, id)
			local extra = id
			id = nextId
			local mm = costs[GetTriangleArea(s, m)] or 1
			if mm == math.huge then
				continue
			end
			local node, mp, ng
			if kind == EXTRA_LINK then
				local _, _, _, _, cost, area, _, _, enabled = GetLink(s, ref)
				local lm = costs[area] or 1
				if not enabled or lm == math.huge then
					continue
				end
				node = target(m, false)
				ng = gt + vector.magnitude(a - tp) * tm + cost * lm
				if node == goalNode then
					mp = goalP
					ng += vector.magnitude(goalP - b) * mm
				else
					mp = b
				end
			else
				-- A seam portal on edge `ref` of t.
				local goalCut = false
				if width > 0 then
					local clear = if entry[u] == 0
						then GetPortalWidth(s, t, ref)
						else GetCornerWidth(s, t, 6 - ref - entry[u])
					if clear < width then
						continue
					end
					if u == startT and cutOff(s, t, ref, radius, startP.X, startP.Z) then
						startCut = true
						continue
					end
					goalCut = m == goalT and cutOff(s, m, seamEdge(s, m, t), radius, goalP.X, goalP.Z)
				end
				node = target(m, goalCut)
				mp = if node == goalNode then goalP else (a + b) * 0.5
				ng = gt + stepCost(tp, mp, a, b, tm, mm, node == goalNode)
			end
			if closed[node] ~= stamp and (seen[node] ~= stamp or ng < g[node]) then
				g[node], pos[node], seen[node], parent[node], via[node], entry[node] = ng, mp, stamp, u, extra, 0
				push(open, node, ng + vector.magnitude(goalP - mp) * scale)
			end
		end
	end

	-- Whether point p of node u's triangle is cut off, inside it, from where u was entered: its
	-- edge, or the start point, or a link's landing (ticket 27's barriers). A point on the
	-- triangle's boundary is undecided by the barrier polygons' inside test (and one on a wall
	-- can't be pushed out), so it is moved a millionth of the way to the centroid first, in f64.
	local function stranded(u: number, p: vector): boolean
		local t = triangleOf(u)
		local ia, ib, ic = GetTriangle(s, t)
		local a, b, c = GetVertex(s, ia), GetVertex(s, ib), GetVertex(s, ic)
		local x = p.X + ((a.X + b.X + c.X) / 3 - p.X) * 1e-6
		local z = p.Z + ((a.Z + b.Z + c.Z) / 3 - p.Z) * 1e-6
		if u == startT then
			return Clearance.Separated(s, t, radius, startP.X, startP.Z, x, z)
		elseif via[u] == 0 then
			return cutOff(s, t, entry[u], radius, x, z)
		end
		local _, _, kind, _, _, landing = GetExtra(s, via[u])
		if kind == EXTRA_LINK then
			return Clearance.Separated(s, t, radius, landing.X, landing.Z, x, z)
		end
		return cutOff(s, t, seamEdge(s, t, triangleOf(parent[u])), radius, x, z)
	end

	-- Whether the end FindPath makes of point p of node u's triangle, pushed off the walls
	-- (which can carry it into a neighbour, out of a sliver too thin to stand in), stands where
	-- a node the search closed reaches it. The start triangle's own point is judged where it
	-- is, as before: a start against a wall may be boxed into its triangle by the widths, and
	-- its push is the way out. Like ticket 27's checks this is sound, not complete: an end the
	-- push leaves in a pinch narrower than 2r can't be placed, and passes.
	local function reachable(u: number, p: vector): boolean
		if u == startT then
			return not stranded(u, p)
		end
		local q, t = Queries.Push(s, triangleOf(u), p, radius, costs)
		local nodes = if t == startT then { startT, startAgain } elseif t == goalT then { goalAgain } else { t }
		for _, w in nodes do
			if closed[w] == stamp and not stranded(w, q) then
				return true
			end
		end
		return false
	end

	local last, endP = goalNode, goalP
	if status ~= "Success" then
		-- The reached triangle holding the point nearest the goal (not the nearest node). The
		-- start is always in the list: it is popped first and is not the goal. The goal's own
		-- triangle is left out (reached, it was cut off from the goal), and so is the rest of
		-- the start's once a chain cut the start off in it: the start then stays put. A point
		-- whose pushed end a barrier strands is left out too, and the next best is taken.
		-- ponytail: a rescan per stranded point; keep a sorted list if many strand at once.
		local stranding: { [number]: boolean } = {}
		repeat
			local best = vector.magnitude(goalP - startP)
			last, endP = startT, startP
			for _, u in closedList do
				local t = triangleOf(u)
				if t ~= goalT and not (u == startT and startCut) and not stranding[u] then
					local p = Snap.ClosestOnTriangle(s, t, goalP)
					local d = vector.magnitude(goalP - p)
					if d < best then
						best, last, endP = d, u, p
					end
				end
			end
			local done = width == 0 or endP == startP or reachable(last, endP)
			stranding[last] = true
		until done
	end
	local corridor, vias = {}, {}
	local u = last
	while u ~= 0 do
		table.insert(corridor, triangleOf(u))
		table.insert(vias, if u == startT then 0 else via[u])
		u = parent[u]
	end
	local count = #corridor
	for i = 1, count // 2 do
		corridor[i], corridor[count + 1 - i] = corridor[count + 1 - i], corridor[i]
		vias[i], vias[count + 1 - i] = vias[count + 1 - i], vias[i]
	end
	return status, corridor, vias, endP, g[last]
end

return Search
