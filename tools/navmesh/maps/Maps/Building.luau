--!strict
-- Ticket 34: the two-storey building (../Building.luau) with step-Part stairs, joined by the
-- adapter's step-height rule (MaxStepHeight 1: riser strips).
local Building = require("../Building")
local Points = require("../BuildingPoints")

local scenarios = {}
for _, r in { 0.5, 1, 2 } do
	table.insert(scenarios, {
		Name = `up the U-stair, r {r}`,
		From = "Lobby",
		To = "Upstairs",
		Filter = { AgentRadius = r },
		Expect = { Status = "Success", Visits = { "Ground", "Landing", "Upper" }, MaxLength = 70 },
	})
	table.insert(scenarios, {
		Name = `down the U-stair, r {r}`,
		From = "Upstairs",
		To = "Lobby",
		Filter = { AgentRadius = r },
		Expect = { Status = "Success", Visits = { "Upper", "Landing", "Ground" }, MaxLength = 70 },
	})
end
for _, s in
	{
		{
			Name = "narrow stair, r 1",
			From = "NarrowFoot",
			To = "NarrowHead",
			Filter = { AgentRadius = 1 },
			Expect = { Status = "Success", MaxLength = 40 },
		},
		{
			Name = "narrow stair rejects r 2: the long way",
			From = "NarrowFoot",
			To = "NarrowHead",
			Filter = { AgentRadius = 2 },
			Expect = { Status = "Success", Visits = { "Ground", "Landing", "Upper" }, MinLength = 60 },
		},
		{
			Name = "street to upstairs, r 1",
			From = "Street",
			To = "Upstairs",
			Filter = { AgentRadius = 1 },
			Expect = { Status = "Success", Visits = { "Ground", "Landing", "Upper" } },
		},
		{
			Name = "landing to upstairs, r 1",
			From = "Landing",
			To = "Upstairs",
			Filter = { AgentRadius = 1 },
			Expect = { Status = "Success", Visits = { "Landing", "Upper" }, MaxLength = 35 },
		},
		{
			Name = "control: narrow stair is not short at r 2",
			From = "NarrowFoot",
			To = "NarrowHead",
			Filter = { AgentRadius = 2 },
			Expect = { MaxLength = 40 },
			MustFail = "MaxLength",
		},
	}
do
	table.insert(scenarios, s)
end

return {
	Name = "Building",
	AdapterOptions = { MaxStepHeight = 1 },
	Build = function(rbx: any, parent: Instance?)
		local walkable, obstacles = Building.Build(rbx, parent, { Ramps = false })
		return { Walkable = walkable, Obstacles = obstacles, Points = Points(rbx) }
	end,
	Scenarios = scenarios,
	View = { From = { 78, 62, -22 }, To = { 34, 2, 22 } },
	SeeThrough = { "Upper", "Wall", "Lintel" },
}
