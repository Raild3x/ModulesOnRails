-- Quick interpreted gauge of the TileSize benchmark (the decision uses the Studio run).
--   lune run tools/navmesh/bench/tilesize_lune.luau [scene]
local process = require("@lune/process")
local NavMesh = require("../../../lib/navmesh/src/NavMesh")
local scenes = {}
for _, scene in require("./Scenes") do
	if process.args[1] == nil or process.args[1] == scene.Name then
		table.insert(scenes, scene)
	end
end
require("./TileSize").Run {
	NavMesh = NavMesh,
	Clock = os.clock,
	Yield = function() end,
	Scenes = scenes,
	Rounds = 1,
	Deadline = os.clock() + 1200,
}
