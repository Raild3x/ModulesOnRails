--!strict
-- Authors: Logan Hunt (Raildex)
-- May 13, 2026

--[=[
	@class GraphUtil
	See [GraphUtil](/api/GraphUtil) for full documentation.
]=]

local GraphUtil = {}

GraphUtil.BFS = require(script.BFS)
GraphUtil.DFS = require(script.DFS)
GraphUtil.Dijkstra = require(script.Dijkstra)
GraphUtil.AStar = require(script.AStar)
GraphUtil.BellmanFord = require(script.BellmanFord)
GraphUtil.MST = require(script.MST)
GraphUtil.TopologicalSort = require(script.TopologicalSort)
GraphUtil.Connectivity = require(script.Connectivity)

local Types = require(script.Types)
export type GetNeighbors<V> = Types.GetNeighbors<V>
export type GetNeighborsArray<V> = Types.GetNeighborsArray<V>
export type GetNeighborsIterator<V> = Types.GetNeighborsIterator<V>
export type GetWeight<V> = Types.GetWeight<V>
export type GetHeuristic<V> = Types.GetHeuristic<V>
export type Iterator<V> = Types.Iterator<V>
export type PathResult<V> = Types.PathResult<V>
export type Edge<V> = Types.Edge<V>

return GraphUtil
