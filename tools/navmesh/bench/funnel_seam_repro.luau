local NavMesh = require("../../../lib/navmesh/src/NavMesh")
local mesh = NavMesh.Build(NavMesh.Fixtures.ThreeFloorStairs.Desc)
for _, r in { 0, 1 } do
	local p = NavMesh.FindPath(
		mesh,
		vector.create(10.5, 0.25, 3) :: any,
		vector.create(10.5, 0, 5.05) :: any,
		{ AgentRadius = r }
	)
	local pts = {}
	for _, w in p.Waypoints do
		table.insert(pts, string.format("(%.2f,%.2f,%.2f %s)", w.Position.X, w.Position.Y, w.Position.Z, w.Floor))
	end
	print(r, p.Status, string.format("len %.2f cost %.2f", p.Length, p.Cost), table.concat(pts, " "))
end
