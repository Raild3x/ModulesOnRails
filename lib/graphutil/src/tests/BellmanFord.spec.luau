local BellmanFord = require("../BellmanFord")

local test_suite = function(tiniest: tiniest)
	local describe = tiniest.describe
	local test = tiniest.test
	local expect = tiniest.expect

	-- Positive-weight directed graph:
	--   A --1-- B --3-- D
	--           |
	--           2
	--           |
	--           C
	local posWeights = {
		A = { B = 1 },
		B = { C = 2, D = 3 },
		C = {},
		D = {},
	}
	local posVerts = { "A", "B", "C", "D" }
	local function posNeighbors(v)
		local result = {}
		for k in pairs(posWeights[v] or {}) do
			table.insert(result, k)
		end
		return result
	end
	local function posWeight(u, v)
		return posWeights[u][v]
	end

	-- Negative-weight directed graph (no negative cycles):
	--   A --1-- B ---(-2)--- C
	local negWeights = {
		A = { B = 1 },
		B = { C = -2 },
		C = {},
	}
	local negVerts = { "A", "B", "C" }
	local function negNeighbors(v)
		local result = {}
		for k in pairs(negWeights[v] or {}) do
			table.insert(result, k)
		end
		return result
	end
	local function negWeight(u, v)
		return negWeights[u][v]
	end

	-- Negative-cycle graph: B → C → B with total weight -1
	--   A --1-- B ---(-1)--- C ---(-1)--- B  (cycle)
	local cycleAdj = {
		A = { "B" },
		B = { "C" },
		C = { "B" }, -- closes a -2-total-weight cycle
	}
	local cycleWeights = {
		A = { B = 1 },
		B = { C = -1 },
		C = { B = -1 },
	}
	local cycleVerts = { "A", "B", "C" }
	local function cycleNeighbors(v)
		return cycleAdj[v] or {}
	end
	local function cycleWeight(u, v)
		return cycleWeights[u][v]
	end

	describe("shortestPath", function()
		test("positive weights: finds correct path A→C", function()
			local result, negCycle = BellmanFord.shortestPath("A", "C", posVerts, posNeighbors, posWeight)
			expect(negCycle).is(false)
			expect(result).exists()
			expect(result.cost).is(3) -- 1 + 2
			expect(result.path[1]).is("A")
			expect(result.path[#result.path]).is("C")
		end)

		test("positive weights: finds correct path A→D", function()
			local result, negCycle = BellmanFord.shortestPath("A", "D", posVerts, posNeighbors, posWeight)
			expect(negCycle).is(false)
			expect(result).exists()
			expect(result.cost).is(4) -- 1 + 3
		end)

		test("negative weights: finds optimal path A→C (cost -1)", function()
			local result, negCycle = BellmanFord.shortestPath("A", "C", negVerts, negNeighbors, negWeight)
			expect(negCycle).is(false)
			expect(result).exists()
			expect(result.cost).is(-1) -- 1 + (-2)
			expect(result.path[1]).is("A")
			expect(result.path[#result.path]).is("C")
		end)

		test("returns nil and false when goal is unreachable", function()
			local result, negCycle = BellmanFord.shortestPath("C", "A", negVerts, negNeighbors, negWeight)
			expect(negCycle).is(false)
			expect(result).never_exists()
		end)

		test("detects negative-weight cycle", function()
			local result, negCycle = BellmanFord.shortestPath("A", "C", cycleVerts, cycleNeighbors, cycleWeight)
			expect(negCycle).is(true)
			expect(result).never_exists()
		end)

		test("path cost matches sum of edge weights", function()
			local result, _ = BellmanFord.shortestPath("A", "C", posVerts, posNeighbors, posWeight)
			expect(result).exists()
			local path = result.path
			local total = 0
			for i = 1, #path - 1 do
				total += posWeight(path[i], path[i + 1])
			end
			expect(total).is(result.cost)
		end)
	end)

	describe("distances", function()
		test("distance to start is 0", function()
			local d, _ = BellmanFord.distances("A", posVerts, posNeighbors, posWeight)
			expect(d["A"]).is(0)
		end)

		test("computes all shortest distances correctly", function()
			local d, _ = BellmanFord.distances("A", posVerts, posNeighbors, posWeight)
			expect(d["B"]).is(1)
			expect(d["C"]).is(3)
			expect(d["D"]).is(4)
		end)

		test("unreachable vertices have math.huge distance", function()
			local d, _ = BellmanFord.distances("C", posVerts, posNeighbors, posWeight)
			expect(d["A"]).is(math.huge)
			expect(d["B"]).is(math.huge)
		end)

		test("negative weights computed correctly", function()
			local d, negCycle = BellmanFord.distances("A", negVerts, negNeighbors, negWeight)
			expect(negCycle).is(false)
			expect(d["B"]).is(1)
			expect(d["C"]).is(-1)
		end)

		test("reports negative cycle", function()
			local _, negCycle = BellmanFord.distances("A", cycleVerts, cycleNeighbors, cycleWeight)
			expect(negCycle).is(true)
		end)
	end)
end

return test_suite
