--!strict
--[=[
	A* open-list candidates for ticket 14 (FindPath), shared by the `openlist` experiments.
	- `Flatten` turns a built mesh into triangle adjacency plus 3D centroids.
	- `MakeSearch` is the one A* every candidate runs: centroid metric, straight-line heuristic,
	  and generation-stamped scratch reused across queries.
	- `Candidates` build each open list:
	  - `linear`: no heap. Push appends, pop scans for the minimum and swap-removes it.
	  - `binary`, `quad`: inline binary and 4-ary heaps on parallel arrays. Stale entries are
	    pushed again and skipped on pop.
	  - `binaryDK`: a binary heap with a position index and in-place decrease-key.
	  - `libheap`: `lib/heap` with stale entries, since its `UpdateCost` is a linear scan.
	  - `shipped`: the shipped `lib/navmesh` OpenList (4-ary), called directly, the way FindPath
	    will use it (`MakeSearchModule`).
	- `Counted` wraps any open list to record the peak size and the pops, per query.
]=]

export type Graph = { N: number, Nbr: { number }, X: { number }, Y: { number }, Z: { number } }
export type OpenList = {
	Reset: () -> (),
	Push: (node: number, key: number) -> (),
	Pop: () -> (number, number), -- node 0 when empty
}

local OpenLists = {}

function OpenLists.Flatten(Storage: any, mesh: any): Graph
	local n = Storage.TriangleCount(mesh)
	local nbr, xs, ys, zs = table.create(3 * n, 0), table.create(n), table.create(n), table.create(n)
	for t = 1, n do
		local a, b, c = Storage.GetTriangle(mesh, t)
		local pa, pb, pc = Storage.GetVertex(mesh, a), Storage.GetVertex(mesh, b), Storage.GetVertex(mesh, c)
		xs[t], ys[t], zs[t] = (pa.X + pb.X + pc.X) / 3, (pa.Y + pb.Y + pc.Y) / 3, (pa.Z + pb.Z + pc.Z) / 3
		for e = 1, 3 do
			nbr[3 * (t - 1) + e] = Storage.GetNeighbor(mesh, t, e)
		end
	end
	return { N = n, Nbr = nbr, X = xs, Y = ys, Z = zs }
end

-- Corner-to-corner query pairs inside the largest connected component (a corner triangle can
-- sit in a pocket sealed off by obstacles): the `count` triangles nearest (0, 0) paired, in
-- order, with the `count` nearest (side, side). Returns a flat {start1, goal1, ...}.
function OpenLists.CornerQueries(graph: Graph, side: number, count: number): { number }
	local component, best = table.create(graph.N, 0), 0
	local sizes = {}
	for seed = 1, graph.N do
		if component[seed] == 0 then
			local id = #sizes + 1
			local stack, members = { seed }, 0
			component[seed] = id
			while #stack > 0 do
				local t = table.remove(stack) :: number
				members += 1
				for e = 1, 3 do
					local m = graph.Nbr[3 * (t - 1) + e]
					if m ~= 0 and component[m] == 0 then
						component[m] = id
						table.insert(stack, m)
					end
				end
			end
			sizes[id] = members
			if members > (sizes[best] or 0) then
				best = id
			end
		end
	end
	local members = {}
	for t = 1, graph.N do
		if component[t] == best then
			table.insert(members, t)
		end
	end
	local function nearest(cx: number, cz: number): { number }
		local sorted = table.clone(members)
		table.sort(sorted, function(a: number, b: number): boolean
			local da = (graph.X[a] - cx) ^ 2 + (graph.Z[a] - cz) ^ 2
			local db = (graph.X[b] - cx) ^ 2 + (graph.Z[b] - cz) ^ 2
			return da < db or (da == db and a < b)
		end)
		return sorted
	end
	local low, high = nearest(0, 0), nearest(side, side)
	local ends = table.create(2 * count)
	for q = 1, count do
		ends[2 * q - 1], ends[2 * q] = low[q], high[q]
	end
	return ends
end

-- One A* shared by every candidate. Lazy open lists may return stale entries, which the closed
-- stamp skips. Returns the optimal cost, or math.huge when unreachable.
function OpenLists.MakeSearch(graph: Graph, open: OpenList): (number, number) -> number
	local n = graph.N
	local nbr, xs, ys, zs = graph.Nbr, graph.X, graph.Y, graph.Z
	local g = table.create(n, 0)
	local seen = table.create(n, 0)
	local closed = table.create(n, 0)
	local stamp = 0
	return function(start: number, goal: number): number
		stamp += 1
		open.Reset()
		local gx, gy, gz = xs[goal], ys[goal], zs[goal]
		local function h(t: number): number
			local dx, dy, dz = xs[t] - gx, ys[t] - gy, zs[t] - gz
			return math.sqrt(dx * dx + dy * dy + dz * dz)
		end
		g[start], seen[start] = 0, stamp
		open.Push(start, h(start))
		while true do
			local t = open.Pop()
			if t == 0 then
				return math.huge
			end
			if closed[t] == stamp then
				continue
			end
			closed[t] = stamp
			if t == goal then
				return g[t]
			end
			local base = 3 * (t - 1)
			local tx, ty, tz, gt = xs[t], ys[t], zs[t], g[t]
			for e = 1, 3 do
				local m = nbr[base + e]
				if m ~= 0 and closed[m] ~= stamp then
					local dx, dy, dz = xs[m] - tx, ys[m] - ty, zs[m] - tz
					local ng = gt + math.sqrt(dx * dx + dy * dy + dz * dz)
					if seen[m] ~= stamp or ng < g[m] then
						g[m], seen[m] = ng, stamp
						open.Push(m, ng + h(m))
					end
				end
			end
		end
	end
end

-- The same A*, calling the shipped lib/navmesh OpenList module directly (the way FindPath will
-- use it), instead of through the OpenList interface's closures.
function OpenLists.MakeSearchModule(graph: Graph, M: any): (number, number) -> number
	local n = graph.N
	local nbr, xs, ys, zs = graph.Nbr, graph.X, graph.Y, graph.Z
	local g = table.create(n, 0)
	local seen = table.create(n, 0)
	local closed = table.create(n, 0)
	local stamp = 0
	local open = M.new()
	local push, pop = M.Push, M.Pop
	return function(start: number, goal: number): number
		stamp += 1
		M.Clear(open)
		local gx, gy, gz = xs[goal], ys[goal], zs[goal]
		local function h(t: number): number
			local dx, dy, dz = xs[t] - gx, ys[t] - gy, zs[t] - gz
			return math.sqrt(dx * dx + dy * dy + dz * dz)
		end
		g[start], seen[start] = 0, stamp
		push(open, start, h(start))
		while true do
			local t = pop(open)
			if t == 0 then
				return math.huge
			end
			if closed[t] == stamp then
				continue
			end
			closed[t] = stamp
			if t == goal then
				return g[t]
			end
			local base = 3 * (t - 1)
			local tx, ty, tz, gt = xs[t], ys[t], zs[t], g[t]
			for e = 1, 3 do
				local m = nbr[base + e]
				if m ~= 0 and closed[m] ~= stamp then
					local dx, dy, dz = xs[m] - tx, ys[m] - ty, zs[m] - tz
					local ng = gt + math.sqrt(dx * dx + dy * dy + dz * dz)
					if seen[m] ~= stamp or ng < g[m] then
						g[m], seen[m] = ng, stamp
						push(open, m, ng + h(m))
					end
				end
			end
		end
	end
end

local function linear(): OpenList
	local nodes, keys, size = {}, {}, 0
	return {
		Reset = function()
			size = 0
		end,
		Push = function(node, key)
			size += 1
			nodes[size], keys[size] = node, key
		end,
		Pop = function()
			if size == 0 then
				return 0, 0
			end
			local best, bestKey = 1, keys[1]
			for i = 2, size do
				if keys[i] < bestKey then
					best, bestKey = i, keys[i]
				end
			end
			local node = nodes[best]
			nodes[best], keys[best] = nodes[size], keys[size]
			size -= 1
			return node, bestKey
		end,
	}
end

local function binary(): OpenList
	local nodes, keys, size = {}, {}, 0
	return {
		Reset = function()
			size = 0
		end,
		Push = function(node, key)
			size += 1
			local i = size
			while i > 1 do
				local p = i // 2
				if keys[p] <= key then
					break
				end
				nodes[i], keys[i] = nodes[p], keys[p]
				i = p
			end
			nodes[i], keys[i] = node, key
		end,
		Pop = function()
			if size == 0 then
				return 0, 0
			end
			local top, topKey = nodes[1], keys[1]
			local node, key = nodes[size], keys[size]
			size -= 1
			local i = 1
			while true do
				local l = 2 * i
				if l > size then
					break
				end
				local r = l + 1
				local c = if r <= size and keys[r] < keys[l] then r else l
				if keys[c] >= key then
					break
				end
				nodes[i], keys[i] = nodes[c], keys[c]
				i = c
			end
			nodes[i], keys[i] = node, key
			return top, topKey
		end,
	}
end

local function quad(): OpenList
	local nodes, keys, size = {}, {}, 0
	return {
		Reset = function()
			size = 0
		end,
		Push = function(node, key)
			size += 1
			local i = size
			while i > 1 do
				local p = (i + 2) // 4
				if keys[p] <= key then
					break
				end
				nodes[i], keys[i] = nodes[p], keys[p]
				i = p
			end
			nodes[i], keys[i] = node, key
		end,
		Pop = function()
			if size == 0 then
				return 0, 0
			end
			local top, topKey = nodes[1], keys[1]
			local node, key = nodes[size], keys[size]
			size -= 1
			local i = 1
			while true do
				local first = 4 * i - 2
				if first > size then
					break
				end
				local c, ck = first, keys[first]
				for k = first + 1, math.min(first + 3, size) do
					if keys[k] < ck then
						c, ck = k, keys[k]
					end
				end
				if ck >= key then
					break
				end
				nodes[i], keys[i] = nodes[c], ck
				i = c
			end
			nodes[i], keys[i] = node, key
			return top, topKey
		end,
	}
end

local function binaryDK(capacity: number): OpenList
	local nodes, keys, size = {}, {}, 0
	local pos = table.create(capacity, 0) -- heap index of each node, 0 = not in the heap
	local function up(i: number, node: number, key: number)
		while i > 1 do
			local p = i // 2
			if keys[p] <= key then
				break
			end
			nodes[i], keys[i] = nodes[p], keys[p]
			pos[nodes[i]] = i
			i = p
		end
		nodes[i], keys[i] = node, key
		pos[node] = i
	end
	return {
		Reset = function()
			for i = 1, size do
				pos[nodes[i]] = 0
			end
			size = 0
		end,
		Push = function(node, key)
			local i = pos[node]
			if i == 0 then
				size += 1
				i = size
			end
			up(i, node, key)
		end,
		Pop = function()
			if size == 0 then
				return 0, 0
			end
			local top, topKey = nodes[1], keys[1]
			pos[top] = 0
			local node, key = nodes[size], keys[size]
			size -= 1
			if size == 0 then
				return top, topKey
			end
			local i = 1
			while true do
				local l = 2 * i
				if l > size then
					break
				end
				local r = l + 1
				local c = if r <= size and keys[r] < keys[l] then r else l
				if keys[c] >= key then
					break
				end
				nodes[i], keys[i] = nodes[c], keys[c]
				pos[nodes[i]] = i
				i = c
			end
			nodes[i], keys[i] = node, key
			pos[node] = i
			return top, topKey
		end,
	}
end

local function libheap(Heap: any): OpenList
	local heap = Heap.min()
	return {
		Reset = function()
			heap = Heap.min()
		end,
		Push = function(node, key)
			heap:Push(node, key)
		end,
		Pop = function()
			local node, key = heap:Pop()
			return node or 0, key or 0
		end,
	}
end

OpenLists.Candidates = {
	{
		Name = "libheap",
		Search = function(graph: Graph, env: any)
			return OpenLists.MakeSearch(graph, libheap(env.Heap))
		end,
	},
	{
		Name = "linear",
		Search = function(graph: Graph)
			return OpenLists.MakeSearch(graph, linear())
		end,
	},
	{
		Name = "binary",
		Search = function(graph: Graph)
			return OpenLists.MakeSearch(graph, binary())
		end,
	},
	{
		Name = "quad",
		Search = function(graph: Graph)
			return OpenLists.MakeSearch(graph, quad())
		end,
	},
	{
		Name = "binaryDK",
		Search = function(graph: Graph)
			return OpenLists.MakeSearch(graph, binaryDK(graph.N))
		end,
	},
	-- The shipped lib/navmesh/src/OpenList (4-ary), called directly.
	{
		Name = "shipped",
		Search = function(graph: Graph, env: any)
			return OpenLists.MakeSearchModule(graph, env.NavMeshOpenList)
		end,
	},
}

OpenLists.Binary = binary

-- Wraps an open list to count, per query, the peak size and the pops.
function OpenLists.Counted(open: OpenList): (OpenList, { Peak: number, Pops: number })
	local stats = { Peak = 0, Pops = 0 }
	local size = 0
	return {
		Reset = function()
			open.Reset()
			size = 0
			stats.Peak, stats.Pops = 0, 0
		end,
		Push = function(node, key)
			size += 1
			stats.Peak = math.max(stats.Peak, size)
			open.Push(node, key)
		end,
		Pop = function()
			local node, key = open.Pop()
			if node ~= 0 then
				size -= 1
				stats.Pops += 1
			end
			return node, key
		end,
	},
		stats
end

return OpenLists
