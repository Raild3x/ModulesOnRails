--!strict
-- Authors: Logan Hunt (Raildex)
-- May 13, 2026
--[=[
	@class DFS

	Depth-First Search traversal algorithms.

	DFS explores a graph by going as deep as possible along each branch before
	backtracking.  It is the basis for cycle detection, topological sorting,
	and strongly connected component algorithms (see [Connectivity](/api/Connectivity)
	and [TopologicalSort](/api/TopologicalSort)).

	All implementations here are **iterative** (stack-based) rather than
	recursive, avoiding stack-overflow issues on large graphs.

	All functions accept either callback form for `GetNeighbors` — see
	[GraphUtil](/api/GraphUtil) for details.

	### Example graph

	```lua
	--  A ──→ B ──→ D
	--  │
	--  ↓
	--  C ──→ E

	local adj = {
	    A = {"B", "C"},
	    B = {"D"},
	    C = {"E"},
	    D = {},
	    E = {},
	}

	local function getNeighbors(v)
	    return adj[v]
	end
	```

	:::note DFS traversal order
	Because the iterative stack reverses insertion order relative to visited
	order, the traversal visits the **last** neighbour listed first.  This
	differs from recursive DFS which visits the first neighbour first.
	If a specific neighbour order matters, sort the neighbour list before
	returning it from `getNeighbors`.
	:::
]=]

local Types = require("./Types")

type GetNeighbors<V> = Types.GetNeighbors<V>
type Iterator<V> = Types.Iterator<V>

local DFS = {}

--[=[
	@within DFS

	Visits every vertex reachable from `start` in depth-first order and
	returns them as an ordered array.

	```lua
	local visited = DFS.toArray("A", getNeighbors)
	-- e.g. { "A", "C", "E", "B", "D" }
	```

	*Time complexity:* `O(V + E)`
]=]
function DFS.toArray<V>(start: V, getNeighbors: GetNeighbors<V>): { V }
	local result: { V } = {}
	local visited: { [V]: boolean } = {}
	local stack: { V } = { start }

	while #stack > 0 do
		local vertex: V = table.remove(stack) :: V

		if not visited[vertex] then
			visited[vertex] = true
			table.insert(result, vertex)

			for neighbor in Types.eachNeighbor(vertex, getNeighbors) do
				if not visited[neighbor] then
					table.insert(stack, neighbor)
				end
			end
		end
	end

	return result
end

--[=[
	@within DFS

	Visits every vertex reachable from `start` in depth-first order and
	returns a set `{ [V]: true }` of all visited vertices.

	```lua
	local reachable = DFS.toSet("A", getNeighbors)
	print(reachable["D"]) -- true
	print(reachable["Z"]) -- nil (unreachable)
	```

	*Time complexity:* `O(V + E)`
]=]
function DFS.toSet<V>(start: V, getNeighbors: GetNeighbors<V>): { [V]: boolean }
	local visited: { [V]: boolean } = {}
	local stack: { V } = { start }

	while #stack > 0 do
		local vertex: V = table.remove(stack) :: V

		if not visited[vertex] then
			visited[vertex] = true

			for neighbor in Types.eachNeighbor(vertex, getNeighbors) do
				if not visited[neighbor] then
					table.insert(stack, neighbor)
				end
			end
		end
	end

	return visited
end

--[=[
	@within DFS

	Returns a lazy iterator that yields vertices one at a time in
	depth-first order.  The iterator drives the DFS internally via a
	closure — no coroutines are used.

	Aliased as [`DFS.forEach`](#forEach).

	```lua
	local next = DFS.toIterator("A", getNeighbors)
	print(next()) -- "A"
	print(next()) -- first deep branch vertex
	-- ...
	print(next()) -- nil  (exhausted)
	```

	:::tip for-loop usage
	```lua
	for vertex in DFS.toIterator("A", getNeighbors) do
	    print(vertex)
	end
	```
	:::

	*Time complexity per call:* amortised `O(degree(V))`
]=]
function DFS.toIterator<V>(start: V, getNeighbors: GetNeighbors<V>): Iterator<V>
	local stack: { V } = { start }
	local visited: { [V]: boolean } = {}

	return function(): V?
		while #stack > 0 do
			local vertex: V = table.remove(stack) :: V

			if not visited[vertex] then
				visited[vertex] = true

				for neighbor in Types.eachNeighbor(vertex, getNeighbors) do
					if not visited[neighbor] then
						table.insert(stack, neighbor)
					end
				end

				return vertex
			end
		end

		return nil
	end
end

--[=[
	@within DFS
	@function forEach
	@param start V
	@param getNeighbors GetNeighbors<V>
	@return Iterator<V>

	Alias of [`DFS.toIterator`](#toIterator).
]=]
DFS.forEach = DFS.toIterator

--[=[
	@within DFS

	Performs a full DFS from `start` and returns a **parent map** —
	a table where every reachable vertex maps to the vertex it was
	discovered from.  The start vertex maps to itself.

	Useful for reconstructing the DFS spanning tree or testing
	reachability across all targets in one pass:

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

	local parents = DFS.toParentMap("A", getNeighbors)
	print(pathTo(parents, "A", "E"))  -- e.g. { "A", "C", "E" }
	```

	:::note Not shortest path
	DFS parent maps do **not** guarantee shortest (fewest-hop) paths.
	Use [`BFS.toParentMap`](/api/BFS#toParentMap) or
	[`BFS.shortestPath`](/api/BFS#shortestPath) when hop-count matters.
	:::

	*Time complexity:* `O(V + E)`
]=]
function DFS.toParentMap<V>(start: V, getNeighbors: GetNeighbors<V>): { [V]: V }
	local parent: { [V]: V } = { [start] = start }
	local stack: { V } = { start }

	while #stack > 0 do
		local vertex: V = table.remove(stack) :: V

		-- Skip stale stack entries (vertex already assigned a parent)
		if parent[vertex] == nil then
			continue
		end

		for neighbor in Types.eachNeighbor(vertex, getNeighbors) do
			if not parent[neighbor] then
				parent[neighbor] = vertex
				table.insert(stack, neighbor)
			end
		end
	end

	return parent
end

return DFS
