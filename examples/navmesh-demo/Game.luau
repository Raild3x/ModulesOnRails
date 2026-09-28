--!strict
-- The demo's gameplay: NPCs, the door, the balcony gate. Pure Luau (no Instances), so the Lune
-- sim and the Studio place run the same code. The Studio side only reads positions.
--
-- Everything marked HAND-ROLLED is something the game had to write on top of NavMesh; see
-- REPORT.md.

local Game = {}

export type Kind = "Wander" | "Chase" | "Patrol"

export type Npc = {
	Name: string,
	Kind: Kind,
	Radius: number,
	Speed: number,
	Filter: { [string]: any }, -- a NavMesh.QueryFilter
	Position: vector, -- feet, on the surface
	Floor: string,
	Follower: any?, -- a NavMesh.Follower
	Goal: vector?,
	Jump: { From: vector, To: vector, T: number }?, -- mid-link
	RepathIn: number, -- chaser: seconds until the next goal check
	PatrolIndex: number,
	Stats: { [string]: number },
}

export type World = {
	NavMesh: any,
	Mesh: any,
	Level: any,
	Time: number,
	Npcs: { Npc },
	DoorId: number?, -- the door's obstacle id while it is closed
	DoorTimer: number,
	GateOpen: boolean,
	GateTimer: number,
	Counters: { [string]: number },
	Timings: { [string]: { Count: number, Total: number, Max: number, Samples: { number } } },
	Log: (string) -> (),
	Rng: () -> number,
	Step: (self: World, dt: number) -> (),
}

local DOOR_PERIOD = 6 -- seconds between door toggles
local GATE_PERIOD = 15 -- seconds between balcony gate (jump link) toggles
local JUMP_TIME = 0.5
local CHASE_REPATH = 0.25 -- seconds between chaser goal checks
local CHASE_MOVED = 2 -- repath when the target moved this far from the path's goal
local STALL_STEPS = 23 -- steps without progress before a repath (0.75 s at 30 Hz)
local WANDER_RANGE = 30
local RESCUE_RADIUS = 4 -- studs: how far to look for the mesh when a door closed on an NPC
local MUD_COST = 4

-- A tiny seeded LCG in [0, 1), so runs are reproducible (FindRandomPoint takes an rng).
local function makeRng(seed: number): () -> number
	local state = seed
	return function(): number
		state = (state * 1103515245 + 12345) % 2147483648
		return state / 2147483648
	end
end

local function flatDistance(a: vector, b: vector): number
	local d = b - a
	return math.sqrt(d.X * d.X + d.Z * d.Z)
end

local function fmt(p: vector): string
	return string.format("(%.1f, %.1f, %.1f)", p.X, p.Y, p.Z)
end

-- HAND-ROLLED: per-call timing, the game needs to know what each query costs.
local function timed<A..., R...>(world: World, name: string, fn: (A...) -> R..., ...: A...): R...
	local t0 = os.clock()
	local function finish(...: R...): R...
		local ms = (os.clock() - t0) * 1000
		local row = world.Timings[name]
		if row == nil then
			row = { Count = 0, Total = 0, Max = 0, Samples = {} }
			world.Timings[name] = row
		end
		row.Count += 1
		row.Total += ms
		row.Max = math.max(row.Max, ms)
		table.insert(row.Samples, ms)
		return ...
	end
	return finish(fn(...))
end

local function count(world: World, npc: Npc?, key: string)
	world.Counters[key] = (world.Counters[key] or 0) + 1
	if npc then
		npc.Stats[key] = (npc.Stats[key] or 0) + 1
	end
end

local function log(world: World, text: string)
	world.Log(string.format("[%6.2fs] %s", world.Time, text))
end

-- Asks for a path and deals with every status. Returns whether the NPC has something to walk.
local function repath(world: World, npc: Npc, goal: vector, why: string): boolean
	local NavMesh = world.NavMesh
	local path = timed(world, "FindPath", NavMesh.FindPath, world.Mesh, npc.Position, goal, npc.Filter)
	count(world, npc, "repath:" .. why)
	count(world, npc, "status:" .. path.Status)
	npc.Goal = goal
	if path.Status == "NoStart" then
		-- The NPC is off the mesh (a door closed on it): step back onto the nearest floor.
		local rescue = NavMesh.FindNearestPoint(world.Mesh, npc.Position, npc.Filter, RESCUE_RADIUS)
		log(
			world,
			`{npc.Name}: NoStart at {fmt(npc.Position)}, moved to {rescue and fmt(rescue.Position) or "nowhere"}`
		)
		if rescue then
			npc.Position, npc.Floor = rescue.Position :: any, rescue.Floor
		end
		npc.Follower = nil
		return false
	elseif path.Status ~= "Success" then
		log(
			world,
			`{npc.Name}: {path.Status} towards {fmt(goal)} ({why}), walking to {fmt(
				path.Waypoints[#path.Waypoints].Position :: any
			)}`
		)
	end
	npc.Follower = NavMesh.NewFollower(path, STALL_STEPS)
	return #path.Waypoints >= 2
end

-- A point within a stroll where the NPC fits (FindRandomPoint honours AgentRadius).
local function pickWanderGoal(world: World, npc: Npc): vector?
	local point = timed(
		world,
		"FindRandomPoint",
		world.NavMesh.FindRandomPoint,
		world.Mesh,
		{ Filter = npc.Filter, Center = npc.Position, Radius = WANDER_RANGE, Rng = world.Rng }
	)
	return point and point.Position :: any
end

-- The patrol route the chased target runs: up the ramp, along the balcony, down the jump into
-- the east room, back out through the door, across the mud and round again.
local PATROL = {
	vector.create(5, 0, 5),
	vector.create(26, 3, 37),
	vector.create(48, 6, 37),
	vector.create(56, 0, 30),
	vector.create(55, 0, 4),
	vector.create(30, 0, 14),
	vector.create(4, 0, 30),
}

local function newGoal(world: World, npc: Npc, why: string)
	if npc.Kind == "Wander" then
		local goal = pickWanderGoal(world, npc)
		if goal then
			repath(world, npc, goal, why)
		end
	elseif npc.Kind == "Patrol" then
		npc.PatrolIndex = npc.PatrolIndex % #PATROL + 1
		repath(world, npc, PATROL[npc.PatrolIndex], why)
	end
end
-- Walks the path with NavMesh.Advance, and takes links labelled "Jump" as a timed hop.
local function follow(world: World, npc: Npc, dt: number)
	local NavMesh = world.NavMesh
	local jump = npc.Jump
	if jump then
		jump.T += dt / JUMP_TIME
		local t = math.min(jump.T, 1)
		local arc = 4 * t * (1 - t) * 2 -- a 2-stud hop over the straight line
		npc.Position = jump.From + (jump.To - jump.From) * t + vector.create(0, arc, 0)
		if t >= 1 then
			npc.Jump = nil
			local landed = NavMesh.FindNearestPoint(world.Mesh, jump.To, npc.Filter)
			if landed then
				npc.Position, npc.Floor = landed.Position :: any, landed.Floor
			end
			count(world, npc, "jumps")
		end
		return
	end

	local follower = npc.Follower
	if follower == nil then
		return
	end
	local position, floor, event =
		timed(world, "Advance", NavMesh.Advance, world.Mesh, follower, npc.Position, npc.Speed * dt, npc.Filter)
	npc.Position, npc.Floor = position :: any, floor or npc.Floor
	if event == "Arrived" then
		npc.Follower = nil
	elseif event == "Link" then
		-- The follower stops at the link's start: hop it.
		log(world, `{npc.Name}: jumps {fmt(follower.Link.From)} -> {fmt(follower.Link.To)}`)
		npc.Jump = { From = npc.Position, To = follower.Link.To, T = 0 }
	elseif event == "Blocked" then
		-- Stalled against something, or off the mesh (a door closed on it).
		count(world, npc, if floor then "stuck" else "move:off-mesh")
		log(world, `{npc.Name}: blocked at {fmt(npc.Position)}, repathing`)
		if not (npc.Goal and repath(world, npc, npc.Goal, "stuck")) then
			npc.Follower = nil
		end
	end
end

local function chase(world: World, npc: Npc, target: Npc, dt: number)
	local NavMesh = world.NavMesh
	npc.RepathIn -= dt
	if npc.Jump or npc.RepathIn > 0 then
		return
	end
	npc.RepathIn = CHASE_REPATH
	-- Line of sight over the surface: walk straight at it (Raycast is a point, not a radius).
	local blocked = timed(world, "Raycast", NavMesh.Raycast, world.Mesh, npc.Position, target.Position, npc.Filter)
	if not blocked and npc.Floor == target.Floor then
		count(world, npc, "chase:direct")
		npc.Follower = NavMesh.NewFollower({
			Status = "Success",
			Waypoints = {
				{ Position = npc.Position, Floor = npc.Floor },
				{ Position = target.Position, Floor = target.Floor },
			},
			Cost = 0,
			TileStamps = {},
		}, STALL_STEPS)
		npc.Goal = target.Position
		return
	end
	local stale = npc.Follower == nil
		or npc.Goal == nil
		or flatDistance(npc.Goal :: vector, target.Position) > CHASE_MOVED
	if stale then
		repath(world, npc, target.Position, "target-moved")
	end
end

local function toggleDoor(world: World)
	local NavMesh = world.NavMesh
	if world.DoorId then
		NavMesh.RemoveObstacle(world.Mesh, world.DoorId)
		world.DoorId = nil
	else
		world.DoorId = NavMesh.AddObstacle(world.Mesh, "Ground", world.Level.DOOR)
	end
	timed(world, "Update", NavMesh.Update, world.Mesh)
	count(world, nil, if world.DoorId then "door:closed" else "door:opened")
	log(world, if world.DoorId then "door closes" else "door opens")
end

-- HAND-ROLLED: nothing tells the game which paths a change broke, so poll every NPC's path.
local function revalidate(world: World, why: string)
	for _, npc in world.Npcs do
		if npc.Follower and npc.Goal and not npc.Jump then
			local valid = timed(world, "IsPathValid", world.NavMesh.IsPathValid, world.Mesh, npc.Follower.Path)
			if not valid then
				repath(world, npc, npc.Goal, why)
			end
		end
	end
end

local function step(world: World, dt: number)
	world.Time += dt
	world.DoorTimer -= dt
	if world.DoorTimer <= 0 then
		world.DoorTimer += DOOR_PERIOD
		toggleDoor(world)
		revalidate(world, "door")
	end
	world.GateTimer -= dt
	if world.GateTimer <= 0 then
		world.GateTimer += GATE_PERIOD
		world.GateOpen = not world.GateOpen
		timed(world, "SetLinkEnabled", world.NavMesh.SetLinkEnabled, world.Mesh, 1, world.GateOpen)
		log(world, if world.GateOpen then "balcony gate opens (jump enabled)" else "balcony gate shuts (jump disabled)")
		revalidate(world, "gate")
	end

	local target = world.Npcs[1] -- the patrolling "player"
	for _, npc in world.Npcs do
		if npc.Kind == "Chase" then
			chase(world, npc, target, dt)
		elseif npc.Follower == nil and not npc.Jump then
			newGoal(world, npc, "arrived")
		end
		follow(world, npc, dt)
	end
end

local function spawn(world: World, name: string, kind: Kind, radius: number, speed: number, at: vector)
	-- GoalFallback: a chased target mid-jump is off the mesh; path to the floor under it instead.
	local filter = { AgentRadius = radius, AreaCosts = { [world.Level.MUD] = MUD_COST }, GoalFallback = true }
	local snapped = world.NavMesh.FindNearestPoint(world.Mesh, at, filter)
	assert(snapped, `{name} spawns off the mesh at {fmt(at)}`)
	table.insert(world.Npcs, {
		Name = name,
		Kind = kind,
		Radius = radius,
		Speed = speed,
		Filter = filter,
		Position = snapped.Position :: any,
		Floor = snapped.Floor,
		Follower = nil,
		Goal = nil,
		Jump = nil,
		RepathIn = 0,
		PatrolIndex = 1,
		Stats = {},
	})
end

--[=[
	Starts a world on an already built (or deserialized) mesh. `log` receives event lines.
]=]
function Game.new(NavMesh: any, mesh: any, Level: any, seed: number, logFn: ((string) -> ())?): World
	local world: World = {
		NavMesh = NavMesh,
		Mesh = mesh,
		Level = Level,
		Time = 0,
		Npcs = {},
		DoorId = nil,
		DoorTimer = DOOR_PERIOD,
		GateOpen = true,
		GateTimer = GATE_PERIOD,
		Counters = {},
		Timings = {},
		Log = logFn or function() end,
		Rng = makeRng(seed),
		Step = function(self: World, dt: number)
			timed(self, "whole frame (7 NPCs)", step, self, dt)
		end,
	}
	spawn(world, "Runner", "Patrol", 0.5, 9, vector.create(5, 0, 5))
	spawn(world, "Chaser", "Chase", 1, 7, vector.create(30, 0, 30))
	spawn(world, "Small1", "Wander", 0.5, 8, vector.create(8, 0, 2))
	spawn(world, "Small2", "Wander", 0.5, 8, vector.create(35, 0, 12))
	spawn(world, "Small3", "Wander", 0.5, 8, vector.create(50, 0, 30))
	spawn(world, "Big1", "Wander", 1.5, 5, vector.create(20, 0, 12))
	spawn(world, "Big2", "Wander", 1.5, 5, vector.create(55, 0, 20))
	return world
end

local function percentile(samples: { number }, p: number): number
	local sorted = table.clone(samples)
	table.sort(sorted)
	return sorted[math.clamp(math.ceil(#sorted * p), 1, #sorted)]
end

local function sortedKeys(t: { [string]: any }): { string }
	local keys = {}
	for key in t do
		table.insert(keys, key)
	end
	table.sort(keys)
	return keys
end

--[=[
	Prints each NPC's tallies, the world counters and the per-call timings.
]=]
function Game.Report(world: World, out: (string) -> ())
	out("\n-- NPCs")
	for _, npc in world.Npcs do
		local parts = {}
		for _, key in sortedKeys(npc.Stats) do
			table.insert(parts, `{key}={npc.Stats[key]}`)
		end
		out(
			string.format(
				"%-7s r=%.1f %-6s at %s on %-7s %s",
				npc.Name,
				npc.Radius,
				npc.Kind,
				fmt(npc.Position),
				npc.Floor,
				table.concat(parts, " ")
			)
		)
	end
	out("\n-- counters")
	for _, key in sortedKeys(world.Counters) do
		out(string.format("%-28s %d", key, world.Counters[key]))
	end
	out("\n-- timings (ms)")
	out(string.format("%-22s %7s %8s %8s %8s %8s", "call", "count", "mean", "p50", "p95", "max"))
	for _, name in sortedKeys(world.Timings) do
		local row = world.Timings[name]
		out(
			string.format(
				"%-22s %7d %8.4f %8.4f %8.4f %8.4f",
				name,
				row.Count,
				row.Total / row.Count,
				percentile(row.Samples, 0.5),
				percentile(row.Samples, 0.95),
				row.Max
			)
		)
	end
end

Game.DT = 1 / 30
Game.Fmt = fmt

return Game
