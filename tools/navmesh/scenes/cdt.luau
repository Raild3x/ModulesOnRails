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

for _, scenario in CDT.Fixtures.All do
	add(`Points_{scenario.Name}`, { Coords = CDT.Fixtures.ToInput(scenario).Coords })
	add(`Constrained_{scenario.Name}`, CDT.Fixtures.ToInput(scenario))
end

add("CrossingX", { Coords = { 0, 0, 10, 10, 0, 10, 10, 0 }, Edges = { 1, 2, 3, 4 } })

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
add("GridOfBars", { Coords = barCoords, Edges = barEdges })

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
