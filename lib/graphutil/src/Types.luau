--!strict
-- Authors: Logan Hunt (Raildex)
-- May 13, 2026
--
-- The `@class GraphUtil` landing page lives in `init.luau`; every `@within
-- GraphUtil` block below is merged onto that same page by Moonwave.

--------------------------------------------------------------------------------
--// Types //--
--------------------------------------------------------------------------------

--[=[
	@within GraphUtil
	@type GetNeighborsArray (vertex: V) -> { V }

	A callback that returns the neighbours of `vertex` as an array. The simpler
	of the two [GetNeighbors] forms — return whatever's convenient and let the
	algorithm collect it.

	```lua
	local adjacencyList = {
	    A = { "B", "C" },
	    B = { "A", "D" },
	    C = { "A", "D" },
	    D = { "B", "C" },
	}

	local function getNeighbors(vertex: string): { string }
	    -- Return an empty array (never nil) for vertices with no neighbours,
	    -- so the algorithms can index the result safely.
	    return adjacencyList[vertex] or {}
	end
	```
]=]
export type GetNeighborsArray<V> = (vertex: V) -> { V }

--[=[
	@within GraphUtil
	@type GetNeighborsIterator (vertex: V) -> () -> V?

	A callback that returns a stateful iterator over the neighbours of
	`vertex`. More allocation-efficient than [GetNeighborsArray] — no
	intermediate table is built — at the cost of managing the iteration state
	yourself.

	```lua
	local adjacencyList = {
	    A = { "B", "C" },
	    B = { "A", "D" },
	    C = { "A", "D" },
	    D = { "B", "C" },
	}

	local function getNeighbors(vertex: string): () -> string?
	    local neighbours = adjacencyList[vertex] or {}
	    local i = 0
	    return function(): string?
	        i += 1
	        return neighbours[i]
	    end
	end
	```
]=]
export type GetNeighborsIterator<V> = (vertex: V) -> () -> V?

--[=[
	@within GraphUtil
	@type GetNeighbors GetNeighborsArray | GetNeighborsIterator

	Either form of neighbour callback — [GetNeighborsArray] or
	[GetNeighborsIterator]. Accepted by every algorithm in this library and
	normalised internally, so you can pick whichever form is most natural for
	your graph representation.

	```lua
	local function arrayForm(vertex: string): { string }
	    return adjacencyList[vertex] or {}
	end

	local ok = BFS.shortestPath("A", "D", arrayForm) -- both forms work
	```
]=]
export type GetNeighbors<V> = GetNeighborsArray<V> | GetNeighborsIterator<V>

--[=[
	@within GraphUtil
	@type GetWeight (from: V, to: V) -> number

	Returns the non-negative weight of the directed edge from `from` to `to`.
	Required by every weighted algorithm ([Dijkstra](/api/Dijkstra),
	[AStar](/api/AStar), [BellmanFord](/api/BellmanFord), [MST](/api/MST)).

	```lua
	local edgeWeights = {
	    A = { B = 2, C = 3 },
	    B = { A = 2, D = 1 },
	    C = { A = 3, D = 5 },
	    D = { B = 1, C = 5 },
	}

	local function getWeight(from: string, to: string): number
	    return edgeWeights[from][to]
	end
	```
]=]
export type GetWeight<V> = (from: V, to: V) -> number

--[=[
	@within GraphUtil
	@type GetHeuristic (vertex: V, goal: V) -> number

	An admissible heuristic: an estimate of the cost from `vertex` to `goal`
	that must never overestimate the true cost. Required by
	[AStar](/api/AStar); an inadmissible heuristic makes A* fast but no longer
	guaranteed optimal.

	```lua
	-- Straight-line distance is admissible for movement costs that are
	-- never cheaper than a direct line (e.g. grid movement).
	local function heuristic(vertex: { Position: Vector3 }, goal: { Position: Vector3 }): number
	    return (vertex.Position - goal.Position).Magnitude
	end
	```
]=]
export type GetHeuristic<V> = (vertex: V, goal: V) -> number

--[=[
	@within GraphUtil
	@type ShouldStop (vertex: V, cost: number) -> boolean

	An optional **cooperative cancellation** predicate. Search functions that
	accept one call it once per expanded vertex — after the goal check, before
	that vertex's neighbours are relaxed — and abort the search the moment it
	returns `true`. Path-finders then return `nil` (indistinguishable from an
	unreachable goal); [`Dijkstra.distances`](/api/Dijkstra#distances) returns
	the partial result accumulated so far.

	Because these algorithms run synchronously to completion, this predicate is
	the only way to bound an open-ended search. `cost` is the accumulated cost
	of `vertex` — weighted distance for [Dijkstra](/api/Dijkstra) /
	[AStar](/api/AStar), hop-count for [BFS](/api/BFS) — so you can stop on a
	budget; most callers ignore both arguments and stop on a wall-clock deadline.

	```lua
	-- Give up after half a second of searching.
	local deadline = os.clock() + 0.5
	local result = AStar.shortestPath(a, b, getNeighbors, getWeight, heuristic, function()
	    return os.clock() > deadline
	end)

	-- Or stop once the search cost exceeds a budget of 500.
	local result = Dijkstra.shortestPath(a, b, getNeighbors, getWeight, function(_vertex, cost)
	    return cost > 500
	end)
	```
]=]
export type ShouldStop<V> = (vertex: V, cost: number) -> boolean

--[=[
	@within GraphUtil
	@type KIterator () -> K?

	A stateless-to-the-caller iterator that yields one value per call,
	returning `nil` once exhausted. This is the single-value form returned by
	[`BFS.toIterator`](/api/BFS#toIterator) and
	[`DFS.toIterator`](/api/DFS#toIterator); for the `(vertex, cost)` pair form
	see [KVIterator].

	The `nil`-at-exhaustion convention is what makes these iterators directly
	usable in a plain `for` loop.

	```lua
	local iter: Types.KIterator<string> = BFS.toIterator(start, getNeighbors)

	for vertex in iter do
	    print(vertex)
	end
	```
]=]
export type KIterator<K> = () -> K?

--[=[
	@within GraphUtil
	@type KVIterator () -> (K?, V?)

	A stateless-to-the-caller iterator that yields a pair of values per call,
	returning `(nil, nil)` once exhausted. This is the `(vertex, cost)` form
	returned by [`Dijkstra.toIterator`](/api/Dijkstra#toIterator); for the
	single-value form see [KIterator].

	Write the type arguments *without* `?` — the alias applies the optionality
	itself, since every slot is `nil` once the traversal is exhausted:
	`KVIterator<string, number>` is `() -> (string?, number?)`.

	```lua
	local iter: Types.KVIterator<string, number> = Dijkstra.toIterator(start, getNeighbors, getWeight)

	for vertex, cost in iter do
	    print(vertex, cost)
	end
	```
]=]
export type KVIterator<K, V> = () -> (K?, V?)

--[=[
	@within GraphUtil
	@interface PathResult
	.path { V } -- Ordered sequence of vertices from start to goal (both inclusive).
	.cost number -- Total accumulated edge-weight along the path. For unweighted algorithms this is the hop-count.

	The result of a path-finding algorithm — returned by
	[`BFS.shortestPath`](/api/BFS#shortestPath),
	[`Dijkstra.shortestPath`](/api/Dijkstra#shortestPath),
	[`AStar.shortestPath`](/api/AStar#shortestPath), and
	[`BellmanFord.shortestPath`](/api/BellmanFord#shortestPath).

	```lua
	local result = Dijkstra.shortestPath("A", "D", getNeighbors, getWeight)
	if result then
	    print(result.path) -- { "A", "B", "D" }
	    print(result.cost) -- 3
	end
	```
]=]
export type PathResult<V> = {
	path: { V },
	cost: number,
}

--[=[
	@within GraphUtil
	@interface Edge
	.from V -- The vertex the edge starts at.
	.to V -- The vertex the edge ends at.
	.weight number -- The edge's weight.

	An edge in a spanning or search tree, as produced by
	[`MST.kruskal`](/api/MST#kruskal) and [`MST.prim`](/api/MST#prim).

	```lua
	local edges = MST.kruskal(vertices, getNeighbors, getWeight)
	for _, edge in edges do
	    print(`{edge.from} -> {edge.to} ({edge.weight})`)
	end
	```
]=]
export type Edge<V> = {
	from: V,
	to: V,
	weight: number,
}

--------------------------------------------------------------------------------
--// Internal Helpers //--
--------------------------------------------------------------------------------

local Types = {}

--[=[
	@within GraphUtil
	@private

	Normalises either form of `GetNeighbors<V>` into a plain iterator
	`() -> V?`.  The detection works by calling `getNeighbors(vertex)` once
	and checking whether the result is itself a function (iterator form) or
	a table (array form).

	This helper is called once per vertex visit inside every algorithm, so
	it must stay cheap.

	```lua
	for neighbor in Types.eachNeighbor(vertex, getNeighbors) do
	    -- ...
	end
	```
]=]
function Types.eachNeighbor<V>(vertex: V, getNeighbors: GetNeighbors<V>): () -> V?
	local result = (getNeighbors :: any)(vertex)
	if type(result) == "function" then
		-- Iterator form — already a () -> V?
		return result
	else
		-- Array form — wrap in a simple stateful closure
		local i = 0
		return function(): V?
			i += 1
			return (result :: { V })[i]
		end
	end
end

return Types
