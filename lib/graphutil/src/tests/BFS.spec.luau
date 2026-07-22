local BFS = require("../BFS")

local test_suite = function(tiniest: tiniest)
	local describe = tiniest.describe
	local test = tiniest.test
	local expect = tiniest.expect

	-- Undirected graph:
	--   A - B - D
	--   |       |
	--   C ------+
	-- E is isolated (no edges)
	local adj = {
		A = { "B", "C" },
		B = { "A", "D" },
		C = { "A", "D" },
		D = { "B", "C" },
		E = {},
	}
	local function getNeighbors(v)
		return adj[v] or {}
	end

	-- Helper: check a table contains exactly a set of values (order-independent)
	local function containsAll(tbl, expected)
		if #tbl ~= #expected then
			return false
		end
		local set = {}
		for _, v in tbl do
			set[v] = true
		end
		for _, v in expected do
			if not set[v] then
				return false
			end
		end
		return true
	end

	describe("toArray", function()
		test("starts with the start vertex", function()
			local result = BFS.toArray("A", getNeighbors)
			expect(result[1]).is("A")
		end)

		test("visits all reachable vertices exactly once", function()
			local result = BFS.toArray("A", getNeighbors)
			expect(containsAll(result, { "A", "B", "C", "D" })).is(true)
		end)

		test("does not visit unreachable vertices", function()
			local result = BFS.toArray("A", getNeighbors)
			expect(#result).is(4) -- E is not reachable
		end)

		test("isolated vertex returns only itself", function()
			local result = BFS.toArray("E", getNeighbors)
			expect(#result).is(1)
			expect(result[1]).is("E")
		end)
	end)

	describe("toSet", function()
		test("marks all reachable vertices true", function()
			local set = BFS.toSet("A", getNeighbors)
			expect(set["A"]).is(true)
			expect(set["B"]).is(true)
			expect(set["C"]).is(true)
			expect(set["D"]).is(true)
		end)

		test("does not include unreachable vertices", function()
			local set = BFS.toSet("A", getNeighbors)
			expect(set["E"]).never_exists()
		end)

		test("isolated vertex set contains only itself", function()
			local set = BFS.toSet("E", getNeighbors)
			expect(set["E"]).is(true)
			expect(set["A"]).never_exists()
		end)
	end)

	describe("toIterator", function()
		test("yields all reachable vertices", function()
			local iter = BFS.toIterator("A", getNeighbors)
			local visited = {}
			local v = iter()
			while v ~= nil do
				visited[v] = true
				v = iter()
			end
			expect(visited["A"]).is(true)
			expect(visited["B"]).is(true)
			expect(visited["C"]).is(true)
			expect(visited["D"]).is(true)
		end)

		test("first yielded value is start", function()
			local iter = BFS.toIterator("A", getNeighbors)
			expect(iter()).is("A")
		end)

		test("returns nil when exhausted", function()
			local iter = BFS.toIterator("E", getNeighbors)
			iter() -- "E"
			expect(iter()).is(nil)
			expect(iter()).is(nil) -- stable after exhaustion
		end)

		test("works in a for loop", function()
			local count = 0
			for _ in BFS.toIterator("A", getNeighbors) do
				count += 1
			end
			expect(count).is(4)
		end)

		test("forEach is an alias of toIterator", function()
			expect(BFS.forEach).is(BFS.toIterator)
		end)
	end)

	describe("shortestPath", function()
		test("start equals goal returns single-vertex path", function()
			local result = BFS.shortestPath("A", "A", getNeighbors)
			expect(result).exists()
			expect(result.cost).is(0)
			expect(#result.path).is(1)
			expect(result.path[1]).is("A")
		end)

		test("returns correct path length and cost (A→D, 2 hops)", function()
			local result = BFS.shortestPath("A", "D", getNeighbors)
			expect(result).exists()
			expect(result.cost).is(2)
			expect(#result.path).is(3)
			expect(result.path[1]).is("A")
			expect(result.path[#result.path]).is("D")
		end)

		test("returns correct 1-hop path (A→B)", function()
			local result = BFS.shortestPath("A", "B", getNeighbors)
			expect(result).exists()
			expect(result.cost).is(1)
			expect(result.path[1]).is("A")
			expect(result.path[2]).is("B")
		end)

		test("returns nil when goal is unreachable", function()
			local result = BFS.shortestPath("A", "E", getNeighbors)
			expect(result).never_exists()
		end)
	end)

	describe("bidirectionalShortestPath", function()
		test("start equals goal returns single-vertex path", function()
			local result = BFS.bidirectionalShortestPath("A", "A", getNeighbors)
			expect(result).exists()
			expect(result.cost).is(0)
			expect(#result.path).is(1)
			expect(result.path[1]).is("A")
		end)

		test("returns correct path length and cost (A→D, 2 hops)", function()
			local result = BFS.bidirectionalShortestPath("A", "D", getNeighbors)
			expect(result).exists()
			expect(result.cost).is(2)
			expect(#result.path).is(3)
			expect(result.path[1]).is("A")
			expect(result.path[#result.path]).is("D")
		end)

		test("returns correct 1-hop path (A→B)", function()
			local result = BFS.bidirectionalShortestPath("A", "B", getNeighbors)
			expect(result).exists()
			expect(result.cost).is(1)
			expect(result.path[1]).is("A")
			expect(result.path[2]).is("B")
		end)

		test("returns nil when goal is unreachable", function()
			local result = BFS.bidirectionalShortestPath("A", "E", getNeighbors)
			expect(result).never_exists()
		end)

		test("path is contiguous (each step is a valid edge)", function()
			local result = BFS.bidirectionalShortestPath("A", "D", getNeighbors)
			expect(result).exists()
			local path = result.path
			for i = 1, #path - 1 do
				local u, v = path[i], path[i + 1]
				local isEdge = false
				for _, n in adj[u] do
					if n == v then
						isEdge = true
						break
					end
				end
				expect(isEdge).is(true)
			end
		end)

		test("matches BFS.shortestPath cost across every reachable pair", function()
			local vertices = { "A", "B", "C", "D" }
			for _, s in vertices do
				for _, g in vertices do
					local single = BFS.shortestPath(s, g, getNeighbors)
					local bidir = BFS.bidirectionalShortestPath(s, g, getNeighbors)
					if single == nil then
						expect(bidir).never_exists()
					else
						expect(bidir).exists()
						expect((bidir :: any).cost).is(single.cost)
						expect(#(bidir :: any).path).is(#single.path)
					end
				end
			end
		end)

		test("directed graph: finds the path using an explicit reverse-neighbors callback", function()
			-- Directed: A→B→D and A→C→D (both arms length 2, no way back from D)
			local dirAdj = {
				A = { "B", "C" },
				B = { "D" },
				C = { "D" },
				D = {},
			}
			local reverseAdj = {
				A = {},
				B = { "A" },
				C = { "A" },
				D = { "B", "C" },
			}
			local function getDirNeighbors(v)
				return dirAdj[v] or {}
			end
			local function getDirReverseNeighbors(v)
				return reverseAdj[v] or {}
			end

			local result = BFS.bidirectionalShortestPath("A", "D", getDirNeighbors, getDirReverseNeighbors)
			expect(result).exists()
			expect(result.cost).is(2)
			expect(result.path[1]).is("A")
			expect(result.path[#result.path]).is("D")
		end)

		test("directed graph: correctly reports unreachable when only a one-way edge exists", function()
			-- A → B is one-way; there is no directed path from B back to A.
			local dirAdj = { A = { "B" }, B = {} }
			local reverseAdj = { A = {}, B = { "A" } }
			local function getDirNeighbors(v)
				return dirAdj[v] or {}
			end
			local function getDirReverseNeighbors(v)
				return reverseAdj[v] or {}
			end

			local forward = BFS.bidirectionalShortestPath("A", "B", getDirNeighbors, getDirReverseNeighbors)
			expect(forward).exists()
			expect(forward.cost).is(1)

			local backward = BFS.bidirectionalShortestPath("B", "A", getDirNeighbors, getDirReverseNeighbors)
			expect(backward).never_exists()
		end)
	end)

	describe("bidirectionalShortestPath (wide diamond ladder)", function()
		-- Each of the two "diamonds" gives a vertex (B, then the meeting
		-- region) two shortest incoming edges, so a frontier re-discovers an
		-- already-seen vertex (its distance is already set) — exercising the
		-- fDist/bDist "already discovered" guards. Start and goal are four hops
		-- apart, so the meeting point lands mid-graph and BOTH reconstructions
		-- run for multiple hops.
		--        A           D
		--      /   \       /   \
		--   S        B ── ?      G
		--      \   /       \   /
		--        C           E
		local ladderAdj = {
			S = { "A", "C" },
			A = { "S", "B" },
			C = { "S", "B" },
			B = { "A", "C", "D", "E" },
			D = { "B", "G" },
			E = { "B", "G" },
			G = { "D", "E" },
		}
		local ladderVerts = { "S", "A", "C", "B", "D", "E", "G" }
		local function ladderNeighbors(v)
			return ladderAdj[v] or {}
		end

		test("finds a shortest S→G path of 4 hops", function()
			local result = BFS.bidirectionalShortestPath("S", "G", ladderNeighbors)
			expect(result).exists()
			expect(result.cost).is(4)
			expect(result.path[1]).is("S")
			expect(result.path[#result.path]).is("G")
			expect(#result.path).is(5)
		end)

		test("reconstructed path is contiguous", function()
			local result = BFS.bidirectionalShortestPath("S", "G", ladderNeighbors)
			expect(result).exists()
			local path = result.path
			for i = 1, #path - 1 do
				local u, v = path[i], path[i + 1]
				local isEdge = false
				for _, n in ladderAdj[u] do
					if n == v then
						isEdge = true
						break
					end
				end
				expect(isEdge).is(true)
			end
		end)

		test("matches BFS.shortestPath cost across every reachable pair", function()
			for _, s in ladderVerts do
				for _, g in ladderVerts do
					local single = BFS.shortestPath(s, g, ladderNeighbors)
					local bidir = BFS.bidirectionalShortestPath(s, g, ladderNeighbors)
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

	describe("iterator-form getNeighbors", function()
		-- getNeighbors may return a stateful iterator () -> V? instead of an
		-- array; results must match the array form.
		local function iterNeighbors(v)
			local list = adj[v] or {}
			local i = 0
			return function()
				i += 1
				return list[i]
			end
		end

		test("toArray matches the array form", function()
			local result = BFS.toArray("A", iterNeighbors)
			expect(containsAll(result, { "A", "B", "C", "D" })).is(true)
		end)

		test("shortestPath matches the array form", function()
			local result = BFS.shortestPath("A", "D", iterNeighbors)
			expect(result).exists()
			expect(result.cost).is(2)
		end)
	end)

	describe("toParentMap", function()
		test("start maps to itself", function()
			local parents = BFS.toParentMap("A", getNeighbors)
			expect(parents["A"]).is("A")
		end)

		test("all reachable vertices have a parent", function()
			local parents = BFS.toParentMap("A", getNeighbors)
			expect(parents["B"]).exists()
			expect(parents["C"]).exists()
			expect(parents["D"]).exists()
		end)

		test("unreachable vertices have no parent", function()
			local parents = BFS.toParentMap("A", getNeighbors)
			expect(parents["E"]).never_exists()
		end)

		test("parents are valid predecessors in BFS tree", function()
			local parents = BFS.toParentMap("A", getNeighbors)
			-- Each non-start vertex's parent must be a direct neighbour
			for v, parent in parents do
				if v == "A" then
					continue
				end
				local parentNeighbors = adj[parent]
				local found = false
				for _, n in parentNeighbors do
					if n == v then
						found = true
						break
					end
				end
				expect(found).is(true)
			end
		end)
	end)

	describe("shouldStop", function()
		-- Linear chain A-B-C-D-E-F (undirected) for deterministic depth testing.
		local chainAdj = {
			A = { "B" },
			B = { "A", "C" },
			C = { "B", "D" },
			D = { "C", "E" },
			E = { "D", "F" },
			F = { "E" },
		}
		local function chainNeighbors(v)
			return chainAdj[v] or {}
		end

		describe("shortestPath", function()
			test("predicate returning true on the first dequeue aborts with nil", function()
				local result = BFS.shortestPath("A", "D", getNeighbors, function()
					return true
				end)
				expect(result).never_exists()
			end)

			test("a predicate that never fires is identical to omitting it", function()
				local result = BFS.shortestPath("A", "D", getNeighbors, function()
					return false
				end)
				expect(result).exists()
				expect(result.cost).is(2)
			end)

			test("the goal is never passed to shouldStop (goal found before dequeue)", function()
				local result = BFS.shortestPath("A", "D", getNeighbors, function(v)
					return v == "D"
				end)
				expect(result).exists()
				expect(result.cost).is(2)
			end)

			test("a depth budget stops the search before a too-far goal is reached", function()
				-- Goal F is 5 hops away; stopping at depth 3 aborts first.
				local result = BFS.shortestPath("A", "F", chainNeighbors, function(_v, depth)
					return depth >= 3
				end)
				expect(result).never_exists()
			end)

			test("a depth budget larger than the path still finds the goal", function()
				local result = BFS.shortestPath("A", "F", chainNeighbors, function(_v, depth)
					return depth >= 100
				end)
				expect(result).exists()
				expect(result.cost).is(5)
			end)
		end)

		describe("bidirectionalShortestPath", function()
			test("predicate returning true on the first dequeue aborts with nil", function()
				local result = BFS.bidirectionalShortestPath("A", "D", getNeighbors, nil, function()
					return true
				end)
				expect(result).never_exists()
			end)

			test("a predicate firing only on a backward-side vertex aborts with nil", function()
				-- The backward frontier dequeues the goal "D" first; the predicate
				-- fires there, exercising the backward-branch cancellation.
				local result = BFS.bidirectionalShortestPath("A", "D", getNeighbors, nil, function(v)
					return v == "D"
				end)
				expect(result).never_exists()
			end)

			test("a predicate that never fires is identical to omitting it", function()
				local result = BFS.bidirectionalShortestPath("A", "D", getNeighbors, nil, function()
					return false
				end)
				expect(result).exists()
				expect(result.cost).is(2)
			end)
		end)
	end)
end

return test_suite
