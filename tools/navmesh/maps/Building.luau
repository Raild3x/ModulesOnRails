--!strict
-- The two-storey building (tickets 34 and 35), shared by Maps/Building and Maps/BuildingRamp.
--
-- 60 x 40 inside (x 0..60, z 0..40), on a lot 20 studs wider each way. Walls 1 thick and 24
-- tall, an 8-wide doorway in the south wall. The upper floor is a 1-stud slab whose top is at
-- y 12, with holes over the stairs.
-- - The main stair rises 1 stud per 1.5-stud tread, 6 wide, with a U-turn at a landing (top 6):
--   flight 1 climbs east along z 28..34 from x 36, the landing is x 43.5..49.5, z 22..34, and
--   flight 2 climbs back west along z 22..28 to the upper floor at x 36.
-- - The narrow stair is 3 wide, straight, along the south wall (z 1..4), climbing east from x 4
--   to the upper floor at x 20.5.
-- Options:
-- - `Ramps`: swap the main stair's flights for wedge ramps with the same rise and run.
-- - `Elevator` (ticket 35): a shaft at x 2..8, z 10..16 with its doors facing north, and a
--   two-way link labelled "Elevator" between the landing points (5, 0, 18) and (5, 12, 18). Its
--   Cost (56 studs: 3.5 s at 16 studs/s, the ride and doors with the cab already waiting) is a
--   floor; a game scales it per query with `AreaCosts[ELEVATOR_AREA]` for the current wait.
--   Every step Part gets `NavArea` STAIRS_AREA, so NPCs can price the stairs.
-- Returns the walkable Parts, the obstacles, the links and the cab Part (or nil).

type Rbx = { Instance: any, Vector3: any, CFrame: any, Color3: any, Enum: any }

local Parts = require("./Parts")

local TREAD, RISE = 1.5, 1
local GROUND, SLAB, WALL = { 70, 72, 78 }, { 196, 170, 120 }, { 120, 120, 135 }
local STAIR, LANDING = { 150, 120, 90 }, { 170, 140, 100 }

local STAIRS_AREA, ELEVATOR_AREA = 5, 6

local function build(rbx: Rbx, parent: Instance?, options: { Ramps: boolean?, Elevator: boolean? }?)
	local o = options or {}
	local ramps = o.Ramps == true
	local P = Parts(rbx, parent)
	local V3, CF = rbx.Vector3, rbx.CFrame
	local walkable, obstacles = {}, {}
	local function walk(p)
		table.insert(walkable, p)
	end
	local function block(p)
		table.insert(obstacles, p)
	end

	walk(P.slab("Ground", -20, -20, 80, 60, 0, GROUND))

	-- Upper floor slab (y 11..12) around the two stair holes.
	walk(P.slab("Upper", 0, 0, 60, 1, 12, SLAB)) -- south strip, along the narrow stair
	walk(P.slab("Upper", 0, 4, 60, 22, 12, SLAB))
	walk(P.slab("Upper", 0, 34, 60, 40, 12, SLAB))
	walk(P.slab("Upper", 0, 1, 4, 4, 12, SLAB)) -- behind the narrow stair's foot
	walk(P.slab("Upper", 20.5, 1, 60, 4, 12, SLAB)) -- the narrow stair's head
	walk(P.slab("Upper", 0, 22, 36, 34, 12, SLAB)) -- the main stair's head (west of x 36)
	walk(P.slab("Upper", 49.5, 22, 60, 34, 12, SLAB))

	-- Walls, with the doorway at x 26..34 in the south wall.
	block(P.box("Wall", -1, -1, 26, 0, 0, 24, WALL))
	block(P.box("Wall", 34, -1, 61, 0, 0, 24, WALL))
	block(P.box("Lintel", 26, -1, 34, 0, 8, 16, WALL))
	block(P.box("Wall", -1, 40, 61, 41, 0, 24, WALL))
	block(P.box("Wall", -1, 0, 0, 40, 0, 24, WALL))
	block(P.box("Wall", 60, 0, 61, 40, 0, 24, WALL))

	-- The main stair.
	walk(P.box("Landing", 43.5, 22, 49.5, 34, 0, 6, LANDING))
	if ramps then
		-- Wedges rise towards their +Z: turned so flight 1 rises east and flight 2 west.
		-- Each flight's five treads run x 36..43.5 and rise 6 (the 6th rise is the landing's or
		-- the upper floor's edge).
		walk(P.part("WedgePart", "Ramp", V3.new(6, 6, 7.5), CF.new(39.75, 3, 31) * CF.Angles(0, math.pi / 2, 0), STAIR))
		walk(
			P.part("WedgePart", "Ramp", V3.new(6, 6, 7.5), CF.new(39.75, 9, 25) * CF.Angles(0, -math.pi / 2, 0), STAIR)
		)
		block(P.box("RampBase", 36, 22, 43.5, 28, 0, 6, STAIR))
	else
		for i = 1, 5 do
			local x = 36 + TREAD * (i - 1)
			walk(P.box("Step", x, 28, x + TREAD, 34, 0, RISE * i, STAIR))
		end
		for j = 7, 11 do
			local x = 43.5 - TREAD * (j - 6)
			walk(P.box("Step", x, 22, x + TREAD, 28, 0, RISE * j, STAIR))
		end
	end

	-- The narrow stair, always steps.
	for i = 1, 11 do
		local x = 4 + TREAD * (i - 1)
		walk(P.box("Narrow", x, 1, x + TREAD, 4, 0, RISE * i, STAIR))
	end

	local links, cab = {}, nil
	if o.Elevator then
		for _, p in walkable do
			if p.Name == "Step" or p.Name == "Narrow" then
				p:SetAttribute("NavArea", STAIRS_AREA)
			end
		end
		block(P.box("Shaft", 2, 10, 8, 16, 0, 24, WALL))
		cab = P.box("Cab", 2.5, 10.5, 7.5, 15.5, 0.05, 8, { 220, 200, 60 }) -- shown in Studio, not navigated
		table.insert(links, {
			From = V3.new(5, 0, 18),
			To = V3.new(5, 12, 18),
			Cost = 56,
			Area = ELEVATOR_AREA,
			Label = "Elevator",
		})
	end
	return walkable, obstacles, links, cab
end

return {
	Build = build,
	STAIRS_AREA = STAIRS_AREA,
	ELEVATOR_AREA = ELEVATOR_AREA,
}
