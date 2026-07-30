--!strict
--!native

--[=[
	Triangle topology helpers, shared constants, and index utilities.

	Triangle vertex / neighbor slot layout (CCW winding, 1-indexed):

	        v[3]
	        /\
	    n[3]/  \n[2]
	       /    \
	      /______\
	    v[1]  n[1]  v[2]

	Neighbor[i] is across from the vertex at slot opoVrt(i):
	  n[1]  across edge v[1]–v[2]   (opposite v[3])
	  n[2]  across edge v[2]–v[3]   (opposite v[1])
	  n[3]  across edge v[3]–v[1]   (opposite v[2])

	Equivalently: vertex[i] is opposite neighbor[opoNbr(i)] where opoNbr = ccw.
]=]

-- 0 is never a valid 1-based vertex or triangle index; used as sentinel.
local NO_VERTEX: number = 0
local NO_NEIGHBOR: number = 0

-- The first three vertices added to every triangulation are the
-- super-triangle vertices.
local N_SUPER_VERTS: number = 3

-- Multiplier for integer edge keys.
-- Supports up to 2^22 ≈ 4 million vertices per triangulation;
-- maximum key ≈ 2^44, safely within the 2^53 integer precision of doubles.
local EDGE_KEY_SHIFT: number = 4194304 -- 2^22

-- Triangle type: three vertex indices and three neighbor triangle indices.
-- All indices are 1-based.
export type Triangle = {
	vertices: { number }, -- [3] vertex indices
	neighbors: { number }, -- [3] neighboring triangle indices
}

local function newTriangle(): Triangle
	return {
		vertices = { NO_VERTEX, NO_VERTEX, NO_VERTEX },
		neighbors = { NO_NEIGHBOR, NO_NEIGHBOR, NO_NEIGHBOR },
	}
end

local function makeTriangle(v1: number, v2: number, v3: number, n1: number, n2: number, n3: number): Triangle
	return {
		vertices = { v1, v2, v3 },
		neighbors = { n1, n2, n3 },
	}
end

-- ccw(i): advance one slot counter-clockwise.
-- 1 → 2,  2 → 3,  3 → 1
local function ccw(i: number): number
	return (i % 3) + 1
end

-- cw(i): advance one slot clockwise.
-- 1 → 3,  2 → 1,  3 → 2
local function cw(i: number): number
	return ((i + 1) % 3) + 1
end

-- opoNbr(vSlot): vertex slot → opposite neighbor slot (identical to ccw).
-- vertex[i] is opposite to neighbor[(i%3)+1]:
--   v[1] → n[2],  v[2] → n[3],  v[3] → n[1]
local function opoNbr(i: number): number
	return (i % 3) + 1
end

-- opoVrt(nSlot): neighbor slot → opposite vertex slot.
-- n[1] → v[3],  n[2] → v[1],  n[3] → v[2]
local function opoVrt(i: number): number
	if i == 1 then
		return 3
	end
	if i == 2 then
		return 1
	end
	return 2
end

-- opposedTriangleInd: which neighbor slot lies across from vertex iVert?
-- Equivalent to opoNbr(vertexInd(vv, iVert)).
local function opposedTriangleInd(vv: { number }, iVert: number): number
	if vv[1] == iVert then
		return 2
	end
	if vv[2] == iVert then
		return 3
	end
	return 1
end

-- opposedVertexInd: which vertex slot lies across from neighbor triangle iTopo?
-- Equivalent to opoVrt(slot where nn == iTopo).
local function opposedVertexInd(nn: { number }, iTopo: number): number
	if nn[1] == iTopo then
		return 3
	end
	if nn[2] == iTopo then
		return 1
	end
	return 2
end

-- edgeNeighborInd: which neighbor slot is shared by the edge between iV1 and iV2?
--   edge v[1]–v[2] → n[1]
--   edge v[2]–v[3] → n[2]
--   edge v[3]–v[1] → n[3]
local function edgeNeighborInd(vv: { number }, iV1: number, iV2: number): number
	if vv[1] == iV1 or vv[1] == iV2 then
		if vv[2] == iV1 or vv[2] == iV2 then
			return 1 -- edge v[1]–v[2] → n[1]
		end
		return 3 -- edge v[1]–v[3] → n[3]
	end
	return 2 -- edge v[2]–v[3] → n[2]
end

-- vertexInd: which slot (1, 2, or 3) does vertex iV occupy in triangle vv?
local function vertexInd(vv: { number }, iV: number): number
	if vv[1] == iV then
		return 1
	end
	if vv[2] == iV then
		return 2
	end
	return 3
end

-- edgeKey: canonical integer key for an undirected edge (iA, iB).
-- Always encodes as  min * EDGE_KEY_SHIFT + max.
local function edgeKey(a: number, b: number): number
	if a < b then
		return a * EDGE_KEY_SHIFT + b
	end
	return b * EDGE_KEY_SHIFT + a
end

-- touchesSuperTriangle: true if any of the triangle's vertices is a
-- super-triangle vertex (indices 1–3).
local function touchesSuperTriangle(t: Triangle): boolean
	return t.vertices[1] <= N_SUPER_VERTS or t.vertices[2] <= N_SUPER_VERTS or t.vertices[3] <= N_SUPER_VERTS
end

-- triContainsVertex: true if triangle holds vertex iV in any slot.
local function triContainsVertex(t: Triangle, iV: number): boolean
	return t.vertices[1] == iV or t.vertices[2] == iV or t.vertices[3] == iV
end

-- ── Navigation helpers ────────────────────────────────────────────────────────

-- nextTriAndVert: advance one CCW step around vertex iV from triangle t.
-- Returns (neighborTriIndex, nextVertexIndex).
-- Mirrors CDT C++ Triangle::next(v).
local function nextTriAndVert(t: Triangle, iV: number): (number, number)
	local s = vertexInd(t.vertices, iV)
	return t.neighbors[s], t.vertices[ccw(s)]
end

-- opposedTri: the triangle across from vertex iV in triangle t.
local function opposedTri(t: Triangle, iV: number): number
	return t.neighbors[opposedTriangleInd(t.vertices, iV)]
end

-- opposedVert: the vertex across from neighbor iTopo in triangle t.
local function opposedVert(t: Triangle, iTopo: number): number
	return t.vertices[opposedVertexInd(t.neighbors, iTopo)]
end

-- edgeNbr: the neighbor across the edge (v1, v2) in triangle t.
local function edgeNbr(t: Triangle, v1: number, v2: number): number
	return t.neighbors[edgeNeighborInd(t.vertices, v1, v2)]
end

-- changeNeighborByEdge: update the neighbor of t on the shared edge (iV1, iV2) to newN.
-- Corresponds to CDT C++ changeNeighbor(iT, v1, v2, newN).
local function changeNeighborByEdge(t: Triangle, iV1: number, iV2: number, newN: number)
	t.neighbors[edgeNeighborInd(t.vertices, iV1, iV2)] = newN
end

-- ── Generic list helpers ──────────────────────────────────────────────────────

-- insertUnique: append val to list only when it is not already present.
local function insertUnique(list: { number }, val: number)
	for _, v in list do
		if v == val then
			return
		end
	end
	table.insert(list, val)
end

-- insertUniqueList: append each value from src to dst, skipping duplicates.
local function insertUniqueList(dst: { number }, src: { number })
	for _, v in src do
		insertUnique(dst, v)
	end
end

return {
	NO_VERTEX = NO_VERTEX,
	NO_NEIGHBOR = NO_NEIGHBOR,
	N_SUPER_VERTS = N_SUPER_VERTS,
	EDGE_KEY_SHIFT = EDGE_KEY_SHIFT,

	newTriangle = newTriangle,
	makeTriangle = makeTriangle,

	ccw = ccw,
	cw = cw,
	opoNbr = opoNbr,
	opoVrt = opoVrt,

	opposedTriangleInd = opposedTriangleInd,
	opposedVertexInd = opposedVertexInd,
	edgeNeighborInd = edgeNeighborInd,
	vertexInd = vertexInd,

	edgeKey = edgeKey,
	touchesSuperTriangle = touchesSuperTriangle,
	triContainsVertex = triContainsVertex,

	nextTriAndVert = nextTriAndVert,
	opposedTri = opposedTri,
	opposedVert = opposedVert,
	edgeNbr = edgeNbr,
	changeNeighborByEdge = changeNeighborByEdge,

	insertUnique = insertUnique,
	insertUniqueList = insertUniqueList,
}
