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

	describe("forEach", function()
		test("linear graph yields in DFS order", function()
			local iter = DFS.forEach("A", linearNeighbors)
			expect(iter()).is("A")
			expect(iter()).is("B")
			expect(iter()).is("C")
			expect(iter()).is("D")
			expect(iter()).is(nil)
		end)

		test("yields all reachable vertices", function()
			local visited = {}
			for v in DFS.forEach("A", getNeighbors) do
				visited[v] = true
			end
			expect(visited["A"]).is(true)
			expect(visited["B"]).is(true)
			expect(visited["C"]).is(true)
			expect(visited["D"]).is(true)
			expect(visited["E"]).never_exists()
		end)

		test("returns nil when exhausted and remains stable", function()
			local iter = DFS.forEach("E", getNeighbors)
			iter() -- "E"
			expect(iter()).is(nil)
			expect(iter()).is(nil)
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
