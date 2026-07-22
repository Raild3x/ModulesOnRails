--!strict
-- Authors: Logan Hunt (Raildex)
-- May 13, 2026
--[=[
	@class GraphUtil

	A library of generic, graph-agnostic algorithms. Describe your graph with
	a few callbacks — no bespoke data structure required — and run any
	algorithm over any representation (adjacency lists, spatial grids, implicit
	neighbour functions, …).

	### Submodules

	| Module | Purpose |
	| --- | --- |
	| [BFS](/api/BFS) | Breadth-first traversal & unweighted shortest paths |
	| [DFS](/api/DFS) | Depth-first traversal & spanning trees |
	| [Dijkstra](/api/Dijkstra) | Weighted shortest paths (non-negative) & cost-ordered traversal |
	| [AStar](/api/AStar) | Heuristic-guided weighted shortest path |
	| [BellmanFord](/api/BellmanFord) | Weighted shortest paths with negative edges & cycle detection |
	| [MST](/api/MST) | Minimum spanning trees (Prim / Kruskal) |
	| [TopologicalSort](/api/TopologicalSort) | Linear ordering of a DAG (DFS / Kahn) |
	| [Connectivity](/api/Connectivity) | Reachability, components, cycles, bipartite, SCCs |

	### Shared callbacks

	Algorithms are driven by callbacks rather than a fixed structure. See each
	type page for the full signature and worked examples:
	[GetNeighbors](#GetNeighbors) (required by every algorithm),
	[GetWeight](#GetWeight) (weighted algorithms), and
	[GetHeuristic](#GetHeuristic) (A\*). Path-finders return a
	[PathResult](#PathResult); MST returns [Edge](#Edge) lists.

	### Directed vs. undirected

	Because your callbacks define the edges, most algorithms work on directed
	and undirected graphs alike. Every function carries a `directed` and/or
	`undirected` tag showing which graph kinds it supports — a function tagged
	with only one (e.g. [TopologicalSort](/api/TopologicalSort) is
	directed-only, [MST](/api/MST) is undirected-only) gives wrong or
	meaningless results on the other kind.

	```lua
	local GraphUtil = require(Packages.GraphUtil)

	local adjacency = {
	    A = { "B", "C" },
	    B = { "A", "D" },
	    C = { "A", "D" },
	    D = { "B", "C" },
	}

	local result = GraphUtil.BFS.shortestPath("A", "D", function(v)
	    return adjacency[v]
	end)
	-- result.path == { "A", "B", "D" }
	```
]=]

local GraphUtil = {}

--[=[
	@within GraphUtil
	@prop BFS BFS
	Breadth-first search — traversal and unweighted (fewest-hop) shortest paths.
]=]
GraphUtil.BFS = require("@self/BFS")

--[=[
	@within GraphUtil
	@prop DFS DFS
	Depth-first search — traversal, reachability sets, and spanning trees.
]=]
GraphUtil.DFS = require("@self/DFS")

--[=[
	@within GraphUtil
	@prop Dijkstra Dijkstra
	Weighted shortest paths (non-negative edges) and cost-ordered traversal.
]=]
GraphUtil.Dijkstra = require("@self/Dijkstra")

--[=[
	@within GraphUtil
	@prop AStar AStar
	Heuristic-guided weighted shortest path — faster than Dijkstra with a good heuristic.
]=]
GraphUtil.AStar = require("@self/AStar")

--[=[
	@within GraphUtil
	@prop BellmanFord BellmanFord
	Weighted shortest paths that tolerate negative edges, with negative-cycle detection.
]=]
GraphUtil.BellmanFord = require("@self/BellmanFord")

--[=[
	@within GraphUtil
	@prop MST MST
	Minimum spanning trees via Prim's and Kruskal's algorithms.
]=]
GraphUtil.MST = require("@self/MST")

--[=[
	@within GraphUtil
	@prop TopologicalSort TopologicalSort
	Linear ordering of a directed acyclic graph via DFS post-order or Kahn's algorithm.
]=]
GraphUtil.TopologicalSort = require("@self/TopologicalSort")

--[=[
	@within GraphUtil
	@prop Connectivity Connectivity
	Reachability, connected components, cycle detection, bipartiteness, and SCCs.
]=]
GraphUtil.Connectivity = require("@self/Connectivity")

local Types = require("@self/Types")
export type GetNeighbors<V> = Types.GetNeighbors<V>
export type GetNeighborsArray<V> = Types.GetNeighborsArray<V>
export type GetNeighborsIterator<V> = Types.GetNeighborsIterator<V>
export type GetWeight<V> = Types.GetWeight<V>
export type GetHeuristic<V> = Types.GetHeuristic<V>
export type ShouldStop<V> = Types.ShouldStop<V>
export type Iterator<V> = Types.Iterator<V>
export type PathResult<V> = Types.PathResult<V>
export type Edge<V> = Types.Edge<V>

return table.freeze(GraphUtil)
