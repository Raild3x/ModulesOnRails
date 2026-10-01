--!strict
-- Headless run of the warehouse: loads the bake (NavMeshBake/*.txt, the shipping recipe's text),
-- runs the game for N ticks at 30 Hz and prints counters and per-call timings.
--   lune run examples/navmesh-demo2/sim.luau [ticks=1800] [seed=7] [scale=1]
local fs = require("@lune/fs")
local process = require("@lune/process")
local roblox = require("@lune/roblox") :: any
local NavMesh = require("../../lib/navmesh/src/NavMesh")
local BakeText = require("./BakeText")
local Game = require("./Game")
local LevelParts = require("./LevelParts")

local ticks = tonumber(process.args[1]) or 1800
local seed = tonumber(process.args[2]) or 7
local scale = tonumber(process.args[3]) or 1

local chunks = {}
local dir = "examples/navmesh-demo2/NavMeshBake"
for i = 1, #fs.readDir(dir) do
	table.insert(chunks, fs.readFile(`{dir}/{i}.txt`))
end
local t0 = os.clock()
local data = BakeText.Load(chunks)
local decodeMs = (os.clock() - t0) * 1000
t0 = os.clock()
local mesh = NavMesh.Deserialize(data)
local loadMs = (os.clock() - t0) * 1000

local _, _, doors, crates = LevelParts(roblox)
local world = Game.new(NavMesh, mesh, doors, crates, seed, scale)
for _ = 1, ticks do
	world:Step(Game.DT)
end
print(
	string.format(
		"== %d ticks (%.0f s), seed %d, %d agents; bake %d bytes, base64 decode %.2f ms, Deserialize %.2f ms",
		ticks,
		ticks * Game.DT,
		seed,
		#world.Npcs,
		buffer.len(data),
		decodeMs,
		loadMs
	)
)
Game.Report(world, print)
