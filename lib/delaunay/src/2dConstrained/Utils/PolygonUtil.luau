-- filepath: c:\Users\Logan\Documents\GitHub\smurf-tycoon\src\Shared\Utils\Delaunay\PolygonMerger2.luau

local DrawUtil = require("./DrawUtil")

-- DEBUG FLAG
local DEBUG = true -- set to false to disable draw
local FLAG_SLOWDOWN = false
local EPSILON = 0.001 -- Small value to check for equality

type Polygon = { Vector2 }

local TestService = game:GetService("TestService")
TestService:SetAttribute("Step", false)
local function awaitInput()
	TestService:GetAttributeChangedSignal("Step"):Wait()
	TestService:SetAttribute("Step", false)
end

-- -95.231, 50, -14.893

--------------------------------------------------------------------------------
--// Utility Functions //--
--------------------------------------------------------------------------------

local function drawLine(a: Vector2, b: Vector2, color: Color3?, size: number?)
	if DEBUG then
		return DrawUtil.DrawLine(a, b, color or Color3.fromRGB(0, 255, 255), size or 0.2)
	end
	return nil
end

local function drawPoint(p: Vector2, color: Color3?, size: number?)
	if DEBUG then
		return DrawUtil.DrawPoint(p, color or Color3.fromRGB(255, 0, 0), size or 1)
	end
	return nil
end

local function drawRay(a: Vector2, b: Vector2, color: Color3?, size: number?)
	if DEBUG then
		return DrawUtil.DrawRay(a, b - a, color or Color3.fromRGB(255, 217, 0), size or 0.5)
	end
	return nil
end

local function drawPolygonOutline(polygon: Polygon, color: Color3?)
	if DEBUG then
		for i = 1, #polygon do
			local p1 = polygon[i]
			local p2 = polygon[i % #polygon + 1]
			drawLine(p1, p2, color)
		end
	end
	return nil
end

--------------------------------------------------------------------------------
--// Helper Functions //--
--------------------------------------------------------------------------------

local function fuzzyEq(v1: Vector2, v2: Vector2): boolean
	return (v2 - v1).Magnitude <= EPSILON
end

local function isCounterClockwisePolygon(polygon: Polygon): boolean
	local area = 0
	for i = 1, #polygon do
		local p1 = polygon[i]
		local p2 = polygon[i % #polygon + 1]
		area += (p2.X - p1.X) * (p2.Y + p1.Y)
	end
	return area < 0 -- Negative area means CCW
end

local function reversePolygon(polygon: Polygon): Polygon
	local reversed = {}
	for i = #polygon, 1, -1 do
		table.insert(reversed, polygon[i])
	end
	return reversed
end

local function edgeIntersection(p1: Vector2, p2: Vector2, q1: Vector2, q2: Vector2, dontIncludeEndpoints): Vector2?
	local r = p2 - p1
	local s = q2 - q1
	local qp = q1 - p1
	local denominator = r:Cross(s)

	if math.abs(denominator) < EPSILON then
		-- Collinear or parallel
		return nil
	end

	local t = qp:Cross(s) / denominator
	local u = qp:Cross(r) / denominator

	-- Check if intersection point is on the line segments
	if dontIncludeEndpoints then
		if t < 0 or t > 1 or u < 0 or u > 1 then
			return nil
		end
	else
		if t <= 0 or t >= 1 - 0 or u <= 0 or u >= 1 - 0 then
			return nil
		end
	end

	return Vector2.new(p1.X + t * r.X, p1.Y + t * r.Y)
end

-- local function isPointInPolygon(point: Vector2, polygon: Polygon): boolean
-- 	local count = 0
-- 	local rayEnd = Vector2.new(math.huge, point.Y)

-- 	for i = 1, #polygon do
-- 		local p1 = polygon[i]
-- 		local p2 = polygon[i % #polygon + 1]

-- 		if edgeIntersection(point, rayEnd, p1, p2) then
-- 			count += 1
-- 		end
-- 	end

-- 	return count % 2 == 1
-- end

local function isPointInPolygon(point: Vector2, polygon: Polygon): boolean
	local count = 0

	for i = 1, #polygon do
		local p1 = polygon[i]
		local p2 = polygon[i % #polygon + 1]

		-- Skip horizontal edges
		if p1.Y == p2.Y then
			continue
		end

		-- Check if the point is within the vertical range of the edge
		if (point.Y > math.min(p1.Y, p2.Y)) and (point.Y <= math.max(p1.Y, p2.Y)) then
			-- Compute the intersection point's X-coordinate
			local xIntersection = p1.X + (point.Y - p1.Y) * (p2.X - p1.X) / (p2.Y - p1.Y)

			-- Count the intersection if it is to the right of the point
			if xIntersection > point.X then
				count += 1
			end
		end
	end

	-- Odd count means the point is inside the polygon
	return count % 2 == 1
end

local function isCounterClockwise(p1: Vector2, p2: Vector2, p3: Vector2): boolean
	return (p2.X - p1.X) * (p3.Y - p1.Y) - (p2.Y - p1.Y) * (p3.X - p1.X) > 0
end

local function getAABB(polygon: Polygon): (Vector2, Vector2)
	local minX, minY = math.huge, math.huge
	local maxX, maxY = -math.huge, -math.huge

	for _, point in ipairs(polygon) do
		minX = math.min(minX, point.X)
		minY = math.min(minY, point.Y)
		maxX = math.max(maxX, point.X)
		maxY = math.max(maxY, point.Y)
	end

	return Vector2.new(minX, minY), Vector2.new(maxX, maxY)
end

local mergeAttempts = 0
local function mergePolygons(polyA: Polygon, polyB: Polygon): Polygon?
	mergeAttempts += 1
	local Visualize = false
	-- if mergeAttempts >= 2 then
	-- 	Visualize = true
	-- end

	-- Step 1: Create graph that describes the polygons
	local vertices = {}
	local edges = {}

	-- Helper function to add a vertex and return its index
	local function addVertex(point: Vector2): number
		for i, v in vertices do
			if fuzzyEq(point, v) then
				-- print("Found existing vertex:", point, "at index", i)
				return i
			end
		end
		table.insert(vertices, point)
		-- drawPoint(point, Color3.fromRGB(0, 255, 0), 3)
		return #vertices
	end

	-- Helper function to add an edge
	local function addEdge(v1: number, v2: number)
		table.insert(edges, { v1 = v1, v2 = v2, visited = false })
		-- drawRay(vertices[v1], vertices[v2], Color3.fromRGB(0, 102, 255), 0.2).Name = v1.."->"..v2
	end

	local didIntersect = false
	-- Find intersections and construct the graph
	local function processPolygon(polygon: Polygon, otherPolygon: Polygon)
		for i = 1, #polygon do
			local p1 = polygon[i]
			local p2 = polygon[i % #polygon + 1]
			local v1 = addVertex(p1)
			local v2 = addVertex(p2)

			if v1 == v2 then
				warn("Duplicate vertices found in polygon. Skipping:", p1, p2)
				continue
			end

			local edgeIntersections = {}
			for j = 1, #otherPolygon do
				local q1 = otherPolygon[j]
				local q2 = otherPolygon[j % #otherPolygon + 1]
				local intersection = edgeIntersection(p1, p2, q1, q2)
				if intersection then
					table.insert(edgeIntersections, { point = intersection, dist = (intersection - p1).Magnitude })
					didIntersect = true
				end
			end

			table.sort(edgeIntersections, function(a, b)
				return a.dist < b.dist
			end)

			local lastVertex = v1
			for _, inter in ipairs(edgeIntersections) do
				local interIdx = addVertex(inter.point)
				addEdge(lastVertex, interIdx)
				-- task.wait(0.2)
				lastVertex = interIdx
			end
			addEdge(lastVertex, v2)
		end
	end

	processPolygon(polyA, polyB)
	processPolygon(polyB, polyA)

	-- Step 2: Check constructed graph
	if not didIntersect then
		if isPointInPolygon(polyA[1], polyB) then
			return polyB
		elseif isPointInPolygon(polyB[1], polyA) then
			return polyA
		else
			warn("Polygons are separate and do not intersect.")
			return nil -- No intersection, return both polygons separately
		end
	end

	-- Step 3: Find left-bottom vertex
	local leftBottomIdx = 1
	for i, vertex in vertices do
		if
			vertex.X < vertices[leftBottomIdx].X
			or (vertex.X == vertices[leftBottomIdx].X and vertex.Y < vertices[leftBottomIdx].Y)
		then
			leftBottomIdx = i
		end
	end

	-- Step 4: Construct common contour
	local result = {}
	local currentVertex = leftBottomIdx
	local currentEdge = nil

	-- local color = BrickColor.random().Color

	if Visualize then
		drawPolygonOutline(polyA, Color3.fromRGB(255, 0, 255))
		drawPolygonOutline(polyB, Color3.fromRGB(0, 255, 255))

		for i = 1, #vertices do
			local point = drawPoint(vertices[i], Color3.fromRGB(0, 255, 0), 2)
			point.Name = "Vertex_" .. i
		end

		for i = 1, #edges do
			local edge = edges[i]
			local edgeVisual = drawRay(vertices[edge.v1], vertices[edge.v2], nil, 0.2)
			edgeVisual.Name = edge.v1 .. "->" .. edge.v2
		end

		awaitInput()
	end

	repeat
		table.insert(result, vertices[currentVertex])
		local maxAngle = -math.huge
		local nextEdge = nil

		for _, edge in edges do
			-- print("Checking edge", edge.v1, edge.v2)
			if not edge.visited and (edge.v1 == currentVertex or edge.v2 == currentVertex) then
				local nextVertex = (edge.v1 == currentVertex) and edge.v2 or edge.v1
				local vector1 = vertices[currentVertex]
					- (currentEdge and vertices[currentEdge.v1] or Vector2.new(0, 0))
				local vector2 = vertices[nextVertex] - vertices[currentVertex]
				local angle = math.atan2(-vector1:Cross(vector2), vector1:Dot(vector2))
				-- drawRay(vertices[currentVertex], vertices[nextVertex], Color3.fromRGB(255, 0, 0), 0.25)
				-- print(angle, maxAngle)
				-- awaitInput()
				if angle > maxAngle then
					maxAngle = angle
					nextEdge = edge
				end
			end
		end

		if nextEdge then
			-- drawRay(vertices[nextEdge.v1], vertices[nextEdge.v2], color)
			-- task.wait(0.25)
			nextEdge.visited = true
			currentEdge = nextEdge
			currentVertex = if currentEdge.v1 == currentVertex then currentEdge.v2 else currentEdge.v1
		end
	until currentVertex == leftBottomIdx

	-- DEBUG
	if Visualize then
		local color = BrickColor.random().Color
		for i = 1, #result do
			local p1 = result[i]
			local p2 = result[i % #result + 1]
			drawRay(p1, p2, color, 0.5)
			task.wait(0.1)
		end
		awaitInput()
	end

	-- task.wait(3)

	return result
end

-- Polygons are represented as a table of Vector2 points in CCW order
local tests = 0
local function mergePolygonsOld(polyA: Polygon, polyB: Polygon): Polygon?
	local merged = {}
	local startIndex, startPoint = 1, nil

	-- tests += 1
	-- if tests == 2 then
	-- 	drawPolygonOutline(polyA, Color3.fromRGB(255, 0, 255))
	-- 	drawPolygonOutline(polyB, Color3.fromRGB(0, 255, 255))
	-- 	FLAG_SLOWDOWN = true
	-- end

	-- Find a starting point in polyA that is not inside polyB
	for i, point in ipairs(polyA) do
		if not isPointInPolygon(point, polyB) then
			startPoint = point
			startIndex = i
			break
		end
	end

	if not startPoint then
		return polyB -- If all points in polyA are inside polyB, return polyB
	end

	local currentPoly, otherPoly = polyA, polyB
	local currentPoint, currentDirection = startPoint, 1

	local function getNextIndex(index)
		return if currentDirection == 1 then index % #currentPoly + 1 else (index - 2) % #currentPoly + 1
	end

	local nextIndex = getNextIndex(startIndex)

	local attempts = 0
	while true do
		attempts += 1
		print("Attempt:", attempts)

		table.insert(merged, currentPoint)
		local nextPoint = currentPoly[nextIndex]

		-- Check for intersections
		local closestIntersection, dist, qI = nil, math.huge, nil
		for i = 1, #otherPoly do
			local q1, q2 = otherPoly[i], otherPoly[i % #otherPoly + 1]
			local intersection = edgeIntersection(currentPoint, nextPoint, q1, q2)

			if intersection and intersection ~= currentPoint then
				assert(intersection ~= nextPoint, "Intersection is equal to nextPoint! Complex Polygon?")
				-- assert(intersection ~= q1, "Intersection is equal to nextPoly! Complex Polygon?")
				-- assert(intersection ~= q2, "Intersection is equal to nextPoly! Complex Polygon?")
				local newDist = (intersection - currentPoint).Magnitude
				if newDist < dist then
					closestIntersection, dist, qI = intersection, newDist, i
				end
			end
		end

		-- if FLAG_SLOWDOWN then
		-- 	if attempts > 11 then
		-- 		drawPoint(currentPoint, Color3.fromRGB(255, 0, 0), .5)
		-- 		drawPoint(nextPoint, Color3.fromRGB(0, 255, 0), .5)
		-- 		if closestIntersection then
		-- 			drawPoint(closestIntersection, Color3.fromRGB(0, 0, 255), .5)
		-- 		end
		-- 	end
		-- 	print("CurrentPoint:",currentPoint, "| NextPoint:", nextPoint, "| ClosestIntersection:", closestIntersection, "| Dist:", dist, qI)
		-- 	drawRay(currentPoint, closestIntersection or nextPoint, Color3.fromRGB(255, 81, 0))
		-- 	awaitInput()
		-- end

		if not closestIntersection then
			currentPoint = nextPoint
			nextIndex = getNextIndex(nextIndex)
		else
			-- if attempts == 100 then
			-- 	drawPoint(currentPoint, Color3.fromRGB(255, 0, 0), 2)
			-- 	drawPoint(nextPoint, Color3.fromRGB(0, 255, 0), 2)
			-- 	drawPoint(closestIntersection, Color3.fromRGB(0, 0, 255), 2)

			-- 	drawRay(currentPoint, closestIntersection, Color3.fromRGB(0, 255, 157))

			-- 	drawPolygonOutline(currentPoly, Color3.fromRGB(255, 0, 255))
			-- 	drawPolygonOutline(otherPoly, Color3.fromRGB(0, 255, 255))

			-- 	for i = 1, #merged - 1 do
			-- 		drawRay(merged[i], merged[i+1], Color3.new((i / #merged), 0, 0))
			-- 		task.wait()
			-- 	end
			-- 	FLAG_SLOWDOWN = true
			-- 	warn("Infinite loop detected!")
			-- end

			local isCCW = isCounterClockwise(currentPoint, nextPoint, otherPoly[qI]) -- Is this actually needed?
			currentDirection = if isCCW then 1 else -1
			nextIndex = if isCCW then qI % #otherPoly + 1 else qI

			currentPoint = closestIntersection
			currentPoly, otherPoly = otherPoly, currentPoly
		end

		if currentPoly == polyA and currentPoint == startPoint then
			break
		end
	end

	-- drawPolygonOutline(merged, Color3.fromRGB(183, 0, 255))
	return merged
end

--------------------------------------------------------------------------------
--// Core Methods //--
--------------------------------------------------------------------------------

local PolygonUtil = {}

function PolygonUtil.Intersects(polyA: Polygon, polyB: Polygon): boolean
	-- Do an AABB check first
	local minA, maxA = getAABB(polyA)
	local minB, maxB = getAABB(polyB)
	if minA.X > maxB.X or maxA.X < minB.X or minA.Y > maxB.Y or maxA.Y < minB.Y then
		return false -- No intersection
	end

	-- TODO: Use Separating Axis Theorem (SAT) to check for intersection?

	-- If their AABBs intersect, check for edge intersections
	for i = 1, #polyA do
		local p1 = polyA[i]
		local p2 = polyA[i % #polyA + 1]

		for j = 1, #polyB do
			local q1 = polyB[j]
			local q2 = polyB[j % #polyB + 1]

			if edgeIntersection(p1, p2, q1, q2) then
				return true
			end
		end
	end

	return false
end

--[=[
	Checks if the polygon is complex (self-intersecting) using a sweep line algorithm.
	Returns true if the polygon is complex, false otherwise.
]=]
function PolygonUtil.IsComplex(polygon: Polygon): boolean
	-- return require(script.Parent.IsComplexPolygon)(polygon)
	-- Check for self intersections
	for i = 1, #polygon do
		local p1 = polygon[i]
		local p2 = polygon[i % #polygon + 1]

		for j = i + 1, #polygon do
			local q1 = polygon[j]
			local q2 = polygon[j % #polygon + 1]
			if p1 == q1 or p1 == q2 or p2 == q1 or p2 == q2 then
				continue -- Skip if the points are the same
			end

			if edgeIntersection(p1, p2, q1, q2) then
				return true -- Found an intersection, polygon is complex
			end
		end
	end
	return false
end

--[=[

]=]
function PolygonUtil.IsPointInPolygon(point: Vector2, polygon: Polygon): boolean
	return isPointInPolygon(point, polygon)
end

function PolygonUtil.Union(polyA: Polygon, polyB: Polygon): Polygon?
	return mergePolygons(polyA, polyB)
end

--[=[
	Iterates through a list of polygons, finds which intersect, and merges each intersecting group.
	Returns a list of merged polygons.

	If you already know which polygons are intersecting, you should manually use `PolygonUtil.Union` to
	merge them in order to avoid unnecessary calculations on whether or not they intersect.
]=]
function PolygonUtil.MassUnion(polygons: { Polygon }): { Polygon }
	local mergedPolygons = {}
	local visited = {}

	-- Helper function to recursively merge intersecting polygons
	local function mergeGroup(currentPolygon, group)
		for i, polygon in ipairs(polygons) do
			if not visited[i] and PolygonUtil.Intersects(currentPolygon, polygon) then
				visited[i] = true
				currentPolygon = PolygonUtil.Union(currentPolygon, polygon) or currentPolygon
				mergeGroup(currentPolygon, group)
			end
		end
		table.insert(group, currentPolygon)
	end

	-- Iterate through all polygons and merge intersecting groups
	for i, polygon in ipairs(polygons) do
		if not visited[i] then
			visited[i] = true
			local group = {}
			mergeGroup(polygon, group)
			table.insert(mergedPolygons, group[1]) -- Add the merged polygon to the result
		end
	end

	return mergedPolygons
end

-- local polyA = {
--     Vector2.new(0, 0),
--     Vector2.new(2, 0),
--     Vector2.new(1, 2),
-- }

-- local polyB = {
--     Vector2.new(1, 1),
--     Vector2.new(3, 1),
--     Vector2.new(3, 3),
--     Vector2.new(1, 3),
-- }

-- for _, point in ipairs(polyA) do
-- 	drawPoint(point, Color3.fromRGB(0, 255, 0), 0.3)
-- end

-- for _, point in ipairs(polyB) do
-- 	drawPoint(point, Color3.fromRGB(255, 0, 0), 0.3)
-- end

-- local mergedPolygon = Polygon.Union(polyA, polyB)

-- print("Merged Polygon:")
-- for _, point in ipairs(mergedPolygon) do
--     print(point)
-- end

-- task.wait(30)

return PolygonUtil
