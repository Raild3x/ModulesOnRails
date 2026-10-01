--!strict
-- The street (ticket 36): a road along X between two sidewalks, two 6-wide crosswalks, cars
-- parked up to the crosswalk lines, and a stand-in facade with a doorway (the Entrance) on the
-- north sidewalk until ticket 34's building lands. Flush for now: every surface is at y 0.
--
--   z 44 +--------- north sidewalk -- facade -- door (x 48..52) ------+
--   z 30 +------+ xw +--------------- road ---------------+ xw +-----+
--        | road | 18 |   cars park in the lanes z 14..18   | 76 |road |
--   z 14 +------+ 24 +------------- and z 26..30 ----------+ 82 +-----+
--   z  0 +--------------------- south sidewalk ---------------------+
--        x 0                                                      x 100
--
-- Areas are named with text NavAreas, so scenarios write `areas.Road`. The road is split
-- around the crosswalks, so "Avoids Road" means "crosses only on a crosswalk".
local Parts = require("../Parts")

local ROAD, WALK, CROSS = { 55, 55, 60 }, { 175, 175, 168 }, { 225, 225, 215 }

local function costs(road: number)
	return function(areas)
		return { AreaCosts = { [areas.Road] = road } }
	end
end

return {
	Name = "Street",
	MaxAgentRadius = 4,
	Build = function(rbx: any, parent: Instance?)
		local P = Parts(rbx, parent)
		local walkable = {}
		local function surface(name: string, area: string, x0: number, z0: number, x1: number, z1: number, rgb)
			local p = P.slab(name, x0, z0, x1, z1, 0, rgb)
			p:SetAttribute("NavArea", area)
			table.insert(walkable, p)
		end
		surface("Road", "Road", 0, 14, 18, 30, ROAD)
		surface("Road", "Road", 24, 14, 76, 30, ROAD)
		surface("Road", "Road", 82, 14, 100, 30, ROAD)
		surface("Crosswalk West", "Crosswalk", 18, 14, 24, 30, CROSS)
		surface("Crosswalk East", "Crosswalk", 76, 14, 82, 30, CROSS)
		surface("South Sidewalk", "Sidewalk", 0, 0, 100, 14, WALK)
		surface("North Sidewalk", "Sidewalk", 0, 30, 100, 44, WALK)

		local obstacles = {}
		local function car(x0: number, z0: number, rgb)
			-- 4.5 tall: a Part exactly AgentHeight (5) tall does not cut the floor (known-gaps.md).
			table.insert(obstacles, P.box("Car", x0, z0, x0 + 6, z0 + 4, 0, 4.5, rgb))
		end
		car(12, 14, { 180, 40, 40 }) -- up to the west crosswalk, both sides of it
		car(24, 14, { 40, 80, 180 })
		car(12, 26, { 200, 180, 40 })
		car(24, 26, { 60, 150, 70 })
		car(70, 14, { 120, 120, 130 }) -- the same at the east crosswalk
		car(82, 14, { 30, 30, 35 })
		car(70, 26, { 230, 230, 230 })
		car(82, 26, { 180, 90, 30 })
		table.insert(obstacles, P.box("Facade", 20, 42, 48, 44, 0, 12, { 150, 80, 60 }))
		table.insert(obstacles, P.box("Facade", 52, 42, 80, 44, 0, 12, { 150, 80, 60 }))

		local V3 = rbx.Vector3
		return {
			Walkable = walkable,
			Obstacles = obstacles,
			Points = {
				Entrance = V3.new(50, 0, 40),
				Far = V3.new(42, 0, 7), -- across the road from the Entrance
				West = V3.new(6, 0, 7),
				East = V3.new(94, 0, 7),
				Mid = V3.new(60, 0, 10),
				NorthWalk = V3.new(40, 0, 36),
			},
		}
	end,
	Scenarios = {
		{
			Name = "far side to the entrance via a crosswalk",
			From = "Far",
			To = "Entrance",
			Filter = costs(10),
			-- Straight across is 33.5; via the west crosswalk is about 60.
			Expect = { Status = "Success", Avoids = { "Road" }, MinLength = 50 },
		},
		{
			Name = "road cost 10: west start stays off the road",
			From = "West",
			To = "Entrance",
			Filter = costs(10),
			Expect = { Status = "Success", Avoids = { "Road" } },
		},
		{
			Name = "road cost 10: east start stays off the road",
			From = "East",
			To = "Entrance",
			Filter = costs(10),
			Expect = { Status = "Success", Avoids = { "Road" } },
		},
		{
			Name = "road cost 10: mid start stays off the road",
			From = "Mid",
			To = "Entrance",
			Filter = costs(10),
			Expect = { Status = "Success", Avoids = { "Road" } },
		},
		{
			Name = "radius 2.5 fits the crosswalk between cars",
			From = "Far",
			To = "NorthWalk",
			Filter = function(areas)
				return { AgentRadius = 2.5, AreaCosts = { [areas.Road] = math.huge } }
			end,
			Expect = { Status = "Success", Avoids = { "Road" } },
		},
		-- Negative controls.
		{
			Name = "control: road cost 1 cuts straight across",
			From = "Far",
			To = "Entrance",
			Filter = costs(1),
			Expect = { Status = "Success", MaxStretch = 1.01, Avoids = { "Road" } },
			MustFail = "Avoids",
		},
		{
			Name = "control: radius 3.5 does not fit between the cars",
			From = "Far",
			To = "NorthWalk",
			Filter = function(areas)
				return { AgentRadius = 3.5, AreaCosts = { [areas.Road] = math.huge } }
			end,
			Expect = { Status = "Success" },
			MustFail = "Status",
		},
	},
}
