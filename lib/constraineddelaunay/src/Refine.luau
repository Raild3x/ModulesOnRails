--!strict
--!native
-- Authors: Logan Hunt (Raildex)
-- September 27, 2026
--[=[
	@class Refine
	@private

	Quality refinement (Ruppert): Steiner vertices are added until every triangle meets
	`MinAngle` and `MaxArea`, or the `MaxSteiner` budget runs out.

	**Segments** are constrained edges and hull edges (SR8), so circumcentres never leave the
	domain. A segment is *encroached* when a vertex lies strictly inside its diametral circle.
	Encroached segments are split at their midpoint first. Then each bad triangle gets its
	circumcentre, unless reaching it would cross a segment, or it would encroach one. In that
	case those segments are split instead.

	**Midpoints only:** a midpoint between dyadic coordinates is exact in f64, so a split hull
	edge stays exactly straight (the hull remains convex). Ruppert's off-centre "concentric
	shell" splits are not used, which is safe because the budget always halts.

	**Unsplittable segments:** a split must be exact. A hull edge's midpoint must be exactly on
	it, and every new triangle must be strictly counter-clockwise (exact `Orient2D`). A segment
	failing that is left alone: in practice these are segments of about 1e-12 studs, next to
	Steiner vertices from nearly coincident constraint crossings. Refine then reports false,
	because the bounds could not all be met.

	**Termination (P6):** guaranteed only for `MinAngle` up to about 20.7 degrees and no input
	angle below 60 degrees. A triangle whose smallest angle lies between two segments (an input
	angle) is skipped, and `MaxSteiner` bounds the work either way.

	**Winding** is kept without the original input. Refinement only splits triangles and flips
	unconstrained edges, so a triangle never leaves its region between constraints, and a
	region's winding is the same everywhere. New triangles copy it across unconstrained edges.
]=]

local Predicates = require("./Predicates")
local Storage = require("./Storage")
local Triangulator = require("./Triangulator")

type State = Storage.State

export type RefineOptions = {
	MinAngle: number?,
	MaxArea: number?,
	MaxSteiner: number?,
}

local Orient2D = Predicates.Orient2D
local InCircle = Predicates.InCircle
local GetTriangle, GetNeighbor, GetVertex = Storage.GetTriangle, Storage.GetNeighbor, Storage.GetVertex

local DEFAULT_MIN_STEINER = 1024
local WALK_LIMIT_FACTOR = 4

local Refine = {}

local function isSegment(s: State, t: number, e: number): boolean
	return GetNeighbor(s, t, e) == 0 or Storage.GetCoverHead(s, t, e) ~= 0
end

local function vertexAt(s: State, t: number, i: number): number
	local a, b, c = GetTriangle(s, t)
	return if i == 1 then a elseif i == 2 then b else c
end

-- Whether (px, py) lies strictly inside the diametral circle of edge e of t.
local function encroaches(s: State, t: number, e: number, px: number, py: number): boolean
	local ux, uy = GetVertex(s, vertexAt(s, t, e % 3 + 1))
	local vx, vy = GetVertex(s, vertexAt(s, t, (e + 1) % 3 + 1))
	return (ux - px) * (vx - px) + (uy - py) * (vy - py) < 0
end

-- Key of the edge between vertices a and b (either order).
local function edgeKey(a: number, b: number): number
	return if a < b then a * 2 ^ 26 + b else b * 2 ^ 26 + a
end

-- Splits segment e of t at its midpoint when that split is exact (see the class docs), and
-- returns whether it did.
local function splitAtMidpoint(s: State, t: number, e: number): boolean
	local c = vertexAt(s, t, e)
	local ux, uy = GetVertex(s, vertexAt(s, t, e % 3 + 1))
	local vx, vy = GetVertex(s, vertexAt(s, t, (e + 1) % 3 + 1))
	local cx, cy = GetVertex(s, c)
	local mx, my = (ux + vx) * 0.5, (uy + vy) * 0.5
	-- t = (c, u, v) becomes (m, v, c) and (u, m, c); across it, n = (d, v, u) becomes (m, u, d) and (v, m, d).
	local exact = Orient2D(mx, my, vx, vy, cx, cy) > 0 and Orient2D(ux, uy, mx, my, cx, cy) > 0
	local n = GetNeighbor(s, t, e)
	if n == 0 then
		exact = exact and Orient2D(ux, uy, vx, vy, mx, my) == 0
	else
		local a, b, c2 = GetTriangle(s, n)
		local d = if a ~= vertexAt(s, t, e % 3 + 1) and a ~= vertexAt(s, t, (e + 1) % 3 + 1)
			then a
			elseif b ~= vertexAt(s, t, e % 3 + 1) and b ~= vertexAt(s, t, (e + 1) % 3 + 1) then b
			else c2
		local dx, dy = GetVertex(s, d)
		exact = exact and Orient2D(mx, my, ux, uy, dx, dy) > 0 and Orient2D(vx, vy, mx, my, dx, dy) > 0
	end
	if not exact then
		return false
	end
	Triangulator.SplitSegment(s, t, e, mx, my)
	return true
end

-- The first encroached segment found that is not `stuck` (unsplittable), as (triangle, slot),
-- or 0, 0.
local function findEncroached(s: State, stuck: { [number]: boolean }): (number, number)
	for t = 1, Storage.TriangleCount(s) do
		for e = 1, 3 do
			if isSegment(s, t, e) and not stuck[edgeKey(vertexAt(s, t, e % 3 + 1), vertexAt(s, t, (e + 1) % 3 + 1))] then
				local ax, ay = GetVertex(s, vertexAt(s, t, e))
				if encroaches(s, t, e, ax, ay) then
					return t, e
				end
			end
		end
	end
	return 0, 0
end

-- Why triangle t needs work: its circumcentre, or nil when it meets the bounds or is skipped.
local function badCircumcentre(s: State, t: number, cosLimit: number, maxArea: number): (number?, number?)
	local a, b, c = GetTriangle(s, t)
	local ax, ay = GetVertex(s, a)
	local bx, by = GetVertex(s, b)
	local cx, cy = GetVertex(s, c)
	local bdx, bdy, cdx, cdy = bx - ax, by - ay, cx - ax, cy - ay
	local cross = bdx * cdy - bdy * cdx
	local bad = cross * 0.5 > maxArea
	if not bad then
		-- The smallest angle is opposite the shortest edge (edge i is opposite vertex i).
		local l1 = (cx - bx) ^ 2 + (cy - by) ^ 2
		local l2 = cdx * cdx + cdy * cdy
		local l3 = bdx * bdx + bdy * bdy
		local i, short, o1, o2 = 1, l1, l2, l3
		if l2 < short then
			i, short, o1, o2 = 2, l2, l3, l1
		end
		if l3 < short then
			i, short, o1, o2 = 3, l3, l1, l2
		end
		local cosine = (o1 + o2 - short) / (2 * math.sqrt(o1 * o2))
		if cosine <= cosLimit then
			return nil, nil
		end
		-- An input angle: both edges at the small angle's vertex are segments (P6).
		if isSegment(s, t, i % 3 + 1) and isSegment(s, t, (i + 1) % 3 + 1) then
			return nil, nil
		end
	end
	local b2, c2 = bdx * bdx + bdy * bdy, cdx * cdx + cdy * cdy
	local d = 2 * cross
	return ax + (cdy * b2 - bdy * c2) / d, ay + (bdx * c2 - cdx * b2) / d
end

-- Walks the straight line from t's centroid to (x, y). Returns (triangle containing it, 0) or
-- (triangle, slot) of the first segment in the way.
local function walkTo(s: State, t: number, x: number, y: number): (number, number)
	local a, b, c = GetTriangle(s, t)
	local ax, ay = GetVertex(s, a)
	local bx, by = GetVertex(s, b)
	local cx, cy = GetVertex(s, c)
	local gx, gy = (ax + bx + cx) / 3, (ay + by + cy) / 3
	for _ = 1, WALK_LIMIT_FACTOR * Storage.TriangleCount(s) + 16 do
		local exit = 0
		for e = 1, 3 do
			local ux, uy = GetVertex(s, vertexAt(s, t, e % 3 + 1))
			local vx, vy = GetVertex(s, vertexAt(s, t, (e + 1) % 3 + 1))
			if Orient2D(ux, uy, vx, vy, x, y) < 0 then
				-- Beyond this edge: leave through it if the line from the centroid crosses it.
				local su, sv = Orient2D(gx, gy, x, y, ux, uy), Orient2D(gx, gy, x, y, vx, vy)
				if exit == 0 or su * sv <= 0 then
					exit = e
				end
				if su * sv <= 0 then
					break
				end
			end
		end
		if exit == 0 then
			return t, 0
		end
		if isSegment(s, t, exit) then
			return t, exit
		end
		t = GetNeighbor(s, t, exit)
	end
	error("Refine: the walk to a circumcentre did not terminate", 3)
end

-- Segments (triangle, slot pairs) that a new vertex at (x, y) in triangle `start` would
-- encroach: the segment edges of every triangle whose circumcircle holds it (its cavity).
local function cavitySegments(s: State, start: number, x: number, y: number): { number }
	local found: { number } = {}
	local seen = { [start] = true }
	local queue = { start }
	local head = 1
	while head <= #queue do
		local t = queue[head]
		head += 1
		for e = 1, 3 do
			if isSegment(s, t, e) then
				if encroaches(s, t, e, x, y) then
					table.insert(found, t)
					table.insert(found, e)
				end
				continue
			end
			local n = GetNeighbor(s, t, e)
			if seen[n] then
				continue
			end
			local a, b, c = GetTriangle(s, n)
			local ax, ay = GetVertex(s, a)
			local bx, by = GetVertex(s, b)
			local cx, cy = GetVertex(s, c)
			if InCircle(ax, ay, bx, by, cx, cy, x, y) > 0 then
				seen[n] = true
				table.insert(queue, n)
			end
		end
	end
	return found
end

-- Recomputes winding after refinement: triangles 1..oldCount keep theirs (see the class docs),
-- and every newer triangle copies a neighbour's across an unconstrained edge.
local function repairWinding(s: State, oldCount: number)
	local groups = Storage.GroupCount(s)
	local count = Storage.TriangleCount(s)
	local kept = table.create(oldCount * (groups + 1), 0)
	for t = 1, oldCount do
		for g = 0, groups do
			kept[(t - 1) * (groups + 1) + g + 1] = Storage.GetWinding(s, t, g)
		end
	end
	Storage.AllocWinding(s)
	local known = table.create(count, false)
	local queue = {}
	for t = 1, oldCount do
		for g = 0, groups do
			Storage.SetWinding(s, t, g, kept[(t - 1) * (groups + 1) + g + 1])
		end
		known[t] = true
		table.insert(queue, t)
	end
	local head = 1
	while head <= #queue do
		local t = queue[head]
		head += 1
		for e = 1, 3 do
			local n = GetNeighbor(s, t, e)
			if n ~= 0 and not known[n] and Storage.GetCoverHead(s, t, e) == 0 then
				known[n] = true
				for g = 0, groups do
					Storage.SetWinding(s, n, g, Storage.GetWinding(s, t, g))
				end
				table.insert(queue, n)
			end
		end
	end
end

--[=[
	@within Refine
	Refines in place. Returns false when `MaxSteiner` vertices were added before the bounds
	were met.
]=]
function Refine.Refine(s: State, options: RefineOptions): boolean
	local minAngle = options.MinAngle or 0
	local maxArea = options.MaxArea or math.huge
	local budget = options.MaxSteiner or math.max(DEFAULT_MIN_STEINER, 4 * Storage.InputCount(s))
	assert(
		type(minAngle) == "number" and minAngle >= 0 and minAngle < 60,
		"Refine: MinAngle must be from 0 to below 60 degrees"
	)
	assert(type(maxArea) == "number" and maxArea > 0, "Refine: MaxArea must be a number above 0")
	assert(
		type(budget) == "number" and budget >= 0 and budget % 1 == 0,
		"Refine: MaxSteiner must be a whole number >= 0"
	)
	local cosLimit = math.cos(math.rad(minAngle))
	local oldCount = Storage.TriangleCount(s)
	if oldCount == 0 then
		return true
	end

	local added = 0
	local done = false
	local stuck: { [number]: boolean } = {}
	-- Splits segment e of t unless it is stuck; returns whether a vertex was added.
	local function split(t: number, e: number): boolean
		local key = edgeKey(vertexAt(s, t, e % 3 + 1), vertexAt(s, t, (e + 1) % 3 + 1))
		if stuck[key] then
			return false
		end
		if splitAtMidpoint(s, t, e) then
			added += 1
			return true
		end
		stuck[key] = true
		return false
	end
	while not done and added < budget do
		done = true
		-- 1. Split encroached segments until none remain.
		while added < budget do
			local t, e = findEncroached(s, stuck)
			if t == 0 then
				break
			end
			if split(t, e) then
				done = false
			end
		end
		-- 2. One pass over the triangles (each re-read as it stands now).
		-- ponytail: full rescans per pass, about O(n) passes x O(n); a work queue if refinement gets hot.
		local t = 1
		while t <= Storage.TriangleCount(s) and added < budget do
			local x, y = badCircumcentre(s, t, cosLimit, maxArea)
			if x == nil or y == nil then
				t += 1
				continue
			end
			local at, blocked = walkTo(s, t, x, y)
			if blocked ~= 0 then
				if split(at, blocked) then
					done = false
				else
					t += 1 -- behind an unsplittable segment: leave this triangle
				end
				continue
			end
			local encroached = cavitySegments(s, at, x, y)
			if #encroached > 0 then
				local didSplit = false
				for k = 1, #encroached, 2 do
					if added >= budget then
						break
					end
					-- An earlier split in this loop may have renumbered the edge: re-check it.
					local et, ee = encroached[k], encroached[k + 1]
					if isSegment(s, et, ee) and encroaches(s, et, ee, x, y) and split(et, ee) then
						didSplit = true
					end
				end
				if didSplit then
					done = false
				else
					t += 1
				end
				continue
			end
			local _, fresh = Triangulator.InsertAt(s, x, y, at)
			if fresh then
				added += 1
				done = false
			else
				t += 1 -- the circumcentre is an existing vertex: nothing to gain here
			end
		end
	end
	if not done then
		-- The budget ran out: report success anyway if the last vertex finished the job.
		done = findEncroached(s, stuck) == 0
		for t = 1, Storage.TriangleCount(s) do
			if not done then
				break
			end
			done = badCircumcentre(s, t, cosLimit, maxArea) == nil
		end
	end
	repairWinding(s, oldCount)
	return done and next(stuck) == nil
end

return Refine
