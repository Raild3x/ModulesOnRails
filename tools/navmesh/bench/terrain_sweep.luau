--!strict
-- Ticket 37: how slight height variation changes the mesh. Builds ForestRiver at each tilt
-- (0 = flat, every piece coplanar) and prints one Markdown row per tilt:
-- - floors, seams, triangles and obstacle rings from the adapter;
-- - FromParts, Build and Deserialize ms, and bake bytes;
-- - FindPath over 200 seeded random pairs at radius 1: median and p95 us, and the statuses;
-- - smoothness: turns (a heading change over 2 degrees, in plan) and waypoints per 100 studs;
-- - water: sampled path points over the channel (outside the ford) that aren't on the bridge.
-- Rounds are interleaved (tilt order rotated each round); times are the median over rounds.
-- `onefloor` instead measures the deferred option: Meadow* and Forest* floors merged into one
-- non-planar floor each (TerrainOneFloor.luau).
--   lune run tools/navmesh/bench/terrain_sweep.luau [rounds=3] [seed=37] [onefloor]
local process = require("@lune/process")
local roblox = require("@lune/roblox") :: any
local NavMesh = require("../../../lib/navmesh/src/NavMesh")
local Adapter = require("../../../lib/navmeshadapter/src/NavMeshAdapter")
local ForestRiver = require("../maps/Maps/ForestRiver") :: any

local ROUNDS = tonumber(process.args[1]) or 3
local SEED = tonumber(process.args[2]) or 37
local ONE_FLOOR = process.args[3] == "onefloor"
local TerrainOneFloor = require("./TerrainOneFloor")
local TILTS = { 0, 1, 3, 5, 10 }
local PAIRS = 200

local function median(xs: { number }): number
	local s = table.clone(xs)
	table.sort(s)
	return s[(#s + 1) // 2]
end
local function p95(xs: { number }): number
	local s = table.clone(xs)
	table.sort(s)
	return s[math.max(1, math.ceil(#s * 0.95))]
end

local function park(seed: number): () -> number
	local s = seed
	return function()
		s = s * 16807 % 2147483647
		return s / 2147483647
	end
end

-- Turns and waypoints per 100 studs, and water hits, over one path.
local function shape(path: any): (number, number, number)
	local w = path.Waypoints
	local turns, heading = 0, nil
	local wet = 0
	for i = 2, #w do
		local a, b = w[i - 1].Position, w[i].Position
		local dx, dz = b.X - a.X, b.Z - a.Z
		if dx * dx + dz * dz > 0.0025 then
			local h = math.atan2(dz, dx)
			if heading then
				local d = math.abs((h - heading + math.pi) % (2 * math.pi) - math.pi)
				turns += if d > math.rad(2) then 1 else 0
			end
			heading = h
		end
		local steps = math.max(1, math.ceil(math.sqrt(dx * dx + dz * dz) / 0.5))
		for k = 0, steps do
			local t = k / steps
			local x, y, z = a.X + dx * t, a.Y + (b.Y - a.Y) * t, a.Z + dz * t
			local overWater = x > 94.2 and x < 105.8 and (z < 110 or z > 125)
			wet += if overWater and y < 2 then 1 else 0
		end
	end
	return turns, #w, wet
end

type Row = {
	Floors: number,
	Seams: number,
	Triangles: number,
	ObstacleRings: number,
	Bake: number,
	FromParts: { number },
	Build: { number },
	Load: { number },
	FindPath: { number }, -- per round: median us
	FindPathP95: { number },
	Statuses: string,
	Turns: number,
	Waypoints: number,
	Wet: number,
}
local rows: { [number]: Row } = {}

for round = 1, ROUNDS do
	for k = 0, #TILTS - 1 do
		local tilt = TILTS[(k + round - 1) % #TILTS + 1]
		local map = ForestRiver.WithTilt(tilt, SEED)
		local built = map.Build(roblox)
		local t0 = os.clock()
		local desc = if ONE_FLOOR
			then TerrainOneFloor(map, built, Adapter)
			else Adapter.FromParts(built.Walkable, built.Obstacles, map.AdapterOptions) :: any
		local fromParts = (os.clock() - t0) * 1000
		desc.MaxAgentRadius = 2
		t0 = os.clock()
		local mesh = NavMesh.Build(desc)
		local build = (os.clock() - t0) * 1000
		local bake = NavMesh.Serialize(mesh)
		t0 = os.clock()
		NavMesh.Deserialize(bake)
		local load = (os.clock() - t0) * 1000

		local row = rows[tilt]
		if row == nil then
			local rings, floors = 0, 0
			for _, f in desc.Floors do
				floors += 1
				rings += if f.Obstacles then #f.Obstacles else 0
			end
			row = {
				Floors = floors,
				Seams = #desc.Seams,
				Triangles = mesh.TriangleCount,
				ObstacleRings = rings,
				Bake = buffer.len(bake),
				FromParts = {},
				Build = {},
				Load = {},
				FindPath = {},
				FindPathP95 = {},
				Statuses = "",
				Turns = 0,
				Waypoints = 0,
				Wet = 0,
			}
			rows[tilt] = row
		end
		local r = row :: Row
		table.insert(r.FromParts, fromParts)
		table.insert(r.Build, build)
		table.insert(r.Load, load)

		local filter = { AgentRadius = 1 }
		local rng = park(SEED)
		local times, statuses = {}, {}
		local turns, waypoints, wet, length = 0, 0, 0, 0
		for _ = 1, PAIRS do
			local a = NavMesh.FindRandomPoint(mesh, { Filter = filter, Rng = rng })
			local b = NavMesh.FindRandomPoint(mesh, { Filter = filter, Rng = rng })
			if a == nil or b == nil then
				continue
			end
			t0 = os.clock()
			local path = NavMesh.FindPath(mesh, a.Position, b.Position, filter)
			table.insert(times, (os.clock() - t0) * 1e6)
			statuses[path.Status] = (statuses[path.Status] or 0) + 1
			if path.Status == "Success" then
				local tn, wp, w = shape(path)
				turns += tn
				waypoints += wp
				wet += w
				length += path.Length
			end
		end
		table.insert(r.FindPath, median(times))
		table.insert(r.FindPathP95, p95(times))
		if round == 1 then
			local parts = {}
			for status, n in statuses do
				table.insert(parts, `{status} {n}`)
			end
			table.sort(parts)
			r.Statuses = table.concat(parts, ", ")
			r.Turns = turns / length * 100
			r.Waypoints = waypoints / length * 100
			r.Wet = wet
		end
	end
end

print(
	`ForestRiver{if ONE_FLOOR then " (one floor per terrain)" else ""}, seed {SEED}, {ROUNDS} interleaved rounds, {PAIRS} random pairs at radius 1`
)
print(
	"| tilt | floors | seams | triangles | obstacle rings | FromParts ms | Build ms | bake KB | Deserialize ms | FindPath us p50 / p95 | turns / 100 st | waypoints / 100 st | water hits | statuses |"
)
print("|---|---|---|---|---|---|---|---|---|---|---|---|---|---|")
for _, tilt in TILTS do
	local r = rows[tilt]
	print(
		string.format(
			"| %d | %d | %d | %d | %d | %.0f | %.0f | %.0f | %.1f | %.0f / %.0f | %.2f | %.2f | %d | %s |",
			tilt,
			r.Floors,
			r.Seams,
			r.Triangles,
			r.ObstacleRings,
			median(r.FromParts),
			median(r.Build),
			r.Bake / 1024,
			median(r.Load),
			median(r.FindPath),
			median(r.FindPathP95),
			r.Turns,
			r.Waypoints,
			r.Wet,
			r.Statuses
		)
	)
end
