-- Ticket 35: should an NPC partway up the stairs reroute when the elevator frees up? Runs a
-- seeded crowd (tools/navmesh/maps/ElevatorSim.luau) on the BuildingElevator map under each
-- reroute policy, and the reverse case (the elevator goes out of service mid-route).
--   lune run tools/navmesh/bench/elevator_reroute.luau [seeds=20] [count=40]
local process = require("@lune/process")
local roblox = require("@lune/roblox") :: any
local NavMesh = require("../../../lib/navmesh/src/NavMesh")
local Adapter = require("../../../lib/navmeshadapter/src/NavMeshAdapter")
local Building = require("../maps/Building")
local Sim = require("../maps/ElevatorSim")

local SEEDS = tonumber(process.args[1]) or 20
local COUNT = tonumber(process.args[2]) or 40
local DT, CAP, AT = 0.1, 120, 6 -- step, give-up time, when the elevator changes (seconds)

local walkable, obstacles, links = Building.Build(roblox, nil, { Elevator = true })
local desc = Adapter.FromParts(walkable, obstacles, { MaxStepHeight = 1 })
desc.MaxAgentRadius = 2
desc.Links = links
local mesh = NavMesh.Build(desc)

local points = Sim.Points(NavMesh, mesh, 30, 12345)

local function run(policy: string, seed: number, startEnabled: boolean)
	NavMesh.SetLinkEnabled(mesh, 1, startEnabled)
	local sim = Sim.new {
		NavMesh = NavMesh,
		Mesh = mesh,
		ElevatorArea = Building.ELEVATOR_AREA,
		StairsArea = Building.STAIRS_AREA,
		Policy = policy,
		Count = COUNT,
		Seed = seed,
		SpawnWindow = 8,
		Enabled = startEnabled,
		Points = points,
	}
	local switched = false
	while sim.Time < CAP and not sim.Finished() do
		if not switched and sim.Time >= AT then
			switched = true
			NavMesh.SetLinkEnabled(mesh, 1, not startEnabled)
			sim.SetEnabled(not startEnabled)
		end
		sim.Step(DT)
	end
	NavMesh.SetLinkEnabled(mesh, 1, true)
	return sim
end

local function trip(npc: any): number
	return if npc.Done then npc.Done - npc.Spawn else CAP - npc.Spawn
end

local function percentile(t: { number }, q: number): number
	table.sort(t)
	return t[math.max(1, math.ceil(#t * q))]
end

local function study(title: string, startEnabled: boolean, policies: { string })
	print(`\n== {title} ({SEEDS} seeds x {COUNT} NPCs; the elevator changes at t = {AT} s)`)
	print(
		"policy       mean s  p90 s  effort  unfinished  stranded  rerouted  >1x  better  worse  saved effort  FindPath  ms/call  invalid(not elev)"
	)
	local base: { [string]: number } = {}
	for _, policy in policies do
		local efforts, own, ownN, waitErr, waitN = 0, 0, 0, 0, 0
		local times, unfinished, stranded, rerouted, multi, calls, ms = {}, 0, 0, 0, 0, 0, 0
		local faster, slower, saved, invalid, spurious = 0, 0, 0, 0, 0
		for seed = 1, SEEDS do
			local sim = run(policy, seed, startEnabled)
			calls += sim.FindPaths
			ms += sim.FindPathMs
			stranded += sim.Stranded
			invalid += sim.Invalidated
			spurious += sim.InvalidNotElevator
			for _, err in sim.WaitErrors do
				waitErr += err
				waitN += 1
			end
			for _, npc in sim.Npcs do
				local t = trip(npc)
				local e = Sim.Effort(npc, t)
				efforts += e
				table.insert(times, t)
				unfinished += if npc.Done then 0 else 1
				rerouted += if npc.Reroutes > 0 then 1 else 0
				multi += if npc.Reroutes > 1 then 1 else 0
				local key = `{seed}/{npc.Id}`
				if policy == policies[1] then
					base[key] = e
				else
					local d = base[key] - e
					saved += d
					if npc.Reroutes > 0 then
						own += d
						ownN += 1
					end
					faster += if d > 0.5 then 1 else 0
					slower += if d < -0.5 then 1 else 0
				end
			end
		end
		local sum = 0
		for _, t in times do
			sum += t
		end
		print(
			string.format(
				"%-11s  rerouted NPCs' own saving %+.2f s each (%d); elevator wait vs promise %+.2f s over %d rides",
				policy,
				own / math.max(ownN, 1),
				ownN,
				waitErr / math.max(waitN, 1),
				waitN
			)
		)
		print(
			string.format(
				"%-11s %7.2f %6.2f %7.2f %11d %9d %9d %4d %7d %6d %13.1f %9d %8.3f %8d (%d)",
				policy,
				sum / #times,
				percentile(times, 0.9),
				efforts / #times,
				unfinished,
				stranded,
				rerouted,
				multi,
				faster,
				slower,
				saved,
				calls,
				ms / math.max(calls, 1),
				invalid,
				spurious
			)
		)
	end
end

study("The elevator frees up", false, { "ignore", "always", "hysteresis", "commit", "waypoints", "library" })
study("The elevator goes out of service", true, { "always", "library" })
