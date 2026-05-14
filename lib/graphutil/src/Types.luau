--!strict
-- Authors: Logan Hunt (Raildex)
-- May 13, 2026
--[=[
	@class GraphUtil

	A comprehensive library of generic graph algorithms.

	All algorithms are graph-agnostic: you provide callbacks that describe
	your graph's structure rather than building a specific data structure.
	This lets you run any algorithm over any representation — adjacency
	lists, spatial grids, implicit neighbour functions, and so on.

	### Shared callback types

	Every algorithm accepts a **`GetNeighbors<V>`** callback.  Two forms are
	accepted and automatically normalised internally:

	```lua title="Array form (simpler)"
	local function getNeighbors(vertex)
	    return adjacencyList[vertex] -- { V }
	end
	```
	```lua title="Iterator form (zero-allocation)"
	local function getNeighbors(vertex)
	    local i = 0
	    local neighbours = adjacencyList[vertex]
	    return function()
	        i += 1
	        return neighbours[i]
	    end
	end
	```

	Weighted algorithms additionally accept a **`GetWeight<V>`** callback:

	```lua
	local function getWeight(from, to)
	    return edgeWeights[from][to]
	end
	```

	A* additionally requires a **`GetHeuristic<V>`** admissible heuristic:

	```lua
	local function heuristic(vertex, goal)
	    return (vertex.Position - goal.Position).Magnitude
	end
	```

	### Return types

	Algorithms that find a path return a **`PathResult<V>`**:

	```lua
	type PathResult<V> = {
	    path: { V },   -- ordered list of vertices from start to goal (inclusive)
	    cost: number,  -- total edge-weight cost (0 for unweighted algorithms)
	}
	```
]=]

--------------------------------------------------------------------------------
--// Types //--
--------------------------------------------------------------------------------

--- A callback that returns the neighbours of `vertex` as an array.
export type GetNeighborsArray<V> = (vertex: V) -> { V }

--- A callback that returns an iterator over the neighbours of `vertex`.
--- More allocation-efficient but requires managing iteration state.
export type GetNeighborsIterator<V> = (vertex: V) -> () -> V?

--- Either form of neighbour callback.  Accepted by all algorithms.
export type GetNeighbors<V> = GetNeighborsArray<V> | GetNeighborsIterator<V>

--- Returns the non-negative weight of the directed edge from → to.
export type GetWeight<V> = (from: V, to: V) -> number

--- Admissible heuristic: estimated cost from `vertex` to `goal`.
--- Must never overestimate the true cost (i.e. be admissible) for A* to be optimal.
export type GetHeuristic<V> = (vertex: V, goal: V) -> number

--- A stateless iterator that yields successive values, returning nil when exhausted.
export type Iterator<V> = () -> V?

--- The result of a path-finding algorithm.
export type PathResult<V> = {
	--- Ordered sequence of vertices from start to goal (both inclusive).
	path: { V },
	--- Total accumulated edge-weight along the path.
	--- For unweighted algorithms this is the hop-count.
	cost: number,
}

--- An edge in a spanning or search tree.
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
