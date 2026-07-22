local DFS = require("../DFS")

local test_suite = function(tiniest: tiniest)
	local describe = tiniest.describe
	local test = tiniest.test
	local expect = tiniest.expect

	-- Linear directed graph for deterministic ordering:
	--   A → B → C → D
	local linear = {
		A = { "B" },
		B = { "C" },
		C = { "D" },
		D = {},
	}
	local function linearNeighbors(v)
		return linear[v] or {}
	end

	-- Undirected graph with two components for reachability tests:
	--   A - B - D
	--   |       |
	--   C ------+   (component 1)
	--   E            (component 2, isolated)
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
		test("linear graph visits in DFS order", function()
			local result = DFS.toArray("A", linearNeighbors)
			expect(result[1]).is("A")
			expect(result[2]).is("B")
			expect(result[3]).is("C")
			expect(result[4]).is("D")
		end)

		test("visits all reachable vertices", function()
			local result = DFS.toArray("A", getNeighbors)
			expect(containsAll(result, { "A", "B", "C", "D" })).is(true)
		end)

		test("does not visit unreachable vertices", function()
			local result = DFS.toArray("A", getNeighbors)
			expect(#result).is(4)
		end)

		test("isolated vertex returns only itself", function()
			local result = DFS.toArray("E", getNeighbors)
			expect(#result).is(1)
			expect(result[1]).is("E")
		end)
	end)

	describe("toSet", function()
		test("marks all reachable vertices", function()
			local set = DFS.toSet("A", getNeighbors)
			expect(set["A"]).is(true)
			expect(set["B"]).is(true)
			expect(set["C"]).is(true)
			expect(set["D"]).is(true)
		end)

		test("excludes unreachable vertices", function()
			local set = DFS.toSet("A", getNeighbors)
			expect(set["E"]).never_exists()
		end)
	end)

	describe("toIterator", function()
		test("linear graph yields in DFS order", function()
			local iter = DFS.toIterator("A", linearNeighbors)
			expect(iter()).is("A")
			expect(iter()).is("B")
			expect(iter()).is("C")
			expect(iter()).is("D")
			expect(iter()).is(nil)
		end)

		test("yields all reachable vertices", function()
			local visited = {}
			for v in DFS.toIterator("A", getNeighbors) do
				visited[v] = true
			end
			expect(visited["A"]).is(true)
			expect(visited["B"]).is(true)
			expect(visited["C"]).is(true)
			expect(visited["D"]).is(true)
			expect(visited["E"]).never_exists()
		end)

		test("returns nil when exhausted and remains stable", function()
			local iter = DFS.toIterator("E", getNeighbors)
			iter() -- "E"
			expect(iter()).is(nil)
			expect(iter()).is(nil)
		end)

		test("forEach is an alias of toIterator", function()
			expect(DFS.forEach).is(DFS.toIterator)
		end)

		test("skips duplicate stack entries without re-yielding a vertex", function()
			-- X is pushed three times (by A, Y, and Z) before it is first
			-- popped, leaving stale duplicates on the stack. Draining the
			-- iterator must yield X exactly once and skip the leftovers.
			--   A → X,  A → Y,  Y → X,  Y → Z,  Z → X
			local dupAdj = {
				A = { "X", "Y" },
				Y = { "X", "Z" },
				Z = { "X" },
				X = {},
			}
			local function dupNeighbors(v)
				return dupAdj[v] or {}
			end

			local counts = {}
			for v in DFS.toIterator("A", dupNeighbors) do
				counts[v] = (counts[v] or 0) + 1
			end
			expect(counts["A"]).is(1)
			expect(counts["X"]).is(1)
			expect(counts["Y"]).is(1)
			expect(counts["Z"]).is(1)
		end)

		test("accepts the iterator form of getNeighbors", function()
			local function iterNeighbors(v)
				local list = linear[v] or {}
				local i = 0
				return function()
					i += 1
					return list[i]
				end
			end
			local result = {}
			for vertex in DFS.toIterator("A", iterNeighbors) do
				table.insert(result, vertex)
			end
			expect(#result).is(4)
			expect(result[1]).is("A")
		end)
	end)

	describe("toParentMap", function()
		test("start maps to itself", function()
			local parents = DFS.toParentMap("A", getNeighbors)
			expect(parents["A"]).is("A")
		end)

		test("all reachable vertices have a parent", function()
			local parents = DFS.toParentMap("A", getNeighbors)
			expect(parents["B"]).exists()
			expect(parents["C"]).exists()
			expect(parents["D"]).exists()
		end)

		test("unreachable vertices have no entry", function()
			local parents = DFS.toParentMap("A", getNeighbors)
			expect(parents["E"]).never_exists()
		end)

		test("linear graph parent chain is correct", function()
			local parents = DFS.toParentMap("A", linearNeighbors)
			expect(parents["A"]).is("A")
			expect(parents["B"]).is("A")
			expect(parents["C"]).is("B")
			expect(parents["D"]).is("C")
		end)
	end)
end

return test_suite
