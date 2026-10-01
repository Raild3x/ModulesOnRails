--!strict
-- The numbers in REPORT.md ("Timings"). Part 1 sweeps TileSize on the warehouse: Build, bake
-- size, Deserialize, then a 30 s game per seed (Update cost, replans per Update by changed
-- region and by stale stamps, FindPath, Advance, the whole tick). Part 2 scales the agent count
-- at the default TileSize. Runs are interleaved; each cell is the median over seeds [min-max].
--   lune run examples/navmesh-demo2/bench.luau [ticks=900] [seeds=3]
local process = require("@lune/process")
local roblox = require("@lune/roblox") :: any
local NavMesh = require("../../lib/navmesh/src/NavMesh")
local Adapter = require("../../lib/navmeshadapter/src/NavMeshAdapter")
local Game = require("./Game")
local LevelParts = require("./LevelParts")

local TICKS = tonumber(process.args[1]) or 900
local SEEDS = tonumber(process.args[2]) or 3
local TILES = { 0, 64, 32, 16, 8 } -- 0: the default
local SCALES = { 1, 2, 4 }

local function median(xs: { number }): number
	local s = table.clone(xs)
	table.sort(s)
	return s[(#s + 1) // 2]
end
local function cell(xs: { number }, fmt: string): string
	local lo, hi = math.huge, -math.huge
	for _, x in xs do
		lo, hi = math.min(lo, x), math.max(hi, x)
	end
	return string.format(`{fmt} [{fmt}-{fmt}]`, median(xs), lo, hi)
end

local function build(tile: number): (any, number)
	local walkable, obstacles = LevelParts(roblox)
	local desc = Adapter.FromParts(walkable, obstacles) :: any
	desc.MaxAgentRadius = 2
	desc.TileSize = if tile > 0 then tile else nil
	local t0 = os.clock()
	local mesh = NavMesh.Build(desc)
	return mesh, (os.clock() - t0) * 1000
end

-- One game: { metric = value }.
local function game(data: buffer, seed: number, scale: number): { [string]: number }
	local t0 = os.clock()
	local mesh = NavMesh.Deserialize(data)
	local loadMs = (os.clock() - t0) * 1000
	local _, _, doors, crates = LevelParts(roblox)
	local world = Game.new(NavMesh, mesh, doors, crates, seed, scale)
	for _ = 1, TICKS do
		world:Step(Game.DT)
	end
	local out = { Deserialize = loadMs }
	for _, row in Game.Timings(world) do
		out[row[1] .. " p50"], out[row[1] .. " p95"] = row[3], row[4]
		out[row[1] .. " count"] = row[2]
	end
	local c, updates = world.Counters, out["Update count"]
	out.regionPer = (c["repath:region"] or 0) / updates
	out.stampPer = (c["stale:stamps"] or 0) / updates
	out.footPer = (c["stale:footprints"] or 0) / updates
	out.findPerTick = out["FindPath count"] / TICKS
	return out
end

local bakes, rows = {}, {}
for _, tile in TILES do
	local builds, mesh = {}, nil
	for _ = 1, 3 do
		local ms
		mesh, ms = build(tile)
		table.insert(builds, ms)
	end
	bakes[tile] = NavMesh.Serialize(mesh)
	local tris = 0
	for _, item in NavMesh.ToDrawList(mesh) do
		tris += if item.Kind == "Tri" then 1 else 0
	end
	rows[tile] = { Build = builds, Tris = tris, Runs = {} }
end
for seed = 1, SEEDS do
	for _, tile in TILES do
		table.insert(rows[tile].Runs, game(bakes[tile], seed, 1))
	end
end

local function col(runs: { any }, key: string): { number }
	local xs = {}
	for _, r in runs do
		table.insert(xs, r[key] or 0)
	end
	return xs
end

print(`== TileSize sweep: {TICKS} ticks x {SEEDS} seeds, 36 agents; ms, median [min-max]`)
print(
	"| TileSize | Triangles | Build | Bake bytes | Deserialize | first Update | Update p50 | Update p95 | replans/Update (regions) | stale/Update (stamps) | blocked/Update (footprints) | FindPath p50 | tick p50 | tick p95 |"
)
print("|---|---|---|---|---|---|---|---|---|---|---|---|---|---|")
for _, tile in TILES do
	local r = rows[tile]
	print(
		string.format(
			"| %s | %d | %s | %d | %s | %s | %s | %s | %s | %s | %s | %s | %s | %s |",
			if tile == 0 then "default" else tostring(tile),
			r.Tris,
			cell(r.Build, "%.1f"),
			buffer.len(bakes[tile]),
			cell(col(r.Runs, "Deserialize"), "%.2f"),
			cell(col(r.Runs, "first Update p50"), "%.1f"),
			cell(col(r.Runs, "Update p50"), "%.2f"),
			cell(col(r.Runs, "Update p95"), "%.2f"),
			cell(col(r.Runs, "regionPer"), "%.1f"),
			cell(col(r.Runs, "stampPer"), "%.1f"),
			cell(col(r.Runs, "footPer"), "%.2f"),
			cell(col(r.Runs, "FindPath p50"), "%.3f"),
			cell(col(r.Runs, "whole tick p50"), "%.2f"),
			cell(col(r.Runs, "whole tick p95"), "%.2f")
		)
	)
end

local scaled = {}
for seed = 1, SEEDS do
	for _, scale in SCALES do
		scaled[scale] = scaled[scale] or {}
		table.insert(scaled[scale], game(bakes[0], seed, scale))
	end
end
print(`\n== Agent count at the default TileSize: {TICKS} ticks x {SEEDS} seeds; ms, median [min-max]`)
print("| Agents | FindPath/tick | FindPath p50 | FindPath p95 | Advance p50 | Update p50 | tick p50 | tick p95 |")
print("|---|---|---|---|---|---|---|---|")
for _, scale in SCALES do
	local runs = scaled[scale]
	print(
		string.format(
			"| %d | %s | %s | %s | %s | %s | %s | %s |",
			1 + math.round(24 * scale) + math.round(11 * scale),
			cell(col(runs, "findPerTick"), "%.1f"),
			cell(col(runs, "FindPath p50"), "%.3f"),
			cell(col(runs, "FindPath p95"), "%.3f"),
			cell(col(runs, "Advance p50"), "%.4f"),
			cell(col(runs, "Update p50"), "%.2f"),
			cell(col(runs, "whole tick p50"), "%.2f"),
			cell(col(runs, "whole tick p95"), "%.2f")
		)
	)
end
