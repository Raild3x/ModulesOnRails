-- Phase profile of NavMesh.Build on the TileSize benchmark map (interpreted, Lune): where does
-- the time go? Wraps the module functions Build reaches through tables, in the vendored CDT
-- copy Build actually uses (run `npm run setup navmesh` first). The wraps are installed before
-- Build is required, so the Triangulator's cached predicate locals see them too.
--   lune run tools/navmesh/bench/profile_build.luau [mapSize] [tileSize]
local process = require("@lune/process")

local CDT_SRC = "../../../lib/navmesh/_Index/raild3x_constraineddelaunay@local/constraineddelaunay/src/"
local Predicates = require(CDT_SRC .. "Predicates")
local counts: { [string]: number } = {}
local times: { [string]: number } = {}
local function count(module: any, name: string)
	local original = module[name]
	counts[name] = 0
	module[name] = function(...)
		counts[name] += 1
		return original(...)
	end
end
local function timed(module: any, name: string, label: string)
	local original = module[name]
	times[label], counts[label] = 0, 0
	module[name] = function(...)
		local t0 = os.clock()
		local results = table.pack(original(...))
		times[label] += os.clock() - t0
		counts[label] += 1
		return table.unpack(results, 1, results.n)
	end
end
count(Predicates, "Orient2D")
count(Predicates, "InCircle")
-- CDT internals the Triangulator reaches through module tables.
timed(require(CDT_SRC .. "Classify"), "Flood", "  Flood")
timed(require(CDT_SRC .. "Classify"), "CheckBalanced", "  Balanced")
timed(require(CDT_SRC .. "Storage"), "Compact", "  Compact")
timed(require(CDT_SRC .. "Triangulator"), "Walk", "  Walk")

local CDT = require("../../../lib/navmesh/ConstrainedDelaunay")
local Quantize = require("../../../lib/navmesh/src/Quantize")
timed(Quantize, "SnapRound", "SnapRound")
timed(CDT, "Triangulate", "Triangulate")
timed(CDT, "Locate", "Locate")
local NavMesh = require("../../../lib/navmesh/src/NavMesh")
local TileSize = require("./TileSize")

local mapSize = tonumber(process.args[1]) or 256
local tileSize = tonumber(process.args[2]) or 32
local desc = TileSize.Map(mapSize, 7)
desc.TileSize = tileSize

local t0 = os.clock()
local mesh = NavMesh.Build(desc) :: any
local total = os.clock() - t0

print(
	string.format(
		"map %d studs, TileSize %d: %d triangles, %d tiles",
		mapSize,
		tileSize,
		mesh.TriangleCount,
		#mesh.TileFloor
	)
)
print(string.format("%-12s %9s %8s %7s", "phase", "ms", "calls", "share"))
local accounted = 0
for _, label in { "SnapRound", "Triangulate", "Locate" } do
	accounted += times[label]
	print(
		string.format("%-12s %9.1f %8d %6.1f%%", label, times[label] * 1000, counts[label], times[label] / total * 100)
	)
end
print(
	string.format(
		"%-12s %9.1f %8s %6.1f%%",
		"rest (Build)",
		(total - accounted) * 1000,
		"",
		(total - accounted) / total * 100
	)
)
print(string.format("%-12s %9.1f", "total", total * 1000))
print("inside Triangulate:")
for _, label in { "  Walk", "  Flood", "  Balanced", "  Compact" } do
	print(
		string.format("%-12s %9.1f %8d %6.1f%%", label, times[label] * 1000, counts[label], times[label] / total * 100)
	)
end
print(string.format("predicate calls: Orient2D %d, InCircle %d", counts.Orient2D, counts.InCircle))
