--!strict
--!native
--[=[
	DelaunayTriangleSet — low-level triangle and vertex storage.

	Owns the `vertices` and `triangles` arrays along with the per-vertex
	adjacent-triangle map (`_vertTris`).  Every method is purely topological:
	no Delaunay-specific logic (circumcircles, constrained edges, etc.) lives
	here.

	This type is composed inside the CDT class, which handles the higher-level
	Delaunay algorithms on top of these primitives.
]=]

local CDTUtils = require("./CDTUtils")

type Triangle = CDTUtils.Triangle

local NO_VERTEX = CDTUtils.NO_VERTEX
local NO_NEIGHBOR = CDTUtils.NO_NEIGHBOR
local N_SUPER_VERTS = CDTUtils.N_SUPER_VERTS
local makeTriangle = CDTUtils.makeTriangle
local nextTriAndVert = CDTUtils.nextTriAndVert
local vertexInd = CDTUtils.vertexInd

-- ── Type ──────────────────────────────────────────────────────────────────────

export type DelaunayTriangleSet = {
	-- Triangle and vertex storage.
	vertices: { Vector2 },
	triangles: { Triangle },
	-- Per-vertex: index of one adjacent triangle (used for fan-walks).
	_vertTris: { number },

	-- Accessors (prefer these over direct field indexing).
	clear: (self: DelaunayTriangleSet) -> (),
	getTriangle: (self: DelaunayTriangleSet, iT: number) -> Triangle,
	getVertexFromIndex: (self: DelaunayTriangleSet, iV: number) -> Vector2,
	getTriangleCount: (self: DelaunayTriangleSet) -> number,
	getVertexCount: (self: DelaunayTriangleSet) -> number,
	getTrianglePoints: (self: DelaunayTriangleSet, iT: number) -> (Vector2, Vector2, Vector2),
	getTrianglesWithVertex: (self: DelaunayTriangleSet, v: number, result: { number }?) -> { number },

	-- Mutators.
	addVertex: (self: DelaunayTriangleSet, pos: Vector2, iT: number) -> number,
	addTriangle: (self: DelaunayTriangleSet, t: Triangle) -> number,
	setAdjTri: (self: DelaunayTriangleSet, v: number, iT: number) -> (),
	changeNeighbor: (self: DelaunayTriangleSet, iT: number, oldN: number, newN: number) -> (),
	hasEdge: (self: DelaunayTriangleSet, a: number, b: number) -> boolean,
	edgeTriangles: (self: DelaunayTriangleSet, a: number, b: number) -> (number, number),
	addSuperTriangle: (
		self: DelaunayTriangleSet,
		minX: number,
		minY: number,
		maxX: number,
		maxY: number
	) -> (),
	removeTriangles: (self: DelaunayTriangleSet, toErase: { [number]: boolean }) -> (),
	pivotVertexTriangleCW: (self: DelaunayTriangleSet, v: number) -> (),
}

-- ── Class ─────────────────────────────────────────────────────────────────────

local DelaunayTriangleSet = {}
DelaunayTriangleSet.__index = DelaunayTriangleSet

--- Construct a new, empty triangle set.
function DelaunayTriangleSet.new(): DelaunayTriangleSet
	local self = setmetatable({}, DelaunayTriangleSet) :: any
	self.vertices = {} :: { Vector2 }
	self.triangles = {} :: { Triangle }
	self._vertTris = {} :: { number }
	return self :: any
end

-- ── Accessors ────────────────────────────────────────────────────────────────

--[=[
	Reset the set to an empty state, discarding all vertices and triangles.
]=]
function DelaunayTriangleSet.clear(self: DelaunayTriangleSet)
	table.clear(self.vertices)
	table.clear(self.triangles)
	table.clear(self._vertTris)
end

--- Return the triangle at index `iT`.
function DelaunayTriangleSet.getTriangle(self: DelaunayTriangleSet, iT: number): Triangle
	return self.triangles[iT]
end

--- Return the vertex position at index `iV`.
function DelaunayTriangleSet.getVertexFromIndex(self: DelaunayTriangleSet, iV: number): Vector2
	return self.vertices[iV]
end

--- Return the number of triangles currently stored.
function DelaunayTriangleSet.getTriangleCount(self: DelaunayTriangleSet): number
	return #self.triangles
end

--- Return the number of vertices currently stored.
function DelaunayTriangleSet.getVertexCount(self: DelaunayTriangleSet): number
	return #self.vertices
end

--[=[
	Return the three `Vector2` positions of the vertices of triangle `iT`.
]=]
function DelaunayTriangleSet.getTrianglePoints(self: DelaunayTriangleSet, iT: number): (Vector2, Vector2, Vector2)
	local vv = self.triangles[iT].vertices
	local verts = self.vertices
	return verts[vv[1]], verts[vv[2]], verts[vv[3]]
end

--[=[
	Return all triangle indices that share vertex `v`.

	Uses the CCW fan stored in `_vertTris` — O(degree) rather than O(N).
	An optional pre-allocated `result` table can be passed to avoid allocation.
]=]
function DelaunayTriangleSet.getTrianglesWithVertex(
	self: DelaunayTriangleSet,
	v: number,
	result: { number }?
): { number }
	local out = result or {}
	local triStart = self._vertTris[v]
	if triStart == NO_NEIGHBOR then
		return out
	end
	local iT = triStart
	repeat
		table.insert(out, iT)
		local iTNext = nextTriAndVert(self.triangles[iT], v)
		iT = iTNext
	until iT == triStart or iT == NO_NEIGHBOR
	return out
end

-- ── Vertex helpers ────────────────────────────────────────────────────────────

--[=[
	Append vertex `pos`, recording `iT` as its initial adjacent triangle.
	Returns the 1-based index of the new vertex.
]=]
function DelaunayTriangleSet.addVertex(self: DelaunayTriangleSet, pos: Vector2, iT: number): number
	local idx = #self.vertices + 1
	self.vertices[idx] = pos
	self._vertTris[idx] = iT
	return idx
end

-- ── Triangle helpers ──────────────────────────────────────────────────────────

--[=[
	Append triangle `t` to the list; return its 1-based index.
]=]
function DelaunayTriangleSet.addTriangle(self: DelaunayTriangleSet, t: Triangle): number
	local idx = #self.triangles + 1
	self.triangles[idx] = t
	return idx
end

--[=[
	Record `iT` as the canonical adjacent triangle for vertex `v`.
]=]
function DelaunayTriangleSet.setAdjTri(self: DelaunayTriangleSet, v: number, iT: number)
	self._vertTris[v] = iT
end

--[=[
	Find and replace `oldN` with `newN` in the neighbor list of triangle `iT`.
	No-op when `iT` is NO_NEIGHBOR.
]=]
function DelaunayTriangleSet.changeNeighbor(self: DelaunayTriangleSet, iT: number, oldN: number, newN: number)
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

-- ── Edge queries ──────────────────────────────────────────────────────────────

--[=[
	Return true when undirected edge (a, b) already exists in the triangulation.
	Walks the CCW fan of triangles around vertex `a`.
]=]
function DelaunayTriangleSet.hasEdge(self: DelaunayTriangleSet, a: number, b: number): boolean
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

--[=[
	Return `(iT, iTNext)` — the two triangles sharing edge (a, b),
	or `(NO_NEIGHBOR, NO_NEIGHBOR)` when the edge is absent.
]=]
function DelaunayTriangleSet.edgeTriangles(self: DelaunayTriangleSet, a: number, b: number): (number, number)
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

-- ── Initialization ────────────────────────────────────────────────────────────

--[=[
	Insert the 3 super-triangle vertices and the single covering triangle.

	The super-triangle is an equilateral-like triangle that entirely encloses
	the bounding box `[minX, maxX] × [minY, maxY]`.  All subsequent user
	vertices are guaranteed to lie strictly inside it.

	Super-triangle geometry:
	  r      = max(2 · max(w, h), 1)
	  R      = 2 · r
	  v1     = (cx − R·cos30°,  cy − r)
	  v2     = (cx + R·cos30°,  cy − r)
	  v3     = (cx,             cy + R)
]=]
function DelaunayTriangleSet.addSuperTriangle(
	self: DelaunayTriangleSet,
	minX: number,
	minY: number,
	maxX: number,
	maxY: number
)
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
	self:addVertex(sv1, 1)
	self:addVertex(sv2, 1)
	self:addVertex(sv3, 1)
	self:addTriangle(makeTriangle(1, 2, 3, NO_NEIGHBOR, NO_NEIGHBOR, NO_NEIGHBOR))
end

-- ── Compaction ────────────────────────────────────────────────────────────────

--[=[
	Compact the triangle array by removing every index in `toErase` and
	remapping all surviving neighbor references to the new indices.

	All erased-neighbor slots are set to NO_NEIGHBOR.
]=]
function DelaunayTriangleSet.removeTriangles(self: DelaunayTriangleSet, toErase: { [number]: boolean })
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

-- ── Fan navigation ────────────────────────────────────────────────────────────

--[=[
	Advance `_vertTris[v]` one step clockwise around vertex `v`
	(CDT C++ `pivotVertexTriangleCW`).

	Uses `t.next(v).first = t.neighbors[ vertexInd(t.vertices, v) ]`.
]=]
function DelaunayTriangleSet.pivotVertexTriangleCW(self: DelaunayTriangleSet, v: number)
	local iT = self._vertTris[v]
	local t = self.triangles[iT]
	self._vertTris[v] = t.neighbors[vertexInd(t.vertices, v)]
end

-- ── Module export ─────────────────────────────────────────────────────────────

return DelaunayTriangleSet
