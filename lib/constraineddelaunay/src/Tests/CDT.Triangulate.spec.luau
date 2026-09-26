-- Authors: Logan Hunt (Raildex)
-- September 25, 2026
-- Test layer 1: unconstrained triangulation through the public API + the invariant checker.

return function(t: tiniest)
	local CDT = require("../ConstrainedDelaunay")
	local Invariants = require("./Helpers/Invariants")
	local Storage = require("../Storage")

	local describe = t.describe
	local expect = t.expect
	local test = t.test
	local snapshot = t.snapshot

	-- Deterministic LCG (Lune has no Random).
	local function makeRng(seed: number): (number, number) -> number
		local state = seed
		return function(lo: number, hi: number): number
			state = (state * 1103515245 + 12345) % 2147483648
			return lo + (state / 2147483648) * (hi - lo)
		end
	end

	local function checked(coords: { number }, label: string)
		local tri = CDT.Triangulate({ Coords = coords })
		local ok, reason = Invariants.Check(tri, coords)
		expect(ok).with_context(`{label}: {reason}`).is_true()
		return tri
	end

	local function pointsOnly(scenario): { number }
		return CDT.Fixtures.ToInput(scenario).Coords
	end

	describe("Triangulate (points only)", function()
		test("every fixture's points", function()
			for _, scenario in CDT.Fixtures.All do
				checked(pointsOnly(scenario), scenario.Name)
			end
		end)

		test("seeded random point sets of many sizes", function()
			local rng = makeRng(3)
			for _, size in { 3, 4, 10, 57, 200, 800 } do
				local coords = {}
				for _ = 1, size do
					table.insert(coords, rng(-100, 100))
					table.insert(coords, rng(-100, 100))
				end
				local tri = checked(coords, `random {size}`)
				expect(CDT.VertexCount(tri)).is(size)
			end
		end)

		test("a fully cocircular integer lattice", function()
			local coords = {}
			for x = 0, 12 do
				for y = 0, 12 do
					table.insert(coords, x)
					table.insert(coords, y)
				end
			end
			local tri = checked(coords, "lattice")
			expect(CDT.TriangleCount(tri)).is(2 * 12 * 12)
		end)

		test("collinear points only give no triangles", function()
			local tri = CDT.Triangulate({ Coords = { 0, 0, 1, 1, 2, 2, 5, 5 } })
			expect(CDT.TriangleCount(tri)).is(0)
			expect(CDT.VertexCount(tri)).is(4)
		end)

		test("exact duplicates merge into the first input point", function()
			local coords = { 0, 0, 4, 0, 0, 4, 4, 0, 1, 1, 0, 0 }
			local tri = checked(coords, "duplicates")
			expect(CDT.VertexCount(tri)).is(4)
			local v = CDT.VertexOfInput(tri, 4)
			expect(v).is(CDT.VertexOfInput(tri, 2))
			expect(CDT.InputVertexOf(tri, v)).is(2)
		end)

		test("points exactly on existing edges (2->4 splits)", function()
			checked({ 0, 0, 10, 0, 10, 10, 0, 10, 5, 5, 5, 0, 10, 5, 2.5, 2.5, 7.5, 7.5 }, "on edges")
		end)

		test("large offsets and tiny coordinates", function()
			local rng = makeRng(9)
			local big, small = {}, {}
			for _ = 1, 150 do
				table.insert(big, 2 ^ 40 + math.floor(rng(0, 50)))
				table.insert(big, 2 ^ 40 + math.floor(rng(0, 50)))
				table.insert(small, rng(0, 1) * 2 ^ -40)
				table.insert(small, rng(0, 1) * 2 ^ -40)
			end
			checked(big, "offset 2^40")
			checked(small, "tiny")
		end)

		test("constraint edges are rejected until ticket 08", function()
			expect(function()
				CDT.Triangulate({ Coords = { 0, 0, 1, 0, 0, 1 }, Edges = { 1, 2 } })
			end).fails()
		end)
	end)

	describe("Locate", function()
		test("finds the containing triangle, and 0 outside the hull", function()
			local rng = makeRng(21)
			local coords = {}
			for _ = 1, 300 do
				table.insert(coords, rng(0, 100))
				table.insert(coords, rng(0, 100))
			end
			local tri = CDT.Triangulate({ Coords = coords })
			local misses = 0
			local hint = nil
			for _ = 1, 500 do
				local x, y = rng(10, 90), rng(10, 90)
				local found = CDT.Locate(tri, x, y, hint)
				local a, b, c = CDT.GetTriangle(tri, found)
				local ax, ay = CDT.GetVertex(tri, a)
				local bx, by = CDT.GetVertex(tri, b)
				local cx, cy = CDT.GetVertex(tri, c)
				local inside = CDT.Orient2D(ax, ay, bx, by, x, y) >= 0
					and CDT.Orient2D(bx, by, cx, cy, x, y) >= 0
					and CDT.Orient2D(cx, cy, ax, ay, x, y) >= 0
				if not inside then
					misses += 1
				end
				hint = found
			end
			expect(misses).is(0)
			expect(CDT.Locate(tri, -1000, -1000)).is(0)
			expect(CDT.Locate(CDT.Triangulate({ Coords = {} }), 0, 0)).is(0)
		end)
	end)

	describe("invariant checker (negative controls)", function()
		test("catches a clockwise triangle", function()
			local coords = { 0, 0, 4, 0, 0, 4, 4, 4 }
			local tri = CDT.Triangulate({ Coords = coords })
			local a, b, c = CDT.GetTriangle(tri, 1)
			Storage.SetTriangle(tri, 1, a, c, b)
			local ok, reason = Invariants.Check(tri, coords)
			expect(ok).never_is_true()
			expect((reason or ""):find("counter%-clockwise") ~= nil).is_true()
		end)

		test("catches a broken neighbour link", function()
			local coords = { 0, 0, 4, 0, 0, 4, 4, 4 }
			local tri = CDT.Triangulate({ Coords = coords })
			for e = 1, 3 do
				if CDT.GetNeighbor(tri, 1, e) ~= 0 then
					Storage.SetNeighbor(tri, 1, e, 0)
				end
			end
			local ok = Invariants.Check(tri, coords)
			expect(ok).never_is_true()
		end)
	end)

	describe("ToDrawList goldens", function()
		test("square with hole points", function()
			snapshot(CDT.ToDrawList(CDT.Triangulate({ Coords = pointsOnly(CDT.Fixtures.SquareWithHole) })))
		end)

		test("small lattice", function()
			snapshot(CDT.ToDrawList(CDT.Triangulate({ Coords = { 0, 0, 1, 0, 2, 0, 0, 1, 1, 1, 2, 1 } })))
		end)
	end)
end
