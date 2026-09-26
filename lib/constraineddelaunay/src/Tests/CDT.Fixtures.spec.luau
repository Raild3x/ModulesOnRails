-- Authors: Logan Hunt (Raildex)
-- September 25, 2026

return function(t: tiniest)
	local Fixtures = require("../Fixtures")

	local describe = t.describe
	local expect = t.expect
	local test = t.test
	local snapshot = t.snapshot

	local GROUP_COLORS = { "#2e7d32", "#c62828", "#1565c0" }

	-- Phase 0 stand-in for CDT.ToDrawList (which waits on the R4 layout): the rings as lines.
	local function outlineDrawList(scenario: Fixtures.Scenario): { any }
		local list = {}
		for _, ring in scenario.Rings do
			local points = ring.Points
			local count = #points // 2
			for i = 1, count do
				local j = i % count + 1
				table.insert(list, {
					Kind = "Line",
					Points = { points[2 * i - 1], 0, points[2 * i], points[2 * j - 1], 0, points[2 * j] },
					Color = GROUP_COLORS[ring.Group] or "#000000",
					Layer = "Constraints",
				})
			end
		end
		return list
	end

	describe("Fixtures.All", function()
		test("lists every scenario, sorted by name", function()
			local names = {}
			for _, scenario in Fixtures.All do
				table.insert(names, scenario.Name)
			end
			expect(table.concat(names, ",")).is("CoincidentTileEdge,OverlappingObstacles,SharedEdge,SquareWithHole")
		end)
	end)

	describe("Fixtures.ToInput", function()
		test("emits every ring as closed directed edges tagged with its group", function()
			local input = Fixtures.ToInput(Fixtures.SquareWithHole)
			expect(input.Coords).is_shallow_equal { 0, 0, 10, 0, 10, 10, 0, 10, 4, 4, 4, 6, 6, 6, 6, 4 }
			expect(input.Edges).is_shallow_equal { 1, 2, 2, 3, 3, 4, 4, 1, 5, 6, 6, 7, 7, 8, 8, 5 }
			expect(input.EdgeGroups).is_shallow_equal { 1, 1, 1, 1, 1, 1, 1, 1 }
		end)

		test("keeps each ring's group", function()
			local input = Fixtures.ToInput(Fixtures.OverlappingObstacles)
			expect(input.EdgeGroups).is_shallow_equal { 1, 1, 1, 1, 2, 2, 2, 2, 2, 2, 2, 2 }
		end)
	end)

	describe("fixture outlines", function()
		for _, scenario in Fixtures.All do
			test(scenario.Name, function()
				snapshot(outlineDrawList(scenario))
			end)
		end
	end)
end
