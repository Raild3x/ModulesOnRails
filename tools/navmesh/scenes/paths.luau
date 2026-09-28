--!strict
-- Scene module for the screenshot loop: FindPath results drawn over their meshes (ticket 14).
--   lune run tools/navmesh/render.luau tools/navmesh/scenes/paths <out-dir>

local NavMesh = require("../../../lib/navmesh/src/NavMesh")

local function flat(y: number, xz: { number }): { vector }
	local ring = {}
	for i = 1, #xz, 2 do
		table.insert(ring, vector.create(xz[i], y, xz[i + 1]))
	end
	return ring
end

local function v(x: number, z: number): any
	return vector.create(x, 0, z)
end

local loop = {
	Floors = {
		Ground = {
			Walkable = { flat(0, { 0, 0, 40, 0, 40, 40, 0, 40 }) },
			Obstacles = { flat(0, { 4, 2, 36, 2, 36, 36, 4, 36 }) },
			Areas = {
				{ Polygon = flat(0, { 0, 2, 4, 2, 4, 40, 0, 40 }), Area = 2 },
				{ Polygon = flat(0, { 4, 36, 36, 36, 36, 40, 4, 40 }), Area = 2 },
				{ Polygon = flat(0, { 36, 2, 40, 2, 40, 40, 36, 40 }), Area = 2 },
			},
		},
	},
}

local scenes = {}
local function add(name: string, desc: any, from: any, to: any, filter: any?, options: any?)
	local mesh = NavMesh.Build(desc)
	local path = NavMesh.FindPath(mesh, from, to, filter)
	table.insert(scenes, { Name = `{name}_{path.Status}`, List = NavMesh.ToDrawList(mesh, options, path) })
end

local courtyard = NavMesh.Fixtures.Courtyard.Desc
add("Courtyard_Corner", courtyard, v(1, 1), v(29, 19))
add("Courtyard_Arm", courtyard, v(29, 1), v(2, 29))
add("Courtyard_Patch", courtyard, v(6, 18), v(6, 29.5), nil, { Areas = true })
add("Courtyard_PatchExcluded", courtyard, v(6, 18), v(6, 29.5), { AreaCosts = { [2] = math.huge } }, { Areas = true })
add("Courtyard_Budget", courtyard, v(1, 1), v(29, 19), { MaxExpansions = 4 })
add("Loop_Direct", loop, v(2, 1), v(38, 1), nil, { Areas = true })
add("Loop_CheapDetour", loop, v(2, 1), v(38, 1), { AreaCosts = { [2] = 0.1 } }, { Areas = true })
add("Shallow", NavMesh.Fixtures.ShallowObstacles.Desc, v(1, 1), v(39, 19))
-- Clearance (ticket 15): the same query at growing radii, over the clearance heat map.
for _, radius in { 0.5, 1.5, 2.5 } do
	add(`Courtyard_Radius{radius}`, courtyard, v(1, 1), v(2, 29), { AgentRadius = radius }, { Clearance = true })
end
-- Ticket 26: several paths in one list, each in its own colour, over a custom palette, with the
-- LinkJump link disabled (drawn faded).
do
	local mesh = NavMesh.Build(courtyard)
	local paths = {
		NavMesh.FindPath(mesh, v(1, 1), v(29, 19)),
		NavMesh.FindPath(mesh, v(29, 1), v(2, 29)),
		NavMesh.FindPath(mesh, v(6, 18), v(6, 29.5)),
	}
	local palette = {
		Areas = true,
		AreaColors = { "#fff59d", "#80deea" },
		WallColor = "#ff6f00",
		PathColors = { "#d81b60", "#3949ab", "#2e7d32" },
	}
	table.insert(scenes, { Name = "Courtyard_MultiPath", List = NavMesh.ToDrawList(mesh, palette, paths) })
	local jump = NavMesh.Build(NavMesh.Fixtures.LinkJump.Desc)
	NavMesh.SetLinkEnabled(jump, 1, false)
	table.insert(scenes, { Name = "LinkJump_Disabled", List = NavMesh.ToDrawList(jump, { Links = true }) })
end
return scenes
