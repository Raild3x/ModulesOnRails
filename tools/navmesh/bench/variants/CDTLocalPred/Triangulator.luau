--!strict
--!native
-- Authors: Logan Hunt (Raildex)
-- September 25, 2026
--[=[
	@class Triangulator
	@private

	Incremental Delaunay insertion (Q5): points are inserted in Morton (Z-order) order into a
	large bounding triangle, located by a visibility walk with exact `Orient2D`, then either
	merged (exact duplicate), split 2->4 (exactly on an edge) or split 1->3, followed by Lawson
	flips decided by exact `InCircle`. Finally the bounding triangle's vertices and every
	triangle touching them are removed, leaving the triangulation of the convex hull.

	Triangles are CCW (a, b, c); slot i (1..3) is the edge opposite vertex i. Constraint
	coverage heads travel with their edges through every split and flip (used from ticket 08).
	All reads and writes go through Storage (S1).
]=]

local Predicates = require("./Predicates")
local Storage = require("./Storage")
local Classify = require("./Classify")
local Types = require("./Types")

type State = Storage.State

-- A/B prototype: the predicates' floating-point filters as local functions; only an
-- inconclusive filter calls the exact module function.
local CCW_ERRBOUND_A = (3 + 16 * 2 ^ -53) * 2 ^ -53
local ICC_ERRBOUND_A = (10 + 96 * 2 ^ -53) * 2 ^ -53
local ExactOrient2D, ExactInCircle = Predicates.Orient2D, Predicates.InCircle
local function Orient2D(ax: number, ay: number, bx: number, by: number, cx: number, cy: number): number
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
	return ExactOrient2D(ax, ay, bx, by, cx, cy)
end
local function InCircle(ax: number, ay: number, bx: number, by: number, cx: number, cy: number, dx: number, dy: number): number
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
	return ExactInCircle(ax, ay, bx, by, cx, cy, dx, dy)
end
-- A/B prototype: the Storage accessors copied here as local functions (same layout as
-- Storage.luau), so the compiler can inline them.
local function GetTriangle(s: State, t: number): (number, number, number)
	local o = (t - 1) * 12
	local b = s.TriVerts
	return buffer.readi32(b, o), buffer.readi32(b, o + 4), buffer.readi32(b, o + 8)
end
local function SetTriangle(s: State, t: number, a: number, b: number, c: number)
	local o = (t - 1) * 12
	local buf = s.TriVerts
	buffer.writei32(buf, o, a)
	buffer.writei32(buf, o + 4, b)
	buffer.writei32(buf, o + 8, c)
end
local function GetNeighbor(s: State, t: number, e: number): number
	return buffer.readi32(s.TriNeighbors, ((t - 1) * 3 + e - 1) * 4)
end
local function SetNeighbor(s: State, t: number, e: number, n: number)
	buffer.writei32(s.TriNeighbors, ((t - 1) * 3 + e - 1) * 4, n)
end
local function GetCoverHead(s: State, t: number, e: number): number
	return buffer.readi32(s.CoverHeads, ((t - 1) * 3 + e - 1) * 4)
end
local function SetCoverHead(s: State, t: number, e: number, head: number)
	buffer.writei32(s.CoverHeads, ((t - 1) * 3 + e - 1) * 4, head)
end
local function GetVertex(s: State, v: number): (number, number)
	local o = (v - 1) * 16
	return buffer.readf64(s.Coords, o), buffer.readf64(s.Coords, o + 8)
end
local function GetWinding(s: State, t: number, group: number): number
	return buffer.readi32(s.Winding, ((t - 1) * (s.GroupCount + 1) + group) * 4)
end
local function SetWinding(s: State, t: number, group: number, value: number)
	buffer.writei32(s.Winding, ((t - 1) * (s.GroupCount + 1) + group) * 4, value)
end

local SUPER_VERTICES = 3
-- Bounding-triangle size relative to the input extent. Large enough that hull points are
-- practically never shadowed by a bounding vertex (checked by the hull invariant).
local SUPER_SCALE = 2 ^ 24
local MORTON_BITS = 16
local WALK_LIMIT_FACTOR = 4 -- walk-step cap as a multiple of the triangle count

local Triangulator = {}

local function vertexAt(s: State, t: number, i: number): number
	local a, b, c = GetTriangle(s, t)
	if i == 1 then
		return a
	end
	if i == 2 then
		return b
	end
	return c
end

-- Slot of triangle t whose neighbour is n.
local function slotOf(s: State, t: number, n: number): number
	if GetNeighbor(s, t, 1) == n then
		return 1
	end
	if GetNeighbor(s, t, 2) == n then
		return 2
	end
	assert(GetNeighbor(s, t, 3) == n, "Triangulator: neighbour back-link missing")
	return 3
end

local function relink(s: State, n: number, from: number, to: number)
	if n ~= 0 then
		SetNeighbor(s, n, slotOf(s, n, from), to)
	end
end

-- Some triangle containing each vertex, maintained by `write` during a build (edge lookups
-- rotate around a vertex from here). Builds are synchronous, so one table is reused.
local VertexTriangle: { number } = {}

-- Writes a triangle's vertices, neighbours and cover heads in slot order.
local function write(s: State, t: number, a: number, b: number, c: number, n1: number, n2: number, n3: number, c1: number, c2: number, c3: number)
	VertexTriangle[a], VertexTriangle[b], VertexTriangle[c] = t, t, t
	SetTriangle(s, t, a, b, c)
	SetNeighbor(s, t, 1, n1)
	SetNeighbor(s, t, 2, n2)
	SetNeighbor(s, t, 3, n3)
	SetCoverHead(s, t, 1, c1)
	SetCoverHead(s, t, 2, c2)
	SetCoverHead(s, t, 3, c3)
end

--[=[
	@within Triangulator
	Flips the edge opposite vertex slot `i` of triangle `t` (which must be unconstrained).
	Returns the two new triangles' slots opposite the vertex that was at `i`.
]=]
function Triangulator.Flip(s: State, t: number, i: number): (number, number, number, number)
	local p = vertexAt(s, t, i)
	local ia, ib = i % 3 + 1, (i + 1) % 3 + 1
	local a, b = vertexAt(s, t, ia), vertexAt(s, t, ib)
	local n = GetNeighbor(s, t, i)
	local j = slotOf(s, n, t)
	local q = vertexAt(s, n, j)
	local jb, ja = j % 3 + 1, (j + 1) % 3 + 1 -- in n, after q come b then a
	local tA, tB = GetNeighbor(s, t, ib), GetNeighbor(s, t, ia) -- across (p,a) and (b,p)
	local nA, nB = GetNeighbor(s, n, jb), GetNeighbor(s, n, ja) -- across (a,q) and (q,b)
	local ctA, ctB = GetCoverHead(s, t, ib), GetCoverHead(s, t, ia)
	local cnA, cnB = GetCoverHead(s, n, jb), GetCoverHead(s, n, ja)
	write(s, t, p, a, q, nA, n, tA, cnA, 0, ctA)
	write(s, n, q, b, p, tB, t, nB, ctB, 0, cnB)
	relink(s, nA, n, t)
	relink(s, tB, t, n)
	return t, 1, n, 3
end

-- Lawson flips until every stacked edge (triangle, slot) is locally Delaunay.
-- After inserting a point only the two edges opposite it need re-checking after a flip;
-- `allSides` re-checks all four outer edges of the flipped quad, which general edge
-- restoration (after constraint recovery) requires.
local function legalize(s: State, stack: { number }, allSides: boolean?)
	while #stack > 0 do
		local slot = table.remove(stack) :: number
		local t = table.remove(stack) :: number
		local n = GetNeighbor(s, t, slot)
		if n == 0 or GetCoverHead(s, t, slot) ~= 0 then
			continue
		end
		local a, b, c = GetTriangle(s, t)
		local q = vertexAt(s, n, slotOf(s, n, t))
		local ax, ay = GetVertex(s, a)
		local bx, by = GetVertex(s, b)
		local cx, cy = GetVertex(s, c)
		local qx, qy = GetVertex(s, q)
		if InCircle(ax, ay, bx, by, cx, cy, qx, qy) > 0 then
			local t1, s1, t2, s2 = Triangulator.Flip(s, t, slot)
			table.insert(stack, t1)
			table.insert(stack, s1)
			table.insert(stack, t2)
			table.insert(stack, s2)
			if allSides then
				-- The flipped quad's other two outer edges: t1 slot 3 and t2 slot 1.
				table.insert(stack, t1)
				table.insert(stack, 3)
				table.insert(stack, t2)
				table.insert(stack, 1)
			end
		end
	end
end

-- Splits triangle t into three around new vertex p; returns the three triangles.
local function splitTriangle(s: State, t: number, p: number, stack: { number })
	local a, b, c = GetTriangle(s, t)
	local n1, n2, n3 = GetNeighbor(s, t, 1), GetNeighbor(s, t, 2), GetNeighbor(s, t, 3)
	local c1, c2, c3 = GetCoverHead(s, t, 1), GetCoverHead(s, t, 2), GetCoverHead(s, t, 3)
	local t2 = Storage.AddTriangle(s, b, c, p)
	local t3 = Storage.AddTriangle(s, c, a, p)
	write(s, t, a, b, p, t2, t3, n3, 0, 0, c3)
	write(s, t2, b, c, p, t3, t, n1, 0, 0, c1)
	write(s, t3, c, a, p, t, t2, n2, 0, 0, c2)
	relink(s, n1, t, t2)
	relink(s, n2, t, t3)
	for _, tri in { t, t2, t3 } do
		table.insert(stack, tri)
		table.insert(stack, 3)
	end
end

-- Splits the edge opposite slot e of t (and its neighbour) at new vertex p.
local function splitEdge(s: State, t: number, e: number, p: number, stack: { number })
	local c = vertexAt(s, t, e)
	local a, b = vertexAt(s, t, e % 3 + 1), vertexAt(s, t, (e + 1) % 3 + 1)
	local tN1, tN2 = GetNeighbor(s, t, e % 3 + 1), GetNeighbor(s, t, (e + 1) % 3 + 1) -- across (b,c), (c,a)
	local tC1, tC2 = GetCoverHead(s, t, e % 3 + 1), GetCoverHead(s, t, (e + 1) % 3 + 1)
	local shared = GetCoverHead(s, t, e) -- coverage of (a,b) applies to both halves
	local n = GetNeighbor(s, t, e)
	assert(n ~= 0, "Triangulator: point on a hull edge of the bounding triangle")
	local j = slotOf(s, n, t)
	local d = vertexAt(s, n, j) -- n = (d, b, a) in rotation: slot j%3+1 holds b, (j+1)%3+1 holds a
	local nN1, nN2 = GetNeighbor(s, n, j % 3 + 1), GetNeighbor(s, n, (j + 1) % 3 + 1) -- across (a,d), (d,b)
	local nC1, nC2 = GetCoverHead(s, n, j % 3 + 1), GetCoverHead(s, n, (j + 1) % 3 + 1)
	local t2 = Storage.AddTriangle(s, a, p, c)
	local n2 = Storage.AddTriangle(s, b, p, d)
	-- t := (p,b,c); t2 := (a,p,c); n := (p,a,d); n2 := (b,p,d)
	write(s, t, p, b, c, tN1, t2, n2, tC1, 0, shared)
	write(s, t2, a, p, c, t, tN2, n, 0, tC2, shared)
	write(s, n, p, a, d, nN1, n2, t2, nC1, 0, shared)
	write(s, n2, b, p, d, n, nN2, t, 0, nC2, shared)
	relink(s, tN2, t, t2)
	relink(s, nN2, n, n2)
	for _, pair in { { t, 1 }, { t2, 2 }, { n, 1 }, { n2, 2 } } do
		table.insert(stack, pair[1])
		table.insert(stack, pair[2])
	end
end

--[=[
	@within Triangulator
	Visibility walk from triangle `t` towards (x, y). Returns the containing triangle and the
	three exact orientations of the point against its edges (slot order), or 0 when the walk
	leaves the triangulation (no neighbour).
]=]
function Triangulator.Walk(s: State, x: number, y: number, t: number): (number, number, number, number)
	local limit = WALK_LIMIT_FACTOR * Storage.TriangleCount(s) + 16
	for _ = 1, limit do
		local a, b, c = GetTriangle(s, t)
		local ax, ay = GetVertex(s, a)
		local bx, by = GetVertex(s, b)
		local cx, cy = GetVertex(s, c)
		local o1 = Orient2D(bx, by, cx, cy, x, y)
		if o1 < 0 then
			t = GetNeighbor(s, t, 1)
			if t == 0 then
				return 0, 0, 0, 0
			end
			continue
		end
		local o2 = Orient2D(cx, cy, ax, ay, x, y)
		if o2 < 0 then
			t = GetNeighbor(s, t, 2)
			if t == 0 then
				return 0, 0, 0, 0
			end
			continue
		end
		local o3 = Orient2D(ax, ay, bx, by, x, y)
		if o3 < 0 then
			t = GetNeighbor(s, t, 3)
			if t == 0 then
				return 0, 0, 0, 0
			end
			continue
		end
		return t, o1, o2, o3
	end
	error("Triangulator: point-location walk did not terminate", 2)
end

local function spread(n: number): number
	n = bit32.band(bit32.bor(n, bit32.lshift(n, 8)), 0x00FF00FF)
	n = bit32.band(bit32.bor(n, bit32.lshift(n, 4)), 0x0F0F0F0F)
	n = bit32.band(bit32.bor(n, bit32.lshift(n, 2)), 0x33333333)
	n = bit32.band(bit32.bor(n, bit32.lshift(n, 1)), 0x55555555)
	return n
end

-- Input indices in Morton (Z-order) of their coordinates, for walk locality.
local function mortonOrder(coords: { number }, count: number, minX: number, minY: number, span: number): { number }
	local scaleToGrid = (2 ^ MORTON_BITS - 1) / span
	local keys = table.create(count)
	local order = table.create(count)
	for i = 1, count do
		local gx = math.floor((coords[2 * i - 1] - minX) * scaleToGrid)
		local gy = math.floor((coords[2 * i] - minY) * scaleToGrid)
		keys[i] = bit32.bor(spread(gx), bit32.lshift(spread(gy), 1))
		order[i] = i
	end
	table.sort(order, function(i: number, j: number): boolean
		if keys[i] ~= keys[j] then
			return keys[i] < keys[j]
		end
		return i < j
	end)
	return order
end

-- Inserts (x, y): merges into an exact duplicate, or splits an edge / a triangle, then
-- restores Delaunay. Returns the vertex and a nearby triangle (walk hint).
local function insertPoint(s: State, x: number, y: number, hint: number, stack: { number }): (number, number)
	local t, o1, o2, o3 = Triangulator.Walk(s, x, y, hint)
	assert(t ~= 0, "Triangulate: point outside the bounding triangle")
	local zeros = (if o1 == 0 then 1 else 0) + (if o2 == 0 then 1 else 0) + (if o3 == 0 then 1 else 0)
	if zeros >= 2 then
		-- Exact duplicate of an existing vertex: the vertex whose opposite edge is non-zero.
		local slot = if o1 ~= 0 then 1 elseif o2 ~= 0 then 2 else 3
		return vertexAt(s, t, slot), t
	end
	local p = Storage.AddVertex(s, x, y)
	if zeros == 1 then
		local e = if o1 == 0 then 1 elseif o2 == 0 then 2 else 3
		splitEdge(s, t, e, p, stack)
	else
		splitTriangle(s, t, p, stack)
	end
	legalize(s, stack)
	return p, VertexTriangle[p]
end

-- The slot of triangle t that is neither vertex x nor vertex y (the edge (x, y) is opposite it).
local function slotOpposite(s: State, t: number, x: number, y: number): number
	local a, b, c = GetTriangle(s, t)
	if a ~= x and a ~= y then
		return 1
	end
	if b ~= x and b ~= y then
		return 2
	end
	return 3
end

-- Calls visit(t, i) for every triangle around vertex x (i = x's slot) until it returns true.
local function aroundVertex(s: State, x: number, visit: (number, number) -> boolean): boolean
	local start = VertexTriangle[x]
	local slotOfX = function(t: number): number
		local a, b = GetTriangle(s, t)
		if a == x then
			return 1
		end
		if b == x then
			return 2
		end
		return 3
	end
	-- One direction across the edge after x, then (if the fan is open) the other direction.
	for _, step in { 1, 2 } do
		local t = start
		local guard = Storage.TriangleCount(s) + 1
		while t ~= 0 and guard > 0 do
			guard -= 1
			local i = slotOfX(t)
			if visit(t, i) then
				return true
			end
			local nextSlot = if step == 1 then (i + 1) % 3 + 1 else i % 3 + 1
			t = GetNeighbor(s, t, nextSlot)
			if t == start then
				return false
			end
		end
	end
	return false
end

-- A triangle having edge (x, y) and the slot opposite it, or 0 when the edge doesn't exist.
local function findEdge(s: State, x: number, y: number): (number, number)
	local found, foundSlot = 0, 0
	aroundVertex(s, x, function(t: number, i: number): boolean
		local a, b, c = GetTriangle(s, t)
		if a == y or b == y or c == y then
			found, foundSlot = t, slotOpposite(s, t, x, y)
			return true
		end
		return false
	end)
	return found, foundSlot
end

local function coverEdge(s: State, t: number, slot: number, ids: { number })
	local head = GetCoverHead(s, t, slot)
	for _, id in ids do
		head = Storage.PushCover(s, head, id)
	end
	SetCoverHead(s, t, slot, head)
	local n = GetNeighbor(s, t, slot)
	if n ~= 0 then
		SetCoverHead(s, n, slotOf(s, n, t), head)
	end
end

local function uncoverEdge(s: State, t: number, slot: number): { number }
	local ids = {}
	for k = 1, Storage.GetCoveringEdgeCount(s, t, slot) do
		table.insert(ids, Storage.GetCoveringEdge(s, t, slot, k))
	end
	SetCoverHead(s, t, slot, 0)
	local n = GetNeighbor(s, t, slot)
	if n ~= 0 then
		SetCoverHead(s, n, slotOf(s, n, t), 0)
	end
	return ids
end

local function dot(s: State, a: number, b: number, c: number): number
	local ax, ay = GetVertex(s, a)
	local bx, by = GetVertex(s, b)
	local cx, cy = GetVertex(s, c)
	return (bx - ax) * (cx - ax) + (by - ay) * (cy - ay)
end

local function orient(s: State, a: number, b: number, c: number): number
	local ax, ay = GetVertex(s, a)
	local bx, by = GetVertex(s, b)
	local cx, cy = GetVertex(s, c)
	return Orient2D(ax, ay, bx, by, cx, cy)
end

type WalkResult = {
	Kind: "Vertex" | "Constraint",
	Stop: number, -- Vertex: the vertex reached on the segment
	Right: number, -- Constraint: the crossed constrained edge (right, left) and a triangle holding it
	Left: number,
	Triangle: number,
	Crossings: { { number } }, -- crossed unconstrained edges before the stop, as {right, left}
}

-- Walks the segment a -> b from a, collecting crossed edges until it reaches a vertex exactly
-- on the segment (possibly b) or a constrained edge it would cross.
local function walkSegment(s: State, a: number, b: number): WalkResult
	local crossings: { { number } } = {}
	local startT, right, left = 0, 0, 0
	local hitVertex = 0
	aroundVertex(s, a, function(t: number, i: number): boolean
		local r, l = vertexAt(s, t, i % 3 + 1), vertexAt(s, t, (i + 1) % 3 + 1)
		local oR, oL = orient(s, a, r, b), orient(s, a, l, b)
		if oR == 0 and dot(s, a, r, b) > 0 then
			hitVertex = r
			return true
		end
		if oL == 0 and dot(s, a, l, b) > 0 then
			hitVertex = l
			return true
		end
		if oR > 0 and oL < 0 then
			startT, right, left = t, r, l
			return true
		end
		return false
	end)
	if hitVertex ~= 0 then
		return { Kind = "Vertex", Stop = hitVertex, Right = 0, Left = 0, Triangle = 0, Crossings = crossings }
	end
	assert(startT ~= 0, "Triangulate: no triangle around the segment start (degenerate input)")
	local t = startT
	while true do
		local slot = slotOpposite(s, t, right, left)
		if GetCoverHead(s, t, slot) ~= 0 then
			return { Kind = "Constraint", Stop = 0, Right = right, Left = left, Triangle = t, Crossings = crossings }
		end
		table.insert(crossings, { right, left })
		local n = GetNeighbor(s, t, slot)
		local c = vertexAt(s, n, slotOf(s, n, t))
		local o = orient(s, a, b, c)
		if o == 0 then
			return { Kind = "Vertex", Stop = c, Right = 0, Left = 0, Triangle = 0, Crossings = crossings }
		end
		if o < 0 then
			right = c
		else
			left = c
		end
		t = n
	end
end

-- Sloan's edge recovery: flip crossed edges (when their quad is convex) until (a, w) exists.
-- Returns the edges created by flips that don't cross the segment (to re-legalize).
local function recoverEdge(s: State, a: number, w: number, crossings: { { number } }): { { number } }
	local queue = crossings
	local fresh: { { number } } = {}
	local guard = 64 * (#queue + 1) * (#queue + 1)
	while #queue > 0 do
		guard -= 1
		assert(guard > 0, "Triangulate: constraint recovery did not converge")
		local edge = table.remove(queue, 1) :: { number }
		local x, y = edge[1], edge[2]
		local t, slot = findEdge(s, x, y)
		local p = vertexAt(s, t, slot)
		local n = GetNeighbor(s, t, slot)
		local q = vertexAt(s, n, slotOf(s, n, t))
		-- Flip only when p-q properly crosses x-y (the quad p, x, q, y is strictly convex).
		if orient(s, p, q, x) * orient(s, p, q, y) < 0 then
			Triangulator.Flip(s, t, slot)
			local crosses = p ~= a and p ~= w and q ~= a and q ~= w and orient(s, a, w, p) * orient(s, a, w, q) < 0
			if crosses then
				table.insert(queue, { p, q })
			else
				table.insert(fresh, { p, q })
			end
		else
			table.insert(queue, edge)
		end
	end
	return fresh
end

-- Inserts constraint segment u -> v covering `ids`, splitting at collinear vertices and at
-- crossings with existing constraints (Steiner vertices).
local function insertConstraint(s: State, u: number, v: number, ids: { number }, stack: { number })
	local work: { { any } } = { { u, v, ids } }
	while #work > 0 do
		local item = table.remove(work) :: { any }
		local a, b, segmentIds = item[1] :: number, item[2] :: number, item[3] :: { number }
		if a == b then
			continue
		end
		local t, slot = findEdge(s, a, b)
		if t ~= 0 then
			coverEdge(s, t, slot, segmentIds)
			continue
		end
		local result = walkSegment(s, a, b)
		if result.Kind == "Vertex" then
			local w = result.Stop
			local fresh = recoverEdge(s, a, w, result.Crossings)
			local et, eslot = findEdge(s, a, w)
			coverEdge(s, et, eslot, segmentIds)
			for _, edge in fresh do
				local ft, fslot = findEdge(s, edge[1], edge[2])
				if ft ~= 0 then
					table.insert(stack, ft)
					table.insert(stack, fslot)
				end
			end
			legalize(s, stack, true)
			table.insert(work, { w, b, segmentIds })
			continue
		end
		-- Crossing an existing constraint (r, l): insert the intersection as a Steiner vertex,
		-- then route both constraints through it.
		local r, l = result.Right, result.Left
		local cslot = slotOpposite(s, result.Triangle, r, l)
		local crossedIds = uncoverEdge(s, result.Triangle, cslot)
		local ax, ay = GetVertex(s, a)
		local bx, by = GetVertex(s, b)
		local rx, ry = GetVertex(s, r)
		local lx, ly = GetVertex(s, l)
		local den = (bx - ax) * (ly - ry) - (by - ay) * (lx - rx)
		local along = ((rx - ax) * (ly - ry) - (ry - ay) * (lx - rx)) / den
		local px, py = ax + along * (bx - ax), ay + along * (by - ay)
		local p = insertPoint(s, px, py, result.Triangle, stack)
		table.insert(work, { r, p, crossedIds })
		table.insert(work, { p, l, crossedIds })
		table.insert(work, { p, b, segmentIds })
		table.insert(work, { a, p, segmentIds })
	end
end

local function groupCountOf(input: Types.TriangulateInput): number
	local groups = input.EdgeGroups
	local edges = input.Edges
	if groups and #groups > 0 then
		local highest = 0
		for _, g in groups do
			highest = math.max(highest, g)
		end
		return highest
	end
	if edges and #edges > 0 then
		return 1
	end
	return 0
end

--[=[
	@within Triangulator
	Builds the constrained Delaunay triangulation of the input points and edges.
]=]
function Triangulator.Build(input: Types.TriangulateInput): State
	local coords = input.Coords
	assert(#coords % 2 == 0, "Triangulate: Coords must hold x,y pairs")
	local count = #coords // 2
	local edges = input.Edges or {}
	assert(#edges % 2 == 0, "Triangulate: Edges must hold index pairs")
	for _, index in edges do
		assert(index >= 1 and index <= count and index % 1 == 0, "Triangulate: edge endpoint out of range")
	end
	local s = Storage.New(count, groupCountOf(input))
	table.clear(VertexTriangle)
	Storage.Reserve(s, count + SUPER_VERTICES, 2 * count + 8)

	local minX, minY, maxX, maxY = math.huge, math.huge, -math.huge, -math.huge
	for i = 1, count do
		local x, y = coords[2 * i - 1], coords[2 * i]
		assert(x == x and y == y and math.abs(x) ~= math.huge and math.abs(y) ~= math.huge, "Triangulate: coordinates must be finite")
		minX, maxX = math.min(minX, x), math.max(maxX, x)
		minY, maxY = math.min(minY, y), math.max(maxY, y)
	end
	if count == 0 then
		Storage.AllocWinding(s)
		return s
	end
	local span = math.max(maxX - minX, maxY - minY, 1)
	local centerX, centerY = (minX + maxX) / 2, (minY + maxY) / 2
	local m = span * SUPER_SCALE
	Storage.AddVertex(s, centerX - 2 * m, centerY - m)
	Storage.AddVertex(s, centerX + 2 * m, centerY - m)
	Storage.AddVertex(s, centerX, centerY + 2 * m)
	Storage.AddTriangle(s, 1, 2, 3)
	write(s, 1, 1, 2, 3, 0, 0, 0, 0, 0, 0)

	local stack: { number } = {}
	local hint = 1
	for _, i in mortonOrder(coords, count, minX, minY, span) do
		local p, near = insertPoint(s, coords[2 * i - 1], coords[2 * i], hint, stack)
		Storage.SetInputVertex(s, i, p)
		hint = near
	end

	-- Winding groups >= 1 must be closed loops (U-d); fail before any constraint work.
	Classify.CheckBalanced(s, input)

	-- Constraint edge k is the k-th index pair; its id is k.
	for k = 1, #edges // 2 do
		local u = Storage.VertexOfInput(s, edges[2 * k - 1])
		local v = Storage.VertexOfInput(s, edges[2 * k])
		insertConstraint(s, u, v, { k }, stack)
	end
	if #edges > 0 then
		-- Global Lawson pass: a constrained edge may be non-Delaunay, and un-constraining one
		-- to route a crossing through a Steiner vertex can leave it (or its surroundings)
		-- non-Delaunay. Flipping every unconstrained edge to convergence yields the CDT.
		for t = 1, Storage.TriangleCount(s) do
			for e = 1, 3 do
				local n = GetNeighbor(s, t, e)
				if n > t and GetCoverHead(s, t, e) == 0 then
					table.insert(stack, t)
					table.insert(stack, e)
				end
			end
		end
		legalize(s, stack, true)
	end

	-- Remove the bounding triangle's vertices and every triangle touching them.
	local keep = table.create(Storage.TriangleCount(s), false)
	for t = 1, Storage.TriangleCount(s) do
		local a, b, c = GetTriangle(s, t)
		keep[t] = a > SUPER_VERTICES and b > SUPER_VERTICES and c > SUPER_VERTICES
	end
	Storage.Compact(s, keep)
	Storage.DropLeadingVertices(s, SUPER_VERTICES)
	Storage.AllocWinding(s)
	Classify.Flood(s, input)
	return s
end

return Triangulator
