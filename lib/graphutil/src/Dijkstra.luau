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
	[`Dijkstra.toIterator`](#toIterator) and [`Dijkstra.toArray`](#toArray) let
	you traverse **all** reachable vertices in ascending accumulated-cost
	order — useful for budget-limited flood fill, range queries, and
	influence-map generation:
	```lua
	for vertex, costFromStart in Dijkstra.toIterator(origin, getNeighbors, getWeight) do
	    if costFromStart > budget then break end
	    markInRange(vertex)
	end
	```
	:::

	All functions accept either callback form for `GetNeighbors` — see
	[GraphUtil](/api/GraphUtil) for details.

	### Example graph

	```lua
	--      2       1
	--  A ───── B ───── D
	--  │               │
	--  3               5
	--  │               │
	--  C ───────────────┘

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

local Types = require("./Types")
local Heap = require("../Heap")

type GetNeighbors<V> = Types.GetNeighbors<V>
type GetWeight<V> = Types.GetWeight<V>
type ShouldStop<V> = Types.ShouldStop<V>
type PathResult<V> = Types.PathResult<V>

-- A single entry in the result of [`Dijkstra.toArray`](#toArray).
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
	local cur: V = goal
	table.insert(path, 1, cur)
	while cur ~= start do
		cur = parent[cur]
		table.insert(path, 1, cur)
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

	Pass an optional [ShouldStop](/api/GraphUtil#ShouldStop) predicate to abort a
	long-running search — checked once per expanded vertex (after the goal check),
	returning `true` stops the search and returns `nil`:

	```lua
	-- Stop once the cheapest frontier vertex exceeds a budget of 500.
	local result = Dijkstra.shortestPath(start, goal, getNeighbors, getWeight, function(_vertex, cost)
	    return cost > 500
	end)
	```

	*Time complexity:* `O((V + E) log V)` with a binary min-heap.
]=]
function Dijkstra.shortestPath<V>(
	start: V,
	goal: V,
	getNeighbors: GetNeighbors<V>,
	getWeight: GetWeight<V>,
	shouldStop: ShouldStop<V>?
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
		-- The IsEmpty check guarantees Pop returns a value.
		local rawVertex, rawCost = heap:Pop()
		local vertex: V = (rawVertex :: any) :: V
		local cost: number = (rawCost :: any) :: number

		if visited[vertex] then
			continue
		end
		visited[vertex] = true

		if vertex == goal then
			return { path = reconstructPath(start, goal, parent), cost = cost }
		end

		-- Cooperative cancellation: abort once the caller's predicate fires.
		if shouldStop and shouldStop(vertex, cost) then
			break
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

	Finds the **shortest weighted path** between `start` and `goal` by
	running Dijkstra from both ends simultaneously — alternately expanding
	whichever heap has the cheaper next vertex — and stopping as soon as the
	two searches are provably guaranteed to have met at the shortest
	possible point. Returns the same [PathResult](/api/GraphUtil#PathResult)
	as [`Dijkstra.shortestPath`](#shortestPath), or `nil` if `goal` is
	unreachable.

	```lua
	local result = Dijkstra.bidirectionalShortestPath("A", "D", getNeighbors, getWeight)
	-- result.path == { "A", "B", "D" }
	-- result.cost == 3
	```

	:::caution Directed graphs
	Growing a search backward from `goal` requires walking edges in
	reverse. By default this function reuses `getNeighbors` for both
	directions, which is only correct for **undirected** graphs. For a
	directed graph, pass a callback that returns the *predecessors* of a
	vertex (i.e. `getReversedNeighbors(v)` returns every `u` such that
	`u → v` is an edge) — the edge weight is still looked up as
	`getWeight(u, v)`, so no separate reverse-weight callback is needed:

	```lua
	-- Directed graph where reverseAdj[v] lists v's predecessors
	local function getReversedNeighbors(v)
	    return reverseAdj[v]
	end

	local result = Dijkstra.bidirectionalShortestPath(
	    "A", "D", getNeighbors, getWeight, getReversedNeighbors
	)
	```
	:::

	An optional [ShouldStop](/api/GraphUtil#ShouldStop) predicate (passed after
	`getReversedNeighbors`) aborts the search and returns `nil` — it is checked
	each time either side settles a vertex.

	*Time complexity:* `O((V + E) log V)`, but typically explores far fewer
	vertices in practice since each side only has to reach roughly halfway.
]=]
function Dijkstra.bidirectionalShortestPath<V>(
	start: V,
	goal: V,
	getNeighbors: GetNeighbors<V>,
	getWeight: GetWeight<V>,
	getReversedNeighbors: GetNeighbors<V>?,
	shouldStop: ShouldStop<V>?
): PathResult<V>?
	if start == goal then
		return { path = { start }, cost = 0 }
	end

	local getReverse: GetNeighbors<V> = getReversedNeighbors or getNeighbors

	local fDist: { [V]: number } = { [start] = 0 }
	local bDist: { [V]: number } = { [goal] = 0 }
	local fParent: { [V]: V } = {}
	local bParent: { [V]: V } = {}
	local fSettled: { [V]: boolean } = {}
	local bSettled: { [V]: boolean } = {}

	local fHeap = Heap.min()
	local bHeap = Heap.min()
	fHeap:Push(start, 0)
	bHeap:Push(goal, 0)

	local best = math.huge
	local meet: V? = nil
	local stopped = false

	-- Tentative distances are always valid upper bounds (non-negative
	-- weights), so any vertex known from both sides is a safe candidate
	-- for the best total path length found so far — keep the cheapest.
	local function tryMeet(vertex: V, fd: number?, bd: number?)
		fd = fd or fDist[vertex]
		bd = bd or bDist[vertex]
		if fd ~= nil and bd ~= nil and (fd :: number) + (bd :: number) < best then
			best = (fd :: number) + (bd :: number)
			meet = vertex
		end
	end

	while not fHeap:IsEmpty() and not bHeap:IsEmpty() do
		-- Heap tops are valid lower bounds on anything left unsettled on
		-- that side. Once neither side can possibly beat `best`, stop.
		local _, fTop = fHeap:Peek()
		local _, bTop = bHeap:Peek()
		if (fTop :: number) + (bTop :: number) >= best then
			break
		end

		if (fTop :: number) <= (bTop :: number) then
			local rawVertex, rawCost = fHeap:Pop()
			local vertex: V = rawVertex :: V
			local cost: number = rawCost :: number
			if fSettled[vertex] then
				continue
			end
			fSettled[vertex] = true

			-- Cooperative cancellation: abort once the caller's predicate fires.
			if shouldStop and shouldStop(vertex, cost) then
				stopped = true
				break
			end

			for neighbor in Types.eachNeighbor(vertex, getNeighbors) do
				local newDist = cost + getWeight(vertex, neighbor)
				if newDist < (fDist[neighbor] or math.huge) then
					fDist[neighbor] = newDist
					fParent[neighbor] = vertex
					fHeap:Push(neighbor, newDist)
				end
				tryMeet(neighbor, fDist[neighbor], bDist[neighbor])
			end
		else
			local rawVertex, rawCost = bHeap:Pop()
			local vertex: V = rawVertex :: V
			local cost: number = rawCost :: number
			if bSettled[vertex] then
				continue
			end
			bSettled[vertex] = true

			-- Cooperative cancellation: abort once the caller's predicate fires.
			if shouldStop and shouldStop(vertex, cost) then
				stopped = true
				break
			end

			for predecessor in Types.eachNeighbor(vertex, getReverse) do
				local newDist = cost + getWeight(predecessor, vertex)
				if newDist < (bDist[predecessor] or math.huge) then
					bDist[predecessor] = newDist
					bParent[predecessor] = vertex
					bHeap:Push(predecessor, newDist)
				end
				tryMeet(predecessor, fDist[predecessor], bDist[predecessor])
			end
		end
	end

	if stopped or meet == nil then
		return nil
	end

	-- Reconstruct start → meet via fParent, then meet → goal via bParent.
	-- The forward chain is guaranteed to reach start; the backward chain may
	-- be empty when meet == goal, so it keeps its nil check.
	local path: { V } = {}
	local forward: V = meet :: V
	table.insert(path, 1, forward)
	while forward ~= start do
		forward = fParent[forward]
		table.insert(path, 1, forward)
	end

	local cur: V? = bParent[meet :: V]
	while cur ~= nil do
		local c: V = cur :: V
		table.insert(path, c)
		if c == goal then
			break
		end
		cur = bParent[c]
	end

	return { path = path, cost = best }
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

	Pass an optional [ShouldStop](/api/GraphUtil#ShouldStop) predicate to abort a
	long-running flood — checked once per settled vertex. Unlike the path-finders,
	on early stop this returns the **partial** distance map accumulated so far
	(every vertex settled before the stop is present and final):

	```lua
	-- Only compute distances out to a budget of 10.
	local d = Dijkstra.distances(start, getNeighbors, getWeight, function(_vertex, cost)
	    return cost > 10
	end)
	```

	*Time complexity:* `O((V + E) log V)` with a binary min-heap.
]=]
function Dijkstra.distances<V>(
	start: V,
	getNeighbors: GetNeighbors<V>,
	getWeight: GetWeight<V>,
	shouldStop: ShouldStop<V>?
): { [V]: number }
	local dist: { [V]: number } = { [start] = 0 }
	local visited: { [V]: boolean } = {}
	local heap = Heap.min()
	heap:Push(start, 0)

	while not heap:IsEmpty() do
		-- The IsEmpty check guarantees Pop returns a value.
		local rawVertex, rawCost = heap:Pop()
		local vertex: V = (rawVertex :: any) :: V
		local cost: number = (rawCost :: any) :: number

		if visited[vertex] then
			continue
		end
		visited[vertex] = true

		-- Cooperative cancellation: return the partial map accumulated so far.
		if shouldStop and shouldStop(vertex, cost) then
			break
		end

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

	Aliased as [`Dijkstra.forEach`](#forEach).

	```lua
	-- Visit all nodes within a travel budget of 5
	for vertex, cost in Dijkstra.toIterator(origin, getNeighbors, getWeight) do
	    if cost > 5 then break end
	    table.insert(inRange, vertex)
	end
	```

	:::tip for-loop usage
	```lua
	for vertex, cost in Dijkstra.toIterator(start, getNeighbors, getWeight) do
	    print(vertex, cost)
	end
	```
	:::

	*Time complexity per call:* amortised `O(degree(V) · log V)`
]=]
function Dijkstra.toIterator<V>(start: V, getNeighbors: GetNeighbors<V>, getWeight: GetWeight<V>): () -> (V?, number?)
	local dist: { [V]: number } = { [start] = 0 }
	local visited: { [V]: boolean } = {}
	local heap = Heap.min()
	heap:Push(start, 0)

	return function(): (V?, number?)
		while not heap:IsEmpty() do
			-- The IsEmpty check guarantees Pop returns a value.
			local rawVertex, rawCost = heap:Pop()
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
	@function forEach
	@param start V
	@param getNeighbors GetNeighbors<V>
	@param getWeight GetWeight<V>
	@return () -> (V?, number?)

	Alias of [`Dijkstra.toIterator`](#toIterator).
]=]
Dijkstra.forEach = Dijkstra.toIterator

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
	local iter = Dijkstra.toIterator(start, getNeighbors, getWeight)

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
