--!strict
-- Game-facing costs under Lune: the demo level at a few TileSizes (how many paths a door
-- toggle invalidates, and what Update costs), then bigger maps from tools/navmesh/bench.
--   lune run examples/navmesh-demo/bench.luau
local NavMesh = require("../../lib/navmesh/src/NavMesh")
local Level = require("./Level")
local Scenes = require("../../tools/navmesh/bench/Scenes")

local function median(samples: { number }): number
	local sorted = table.clone(samples)
	table.sort(sorted)
	return sorted[math.max(1, math.ceil(#sorted / 2))]
end

local function ms(fn: () -> ()): number
	local t0 = os.clock()
	fn()
	return (os.clock() - t0) * 1000
end

local function countKind(list: { any }, layer: string?): number
	local n = 0
	for _, p in list do
		if (layer == nil and p.Kind == "Tri") or p.Layer == layer then
			n += 1
		end
	end
	return n
end

local seed = 1
local function rng(): number
	seed = (seed * 1103515245 + 12345) % 2147483648
	return seed / 2147483648
end

print("== demo level: a door toggle vs TileSize")
print(
	string.format(
		"%-9s %6s %6s %9s %11s %11s %12s",
		"TileSize",
		"tiles",
		"tris",
		"build ms",
		"Update ms",
		"FindPath ms",
		"paths broken"
	)
)
for _, size in { 0, 32, 16, 8, 4 } do
	local desc = table.clone(Level.Desc)
	desc.TileSize = if size > 0 then size else nil
	local mesh
	local buildMs = ms(function()
		mesh = NavMesh.Build(desc)
	end)
	local list = NavMesh.ToDrawList(mesh, { Tiles = true })
	-- 200 random paths, then close the door once and count the ones IsPathValid rejects.
	local paths, findTimes = {}, {}
	for _ = 1, 200 do
		local a = NavMesh.FindRandomPoint(mesh, { Rng = rng })
		local b = NavMesh.FindRandomPoint(mesh, { Rng = rng })
		if a and b then
			local path
			table.insert(
				findTimes,
				ms(function()
					path = NavMesh.FindPath(mesh, a.Position, b.Position, { AgentRadius = 0.5 })
				end)
			)
			table.insert(paths, path)
		end
	end
	local door = NavMesh.AddObstacle(mesh, "Ground", Level.DOOR)
	local updates = { ms(function()
		NavMesh.Update(mesh)
	end) }
	local broken = 0
	for _, path in paths do
		if not NavMesh.IsPathValid(mesh, path) then
			broken += 1
		end
	end
	for i = 1, 40 do
		if door then
			NavMesh.RemoveObstacle(mesh, door)
			door = nil
		else
			door = NavMesh.AddObstacle(mesh, "Ground", Level.DOOR)
		end
		table.insert(
			updates,
			ms(function()
				NavMesh.Update(mesh)
			end)
		)
	end
	print(
		string.format(
			"%-9s %6d %6d %9.2f %11.3f %11.4f %9d/%d",
			if size > 0 then tostring(size) else "default",
			countKind(list, "Tiles") // 4,
			countKind(list),
			buildMs,
			median(updates),
			median(findTimes),
			broken,
			#paths
		)
	)
end

print("\n== bigger maps (default TileSize), medians; cap = NavMeshDesc.MaxAgentRadius")
print(
	string.format(
		"%-8s %5s %6s %7s %9s %8s %12s %12s %10s %12s %s",
		"scene",
		"side",
		"cap",
		"tris",
		"build ms",
		"bytes",
		"FindPath r0",
		"FindPath r1",
		"Update ms",
		"MoveAlong ms",
		"status r0/r1"
	)
)
for _, run in
	{
		{ 0, "props" },
		{ 2, "props" },
		{ 0, "bench" },
		{ 2, "bench" },
		{ 0, "terrain" },
		{ 2, "terrain" },
		{ 0, "walls" },
		{ 2, "walls" },
	}
do
	local cap, name = run[1] :: number, run[2] :: string
	local scene
	for _, s in Scenes do
		if s.Name == name then
			scene = s
		end
	end
	local desc = scene.Make()
	desc.MaxAgentRadius = if cap > 0 then cap else nil
	local mesh
	local buildMs = ms(function()
		mesh = NavMesh.Build(desc)
	end)
	local side = scene.Side
	-- Corner to corner, snapped onto the mesh first (a corner may be inside a prop).
	local from = NavMesh.FindNearestPoint(
		mesh,
		vector.create(side * 0.02, 0, side * 0.02),
		{ SnapExtents = vector.create(8, 4, 8) }
	)
	local to = NavMesh.FindNearestPoint(
		mesh,
		vector.create(side * 0.98, 0, side * 0.98),
		{ SnapExtents = vector.create(8, 4, 8) }
	)
	assert(from and to, scene.Name)
	local r0, r1, status = {}, {}, ""
	for _ = 1, 9 do
		table.insert(
			r0,
			ms(function()
				status = NavMesh.FindPath(mesh, from.Position, to.Position).Status
			end)
		)
		table.insert(
			r1,
			ms(function()
				status = status:sub(1, 7)
					.. "/"
					.. NavMesh.FindPath(mesh, from.Position, to.Position, { AgentRadius = 1 }).Status
			end)
		)
	end
	local updates = {}
	local crate: { any }? = nil
	local id: number? = nil
	for i = 1, 21 do
		if id then
			NavMesh.RemoveObstacle(mesh, id)
			id = nil
		else
			local c = side / 2 + (i % 5)
			crate = {
				vector.create(c - 2, 0, c - 2),
				vector.create(c + 2, 0, c - 2),
				vector.create(c + 2, 0, c + 2),
				vector.create(c - 2, 0, c + 2),
			}
			id = NavMesh.AddObstacle(mesh, "Ground", crate :: any)
		end
		table.insert(
			updates,
			ms(function()
				NavMesh.Update(mesh)
			end)
		)
	end
	local moves = {}
	local p = from.Position
	for _ = 1, 200 do
		local target = p + vector.normalize(to.Position - p) * 0.3
		table.insert(
			moves,
			ms(function()
				p = NavMesh.MoveAlongSurface(mesh, p, target, { AgentRadius = 1 }).Position
			end)
		)
	end
	print(
		string.format(
			"%-8s %5d %6s %7d %9.1f %8d %12.3f %12.3f %10.3f %12.4f %s",
			scene.Name,
			side,
			if cap > 0 then tostring(cap) else "none",
			countKind(NavMesh.ToDrawList(mesh)),
			buildMs,
			buffer.len(NavMesh.Serialize(mesh)),
			median(r0),
			median(r1),
			median(updates),
			median(moves),
			status
		)
	)
end

print("\n== the 256-stud 'bench' map, MaxAgentRadius 2: TileSize vs Update (a 4x4 crate)")
print(string.format("%-9s %6s %9s %10s %12s", "TileSize", "tiles", "build ms", "Update ms", "FindPath r1"))
for _, size in { 0, 64, 32, 16, 8 } do
	local desc
	for _, s in Scenes do
		if s.Name == "bench" then
			desc = s.Make()
		end
	end
	desc.MaxAgentRadius = 2
	desc.TileSize = if size > 0 then size else nil
	local mesh
	local buildMs = ms(function()
		mesh = NavMesh.Build(desc)
	end)
	local updates, finds = {}, {}
	local id: number? = nil
	for i = 1, 21 do
		if id then
			NavMesh.RemoveObstacle(mesh, id)
			id = nil
		else
			local c = 128 + (i % 5)
			id = NavMesh.AddObstacle(
				mesh,
				"Ground",
				{
					vector.create(c - 2, 0, c - 2),
					vector.create(c + 2, 0, c - 2),
					vector.create(c + 2, 0, c + 2),
					vector.create(c - 2, 0, c + 2),
				} :: any
			)
		end
		table.insert(
			updates,
			ms(function()
				NavMesh.Update(mesh)
			end)
		)
		table.insert(
			finds,
			ms(function()
				NavMesh.FindPath(mesh, vector.create(5, 0, 5), vector.create(250, 0, 250), { AgentRadius = 1 })
			end)
		)
	end
	print(
		string.format(
			"%-9s %6d %9.1f %10.3f %12.3f",
			if size > 0 then tostring(size) else "default",
			countKind(NavMesh.ToDrawList(mesh, { Triangles = false, Tiles = true }), "Tiles") // 4,
			buildMs,
			median(updates),
			median(finds)
		)
	)
end
