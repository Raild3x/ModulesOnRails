--!strict
-- Authors: Logan Hunt (Raildex)
-- May 13, 2026
--[=[
	@class BellmanFord

	Bellman-Ford shortest-path algorithm supporting negative edge weights.

	Unlike Dijkstra, Bellman-Ford can handle **negative edge weights**.  It
	works by relaxing all edges `|V| − 1` times, then performing one final
	relaxation pass to detect **negative-weight cycles** (cycles where the
	total weight is less than zero).  If such a cycle exists, no well-defined
	shortest path can be computed for vertices reachable through it.

	:::tip When to use each algorithm
	| Scenario | Algorithm |
	| --- | --- |
	| All weights ≥ 0, single target | [Dijkstra.shortestPath](/api/Dijkstra#shortestPath) |
	| All weights ≥ 0, weighted traversal | [Dijkstra.toIterator](/api/Dijkstra#toIterator) |
	| All weights ≥ 0, heuristic available | [AStar.shortestPath](/api/AStar#shortestPath) |
	| Negative weights possible | **BellmanFord** |
	:::

	### `allVertices` parameter

	Bellman-Ford needs to enumerate every edge in the graph, which requires
	knowing every vertex.  Pass the complete list as `allVertices: { V }`.
	Vertices reachable from `start` that are **not** in `allVertices` are
	treated as unreachable.

	All functions accept either callback form for `GetNeighbors` — see
	[GraphUtil](/api/GraphUtil) for details.

	### Example

	```lua
	--        1         3
	--  A ──→ B ──────→ D
	--        │
	--       -2
	--        ↓
	--        C

	local weights = {
	    A = { B = 1 },
	    B = { C = -2, D = 3 },
	    C = {},
	    D = {},
	}
	local allVertices = { "A", "B", "C", "D" }

	local function getNeighbors(v) return ... end
	local function getWeight(from, to) return weights[from][to] end

	local path, hasNegativeCycle = BellmanFord.shortestPath("A", "C", allVertices, getNeighbors, getWeight)
	-- path.path  == { "A", "B", "C" }
	-- path.cost  == -1   (1 + -2)
	-- hasNegativeCycle == false
	```
]=]

local Types = require("./Types")

type GetNeighbors<V> = Types.GetNeighbors<V>
type GetWeight<V> = Types.GetWeight<V>
type PathResult<V> = Types.PathResult<V>

local BellmanFord = {}

--[=[
	@within BellmanFord

	Finds the shortest weighted path from `start` to `goal`, returning a
	`(PathResult<V>?, boolean)` tuple.

	* **First return** — a [PathResult](/api/GraphUtil#PathResult) if a path
	  exists and no negative cycle was detected; `nil` otherwise.
	* **Second return** — `true` if a negative-weight cycle was detected in
	  the reachable subgraph from `start` (in which case the first return is
	  always `nil`).

	```lua
	local result, hasNegCycle = BellmanFord.shortestPath(
	    "A", "C", allVertices, getNeighbors, getWeight
	)
	if hasNegCycle then
	    warn("Graph contains a negative-weight cycle")
	elseif result == nil then
	    warn("Goal is unreachable")
	else
	    print("Cost:", result.cost)
	end
	```

	*Time complexity:* `O(V · E)`
]=]
function BellmanFord.shortestPath<V>(
	start: V,
	goal: V,
	allVertices: { V },
	getNeighbors: GetNeighbors<V>,
	getWeight: GetWeight<V>
): (PathResult<V>?, boolean)
	local dist: { [V]: number } = {}
	local parent: { [V]: V } = {}

	for _, v in allVertices do
		dist[v] = math.huge
	end
	dist[start] = 0

	local n = #allVertices

	-- Relax all edges n-1 times
	for _ = 1, n - 1 do
		local relaxed = false
		for _, u in allVertices do
			local dU = dist[u]
			if dU == math.huge then
				continue
			end
			for v in Types.eachNeighbor(u, getNeighbors) do
				local newDist = dU + getWeight(u, v)
				if newDist < (dist[v] or math.huge) then
					dist[v] = newDist
					parent[v] = u
					relaxed = true
				end
			end
		end
		if not relaxed then
			break -- Early exit: no changes means distances are settled
		end
	end

	-- Check for negative-weight cycles (n-th relaxation pass)
	for _, u in allVertices do
		local dU = dist[u]
		if dU == math.huge then
			continue
		end
		for v in Types.eachNeighbor(u, getNeighbors) do
			if dU + getWeight(u, v) < (dist[v] or math.huge) then
				return nil, true -- Negative cycle detected
			end
		end
	end

	-- Goal unreachable
	if (dist[goal] or math.huge) == math.huge then
		return nil, false
	end

	-- Reconstruct path
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

	return { path = path, cost = dist[goal] :: number }, false
end

--[=[
	@within BellmanFord

	Runs Bellman-Ford from `start` and returns all shortest distances from
	`start` to every vertex in `allVertices`, alongside a negative-cycle flag.

	* **First return** — `{ [V]: number }` mapping each reachable vertex to
	  its shortest distance from `start`.  Vertices in `allVertices` that are
	  unreachable have a value of `math.huge`.
	* **Second return** — `true` if a negative-weight cycle was detected.
	  Distances may be incorrect for vertices affected by the cycle.

	```lua
	local distances, hasNegCycle = BellmanFord.distances("A", allVertices, getNeighbors, getWeight)
	if not hasNegCycle then
	    print(distances["D"]) -- shortest dist A→D
	end
	```

	*Time complexity:* `O(V · E)`
]=]
function BellmanFord.distances<V>(
	start: V,
	allVertices: { V },
	getNeighbors: GetNeighbors<V>,
	getWeight: GetWeight<V>
): ({ [V]: number }, boolean)
	local dist: { [V]: number } = {}

	for _, v in allVertices do
		dist[v] = math.huge
	end
	dist[start] = 0

	local n = #allVertices

	for _ = 1, n - 1 do
		local relaxed = false
		for _, u in allVertices do
			local dU = dist[u]
			if dU == math.huge then
				continue
			end
			for v in Types.eachNeighbor(u, getNeighbors) do
				local newDist = dU + getWeight(u, v)
				if newDist < (dist[v] or math.huge) then
					dist[v] = newDist
					relaxed = true
				end
			end
		end
		if not relaxed then
			break
		end
	end

	-- Negative cycle check
	for _, u in allVertices do
		local dU = dist[u]
		if dU == math.huge then
			continue
		end
		for v in Types.eachNeighbor(u, getNeighbors) do
			if dU + getWeight(u, v) < (dist[v] or math.huge) then
				return dist, true
			end
		end
	end

	return dist, false
end

return BellmanFord
