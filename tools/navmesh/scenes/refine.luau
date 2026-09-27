--!strict
-- Scene module for the screenshot loop: CDT.Refine results (ticket 10), before and after.
--   lune run tools/navmesh/render.luau tools/navmesh/scenes/refine <out-dir>

local CDT = require("../../../lib/constraineddelaunay/src/ConstrainedDelaunay")

local scenes = {}

local function add(name: string, input: CDT.TriangulateInput, options: CDT.RefineOptions, colorGroup: number?)
	local draw = { ColorByGroup = colorGroup }
	table.insert(scenes, { Name = `{name}_Before`, List = CDT.ToDrawList(CDT.Triangulate(input), draw) })
	local tri = CDT.Triangulate(input)
	local done = CDT.Refine(tri, options)
	table.insert(
		scenes,
		{ Name = `{name}_After_{if done then "Done" else "Budget"}`, List = CDT.ToDrawList(tri, draw) }
	)
end

for _, scenario in CDT.Fixtures.All do
	add(scenario.Name, CDT.Fixtures.ToInput(scenario), { MinAngle = 20, MaxArea = 2 }, 1)
end
-- A flat hull triangle: its circumcentre lies outside, so hull edges must be split instead.
add("FlatHull", { Coords = { 0, 0, 10, 0, 5, 0.5 } }, { MinAngle = 20 })
-- Two constraints meeting at about 8 degrees: that input angle is left alone (P6).
add(
	"SmallInputAngle",
	{ Coords = { 0, 0, 40, 0, 40, 40, 0, 40, 5, 5, 35, 5, 35, 9.2 }, Edges = { 5, 6, 5, 7 }, EdgeGroups = { 0, 0 } },
	{ MinAngle = 20 }
)
add("Budget", { Coords = { 0, 0, 20, 0, 20, 20, 0, 20 } }, { MaxArea = 0.5, MaxSteiner = 60 })
return scenes
