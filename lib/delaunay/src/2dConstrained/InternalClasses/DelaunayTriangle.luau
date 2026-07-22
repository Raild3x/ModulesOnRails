local NO_ADJACENT_TRIANGLE = -1

local DelaunayTriangle = {}

--[=[
	@param point1 -- The index of the first vertex
	@param point2 -- The index of the second vertex
	@param point3 -- The index of the third vertex
	@param adjacent1 -- The index of the triangle that is adjacent to the first edge
	@param adjacent2 -- The index of the triangle that is adjacent to the second edge
	@param adjacent3 -- The index of the triangle that is adjacent to the third edge
]=]
function DelaunayTriangle.new(
	point1: number,
	point2: number,
	point3: number,
	adjacent1: number?,
	adjacent2: number?,
	adjacent3: number?
): DelaunayTriangle
	assert(typeof(point1) == "number", "point1 must be a number")
	assert(typeof(point2) == "number", "point2 must be a number")
	assert(typeof(point3) == "number", "point3 must be a number")
	assert(typeof(adjacent1) == "number" or adjacent1 == nil, "adjacent1 must be a number or nil")
	assert(typeof(adjacent2) == "number" or adjacent2 == nil, "adjacent2 must be a number or nil")
	assert(typeof(adjacent3) == "number" or adjacent3 == nil, "adjacent3 must be a number or nil")

	return {
		Points = { point1, point2, point3 },
		AdjacentTriangles = {
			adjacent1 or NO_ADJACENT_TRIANGLE,
			adjacent2 or NO_ADJACENT_TRIANGLE,
			adjacent3 or NO_ADJACENT_TRIANGLE,
		},
	}
end

export type DelaunayTriangle = {
	Points: { number }, -- Indices of the triangle's vertices
	AdjacentTriangles: { number }, -- Indices of adjacent triangles (or NO_ADJACENT_TRIANGLE)
}

return DelaunayTriangle
