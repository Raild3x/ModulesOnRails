--!strict
-- Authors: Logan Hunt (Raildex)
-- May 13, 2026
--[=[
	@class MST

	Minimum Spanning Tree algorithms: Prim's and Kruskal's.

	A **Minimum Spanning Tree** (MST) of a connected undirected weighted graph
	is a subset of edges that connects all vertices with the minimum total
	edge weight and contains no cycles.

	Both algorithms produce the same optimal result and return an array of
	[Edge](/api/GraphUtil#Edge) values.

	### When to use each variant

	| Algorithm | Best when |
	| --- | --- |
	| [`prim`](#prim) | Dense graphs; start vertex is known |
	| [`kruskal`](#kruskal) | Sparse graphs; all vertices known upfront |

	All functions accept either callback form for `GetNeighbors` — see
	[GraphUtil](/api/GraphUtil) for details.

	:::caution Undirected graphs
	Both algorithms expect an undirected graph where each edge is represented
	in **both** directions by `getNeighbors` (i.e. if A is a neighbour of B,
	then B must also be a neighbour of A).
	:::

	### Example graph

	```lua
	--       1
	--  A ─────── B
	--  │ ╲       │
	--  4  ╲3     2
	--  │    ╲    │
	--  D ─────── C
	--       5

	local weights = {
	    A = {B=1, C=3, D=4},
	    B = {A=1, C=2},
	    C = {B=2, A=3, D=5},
	    D = {A=4, C=5},
	}
	local allVertices = {"A","B","C","D"}

	local function getNeighbors(v)
	    local result = {}
	    for k in pairs(weights[v]) do table.insert(result, k) end
	    return result
	end
	local function getWeight(u, v) return weights[u][v] end
	```
]=]

local Types = require("./Types")
local Heap = require("../Heap")

type GetNeighbors<V> = Types.GetNeighbors<V>
type GetWeight<V> = Types.GetWeight<V>
type Edge<V> = Types.Edge<V>

local MST = {}

--[=[
	@within MST

	Builds a Minimum Spanning Tree starting from `start` using **Prim's
	algorithm** with a min-heap.  Returns an array of [Edge](/api/GraphUtil#Edge)
	values whose total weight is minimised.

	The function grows the MST greedily: it always picks the cheapest edge
	crossing from the visited set into the unvisited set.

	```lua
	local edges = MST.prim("A", getNeighbors, getWeight)
	-- {
	--   { from="A", to="B", weight=1 },
	--   { from="B", to="C", weight=2 },
	--   { from="A", to="D", weight=4 },  -- (A-D cheaper than C-D)
	-- }
	```

	:::note Connectivity
	If the graph is disconnected, `prim` only spans the component reachable
	from `start`.  Run once per component to span the full forest.
	:::

	*Time complexity:* `O((V + E) log V)` with a binary min-heap.
]=]
function MST.prim<V>(start: V, getNeighbors: GetNeighbors<V>, getWeight: GetWeight<V>): { Edge<V> }
	local inMST: { [V]: boolean } = { [start] = true }
	local result: { Edge<V> } = {}

	-- Heap entries store the destination; we track the source in 'edgeFrom'
	local edgeFrom: { [V]: V } = {}
	local heap = Heap.min()

	-- Push all edges from start
	for neighbor in Types.eachNeighbor(start, getNeighbors) do
		edgeFrom[neighbor] = start
		heap:Push(neighbor, getWeight(start, neighbor))
	end

	while not heap:IsEmpty() do
		-- The IsEmpty check guarantees Pop returns a value.
		local rawTo, rawCost = heap:Pop()
		local to: V = (rawTo :: any) :: V
		local cost: number = (rawCost :: any) :: number

		if inMST[to] then
			continue -- stale heap entry
		end
		inMST[to] = true

		local from: V = edgeFrom[to]
		table.insert(result, { from = from, to = to, weight = cost })

		-- Relax edges from newly added vertex
		for neighbor in Types.eachNeighbor(to, getNeighbors) do
			if not inMST[neighbor] then
				local w = getWeight(to, neighbor)
				-- We push eagerly; stale entries are filtered by inMST check above
				if edgeFrom[neighbor] == nil then
					edgeFrom[neighbor] = to
					heap:Push(neighbor, w)
				else
					-- Push a potentially better candidate; the heap will surface the cheapest
					local currentCost = getWeight(edgeFrom[neighbor], neighbor)
					if w < currentCost then
						edgeFrom[neighbor] = to
						heap:Push(neighbor, w)
					end
				end
			end
		end
	end

	return result
end

--[=[
	@within MST

	Builds a Minimum Spanning Tree using **Kruskal's algorithm**.  Returns an
	array of [Edge](/api/GraphUtil#Edge) values whose total weight is minimised.

	Kruskal's works by sorting all edges by weight and greedily adding each
	edge that connects two previously disconnected components, using a
	Union-Find (disjoint-set) structure to detect cycles in `O(α(V))` time.

	```lua
	local edges = MST.kruskal(allVertices, getNeighbors, getWeight)
	-- {
	--   { from="A", to="B", weight=1 },
	--   { from="B", to="C", weight=2 },
	--   { from="A", to="D", weight=4 },
	-- }
	```

	:::note Edge discovery
	Kruskal's collects all edges by iterating `getNeighbors` over every vertex
	in `allVertices`.  To avoid duplicates, each undirected edge is only
	added once (the canonical direction is the one where the vertex appears
	first in `allVertices`).
	:::

	*Time complexity:* `O(E log E)` dominated by the edge sort.
]=]
function MST.kruskal<V>(allVertices: { V }, getNeighbors: GetNeighbors<V>, getWeight: GetWeight<V>): { Edge<V> }
	-- Assign each vertex a numeric id for the Union-Find structure
	local id: { [V]: number } = {}
	for i, v in allVertices do
		id[v] = i
	end

	-- Collect all unique undirected edges (u, v) where id[u] < id[v]
	type RawEdge<V> = { from: V, to: V, weight: number }
	local edges: { RawEdge<V> } = {}
	local seen: { [string]: boolean } = {}

	for _, u in allVertices do
		-- u comes from allVertices, so its id is always present.
		local uid = id[u] :: number
		for v in Types.eachNeighbor(u, getNeighbors) do
			local vid = id[v]
			if vid == nil then
				continue
			end
			-- Canonical key: smaller id first to deduplicate undirected edges
			local key = if uid < vid then uid .. "," .. vid else vid .. "," .. uid
			if not seen[key] then
				seen[key] = true
				table.insert(edges, { from = u, to = v, weight = getWeight(u, v) })
			end
		end
	end

	-- Sort edges by weight (ascending)
	table.sort(edges, function(a, b)
		return a.weight < b.weight
	end)

	-- Union-Find with path compression and union by rank
	local parent: { number } = table.create(#allVertices)
	local rank: { number } = table.create(#allVertices, 0)
	for i = 1, #allVertices do
		parent[i] = i
	end

	local function find(x: number): number
		while parent[x] ~= x do
			parent[x] = parent[parent[x]] -- path compression (halving)
			x = parent[x]
		end
		return x
	end

	local function union(x: number, y: number): boolean
		local px, py = find(x), find(y)
		if px == py then
			return false -- already in same component
		end
		if rank[px] < rank[py] then
			px, py = py, px
		end
		parent[py] = px
		if rank[px] == rank[py] then
			rank[px] += 1
		end
		return true
	end

	-- Greedily add edges that connect distinct components
	local result: { Edge<V> } = {}
	for _, edge in edges do
		-- Both endpoints of a collected edge are always in allVertices.
		local uid = id[edge.from] :: number
		local vid = id[edge.to] :: number
		if union(uid, vid) then
			table.insert(result, { from = edge.from, to = edge.to, weight = edge.weight })
			if #result == #allVertices - 1 then
				break -- MST is complete
			end
		end
	end

	return result
end

return MST
