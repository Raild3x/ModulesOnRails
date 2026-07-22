--!strict
-- Authors: Logan Hunt (Raildex)
-- May 13, 2026
--[=[
	@class TopologicalSort

	Topological ordering of directed acyclic graphs (DAGs).

	A topological sort produces a linear ordering of vertices such that for
	every directed edge `u → v`, vertex `u` appears before `v` in the
	ordering.  This is only possible when the graph has **no directed cycles**.

	Both implementations return `nil` when a cycle is detected, signaling that
	no valid topological order exists.

	### When to use each variant

	| Function | Strategy | Best when |
	| --- | --- | --- |
	| [`sort`](#sort) | DFS post-order | General purpose |
	| [`kahn`](#kahn) | BFS / in-degree queue | You also need the in-degree counts, or want a more predictable iteration order |

	All functions accept either callback form for `GetNeighbors` — see
	[GraphUtil](/api/GraphUtil) for details.

	### Example graph

	```lua
	-- Task dependency graph (directed, acyclic):
	--  compile ──→ link ──→ test ──→ deploy
	--              ↑
	--  assets ─────┘

	local deps = {
	    compile  = {},
	    assets   = {},
	    link     = {"compile", "assets"},
	    test     = {"link"},
	    deploy   = {"test"},
	}

	local allTasks = {"compile", "assets", "link", "test", "deploy"}

	local function getNeighbors(v)
	    return deps[v]         -- outgoing edges (v must come before its neighbors)
	end
	```
]=]

local Types = require("./Types")

type GetNeighbors<V> = Types.GetNeighbors<V>

local TopologicalSort = {}

--[=[
	@within TopologicalSort

	Returns a topological ordering of `allVertices` using iterative
	**DFS post-order**.  After fully exploring all outgoing edges of a vertex,
	it is prepended to the result list — this naturally places dependencies
	before dependents.

	Returns `nil` if the graph contains a directed cycle (no valid ordering
	exists).

	```lua
	local order = TopologicalSort.sort(allTasks, getNeighbors)
	-- e.g. { "compile", "assets", "link", "test", "deploy" }
	```

	*Time complexity:* `O(V + E)`
]=]
function TopologicalSort.sort<V>(allVertices: { V }, getNeighbors: GetNeighbors<V>): { V }?
	-- 0 = white, 1 = grey (on stack), 2 = black
	local color: { [V]: number } = {}
	local result: { V } = {}

	for _, start in allVertices do
		if (color[start] or 0) == 2 then
			continue
		end

		type Frame<V> = { vertex: V, iter: () -> V? }
		local stack: { Frame<V> } = {}
		color[start] = 1
		table.insert(stack, { vertex = start, iter = Types.eachNeighbor(start, getNeighbors) })

		while #stack > 0 do
			local frame: Frame<V> = stack[#stack]
			local neighbor = frame.iter()

			if neighbor == nil then
				-- Finished: prepend to result (post-order → reverse = topo order)
				color[frame.vertex] = 2
				table.insert(result, 1, frame.vertex)
				table.remove(stack)
			else
				local c = color[neighbor] or 0
				if c == 1 then
					return nil -- Back edge → cycle detected
				elseif c == 0 then
					color[neighbor] = 1
					table.insert(stack, {
						vertex = neighbor,
						iter = Types.eachNeighbor(neighbor, getNeighbors),
					})
				end
			end
		end
	end

	return result
end

--[=[
	@within TopologicalSort

	Returns a topological ordering using **Kahn's algorithm** (BFS / in-degree
	queue).  Vertices with zero in-degree are enqueued first; as each is
	removed, the in-degrees of its successors are decremented and any newly
	zero-degree successors are enqueued.

	Returns `nil` if the graph contains a directed cycle (not all vertices
	could be processed).

	```lua
	local order = TopologicalSort.kahn(allTasks, getNeighbors)
	-- e.g. { "compile", "assets", "link", "test", "deploy" }
	```

	:::tip Stable ordering
	Kahn's approach processes vertices in FIFO order within the same in-degree
	level, which can produce a more predictable ordering than DFS for graphs
	with multiple valid topological sorts.
	:::

	*Time complexity:* `O(V + E)`
]=]
function TopologicalSort.kahn<V>(allVertices: { V }, getNeighbors: GetNeighbors<V>): { V }?
	-- Build in-degree table and adjacency list
	local inDegree: { [V]: number } = {}
	local outEdges: { [V]: { V } } = {}

	for _, v in allVertices do
		inDegree[v] = inDegree[v] or 0
		outEdges[v] = outEdges[v] or {}
	end

	for _, v in allVertices do
		for neighbor in Types.eachNeighbor(v, getNeighbors) do
			inDegree[neighbor] = (inDegree[neighbor] or 0) + 1
			if not outEdges[v] then
				outEdges[v] = {}
			end
			table.insert(outEdges[v], neighbor)
		end
	end

	-- Seed queue with zero-in-degree vertices
	local queue: { V } = {}
	for _, v in allVertices do
		if inDegree[v] == 0 then
			table.insert(queue, v)
		end
	end

	local result: { V } = {}
	local head = 1

	while head <= #queue do
		local v: V = queue[head]
		head += 1
		table.insert(result, v)

		for _, neighbor in outEdges[v] do
			inDegree[neighbor] -= 1
			if inDegree[neighbor] == 0 then
				table.insert(queue, neighbor)
			end
		end
	end

	-- If we didn't process every vertex, there's a cycle
	if #result ~= #allVertices then
		return nil
	end

	return result
end

return TopologicalSort
