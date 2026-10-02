-- Minimal repro: FindPath's Cost for one straight path depends on an area's multiplier the
-- path never touches. A 40 x 20 floor; area 5 is a patch far off the path.
local NavMesh = require("../../../lib/navmesh/src/NavMesh")
local V = vector.create
local desc = {
	Floors = {
		F = {
			Walkable = { { V(0, 0, 0), V(40, 0, 0), V(40, 0, 20), V(0, 0, 20) } :: any },
			Areas = { { Polygon = { V(30, 0, 15), V(38, 0, 15), V(38, 0, 19), V(30, 0, 19) }, Area = 5 } :: any },
		},
	},
}
local mesh = NavMesh.Build(desc :: any)
for _, c in { 1, 1.0001, 2, 5, math.huge } do
	local p = NavMesh.FindPath(mesh, V(2, 0, 5) :: any, V(38, 0, 5) :: any, { AreaCosts = { [5] = c } })
	print(
		string.format(
			"AreaCosts[5] = %-8s Status %s  Length %.3f  Cost %.3f  waypoints %d",
			tostring(c),
			p.Status,
			p.Length,
			p.Cost,
			#p.Waypoints
		)
	)
end
