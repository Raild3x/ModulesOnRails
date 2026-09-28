--!strict
-- Probe (ticket 14): where A* places a triangle's node, and what that does to path length.
--   centre:  node at the triangle centre (fixed).
--   entry:   node at the midpoint of the edge it was entered by (Recast; parent-dependent).
--   edges:   one node per (triangle, entry edge) at that edge's midpoint (fixed positions).
-- Each variant's corridor is funnelled; lengths are compared per query against the shortest
-- of the three. Timing covers search only.
local NavMesh = require("../../../lib/navmesh/src/NavMesh")
local Storage = require("../../../lib/navmesh/src/Storage")
local Snap = require("../../../lib/navmesh/src/Snap")
local Funnel = require("../../../lib/navmesh/src/Funnel")
local OL = require("../../../lib/navmesh/src/OpenList")
local TileSize = require("./TileSize")

local function verts(s, t)
	local a, b, c = Storage.GetTriangle(s, t)
	return { a, b, c }
end
local function mid(s, t, e): vector
	local vs = verts(s, t)
	return (Storage.GetVertex(s, vs[e % 3 + 1]) + Storage.GetVertex(s, vs[(e + 1) % 3 + 1])) * 0.5
end

local function corridorOf(parent, last)
	local c = {}
	local t = last
	while t ~= 0 do
		table.insert(c, 1, t)
		t = parent[t]
	end
	return c
end

-- centre / entry: triangle nodes.
local function triSearch(s, st, sp: vector, gt, gp: vector, entry: boolean)
	local g, parent, pos, closed = {}, {}, {}, {}
	local open = OL.new()
	g[st], parent[st], pos[st] = 0, 0, sp
	OL.Push(open, st, 0)
	local pops = 0
	while true do
		local t = OL.Pop(open)
		if t == 0 then
			return nil, pops
		end
		if closed[t] then
			continue
		end
		closed[t] = true
		pops += 1
		if t == gt then
			return corridorOf(parent, t), pops
		end
		local tp = pos[t]
		for e = 1, 3 do
			local m = Storage.GetNeighbor(s, t, e)
			if m == 0 or closed[m] then
				continue
			end
			local mp = if m == gt then gp elseif entry then mid(s, t, e) else Storage.GetTriangleCentre(s, m)
			local ng = g[t] + vector.magnitude(mp - tp)
			if g[m] == nil or ng < g[m] then
				g[m], parent[m], pos[m] = ng, t, mp
				OL.Push(open, m, ng + vector.magnitude(gp - mp))
			end
		end
	end
end

-- edges: node id (t - 1) * 3 + e = "in triangle t, entered across its edge e"; START sits at
-- sp in st, GOAL at gp.
local function edgeSearch(s, st, sp: vector, gt, gp: vector)
	local n = Storage.TriangleCount(s)
	local GOAL, START = 3 * n + 1, 3 * n + 2
	local g, parent, closed = { [START] = 0 }, { [START] = 0 }, {}
	local open = OL.new()
	OL.Push(open, START, 0)
	local pops = 0
	local function nodeTri(id)
		return if id == START then st else (id - 1) // 3 + 1
	end
	local function nodePos(id): vector
		if id == START then
			return sp
		end
		return mid(s, (id - 1) // 3 + 1, (id - 1) % 3 + 1)
	end
	while true do
		local id = OL.Pop(open)
		if id == 0 then
			return nil, pops
		end
		if closed[id] then
			continue
		end
		closed[id] = true
		pops += 1
		if id == GOAL then
			local c = { gt }
			local k = parent[GOAL]
			while k ~= 0 do
				local t = nodeTri(k)
				if c[1] ~= t then
					table.insert(c, 1, t)
				end
				k = parent[k]
			end
			return c, pops
		end
		local t = nodeTri(id)
		local p = nodePos(id)
		local function relax(nid, np: vector)
			if closed[nid] then
				return
			end
			local ng = g[id] + vector.magnitude(np - p)
			if g[nid] == nil or ng < g[nid] then
				g[nid], parent[nid] = ng, id
				OL.Push(open, nid, ng + vector.magnitude(gp - np))
			end
		end
		if t == gt then
			relax(GOAL, gp)
		end
		for e = 1, 3 do
			local m = Storage.GetNeighbor(s, t, e)
			if m == 0 then
				continue
			end
			for e2 = 1, 3 do
				if Storage.GetNeighbor(s, m, e2) == t then
					relax((m - 1) * 3 + e2, mid(s, m, e2))
				end
			end
		end
	end
end

local function length(points: { vector }): number
	local L = 0
	for i = 2, #points do
		L += vector.magnitude(points[i] - points[i - 1])
	end
	return L
end

local function probe(name: string, desc: any, lo: number, hi: number, queries: number)
	local mesh = NavMesh.Build(desc)
	local seed = 12345
	local function rnd()
		seed = (seed * 1103515245 + 12345) % 2147483648
		return lo + (hi - lo) * seed / 2147483648
	end
	local ext = vector.create(0.5, 4, 0.5)
	local stats = {
		centre = { worst = 1, sum = 0, pops = 0, time = 0 },
		entry = { worst = 1, sum = 0, pops = 0, time = 0 },
		edges = { worst = 1, sum = 0, pops = 0, time = 0 },
	}
	local done = 0
	while done < queries do
		local st, sp = Snap.Snap(mesh, vector.create(rnd(), 0, rnd()), ext, {})
		local gt, gp = Snap.Snap(mesh, vector.create(rnd(), 0, rnd()), ext, {})
		if sp == nil or gp == nil then
			continue
		end
		local lens, pops, times = {}, {}, {}
		local c0 = os.clock()
		local c1, p1 = triSearch(mesh, st, sp, gt, gp, false)
		times.centre = os.clock() - c0
		c0 = os.clock()
		local c2, p2 = triSearch(mesh, st, sp, gt, gp, true)
		times.entry = os.clock() - c0
		c0 = os.clock()
		local c3, p3 = edgeSearch(mesh, st, sp, gt, gp)
		times.edges = os.clock() - c0
		if c1 == nil then
			assert(c2 == nil and c3 == nil, "reachability disagrees")
			continue
		end
		assert(c2 and c3, "reachability disagrees")
		lens.centre = length((Funnel.StringPull(mesh, c1, sp, gp, 0)))
		lens.entry = length((Funnel.StringPull(mesh, c2, sp, gp, 0)))
		lens.edges = length((Funnel.StringPull(mesh, c3, sp, gp, 0)))
		pops.centre, pops.entry, pops.edges = p1, p2, p3
		local best = math.min(lens.centre, lens.entry, lens.edges)
		if best < 1e-9 then
			continue
		end
		done += 1
		for k, st_ in stats do
			local r = lens[k] / best
			st_.worst = math.max(st_.worst, r)
			st_.sum += r
			st_.pops += pops[k]
			st_.time += times[k]
		end
	end
	print(`{name} ({Storage.TriangleCount(mesh)} tris, {queries} queries)`)
	for _, k in { "centre", "entry", "edges" } do
		local st_ = stats[k]
		print(
			string.format(
				"  %-7s mean x%.4f  worst x%.3f  pops/query %.0f  ms/query %.3f",
				k,
				st_.sum / queries,
				st_.worst,
				st_.pops / queries,
				1000 * st_.time / queries
			)
		)
	end
end

probe("Courtyard", NavMesh.Fixtures.Courtyard.Desc, 0, 30, 300)
for _, side in { 64, 128, 256 } do
	local desc = TileSize.Map(side, 7)
	probe(`Map{side}`, desc, 0, side, if side == 256 then 100 else 200)
end
