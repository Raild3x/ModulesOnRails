local TopologicalSort = require("../TopologicalSort")

local test_suite = function(tiniest: tiniest)
	local describe = tiniest.describe
	local test = tiniest.test
	local expect = tiniest.expect

	-- Diamond DAG: A→B, A→C, B→D, C→D
	-- Valid topo orders: A,B,C,D  or  A,C,B,D
	local diamondAdj = {
		A = { "B", "C" },
		B = { "D" },
		C = { "D" },
		D = {},
	}
	local diamondVerts = { "A", "B", "C", "D" }
	local function diamondNeighbors(v)
		return diamondAdj[v] or {}
	end

	-- Linear DAG: A→B→C→D
	local linearAdj = {
		A = { "B" },
		B = { "C" },
		C = { "D" },
		D = {},
	}
	local linearVerts = { "A", "B", "C", "D" }
	local function linearNeighbors(v)
		return linearAdj[v] or {}
	end

	-- Cyclic graph: A→B→C→A
	local cyclicAdj = {
		A = { "B" },
		B = { "C" },
		C = { "A" },
	}
	local cyclicVerts = { "A", "B", "C" }
	local function cyclicNeighbors(v)
		return cyclicAdj[v] or {}
	end

	-- Helper: verify a topological order is valid for a given adjacency
	local function isValidTopoOrder(order, adj)
		if order == nil then
			return false
		end
		local pos = {}
		for i, v in order do
			pos[v] = i
		end
		for u, neighbors in adj do
			for _, v in neighbors do
				if pos[u] == nil or pos[v] == nil or pos[u] >= pos[v] then
					return false
				end
			end
		end
		return true
	end

	describe("sort (DFS post-order)", function()
		test("linear DAG produces correct order", function()
			local order = TopologicalSort.sort(linearVerts, linearNeighbors)
			expect(order).exists()
			expect(#order).is(4)
			expect(isValidTopoOrder(order, linearAdj)).is(true)
		end)

		test("linear DAG: exact order A,B,C,D", function()
			local order = TopologicalSort.sort(linearVerts, linearNeighbors)
			expect(order[1]).is("A")
			expect(order[2]).is("B")
			expect(order[3]).is("C")
			expect(order[4]).is("D")
		end)

		test("diamond DAG produces a valid topological order", function()
			local order = TopologicalSort.sort(diamondVerts, diamondNeighbors)
			expect(order).exists()
			expect(#order).is(4)
			expect(isValidTopoOrder(order, diamondAdj)).is(true)
		end)

		test("diamond DAG: A is first and D is last", function()
			local order = TopologicalSort.sort(diamondVerts, diamondNeighbors)
			expect(order[1]).is("A")
			expect(order[4]).is("D")
		end)

		test("returns nil for cyclic graph", function()
			local order = TopologicalSort.sort(cyclicVerts, cyclicNeighbors)
			expect(order).never_exists()
		end)

		test("single vertex returns itself", function()
			local order = TopologicalSort.sort({ "X" }, function(_v)
				return {}
			end)
			expect(order).exists()
			expect(#order).is(1)
			expect(order[1]).is("X")
		end)
	end)

	describe("kahn (BFS in-degree queue)", function()
		test("linear DAG produces correct order", function()
			local order = TopologicalSort.kahn(linearVerts, linearNeighbors)
			expect(order).exists()
			expect(#order).is(4)
			expect(isValidTopoOrder(order, linearAdj)).is(true)
		end)

		test("linear DAG: exact order A,B,C,D", function()
			local order = TopologicalSort.kahn(linearVerts, linearNeighbors)
			expect(order[1]).is("A")
			expect(order[2]).is("B")
			expect(order[3]).is("C")
			expect(order[4]).is("D")
		end)

		test("diamond DAG produces a valid topological order", function()
			local order = TopologicalSort.kahn(diamondVerts, diamondNeighbors)
			expect(order).exists()
			expect(#order).is(4)
			expect(isValidTopoOrder(order, diamondAdj)).is(true)
		end)

		test("diamond DAG: A is first and D is last", function()
			local order = TopologicalSort.kahn(diamondVerts, diamondNeighbors)
			expect(order[1]).is("A")
			expect(order[4]).is("D")
		end)

		test("returns nil for cyclic graph", function()
			local order = TopologicalSort.kahn(cyclicVerts, cyclicNeighbors)
			expect(order).never_exists()
		end)

		test("single vertex returns itself", function()
			local order = TopologicalSort.kahn({ "X" }, function(_v)
				return {}
			end)
			expect(order).exists()
			expect(#order).is(1)
			expect(order[1]).is("X")
		end)
	end)
end

return test_suite
