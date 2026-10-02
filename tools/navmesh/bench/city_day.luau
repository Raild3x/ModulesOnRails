--!strict
-- Ticket 38: a seeded crowd's day on the City map (tools/navmesh/maps/Maps/City.luau), the
-- regression bench for realistic content. One command:
--   lune run tools/navmesh/bench/city_day.luau [seed=1] [count=60]
-- Builds the map (Build ms, bake, Deserialize ms, counts), then runs ElevatorSim's crowd on the
-- deserialized mesh: each NPC leaves home on the upper floor, walks to a spot outdoors and comes
-- home, by stairs or elevator, a crosswalk (the road costs 10), and the bridge or the ford.
-- Events: a crate dropped on the sidewalk, the door closing and reopening, the elevator out of
-- service and back (ticket 35's policy: broadcast, hysteresis 15%), the crate taken away. Each
-- obstacle event runs NavMesh.Update and re-plans the walkers whose path ahead it touches.
-- Exits 1 if an NPC that can walk doesn't get home, or anyone sets foot in the river.
local process = require("@lune/process")
local roblox = require("@lune/roblox") :: any
local NavMesh = require("../../../lib/navmesh/src/NavMesh")
local Adapter = require("../../../lib/navmeshadapter/src/NavMeshAdapter")
local Building = require("../maps/Building")
local City = require("../maps/Maps/City") :: any
local Sim = require("../maps/ElevatorSim")

local SEED = tonumber(process.args[1]) or 1
local COUNT = tonumber(process.args[2]) or 60
local DT, LIMIT = 0.1, 600
local FORD = 7
local OX, OZ = City.Offset[1], City.Offset[3]

local function median(xs: { number }): number
	local s = table.clone(xs)
	table.sort(s)
	return s[(#s + 1) // 2]
end
local function p95(xs: { number }): number
	local s = table.clone(xs)
	table.sort(s)
	return s[math.max(1, math.ceil(#s * 0.95))]
end
local function v(x: number, y: number, z: number): any
	return vector.create(x, y, z)
end
local function box(x0: number, z0: number, x1: number, z1: number): { any }
	return { v(x0, 0, z0), v(x1, 0, z0), v(x1, 0, z1), v(x0, 0, z1) }
end

-- The map.
local built = City.Build(roblox)
local t0 = os.clock()
local desc, areas = Adapter.FromParts(built.Walkable, built.Obstacles, City.AdapterOptions)
local fromPartsMs = (os.clock() - t0) * 1000
local d = desc :: any
d.MaxAgentRadius = City.MaxAgentRadius
d.Links = built.Links
t0 = os.clock()
local built0 = NavMesh.Build(d)
local buildMs = (os.clock() - t0) * 1000
local bake = NavMesh.Serialize(built0)
t0 = os.clock()
local mesh = NavMesh.Deserialize(bake)
local loadMs = (os.clock() - t0) * 1000
local floors = 0
for _ in d.Floors do
	floors += 1
end

-- The crowd: homes on the upper floor, destinations outdoors (south of the sidewalk).
math.randomseed(SEED)
local rng = function(): number
	return math.random()
end
-- Homes on the upper floor, room for the widest NPC (radius 2).
local homes = {}
while #homes < COUNT do
	local p = NavMesh.FindRandomPoint(mesh, { Filter = { AgentRadius = 2 }, Rng = rng })
	if p and p.Floor == "Upper" then
		table.insert(homes, p.Position)
	end
end
-- A spot outdoors (south of the sidewalk) this NPC can reach from home: a random point clear
-- for its radius can still sit in a pocket between trees it can't enter.
local function destination(home: Vector3, filter: any): Vector3
	while true do
		local p = NavMesh.FindRandomPoint(mesh, { Filter = filter, Rng = rng })
		if p and p.Position.Z < -56 and NavMesh.FindPath(mesh, home, p.Position, filter).Status == "Success" then
			return p.Position
		end
	end
end
local KINDS = {
	{ Kind = "Walker", Share = 0.5, Stairs = 1, Ford = 1 },
	{ Kind = "Tired", Share = 0.35, Stairs = 5, Ford = 50 },
	{ Kind = "Wheelchair", Share = 0.15, Stairs = math.huge, Ford = math.huge },
}
local RADII = { 0.5, 1, 1, 1.5, 2 }
local crowd = {}
for i = 1, COUNT do
	local r, kind = math.random(), KINDS[#KINDS]
	local acc = 0
	for _, k in KINDS do
		acc += k.Share
		if r < acc then
			kind = k
			break
		end
	end
	local home, radius = homes[i], RADII[math.random(#RADII)]
	local costs = { [areas.Road] = 10, [FORD] = kind.Ford }
	local reach = { AgentRadius = radius, AreaCosts = table.clone(costs) }
	reach.AreaCosts[Building.STAIRS_AREA] = kind.Stairs
	table.insert(crowd, {
		Kind = kind.Kind,
		Stairs = kind.Stairs,
		Radius = radius,
		Costs = costs,
		Spawn = math.random() * 30,
		From = home,
		Legs = { destination(home, reach), home },
	})
end

NavMesh.SetLinkEnabled(mesh, 1, true)
local sim = Sim.new {
	NavMesh = NavMesh,
	Mesh = mesh,
	ElevatorArea = Building.ELEVATOR_AREA,
	StairsArea = Building.STAIRS_AREA,
	Policy = "hysteresis",
	Seed = SEED,
	Enabled = true,
	Crowd = crowd,
}

-- The events, at their times.
local log = {}
local function reroutes(): number
	local n = 0
	for _, npc in sim.Npcs do
		n += npc.Reroutes
	end
	return n
end
local function obstacleEvent(name: string, change: () -> ())
	local before = reroutes()
	local s = os.clock()
	change()
	local regions = NavMesh.Update(mesh)
	local updateMs = (os.clock() - s) * 1000
	local repaths = sim.Changed(regions)
	table.insert(log, { name, sim.Time, updateMs, #regions, repaths, reroutes() - before })
end
local function elevatorEvent(name: string, enabled: boolean)
	local before = reroutes()
	local s = os.clock()
	NavMesh.SetLinkEnabled(mesh, 1, enabled)
	sim.SetEnabled(enabled)
	table.insert(log, { name, sim.Time, (os.clock() - s) * 1000, 0, 0, reroutes() - before })
end
local crate, door
local EVENTS = {
	{
		20,
		function()
			obstacleEvent("crate dropped on the sidewalk", function()
				crate = NavMesh.AddObstacle(mesh, "Ground", box(-1, -46, 5, -42))
			end)
		end,
	},
	{
		35,
		function()
			obstacleEvent("door closes", function()
				door = NavMesh.AddObstacle(mesh, "Ground", box(25, -1.5, 35, 0.5))
			end)
		end,
	},
	{
		50,
		function()
			obstacleEvent("door opens", function()
				NavMesh.RemoveObstacle(mesh, door)
			end)
		end,
	},
	{
		60,
		function()
			elevatorEvent("elevator out of service", false)
		end,
	},
	{
		90,
		function()
			elevatorEvent("elevator back in service", true)
		end,
	},
	{
		100,
		function()
			obstacleEvent("crate taken away", function()
				NavMesh.RemoveObstacle(mesh, crate)
			end)
		end,
	},
}

-- The day.
local wet, nextEvent = 0, 1
local wall = os.clock()
while sim.Time < LIMIT and not (nextEvent > #EVENTS and sim.Finished()) do
	while EVENTS[nextEvent] and sim.Time >= EVENTS[nextEvent][1] do
		EVENTS[nextEvent][2]()
		nextEvent += 1
	end
	sim.Step(DT)
	for _, npc in sim.Npcs do
		local p = npc.Position
		local x, z = p.X - OX, p.Z - OZ -- in ForestRiver's own frame
		if x > 94.2 and x < 105.8 and z > 0 and z < 160 and (z < 110 or z > 125) and p.Y < 2 then
			wet += 1
		end
	end
end
local wallS = os.clock() - wall

-- The report.
print(
	`City day: seed {SEED}, {COUNT} NPCs, dt {DT} s, {string.format("%.0f", sim.Time)} s simulated in {string.format(
		"%.1f",
		wallS
	)} s`
)
print(
	string.format(
		"FromParts %.0f ms, Build %.0f ms, Deserialize %.1f ms; bake %d bytes; %d triangles, %d floors, %d seams",
		fromPartsMs,
		buildMs,
		loadMs,
		buffer.len(bake),
		built0.TriangleCount,
		floors,
		#d.Seams
	)
)
print(
	string.format(
		"FindPath: %d calls, median %.3f ms, p95 %.3f ms",
		#sim.FindPathTimes,
		median(sim.FindPathTimes),
		p95(sim.FindPathTimes)
	)
)
print("| t s | event | Update ms | regions | re-planned (path touched) | reroutes |")
print("|---|---|---|---|---|---|")
for _, e in log do
	print(string.format("| %.1f | %s | %.2f | %d | %d | %d |", e[2], e[1], e[3], e[4], e[5], e[6]))
end
local byKind = {}
local failed = 0
for _, npc in sim.Npcs do
	local k = byKind[npc.Kind] or { n = 0, done = 0, trips = {}, rides = 0, reroutes = 0 }
	byKind[npc.Kind] = k
	k.n += 1
	k.reroutes += npc.Reroutes
	k.rides += if npc.UsedElevator then 1 else 0
	if npc.State == "done" then
		k.done += 1
		table.insert(k.trips, (npc.Done :: number) - npc.Spawn)
	elseif npc.Stairs < math.huge then
		failed += 1
	end
end
print("| kind | NPCs | home | median day s | rode the elevator | reroutes |")
print("|---|---|---|---|---|---|")
for _, kind in KINDS do
	local k = byKind[kind.Kind]
	if k then
		print(
			string.format(
				"| %s | %d | %d | %.1f | %d | %d |",
				kind.Kind,
				k.n,
				k.done,
				if #k.trips > 0 then median(k.trips) else 0,
				k.rides,
				k.reroutes
			)
		)
	end
end
for _, npc in sim.Npcs do
	if npc.State ~= "done" and npc.Stairs < math.huge then
		local f = npc.Follower
		local p, g = npc.Position, npc.Goal
		print(
			string.format(
				"not home: NPC %d %s r %.1f, %s on %s at (%.1f, %.1f, %.1f), leg %d, goal (%.1f, %.1f, %.1f), path %s",
				npc.Id,
				npc.Kind,
				npc.Radius or 1,
				npc.State,
				tostring(npc.Floor),
				p.X,
				p.Y,
				p.Z,
				npc.Leg or 0,
				g.X,
				g.Y,
				g.Z,
				if f then f.Path.Status else "-"
			)
		)
	end
end
print(`water: {wet} NPC-steps in the river`)
local ok = failed == 0 and wet == 0
print(if ok then "CITY DAY PASS" else `CITY DAY FAIL ({failed} walkers not home, {wet} wet steps)`)
process.exit(if ok then 0 else 1)
