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

	describe("shortestPath", function()
		test("start equals goal returns zero-cost single-vertex path", function()
			local result = AStar.shortestPath("A", "A", getNeighbors, getWeight, zeroHeuristic)
			expect(result).exists()
			expect(result.cost).is(0)
			expect(#result.path).is(1)
			expect(result.path[1]).is("A")
		end)

		test("zero heuristic finds optimal path A→D (cost 3)", function()
			local result = AStar.shortestPath("A", "D", getNeighbors, getWeight, zeroHeuristic)
			expect(result).exists()
			expect(result.cost).is(3)
			expect(result.path[1]).is("A")
			expect(result.path[#result.path]).is("D")
		end)

		test("zero heuristic finds direct edge A→C (cost 3)", function()
			local result = AStar.shortestPath("A", "C", getNeighbors, getWeight, zeroHeuristic)
			expect(result).exists()
			expect(result.cost).is(3)
		end)

		test("path is contiguous (each step is a valid edge)", function()
			local result = AStar.shortestPath("A", "D", getNeighbors, getWeight, zeroHeuristic)
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
			local result = AStar.shortestPath("A", "D", noNeighbors, getWeight, zeroHeuristic)
			expect(result).never_exists()
		end)

		test("returns nil after exploring a whole component when goal is unreachable", function()
			-- The goal "Z" is disconnected, but several vertices are reachable
			-- from the start, so the search expands the full A→B→C chain (the
			-- main loop runs multiple times) before the frontier empties.
			--   A →1 B →1 C   |   Z (isolated)
			local chainAdj = {
				A = { B = 1 },
				B = { C = 1 },
				C = {},
				Z = {},
			}
			local function chainNeighbors(v)
				local result = {}
				for k in pairs(chainAdj[v] or {}) do
					table.insert(result, k)
				end
				return result
			end
			local function chainWeight(u, v)
				return chainAdj[u][v]
			end

			local result = AStar.shortestPath("A", "Z", chainNeighbors, chainWeight, zeroHeuristic)
			expect(result).never_exists()
		end)

		test("inadmissible heuristic still returns a path (not necessarily optimal)", function()
			-- A* should not error with a bad heuristic, just potentially return a suboptimal path
			local result = AStar.shortestPath("A", "D", getNeighbors, getWeight, hugeHeuristic)
			expect(result).exists()
			expect(result.path[1]).is("A")
			expect(result.path[#result.path]).is("D")
		end)

		test("path cost matches sum of edge weights", function()
			local result = AStar.shortestPath("A", "D", getNeighbors, getWeight, zeroHeuristic)
			expect(result).exists()
			local path = result.path
			local total = 0
			for i = 1, #path - 1 do
				total += getWeight(path[i], path[i + 1])
			end
			expect(total).is(result.cost)
		end)

		test("skips a stale heap entry when a vertex is relaxed to a cheaper cost", function()
			-- C is first reached at g=4 (direct A→C) and pushed, then relaxed
			-- to g=2 (A→B→C) and pushed again. The stale g=4 entry sits below
			-- the goal's g=5 in the heap, so it is popped (and must be skipped
			-- as already-visited) before the goal is reached.
			--   A →1 B,  A →4 C,  B →1 C,  C →1 D,  D →2 E
			local staleAdj = {
				A = { B = 1, C = 4 },
				B = { C = 1 },
				C = { D = 1 },
				D = { E = 2 },
				E = {},
			}
			local function staleNeighbors(v)
				local result = {}
				for k in pairs(staleAdj[v] or {}) do
					table.insert(result, k)
				end
				return result
			end
			local function staleWeight(u, v)
				return staleAdj[u][v]
			end

			local result = AStar.shortestPath("A", "E", staleNeighbors, staleWeight, zeroHeuristic)
			expect(result).exists()
			expect(result.cost).is(5) -- A→B→C→D→E (1+1+1+2), not A→C→D→E (4+1+2)
			expect(result.path[1]).is("A")
			expect(result.path[#result.path]).is("E")
		end)

		test("reopens a closed vertex for an admissible but inconsistent heuristic", function()
			-- Admissibility alone must guarantee optimality, which requires
			-- re-opening a vertex if a cheaper path to it is found after it was
			-- popped. This heuristic is admissible but *inconsistent* (h(X)=3
			-- drops to h(C)=0 across an edge of weight 1).
			--
			--   S →1 X →1 C →2 G        (optimal S→X→C→G = 4)
			--   S ─────3───→ C          (decoy: S→C→G = 5)
			--
			-- The heuristic makes A* pop C at the decoy cost g=3 *before* X is
			-- expanded; X then relaxes C down to g=2. Without re-opening, C's
			-- edge to G is never re-relaxed and the search returns the
			-- suboptimal cost 5.
			local adj = {
				S = { X = 1, C = 3 },
				X = { C = 1 },
				C = { G = 2 },
				G = {},
			}
			local function adjNeighbors(v)
				local result = {}
				for k in pairs(adj[v] or {}) do
					table.insert(result, k)
				end
				return result
			end
			local function adjWeight(u, v)
				return adj[u][v]
			end
			-- Inconsistent yet admissible: never exceeds true remaining cost
			-- (d(C,G)=2, d(X,G)=3, d(S,G)=4).
			local hVals = { S = 0, X = 3, C = 0, G = 0 }
			local function inconsistentHeuristic(v, _goal)
				return hVals[v]
			end

			local result = AStar.shortestPath("S", "G", adjNeighbors, adjWeight, inconsistentHeuristic)
			expect(result).exists()
			expect(result.cost).is(4) -- S→X→C→G (1+1+2), not the decoy S→C→G (3+2)
			expect(result.path[1]).is("S")
			expect(result.path[#result.path]).is("G")
		end)

		test("accepts the iterator form of getNeighbors", function()
			-- getNeighbors may return a stateful iterator () -> V? instead of
			-- an array; the result must match the array form.
			local function iterNeighbors(v)
				local keys = {}
				for k in pairs(weights[v] or {}) do
					table.insert(keys, k)
				end
				local i = 0
				return function()
					i += 1
					return keys[i]
				end
			end

			local result = AStar.shortestPath("A", "D", iterNeighbors, getWeight, zeroHeuristic)
			expect(result).exists()
			expect(result.cost).is(3)
			expect(result.path[1]).is("A")
			expect(result.path[#result.path]).is("D")
		end)
	end)

	describe("shouldStop", function()
		-- A →1 B →1 C →1 D →1 E chain for deterministic budget testing.
		local chainAdj = {
			A = { B = 1 },
			B = { C = 1 },
			C = { D = 1 },
			D = { E = 1 },
			E = {},
		}
		local function chainNeighbors(v)
			local result = {}
			for k in pairs(chainAdj[v] or {}) do
				table.insert(result, k)
			end
			return result
		end
		local function chainWeight(u, v)
			return chainAdj[u][v]
		end

		test("predicate returning true on the first expansion aborts with nil", function()
			local result = AStar.shortestPath("A", "D", getNeighbors, getWeight, zeroHeuristic, function()
				return true
			end)
			expect(result).never_exists()
		end)

		test("a predicate that never fires is identical to omitting it", function()
			local result = AStar.shortestPath("A", "D", getNeighbors, getWeight, zeroHeuristic, function()
				return false
			end)
			expect(result).exists()
			expect(result.cost).is(3)
		end)

		test("the goal is never passed to shouldStop (goal check wins)", function()
			-- Predicate would fire on the goal, but the goal is returned before
			-- shouldStop is ever evaluated for it.
			local result = AStar.shortestPath("A", "D", getNeighbors, getWeight, zeroHeuristic, function(v)
				return v == "D"
			end)
			expect(result).exists()
			expect(result.cost).is(3)
			expect(result.path[#result.path]).is("D")
		end)

		test("a cost budget stops the search before a too-far goal is reached", function()
			-- Goal E is at cost 4; budget of 2 stops the search first.
			local result = AStar.shortestPath("A", "E", chainNeighbors, chainWeight, zeroHeuristic, function(_v, cost)
				return cost > 2
			end)
			expect(result).never_exists()
		end)

		test("a budget larger than the path cost still finds the goal", function()
			local result = AStar.shortestPath("A", "E", chainNeighbors, chainWeight, zeroHeuristic, function(_v, cost)
				return cost > 100
			end)
			expect(result).exists()
			expect(result.cost).is(4)
		end)
	end)
end

return test_suite
