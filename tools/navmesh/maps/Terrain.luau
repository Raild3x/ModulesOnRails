--!strict
-- Part terrain for maps: a triangle as two thin WedgeParts (the usual Roblox triangle trick),
-- and a heightfield of them. Used by Maps/ForestRiver (ticket 37) and Maps/Highlands.

local Terrain = {}

-- Triangle abc as two WedgeParts, 0.2 thick, hanging below it; appended to `out`.
function Terrain.Triangle(P: any, rbx: any, out: { BasePart }, name: string, a: any, b: any, c: any, rgb: { number })
	local V3, CF = rbx.Vector3, rbx.CFrame
	local ab, ac, bc = b - a, c - a, c - b
	if ab:Dot(ab) > ac:Dot(ac) and ab:Dot(ab) > bc:Dot(bc) then
		c, a = a, c
	elseif ac:Dot(ac) > bc:Dot(bc) then
		a, b = b, a
	end
	ab, ac, bc = b - a, c - a, c - b
	local right = ac:Cross(ab).Unit
	local up, back = bc:Cross(right).Unit, bc.Unit
	local down = if right.Y > 0 then -right else right
	local h = math.abs(ab:Dot(up))
	local sa, sb = V3.new(0.2, h, math.abs(ab:Dot(back))), V3.new(0.2, h, math.abs(ac:Dot(back)))
	table.insert(out, P.part("WedgePart", name, sa, CF.fromMatrix((a + b) / 2 + down * 0.1, right, up, back), rgb))
	table.insert(out, P.part("WedgePart", name, sb, CF.fromMatrix((a + c) / 2 + down * 0.1, -right, up, -back), rgb))
end

-- A heightfield: vertex (i, j) at (x0 + cell i, height(i, j), z0 + cell j), for i in 0..nx and
-- j in 0..nz; each cell two triangles named `{name}{i}_{j}a` and `...b`, coloured by color(i, j,
-- the triangle's slope in degrees).
function Terrain.Heightfield(
	P: any,
	rbx: any,
	out: { BasePart },
	name: string,
	x0: number,
	z0: number,
	cell: number,
	nx: number,
	nz: number,
	height: (i: number, j: number) -> number,
	color: (i: number, j: number, slope: number) -> { number }
)
	local V3 = rbx.Vector3
	local function at(i: number, j: number): any
		return V3.new(x0 + i * cell, height(i, j), z0 + j * cell)
	end
	local function slope(a: any, b: any, c: any): number
		local n = (b - a):Cross(c - a).Unit
		return math.deg(math.acos(math.abs(n.Y)))
	end
	for i = 0, nx - 1 do
		for j = 0, nz - 1 do
			local p, q, r, s = at(i, j), at(i + 1, j), at(i + 1, j + 1), at(i, j + 1)
			Terrain.Triangle(P, rbx, out, `{name}{i}_{j}a`, p, q, r, color(i, j, slope(p, q, r)))
			Terrain.Triangle(P, rbx, out, `{name}{i}_{j}b`, p, r, s, color(i, j, slope(p, r, s)))
		end
	end
end

return Terrain
