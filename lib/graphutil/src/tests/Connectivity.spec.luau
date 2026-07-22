local Connectivity = require("../Connectivity")

local test_suite = function(tiniest: tiniest)
	local describe = tiniest.describe
	local test = tiniest.test
	local expect = tiniest.expect

	-- Undirected graph with two components:
	--   A - B - D    (component 1)
	--   |       |
	--   C ------+
	--   E            (component 2)
	local undirAdj = {
		A = { "B", "C" },
		B = { "A", "D" },
		C = { "A", "D" },
		D = { "B", "C" },
		E = {},
	}
	local undirVerts = { "A", "B", "C", "D", "E" }
	local function undirNeighbors(v)
		return undirAdj[v] or {}
	end

	-- Directed graph with a cycle: A→B→C→A, plus D→E (no cycle)
	local dirAdj = {
		A = { "B" },
		B = { "C" },
		C = { "A" },
		D = { "E" },
		E = {},
	}
	local dirVerts = { "A", "B", "C", "D", "E" }
	local function dirNeighbors(v)
		return dirAdj[v] or {}
	end

	-- Directed DAG (no cycles): A→B→D, A→C→D
	local dagAdj = {
		A = { "B", "C" },
		B = { "D" },
		C = { "D" },
		D = {},
	}
	local dagVerts = { "A", "B", "C", "D" }
	local function dagNeighbors(v)
		return dagAdj[v] or {}
	end

	-- Bipartite: A-B-C-D square (even cycle, 2-colorable)
	local bipartiteAdj = {
		A = { "B", "D" },
		B = { "A", "C" },
		C = { "B", "D" },
		D = { "C", "A" },
	}
	local function bipartiteNeighbors(v)
		return bipartiteAdj[v] or {}
	end

	-- Non-bipartite: triangle A-B-C (odd cycle)
	local triAdj = {
		A = { "B", "C" },
		B = { "A", "C" },
		C = { "A", "B" },
	}
	local function triNeighbors(v)
		return triAdj[v] or {}
	end

	-- SCC graph: {A,B,C} strongly connected, {D}, {E}
	local sccAdj = {
		A = { "B" },
		B = { "C" },
		C = { "A" },
		D = { "E" },
		E = {},
	}
	local sccVerts = { "A", "B", "C", "D", "E" }
	local function sccNeighbors(v)
		return sccAdj[v] or {}
	end

	describe("isConnected", function()
		test("start equals goal is always true", function()
			expect(Connectivity.isConnected("A", "A", undirNeighbors)).is(true)
		end)

		test("connected vertices return true", function()
			expect(Connectivity.isConnected("A", "D", undirNeighbors)).is(true)
		end)

		test("disconnected vertices return false", function()
			expect(Connectivity.isConnected("A", "E", undirNeighbors)).is(false)
		end)
	end)

	describe("components", function()
		test("returns correct number of components", function()
			local comps = Connectivity.components(undirVerts, undirNeighbors)
			expect(#comps).is(2)
		end)

		test("components contain the correct total number of vertices", function()
			local comps = Connectivity.components(undirVerts, undirNeighbors)
			local total = 0
			for _, comp in comps do
				total += #comp
			end
			expect(total).is(5)
		end)

		test("each vertex appears in exactly one component", function()
			local comps = Connectivity.components(undirVerts, undirNeighbors)
			local seen = {}
			for _, comp in comps do
				for _, v in comp do
					expect(seen[v]).never_exists()
					seen[v] = true
				end
			end
			expect(seen["A"]).is(true)
			expect(seen["E"]).is(true)
		end)
	end)

	describe("hasDirectedCycle", function()
		test("detects cycle in directed graph", function()
			expect(Connectivity.hasDirectedCycle(dirVerts, dirNeighbors)).is(true)
		end)

		test("returns false for DAG", function()
			expect(Connectivity.hasDirectedCycle(dagVerts, dagNeighbors)).is(false)
		end)
	end)

	describe("hasUndirectedCycle", function()
		test("detects cycle in undirected graph", function()
			expect(Connectivity.hasUndirectedCycle(undirVerts, undirNeighbors)).is(true)
		end)

		test("returns false for a tree (linear/chain graph)", function()
			local treeAdj = {
				A = { "B" },
				B = { "A", "C" },
				C = { "B", "D" },
				D = { "C" },
			}
			local treeVerts = { "A", "B", "C", "D" }
			local function treeNeighbors(v)
				return treeAdj[v] or {}
			end
			expect(Connectivity.hasUndirectedCycle(treeVerts, treeNeighbors)).is(false)
		end)
	end)

	describe("isBipartite", function()
		test("square (even cycle) is bipartite", function()
			expect(Connectivity.isBipartite("A", bipartiteNeighbors)).is(true)
		end)

		test("triangle (odd cycle) is not bipartite", function()
			expect(Connectivity.isBipartite("A", triNeighbors)).is(false)
		end)

		test("single isolated vertex is bipartite", function()
			local function noNeighbors(_v)
				return {}
			end
			expect(Connectivity.isBipartite("X", noNeighbors)).is(true)
		end)
	end)

	describe("stronglyConnectedComponents", function()
		test("returns correct number of SCCs", function()
			local sccs = Connectivity.stronglyConnectedComponents(sccVerts, sccNeighbors)
			expect(#sccs).is(3) -- {A,B,C}, {D}, {E}
		end)

		test("all vertices appear in exactly one SCC", function()
			local sccs = Connectivity.stronglyConnectedComponents(sccVerts, sccNeighbors)
			local seen = {}
			for _, scc in sccs do
				for _, v in scc do
					expect(seen[v]).never_exists()
					seen[v] = true
				end
			end
			for _, v in sccVerts do
				expect(seen[v]).is(true)
			end
		end)

		test("the {A,B,C} cycle forms one SCC of size 3", function()
			local sccs = Connectivity.stronglyConnectedComponents(sccVerts, sccNeighbors)
			local found = false
			for _, scc in sccs do
				if #scc == 3 then
					local set = {}
					for _, v in scc do
						set[v] = true
					end
					if set["A"] and set["B"] and set["C"] then
						found = true
					end
				end
			end
			expect(found).is(true)
		end)

		test("D and E are singleton SCCs", function()
			local sccs = Connectivity.stronglyConnectedComponents(sccVerts, sccNeighbors)
			local singletons = {}
			for _, scc in sccs do
				if #scc == 1 then
					singletons[scc[1]] = true
				end
			end
			expect(singletons["D"]).is(true)
			expect(singletons["E"]).is(true)
		end)

		test("collapses a hub with multiple incoming edges into one SCC", function()
			-- A is a hub: both B and C point back to it, giving A in-degree 2.
			-- The reverse graph then gives A two reverse-neighbours, so the
			-- second (reverse) DFS pass iterates a multi-element predecessor
			-- list rather than the single-predecessor lists of the other tests.
			--   A ⇄ B,  A ⇄ C   →  one SCC {A, B, C}
			local hubAdj = {
				A = { "B", "C" },
				B = { "A" },
				C = { "A" },
			}
			local hubVerts = { "A", "B", "C" }
			local function hubNeighbors(v)
				return hubAdj[v] or {}
			end

			local sccs = Connectivity.stronglyConnectedComponents(hubVerts, hubNeighbors)
			expect(#sccs).is(1)
			expect(#sccs[1]).is(3)
		end)

		test("builds reverse edges for neighbours outside allVertices", function()
			-- "X" is reachable from A but omitted from allVertices, so its
			-- reverse-adjacency entry is created lazily on discovery rather
			-- than pre-seeded. A is still its own singleton SCC.
			local adj = { A = { "X" }, X = {} }
			local sccs = Connectivity.stronglyConnectedComponents({ "A" }, function(v)
				return adj[v] or {}
			end)
			-- Only A is enumerated as a component seed.
			local seen = {}
			for _, scc in sccs do
				for _, v in scc do
					seen[v] = true
				end
			end
			expect(seen["A"]).is(true)
		end)
	end)
end

return test_suite
