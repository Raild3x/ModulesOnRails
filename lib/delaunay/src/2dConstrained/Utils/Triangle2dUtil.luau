local Util2d = require("./DelaunayUtil")

export type Triangle2d = { Vector2 }

local Triangle2d = {}

function Triangle2d.new(p1: Vector2, p2: Vector2, p3: Vector2): Triangle2d
	return { p1, p2, p3 }
end

--[=[
	Returns the circumcenter of the triangle.
	https://en.wikipedia.org/wiki/Circumscribed_circle#Circumcenter_coordinates

	The circumcenter is the center of the circle that passes through all
	three vertices of the triangle.
]=]
function Triangle2d.GetCircumcenter(triangle: Triangle2d): Vector2
	local ax, ay = triangle[1].X, triangle[1].Y
	local bx, by = triangle[2].X, triangle[2].Y
	local cx, cy = triangle[3].X, triangle[3].Y

	local d = 2 * (ax * (by - cy) + bx * (cy - ay) + cx * (ay - by))
	local ux = ((ax * ax + ay * ay) * (by - cy) + (bx * bx + by * by) * (cy - ay) + (cx * cx + cy * cy) * (ay - by)) / d
	local uy = ((ax * ax + ay * ay) * (cx - bx) + (bx * bx + by * by) * (ax - cx) + (cx * cx + cy * cy) * (bx - ax)) / d

	return Vector2.new(ux, uy)
end

--[=[
	Returns the circumradius of the triangle.
	https://en.wikipedia.org/wiki/Circumscribed_circle#Circumradius

	The circumradius is the radius of the circle that passes through all
	three vertices of the triangle.
]=]
function Triangle2d.GetCircumradius(triangle: Triangle2d): number
	local ax, ay = triangle[1].X, triangle[1].Y
	local bx, by = triangle[2].X, triangle[2].Y
	local cx, cy = triangle[3].X, triangle[3].Y

	local d = 2 * (ax * (by - cy) + bx * (cy - ay) + cx * (ay - by))
	local radius = math.sqrt(
		((ax * ax + ay * ay) * (by - cy) + (bx * bx + by * by) * (cy - ay) + (cx * cx + cy * cy) * (ay - by)) / d
	)

	return radius
end

--[=[
	Returns the area of the triangle.
	https://en.wikipedia.org/wiki/Triangle#Area

	The area is the amount of space enclosed by the triangle.
]=]
function Triangle2d.GetArea(triangle: Triangle2d): number
	local a, b, c = triangle[1], triangle[2], triangle[3]
	return 0.5 * math.abs((b - a):Cross(c - a))
end

--[=[
	Returns the centroid of the triangle.
	https://en.wikipedia.org/wiki/Centroid#Centroid_of_a_triangle

	The centroid is the point where the three medians of the triangle intersect.
]=]
function Triangle2d.GetCentroid(triangle: Triangle2d): Vector2
	local ax, ay = triangle[1].X, triangle[1].Y
	local bx, by = triangle[2].X, triangle[2].Y
	local cx, cy = triangle[3].X, triangle[3].Y

	local centroidX = (ax + bx + cx) / 3
	local centroidY = (ay + by + cy) / 3

	return Vector2.new(centroidX, centroidY)
end

--[=[
	Is a triangle in 2d space oriented clockwise or counter-clockwise
	https://math.stackexchange.com/questions/1324179/how-to-tell-if-3-connected-points-are-connected-clockwise-or-counter-clockwise
	https://en.wikipedia.org/wiki/Curve_orientation
]=]
function Triangle2d.IsTriangleOrientedClockwise(p1: Vector2, p2: Vector2, p3: Vector2): boolean
	local determinant = p1.X * p2.Y + p3.X * p1.Y + p2.X * p3.Y - p1.X * p3.Y - p3.X * p2.Y - p2.X * p1.Y
	return determinant < 0
end

--[=[
	p is the testpoint, and the other points are corners in the triangle
]=]
function Triangle2d.IsPointInTriangle(point: Vector2, t1: Vector2, t2: Vector2, t3: Vector2): boolean
	local function sign(p1: Vector2, p2: Vector2, p3: Vector2): number
		return (p1.X - p3.X) * (p2.Y - p3.Y) - (p2.X - p3.X) * (p1.Y - p3.Y)
	end

	local b1 = sign(point, t1, t2) < 0.0
	local b2 = sign(point, t2, t3) < 0.0
	local b3 = sign(point, t3, t1) < 0.0

	return ((b1 == b2) and (b2 == b3))
end

function Triangle2d.AreAnyLineSegmentsIntersecting(t1: Triangle2d, t2: Triangle2d)
	for i = 1, 3 do
		local p1 = t1[i]
		local p2 = t1[Util2d.ClampListIndex(i + 1, 3)]

		for j = 1, 3 do
			local p3 = t2[j]
			local p4 = t2[Util2d.ClampListIndex(j + 1, 3)]

			if Util2d.AreLineSegmentsIntersecting(p1, p2, p3, p4) then
				return true
			end
		end
	end
	return false
end

function Triangle2d.AreAnyEdgesShared(t1: Triangle2d, t2: Triangle2d): boolean
	local a1, a2, a3 = t1[1], t1[2], t1[3]
	local b1, b2, b3 = t2[1], t2[2], t2[3]

	return (a1 == b1 or a1 == b2 or a1 == b3 or a2 == b1 or a2 == b2 or a2 == b3 or a3 == b1 or a3 == b2 or a3 == b3)
end

function Triangle2d.AreCornersIntersecting(t1: Triangle2d, t2: Triangle2d): boolean
	-- We only have to test one corner from each triangle
	--Triangle 1 in triangle 2
	if Triangle2d.IsPointInTriangle(t1[1], t2[1], t2[2], t2[3]) then
		return true
	--Triangle 2 in triangle 1
	elseif Triangle2d.IsPointInTriangle(t2[1], t1[1], t1[2], t1[3]) then
		return true
	end
	return false
end

function Triangle2d.IsIntersectingAABB(t1: Triangle2d, t2: Triangle2d): boolean
	local minX1, minY1 = math.min(t1[1].X, t1[2].X, t1[3].X), math.min(t1[1].Y, t1[2].Y, t1[3].Y)
	local maxX1, maxY1 = math.max(t1[1].X, t1[2].X, t1[3].X), math.max(t1[1].Y, t1[2].Y, t1[3].Y)

	local minX2, minY2 = math.min(t2[1].X, t2[2].X, t2[3].X), math.min(t2[1].Y, t2[2].Y, t2[3].Y)
	local maxX2, maxY2 = math.max(t2[1].X, t2[2].X, t2[3].X), math.max(t2[1].Y, t2[2].Y, t2[3].Y)

	return not (maxX1 < minX2 or maxX2 < minX1 or maxY1 < minY2 or maxY2 < minY1)
end

-- TODO: Add a version that doesnt require the triangle to be an array and instead take a tuple of points
function Triangle2d.IsPointInCircumcircle(point: Vector2, triangle: Triangle2d): boolean
	debug.profilebegin("IsPointInCircumcircle")
	local dx, dy = point.X, point.Y

	-- Precompute squared distances for reuse
	local t1, t2, t3 = triangle[1], triangle[2], triangle[3]
	local ax, ay = t1.X - dx, t1.Y - dy
	local bx, by = t2.X - dx, t2.Y - dy
	local cx, cy = t3.X - dx, t3.Y - dy

	local aSquared = ax * ax + ay * ay
	local bSquared = bx * bx + by * by
	local cSquared = cx * cx + cy * cy

	-- Compute determinant directly
	local determinant = ax * (by * cSquared - cy * bSquared)
		- ay * (bx * cSquared - cx * bSquared)
		+ aSquared * (bx * cy - cx * by)

	debug.profileend()
	return determinant >= 0
end

function Triangle2d.GetClosestPointOnLineSegment(point: Vector2, p1: Vector2, p2: Vector2): Vector2
	local line = p2 - p1
	local lengthSquared = line:Dot(line)
	if lengthSquared == 0 then
		return p1 -- p1 and p2 are the same point
	end

	local t = (point - p1):Dot(line) / lengthSquared
	t = math.clamp(t, 0, 1) -- Clamp t to the range [0, 1]

	return p1 + line * t
end

function Triangle2d.GetClosestPointOnTriangleEdges(goal: Vector2, trianglePoints: Triangle2d): Vector2
	local closestPoint = trianglePoints[1]
	local closestDistance = math.huge

	for i = 1, #trianglePoints do
		local p1 = trianglePoints[i]
		local p2 = trianglePoints[i % #trianglePoints + 1] -- Wrap around to the first point

		-- Find the closest point on the line segment (p1, p2) to the goal
		local closestPointOnEdge = Triangle2d.GetClosestPointOnLineSegment(p1, p2, goal)
		local distance = (closestPointOnEdge - goal).Magnitude

		-- Update the closest point if this one is closer
		if distance < closestDistance then
			closestDistance = distance
			closestPoint = closestPointOnEdge
		end
	end

	return closestPoint
end

-- local timeTaken = 0
-- for i = 1, 100_000 do
-- 	local point = Vector2.new(math.random(), math.random())
-- 	local tri = {
-- 		Vector2.new(-1, -1),
-- 		Vector2.new(1, -1),
-- 		Vector2.new(0, 1)
-- 	}
-- 	local t = os.clock()
-- 	Triangle2d.IsPointInCircumcircle(point, tri)
-- 	timeTaken += os.clock() - t
-- end
-- print("Time taken for 100k iterations:", timeTaken * 1000, "ms")

-- local timeTaken = 0
-- for i = 1, 100_000 do
-- 	local point = Vector2.new(math.random(), math.random())
-- 	local tri = {
-- 		Vector2.new(-1, -1),
-- 		Vector2.new(1, -1),
-- 		Vector2.new(0, 1)
-- 	}
-- 	local t = os.clock()
-- 	Triangle2d.IsPointInCircumcircleNew(point, tri)
-- 	timeTaken += os.clock() - t
-- end
-- print("Time taken for 100k iterations:", timeTaken * 1000, "ms")

return Triangle2d
