local Dijkstra = require("../Dijkstra")

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
	-- Shortest A→D = A→B→D (cost 3)
	-- Shortest A→C = A→C   (cost 3)
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

	-- Disconnected vertex
	local allNeighbors = function(v)
		if v == "Z" then
			return {}
		end
		return getNeighbors(v)
	end

	describe("shortestPath", function()
		test("start equals goal returns zero-cost single-vertex path", function()
			local result = Dijkstra.shortestPath("A", "A", getNeighbors, getWeight)
			expect(result).exists()
			expect(result.cost).is(0)
			expect(#result.path).is(1)
			expect(result.path[1]).is("A")
		end)

		test("finds optimal path A→D (cost 3 via B)", function()
			local result = Dijkstra.shortestPath("A", "D", getNeighbors, getWeight)
			expect(result).exists()
			expect(result.cost).is(3)
			expect(result.path[1]).is("A")
			expect(result.path[#result.path]).is("D")
		end)

		test("finds direct edge A→C (cost 3)", function()
			local result = Dijkstra.shortestPath("A", "C", getNeighbors, getWeight)
			expect(result).exists()
			expect(result.cost).is(3)
			expect(result.path[1]).is("A")
			expect(result.path[#result.path]).is("C")
		end)

		test("returns nil for unreachable goal", function()
			local result = Dijkstra.shortestPath("A", "Z", allNeighbors, getWeight)
			expect(result).never_exists()
		end)
	end)

	describe("distances", function()
		test("distance to start is 0", function()
			local d = Dijkstra.distances("A", getNeighbors, getWeight)
			expect(d["A"]).is(0)
		end)

		test("computes all shortest distances from A", function()
			local d = Dijkstra.distances("A", getNeighbors, getWeight)
			expect(d["B"]).is(2)
			expect(d["C"]).is(3)
			expect(d["D"]).is(3)
		end)

		test("unreachable vertices are absent from result", function()
			local d = Dijkstra.distances("A", allNeighbors, getWeight)
			expect(d["Z"]).never_exists()
		end)
	end)

	describe("forEach", function()
		test("first yielded vertex is start with cost 0", function()
			local iter = Dijkstra.forEach("A", getNeighbors, getWeight)
			local v, c = iter()
			expect(v).is("A")
			expect(c).is(0)
		end)

		test("yields vertices in non-decreasing cost order", function()
			local iter = Dijkstra.forEach("A", getNeighbors, getWeight)
			local lastCost = -1
			local v, c = iter()
			while v ~= nil do
				expect(c >= lastCost).is(true)
				lastCost = c :: number
				v, c = iter()
			end
		end)

		test("yields all reachable vertices", function()
			local visited = {}
			for v, _ in Dijkstra.forEach("A", getNeighbors, getWeight) do
				visited[v] = true
			end
			expect(visited["A"]).is(true)
			expect(visited["B"]).is(true)
			expect(visited["C"]).is(true)
			expect(visited["D"]).is(true)
		end)

		test("returns nil, nil when exhausted", function()
			local iter = Dijkstra.forEach("A", getNeighbors, getWeight)
			-- drain
			while true do
				local v, _ = iter()
				if v == nil then
					break
				end
			end
			local v2, c2 = iter()
			expect(v2).is(nil)
			expect(c2).is(nil)
		end)
	end)

	describe("toArray", function()
		test("returns all reachable vertices as VisitRecords", function()
			local records = Dijkstra.toArray("A", getNeighbors, getWeight)
			expect(#records).is(4)
		end)

		test("first record is start with cost 0", function()
			local records = Dijkstra.toArray("A", getNeighbors, getWeight)
			expect(records[1].vertex).is("A")
			expect(records[1].cost).is(0)
		end)

		test("records are in non-decreasing cost order", function()
			local records = Dijkstra.toArray("A", getNeighbors, getWeight)
			for i = 2, #records do
				expect(records[i].cost >= records[i - 1].cost).is(true)
			end
		end)
	end)
end

return test_suite
