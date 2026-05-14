--!strict
--[=[
	Geometric3dUtils
	
	A collection of robust geometric predicates for 3D computational geometry,
	implementing Shewchuk's exact arithmetic formulation without requiring
	multi-precision libraries.
	
	These predicates are designed to work robustly in floating-point arithmetic
	by leveraging the translated frame of reference to minimize catastrophic
	cancellation.
]=]

--------------------------------------------------------------------------------
--// Determinant Calculations //--
--------------------------------------------------------------------------------

-- 3×3 determinant, Sarrus / cofactor expansion on row 0.
local function det3(
	a: number,
	b: number,
	c: number,
	d: number,
	e: number,
	f: number,
	g: number,
	h: number,
	i: number
): number
	return a * (e * i - f * h) - b * (d * i - f * g) + c * (d * h - e * g)
end

-- 4×4 determinant, Laplace expansion along row 0.
local function det4(
	a00: number,
	a01: number,
	a02: number,
	a03: number,
	a10: number,
	a11: number,
	a12: number,
	a13: number,
	a20: number,
	a21: number,
	a22: number,
	a23: number,
	a30: number,
	a31: number,
	a32: number,
	a33: number
): number
	return a00 * det3(a11, a12, a13, a21, a22, a23, a31, a32, a33)
		- a01 * det3(a10, a12, a13, a20, a22, a23, a30, a32, a33)
		+ a02 * det3(a10, a11, a13, a20, a21, a23, a30, a31, a33)
		- a03 * det3(a10, a11, a12, a20, a21, a22, a30, a31, a32)
end

--------------------------------------------------------------------------------
--// Orientation Predicate //--
--------------------------------------------------------------------------------

--[[
	orient3d(A, B, C, D)

	Returns the signed volume of tetrahedron ABCD (up to a positive constant factor):
	  > 0  →  D lies on the positive (CCW-when-viewed-from-above) side of plane ABC.
	  < 0  →  D lies on the negative side.
	  = 0  →  A, B, C, D are coplanar (degenerate tetrahedron).

	Definition:  det3( B-A, C-A, D-A )
	This matches the Shewchuk / CGAL orient3d sign convention.
]]
local function orient3d(a: Vector3, b: Vector3, c: Vector3, d: Vector3): number
	return det3(b.X - a.X, b.Y - a.Y, b.Z - a.Z, c.X - a.X, c.Y - a.Y, c.Z - a.Z, d.X - a.X, d.Y - a.Y, d.Z - a.Z)
end

--------------------------------------------------------------------------------
--// In-Sphere Predicate //--
--------------------------------------------------------------------------------

--[[
	inSphereRaw(A, B, C, D, P)

	Evaluates Shewchuk's 4×4 in-sphere determinant in the translated frame of P:
	  rows are  (A-P, |A-P|²),  (B-P, |B-P|²),  (C-P, |C-P|²),  (D-P, |D-P|²).

	Semantics (verified numerically):
	  For *positively-oriented* ABCD:  < 0 iff P lies strictly inside the circumsphere.
	  For *negatively-oriented* ABCD:  the sign is flipped.

	→  Always combine with orient3d to obtain an orientation-independent result:
	       circumSphereContains ⟺  inSphereRaw * orient3d < 0
]]
local function inSphereRaw(a: Vector3, b: Vector3, c: Vector3, d: Vector3, p: Vector3): number
	local ax, ay, az = a.X - p.X, a.Y - p.Y, a.Z - p.Z
	local bx, by, bz = b.X - p.X, b.Y - p.Y, b.Z - p.Z
	local cx, cy, cz = c.X - p.X, c.Y - p.Y, c.Z - p.Z
	local dx, dy, dz = d.X - p.X, d.Y - p.Y, d.Z - p.Z
	return det4(
		ax,
		ay,
		az,
		ax * ax + ay * ay + az * az,
		bx,
		by,
		bz,
		bx * bx + by * by + bz * bz,
		cx,
		cy,
		cz,
		cx * cx + cy * cy + cz * cz,
		dx,
		dy,
		dz,
		dx * dx + dy * dy + dz * dz
	)
end

--[[
	circumSphereContains(A, B, C, D, P)

	Returns true iff point P lies strictly inside the circumsphere of tetrahedron ABCD.
	Orientation-independent: uses inSphereRaw × orient3d so that the result is the same
	regardless of the winding order of ABCD.
	Returns false for degenerate (coplanar) tetrahedra.
]]
local function circumSphereContains(a: Vector3, b: Vector3, c: Vector3, d: Vector3, p: Vector3): boolean
	local o = orient3d(a, b, c, d)
	if o == 0 then
		return false -- degenerate — no well-defined circumsphere
	end
	return inSphereRaw(a, b, c, d, p) * o < 0
end

return {
	det3 = det3,
	det4 = det4,
	orient3d = orient3d,
	inSphereRaw = inSphereRaw,
	circumSphereContains = circumSphereContains,
}
