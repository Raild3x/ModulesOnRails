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
	@type GetNeighborsArray<V> (vertex: V) -> { V }

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
	    return adjacencyList[vertex]
	end
	```
]=]
export type GetNeighborsArray<V> = (vertex: V) -> { V }

--[=[
	@within GraphUtil
	@type GetNeighborsIterator<V> (vertex: V) -> () -> V?

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
	    local neighbours = adjacencyList[vertex]
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
	@type GetNeighbors<V> GetNeighborsArray<V> | GetNeighborsIterator<V>

	Either form of neighbour callback — [GetNeighborsArray] or
	[GetNeighborsIterator]. Accepted by every algorithm in this library and
	normalised internally, so you can pick whichever form is most natural for
	your graph representation.

	```lua
	local function arrayForm(vertex: string): { string }
	    return adjacencyList[vertex]
	end

	local ok = BFS.shortestPath("A", "D", arrayForm) -- both forms work
	```
]=]
export type GetNeighbors<V> = GetNeighborsArray<V> | GetNeighborsIterator<V>

--[=[
	@within GraphUtil
	@type GetWeight<V> (from: V, to: V) -> number

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
	@type GetHeuristic<V> (vertex: V, goal: V) -> number

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
	@type Iterator<V> () -> V?

	A stateless-to-the-caller iterator that yields successive values,
	returning `nil` once exhausted. Used for lazy, break-early traversals such
	as [`Dijkstra.toIterator`](/api/Dijkstra#toIterator).

	```lua
	local iter: Types.Iterator<string> = Dijkstra.toIterator(start, getNeighbors, getWeight) :: any

	for vertex in iter do
	    print(vertex)
	end
	```
]=]
export type Iterator<V> = () -> V?

--[=[
	@within GraphUtil
	@interface PathResult<V>
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
	@interface Edge<V>
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
