--!strict
return function(t: tiniest)
	local CDTUtils = require("../CDTUtils")

	local describe = t.describe
	local expect = t.expect
	local test = t.test

	describe("CDTUtils", function()
		-- ── Constants ──────────────────────────────────────────────────────────
		describe("constants", function()
			test("NO_VERTEX is 0", function()
				expect(CDTUtils.NO_VERTEX).is(0)
			end)

			test("NO_NEIGHBOR is 0", function()
				expect(CDTUtils.NO_NEIGHBOR).is(0)
			end)

			test("N_SUPER_VERTS is 3", function()
				expect(CDTUtils.N_SUPER_VERTS).is(3)
			end)

			test("EDGE_KEY_SHIFT is 2^22", function()
				expect(CDTUtils.EDGE_KEY_SHIFT).is(4194304)
			end)
		end)

		-- ── Triangle constructors ──────────────────────────────────────────────
		describe("newTriangle", function()
			test("produces zero-initialized vertices and neighbors", function()
				local t2 = CDTUtils.newTriangle()
				expect(t2.vertices[1]).is(0)
				expect(t2.vertices[2]).is(0)
				expect(t2.vertices[3]).is(0)
				expect(t2.neighbors[1]).is(0)
				expect(t2.neighbors[2]).is(0)
				expect(t2.neighbors[3]).is(0)
			end)
		end)

		describe("makeTriangle", function()
			test("stores all six supplied values", function()
				local t2 = CDTUtils.makeTriangle(4, 5, 6, 10, 11, 12)
				expect(t2.vertices[1]).is(4)
				expect(t2.vertices[2]).is(5)
				expect(t2.vertices[3]).is(6)
				expect(t2.neighbors[1]).is(10)
				expect(t2.neighbors[2]).is(11)
				expect(t2.neighbors[3]).is(12)
			end)
		end)

		-- ── Slot index helpers ────────────────────────────────────────────────
		describe("ccw", function()
			test("1 → 2", function()
				expect(CDTUtils.ccw(1)).is(2)
			end)
			test("2 → 3", function()
				expect(CDTUtils.ccw(2)).is(3)
			end)
			test("3 → 1", function()
				expect(CDTUtils.ccw(3)).is(1)
			end)
		end)

		describe("cw", function()
			test("1 → 3", function()
				expect(CDTUtils.cw(1)).is(3)
			end)
			test("2 → 1", function()
				expect(CDTUtils.cw(2)).is(1)
			end)
			test("3 → 2", function()
				expect(CDTUtils.cw(3)).is(2)
			end)
		end)

		describe("opoNbr", function()
			-- opoNbr(vSlot): v[1]→n[2], v[2]→n[3], v[3]→n[1]
			test("1 → 2", function()
				expect(CDTUtils.opoNbr(1)).is(2)
			end)
			test("2 → 3", function()
				expect(CDTUtils.opoNbr(2)).is(3)
			end)
			test("3 → 1", function()
				expect(CDTUtils.opoNbr(3)).is(1)
			end)
		end)

		describe("opoVrt", function()
			-- opoVrt(nSlot): n[1]→v[3], n[2]→v[1], n[3]→v[2]
			test("1 → 3", function()
				expect(CDTUtils.opoVrt(1)).is(3)
			end)
			test("2 → 1", function()
				expect(CDTUtils.opoVrt(2)).is(1)
			end)
			test("3 → 2", function()
				expect(CDTUtils.opoVrt(3)).is(2)
			end)
		end)

		-- ── opposedTriangleInd ────────────────────────────────────────────────
		describe("opposedTriangleInd", function()
			-- vv = {10, 20, 30}
			local vv = { 10, 20, 30 }

			test("vertex in slot 1 → opposite neighbor slot 2", function()
				expect(CDTUtils.opposedTriangleInd(vv, 10)).is(2)
			end)

			test("vertex in slot 2 → opposite neighbor slot 3", function()
				expect(CDTUtils.opposedTriangleInd(vv, 20)).is(3)
			end)

			test("vertex in slot 3 → opposite neighbor slot 1", function()
				expect(CDTUtils.opposedTriangleInd(vv, 30)).is(1)
			end)
		end)

		-- ── opposedVertexInd ──────────────────────────────────────────────────
		describe("opposedVertexInd", function()
			-- nn = {100, 200, 300}
			local nn = { 100, 200, 300 }

			test("neighbor in slot 1 → opposite vertex slot 3", function()
				expect(CDTUtils.opposedVertexInd(nn, 100)).is(3)
			end)

			test("neighbor in slot 2 → opposite vertex slot 1", function()
				expect(CDTUtils.opposedVertexInd(nn, 200)).is(1)
			end)

			test("neighbor in slot 3 → opposite vertex slot 2", function()
				expect(CDTUtils.opposedVertexInd(nn, 300)).is(2)
			end)
		end)

		-- ── edgeNeighborInd ───────────────────────────────────────────────────
		describe("edgeNeighborInd", function()
			-- vv = {1, 2, 3}
			local vv = { 1, 2, 3 }

			test("edge v1-v2 (slots 1,2) → neighbor slot 1", function()
				expect(CDTUtils.edgeNeighborInd(vv, 1, 2)).is(1)
				expect(CDTUtils.edgeNeighborInd(vv, 2, 1)).is(1)
			end)

			test("edge v2-v3 (slots 2,3) → neighbor slot 2", function()
				expect(CDTUtils.edgeNeighborInd(vv, 2, 3)).is(2)
				expect(CDTUtils.edgeNeighborInd(vv, 3, 2)).is(2)
			end)

			test("edge v1-v3 (slots 1,3) → neighbor slot 3", function()
				expect(CDTUtils.edgeNeighborInd(vv, 1, 3)).is(3)
				expect(CDTUtils.edgeNeighborInd(vv, 3, 1)).is(3)
			end)
		end)

		-- ── vertexInd ─────────────────────────────────────────────────────────
		describe("vertexInd", function()
			local vv = { 7, 8, 9 }

			test("returns 1 when vertex is in slot 1", function()
				expect(CDTUtils.vertexInd(vv, 7)).is(1)
			end)

			test("returns 2 when vertex is in slot 2", function()
				expect(CDTUtils.vertexInd(vv, 8)).is(2)
			end)

			test("returns 3 when vertex is in slot 3", function()
				expect(CDTUtils.vertexInd(vv, 9)).is(3)
			end)
		end)

		-- ── edgeKey ───────────────────────────────────────────────────────────
		describe("edgeKey", function()
			test("is symmetric regardless of argument order", function()
				expect(CDTUtils.edgeKey(3, 7)).is(CDTUtils.edgeKey(7, 3))
				expect(CDTUtils.edgeKey(1, 100)).is(CDTUtils.edgeKey(100, 1))
			end)

			test("produces distinct keys for distinct edges", function()
				expect(CDTUtils.edgeKey(1, 2) ~= CDTUtils.edgeKey(1, 3)).is(true)
				expect(CDTUtils.edgeKey(1, 2) ~= CDTUtils.edgeKey(2, 3)).is(true)
			end)

			test("encodes small edge as min*SHIFT+max", function()
				local SHIFT = CDTUtils.EDGE_KEY_SHIFT
				expect(CDTUtils.edgeKey(1, 2)).is(1 * SHIFT + 2)
			end)
		end)

		-- ── touchesSuperTriangle ──────────────────────────────────────────────
		describe("touchesSuperTriangle", function()
			test("true when any vertex index is ≤ 3", function()
				local tri = CDTUtils.makeTriangle(1, 5, 6, 0, 0, 0)
				expect(CDTUtils.touchesSuperTriangle(tri)).is(true)

				local tri2 = CDTUtils.makeTriangle(7, 3, 8, 0, 0, 0)
				expect(CDTUtils.touchesSuperTriangle(tri2)).is(true)
			end)

			test("false when all vertex indices are > 3", function()
				local tri = CDTUtils.makeTriangle(4, 5, 6, 0, 0, 0)
				expect(CDTUtils.touchesSuperTriangle(tri)).is(false)
			end)
		end)

		-- ── triContainsVertex ─────────────────────────────────────────────────
		describe("triContainsVertex", function()
			local tri = CDTUtils.makeTriangle(10, 20, 30, 0, 0, 0)

			test("true for vertex in any slot", function()
				expect(CDTUtils.triContainsVertex(tri, 10)).is(true)
				expect(CDTUtils.triContainsVertex(tri, 20)).is(true)
				expect(CDTUtils.triContainsVertex(tri, 30)).is(true)
			end)

			test("false for a vertex not in the triangle", function()
				expect(CDTUtils.triContainsVertex(tri, 99)).is(false)
			end)
		end)
	end)
end
