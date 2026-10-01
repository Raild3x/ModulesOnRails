--!strict
-- Bakes the warehouse: LevelParts -> NavMeshAdapter.FromParts -> Build -> Serialize, written as
-- base64 chunks to NavMeshBake/1.txt, 2.txt, ... (Rojo turns each into a StringValue; sim.luau reads the
-- files). Doors and crates are dynamic and stay out of the bake.
--   lune run examples/navmesh-demo2/bake.luau
local fs = require("@lune/fs")
local roblox = require("@lune/roblox") :: any
local NavMesh = require("../../lib/navmesh/src/NavMesh")
local Adapter = require("../../lib/navmeshadapter/src/NavMeshAdapter")
local BakeText = require("./BakeText")
local LevelParts = require("./LevelParts")

local DIR = "examples/navmesh-demo2/NavMeshBake"

local walkable, obstacles = LevelParts(roblox)
local t0 = os.clock()
local desc = Adapter.FromParts(walkable, obstacles)
local adaptMs = (os.clock() - t0) * 1000
desc.MaxAgentRadius = 2 -- the widest agent in Game.luau
t0 = os.clock()
local mesh = NavMesh.Build(desc)
local buildMs = (os.clock() - t0) * 1000
local data = NavMesh.Serialize(mesh)
local text = BakeText.Encode(data)
assert(buffer.tostring(BakeText.Load { text }) == buffer.tostring(data), "base64 round trip")

if fs.isDir(DIR) then
	fs.removeDir(DIR)
end
fs.writeDir(DIR)
local chunks = 0
for i = 1, #text, BakeText.CHUNK do
	chunks += 1
	fs.writeFile(`{DIR}/{chunks}.txt`, string.sub(text, i, i + BakeText.CHUNK - 1))
end
print(
	string.format(
		"FromParts %.2f ms, Build %.2f ms; bake %d bytes, %d base64 chars in %d chunk(s)",
		adaptMs,
		buildMs,
		buffer.len(data),
		#text,
		chunks
	)
)
