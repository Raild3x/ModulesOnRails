local DelaunayTriangleEdge = {}

function DelaunayTriangleEdge.new(
	triangleIndex: number,
	edgeIndex: number,
	edgeVertexA: number,
	edgeVertexB: number
): DelaunayTriangleEdge
	assert(typeof(triangleIndex) == "number", "triangleIndex must be a number")
	assert(typeof(edgeIndex) == "number", "edgeIndex must be a number")
	assert(typeof(edgeVertexA) == "number", "edgeVertexA must be a number")
	assert(typeof(edgeVertexB) == "number", "edgeVertexB must be a number")

	return {
		TriangleIndex = triangleIndex,
		EdgeIndex = edgeIndex,
		EdgeVertexA = edgeVertexA,
		EdgeVertexB = edgeVertexB,
	}
end

export type DelaunayTriangleEdge = {
	TriangleIndex: number,
	EdgeIndex: number,
	EdgeVertexA: number,
	EdgeVertexB: number,
}

return DelaunayTriangleEdge
