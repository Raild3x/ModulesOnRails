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

	-- Chain graph A—B—C—D—E where the start vertex is NOT adjacent to every
	-- other vertex. Prim discovers C, D, E only after expanding an interior
	-- vertex, so it takes the "first time seeing this neighbour" branch that a
	-- star-shaped graph (where every vertex neighbours the start) never hits.
	--   A —1— B —1— C —1— D —1— E
	local chainWeights = {
		A = { B = 1 },
		B = { A = 1, C = 1 },
		C = { B = 1, D = 1 },
		D = { C = 1, E = 1 },
		E = { D = 1 },
	}
	local chainVerts = { "A", "B", "C", "D", "E" }
	local function chainNeighbors(v)
		local result = {}
		for k in pairs(chainWeights[v] or {}) do
			table.insert(result, k)
		end
		return result
	end
	local function chainWeight(u, v)
		return chainWeights[u][v]
	end

	describe("prim (chain graph)", function()
		test("spans a chain where the start only borders one vertex", function()
			local edges = MST.prim("A", chainNeighbors, chainWeight)
			expect(#edges).is(#chainVerts - 1)
			expect(totalWeight(edges)).is(4) -- every edge is required
		end)

		test("all vertices are spanned", function()
			local edges = MST.prim("A", chainNeighbors, chainWeight)
			local spanned = { A = true }
			for _, e in edges do
				spanned[e.from] = true
				spanned[e.to] = true
			end
			for _, v in chainVerts do
				expect(spanned[v]).is(true)
			end
		end)

		test("accepts the iterator form of getNeighbors", function()
			local function iterNeighbors(v)
				local keys = {}
				for k in pairs(chainWeights[v] or {}) do
					table.insert(keys, k)
				end
				local i = 0
				return function()
					i += 1
					return keys[i]
				end
			end
			local edges = MST.prim("A", iterNeighbors, chainWeight)
			expect(totalWeight(edges)).is(4)
		end)
	end)

	describe("kruskal (union-by-rank stress)", function()
		-- Two equal-height subtrees {1,2,3,4} and are grown from cheap edges,
		-- then a single low-rank vertex is unioned into the taller tree LAST.
		-- Because the smaller-id endpoint (the lone vertex) is the shorter
		-- tree, union must swap its roots by rank — a branch a small
		-- star/diamond graph never reaches.
		local rankVerts = { "1", "2", "3", "4", "5" }
		-- Weights chosen so the processing order is:
		--   2-3, 4-5 (rank 1 pairs), 2-4 (rank 2), then 1-2 (lone → tall)
		local rankWeights = {
			["1"] = { ["2"] = 4 },
			["2"] = { ["3"] = 1, ["4"] = 3, ["1"] = 4 },
			["3"] = { ["2"] = 1 },
			["4"] = { ["5"] = 1, ["2"] = 3 },
			["5"] = { ["4"] = 1 },
		}
		local function rankNeighbors(v)
			local result = {}
			for k in pairs(rankWeights[v] or {}) do
				table.insert(result, k)
			end
			return result
		end
		local function rankWeight(u, v)
			return rankWeights[u][v]
		end

		test("produces a spanning tree of V-1 edges", function()
			local edges = MST.kruskal(rankVerts, rankNeighbors, rankWeight)
			expect(#edges).is(#rankVerts - 1)
		end)

		test("total weight is minimal (1+1+3+4 = 9)", function()
			local edges = MST.kruskal(rankVerts, rankNeighbors, rankWeight)
			expect(totalWeight(edges)).is(9)
		end)

		test("all vertices are spanned exactly once (no cycle)", function()
			local edges = MST.kruskal(rankVerts, rankNeighbors, rankWeight)
			local spanned = {}
			for _, e in edges do
				spanned[e.from] = true
				spanned[e.to] = true
			end
			for _, v in rankVerts do
				expect(spanned[v]).is(true)
			end
		end)

		test("compresses a deep union-find chain (multi-step find)", function()
			-- Edges are weighted so Kruskal unions two rank-2 subtrees into a
			-- rank-3 tree, leaving vertex 8 three levels below the root
			-- (8 → 7 → 5 → 1). The final edge 8—9 then unions vertex 8 into a
			-- new singleton, forcing find(8) to walk (and path-halve) that
			-- depth-3 chain — its loop runs more than one iteration.
			local deepVerts = { "1", "2", "3", "4", "5", "6", "7", "8", "9" }
			local deepWeights = {
				["1"] = { ["2"] = 1, ["3"] = 3, ["5"] = 7 },
				["2"] = { ["1"] = 1 },
				["3"] = { ["4"] = 2, ["1"] = 3 },
				["4"] = { ["3"] = 2 },
				["5"] = { ["6"] = 4, ["1"] = 7, ["7"] = 6 },
				["6"] = { ["5"] = 4 },
				["7"] = { ["5"] = 6, ["8"] = 5 },
				["8"] = { ["7"] = 5, ["9"] = 8 },
				["9"] = { ["8"] = 8 },
			}
			local function deepNeighbors(v)
				local result = {}
				for k in pairs(deepWeights[v] or {}) do
					table.insert(result, k)
				end
				return result
			end
			local function deepWeight(u, v)
				return deepWeights[u][v]
			end

			local edges = MST.kruskal(deepVerts, deepNeighbors, deepWeight)
			expect(#edges).is(#deepVerts - 1) -- 8 tree edges spanning 9 vertices
			expect(totalWeight(edges)).is(36) -- 1+2+3+4+5+6+7+8
			local spanned = {}
			for _, e in edges do
				spanned[e.from] = true
				spanned[e.to] = true
			end
			for _, v in deepVerts do
				expect(spanned[v]).is(true)
			end
		end)

		test("ignores edges to neighbours absent from allVertices", function()
			-- "Q" is returned as a neighbour of A/B but is not listed in
			-- allVertices, so it has no Union-Find id. Kruskal must skip those
			-- dangling edges and still build the MST over the known vertices.
			--   A —1— B,  A —9— Q(unknown),  B —9— Q(unknown)
			local danglingWeights = {
				A = { B = 1, Q = 9 },
				B = { A = 1, Q = 9 },
			}
			local function danglingNeighbors(v)
				local result = {}
				for k in pairs(danglingWeights[v] or {}) do
					table.insert(result, k)
				end
				return result
			end
			local function danglingWeight(u, v)
				return danglingWeights[u][v]
			end

			local edges = MST.kruskal({ "A", "B" }, danglingNeighbors, danglingWeight)
			expect(#edges).is(1) -- only the A—B edge; Q is skipped
			expect(edges[1].weight).is(1)
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
