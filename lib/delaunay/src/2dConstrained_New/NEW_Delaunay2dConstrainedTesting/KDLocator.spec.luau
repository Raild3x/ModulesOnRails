--!strict
return function(t: tiniest)
	local KDLocator = require("../KDLocator")

	local describe = t.describe
	local expect = t.expect
	local test = t.test

	-- Build a simple grid of points for insertion tests.
	local function makeGrid(n: number): { Vector2 }
		local pts: { Vector2 } = {}
		for x = 0, n - 1 do
			for y = 0, n - 1 do
				table.insert(pts, Vector2.new(x * 10, y * 10))
			end
		end
		return pts
	end

	describe("KDLocator", function()
		-- ── new ───────────────────────────────────────────────────────────────
		describe("new", function()
			test("starts empty", function()
				local loc = KDLocator.new()
				expect(loc:isEmpty()).is(true)
			end)
		end)

		-- ── addPoint ─────────────────────────────────────────────────────────
		describe("addPoint", function()
			test("isEmpty becomes false after the first insertion", function()
				local loc = KDLocator.new()
				local verts = { Vector2.new(5, 5) }
				loc:addPoint(1, verts)
				expect(loc:isEmpty()).is(false)
			end)

			test("adding multiple points does not error", function()
				local loc = KDLocator.new()
				local verts = makeGrid(4)
				for i = 1, #verts do
					loc:addPoint(i, verts)
				end
				expect(loc:isEmpty()).is(false)
			end)
		end)

		-- ── initialize ────────────────────────────────────────────────────────
		describe("initialize", function()
			test("isEmpty becomes false after initializing with vertices", function()
				local loc = KDLocator.new()
				local verts = makeGrid(3)
				loc:initialize(verts)
				expect(loc:isEmpty()).is(false)
			end)

			test("re-initialize resets the tree from a prior state", function()
				local loc = KDLocator.new()
				local verts1 = makeGrid(4)
				loc:initialize(verts1)
				-- Reinitialize with a different (smaller) set
				local verts2 = { Vector2.new(0, 0), Vector2.new(1, 0), Vector2.new(0, 1) }
				loc:initialize(verts2)
				-- nearPoint should still work correctly
				local nearest = loc:nearPoint(Vector2.new(0.1, 0.1), verts2)
				expect(nearest >= 1 and nearest <= 3).is(true)
			end)
		end)

		-- ── nearPoint ────────────────────────────────────────────────────────
		describe("nearPoint", function()
			test("returns the index of the exact matching vertex", function()
				local loc = KDLocator.new()
				local verts = {
					Vector2.new(0, 0), -- 1
					Vector2.new(10, 0), -- 2
					Vector2.new(0, 10), -- 3
					Vector2.new(10, 10), -- 4
				}
				loc:initialize(verts)
				expect(loc:nearPoint(Vector2.new(0, 0), verts)).is(1)
				expect(loc:nearPoint(Vector2.new(10, 0), verts)).is(2)
				expect(loc:nearPoint(Vector2.new(0, 10), verts)).is(3)
				expect(loc:nearPoint(Vector2.new(10, 10), verts)).is(4)
			end)

			test("returns the nearest vertex to a query not coinciding with any vertex", function()
				local loc = KDLocator.new()
				local verts = {
					Vector2.new(0, 0), -- 1  (closest to query (0.1, 0.1))
					Vector2.new(100, 0), -- 2
					Vector2.new(100, 100), -- 3
					Vector2.new(0, 100), -- 4
				}
				loc:initialize(verts)
				expect(loc:nearPoint(Vector2.new(0.1, 0.1), verts)).is(1)
			end)

			test("returns the nearest vertex for a query near the center", function()
				-- 5-point cross: center at (5,5), four corners at distance > √50
				local loc = KDLocator.new()
				local verts = {
					Vector2.new(0, 0),
					Vector2.new(10, 0),
					Vector2.new(10, 10),
					Vector2.new(0, 10),
					Vector2.new(5, 5), -- closest to (4.9, 4.9)
				}
				loc:initialize(verts)
				expect(loc:nearPoint(Vector2.new(4.9, 4.9), verts)).is(5)
			end)

			test("handles a large grid correctly", function()
				local loc = KDLocator.new()
				local verts = makeGrid(10) -- 100 points at 10-unit spacing
				loc:initialize(verts)
				-- Query the exact position of the last point
				local last = #verts
				local result = loc:nearPoint(verts[last], verts)
				expect(result).is(last)
			end)
		end)
	end)
end
