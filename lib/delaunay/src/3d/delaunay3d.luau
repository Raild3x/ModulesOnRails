--!strict
-- Authors: Logan Hunt (Raildex)
-- Revised: May 2026
-- Reference: CGAL Delaunay_triangulation_3.h (GPL-3.0-or-later / LicenseRef-Commercial)
--[=[
	@class Delaunay3d

	A 3D [Delaunay Triangulation](https://en.wikipedia.org/wiki/Delaunay_triangulation)
	implemented via the incremental **Bowyer–Watson** algorithm, following the algorithmic
	approach of CGAL's `Delaunay_triangulation_3`.

	The key correctness invariant is the *orient × insphere* predicate:

	```
	circumSphereContains(A,B,C,D, P)
	    ⟺  inSphere(A,B,C,D,P) * orient3d(A,B,C,D)  <  0
	```

	Both sub-predicates are computed in the translated frame of the query point `P`
	(i.e. rows `A-P, B-P, C-P, D-P`) which minimises catastrophic cancellation without
	requiring exact/multi-precision arithmetic.

	### Usage
	```lua
	local Delaunay3d = require(path.to.Delaunay3d)

	local vertices = {
	    Vector3.new(0,  0,  0),
	    Vector3.new(10, 0,  0),
	    Vector3.new(5,  10, 0),
	    Vector3.new(5,  5,  10),
	}

	local result = Delaunay3d.Triangulate(vertices)
	print(#result.Tetrahedra) -- number of tetrahedra
	print(#result.Triangles)  -- number of unique triangular faces
	print(#result.Edges)      -- number of unique edges
	```
]=]

--------------------------------------------------------------------------------
--// Types //--
--------------------------------------------------------------------------------

--- A tetrahedron produced by the triangulation.
export type Tetrahedron = { Vector3 }

--- A triangular face produced by the triangulation.
export type Triangle = { Vector3 }

--- An edge produced by the triangulation.
export type Edge = { Vector3 }

--- The result returned by `Delaunay3d.Triangulate`.
export type TriangulationResult = {
	Vertices: { Vector3 },
	Tetrahedra: { Tetrahedron },
	Triangles: { Triangle },
	Edges: { Edge },
}

--- Public interface of a Delaunay3d instance.
export type Delaunay3dObject = {
	-- Mutation
	AddPoint: (self: Delaunay3dObject, point: Vector3, id: string?) -> string,
	RemovePoint: (self: Delaunay3dObject, id: string) -> (),
	MovePoint: (self: Delaunay3dObject, id: string, newPosition: Vector3) -> (),
	Clear: (self: Delaunay3dObject) -> (),

	-- Bulk accessors (allocate new tables)
	GetVertices: (self: Delaunay3dObject) -> { Vector3 },
	GetEdges: (self: Delaunay3dObject) -> { Edge },
	GetTriangles: (self: Delaunay3dObject) -> { Triangle },
	GetTetrahedrons: (self: Delaunay3dObject) -> { Tetrahedron },
	GetHullVertices: (self: Delaunay3dObject) -> { Vector3 },
	GetHullEdges: (self: Delaunay3dObject) -> { Edge },
	GetHullTriangles: (self: Delaunay3dObject) -> { Triangle },

	-- Zero-alloc iterators
	-- Usage:  for u, v in self:ForEachEdge() do ... end
	ForEachEdge: (self: Delaunay3dObject) -> () -> (Vector3, Vector3),
	ForEachTriangle: (self: Delaunay3dObject) -> () -> (Vector3, Vector3, Vector3),
	ForEachTetrahedron: (self: Delaunay3dObject) -> () -> (Vector3, Vector3, Vector3, Vector3),

	-- Queries
	GetAdjacentVertices: (self: Delaunay3dObject, id: string) -> { Vector3 },
	GetTetrahedronsContaining: (self: Delaunay3dObject, point: Vector3) -> { Tetrahedron },
}

--------------------------------------------------------------------------------
--// Geometric Predicates //--
--------------------------------------------------------------------------------

-- 3×3 determinant, Sarrus / cofactor expansion on row 0.
local function det3(
	a: number,
	b: number,
	c: number,
	d: number,
	e: number,
	f: number,
	g: number,
	h: number,
	i: number
): number
	return a * (e * i - f * h) - b * (d * i - f * g) + c * (d * h - e * g)
end

-- 4×4 determinant, Laplace expansion along row 0.
local function det4(
	a00: number,
	a01: number,
	a02: number,
	a03: number,
	a10: number,
	a11: number,
	a12: number,
	a13: number,
	a20: number,
	a21: number,
	a22: number,
	a23: number,
	a30: number,
	a31: number,
	a32: number,
	a33: number
): number
	return a00 * det3(a11, a12, a13, a21, a22, a23, a31, a32, a33)
		- a01 * det3(a10, a12, a13, a20, a22, a23, a30, a32, a33)
		+ a02 * det3(a10, a11, a13, a20, a21, a23, a30, a31, a33)
		- a03 * det3(a10, a11, a12, a20, a21, a22, a30, a31, a32)
end

--[[
	orient3d(A, B, C, D)

	Returns the signed volume of tetrahedron ABCD (up to a positive constant factor):
	  > 0  →  D lies on the positive (CCW-when-viewed-from-above) side of plane ABC.
	  < 0  →  D lies on the negative side.
	  = 0  →  A, B, C, D are coplanar (degenerate tetrahedron).

	Definition:  det3( B-A, C-A, D-A )
	This matches the Shewchuk / CGAL orient3d sign convention.
]]
local function orient3d(a: Vector3, b: Vector3, c: Vector3, d: Vector3): number
	return det3(b.X - a.X, b.Y - a.Y, b.Z - a.Z, c.X - a.X, c.Y - a.Y, c.Z - a.Z, d.X - a.X, d.Y - a.Y, d.Z - a.Z)
end

--[[
	inSphereRaw(A, B, C, D, P)

	Evaluates Shewchuk's 4×4 in-sphere determinant in the translated frame of P:
	  rows are  (A-P, |A-P|²),  (B-P, |B-P|²),  (C-P, |C-P|²),  (D-P, |D-P|²).

	Semantics (verified numerically):
	  For *positively-oriented* ABCD:  < 0 iff P lies strictly inside the circumsphere.
	  For *negatively-oriented* ABCD:  the sign is flipped.

	→  Always combine with orient3d to obtain an orientation-independent result:
	       circumSphereContains ⟺  inSphereRaw * orient3d < 0
]]
local function inSphereRaw(a: Vector3, b: Vector3, c: Vector3, d: Vector3, p: Vector3): number
	local ax, ay, az = a.X - p.X, a.Y - p.Y, a.Z - p.Z
	local bx, by, bz = b.X - p.X, b.Y - p.Y, b.Z - p.Z
	local cx, cy, cz = c.X - p.X, c.Y - p.Y, c.Z - p.Z
	local dx, dy, dz = d.X - p.X, d.Y - p.Y, d.Z - p.Z
	return det4(
		ax,
		ay,
		az,
		ax * ax + ay * ay + az * az,
		bx,
		by,
		bz,
		bx * bx + by * by + bz * bz,
		cx,
		cy,
		cz,
		cx * cx + cy * cy + cz * cz,
		dx,
		dy,
		dz,
		dx * dx + dy * dy + dz * dz
	)
end

--[[
	circumSphereContains(A, B, C, D, P)

	Returns true iff point P lies strictly inside the circumsphere of tetrahedron ABCD.
	Orientation-independent: uses inSphereRaw × orient3d so that the result is the same
	regardless of the winding order of ABCD.
	Returns false for degenerate (coplanar) tetrahedra.
]]
local function circumSphereContains(a: Vector3, b: Vector3, c: Vector3, d: Vector3, p: Vector3): boolean
	local o = orient3d(a, b, c, d)
	if o == 0 then
		return false -- degenerate — no well-defined circumsphere
	end
	return inSphereRaw(a, b, c, d, p) * o < 0
end

--------------------------------------------------------------------------------
--// Hashing Utilities //--
--------------------------------------------------------------------------------

local function v3Key(v: Vector3): string
	return `{v.X},{v.Y},{v.Z}`
end

-- Canonical (permutation-independent) key for a triangular face.
local function _triKey(a: Vector3, b: Vector3, c: Vector3): string
	local ka, kb, kc = v3Key(a), v3Key(b), v3Key(c)
	-- Sort three strings ascending (3-element sort network).
	if ka > kb then
		ka, kb = kb, ka
	end
	if kb > kc then
		kb, kc = kc, kb
	end
	if ka > kb then
		ka, kb = kb, ka
	end
	return `{ka}|{kb}|{kc}`
end

-- Canonical (permutation-independent) key for an edge.
local function _edgeKey(a: Vector3, b: Vector3): string
	local ka, kb = v3Key(a), v3Key(b)
	if ka > kb then
		ka, kb = kb, ka
	end
	return `{ka}|{kb}`
end

--------------------------------------------------------------------------------
--// Numeric Key Canonicalization (Opt#2) //--
--------------------------------------------------------------------------------

--[[
	Fast permutation-independent integer triple comparison.
	Used during Bowyer-Watson insertion (transient vertex pass)
	to eliminate string allocation overhead in cavity detection.
	
	Returns a canonical tuple (ia, ib, ic) where ia <= ib <= ic.
]]
local function canonicalTriKey(ia: number, ib: number, ic: number): (number, number, number)
	-- Sort three integers via min conditional swaps.
	if ia > ib then
		ia, ib = ib, ia
	end
	if ib > ic then
		ib, ic = ic, ib
	end
	if ia > ib then
		ia, ib = ib, ia
	end
	return ia, ib, ic
end

--[[
	Fast permutation-independent integer pair comparison.
	Used during Bowyer-Watson insertion.
	
	Returns a canonical tuple (ia, ib) where ia <= ib.
]]
local function canonicalEdgeKey(ia: number, ib: number): (number, number)
	if ia > ib then
		return ib, ia
	end
	return ia, ib
end

--------------------------------------------------------------------------------
--// Bounding Box + Super-Tetrahedron //--
--------------------------------------------------------------------------------

--[[
	Computes the AABB centre and half-spread   M = max(rangeX, rangeY, rangeZ) / 2
	of a non-empty point set.
	M is the radius of the smallest axis-aligned cube centred at `centre` that
	contains all input points.
]]
local function computeBounds(verts: { Vector3 }): (Vector3, number)
	local minX, minY, minZ = verts[1].X, verts[1].Y, verts[1].Z
	local maxX, maxY, maxZ = minX, minY, minZ
	for i = 2, #verts do
		local v = verts[i]
		if v.X < minX then
			minX = v.X
		elseif v.X > maxX then
			maxX = v.X
		end
		if v.Y < minY then
			minY = v.Y
		elseif v.Y > maxY then
			maxY = v.Y
		end
		if v.Z < minZ then
			minZ = v.Z
		elseif v.Z > maxZ then
			maxZ = v.Z
		end
	end
	local spread = math.max(maxX - minX, maxY - minY, maxZ - minZ) * 0.5
	if spread < 1e-9 then
		spread = 1
	end
	return Vector3.new((minX + maxX) * 0.5, (minY + maxY) * 0.5, (minZ + maxZ) * 0.5), spread
end

--[[
	makeSuperTetrahedron(centre, M)

	Constructs a super-tetrahedron that strictly contains the axis-aligned cube
	[-M, M]³ around `centre`.

	Vertex pattern: centre + s · { (+1,+1,+1), (-1,-1,+1), (-1,+1,-1), (+1,-1,-1) }
	This is the regular tetrahedron with even-parity sign combinations.

	The four half-space constraints for this tetrahedron are:
	    x + y + z  ≥  −s        (opposite to vertex (+1,+1,+1))
	    x + y − z  ≤   s        (opposite to vertex (-1,-1,+1))
	    x − y + z  ≤   s        (opposite to vertex (-1,+1,-1))
	   −x + y + z  ≤   s        (opposite to vertex (+1,-1,-1))

	Any point with |px|,|py|,|pz| ≤ M satisfies all four if  s ≥ 3M.
	We use  s = 1000M  for a comfortable geometric margin.
]]
local function makeSuperTetrahedron(centre: Vector3, M: number): (Vector3, Vector3, Vector3, Vector3)
	local s = M * 1000
	return centre + Vector3.new(s, s, s),
		centre + Vector3.new(-s, -s, s),
		centre + Vector3.new(-s, s, -s),
		centre + Vector3.new(s, -s, -s)
end

local function appendFlatTetrahedron(flat: { Vector3 }, a: Vector3, b: Vector3, c: Vector3, d: Vector3)
	local ti = #flat
	flat[ti + 1] = a
	flat[ti + 2] = b
	flat[ti + 3] = c
	flat[ti + 4] = d
end

local function appendFlatEdge(flat: { Vector3 }, u: Vector3, v: Vector3)
	local ei = #flat
	flat[ei + 1] = u
	flat[ei + 2] = v
end

type FaceRecord = {
	Count: number,
	Start: number,
}

local function getFaceRecord(
	root: { [number]: { [number]: { [number]: FaceRecord } } },
	ia: number,
	ib: number,
	ic: number
): FaceRecord
	local level2 = root[ia]
	if not level2 then
		level2 = {}
		root[ia] = level2
	end

	local level3 = level2[ib]
	if not level3 then
		level3 = {}
		level2[ib] = level3
	end

	local record = level3[ic]
	if not record then
		record = { Count = 0, Start = 0 }
		level3[ic] = record
	end

	return record
end

local function markTriSeen(
	root: { [number]: { [number]: { [number]: boolean } } },
	ia: number,
	ib: number,
	ic: number
): boolean
	local level2 = root[ia]
	if not level2 then
		level2 = {}
		root[ia] = level2
	end

	local level3 = level2[ib]
	if not level3 then
		level3 = {}
		level2[ib] = level3
	end

	if level3[ic] then
		return false
	end

	level3[ic] = true
	return true
end

local function markEdgeSeen(root: { [number]: { [number]: boolean } }, ia: number, ib: number): boolean
	local level2 = root[ia]
	if not level2 then
		level2 = {}
		root[ia] = level2
	end

	if level2[ib] then
		return false
	end

	level2[ib] = true
	return true
end

local function _buildHullFlatData(flatTets: { Vector3 }): ({ Vector3 }, { Vector3 }, { Vector3 })
	local posToId: { [Vector3]: number } = {}
	local nextId = 0

	local function ensurePosId(pos: Vector3): number
		local id = posToId[pos]
		if id ~= nil then
			return id
		end
		nextId += 1
		posToId[pos] = nextId
		return nextId
	end

	local faceRecords: { [number]: { [number]: { [number]: FaceRecord } } } = {}
	local faceBuffer: { Vector3 } = {}
	local edgeSeen: { [number]: { [number]: boolean } } = {}
	local hullVerticesSeen: { [Vector3]: boolean } = {}
	local hullVertices: { Vector3 } = {}
	local hullTriangles: { Vector3 } = {}
	local hullEdges: { Vector3 } = {}

	local function addHullVertex(v: Vector3)
		if hullVerticesSeen[v] then
			return
		end
		hullVerticesSeen[v] = true
		hullVertices[#hullVertices + 1] = v
	end

	local function addBoundaryFace(u: Vector3, v: Vector3, w: Vector3, iu: number, iv: number, iw: number)
		local ia, ib, ic = canonicalTriKey(iu, iv, iw)
		local record = getFaceRecord(faceRecords, ia, ib, ic)
		record.Count += 1
		if record.Count == 1 then
			local fi = #faceBuffer
			faceBuffer[fi + 1] = u
			faceBuffer[fi + 2] = v
			faceBuffer[fi + 3] = w
			record.Start = fi + 1
		end
	end

	for i = 1, #flatTets, 4 do
		local a, b, c, d = flatTets[i], flatTets[i + 1], flatTets[i + 2], flatTets[i + 3]
		local ida, idb, idc, idd = ensurePosId(a), ensurePosId(b), ensurePosId(c), ensurePosId(d)
		addBoundaryFace(a, b, c, ida, idb, idc)
		addBoundaryFace(a, b, d, ida, idb, idd)
		addBoundaryFace(a, c, d, ida, idc, idd)
		addBoundaryFace(b, c, d, idb, idc, idd)
	end

	local function addHullEdge(u: Vector3, v: Vector3, iu: number, iv: number)
		local ia, ib = canonicalEdgeKey(iu, iv)
		if markEdgeSeen(edgeSeen, ia, ib) then
			appendFlatEdge(hullEdges, u, v)
			addHullVertex(u)
			addHullVertex(v)
		end
	end

	for _, level2 in faceRecords do
		for _, level3 in level2 do
			for _, record in level3 do
				if record.Count == 1 then
					local startIndex = record.Start
					local u, v, w = faceBuffer[startIndex], faceBuffer[startIndex + 1], faceBuffer[startIndex + 2]
					local iu, iv, iw = ensurePosId(u), ensurePosId(v), ensurePosId(w)
					table.move(faceBuffer, startIndex, startIndex + 2, #hullTriangles + 1, hullTriangles)
					addHullEdge(u, v, iu, iv)
					addHullEdge(u, w, iu, iw)
					addHullEdge(v, w, iv, iw)
				end
			end
		end
	end

	return hullVertices, hullTriangles, hullEdges
end

--------------------------------------------------------------------------------
--// Bowyer–Watson Insertion Step //--
--------------------------------------------------------------------------------

--[[
	insertPoint(tets, p)

	Single Bowyer–Watson insertion step:
	  1. Partition `tets` into "bad" (circumsphere contains p) and "good".
	  2. Collect the boundary faces of the conflict cavity (faces shared by exactly
	     one bad tetrahedron — the star-shaped boundary).
	  3. Return the surviving good tetrahedra plus new tetrahedra formed by
	     connecting each boundary face to p.

	Returns a new table; the input `tets` is not mutated.
]]
local function insertPoint(flatTets: { Vector3 }, p: Vector3): { Vector3 }
	-- Opt#2: Build a transient position → integer mapping to enable numeric cavity detection.
	-- This eliminates string allocation in the hot loop (triKey calls).
	local posToId: { [Vector3]: number } = {}
	local nextId = 0

	local function ensurePosId(pos: Vector3): number
		local id = posToId[pos]
		if id ~= nil then
			return id
		end
		nextId += 1
		posToId[pos] = nextId
		return nextId
	end

	-- Use numeric buckets for cavity deduplication.
	local faceRecords: { [number]: { [number]: { [number]: FaceRecord } } } = {}
	local faceBuffer: { Vector3 } = {}
	local result: { Vector3 } = {}

	local function addBoundaryFace(u: Vector3, v: Vector3, w: Vector3, iu: number, iv: number, iw: number)
		local ia, ib, ic = canonicalTriKey(iu, iv, iw)
		local record = getFaceRecord(faceRecords, ia, ib, ic)
		record.Count += 1
		if record.Count == 1 then
			local fi = #faceBuffer
			faceBuffer[fi + 1] = u
			faceBuffer[fi + 2] = v
			faceBuffer[fi + 3] = w
			record.Start = fi + 1
		end
	end

	for i = 1, #flatTets, 4 do
		local a, b, c, d = flatTets[i], flatTets[i + 1], flatTets[i + 2], flatTets[i + 3]
		local ida = ensurePosId(a)
		local idb = ensurePosId(b)
		local idc = ensurePosId(c)
		local idd = ensurePosId(d)
		if circumSphereContains(a, b, c, d, p) then
			-- Bad tet: register its four faces using numeric keys.
			addBoundaryFace(a, b, c, ida, idb, idc)
			addBoundaryFace(a, b, d, ida, idb, idd)
			addBoundaryFace(a, c, d, ida, idc, idd)
			addBoundaryFace(b, c, d, idb, idc, idd)
		else
			-- Good tet: keep as-is.
			appendFlatTetrahedron(result, a, b, c, d)
		end
	end

	-- Connect each boundary face (count == 1) to the new point.
	for _, level2 in faceRecords do
		for _, level3 in level2 do
			for _, record in level3 do
				if record.Count == 1 then
					local startIndex = record.Start
					local ri = #result
					table.move(faceBuffer, startIndex, startIndex + 2, ri + 1, result)
					result[ri + 4] = p
				end
			end
		end
	end

	return result
end

--------------------------------------------------------------------------------
--// Public API //--
--------------------------------------------------------------------------------

-- Module-level counter for auto-generated vertex ids.
local _nextId = 0
local AUTO_ID_PREFIX = "__auto__:"

local function nextAutoId(vertices: { [string]: Vector3 }): string
	while true do
		_nextId += 1
		local id = AUTO_ID_PREFIX .. tostring(_nextId)
		if vertices[id] == nil then
			return id
		end
	end
end

-- Internal type — includes private fields not part of the public interface.
type Delaunay3dInternal = {
	-- id → position (source of truth for id-based lookups).
	_Vertices: { [string]: Vector3 },
	-- Dense flat list of unique positions. Fed directly to triangulation.
	_UniqueVertices: { Vector3 },
	-- Position-index map for O(1) swap-remove in _UniqueVertices.
	_PositionToIndex: { [Vector3]: number },
	-- Number of ids currently referencing a given position.
	_PositionRefCount: { [Vector3]: number },

	-- Flat stride-based output caches (recomputed on Flush).
	-- _FlatTetrahedra: stride-4  (a, b, c, d per tet)
	-- _FlatTriangles:  stride-3  (u, v, w per face)
	-- _FlatEdges:      stride-2  (u, v per edge)
	_FlatTetrahedra: { Vector3 },
	_FlatTriangles: { Vector3 },
	_FlatEdges: { Vector3 },

	-- Boxed struct caches (only rebuilt when needed, cleared on mutation).
	_BoxedTetrahedra: { Tetrahedron }?,
	_BoxedTriangles: { Triangle }?,
	_BoxedEdges: { Edge }?,
	_BoxedHullTriangles: { Triangle }?,
	_BoxedHullEdges: { Edge }?,

	-- Hull flat caches (derived from the current tetrahedra buffer on demand).
	_HullVertices: { Vector3 }?,
	_HullTrianglesFlat: { Vector3 }?,
	_HullEdgesFlat: { Vector3 }?,

	-- Adjacency: vertex position → adjacent vertex positions.
	_AdjacencyMap: { [Vector3]: { Vector3 } },

	-- True whenever mutation has occurred since the last flush.
	_IsDirty: boolean,
	-- Version counter incremented on each mutation; used to detect structural changes during iteration.
	_GraphVersion: number,

	_Flush: (self: Delaunay3dInternal) -> (),
} & Delaunay3dObject

local Delaunay3d = {}
Delaunay3d.__index = Delaunay3d

--[=[
	Creates a new Delaunay3d instance, optionally seeded with an initial set of points.

	@param initialPoints { Vector3 }? -- Optional initial vertices to insert.
	@return Delaunay3dObject
]=]
function Delaunay3d.new(initialPoints: { Vector3 }?): Delaunay3dObject
	local self = setmetatable({
		_Vertices = {},
		_UniqueVertices = {},
		_PositionToIndex = {},
		_PositionRefCount = {},
		_FlatTetrahedra = {},
		_FlatTriangles = {},
		_FlatEdges = {},
		_BoxedTetrahedra = nil,
		_BoxedTriangles = nil,
		_BoxedEdges = nil,
		_BoxedHullTriangles = nil,
		_BoxedHullEdges = nil,
		_HullVertices = nil,
		_HullTrianglesFlat = nil,
		_HullEdgesFlat = nil,
		_AdjacencyMap = {},
		_IsDirty = true,
		_GraphVersion = 0,
	}, Delaunay3d) :: any
	if initialPoints then
		for _, p in initialPoints do
			(self :: Delaunay3dInternal):AddPoint(p)
		end
	end
	return self
end

--------------------------------------------------------------------------------
--// Private helpers //--
--------------------------------------------------------------------------------

--[[
	_buildFlatMesh(tets, superKeys)

	Given the raw Tetrahedron list produced by Bowyer-Watson and the set of
	super-tetrahedron vertex keys, builds three flat stride-based arrays and an
	adjacency map, discarding any tetrahedron that shares a vertex with the
	super-tetrahedron.

	Returns:
	  flatTets  { Vector3 }  stride-4  (a,b,c,d per tetrahedron)
	  flatTris  { Vector3 }  stride-3  (u,v,w per unique triangular face)
	  flatEdges { Vector3 }  stride-2  (u,v per unique edge)
	  adjMap    { [string]: { Vector3 } }  v3Key → adjacent positions
]]
local function _buildFlatMesh(
	flatTets: { Vector3 },
	superKeys: { [Vector3]: true }
): ({ Vector3 }, { Vector3 }, { Vector3 }, { [Vector3]: { Vector3 } })
	local outFlatTets: { Vector3 } = {}
	local outFlatTris: { Vector3 } = {}
	local outFlatEdges: { Vector3 } = {}
	local adjMap: { [Vector3]: { Vector3 } } = {}

	-- Opt#2: Build numeric position mapping for efficient deduplication.
	local posToId: { [Vector3]: number } = {}
	local nextId = 0

	local function ensurePosId(pos: Vector3): number
		local id = posToId[pos]
		if id ~= nil then
			return id
		end
		nextId += 1
		posToId[pos] = nextId
		return nextId
	end

	local trisSeen: { [number]: { [number]: { [number]: boolean } } } = {}
	local edgesSeen: { [number]: { [number]: boolean } } = {}

	-- Helper: add a directed link u→v into adjMap (one direction only; called
	-- for both orders at each edge site).
	local function addAdj(u: Vector3, v: Vector3)
		local list = adjMap[u]
		if not list then
			list = {}
			adjMap[u] = list
		end
		list[#list + 1] = v
	end

	local function addTri(u: Vector3, v: Vector3, w: Vector3, iu: number, iv: number, iw: number)
		local ia, ib, ic = canonicalTriKey(iu, iv, iw)
		if markTriSeen(trisSeen, ia, ib, ic) then
			local fi = #outFlatTris
			outFlatTris[fi + 1] = u
			outFlatTris[fi + 2] = v
			outFlatTris[fi + 3] = w
		end
	end

	local function addEdge(u: Vector3, v: Vector3, iu: number, iv: number)
		local ia, ib = canonicalEdgeKey(iu, iv)
		if markEdgeSeen(edgesSeen, ia, ib) then
			local ei = #outFlatEdges
			outFlatEdges[ei + 1] = u
			outFlatEdges[ei + 2] = v
			addAdj(u, v)
			addAdj(v, u)
		end
	end

	for i = 1, #flatTets, 4 do
		local a, b, c, d = flatTets[i], flatTets[i + 1], flatTets[i + 2], flatTets[i + 3]
		if superKeys[a] or superKeys[b] or superKeys[c] or superKeys[d] then
			continue
		end

		local ida = ensurePosId(a)
		local idb = ensurePosId(b)
		local idc = ensurePosId(c)
		local idd = ensurePosId(d)

		-- Flat tetrahedron entry.
		appendFlatTetrahedron(outFlatTets, a, b, c, d)

		-- Unique triangular faces + edges (using numeric keys).
		addTri(a, b, c, ida, idb, idc)
		addTri(a, b, d, ida, idb, idd)
		addTri(a, c, d, ida, idc, idd)
		addTri(b, c, d, idb, idc, idd)

		addEdge(a, b, ida, idb)
		addEdge(a, c, ida, idc)
		addEdge(a, d, ida, idd)
		addEdge(b, c, idb, idc)
		addEdge(b, d, idb, idd)
		addEdge(c, d, idc, idd)
	end

	return outFlatTets, outFlatTris, outFlatEdges, adjMap
end

--[=[
	Removes all vertices and clears all cached triangulation output.
]=]
function Delaunay3d.Clear(self: Delaunay3dInternal)
	self._IsDirty = true
	table.clear(self._Vertices)
	table.clear(self._UniqueVertices)
	table.clear(self._PositionToIndex)
	table.clear(self._PositionRefCount)
	table.clear(self._FlatTetrahedra)
	table.clear(self._FlatTriangles)
	table.clear(self._FlatEdges)
	table.clear(self._AdjacencyMap)
	self._BoxedTetrahedra = nil
	self._BoxedTriangles = nil
	self._BoxedEdges = nil
	self._BoxedHullTriangles = nil
	self._BoxedHullEdges = nil
	self._HullVertices = nil
	self._HullTrianglesFlat = nil
	self._HullEdgesFlat = nil
	self._GraphVersion += 1
end

--------------------------------------------------------------------------------
--// Phase 3 — _Flush //--
--------------------------------------------------------------------------------

--[=[
	Recomputes the triangulation from the current vertex set if dirty.
	Called automatically by all accessor and iterator methods.
]=]
function Delaunay3d._Flush(self: Delaunay3dInternal)
	if not self._IsDirty then
		return
	end
	self._IsDirty = false
	-- Clear boxed caches; they will be rebuilt lazily if accessed.
	self._BoxedTetrahedra = nil
	self._BoxedTriangles = nil
	self._BoxedEdges = nil
	self._BoxedHullTriangles = nil
	self._BoxedHullEdges = nil
	self._HullVertices = nil
	self._HullTrianglesFlat = nil
	self._HullEdgesFlat = nil

	local verts = self._UniqueVertices
	if #verts < 4 then
		-- Not enough vertices for a tetrahedron; clear all output.
		table.clear(self._FlatTetrahedra)
		table.clear(self._FlatTriangles)
		table.clear(self._FlatEdges)
		table.clear(self._AdjacencyMap)
		self._HullVertices = nil
		self._HullTrianglesFlat = nil
		self._HullEdgesFlat = nil
		self._BoxedHullTriangles = nil
		self._BoxedHullEdges = nil
		return
	end

	local centre, M = computeBounds(verts)
	local sp1, sp2, sp3, sp4 = makeSuperTetrahedron(centre, M)

	local superKeys: { [Vector3]: true } = {
		[sp1] = true,
		[sp2] = true,
		[sp3] = true,
		[sp4] = true,
	}

	local Tetrahedrons: { Vector3 } = { sp1, sp2, sp3, sp4 }
	for _, p in verts do
		Tetrahedrons = insertPoint(Tetrahedrons, p)
	end

	local flatTets, flatTris, flatEdges, adjMap = _buildFlatMesh(Tetrahedrons, superKeys)
	self._FlatTetrahedra = flatTets
	self._FlatTriangles = flatTris
	self._FlatEdges = flatEdges
	self._AdjacencyMap = adjMap
end

--------------------------------------------------------------------------------
--// Lazy Hull Boxers //--
--------------------------------------------------------------------------------

local function boxHullTrianglesFlat(flatTris: { Vector3 }): { Triangle }
	local result: { Triangle } = table.create(#flatTris / 3) :: any
	local ri = 1
	for i = 1, #flatTris, 3 do
		local tri: Triangle = { flatTris[i], flatTris[i + 1], flatTris[i + 2] }
		result[ri] = tri
		ri += 1
	end
	return result
end

local function boxHullEdgesFlat(flatEdges: { Vector3 }): { Edge }
	local result: { Edge } = table.create(#flatEdges / 2) :: any
	local ri = 1
	for i = 1, #flatEdges, 2 do
		local edge: Edge = { flatEdges[i], flatEdges[i + 1] }
		result[ri] = edge
		ri += 1
	end
	return result
end

--------------------------------------------------------------------------------
--// Lazy Boxed Array Builders //--
--------------------------------------------------------------------------------

--[[
	Box flat stride-4 array into Tetrahedron tuple array.
	Cached after first build to avoid rebuilding on repeated calls.
]]
local function boxTetrahedra(self: Delaunay3dInternal): { Tetrahedron }
	if self._BoxedTetrahedra then
		return self._BoxedTetrahedra
	end
	local flat = self._FlatTetrahedra
	local result: { Tetrahedron } = table.create(#flat / 4) :: any
	local ri = 1
	for i = 1, #flat, 4 do
		local tet: Tetrahedron = { flat[i], flat[i + 1], flat[i + 2], flat[i + 3] }
		result[ri] = tet
		ri += 1
	end
	self._BoxedTetrahedra = result
	return result
end

--[[
	Box flat stride-3 array into Triangle tuple array.
	Cached after first build to avoid rebuilding on repeated calls.
]]
local function boxTriangles(self: Delaunay3dInternal): { Triangle }
	if self._BoxedTriangles then
		return self._BoxedTriangles
	end
	local flat = self._FlatTriangles
	local result: { Triangle } = table.create(#flat / 3) :: any
	local ri = 1
	for i = 1, #flat, 3 do
		local tri: Triangle = { flat[i], flat[i + 1], flat[i + 2] }
		result[ri] = tri
		ri += 1
	end
	self._BoxedTriangles = result
	return result
end

--[[
	Box flat stride-2 array into Edge tuple array.
	Cached after first build to avoid rebuilding on repeated calls.
]]
local function boxEdges(self: Delaunay3dInternal): { Edge }
	if self._BoxedEdges then
		return self._BoxedEdges
	end
	local flat = self._FlatEdges
	local result: { Edge } = table.create(#flat / 2) :: any
	local ri = 1
	for i = 1, #flat, 2 do
		local edge: Edge = { flat[i], flat[i + 1] }
		result[ri] = edge
		ri += 1
	end
	self._BoxedEdges = result
	return result
end

--------------------------------------------------------------------------------
--// Phase 4 — Mutation methods //--
--------------------------------------------------------------------------------

--[=[
	Inserts a vertex into the triangulation.

	@param point Vector3 -- The position to insert.
	@param id string? -- Optional caller-supplied id. Auto-generated if omitted.
	@return string -- The id of the inserted vertex.
]=]
function Delaunay3d.AddPoint(self: Delaunay3dInternal, point: Vector3, id: string?): string
	local vid: string
	if id ~= nil then
		if string.sub(id, 1, #AUTO_ID_PREFIX) == AUTO_ID_PREFIX then
			error("Delaunay3d.AddPoint: manual ids cannot start with reserved auto-id prefix " .. AUTO_ID_PREFIX)
		end
		vid = id
	else
		vid = nextAutoId(self._Vertices)
	end

	local existingPosition = self._Vertices[vid]
	if existingPosition ~= nil then
		if existingPosition == point then
			return vid -- no-op
		end
		self:MovePoint(vid, point)
		return vid
	end

	self._Vertices[vid] = point

	local existingRefCount = self._PositionRefCount[point]
	if existingRefCount ~= nil then
		self._PositionRefCount[point] = existingRefCount + 1
		self._GraphVersion += 1
		return vid
	end

	local idx = #self._UniqueVertices + 1
	self._UniqueVertices[idx] = point
	self._PositionToIndex[point] = idx
	self._PositionRefCount[point] = 1
	self._IsDirty = true
	self._GraphVersion += 1
	return vid
end

--[=[
	Removes the vertex with the given id from the triangulation.
	Does nothing if the id is not found.

	@param id string
]=]
function Delaunay3d.RemovePoint(self: Delaunay3dInternal, id: string)
	local position = self._Vertices[id]
	if position == nil then
		return
	end
	self._Vertices[id] = nil :: any

	local refCount = self._PositionRefCount[position]
	if refCount == nil then
		return
	end
	if refCount > 1 then
		self._PositionRefCount[position] = refCount - 1
		self._GraphVersion += 1
		return -- unique vertex set unchanged, keep current dirty flag
	end

	self._PositionRefCount[position] = nil :: any
	local idx = self._PositionToIndex[position]
	if idx == nil then
		return
	end
	self._PositionToIndex[position] = nil :: any

	local last = #self._UniqueVertices
	if idx ~= last then
		local tailPosition = self._UniqueVertices[last]
		self._UniqueVertices[idx] = tailPosition
		self._PositionToIndex[tailPosition] = idx
	end

	self._UniqueVertices[last] = nil :: any
	self._IsDirty = true
	self._GraphVersion += 1
end

--[=[
	Moves the vertex with the given id to a new position.
	Does nothing if the id is not found.

	@param id string
	@param newPosition Vector3
]=]
function Delaunay3d.MovePoint(self: Delaunay3dInternal, id: string, newPosition: Vector3)
	local oldPosition = self._Vertices[id]
	if oldPosition == nil then
		return
	end
	if oldPosition == newPosition then
		return
	end

	self._Vertices[id] = newPosition

	local uniqueChanged = false

	-- Remove one reference from oldPosition, deleting it from unique storage if
	-- no ids remain.
	local oldRefCount = self._PositionRefCount[oldPosition]
	if oldRefCount ~= nil then
		if oldRefCount > 1 then
			self._PositionRefCount[oldPosition] = oldRefCount - 1
		else
			self._PositionRefCount[oldPosition] = nil :: any
			local oldIdx = self._PositionToIndex[oldPosition]
			if oldIdx ~= nil then
				self._PositionToIndex[oldPosition] = nil :: any
				local last = #self._UniqueVertices
				if oldIdx ~= last then
					local tailPosition = self._UniqueVertices[last]
					self._UniqueVertices[oldIdx] = tailPosition
					self._PositionToIndex[tailPosition] = oldIdx
				end
				self._UniqueVertices[last] = nil :: any
				uniqueChanged = true
			end
		end
	end

	-- Add one reference to newPosition, inserting into unique storage if needed.
	local newRefCount = self._PositionRefCount[newPosition]
	if newRefCount ~= nil then
		self._PositionRefCount[newPosition] = newRefCount + 1
	else
		local idx = #self._UniqueVertices + 1
		self._UniqueVertices[idx] = newPosition
		self._PositionToIndex[newPosition] = idx
		self._PositionRefCount[newPosition] = 1
		uniqueChanged = true
	end

	if uniqueChanged then
		self._IsDirty = true
	end
	self._GraphVersion += 1
end

--------------------------------------------------------------------------------
--// Phase 5 — Accessors, iterators, queries //--
--------------------------------------------------------------------------------

--[=[
	Returns the current list of vertex positions (one per id, in insertion order).
	Does not trigger a flush.
]=]
function Delaunay3d.GetVertices(self: Delaunay3dInternal): { Vector3 }
	return self._UniqueVertices
end

--[=[
	Returns all edges as tuple arrays `{ [1], [2] }`.
]=]
function Delaunay3d.GetEdges(self: Delaunay3dInternal): { Edge }
	self:_Flush()
	return boxEdges(self)
end

--[=[
	Returns all triangular faces as tuple arrays `{ [1], [2], [3] }`.
]=]
function Delaunay3d.GetTriangles(self: Delaunay3dInternal): { Triangle }
	self:_Flush()
	return boxTriangles(self)
end

--[=[
	Returns all tetrahedra as numerber arrays `{ [1], [2], [3], [4] }`.
]=]
function Delaunay3d.GetTetrahedrons(self: Delaunay3dInternal): { Tetrahedron }
	self:_Flush()
	return boxTetrahedra(self)
end

--[=[
	Returns the current hull vertex positions.
]=]
function Delaunay3d.GetHullVertices(self: Delaunay3dInternal): { Vector3 }
	self:_Flush()
	if not self._HullVertices then
		local hullVertices, hullTrianglesFlat, hullEdgesFlat = _buildHullFlatData(self._FlatTetrahedra)
		self._HullVertices = hullVertices
		self._HullTrianglesFlat = hullTrianglesFlat
		self._HullEdgesFlat = hullEdgesFlat
		self._BoxedHullTriangles = nil
		self._BoxedHullEdges = nil
	end
	local hullVertices = self._HullVertices
	if hullVertices == nil then
		local computedHullVertices, hullTrianglesFlat, hullEdgesFlat = _buildHullFlatData(self._FlatTetrahedra)
		self._HullVertices = computedHullVertices
		self._HullTrianglesFlat = hullTrianglesFlat
		self._HullEdgesFlat = hullEdgesFlat
		self._BoxedHullTriangles = nil
		self._BoxedHullEdges = nil
		hullVertices = computedHullVertices
	end
	return hullVertices :: { Vector3 }
end

--[=[
	Returns all hull triangles as tuple arrays `{ [1], [2], [3] }`.
]=]
function Delaunay3d.GetHullTriangles(self: Delaunay3dInternal): { Triangle }
	self:_Flush()
	local hullTrianglesFlat = self._HullTrianglesFlat
	if hullTrianglesFlat == nil then
		local hullVertices, computedHullTrianglesFlat, hullEdgesFlat = _buildHullFlatData(self._FlatTetrahedra)
		self._HullVertices = hullVertices
		self._HullTrianglesFlat = computedHullTrianglesFlat
		self._HullEdgesFlat = hullEdgesFlat
		hullTrianglesFlat = computedHullTrianglesFlat
	end
	assert(hullTrianglesFlat ~= nil, "Delaunay3d.GetHullTriangles: hull cache was not initialized")
	local boxedHullTriangles = self._BoxedHullTriangles
	if boxedHullTriangles == nil then
		boxedHullTriangles = boxHullTrianglesFlat(hullTrianglesFlat)
		self._BoxedHullTriangles = boxedHullTriangles
	end
	return boxedHullTriangles :: { Triangle }
end

--[=[
	Returns all hull edges as tuple arrays `{ [1], [2] }`.
]=]
function Delaunay3d.GetHullEdges(self: Delaunay3dInternal): { Edge }
	self:_Flush()
	local hullEdgesFlat = self._HullEdgesFlat
	if hullEdgesFlat == nil then
		local hullVertices, hullTrianglesFlat, computedHullEdgesFlat = _buildHullFlatData(self._FlatTetrahedra)
		self._HullVertices = hullVertices
		self._HullTrianglesFlat = hullTrianglesFlat
		self._HullEdgesFlat = computedHullEdgesFlat
		hullEdgesFlat = computedHullEdgesFlat
	end
	assert(hullEdgesFlat ~= nil, "Delaunay3d.GetHullEdges: hull cache was not initialized")
	local boxedHullEdges = self._BoxedHullEdges
	if boxedHullEdges == nil then
		boxedHullEdges = boxHullEdgesFlat(hullEdgesFlat)
		self._BoxedHullEdges = boxedHullEdges
	end
	return boxedHullEdges :: { Edge }
end

--[=[
	Zero-alloc iterator over all edges.
	```lua
	for u, v in mesh:ForEachEdge() do ... end
	```
]=]
function Delaunay3d.ForEachEdge(self: Delaunay3dInternal): () -> (Vector3, Vector3)
	self:_Flush()
	local flat = self._FlatEdges
	local i = 0
	local startVersion = self._GraphVersion
	return function(): (Vector3, Vector3)
		if self._GraphVersion ~= startVersion then
			warn(
				"Delaunay3d.ForEachEdge: triangulation was modified during iteration; results may be incomplete or inconsistent"
			)
		end
		i += 2
		if i > #flat then
			return nil :: any, nil :: any
		end
		return flat[i - 1], flat[i]
	end
end

--[=[
	Zero-alloc iterator over all triangular faces.
	```lua
	for u, v, w in mesh:ForEachTriangle() do ... end
	```
]=]
function Delaunay3d.ForEachTriangle(self: Delaunay3dInternal): () -> (Vector3, Vector3, Vector3)
	self:_Flush()
	local flat = self._FlatTriangles
	local i = 0
	local startVersion = self._GraphVersion
	return function(): (Vector3, Vector3, Vector3)
		if self._GraphVersion ~= startVersion then
			warn(
				"Delaunay3d.ForEachTriangle: triangulation was modified during iteration; results may be incomplete or inconsistent"
			)
		end
		i += 3
		if i > #flat then
			return nil :: any, nil :: any, nil :: any
		end
		return flat[i - 2], flat[i - 1], flat[i]
	end
end

--[=[
	Zero-alloc iterator over all tetrahedra.
	```lua
	for a, b, c, d in mesh:ForEachTetrahedron() do ... end
	```
]=]
function Delaunay3d.ForEachTetrahedron(self: Delaunay3dInternal): () -> (Vector3, Vector3, Vector3, Vector3)
	self:_Flush()
	local flat = self._FlatTetrahedra
	local i = 0
	local startVersion = self._GraphVersion
	return function(): (Vector3, Vector3, Vector3, Vector3)
		if self._GraphVersion ~= startVersion then
			warn(
				"Delaunay3d.ForEachTetrahedron: triangulation was modified during iteration; results may be incomplete or inconsistent"
			)
		end
		i += 4
		if i > #flat then
			return nil :: any, nil :: any, nil :: any, nil :: any
		end
		return flat[i - 3], flat[i - 2], flat[i - 1], flat[i]
	end
end

--[=[
	Returns the list of vertex positions that share an edge with the vertex
	identified by `id`. Returns an empty table if the id is unknown or the
	triangulation has fewer than 4 points.

	@param id string
	@return { Vector3 }
]=]
function Delaunay3d.GetAdjacentVertices(self: Delaunay3dInternal, id: string): { Vector3 }
	self:_Flush()
	local pos = self._Vertices[id]
	if not pos then
		return {}
	end
	return self._AdjacencyMap[pos] or {}
end

--[=[
	Returns all tetrahedra whose interior (closed) contains `point`.
	Uses the orient3d sign-consistency test (5 calls per tetrahedron).

	@param point Vector3
	@return { Tetrahedron }
]=]
function Delaunay3d.GetTetrahedronsContaining(self: Delaunay3dInternal, point: Vector3): { Tetrahedron }
	self:_Flush()
	local flat = self._FlatTetrahedra
	local result: { Tetrahedron } = {}

	-- Point-in-tetrahedron: orient3d(A,B,C,D) determines the reference
	-- orientation; then each of the four sub-volumes formed by replacing one
	-- vertex with 'point' must have the same sign (≥ 0 for positive, ≤ 0 for
	-- negative orientation).
	for i = 1, #flat, 4 do
		local a, b, c, d = flat[i], flat[i + 1], flat[i + 2], flat[i + 3]
		local o = orient3d(a, b, c, d)
		if o == 0 then
			continue -- degenerate, skip
		end
		local inside: boolean
		if o > 0 then
			inside = orient3d(a, b, c, point) >= 0
				and orient3d(a, b, point, d) >= 0
				and orient3d(a, point, c, d) >= 0
				and orient3d(point, b, c, d) >= 0
		else
			inside = orient3d(a, b, c, point) <= 0
				and orient3d(a, b, point, d) <= 0
				and orient3d(a, point, c, d) <= 0
				and orient3d(point, b, c, d) <= 0
		end
		if inside then
			result[#result + 1] = { a, b, c, d }
		end
	end
	return result
end

--------------------------------------------------------------------------------
--// Shared Flat Array Boxers (no caching) //--
--------------------------------------------------------------------------------

--[[
	Box flat stride-4 array into Tetrahedron tuple array.
	Standalone version for use in static methods; does not cache.
]]
local function _boxFlatTetrahedra(flatTets: { Vector3 }): { Tetrahedron }
	local result: { Tetrahedron } = table.create(#flatTets / 4) :: any
	local ri = 1
	for i = 1, #flatTets, 4 do
		local tet: Tetrahedron = { flatTets[i], flatTets[i + 1], flatTets[i + 2], flatTets[i + 3] }
		result[ri] = tet
		ri += 1
	end
	return result
end

--[[
	Box flat stride-3 array into Triangle tuple array.
	Standalone version for use in static methods; does not cache.
]]
local function _boxFlatTriangles(flatTris: { Vector3 }): { Triangle }
	local result: { Triangle } = table.create(#flatTris / 3) :: any
	local ri = 1
	for i = 1, #flatTris, 3 do
		local tri: Triangle = { flatTris[i], flatTris[i + 1], flatTris[i + 2] }
		result[ri] = tri
		ri += 1
	end
	return result
end

--[[
	Box flat stride-2 array into Edge tuple array.
	Standalone version for use in static methods; does not cache.
]]
local function _boxFlatEdges(flatEdges: { Vector3 }): { Edge }
	local result: { Edge } = table.create(#flatEdges / 2) :: any
	local ri = 1
	for i = 1, #flatEdges, 2 do
		local edge: Edge = { flatEdges[i], flatEdges[i + 1] }
		result[ri] = edge
		ri += 1
	end
	return result
end

--------------------------------------------------------------------------------
--// Phase 6 — Static Triangulate //--
--------------------------------------------------------------------------------

--[=[
	@within Delaunay3d
	Performs 3D Delaunay Triangulation on the provided list of vertices using the
	Bowyer–Watson incremental insertion algorithm.

	The triangulation satisfies the Delaunay property: no vertex lies strictly inside
	the circumsphere of any tetrahedron in the mesh.

	Returns a `TriangulationResult` containing:
	- `Tetrahedra` — the final tetrahedra of the mesh.
	- `Triangles`  — every unique triangular face across all tetrahedra (including
	                 shared interior faces).
	- `Edges`      — every unique edge across all tetrahedra.
	- `Vertices`   — the original input positions.

	@param vertices { Vector3 } -- Must contain at least 4 non-coplanar positions.
	@return TriangulationResult
]=]
function Delaunay3d.Triangulate(vertices: { Vector3 }): TriangulationResult
	assert(#vertices >= 4, "Delaunay3d.Triangulate: need at least 4 non-coplanar vertices for a 3-D triangulation")

	local centre, M = computeBounds(vertices)
	local sp1, sp2, sp3, sp4 = makeSuperTetrahedron(centre, M)

	local superKeys: { [Vector3]: true } = {
		[sp1] = true,
		[sp2] = true,
		[sp3] = true,
		[sp4] = true,
	}

	local Tetrahedrons: { Vector3 } = { sp1, sp2, sp3, sp4 }
	for _, p in vertices do
		Tetrahedrons = insertPoint(Tetrahedrons, p)
	end

	local flatTets, flatTris, flatEdges = _buildFlatMesh(Tetrahedrons, superKeys)

	-- Box flat arrays using shared helpers.
	return {
		Vertices = vertices,
		Tetrahedra = _boxFlatTetrahedra(flatTets),
		Triangles = _boxFlatTriangles(flatTris),
		Edges = _boxFlatEdges(flatEdges),
	}
end

return Delaunay3d
