--!strict
--!native
-- Authors: Logan Hunt (Raildex)
-- September 27, 2026
--[=[
	@class NavMeshClearance
	@private

	Clearance widths (SR4, ruling U-a): the widest agent that can pass each part of a triangle,
	computed once at Build so any `AgentRadius` works at query time.

	**Walls** are mesh edges with no neighbour that are not open (`Storage.IsWallEdge`): the
	walkable and obstacle boundaries. Tile, area and seam edges are never walls, so free-space
	vertices never bound a width. Walls are per floor: near a seam, the other floor's walls are
	not counted.

	**Corner width** (between the two edges at vertex C of triangle ABC): an agent of radius r
	passing from CA to CB is blocked exactly when the r-discs around wall edges, cut to the
	triangle, chain from C to the far edge AB (planar separation; each cut disc is convex). The
	width is 2r* for the smallest such r (a minimax Dijkstra):
	- start: C lies in a disc, d(C, wall) <= r;
	- link: two cut discs meet *inside the triangle*, min over p in it of
	  max(d(p, f), d(p, g)) <= r. An overlap outside the triangle doesn't block it: every wall
	  loop is connected, so counting those would close every passage;
	- finish: a disc reaches AB, d(wall, AB) <= r.
	A wall vertex at C lies on a wall edge, so it starts the chain at r = 0: the width is its gap
	to the far walls (Demyen's formula when A and B are walls too). A free vertex bounds nothing.

	**Portal width** (across edge UV): the same chain from U to V, with links met on UV itself
	(the discs then cover UV). It is for the start and goal triangles; elsewhere a corner width
	already covers both of its portals.

	**Precision:** a link whose minimum is not at the closest-pair midpoint is found on the
	region's edges, at a crossing found by regula falsi to about 1e-13 of the edge. Widths may
	read a hair wide, never narrow.

	**Reach and the cap:** a width depends only on walls within r* of its triangle, which bounds
	what `Update` must recompute. With `MaxAgentRadius` R, the search stops at R and a width is
	stored as at most 2R.

	**Cost (ticket 15 notes):** about 0.1-0.25 ms per triangle on Lune. That is several times the
	triangulation itself, and dominated by exact link costs.
]=]

local Storage = require("./Storage")

type Seg = { number } -- x1, z1, x2, z2
-- A region links must be met in: a triangle's three edges (CCW), or one portal edge.
type Region = { Seg }

local CELL = 8 -- studs per wall-grid cell
local FIRST_LIMIT = 4 -- the first search radius (studs); it doubles until the answer is exact
local LAST_LIMIT = 65536 -- the whole coordinate range: every wall is in the search

local Clearance = {}

local function cross(ax: number, az: number, bx: number, bz: number, cx: number, cz: number): number
	return (bx - ax) * (cz - az) - (bz - az) * (cx - ax)
end

-- The point of segment s nearest (px, pz).
local function nearestOn(px: number, pz: number, s: Seg): (number, number)
	local dx, dz = s[3] - s[1], s[4] - s[2]
	local len2 = dx * dx + dz * dz
	local u = if len2 > 0 then math.clamp(((px - s[1]) * dx + (pz - s[2]) * dz) / len2, 0, 1) else 0
	return s[1] + u * dx, s[2] + u * dz
end

local function pointSeg(px: number, pz: number, s: Seg): number
	local qx, qz = nearestOn(px, pz, s)
	return math.sqrt((qx - px) ^ 2 + (qz - pz) ^ 2)
end

local function crosses(a: Seg, b: Seg): (boolean, number)
	local d3, d4 = cross(b[1], b[2], b[3], b[4], a[1], a[2]), cross(b[1], b[2], b[3], b[4], a[3], a[4])
	local d1, d2 = cross(a[1], a[2], a[3], a[4], b[1], b[2]), cross(a[1], a[2], a[3], a[4], b[3], b[4])
	return d1 * d2 < 0 and d3 * d4 < 0, if d3 ~= d4 then d3 / (d3 - d4) else 0
end

local function segSeg(a: Seg, b: Seg): number
	if crosses(a, b) then
		return 0
	end
	return math.min(pointSeg(a[1], a[2], b), pointSeg(a[3], a[4], b), pointSeg(b[1], b[2], a), pointSeg(b[3], b[4], a))
end

-- The midpoint of a closest pair of points of a and b (their crossing point when they cross).
local function closestMidpoint(a: Seg, b: Seg): (number, number)
	local crossing, u = crosses(a, b)
	if crossing then
		return a[1] + u * (a[3] - a[1]), a[2] + u * (a[4] - a[2])
	end
	local best, mx, mz = math.huge, 0, 0
	for k = 1, 4 do
		local from, onto = if k <= 2 then a else b, if k <= 2 then b else a
		local px, pz = from[2 * ((k - 1) % 2) + 1], from[2 * ((k - 1) % 2) + 2]
		local qx, qz = nearestOn(px, pz, onto)
		local d = (qx - px) ^ 2 + (qz - pz) ^ 2
		if d < best then
			best, mx, mz = d, (px + qx) * 0.5, (pz + qz) * 0.5
		end
	end
	return mx, mz
end

-- The parameter u in [0, 1] of the point of edge e nearest segment f (a minimum of d(e(u), f)).
local function nearestParam(e: Seg, f: Seg): number
	local crossing, _ = crosses(f, e)
	if crossing then
		local _, u = crosses(e, f)
		return u
	end
	local ex, ez, dx, dz = e[1], e[2], e[3] - e[1], e[4] - e[2]
	local len2 = dx * dx + dz * dz
	-- Candidates: e's endpoints, and the projections of f's endpoints onto e.
	local bestU, best = 0, math.huge
	for _, u in
		{
			0,
			1,
			math.clamp(((f[1] - ex) * dx + (f[2] - ez) * dz) / len2, 0, 1),
			math.clamp(((f[3] - ex) * dx + (f[4] - ez) * dz) / len2, 0, 1),
		}
	do
		local d = pointSeg(ex + u * dx, ez + u * dz, f)
		if d < best then
			bestU, best = u, d
		end
	end
	return bestU
end

-- min over p on edge e of max(d(p, f), d(p, g)). Both distances are convex along e: if one
-- dominates at the other's minimum, that is the answer; otherwise it is their crossing, which
-- lies between the two minima (found by regula falsi, Illinois variant).
local function edgeMinMax(e: Seg, f: Seg, g: Seg): number
	local ex, ez, dx, dz = e[1], e[2], e[3] - e[1], e[4] - e[2]
	local function df(u: number): number
		return pointSeg(ex + u * dx, ez + u * dz, f)
	end
	local function dg(u: number): number
		return pointSeg(ex + u * dx, ez + u * dz, g)
	end
	local uf, ug = nearestParam(e, f), nearestParam(e, g)
	local fAtF, gAtF = df(uf), dg(uf)
	if fAtF >= gAtF then
		return fAtF
	end
	local fAtG, gAtG = df(ug), dg(ug)
	if gAtG >= fAtG then
		return gAtG
	end
	-- h = df - dg is < 0 at uf and > 0 at ug.
	local a, ha, b, hb = uf, fAtF - gAtF, ug, fAtG - gAtG
	local side = 0
	local u, value = a, math.max(fAtF, gAtF)
	for _ = 1, 64 do
		u = (a * hb - b * ha) / (hb - ha)
		local fu, gu = df(u), dg(u)
		local hu = fu - gu
		value = math.max(fu, gu)
		if hu == 0 or math.abs(b - a) < 1e-13 then
			break
		end
		if (hu < 0) == (ha < 0) then
			a, ha = u, hu
			if side == -1 then
				hb *= 0.5
			end
			side = -1
		else
			b, hb = u, hu
			if side == 1 then
				ha *= 0.5
			end
			side = 1
		end
	end
	return value
end

local function inRegion(region: Region, px: number, pz: number): boolean
	if #region == 1 then
		local s = region[1]
		return cross(s[1], s[2], s[3], s[4], px, pz) == 0
			and math.min(s[1], s[3]) <= px
			and px <= math.max(s[1], s[3])
			and math.min(s[2], s[4]) <= pz
			and pz <= math.max(s[2], s[4])
	end
	for _, s in region do
		if cross(s[1], s[2], s[3], s[4], px, pz) < 0 then
			return false
		end
	end
	return true
end

-- The cost of linking walls f and g inside `region`: min over p in it of max(d(p, f), d(p, g)).
-- Convex, so the minimum is the closest-pair midpoint when that lies inside, else on an edge.
local function linkCost(region: Region, f: Seg, g: Seg): number
	local mx, mz = closestMidpoint(f, g)
	if inRegion(region, mx, mz) then
		return math.max(pointSeg(mx, mz, f), pointSeg(mx, mz, g))
	end
	-- Outside: the minimum lies on an edge that faces the midpoint (for a portal, its one edge).
	local best = math.huge
	for _, e in region do
		if #region == 1 or cross(e[1], e[2], e[3], e[4], mx, mz) < 0 then
			best = math.min(best, edgeMinMax(e, f, g))
		end
	end
	return best
end

-- Smallest r that chains cut discs from point (sx, sz) to `sink`, with links met inside
-- `region`. `reach[i]` is feature i's distance to the region, a lower bound on any link into
-- it. `links` caches link costs for the region. Returns math.huge when nothing blocks.
local function chain(
	feats: { Seg },
	reach: { number },
	region: Region,
	links: { [number]: number },
	gaps: { [number]: number },
	sx: number,
	sz: number,
	sink: Seg
): number
	local m = #feats
	local label = table.create(m, 0)
	local done = table.create(m, false)
	for i = 1, m do
		label[i] = math.max(pointSeg(sx, sz, feats[i]), reach[i])
	end
	local best = math.huge
	while true do
		local i, li = 0, math.huge
		for j = 1, m do
			if not done[j] and label[j] < li then
				i, li = j, label[j]
			end
		end
		if i == 0 or li >= best then
			return best
		end
		done[i] = true
		local fi = feats[i]
		best = math.min(best, math.max(li, segSeg(fi, sink)))
		-- A link can only matter if it could beat both j's label and the best chain so far.
		for j = 1, m do
			local bound = math.min(label[j], best)
			if done[j] or bound <= li or reach[j] >= bound then
				continue
			end
			-- Cheap lower bound first: two discs can't meet before r = d(f, g) / 2.
			local k = if i < j then i * (m + 1) + j else j * (m + 1) + i
			local gap = gaps[k]
			if gap == nil then
				gap = segSeg(fi, feats[j])
				gaps[k] = gap
			end
			if gap * 0.5 >= bound then
				continue
			end
			local cost = links[k]
			if cost == nil then
				cost = linkCost(region, fi, feats[j])
				links[k] = cost
			end
			local via = math.max(li, cost)
			if via < label[j] then
				label[j] = via
			end
		end
	end
end

--[=[
	@within NavMeshClearance
	Computes every triangle's corner and portal widths and every vertex's wall flag. `cap` is the
	MaxAgentRadius (0 = none).
]=]
function Clearance.Compute(s: Storage.State, cap: number)
	Storage.SetMaxAgentRadius(s, cap)
	local n = Storage.TriangleCount(s)

	-- Walls, bucketed by floor and grid cell.
	local walls: { Seg } = {}
	local grid: { [number]: { number } } = {}
	local function key(floor: number, cx: number, cz: number): number
		return (floor * 65536 + cx + 32768) * 65536 + cz + 32768
	end
	for t = 1, n do
		local verts = { Storage.GetTriangle(s, t) }
		local floor = Storage.GetTriangleFloor(s, t)
		for e = 1, 3 do
			if not Storage.IsWallEdge(s, t, e) then
				continue
			end
			local u, v = verts[e % 3 + 1], verts[(e + 1) % 3 + 1]
			Storage.SetWallVertex(s, u, true)
			Storage.SetWallVertex(s, v, true)
			local p, q = Storage.GetVertex(s, u), Storage.GetVertex(s, v)
			table.insert(walls, { p.X, p.Z, q.X, q.Z })
			local id = #walls
			for cx = math.floor(math.min(p.X, q.X) / CELL), math.floor(math.max(p.X, q.X) / CELL) do
				for cz = math.floor(math.min(p.Z, q.Z) / CELL), math.floor(math.max(p.Z, q.Z) / CELL) do
					local k = key(floor, cx, cz)
					local bucket = grid[k]
					if bucket == nil then
						bucket = {}
						grid[k] = bucket
					end
					table.insert(bucket, id)
				end
			end
		end
	end

	local limitCap = if cap > 0 then cap else LAST_LIMIT
	-- ponytail: every triangle, once per Build; Update (ticket 18) must pass a subset, and a
	-- per-edge wall-chain merge or a cheaper link bound is the next lever if that is too slow.
	for t = 1, n do
		local verts = { Storage.GetTriangle(s, t) }
		local floor = Storage.GetTriangleFloor(s, t)
		local P = { Storage.GetVertex(s, verts[1]), Storage.GetVertex(s, verts[2]), Storage.GetVertex(s, verts[3]) }
		-- Edge e of t, opposite vertex e, in CCW order.
		local edges: Region = {}
		for e = 1, 3 do
			local u, v = P[e % 3 + 1], P[(e + 1) % 3 + 1]
			edges[e] = { u.X, u.Z, v.X, v.Z }
		end
		local minX, maxX = math.min(P[1].X, P[2].X, P[3].X), math.max(P[1].X, P[2].X, P[3].X)
		local minZ, maxZ = math.min(P[1].Z, P[2].Z, P[3].Z), math.max(P[1].Z, P[2].Z, P[3].Z)
		local across = { Storage.GetNeighbor(s, t, 1), Storage.GetNeighbor(s, t, 2), Storage.GetNeighbor(s, t, 3) }
		local crossable = {
			not Storage.IsWallEdge(s, t, 1),
			not Storage.IsWallEdge(s, t, 2),
			not Storage.IsWallEdge(s, t, 3),
		}
		local limit = math.min(FIRST_LIMIT, limitCap)
		while true do
			-- Walls within `limit` of the triangle, and how close each comes to it and its edges.
			local feats: { Seg } = {}
			local toTri: { number } = {}
			local toEdge: { { number } } = { {}, {}, {} }
			local seen: { [number]: boolean } = {}
			for cx = math.floor((minX - limit) / CELL), math.floor((maxX + limit) / CELL) do
				for cz = math.floor((minZ - limit) / CELL), math.floor((maxZ + limit) / CELL) do
					local bucket: { number } = grid[key(floor, cx, cz)] or {}
					for _, id in bucket do
						if seen[id] then
							continue
						end
						seen[id] = true
						local w = walls[id]
						local d1, d2, d3 = segSeg(w, edges[1]), segSeg(w, edges[2]), segSeg(w, edges[3])
						local d = math.min(d1, d2, d3)
						if d <= limit then
							table.insert(feats, w)
							table.insert(toTri, d)
							table.insert(toEdge[1], d1)
							table.insert(toEdge[2], d2)
							table.insert(toEdge[3], d3)
						end
					end
				end
			end
			-- Only widths a query reads: a corner between two crossable edges, a crossable portal.
			-- The rest stay 0 (nothing crosses a wall).
			local r = table.create(6, 0)
			local exact = true
			local triLinks, gaps = {}, {}
			for k = 1, 3 do
				if crossable[k % 3 + 1] and crossable[(k + 1) % 3 + 1] then
					r[k] = chain(feats, toTri, edges, triLinks, gaps, P[k].X, P[k].Z, edges[k])
				end
				-- A portal is shared: the lower-numbered triangle computes it (see below). A seam
				-- edge (open, no neighbour) is its own triangle's alone.
				if crossable[k] and (across[k] > t or across[k] == 0) then
					local u = P[k % 3 + 1]
					local sink = { edges[k][3], edges[k][4], edges[k][3], edges[k][4] }
					r[3 + k] = chain(feats, toEdge[k], { edges[k] }, {}, gaps, u.X, u.Z, sink)
				end
				exact = exact and r[k] <= limit and r[3 + k] <= limit
			end
			if exact or limit >= limitCap then
				-- Past the limit only a lower bound is known: the cap (or, uncapped, the whole
				-- range was searched and nothing blocks).
				for k = 1, 3 do
					Storage.SetCornerWidth(s, t, k, 2 * math.min(r[k], limitCap))
					local nb = across[k]
					if nb > t then
						local width = 2 * math.min(r[3 + k], limitCap)
						Storage.SetPortalWidth(s, t, k, width)
						local back = if Storage.GetNeighbor(s, nb, 1) == t
							then 1
							elseif Storage.GetNeighbor(s, nb, 2) == t then 2
							else 3
						Storage.SetPortalWidth(s, nb, back, width)
					elseif nb == 0 then
						Storage.SetPortalWidth(s, t, k, if crossable[k] then 2 * math.min(r[3 + k], limitCap) else 0)
					end
				end
				break
			end
			limit = math.min(limit * 2, limitCap)
		end
	end
end

return Clearance
