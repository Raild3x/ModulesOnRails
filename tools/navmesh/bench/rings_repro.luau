--!strict
-- Ticket 31 repro: Build is O(triangles x walkable rings) on a floor. Build.triangulateTile asks
-- every walkable ring's surface for each kept triangle's heights (one CDT.Locate per ring), so
-- a floor authored as many small rings (a terrain adapter's output) builds quadratically.
-- The floor here is an n x n grid of flat 8-stud squares (all one height, edge to edge), so the
-- area, triangles and rings all grow as n^2; a linear Build would grow 4x per doubling of n.
-- Update re-triangulates its dirty tiles the same way, so one crate's Update (a fixed number of
-- dirty triangles) grows with the ring count; a local Update would stay flat.
--   lune run tools/navmesh/bench/rings_repro.luau
local NavMesh = require("../../../lib/navmesh/src/NavMesh")
local CDT = require("../../../lib/navmesh/ConstrainedDelaunay")

local locates = 0
local locate = CDT.Locate
CDT.Locate = function(...)
	locates += 1
	return locate(...)
end

local function grid(n: number): any
	local rings = {}
	for i = 0, n - 1 do
		for j = 0, n - 1 do
			local x, z = i * 8, j * 8
			table.insert(rings, {
				vector.create(x, 0, z),
				vector.create(x + 8, 0, z),
				vector.create(x + 8, 0, z + 8),
				vector.create(x, 0, z + 8),
			})
		end
	end
	return { TileSize = 32, Floors = { Ground = { Walkable = rings } } }
end

print("| n | rings | triangles | Build ms | CDT.Locate calls | Locates per triangle | crate Update ms | its Locates |")
print("|---|---|---|---|---|---|---|---|")
for _, n in { 8, 16, 32, 64 } do
	locates = 0
	local t0 = os.clock()
	local mesh = NavMesh.Build(grid(n)) :: any
	local ms = (os.clock() - t0) * 1000
	local built = locates
	-- A warm-up crate builds the wall index; the second is timed.
	for run = 1, 2 do
		local c = 8 * (n // 2) + run * 3
		local crate = {
			vector.create(c - 1, 0, c - 1),
			vector.create(c + 1, 0, c - 1),
			vector.create(c + 1, 0, c + 1),
			vector.create(c - 1, 0, c + 1),
		}
		NavMesh.AddObstacle(mesh, "Ground", crate :: any)
		locates = 0
		t0 = os.clock()
		NavMesh.Update(mesh)
	end
	local update = (os.clock() - t0) * 1000
	print(
		string.format(
			"| %d | %d | %d | %.0f | %d | %.0f | %.1f | %d |",
			n,
			n * n,
			mesh.TriangleCount,
			ms,
			built,
			built / mesh.TriangleCount,
			update,
			locates
		)
	)
end
