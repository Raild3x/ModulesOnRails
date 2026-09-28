--!strict
-- Scene module for the screenshot loop: floors, seams and links (ticket 16). The three-floor
-- fixture whole, with a path from Ground to Upper, then one floor at a time via layers.
--   lune run tools/navmesh/render.luau tools/navmesh/scenes/floors <out-dir>

local NavMesh = require("../../../lib/navmesh/src/NavMesh")

local Fixtures = NavMesh.Fixtures
local v = vector.create
local show = { Tiles = false, Seams = true, Links = true }

local scenes = {}
local stairs = NavMesh.Build(Fixtures.ThreeFloorStairs.Desc)
local up = NavMesh.FindPath(stairs, v(2, 0, 2) :: any, v(30, 5, 10) :: any)
local list = NavMesh.ToDrawList(stairs, show, up)
table.insert(scenes, { Name = "ThreeFloorStairs_All", List = list })
for _, floor in { "Ground", "Stairs", "Upper" } do
	table.insert(scenes, {
		Name = `ThreeFloorStairs_{floor}`,
		List = list,
		Layers = { `Floor:{floor}`, "Walls", "Seams", "Path" },
	})
end
for _, name in { "LinkJump", "OneWayLink" } do
	local mesh = NavMesh.Build(Fixtures[name].Desc)
	local path = if name == "LinkJump"
		then NavMesh.FindPath(mesh, v(2, 0, 2) :: any, v(22, 0, 8) :: any)
		else NavMesh.FindPath(mesh, v(2, 4, 2) :: any, v(20, 0, 8) :: any)
	table.insert(scenes, { Name = name, List = NavMesh.ToDrawList(mesh, show, path) })
end
return scenes
