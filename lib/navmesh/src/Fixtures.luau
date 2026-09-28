--!strict
-- Authors: Logan Hunt (Raildex)
-- September 25, 2026
--[=[
	@class NavMeshFixtures
	@private

	Shared NavMesh scenarios (`{ Name, Desc }`) for specs, the render script and benchmarks.
	Plain data only. Lives in `src/` on purpose so the debug packages can reach it through
	their dependency. Scenarios arrive with the tickets that need them (single-tile Build
	onwards); every scenario defined here is listed in `All` automatically.
]=]

--[=[
	@within NavMeshFixtures
	@interface Scenario
	.Name string
	.Desc any -- a NavMeshDesc (typed once the NavMesh API lands)
]=]
export type Scenario = {
	Name: string,
	Desc: any,
}

local Fixtures = {}

-- A ring from flat {x, z, ...} pairs at height `y`.
local function flat(y: number, xz: { number }): { vector }
	local ring = {}
	for i = 1, #xz, 2 do
		table.insert(ring, vector.create(xz[i], y, xz[i + 1]))
	end
	return ring
end

-- A ring from flat {x, y, z, ...} triples.
local function points(xyz: { number }): { vector }
	local ring = {}
	for i = 1, #xyz, 3 do
		table.insert(ring, vector.create(xyz[i], xyz[i + 1], xyz[i + 2]))
	end
	return ring
end

--[=[
	@within NavMeshFixtures
	@prop Courtyard Scenario
	An L-shaped flat yard with a hole, two overlapping crates, a crate across the outer wall,
	and a patch of area 2.
]=]
Fixtures.Courtyard = {
	Name = "Courtyard",
	Desc = {
		Floors = {
			Ground = {
				Walkable = { flat(0, { 0, 0, 30, 0, 30, 20, 18, 20, 18, 30, 0, 30 }) },
				Obstacles = {
					flat(0, { 12, 12, 16, 12, 16, 16, 12, 16 }), -- a hole in the yard
					flat(0, { 4, 3, 9, 3, 9, 7, 4, 7 }),
					flat(0, { 7, 5, 11, 5, 11, 9, 7, 9 }), -- overlaps the crate above
					flat(0, { 26, 8, 33, 8, 33, 11, 26, 11 }), -- sticks out through the east wall
				},
				Areas = { { Polygon = flat(0, { 2, 20, 10, 20, 10, 28, 2, 28 }), Area = 2 } },
			},
		},
	},
}

--[=[
	@within NavMeshFixtures
	@prop SplitLevel Scenario
	Two walkable rings sharing an edge: a flat pad (y = 0) and a ramp rising 0.5 per stud
	along +X. The shared edge is a crease that must survive.
]=]
Fixtures.SplitLevel = {
	Name = "SplitLevel",
	Desc = {
		Floors = {
			Ground = {
				Walkable = {
					flat(0, { 0, 0, 10, 0, 10, 10, 0, 10 }),
					points { 10, 0, 0, 20, 5, 0, 20, 5, 10, 10, 0, 10 },
				},
			},
		},
	},
}

--[=[
	@within NavMeshFixtures
	@prop TwistedQuad Scenario
	One non-planar ring (a corner lifted to y = 5): its surface triangulation's diagonal is a
	crease no triangle may cross.
]=]
Fixtures.TwistedQuad = {
	Name = "TwistedQuad",
	Desc = {
		Floors = {
			Ground = {
				Walkable = { points { 0, 0, 0, 12, 0, 0, 10, 5, 10, 0, 0, 8 } },
				Obstacles = { flat(0, { 4, 3, 6, 3, 6, 5, 4, 5 }) },
			},
		},
	},
}

--[=[
	@within NavMeshFixtures
	@prop ShallowObstacles Scenario
	Thin obstacles crossing at shallow angles (SR2): the sliver-prone case for snap rounding
	and the degeneracy guard.
]=]
Fixtures.ShallowObstacles = {
	Name = "ShallowObstacles",
	Desc = {
		Floors = {
			Ground = {
				Walkable = { flat(0, { 0, 0, 40, 0, 40, 20, 0, 20 }) },
				Obstacles = {
					flat(0, { 2, 9.9, 38, 10.4, 38, 10.7, 2, 10.2 }),
					flat(0, { 2, 10.6, 38, 9.95, 38, 10.25, 2, 10.9 }),
					flat(0, { 5, 4, 35, 4.3, 35, 4.31, 5, 4.02 }),
				},
			},
		},
	},
}

--[=[
	@within NavMeshFixtures
	@prop ThreeFloorStairs Scenario
	Ground (y = 0, 40 x 20) runs on under a ramp. The ramp (Stairs, x = 10..20, z = 0..4) climbs
	to a mezzanine (Upper, y = 5, x = 20..40). Seams join Ground to Stairs at x = 10 and Stairs to
	Upper at x = 20. The Ground seam edge keeps its Ground neighbour on both sides, so crossing
	it can go onto the ramp or on under it.
]=]
Fixtures.ThreeFloorStairs = {
	Name = "ThreeFloorStairs",
	Desc = {
		Floors = {
			Ground = { Walkable = { flat(0, { 0, 0, 40, 0, 40, 20, 0, 20 }) } },
			Stairs = { Walkable = { points { 10, 0, 0, 20, 5, 0, 20, 5, 4, 10, 0, 4 } } },
			Upper = { Walkable = { flat(5, { 20, 0, 40, 0, 40, 20, 20, 20 }) } },
		},
		Seams = {
			{ FloorA = "Ground", FloorB = "Stairs", From = vector.create(10, 0, 0), To = vector.create(10, 0, 4) },
			{ FloorA = "Stairs", FloorB = "Upper", From = vector.create(20, 5, 0), To = vector.create(20, 5, 4) },
		},
	},
}

--[=[
	@within NavMeshFixtures
	@prop LinkJump Scenario
	Two pads with a 4-stud gap, joined by a two-way link labelled "Jump".
]=]
Fixtures.LinkJump = {
	Name = "LinkJump",
	Desc = {
		Floors = {
			Ground = {
				Walkable = { flat(0, { 0, 0, 10, 0, 10, 10, 0, 10 }), flat(0, { 14, 0, 24, 0, 24, 10, 14, 10 }) },
			},
		},
		Links = { { From = vector.create(9, 0, 5), To = vector.create(15, 0, 5), Label = "Jump" } },
	},
}

--[=[
	@within NavMeshFixtures
	@prop OneWayLink Scenario
	A ledge (y = 4) with a one-way drop, labelled "Drop", to the ground beside it.
]=]
Fixtures.OneWayLink = {
	Name = "OneWayLink",
	Desc = {
		Floors = {
			Ledge = { Walkable = { flat(4, { 0, 0, 10, 0, 10, 10, 0, 10 }) } },
			Ground = { Walkable = { flat(0, { 12, 0, 22, 0, 22, 10, 12, 10 }) } },
		},
		Links = {
			{ From = vector.create(9, 4, 5), To = vector.create(13, 0, 5), Bidirectional = false, Label = "Drop" },
		},
	},
}

-- Every scenario defined above, sorted by name, so a new fixture can never be left out.
local all: { Scenario } = {}
for _, value in Fixtures :: { [string]: any } do
	if type(value) == "table" and value.Desc ~= nil then
		table.insert(all, value :: Scenario)
	end
end
table.sort(all, function(a: Scenario, b: Scenario): boolean
	return a.Name < b.Name
end)

--[=[
	@within NavMeshFixtures
	@prop All { Scenario }
	Every scenario, sorted by `Name` (built automatically).
]=]
Fixtures.All = all

return Fixtures
