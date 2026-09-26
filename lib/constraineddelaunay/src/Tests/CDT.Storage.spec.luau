-- Authors: Logan Hunt (Raildex)
-- September 25, 2026
-- Storage contract suite (ruling S1): any replacement Storage layout must pass this file
-- unchanged. Requires only ../Storage (plus PlainData for the network-safety check).

return function(t: tiniest)
	local Storage = require("../Storage")
	local PlainData = require("../PlainData")

	local describe = t.describe
	local expect = t.expect
	local test = t.test

	-- Every exported function must be named here by at least one case; the completeness test
	-- below fails if Storage grows an accessor nobody tests.
	local covered: { [string]: boolean } = {}
	local function cases(...: string)
		for _, name in { ... } do
			covered[name] = true
		end
	end

	describe("CDT Storage contract", function()
		test("counts start empty and report the constructor arguments", function()
			cases("New", "VertexCount", "TriangleCount", "GroupCount", "InputCount")
			local s = Storage.New(5, 3)
			expect(Storage.VertexCount(s)).is(0)
			expect(Storage.TriangleCount(s)).is(0)
			expect(Storage.GroupCount(s)).is(3)
			expect(Storage.InputCount(s)).is(5)
		end)

		test("vertices round-trip f64 coordinates exactly", function()
			cases("AddVertex", "GetVertex")
			local s = Storage.New(0, 1)
			local tiny = 2 ^ -60
			local v1 = Storage.AddVertex(s, 1 + 2 ^ -52, -tiny)
			local v2 = Storage.AddVertex(s, -123456.789, 2 ^ 40 + 0.5)
			expect(v1).is(1)
			expect(v2).is(2)
			local x, y = Storage.GetVertex(s, v1)
			expect(x).is(1 + 2 ^ -52)
			expect(y).is(-tiny)
			x, y = Storage.GetVertex(s, v2)
			expect(x).is(-123456.789)
			expect(y).is(2 ^ 40 + 0.5)
		end)

		test("input/vertex maps: first input wins, Steiner vertices report nil", function()
			cases("SetInputVertex", "InputVertexOf", "VertexOfInput")
			local s = Storage.New(3, 1)
			local a = Storage.AddVertex(s, 0, 0)
			local steiner = Storage.AddVertex(s, 1, 1)
			Storage.SetInputVertex(s, 2, a)
			Storage.SetInputVertex(s, 3, a) -- duplicate merged into a
			expect(Storage.InputVertexOf(s, a)).is(2)
			expect(Storage.VertexOfInput(s, 3)).is(a)
			expect(Storage.InputVertexOf(s, steiner)).never_exists()
		end)

		test("triangles, neighbours and coverage round-trip", function()
			cases(
				"AddTriangle",
				"GetTriangle",
				"SetTriangle",
				"GetNeighbor",
				"SetNeighbor",
				"GetCoverHead",
				"SetCoverHead"
			)
			local s = Storage.New(0, 1)
			local tri = Storage.AddTriangle(s, 1, 2, 3)
			local a, b, c = Storage.GetTriangle(s, tri)
			expect(a + b * 10 + c * 100).is(321)
			expect(Storage.GetNeighbor(s, tri, 2)).is(0)
			Storage.SetTriangle(s, tri, 4, 5, 6)
			a, b, c = Storage.GetTriangle(s, tri)
			expect(a + b * 10 + c * 100).is(654)
			Storage.SetNeighbor(s, tri, 3, 9)
			expect(Storage.GetNeighbor(s, tri, 3)).is(9)
			Storage.SetCoverHead(s, tri, 1, 7)
			expect(Storage.GetCoverHead(s, tri, 1)).is(7)
			expect(Storage.GetCoverHead(s, tri, 2)).is(0)
		end)

		test("covering-edge lists: push, count and index", function()
			cases("PushCover", "GetCoveringEdgeCount", "GetCoveringEdge")
			local s = Storage.New(0, 1)
			local tri = Storage.AddTriangle(s, 1, 2, 3)
			expect(Storage.GetCoveringEdgeCount(s, tri, 1)).is(0)
			local head = Storage.PushCover(s, 0, 11)
			head = Storage.PushCover(s, head, 22)
			Storage.SetCoverHead(s, tri, 1, head)
			expect(Storage.GetCoveringEdgeCount(s, tri, 1)).is(2)
			expect(Storage.GetCoveringEdge(s, tri, 1, 1)).is(22)
			expect(Storage.GetCoveringEdge(s, tri, 1, 2)).is(11)
			expect(function()
				Storage.GetCoveringEdge(s, tri, 1, 3)
			end).fails()
		end)

		test("winding per triangle and group", function()
			cases("AllocWinding", "GetWinding", "SetWinding")
			local s = Storage.New(0, 2)
			Storage.AddTriangle(s, 1, 2, 3)
			Storage.AddTriangle(s, 1, 3, 4)
			Storage.AllocWinding(s)
			expect(Storage.GetWinding(s, 2, 2)).is(0)
			Storage.SetWinding(s, 2, 2, -3)
			Storage.SetWinding(s, 1, 0, 5)
			expect(Storage.GetWinding(s, 2, 2)).is(-3)
			expect(Storage.GetWinding(s, 1, 0)).is(5)
			expect(Storage.GetWinding(s, 2, 1)).is(0)
		end)

		test("grows past capacity, with and without Reserve", function()
			cases("Reserve")
			local s = Storage.New(0, 1)
			for i = 1, 1000 do
				Storage.AddVertex(s, i, -i)
				Storage.AddTriangle(s, i, i + 1, i + 2)
			end
			local x, y = Storage.GetVertex(s, 777)
			expect(x + y).is(0)
			local a = Storage.GetTriangle(s, 1000)
			expect(a).is(1000)
			local r = Storage.New(0, 1)
			Storage.Reserve(r, 5000, 9000)
			for i = 1, 5000 do
				Storage.AddVertex(r, i, i)
			end
			expect(Storage.VertexCount(r)).is(5000)
			local node = 0
			for i = 1, 100 do
				node = Storage.PushCover(s, node, i)
			end
			Storage.SetCoverHead(s, 5, 2, node)
			expect(Storage.GetCoveringEdgeCount(s, 5, 2)).is(100)
		end)

		test("Compact keeps selected triangles densely and clears dropped neighbours", function()
			cases("Compact")
			local s = Storage.New(0, 1)
			for i = 1, 4 do
				Storage.AddTriangle(s, i, i + 1, i + 2)
			end
			Storage.SetNeighbor(s, 3, 1, 1) -- points at a dropped triangle
			Storage.SetNeighbor(s, 3, 2, 4) -- points at a kept one
			Storage.SetCoverHead(s, 4, 3, 42)
			Storage.Compact(s, { false, true, true, true })
			expect(Storage.TriangleCount(s)).is(3)
			local a = Storage.GetTriangle(s, 1)
			expect(a).is(2)
			expect(Storage.GetNeighbor(s, 2, 1)).is(0)
			expect(Storage.GetNeighbor(s, 2, 2)).is(3)
			expect(Storage.GetCoverHead(s, 3, 3)).is(42)
		end)

		test("DropLeadingVertices shifts ids and the maps; refuses referenced vertices", function()
			cases("DropLeadingVertices")
			local s = Storage.New(2, 1)
			for i = 1, 6 do
				Storage.AddVertex(s, i * 10, 0)
			end
			Storage.SetInputVertex(s, 1, 5)
			Storage.AddTriangle(s, 4, 5, 6)
			Storage.DropLeadingVertices(s, 3)
			expect(Storage.VertexCount(s)).is(3)
			local x = Storage.GetVertex(s, 1)
			expect(x).is(40)
			local a, b, c = Storage.GetTriangle(s, 1)
			expect(a + b * 10 + c * 100).is(321)
			expect(Storage.VertexOfInput(s, 1)).is(2)
			expect(Storage.InputVertexOf(s, 2)).is(1)
			local bad = Storage.New(0, 1)
			Storage.AddVertex(bad, 0, 0)
			Storage.AddVertex(bad, 1, 0)
			Storage.AddTriangle(bad, 1, 2, 2)
			expect(function()
				Storage.DropLeadingVertices(bad, 1)
			end).fails()
		end)

		test("state is plain, network-safe data", function()
			local s = Storage.New(2, 1)
			Storage.AddVertex(s, 1, 2)
			Storage.AddTriangle(s, 1, 1, 1)
			Storage.AllocWinding(s)
			expect(PlainData.Check(s)).is_true()
		end)

		test("every exported Storage function has a contract case", function()
			local missing = {}
			for name, value in Storage :: { [string]: any } do
				if type(value) == "function" and not covered[name] then
					table.insert(missing, name)
				end
			end
			table.sort(missing)
			expect(table.concat(missing, ",")).is("")
		end)
	end)
end
