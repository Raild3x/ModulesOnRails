--!strict
return function(t: tiniest)
	local Predicates = require("../Predicates")

	local describe = t.describe
	local expect = t.expect
	local test = t.test

	-- CCW reference triangle used throughout.
	-- v1=(0,0)  v2=(10,0)  v3=(0,10)
	local V1 = Vector2.new(0, 0)
	local V2 = Vector2.new(10, 0)
	local V3 = Vector2.new(0, 10)

	describe("Predicates", function()
		-- ── orient2D ──────────────────────────────────────────────────────────
		describe("orient2D", function()
			test("returns positive for a point left of the directed edge", function()
				-- p=(0,1) is above (left of) v1=(0,0)→v2=(1,0)
				local d = Predicates.orient2D(Vector2.new(0, 1), Vector2.new(0, 0), Vector2.new(1, 0))
				expect(d > 0).is(true)
			end)

			test("returns negative for a point right of the directed edge", function()
				local d = Predicates.orient2D(Vector2.new(0, -1), Vector2.new(0, 0), Vector2.new(1, 0))
				expect(d < 0).is(true)
			end)

			test("returns zero for a collinear point", function()
				local d = Predicates.orient2D(Vector2.new(2, 0), Vector2.new(0, 0), Vector2.new(1, 0))
				expect(d).is(0)
			end)
		end)

		-- ── classifyOrientation ───────────────────────────────────────────────
		describe("classifyOrientation", function()
			test("classifies positive as Left", function()
				expect(Predicates.classifyOrientation(1)).is("Left")
			end)

			test("classifies negative as Right", function()
				expect(Predicates.classifyOrientation(-1)).is("Right")
			end)

			test("classifies zero as OnLine", function()
				expect(Predicates.classifyOrientation(0)).is("OnLine")
			end)

			test("respects tolerance: value within tol is OnLine", function()
				expect(Predicates.classifyOrientation(0.0001, 0.001)).is("OnLine")
			end)
		end)

		-- ── locatePointLine ───────────────────────────────────────────────────
		describe("locatePointLine", function()
			test("Left for a point above a horizontal directed edge", function()
				local result = Predicates.locatePointLine(Vector2.new(5, 1), Vector2.new(0, 0), Vector2.new(10, 0))
				expect(result).is("Left")
			end)

			test("Right for a point below a horizontal directed edge", function()
				local result = Predicates.locatePointLine(Vector2.new(5, -1), Vector2.new(0, 0), Vector2.new(10, 0))
				expect(result).is("Right")
			end)

			test("OnLine for a point on the edge", function()
				local result = Predicates.locatePointLine(Vector2.new(5, 0), Vector2.new(0, 0), Vector2.new(10, 0))
				expect(result).is("OnLine")
			end)
		end)

		-- ── locatePointTriangle ───────────────────────────────────────────────
		describe("locatePointTriangle", function()
			test("Inside for a point strictly inside a CCW triangle", function()
				local result = Predicates.locatePointTriangle(Vector2.new(1, 1), V1, V2, V3)
				expect(result).is("Inside")
			end)

			test("Outside for a point clearly outside the triangle", function()
				local result = Predicates.locatePointTriangle(Vector2.new(20, 20), V1, V2, V3)
				expect(result).is("Outside")
			end)

			test("OnEdge1 for a point on edge v1→v2", function()
				-- midpoint of v1=(0,0)→v2=(10,0)
				local result = Predicates.locatePointTriangle(Vector2.new(5, 0), V1, V2, V3)
				expect(result).is("OnEdge1")
			end)

			test("OnEdge2 for a point on edge v2→v3", function()
				-- midpoint of v2=(10,0)→v3=(0,10)
				local result = Predicates.locatePointTriangle(Vector2.new(5, 5), V1, V2, V3)
				expect(result).is("OnEdge2")
			end)

			test("OnEdge3 for a point on edge v3→v1", function()
				-- midpoint of v3=(0,10)→v1=(0,0)
				local result = Predicates.locatePointTriangle(Vector2.new(0, 5), V1, V2, V3)
				expect(result).is("OnEdge3")
			end)

			test("OnVertex for a triangle vertex", function()
				-- v1=(0,0) lies on both edge1 (v1→v2) and edge3 (v3→v1)
				local result = Predicates.locatePointTriangle(V1, V1, V2, V3)
				expect(result).is("OnVertex")
			end)

			test("Outside for negative-side of first edge", function()
				-- Point well below the base edge
				local result = Predicates.locatePointTriangle(Vector2.new(5, -5), V1, V2, V3)
				expect(result).is("Outside")
			end)
		end)

		-- ── isOnEdge ──────────────────────────────────────────────────────────
		describe("isOnEdge", function()
			test("true for OnEdge1/2/3", function()
				expect(Predicates.isOnEdge("OnEdge1")).is(true)
				expect(Predicates.isOnEdge("OnEdge2")).is(true)
				expect(Predicates.isOnEdge("OnEdge3")).is(true)
			end)

			test("false for Inside, Outside, OnVertex", function()
				expect(Predicates.isOnEdge("Inside")).is(false)
				expect(Predicates.isOnEdge("Outside")).is(false)
				expect(Predicates.isOnEdge("OnVertex")).is(false)
			end)
		end)

		-- ── edgeLocSlot ───────────────────────────────────────────────────────
		describe("edgeLocSlot", function()
			test("OnEdge1 → slot 1", function()
				expect(Predicates.edgeLocSlot("OnEdge1")).is(1)
			end)

			test("OnEdge2 → slot 2", function()
				expect(Predicates.edgeLocSlot("OnEdge2")).is(2)
			end)

			test("OnEdge3 → slot 3", function()
				expect(Predicates.edgeLocSlot("OnEdge3")).is(3)
			end)
		end)

		-- ── isInCircumcircle ──────────────────────────────────────────────────
		describe("isInCircumcircle", function()
			-- Right-angle triangle: v1=(0,0), v2=(4,0), v3=(0,4).
			-- Circumcenter = (2,2), radius = 2√2.
			local C1 = Vector2.new(0, 0)
			local C2 = Vector2.new(4, 0)
			local C3 = Vector2.new(0, 4)

			test("true for the circumcenter (strictly inside)", function()
				expect(Predicates.isInCircumcircle(Vector2.new(2, 2), C1, C2, C3)).is(true)
			end)

			test("false for a point well outside the circumcircle", function()
				expect(Predicates.isInCircumcircle(Vector2.new(10, 10), C1, C2, C3)).is(false)
			end)

			test("false for a point exactly on the circumcircle boundary", function()
				-- (4,4) is on the circle of the right-angle triangle above
				expect(Predicates.isInCircumcircle(Vector2.new(4, 4), C1, C2, C3)).is(false)
			end)

			test("true for a point just inside the circle", function()
				-- slightly inside from the right-angle corner (0,0)→centre direction
				expect(Predicates.isInCircumcircle(Vector2.new(2, 1.5), C1, C2, C3)).is(true)
			end)
		end)
	end)
end
