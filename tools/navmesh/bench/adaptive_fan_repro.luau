--!strict
-- Repro: Highlands' adaptive ground stitched with fans (Terrain.Adaptive's `fan`: a cell with
-- smaller neighbours is a fan from its middle) makes the adapter join walkable rings that fold
-- back on themselves (a slit round a fan's middle, by the isthmus and by an outcrop's cut), which
-- NavMesh.Build rejects. Snap stitching, the default, builds. A small fan alone builds too: it
-- takes Highlands' cuts (the water, the outcrops) as well.
--   lune run tools/navmesh/bench/adaptive_fan_repro.luau
local roblox = require("@lune/roblox") :: any
local NavMesh = require("../../../lib/navmesh/src/NavMesh")
local Adapter = require("../../../lib/navmeshadapter/src/NavMeshAdapter")
local Highlands = require("../maps/Maps/Highlands") :: any

for _, fan in { false, true } do
	Highlands.Stitch.Fan = fan
	local built = Highlands.Build(roblox)
	local ok, err = pcall(function()
		local desc = Adapter.FromParts(built.Walkable, built.Obstacles, Highlands.AdapterOptions) :: any
		desc.MaxAgentRadius = 2
		NavMesh.Build(desc)
	end)
	print(
		if fan then "fan " else "snap",
		#built.Walkable,
		"Parts:",
		if ok then "builds" else tostring(err):match("[^\n]*")
	)
end
