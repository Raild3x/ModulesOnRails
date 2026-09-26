-- Authors: Logan Hunt (Raildex)
-- September 25, 2026

return function(t: tiniest)
	local Quantize = require("../Quantize")
	local CDT = require("../../ConstrainedDelaunay")

	local describe = t.describe
	local expect = t.expect
	local test = t.test

	local Orient2D = CDT.Orient2D

	-- Deterministic LCG (Lune has no Random).
	local function makeRng(seed: number): (number, number) -> number
		local state = seed
		return function(lo: number, hi: number): number
			state = (state * 1103515245 + 12345) % 2147483648
			-- The high bits: an LCG's low bits have a short period.
			return lo + math.floor(state / 2147483648 * (hi - lo + 1))
		end
	end

	local function pt(coords: { number }, v: number): (number, number)
		return coords[2 * v - 1], coords[2 * v]
	end

	-- Whether the closed segment p-q meets the open square of half-width 1/2 around (cx, cy).
	-- This is an independent check (separating axes plus exact Orient2D), not the module's
	-- clipping.
	local function meetsOpenPixel(px: number, py: number, qx: number, qy: number, cx: number, cy: number): boolean
		if math.max(px, qx) <= cx - 0.5 or math.min(px, qx) >= cx + 0.5 then
			return false
		end
		if math.max(py, qy) <= cy - 0.5 or math.min(py, qy) >= cy + 0.5 then
			return false
		end
		local pos, neg = false, false
		for _, corner in { { -0.5, -0.5 }, { 0.5, -0.5 }, { 0.5, 0.5 }, { -0.5, 0.5 } } do
			local s = Orient2D(px, py, qx, qy, cx + corner[1], cy + corner[2])
			pos = pos or s > 0
			neg = neg or s < 0
		end
		return pos and neg
	end

	-- The snap-rounding invariants. Returns a list of violations (empty = holds).
	local function violations(coords: { number }, edges: { number }): { string }
		local found = {}
		local vertexCount = #coords // 2
		for i = 1, #edges // 2 do
			local a, b = edges[2 * i - 1], edges[2 * i]
			local ax, ay = pt(coords, a)
			local bx, by = pt(coords, b)
			if ax == bx and ay == by then
				table.insert(found, `edge {i} has zero length`)
			end
			-- (1) No two fragments cross properly.
			for j = i + 1, #edges // 2 do
				local c, d = edges[2 * j - 1], edges[2 * j]
				local cx, cy = pt(coords, c)
				local dx, dy = pt(coords, d)
				if
					Orient2D(ax, ay, bx, by, cx, cy) * Orient2D(ax, ay, bx, by, dx, dy) < 0
					and Orient2D(cx, cy, dx, dy, ax, ay) * Orient2D(cx, cy, dx, dy, bx, by) < 0
				then
					table.insert(found, `edges {i} and {j} cross`)
				end
			end
			-- (2) No fragment enters the pixel of a vertex that is not one of its ends (ISR).
			for v = 1, vertexCount do
				local vx, vy = pt(coords, v)
				if (vx ~= ax or vy ~= ay) and (vx ~= bx or vy ~= by) and meetsOpenPixel(ax, ay, bx, by, vx, vy) then
					table.insert(found, `edge {i} enters the pixel of vertex {v} ({vx}, {vy})`)
				end
			end
		end
		return found
	end

	-- Each source segment's fragments must form a chain from its start to its end.
	local function chainsHold(
		coords: { number },
		inEdges: { number },
		outEdges: { number },
		source: { number }
	): boolean
		local cursor: { [number]: number } = {}
		for f = 1, #source do
			local k = source[f]
			local expected = cursor[k] or inEdges[2 * k - 1]
			local ex, ey = pt(coords, expected)
			local fx, fy = pt(coords, outEdges[2 * f - 1])
			if ex ~= fx or ey ~= fy then
				return false
			end
			cursor[k] = outEdges[2 * f]
		end
		for k, last in cursor do
			local lx, ly = pt(coords, last)
			local bx, by = pt(coords, inEdges[2 * k])
			if lx ~= bx or ly ~= by then
				return false
			end
		end
		return true
	end

	local function addsNoVertex(coords: { number }, edges: { number }, groups: { number }): boolean
		local tri = CDT.Triangulate { Coords = coords, Edges = edges, EdgeGroups = groups }
		for v = 1, CDT.VertexCount(tri) do
			if CDT.InputVertexOf(tri, v) == nil then
				return false
			end
		end
		return true
	end

	local function zeros(n: number): { number }
		return table.create(n, 0)
	end

	-- A soup of random segments. `span` sets how crowded the pixels are; `shallow` adds long,
	-- nearly parallel segments, the sliver-prone case.
	local function soup(seed: number, count: number, span: number, shallow: boolean): ({ number }, { number })
		local rng = makeRng(seed)
		local coords, edges = {}, {}
		for s = 1, count do
			local ax, ay = rng(0, span), rng(0, span)
			local bx, by = rng(0, span), rng(0, span)
			if shallow and s % 2 == 0 then
				ax, bx = 0, span
				by = ay + rng(-2, 2)
			end
			table.insert(coords, ax)
			table.insert(coords, ay)
			table.insert(coords, bx)
			table.insert(coords, by)
			table.insert(edges, 2 * s - 1)
			table.insert(edges, 2 * s)
		end
		return coords, edges
	end

	-- Random closed rings (self-intersections allowed) in winding group 1.
	local function rings(seed: number, ringCount: number, span: number): ({ number }, { number })
		local rng = makeRng(seed)
		local coords, edges = {}, {}
		for _ = 1, ringCount do
			local first = #coords // 2 + 1
			local n = rng(3, 7)
			for i = 0, n - 1 do
				table.insert(coords, rng(0, span))
				table.insert(coords, rng(0, span))
				table.insert(edges, first + i)
				table.insert(edges, first + (i + 1) % n)
			end
		end
		return coords, edges
	end

	describe("ToGrid", function()
		test("quantizes studs to 1/256 grid integers", function()
			expect(Quantize.ToGrid(1.5)).is(384)
			expect(Quantize.ToGrid(-0.001)).is(0)
			expect(Quantize.ToGrid(32768)).is(8388608)
		end)

		test("errors outside ±32,768 studs and on NaN (U-d)", function()
			expect(function()
				Quantize.ToGrid(32768.01)
			end).fails()
			expect(function()
				Quantize.ToGrid(-40000)
			end).fails()
			expect(function()
				Quantize.ToGrid(0 / 0)
			end).fails()
		end)
	end)

	describe("SnapRound", function()
		test("routes two crossing segments through one shared hot pixel", function()
			-- y = 0.4x crosses y = 4 - 0.5x at (4.44, 1.78), which is in pixel (4, 2).
			local coords = { 0, 0, 10, 4, 2, 3, 8, 0 }
			local edges = { 1, 2, 3, 4 }
			local outCoords, outEdges, source = Quantize.SnapRound(coords, edges)
			expect(#outCoords).is(10)
			expect(outCoords[9]).is(4)
			expect(outCoords[10]).is(2)
			expect(table.concat(outEdges, ",")).is("1,5,5,2,3,5,5,4")
			expect(table.concat(source, ",")).is("1,1,2,2")
		end)

		-- Pixel (0, 0) is made hot by a zero-length segment (vertices 1, 2), so nothing else
		-- interferes. Only the bottom-left corner of a half-open pixel is inside it.
		local function routeNearOrigin(ax: number, ay: number, bx: number, by: number): string
			local _, outEdges = Quantize.SnapRound({ 0, 0, 0, 0, ax, ay, bx, by }, { 1, 2, 3, 4 })
			return table.concat(outEdges, ",")
		end

		test("half-open pixels: a segment touching only a corner hits only the bottom-left one", function()
			local cases = {
				{ "top-right (0.5, 0.5)", { -1, 2, 2, -1 }, "3,4" },
				{ "top-left (-0.5, 0.5)", { -2, -1, 1, 2 }, "3,4" },
				{ "bottom-right (0.5, -0.5)", { -1, -2, 2, 1 }, "3,4" },
				{ "bottom-left (-0.5, -0.5)", { -2, 1, 1, -2 }, "3,1,1,4" },
			}
			for _, case in cases do
				local s = case[2]
				expect(routeNearOrigin(s[1], s[2], s[3], s[4])).with_context(case[1]).is(case[3])
				-- Reversed, the entry and exit bounds swap roles.
				expect(routeNearOrigin(s[3], s[4], s[1], s[2])).with_context(`{case[1]} reversed`).is(case[3])
			end
		end)

		test("a segment ending one pixel short of a hot pixel is not routed through it", function()
			expect(routeNearOrigin(-5, 0, -1, 0)).is("3,4")
			expect(routeNearOrigin(1, 0, 5, 0)).is("3,4")
			expect(routeNearOrigin(1, 1, 4, 3)).is("3,4")
			-- ...and one passing through it is.
			expect(routeNearOrigin(-3, 0, 3, 0)).is("3,1,1,4")
		end)

		test("collinear overlap and a T-junction reuse the endpoint vertices, adding none", function()
			-- 1-2 and 3-4 overlap on y = 0; 5-6 ends on 1-2's interior.
			local coords = { 0, 0, 10, 0, 4, 0, 14, 0, 7, 5, 7, 0 }
			local outCoords, outEdges = Quantize.SnapRound(coords, { 1, 2, 3, 4, 5, 6 })
			expect(#outCoords).is(#coords)
			expect(table.concat(outEdges, ",")).is("1,3,3,6,6,2,3,6,6,2,2,4,5,6")
		end)

		test("a routed segment reuses the input vertex at a hot pixel instead of duplicating it", function()
			-- The line y = -1 - x touches (0, 0)'s included corner, then crosses 1-2 at (0, -1).
			local outCoords, outEdges = Quantize.SnapRound({ 0, 0, 0, -5, -2, 1, 1, -2 }, { 1, 2, 3, 4 })
			expect(#outCoords).is(10)
			expect(table.concat(outEdges, ",")).is("1,5,5,2,3,1,1,5,5,4")
		end)

		test("through a corner, the pixel touched at the corner comes before the one entered there", function()
			-- 5-6 on y = -1 - x passes the corner (-0.5, -0.5): pixel (0, 0) holds only that point
			-- and pixel (0, -1) starts just after it, so both share the entry parameter. The
			-- hot pixels are made in the opposite order by zero-length segments (0, -1) then (0, 0).
			local _, outEdges = Quantize.SnapRound({ 0, -1, 0, -1, 0, 0, 0, 0, -2, 1, 1, -2 }, { 1, 2, 3, 4, 5, 6 })
			expect(table.concat(outEdges, ",")).is("5,3,3,1,1,6")

			-- Going up-left on y = -x through (0.5, -0.5): pixel (1, 0) holds only the corner, and
			-- (0, 0) is entered there. Its entry is open on x (right edge) but closed on y (bottom).
			local _, upLeft = Quantize.SnapRound({ 0, 0, 0, 0, 1, 0, 1, 0, 2, -2, -2, 2 }, { 1, 2, 3, 4, 5, 6 })
			expect(table.concat(upLeft, ",")).is("5,3,3,1,1,6")
		end)

		test("a crossing exactly on a pixel edge marks both pixels hot", function()
			-- 1-2 (y = 0) crosses 3-4 at (4.5, 0), on the edge between pixels (4, 0) and (5, 0).
			local outCoords, outEdges = Quantize.SnapRound({ 0, 0, 9, 0, 4, -1, 5, 1 }, { 1, 2, 3, 4 })
			expect(table.concat(outCoords, ",", 9)).is("4,0,5,0")
			expect(table.concat(outEdges, ",")).is("1,5,5,6,6,2,3,5,5,6,6,4")
		end)

		test("drops zero-length segments and keeps input vertex indices", function()
			local outCoords, outEdges = Quantize.SnapRound({ 5, 7, 5, 7, 0, 0, 3, 0 }, { 1, 2, 3, 4 })
			expect(table.concat(outEdges, ",")).is("3,4")
			expect(#outCoords).is(8)
		end)

		test("random soups: no crossings, no fragment through a foreign hot pixel, no CDT vertex added", function()
			local soups, checked = 0, 0
			for seed = 1, 120 do
				local span = if seed % 3 == 0 then 400 else 24
				local coords, edges = soup(seed, 6 + seed % 20, span, seed % 4 == 0)
				local outCoords, outEdges, source = Quantize.SnapRound(coords, edges)
				local bad = violations(outCoords, outEdges)
				expect(#bad).with_context(`seed {seed}: {bad[1]}`).is(0)
				expect(chainsHold(outCoords, edges, outEdges, source)).with_context(`seed {seed}`).is_true()
				expect(addsNoVertex(outCoords, outEdges, zeros(#outEdges // 2))).with_context(`seed {seed}`).is_true()
				soups += 1
				checked += #outEdges // 2
			end
			expect(soups).is(120)
			expect(checked > 1000).is_true()
		end)

		test("random closed rings stay closed and balanced in winding group 1", function()
			for seed = 1, 60 do
				local coords, edges = rings(seed, 1 + seed % 4, if seed % 2 == 0 then 30 else 600)
				local outCoords, outEdges = Quantize.SnapRound(coords, edges)
				local groups = table.create(#outEdges // 2, 1)
				-- Triangulate errors on an unbalanced group, so passing proves the rings closed.
				expect(addsNoVertex(outCoords, outEdges, groups)).with_context(`seed {seed}`).is_true()
				expect(#violations(outCoords, outEdges)).with_context(`seed {seed}`).is(0)
			end
		end)

		test("the invariant checks catch unsnapped soups and near-misses (negative control)", function()
			local crossingSoups, steinerSoups = 0, 0
			for seed = 1, 40 do
				local coords, edges = soup(seed, 12, 24, false)
				if #violations(coords, edges) > 0 then
					crossingSoups += 1
				end
				if not addsNoVertex(coords, edges, zeros(#edges // 2)) then
					steinerSoups += 1
				end
			end
			expect(crossingSoups > 30).is_true()
			expect(steinerSoups > 30).is_true()

			-- A fragment passing 0.4 of a pixel from a vertex it doesn't end at.
			local nearMiss = violations({ 0, 0, 10, 1, 5, 0 }, { 1, 2 })
			expect(#nearMiss).is(1)
		end)
	end)
end
