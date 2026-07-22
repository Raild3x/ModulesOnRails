--!strict
-- Authors: Logan Hunt (Raildex)
-- May 13, 2026
--[=[
	@class BFS

	Breadth-First Search traversal and unweighted shortest-path algorithms.

	BFS explores a graph level-by-level outward from a start vertex, visiting
	all neighbours at the current depth before moving deeper.  This property
	makes it the correct choice for **unweighted shortest paths** (fewest hops).
	For weighted shortest paths, use [Dijkstra](/api/Dijkstra) or [AStar](/api/AStar).

	All functions accept either callback form for `GetNeighbors` — see
	[GraphUtil](/api/GraphUtil) for details.

	### Example graph

	```lua
	--  A ─── B ─── D
	--  │           │
	--  C ──────────┘

	local adj = {
	    A = {"B", "C"},
	    B = {"A", "D"},
	    C = {"A", "D"},
	    D = {"B", "C"},
	}

	local function getNeighbors(v)
	    return adj[v]
	end
	```
]=]

local Types = require("./Types")

type GetNeighbors<V> = Types.GetNeighbors<V>
type Iterator<V> = Types.Iterator<V>
type PathResult<V> = Types.PathResult<V>

local BFS = {}

--[=[
	@within BFS

	Visits every vertex reachable from `start` in breadth-first order and
	returns them as an ordered array.

	```lua
	local visited = BFS.toArray("A", getNeighbors)
	-- { "A", "B", "C", "D" }  (BFS level order)
	```

	*Time complexity:* `O(V + E)`
]=]
function BFS.toArray<V>(start: V, getNeighbors: GetNeighbors<V>): { V }
	local result: { V } = {}
	local visited: { [V]: boolean } = { [start] = true }
	local queue: { V } = { start }
	local head = 1

	while head <= #queue do
		local vertex: V = queue[head]
		head += 1
		table.insert(result, vertex)

		for neighbor in Types.eachNeighbor(vertex, getNeighbors) do
			if not visited[neighbor] then
				visited[neighbor] = true
				table.insert(queue, neighbor)
			end
		end
	end

	return result
end

--[=[
	@within BFS

	Visits every vertex reachable from `start` in breadth-first order and
	returns a set `{ [V]: true }` of all visited vertices.  Useful when you
	only need a reachability check rather than the traversal order itself.

	```lua
	local reachable = BFS.toSet("A", getNeighbors)
	print(reachable["D"]) -- true
	print(reachable["Z"]) -- nil (unreachable)
	```

	*Time complexity:* `O(V + E)`
]=]
function BFS.toSet<V>(start: V, getNeighbors: GetNeighbors<V>): { [V]: boolean }
	local visited: { [V]: boolean } = { [start] = true }
	local queue: { V } = { start }
	local head = 1

	while head <= #queue do
		local vertex: V = queue[head]
		head += 1

		for neighbor in Types.eachNeighbor(vertex, getNeighbors) do
			if not visited[neighbor] then
				visited[neighbor] = true
				table.insert(queue, neighbor)
			end
		end
	end

	return visited
end

--[=[
	@within BFS

	Returns a lazy iterator that yields vertices one at a time in
	breadth-first order.  The iterator drives the BFS internally via a
	closure — no coroutines are used.

	Aliased as [`BFS.forEach`](#forEach).

	```lua
	local next = BFS.toIterator("A", getNeighbors)
	print(next()) -- "A"
	print(next()) -- "B"
	print(next()) -- "C"
	-- ...
	print(next()) -- nil  (exhausted)
	```

	:::tip for-loop usage
	The iterator is compatible with a plain `for` loop since Luau supports
	`for x in fn do` for `() -> T?` iterators:
	```lua
	for vertex in BFS.toIterator("A", getNeighbors) do
	    print(vertex)
	end
	```
	:::

	*Time complexity per call:* amortised `O(degree(V))`
]=]
function BFS.toIterator<V>(start: V, getNeighbors: GetNeighbors<V>): Iterator<V>
	local queue: { V } = { start }
	local head = 1
	local visited: { [V]: boolean } = { [start] = true }

	return function(): V?
		if head > #queue then
			return nil
		end

		local vertex: V = queue[head]
		head += 1

		for neighbor in Types.eachNeighbor(vertex, getNeighbors) do
			if not visited[neighbor] then
				visited[neighbor] = true
				table.insert(queue, neighbor)
			end
		end

		return vertex
	end
end

--[=[
	@within BFS
	@function forEach
	@param start V
	@param getNeighbors GetNeighbors<V>
	@return Iterator<V>

	Alias of [`BFS.toIterator`](#toIterator).
]=]
BFS.forEach = BFS.toIterator

--[=[
	@within BFS

	Finds the **shortest path** (fewest hops / edges) from `start` to `goal`
	using BFS.  Returns a [PathResult](/api/GraphUtil#PathResult) where `cost`
	is the hop count, or `nil` if `goal` is unreachable from `start`.

	This is the correct function to use when all edges have equal (or no)
	weight.  For weighted shortest paths use [Dijkstra.shortestPath](/api/Dijkstra#shortestPath).

	```lua
	local result = BFS.shortestPath("A", "D", getNeighbors)
	-- result.path == { "A", "B", "D" }  (or { "A", "C", "D" })
	-- result.cost == 2
	```

	*Time complexity:* `O(V + E)`
]=]
function BFS.shortestPath<V>(start: V, goal: V, getNeighbors: GetNeighbors<V>): PathResult<V>?
	if start == goal then
		return { path = { start }, cost = 0 }
	end

	local parent: { [V]: V } = {}
	local visited: { [V]: boolean } = { [start] = true }
	local queue: { V } = { start }
	local head = 1
	local found = false

	while head <= #queue and not found do
		local vertex: V = queue[head]
		head += 1

		for neighbor in Types.eachNeighbor(vertex, getNeighbors) do
			if not visited[neighbor] then
				visited[neighbor] = true
				parent[neighbor] = vertex

				if neighbor == goal then
					found = true
					break
				end

				table.insert(queue, neighbor)
			end
		end
	end

	if not found then
		return nil
	end

	-- Reconstruct path by following parent pointers from goal back to start
	local path: { V } = {}
	local current: V? = goal
	while current ~= nil do
		local c: V = current :: V
		table.insert(path, 1, c)
		if c == start then
			break
		end
		current = parent[c]
	end

	return { path = path, cost = #path - 1 }
end

--[=[
	@within BFS

	Finds the **shortest path** (fewest hops) between `start` and `goal` by
	growing a BFS frontier from *both* ends simultaneously and stopping as
	soon as the two frontiers are provably guaranteed to have met at the
	shortest possible point.  Returns the same [PathResult](/api/GraphUtil#PathResult)
	as [`BFS.shortestPath`](#shortestPath), or `nil` if `goal` is unreachable.

	On large, densely-branching graphs this explores far fewer vertices than
	a single-directional search — each side only needs to reach roughly
	half the hop-distance, so the total number of vertices visited grows
	with the *branching factor to the power of half the distance* instead of
	the full distance.

	```lua
	local result = BFS.bidirectionalShortestPath("A", "D", getNeighbors)
	-- result.path == { "A", "B", "D" }  (or { "A", "C", "D" })
	-- result.cost == 2
	```

	:::caution Directed graphs
	Growing a frontier backward from `goal` requires walking edges in
	reverse.  By default this function reuses `getNeighbors` for both
	directions, which is only correct for **undirected** graphs.  For a
	directed graph, pass a third callback that returns the *predecessors* of
	a vertex (i.e. `getReversedNeighbors(v)` returns every `u` such that
	`u → v` is an edge):

	```lua
	-- Directed graph where reverseAdj[v] lists v's predecessors
	local function getReversedNeighbors(v)
	    return reverseAdj[v]
	end

	local result = BFS.bidirectionalShortestPath("A", "D", getNeighbors, getReversedNeighbors)
	```
	:::

	*Time complexity:* `O(V + E)` worst case, but typically `O(b^(d/2))` for
	a graph with branching factor `b` and hop-distance `d` between `start`
	and `goal`.
]=]
function BFS.bidirectionalShortestPath<V>(
	start: V,
	goal: V,
	getNeighbors: GetNeighbors<V>,
	getReversedNeighbors: GetNeighbors<V>?
): PathResult<V>?
	if start == goal then
		return { path = { start }, cost = 0 }
	end

	local getReverse: GetNeighbors<V> = getReversedNeighbors or getNeighbors

	-- Distance-from-root maps double as visited sets for each side.
	local fDist: { [V]: number } = { [start] = 0 }
	local bDist: { [V]: number } = { [goal] = 0 }
	local fParent: { [V]: V } = {}
	local bParent: { [V]: V } = {}

	local fQueue: { V } = { start }
	local fHead = 1
	local bQueue: { V } = { goal }
	local bHead = 1

	local best = math.huge
	local meet: V? = nil

	-- A newly-discovered vertex is a candidate meeting point only if the
	-- other side has already reached it; keep the cheapest such candidate.
	local function tryMeet(vertex: V)
		local fd, bd = fDist[vertex], bDist[vertex]
		if fd ~= nil and bd ~= nil and fd + bd < best then
			best = fd + bd
			meet = vertex
		end
	end

	while fHead <= #fQueue and bHead <= #bQueue do
		-- The FIFO queues are non-decreasing in distance, so the head of
		-- each queue is a valid lower bound on anything left to expand on
		-- that side.  Once neither side can possibly beat `best`, stop.
		local fFrontierDist = fDist[fQueue[fHead]]
		local bFrontierDist = bDist[bQueue[bHead]]
		if fFrontierDist + bFrontierDist >= best then
			break
		end

		-- Expand whichever side is currently shallower; purely a
		-- performance choice (keeps both frontiers roughly level), not
		-- required for correctness.
		if fFrontierDist <= bFrontierDist then
			local vertex: V = fQueue[fHead]
			fHead += 1
			for neighbor in Types.eachNeighbor(vertex, getNeighbors) do
				if fDist[neighbor] == nil then
					fDist[neighbor] = fFrontierDist + 1
					fParent[neighbor] = vertex
					table.insert(fQueue, neighbor)
					tryMeet(neighbor)
				end
			end
		else
			local vertex: V = bQueue[bHead]
			bHead += 1
			for neighbor in Types.eachNeighbor(vertex, getReverse) do
				if bDist[neighbor] == nil then
					bDist[neighbor] = bFrontierDist + 1
					bParent[neighbor] = vertex
					table.insert(bQueue, neighbor)
					tryMeet(neighbor)
				end
			end
		end
	end

	if meet == nil then
		return nil
	end

	-- Reconstruct start → meet via fParent, then meet → goal via bParent.
	local path: { V } = {}
	local cur: V? = meet
	while cur ~= nil do
		local c: V = cur :: V
		table.insert(path, 1, c)
		if c == start then
			break
		end
		cur = fParent[c]
	end

	cur = bParent[meet :: V]
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
	@within BFS

	Performs a full BFS from `start` and returns a **parent map** —
	a table where every reachable vertex maps to the vertex it was
	discovered from.  The start vertex maps to itself.

	This gives you the BFS spanning tree in one pass, letting you
	reconstruct the shortest hop-path to *any* reachable vertex without
	running a separate search per target:

	```lua
	local function pathTo(parentMap, start, goal)
	    if not parentMap[goal] then return nil end  -- unreachable
	    local path = {}
	    local v = goal
	    while v ~= start do
	        table.insert(path, 1, v)
	        v = parentMap[v]
	    end
	    table.insert(path, 1, start)
	    return path
	end

	local parents = BFS.toParentMap("A", getNeighbors)
	print(pathTo(parents, "A", "D"))  -- { "A", "B", "D" }
	print(pathTo(parents, "A", "C"))  -- { "A", "C" }
	```

	*Time complexity:* `O(V + E)`
]=]
function BFS.toParentMap<V>(start: V, getNeighbors: GetNeighbors<V>): { [V]: V }
	local parent: { [V]: V } = { [start] = start }
	local queue: { V } = { start }
	local head = 1

	while head <= #queue do
		local vertex: V = queue[head]
		head += 1

		for neighbor in Types.eachNeighbor(vertex, getNeighbors) do
			if not parent[neighbor] then
				parent[neighbor] = vertex
				table.insert(queue, neighbor)
			end
		end
	end

	return parent
end

return BFS
