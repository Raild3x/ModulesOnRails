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

	describe("forEach", function()
		test("yields all reachable vertices", function()
			local iter = BFS.forEach("A", getNeighbors)
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
			local iter = BFS.forEach("A", getNeighbors)
			expect(iter()).is("A")
		end)

		test("returns nil when exhausted", function()
			local iter = BFS.forEach("E", getNeighbors)
			iter() -- "E"
			expect(iter()).is(nil)
			expect(iter()).is(nil) -- stable after exhaustion
		end)

		test("works in a for loop", function()
			local count = 0
			for _ in BFS.forEach("A", getNeighbors) do
				count += 1
			end
			expect(count).is(4)
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
end

return test_suite
