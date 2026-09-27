-- Authors: Logan Hunt (Raildex)
-- September 27, 2026
-- Refine (ticket 10): the angle and area bounds, hull edges as segments (SR8), the input-angle
-- skip and the MaxSteiner budget (P6), with every invariant, winding and constraint chain kept.

return function(t: tiniest)
	local CDT = require("../ConstrainedDelaunay")
	local Invariants = require("./Helpers/Invariants")

	local describe = t.describe
	local expect = t.expect
	local test = t.test

	type Tri = CDT.Triangulation

	local function isSegment(tri: Tri, tr: number, e: number): boolean
		return CDT.GetNeighbor(tri, tr, e) == 0 or CDT.GetCoveringEdgeCount(tri, tr, e) > 0
	end

	-- Violations of the bounds: a triangle over MaxArea, or with an angle under MinAngle that
	-- is not an input angle (both edges at that vertex are segments).
	local function boundViolations(tri: Tri, minAngle: number, maxArea: number): { string }
		local found = {}
		for tr = 1, CDT.TriangleCount(tri) do
			local verts = { CDT.GetTriangle(tri, tr) }
			local xs, ys = {}, {}
			for i = 1, 3 do
				xs[i], ys[i] = CDT.GetVertex(tri, verts[i])
			end
			local area = ((xs[2] - xs[1]) * (ys[3] - ys[1]) - (ys[2] - ys[1]) * (xs[3] - xs[1])) / 2
			if area > maxArea + 1e-9 then
				table.insert(found, `triangle {tr} has area {area}`)
			end
			for i = 1, 3 do
				local j, k = i % 3 + 1, (i + 1) % 3 + 1
				local ux, uy = xs[j] - xs[i], ys[j] - ys[i]
				local vx, vy = xs[k] - xs[i], ys[k] - ys[i]
				local angle = math.deg(
					math.acos(
						math.clamp((ux * vx + uy * vy) / math.sqrt((ux * ux + uy * uy) * (vx * vx + vy * vy)), -1, 1)
					)
				)
				if angle < minAngle - 1e-6 and not (isSegment(tri, tr, j) and isSegment(tri, tr, k)) then
					table.insert(found, `triangle {tr} has a {angle} degree angle`)
				end
			end
		end
		return found
	end

	-- Segments with a vertex strictly inside their diametral circle (none may remain).
	local function encroachedSegments(tri: Tri): { string }
		local found = {}
		for tr = 1, CDT.TriangleCount(tri) do
			local verts = { CDT.GetTriangle(tri, tr) }
			for e = 1, 3 do
				if isSegment(tri, tr, e) then
					local px, py = CDT.GetVertex(tri, verts[e])
					local ux, uy = CDT.GetVertex(tri, verts[e % 3 + 1])
					local vx, vy = CDT.GetVertex(tri, verts[(e + 1) % 3 + 1])
					if (ux - px) * (vx - px) + (uy - py) * (vy - py) < 0 then
						table.insert(found, `a segment of triangle {tr} is encroached by vertex {verts[e]}`)
					end
				end
			end
		end
		return found
	end

	-- Winding of (px, py) around a ring of flat x,y pairs.
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

	local function windingMismatches(tri: Tri, rings: { any }): { string }
		local found = {}
		for tr = 1, CDT.TriangleCount(tri) do
			local a, b, c = CDT.GetTriangle(tri, tr)
			local ax, ay = CDT.GetVertex(tri, a)
			local bx, by = CDT.GetVertex(tri, b)
			local cx, cy = CDT.GetVertex(tri, c)
			local px, py = (ax + bx + cx) / 3, (ay + by + cy) / 3
			for g = 1, CDT.GroupCount(tri) do
				local expected = 0
				for _, ring in rings do
					if ring.Group == g then
						expected += ringWinding(ring.Points, px, py)
					end
				end
				if CDT.GetWinding(tri, tr, g) ~= expected then
					table.insert(found, `triangle {tr} group {g}: {CDT.GetWinding(tri, tr, g)} vs {expected}`)
				end
			end
		end
		return found
	end

	local function steinerCount(tri: Tri): number
		local n = 0
		for v = 1, CDT.VertexCount(tri) do
			if CDT.InputVertexOf(tri, v) == nil then
				n += 1
			end
		end
		return n
	end

	local function square(side: number): CDT.TriangulateInput
		return { Coords = { 0, 0, side, 0, side, side, 0, side } }
	end

	describe("Refine", function()
		test("refined fixtures meet the bounds and keep every invariant, winding and chain", function()
			for _, scenario in CDT.Fixtures.All do
				local input = CDT.Fixtures.ToInput(scenario)
				local tri = CDT.Triangulate(input)
				local before = CDT.TriangleCount(tri)
				expect(CDT.Refine(tri, { MinAngle = 20, MaxArea = 2 })).with_context(scenario.Name).is_true()
				expect(CDT.TriangleCount(tri) > before).with_context(scenario.Name).is_true()
				local ok, reason = Invariants.Check(tri, input.Coords, input.Edges)
				expect(ok).with_context(`{scenario.Name}: {reason}`).is_true()
				expect(table.concat(boundViolations(tri, 20, 2), "\n")).with_context(scenario.Name).is("")
				expect(table.concat(encroachedSegments(tri), "\n")).with_context(scenario.Name).is("")
				expect(table.concat(windingMismatches(tri, scenario.Rings), "\n")).with_context(scenario.Name).is("")
			end
		end)

		test("hull edges act as segments: vertices never leave the hull", function()
			-- A flat hull triangle whose circumcentre lies far outside it.
			local input = { Coords = { 0, 0, 10, 0, 5, 0.5 } }
			local tri = CDT.Triangulate(input)
			expect(CDT.Refine(tri, { MinAngle = 20 })).is_true()
			expect(steinerCount(tri) > 0).is_true()
			local hull = { 0, 0, 10, 0, 5, 0.5 }
			for v = 1, CDT.VertexCount(tri) do
				local x, y = CDT.GetVertex(tri, v)
				for i = 1, 3 do
					local j = i % 3 + 1
					local side = CDT.Orient2D(hull[2 * i - 1], hull[2 * i], hull[2 * j - 1], hull[2 * j], x, y)
					expect(side >= 0).with_context(`vertex {v} at {x},{y}`).is_true()
				end
			end
			local ok, reason = Invariants.Check(tri, input.Coords)
			expect(ok).with_context(reason).is_true()
			expect(table.concat(boundViolations(tri, 20, math.huge), "\n")).is("")
		end)

		test("an input angle below the bound is skipped, so refinement still finishes", function()
			-- Two constraints meeting at about 8 degrees inside a square.
			local input = {
				Coords = { 0, 0, 40, 0, 40, 40, 0, 40, 5, 5, 35, 5, 35, 9.2 },
				Edges = { 5, 6, 5, 7 },
				EdgeGroups = { 0, 0 },
			}
			local tri = CDT.Triangulate(input)
			expect(CDT.Refine(tri, { MinAngle = 20 })).is_true()
			local ok, reason = Invariants.Check(tri, input.Coords, input.Edges)
			expect(ok).with_context(reason).is_true()
			expect(table.concat(boundViolations(tri, 20, math.huge), "\n")).is("")
		end)

		test("MaxSteiner stops refinement and reports it", function()
			local tri = CDT.Triangulate(square(100))
			expect(CDT.Refine(tri, { MaxArea = 1, MaxSteiner = 7 })).never_is_true()
			expect(steinerCount(tri)).is(7)
			-- The default budget is max(1024, 4 * input point count).
			local big = CDT.Triangulate(square(100))
			expect(CDT.Refine(big, { MaxArea = 1 })).never_is_true()
			expect(steinerCount(big)).is(1024)
			local ok, reason = Invariants.Check(big, square(100).Coords)
			expect(ok).with_context(reason).is_true()
		end)

		test("a budget that runs out exactly as the bounds are met still reports success", function()
			local probe = CDT.Triangulate(square(8))
			expect(CDT.Refine(probe, { MaxArea = 4 })).is_true()
			local needed = steinerCount(probe)
			expect(needed > 0).is_true()
			local tri = CDT.Triangulate(square(8))
			expect(CDT.Refine(tri, { MaxArea = 4, MaxSteiner = needed })).is_true()
			local short = CDT.Triangulate(square(8))
			expect(CDT.Refine(short, { MaxArea = 4, MaxSteiner = needed - 1 })).never_is_true()
		end)

		test("a triangulation that already meets the bounds is left alone", function()
			local tri = CDT.Triangulate(square(4))
			expect(CDT.Refine(tri, { MinAngle = 20, MaxArea = 100 })).is_true()
			expect(CDT.VertexCount(tri)).is(4)
			local empty = CDT.Triangulate { Coords = {} }
			expect(CDT.Refine(empty, { MaxArea = 1 })).is_true()
		end)

		test("a triangle exactly at MaxArea is left alone", function()
			-- square(4) is two triangles of area 8.
			local tri = CDT.Triangulate(square(4))
			expect(CDT.Refine(tri, { MaxArea = 8 })).is_true()
			expect(steinerCount(tri)).is(0)
			expect(CDT.Refine(tri, { MaxArea = 7.99 })).is_true()
			expect(steinerCount(tri) > 0).is_true()
		end)

		test("the budget also bounds segment splitting", function()
			-- Points just above a long hull edge encroach it again after every split.
			local input = { Coords = { 0, 0, 16, 0, 8, 8, 1, 0.1, 5, 0.1, 11, 0.1, 15, 0.1 } }
			local tri = CDT.Triangulate(input)
			expect(CDT.Refine(tri, { MaxSteiner = 2 })).never_is_true()
			expect(steinerCount(tri)).is(2)
			local full = CDT.Triangulate(input)
			expect(CDT.Refine(full, {})).is_true()
			expect(steinerCount(full) > 2).is_true()
			expect(table.concat(encroachedSegments(full), "\n")).is("")
		end)

		test("the default budget grows with the input: 4 per input point past 256", function()
			local coords = {}
			for i = 0, 299 do
				table.insert(coords, (i % 20) * 5)
				table.insert(coords, (i // 20) * 5)
			end
			local tri = CDT.Triangulate({ Coords = coords })
			expect(CDT.Refine(tri, { MaxArea = 0.01 })).never_is_true()
			expect(steinerCount(tri)).is(1200)
		end)

		test("random point and constraint soups keep every invariant", function()
			local state = 20260927
			local function rng(lo: number, hi: number): number
				state = (state * 1103515245 + 12345) % 2147483648
				return lo + (state / 2147483648) * (hi - lo)
			end
			for seed = 1, 12 do
				local coords, edges, groups = {}, {}, {}
				for _ = 1, 30 do
					table.insert(coords, math.floor(rng(0, 100)))
					table.insert(coords, math.floor(rng(0, 100)))
				end
				-- A few long open constraints between random input points.
				for _ = 1, 4 do
					local a, b = math.floor(rng(1, 31)), math.floor(rng(1, 31))
					if a ~= b then
						table.insert(edges, a)
						table.insert(edges, b)
						table.insert(groups, 0)
					end
				end
				local input = { Coords = coords, Edges = edges, EdgeGroups = groups }
				local tri = CDT.Triangulate(input)
				local done = CDT.Refine(tri, { MinAngle = 20, MaxArea = 40 })
				local ok, reason = Invariants.Check(tri, input.Coords, input.Edges)
				expect(ok).with_context(`seed {seed}: {reason}`).is_true()
				if done then
					expect(table.concat(boundViolations(tri, 20, 40), "\n")).with_context(`seed {seed}`).is("")
					expect(table.concat(encroachedSegments(tri), "\n")).with_context(`seed {seed}`).is("")
				end
			end
		end)

		test("options are validated", function()
			local tri = CDT.Triangulate(square(4))
			for _, bad in
				{ { MinAngle = -1 }, { MinAngle = 60 }, { MaxArea = 0 }, { MaxSteiner = 1.5 }, { MaxSteiner = -1 } }
			do
				expect(function()
					CDT.Refine(tri, bad :: any)
				end).fails_with("Refine:")
			end
		end)
	end)
end
