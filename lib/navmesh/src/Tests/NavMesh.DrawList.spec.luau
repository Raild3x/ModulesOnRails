-- Authors: Logan Hunt (Raildex)
-- September 28, 2026
-- Debug drawing for a real scene (ticket 26): several paths, a palette, disabled links and tile
-- bounds at the floor's height.

return function(t: tiniest)
	local NavMesh = require("../NavMesh")

	local describe = t.describe
	local expect = t.expect
	local test = t.test

	local Fixtures = NavMesh.Fixtures

	local function v(x: number, y: number, z: number): any
		return vector.create(x, y, z)
	end

	local function flat(y: number, xz: { number }): any
		local ring = {}
		for i = 1, #xz, 2 do
			table.insert(ring, vector.create(xz[i], y, xz[i + 1]))
		end
		return ring
	end

	-- Colour -> primitive count on `layer`.
	local function colors(list: { any }, layer: string): { [string]: number }
		local out = {}
		for _, primitive in list do
			if primitive.Layer == layer then
				out[primitive.Color] = (out[primitive.Color] or 0) + 1
			end
		end
		return out
	end

	describe("ToDrawList", function()
		test("draws a list of paths, each in its PathColors entry", function()
			local mesh = NavMesh.Build(Fixtures.Courtyard.Desc)
			local a = NavMesh.FindPath(mesh, v(1, 0, 1), v(29, 0, 19))
			local b = NavMesh.FindPath(mesh, v(29, 0, 1), v(2, 0, 29))
			local nA, nB = #a.Waypoints, #b.Waypoints
			expect(nA > 1 and nB > 1).is_true()

			local list = NavMesh.ToDrawList(
				mesh,
				{ Triangles = false, PathColors = { "#000001", "#000002" } },
				{ a, b }
			)
			local got = colors(list, "Path")
			expect(got["#000001"]).is(2 * nA - 1) -- a point per waypoint, a line between each pair
			expect(got["#000002"]).is(2 * nB - 1)
			-- Path a starts with a point at waypoint 1, then a line from waypoint 1 to waypoint 2.
			local p1, p2 = a.Waypoints[1].Position, a.Waypoints[2].Position
			expect(list[1].Kind).is("Point")
			local line = list[2].Points
			expect(line[1] == p1.X and line[3] == p1.Z and line[4] == p2.X and line[6] == p2.Z).is_true()

			-- Colours cycle; without PathColors every path takes the default colour.
			got = colors(NavMesh.ToDrawList(mesh, { Triangles = false, PathColors = { "#000003" } }, { a, b }), "Path")
			expect(got["#000003"]).is(2 * (nA + nB) - 2)
			got = colors(NavMesh.ToDrawList(mesh, { Triangles = false }, { a, b }), "Path")
			expect(got["#d81b60"]).is(2 * (nA + nB) - 2)

			-- The single-path call is unchanged, and an empty list draws nothing.
			got = colors(NavMesh.ToDrawList(mesh, { Triangles = false }, a), "Path")
			expect(got["#d81b60"]).is(2 * nA - 1)
			expect(#NavMesh.ToDrawList(mesh, { Triangles = false }, {})).is(0)
		end)

		test("FloorColors, AreaColors and WallColor replace the default palette", function()
			local mesh = NavMesh.Build(Fixtures.OneWayLink.Desc) -- floors Ground (id 1), Ledge (id 2)
			local opts = { FloorColors = { "#000001", "#000002" }, WallColor = "#000003" }
			local list = NavMesh.ToDrawList(mesh, opts)
			expect(next(colors(list, "Floor:Ground"))).is("#000001")
			expect(next(colors(list, "Floor:Ledge"))).is("#000002")
			local walls = colors(list, "Walls")
			expect(next(walls)).is("#000003")
			expect(walls["#212121"]).never_exists()

			local courtyard = NavMesh.Build(Fixtures.Courtyard.Desc) -- areas 1 and 2
			local byArea = colors(
				NavMesh.ToDrawList(courtyard, { Areas = true, AreaColors = { "#00000a", "#00000b" } }),
				"Floor:Ground"
			)
			expect(byArea["#00000a"] > 0 and byArea["#00000b"] > 0).is_true()
			expect(byArea["#9e9e9e"]).never_exists()
		end)

		test("disabled links are drawn in their own colour", function()
			-- LinkJump plus a one-way second link across the same gap.
			local desc = table.clone(Fixtures.LinkJump.Desc)
			desc.Links = table.clone(desc.Links :: any)
			table.insert(desc.Links :: any, { From = v(9, 0, 8), To = v(15, 0, 8), Bidirectional = false })
			local mesh = NavMesh.Build(desc)
			local enabled = colors(NavMesh.ToDrawList(mesh, { Triangles = false, Links = true }), "Links")
			expect(enabled["#6a1b9a"]).is(3)
			NavMesh.SetLinkEnabled(mesh, 1, false)
			local disabled = colors(NavMesh.ToDrawList(mesh, { Triangles = false, Links = true }), "Links")
			expect(disabled["#6a1b9a"]).is(1) -- link 2 is still enabled
			expect(disabled["#ce93d8"]).is(2) -- link 1, both ways
		end)

		test("tile bounds sit at the lowest height of the tile's floor", function()
			local mesh = NavMesh.Build(Fixtures.OneWayLink.Desc) -- Ledge at y = 4, ground at y = 0
			local heights: { [number]: number } = {}
			for _, primitive in NavMesh.ToDrawList(mesh, { Triangles = false, Tiles = true }) do
				expect(primitive.Points[2]).is(primitive.Points[5])
				heights[primitive.Points[2]] = (heights[primitive.Points[2]] or 0) + 1
			end
			expect(heights[4] > 0 and heights[0] > 0).is_true()

			-- A tile emptied by an obstacle has no height to use: its bounds are drawn at 0.
			local pad = NavMesh.Build {
				TileSize = 32,
				Floors = { G = { Walkable = { flat(2, { 0, 0, 64, 0, 64, 32, 0, 32 }) } } },
			}
			NavMesh.AddObstacle(pad, "G", flat(2, { 31, -1, 65, -1, 65, 33, 31, 33 }))
			NavMesh.Update(pad)
			heights = {}
			for _, primitive in NavMesh.ToDrawList(pad, { Triangles = false, Tiles = true }) do
				heights[primitive.Points[2]] = (heights[primitive.Points[2]] or 0) + 1
			end
			expect(heights[2]).is(4)
			expect(heights[0]).is(4)

			-- A one-triangle tile still takes its height.
			local tri = NavMesh.Build { Floors = { G = { Walkable = { flat(3, { 0, 0, 4, 0, 0, 4 }) } } } }
			for _, primitive in NavMesh.ToDrawList(tri, { Triangles = false, Tiles = true }) do
				expect(primitive.Points[2]).is(3)
			end
		end)
	end)
end
