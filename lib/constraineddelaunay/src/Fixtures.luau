--!strict
-- Authors: Logan Hunt (Raildex)
-- September 25, 2026
--[=[
	@class ConstrainedDelaunayFixtures
	@private

	Shared scenario data for specs, the render script and benchmarks. Plain data only.

	Lives in `src/` (not `src/Tests/`) on purpose: the debug packages reach it through their
	dependency on this package, so it ships to consumers. Keep it small.
]=]

--[=[
	@within ConstrainedDelaunayFixtures
	@interface Ring
	.Group number -- winding group the ring's edges belong to
	.Points { number } -- flat x,y pairs; the ring closes back to its first point
]=]
export type Ring = {
	Group: number,
	Points: { number },
}

--[=[
	@within ConstrainedDelaunayFixtures
	@interface Scenario
	.Name string
	.Rings { Ring }
]=]
export type Scenario = {
	Name: string,
	Rings: { Ring },
}

local Types = require("./Types")

-- Generic winding groups for the fixtures. The CDT gives groups no meaning; the fixture names
-- say how the scenario combines them (NavMesh owns its own group meanings).
local GROUP_WALKABLE = 1
local GROUP_OBSTACLE = 2
local GROUP_TILE = 3

local Fixtures = {}

-- A 10x10 square (CCW) with a 2x2 hole (CW) in the same group.
Fixtures.SquareWithHole = {
	Name = "SquareWithHole",
	Rings = {
		{ Group = GROUP_WALKABLE, Points = { 0, 0, 10, 0, 10, 10, 0, 10 } },
		{ Group = GROUP_WALKABLE, Points = { 4, 4, 4, 6, 6, 6, 6, 4 } },
	},
} :: Scenario

-- Two obstacles that overlap each other inside one walkable square.
Fixtures.OverlappingObstacles = {
	Name = "OverlappingObstacles",
	Rings = {
		{ Group = GROUP_WALKABLE, Points = { 0, 0, 20, 0, 20, 20, 0, 20 } },
		{ Group = GROUP_OBSTACLE, Points = { 3, 3, 9, 3, 9, 9, 3, 9 } },
		{ Group = GROUP_OBSTACLE, Points = { 6, 6, 12, 6, 12, 12, 6, 12 } },
	},
} :: Scenario

-- A walkable edge lying exactly on a tile boundary (x = 10): coincident constraints.
Fixtures.CoincidentTileEdge = {
	Name = "CoincidentTileEdge",
	Rings = {
		{ Group = GROUP_WALKABLE, Points = { 2, 2, 10, 2, 10, 8, 2, 8 } },
		{ Group = GROUP_TILE, Points = { 0, 0, 10, 0, 10, 10, 0, 10 } },
	},
} :: Scenario

-- Two walkable rings sharing the edge x = 5.
Fixtures.SharedEdge = {
	Name = "SharedEdge",
	Rings = {
		{ Group = GROUP_WALKABLE, Points = { 0, 0, 5, 0, 5, 5, 0, 5 } },
		{ Group = GROUP_WALKABLE, Points = { 5, 0, 10, 0, 10, 5, 5, 5 } },
	},
} :: Scenario

--[=[
	@within ConstrainedDelaunayFixtures

	Converts a scenario to a `TriangulateInput`: every ring's points in order, one directed
	edge per ring side (closing back to the first point), tagged with the ring's group.
	Points shared between rings are emitted per ring; the CDT merges exact duplicates.
]=]
function Fixtures.ToInput(scenario: Scenario): Types.TriangulateInput
	local coords: { number } = {}
	local edges: { number } = {}
	local groups: { number } = {}
	local base = 0
	for _, ring in scenario.Rings do
		local points = ring.Points
		local count = #points // 2
		for i = 1, count do
			table.insert(coords, points[2 * i - 1])
			table.insert(coords, points[2 * i])
			table.insert(edges, base + i)
			table.insert(edges, base + (i % count) + 1)
			table.insert(groups, ring.Group)
		end
		base += count
	end
	return { Coords = coords, Edges = edges, EdgeGroups = groups }
end

-- Every scenario defined above, sorted by name, so a new fixture can never be left out.
local all: { Scenario } = {}
for _, value in Fixtures :: { [string]: any } do
	if type(value) == "table" and value.Rings ~= nil then
		table.insert(all, value :: Scenario)
	end
end
table.sort(all, function(a: Scenario, b: Scenario): boolean
	return a.Name < b.Name
end)

--[=[
	@within ConstrainedDelaunayFixtures
	@prop All { Scenario }
	Every scenario, sorted by `Name` (built automatically).
]=]
Fixtures.All = all

return Fixtures
