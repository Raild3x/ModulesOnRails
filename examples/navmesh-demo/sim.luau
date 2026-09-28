--!strict
-- Headless run of the demo: loads the baked mesh, runs the NPCs for N ticks at 30 Hz and
-- prints what happened and what each NavMesh call cost.
--   lune run examples/navmesh-demo/sim.luau [ticks=3600] [seed=7] [--quiet]
local process = require("@lune/process")
local NavMesh = require("../../lib/navmesh/src/NavMesh")
local Baked = require("./Baked")
local Game = require("./Game")
local Level = require("./Level")

local ticks = tonumber(process.args[1]) or 3600
local seed = tonumber(process.args[2]) or 7
local quiet = table.find(process.args, "--quiet") ~= nil

local t0 = os.clock()
local mesh = NavMesh.Deserialize(buffer.fromstring(Baked))
local loadMs = (os.clock() - t0) * 1000

local world = Game.new(NavMesh, mesh, Level, seed, if quiet then nil else print)
for _ = 1, ticks do
	world:Step(Game.DT)
end

print(
	string.format(
		"\n== %d ticks (%.0f s of game time), seed %d; Deserialize %.2f ms",
		ticks,
		ticks * Game.DT,
		seed,
		loadMs
	)
)
Game.Report(world, print)
