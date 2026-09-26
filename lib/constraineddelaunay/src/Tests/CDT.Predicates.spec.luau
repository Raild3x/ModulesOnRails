-- Authors: Logan Hunt (Raildex)
-- September 25, 2026

return function(t: tiniest)
	local CDT = require("../ConstrainedDelaunay")

	local describe = t.describe
	local expect = t.expect
	local test = t.test

	local ULP_HALF = 2 ^ -53 -- ulp of numbers in [0.5, 1)
	local OFFSET = 2 ^ 40 -- large enough that naive f64 determinants lose precision

	local function sign(x: number): number
		if x > 0 then
			return 1
		end
		if x < 0 then
			return -1
		end
		return 0
	end

	-- Plain f64 determinants: exact for small integer inputs, wrong near degeneracy otherwise.
	local function naiveOrient(ax, ay, bx, by, cx, cy): number
		return sign((bx - ax) * (cy - ay) - (by - ay) * (cx - ax))
	end
	local function naiveInCircle(ax, ay, bx, by, cx, cy, dx, dy): number
		local adx, ady, bdx, bdy, cdx, cdy = ax - dx, ay - dy, bx - dx, by - dy, cx - dx, cy - dy
		return sign(
			(adx * adx + ady * ady) * (bdx * cdy - cdx * bdy)
				+ (bdx * bdx + bdy * bdy) * (cdx * ady - adx * cdy)
				+ (cdx * cdx + cdy * cdy) * (adx * bdy - bdx * ady)
		)
	end

	-- Deterministic LCG (Lune has no Random).
	local function makeRng(seed: number): (number, number) -> number
		local state = seed
		return function(lo: number, hi: number): number
			state = (state * 1103515245 + 12345) % 2147483648
			return lo + state % (hi - lo + 1)
		end
	end

	describe("Orient2D", function()
		test("signs of simple triangles", function()
			expect(CDT.Orient2D(0, 0, 1, 0, 0, 1)).is(1)
			expect(CDT.Orient2D(0, 0, 0, 1, 1, 0)).is(-1)
			expect(CDT.Orient2D(0, 0, 1, 1, 3, 3)).is(0)
		end)

		-- Kettner et al., "Classroom examples of robustness problems": a point near (0.5, 0.5)
		-- against the line y = x through (12, 12) and (24, 24). The true sign is sign(j - i).
		test("near-collinear grid matches the closed-form sign exactly", function()
			local wrong, naiveWrong = 0, 0
			for i = 0, 63 do
				for j = 0, 63 do
					local ax, ay = 0.5 + i * ULP_HALF, 0.5 + j * ULP_HALF
					local expected = sign(j - i)
					if CDT.Orient2D(ax, ay, 12, 12, 24, 24) ~= expected then
						wrong += 1
					end
					if naiveOrient(ax, ay, 12, 12, 24, 24) ~= expected then
						naiveWrong += 1
					end
				end
			end
			expect(wrong).is(0)
			-- Negative control: plain f64 gets this grid wrong, so the test has teeth.
			expect(naiveWrong > 0).is_true()
		end)

		test("translation invariance at a 2^40 offset (incl. exactly collinear)", function()
			local rng = makeRng(7)
			local wrong, naiveWrong = 0, 0
			for trial = 1, 3000 do
				local ax, ay, bx, by = rng(-50, 50), rng(-50, 50), rng(-50, 50), rng(-50, 50)
				local cx, cy
				if trial % 3 == 0 then
					-- exactly collinear: c = a + k (b - a)
					local k = rng(-3, 3)
					cx, cy = ax + k * (bx - ax), ay + k * (by - ay)
				else
					cx, cy = rng(-50, 50), rng(-50, 50)
				end
				local expected = naiveOrient(ax, ay, bx, by, cx, cy) -- exact for small integers
				local o = OFFSET
				if CDT.Orient2D(ax + o, ay + o, bx + o, by + o, cx + o, cy + o) ~= expected then
					wrong += 1
				end
			end
			expect(wrong).is(0)
		end)
	end)

	describe("InCircle", function()
		test("inside, outside and on the circle of a CCW triangle", function()
			-- unit-ish circle through (1,0), (0,1), (-1,0)
			expect(CDT.InCircle(1, 0, 0, 1, -1, 0, 0, 0)).is(1)
			expect(CDT.InCircle(1, 0, 0, 1, -1, 0, 3, 3)).is(-1)
			expect(CDT.InCircle(1, 0, 0, 1, -1, 0, 0, -1)).is(0)
			-- clockwise triangle flips the sign
			expect(CDT.InCircle(-1, 0, 0, 1, 1, 0, 0, 0)).is(-1)
		end)

		test("translation invariance at a 2^40 offset (incl. exactly cocircular)", function()
			-- Integer points on the circle of radius 5 around the origin.
			local circle = { { 5, 0 }, { 4, 3 }, { 3, 4 }, { 0, 5 }, { -3, 4 }, { -4, 3 }, { -5, 0 }, { -4, -3 }, { 0, -5 }, { 3, -4 } }
			local rng = makeRng(11)
			local wrong, zeros, naiveWrong = 0, 0, 0
			for trial = 1, 1500 do
				local pts = {}
				if trial % 2 == 0 then
					-- four distinct points of the same circle (CCW order by index): exactly cocircular
					local i1 = rng(1, 7)
					pts = { circle[i1], circle[i1 + 1], circle[i1 + 2], circle[(i1 + 4) % #circle + 1] }
				else
					for k = 1, 4 do
						pts[k] = { rng(-30, 30), rng(-30, 30) }
					end
				end
				local a, b, c, d = pts[1], pts[2], pts[3], pts[4]
				local expected = naiveInCircle(a[1], a[2], b[1], b[2], c[1], c[2], d[1], d[2])
				if expected == 0 then
					zeros += 1
				end
				local o = OFFSET
				local actual = CDT.InCircle(a[1] + o, a[2] + o, b[1] + o, b[2] + o, c[1] + o, c[2] + o, d[1] + o, d[2] + o)
				if actual ~= expected then
					wrong += 1
				end
			end
			expect(wrong).is(0)
			expect(zeros > 100).is_true()
		end)

		-- Points a hair (2^-60) off the unit circle: the filter can't decide, and the input
		-- differences (1 - 2^-60, ...) are not representable, so the exact path must carry them.
		test("near-cocircular points with inexact differences", function()
			local tiny = 2 ^ -60
			-- distance^2 = 1 + 2^-120 > 1: outside
			expect(CDT.InCircle(1, 0, 0, 1, -1, 0, tiny, -1)).is(-1)
			-- (-1 + 2^-60 would round to -1; 2^-50 is representable next to 1.)
			-- distance^2 = 2^-120 + (1 - 2^-50)^2 < 1: inside
			expect(CDT.InCircle(1, 0, 0, 1, -1, 0, tiny, -1 + 2 ^ -50)).is(1)
			-- orientation of a point 2^-60 above the x-axis segment
			expect(CDT.Orient2D(-1, 0, 1, 0, tiny, tiny)).is(1)
			expect(CDT.Orient2D(-1, 0, 1, 0, tiny, -tiny)).is(-1)
		end)

		-- Integer points on a circle of radius 5K (Pythagorean 3-4-5 scaled): lifts and products
		-- exceed 2^53, so plain f64 loses the cancellation. Exact signs are known analytically:
		-- on the circle -> 0, one unit inside -> 1, one unit outside -> -1.
		test("large exactly-cocircular circles give exact signs", function()
			local wrong, naiveWrong = 0, 0
			for step = 0, 200 do
				local k = 2 ^ 21 + 1 + step * 7919
				local ax, ay, bx, by, cx, cy = 5 * k, 0, 4 * k, 3 * k, 0, 5 * k -- CCW on the circle
				local cases = {
					{ -3 * k, 4 * k, 0 },
					{ -3 * k + 1, 4 * k, 1 },
					{ -3 * k - 1, 4 * k, -1 },
				}
				for _, case in cases do
					if CDT.InCircle(ax, ay, bx, by, cx, cy, case[1], case[2]) ~= case[3] then
						wrong += 1
					end
					if naiveInCircle(ax, ay, bx, by, cx, cy, case[1], case[2]) ~= case[3] then
						naiveWrong += 1
					end
				end
			end
			expect(wrong).is(0)
			-- Negative control: plain f64 gets some of these wrong, so the test has teeth.
			expect(naiveWrong > 0).is_true()
		end)

		-- Nudge d by a tiny but representable delta (2^-20..2^-28; the ulp of 3K ~ 2^22.6 is
		-- ~2^-30), so the lifts carry long fractional tails and the exact path must run
		-- multi-term expansions (products, scale, grow). The sign is known analytically:
		-- distance^2 = (3K - delta)^2 + (4K)^2 = 25K^2 - 6K delta + delta^2: inside for +delta.
		test("tiny nudges off a large circle force deep exact expansions", function()
			local wrong = 0
			for step = 0, 40 do
				local k = 2 ^ 21 + 3 + step * 104729
				for e = 20, 28, 2 do
					local delta = 2 ^ -e
					if CDT.InCircle(5 * k, 0, 4 * k, 3 * k, 0, 5 * k, -3 * k + delta, 4 * k) ~= 1 then
						wrong += 1
					end
					if CDT.InCircle(5 * k, 0, 4 * k, 3 * k, 0, 5 * k, -3 * k - delta, 4 * k) ~= -1 then
						wrong += 1
					end
					-- Orientation of a point nudged off the line through (0,0) and (4K, 3K). Near 6K
					-- a 2^-28 nudge may round away entirely, so the expected sign is that of the
					-- nudge that actually survived rounding (0 = exactly collinear).
					local up, down = 6 * k + delta, 6 * k - delta
					if CDT.Orient2D(0, 0, 4 * k, 3 * k, 8 * k, up) ~= sign(up - 6 * k) then
						wrong += 1
					end
					if CDT.Orient2D(0, 0, 4 * k, 3 * k, 8 * k, down) ~= sign(down - 6 * k) then
						wrong += 1
					end
				end
			end
			expect(wrong).is(0)
		end)
	end)
end
