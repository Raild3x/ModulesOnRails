--!strict
-- Ticket 35's crowd: NPCs walk the building with the path follower, ride the elevator, and react
-- when it opens or goes out of service, under a reroute policy. The game side of riding lives
-- here (the library only routes): a cab with doors and a capacity, a queue per floor, and an
-- estimate of the current wait that NPCs pass as AreaCosts[ELEVATOR_AREA].
-- Used by tools/navmesh/bench/elevator_reroute.luau (the measurement) and Studio.luau's view.
--
-- Policies, applied when the elevator comes back into service (the game knows: it owns the cab):
-- - "ignore": keep the current path.
-- - "always": switch if the fresh path costs less than staying off the elevator.
-- - "hysteresis": switch only if it costs at least HYSTERESIS less.
-- - "commit": like "hysteresis", but never once on the stairs (a step, riser or landing floor).
-- - "waypoints": no event; at every waypoint reached, re-plan and switch as "always" does.
-- - "library": no event either way; a walking NPC re-plans only when IsPathValid turns false.
--   Out of service, NPCs already waiting are stranded: nothing tells them.
-- Both costs come from FindPath in the same cost mode (ticket 35's as-built notes: Cost changes
-- meaning between uniform and weighted filters), so the elevator multiplier is never exactly 1.

local SPEED = 16 -- studs per second, Roblox's default walk
local RIDE, DOORS, CAPACITY = 1.5, 2, 4 -- seconds floor to floor, seconds doors open, riders
local BEST = RIDE + DOORS -- the link's Cost (56 studs) is this many seconds at SPEED
local HYSTERESIS = 0.15
local KINDS = { -- share of the crowd, stairs multiplier
	{ Name = "Walker", Share = 0.5, Stairs = 1 },
	{ Name = "Tired", Share = 0.35, Stairs = 5 },
	{ Name = "Wheelchair", Share = 0.15, Stairs = math.huge },
}

export type Npc = {
	Id: number,
	Kind: string,
	Stairs: number,
	Position: Vector3,
	Floor: string?,
	Goal: Vector3,
	Spawn: number,
	State: string, -- "walk" | "wait" | "ride" | "stuck" | "done"
	Follower: any,
	Level: number?, -- waiting or riding: the floor index it boards at (0 ground, 1 upper)
	Landing: Vector3?,
	Done: number?,
	Reroutes: number,
	UsedElevator: boolean,
	WaitFrom: number?, -- when it joined the queue, and the wait it was promised
	Promised: number?,
	StairsTime: number, -- seconds on the step floors (the stairs area; risers and the landing aren't)
}

local Sim = {}
Sim.SPEED = SPEED

-- Spawn and goal pools: `count` random points inside the building on each of Ground and Upper.
function Sim.Points(NavMesh: any, mesh: any, count: number, seed: number): { Ground: { Vector3 }, Upper: { Vector3 } }
	math.randomseed(seed)
	local points = { Ground = {}, Upper = {} }
	while #points.Ground < count or #points.Upper < count do
		local p = NavMesh.FindRandomPoint(mesh, { Rng = math.random, Filter = { AgentRadius = 1 } })
		if p and (p.Floor == "Ground" or p.Floor == "Upper") then
			local x, z = p.Position.X, p.Position.Z
			if x > 1 and x < 59 and z > 1 and z < 39 and #points[p.Floor] < count then
				table.insert(points[p.Floor], p.Position)
			end
		end
	end
	return points :: any
end

-- What the NPC's own costs say its trip was worth: seconds, plus the stairs surcharge it pays
-- (a tired NPC's 5x) for each second on the stairs.
function Sim.Effort(npc: Npc, trip: number): number
	return trip + (if npc.StairsTime > 0 then (npc.Stairs - 1) * npc.StairsTime else 0)
end

local function isStairs(floor: string?): boolean
	return floor ~= nil and (string.find(floor, "^Step") or string.find(floor, "^Riser") or floor == "Landing") ~= nil
end

local function usesElevator(path: any): boolean
	for _, w in path.Waypoints do
		if w.Label == "Elevator" then
			return true
		end
	end
	return false
end

-- o: NavMesh, Mesh, ElevatorArea, StairsArea, Policy, Count, Seed, SpawnWindow, Enabled (at
-- t = 0), Points ({ Ground: {Vector3}, Upper: {Vector3} } to draw spawns and goals from).
function Sim.new(o: any)
	local NavMesh, mesh = o.NavMesh, o.Mesh
	math.randomseed(o.Seed)
	local self = {
		Time = 0,
		Npcs = {} :: { Npc },
		Cab = { Level = 0, State = "idle", Timer = 0, Target = 0, Riders = {} :: { Npc } },
		Waiting = { [0] = {} :: { Npc }, [1] = {} :: { Npc } },
		Enabled = o.Enabled,
		FindPaths = 0,
		FindPathMs = 0,
		Stranded = 0, -- NPCs left at a cab that won't come (the library policy, out of service)
		WaitErrors = {} :: { number }, -- actual minus promised seconds, per ride
		Invalidated = 0, -- library policy: walking paths IsPathValid rejected
		InvalidNotElevator = 0, -- ... of which never used the elevator
	}

	-- Seconds until the cab can open its doors at `level`, plus the queue ahead and the ride.
	local function expectedSeconds(level: number): number
		local cab = self.Cab
		local reach
		if cab.State == "idle" then
			reach = if cab.Level == level then 0 else RIDE
		elseif cab.State == "moving" then
			reach = cab.Timer + (if cab.Target == level then 0 else DOORS + RIDE)
		else
			reach = cab.Timer + (if cab.Level == level then 0 else RIDE)
		end
		local queue = math.floor(#self.Waiting[level] / CAPACITY) * 2 * (RIDE + DOORS)
		return reach + queue + BEST
	end

	local function filter(npc: Npc, elevator: number): any
		return {
			AgentRadius = 1,
			AreaCosts = { [o.StairsArea] = npc.Stairs, [o.ElevatorArea] = elevator },
		}
	end
	local function elevatorFactor(npc: Npc): number
		if not self.Enabled then
			return math.huge
		end
		local level = if npc.Position.Y > 6 then 1 else 0
		return math.max(1.001, expectedSeconds(level) / BEST)
	end
	local function findPath(from: Vector3, to: Vector3, f: any): any
		local t0 = os.clock()
		local path = NavMesh.FindPath(mesh, from, to, f)
		self.FindPathMs += (os.clock() - t0) * 1000
		self.FindPaths += 1
		return path
	end
	local function follow(npc: Npc, path: any)
		npc.Follower = NavMesh.NewFollower(path)
		npc.State = if path.Status == "Success" then "walk" else "stuck"
	end
	local function plan(npc: Npc)
		follow(npc, findPath(npc.Position, npc.Goal, filter(npc, elevatorFactor(npc))))
	end

	-- The reroute decision: is the fresh path enough cheaper than staying off the elevator?
	local function reconsider(npc: Npc, threshold: number)
		local fresh = findPath(npc.Position, npc.Goal, filter(npc, elevatorFactor(npc)))
		if fresh.Status ~= "Success" or not usesElevator(fresh) or usesElevator(npc.Follower.Path) then
			return
		end
		local stay = findPath(npc.Position, npc.Goal, filter(npc, 1e6))
		if stay.Status ~= "Success" or fresh.Cost < stay.Cost * (1 - threshold) then
			npc.Reroutes += 1
			follow(npc, fresh)
		end
	end

	function self.SetEnabled(enabled: boolean)
		if enabled == self.Enabled then
			return
		end
		self.Enabled = enabled
		for _, npc in self.Npcs do
			if npc.State == "stuck" then
				plan(npc)
			elseif enabled and npc.State == "walk" then
				local p = o.Policy
				if p == "always" then
					reconsider(npc, 0)
				elseif p == "hysteresis" or (p == "commit" and not isStairs(npc.Floor)) then
					reconsider(npc, HYSTERESIS)
				end
			elseif not enabled and o.Policy == "library" and npc.State == "wait" then
				npc.State = "stranded"
				self.Stranded += 1
			elseif not enabled and o.Policy ~= "library" then
				-- Out of service: the game tells those walking to it, and those waiting, to re-plan.
				-- Riders are delivered.
				if npc.State == "walk" and usesElevator(npc.Follower.Path) then
					npc.Reroutes += 1
					plan(npc)
				elseif npc.State == "wait" then
					local queue = self.Waiting[npc.Level :: number]
					table.remove(queue, table.find(queue, npc) :: number)
					npc.Reroutes += 1
					plan(npc)
				end
			end
		end
	end

	-- The crowd: kinds by share, spawns over SpawnWindow seconds, 80% bound for the other floor.
	for id = 1, o.Count do
		local r, kind = math.random(), KINDS[#KINDS]
		local acc = 0
		for _, k in KINDS do
			acc += k.Share
			if r < acc then
				kind = k
				break
			end
		end
		local up = math.random() < 0.5
		local from = (if up then o.Points.Ground else o.Points.Upper)[math.random(#o.Points.Ground)]
		local cross = math.random() < 0.8
		local list = if up == cross then o.Points.Upper else o.Points.Ground
		local to = list[math.random(#list)]
		table.insert(self.Npcs, {
			Id = id,
			Kind = kind.Name,
			Stairs = kind.Stairs,
			Position = from,
			Floor = nil,
			Goal = to,
			Spawn = math.random() * o.SpawnWindow,
			State = "pending",
			Follower = nil,
			Reroutes = 0,
			UsedElevator = false,
			StairsTime = 0,
		})
	end

	local function board(level: number)
		local cab, queue = self.Cab, self.Waiting[level]
		while #queue > 0 and #cab.Riders < CAPACITY do
			local npc = table.remove(queue, 1) :: Npc
			npc.State = "ride"
			table.insert(cab.Riders, npc)
		end
	end
	local function stepCab(dt: number)
		local cab = self.Cab
		cab.Timer -= dt
		if cab.State == "moving" and cab.Timer <= 0 then
			cab.Level = cab.Target
			for i = #cab.Riders, 1, -1 do
				local npc = cab.Riders[i]
				table.remove(cab.Riders, i)
				npc.Position = npc.Landing :: Vector3
				npc.State = "walk"
				table.insert(self.WaitErrors, self.Time - (npc.WaitFrom :: number) - (npc.Promised :: number))
			end
			if self.Enabled then
				board(cab.Level)
			end
			cab.State, cab.Timer = "doors", DOORS
		elseif cab.State == "doors" and cab.Timer > 0 and self.Enabled then
			board(cab.Level) -- step in while the doors are open
		elseif cab.State == "doors" and cab.Timer <= 0 then
			local other = 1 - cab.Level
			if #cab.Riders > 0 or (self.Enabled and #self.Waiting[other] > 0) then
				cab.State, cab.Timer, cab.Target = "moving", RIDE, other
			else
				cab.State = "idle"
			end
		elseif cab.State == "idle" and self.Enabled then
			if #self.Waiting[cab.Level] > 0 then
				board(cab.Level)
				cab.State, cab.Timer = "doors", DOORS
			elseif #self.Waiting[1 - cab.Level] > 0 then
				cab.State, cab.Timer, cab.Target = "moving", RIDE, 1 - cab.Level
			end
		end
	end

	function self.Step(dt: number)
		self.Time += dt
		stepCab(dt)
		for _, npc in self.Npcs do
			if npc.State == "pending" and self.Time >= npc.Spawn then
				plan(npc)
			elseif
				npc.State == "stuck"
				and (o.Policy == "waypoints" or o.Policy == "library")
				and self.Time % 1 < dt
			then
				plan(npc) -- no event to wake it: poll
			end
			if npc.State ~= "walk" then
				continue
			end
			if o.Policy == "library" and not NavMesh.IsPathValid(mesh, npc.Follower.Path) then
				self.Invalidated += 1
				if not usesElevator(npc.Follower.Path) then
					self.InvalidNotElevator += 1
				end
				npc.Reroutes += 1
				plan(npc)
			end
			local before = npc.Follower.Next
			local f = filter(npc, elevatorFactor(npc))
			local position, floor, event = NavMesh.Advance(mesh, npc.Follower, npc.Position, SPEED * dt, f)
			npc.Position, npc.Floor = position, floor or npc.Floor
			if npc.Floor and string.find(npc.Floor, "^Step") then -- the floors with the stairs area
				npc.StairsTime += dt
			end
			if event == "Arrived" then
				npc.State, npc.Done = "done", self.Time
			elseif event == "Link" then
				local link = npc.Follower.Link
				if self.Enabled then
					npc.Level = if link.From.Y > 6 then 1 else 0
					npc.Landing = link.To
					npc.State = "wait"
					npc.UsedElevator = true
					npc.WaitFrom, npc.Promised = self.Time, expectedSeconds(npc.Level :: number)
					table.insert(self.Waiting[npc.Level :: number], npc)
				elseif o.Policy == "library" then
					self.Stranded += 1 -- nobody told it: it waits at a dead elevator
					npc.State = "stranded"
				else
					plan(npc)
				end
			elseif event == "Blocked" then
				plan(npc)
			elseif o.Policy == "waypoints" and npc.Follower.Next ~= before and self.Enabled then
				reconsider(npc, 0)
			end
		end
	end

	function self.Finished(): boolean
		for _, npc in self.Npcs do
			if npc.State ~= "done" and npc.State ~= "stranded" then
				return false
			end
		end
		return true
	end

	return self
end

return Sim
