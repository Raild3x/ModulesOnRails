--!strict
-- Ticket 35: ticket 34's building with an elevator beside the stairs (Building.luau, `Elevator`).
-- NPC kinds are filters: a walker prices everything at 1, a tired NPC pays 5x on stairs, and a
-- wheelchair can't use stairs. The elevator link's Cost (56) is its best case, the cab waiting.
local Building = require("../Building")
local Points = require("../BuildingPoints")
local ElevatorSim = require("../ElevatorSim")

local STAIRS, ELEVATOR = Building.STAIRS_AREA, Building.ELEVATOR_AREA

local function scenario(name: string, from: string, to: string, costs: { [number]: number }?, expect: any, extra: any?)
	local s = {
		Name = name,
		From = from,
		To = to,
		Filter = { AgentRadius = 1, AreaCosts = costs },
		Expect = expect,
	}
	for k, v in extra or {} do
		s[k] = v
	end
	return s
end

return {
	Name = "BuildingElevator",
	AdapterOptions = { MaxStepHeight = 1 },
	Build = function(rbx: any, parent: Instance?)
		local walkable, obstacles, links, cab = Building.Build(rbx, parent, { Elevator = true })
		return { Walkable = walkable, Obstacles = obstacles, Points = Points(rbx), Links = links, Extra = cab }
	end,
	-- Studio: a crowd under the ruled policy (hysteresis on the game's event), one ball per NPC
	-- coloured by kind, and the cab Part following the sim's cab. The elevator is in service.
	Animate = function(report: any, NavMesh: any, rbx: any, parent: Instance)
		local sim = ElevatorSim.new {
			NavMesh = NavMesh,
			Mesh = report.Mesh,
			ElevatorArea = Building.ELEVATOR_AREA,
			StairsArea = Building.STAIRS_AREA,
			Policy = "hysteresis",
			Count = 80,
			Seed = 7,
			SpawnWindow = 40, -- a steady flow for the whole hold
			Enabled = true,
			Points = ElevatorSim.Points(NavMesh, report.Mesh, 30, 12345),
		}
		local colors = { Walker = { 46, 230, 64 }, Tired = { 255, 159, 10 }, Wheelchair = { 47, 140, 255 } }
		local balls = {}
		for _, npc in sim.Npcs do
			local ball = rbx.Instance.new("Part")
			ball.Shape = rbx.Enum.PartType.Ball
			ball.Anchored, ball.CanCollide = true, false
			ball.Size = rbx.Vector3.one * 2
			local c = colors[npc.Kind]
			ball.Color = rbx.Color3.fromRGB(c[1], c[2], c[3])
			ball.Material = rbx.Enum.Material.Neon
			ball.Transparency = 1
			ball.Parent = parent
			balls[npc] = ball
		end
		local cab, accumulator = report.Built.Extra, 0
		return function(dt: number)
			accumulator += math.min(dt, 0.25)
			while accumulator >= 0.1 do
				accumulator -= 0.1
				sim.Step(0.1)
			end
			for npc, ball in balls do
				local riding = npc.State == "ride"
				local shown = npc.State ~= "pending" and npc.State ~= "done"
				ball.Transparency = if shown then 0 else 1
				local p = if riding then cab.Position else npc.Position
				ball.Position = rbx.Vector3.new(p.X, p.Y + 1, p.Z)
			end
			local c = sim.Cab
			local y = c.Level * 12
			if c.State == "moving" then
				y = (c.Target * 12) + (c.Level * 12 - c.Target * 12) * math.max(c.Timer, 0) / 1.5
			end
			cab.Position = rbx.Vector3.new(5, y + 4.05, 13)
		end
	end,
	Scenarios = {
		scenario("walker: stairs beat the elevator", "Lobby", "Upstairs", nil, {
			Status = "Success",
			Links = {},
			Visits = { "Ground", "Landing", "Upper" },
		}),
		scenario("walker: the elevator wins far from the stairs", "WestGround", "WestUpper", nil, {
			Status = "Success",
			Links = { "Elevator" },
		}),
		scenario("tired (stairs x5): the elevator wins", "Lobby", "Upstairs", { [STAIRS] = 5 }, {
			Status = "Success",
			Links = { "Elevator" },
		}),
		scenario("tired, elevator busy (x3): the stairs win again", "Lobby", "Upstairs", {
			[STAIRS] = 5,
			[ELEVATOR] = 3,
		}, { Status = "Success", Links = {}, Visits = { "Landing" } }),
		scenario("wheelchair: elevator only", "Lobby", "Upstairs", { [STAIRS] = math.huge }, {
			Status = "Success",
			Links = { "Elevator" },
		}),
		scenario(
			"out of service: the tired take the stairs",
			"Lobby",
			"Upstairs",
			{ [STAIRS] = 5 },
			{ Status = "Success", Links = {}, Visits = { "Landing" } },
			{ DisabledLinks = { "Elevator" } }
		),
		scenario(
			"out of service: a wheelchair can't go up",
			"Lobby",
			"Upstairs",
			{ [STAIRS] = math.huge },
			{ Status = "Partial", Floors = { "Ground" } },
			{ DisabledLinks = { "Elevator" } }
		),
		scenario(
			"out of service: the far walker takes the stairs",
			"WestGround",
			"WestUpper",
			nil,
			{ Status = "Success", Links = {}, Visits = { "Landing" } },
			{ DisabledLinks = { "Elevator" } }
		),
		scenario(
			"control: out of service is not ridden",
			"Lobby",
			"Upstairs",
			{ [STAIRS] = 5 },
			{ Links = { "Elevator" } },
			{ DisabledLinks = { "Elevator" }, MustFail = "Links" }
		),
	},
	View = { From = { 78, 62, -22 }, To = { 30, 2, 22 } },
	SeeThrough = { "Upper", "Wall", "Lintel", "Shaft" },
}
