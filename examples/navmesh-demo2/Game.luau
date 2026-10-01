--!strict
-- The warehouse game: a "player" runs between random points, 24 chasers of radius 0.5-2 hunt it,
-- 11 wanderers stroll, six doors open and close, and eight crates slide back and forth in 2-stud
-- hops. Pure Luau over the level's Parts (no Instances created), so the Lune sim and the Studio
-- place run the same code; the Studio side only reads positions.
--
-- Code between a "glue:<what>" start marker and its end marker is what the game had to write on
-- top of NavMesh (counted in REPORT.md).

local Game = {}

export type Npc = {
	Name: string,
	Kind: "Player" | "Chaser" | "Wanderer",
	Radius: number,
	Speed: number,
	Filter: { [string]: any }, -- a NavMesh.QueryFilter
	Position: vector,
	Floor: string,
	Follower: any?, -- a NavMesh.Follower
	Goal: vector?,
	CaughtAt: number,
}

type Dynamic = { Part: any, Floor: string, Id: number?, Timer: number, T: number, Dir: number, From: any, To: any }

local N_CHASERS, N_WANDERERS = 24, 11
local RADII = { 0.5, 1, 1.5, 2 }
local DOOR_PERIOD = 5 -- seconds each door stays open or shut (staggered)
local CRATE_HOP, CRATE_PERIOD = 2, 1 -- a crate moves 2 studs every second (staggered)
local CHASE_MOVED = 6 -- a chaser replans once the player is this far from its path's goal
local REPLANS_PER_TICK = 4 -- chaser replans per tick (round robin)
local STALL_STEPS = 15
local RESCUE_RADIUS = 6

local function makeRng(seed: number): () -> number
	local state = seed
	return function(): number
		state = (state * 1103515245 + 12345) % 2147483648
		return state / 2147483648
	end
end

local function v(p: any): vector
	return vector.create(p.X, p.Y, p.Z)
end

local function flat(a: vector, b: vector): number
	return math.sqrt((a.X - b.X) ^ 2 + (a.Z - b.Z) ^ 2)
end

-- Timing and counters (instrumentation, not glue).
local function timed<A..., R...>(world: any, name: string, fn: (A...) -> R..., ...: A...): R...
	local t0 = os.clock()
	local function finish(...: R...): R...
		local samples = world.Timings[name]
		if samples == nil then
			samples = {}
			world.Timings[name] = samples
		end
		table.insert(samples, (os.clock() - t0) * 1000)
		return ...
	end
	return finish(fn(...))
end

local function count(world: any, key: string, n: number?)
	world.Counters[key] = (world.Counters[key] or 0) + (n or 1)
end

--> glue:dynamic
-- A Part's footprint as an obstacle ring (the adapter converts a whole level once; one Part at
-- runtime is up to the game), and the floor it stands on.
local function footprint(part: any): { vector }
	local x, y, z, r00, r01, r02, r10, r11, r12, r20, r21, r22 = part.CFrame:GetComponents()
	local hx, hy, hz = part.Size.X / 2, -part.Size.Y / 2, part.Size.Z / 2
	local ring = {}
	for _, c in { { -hx, -hz }, { hx, -hz }, { hx, hz }, { -hx, hz } } do
		local px, pz = c[1], c[2]
		table.insert(
			ring,
			vector.create(
				x + r00 * px + r01 * hy + r02 * pz,
				y + r10 * px + r11 * hy + r12 * pz,
				z + r20 * px + r21 * hy + r22 * pz
			)
		)
	end
	return ring
end

local function dynamic(world: any, part: any, from: any?, to: any?, phase: number): Dynamic
	local base = v(part.CFrame.Position) - vector.create(0, part.Size.Y / 2, 0)
	local on = world.NavMesh.FindNearestPoint(world.Mesh, base)
	assert(on, `{part.Name} at {base} is not over a floor`)
	return { Part = part, Floor = on.Floor, Id = nil, Timer = phase, T = 0, Dir = 1, From = from, To = to }
end

local function place(world: any, d: Dynamic)
	if d.Id then
		world.NavMesh.RemoveObstacle(world.Mesh, d.Id)
	end
	local ring = footprint(d.Part)
	d.Id = world.NavMesh.AddObstacle(world.Mesh, d.Floor, ring)
	table.insert(
		world.Added,
		{ Floor = d.Floor, Min = vector.min(ring[1], ring[3]), Max = vector.max(ring[1], ring[3]) }
	)
end
--< glue

local function stepDoors(world: any, dt: number)
	for _, door in world.Doors do
		door.Timer -= dt
		if door.Timer > 0 then
			continue
		end
		door.Timer += DOOR_PERIOD
		if door.Id then
			world.NavMesh.RemoveObstacle(world.Mesh, door.Id)
			door.Id = nil
			world.Opened = true
			count(world, "door:open")
		else
			place(world, door)
			count(world, "door:shut")
		end
	end
end

local function stepCrates(world: any, dt: number)
	for _, crate in world.Crates do
		crate.Timer -= dt
		if crate.Timer > 0 then
			continue
		end
		crate.Timer += CRATE_PERIOD
		local length = (crate.To - crate.From).Magnitude
		crate.T += crate.Dir * CRATE_HOP / length
		if crate.T >= 1 or crate.T <= 0 then
			crate.T, crate.Dir = math.clamp(crate.T, 0, 1), -crate.Dir
		end
		local part = crate.Part
		part.CFrame += crate.From:Lerp(crate.To, crate.T) - (part.CFrame.Position - part.CFrame.UpVector * (part.Size.Y / 2))
		place(world, crate)
		count(world, "crate:hop")
	end
end

--> glue:rescue
-- Off the mesh (a door or a crate landed on it): step back onto the nearest floor. FindPath says
-- NoStart and Advance says Blocked with no floor; both end up here.
local function rescue(world: any, npc: Npc): boolean
	local back = timed(
		world,
		"FindNearestPoint",
		world.NavMesh.FindNearestPoint,
		world.Mesh,
		npc.Position,
		npc.Filter,
		RESCUE_RADIUS
	)
	count(world, if back then "rescued" else "lost")
	if back then
		npc.Position, npc.Floor = v(back.Position), back.Floor
	end
	return back ~= nil
end
--< glue

local function repath(world: any, npc: Npc, goal: vector, why: string)
	local path = timed(world, "FindPath", world.NavMesh.FindPath, world.Mesh, npc.Position, goal, npc.Filter)
	--> glue:rescue
	if path.Status == "NoStart" and rescue(world, npc) then
		path = timed(world, "FindPath", world.NavMesh.FindPath, world.Mesh, npc.Position, goal, npc.Filter)
	end
	--< glue
	count(world, "repath:" .. why)
	count(world, `status:{path.Status}` .. if path.Status == "Success" then "" else ` r={npc.Radius} {npc.Kind}`)
	npc.Goal = goal
	npc.Follower = if #path.Waypoints >= 2 then world.NavMesh.NewFollower(path, STALL_STEPS) else nil
end

--> glue:replan
-- Does the rest of this agent's path (from where it stands) touch a changed box on its floor,
-- fattened by its radius? Ticket 28's FirstAffectedSegment, by hand.
local function segmentHitsBox(a: vector, b: vector, lo: vector, hi: vector, r: number): boolean
	local t0, t1 = 0, 1
	for _, axis in { "X", "Z" } do
		local p, d = (a :: any)[axis], (b :: any)[axis] - (a :: any)[axis]
		local min, max = (lo :: any)[axis] - r, (hi :: any)[axis] + r
		if math.abs(d) < 1e-9 then
			if p < min or p > max then
				return false
			end
		else
			local u0, u1 = (min - p) / d, (max - p) / d
			t0, t1 = math.max(t0, math.min(u0, u1)), math.min(t1, math.max(u0, u1))
			if t0 > t1 then
				return false
			end
		end
	end
	return true
end

local function pathTouches(npc: Npc, regions: { any }): boolean
	local follower = npc.Follower
	local waypoints = follower.Path.Waypoints
	local from, floor = npc.Position, npc.Floor
	for i = follower.Next, #waypoints do
		local w = waypoints[i]
		for _, region in regions do
			if
				(region.Floor == floor or region.Floor == w.Floor)
				and segmentHitsBox(from, v(w.Position), v(region.Min), v(region.Max), npc.Radius)
			then
				return true
			end
		end
		from, floor = v(w.Position), w.Floor
	end
	return false
end

-- After an Update: replan agents whose way ahead changed, and Partial paths when a door opened
-- (the regions only promise "unaffected" for adds, and do not say which boxes opened).
local function replanAfterUpdate(world: any, regions: { any }, opened: boolean)
	for _, npc in world.Npcs do
		if npc.Follower == nil or npc.Goal == nil then
			continue
		end
		-- For comparison: what per-tile stamps would replan, and what a box around each added
		-- footprint would (enough for "still walkable"; the regions promise "the same path").
		if not world.NavMesh.IsPathValid(world.Mesh, npc.Follower.Path) then
			count(world, "stale:stamps")
		end
		if pathTouches(npc, world.Added) then
			count(world, "stale:footprints")
		end
		local hit = timed(world, "region test", pathTouches, npc, regions)
		if hit or (opened and npc.Follower.Path.Status ~= "Success") then
			repath(world, npc, npc.Goal :: vector, if hit then "region" else "partial")
		end
	end
end
--< glue

local function pickGoal(world: any, npc: Npc, range: number?)
	local options = { Filter = npc.Filter, Rng = world.Rng }
	if range then
		options.Center, options.Radius = npc.Position, range
	end
	local point = timed(world, "FindRandomPoint", world.NavMesh.FindRandomPoint, world.Mesh, options)
	if point then
		repath(world, npc, v(point.Position), "new-goal")
	end
end

--> glue:chase
-- Chasers replan when the player has moved CHASE_MOVED from their goal, a few per tick, round robin.
local function chase(world: any)
	local player = world.Npcs[1]
	local chasers = world.Chasers
	local budget = REPLANS_PER_TICK
	for _ = 1, #chasers do
		if budget == 0 then
			break
		end
		world.ChaseCursor = world.ChaseCursor % #chasers + 1
		local npc = chasers[world.ChaseCursor]
		if npc.Follower == nil or npc.Goal == nil or flat(npc.Goal :: vector, player.Position) > CHASE_MOVED then
			repath(world, npc, player.Position, "chase")
			budget -= 1
		end
	end
	for _, npc in chasers do
		local near = npc.Floor == player.Floor
			and flat(npc.Position, player.Position) <= npc.Radius + player.Radius + 0.5
		if near and world.Time - npc.CaughtAt > 3 then
			npc.CaughtAt = world.Time
			count(world, "caught")
		end
	end
end
--< glue

--> glue:follow
local function follow(world: any, npc: Npc, dt: number)
	local follower = npc.Follower
	if follower == nil then
		return
	end
	local NavMesh = world.NavMesh
	local position, floor, event =
		timed(world, "Advance", NavMesh.Advance, world.Mesh, follower, npc.Position, npc.Speed * dt, npc.Filter)
	npc.Position = v(position)
	npc.Floor = floor or npc.Floor
	if event == "Arrived" then
		npc.Follower = nil
		count(world, "arrived")
	elseif event == "Blocked" then
		npc.Follower = nil
		if npc.Goal then
			repath(world, npc, npc.Goal, if floor then "stalled" else "off-mesh")
		end
	end
end
--< glue

local function step(world: any, dt: number)
	world.Time += dt
	stepDoors(world, dt)
	stepCrates(world, dt)
	if world.NavMesh.HasPendingChanges(world.Mesh) then
		local regions = timed(world, "Update", world.NavMesh.Update, world.Mesh)
		count(world, "regions", #regions)
		replanAfterUpdate(world, regions, world.Opened)
		world.Opened, world.Added = false, {}
	end
	chase(world)
	for _, npc in world.Npcs do
		if npc.Follower == nil and npc.Kind ~= "Chaser" then
			pickGoal(world, npc, if npc.Kind == "Wanderer" then 60 else nil)
		end
		follow(world, npc, dt)
	end
end

local function spawn(world: any, name: string, kind: any, radius: number, speed: number)
	local filter = { AgentRadius = radius, GoalFallback = true }
	local at = world.NavMesh.FindRandomPoint(world.Mesh, { Filter = filter, Rng = world.Rng })
	local npc: Npc = {
		Name = name,
		Kind = kind,
		Radius = radius,
		Speed = speed,
		Filter = filter,
		Position = v(at.Position),
		Floor = at.Floor,
		Follower = nil,
		Goal = nil,
		CaughtAt = -math.huge,
	}
	table.insert(world.Npcs, npc)
	if kind == "Chaser" then
		table.insert(world.Chasers, npc)
	end
end

--[=[
	A world on a loaded mesh. `doors` and `crates` come from LevelParts; `scale` multiplies the
	agent counts (1 = 36 agents).
]=]
function Game.new(NavMesh: any, mesh: any, doors: { any }, crates: { any }, seed: number, scale: number?): any
	local world = {
		NavMesh = NavMesh,
		Mesh = mesh,
		Time = 0,
		Npcs = {},
		Chasers = {},
		ChaseCursor = 0,
		Opened = false, -- a door opened since the last Update
		Added = {}, -- boxes of the footprints added since the last Update (instrumentation)
		Doors = {},
		Crates = {},
		Counters = {},
		Timings = {},
		Rng = makeRng(seed),
		Step = function(self, dt: number)
			timed(self, "whole tick", step, self, dt)
		end,
	}
	for i, part in doors do
		table.insert(world.Doors, dynamic(world, part, nil, nil, i * DOOR_PERIOD / #doors))
	end
	for i, c in crates do
		local d = dynamic(world, c.Part, c.From, c.To, i * CRATE_PERIOD / #crates)
		place(world, d)
		table.insert(world.Crates, d)
	end
	timed(world, "first Update", NavMesh.Update, mesh) -- the crates' start positions
	world.Added = {}
	local s = scale or 1
	spawn(world, "Player", "Player", 0.5, 12)
	for i = 1, math.round(N_CHASERS * s) do
		local r = RADII[(i - 1) % #RADII + 1]
		spawn(world, `Chaser{i}`, "Chaser", r, 11 - r * 2)
	end
	for i = 1, math.round(N_WANDERERS * s) do
		spawn(world, `Wanderer{i}`, "Wanderer", RADII[(i - 1) % #RADII + 1], 6)
	end
	return world
end

local function percentile(sorted: { number }, p: number): number
	return sorted[math.clamp(math.ceil(#sorted * p), 1, #sorted)]
end

-- Rows of (name, count, p50, p95, max, total) per timed call, sorted by name.
function Game.Timings(world: any): { { any } }
	local rows = {}
	for name, samples in world.Timings do
		local sorted, total = table.clone(samples), 0
		table.sort(sorted)
		for _, ms in sorted do
			total += ms
		end
		table.insert(rows, { name, #sorted, percentile(sorted, 0.5), percentile(sorted, 0.95), sorted[#sorted], total })
	end
	table.sort(rows, function(a, b)
		return a[1] < b[1]
	end)
	return rows
end

function Game.Report(world: any, out: (string) -> ())
	-- No crowd avoidance (out of scope per spec): count agents standing inside each other.
	local overlaps = 0
	for i, a in world.Npcs do
		for j = i + 1, #world.Npcs do
			local b = world.Npcs[j]
			overlaps += if a.Floor == b.Floor and flat(a.Position, b.Position) < a.Radius + b.Radius then 1 else 0
		end
	end
	world.Counters["overlapping pairs at the end"] = overlaps
	local keys = {}
	for key in world.Counters do
		table.insert(keys, key)
	end
	table.sort(keys)
	for _, key in keys do
		out(string.format("%-22s %d", key, world.Counters[key]))
	end
	out(string.format("%-18s %7s %8s %8s %8s %9s", "call (ms)", "count", "p50", "p95", "max", "total"))
	for _, row in Game.Timings(world) do
		out(string.format("%-18s %7d %8.4f %8.4f %8.3f %9.1f", table.unpack(row)))
	end
end

Game.DT = 1 / 30
return Game
