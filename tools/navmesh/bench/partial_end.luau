--!strict
--[=[
	Track G (G3): a Partial or Budget end inside its last triangle. Over the many-slab room
	(slabs on the south wall, 0.5-2 studs short of the north wall, one tile), counts the ends a
	grid flood proves unreachable from the start, and times FindPath on the Partial queries.

	lune run tools/navmesh/bench/partial_end.luau
	Compare against the previous Search.luau (git show <base>:lib/navmesh/src/Search.luau).
]=]

local NavMesh = require("../../../lib/navmesh/src/NavMesh")
local Flood = require("../../../lib/navmesh/src/Tests/Helpers/Flood")

local v = vector.create
local function flat(xz: { number }): any
	local ring = {}
	for i = 1, #xz, 2 do
		table.insert(ring, v(xz[i], 0, xz[i + 1]))
	end
	return ring
end

local totalChecked, totalRefuted, times = 0, 0, {}
for seed = 1, 5 do
	math.randomseed(seed)
	local function rnd(lo: number, hi: number): number
		return lo + math.random() * (hi - lo)
	end
	local obstacles = {}
	local x = 2
	while x < 60 do
		local w, gap = rnd(0.5, 2), rnd(0.5, 2)
		table.insert(obstacles, flat { x, -1, x + w, -1, x + w, 10 - gap, x, 10 - gap })
		x += w + rnd(2, 6)
	end
	local mesh = NavMesh.Build {
		TileSize = 64,
		Floors = { Ground = { Walkable = { flat { 0, 0, 64, 0, 64, 10, 0, 10 } }, Obstacles = obstacles } },
	}
	local oracle = Flood.New(mesh)
	for i = 1, 300 do
		local r = rnd(0.2, 1.1)
		local a, b = v(rnd(0, 64), 0, rnd(0, 10)), v(rnd(0, 64), 0, rnd(0, 10))
		if not Flood.OnMesh(oracle, a.X, a.Z) or not Flood.OnMesh(oracle, b.X, b.Z) then
			continue
		elseif oracle.Clearance(a.X, a.Z, r + 0.01) < r then
			continue
		end
		local filter = { AgentRadius = r, MaxExpansions = if i % 3 == 0 then 4 else nil }
		local path = NavMesh.FindPath(mesh, a, b, filter)
		if path.Status == "Partial" or path.Status == "Budget" then
			local t0 = os.clock()
			for _ = 1, 20 do
				NavMesh.FindPath(mesh, a, b, filter)
			end
			table.insert(times, (os.clock() - t0) / 20 * 1e6)
			totalChecked += 1
			local last = path.Waypoints[#path.Waypoints].Position :: any
			if not Flood.Connected(oracle, r, path.Waypoints[1].Position :: any, last) then
				totalRefuted += 1
			end
		end
	end
end
table.sort(times)
local sum = 0
for _, t in times do
	sum += t
end
print(
	string.format(
		"Partial/Budget ends: %d, unreachable (flood): %d (%.1f%%); FindPath us mean %.1f p50 %.1f p95 %.1f",
		totalChecked,
		totalRefuted,
		100 * totalRefuted / totalChecked,
		sum / #times,
		times[math.ceil(#times / 2)],
		times[math.ceil(#times * 0.95)]
	)
)
