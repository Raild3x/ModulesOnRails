-- Authors: Logan Hunt (Raildex)
-- September 25, 2026
-- Storage contract suite (ruling S1): any replacement Storage layout must pass this file
-- unchanged. Requires only ../Storage (plus the CDT's PlainData for the network-safety check).

return function(t: tiniest)
	local Storage = require("../Storage")
	local PlainData = require("../../ConstrainedDelaunay").PlainData

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

	-- A state with one floor, one tile and a 2-triangle range.
	local function withTile(): (Storage.State, number, number)
		local s = Storage.New()
		local floor = Storage.InsertFloor(s, "Ground")
		local tile = Storage.InsertTile(s, floor, -1, -2, 3, 4)
		local first = Storage.AllocTileRange(s, tile, 2)
		return s, tile, first
	end

	describe("NavMesh Storage contract", function()
		test("counts start empty", function()
			cases("New", "VertexCount", "TriangleCount", "TileCount", "FloorCount")
			local s = Storage.New()
			expect(Storage.VertexCount(s)).is(0)
			expect(Storage.TriangleCount(s)).is(0)
			expect(Storage.TileCount(s)).is(0)
			expect(Storage.FloorCount(s)).is(0)
		end)

		test("vertices round-trip as vectors with f32 components", function()
			cases("AddVertex", "GetVertex")
			local s = Storage.New()
			local v1 = Storage.AddVertex(s, vector.create(1.5, -2.25, 32768))
			local v2 = Storage.AddVertex(s, vector.create(0, 0.1, 0))
			expect(v1).is(1)
			expect(v2).is(2)
			expect(Storage.VertexCount(s)).is(2)
			local p = Storage.GetVertex(s, v1)
			expect(p.X).is(1.5)
			expect(p.Y).is(-2.25)
			expect(p.Z).is(32768)
			-- f32 storage: 0.1 comes back as its nearest f32 (precision class: f32 storage).
			expect(Storage.GetVertex(s, v2).Y).is(0.10000000149011612)
		end)

		test("floors are named and numbered in insertion order", function()
			cases("InsertFloor", "GetFloorName")
			local s = Storage.New()
			expect(Storage.InsertFloor(s, "Ground")).is(1)
			expect(Storage.InsertFloor(s, "Upper")).is(2)
			expect(Storage.GetFloorName(s, 2)).is("Upper")
			expect(Storage.FloorCount(s)).is(2)
		end)

		test("tiles keep their floor, bounds and range", function()
			cases("InsertTile", "GetTileFloor", "GetTileBounds", "AllocTileRange", "GetTileRange")
			local s, tile, first = withTile()
			expect(Storage.TileCount(s)).is(1)
			expect(Storage.GetTileFloor(s, tile)).is(1)
			local x0, z0, x1, z1 = Storage.GetTileBounds(s, tile)
			expect(table.concat({ x0, z0, x1, z1 }, ",")).is("-1,-2,3,4")
			local f, n = Storage.GetTileRange(s, tile)
			expect(f).is(first)
			expect(n).is(2)
			expect(Storage.TriangleCount(s)).is(2)
		end)

		test("an allocated range starts zeroed and tagged with its tile and floor", function()
			cases("GetTriangleTile", "GetTriangleFloor", "GetTriangleArea", "GetTriangle", "GetNeighbor")
			local s, tile, first = withTile()
			for id = first, first + 1 do
				expect(Storage.GetTriangleTile(s, id)).is(tile)
				expect(Storage.GetTriangleFloor(s, id)).is(1)
				expect(Storage.GetTriangleArea(s, id)).is(0)
				local a, b, c = Storage.GetTriangle(s, id)
				expect(a + b + c).is(0)
				for e = 1, 3 do
					expect(Storage.GetNeighbor(s, id, e)).is(0)
				end
			end
		end)

		test("per-triangle fields round-trip independently", function()
			cases("SetTriangle", "SetNeighbor", "SetTriangleFloor", "SetTriangleArea", "SetTriangleTile")
			local s, _, first = withTile()
			local second = first + 1
			Storage.SetTriangle(s, first, 3, 1, 2)
			Storage.SetNeighbor(s, first, 2, second)
			Storage.SetTriangleFloor(s, second, 7)
			Storage.SetTriangleArea(s, first, 5)
			Storage.SetTriangleTile(s, second, 9)
			expect(table.concat({ Storage.GetTriangle(s, first) }, ",")).is("3,1,2")
			expect(Storage.GetNeighbor(s, first, 1)).is(0)
			expect(Storage.GetNeighbor(s, first, 2)).is(second)
			expect(Storage.GetNeighbor(s, first, 3)).is(0)
			expect(Storage.GetTriangleFloor(s, first)).is(1)
			expect(Storage.GetTriangleFloor(s, second)).is(7)
			expect(Storage.GetTriangleArea(s, first)).is(5)
			expect(Storage.GetTriangleArea(s, second)).is(0)
			expect(Storage.GetTriangleTile(s, second)).is(9)
		end)

		test("grows past capacity and keeps earlier triangles", function()
			cases("Reserve")
			local s = Storage.New()
			local floor = Storage.InsertFloor(s, "Ground")
			local tiles = {}
			for k = 1, 40 do
				local tile = Storage.InsertTile(s, floor, k, -k, k + 1, 2 * k)
				local id = Storage.AllocTileRange(s, tile, k)
				Storage.SetTriangle(s, id, k, k + 1, k + 2)
				Storage.SetTriangleArea(s, id, k)
				Storage.SetNeighbor(s, id, 3, k + 7)
				Storage.SetTriangleFloor(s, id, k + 100)
				tiles[k] = id
			end
			expect(Storage.TriangleCount(s)).is(40 * 41 / 2)
			for k, id in tiles do
				expect(table.concat({ Storage.GetTriangle(s, id) }, ",")).is(`{k},{k + 1},{k + 2}`)
				expect(Storage.GetTriangleArea(s, id)).is(k)
				expect(Storage.GetNeighbor(s, id, 3)).is(k + 7)
				expect(Storage.GetTriangleFloor(s, id)).is(k + 100)
				expect(Storage.GetTriangleTile(s, id)).is(k)
				expect(table.concat({ Storage.GetTileBounds(s, k) }, ",")).is(`{k},{-k},{k + 1},{2 * k}`)
			end
			-- Reserve pre-sizes without changing the count or contents.
			Storage.Reserve(s, 5000)
			expect(Storage.TriangleCount(s)).is(820)
			expect(Storage.GetTriangleArea(s, tiles[40])).is(40)
		end)

		test("clearance widths, wall flags and the radius cap round-trip", function()
			cases("GetCornerWidth", "SetCornerWidth", "GetPortalWidth", "SetPortalWidth")
			cases("IsWallVertex", "SetWallVertex", "GetMaxAgentRadius", "SetMaxAgentRadius")
			local s, _, first = withTile()
			for k = 1, 3 do
				expect(Storage.GetCornerWidth(s, first, k)).is(0)
				expect(Storage.GetPortalWidth(s, first + 1, k)).is(0)
			end
			Storage.SetCornerWidth(s, first, 2, 4.1)
			Storage.SetPortalWidth(s, first + 1, 3, math.huge)
			expect(Storage.GetCornerWidth(s, first, 2)).is(4.1) -- f64: exact
			expect(Storage.GetCornerWidth(s, first, 1)).is(0)
			expect(Storage.GetPortalWidth(s, first + 1, 3)).is(math.huge)
			local v = Storage.AddVertex(s, vector.create(0, 0, 0))
			expect(Storage.IsWallVertex(s, v)).is(false)
			Storage.SetWallVertex(s, v, true)
			expect(Storage.IsWallVertex(s, v)).is(true)
			expect(Storage.GetMaxAgentRadius(s)).is(0)
			Storage.SetMaxAgentRadius(s, 8)
			expect(Storage.GetMaxAgentRadius(s)).is(8)
			-- Widths survive growth.
			Storage.Reserve(s, 4096)
			expect(Storage.GetCornerWidth(s, first, 2)).is(4.1)
		end)

		test("open edges, extra links, links and tile stamps round-trip", function()
			cases("IsEdgeOpen", "SetEdgeOpen", "IsWallEdge", "AddExtra", "GetExtraHead", "GetExtra")
			cases("LinkCount", "InsertLink", "GetLink", "SetLinkFlag", "GetTileStamp", "BumpTileStamp")
			local s, tile, first = withTile()
			local second = first + 1
			Storage.SetNeighbor(s, first, 1, second)
			expect(Storage.IsEdgeOpen(s, first, 2)).is(false)
			expect(Storage.IsWallEdge(s, first, 2)).is(true)
			expect(Storage.IsWallEdge(s, first, 1)).is(false) -- it has a neighbour
			Storage.SetEdgeOpen(s, first, 2)
			Storage.SetEdgeOpen(s, first, 3)
			expect(Storage.IsEdgeOpen(s, first, 2)).is(true)
			expect(Storage.IsEdgeOpen(s, first, 3)).is(true)
			expect(Storage.IsEdgeOpen(s, first, 1)).is(false)
			expect(Storage.IsWallEdge(s, first, 2)).is(false)

			expect(Storage.GetExtraHead(s, first)).is(0)
			local a, b = vector.create(1, 2, 3), vector.create(4, 5, 6)
			local e1 = Storage.AddExtra(s, first, second, Storage.EXTRA_SEAM, 0, a, b)
			local e2 = Storage.AddExtra(s, first, 7, Storage.EXTRA_LINK, 3, b, a)
			expect(Storage.GetExtraHead(s, first)).is(e2)
			local nextId, target, kind, ref, pa, pb = Storage.GetExtra(s, e2)
			expect(`{nextId},{target},{kind},{ref}`).is(`{e1},7,{Storage.EXTRA_LINK},3`)
			expect(pa == b and pb == a).is_true()
			expect((Storage.GetExtra(s, e1))).is(0)
			expect(Storage.GetExtraHead(s, second)).is(0)

			expect(Storage.LinkCount(s)).is(0)
			local id = Storage.InsertLink(s, first, a, second, b, 2.5, 3, "Jump", false)
			expect(id).is(1)
			expect(Storage.LinkCount(s)).is(1)
			local fromTri, from, toTri, to, cost, area, label, both, enabled = Storage.GetLink(s, id)
			expect(`{fromTri},{toTri},{cost},{area},{label},{both},{enabled}`).is(
				`{first},{second},2.5,3,Jump,false,true`
			)
			expect(from == a and to == b).is_true()
			Storage.SetLinkFlag(s, id, false)
			expect(select(9, Storage.GetLink(s, id))).is(false)

			expect(Storage.GetTileStamp(s, tile)).is(0)
			Storage.BumpTileStamp(s, tile)
			Storage.BumpTileStamp(s, tile)
			expect(Storage.GetTileStamp(s, tile)).is(2)
			-- Open flags and extra heads survive growth.
			Storage.Reserve(s, 4096)
			expect(Storage.IsEdgeOpen(s, first, 3)).is(true)
			expect(Storage.GetExtraHead(s, first)).is(e2)
		end)

		test("state is plain, network-safe data", function()
			local s, _, first = withTile()
			Storage.AddVertex(s, vector.create(1, 2, 3))
			Storage.SetTriangle(s, first, 1, 1, 1)
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
