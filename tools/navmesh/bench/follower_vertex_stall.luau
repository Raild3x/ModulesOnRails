--!strict
-- Repro (Track M2, ticket 38): on the City map, a walker 0.2 studs from a meadow vertex where
-- several triangle floors meet never arrives. FindPath starts the path on Meadow6_9a, on the line
-- z = -110, and routes it through the vertex (40, -110); the NPC stands just north of that line on
-- Meadow6_10a. Advance moves it on Meadow6_10a and it stops at (41.21, -109.79): Blocked, and a
-- re-plan from there gives the same path, so a game re-planning on Blocked loops forever.
-- The same walk on ForestRiver alone (no -20, -210 shift, so different f32 rounding) arrives.
--   lune run tools/navmesh/bench/follower_vertex_stall.luau
-- Expected: Arrived. Today: Blocked.
local roblox = require("@lune/roblox") :: any
local NavMesh = require("../../../lib/navmesh/src/NavMesh")
local Adapter = require("../../../lib/navmeshadapter/src/NavMeshAdapter")
local City = require("../maps/Maps/City") :: any

local built = City.Build(roblox)
local desc = Adapter.FromParts(built.Walkable, built.Obstacles, City.AdapterOptions) :: any
desc.MaxAgentRadius = City.MaxAgentRadius
desc.Links = built.Links
local mesh = NavMesh.Build(desc)

local function show(p: any): string
	return string.format("(%.2f, %.2f, %.2f)", p.X, p.Y, p.Z)
end
local from, to = vector.create(41.2, -0.4, -109.8), vector.create(40.6, -0.4, -113.7)
local filter = { AgentRadius = 1 }
local path = NavMesh.FindPath(mesh, from, to, filter)
for i, w in path.Waypoints do
	print(`waypoint {i}: {w.Floor} {show(w.Position)}`)
end
local follower = NavMesh.NewFollower(path)
local position, floor, event = from, nil, nil
for _ = 1, 100 do
	position, floor, event = NavMesh.Advance(mesh, follower, position, 1.6, filter)
	if event == "Arrived" or event == "Blocked" then
		break
	end
end
print(`{event} on {floor} at {show(position)}`)
