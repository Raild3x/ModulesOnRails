local MST = require("../MST")

local test_suite = function(tiniest: tiniest)
	local describe = tiniest.describe
	local test = tiniest.test
	local expect = tiniest.expect

	-- Weighted undirected graph (from MST class docs):
	--   A --1-- B
	--   |  \    |
	--   4   3   2
	--   |    \  |
	--   D --5-- C
	-- MST edges: A-B(1), B-C(2), A-D(4)  total = 7
	local weights = {
		A = { B = 1, C = 3, D = 4 },
		B = { A = 1, C = 2 },
		C = { B = 2, A = 3, D = 5 },
		D = { A = 4, C = 5 },
	}
	local allVerts = { "A", "B", "C", "D" }
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

	local function totalWeight(edges)
		local sum = 0
		for _, e in edges do
			sum += e.weight
		end
		return sum
	end

	local function hasEdge(edges, u, v)
		for _, e in edges do
			if (e.from == u and e.to == v) or (e.from == v and e.to == u) then
				return true
			end
		end
		return false
	end

	describe("prim", function()
		test("returns V-1 edges for a connected graph", function()
			local edges = MST.prim("A", getNeighbors, getWeight)
			expect(#edges).is(#allVerts - 1)
		end)

		test("total weight equals MST weight (7)", function()
			local edges = MST.prim("A", getNeighbors, getWeight)
			expect(totalWeight(edges)).is(7)
		end)

		test("MST includes cheapest A-B edge (weight 1)", function()
			local edges = MST.prim("A", getNeighbors, getWeight)
			expect(hasEdge(edges, "A", "B")).is(true)
		end)

		test("MST includes B-C edge (weight 2)", function()
			local edges = MST.prim("A", getNeighbors, getWeight)
			expect(hasEdge(edges, "B", "C")).is(true)
		end)

		test("MST does not include expensive C-D edge (weight 5)", function()
			local edges = MST.prim("A", getNeighbors, getWeight)
			expect(hasEdge(edges, "C", "D")).is(false)
		end)

		test("all vertices are spanned", function()
			local edges = MST.prim("A", getNeighbors, getWeight)
			local spanned = {}
			for _, e in edges do
				spanned[e.from] = true
				spanned[e.to] = true
			end
			-- start vertex is also in the spanning set (implicitly)
			spanned["A"] = true
			for _, v in allVerts do
				expect(spanned[v]).is(true)
			end
		end)
	end)

	describe("kruskal", function()
		test("returns V-1 edges for a connected graph", function()
			local edges = MST.kruskal(allVerts, getNeighbors, getWeight)
			expect(#edges).is(#allVerts - 1)
		end)

		test("total weight equals MST weight (7)", function()
			local edges = MST.kruskal(allVerts, getNeighbors, getWeight)
			expect(totalWeight(edges)).is(7)
		end)

		test("MST includes cheapest A-B edge (weight 1)", function()
			local edges = MST.kruskal(allVerts, getNeighbors, getWeight)
			expect(hasEdge(edges, "A", "B")).is(true)
		end)

		test("MST includes B-C edge (weight 2)", function()
			local edges = MST.kruskal(allVerts, getNeighbors, getWeight)
			expect(hasEdge(edges, "B", "C")).is(true)
		end)

		test("MST does not include expensive C-D edge (weight 5)", function()
			local edges = MST.kruskal(allVerts, getNeighbors, getWeight)
			expect(hasEdge(edges, "C", "D")).is(false)
		end)

		test("all vertices are spanned", function()
			local edges = MST.kruskal(allVerts, getNeighbors, getWeight)
			local spanned = {}
			for _, e in edges do
				spanned[e.from] = true
				spanned[e.to] = true
			end
			for _, v in allVerts do
				expect(spanned[v]).is(true)
			end
		end)
	end)

	describe("prim vs kruskal", function()
		test("both produce the same total MST weight", function()
			local primEdges = MST.prim("A", getNeighbors, getWeight)
			local kruskalEdges = MST.kruskal(allVerts, getNeighbors, getWeight)
			expect(totalWeight(primEdges)).is(totalWeight(kruskalEdges))
		end)

		test("both return the same number of edges", function()
			local primEdges = MST.prim("A", getNeighbors, getWeight)
			local kruskalEdges = MST.kruskal(allVerts, getNeighbors, getWeight)
			expect(#primEdges).is(#kruskalEdges)
		end)
	end)
end

return test_suite
