--!strict
--[=[
	Ticket 25: waypoints at seams and creases (FindPath's drape) against the alternative, a
	`SamplePath(path, spacing)` helper that walks each segment over the surface and emits a point
	every `spacing` studs. Prints, per scene: FindPath time, the waypoints added, and the worst
	height a lerp between consecutive points strays from the surface; then SamplePath's cost and
	error at a few spacings.

	lune run tools/navmesh/bench/path_shape.luau
	Run it twice to compare FindPath with and without the drape: the second time with
	`drape(lefts, rights, owners, pull(...))` replaced by `pull(...)` in Funnel.luau.
]=]

local NavMesh = require("../../../lib/navmesh/src/NavMesh")
local Scenes = require("./Scenes")

local v = vector.create
local function rect(y: number, x0: number, z0: number, x1: number, z1: number): any
	return { v(x0, y, z0), v(x1, y, z0), v(x1, y, z1), v(x0, y, z1) }
end

-- The prototype helper: each segment walked over the surface, a point every `spacing` studs.
local function samplePath(mesh: any, path: any, spacing: number): { any }
	local out = { path.Waypoints[1].Position }
	local w = path.Waypoints
	for i = 1, #w - 1 do
		local a, b = w[i].Position, w[i + 1].Position
		if w[i].Label then
			table.insert(out, b)
			continue
		end
		local n = math.max(1, math.ceil(vector.magnitude(b - a) / spacing))
		local p = a
		for s = 1, n do
			p = NavMesh.MoveAlongSurface(mesh, p, a + (b - a) * (s / n)).Position
			table.insert(out, p)
		end
	end
	return out
end

-- The worst gap between a lerp over consecutive points and the surface, walked in 0.05 steps.
local function drift(mesh: any, points: { any }): number
	local worst = 0
	for i = 1, #points - 1 do
		local a, b = points[i], points[i + 1]
		local n = math.max(1, math.ceil(vector.magnitude(b - a) / 0.05))
		local p = a
		for s = 1, n do
			local target = a + (b - a) * (s / n)
			p = NavMesh.MoveAlongSurface(mesh, p, target).Position
			worst = math.max(worst, math.abs(p.Y - target.Y))
		end
	end
	return worst
end

local function median(xs: { number }): number
	table.sort(xs)
	return xs[math.max(1, math.ceil(#xs / 2))]
end

local scenes: { { any } } = {
	{
		"overhang",
		{
			Floors = {
				Ground = { Walkable = { rect(0, 0, 0, 50, 20) }, Obstacles = { rect(0, 10, 0, 20, 20) } },
				Ramp = { Walkable = { { v(10, 0, 0), v(20, 5, 0), v(20, 5, 20), v(10, 0, 20) } } },
				Top = { Walkable = { rect(5, 20, 0, 50, 20) } },
			},
			Seams = {
				{ FloorA = "Ground", FloorB = "Ramp", From = v(10, 0, 0), To = v(10, 0, 20) },
				{ FloorA = "Ramp", FloorB = "Top", From = v(20, 5, 0), To = v(20, 5, 20) },
			},
		},
	},
	{
		"hills",
		{
			Floors = {
				Hills = {
					Walkable = {
						{
							v(0, 0, 0),
							v(12, 3.3, 0),
							v(24, 0.7, 0),
							v(30, 2.1, 9),
							v(30, -1.9, 21),
							v(18, 4.6, 24),
							v(6, 1.3, 24),
							v(0, -0.4, 12),
						},
					},
					Obstacles = { rect(0, 13, 9, 16, 13) },
				},
			},
		},
	},
}
for _, scene in Scenes do
	if scene.Name == "walls" or scene.Name == "props" then
		table.insert(scenes, { scene.Name .. " (flat)", scene.Make() })
	end
end

print(
	string.format(
		"%-18s %6s %10s %9s %9s | %-26s %-26s",
		"scene",
		"paths",
		"FindPath",
		"waypoints",
		"drift",
		"SamplePath 1: us pts drift",
		"SamplePath 0.25: us pts drift"
	)
)
for _, scene in scenes do
	local name, desc = scene[1], scene[2]
	local mesh = NavMesh.Build(desc)
	math.randomseed(31)
	local queries = {}
	while #queries < 100 do
		local a = NavMesh.FindRandomPoint(mesh, { Filter = { AgentRadius = 0.5 } })
		local b = NavMesh.FindRandomPoint(mesh, { Filter = { AgentRadius = 0.5 } })
		if a and b then
			table.insert(queries, { a.Position, b.Position })
		end
	end
	local times, count, worst, paths = {}, 0, 0, {}
	for round = 1, 5 do
		local t0 = os.clock()
		for i, q in queries do
			paths[i] = NavMesh.FindPath(mesh, q[1], q[2], { AgentRadius = 0.5 })
		end
		table.insert(times, (os.clock() - t0) / #queries * 1e6)
		if round == 1 then
			for _, path in paths do
				count += #path.Waypoints
				local points = {}
				for _, w in path.Waypoints do
					table.insert(points, w.Position)
				end
				worst = math.max(worst, drift(mesh, points))
			end
		end
	end
	local sampled = {}
	for _, spacing in { 1, 0.25 } do
		local t0 = os.clock()
		local all = {}
		for i, path in paths do
			all[i] = samplePath(mesh, path, spacing)
		end
		local us = (os.clock() - t0) / #paths * 1e6
		local pts, err = 0, 0
		for _, points in all do
			pts += #points
			err = math.max(err, drift(mesh, points))
		end
		table.insert(sampled, string.format("%6.0f %5.1f %6.3f", us, pts / #paths, err))
	end
	print(
		string.format(
			"%-18s %6d %8.1fus %9.2f %9.4f | %-26s %-26s",
			name,
			#paths,
			median(times),
			count / #paths,
			worst,
			sampled[1],
			sampled[2]
		)
	)
end
