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

	describe("bidirectionalShortestPath", function()
		test("start equals goal returns zero-cost single-vertex path", function()
			local result = Dijkstra.bidirectionalShortestPath("A", "A", getNeighbors, getWeight)
			expect(result).exists()
			expect(result.cost).is(0)
			expect(#result.path).is(1)
			expect(result.path[1]).is("A")
		end)

		test("finds optimal path A→D (cost 3 via B)", function()
			local result = Dijkstra.bidirectionalShortestPath("A", "D", getNeighbors, getWeight)
			expect(result).exists()
			expect(result.cost).is(3)
			expect(result.path[1]).is("A")
			expect(result.path[#result.path]).is("D")
		end)

		test("finds direct edge A→C (cost 3)", function()
			local result = Dijkstra.bidirectionalShortestPath("A", "C", getNeighbors, getWeight)
			expect(result).exists()
			expect(result.cost).is(3)
			expect(result.path[1]).is("A")
			expect(result.path[#result.path]).is("C")
		end)

		test("returns nil for unreachable goal", function()
			local result = Dijkstra.bidirectionalShortestPath("A", "Z", allNeighbors, getWeight)
			expect(result).never_exists()
		end)

		test("path cost matches sum of edge weights", function()
			local result = Dijkstra.bidirectionalShortestPath("A", "D", getNeighbors, getWeight)
			expect(result).exists()
			local path = result.path
			local total = 0
			for i = 1, #path - 1 do
				total += getWeight(path[i], path[i + 1])
			end
			expect(total).is(result.cost)
		end)

		test("matches Dijkstra.shortestPath cost across every reachable pair", function()
			local vertices = { "A", "B", "C", "D" }
			for _, s in vertices do
				for _, g in vertices do
					local single = Dijkstra.shortestPath(s, g, getNeighbors, getWeight)
					local bidir = Dijkstra.bidirectionalShortestPath(s, g, getNeighbors, getWeight)
					if single == nil then
						expect(bidir).never_exists()
					else
						expect(bidir).exists()
						expect((bidir :: any).cost).is(single.cost)
					end
				end
			end
		end)

		test("directed graph: finds the path using an explicit reverse-neighbors callback", function()
			-- Directed: A --1--> B --1--> D, A --5--> D (direct but pricier)
			local dirWeights = {
				A = { B = 1, D = 5 },
				B = { D = 1 },
				D = {},
			}
			local reverseAdj = {
				A = {},
				B = { "A" },
				D = { "A", "B" },
			}
			local function getDirNeighbors(v)
				local result = {}
				for k in pairs(dirWeights[v] or {}) do
					table.insert(result, k)
				end
				return result
			end
			local function getDirWeight(u, v)
				return dirWeights[u][v]
			end
			local function getDirReverseNeighbors(v)
				return reverseAdj[v] or {}
			end

			local result = Dijkstra.bidirectionalShortestPath(
				"A",
				"D",
				getDirNeighbors,
				getDirWeight,
				getDirReverseNeighbors
			)
			expect(result).exists()
			expect(result.cost).is(2) -- A→B→D, not the direct A→D edge
			expect(#result.path).is(3)
		end)

		test("directed graph: correctly reports unreachable when only a one-way edge exists", function()
			local dirWeights = { A = { B = 1 }, B = {} }
			local reverseAdj = { A = {}, B = { "A" } }
			local function getDirNeighbors(v)
				local result = {}
				for k in pairs(dirWeights[v] or {}) do
					table.insert(result, k)
				end
				return result
			end
			local function getDirWeight(u, v)
				return dirWeights[u][v]
			end
			local function getDirReverseNeighbors(v)
				return reverseAdj[v] or {}
			end

			local backward = Dijkstra.bidirectionalShortestPath(
				"B",
				"A",
				getDirNeighbors,
				getDirWeight,
				getDirReverseNeighbors
			)
			expect(backward).never_exists()
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

	describe("toIterator", function()
		test("first yielded vertex is start with cost 0", function()
			local iter = Dijkstra.toIterator("A", getNeighbors, getWeight)
			local v, c = iter()
			expect(v).is("A")
			expect(c).is(0)
		end)

		test("yields vertices in non-decreasing cost order", function()
			local iter = Dijkstra.toIterator("A", getNeighbors, getWeight)
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
			for v, _ in Dijkstra.toIterator("A", getNeighbors, getWeight) do
				visited[v] = true
			end
			expect(visited["A"]).is(true)
			expect(visited["B"]).is(true)
			expect(visited["C"]).is(true)
			expect(visited["D"]).is(true)
		end)

		test("drains past several trailing stale entries before signalling exhaustion", function()
			-- T1 and T2 are each reachable cheaply (cost 2, via A) but also
			-- carry an expensive direct edge (cost 10) from S. Those two
			-- expensive entries remain in the heap as the highest-cost stale
			-- duplicates, so the final iterator call pops BOTH of them before
			-- the heap empties and it returns nil.
			--   S →1 A,  S →10 T1,  S →10 T2,  A →1 T1,  A →1 T2
			local twinAdj = {
				S = { A = 1, T1 = 10, T2 = 10 },
				A = { T1 = 1, T2 = 1 },
				T1 = {},
				T2 = {},
			}
			local function twinNeighbors(v)
				local result = {}
				for k in pairs(twinAdj[v] or {}) do
					table.insert(result, k)
				end
				return result
			end
			local function twinWeight(u, v)
				return twinAdj[u][v]
			end

			local seen = {}
			local count = 0
			for v, c in Dijkstra.toIterator("S", twinNeighbors, twinWeight) do
				expect(seen[v]).never_exists()
				seen[v] = c
				count += 1
			end
			expect(count).is(4)
			expect(seen["T1"]).is(2) -- cheapest cost, not the stale 10
			expect(seen["T2"]).is(2)
		end)

		test("returns nil, nil when exhausted", function()
			local iter = Dijkstra.toIterator("A", getNeighbors, getWeight)
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

		test("forEach is an alias of toIterator", function()
			expect(Dijkstra.forEach).is(Dijkstra.toIterator)
		end)
	end)

	-- Directed graph that forces a STALE HEAP ENTRY: C is first discovered at
	-- cost 4 (direct A→C) and pushed, then relaxed to cost 2 (A→B→C) and
	-- pushed again. The cost-4 entry is popped after C is already settled and
	-- must be skipped — exercising the `visited[vertex]` continue guards in
	-- shortestPath, distances, and toIterator.
	--   A →1 B,  A →4 C,  B →1 C,  C →1 D
	local staleAdj = {
		A = { B = 1, C = 4 },
		B = { C = 1 },
		C = { D = 1 },
		D = {},
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

	describe("stale heap entries", function()
		test("shortestPath skips the stale entry and returns the cheaper path", function()
			local result = Dijkstra.shortestPath("A", "D", staleNeighbors, staleWeight)
			expect(result).exists()
			expect(result.cost).is(3) -- A→B→C→D (1+1+1), not A→C→D (4+1)
			expect(result.path[1]).is("A")
			expect(result.path[#result.path]).is("D")
		end)

		test("distances records the relaxed (cheaper) cost to C", function()
			local d = Dijkstra.distances("A", staleNeighbors, staleWeight)
			expect(d["C"]).is(2) -- via B, not the direct cost-4 edge
			expect(d["D"]).is(3)
		end)

		test("toIterator yields each vertex once at its cheapest cost", function()
			local seen = {}
			for v, c in Dijkstra.toIterator("A", staleNeighbors, staleWeight) do
				expect(seen[v]).never_exists() -- a stale duplicate must not be yielded again
				seen[v] = c
			end
			expect(seen["C"]).is(2)
			expect(seen["D"]).is(3)
		end)
	end)

	describe("iterator-form getNeighbors", function()
		-- getNeighbors may return a stateful iterator () -> V? instead of an
		-- array. Results must match the array form exactly.
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

		test("shortestPath matches the array form", function()
			local result = Dijkstra.shortestPath("A", "D", iterNeighbors, getWeight)
			expect(result).exists()
			expect(result.cost).is(3)
		end)

		test("distances match the array form", function()
			local d = Dijkstra.distances("A", iterNeighbors, getWeight)
			expect(d["B"]).is(2)
			expect(d["C"]).is(3)
			expect(d["D"]).is(3)
		end)
	end)

	-- Longer weighted undirected graph with a "shortcut" edge at each end.
	-- The shortcuts (S–B and C–G, both weight 4) are more expensive than the
	-- two-hop path, so B and C are each settled cheaply first and their
	-- shortcut heap entries become stale — exercising the fSettled/bSettled
	-- guards. With start and goal five weight-units apart, the meeting point
	-- lands mid-path, so BOTH the forward and backward path reconstructions
	-- run for several hops.
	--        1     1     1     1     1
	--   S ── A ── B ── C ── D ── G
	--        \____/         \____/
	--        (S–B = 4)     (C–G = 4)
	local biWeights = {
		S = { A = 1, B = 4 },
		A = { S = 1, B = 1 },
		B = { A = 1, S = 4, C = 1 },
		C = { B = 1, D = 1, G = 4 },
		D = { C = 1, G = 1 },
		G = { D = 1, C = 4 },
	}
	local biVerts = { "S", "A", "B", "C", "D", "G" }
	local function biNeighbors(v)
		local result = {}
		for k in pairs(biWeights[v] or {}) do
			table.insert(result, k)
		end
		return result
	end
	local function biWeight(u, v)
		return biWeights[u][v]
	end

	describe("bidirectionalShortestPath (longer graph)", function()
		test("finds the optimal S→G path (cost 5) skipping the shortcut edges", function()
			local result = Dijkstra.bidirectionalShortestPath("S", "G", biNeighbors, biWeight)
			expect(result).exists()
			expect(result.cost).is(5) -- S-A-B-C-D-G, not either weight-4 shortcut
			expect(result.path[1]).is("S")
			expect(result.path[#result.path]).is("G")
		end)

		test("reconstructed path is contiguous and cost matches its edges", function()
			local result = Dijkstra.bidirectionalShortestPath("S", "G", biNeighbors, biWeight)
			expect(result).exists()
			local path = result.path
			local total = 0
			for i = 1, #path - 1 do
				total += biWeight(path[i], path[i + 1])
			end
			expect(total).is(result.cost)
		end)

		test("matches Dijkstra.shortestPath cost across every reachable pair", function()
			for _, s in biVerts do
				for _, g in biVerts do
					local single = Dijkstra.shortestPath(s, g, biNeighbors, biWeight)
					local bidir = Dijkstra.bidirectionalShortestPath(s, g, biNeighbors, biWeight)
					if single == nil then
						expect(bidir).never_exists()
					else
						expect(bidir).exists()
						expect((bidir :: any).cost).is(single.cost)
					end
				end
			end
		end)
	end)

	-- A long central path (weight-2 edges, total 12) with a cheap dead-end
	-- diamond hanging off each end. Each diamond lets a vertex (X near start,
	-- Y near goal) be settled cheaply (cost 2) while its direct weight-5 edge
	-- lingers in the heap as a stale entry. Because the two frontiers only
	-- meet near the middle (~cost 6), the cost-5 stale entries are popped
	-- before termination — exercising the fSettled/bSettled skip guards that a
	-- short graph terminates too early to reach.
	--   X                                   Y
	--   |1   \5                        5/   1|
	--   A      S=P=Q=R=U=W=G      (=  is weight 2)      B
	--         5/  (S-X=5)          (G-Y=5)  \5
	local settleWeights = {
		S = { A = 1, X = 5, P = 2 },
		A = { S = 1, X = 1 },
		X = { S = 5, A = 1 },
		P = { S = 2, Q = 2 },
		Q = { P = 2, R = 2 },
		R = { Q = 2, U = 2 },
		U = { R = 2, W = 2 },
		W = { U = 2, G = 2 },
		G = { W = 2, B = 1, Y = 5 },
		B = { G = 1, Y = 1 },
		Y = { G = 5, B = 1 },
	}
	local settleVerts = { "S", "A", "X", "P", "Q", "R", "U", "W", "G", "B", "Y" }
	local function settleNeighbors(v)
		local result = {}
		for k in pairs(settleWeights[v] or {}) do
			table.insert(result, k)
		end
		return result
	end
	local function settleWeight(u, v)
		return settleWeights[u][v]
	end

	describe("bidirectionalShortestPath (stale settled vertices)", function()
		test("finds the S→G path of cost 12 down the central chain", function()
			local result = Dijkstra.bidirectionalShortestPath("S", "G", settleNeighbors, settleWeight)
			expect(result).exists()
			expect(result.cost).is(12)
			expect(result.path[1]).is("S")
			expect(result.path[#result.path]).is("G")
		end)

		test("matches Dijkstra.shortestPath cost across every reachable pair", function()
			for _, s in settleVerts do
				for _, g in settleVerts do
					local single = Dijkstra.shortestPath(s, g, settleNeighbors, settleWeight)
					local bidir = Dijkstra.bidirectionalShortestPath(s, g, settleNeighbors, settleWeight)
					if single == nil then
						expect(bidir).never_exists()
					else
						expect(bidir).exists()
						expect((bidir :: any).cost).is(single.cost)
					end
				end
			end
		end)

		test("toIterator drains every vertex once past a stale interior entry", function()
			-- X is settled at cost 2 but leaves a stale cost-5 heap entry. As
			-- the iterator drains, that stale entry is popped and skipped in
			-- the SAME call that then pops the next (costlier) fresh vertex, so
			-- the iterator's inner loop runs more than once in a single call.
			local seen = {}
			local count = 0
			for v, c in Dijkstra.toIterator("S", settleNeighbors, settleWeight) do
				expect(seen[v]).never_exists()
				seen[v] = c
				count += 1
			end
			expect(count).is(#settleVerts) -- all 11 vertices, each yielded once
			expect(seen["X"]).is(2) -- cheapest cost, not the stale 5
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

		describe("shortestPath", function()
			test("predicate returning true on the first expansion aborts with nil", function()
				local result = Dijkstra.shortestPath("A", "D", getNeighbors, getWeight, function()
					return true
				end)
				expect(result).never_exists()
			end)

			test("a predicate that never fires is identical to omitting it", function()
				local result = Dijkstra.shortestPath("A", "D", getNeighbors, getWeight, function()
					return false
				end)
				expect(result).exists()
				expect(result.cost).is(3)
			end)

			test("the goal is never passed to shouldStop (goal check wins)", function()
				local result = Dijkstra.shortestPath("A", "D", getNeighbors, getWeight, function(v)
					return v == "D"
				end)
				expect(result).exists()
				expect(result.cost).is(3)
			end)

			test("a cost budget stops the search before a too-far goal is reached", function()
				local result = Dijkstra.shortestPath("A", "E", chainNeighbors, chainWeight, function(_v, cost)
					return cost > 2
				end)
				expect(result).never_exists()
			end)
		end)

		describe("distances", function()
			test("returns the partial map accumulated before the stop", function()
				local d = Dijkstra.distances("A", chainNeighbors, chainWeight, function(_v, cost)
					return cost > 1
				end)
				expect(d["A"]).is(0)
				expect(d["B"]).is(1)
				expect(d["C"]).is(2) -- settled just before the predicate fired
				expect(d["D"]).never_exists() -- never reached
				expect(d["E"]).never_exists()
			end)

			test("a predicate that never fires yields the full map", function()
				local d = Dijkstra.distances("A", chainNeighbors, chainWeight, function()
					return false
				end)
				expect(d["E"]).is(4)
			end)
		end)

		describe("bidirectionalShortestPath", function()
			test("predicate returning true on the first settled vertex aborts with nil", function()
				local result = Dijkstra.bidirectionalShortestPath("A", "D", getNeighbors, getWeight, nil, function()
					return true
				end)
				expect(result).never_exists()
			end)

			test("a predicate firing only on a backward-side vertex aborts with nil", function()
				-- The backward search settles the goal "D" first; the predicate
				-- fires there, exercising the backward-branch cancellation.
				local result = Dijkstra.bidirectionalShortestPath("A", "D", getNeighbors, getWeight, nil, function(v)
					return v == "D"
				end)
				expect(result).never_exists()
			end)

			test("a predicate that never fires is identical to omitting it", function()
				local result = Dijkstra.bidirectionalShortestPath("A", "D", getNeighbors, getWeight, nil, function()
					return false
				end)
				expect(result).exists()
				expect(result.cost).is(3)
			end)
		end)
	end)
end

return test_suite
