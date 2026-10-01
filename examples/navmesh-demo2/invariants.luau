--!strict
-- Runs the game and checks every agent after every tick: on the mesh, and at least its radius
-- (less 0.05) from the nearest wall. Prints the violations (REPORT.md, "What worked well").
--   lune run examples/navmesh-demo2/invariants.luau [ticks=1800] [seed=7]
local fs = require("@lune/fs")
local process = require("@lune/process")
local roblox = require("@lune/roblox") :: any
local NavMesh = require("../../lib/navmesh/src/NavMesh")
local BakeText = require("./BakeText")
local Game = require("./Game")
local LevelParts = require("./LevelParts")

local ticks = tonumber(process.args[1]) or 1800
local seed = tonumber(process.args[2]) or 7
local mesh = NavMesh.Deserialize(BakeText.Load { fs.readFile("examples/navmesh-demo2/NavMeshBake/1.txt") })
local _, _, doors, crates = LevelParts(roblox)
local world = Game.new(NavMesh, mesh, doors, crates, seed, 1)
local checked, off, tight = 0, 0, 0
for _ = 1, ticks do
	world:Step(Game.DT)
	for _, npc in world.Npcs do
		checked += 1
		if NavMesh.FindNearestPoint(mesh, npc.Position) == nil then
			off += 1
		elseif NavMesh.FindDistanceToWall(mesh, npc.Position, 5) < npc.Radius - 0.05 then
			tight += 1
		end
	end
end
print(
	string.format(
		"%d agent-ticks checked: %d off the mesh, %d closer to a wall than radius - 0.05",
		checked,
		off,
		tight
	)
)
