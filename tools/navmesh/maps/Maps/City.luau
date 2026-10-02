--!strict
-- The combined city (ticket 38): ticket 36's street with ticket 34's building and ticket 35's
-- elevator, and ticket 37's forest and river south of the sidewalk. The regression map for
-- realistic content; tools/navmesh/bench/city_day.luau runs a seeded crowd's day on it.
--
--   z  60 +---------- building lot (x -20..80), the building at x 0..60, z 0..40 -----+
--   z   0 +------ doorway x 26..34 ------------------------------------------------+
--   z -20 +------ road, crosswalks at x -2..4 and 56..62 ------------------------------+
--   z -50 +------ south sidewalk ------------------------------------------------------+
--         | meadow (x -20..70), level along the sidewalk | river x 70..90 | forest east  |
--   z-210 +-----------------------------------------------------------------------------+
-- The sidewalk, the lot and the level ground south of it are one floor, "Ground"; the road and
-- its crosswalks (area Crosswalk) are "Road". The river runs up to the sidewalk, which crosses it like a culvert; south of the sidewalk the
-- east side is reached by the bridge (z -174..-168) or the ford (z -100..-85, area 7).
local ForestRiver = require("./ForestRiver") :: any
local Street = require("../Street")
local Building = require("../Building")

local OFFSET = { -20, 0, -210 } -- where ForestRiver's own origin lands
local FORD = ForestRiver.Ford

local street = Street(true, { Elevator = true })
local outdoors = ForestRiver.WithTilt(5, 37, { LevelSouth = true })

-- Area costs by NPC kind, as functions of the adapter's area-name table (Road is a text area).
local function kind(stairs: number, ford: number, radius: number?)
	return function(areas: any)
		return {
			AgentRadius = radius or 1,
			AreaCosts = { [areas.Road] = 10, [Building.STAIRS_AREA] = stairs, [FORD] = ford },
		}
	end
end

return {
	Name = "City",
	MaxAgentRadius = 4,
	AdapterOptions = { MaxStepHeight = 1 },
	View = { From = { 80, 330, 130 }, To = { 80, 0, -80 } },
	Offset = OFFSET,
	Build = function(rbx: any, parent: Instance?)
		local built = street.Build(rbx, parent)
		local far = outdoors.Build(rbx, parent)
		local shift = rbx.Vector3.new(OFFSET[1], OFFSET[2], OFFSET[3])
		for _, list in { far.Walkable, far.Obstacles } do
			for _, part in list do
				part.CFrame = part.CFrame + shift
			end
		end
		for _, p in far.Walkable do
			table.insert(built.Walkable, p)
		end
		for _, p in far.Obstacles do
			table.insert(built.Obstacles, p)
		end
		for name, p in far.Points do
			built.Points[name] = p + shift
		end
		return built
	end,
	Scenarios = {
		{
			Name = "walker: upstairs to the forest, by a crosswalk and the bridge",
			From = "Upstairs",
			To = "ForestEast",
			Filter = kind(1, 50),
			Expect = {
				Status = "Success",
				Visits = { "Upper", "Landing", "Ground", "Road", "Bridge" }, -- the U-stair, a crosswalk
				Avoids = { "Road", FORD },
			},
		},
		{
			Name = "walker, ford cheap: wades the ford instead",
			From = "Upstairs",
			To = "EastFord",
			Filter = kind(1, 1),
			Expect = { Status = "Success", Visits = { "Ground", "Road", "Ford" }, Avoids = { "Road" } },
		},
		{
			Name = "wheelchair: down by the elevator, out to the meadow",
			From = "WestUpper",
			To = "MeadowFord",
			Filter = kind(math.huge, 50),
			Expect = { Status = "Success", Links = { "Elevator" }, Avoids = { "Road" } },
		},
		{
			Name = "tired, home from the plateau: up by the elevator",
			From = "Plateau",
			To = "WestUpper",
			Filter = kind(5, 50),
			Expect = { Status = "Success", Visits = { "Bridge", "Road", "Ground" }, Links = { "Elevator" } },
		},
		{
			Name = "elevator out: a wheelchair can't leave the upper floor",
			From = "WestUpper",
			To = "MeadowFord",
			Filter = kind(math.huge, 50),
			DisabledLinks = { "Elevator" },
			Expect = { Status = "Partial" },
		},
		{
			Name = "radius 2 through the forest from the street",
			From = "Street",
			To = "ForestEast",
			Filter = kind(1, 50, 2),
			Expect = { Status = "Success", Visits = { "Bridge" } },
		},
		-- Negative controls.
		{
			Name = "control: road cost 1 crosses off the crosswalks",
			From = "Street",
			To = "MeadowFord",
			Filter = function(areas: any)
				return { AgentRadius = 1, AreaCosts = { [areas.Road] = 1 } }
			end,
			Expect = { Avoids = { "Road" } },
			MustFail = "Avoids",
		},
		{
			Name = "control: the out-of-service elevator is not ridden",
			From = "WestUpper",
			To = "MeadowFord",
			Filter = kind(5, 50),
			DisabledLinks = { "Elevator" },
			Expect = { Links = { "Elevator" } },
			MustFail = "Links",
		},
	},
}
