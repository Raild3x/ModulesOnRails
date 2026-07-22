--!strict
-- Authors: Logan Hunt (Raildex)
-- May 13, 2026
--[=[
	@class Connectivity

	Graph connectivity queries: reachability, components, cycle detection,
	bipartiteness, and strongly connected components.

	Most functions come in two flavours depending on whether the graph is
	**directed** or **undirected**.  Check each function's `directed` /
	`undirected` tags to confirm which it operates on.

	### `allVertices` parameter

	Several functions require `allVertices: { V }` — the complete list of
	vertices in the graph.  This is needed to find disconnected components
	and to seed multi-source traversals.

	All functions accept either callback form for `GetNeighbors` — see
	[GraphUtil](/api/GraphUtil) for details.

	### Example graphs used in the docs below

	```lua
	-- Undirected: one component A─B─C─D, plus a separate component E─F
	--  A ── B ── C ── D        E ── F
	local undirAdj = {
	    A = {"B"}, B = {"A","C"}, C = {"B","D"}, D = {"C"},
	    E = {"F"}, F = {"E"},
	}

	-- Directed: a cycle A→B→C→A, plus an acyclic edge D→E
	--  A ──→ B ──→ C          D ──→ E
	--  ▲           │
	--  └───────────┘
	local dirAdj = {
	    A = {"B"}, B = {"C"}, C = {"A"},
	    D = {"E"}, E = {},
	}
	```
]=]

local Types = require("./Types")

type GetNeighbors<V> = Types.GetNeighbors<V>

local Connectivity = {}

--------------------------------------------------------------------------------
--// Reachability //--
--------------------------------------------------------------------------------

--[=[
	@within Connectivity
	@tag directed
	@tag undirected

	Returns `true` if `goal` is reachable from `start` by following edges
	(directed or undirected depending on your `getNeighbors` callback).

	This is a single-target BFS and short-circuits as soon as `goal` is found.

	```lua
	print(Connectivity.isConnected("A", "D", getNeighbors)) -- true
	print(Connectivity.isConnected("A", "E", getNeighbors)) -- false (different component)
	```

	*Time complexity:* `O(V + E)` worst case, often much better.
]=]
function Connectivity.isConnected<V>(start: V, goal: V, getNeighbors: GetNeighbors<V>): boolean
	if start == goal then
		return true
	end

	local visited: { [V]: boolean } = { [start] = true }
	local queue: { V } = { start }
	local head = 1

	while head <= #queue do
		local vertex: V = queue[head]
		head += 1

		for neighbor in Types.eachNeighbor(vertex, getNeighbors) do
			if neighbor == goal then
				return true
			end
			if not visited[neighbor] then
				visited[neighbor] = true
				table.insert(queue, neighbor)
			end
		end
	end

	return false
end

--------------------------------------------------------------------------------
--// Connected Components (undirected) //--
--------------------------------------------------------------------------------

--[=[
	@within Connectivity
	@tag undirected

	Finds all **connected components** of an undirected graph and returns them
	as an array of vertex arrays.  Each inner array is one component; vertices
	within a component are in BFS discovery order.

	Pass a bidirectional `getNeighbors` (each undirected edge appears in both
	directions) so that every connected group is fully explored.

	```lua
	local comps = Connectivity.components({"A","B","C","D","E","F"}, getNeighbors)
	-- { {"A","B","C","D"}, {"E","F"} }  (order may vary)
	```

	*Time complexity:* `O(V + E)`
]=]
function Connectivity.components<V>(allVertices: { V }, getNeighbors: GetNeighbors<V>): { { V } }
	local visited: { [V]: boolean } = {}
	local result: { { V } } = {}

	for _, seed in allVertices do
		if visited[seed] then
			continue
		end

		local component: { V } = {}
		local queue: { V } = { seed }
		local head = 1
		visited[seed] = true

		while head <= #queue do
			local vertex: V = queue[head]
			head += 1
			table.insert(component, vertex)

			for neighbor in Types.eachNeighbor(vertex, getNeighbors) do
				if not visited[neighbor] then
					visited[neighbor] = true
					table.insert(queue, neighbor)
				end
			end
		end

		table.insert(result, component)
	end

	return result
end

--------------------------------------------------------------------------------
--// Cycle Detection //--
--------------------------------------------------------------------------------

--[=[
	@within Connectivity
	@tag directed

	Returns `true` if the **directed** graph contains at least one cycle.

	```lua
	-- dirAdj: A→B→C→A forms a cycle
	print(Connectivity.hasDirectedCycle({"A","B","C","D","E"}, getNeighbors)) -- true
	```

	:::caution Directed graphs only
	For undirected cycle detection use [`hasUndirectedCycle`](#hasUndirectedCycle).
	:::

	:::info Internals
	Uses iterative DFS with a three-colour marking scheme:
	- **white** (0) — unvisited
	- **grey** (1) — on the current DFS path (in the recursion stack)
	- **black** (2) — fully processed

	A back edge (grey → grey) indicates a cycle.
	:::

	*Time complexity:* `O(V + E)`
]=]
function Connectivity.hasDirectedCycle<V>(allVertices: { V }, getNeighbors: GetNeighbors<V>): boolean
	-- 0 = white, 1 = grey, 2 = black
	local color: { [V]: number } = {}

	for _, start in allVertices do
		if (color[start] or 0) == 2 then
			continue
		end

		-- Iterative DFS using an explicit call stack.
		-- Each entry is { vertex, iterator } so we can resume the neighbour loop.
		type Frame<V> = { vertex: V, iter: () -> V? }
		local stack: { Frame<V> } = {}
		color[start] = 1
		table.insert(stack, { vertex = start, iter = Types.eachNeighbor(start, getNeighbors) })

		while #stack > 0 do
			local frame: Frame<V> = stack[#stack]
			local neighbor = frame.iter()

			if neighbor == nil then
				-- All neighbours processed — mark black and pop
				color[frame.vertex] = 2
				table.remove(stack)
			else
				local c = color[neighbor] or 0
				if c == 1 then
					return true -- back edge → cycle
				elseif c == 0 then
					color[neighbor] = 1
					table.insert(stack, {
						vertex = neighbor,
						iter = Types.eachNeighbor(neighbor, getNeighbors),
					})
				end
				-- c == 2: already fully processed, skip
			end
		end
	end

	return false
end

--[=[
	@within Connectivity
	@tag undirected

	Returns `true` if the **undirected** graph contains at least one cycle,
	using BFS with parent tracking.  An edge to an already-visited non-parent
	vertex indicates a cycle.

	```lua
	-- A-B-C-A forms an undirected cycle
	print(Connectivity.hasUndirectedCycle({"A","B","C"}, getNeighbors)) -- true
	```

	:::caution Undirected graphs only
	For directed cycle detection use [`hasDirectedCycle`](#hasDirectedCycle).
	:::

	*Time complexity:* `O(V + E)`
]=]
function Connectivity.hasUndirectedCycle<V>(allVertices: { V }, getNeighbors: GetNeighbors<V>): boolean
	local visited: { [V]: boolean } = {}

	for _, seed in allVertices do
		if visited[seed] then
			continue
		end

		-- Each queue entry carries { vertex, parent }
		type Entry<V> = { vertex: V, parent: V? }
		local queue: { Entry<V> } = { { vertex = seed, parent = nil } }
		local head = 1
		visited[seed] = true

		while head <= #queue do
			local entry: Entry<V> = queue[head]
			head += 1
			local vertex: V = entry.vertex
			local parent: V? = entry.parent

			for neighbor in Types.eachNeighbor(vertex, getNeighbors) do
				if not visited[neighbor] then
					visited[neighbor] = true
					table.insert(queue, { vertex = neighbor, parent = vertex })
				elseif neighbor ~= parent then
					return true -- back edge to non-parent → cycle
				end
			end
		end
	end

	return false
end

--------------------------------------------------------------------------------
--// Bipartite Check //--
--------------------------------------------------------------------------------

--[=[
	@within Connectivity
	@tag undirected

	Returns `true` if the graph component reachable from `start` is
	**bipartite** — its vertices can be divided into two groups such that
	every edge connects a vertex in one group to a vertex in the other.

	Uses BFS two-colouring: colour `start` with 0 and alternate 0/1 for each
	discovered vertex.  If a neighbour already has the same colour as the
	current vertex, the graph is not bipartite.

	```lua
	-- A-B-C-D square (even cycle) → bipartite
	-- A-B-C triangle (odd cycle)   → not bipartite
	print(Connectivity.isBipartite("A", getNeighbors))
	```

	:::note Per-component
	This only checks the component reachable from `start`.  Call once per
	component (e.g. using [`components`](#components)) to check the full graph.
	:::

	*Time complexity:* `O(V + E)`
]=]
function Connectivity.isBipartite<V>(start: V, getNeighbors: GetNeighbors<V>): boolean
	local color: { [V]: number } = { [start] = 0 }
	local queue: { V } = { start }
	local head = 1

	while head <= #queue do
		local vertex: V = queue[head]
		head += 1
		local nextColor = 1 - color[vertex]

		for neighbor in Types.eachNeighbor(vertex, getNeighbors) do
			if color[neighbor] == nil then
				color[neighbor] = nextColor
				table.insert(queue, neighbor)
			elseif color[neighbor] ~= nextColor then
				return false -- same color on both ends of an edge
			end
		end
	end

	return true
end

--------------------------------------------------------------------------------
--// Strongly Connected Components (directed) //--
--------------------------------------------------------------------------------

--[=[
	@within Connectivity
	@tag directed

	Finds all **Strongly Connected Components** (SCCs) of a directed graph
	using **Kosaraju's algorithm** and returns them as an array of vertex
	arrays.  Within each SCC, every vertex can reach every other vertex.

	Kosaraju's requires traversing the graph *and* its reverse.  Because the
	library's callback design doesn't expose a reverse-edge callback, this
	function builds the reverse adjacency internally during the first DFS pass.

	```lua
	-- A→B→C→A  (one SCC), D→E (two singleton SCCs)
	local sccs = Connectivity.stronglyConnectedComponents(
	    {"A","B","C","D","E"}, getNeighbors
	)
	-- { {"A","B","C"}, {"D"}, {"E"} }  (order may vary)
	```

	*Time complexity:* `O(V + E)`
]=]
function Connectivity.stronglyConnectedComponents<V>(allVertices: { V }, getNeighbors: GetNeighbors<V>): { { V } }
	-- Pass 1: DFS on original graph, record finish order + build reverse graph
	local visited: { [V]: boolean } = {}
	local finishOrder: { V } = {}
	local reverse: { [V]: { V } } = {}

	for _, v in allVertices do
		reverse[v] = reverse[v] or {}
	end

	-- Iterative DFS with finish-order tracking
	for _, start in allVertices do
		if visited[start] then
			continue
		end

		type Frame<V> = { vertex: V, iter: () -> V? }
		local stack: { Frame<V> } = {}
		visited[start] = true
		table.insert(stack, { vertex = start, iter = Types.eachNeighbor(start, getNeighbors) })

		while #stack > 0 do
			local frame: Frame<V> = stack[#stack]
			local neighbor = frame.iter()

			if neighbor == nil then
				table.insert(finishOrder, frame.vertex)
				table.remove(stack)
			else
				-- Build reverse edge
				if not reverse[neighbor] then
					reverse[neighbor] = {}
				end
				table.insert(reverse[neighbor], frame.vertex)

				if not visited[neighbor] then
					visited[neighbor] = true
					table.insert(stack, {
						vertex = neighbor,
						iter = Types.eachNeighbor(neighbor, getNeighbors),
					})
				end
			end
		end
	end

	-- Pass 2: DFS on reverse graph in reverse finish order
	local assigned: { [V]: boolean } = {}
	local sccs: { { V } } = {}

	for i = #finishOrder, 1, -1 do
		local seed: V = finishOrder[i]
		if assigned[seed] then
			continue
		end

		local scc: { V } = {}
		local stack2: { V } = { seed }
		assigned[seed] = true

		while #stack2 > 0 do
			local v: V = table.remove(stack2) :: V
			table.insert(scc, v)

			for _, neighbor in reverse[v] or {} do
				if not assigned[neighbor] then
					assigned[neighbor] = true
					table.insert(stack2, neighbor)
				end
			end
		end

		table.insert(sccs, scc)
	end

	return sccs
end

return Connectivity
