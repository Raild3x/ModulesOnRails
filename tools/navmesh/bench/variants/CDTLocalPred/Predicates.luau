--!strict
--!native
-- Authors: Logan Hunt (Raildex)
-- September 25, 2026
--[=[
	@class Predicates
	@private

	Exact geometric predicates on f64 inputs (Shewchuk, "Adaptive Precision Floating-Point
	Arithmetic and Fast Robust Geometric Predicates", 1997).

	Each predicate first evaluates the determinant in plain f64 and accepts the sign when it
	clears Shewchuk's error bound (the common, fast path). Otherwise it re-evaluates exactly
	with floating-point expansions (sums of non-overlapping doubles), so the returned sign is
	always correct. Luau has no fused multiply-add, which the Veltkamp split relies on.

	Written as `if ... return` sequences rather than `elseif` chains so mutation testing
	covers every branch (see verification.md F2 finding).
]=]

local Predicates = {}

local EPSILON = 2 ^ -53 -- half an ulp of 1
local SPLITTER = 2 ^ 27 + 1 -- Veltkamp splitter for 53-bit mantissas
-- Shewchuk's first-stage error bounds for orient2d and incircle.
local CCW_ERRBOUND_A = (3 + 16 * EPSILON) * EPSILON
local ICC_ERRBOUND_A = (10 + 96 * EPSILON) * EPSILON

type Expansion = { number }

-- a + b = x + y exactly.
local function twoSum(a: number, b: number): (number, number)
	local x = a + b
	local bVirtual = x - a
	local aVirtual = x - bVirtual
	return x, (a - aVirtual) + (b - bVirtual)
end

-- a + b = x + y exactly, given |a| >= |b|.
local function fastTwoSum(a: number, b: number): (number, number)
	local x = a + b
	return x, b - (x - a)
end

local function split(a: number): (number, number)
	local c = SPLITTER * a
	local high = c - (c - a)
	return high, a - high
end

-- a * b = x + y exactly.
local function twoProduct(a: number, b: number): (number, number)
	local x = a * b
	local aHigh, aLow = split(a)
	local bHigh, bLow = split(b)
	local err = x - aHigh * bHigh
	err -= aLow * bHigh
	err -= aHigh * bLow
	return x, aLow * bLow - err
end

-- Adds one double to an expansion (Shewchuk grow-expansion, zeros eliminated).
local function grow(e: Expansion, b: number): Expansion
	local h: Expansion = table.create(#e + 1)
	local q = b
	for _, component in e do
		local low
		q, low = twoSum(q, component)
		if low ~= 0 then
			table.insert(h, low)
		end
	end
	if q ~= 0 or #h == 0 then
		table.insert(h, q)
	end
	return h
end

local function add(e: Expansion, f: Expansion): Expansion
	local h = e
	for _, component in f do
		h = grow(h, component)
	end
	return h
end

local function negate(e: Expansion): Expansion
	local h: Expansion = table.create(#e)
	for i, component in e do
		h[i] = -component
	end
	return h
end

-- Multiplies an expansion by one double (Shewchuk scale-expansion, zeros eliminated).
local function scale(e: Expansion, b: number): Expansion
	local h: Expansion = table.create(2 * #e)
	local q, low = twoProduct(e[1], b)
	if low ~= 0 then
		table.insert(h, low)
	end
	for i = 2, #e do
		local productHigh, productLow = twoProduct(e[i], b)
		local sum
		sum, low = twoSum(q, productLow)
		if low ~= 0 then
			table.insert(h, low)
		end
		q, low = fastTwoSum(productHigh, sum)
		if low ~= 0 then
			table.insert(h, low)
		end
	end
	if q ~= 0 or #h == 0 then
		table.insert(h, q)
	end
	return h
end

local function multiply(e: Expansion, f: Expansion): Expansion
	local h = scale(e, f[1])
	for j = 2, #f do
		h = add(h, scale(e, f[j]))
	end
	return h
end

-- a - b exactly, as an expansion.
local function difference(a: number, b: number): Expansion
	local x, y = twoSum(a, -b)
	if y == 0 then
		return { x }
	end
	return { y, x }
end

-- Sign of an expansion: its largest-magnitude (last) component decides.
local function signOf(e: Expansion): number
	local top = e[#e]
	if top > 0 then
		return 1
	end
	if top < 0 then
		return -1
	end
	return 0
end

local function orient2DExact(ax: number, ay: number, bx: number, by: number, cx: number, cy: number): number
	-- (bx-ax)(cy-ay) - (by-ay)(cx-ax) expanded into six exact products of the inputs.
	local e: Expansion = { 0 }
	local function addProduct(p: number, q: number, sign: number)
		local high, low = twoProduct(p, q)
		e = grow(e, sign * low)
		e = grow(e, sign * high)
	end
	addProduct(bx, cy, 1)
	addProduct(bx, ay, -1)
	addProduct(ax, cy, -1)
	addProduct(by, cx, -1)
	addProduct(ax, by, 1)
	addProduct(ay, cx, 1)
	return signOf(e)
end

--[=[
	@within ConstrainedDelaunay

	Exact orientation of the triangle (a, b, c): `1` when counter-clockwise, `-1` when
	clockwise, `0` when exactly collinear. Correct for every finite f64 input.
]=]
function Predicates.Orient2D(ax: number, ay: number, bx: number, by: number, cx: number, cy: number): number
	local detLeft = (ax - cx) * (by - cy)
	local detRight = (ay - cy) * (bx - cx)
	local det = detLeft - detRight
	local errBound = CCW_ERRBOUND_A * (math.abs(detLeft) + math.abs(detRight))
	if det > errBound then
		return 1
	end
	if -det > errBound then
		return -1
	end
	return orient2DExact(ax, ay, bx, by, cx, cy)
end

local function inCircleExact(
	ax: number,
	ay: number,
	bx: number,
	by: number,
	cx: number,
	cy: number,
	dx: number,
	dy: number
): number
	local adx, ady = difference(ax, dx), difference(ay, dy)
	local bdx, bdy = difference(bx, dx), difference(by, dy)
	local cdx, cdy = difference(cx, dx), difference(cy, dy)

	local aLift = add(multiply(adx, adx), multiply(ady, ady))
	local bLift = add(multiply(bdx, bdx), multiply(bdy, bdy))
	local cLift = add(multiply(cdx, cdx), multiply(cdy, cdy))

	local bcDet = add(multiply(bdx, cdy), negate(multiply(cdx, bdy)))
	local caDet = add(multiply(cdx, ady), negate(multiply(adx, cdy)))
	local abDet = add(multiply(adx, bdy), negate(multiply(bdx, ady)))

	local det = add(add(multiply(aLift, bcDet), multiply(bLift, caDet)), multiply(cLift, abDet))
	return signOf(det)
end

--[=[
	@within ConstrainedDelaunay

	Exact incircle test for a counter-clockwise triangle (a, b, c): `1` when d lies strictly
	inside its circumcircle, `-1` when strictly outside, `0` when exactly on it. (The sign
	flips if a, b, c are clockwise.) Correct for every finite f64 input.
]=]
function Predicates.InCircle(
	ax: number,
	ay: number,
	bx: number,
	by: number,
	cx: number,
	cy: number,
	dx: number,
	dy: number
): number
	local adx, ady = ax - dx, ay - dy
	local bdx, bdy = bx - dx, by - dy
	local cdx, cdy = cx - dx, cy - dy

	local bdxcdy, cdxbdy = bdx * cdy, cdx * bdy
	local cdxady, adxcdy = cdx * ady, adx * cdy
	local adxbdy, bdxady = adx * bdy, bdx * ady
	local aLift = adx * adx + ady * ady
	local bLift = bdx * bdx + bdy * bdy
	local cLift = cdx * cdx + cdy * cdy

	local det = aLift * (bdxcdy - cdxbdy) + bLift * (cdxady - adxcdy) + cLift * (adxbdy - bdxady)
	local permanent = (math.abs(bdxcdy) + math.abs(cdxbdy)) * aLift
		+ (math.abs(cdxady) + math.abs(adxcdy)) * bLift
		+ (math.abs(adxbdy) + math.abs(bdxady)) * cLift
	local errBound = ICC_ERRBOUND_A * permanent
	if det > errBound then
		return 1
	end
	if -det > errBound then
		return -1
	end
	return inCircleExact(ax, ay, bx, by, cx, cy, dx, dy)
end

return Predicates
