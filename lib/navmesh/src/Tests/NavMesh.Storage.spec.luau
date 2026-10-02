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
			cases("GetSimplifyTolerance", "SetSimplifyTolerance")
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
			expect(Storage.GetSimplifyTolerance(s)).is(0)
			Storage.SetSimplifyTolerance(s, 0.1)
			expect(Storage.GetSimplifyTolerance(s)).is(0.1)
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
			cases("SetTileStamp")
			Storage.SetTileStamp(s, tile, 41)
			expect(Storage.GetTileStamp(s, tile)).is(41)
			-- Open flags and extra heads survive growth.
			Storage.Reserve(s, 4096)
			expect(Storage.IsEdgeOpen(s, first, 3)).is(true)
			expect(Storage.GetExtraHead(s, first)).is(e2)
		end)

		test("link records: sparse ids never reused, states, names, extras follow a removal", function()
			cases("GetLinkId", "GetLinkName", "SetLinkName", "GetLinkState", "SetLinkState")
			cases("GetLinkNextId", "SetLinkNextId", "FindLink", "RemoveLinkRecord")
			local s, _, first = withTile()
			local second = first + 1
			local a, b = vector.create(1, 0, 1), vector.create(2, 0, 2)
			expect(Storage.GetLinkNextId(s)).is(1)
			local s1 = Storage.InsertLink(s, first, a, second, b, 1, 1, "", true)
			local s2 = Storage.InsertLink(s, first, b, second, a, 2, 1, "", true, "door", 5)
			local s3 = Storage.InsertLink(s, second, a, first, b, 3, 1, "", false, "door")
			expect(`{Storage.GetLinkId(s, s1)},{Storage.GetLinkId(s, s2)},{Storage.GetLinkId(s, s3)}`).is("1,5,6")
			expect(`{Storage.GetLinkName(s, s1)}|{Storage.GetLinkName(s, s2)}`).is("|door")
			Storage.SetLinkName(s, s1, "gate")
			expect(Storage.GetLinkName(s, s1)).is("gate")
			expect(Storage.GetLinkNextId(s)).is(7)
			expect(Storage.GetLinkState(s, s2)).is(Storage.OBSTACLE_ACTIVE)
			Storage.SetLinkState(s, s2, Storage.OBSTACLE_PENDING_REMOVE)
			expect(Storage.GetLinkState(s, s2)).is(Storage.OBSTACLE_PENDING_REMOVE)
			expect(`{Storage.FindLink(s, 1)},{Storage.FindLink(s, 5)},{Storage.FindLink(s, 6)}`).is("1,2,3")
			for _, missing in { 0, 2, 4, 7 } do
				expect(Storage.FindLink(s, missing)).with_context(tostring(missing)).is(0)
			end
			expect(function()
				Storage.InsertLink(s, first, a, second, b, 1, 1, "", true, "", 6)
			end).fails_with("never reused")
			expect(function()
				Storage.SetLinkNextId(s, 3)
			end).fails_with("never reused")
			-- Extra links name slots: removing slot 2 moves slot 3's extras down, not slot 1's.
			local e1 = Storage.AddExtra(s, first, second, Storage.EXTRA_LINK, s1, a, b)
			local e3 = Storage.AddExtra(s, second, first, Storage.EXTRA_LINK, s3, a, b)
			local es = Storage.AddExtra(s, first, second, Storage.EXTRA_SEAM, 3, a, b)
			Storage.RemoveLinkRecord(s, s2)
			expect(Storage.LinkCount(s)).is(2)
			expect(`{Storage.GetLinkId(s, 1)},{Storage.GetLinkId(s, 2)}`).is("1,6")
			expect(`{Storage.GetLinkName(s, 2)},{select(5, Storage.GetLink(s, 2))}`).is("door,3")
			expect(`{select(4, Storage.GetExtra(s, e1))},{select(4, Storage.GetExtra(s, e3))}`).is("1,2")
			expect(select(4, Storage.GetExtra(s, es))).is(3) -- a seam's ref is an edge slot
			expect(Storage.GetLinkNextId(s)).is(7)
			Storage.SetLinkNextId(s, 9)
			expect(Storage.GetLinkId(s, Storage.InsertLink(s, first, a, second, b, 1, 1, "", true))).is(9)
		end)

		test("rebuild sources: floor data, seams, pieces, obstacles", function()
			cases("SetFloorSources", "GetFloorSources")
			cases("SeamCount", "InsertSeam", "GetSeam", "PieceCount", "InsertPiece", "GetPiece")
			cases("ObstacleCount", "InsertObstacleRecord", "GetObstacleRecord", "SetObstacleState", "GetObstacleState")
			cases("GetObstacleNextId", "SetObstacleNextId", "FindObstacle", "RemoveObstacleRecord")
			cases("ClearExtras", "SetLinkEnds")
			local s, _, first = withTile()
			local ring = { X = { 0, 4, 4 }, Z = { 0, 0, 4 }, Y = { 1, 2, 3 } }
			Storage.SetFloorSources(s, 1, 512, 3, { 7, 8 }, { ring, ring }, { 1, 2 })
			local size, area, ids, rings, groups = Storage.GetFloorSources(s, 1)
			expect(`{size},{area},{table.concat(ids, ",")},{#rings}`).is("512,3,7,8,2")
			expect(table.concat(rings[1].Y, ",")).is("1,2,3")
			expect(table.concat(groups, ",")).is("1,2")

			expect(Storage.SeamCount(s)).is(0)
			expect(Storage.InsertSeam(s, 1, 2, 0, 0, 256, 0)).is(1)
			expect(table.concat({ Storage.GetSeam(s, 1) }, ",")).is("1,2,0,0,256,0")
			expect(Storage.PieceCount(s)).is(0)
			Storage.InsertPiece(s, 1, first, 2)
			expect(Storage.PieceCount(s)).is(1)
			expect(table.concat({ Storage.GetPiece(s, 1) }, ",")).is(`1,{first},2`)

			expect(Storage.ObstacleCount(s)).is(0)
			expect(Storage.GetObstacleNextId(s)).is(1)
			local id = Storage.InsertObstacleRecord(s, 1, { 0, 4, 4 }, { 0, 0, 4 })
			expect(id).is(1)
			expect(Storage.ObstacleCount(s)).is(1)
			local gotId, floor, state, xs, zs = Storage.GetObstacleRecord(s, 1)
			expect(`{gotId},{floor},{state},{table.concat(xs, ",")},{table.concat(zs, ",")}`).is(
				`1,1,{Storage.OBSTACLE_PENDING_ADD},0,4,4,0,0,4`
			)
			Storage.SetObstacleState(s, 1, Storage.OBSTACLE_ACTIVE)
			expect(Storage.GetObstacleState(s, 1)).is(Storage.OBSTACLE_ACTIVE)
			-- Sparse ids: a record under a given id, then records found by id, and a removal that
			-- moves later records (and their rings) down a slot but keeps the next id.
			expect(Storage.InsertObstacleRecord(s, 2, { 8, 9, 9 }, { 8, 8, 9 }, 5)).is(5)
			expect(Storage.InsertObstacleRecord(s, 1, { 1, 2, 2 }, { 1, 1, 2 })).is(6)
			expect(`{Storage.FindObstacle(s, 1)},{Storage.FindObstacle(s, 5)},{Storage.FindObstacle(s, 6)}`).is("1,2,3")
			expect(`{Storage.FindObstacle(s, 3)},{Storage.FindObstacle(s, 7)}`).is("0,0")
			Storage.RemoveObstacleRecord(s, 2)
			expect(Storage.ObstacleCount(s)).is(2)
			expect(`{Storage.FindObstacle(s, 5)},{Storage.FindObstacle(s, 6)}`).is("0,2")
			local sixId, sixFloor, _, sixX, sixZ = Storage.GetObstacleRecord(s, 2)
			expect(`{sixId},{sixFloor},{table.concat(sixX, ",")},{table.concat(sixZ, ",")}`).is("6,1,1,2,2,1,1,2")
			expect(#(select(4, Storage.GetObstacleRecord(s, 1)))).is(3)
			expect(Storage.GetObstacleNextId(s)).is(7)
			Storage.SetObstacleNextId(s, 9)
			expect(Storage.InsertObstacleRecord(s, 1, { 0, 1, 1 }, { 0, 0, 1 })).is(9)
			expect(function()
				Storage.InsertObstacleRecord(s, 1, { 0, 1, 1 }, { 0, 0, 1 }, 4)
			end).fails_with("never reused")
			expect(function()
				Storage.SetObstacleNextId(s, 3)
			end).fails_with("never reused")

			local a, b = vector.create(1, 0, 1), vector.create(2, 0, 2)
			Storage.AddExtra(s, first, first + 1, Storage.EXTRA_SEAM, 1, a, b)
			Storage.ClearExtras(s)
			expect(Storage.GetExtraHead(s, first)).is(0)
			local link = Storage.InsertLink(s, first, a, first + 1, b, 1, 1, "", true)
			Storage.SetLinkEnds(s, link, 0, b, first, a)
			local fromTri, from, toTri, to = Storage.GetLink(s, link)
			expect(`{fromTri},{toTri}`).is(`0,{first}`)
			expect(from == b and to == a).is_true()
		end)

		test("bulk range operations (Update, ticket 22)", function()
			cases(
				"SetTriangleCount",
				"CopyTriangleRange",
				"RemapTriangles",
				"SetTileRange",
				"SetVertex",
				"SetVertexCount",
				"ShellFrom"
			)
			local s, tile, first = withTile()
			for _ = 1, 4 do
				Storage.AddVertex(s, vector.create(0, 0, 0))
			end
			Storage.SetTriangle(s, first, 1, 2, 3)
			Storage.SetTriangle(s, first + 1, 2, 4, 3)
			Storage.SetNeighbor(s, first, 1, first + 1)
			Storage.SetNeighbor(s, first + 1, 3, first)
			Storage.SetCornerWidth(s, first + 1, 2, 1.5)
			Storage.SetTriangleArea(s, first + 1, 9)
			Storage.AddExtra(s, first, first + 1, Storage.EXTRA_LINK, 1, vector.zero, vector.zero)

			local n = Storage.ShellFrom(s)
			expect(Storage.TileCount(n)).is(1)
			expect(Storage.VertexCount(n)).is(4)
			expect(Storage.TriangleCount(n)).is(0)
			expect(n.Vertices == s.Vertices).is(false)
			Storage.SetTriangleCount(n, 3)
			expect(Storage.TriangleCount(n)).is(3)
			-- Copied one slot up: data verbatim, extra heads cleared.
			Storage.CopyTriangleRange(n, 2, s, first, 2)
			expect(table.concat({ Storage.GetTriangle(n, 3) }, ",")).is("2,4,3")
			expect(Storage.GetCornerWidth(n, 3, 2)).is(1.5)
			expect(Storage.GetTriangleArea(n, 3)).is(9)
			expect(Storage.GetTriangleTile(n, 3)).is(tile)
			expect(Storage.GetExtraHead(n, 2)).is(0)
			-- Old ids first.. shift by +1; vertex 4 becomes 1; an id in a removed segment -> 0.
			Storage.RemapTriangles(n, 2, 3, { [4] = 1 }, { first, first + 1 }, { 1, false })
			expect(table.concat({ Storage.GetTriangle(n, 3) }, ",")).is("2,1,3")
			expect(Storage.GetNeighbor(n, 2, 1)).is(0)
			expect(Storage.GetNeighbor(n, 3, 3)).is(first + 1)
			Storage.SetTileRange(n, tile, 2, 2)
			expect(table.concat({ Storage.GetTileRange(n, tile) }, ",")).is("2,2")
			-- Overlapping copy within one state.
			Storage.CopyTriangleRange(n, 1, n, 2, 2)
			expect(table.concat({ Storage.GetTriangle(n, 2) }, ",")).is("2,1,3")
			Storage.SetVertex(n, 1, vector.create(5, 6, 7))
			expect(Storage.GetVertex(n, 1).Y).is(6)
			expect(Storage.GetVertex(s, 1).Y).is(0)
			Storage.SetVertexCount(n, 2)
			expect(Storage.VertexCount(n)).is(2)
			expect(Storage.GetVertex(n, 3)).is(nil)

			-- Ids below the first segment stay as they are.
			Storage.SetNeighbor(n, 1, 1, 1)
			Storage.RemapTriangles(n, 1, 1, {}, { 2 }, { 5 })
			expect(Storage.GetNeighbor(n, 1, 1)).is(1)
			-- A one-triangle range is copied too.
			Storage.CopyTriangleRange(n, 2, n, 1, 1)
			expect(Storage.GetNeighbor(n, 2, 1)).is(1)
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
