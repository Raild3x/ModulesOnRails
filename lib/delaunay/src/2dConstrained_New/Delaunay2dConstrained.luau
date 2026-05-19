--!strict
--!native
--[=[
	Constrained Delaunay Triangulation (CDT).

	A Luau port of Artem Amirkhanov's CDT library (MPL-2.0).
	Reference: https://github.com/artem-ogre/CDT

	## Algorithm overview

	1. **Super-triangle setup** — three sentinel vertices (`N_SUPER_VERTS = 3`)
	   are inserted first so that every input vertex is guaranteed to lie
	   inside the initial triangulation.  They are stripped by the `erase*`
	   methods at the end.

	2. **Vertex insertion** (`insertVertices`) — each vertex is located inside
	   the existing triangulation via a stochastic walk, then the containing
	   triangle (or shared edge) is split.  The Lawson flip algorithm restores
	   the Delaunay property after each split.

	3. **Constrained edge insertion** (`insertEdges`) — edges that must appear
	   in the final mesh are forced in by retriangulating the pseudo-polygons
	   on each side of intersected edges via the Bowyer-Watson divide-and-
	   conquer approach.

	4. **Erasure** — one of three methods removes unwanted triangles:
	   - `eraseSuperTriangle`        — remove only super-triangle-touching tris.
	   - `eraseOuterTriangles`       — flood-fill + fixed-edge stop to remove
	                                   the outer region.
	   - `eraseOuterTrianglesAndHoles` — depth-parity: even-depth triangles
	                                   (outside or inside holes) are erased.

	After step 4, `vertices` and `triangles` contain the final mesh with
	super-triangle vertices stripped and all indices remapped to 1-based.

	## Usage

	```lua
	local CDT = require(path.to.Delaunay2dConstrained)

	local cdt = CDT.new()
	cdt:insertVertices(myVertices)   -- { Vector2, ... }
	cdt:insertEdges(myEdges)         -- { {v0, v1}, ... }  (0-based vertex indices)
	cdt:eraseOuterTrianglesAndHoles()

	local verts    = cdt.vertices    -- { Vector2, ... }   (1-based, finalized)
	local tris     = cdt.triangles   -- { Triangle, ... }  (1-based, finalized)
	```

	## Triangle slot layout (CCW winding, 1-indexed)

	        v[3]
	        /\
	    n[3]/  \n[2]
	       /    \
	      /______\
	    v[1]  n[1]  v[2]

	`n[i]` is the neighbor triangle across the edge opposite `v[opoVrt(i)]`.
	Super-triangle vertices occupy slots 1–3 of `vertices` before finalization.
]=]

local CDTUtils = require("./CDTUtils")
local Predicates = require("./Predicates")
local KDLocatorModule = require("./KDLocator")

type Triangle = CDTUtils.Triangle
type KDLocator = KDLocatorModule.KDLocator

-- ── Locals aliased for performance / readability ──────────────────────────────
local NO_VERTEX = CDTUtils.NO_VERTEX
local NO_NEIGHBOR = CDTUtils.NO_NEIGHBOR
local N_SUPER_VERTS = CDTUtils.N_SUPER_VERTS
local EDGE_KEY_SHIFT = CDTUtils.EDGE_KEY_SHIFT
local makeTriangle = CDTUtils.makeTriangle
local ccw = CDTUtils.ccw
local cw_fn = CDTUtils.cw
local opoVrt = CDTUtils.opoVrt
local opposedVertexInd = CDTUtils.opposedVertexInd
local opposedTriangleInd = CDTUtils.opposedTriangleInd
local edgeNeighborInd = CDTUtils.edgeNeighborInd
local triContainsVertex = CDTUtils.triContainsVertex
local vertexInd = CDTUtils.vertexInd
local edgeKey = CDTUtils.edgeKey
local touchesSuperTriangle = CDTUtils.touchesSuperTriangle
local nextTriAndVert = CDTUtils.nextTriAndVert
local opposedTri = CDTUtils.opposedTri
local opposedVert = CDTUtils.opposedVert
local edgeNbr = CDTUtils.edgeNbr
local changeNeighborByEdge = CDTUtils.changeNeighborByEdge
local insertUnique = CDTUtils.insertUnique
local insertUniqueList = CDTUtils.insertUniqueList

local locatePointLine = Predicates.locatePointLine
local locatePointTriangle = Predicates.locatePointTriangle
local isOnEdge = Predicates.isOnEdge
local edgeLocSlot = Predicates.edgeLocSlot
local isInCircumcircle = Predicates.isInCircumcircle
local orient2D = Predicates.orient2D
local intersectionPosition = Predicates.intersectionPosition

-- Shorthand used heavily in this file.
local function cw(i: number): number
	return cw_fn(i)
end

-- ── Type definitions ──────────────────────────────────────────────────────────

--[=[
	Public CDT interface exposed to consumers.

	After calling `insertVertices` (and optionally `insertEdges`) followed by
	one of the `erase*` methods, `vertices` and `triangles` hold the
	finalized triangulation with super-triangle vertices removed.
]=]
export type CDT = {
	-- Accessible after finalization.
	vertices: { Vector2 },
	triangles: { Triangle },
	-- Edge bookkeeping (populated during insertEdges).
	fixedEdges: { [number]: boolean },
	overlapCount: { [number]: number },
	pieceToOriginals: { [number]: { number } },
	-- Public methods.
	insertVertices: (self: CDT, verts: { Vector2 }) -> (),
	insertEdges: (self: CDT, edges: { { number } }) -> (),
	eraseSuperTriangle: (self: CDT) -> (),
	eraseOuterTriangles: (self: CDT) -> (),
	eraseOuterTrianglesAndHoles: (self: CDT) -> (),
}

-- Internal type: adds private fields not exposed to consumers.
type CDTInternal = {
	_vertTris: { number },
	_locator: KDLocator,
	_isFinalized: boolean,
} & CDT

-- ── CDT class ─────────────────────────────────────────────────────────────────

local CDT = {}
CDT.__index = CDT

--- Construct a new, empty CDT.
function CDT.new(): CDT
	local self = setmetatable({}, CDT) :: any
	self.vertices = {} :: { Vector2 }
	self.triangles = {} :: { Triangle }
	self.fixedEdges = {} :: { [number]: boolean }
	self.overlapCount = {} :: { [number]: number }
	self.pieceToOriginals = {} :: { [number]: { number } }
	self._vertTris = {} :: { number }
	self._locator = KDLocatorModule.new()
	self._isFinalized = false
	return self :: any
end

-- ── Infrastructure helpers ──────────────────────────────────────────────────

-- Append vertex `pos`, recording `iT` as its initial adjacent triangle.
local function addNewVertex(self: CDTInternal, pos: Vector2, iT: number)
	local idx = #self.vertices + 1
	self.vertices[idx] = pos
	self._vertTris[idx] = iT
end

-- Append triangle `t`; return its 1-based index.
local function addTriangle(self: CDTInternal, t: Triangle): number
	local idx = #self.triangles + 1
	self.triangles[idx] = t
	return idx
end

-- Record `iT` as the canonical adjacent triangle for vertex `v`.
local function setAdjTri(self: CDTInternal, v: number, iT: number)
	self._vertTris[v] = iT
end

-- Find and replace `oldN` with `newN` in the neighbor list of triangle `iT`.
-- No-op when `iT` is NO_NEIGHBOR.
local function changeNeighbor(self: CDTInternal, iT: number, oldN: number, newN: number)
	if iT == NO_NEIGHBOR then
		return
	end
	local nn = self.triangles[iT].neighbors
	if nn[1] == oldN then
		nn[1] = newN
	elseif nn[2] == oldN then
		nn[2] = newN
	else
		nn[3] = newN
	end
end

-- Return true when undirected edge (a, b) already exists in the triangulation.
local function hasEdge(self: CDTInternal, a: number, b: number): boolean
	local triStart = self._vertTris[a]
	if triStart == NO_NEIGHBOR then
		return false
	end
	local iT = triStart
	repeat
		local iTNext, iV = nextTriAndVert(self.triangles[iT], a)
		if iV == b then
			return true
		end
		iT = iTNext
	until iT == triStart or iT == NO_NEIGHBOR
	return false
end

-- Return (iT, iTNext) — the two triangles sharing edge (a, b),
-- or (NO_NEIGHBOR, NO_NEIGHBOR) when the edge is absent.
local function edgeTriangles(self: CDTInternal, a: number, b: number): (number, number)
	local triStart = self._vertTris[a]
	if triStart == NO_NEIGHBOR then
		return NO_NEIGHBOR, NO_NEIGHBOR
	end
	local iT = triStart
	repeat
		local iTNext, iV = nextTriAndVert(self.triangles[iT], a)
		if iV == b then
			return iT, iTNext
		end
		iT = iTNext
	until iT == triStart
	return NO_NEIGHBOR, NO_NEIGHBOR
end

-- Register vertex `iV` with the KD-locator (no-op when locator is empty).
local function tryAddVertexToLocator(self: CDTInternal, iV: number)
	if not self._locator:isEmpty() then
		self._locator:addPoint(iV, self.vertices)
	end
end

-- Initialize the KD-locator from the current vertex array — if not yet done.
local function tryInitLocator(self: CDTInternal)
	if #self.vertices > 0 and self._locator:isEmpty() then
		self._locator:initialize(self.vertices)
	end
end

--[=[
	Insert the 3 super-triangle vertices and the single covering triangle.

	The super-triangle is an equilateral-like triangle that entirely covers
	the bounding box supplied by the caller.  All subsequent user vertices
	are guaranteed to lie strictly inside it.

	Super-triangle geometry (matches CDT C++ addSuperTriangle):
	  r = max(2 * max(w, h), 1)   -- half-height ; ≥ 1 for degenerate input
	  R = 2 * r                   -- excircle radius
	  v1 = (cx - R·cos30, cy - r)
	  v2 = (cx + R·cos30, cy - r)
	  v3 = (cx,           cy + R)
]=]
local function addSuperTriangle(self: CDTInternal, minX: number, minY: number, maxX: number, maxY: number)
	local cx = (minX + maxX) * 0.5
	local cy = (minY + maxY) * 0.5
	local w = maxX - minX
	local h = maxY - minY
	local r = math.max(2 * math.max(w, h), 1)
	local R = 2 * r
	local shiftX = R * 0.8660254037844386 -- R · √3/2  (= R · cos 30°)

	local sv1 = Vector2.new(cx - shiftX, cy - r)
	local sv2 = Vector2.new(cx + shiftX, cy - r)
	local sv3 = Vector2.new(cx, cy + R)

	-- Triangle 1 is the sole initial triangle; all three super-vertices point to it.
	addNewVertex(self, sv1, 1)
	addNewVertex(self, sv2, 1)
	addNewVertex(self, sv3, 1)
	addTriangle(self, makeTriangle(1, 2, 3, NO_NEIGHBOR, NO_NEIGHBOR, NO_NEIGHBOR))
end

-- ── Vertex insertion ────────────────────────────────────────────────────────

--[=[
	Stochastic triangle walk.

	Starting from the triangle adjacent to `startVertex`, follow edges that
	are to the right of `pos` until we land in a triangle that (likely)
	contains pos.  A random per-iteration edge-check offset prevents worst-
	case O(n) behaviour on adversarial inputs.

	Returns the triangle index.
]=]
local function walkTriangles(self: CDTInternal, startVertex: number, pos: Vector2): number
	local currTri = self._vertTris[startVertex]
	while true do
		local t = self.triangles[currTri]
		local found = true
		local offset = math.random(0, 2) -- randomise which edge is checked first
		for i_ = 0, 2 do
			local i = (i_ + offset) % 3 + 1 -- random slot in {1, 2, 3}
			local vStart = self.vertices[t.vertices[i]]
			local vEnd = self.vertices[t.vertices[ccw(i)]]
			if locatePointLine(pos, vStart, vEnd) == "Right" and t.neighbors[i] ~= NO_NEIGHBOR then
				currTri = t.neighbors[i]
				found = false
				break
			end
		end
		if found then
			break
		end
	end
	return currTri
end

--[=[
	Locate which triangle(s) contain vertex iV.

	Returns `(iT, iT2)`:
	  iT  — index of the containing triangle.
	  iT2 — second triangle when iV lies exactly on the shared edge,
	         NO_NEIGHBOR otherwise.

	Throws on unreachable geometry (Outside) or duplicate vertices.
]=]
local function walkingSearchTrianglesAt(self: CDTInternal, iV: number, startVert: number): (number, number)
	local v = self.vertices[iV]
	local iT = walkTriangles(self, startVert, v)
	local t = self.triangles[iT]
	local loc =
		locatePointTriangle(v, self.vertices[t.vertices[1]], self.vertices[t.vertices[2]], self.vertices[t.vertices[3]])
	if loc == "Outside" then
		error(string.format("CDT: no containing triangle found for vertex %d", iV))
	end
	if loc == "OnVertex" then
		error(string.format("CDT: duplicate vertex at index %d", iV))
	end
	local iT2 = NO_NEIGHBOR
	if isOnEdge(loc) then
		iT2 = t.neighbors[edgeLocSlot(loc)]
	end
	return iT, iT2
end

--[=[
	Split triangle iT into 3 by inserting vertex v inside it.

	Before:
	                v3
	               /  \
	           n3 /    \ n2
	             /  iT  \
	           v1________v2
	                n1

	After (iT is re-used for the v1-v2-v sub-triangle):
	                v3
	               /  \
	          n3  /    \  n2
	            / iNewT2\ iNewT1
	           v3__v__v3
	          v1   v   v2
	         / iT \   /
	           n1

	Returns the triStack {iT, iNewT1, iNewT2} for Delaunay flip processing.
]=]
local function insertVertexInsideTriangle(self: CDTInternal, v: number, iT: number): { number }
	local iNewT1 =
		addTriangle(self, makeTriangle(NO_VERTEX, NO_VERTEX, NO_VERTEX, NO_NEIGHBOR, NO_NEIGHBOR, NO_NEIGHBOR))
	local iNewT2 =
		addTriangle(self, makeTriangle(NO_VERTEX, NO_VERTEX, NO_VERTEX, NO_NEIGHBOR, NO_NEIGHBOR, NO_NEIGHBOR))

	-- Snapshot current triangle before mutating it.
	local t = self.triangles[iT]
	local v1 = t.vertices[1]
	local v2 = t.vertices[2]
	local v3 = t.vertices[3]
	local n1 = t.neighbors[1]
	local n2 = t.neighbors[2]
	local n3 = t.neighbors[3]

	self.triangles[iNewT1] = makeTriangle(v2, v3, v, n2, iNewT2, iT)
	self.triangles[iNewT2] = makeTriangle(v3, v1, v, n3, iT, iNewT1)
	self.triangles[iT] = makeTriangle(v1, v2, v, n1, iNewT1, iNewT2)

	setAdjTri(self, v, iT)
	setAdjTri(self, v3, iNewT1)
	changeNeighbor(self, n2, iT, iNewT1)
	changeNeighbor(self, n3, iT, iNewT2)

	return { iT, iNewT1, iNewT2 }
end

--[=[
	Split the shared edge between iT1 and iT2 by inserting vertex v on it.

	Before:
	        v1                 v1
	       /|  T1 (top)       / \
	   n1 / |      \      n1/   \n4
	     /  |       \      /iTnew1\
	   v2---+--------v4  v2---v---v4
	     \  |       /      \iTnew2/
	   n2 \ |      /      n2\   /n3
	       \|  T2 (bot)      \ /
	        v3                 v3

	`handleFixed`: when true, a fixed edge (v2,v4) is forwarded to the
	split-fixed-edge routine (`splitFixedEdge`).

	Returns triStack {iT1, iTnew2, iT2, iTnew1} for Delaunay flip processing.
]=]
local function insertVertexOnEdge(
	self: CDTInternal,
	v: number,
	iT1: number,
	iT2: number,
	handleFixed: boolean
): { number }
	local iTnew1 =
		addTriangle(self, makeTriangle(NO_VERTEX, NO_VERTEX, NO_VERTEX, NO_NEIGHBOR, NO_NEIGHBOR, NO_NEIGHBOR))
	local iTnew2 =
		addTriangle(self, makeTriangle(NO_VERTEX, NO_VERTEX, NO_VERTEX, NO_NEIGHBOR, NO_NEIGHBOR, NO_NEIGHBOR))

	-- From iT1: find the vertex/neighbor pair on each side of the shared edge.
	local t1 = self.triangles[iT1]
	local i1 = opposedVertexInd(t1.neighbors, iT2)
	local v1 = t1.vertices[i1]
	local v2 = t1.vertices[ccw(i1)]
	local n1 = t1.neighbors[i1]
	local n4 = t1.neighbors[cw(i1)]

	-- From iT2: symmetric extraction.
	local t2 = self.triangles[iT2]
	local i2 = opposedVertexInd(t2.neighbors, iT1)
	local v3 = t2.vertices[i2]
	local v4 = t2.vertices[ccw(i2)]
	local n3 = t2.neighbors[i2]
	local n2 = t2.neighbors[cw(i2)]

	self.triangles[iT1] = makeTriangle(v, v1, v2, iTnew1, n1, iT2)
	self.triangles[iT2] = makeTriangle(v, v2, v3, iT1, n2, iTnew2)
	self.triangles[iTnew1] = makeTriangle(v, v4, v1, iTnew2, n4, iT1)
	self.triangles[iTnew2] = makeTriangle(v, v3, v4, iT2, n3, iTnew1)

	setAdjTri(self, v, iT1)
	setAdjTri(self, v4, iTnew1)
	changeNeighbor(self, n4, iT1, iTnew1)
	changeNeighbor(self, n3, iT2, iTnew2)

	-- Split a fixed edge that lies on the shared edge being subdivided.
	if handleFixed and self.fixedEdges[edgeKey(v2, v4)] then
		splitFixedEdge(self, v2, v4, v)
	end

	return { iT1, iTnew2, iT2, iTnew1 }
end

-- ── Delaunay flipping ───────────────────────────────────────────────────────

--[=[
	Collect the 8 geometric parameters needed to test and potentially perform
	a Delaunay edge flip on the edge opposite to vertex iV1 in triangle iT.

	Naming convention (see CDT flipEdge diagram):
	  iT    holds {v1, v2, v4}   — v1 is the newly inserted vertex
	  iTopo holds {v2, v3, v4}   — sharing edge (v2, v4) with iT

	After a flip the shared edge (v2, v4) is replaced by edge (v1, v3):
	  iT    becomes {v4, v1, v3}
	  iTopo becomes {v2, v3, v1}

	Returns (iTopo, iV2, iV3, iV4, n1, n2, n3, n4).
	iTopo == NO_NEIGHBOR means the edge is on the convex hull (no flip).
]=]
local function edgeFlipInfo(
	self: CDTInternal,
	iT: number,
	iV1: number
): (number, number, number, number, number, number, number, number)
	local t = self.triangles[iT]
	local tv = t.vertices
	local tn = t.neighbors

	-- Slot that iV1 occupies in triangle iT.
	local s = vertexInd(tv, iV1)
	-- iV2 is CCW from iV1; iV4 is CW from iV1.
	local iV2 = tv[ccw(s)]
	local iV4 = tv[cw(s)]
	-- n1: neighbor on edge (iV1, iV2); n3: neighbor on edge (iV4, iV1).
	local n1 = tn[s]
	local n3 = tn[cw(s)]
	-- iTopo: the neighbor sharing the flip-candidate edge (iV2, iV4).
	local iTopo = tn[ccw(s)]

	if iTopo == NO_NEIGHBOR then
		return NO_NEIGHBOR, iV2, NO_VERTEX, iV4, n1, NO_NEIGHBOR, n3, NO_NEIGHBOR
	end

	-- From iTopo, find which slot points back to iT, then extract
	-- the opposed vertex (iV3) and outer neighbors (n2, n4).
	local tOpo = self.triangles[iTopo]
	local tov = tOpo.vertices
	local ton = tOpo.neighbors
	local j: number
	if ton[1] == iT then
		j = 1
	elseif ton[2] == iT then
		j = 2
	else
		j = 3
	end
	local iV3 = tov[opoVrt(j)]
	local n2 = ton[ccw(j)]
	local n4 = ton[cw(j)]

	return iTopo, iV2, iV3, iV4, n1, n2, n3, n4
end

--[=[
	Return true when flipping the shared edge (iV2, iV4) improves the
	Delaunay property.

	iV1 is the newly inserted vertex; iV3 is the vertex in iTopo that is
	opposite to iT.

	Handles super-triangle vertices by substituting an orient2D-based test
	for the standard in-circumcircle test (super-triangle vertices are
	finite approximations of infinity).  Matches CDT C++ isFlipNeeded logic.
]=]
local function isFlipNeeded(self: CDTInternal, iV1: number, iV2: number, iV3: number, iV4: number): boolean
	-- Constrained (fixed) edges must never be flipped away.
	if self.fixedEdges[edgeKey(iV2, iV4)] then
		return false
	end

	local v1 = self.vertices[iV1]
	local v2 = self.vertices[iV2]
	local v3 = self.vertices[iV3]
	local v4 = self.vertices[iV4]
	local N = N_SUPER_VERTS -- super-triangle vertices are indices 1..N

	-- iV1 is a super-triangle vertex (flip-candidate edge touches super-tri).
	if iV1 <= N then
		if iV2 <= N then
			-- Both flip-candidate and original edge touch super-tri.
			return locatePointLine(v2, v3, v4) == locatePointLine(v1, v3, v4)
		end
		if iV4 <= N then
			return locatePointLine(v4, v2, v3) == locatePointLine(v1, v2, v3)
		end
		return false -- only the flip-candidate edge touches super-tri
	end

	-- iV3 is a super-triangle vertex (flip-candidate edge touches super-tri).
	if iV3 <= N then
		if iV2 <= N then
			return locatePointLine(v2, v1, v4) == locatePointLine(v3, v1, v4)
		end
		if iV4 <= N then
			return locatePointLine(v4, v2, v1) == locatePointLine(v3, v2, v1)
		end
		return false
	end

	-- Neither flip-candidate vertex is super — fall through to orient2D
	-- substitutions for when a *shared-edge* vertex is super.
	if iV2 <= N then
		return locatePointLine(v2, v3, v4) == locatePointLine(v1, v3, v4)
	end
	if iV4 <= N then
		return locatePointLine(v4, v2, v3) == locatePointLine(v1, v2, v3)
	end

	-- Standard Delaunay: does iV1 lie inside the circumcircle of (iV2, iV3, iV4)?
	return isInCircumcircle(v1, v2, v3, v4)
end

--[=[
	Perform an edge flip between triangles iT and iTopo.

	Before:                     After:
	         v4                          v4
	        /|\                         / \
	    n3 / | \ n4                 n3/iT' \ n4
	      /  T  \           →       /~~~~~~~\
	    v1   |   v3               v1         v3
	      \ Tpo  /                 \ Topo'  /
	    n1 \ | / n2              n1 \     / n2
	        \|/                      \   /
	         v2                       v2

	New edge: v1–v3.  Old edge: v2–v4 (removed).
]=]
local function flipEdge(
	self: CDTInternal,
	iT: number,
	iTopo: number,
	v1: number,
	v2: number,
	v3: number,
	v4: number,
	n1: number,
	n2: number,
	n3: number,
	n4: number
)
	self.triangles[iT] = makeTriangle(v4, v1, v3, n3, iTopo, n4)
	self.triangles[iTopo] = makeTriangle(v2, v3, v1, n2, iT, n1)
	changeNeighbor(self, n1, iT, iTopo)
	changeNeighbor(self, n4, iTopo, iT)
	if not self._isFinalized then
		setAdjTri(self, v4, iT)
		setAdjTri(self, v2, iTopo)
	end
end

--[=[
	Lawson edge-flip algorithm.

	Restore the Delaunay property in the neighbourhood of newly inserted
	vertex iV1 by iteratively flipping non-Delaunay edges popped from
	`triStack` (used as a LIFO stack via table.remove from the end).
]=]
local function ensureDelaunayByEdgeFlips(self: CDTInternal, iV1: number, triStack: { number })
	while #triStack > 0 do
		local iT = table.remove(triStack) :: number
		local iTopo, iV2, iV3, iV4, n1, n2, n3, n4 = edgeFlipInfo(self, iT, iV1)
		if iTopo ~= NO_NEIGHBOR and isFlipNeeded(self, iV1, iV2, iV3, iV4) then
			flipEdge(self, iT, iTopo, iV1, iV2, iV3, iV4, n1, n2, n3, n4)
			table.insert(triStack, iT)
			table.insert(triStack, iTopo)
		end
	end
end

-- ── Pseudo-polygon triangulation ────────────────────────────────────────────

--[=[
	Find the optimal Delaunay point in poly[iA+1 .. iB-1] (1-indexed Luau).

	Scans interior indices iA+1…iB-1 of `poly` and returns the index iC
	whose vertex lies inside the circumcircle of the current best triangle
	(a, b, best), maximising Delaunay quality.

	Mirrors CDT C++ findDelaunayPoint (0-indexed there; Luau uses 1-indexed).
]=]
local function findDelaunayPoint(self: CDTInternal, poly: { number }, iA: number, iB: number): number
	local a = self.vertices[poly[iA]]
	local b = self.vertices[poly[iB]]
	local out = iA + 1
	local c = self.vertices[poly[out]]
	for i = iA + 1, iB - 1 do
		local v = self.vertices[poly[i]]
		if isInCircumcircle(v, a, b, c) then
			out = i
			c = v
		end
	end
	return out
end

--[=[
	One iteration of pseudo-polygon triangulation.

	Pops a task `{iA, iB, iT, iParent, iInParent}` from the back of
	`iterations` and:
	  1. Finds the Delaunay point iC in poly[iA+1..iB-1].
	  2. Handles the B-side half-polygon [iC..iB]: either pushes a sub-task
	     or wires the outer edge b→c into t.neighbors[2].
	  3. Handles the A-side half-polygon [iA..iC]: either pushes a sub-task
	     or wires the outer edge c→a into t.neighbors[3].
	  4. Finalises triangle iT: t.vertices={a,b,c}, t.neighbors[1]=iParent,
	     updates the parent neighbor slot, records iT as adj tri for c.

	`iInParent` is the Luau 1-indexed neighbor slot in `iParent` that will
	be set to `iT` once the triangle is finalised.

	Neighbor index mapping vs CDT C++ (0-indexed → Luau 1-indexed):
	  C++ n[0] across a-b → Luau n[1]
	  C++ n[1] across b-c → Luau n[2]
	  C++ n[2] across c-a → Luau n[3]
	  C++ iInParent 0/1/2 → Luau iInParent 1/2/3
]=]
local function tppIteration(
	self: CDTInternal,
	poly: { number },
	outerTris: { [number]: number },
	trianglesToReuse: { number },
	iterations: { { number } }
)
	local task = table.remove(iterations) :: { number }
	local iA = task[1]
	local iB = task[2]
	local iT = task[3]
	local iParent = task[4]
	local iInParent = task[5] -- Luau 1-indexed neighbor slot of parent

	local t = self.triangles[iT]
	local iC = findDelaunayPoint(self, poly, iA, iB)
	local a = poly[iA]
	local b = poly[iB]
	local c = poly[iC]

	-- B-side: sub-polygon poly[iC..iB].
	if iB - iC > 1 then
		-- Interior points remain on the B-side; recurse with a reused triangle.
		-- Parent slot 2 = across b-c (C++ neighbors[1]).
		local iNext = table.remove(trianglesToReuse) :: number
		table.insert(iterations, { iC, iB, iNext, iT, 2 })
	else
		-- Single outer edge b-c; wire t.neighbors[2] to its outer triangle.
		local ekBC = edgeKey(b, c)
		local outerTri = outerTris[ekBC]
		if outerTri ~= nil and outerTri ~= NO_NEIGHBOR then
			t.neighbors[2] = outerTri
			changeNeighborByEdge(self.triangles[outerTri], c, b, iT)
		else
			outerTris[ekBC] = iT
		end
	end

	-- A-side: sub-polygon poly[iA..iC].
	if iC - iA > 1 then
		-- Interior points remain on the A-side; recurse with a reused triangle.
		-- Parent slot 3 = across c-a (C++ neighbors[2]).
		local iNext = table.remove(trianglesToReuse) :: number
		table.insert(iterations, { iA, iC, iNext, iT, 3 })
	else
		-- Single outer edge c-a; wire t.neighbors[3] to its outer triangle.
		local ekCA = edgeKey(c, a)
		local outerTri = outerTris[ekCA]
		if outerTri ~= nil and outerTri ~= NO_NEIGHBOR then
			t.neighbors[3] = outerTri
			changeNeighborByEdge(self.triangles[outerTri], c, a, iT)
		else
			outerTris[ekCA] = iT
		end
	end

	-- Finalise: wire iT into parent, set back-reference, assign vertices, update adj tri.
	self.triangles[iParent].neighbors[iInParent] = iT
	t.neighbors[1] = iParent -- C++ n[0]: across base edge a-b
	t.vertices[1] = a
	t.vertices[2] = b
	t.vertices[3] = c
	setAdjTri(self, c, iT)
end

--[=[
	Triangulate the pseudo-polygon `poly` using the Lawson-Delaunay criterion.

	`poly` is an ordered list of vertex indices forming one boundary of a
	constrained-edge region.  `iT` is the seed triangle for this polygon;
	`iN` is the opposite-side seed triangle (becomes the parent of the root
	task, so `iN.neighbors[1]` will be set to `iT` once finalized).

	Preconditions:
	  #poly >= 3
	  outerTris already contains entries for every boundary edge of `poly`
	    (including the final edges to iB), with values being the outer
	    neighboring triangle or NO_NEIGHBOR for hull/hanging edges.
	  trianglesToReuse has at least (#poly - 3) entries.

	Corresponds to CDT C++ triangulatePseudoPolygon.
]=]
local function triangulatePseudoPolygon(
	self: CDTInternal,
	poly: { number },
	outerTris: { [number]: number },
	iT: number,
	iN: number,
	trianglesToReuse: { number },
	iterations: { { number } }
)
	-- Seed the task stack: full polygon [1..#poly], Luau iInParent=1
	-- → iN.neighbors[1] = iT once root task is finalized (C++ n[0] across base edge).
	table.clear(iterations)
	table.insert(iterations, { 1, #poly, iT, iN, 1 })
	while #iterations > 0 do
		tppIteration(self, poly, outerTris, trianglesToReuse, iterations)
	end
end

-- Insert a single vertex (by index) and restore the Delaunay property.
local function insertVertex(self: CDTInternal, iV: number)
	local v = self.vertices[iV]
	local walkStart = self._locator:nearPoint(v, self.vertices)
	local iT, iT2 = walkingSearchTrianglesAt(self, iV, walkStart)
	local triStack: { number }
	if iT2 == NO_NEIGHBOR then
		triStack = insertVertexInsideTriangle(self, iV, iT)
	else
		triStack = insertVertexOnEdge(self, iV, iT, iT2, true)
	end
	ensureDelaunayByEdgeFlips(self, iV, triStack)
	tryAddVertexToLocator(self, iV)
end

-- ── Public: insertVertices ────────────────────────────────────────────────────

--[=[
	Insert a batch of 2D points into the triangulation.

	May be called multiple times; the super-triangle is created automatically
	on the first call using a bounding box computed from `verts`.
	Insertion order is sequential (AsProvided in CDT terms).

	@param verts -- array of Vector2 points to insert
]=]
function CDT.insertVertices(self: CDTInternal, verts: { Vector2 })
	if self._isFinalized then
		error("CDT: cannot insert vertices into a finalized triangulation")
	end
	if #verts == 0 then
		return
	end

	local isFirstCall = (#self.vertices == 0)

	if isFirstCall then
		-- Compute bounding box of the incoming vertices.
		local minX, minY = math.huge, math.huge
		local maxX, maxY = -math.huge, -math.huge
		for _, v in verts do
			local x, y = v.X, v.Y
			if x < minX then
				minX = x
			end
			if y < minY then
				minY = y
			end
			if x > maxX then
				maxX = x
			end
			if y > maxY then
				maxY = y
			end
		end
		addSuperTriangle(self, minX, minY, maxX, maxY)
	end

	tryInitLocator(self)

	-- Append all new vertices first so indices are stable during insertion.
	local nExistingVerts = #self.vertices
	for _, v in verts do
		addNewVertex(self, v, NO_NEIGHBOR)
	end

	-- Insert and Delaunay-restore each new vertex.
	for iV = nExistingVerts + 1, #self.vertices do
		insertVertex(self, iV)
	end
end

-- ── Constrained edge insertion ───────────────────────────────────────────────

-- Advance _vertTris[v] one step clockwise (CDT C++ pivotVertexTriangleCW).
-- Uses t.next(v).first = t.neighbors[ vertexInd(t.vertices, v) ].
local function pivotVertexTriangleCW(self: CDTInternal, v: number)
	local iT = self._vertTris[v]
	local t = self.triangles[iT]
	self._vertTris[v] = t.neighbors[vertexInd(t.vertices, v)]
end

--[=[
	Mark undirected edge (iA, iB) as fixed.

	If the edge is already fixed the overlap counter is incremented.
	Corresponds to CDT C++ fixEdge(edge).
]=]
local function fixEdgeSimple(self: CDTInternal, iA: number, iB: number)
	local k = edgeKey(iA, iB)
	if self.fixedEdges[k] then
		self.overlapCount[k] = (self.overlapCount[k] or 0) + 1
	else
		self.fixedEdges[k] = true
	end
end

--[=[
	Mark edge (iA, iB) as a piece of `originalEdge` (iOrigA, iOrigB).

	Always calls fixEdgeSimple; additionally registers the original in
	pieceToOriginals when the piece differs from the original.
	Corresponds to CDT C++ fixEdge(edge, originalEdge).
]=]
local function fixEdge(self: CDTInternal, iA: number, iB: number, iOrigA: number, iOrigB: number)
	fixEdgeSimple(self, iA, iB)
	local k = edgeKey(iA, iB)
	local origK = edgeKey(iOrigA, iOrigB)
	if k ~= origK then
		if not self.pieceToOriginals[k] then
			self.pieceToOriginals[k] = {}
		end
		insertUnique(self.pieceToOriginals[k], origK)
	end
end

--[=[
	Split an already-fixed edge (v1, v2) at vertex iSplitVert.

	Removes the original fixed edge and registers both halves.
	Transfers overlap count and pieceToOriginals mappings.
	Corresponds to CDT C++ splitFixedEdge(edge, iSplitVert).
]=]
function splitFixedEdge(self: CDTInternal, v1: number, v2: number, iSplitVert: number)
	local origK = edgeKey(v1, v2)
	-- Remove original fixed marker.
	self.fixedEdges[origK] = nil
	-- Register both halves as fixed.
	fixEdgeSimple(self, v1, iSplitVert)
	fixEdgeSimple(self, iSplitVert, v2)
	local k1 = edgeKey(v1, iSplitVert)
	local k2 = edgeKey(iSplitVert, v2)
	-- Transfer overlap count.
	local ov = self.overlapCount[origK]
	if ov then
		self.overlapCount[k1] = (self.overlapCount[k1] or 0) + ov
		self.overlapCount[k2] = (self.overlapCount[k2] or 0) + ov
		self.overlapCount[origK] = nil
	end
	-- Build originals list: use existing pieceToOriginals if present, else {origK}.
	local newOriginals: { number }
	local existing = self.pieceToOriginals[origK]
	if existing then
		newOriginals = existing
		self.pieceToOriginals[origK] = nil
	else
		newOriginals = { origK }
	end
	if not self.pieceToOriginals[k1] then
		self.pieceToOriginals[k1] = {}
	end
	if not self.pieceToOriginals[k2] then
		self.pieceToOriginals[k2] = {}
	end
	insertUniqueList(self.pieceToOriginals[k1], newOriginals)
	insertUniqueList(self.pieceToOriginals[k2], newOriginals)
end

--[=[
	Add a split-point vertex and insert it on the edge between iT and iTopo.

	Allocates a new vertex at `pos`, calls insertVertexOnEdge, wires the
	locator, and runs Delaunay flips.  Returns the new vertex index.
	Corresponds to CDT C++ addSplitEdgeVertex.
]=]
local function addSplitEdgeVertex(self: CDTInternal, pos: Vector2, iT: number, iTopo: number): number
	-- Allocate but don't link to a triangle yet (NO_NEIGHBOR).
	local iSplit = #self.vertices + 1
	addNewVertex(self, pos, NO_NEIGHBOR)
	-- Insert on the shared edge; pass handleFixed=false to avoid recursion.
	local triStack = insertVertexOnEdge(self, iSplit, iT, iTopo, false)
	tryAddVertexToLocator(self, iSplit)
	ensureDelaunayByEdgeFlips(self, iSplit, triStack)
	return iSplit
end

--[=[
	Find the first triangle exiting vertex iA toward point b.

	Returns (iT, iVL, iVR) where:
	  iT  = the triangle index whose edge (iVL, iVR) is crossed by line a→b,
	        or NO_NEIGHBOR when a vertex of the fan lies exactly on the line.
	  iVL = the vertex on the left of  a→b  (or the on-line vertex when iT=NO_NEIGHBOR)
	  iVR = the vertex on the right of a→b  (same as iVL when on-line)

	Corresponds to CDT C++ intersectedTriangle.
]=]
local function intersectedTriangle(
	self: CDTInternal,
	iA: number,
	a: Vector2,
	b: Vector2,
	tol: number
): (number, number, number)
	local startTri = self._vertTris[iA]
	local iT = startTri
	repeat
		local t = self.triangles[iT]
		local i = vertexInd(t.vertices, iA)
		local iP2 = t.vertices[ccw(i)]
		local orientP2 = orient2D(self.vertices[iP2], a, b)
		if orientP2 < 0 then -- Right
			local iP1 = t.vertices[cw(i)]
			local orientP1 = orient2D(self.vertices[iP1], a, b)
			if orientP1 == 0 then -- OnLine exactly
				return NO_NEIGHBOR, iP1, iP1
			end
			if orientP1 > 0 then -- Left
				if tol > 0 then
					-- Snap near-collinear vertex to the constraint line.
					local absP1 = math.abs(orientP1)
					local absP2 = math.abs(orientP2)
					if absP1 <= absP2 then
						if absP1 / math.abs(orient2D(self.vertices[iP1], a, b)) <= tol then
							return NO_NEIGHBOR, iP1, iP1
						end
					else
						if absP2 / math.abs(orient2D(self.vertices[iP2], a, b)) <= tol then
							return NO_NEIGHBOR, iP2, iP2
						end
					end
				end
				return iT, iP1, iP2
			end
		end
		-- Advance CW: next triangle around iA = t.neighbors[ slot of iA ] (= t.next(iA).first)
		iT = t.neighbors[vertexInd(t.vertices, iA)]
	until iT == startTri
	error(string.format("CDT: could not find triangle intersected by constraint edge from vertex %d", iA))
end

-- Helper wrappers using CDTUtils index functions.
--[=[
	One iteration of constrained-edge insertion (CDT C++ insertEdgeIteration).

	Processes edge (iA→iB) and may push sub-edges onto `remaining`.
	`originalEdge` is the user-supplied edge (iOrigA, iOrigB) for
	pieceToOriginals bookkeeping.
	`tppIter` is the reusable task buffer for triangulatePseudoPolygon.
]=]
local function insertEdgeIteration(
	self: CDTInternal,
	iA: number,
	iB: number,
	iOrigA: number,
	iOrigB: number,
	remaining: { { number } }, -- list of {iA, iB} pairs
	tppIter: { { number } }
)
	if iA == iB then
		return
	end

	-- Edge already exists in triangulation: just mark it fixed and return.
	if hasEdge(self, iA, iB) then
		fixEdge(self, iA, iB, iOrigA, iOrigB)
		return
	end

	local a = self.vertices[iA]
	local b = self.vertices[iB]
	local iBOriginal = iB -- saved to detect on-line vertex splits

	local iT, iVL, iVR = intersectedTriangle(self, iA, a, b, 0)

	-- A vertex lies exactly on the constraint line: split into two sub-edges.
	if iT == NO_NEIGHBOR then
		fixEdge(self, iA, iVL, iOrigA, iOrigB)
		table.insert(remaining, { iVL, iB })
		return
	end

	local t = self.triangles[iT]
	local intersected: { number } = { iT }
	local polyL: { number } = { iA, iVL }
	local polyR: { number } = { iA, iVR }
	local outerTris: { [number]: number } = {}
	outerTris[edgeKey(iA, iVL)] = edgeNbr(t, iA, iVL)
	outerTris[edgeKey(iA, iVR)] = edgeNbr(t, iA, iVR)
	local iV = iA

	while not triContainsVertex(t, iB) do
		local iTopo = opposedTri(t, iV)
		local tOpo = self.triangles[iTopo]
		local iVopo = opposedVert(tOpo, iT)

		-- Intersecting fixed edges are not allowed in this port.
		if self.fixedEdges[edgeKey(iVL, iVR)] then
			-- TryResolve: split the intersecting fixed edge at the crossing point.
			local newPos = intersectionPosition(a, b, self.vertices[iVL], self.vertices[iVR])
			local iNewVert = addSplitEdgeVertex(self, newPos, iT, iTopo)
			splitFixedEdge(self, iVL, iVR, iNewVert)
			table.insert(remaining, { iA, iNewVert })
			table.insert(remaining, { iNewVert, iB })
			return
		end

		local loc = locatePointLine(self.vertices[iVopo], a, b)
		if loc == "Left" then
			local ek = edgeKey(polyL[#polyL], iVopo)
			local outer = edgeNbr(tOpo, polyL[#polyL], iVopo)
			if outerTris[ek] == nil then
				outerTris[ek] = outer
			else
				outerTris[ek] = NO_NEIGHBOR -- hanging edge
			end
			table.insert(polyL, iVopo)
			iV = iVL
			iVL = iVopo
		elseif loc == "Right" then
			local ek = edgeKey(polyR[#polyR], iVopo)
			local outer = edgeNbr(tOpo, polyR[#polyR], iVopo)
			if outerTris[ek] == nil then
				outerTris[ek] = outer
			else
				outerTris[ek] = NO_NEIGHBOR -- hanging edge
			end
			table.insert(polyR, iVopo)
			iV = iVR
			iVR = iVopo
		else -- OnLine: vertex on constraint, split here
			iB = iVopo
		end

		table.insert(intersected, iTopo)
		iT = iTopo
		t = self.triangles[iT]
	end

	-- Wire in the final outer edges reaching iB.
	outerTris[edgeKey(polyL[#polyL], iB)] = edgeNbr(t, polyL[#polyL], iB)
	outerTris[edgeKey(polyR[#polyR], iB)] = edgeNbr(t, polyR[#polyR], iB)
	table.insert(polyL, iB)
	table.insert(polyR, iB)

	-- Ensure iA / iB have valid adj triangles outside the intersected set.
	if self._vertTris[iA] == intersected[1] then
		pivotVertexTriangleCW(self, iA)
	end
	if self._vertTris[iB] == intersected[#intersected] then
		pivotVertexTriangleCW(self, iB)
	end

	-- Reverse polyR so both polys run iA → iB.
	local lo, hi = 1, #polyR
	while lo < hi do
		polyR[lo], polyR[hi] = polyR[hi], polyR[lo]
		lo += 1
		hi -= 1
	end

	-- Pop last two intersected triangles as seeds for TPP.
	local iTL = table.remove(intersected) :: number
	local iTR = table.remove(intersected) :: number

	triangulatePseudoPolygon(self, polyL, outerTris, iTL, iTR, intersected, tppIter)
	triangulatePseudoPolygon(self, polyR, outerTris, iTR, iTL, intersected, tppIter)

	-- Fix the (partial) edge. When an on-line vertex was encountered, iB was
	-- rebound mid-traversal; push the unprocessed remainder so the outer
	-- insertEdge loop handles it (CDT C++ iB != edge.v2() check).
	fixEdge(self, iA, iB, iOrigA, iOrigB)
	if iB ~= iBOriginal then
		table.insert(remaining, { iB, iBOriginal })
	end
end

--[=[
	Insert one constrained edge (iA→iB), iterating until done.

	Uses a local `remaining` stack to avoid recursion (CDT C++ insertEdge).
]=]
local function insertEdge(
	self: CDTInternal,
	iA: number,
	iB: number,
	iOrigA: number,
	iOrigB: number,
	tppIter: { { number } }
)
	local remaining: { { number } } = { { iA, iB } }
	while #remaining > 0 do
		local seg = table.remove(remaining) :: { number }
		insertEdgeIteration(self, seg[1], seg[2], iOrigA, iOrigB, remaining, tppIter)
	end
end

-- ── Public: insertEdges ───────────────────────────────────────────────────────

--[=[
	Insert a batch of constrained edges into the triangulation.

	Each edge is a pair of **0-based** vertex indices (matching the order in
	which vertices were supplied to `insertVertices`); internally they are
	shifted by +N_SUPER_VERTS to account for the three super-triangle vertices
	that occupy slots 1-3 of `self.vertices`.

	Must be called after `insertVertices` and before any `erase*` method.

	@param edges -- array of {v1: number, v2: number} pairs (0-based vertex indices)
]=]
function CDT.insertEdges(self: CDTInternal, edges: { { number } })
	if self._isFinalized then
		error("CDT: cannot insert edges into a finalized triangulation")
	end
	local tppIter: { { number } } = {}
	for _, e in edges do
		-- Shift from 0-based user indices to 1-based internal indices
		-- (+N_SUPER_VERTS accounts for the three super-triangle vertices).
		local iA = e[1] + N_SUPER_VERTS + 1
		local iB = e[2] + N_SUPER_VERTS + 1
		insertEdge(self, iA, iB, iA, iB, tppIter)
	end
end

-- ── Finalization and erasure ─────────────────────────────────────────────────

-- Re-map an edge key by subtracting N_SUPER_VERTS from both vertex indices.
-- Used during finalization to strip super-triangle vertex offsets.
local function remapEdgeKey(k: number): number
	local vLo = math.floor(k / EDGE_KEY_SHIFT)
	local vHi = k - vLo * EDGE_KEY_SHIFT
	return (vLo - N_SUPER_VERTS) * EDGE_KEY_SHIFT + (vHi - N_SUPER_VERTS)
end

--[=[
	Compact the triangle array by removing the indices in `toErase` and
	remapping all surviving neighbor references.
	Corresponds to CDT C++ removeTriangles.
]=]
local function removeTriangles(self: CDTInternal, toErase: { [number]: boolean })
	if next(toErase) == nil then
		return
	end
	local oldTris = self.triangles
	local newTris: { Triangle } = {}
	local triMap: { [number]: number } = {}
	local iTnew = 0
	for iT = 1, #oldTris do
		if not toErase[iT] then
			iTnew += 1
			triMap[iT] = iTnew
			newTris[iTnew] = oldTris[iT]
		end
	end
	-- Remap neighbor indices in surviving triangles.
	for _, t in newTris do
		local nn = t.neighbors
		for s = 1, 3 do
			local n = nn[s]
			if toErase[n] then
				nn[s] = NO_NEIGHBOR
			elseif n ~= NO_NEIGHBOR then
				nn[s] = triMap[n] :: number
			end
		end
	end
	self.triangles = newTris
end

--[=[
	Finalize the triangulation: clear adjacency, strip super-triangle
	vertices, remap edge key tables, remove the given triangles, and
	subtract N_SUPER_VERTS from every remaining triangle vertex index.
	Corresponds to CDT C++ finalizeTriangulation.
]=]
local function finalizeTriangulation(self: CDTInternal, toErase: { [number]: boolean })
	-- Clear per-vertex triangle cache (marks triangulation as finalized).
	table.clear(self._vertTris)

	-- Remove super-triangle vertices (always at front: slots 1..N_SUPER_VERTS).
	for _ = 1, N_SUPER_VERTS do
		table.remove(self.vertices, 1)
	end

	-- Remap fixed edges: subtract N_SUPER_VERTS from both vertex indices.
	local newFixed: { [number]: boolean } = {}
	for k in self.fixedEdges do
		newFixed[remapEdgeKey(k)] = true
	end
	self.fixedEdges = newFixed

	-- Remap overlap count.
	local newOverlap: { [number]: number } = {}
	for k, v in self.overlapCount do
		newOverlap[remapEdgeKey(k)] = v
	end
	self.overlapCount = newOverlap

	-- Remap piece-to-originals.
	local newP2O: { [number]: { number } } = {}
	for k, origList in self.pieceToOriginals do
		local newList: { number } = {}
		for _, ok in origList do
			table.insert(newList, remapEdgeKey(ok))
		end
		newP2O[remapEdgeKey(k)] = newList
	end
	self.pieceToOriginals = newP2O

	-- Remove erased triangles and remap neighbor indices.
	removeTriangles(self, toErase)

	-- Subtract N_SUPER_VERTS from every vertex slot in surviving triangles.
	for _, t in self.triangles do
		local vv = t.vertices
		for s = 1, 3 do
			vv[s] -= N_SUPER_VERTS
		end
	end

	self._isFinalized = true
end

--[=[
	Flood-fill from `seeds`, collecting all triangles reachable without
	crossing a fixed edge.  Corresponds to CDT C++ growToBoundary.
]=]
local function growToBoundary(self: CDTInternal, seeds: { number }): { [number]: boolean }
	local traversed: { [number]: boolean } = {}
	while #seeds > 0 do
		local iT = table.remove(seeds) :: number
		traversed[iT] = true
		local t = self.triangles[iT]
		for ns = 1, 3 do
			-- n[ns] is across edge v[ns]–v[ccw(ns)].
			local opEdge = edgeKey(t.vertices[ns], t.vertices[ccw(ns)])
			if self.fixedEdges[opEdge] then
				continue
			end
			local iN = t.neighbors[ns]
			if iN ~= NO_NEIGHBOR and not traversed[iN] then
				table.insert(seeds, iN)
			end
		end
	end
	return traversed
end

--[=[
	Peel one depth layer: flood-fill `seeds` at `layerDepth`, collecting
	triangles that lie behind fixed-edge boundaries for a deeper layer.
	Corresponds to CDT C++ peelLayer.
]=]
local function peelLayer(
	self: CDTInternal,
	seeds: { number },
	layerDepth: number,
	triDepths: { [number]: number }
): { [number]: number }
	local behindBoundary: { [number]: number } = {}
	while #seeds > 0 do
		local iT = table.remove(seeds) :: number
		if (triDepths[iT] or math.huge) > layerDepth then
			triDepths[iT] = layerDepth
		end
		-- Erase from behindBoundary: this triangle is processed now, not later.
		(behindBoundary :: any)[iT] = nil
		local t = self.triangles[iT]
		for ns = 1, 3 do
			local iN = t.neighbors[ns]
			if iN == NO_NEIGHBOR or (triDepths[iN] or math.huge) <= layerDepth then
				continue
			end
			local opEdge = edgeKey(t.vertices[ns], t.vertices[ccw(ns)])
			if self.fixedEdges[opEdge] then
				local ov = self.overlapCount[opEdge]
				behindBoundary[iN] = layerDepth + (ov or 0) + 1
			else
				table.insert(seeds, iN)
			end
		end
	end
	return behindBoundary
end

--[=[
	Compute a depth value for every triangle.

	Depth 0 = outermost region (touches super-triangle boundary).
	Odd depth = inside a constraint loop; even depth = outside / hole.
	Corresponds to CDT C++ calculateTriangleDepths.
]=]
local function calculateTriangleDepths(self: CDTInternal): { [number]: number }
	local INF = math.huge
	local triDepths: { [number]: number } = {}
	for iT = 1, #self.triangles do
		triDepths[iT] = INF
	end
	-- Seed from the first super-triangle vertex's adjacent triangle.
	local seeds: { number } = { self._vertTris[1] }
	local layerDepth = 0
	local deepestSeedDepth = 0
	local seedsByDepth: { [number]: { [number]: boolean } } = {}
	repeat
		local newSeeds = peelLayer(self, seeds, layerDepth, triDepths)
		seedsByDepth[layerDepth] = nil
		for iN, depth in newSeeds do
			if depth > deepestSeedDepth then
				deepestSeedDepth = depth
			end
			if not seedsByDepth[depth] then
				seedsByDepth[depth] = {}
			end
			seedsByDepth[depth][iN] = true
		end
		local nextSet = seedsByDepth[layerDepth + 1]
		seeds = {}
		if nextSet then
			for iT in nextSet do
				table.insert(seeds, iT)
			end
		end
		layerDepth += 1
	until #seeds == 0 and (deepestSeedDepth <= layerDepth)
	return triDepths
end

-- ── Public erasure methods ──────────────────────────────────────────────────────

--[=[
	Remove all triangles touching any super-triangle vertex, then finalize
	the vertex/triangle index space.

	After this call `vertices` and `triangles` hold the fully triangulated
	result with super-triangle vertices stripped.
]=]
function CDT.eraseSuperTriangle(self: CDTInternal)
	if self._isFinalized then
		error("CDT: triangulation already finalized")
	end
	local toErase: { [number]: boolean } = {}
	for iT = 1, #self.triangles do
		if touchesSuperTriangle(self.triangles[iT]) then
			toErase[iT] = true
		end
	end
	finalizeTriangulation(self, toErase)
end

--[=[
	Remove outer triangles via flood-fill from the first super-triangle vertex,
	stopping at fixed edges.  Leaves the inner triangulation intact.
]=]
function CDT.eraseOuterTriangles(self: CDTInternal)
	if self._isFinalized then
		error("CDT: triangulation already finalized")
	end
	local seeds: { number } = { self._vertTris[1] }
	local toErase = growToBoundary(self, seeds)
	finalizeTriangulation(self, toErase)
end

--[=[
	Remove outer triangles and holes using triangle-depth parity:
	even-depth triangles (0, 2, 4, …) are outside constraint loops and
	are erased; odd-depth triangles are kept.
]=]
function CDT.eraseOuterTrianglesAndHoles(self: CDTInternal)
	if self._isFinalized then
		error("CDT: triangulation already finalized")
	end
	local triDepths = calculateTriangleDepths(self)
	local toErase: { [number]: boolean } = {}
	for iT = 1, #self.triangles do
		if triDepths[iT] % 2 == 0 then
			toErase[iT] = true
		end
	end
	finalizeTriangulation(self, toErase)
end

-- ── Module exports ────────────────────────────────────────────────────────────

return CDT
