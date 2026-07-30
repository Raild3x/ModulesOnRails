--!strict
--!native

--[=[
	Pure geometric predicate functions. No external dependencies.

	Sign convention for orient2D:
	  positive (Left)  -- p is counter-clockwise of the directed edge v1→v2
	  negative (Right) -- p is clockwise of the directed edge v1→v2
	  zero    (OnLine) -- p is collinear with v1 and v2

	Triangle vertex winding assumed to be CCW throughout.
]=]

-- Signed area of triangle (v1, v2, p) × 2.
-- Uses Vector2:Cross which returns (self.X * other.Y - self.Y * other.X).
local function orient2D(p: Vector2, v1: Vector2, v2: Vector2): number
	return (v2 - v1):Cross(p - v1)
end

type OrientationClassification = "Left" | "Right" | "OnLine"
-- Classify a signed orient2D value.
-- Returns "Left" | "Right" | "OnLine".
local function classifyOrientation(d: number, tol: number?): OrientationClassification
	local eps = tol or 0
	if d > eps then
		return "Left"
	elseif d < -eps then
		return "Right"
	else
		return "OnLine"
	end
end

-- Locate p relative to the directed line v1→v2.
-- Returns "Left" | "Right" | "OnLine".
local function locatePointLine(p: Vector2, v1: Vector2, v2: Vector2, tol: number?): OrientationClassification
	return classifyOrientation(orient2D(p, v1, v2), tol)
end

--[=[
	Locate p relative to the CCW triangle (v1, v2, v3).

	Returns one of:
	  "Inside"  | "Outside"
	  "OnEdge1" -- on edge v1→v2  (opposite neighbor slot 1)
	  "OnEdge2" -- on edge v2→v3  (opposite neighbor slot 2)
	  "OnEdge3" -- on edge v3→v1  (opposite neighbor slot 3)
	  "OnVertex"-- on two edges simultaneously
]=]
local function locatePointTriangle(p: Vector2, v1: Vector2, v2: Vector2, v3: Vector2): string
	local result = "Inside"

	local e1 = locatePointLine(p, v1, v2)
	if e1 == "Right" then
		return "Outside"
	end
	if e1 == "OnLine" then
		result = "OnEdge1"
	end

	local e2 = locatePointLine(p, v2, v3)
	if e2 == "Right" then
		return "Outside"
	end
	if e2 == "OnLine" then
		result = if result == "Inside" then "OnEdge2" else "OnVertex"
	end

	local e3 = locatePointLine(p, v3, v1)
	if e3 == "Right" then
		return "Outside"
	end
	if e3 == "OnLine" then
		result = if result == "Inside" then "OnEdge3" else "OnVertex"
	end

	return result
end

-- Returns true when loc is one of the OnEdge variants.
local function isOnEdge(loc: string): boolean
	return loc == "OnEdge1" or loc == "OnEdge2" or loc == "OnEdge3"
end

-- Maps an OnEdge location to the corresponding neighbor slot (1-indexed).
-- OnEdge1 → 1,  OnEdge2 → 2,  OnEdge3 → 3.
local function edgeLocSlot(loc: string): number
	if loc == "OnEdge1" then
		return 1
	end
	if loc == "OnEdge2" then
		return 2
	end
	return 3
end

--[=[
	Returns true when p lies strictly inside the circumcircle of the CCW
	triangle (v1, v2, v3).

	Implemented as the standard 3×3 cofactor determinant:
	  | ax  ay  az |
	  | bx  by  bz |  > 0
	  | cx  cy  cz |
	where a = v1 - p, b = v2 - p, c = v3 - p, and z = x² + y².
]=]
local function isInCircumcircle(p: Vector2, v1: Vector2, v2: Vector2, v3: Vector2): boolean
	local ax = v1.X - p.X
	local ay = v1.Y - p.Y
	local bx = v2.X - p.X
	local by = v2.Y - p.Y
	local cx = v3.X - p.X
	local cy = v3.Y - p.Y
	local az = ax * ax + ay * ay
	local bz = bx * bx + by * by
	local cz = cx * cx + cy * cy
	return ax * (by * cz - bz * cy) - ay * (bx * cz - bz * cx) + az * (bx * cy - by * cx) > 0
end

--[=[
	Compute the intersection point of segments a→b and c→d.

	Uses orient2D-based interpolation for robustness.
	Precondition: segments intersect (caller is responsible for guarantee).
	Corresponds to CDT C++ detail::intersectionPosition.
]=]
local function intersectionPosition(a: Vector2, b: Vector2, c: Vector2, d: Vector2): Vector2
	local a_cd = orient2D(a, c, d)
	local b_cd = orient2D(b, c, d)
	local t_ab = a_cd / (a_cd - b_cd)
	local c_ab = orient2D(c, a, b)
	local d_ab = orient2D(d, a, b)
	local t_cd = c_ab / (c_ab - d_ab)
	local x: number
	local y: number
	if math.abs(a.X - b.X) < math.abs(c.X - d.X) then
		x = a.X + t_ab * (b.X - a.X)
	else
		x = c.X + t_cd * (d.X - c.X)
	end
	if math.abs(a.Y - b.Y) < math.abs(c.Y - d.Y) then
		y = a.Y + t_ab * (b.Y - a.Y)
	else
		y = c.Y + t_cd * (d.Y - c.Y)
	end
	return Vector2.new(x, y)
end

return {
	orient2D = orient2D,
	classifyOrientation = classifyOrientation,
	locatePointLine = locatePointLine,
	locatePointTriangle = locatePointTriangle,
	isOnEdge = isOnEdge,
	edgeLocSlot = edgeLocSlot,
	isInCircumcircle = isInCircumcircle,
	intersectionPosition = intersectionPosition,
}
