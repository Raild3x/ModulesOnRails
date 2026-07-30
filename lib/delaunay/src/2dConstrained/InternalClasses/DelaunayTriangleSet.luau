--!strict
--!native

local Janitor = require("../../../Janitor")
local DelaunayTriangleEdge = require("./DelaunayTriangleEdge")
local DelaunayTriangle = require("./DelaunayTriangle")
local Triangle2d = require("../Utils/Triangle2dUtil")
local DelaunayUtil = require("../Utils/DelaunayUtil")
local DrawUtil = require("../Utils/DrawUtil")

export type DelaunayTriangle = DelaunayTriangle.DelaunayTriangle
export type DelaunayTriangleEdge = DelaunayTriangleEdge.DelaunayTriangleEdge
export type Triangle2d = Triangle2d.Triangle2d

type int = number

local NO_ADJACENT_TRIANGLE = -1
local NOT_FOUND = -1

local TestService = game:GetService("TestService")
TestService:SetAttribute("Step", false)
local function awaitInput()
	TestService:GetAttributeChangedSignal("Step"):Wait()
	TestService:SetAttribute("Step", false)
end

export type DelaunayTriangleSet = {

	Points: { Vector2 }, -- Array of 2D vectors (Vector2). Points are never removed from triangulation.
	TriangleVertices: { int }, -- Array of indices that point to Points defining triangles (groups of 3).
	AdjacentTriangles: { int }, -- Array of indices pointing to the 3 adjacent triangles of each triangle in CCW order (groups of 3).

	AddPoint: (self: DelaunayTriangleSet, point: Vector2) -> int,
	GetIndexOfPoint: (self: DelaunayTriangleSet, point: Vector2) -> int,
	GetPointFromIndex: (self: DelaunayTriangleSet, index: int) -> Vector2,
	GetTriangleCount: (self: DelaunayTriangleSet) -> int,
	AddTriangle: (self: DelaunayTriangleSet, newTriangle: DelaunayTriangle) -> int,
	AddRawTriangle: (
		self: DelaunayTriangleSet,
		p1: Vector2,
		p2: Vector2,
		p3: Vector2,
		adjacentTriangleA: int,
		adjacentTriangleB: int,
		adjacentTriangleC: int
	) -> int,
	AreEdgesEqual: (self: DelaunayTriangleSet, v1a: int, v1b: int, v2a: int, v2b: int) -> boolean,
	FindTriangleWithEdge: (self: DelaunayTriangleSet, edgeVertexIndexA: int, edgeVertexIndexB: int) -> int,
	GetTriangleVertexIndices: (self: DelaunayTriangleSet, triangleIndex: int) -> (int, int, int),
	GetTriangleEdgeIndices: (self: DelaunayTriangleSet, triangleIndex: int) -> { { int } },
	GetTrianglePoints: (self: DelaunayTriangleSet, triangleIndex: int) -> Triangle2d,
	GetDelaunayTriangle: (self: DelaunayTriangleSet, triangleIndex: int) -> DelaunayTriangle,
	GetTrianglesInPolygon: (
		self: DelaunayTriangleSet,
		polygonOutline: { int },
		_outputTrianglesInPolygon: { int }?
	) -> { int },
	FindTriangleThatContainsEdge: (
		self: DelaunayTriangleSet,
		edgeVertexIndexA: int,
		edgeVertexIndexB: int
	) -> DelaunayTriangleEdge,
	GetTrianglesWithVertex: (self: DelaunayTriangleSet, vertexIndex: int, _outputTriangles: { int }?) -> { int },
	GetAdjacentTriangleVertexIndices: (self: DelaunayTriangleSet, triangleIndex: int) -> (int, int, int),
	SetAdjacentTriangle: (
		self: DelaunayTriangleSet,
		triangleIndex: int,
		adjacentPosition: int,
		newAdjacentTriangleIndex: int
	) -> (),
	FindTriangleThatContainsPoint: (self: DelaunayTriangleSet, point: Vector2, startingTriangleIndex: int?) -> int,
	clear: (self: DelaunayTriangleSet) -> (),
	SetTriangleAdjacency: (self: DelaunayTriangleSet, triangleIndex: int, adjacentsToTriangle: { int }) -> (),
	ReplaceAdjacent: (
		self: DelaunayTriangleSet,
		triangleIndex: int,
		oldAdjacentTriangle: int,
		newAdjacentTriangle: int
	) -> (),
	ReplaceTriangle: (self: DelaunayTriangleSet, triangleIndex: int, newTriangle: DelaunayTriangle) -> (),
	FindTriangleThatContainsLineEndpoint: (
		self: DelaunayTriangleSet,
		endpointAIndex: int,
		endpointBIndex: int
	) -> int,
	GetIntersectingEdges: (
		self: DelaunayTriangleSet,
		lineEndpointA: Vector2,
		lineEndpointB: Vector2,
		startTriangle: int,
		_intersectingEdges: { DelaunayTriangleEdge }?
	) -> { DelaunayTriangleEdge },
}

--------------------------------------------------------------------------------
--// Class //--
--------------------------------------------------------------------------------

local DelaunayTriangleSet = {}
DelaunayTriangleSet.__index = DelaunayTriangleSet

--[=[
    Creates a new instance of DelaunayTriangleSet.

    @return DelaunayTriangleSet -- A new instance of the DelaunayTriangleSet class.
]=]
function DelaunayTriangleSet.new(): DelaunayTriangleSet
	return setmetatable({
		Points = {} :: { Vector2 }, -- Array of 2D vectors (Vector2). Points are never removed from triangulation.
		TriangleVertices = {} :: { int }, -- Array of indices that point to Points defining triangles (groups of 3).
		AdjacentTriangles = {} :: { int }, -- Array of indices pointing to the 3 adjacent triangles of each triangle in CCW order (groups of 3).
	}, DelaunayTriangleSet) :: any
end

--[=[
    Clears all data from the DelaunayTriangleSet, resetting it to an empty state.
]=]
function DelaunayTriangleSet.clear(self: DelaunayTriangleSet)
	table.clear(self.Points)
	table.clear(self.TriangleVertices)
	table.clear(self.AdjacentTriangles)
end

--[=[
    Adds a point to the Points array and returns its index.

    @param point Vector2 -- The point to add.
    @return int -- The index of the added point.
]=]
function DelaunayTriangleSet.AddPoint(self: DelaunayTriangleSet, point: Vector2): int
	table.insert(self.Points, point)
	return #self.Points
end

--[=[
    Finds the index of a given point in the Points array.

    @param point Vector2 -- The point to search for.
    @return int -- The index of the point if found, or -1 if not found.
]=]
function DelaunayTriangleSet.GetIndexOfPoint(self: DelaunayTriangleSet, point: Vector2): int
	for i, p in self.Points do
		if p == point then
			return i
		end
	end
	return NOT_FOUND
end

--[=[
    Retrieves a point from the Points array by its index.

    @param index int -- The index of the point.
    @return Vector2 -- The point at the given index.
]=]
function DelaunayTriangleSet.GetPointFromIndex(self: DelaunayTriangleSet, index: int): Vector2
	return self.Points[index]
end

--[=[
    Gets the total number of triangles in the triangulation.

    @return int -- The number of triangles.
]=]
function DelaunayTriangleSet.GetTriangleCount(self: DelaunayTriangleSet): int
	return #self.TriangleVertices / 3
end

--[=[
    Adds a triangle to the triangulation.

    @param newTriangle DelaunayTriangle -- The triangle to add.
    @return int -- The index of the added triangle.
]=]
function DelaunayTriangleSet.AddTriangle(self: DelaunayTriangleSet, newTriangle: DelaunayTriangle)
	for _, vertex in ipairs(newTriangle.Points) do
		table.insert(self.TriangleVertices, vertex)
	end
	for _, adjacent in ipairs(newTriangle.AdjacentTriangles) do
		table.insert(self.AdjacentTriangles, adjacent)
	end

	-- Debug: Print added triangle
	-- print("Added triangle", newTriangle, self, debug.traceback())

	return self:GetTriangleCount() -- Return the index of the added triangle
end

--[=[
    Adds a raw triangle to the triangulation using its vertices and adjacent triangles.

    @param p1 Vector2 -- The first vertex of the triangle.
    @param p2 Vector2 -- The second vertex of the triangle.
    @param p3 Vector2 -- The third vertex of the triangle.
    @param adjacentTriangleA int -- The first adjacent triangle index.
    @param adjacentTriangleB int -- The second adjacent triangle index.
    @param adjacentTriangleC int -- The third adjacent triangle index.
    @return int -- The index of the added triangle.
]=]
function DelaunayTriangleSet.AddRawTriangle(
	self: DelaunayTriangleSet,
	p1: Vector2,
	p2: Vector2,
	p3: Vector2,
	adjacentTriangleA: int,
	adjacentTriangleB: int,
	adjacentTriangleC: int
): int
	table.insert(self.AdjacentTriangles, adjacentTriangleA)
	table.insert(self.AdjacentTriangles, adjacentTriangleB)
	table.insert(self.AdjacentTriangles, adjacentTriangleC)

	table.insert(self.TriangleVertices, self:AddPoint(p1))
	table.insert(self.TriangleVertices, self:AddPoint(p2))
	table.insert(self.TriangleVertices, self:AddPoint(p3))

	-- Debug: Print added raw triangle
	-- print("Added Raw triangle", p1, p2, p3, adjacentTriangleA, adjacentTriangleB, adjacentTriangleC, self)

	return self:GetTriangleCount() -- Return the index of the added triangle
end

--[=[
    Checks if two edges are equal, regardless of their vertex order.

    @param v1a int -- The first vertex of the first edge.
    @param v1b int -- The second vertex of the first edge.
    @param v2a int -- The first vertex of the second edge.
    @param v2b int -- The second vertex of the second edge.
    @return boolean -- True if the edges are equal, false otherwise.
]=]
function DelaunayTriangleSet.AreEdgesEqual(self: DelaunayTriangleSet, v1a: int, v1b: int, v2a: int, v2b: int): boolean
	return (v1a == v2a and v1b == v2b) or (v1a == v2b and v1b == v2a)
end

--[=[
    Finds the index of a triangle that contains a specific edge.

    @param edgeVertexIndexA int -- The index of the first vertex of the edge.
    @param edgeVertexIndexB int -- The index of the second vertex of the edge.
    @return int -- The index of the triangle if found, or -1 if not found.
]=]
function DelaunayTriangleSet.FindTriangleWithEdge(
	self: DelaunayTriangleSet,
	edgeVertexIndexA: int,
	edgeVertexIndexB: int
): int
	for i = 1, self:GetTriangleCount() do
		local v0, v1, v2 = self:GetTriangleVertexIndices(i)
		if
			self:AreEdgesEqual(v0, v1, edgeVertexIndexA, edgeVertexIndexB)
			or self:AreEdgesEqual(v1, v2, edgeVertexIndexA, edgeVertexIndexB)
			or self:AreEdgesEqual(v2, v0, edgeVertexIndexA, edgeVertexIndexB)
		then
			return i
		end
	end
	return NOT_FOUND
end

--[=[
    Retrieves the vertex indices of a triangle by its index.

    @param triangleIndex int -- The index of the triangle.
    @return int, int, int -- The three vertex indices of the triangle.
]=]
function DelaunayTriangleSet.GetTriangleVertexIndices(self: DelaunayTriangleSet, triangleIndex: int): (int, int, int)
	local baseIndex = (triangleIndex - 1) * 3
	return self.TriangleVertices[baseIndex + 1],
		self.TriangleVertices[baseIndex + 2],
		self.TriangleVertices[baseIndex + 3]
end

--[=[
    Retrieves the edges of a triangle as pairs of vertex indices.

    @param triangleIndex int -- The index of the triangle.
    @return {{int}} -- A table containing the edges as pairs of vertex indices.
]=]
function DelaunayTriangleSet.GetTriangleEdgeIndices(self: DelaunayTriangleSet, triangleIndex: int): { { int } }
	local triangleVertices = self.TriangleVertices
	local baseIndex = (triangleIndex - 1) * 3
	return {
		{ triangleVertices[baseIndex + 1], triangleVertices[baseIndex + 2] },
		{ triangleVertices[baseIndex + 2], triangleVertices[baseIndex + 3] },
		{ triangleVertices[baseIndex + 3], triangleVertices[baseIndex + 1] },
	}
end

--[=[
	Gets a true 2D triangle based on the vertices of a triangle by its index.

	@param triangleIndex int -- The index of the triangle.
	@return Triangle2d -- The 2D triangle object.
]=]
function DelaunayTriangleSet.GetTrianglePoints(self: DelaunayTriangleSet, triangleIndex: int): Triangle2d
	assert(triangleIndex > 0 and triangleIndex <= self:GetTriangleCount(), "Triangle index out of bounds")
	local points, triangleVertices = self.Points, self.TriangleVertices
	local baseIndex = (triangleIndex - 1) * 3
	return Triangle2d.new(
		points[triangleVertices[baseIndex + 1]],
		points[triangleVertices[baseIndex + 2]],
		points[triangleVertices[baseIndex + 3]]
	)
end

--[=[
	Gets a DelaunayTriangle based on the vertices of a triangle by its index.

	@param triangleIndex int -- The index of the triangle in the TriangleVertices array.
	@return DelaunayTriangle -- The DelaunayTriangle object corresponding to the given index.
]=]
function DelaunayTriangleSet.GetDelaunayTriangle(self: DelaunayTriangleSet, triangleIndex: int): DelaunayTriangle
	local triangleVertices, adjacentTriangles = self.TriangleVertices, self.AdjacentTriangles
	local baseIndex = (triangleIndex - 1) * 3 + 1
	return DelaunayTriangle.new(
		triangleVertices[baseIndex],
		triangleVertices[baseIndex + 1],
		triangleVertices[baseIndex + 2],
		adjacentTriangles[baseIndex],
		adjacentTriangles[baseIndex + 1],
		adjacentTriangles[baseIndex + 2]
	)
end

--[=[
	Given the outline of a closed polygon, expressed as a list of vertices, it finds all the triangles that lay inside of the figure.

	@param polygonOutline {int} -- The outline, a list of vertex indices sorted counter-clockwise.
	@param _outputTrianglesInPolygon {int}? -- An optional array to store the output triangle indices. No elements are removed from this list. If not provided, a new array will be created.
	@return {int} -- The indices of triangles inside the polygon.
]=]
function DelaunayTriangleSet.GetTrianglesInPolygon(
	self: DelaunayTriangleSet,
	polygonOutline: { int },
	_outputTrianglesInPolygon: { int }?
): { int }
	debug.profilebegin("GetTrianglesInPolygon")
	-- This method assumes that the edges of the triangles to find were created using the same vertex order
	-- It also assumes all triangles are inside a supertriangle, so no adjacent triangles are -1

	local outputTrianglesInPolygon = _outputTrianglesInPolygon or {}

	local adjacentTrianglesStack: { int } = {} -- Stack
	local AdjacentTriangles = self.AdjacentTriangles
	local TriangleVertices = self.TriangleVertices

	local polygonOutlineCount = #polygonOutline
	for i = 1, polygonOutlineCount do
		-- For every edge, it gets the inner triangle that contains such edge
		local triangleEdge: DelaunayTriangleEdge =
			self:FindTriangleThatContainsEdge(polygonOutline[i], polygonOutline[i % polygonOutlineCount + 1])
		local edgeTriangleIndex = triangleEdge.TriangleIndex

		-- A triangle may form a corner, with 2 consecutive outline edges. This avoids adding it twice
		if
			#outputTrianglesInPolygon > 0
			and (
				outputTrianglesInPolygon[#outputTrianglesInPolygon] == edgeTriangleIndex -- Is the last added triangle the same as current?
				or outputTrianglesInPolygon[1] == edgeTriangleIndex
			) -- Is the first added triangle the same as the current, which is the last to be added (closes the polygon)?
		then
			continue -- Skip if the triangle is already in the output list
		end

		table.insert(outputTrianglesInPolygon, edgeTriangleIndex) -- Add the triangle to the output list

		local previousOutlineEdgeVertexA = polygonOutline[(i + polygonOutlineCount - 2) % polygonOutlineCount + 1]
		local previousOutlineEdgeVertexB = polygonOutline[i]
		local nextOutlineEdgeVertexA = polygonOutline[i % polygonOutlineCount + 1]
		local nextOutlineEdgeVertexB = polygonOutline[(i + 1) % polygonOutlineCount + 1]

		-- do -- Debug
		-- 	local trianglePoints = self:GetTrianglePoints(edgeTriangleIndex)
		-- 	DrawUtil.DrawTriangle(trianglePoints, BrickColor.Yellow().Color)

		-- 	local p1 = self:GetPointFromIndex(triangleEdge.EdgeVertexA)
		-- 	local p2 = self:GetPointFromIndex(triangleEdge.EdgeVertexB)
		-- 	DrawUtil.DrawRay(p1, p2 - p1, BrickColor.Blue().Color)

		-- 	local p3 = self:GetPointFromIndex(previousOutlineEdgeVertexA)
		-- 	local p4 = self:GetPointFromIndex(previousOutlineEdgeVertexB)
		-- 	DrawUtil.DrawRay(p3, p4 - p3, BrickColor.Red().Color)

		-- 	local p5 = self:GetPointFromIndex(nextOutlineEdgeVertexA)
		-- 	local p6 = self:GetPointFromIndex(nextOutlineEdgeVertexB)
		-- 	DrawUtil.DrawRay(p5, p6 - p5, BrickColor.Green().Color)
		-- 	task.wait(1)
		-- end

		for j = 1, 2 do --  For the 2 adjacent triangles of the other 2 edges
			local adjacentTriangleIndex =
				AdjacentTriangles[(edgeTriangleIndex - 1) * 3 + (triangleEdge.EdgeIndex + j - 1) % 3 + 1]
			local isAdjacentTriangleInOutline = false

			-- Compare the contiguous edges of the outline, to the right and to the left of the current one, flipped and not flipped, with the adjacent triangle's edges
			local adjacentBaseIndex = (adjacentTriangleIndex - 1) * 3
			for k = 1, 3 do
				local currentTriangleEdgeVertexA = TriangleVertices[adjacentBaseIndex + k]
				local currentTriangleEdgeVertexB = TriangleVertices[adjacentBaseIndex + (if k == 3 then 1 else k + 1)]

				if
					(
						currentTriangleEdgeVertexA == previousOutlineEdgeVertexA
						and currentTriangleEdgeVertexB == previousOutlineEdgeVertexB
					)
					or (currentTriangleEdgeVertexA == previousOutlineEdgeVertexB and currentTriangleEdgeVertexB == previousOutlineEdgeVertexA)
					or (currentTriangleEdgeVertexA == nextOutlineEdgeVertexA and currentTriangleEdgeVertexB == nextOutlineEdgeVertexB)
					or (
						currentTriangleEdgeVertexA == nextOutlineEdgeVertexB
						and currentTriangleEdgeVertexB == nextOutlineEdgeVertexA
					)
				then
					isAdjacentTriangleInOutline = true -- The triangle is adjacent to the edge of the polygon outline
					break -- No need to check the other edges
				end
			end

			if
				not isAdjacentTriangleInOutline
				and table.find(outputTrianglesInPolygon, adjacentTriangleIndex) == nil
			then
				-- If the triangle is not already in the output list, add it to the stack
				-- DrawUtil.DrawTriangle(self:GetTrianglePoints(adjacentTriangleIndex), BrickColor.Red().Color)
				-- task.wait(1)
				table.insert(adjacentTrianglesStack, adjacentTriangleIndex)
			end
		end
	end

	-- Then it propagates by adjacency, stopping when an adjacent triangle has already been included in the list
	-- Since all the outline triangles have been added previously, it will not propagate outside of the polygon
	debug.profilebegin("PropagateAdjacentTriangles")
	while #adjacentTrianglesStack > 0 do
		local currentTriangle = table.remove(adjacentTrianglesStack) :: number -- Pop the last triangle from the stack

		if table.find(outputTrianglesInPolygon, currentTriangle) then
			continue -- Skip if the triangle is already in the output list
		end

		local baseIndex = (currentTriangle - 1) * 3 + 1
		for i = baseIndex, baseIndex + 2 do
			local adjacentTriangle = AdjacentTriangles[baseIndex]
			if
				adjacentTriangle ~= NO_ADJACENT_TRIANGLE
				and table.find(outputTrianglesInPolygon, adjacentTriangle) == nil
			then
				table.insert(adjacentTrianglesStack, adjacentTriangle) -- Add the adjacent triangle to the stack
			end
		end

		-- DrawUtil.DrawTriangle(self:GetTrianglePoints(currentTriangle), BrickColor.Green().Color)
		-- task.wait(1)
		table.insert(outputTrianglesInPolygon, currentTriangle) -- Add the triangle to the output list
	end
	debug.profileend()

	debug.profileend()
	return outputTrianglesInPolygon
end

--[=[
	Calculates which edges of the triangulation intersect with a proposed line segment AB.

	@param lineEndpointA Vector2 -- The first endpoint of the line segment.
	@param lineEndpointB Vector2 -- The second endpoint of the line segment.
	@param startTriangle int -- The index of the triangle to start searching from.
	@param _intersectingEdges {DelaunayTriangleEdge}? -- An optional array to store the intersecting edges. If not provided, a new array will be created.
	@return {DelaunayTriangleEdge} -- The intersecting edges.
]=]
function DelaunayTriangleSet.GetIntersectingEdges(
	self: DelaunayTriangleSet,
	lineEndpointA: Vector2,
	lineEndpointB: Vector2,
	startTriangle: int,
	_intersectingEdges: { DelaunayTriangleEdge }?
): { DelaunayTriangleEdge }
	debug.profilebegin("GetIntersectingEdges")
	local intersectingEdges = _intersectingEdges or {}
	local Points: { Vector2 } = self.Points
	local AdjacentTriangles: { int } = self.AdjacentTriangles

	local isTriangleContainingBFound = false
	local triangleIndex = startTriangle

	-- DrawUtil.DrawRay(lineEndpointA, lineEndpointB - lineEndpointA, BrickColor.Green().Color, 0.8)

	while not isTriangleContainingBFound do
		local hasCrossedEdge = false
		local tentativeAdjacentTriangle = NO_ADJACENT_TRIANGLE

		-- DrawUtil.DrawTriangle(self:GetTrianglePoints(triangleIndex), BrickColor.Yellow().Color)

		local edges = self:GetTriangleEdgeIndices(triangleIndex)
		for i = 1, 3 do
			-- Get the vertices of the current edge
			local edgeVertexA = edges[i][1]
			local edgeVertexB = edges[i][2]

			-- DrawUtil.DrawRay(points[edgeVertexA], points[edgeVertexB] - points[edgeVertexA], BrickColor.Blue().Color)

			-- Check if the edge contains lineEndpointB
			if Points[edgeVertexA] == lineEndpointB or Points[edgeVertexB] == lineEndpointB then
				isTriangleContainingBFound = true
				break
			end

			-- Check if lineEndpointB is to the right of the edge
			if DelaunayUtil.IsPointToTheRightOfEdge(Points[edgeVertexA], Points[edgeVertexB], lineEndpointB) then
				tentativeAdjacentTriangle = i

				-- DrawUtil.DrawLine(points[edgeVertexA], points[edgeVertexB], BrickColor.Green().Color, 0.7)

				-- Check if the line segment intersects the edge
				if
					DelaunayUtil.AreLineSegmentsIntersecting(
						Points[edgeVertexA],
						Points[edgeVertexB],
						lineEndpointA,
						lineEndpointB
					)
				then
					hasCrossedEdge = true

					-- Add the intersecting edge to the list
					table.insert(
						intersectingEdges,
						DelaunayTriangleEdge.new(NOT_FOUND, NOT_FOUND, edgeVertexA, edgeVertexB)
					)

					-- DrawUtil.DrawLine(points[edgeVertexA], points[edgeVertexB], BrickColor.Red().Color, 0.8)
					-- print("Found intersecting edge:", triangleIndex, "Edge:", i, "LineEndpointA:", lineEndpointA, "LineEndpointB:", lineEndpointB, "Edge:", edgeVertexA, edgeVertexB)

					-- Check if the edge contains lineEndpointA
					if Points[edgeVertexA] == lineEndpointA or Points[edgeVertexB] == lineEndpointA then
						isTriangleContainingBFound = true
						-- print("Found triangle containing A:", triangleIndex, "Edge:", i, "LineEndpointA:", lineEndpointA, "Edge:", edgeVertexA, edgeVertexB)
						break
					end

					-- The point is in the exterior of the triangle (vertices are sorted CCW, the right side is always the exterior from the perspective of the A->B edge)
					-- Move to the adjacent triangle
					triangleIndex = AdjacentTriangles[(triangleIndex - 1) * 3 + i]
					break
				end
			end
		end

		-- If no edge was crossed, continue searching at a different adjacent triangle
		if not hasCrossedEdge then
			triangleIndex = AdjacentTriangles[(triangleIndex - 1) * 3 + tentativeAdjacentTriangle]
		end
	end
	debug.profileend()
	-- warn("Intersecting edges:", intersectingEdges, "| Self:", self)
	return intersectingEdges
end

--[=[
    Given a point, it searches for a triangle that contains it.

    @param point Vector2 -- The point expected to be contained by a triangle.
    @param startTriangle int? -- The index of the first triangle to check. Defaults to the last triangle.
    @return int -- The index of the triangle that contains the point.
]=]
function DelaunayTriangleSet.FindTriangleThatContainsPoint(
	self: DelaunayTriangleSet,
	point: Vector2,
	startTriangle: int?
): int
	debug.profilebegin("FindTriangleThatContainsPoint")

	local tCount = self:GetTriangleCount()
	startTriangle = startTriangle or tCount -- Default to the last triangle if not provided
	local isTriangleFound = false
	local triangleIndex = startTriangle
	local checkedTriangles = 0

	local Points = self.Points
	local TriangleVertices = self.TriangleVertices
	local AdjacentTriangles = self.AdjacentTriangles

	-- DrawUtil.DrawPoint(point, BrickColor.Green().Color, 3).Name = "PointToFind"

	while not isTriangleFound and checkedTriangles < tCount do
		isTriangleFound = true

		local baseIndex = (triangleIndex - 1) * 3
		for i = 1, 3 do
			local vertexA = Points[TriangleVertices[baseIndex + i]]
			local vertexB = Points[TriangleVertices[baseIndex + (i % 3) + 1]]

			-- task.wait()
			-- DrawUtil.DrawPoint(vertexA, BrickColor.Blue().Color, 1)
			-- DrawUtil.DrawRay(vertexA, vertexB - vertexA, BrickColor.Blue().Color)

			if DelaunayUtil.IsPointToTheRightOfEdge(vertexA, vertexB, point) then
				-- The point is in the exterior of the triangle (vertices are sorted CCW, the
				-- right side is always the exterior from the perspective of the A->B edge)
				triangleIndex = AdjacentTriangles[baseIndex + i]
				isTriangleFound = false
				break
			end
		end

		checkedTriangles += 1
	end

	if checkedTriangles >= tCount and tCount > 1 then
		-- Fallback: if walking failed (usually due numeric ambiguity/cycles),
		-- do a deterministic linear scan over all triangles.
		for candidateTriangleIndex = 1, tCount do
			local candidateBaseIndex = (candidateTriangleIndex - 1) * 3
			local containsPoint = true

			for i = 1, 3 do
				local vertexA = Points[TriangleVertices[candidateBaseIndex + i]]
				local vertexB = Points[TriangleVertices[candidateBaseIndex + (i % 3) + 1]]
				if DelaunayUtil.IsPointToTheRightOfEdge(vertexA, vertexB, point) then
					containsPoint = false
					break
				end
			end

			if containsPoint then
				debug.profileend()
				warn(
					"Had to fallback to linear scan to find triangle containing point. This may indicate numerical instability or very small triangles. Consider adding more robust handling for such cases.",
					"Point:",
					point,
					"TriangleIndexFound:",
					candidateTriangleIndex,
					"StartTriangle:",
					startTriangle
				)
				return candidateTriangleIndex
			end
		end

		for i = 1, tCount do
			local triangleVisual = DrawUtil.DrawTriangle(self:GetTrianglePoints(i) :: any, BrickColor.Gray().Color)
			triangleVisual.Name = "Triangle_" .. i .. "_At_Time_Of_Failure"
		end
		local pointVisual = DrawUtil.DrawPoint(point, BrickColor.Red().Color, 3)
		pointVisual.Name = "Point We Failed to Find Triangle For!"
		print(self, "Visuals:", pointVisual)
		error(
			("Unable to find a triangle that contains the point (%f, %f), starting at triangle %d. Are you generating very small triangles?"):format(
				point.X,
				point.Y,
				startTriangle :: number
			)
		)
	end

	debug.profileend()
	return triangleIndex
end

--[=[
    Given an edge AB, it searches for a triangle that contains the first point and the beginning of the edge.

    @param endpointAIndex int -- The index of the first point.
    @param endpointBIndex int -- The index of the second point.
    @return int -- The index of the triangle that contains the first line endpoint.
]=]
function DelaunayTriangleSet.FindTriangleThatContainsLineEndpoint(
	self: DelaunayTriangleSet,
	endpointAIndex: int,
	endpointBIndex: int
): int
	debug.profilebegin("FindTriangleThatContainsLineEndpoint")
	local Points = self.Points
	local TriangleVertices = self.TriangleVertices

	-- Get all triangles that share the vertex at endpointA
	local trianglesWithEndpoint = self:GetTrianglesWithVertex(endpointAIndex)
	if #trianglesWithEndpoint == 0 then
		warn("Unable to find a triangle that contains the line endpoint. No triangles share the vertex.")
		return NOT_FOUND -- No triangles found with the given endpoint
	end

	local foundTriangle = NOT_FOUND
	local endpointA = Points[endpointAIndex]
	local endpointB = Points[endpointBIndex]
	assert(endpointA and endpointB, "Invalid endpoints provided.")

	for _, triangleIndex in trianglesWithEndpoint do
		local baseIndex = (triangleIndex - 1) * 3
		-- Determine the position of endpointA in the triangle
		local vertexPositionInTriangle = 3
		if TriangleVertices[baseIndex + 1] == endpointAIndex then
			vertexPositionInTriangle = 1
		elseif TriangleVertices[baseIndex + 2] == endpointAIndex then
			vertexPositionInTriangle = 2
		end

		-- Get the two edges of the triangle that are contiguous to endpointA
		local triangleEdgePoint1 = Points[TriangleVertices[baseIndex + vertexPositionInTriangle % 3 + 1]]
		local triangleEdgePoint2 = Points[TriangleVertices[baseIndex + (vertexPositionInTriangle + 1) % 3 + 1]]

		-- Check if the line is within the angle formed by the two edges
		if
			DelaunayUtil.IsPointToTheRightOfEdge(triangleEdgePoint1, endpointA, endpointB)
			and DelaunayUtil.IsPointToTheRightOfEdge(endpointA, triangleEdgePoint2, endpointB)
		then
			foundTriangle = triangleIndex
			break
		end
	end

	if foundTriangle == NOT_FOUND then -- DEBUG
		warn("Unable to find a triangle that contains the line endpoint.", endpointB)
		DrawUtil.DrawPoint(endpointA, BrickColor.Red().Color, 3).Name = "LineEndpointA"
		DrawUtil.DrawPoint(endpointB, BrickColor.Blue().Color, 3).Name = "LineEndpointB"
		local jani = Janitor.new()
		for _, triangleIndex in trianglesWithEndpoint do
			jani:Cleanup()
			local baseIndex = (triangleIndex - 1) * 3
			-- Determine the position of endpointA in the triangle
			local vertexPositionInTriangle = 3
			if TriangleVertices[baseIndex + 1] == endpointAIndex then
				vertexPositionInTriangle = 1
			elseif TriangleVertices[baseIndex + 2] == endpointAIndex then
				vertexPositionInTriangle = 2
			end

			-- Get the two edges of the triangle that are contiguous to endpointA
			local triangleEdgePoint1 = Points[TriangleVertices[baseIndex + vertexPositionInTriangle % 3 + 1]]
			local triangleEdgePoint2 = Points[TriangleVertices[baseIndex + (vertexPositionInTriangle + 1) % 3 + 1]]

			local triangleVisual =
				DrawUtil.DrawTriangle(self:GetTrianglePoints(triangleIndex) :: any, BrickColor.random().Color)
			local ray1 = DrawUtil.DrawRay(triangleEdgePoint1, endpointA - triangleEdgePoint1, BrickColor.White().Color)
			local ray2 = DrawUtil.DrawRay(endpointA, triangleEdgePoint2 - endpointA, BrickColor.Yellow().Color)
			jani:Add(triangleVisual)
			jani:Add(ray1)
			jani:Add(ray2)
			assert(triangleEdgePoint1 ~= endpointB, "Triangle edge point 1 is equal to endpointB")
			assert(triangleEdgePoint2 ~= endpointB, "Triangle edge point 2 is equal to endpointB")
			awaitInput()

			-- Check if the line is within the angle formed by the two edges
			if
				DelaunayUtil.IsPointToTheRightOfEdge(triangleEdgePoint1, endpointA, endpointB)
				and DelaunayUtil.IsPointToTheRightOfEdge(endpointA, triangleEdgePoint2, endpointB)
			then
				print(
					"Found triangle:",
					triangleIndex,
					"Edge:",
					vertexPositionInTriangle,
					"LineEndpointA:",
					endpointA,
					"LineEndpointB:",
					endpointB
				)
				foundTriangle = triangleIndex
				break
			end
		end
		task.wait(20)
	end

	debug.profileend()
	return foundTriangle
end

--[=[
    Stores the adjacency data of a triangle.

    @param triangleIndex int -- The index of the triangle whose adjacency data is to be written.
    @param adjacentsToTriangle {int} -- The adjacency data, 3 triangle indices sorted counter-clockwise.
]=]
function DelaunayTriangleSet.SetTriangleAdjacency(
	self: DelaunayTriangleSet,
	triangleIndex: int,
	adjacentsToTriangle: { int }
)
	for i = 1, 3 do
		self.AdjacentTriangles[(triangleIndex - 1) * 3 + i] = adjacentsToTriangle[i]
	end
end

--[=[
    Given a triangle, it searches for an adjacent triangle and replaces it with another adjacent triangle.

    @param triangleIndex int -- The index of the triangle whose adjacency data is to be modified.
    @param oldAdjacentTriangle int -- The index of the adjacent triangle to be replaced.
    @param newAdjacentTriangle int -- The new index of an adjacent triangle that will replace the existing one.
]=]
function DelaunayTriangleSet.ReplaceAdjacent(
	self: DelaunayTriangleSet,
	triangleIndex: int,
	oldAdjacentTriangle: int,
	newAdjacentTriangle: int
)
	local baseIndex = (triangleIndex - 1) * 3
	local AdjacentTriangles = self.AdjacentTriangles
	for i = 1, 3 do
		if AdjacentTriangles[baseIndex + i] == oldAdjacentTriangle then
			AdjacentTriangles[baseIndex + i] = newAdjacentTriangle
		end
	end
end

--[=[
    Replaces all the data of a given triangle. The index of the triangle will remain the same.

    @param triangleIndex int -- The index of the triangle whose data is to be replaced.
    @param newTriangle DelaunayTriangle -- The new data that will replace the existing one.
]=]
function DelaunayTriangleSet.ReplaceTriangle(
	self: DelaunayTriangleSet,
	triangleIndex: int,
	newTriangle: DelaunayTriangle
)
	local baseIndex = (triangleIndex - 1) * 3
	local TriangleVertices = self.TriangleVertices
	local AdjacentTriangles = self.AdjacentTriangles
	for i = 1, 3 do
		TriangleVertices[baseIndex + i] = newTriangle.Points[i]
		AdjacentTriangles[baseIndex + i] = newTriangle.AdjacentTriangles[i]
	end
end

--[=[
	Given the index of a point, it obtains all the existing triangles that share that point.

	@param vertexIndex int -- The index of the point in the Points array.
	@param _outputTriangles {int}? -- An optional array to store the output triangle indices. If not provided, a new array will be created.
	@return {int} -- The indices of triangles that share the point.
]=]
function DelaunayTriangleSet.GetTrianglesWithVertex(
	self: DelaunayTriangleSet,
	vertexIndex: int,
	_outputTriangles: { int }?
): { int }
	local outputTriangles = _outputTriangles or {}
	local TriangleVertices = self.TriangleVertices
	for i = 1, self:GetTriangleCount() do
		local baseIndex = (i - 1) * 3
		for j = 1, 3 do
			if TriangleVertices[baseIndex + j] == vertexIndex then
				table.insert(outputTriangles, i)
				break
			end
		end
	end
	return outputTriangles
end

--[=[
	Given an edge AB, it searches for the triangle that has an edge with the same vertices in the same order.

	Remember that the vertices of a triangle are sorted counter-clockwise.

	@param edgeVertexA int -- The index of the first vertex of the edge.
	@param edgeVertexB int -- The index of the second vertex of the edge.
	@return DelaunayTriangleEdge -- The triangle edge object.
]=]
function DelaunayTriangleSet.FindTriangleThatContainsEdge(
	self: DelaunayTriangleSet,
	edgeVertexA: int,
	edgeVertexB: int
): DelaunayTriangleEdge
	debug.profilebegin("FindTriangleThatContainsEdge")
	local foundTriangle = DelaunayTriangleEdge.new(NOT_FOUND, NOT_FOUND, edgeVertexA, edgeVertexB)
	local vertices = self.TriangleVertices

	for baseIndex = 1, #vertices, 3 do
		for j = 0, 2 do
			if
				vertices[baseIndex + j] == edgeVertexA
				and vertices[if j == 2 then baseIndex else baseIndex + j + 1] == edgeVertexB
			then
				foundTriangle.TriangleIndex = (baseIndex - 1) / 3 + 1
				foundTriangle.EdgeIndex = j + 1
				debug.profileend()
				return foundTriangle
			end
		end
	end
	debug.profileend()
	return foundTriangle
end

--[=[
	Get the adjacent triangles of a triangle by its index.

	@param triangleIndex int -- The index of the triangle.
	@return int, int, int -- The indices of the adjacent triangles.
]=]
function DelaunayTriangleSet.GetAdjacentTriangleVertexIndices(
	self: DelaunayTriangleSet,
	triangleIndex: int
): (int, int, int)
	local baseIndex = (triangleIndex - 1) * 3
	return self.AdjacentTriangles[baseIndex + 1],
		self.AdjacentTriangles[baseIndex + 2],
		self.AdjacentTriangles[baseIndex + 3]
end

--[=[
	Set the adjacency of a triangle.

	@param triangleIndex int -- The index of the triangle.
	@param edgeIndex int -- The edge index of the triangle.
	@param adjacentTriangle int -- The index of the adjacent triangle.
]=]
function DelaunayTriangleSet.SetAdjacentTriangle(
	self: DelaunayTriangleSet,
	triangleIndex: int,
	edgeIndex: int,
	adjacentTriangle: int
)
	local baseIndex = (triangleIndex - 1) * 3
	self.AdjacentTriangles[baseIndex + edgeIndex] = adjacentTriangle
end

return DelaunayTriangleSet
