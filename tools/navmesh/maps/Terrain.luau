--!strict
-- Part terrain for maps: a triangle as two thin WedgeParts (the usual Roblox triangle trick),
-- a heightfield of them, and an adaptive one. Used by Maps/ForestRiver (ticket 37) and
-- Maps/Highlands.

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

-- An adaptive heightfield: nx by nz root cells of `cell` studs from (x0, z0), each halving down
-- to `minCell` (cell / minCell a power of two), a cell split while height(x, z) strays more than
-- tolerance(x, z, cell size) from the flat surface through its corners (checked at its edge midpoints and
-- middle), so flat ground gets big triangles and cliffs small ones. Every cell is two triangles;
-- a corner on a bigger neighbour's edge takes that edge's height, so there are no cracks (the
-- usual T-junction stitch). `fan` stitches instead with a fan from the cell's middle through the
-- smaller neighbours' corners, so neighbours share vertices (the adapter splits such fans into
-- rings that fold back: bench/adaptive_fan_repro.luau).
-- paint(a, b, c, slope) gives each triangle's colour and, optionally, its NavArea name; or nil
-- to leave the triangle out (ground under water).
-- Returns the number of triangles, and the built surface's height at (x, z) (for placing Parts
-- on it: it differs from height() by up to the tolerance).
function Terrain.Adaptive(
	P: any,
	rbx: any,
	out: { BasePart },
	name: string,
	x0: number,
	z0: number,
	cell: number,
	nx: number,
	nz: number,
	minCell: number,
	height: (x: number, z: number) -> number,
	tolerance: (x: number, z: number, s: number) -> number,
	paint: (a: any, b: any, c: any, slope: number) -> ({ number }?, string?),
	fan: boolean?
): (number, (x: number, z: number) -> number)
	local V3 = rbx.Vector3
	local leaves, corners, isLeaf = {}, {}, {}
	local function key(x: number, z: number): string
		return `{x},{z}`
	end
	local function split(x: number, z: number, s: number)
		if s > minCell then
			local h00, h10, h01, h11 = height(x, z), height(x + s, z), height(x, z + s), height(x + s, z + s)
			local m = s / 2
			local err = math.max(
				math.abs(height(x + m, z) - (h00 + h10) / 2),
				math.abs(height(x, z + m) - (h00 + h01) / 2),
				math.abs(height(x + s, z + m) - (h10 + h11) / 2),
				math.abs(height(x + m, z + s) - (h01 + h11) / 2),
				math.abs(height(x + m, z + m) - (h00 + h10 + h01 + h11) / 4)
			)
			if err > tolerance(x + m, z + m, s) then
				for _, d in { { 0, 0 }, { m, 0 }, { 0, m }, { m, m } } do
					split(x + d[1], z + d[2], m)
				end
				return
			end
		end
		table.insert(leaves, { x, z, s })
		isLeaf[`{x},{z},{s}`] = true
		for _, d in { { 0, 0 }, { s, 0 }, { 0, s }, { s, s } } do
			corners[key(x + d[1], z + d[2])] = true
		end
	end
	for i = 0, nx - 1 do
		for j = 0, nz - 1 do
			split(x0 + i * cell, z0 + j * cell, cell)
		end
	end

	-- T-junctions: each point inside an edge of a bigger cell, with that edge (the biggest).
	local onEdge = {}
	for _, leaf in leaves do
		local x, z, s = leaf[1], leaf[2], leaf[3]
		for _, e in { { x, z, 1, 0 }, { x + s, z, 0, 1 }, { x + s, z + s, -1, 0 }, { x, z + s, 0, -1 } } do
			for d = minCell, s - minCell, minCell do
				local k = key(e[1] + e[3] * d, e[2] + e[4] * d)
				if onEdge[k] == nil or onEdge[k][5] < s then
					onEdge[k] = { e[1], e[2], e[1] + e[3] * s, e[2] + e[4] * s, s, d / s }
				end
			end
		end
	end
	local function y(x: number, z: number): number
		local e = if fan then nil else onEdge[key(x, z)]
		if e then
			return y(e[1], e[2]) + (y(e[3], e[4]) - y(e[1], e[2])) * e[6]
		end
		return height(x, z)
	end
	local function at(x: number, z: number): any
		return V3.new(x, y(x, z), z)
	end
	local count = 0
	local function tri(a: any, b: any, c: any)
		local n = (b - a):Cross(c - a).Unit
		local rgb, area = paint(a, b, c, math.deg(math.acos(math.abs(n.Y))))
		if rgb == nil then
			return
		end
		local first = #out + 1
		count += 1
		Terrain.Triangle(P, rbx, out, `{name}{count}`, a, b, c, rgb)
		if area then
			for k = first, #out do
				out[k]:SetAttribute("NavArea", area)
			end
		end
	end
	for _, leaf in leaves do
		local x, z, s = leaf[1], leaf[2], leaf[3]
		-- The ring: corners and the smaller neighbours' corners on the edges, anticlockwise.
		local ring = {}
		for _, e in { { x, z, 1, 0 }, { x + s, z, 0, 1 }, { x + s, z + s, -1, 0 }, { x, z + s, 0, -1 } } do
			table.insert(ring, { e[1], e[2] })
			for d = minCell, s - minCell, minCell do
				local px, pz = e[1] + e[3] * d, e[2] + e[4] * d
				if corners[key(px, pz)] then
					table.insert(ring, { px, pz })
				end
			end
		end
		if #ring == 4 or not fan then
			local p, q, r, t = at(x, z), at(x + s, z), at(x + s, z + s), at(x, z + s)
			tri(p, q, r)
			tri(p, r, t)
		else
			local c = at(x + s / 2, z + s / 2)
			for k, a in ring do
				local b = ring[k % #ring + 1]
				tri(c, at(a[1], a[2]), at(b[1], b[2]))
			end
		end
	end
	local function surface(x: number, z: number): number
		local s = cell
		while s >= minCell do
			local ox, oz = x0 + (x - x0) // s * s, z0 + (z - z0) // s * s
			if isLeaf[`{ox},{oz},{s}`] then
				local u, v = (x - ox) / s, (z - oz) / s
				local p, r = y(ox, oz), y(ox + s, oz + s)
				if u >= v then -- triangle p, (ox + s, oz), r
					local q = y(ox + s, oz)
					return p + (q - p) * u + (r - q) * v
				end
				local t = y(ox, oz + s)
				return p + (t - p) * v + (r - t) * u
			end
			s /= 2
		end
		return height(x, z)
	end
	return count, surface
end

return Terrain
