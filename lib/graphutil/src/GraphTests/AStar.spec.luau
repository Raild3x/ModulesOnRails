local AStar = require("../AStar")

local test_suite = function(tiniest: tiniest)
	local describe = tiniest.describe
	local test = tiniest.test
	local expect = tiniest.expect

	-- Weighted undirected graph:
	--   A --2-- B --1-- D
	--   |               |
	--   3               4
	--   |               |
	--   C ------5-------+
	local weights = {
		A = { B = 2, C = 3 },
		B = { A = 2, D = 1 },
		C = { A = 3, D = 5 },
		D = { B = 1, C = 5 },
	}
	local function getNeighbors(v)
		local result = {}
		for k in pairs(weights[v] or {}) do
			table.insert(result, k)
		end
		return result
	end
	local function getWeight(u, v)
		return weights[u][v]
	end

	-- Zero heuristic degrades A* to Dijkstra — still optimal
	local function zeroHeuristic(_v, _goal)
		return 0
	end

	-- Overestimating heuristic to verify that inadmissible heuristics
	-- do not crash the algorithm (even if result may be suboptimal)
	local function hugeHeuristic(_v, _goal)
		return 1000
	end

	describe("search", function()
		test("start equals goal returns zero-cost single-vertex path", function()
			local result = AStar.search("A", "A", getNeighbors, getWeight, zeroHeuristic)
			expect(result).exists()
			expect(result.cost).is(0)
			expect(#result.path).is(1)
			expect(result.path[1]).is("A")
		end)

		test("zero heuristic finds optimal path A→D (cost 3)", function()
			local result = AStar.search("A", "D", getNeighbors, getWeight, zeroHeuristic)
			expect(result).exists()
			expect(result.cost).is(3)
			expect(result.path[1]).is("A")
			expect(result.path[#result.path]).is("D")
		end)

		test("zero heuristic finds direct edge A→C (cost 3)", function()
			local result = AStar.search("A", "C", getNeighbors, getWeight, zeroHeuristic)
			expect(result).exists()
			expect(result.cost).is(3)
		end)

		test("path is contiguous (each step is a valid edge)", function()
			local result = AStar.search("A", "D", getNeighbors, getWeight, zeroHeuristic)
			expect(result).exists()
			local path = result.path
			for i = 1, #path - 1 do
				local u, v = path[i], path[i + 1]
				expect(weights[u] and weights[u][v] ~= nil).is(true)
			end
		end)

		test("returns nil when goal is unreachable", function()
			local function noNeighbors(_v)
				return {}
			end
			local result = AStar.search("A", "D", noNeighbors, getWeight, zeroHeuristic)
			expect(result).never_exists()
		end)

		test("inadmissible heuristic still returns a path (not necessarily optimal)", function()
			-- A* should not error with a bad heuristic, just potentially return a suboptimal path
			local result = AStar.search("A", "D", getNeighbors, getWeight, hugeHeuristic)
			expect(result).exists()
			expect(result.path[1]).is("A")
			expect(result.path[#result.path]).is("D")
		end)

		test("path cost matches sum of edge weights", function()
			local result = AStar.search("A", "D", getNeighbors, getWeight, zeroHeuristic)
			expect(result).exists()
			local path = result.path
			local total = 0
			for i = 1, #path - 1 do
				total += getWeight(path[i], path[i + 1])
			end
			expect(total).is(result.cost)
		end)
	end)
end

return test_suite
