-- Authors: Logan Hunt (Raildex)
-- May 13, 2026
--[=[
    @class GraphUtil.spec
    @ignore

    Smoke tests verifying that all sub-modules are correctly exported from
    the GraphUtil aggregator. Individual algorithm tests live in their own
    *.spec.luau files alongside each module.
]=]

local GraphUtil = require("..")

local test_suite = function(t: tiniest)
	local describe = t.describe
	local test = t.test
	local expect = t.expect

	describe("GraphUtil exports", function()
		test("BFS module is exported", function()
			expect(GraphUtil.BFS).exists()
		end)

		test("DFS module is exported", function()
			expect(GraphUtil.DFS).exists()
		end)

		test("Dijkstra module is exported", function()
			expect(GraphUtil.Dijkstra).exists()
		end)

		test("AStar module is exported", function()
			expect(GraphUtil.AStar).exists()
		end)

		test("BellmanFord module is exported", function()
			expect(GraphUtil.BellmanFord).exists()
		end)

		test("Connectivity module is exported", function()
			expect(GraphUtil.Connectivity).exists()
		end)

		test("TopologicalSort module is exported", function()
			expect(GraphUtil.TopologicalSort).exists()
		end)

		test("MST module is exported", function()
			expect(GraphUtil.MST).exists()
		end)
	end)
end

return test_suite
