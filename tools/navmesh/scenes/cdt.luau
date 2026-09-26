--!strict
-- Scene module for the screenshot loop: triangulations built from the CDT's fixtures and a
-- few generated point sets, as DrawLists.
--   lune run tools/navmesh/render.luau tools/navmesh/scenes/cdt <out-dir>

local CDT = require("../../../lib/constraineddelaunay/src/ConstrainedDelaunay")

-- Deterministic LCG (Lune has no Random).
local function makeRng(seed: number): (number, number) -> number
	local state = seed
	return function(lo: number, hi: number): number
		state = (state * 1103515245 + 12345) % 2147483648
		return lo + (state / 2147483648) * (hi - lo)
	end
end

local scenes = {}

local function add(name: string, input: CDT.TriangulateInput, options: CDT.CDTDrawOptions?)
	local tri = CDT.Triangulate(input)
	table.insert(scenes, { Name = name, List = CDT.ToDrawList(tri, options) })
end

-- The NavMesh keep rule on winding groups: walkable (1) > 0, obstacle (2) == 0, and inside
-- the tile clip (3) when the scenario has one. Kept = green, excluded = grey.
local KEPT, EXCLUDED = "#43a047", "#9e9e9e"
local function classified(name: string, input: CDT.TriangulateInput)
	local tri = CDT.Triangulate(input)
	local groups = CDT.GroupCount(tri)
	local list = {}
	for t = 1, CDT.TriangleCount(tri) do
		local a, b, c = CDT.GetTriangle(tri, t)
		local ax, ay = CDT.GetVertex(tri, a)
		local bx, by = CDT.GetVertex(tri, b)
		local cx, cy = CDT.GetVertex(tri, c)
		local keep = CDT.GetWinding(tri, t, 1) > 0
			and (groups < 2 or CDT.GetWinding(tri, t, 2) == 0)
			and (groups < 3 or CDT.GetWinding(tri, t, 3) > 0)
		table.insert(list, { Kind = "Tri", Points = { ax, 0, ay, bx, 0, by, cx, 0, cy }, Color = if keep then KEPT else EXCLUDED, Layer = "Triangles" })
	end
	-- Constraints and vertices on top, from the standard view (its triangles are dropped).
	for _, primitive in CDT.ToDrawList(tri) do
		if primitive.Kind ~= "Tri" then
			table.insert(list, primitive)
		end
	end
	table.insert(scenes, { Name = name, List = list })
end

for _, scenario in CDT.Fixtures.All do
	add(`Points_{scenario.Name}`, { Coords = CDT.Fixtures.ToInput(scenario).Coords })
	add(`Constrained_{scenario.Name}`, CDT.Fixtures.ToInput(scenario))
	classified(`Classified_{scenario.Name}`, CDT.Fixtures.ToInput(scenario))
end

-- A walkable courtyard with overlapping obstacles and a hole, clipped to a tile.
classified("Classified_Courtyard", CDT.Fixtures.ToInput({
	Name = "Courtyard",
	Rings = {
		{ Group = 1, Points = { 0, 0, 30, 0, 30, 20, 18, 20, 18, 30, 0, 30 } }, -- L-shaped walkable
		{ Group = 1, Points = { 4, 4, 4, 8, 8, 8, 8, 4 } }, -- CW hole in the walkable ring
		{ Group = 2, Points = { 12, 3, 20, 3, 20, 9, 12, 9 } }, -- obstacle
		{ Group = 2, Points = { 16, 6, 24, 6, 26, 14, 16, 12 } }, -- overlapping obstacle
		{ Group = 2, Points = { 5, 18, 11, 16, 13, 24, 7, 26 } }, -- rotated obstacle
		{ Group = 3, Points = { -2, -2, 26, -2, 26, 32, -2, 32 } }, -- tile clip (x < 26)
	},
}))

add("CrossingX", { Coords = { 0, 0, 10, 10, 0, 10, 10, 0 }, Edges = { 1, 2, 3, 4 }, EdgeGroups = { 0, 0 } })

local barCoords, barEdges = {}, {}
for i = 0, 5 do
	for _, p in { { i * 2, -1 }, { i * 2, 11 }, { -1, i * 2 + 0.5 }, { 11, i * 2 + 0.5 } } do
		table.insert(barCoords, p[1])
		table.insert(barCoords, p[2])
	end
	local base = i * 4
	table.insert(barEdges, base + 1)
	table.insert(barEdges, base + 2)
	table.insert(barEdges, base + 3)
	table.insert(barEdges, base + 4)
end
local barGroups = table.create(#barEdges // 2, 0)
add("GridOfBars", { Coords = barCoords, Edges = barEdges, EdgeGroups = barGroups })

local rng = makeRng(42)
local random = {}
for _ = 1, 200 do
	table.insert(random, rng(0, 100))
	table.insert(random, rng(0, 100))
end
add("Random200", { Coords = random })

local lattice = {}
for x = 0, 8 do
	for y = 0, 8 do
		table.insert(lattice, x)
		table.insert(lattice, y)
	end
end
add("Lattice9x9", { Coords = lattice })

local small = {}
for _ = 1, 12 do
	table.insert(small, rng(0, 10))
	table.insert(small, rng(0, 10))
end
add("Circumcircles12", { Coords = small }, { ShowCircumcircles = true })

return scenes
