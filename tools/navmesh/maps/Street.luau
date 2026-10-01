--!strict
-- The street (ticket 36) in front of ticket 34's building (Building.luau), shared by
-- Maps/Street (curbs) and Maps/StreetFlush. A road along X between the building's forecourt
-- (its lot's ground, z -20..0) and a south sidewalk, two 6-wide crosswalks, and cars parked up to
-- both sides of each crosswalk.
--
--   z   0 +------------- building wall, doorway x 26..34 -------------+
--         |                forecourt (the building's lot)              |
--   z -20 +------+ xw +--------------- road ---------------+ xw +-----+
--         | road | -2 |   cars park in the lanes z -36..-32 | 56 |road |
--   z -36 +------+  4 +------------- and z -24..-20 -------+ 62 +-----+
--         |                       south sidewalk                      |
--   z -50 +-----------------------------------------------------------+
--         x -20                                                    x 80
--
-- With `curbs`, the road and crosswalks sit 0.5 below the sidewalks: the curb is a step the
-- adapter's MaxStepHeight joins (riser strips), and each crosswalk end has a curb cut, a wedge
-- ramp up to the sidewalk. Flush, every surface is at y 0.
--
-- Areas are named with text NavAreas, so scenarios write `areas.Road`. The road is split
-- around the crosswalks, so "Avoids Road" means "crosses only on a crosswalk". The forecourt is
-- the building's ground: area 1.
local Building = require("./Building")
local BuildingPoints = require("./BuildingPoints")
local Parts = require("./Parts")

local ROAD, WALK, CROSS = { 55, 55, 60 }, { 175, 175, 168 }, { 225, 225, 215 }

local function costs(road: number)
	return function(areas)
		return { AreaCosts = { [areas.Road] = road } }
	end
end

local function excluded(radius: number)
	return function(areas)
		return { AgentRadius = radius, AreaCosts = { [areas.Road] = math.huge } }
	end
end

return function(curbs: boolean)
	local roadY = if curbs then -0.5 else 0
	return {
		Name = if curbs then "Street" else "StreetFlush",
		MaxAgentRadius = 4,
		AdapterOptions = { MaxStepHeight = 1 },
		View = nil,
		Build = function(rbx: any, parent: Instance?)
			local walkable, obstacles = Building(rbx, parent, false)
			local built = { Walkable = walkable, Obstacles = obstacles, Points = {} }
			local P = Parts(rbx, parent)
			local CF, V3 = rbx.CFrame, rbx.Vector3
			local function tagged(p, area: string)
				p:SetAttribute("NavArea", area)
				table.insert(built.Walkable, p)
			end
			local function surface(name: string, area: string, x0: number, z0: number, x1: number, z1: number, y, rgb)
				tagged(P.slab(name, x0, z0, x1, z1, y, rgb), area)
			end
			surface("Road", "Road", -20, -36, -2, -20, roadY, ROAD)
			surface("Road", "Road", 4, -36, 56, -20, roadY, ROAD)
			surface("Road", "Road", 62, -36, 80, -20, roadY, ROAD)
			surface("Crosswalk West", "Crosswalk", -2, -36, 4, -20, roadY, CROSS)
			surface("Crosswalk East", "Crosswalk", 56, -36, 62, -20, roadY, CROSS)
			surface("South Sidewalk", "Sidewalk", -20, -50, 80, -36, 0, WALK)
			if curbs then
				-- Curb cuts: 2-stud wedges on the crosswalk, rising to the sidewalk at each end.
				for _, x in { 1, 59 } do
					local size = V3.new(6, -roadY, 2)
					local y = roadY / 2
					tagged(P.part("WedgePart", "Curb Cut", size, CF.new(x, y, -21), CROSS), "Crosswalk")
					tagged(
						P.part("WedgePart", "Curb Cut", size, CF.new(x, y, -35) * CF.Angles(0, math.pi, 0), CROSS),
						"Crosswalk"
					)
				end
			end

			local function car(x0: number, z0: number, rgb)
				-- 4.5 tall: a Part exactly AgentHeight (5) tall does not cut the floor (known-gaps.md).
				table.insert(built.Obstacles, P.box("Car", x0, z0, x0 + 6, z0 + 4, roadY, 4.5, rgb))
			end
			car(-8, -36, { 180, 40, 40 }) -- up to the west crosswalk, both sides of it
			car(4, -36, { 40, 80, 180 })
			car(-8, -24, { 200, 180, 40 })
			car(4, -24, { 60, 150, 70 })
			car(50, -36, { 120, 120, 130 }) -- the same at the east crosswalk
			car(62, -36, { 30, 30, 35 })
			car(50, -24, { 230, 230, 230 })
			car(62, -24, { 180, 90, 30 })

			built.Points = BuildingPoints(rbx)
			for name, p in
				{
					Entrance = { 30, 0, 15 }, -- the lobby, through the doorway
					Far = { 22, 0, -43 }, -- across the road from the doorway
					West = { -14, 0, -43 },
					East = { 74, 0, -43 },
					Mid = { 40, 0, -40 },
					NorthWalk = { 20, 0, -14 },
				}
			do
				built.Points[name] = V3.new(p[1], p[2], p[3])
			end
			return built
		end,
		Scenarios = {
			{
				Name = "far side to the entrance via a crosswalk",
				From = "Far",
				To = "Entrance",
				Filter = costs(10),
				-- Straight across is 58.5; via the west crosswalk is about 80.
				Expect = { Status = "Success", Avoids = { "Road" }, MinLength = 70 },
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
				Filter = excluded(2.5),
				Expect = { Status = "Success", Avoids = { "Road" } },
			},
			-- Negative controls.
			{
				Name = "control: road cost 1 cuts straight across",
				From = "Far",
				To = "Entrance",
				Filter = costs(1),
				Expect = { Status = "Success", MaxStretch = 1.02, Avoids = { "Road" } },
				MustFail = "Avoids",
			},
			{
				Name = "control: radius 3.5 does not fit between the cars",
				From = "Far",
				To = "NorthWalk",
				Filter = excluded(3.5),
				Expect = { Status = "Success" },
				MustFail = "Status",
			},
		},
	}
end
