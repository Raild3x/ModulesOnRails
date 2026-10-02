--!strict
-- Ticket 34's comparison: the building with the U-stair's flights swapped for wedge ramps of the
-- same rise and run (the narrow stair stays steps).
local Building = require("../Building")
local Points = require("../BuildingPoints")

local scenarios = {}
for _, r in { 0.5, 1, 2 } do
	table.insert(scenarios, {
		Name = `up the U-ramp, r {r}`,
		From = "Lobby",
		To = "Upstairs",
		Filter = { AgentRadius = r },
		Expect = { Status = "Success", Visits = { "Ground", "Landing", "Upper" }, MaxLength = 70 },
	})
	table.insert(scenarios, {
		Name = `down the U-ramp, r {r}`,
		From = "Upstairs",
		To = "Lobby",
		Filter = { AgentRadius = r },
		Expect = { Status = "Success", Visits = { "Upper", "Landing", "Ground" }, MaxLength = 70 },
	})
end

return {
	Name = "BuildingRamp",
	AdapterOptions = { MaxStepHeight = 1 },
	Build = function(rbx: any, parent: Instance?)
		local walkable, obstacles = Building.Build(rbx, parent, { Ramps = true })
		return { Walkable = walkable, Obstacles = obstacles, Points = Points(rbx) }
	end,
	Scenarios = scenarios,
	View = { From = { 78, 62, -22 }, To = { 34, 2, 22 } },
	SeeThrough = { "Upper", "Wall", "Lintel" },
}
