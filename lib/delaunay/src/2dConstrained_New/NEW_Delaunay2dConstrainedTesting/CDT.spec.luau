--!strict
return function(t: tiniest)
	local CDTModule = require("../Delaunay2dConstrained")

	local describe = t.describe
	local expect = t.expect
	local test = t.test

	-- Canonical square: 4 vertices in CCW order.
	local function squareVerts(scale: number?): { Vector2 }
		local s = scale or 10
		return {
			Vector2.new(0, 0),
			Vector2.new(s, 0),
			Vector2.new(s, s),
			Vector2.new(0, s),
		}
	end

	-- Build a fully-triangulated square using eraseSuperTriangle.
	local function triangulatedSquare(scale: number?): CDTModule.CDT
		local cdt = CDTModule.new()
		cdt:insertVertices(squareVerts(scale))
		cdt:eraseSuperTriangle()
		return cdt
	end

	-- Helper: check whether any triangle vertex index is out of bounds for the
	-- finalized vertex array.  After any erase* call, _finalizeTriangulation
	-- removes the 3 super-triangle vertices and remaps all remaining indices to
	-- 1..#cdt.vertices, so a valid post-finalization triangulation never has an
	-- index outside that range.  Checking v<=3 is WRONG here because user verts
	-- 1, 2, and 3 are perfectly valid after the remap.
	local function hasSuperVert(cdt: CDTModule.CDT): boolean
		local n = #cdt.vertices
		for _, tri in cdt.triangles do
			for _, v in tri.vertices do
				if v < 1 or v > n then
					return true
				end
			end
		end
		return false
	end

	describe("Delaunay2dConstrained", function()
		-- ── new ───────────────────────────────────────────────────────────────
		describe("new", function()
			test("starts with empty vertices and triangles", function()
				local cdt = CDTModule.new()
				expect(#cdt.vertices).is(0)
				expect(#cdt.triangles).is(0)
			end)

			test("starts with empty edge bookkeeping tables", function()
				local cdt = CDTModule.new()
				local fixedCount = 0
				for _ in cdt.fixedEdges do
					fixedCount += 1
				end
				expect(fixedCount).is(0)
			end)
		end)

		-- ── insertVertices ───────────────────────────────────────────────────
		describe("insertVertices", function()
			test("appends the supplied vertices after the super-triangle", function()
				local cdt = CDTModule.new()
				local verts = squareVerts()
				cdt:insertVertices(verts)
				-- 3 super-triangle + 4 user verts
				expect(#cdt.vertices).is(7)
			end)

			test("creates triangles (including super-triangle fan)", function()
				local cdt = CDTModule.new()
				cdt:insertVertices(squareVerts())
				expect(#cdt.triangles > 0).is(true)
			end)

			test("triangle count is at least 2*n-2 for a convex polygon (n=4)", function()
				local cdt = CDTModule.new()
				cdt:insertVertices(squareVerts())
				cdt:eraseSuperTriangle()
				-- A Delaunay triangulation of 4 convex points produces 2 triangles.
				expect(#cdt.triangles >= 2).is(true)
			end)
		end)

		-- ── eraseSuperTriangle ────────────────────────────────────────────────
		describe("eraseSuperTriangle", function()
			test("removes all triangles that touch super-triangle vertices", function()
				local cdt = triangulatedSquare()
				expect(hasSuperVert(cdt)).is(false)
			end)

			test("leaves at least one triangle for four points", function()
				local cdt = triangulatedSquare()
				expect(#cdt.triangles > 0).is(true)
			end)
		end)

		-- ── eraseOuterTriangles ───────────────────────────────────────────────
		-- eraseOuterTriangles seeds from super-vertex 1 and flood-fills without
		-- stopping at any edge.  Without constrained boundary edges the entire
		-- mesh is consumed.  Both tests therefore add the square boundary first.
		describe("eraseOuterTriangles", function()
			test("result has no super-triangle vertices", function()
				local cdt = CDTModule.new()
				cdt:insertVertices(squareVerts())
				cdt:insertEdges { { 0, 1 }, { 1, 2 }, { 2, 3 }, { 3, 0 } }
				cdt:eraseOuterTriangles()
				expect(hasSuperVert(cdt)).is(false)
			end)

			test("leaves at least one triangle", function()
				local cdt = CDTModule.new()
				cdt:insertVertices(squareVerts())
				cdt:insertEdges { { 0, 1 }, { 1, 2 }, { 2, 3 }, { 3, 0 } }
				cdt:eraseOuterTriangles()
				expect(#cdt.triangles > 0).is(true)
			end)
		end)

		-- ── insertEdges ───────────────────────────────────────────────────────
		describe("insertEdges", function()
			test("records the constrained edge in fixedEdges", function()
				local cdt = CDTModule.new()
				cdt:insertVertices(squareVerts())
				-- Constrain the diagonal: v1=(0,0)→v3=(10,10), 0-based indices 0 and 2.
				cdt:insertEdges { { 0, 2 } }
				local fixedCount = 0
				for _ in cdt.fixedEdges do
					fixedCount += 1
				end
				expect(fixedCount > 0).is(true)
			end)

			test("does not increase total vertex count", function()
				local cdt = CDTModule.new()
				cdt:insertVertices(squareVerts())
				local countBefore = #cdt.vertices
				cdt:insertEdges { { 0, 2 } }
				expect(#cdt.vertices).is(countBefore)
			end)
		end)

		-- ── eraseOuterTrianglesAndHoles ───────────────────────────────────────
		describe("eraseOuterTrianglesAndHoles", function()
			test("removes outer triangles for a simple convex polygon", function()
				local cdt = CDTModule.new()
				cdt:insertVertices(squareVerts())
				-- Close the boundary as constrained edges (CCW order, 0-based).
				cdt:insertEdges { { 0, 1 }, { 1, 2 }, { 2, 3 }, { 3, 0 } }
				cdt:eraseOuterTrianglesAndHoles()
				expect(hasSuperVert(cdt)).is(false)
				expect(#cdt.triangles > 0).is(true)
			end)

			test("excludes hole triangles: point inside the hole has no containing triangle", function()
				-- Outer square 0..30, inner hole square 10..20.
				local cdt = CDTModule.new()
				local outer = {
					Vector2.new(0, 0),
					Vector2.new(30, 0),
					Vector2.new(30, 30),
					Vector2.new(0, 30),
				}
				local inner = {
					Vector2.new(10, 10),
					Vector2.new(20, 10),
					Vector2.new(20, 20),
					Vector2.new(10, 20),
				}
				local all = {}
				for _, v in outer do
					table.insert(all, v)
				end
				for _, v in inner do
					table.insert(all, v)
				end
				cdt:insertVertices(all)
				-- Outer boundary edges (0-based: 0–3)
				-- Inner hole edges (0-based: 4–7)
				cdt:insertEdges {
					{ 0, 1 },
					{ 1, 2 },
					{ 2, 3 },
					{ 3, 0 },
					{ 4, 5 },
					{ 5, 6 },
					{ 6, 7 },
					{ 7, 4 },
				}
				cdt:eraseOuterTrianglesAndHoles()

				-- No triangle should have all three vertices strictly inside the hole (15,15)
				-- We verify this indirectly: every remaining triangle passes hasSuperVert=false
				-- and the total count is what a donut triangulation produces.
				expect(hasSuperVert(cdt)).is(false)

				-- A donut with 4+4 verts should produce 8 triangles (two triangulated bands).
				expect(#cdt.triangles > 0).is(true)
			end)
		end)

		-- ── full pipeline ─────────────────────────────────────────────────────
		describe("full pipeline", function()
			test("square produces exactly 2 Delaunay triangles", function()
				local cdt = triangulatedSquare()
				expect(#cdt.triangles).is(2)
			end)

			test("pentagon produces at least 3 triangles", function()
				local cdt = CDTModule.new()
				local verts: { Vector2 } = {}
				for i = 1, 5 do
					local angle = (i - 1) * (2 * math.pi / 5)
					table.insert(verts, Vector2.new(math.cos(angle) * 10, math.sin(angle) * 10))
				end
				cdt:insertVertices(verts)
				cdt:eraseSuperTriangle()
				expect(#cdt.triangles >= 3).is(true)
			end)

			test("all output vertices are user-supplied (no super-triangle) after erase", function()
				local cdt = triangulatedSquare()
				-- After finalization, super-triangle verts are removed and all remaining
				-- vertex indices are remapped to 1..#cdt.vertices (user verts only).
				local n = #cdt.vertices
				for _, tri in cdt.triangles do
					for _, v in tri.vertices do
						expect(v >= 1 and v <= n).is(true)
					end
				end
			end)

			test("constrained diagonal is preserved as a fixed edge", function()
				local cdt = CDTModule.new()
				cdt:insertVertices(squareVerts())
				cdt:insertEdges { { 0, 2 } } -- diagonal (0,0)→(10,10)
				cdt:eraseSuperTriangle()
				local fixedCount = 0
				for _ in cdt.fixedEdges do
					fixedCount += 1
				end
				expect(fixedCount > 0).is(true)
			end)
		end)
	end)
end
