-- Authors: Logan Hunt (Raildex)
-- September 25, 2026
-- Test layer 1, invariant (d): the flood's per-group winding equals a direct point-in-polygon
-- winding count of the input rings, at every triangle's centroid.

return function(t: tiniest)
	local CDT = require("../ConstrainedDelaunay")
	local Invariants = require("./Helpers/Invariants")

	local describe = t.describe
	local expect = t.expect
	local test = t.test

	type Ring = { Group: number, Points: { number } }

	local function makeRng(seed: number): (number, number) -> number
		local state = seed
		return function(lo: number, hi: number): number
			state = (state * 1103515245 + 12345) % 2147483648
			return lo + (state / 2147483648) * (hi - lo)
		end
	end

	-- Winding number of (px, py) around a ring of flat x,y pairs (standard crossing rule).
	local function ringWinding(points: { number }, px: number, py: number): number
		local w = 0
		local count = #points // 2
		for i = 1, count do
			local j = i % count + 1
			local x1, y1, x2, y2 = points[2 * i - 1], points[2 * i], points[2 * j - 1], points[2 * j]
			local side = (x2 - x1) * (py - y1) - (px - x1) * (y2 - y1)
			if y1 <= py then
				if y2 > py and side > 0 then
					w += 1
				end
			elseif y2 <= py and side < 0 then
				w -= 1
			end
		end
		return w
	end

	local function toInput(rings: { Ring }): CDT.TriangulateInput
		return CDT.Fixtures.ToInput { Name = "", Rings = rings }
	end

	-- Steiner vertices at constraint crossings are rounded, so the triangulated constraint
	-- chain can sit ~1e-15 off the exact ring edge. A sliver between the two has its centroid
	-- on the "wrong" side of the exact ring, so the exact-geometry reference can't judge it:
	-- skip slivers (min altitude < SLIVER) that touch a Steiner vertex. The flood itself counts
	-- winding around the triangulated chains, which is the CDT's defined semantics.
	local SLIVER = 1e-6
	local skippedSlivers = 0

	local function isSteinerSliver(
		tri: CDT.Triangulation,
		a: number,
		b: number,
		c: number,
		ax,
		ay,
		bx,
		by,
		cx,
		cy
	): boolean
		if CDT.InputVertexOf(tri, a) and CDT.InputVertexOf(tri, b) and CDT.InputVertexOf(tri, c) then
			return false
		end
		local area2 = math.abs((bx - ax) * (cy - ay) - (by - ay) * (cx - ax))
		local longest = math.max(
			math.sqrt((bx - ax) ^ 2 + (by - ay) ^ 2),
			math.sqrt((cx - bx) ^ 2 + (cy - by) ^ 2),
			math.sqrt((ax - cx) ^ 2 + (ay - cy) ^ 2)
		)
		return area2 / longest < SLIVER
	end

	-- Number of (triangle, group) pairs whose flood winding differs from the reference.
	local function mismatches(rings: { Ring }, reference: { Ring }?): (number, CDT.Triangulation)
		local input = toInput(rings)
		local tri = CDT.Triangulate(input)
		local ok, reason = Invariants.Check(tri, input.Coords, input.Edges)
		expect(ok).with_context(reason).is_true()
		local wrong = 0
		local truth = reference or rings
		for tt = 1, CDT.TriangleCount(tri) do
			local a, b, c = CDT.GetTriangle(tri, tt)
			local ax, ay = CDT.GetVertex(tri, a)
			local bx, by = CDT.GetVertex(tri, b)
			local cx, cy = CDT.GetVertex(tri, c)
			if isSteinerSliver(tri, a, b, c, ax, ay, bx, by, cx, cy) then
				skippedSlivers += 1
				continue
			end
			local px, py = (ax + bx + cx) / 3, (ay + by + cy) / 3
			for g = 1, CDT.GroupCount(tri) do
				local expected = 0
				for _, ring in truth do
					if ring.Group == g then
						expected += ringWinding(ring.Points, px, py)
					end
				end
				if CDT.GetWinding(tri, tt, g) ~= expected then
					wrong += 1
				end
			end
		end
		return wrong, tri
	end

	describe("winding groups", function()
		test("every fixture matches the direct winding count", function()
			for _, scenario in CDT.Fixtures.All do
				local wrong = mismatches(scenario.Rings)
				expect(wrong).with_context(scenario.Name).is(0)
			end
		end)

		test("a CW hole in the same group cancels to 0", function()
			local _, tri = mismatches(CDT.Fixtures.SquareWithHole.Rings)
			local inHole = CDT.Locate(tri, 5, 5)
			local inRing = CDT.Locate(tri, 1, 1)
			expect(CDT.GetWinding(tri, inHole, 1)).is(0)
			expect(CDT.GetWinding(tri, inRing, 1)).is(1)
		end)

		test("overlapping obstacles count twice in their overlap", function()
			local _, tri = mismatches(CDT.Fixtures.OverlappingObstacles.Rings)
			expect(CDT.GetWinding(tri, CDT.Locate(tri, 7.5, 7.5), 2)).is(2)
			expect(CDT.GetWinding(tri, CDT.Locate(tri, 4, 4), 2)).is(1)
			expect(CDT.GetWinding(tri, CDT.Locate(tri, 15, 15), 2)).is(0)
			expect(CDT.GetWinding(tri, CDT.Locate(tri, 15, 15), 1)).is(1)
		end)

		test("group 0 constraints add no winding", function()
			local rings = CDT.Fixtures.SquareWithHole.Rings
			local input = toInput(rings)
			local groups = input.EdgeGroups :: { number }
			for k = 5, 8 do
				groups[k] = 0 -- the hole becomes a plain constraint
			end
			local tri = CDT.Triangulate(input)
			expect(CDT.GetWinding(tri, CDT.Locate(tri, 5, 5), 1)).is(1)
		end)

		test("seeded random rings in three groups (self-intersecting allowed)", function()
			skippedSlivers = 0
			local total, triangles = 0, 0
			for trial = 1, 30 do
				local rng = makeRng(500 + trial)
				local rings: { Ring } = {}
				for r = 1, 2 + trial % 4 do
					local points = {}
					for _ = 1, 3 + math.floor(rng(0, 5)) do
						table.insert(points, math.floor(rng(0, 40)) + (if trial % 2 == 0 then 0 else rng(0, 1)))
						table.insert(points, math.floor(rng(0, 40)) + (if trial % 2 == 0 then 0 else rng(0, 1)))
					end
					table.insert(rings, { Group = 1 + r % 3, Points = points })
				end
				local ok, wrong, tri = pcall(mismatches, rings)
				expect(ok).with_context(`trial {trial}: {wrong}`).is_true()
				total += wrong :: number
				triangles += CDT.TriangleCount(tri)
			end
			expect(total).is(0)
			-- Skipped slivers must stay a rare exception, not a loophole.
			expect(skippedSlivers <= triangles // 100).with_context(`{skippedSlivers} slivers of {triangles}`).is_true()
		end)
	end)

	describe("ToDrawList golden (coloured by winding)", function()
		test("square with hole, group 1", function()
			local tri = CDT.Triangulate(CDT.Fixtures.ToInput(CDT.Fixtures.SquareWithHole))
			t.snapshot(CDT.ToDrawList(tri, { ColorByGroup = 1 }))
		end)
	end)

	describe("invariant (d) negative control", function()
		test("a reversed reference ring is detected", function()
			local rings = CDT.Fixtures.SquareWithHole.Rings
			local reversedHole = {}
			local hole = rings[2].Points
			for i = #hole // 2, 1, -1 do
				table.insert(reversedHole, hole[2 * i - 1])
				table.insert(reversedHole, hole[2 * i])
			end
			local wrong = mismatches(rings, { rings[1], { Group = 1, Points = reversedHole } })
			expect(wrong > 0).is_true()
		end)
	end)
end
