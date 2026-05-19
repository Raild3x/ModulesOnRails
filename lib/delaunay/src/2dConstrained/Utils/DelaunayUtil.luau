--!strict

type Triangle = { Vector2 }

local Util = {}

--------------------------------------------------------------------------------
--// Math Util //--
--------------------------------------------------------------------------------

--[=[
	Determines whether or not a point is to the left, right, or on a line.
	< 0 -> to the right
	= 0 -> on the line
	> 0 -> to the left
]=]
function Util.GetPointRelationToVector(p: Vector2, vOrigin: Vector2, vDir: Vector2): number
	local a = vOrigin
	local b = vOrigin + vDir
	local determinant = (a.X - p.X) * (b.Y - p.Y) - (a.Y - p.Y) * (b.X - p.X)
	return determinant
end

--[=[
	True if the point is on the right side; False if the point is on the left side or is contained in the edge.
]=]
function Util.IsPointToTheRightOfEdge(eStart: Vector2, eEnd: Vector2, p: Vector2): boolean
	-- Determinant-based side test is more stable than using normalized vectors.
	-- Using .Unit can produce NaN on zero-length vectors and amplify numerical noise.
	local determinant = (eEnd.X - eStart.X) * (p.Y - eStart.Y) - (eEnd.Y - eStart.Y) * (p.X - eStart.X)
	return determinant < -0.0001 -- Due to extremely small negative values were causing wrong results, a tolerance is used instead of zero
end

assert(
	Util.IsPointToTheRightOfEdge(Vector2.new(0, 0), Vector2.new(0, 1), Vector2.new(0.5, 0.5)) == true,
	"Failed Math Test"
)
assert(
	Util.IsPointToTheRightOfEdge(Vector2.new(0, 0), Vector2.new(0, 1), Vector2.new(-0.5, 0.5)) == false,
	"Failed Math Test"
)
assert(
	Util.IsPointToTheRightOfEdge(Vector2.new(0, 0), Vector2.new(0, 1), Vector2.new(0.5, -0.5)) == true,
	"Failed Math Test"
)

--[=[
	
]=]
function Util.ClampListIndex(index: number, listSize: number): number
	return ((index - 1) % listSize) + 1
end

-- More thorough version
-- function Util.IsPointInTriangle(point: Vector2, t1: Vector2, t2: Vector2, t3: Vector2): boolean

-- 	-- Based on Barycentric coordinates
-- 	local denominator = ((t2.Y - t3.Y) * (t1.X - t3.X) + (t3.X - t2.X) * (t1.Y - t3.Y));

-- 	local a = ((t2.Y - t3.Y) * (p.X - t3.X) + (t3.X - t2.X) * (point.Y - t3.Y)) / denominator;
-- 	local b = ((t3.Y - t1.Y) * (p.X - t3.X) + (t1.X - t3.X) * (point.Y - t3.Y)) / denominator;
-- 	local c = 1 - a - b;

-- 	-- The point is within the triangle or on the border if 0 <= a <= 1 and 0 <= b <= 1 and 0 <= c <= 1
-- 	-- if (a >= 0 and a <= 1 and b >= 0 and b <= 1 and c >= 0 and c <= 1) then
-- 	-- 	return true
-- 	-- end

-- 	-- The point is within the triangle
-- 	if a > 0 and a < 1 and b > 0 and b < 1 and c > 0 and c < 1 then
-- 		return true
-- 	end

-- 	return false
-- end

function Util.AreLineSegmentsIntersecting(
	l1_p1: Vector2,
	l1_p2: Vector2,
	l2_p1: Vector2,
	l2_p2: Vector2,
	includeEndPoints: boolean?
): boolean
	local denominator = ((l2_p2.Y - l2_p1.Y) * (l1_p2.X - l1_p1.X)) - ((l2_p2.X - l2_p1.X) * (l1_p2.Y - l1_p1.Y))

	if denominator == 0 then
		return false -- Lines are parallel
	end

	local ua = (((l2_p2.X - l2_p1.X) * (l1_p1.Y - l2_p1.Y)) - ((l2_p2.Y - l2_p1.Y) * (l1_p1.X - l2_p1.X))) / denominator
	local ub = (((l1_p2.X - l1_p1.X) * (l1_p1.Y - l2_p1.Y)) - ((l1_p2.Y - l1_p1.Y) * (l1_p1.X - l2_p1.X))) / denominator

	-- Are the line segments intersecting if the end points are the same
	if includeEndPoints then
		return (ua >= 0 and ua <= 1) and (ub >= 0 and ub <= 1)
	else
		return (ua > 0 and ua < 1) and (ub > 0 and ub < 1)
	end
end

--[=[
	Whats the coordinate of an intersection point between two lines in 2d space if we know they are intersecting
	http://thirdpartyninjas.com/blog/2008/10/07/line-segment-intersection/
]=]
function Util.GetLineLineIntersectionPoint(l1_p1: Vector2, l1_p2: Vector2, l2_p1: Vector2, l2_p2: Vector2): Vector2
	local denominator = ((l2_p2.Y - l2_p1.Y) * (l1_p2.X - l1_p1.X)) - ((l2_p2.X - l2_p1.X) * (l1_p2.Y - l1_p1.Y))

	local ua = (((l2_p2.X - l2_p1.X) * (l1_p1.Y - l2_p1.Y)) - ((l2_p2.Y - l2_p1.Y) * (l1_p1.X - l2_p1.X))) / denominator

	local intersectionPoint = l1_p1 + (l1_p2 - l1_p1) * ua
	return intersectionPoint
end

function Util.IsPointInPolygon(point: Vector2, polygon: { Vector2 }): boolean
	local inside = false
	local n = #polygon

	for i = 1, n do
		local j = (i % n) + 1
		local pi = polygon[i]
		local pj = polygon[j]

		if
			((pi.Y > point.Y) ~= (pj.Y > point.Y))
			and (point.X < (pj.X - pi.X) * (point.Y - pi.Y) / (pj.Y - pi.Y) + pi.X)
		then
			inside = not inside
		end
	end

	return inside
end

--[=[
	
]=]
function Util.CreateSuperTriangle(points: { Vector2 }): { Vector2 }
	local minX, minY = math.huge, math.huge
	local maxX, maxY = -math.huge, -math.huge

	for _, point in ipairs(points) do
		minX = math.min(minX, point.X)
		minY = math.min(minY, point.Y)
		maxX = math.max(maxX, point.X)
		maxY = math.max(maxY, point.Y)
	end

	local dx = maxX - minX
	local dy = maxY - minY
	local SCALE = 100 -- Scale factor to ensure the super triangle is sufficiently large to encompass all points
	local dmax = math.max(dx, dy) * SCALE

	local midX = (minX + maxX) / 2
	local midY = (minY + maxY) / 2

	return {
		Vector2.new(midX - 2 * dmax, midY - dmax),
		Vector2.new(midX + 2 * dmax, midY - dmax),
		Vector2.new(midX, midY + 2 * dmax),
	}
end

-- Calculates the determinan of a 3 columns x 3 rows matrix.
local function calculateMatrix3x3Determinant(
	m00: number,
	m10: number,
	m20: number,
	m01: number,
	m11: number,
	m21: number,
	m02: number,
	m12: number,
	m22: number
): number
	return m00 * m11 * m22 + m10 * m21 * m02 + m20 * m01 * m12 - m20 * m11 * m02 - m10 * m01 * m22 - m00 * m21 * m12
end

--[=[
	
]=]
function Util.IsTriangleVerticesCW(p1: Vector2, p2: Vector2, p3: Vector2): boolean
	-- local area = (p2.X - p1.X) * (p3.Y - p1.Y) - (p3.X - p1.X) * (p2.Y - p1.Y)
	-- return area < 0
	return calculateMatrix3x3Determinant(p1.X, p1.Y, 1, p2.X, p2.Y, 1, p3.X, p3.Y, 1) < 0
end

-- Is a quadrilateral convex? Assume no 3 points are colinear and the shape doesnt look like an hourglass
function Util.IsQuadrilateralConvex(a: Vector2, b: Vector2, c: Vector2, d: Vector2): boolean
	-- local ab = b - a
	-- local bc = c - b
	-- local cd = d - c
	-- local da = a - d

	-- return Util.GetPointRelationToVector(a, b, ab) > 0 and
	-- 	Util.GetPointRelationToVector(b, c, bc) > 0 and
	-- 	Util.GetPointRelationToVector(c, d, cd) > 0 and
	-- 	Util.GetPointRelationToVector(d, a, da) > 0

	-- if Util.AreLineSegmentsIntersecting(a, c, b, d) then
	-- 	warn("The quadrilateral is an hourglass shape")
	--     return true -- The quadrilateral is an hourglass shape
	-- end

	local isConvex = false

	local abc = Util.IsTriangleVerticesCW(a, b, c)
	local abd = Util.IsTriangleVerticesCW(a, b, d)
	local bcd = Util.IsTriangleVerticesCW(b, c, d)
	local cad = Util.IsTriangleVerticesCW(c, a, d)

	if
		(abc and abd and bcd and not cad)
		or (abc and abd and not bcd and cad)
		or (abc and not abd and bcd and cad)
		-- The opposite sign, which makes everything inverted
		or (not abc and not abd and not bcd and cad)
		or (not abc and not abd and bcd and not cad)
		or (not abc and abd and not bcd and not cad)
	then
		isConvex = true
	end

	return isConvex
end
-- Write test cases for IsQuadrilateralConvex. Points are in counter-clockwise order
-- assert(Util.IsQuadrilateralConvex(Vector2.new(0, 0), Vector2.new(1, 0), Vector2.new(1, 1), Vector2.new(0, 1)) == true, "Failed Test")
-- assert(Util.IsQuadrilateralConvex(Vector2.new(0, 0), Vector2.new(1, 0), Vector2.new(0, 1), Vector2.new(1, 1)) == false, "Failed Test")
-- assert(Util.IsQuadrilateralConvex(Vector2.new(0, 0), Vector2.new(1, 0), Vector2.new(0, 1), Vector2.new(1, 1)) == false, "Failed Test")
-- assert(Util.IsQuadrilateralConvex(Vector2.new(0, 0), Vector2.new(1, 0), Vector2.new(1, 1), Vector2.new(0, 1)) == true, "Failed Test")
-- assert(Util.IsQuadrilateralConvex(Vector2.new(0, 0), Vector2.new(1, 0), Vector2.new(0, 1), Vector2.new(1, 1)) == false, "Failed Test")

return Util
