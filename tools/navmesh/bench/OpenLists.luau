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
	{ Name = "libheap", Make = function(_graph: Graph, Heap: any): OpenList
		return libheap(Heap)
	end },
	{ Name = "linear", Make = function(): OpenList
		return linear()
	end },
	{ Name = "binary", Make = function(): OpenList
		return binary()
	end },
	{ Name = "quad", Make = function(): OpenList
		return quad()
	end },
	{ Name = "binaryDK", Make = function(graph: Graph): OpenList
		return binaryDK(graph.N)
	end },
}

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
