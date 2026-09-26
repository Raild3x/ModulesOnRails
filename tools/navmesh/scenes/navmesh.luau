--!strict
-- Scene module for the screenshot loop: every NavMesh fixture built and drawn, by floor (with
-- tile bounds), by area, and cut into small tiles.
--   lune run tools/navmesh/render.luau tools/navmesh/scenes/navmesh <out-dir>

local NavMesh = require("../../../lib/navmesh/src/NavMesh")

local scenes = {}
for _, scenario in NavMesh.Fixtures.All do
	local mesh = NavMesh.Build(scenario.Desc)
	table.insert(scenes, { Name = `{scenario.Name}_Floors`, List = NavMesh.ToDrawList(mesh, { Tiles = true }) })
	table.insert(scenes, { Name = `{scenario.Name}_Areas`, List = NavMesh.ToDrawList(mesh, { Areas = true }) })
	local tiled = table.clone(scenario.Desc)
	tiled.TileSize = 5.5
	table.insert(
		scenes,
		{ Name = `{scenario.Name}_Tiles5_5`, List = NavMesh.ToDrawList(NavMesh.Build(tiled), { Tiles = true }) }
	)
end
return scenes
