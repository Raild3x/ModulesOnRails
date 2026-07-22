--!strict
-- Authors: Logan Hunt (Raildex)
-- May 13, 2026
--[=[
	@class AStar

	A\* heuristic-guided shortest-path search.

	A\* finds the shortest weighted path from `start` to `goal` using a
	user-provided **admissible heuristic** to guide the search.  By
	preferring vertices that appear geometrically (or otherwise) closer to
	the goal, A\* typically expands far fewer vertices than Dijkstra while
	still guaranteeing an optimal result — provided the heuristic never
	overestimates the true cost.

	### Choosing a heuristic

	| Graph type | Good heuristic |
	| --- | --- |
	| 2-D grid / world-space | Euclidean or Manhattan distance |
	| Road network | Straight-line distance |
	| Abstract graph | `0` (degrades to Dijkstra) |

	:::caution Admissibility
	The heuristic **must be admissible** — it must never return a value
	greater than the true cheapest cost to reach `goal` from `vertex`.
	An inadmissible heuristic can cause A\* to return a suboptimal path.
	:::

	All functions accept either callback form for `GetNeighbors` — see
	[GraphUtil](/api/GraphUtil) for details.

	### Example (grid pathfinding)

	```lua
	-- Each node is a Vector2 grid position.
	-- Edge weight = 1 (uniform grid), heuristic = Manhattan distance.

	local function getNeighbors(pos: Vector2): { Vector2 }
	    local neighbors = {}
	    for _, dir in { Vector2.new(1,0), Vector2.new(-1,0), Vector2.new(0,1), Vector2.new(0,-1) } do
	        local next = pos + dir
	        if not walls[next] then
	            table.insert(neighbors, next)
	        end
	    end
	    return neighbors
	end

	local function getWeight(_from: Vector2, _to: Vector2): number
	    return 1
	end

	local function heuristic(v: Vector2, goal: Vector2): number
	    return math.abs(v.X - goal.X) + math.abs(v.Y - goal.Y)
	end

	local result = AStar.shortestPath(
	    Vector2.new(0, 0),
	    Vector2.new(5, 5),
	    getNeighbors,
	    getWeight,
	    heuristic
	)
	```
]=]

local Types = require("./Types")
local Heap = require("../Heap")

type GetNeighbors<V> = Types.GetNeighbors<V>
type GetWeight<V> = Types.GetWeight<V>
type GetHeuristic<V> = Types.GetHeuristic<V>
type PathResult<V> = Types.PathResult<V>

local AStar = {}

--[=[
	@within AStar

	Finds the shortest weighted path from `start` to `goal` using A\* search
	guided by `heuristic`.  Returns a [PathResult](/api/GraphUtil#PathResult),
	or `nil` if `goal` is unreachable from `start`.

	The heap is keyed on **f-score** = `g(v) + h(v, goal)` where `g(v)` is
	the known cheapest cost from `start` to `v` and `h` is the heuristic.

	```lua
	local result = AStar.shortestPath(start, goal, getNeighbors, getWeight, heuristic)
	if result then
	    print("Path cost:", result.cost)
	    for _, v in result.path do print(v) end
	end
	```

	*Time complexity:* `O((V + E) log V)` in the worst case, but typically
	much better in practice due to heuristic pruning.
]=]
function AStar.shortestPath<V>(
	start: V,
	goal: V,
	getNeighbors: GetNeighbors<V>,
	getWeight: GetWeight<V>,
	heuristic: GetHeuristic<V>
): PathResult<V>?
	if start == goal then
		return { path = { start }, cost = 0 }
	end

	-- g[v] = cheapest known cost from start to v
	local g: { [V]: number } = { [start] = 0 }
	local parent: { [V]: V } = {}
	local visited: { [V]: boolean } = {}

	-- Push start keyed on f = g(start) + h(start, goal) = 0 + h
	local heap = Heap.min()
	heap:Push(start, heuristic(start, goal))

	while not heap:IsEmpty() do
		local rawVertex, _ = heap:Pop()
		if not rawVertex then
			break
		end
		local vertex: V = (rawVertex :: any) :: V

		if visited[vertex] then
			continue
		end
		visited[vertex] = true

		if vertex == goal then
			-- Reconstruct path following parent pointers from goal back to start
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
			return { path = path, cost = g[goal] }
		end

		local gVertex = g[vertex] :: number

		for neighbor in Types.eachNeighbor(vertex, getNeighbors) do
			if visited[neighbor] then
				continue
			end
			local tentativeG = gVertex + getWeight(vertex, neighbor)
			if tentativeG < (g[neighbor] or math.huge) then
				g[neighbor] = tentativeG
				parent[neighbor] = vertex
				local f = tentativeG + heuristic(neighbor, goal)
				heap:Push(neighbor, f)
			end
		end
	end

	return nil
end

return AStar
