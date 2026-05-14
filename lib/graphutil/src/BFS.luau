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
	--   A — B — D
	--   |       |
	--   C ——————+

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

local Types = require(script.Parent.Types)

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

	```lua
	local next = BFS.forEach("A", getNeighbors)
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
	for vertex in BFS.forEach("A", getNeighbors) do
	    print(vertex)
	end
	```
	:::

	*Time complexity per call:* amortised `O(degree(V))`
]=]
function BFS.forEach<V>(start: V, getNeighbors: GetNeighbors<V>): Iterator<V>
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
