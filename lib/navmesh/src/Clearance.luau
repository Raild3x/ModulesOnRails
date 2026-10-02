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

	**Update (ticket 22):** Build keeps its wall index (walls by floor and grid cell, listed under
	their tiles) in a weak per-mesh cache. `Refresh` swaps the rebuilt tiles' walls in it and
	recomputes every triangle within its own reach r* of a *changed wall*: one in the old walls or
	the new ones, not both. That is more than the obstacle's box. A static wall crossing the
	obstacle gets a snapped vertex at the crossing, and that tilts the whole fragment back to its
	previous vertex by up to half a grid pixel. The index is runtime state and never serialized:
	a loaded mesh builds it on its first `Update`, from the state before the change.

	**Cost (ticket 15 notes):** about 0.1-0.25 ms per triangle on Lune. That is several times the
	triangulation itself, and dominated by exact link costs.
]=]

local OpenList = require("./OpenList")
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

-- min over p on edge e of max(d(p, f), d(p, g)), and that p. Both distances are convex along
-- e: if one dominates at the other's minimum, that is the answer; otherwise it is their
-- crossing, which lies between the two minima (found by regula falsi, Illinois variant).
local function edgeMinMax(e: Seg, f: Seg, g: Seg): (number, number, number)
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
		return fAtF, ex + uf * dx, ez + uf * dz
	end
	local fAtG, gAtG = df(ug), dg(ug)
	if gAtG >= fAtG then
		return gAtG, ex + ug * dx, ez + ug * dz
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
	return value, ex + u * dx, ez + u * dz
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

-- The cost of linking walls f and g inside `region`: min over p in it of max(d(p, f), d(p, g)),
-- and that p. Convex, so the minimum is the closest-pair midpoint when that lies inside, else on
-- an edge.
local function linkCost(region: Region, f: Seg, g: Seg): (number, number, number)
	local mx, mz = closestMidpoint(f, g)
	if inRegion(region, mx, mz) then
		return math.max(pointSeg(mx, mz, f), pointSeg(mx, mz, g)), mx, mz
	end
	-- Outside: the minimum lies on an edge that faces the midpoint (for a portal, its one edge).
	local best, bx, bz = math.huge, mx, mz
	for _, e in region do
		if #region == 1 or cross(e[1], e[2], e[3], e[4], mx, mz) < 0 then
			local cost, px, pz = edgeMinMax(e, f, g)
			if cost < best then
				best, bx, bz = cost, px, pz
			end
		end
	end
	return best, bx, bz
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
	local halfLen = table.create(m, 0)
	for i = 1, m do
		local f = feats[i]
		halfLen[i] = math.sqrt((f[3] - f[1]) ^ 2 + (f[4] - f[2]) ^ 2) * 0.5
	end
	local best = math.huge
	-- Links are evaluated lazily (most never lower a label; 6-8% did on long rings): a relaxation
	-- whose cost isn't cached waits in a heap, keyed by a lower bound of what it could give,
	-- max(li, gap / 2, reach), as source * (m + 1) + target. It is evaluated only once no label
	-- left is below that bound, and dropped if its target's label has fallen to it. Labels are
	-- exact when popped, as in the eager search, so `best` is the same number; a source's label
	-- is final once it is done, so it is read back at the pop.
	local waiting = OpenList.new()
	while true do
		local i, li = 0, math.huge
		for j = 1, m do
			if not done[j] and label[j] < li then
				i, li = j, label[j]
			end
		end
		while waiting.Size > 0 and waiting.Keys[1] < li and waiting.Keys[1] < best do
			local pair, key = OpenList.Pop(waiting)
			local a, b = pair // (m + 1), pair % (m + 1)
			if done[b] or key >= label[b] then
				continue
			end
			local k = if a < b then a * (m + 1) + b else b * (m + 1) + a
			local cost = links[k]
			if cost == nil then
				cost = linkCost(region, feats[a], feats[b])
				links[k] = cost
			end
			local via = math.max(label[a], cost)
			if via < label[b] then
				label[b] = via
				if via < li then
					i, li = b, via
				end
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
			-- Cheap lower bound first: two discs can't meet before r = d(f, g) / 2. A bound on
			-- d(f, g) is enough here: the midpoints' distance less the half lengths.
			local k = if i < j then i * (m + 1) + j else j * (m + 1) + i
			local gap = gaps[k]
			if gap == nil then
				local fj = feats[j]
				gap = math.max(
					0,
					math.sqrt(((fi[1] + fi[3]) - (fj[1] + fj[3])) ^ 2 + ((fi[2] + fi[4]) - (fj[2] + fj[4])) ^ 2) * 0.5
						- halfLen[i]
						- halfLen[j]
				)
				gaps[k] = gap
			end
			if gap * 0.5 >= bound then
				continue
			end
			local cost = links[k]
			if cost ~= nil then
				local via = math.max(li, cost)
				if via < label[j] then
					label[j] = via
				end
				continue
			end
			OpenList.Push(waiting, i * (m + 1) + j, math.max(li, gap * 0.5, reach[j]))
		end
	end
end

-- The wall index: wall segments by floor and grid cell, each listed under its tile. Freed ids
-- are reused, so toggling obstacles never grows it.
type WallIndex = {
	Walls: { Seg },
	WallFloor: { number },
	TileWalls: { [number]: { number } }, -- tile -> its wall ids
	Grid: { [number]: { number } }, -- floor and cell -> wall ids
	Free: { number },
}

-- Per mesh (weak): the wall index Build made, kept in step by Refresh; and each tile's largest
-- width, which bounds how far a change can reach into it (nil = not measured yet).
local indexes: { [Storage.State]: WallIndex } = setmetatable({}, { __mode = "k" }) :: any
local tileReaches: { [Storage.State]: { [number]: number } } = setmetatable({}, { __mode = "k" }) :: any
-- Per mesh (weak): what `around` answered per triangle (ticket 27 queries).
local lastAround: { [Storage.State]: any } = setmetatable({}, { __mode = "k" }) :: any

local function cellKey(floor: number, cx: number, cz: number): number
	return (floor * 65536 + cx + 32768) * 65536 + cz + 32768
end

-- Adds the wall edges of triangles first..last to the index, flagging their vertices when
-- `flag`, and appending each wall to `added` when given.
local function addWalls(index: WallIndex, s: Storage.State, first: number, last: number, flag: boolean, added: { Seg }?)
	local walls, grid = index.Walls, index.Grid
	for t = first, last do
		local verts = { Storage.GetTriangle(s, t) }
		local floor = Storage.GetTriangleFloor(s, t)
		for e = 1, 3 do
			if not Storage.IsWallEdge(s, t, e) then
				continue
			end
			local u, v = verts[e % 3 + 1], verts[(e + 1) % 3 + 1]
			if flag then
				Storage.SetWallVertex(s, u, true)
				Storage.SetWallVertex(s, v, true)
			end
			local p, q = Storage.GetVertex(s, u), Storage.GetVertex(s, v)
			local id = table.remove(index.Free) or #walls + 1
			local wall = { p.X, p.Z, q.X, q.Z }
			walls[id] = wall
			index.WallFloor[id] = floor
			if added then
				table.insert(added, wall)
			end
			local tile = Storage.GetTriangleTile(s, t)
			local list = index.TileWalls[tile]
			if list == nil then
				list = {}
				index.TileWalls[tile] = list
			end
			table.insert(list, id)
			for cx = math.floor(math.min(p.X, q.X) / CELL), math.floor(math.max(p.X, q.X) / CELL) do
				for cz = math.floor(math.min(p.Z, q.Z) / CELL), math.floor(math.max(p.Z, q.Z) / CELL) do
					local k = cellKey(floor, cx, cz)
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
end

local function buildIndex(s: Storage.State, flag: boolean): WallIndex
	local index: WallIndex = { Walls = {}, WallFloor = {}, TileWalls = {}, Grid = {}, Free = {} }
	addWalls(index, s, 1, Storage.TriangleCount(s), flag)
	return index
end

-- The walls of `floor` within `limit` of the triangle with edges `edges`, how close each comes
-- to it, and to each of its edges.
local function nearWalls(
	index: WallIndex,
	floor: number,
	edges: Region,
	limit: number
): ({ Seg }, { number }, { { number } })
	local minX = math.min(edges[1][1], edges[2][1], edges[3][1])
	local maxX = math.max(edges[1][1], edges[2][1], edges[3][1])
	local minZ = math.min(edges[1][2], edges[2][2], edges[3][2])
	local maxZ = math.max(edges[1][2], edges[2][2], edges[3][2])
	local feats: { Seg } = {}
	local toTri: { number } = {}
	local toEdge: { { number } } = { {}, {}, {} }
	local seen: { [number]: boolean } = {}
	for cx = math.floor((minX - limit) / CELL), math.floor((maxX + limit) / CELL) do
		for cz = math.floor((minZ - limit) / CELL), math.floor((maxZ + limit) / CELL) do
			local bucket: { number } = index.Grid[cellKey(floor, cx, cz)] or {}
			for _, id in bucket do
				if seen[id] then
					continue
				end
				seen[id] = true
				local w = index.Walls[id]
				-- Box gap first: a wall whose box is further than `limit` from the triangle's is.
				if
					math.min(w[1], w[3]) > maxX + limit
					or math.max(w[1], w[3]) < minX - limit
					or math.min(w[2], w[4]) > maxZ + limit
					or math.max(w[2], w[4]) < minZ - limit
				then
					continue
				end
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
	return feats, toTri, toEdge
end

-- The corner and portal widths of every triangle, or of those in `only` (the rest keep the
-- widths they have), from the index's walls.
local function computeWidths(s: Storage.State, cap: number, only: { [number]: boolean }?, index: WallIndex)
	Storage.SetMaxAgentRadius(s, cap)
	local n = Storage.TriangleCount(s)

	local limitCap = if cap > 0 then cap else LAST_LIMIT
	-- ponytail: a per-edge wall-chain merge or a cheaper link bound is the next lever if the
	-- per-triangle cost (the uncapped search above all) is too slow.
	local order: { number }
	if only then
		order = {}
		for t in only do
			table.insert(order, t)
		end
		table.sort(order)
	else
		order = table.create(n)
		for t = 1, n do
			order[t] = t
		end
	end
	for _, t in order do
		local verts = { Storage.GetTriangle(s, t) }
		local floor = Storage.GetTriangleFloor(s, t)
		local P = { Storage.GetVertex(s, verts[1]), Storage.GetVertex(s, verts[2]), Storage.GetVertex(s, verts[3]) }
		-- Edge e of t, opposite vertex e, in CCW order.
		local edges: Region = {}
		for e = 1, 3 do
			local u, v = P[e % 3 + 1], P[(e + 1) % 3 + 1]
			edges[e] = { u.X, u.Z, v.X, v.Z }
		end
		local across = { Storage.GetNeighbor(s, t, 1), Storage.GetNeighbor(s, t, 2), Storage.GetNeighbor(s, t, 3) }
		-- Whether t computes the portal across edge k (and writes it for both sides).
		local function owns(k: number): boolean
			local nb = across[k]
			return nb == 0 or nb > t or (only ~= nil and not only[nb])
		end
		local crossable = {
			not Storage.IsWallEdge(s, t, 1),
			not Storage.IsWallEdge(s, t, 2),
			not Storage.IsWallEdge(s, t, 3),
		}
		local limit = math.min(FIRST_LIMIT, limitCap)
		-- Only widths a query reads: a corner between two crossable edges, a crossable portal.
		-- The rest stay 0 (nothing crosses a wall). A width found within a smaller limit is
		-- exact and is not searched again (only walls within it can bound it).
		local r = table.create(6, 0)
		local solved = table.create(6, false)
		while true do
			local feats, toTri, toEdge = nearWalls(index, floor, edges, limit)
			local exact = true
			local triLinks, gaps = {}, {}
			for k = 1, 3 do
				if not solved[k] and crossable[k % 3 + 1] and crossable[(k + 1) % 3 + 1] then
					r[k] = chain(feats, toTri, edges, triLinks, gaps, P[k].X, P[k].Z, edges[k])
				end
				-- A portal is shared: the lower-numbered triangle computes it (see below), unless
				-- that one is outside `only`. A seam edge (open, no neighbour) is its own alone.
				if not solved[3 + k] and crossable[k] and owns(k) then
					local u = P[k % 3 + 1]
					local sink = { edges[k][3], edges[k][4], edges[k][3], edges[k][4] }
					r[3 + k] = chain(feats, toEdge[k], { edges[k] }, {}, gaps, u.X, u.Z, sink)
				end
				solved[k], solved[3 + k] = r[k] <= limit, r[3 + k] <= limit
				exact = exact and solved[k] and solved[3 + k]
			end
			if exact or limit >= limitCap then
				-- Past the limit only a lower bound is known: the cap (or, uncapped, the whole
				-- range was searched and nothing blocks).
				for k = 1, 3 do
					Storage.SetCornerWidth(s, t, k, 2 * math.min(r[k], limitCap))
					local nb = across[k]
					if nb ~= 0 and owns(k) then
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

--[=[
	@within NavMeshClearance
	Computes every vertex's wall flag and the corner and portal widths of every triangle (Build).
	`cap` is the MaxAgentRadius (0 = none). The wall index is kept for `Refresh`.
]=]
function Clearance.Compute(s: Storage.State, cap: number)
	local index = buildIndex(s, true)
	indexes[s] = index
	tileReaches[s] = {}
	computeWidths(s, cap, nil, index)
end

-- A lower bound on the plan distance (studs) between two boxes: their gap.
local function boxGap(
	ax0: number,
	az0: number,
	ax1: number,
	az1: number,
	bx0: number,
	bz0: number,
	bx1: number,
	bz1: number
): number
	local dx = math.max(bx0 - ax1, 0, ax0 - bx1)
	local dz = math.max(bz0 - az1, 0, az0 - bz1)
	return math.sqrt(dx * dx + dz * dz)
end

-- The largest width in a tile: nothing further than half of it from the tile can change one.
local function tileReach(s: Storage.State, tile: number): number
	local first, count = Storage.GetTileRange(s, tile)
	local reach = 0
	for t = first, first + count - 1 do
		for k = 1, 3 do
			reach = math.max(reach, Storage.GetCornerWidth(s, t, k), Storage.GetPortalWidth(s, t, k))
		end
	end
	return reach
end

-- Removes the walls of `tiles` from the index; returns them by "floor:x1,z1,x2,z2".
local function removeWalls(index: WallIndex, tiles: { number }): { [string]: { number } }
	local removed: { [string]: { number } } = {}
	for _, tile in tiles do
		local ids: { number } = index.TileWalls[tile] or {}
		for _, id in ids do
			local w = index.Walls[id]
			local floor = index.WallFloor[id]
			removed[`{floor}:{w[1]},{w[2]},{w[3]},{w[4]}`] = { floor, w[1], w[2], w[3], w[4] }
			for cx = math.floor(math.min(w[1], w[3]) / CELL), math.floor(math.max(w[1], w[3]) / CELL) do
				for cz = math.floor(math.min(w[2], w[4]) / CELL), math.floor(math.max(w[2], w[4]) / CELL) do
					local k = cellKey(floor, cx, cz)
					local bucket = index.Grid[k]
					local at = table.find(bucket, id) :: number
					bucket[at] = bucket[#bucket]
					bucket[#bucket] = nil
					if #bucket == 0 then
						index.Grid[k] = nil
					end
				end
			end
			table.insert(index.Free, id)
		end
		index.TileWalls[tile] = nil
	end
	return removed
end

--[=[
	@within NavMeshClearance
	Clearance for an `Update` commit. `n` is the new state and `mesh` the caller's (still the old
	state; `n` is swapped into it afterwards). `dirty` are the rebuilt tiles and `near` their
	clean neighbours; `recompute` holds the rebuilt triangles that match no old one.

	Swaps the rebuilt tiles' walls in `mesh`'s wall index (built from the old state first if the
	mesh has none, as after a load) and flags wall vertices of the rebuilt tiles and their
	neighbours. Every triangle within its own reach of a changed wall then joins `recompute`
	(tiles are culled first by their largest width), and those widths are computed. Returns the
	tiles the reach test added triangles from (the dirty tiles are the caller's to add). It must be the commit's last step that can fail: an error
	after it would leave the index ahead of the mesh.
]=]
function Clearance.Refresh(
	mesh: Storage.State,
	n: Storage.State,
	dirty: { number },
	near: { number },
	recompute: { [number]: boolean }
): { [number]: boolean }
	local index = indexes[mesh] or buildIndex(mesh, false)
	local reaches = tileReaches[mesh] or {}
	lastAround[mesh] = nil
	local touched: { [number]: boolean } = {}

	-- Changed walls: in the old walls of the rebuilt tiles or in the new ones, not both.
	local old = removeWalls(index, dirty)
	local changed: { { number } } = {} -- floor, x1, z1, x2, z2
	for _, tile in dirty do
		local first, count = Storage.GetTileRange(n, tile)
		local added: { Seg } = {}
		addWalls(index, n, first, first + count - 1, true, added)
		local floor = Storage.GetTileFloor(n, tile)
		for _, w in added do
			local k = `{floor}:{w[1]},{w[2]},{w[3]},{w[4]}`
			if old[k] then
				old[k] = nil
			else
				table.insert(changed, { floor, w[1], w[2], w[3], w[4] })
			end
		end
	end
	for _, c in old do
		table.insert(changed, c)
	end
	-- A neighbour's walls are unchanged, but a vertex it shares with a rebuilt tile had its flag
	-- cleared by the caller: flag it again from the neighbour's own walls.
	for _, tile in near do
		local first, count = Storage.GetTileRange(n, tile)
		for t = first, first + count - 1 do
			local verts = { Storage.GetTriangle(n, t) }
			for e = 1, 3 do
				if Storage.IsWallEdge(n, t, e) then
					Storage.SetWallVertex(n, verts[e % 3 + 1], true)
					Storage.SetWallVertex(n, verts[(e + 1) % 3 + 1], true)
				end
			end
		end
	end

	-- Reach: every triangle within half its largest width of a changed wall. Box gaps are lower
	-- bounds on the distances, so nothing that might change is skipped.
	local boxes: { [number]: { number } } = {} -- per floor: the changed walls' bounding box
	for _, c in changed do
		local b = boxes[c[1]] or { math.huge, math.huge, -math.huge, -math.huge }
		boxes[c[1]] = b
		b[1], b[2] = math.min(b[1], c[2], c[4]), math.min(b[2], c[3], c[5])
		b[3], b[4] = math.max(b[3], c[2], c[4]), math.max(b[4], c[3], c[5])
	end
	for tile = 1, Storage.TileCount(n) do
		local floor = Storage.GetTileFloor(n, tile)
		local b = boxes[floor]
		if b == nil then
			continue
		end
		local reach = reaches[tile]
		if reach == nil then
			reach = tileReach(n, tile)
			reaches[tile] = reach
		end
		local x0, z0, x1, z1 = Storage.GetTileBounds(n, tile)
		if boxGap(x0, z0, x1, z1, b[1], b[2], b[3], b[4]) > reach / 2 then
			continue
		end
		local first, count = Storage.GetTileRange(n, tile)
		for t = first, first + count - 1 do
			if recompute[t] then
				continue
			end
			local r = 0
			for k = 1, 3 do
				r = math.max(r, Storage.GetCornerWidth(n, t, k), Storage.GetPortalWidth(n, t, k))
			end
			local va, vb, vc = Storage.GetTriangle(n, t)
			local pa, pb, pc = Storage.GetVertex(n, va), Storage.GetVertex(n, vb), Storage.GetVertex(n, vc)
			local tx0, tx1 = math.min(pa.X, pb.X, pc.X), math.max(pa.X, pb.X, pc.X)
			local tz0, tz1 = math.min(pa.Z, pb.Z, pc.Z), math.max(pa.Z, pb.Z, pc.Z)
			for _, c in changed do
				local cx0, cx1 = math.min(c[2], c[4]), math.max(c[2], c[4])
				local cz0, cz1 = math.min(c[3], c[5]), math.max(c[3], c[5])
				if c[1] == floor and boxGap(tx0, tz0, tx1, tz1, cx0, cz0, cx1, cz1) <= r / 2 then
					recompute[t] = true
					touched[tile] = true
					break
				end
			end
		end
	end
	computeWidths(n, Storage.GetMaxAgentRadius(n), recompute, index)
	-- Widths changed in these tiles: their bounds are measured again when next needed.
	for _, tile in dirty do
		reaches[tile] = nil
	end
	for tile in touched do
		reaches[tile] = nil
	end
	indexes[mesh] = index
	tileReaches[mesh] = reaches
	return touched
end

-- Even-odd test: whether (x, z) is inside the closed polygon `poly` (flat x, z pairs).
local function inside(poly: { number }, x: number, z: number): boolean
	local odd = false
	local n = #poly // 2
	local j = n
	for i = 1, n do
		local xi, zi, xj, zj = poly[2 * i - 1], poly[2 * i], poly[2 * j - 1], poly[2 * j]
		if (zi > z) ~= (zj > z) and x < (xj - xi) * (z - zi) / (zj - zi) + xi then
			odd = not odd
		end
		j = i
	end
	return odd
end

-- The one edge of a triangle (its `edges`) that (x, z) lies beyond, 0 when inside, or -1 when
-- beyond two (past a vertex).
local function beyond(edges: Region, x: number, z: number): number
	local found = 0
	for e = 1, 3 do
		local ed, o = edges[e], edges[(e + 1) % 3 + 1] -- o starts at vertex e
		if cross(ed[1], ed[2], ed[3], ed[4], x, z) * cross(ed[1], ed[2], ed[3], ed[4], o[1], o[2]) < 0 then
			if found ~= 0 then
				return -1
			end
			found = e
		end
	end
	return found
end

-- Triangle t's edges (edge e opposite vertex e, CCW), which of them are walls, the walls within
-- r of it, and the record holding them: [4] the CutOff / Separated verdicts asked there, [5]
-- their count. Records are kept per mesh, triangle and radius (a search asks about a triangle
-- once per exit edge and link, and E3's landing checks repeat on every query at one radius: a
-- game has a few agent sizes), until the walls change (Refresh drops them).
-- ponytail: dropped wholesale at AROUND_CAP records; an LRU if huge maps thrash it.
local AROUND_CAP = 32768
local function around(s: Storage.State, t: number, r: number): (Region, { boolean }, { Seg }, { any })
	local memo = lastAround[s]
	if memo == nil or memo.n >= AROUND_CAP then
		memo = { n = 0 }
		lastAround[s] = memo
	end
	local key = string.format("%d %.17g", t, r)
	local rec = memo[key]
	if rec then
		return rec[1], rec[2], rec[3], rec
	end
	local index = indexes[s] or buildIndex(s, false)
	indexes[s] = index
	local P = {}
	for i, v in { Storage.GetTriangle(s, t) } do
		P[i] = Storage.GetVertex(s, v)
	end
	local edges: Region = {}
	for e = 1, 3 do
		local u, v = P[e % 3 + 1], P[(e + 1) % 3 + 1]
		edges[e] = { u.X, u.Z, v.X, v.Z }
	end
	local walls = { Storage.IsWallEdge(s, t, 1), Storage.IsWallEdge(s, t, 2), Storage.IsWallEdge(s, t, 3) }
	local feats = nearWalls(index, Storage.GetTriangleFloor(s, t), edges, r)
	rec = { edges, walls, feats, {}, 0 }
	memo[key] = rec
	memo.n += 1
	return edges, walls, feats, rec
end

-- Whether the segment (ax, az)-(bx, bz) keeps at least r from every wall in `feats`.
local function clear(feats: { Seg }, r: number, ax: number, az: number, bx: number, bz: number): boolean
	local seg = { ax, az, bx, bz }
	for _, f in feats do
		if segSeg(seg, f) < r then
			return false
		end
	end
	return true
end

-- Where an agent of radius r at (x, z) stands once pushed straight out of its nearest wall to
-- r, or nil when that is still inside a disc, or it touches the wall (its side of a barrier is
-- then unknown). An end already clear stays put. `feats` must hold every wall within r of the
-- end's triangle, which the end is in: a pushed point outside the triangle is inside no barrier.
local function standing(feats: { Seg }, r: number, x: number, z: number): (number?, number?)
	local best, bx, bz = math.huge, x, z
	for _, f in feats do
		local qx, qz = nearestOn(x, z, f)
		local d = math.sqrt((qx - x) ^ 2 + (qz - z) ^ 2)
		if d < best then
			best, bx, bz = d, qx, qz
		end
	end
	if best >= r then
		return x, z
	elseif best == 0 then
		return nil, nil
	end
	local px, pz = bx + (x - bx) * r / best, bz + (z - bz) * r / best
	for _, f in feats do
		if pointSeg(px, pz, f) < r * (1 - 1e-9) then
			return nil, nil
		end
	end
	return px, pz
end

--[[
	Barriers inside a triangle at radius r (ticket 27). The cut discs (open radius-r discs
	around the walls in `feats`, cut to the triangle) fall into components, joined where two
	link inside the triangle (Chain's link rule). A component that touches the boundary path
	`arc` (a list of consecutive edges) at two places gives a closed polygon: a covered polyline
	through the component between the two contacts, closed along `arc` between them. Every piece
	of the polyline lies in one cut disc, so no agent centre of radius r crosses it inside the
	triangle, and the rest of the polygon is that part of `arc`.
	- Contacts are the triangle's vertices, and on a wall edge also the point nearest the wall,
	  when nearer than r (an agent may touch a wall, as widths let it: a width of exactly 2r
	  passes). A barrier ending inside a crossable edge doesn't close: the agent can step round
	  its end into the neighbour and back across the same edge, which no corridor can hold;
	  round a vertex it passes other triangles, which a corridor can;
	- consecutive polyline points (a contact, then link points, then a contact) share a disc.
	Per component, the pair is its first and last contact along `arc`.
	With `pq` (Separated: `arc` is the whole boundary, which has no first) it returns instead
	whether some pair of contacts at different points gives a polygon holding exactly one of the
	points P and Q. Each pair's polyline runs through the component's breadth-first tree from
	its first wall, so the polygon holds one of them when the segment PQ crosses that polyline
	an odd number of times; PQ crosses the path from a contact to a fixed point Z of the root's
	disc with parity par(contact), and a pair's polyline (the two paths joined at Z, the shared
	part crossed twice) with par(a) xor par(b). So one parity per contact, not a polygon per
	pair (E3: Separated ran per link start, and the pairs were O(contacts^2) polygons). Two
	contacts at one point count too: their polyline is a closed covered loop.
	ponytail: one path per pair; a pocket that a loop inside a component closes is missed (a
	missed block, never a false one).
]]
local function barriers(
	edges: Region,
	walls: { boolean },
	feats: { Seg },
	r: number,
	arc: { number },
	pq: Seg?
): ({ { number } }, boolean)
	local m = #feats
	-- Contacts: position along the arc (edge slot - 1 + u), point and wall, in wall order.
	local at, atX, atZ, of = {}, {}, {}, {}
	local touches = table.create(m, false)
	for i, f in feats do
		for slot, j in arc do
			local edge = edges[j]
			for _, u in if walls[j] then { 0, 1, nearestParam(edge, f) } else { 0, 1 } do
				local x, z = edge[1] + u * (edge[3] - edge[1]), edge[2] + u * (edge[4] - edge[2])
				if pointSeg(x, z, f) < r then
					table.insert(at, slot - 1 + u)
					table.insert(atX, x)
					table.insert(atZ, z)
					table.insert(of, i)
					touches[i] = true
				end
			end
		end
	end
	local links: { [number]: { number } } = {} -- i * (m + 1) + j -> { cost, x, z }
	local function link(i: number, j: number): { number }
		local k = if i < j then i * (m + 1) + j else j * (m + 1) + i
		local l = links[k]
		if l == nil then
			-- Two discs can't meet before r = d(f, g) / 2.
			l = if segSeg(feats[i], feats[j]) >= 2 * r then { math.huge } else { linkCost(edges, feats[i], feats[j]) }
			links[k] = l
		end
		return l
	end
	-- The polygon for contacts a and b (at[a] < at[b]): contact b, the link points back through
	-- the component to a's wall (breadth first from it), contact a, then the arc's vertices
	-- between the two.
	local function polygon(members: { number }, a: number, b: number): { number }
		local from, to = of[a], of[b]
		local parent: { [number]: number } = { [from] = 0 }
		local queue = { from }
		local head = 1
		while parent[to] == nil do
			local i = queue[head]
			head += 1
			for _, j in members do
				if parent[j] == nil and link(i, j)[1] < r then
					parent[j] = i
					table.insert(queue, j)
				end
			end
		end
		local poly = { atX[b], atZ[b] }
		local i = to
		while parent[i] ~= 0 do
			local l = link(i, parent[i])
			table.insert(poly, l[2])
			table.insert(poly, l[3])
			i = parent[i]
		end
		table.insert(poly, atX[a])
		table.insert(poly, atZ[a])
		for slot = 1, #arc - 1 do
			if at[a] < slot and slot < at[b] then
				local edge = edges[arc[slot]]
				table.insert(poly, edge[3])
				table.insert(poly, edge[4])
			end
		end
		return poly
	end
	-- Components, breadth first from each wall with a contact not yet reached (one without a
	-- contact bounds nothing).
	local component = table.create(m, 0)
	local out = {}
	for root = 1, m do
		if component[root] ~= 0 or not touches[root] then
			continue
		end
		local members = { root }
		local up = { [root] = 0 } -- the breadth-first tree, for `pq`
		component[root] = root
		local head = 1
		while head <= #members do
			local i = members[head]
			head += 1
			for j = 1, m do
				if component[j] == 0 and link(i, j)[1] < r then
					component[j] = root
					up[j] = i
					table.insert(members, j)
				end
			end
		end
		local mine = {}
		for c = 1, #at do
			if component[of[c]] == root then
				table.insert(mine, c)
			end
		end
		if pq then
			-- Z: the component's first contact, which is on the root (contacts are gathered in
			-- wall order, and the root is its first wall with one). first[i]: the first point of
			-- the path from wall i to Z; par[i]: PQ's crossing parity with that path.
			local zx, zz = atX[mine[1]], atZ[mine[1]]
			local firstX, firstZ, par = { [root] = zx }, { [root] = zz }, { [root] = false }
			local function odd(ax: number, az: number, bx: number, bz: number): boolean
				return (crosses(pq, { ax, az, bx, bz }))
			end
			for k = 2, #members do -- parents come first in breadth-first order
				local i = members[k]
				local l = link(i, up[i])
				firstX[i], firstZ[i] = l[2], l[3]
				par[i] = par[up[i]] ~= odd(l[2], l[3], firstX[up[i]], firstZ[up[i]])
			end
			-- Two contacts of different parity part P and Q. Two at one point give a closed loop
			-- of covered pieces (no arc), which parts them too.
			local has = {}
			for _, c in mine do
				has[par[of[c]] ~= odd(atX[c], atZ[c], firstX[of[c]], firstZ[of[c]])] = true
			end
			if has[true] and has[false] then
				return out, true
			end
			continue
		end
		table.sort(mine, function(a: number, b: number): boolean
			return at[a] < at[b]
		end)
		if #mine >= 2 and at[mine[#mine]] > at[mine[1]] then
			table.insert(out, polygon(members, mine[1], mine[#mine]))
		end
	end
	return out, false
end

--[[
	Clearance.CutOff, unremembered. A straight clear line to a point of `e` proves the point is
	not cut off. Otherwise each barrier (see `barriers`) along the other two edges closes a
	polygon that holds no point of `e` but its ends; a point inside it (odd crossings) can reach
	`e` only across the barrier. So the test is sound: it never cuts off a point that can pass.
	It can miss a block.
]]
local function cutOffNow(s: Storage.State, t: number, e: number, r: number, px: number, pz: number): boolean
	local edges, walls, feats = around(s, t, r)
	local x, z = standing(feats, r, px, pz)
	if x == nil then -- (standing gives both coordinates or neither)
		return false
	end
	local edge = edges[e]
	for _, u in { 0.5, 0.25, 0.75 } do
		if clear(feats, r, x, z :: number, edge[1] + u * (edge[3] - edge[1]), edge[2] + u * (edge[4] - edge[2])) then
			return false
		end
	end
	for _, poly in (barriers(edges, walls, feats, r, { e % 3 + 1, (e + 1) % 3 + 1 })) do
		if inside(poly, x, z :: number) then
			return true
		end
	end
	return false
end

--[[
	Clearance.Separated, unremembered. A clear straight line proves the points are not parted;
	otherwise they are when their crossing parities differ for some barrier along the whole
	boundary (the two polygons one barrier closes, either way round, differ by the whole
	triangle).
]]
local function separatedNow(
	s: Storage.State,
	t: number,
	r: number,
	px: number,
	pz: number,
	qx: number,
	qz: number
): boolean
	local edges, walls, feats = around(s, t, r)
	local ax, az = standing(feats, r, px, pz)
	local bx, bz = standing(feats, r, qx, qz)
	if ax == nil or bx == nil then -- (standing gives both coordinates or neither)
		return false
	end
	local ay, by = az :: number, bz :: number
	if clear(feats, r, ax, ay, bx, by) then
		return false
	end
	-- A point pushed out of the triangle (off a wall of a thin one) is inside no barrier, so its
	-- parity says nothing (E3: a link's start against a wall). Over one crossable edge it stands
	-- just past that edge, so the other is parted from it when cut off from that edge; past a
	-- vertex (or both out) its side is unknown, and they are not parted.
	local ea, eb = beyond(edges, ax, ay), beyond(edges, bx, by)
	if ea ~= 0 or eb ~= 0 then
		if ea < 0 or eb < 0 or (ea > 0 and eb > 0) then
			return false
		end
		local e = math.max(ea, eb)
		return not walls[e]
			and if ea > 0 then Clearance.CutOff(s, t, e, r, qx, qz) else Clearance.CutOff(s, t, e, r, px, pz)
	end
	local _, parted = barriers(edges, walls, feats, r, { 1, 2, 3 }, { ax, ay, bx, by })
	return parted
end

-- Keeps a verdict in triangle t's record at radius r (see `around`; E3: a search with links asks
-- the same landing and link-start questions on every query at one radius).
-- ponytail: the record's verdicts are dropped at VERDICT_CAP; an LRU if a triangle gets many.
local VERDICT_CAP = 256
local function remember(rec: { any }, key: string, verdict: boolean): boolean
	if rec[5] >= VERDICT_CAP then
		table.clear(rec[4])
		rec[5] = 0
	end
	rec[4][key] = verdict
	rec[5] += 1
	return verdict
end

--[=[
	@within NavMeshClearance
	Whether an agent of radius `r` at point (x, z) of triangle `t` is cut off from its edge `e`
	inside `t` (ticket 27): found at query time, not stored in the mesh (remembered per triangle
	and radius until the walls change). Sound: it never cuts off a point that can pass. It can
	miss a block.
]=]
function Clearance.CutOff(s: Storage.State, t: number, e: number, r: number, px: number, pz: number): boolean
	local _, _, _, rec = around(s, t, r)
	local key = string.format("%d %.17g %.17g", e, px, pz)
	local known = rec[4][key]
	if known ~= nil then
		return known
	end
	return remember(rec, key, cutOffNow(s, t, e, r, px, pz))
end

--[=[
	@within NavMeshClearance
	Whether two points of triangle `t` are parted inside it for an agent of radius `r` (ticket
	27, start and goal in one triangle; E3, a link's landing and another link's start).
]=]
function Clearance.Separated(
	s: Storage.State,
	t: number,
	r: number,
	px: number,
	pz: number,
	qx: number,
	qz: number
): boolean
	local _, _, _, rec = around(s, t, r)
	local key = string.format("s %.17g %.17g %.17g %.17g", px, pz, qx, qz)
	local known = rec[4][key]
	if known ~= nil then
		return known
	end
	return remember(rec, key, separatedNow(s, t, r, px, pz, qx, qz))
end

return Clearance
