-- Runs an A/B experiment under Lune: a quick correctness check and interpreted gauge. The
-- decision uses ab.py (Studio, native).
--   lune run tools/navmesh/bench/ab_lune.luau <experiment> [rounds]
local fs = require("@lune/fs")
local process = require("@lune/process")

local dynRequire: any = require
local variants = {}
for _, entry in fs.readDir("tools/navmesh/bench/variants") do
	local stem = entry:match("^(.+)%.luau$")
	if stem then
		variants[stem] = dynRequire("./variants/" .. stem)
	elseif fs.isDir("tools/navmesh/bench/variants/" .. entry) then
		variants[entry] = dynRequire("./variants/" .. entry .. "/ConstrainedDelaunay")
	end
end

dynRequire("./ab/" .. assert(process.args[1], "usage: ab_lune.luau <experiment> [rounds]")) {
	NavMesh = require("../../../lib/navmesh/src/NavMesh"),
	Quantize = require("../../../lib/navmesh/src/Quantize"),
	NavMeshStorage = require("../../../lib/navmesh/src/Storage"),
	Heap = require("../../../lib/heap/src"),
	NavMeshOpenList = require("../../../lib/navmesh/src/OpenList"),
	CDT = require("../../../lib/navmesh/ConstrainedDelaunay"),
	TileSize = require("./TileSize"),
	Scenes = require("./Scenes"),
	OpenLists = require("./OpenLists"),
	AB = require("./AB"),
	Variants = variants,
	Rounds = tonumber(process.args[2]) or 1,
	Clock = os.clock,
	Yield = function() end,
	Deadline = os.clock() + 1800,
	NarrowRegion = process.env.NARROW_REGION == "1",
}
