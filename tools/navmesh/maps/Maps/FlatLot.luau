--!strict
-- The tracer map (ticket 33): a flat 60 x 40 lot with one crate in the middle and a mud patch
-- (area 3) north of it. Spawn and Goal face each other across the crate.
local Parts = require("../Parts")

return {
	Name = "FlatLot",
	Build = function(rbx: any, parent: Instance?)
		local P = Parts(rbx, parent)
		local mud = P.box("Mud", 20, 26, 40, 34, -0.2, 0.2, { 90, 70, 40 })
		mud:SetAttribute("NavArea", 3)
		return {
			Walkable = { P.slab("Ground", 0, 0, 60, 40, 0, { 70, 72, 78 }), mud },
			Obstacles = { P.box("Crate", 27, 17, 33, 23, 0, 4, { 160, 110, 60 }) },
			Points = {
				Spawn = rbx.Vector3.new(10, 0, 20),
				Goal = rbx.Vector3.new(50, 0, 20),
				North = rbx.Vector3.new(10, 0, 30),
				NorthGoal = rbx.Vector3.new(50, 0, 30),
			},
		}
	end,
	Scenarios = {
		{
			Name = "around the crate",
			From = "Spawn",
			To = "Goal",
			Filter = { AgentRadius = 1 },
			-- Straight through is 40; around the crate's corner (3 + 1 off the line) is longer.
			Expect = { Status = "Success", Floors = { "Ground" }, MinLength = 40.5, MaxStretch = 1.2 },
		},
		{
			Name = "mud avoided when costly",
			From = "North",
			To = "NorthGoal",
			Filter = { AreaCosts = { [3] = 10 } },
			Expect = { Status = "Success", Avoids = { 3 } },
		},
		-- Negative controls: wrong expectations that must fail, and be named.
		{
			Name = "control: wrong floor",
			From = "Spawn",
			To = "Goal",
			Expect = { Floors = { "Roof" } },
			MustFail = "Floors",
		},
		{
			Name = "control: mud walked at cost 1",
			From = "North",
			To = "NorthGoal",
			Expect = { Avoids = { 3 } },
			MustFail = "Avoids",
		},
	},
}
