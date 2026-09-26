-- Quick interpreted gauge of the TileSize benchmark (the decision uses the Studio run).
--   lune run tools/navmesh/bench/tilesize_lune.luau [mapSize]
local process = require("@lune/process")
local NavMesh = require("../../../lib/navmesh/src/NavMesh")
require("./TileSize").Run {
	NavMesh = NavMesh,
	Clock = os.clock,
	Sizes = { 8, 16, 32, 64 },
	MapSize = tonumber(process.args[1]) or 64,
	Rounds = 1,
	Deadline = os.clock() + 600,
}
