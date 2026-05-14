--!strict
-- Authors: Logan Hunt (Raildex)
-- May 13, 2026
--[=[
	@class Dijkstra

	Dijkstra's shortest-path and priority-ordered traversal algorithms.

	Dijkstra's algorithm finds the shortest (lowest total weight) path from a
	source vertex to one or all reachable vertices in a graph with
	**non-negative edge weights**.  It uses a min-heap priority queue to always
	expand the cheapest known vertex next.

	:::caution Non-negative weights only
	Dijkstra's algorithm produces incorrect results if any edge weight is
	negative.  Use [BellmanFord](/api/BellmanFord) when negative weights are
	possible.
	:::

	:::tip Priority traversal
	[`Dijkstra.forEach`](#forEach) and [`Dijkstra.toArray`](#toArray) let you
	traverse **all** reachable vertices in ascending accumulated-cost order —
	useful for budget-limited flood fill, range queries, and influence-map
	generation:
	```lua
	for vertex, costFromStart in Dijkstra.forEach(origin, getNeighbors, getWeight) do
	    if costFromStart > budget then break end
	    markInRange(vertex)
	end
	```
	:::

	All functions accept either callback form for `GetNeighbors` — see
	[GraphUtil](/api/GraphUtil) for details.

	### Example graph

	```lua
	--   A --2-- B --1-- D
	--   |               |
	--   3               4
	--   |               |
	--   C ------5------ +

	local weights = {
	    A = { B = 2, C = 3 },
	    B = { A = 2, D = 1 },
	    C = { A = 3, D = 5 },
	    D = { B = 1, C = 5 },
	}

	local function getNeighbors(v) return weights[v] and (function()
	    local keys = {}
	    for k in pairs(weights[v]) do table.insert(keys, k) end
	    return keys
	end)() or {} end

	local function getWeight(from, to) return weights[from][to] end
	```
]=]

local Types = require(script.Parent.Types)
local Heap = require(script.Parent.Parent.Heap)

type GetNeighbors<V> = Types.GetNeighbors<V>
type GetWeight<V> = Types.GetWeight<V>
type PathResult<V> = Types.PathResult<V>

--- A single entry in the result of [`Dijkstra.toArray`](#toArray).
export type VisitRecord<V> = {
	--- The visited vertex.
	vertex: V,
	--- Total accumulated cost from the start vertex to this vertex.
	cost: number,
}

local Dijkstra = {}

--------------------------------------------------------------------------------
--// Helpers //--
--------------------------------------------------------------------------------

-- Reconstructs an ordered path from a parent-pointer table.
local function reconstructPath<V>(start: V, goal: V, parent: { [V]: V }): { V }
	local path: { V } = {}
	local cur: V? = goal
	while cur ~= nil do
		local c: V = cur :: V
		table.insert(path, 1, c)
		if c == start then
			break
		end
		cur = parent[c]
	end
	return path
end

--------------------------------------------------------------------------------
--// Public API //--
--------------------------------------------------------------------------------

--[=[
	@within Dijkstra

	Finds the **shortest weighted path** from `start` to `goal` and returns a
	[PathResult](/api/GraphUtil#PathResult), or `nil` if `goal` is unreachable.

	```lua
	local result = Dijkstra.shortestPath("A", "D", getNeighbors, getWeight)
	-- result.path == { "A", "B", "D" }
	-- result.cost == 3   (2 + 1)
	```

	*Time complexity:* `O((V + E) log V)` with a binary min-heap.
]=]
function Dijkstra.shortestPath<V>(
	start: V,
	goal: V,
	getNeighbors: GetNeighbors<V>,
	getWeight: GetWeight<V>
): PathResult<V>?
	if start == goal then
		return { path = { start }, cost = 0 }
	end

	local dist: { [V]: number } = { [start] = 0 }
	local parent: { [V]: V } = {}
	local visited: { [V]: boolean } = {}
	local heap = Heap.min()
	heap:Push(start, 0)

	while not heap:IsEmpty() do
		local rawVertex, rawCost = heap:Pop()
		if not rawVertex then
			break
		end
		local vertex: V = (rawVertex :: any) :: V
		local cost: number = (rawCost :: any) :: number

		if visited[vertex] then
			continue
		end
		visited[vertex] = true

		if vertex == goal then
			return { path = reconstructPath(start, goal, parent), cost = cost }
		end

		for neighbor in Types.eachNeighbor(vertex, getNeighbors) do
			if visited[neighbor] then
				continue
			end
			local newCost = cost + getWeight(vertex, neighbor)
			if newCost < (dist[neighbor] or math.huge) then
				dist[neighbor] = newCost
				parent[neighbor] = vertex
				heap:Push(neighbor, newCost)
			end
		end
	end

	return nil
end

--[=[
	@within Dijkstra

	Runs Dijkstra from `start` to completion and returns a map of every
	reachable vertex to its shortest distance from `start`.  Unreachable
	vertices are absent from the table.

	```lua
	local d = Dijkstra.distances("A", getNeighbors, getWeight)
	print(d["B"]) -- 2
	print(d["C"]) -- 3
	print(d["D"]) -- 3
	```

	*Time complexity:* `O((V + E) log V)` with a binary min-heap.
]=]
function Dijkstra.distances<V>(start: V, getNeighbors: GetNeighbors<V>, getWeight: GetWeight<V>): { [V]: number }
	local dist: { [V]: number } = { [start] = 0 }
	local visited: { [V]: boolean } = {}
	local heap = Heap.min()
	heap:Push(start, 0)

	while not heap:IsEmpty() do
		local rawVertex, rawCost = heap:Pop()
		if not rawVertex then
			break
		end
		local vertex: V = (rawVertex :: any) :: V
		local cost: number = (rawCost :: any) :: number

		if visited[vertex] then
			continue
		end
		visited[vertex] = true

		for neighbor in Types.eachNeighbor(vertex, getNeighbors) do
			if visited[neighbor] then
				continue
			end
			local newCost = cost + getWeight(vertex, neighbor)
			if newCost < (dist[neighbor] or math.huge) then
				dist[neighbor] = newCost
				heap:Push(neighbor, newCost)
			end
		end
	end

	return dist
end

--[=[
	@within Dijkstra

	Returns a lazy iterator that yields `(vertex, costFromStart)` pairs in
	**ascending accumulated-cost order** — every vertex is visited before any
	vertex that is reachable through it at higher cost.

	The iterator drives the heap expansion internally via a closure; no
	coroutines are used.  You can `break` early to stop expansion, which is
	the key advantage over [`Dijkstra.distances`](#distances).

	```lua
	-- Visit all nodes within a travel budget of 5
	for vertex, cost in Dijkstra.forEach(origin, getNeighbors, getWeight) do
	    if cost > 5 then break end
	    table.insert(inRange, vertex)
	end
	```

	:::tip for-loop usage
	```lua
	for vertex, cost in Dijkstra.forEach(start, getNeighbors, getWeight) do
	    print(vertex, cost)
	end
	```
	:::

	*Time complexity per call:* amortised `O(degree(V) · log V)`
]=]
function Dijkstra.forEach<V>(start: V, getNeighbors: GetNeighbors<V>, getWeight: GetWeight<V>): () -> (V?, number?)
	local dist: { [V]: number } = { [start] = 0 }
	local visited: { [V]: boolean } = {}
	local heap = Heap.min()
	heap:Push(start, 0)

	return function(): (V?, number?)
		while not heap:IsEmpty() do
			local rawVertex, rawCost = heap:Pop()
			if not rawVertex then
				break
			end
			local vertex: V = (rawVertex :: any) :: V
			local cost: number = (rawCost :: any) :: number

			if visited[vertex] then
				continue
			end
			visited[vertex] = true

			for neighbor in Types.eachNeighbor(vertex, getNeighbors) do
				if visited[neighbor] then
					continue
				end
				local newCost = cost + getWeight(vertex, neighbor)
				if newCost < (dist[neighbor] or math.huge) then
					dist[neighbor] = newCost
					heap:Push(neighbor, newCost)
				end
			end

			return vertex, cost
		end
		return nil, nil
	end
end

--[=[
	@within Dijkstra

	Runs Dijkstra from `start` to completion and returns an array of
	[VisitRecord](/api/Dijkstra#VisitRecord) values in ascending accumulated-cost
	order.

	```lua
	local records = Dijkstra.toArray("A", getNeighbors, getWeight)
	for _, record in records do
	    print(record.vertex, record.cost)
	end
	-- A  0
	-- B  2
	-- C  3
	-- D  3
	```

	*Time complexity:* `O((V + E) log V)` with a binary min-heap.
]=]
function Dijkstra.toArray<V>(start: V, getNeighbors: GetNeighbors<V>, getWeight: GetWeight<V>): { VisitRecord<V> }
	local result: { VisitRecord<V> } = {}
	local iter = Dijkstra.forEach(start, getNeighbors, getWeight)

	while true do
		local vertex, cost = iter()
		if not vertex then
			break
		end
		table.insert(result, { vertex = (vertex :: any) :: V, cost = (cost :: any) :: number })
	end

	return result
end

return Dijkstra
