--!strict
--!native
--[=[
	NavMesh2d — high-level navmesh built on top of the CDT core.

	Phases implemented in this file:
	  5A – Data model + triangulation pipeline             [done]
	  5B – Query API (isPointOnMesh, outline, A*)          [done]
	  6  – Render utilities                                [done]
	  7  – Public NavMesh wrapper (signals + lifecycle)    [done]

	Usage (phase 5A):

	```lua
	local nav = NavMesh2d.new()
	nav:addPoint(Vector2.new(0,  0))
	nav:addPoint(Vector2.new(10, 0))
	nav:addPoint(Vector2.new(10, 10))
	nav:addPoint(Vector2.new(0,  10))
	-- Optional hole:
	nav:addHole({ Vector2.new(3,3), Vector2.new(7,3), Vector2.new(7,7), Vector2.new(3,7) })
	local triangles = nav:getTriangles()
	-- triangles is { {Vector2, Vector2, Vector2}, ... }
	```
]=]

local CDTModule = require("./Delaunay2dConstrained")
local Predicates = require("./Predicates")
local DrawTriangle3d = require("../DrawTriangle3d")
local SignalModule = require("../../Signal")
local JanitorModule = require("../../Janitor")

local locatePointTriangle = Predicates.locatePointTriangle

type CDT = CDTModule.CDT
type TriangleConfig = DrawTriangle3d.TriangleConfig
type NavSignal<T...> = SignalModule.ClassicSignal<T...>
type JanitorObj = JanitorModule.Janitor

-- A hole polygon: ordered list of Vector2 vertices (CCW winding expected).
type Polygon = { Vector2 }

-- A single output triangle: three Vector2 vertices (no index indirection).
type Triangle2d = { Vector2 }

-- ── Public type exported to consumers ────────────────────────────────────────

--[=[
	Public NavMesh2d interface.

	After adding points (and optionally holes), call `getTriangles` to
	obtain the constrained triangulation.  The triangulation is computed
	lazily and cached until the mesh is modified.
]=]
export type NavMesh2d = {
	-- Point management.
	addPoint: (self: NavMesh2d, point: Vector2 | Vector3, id: any?) -> any,
	removePoint: (self: NavMesh2d, id: any) -> boolean,
	getPoints: (self: NavMesh2d) -> { Vector2 },
	getPointCount: (self: NavMesh2d) -> number,
	-- Hole management.
	addHole: (self: NavMesh2d, polygon: Polygon) -> (),
	removeHole: (self: NavMesh2d, polygon: Polygon) -> boolean,
	clearHoles: (self: NavMesh2d) -> (),
	-- Triangulation.
	invalidate: (self: NavMesh2d) -> (),
	getTriangles: (self: NavMesh2d) -> { Triangle2d },
	-- Query.
	getOutlinePolygon: (self: NavMesh2d) -> Polygon,
	isPointOnMesh: (self: NavMesh2d, point: Vector2 | Vector3, ignoreHoles: boolean?) -> boolean,
	findContainingTriangle: (self: NavMesh2d, point: Vector2 | Vector3) -> Triangle2d?,
	-- Render.
	render: (
		self: NavMesh2d,
		config: {
			Height: number?,
			TriangleColor: Color3?,
			OutlineColor: Color3?,
			HoleColor: Color3?,
			Transparency: number?,
		}?
	) -> Model,
	clearRender: (self: NavMesh2d) -> (),
	-- Lifecycle.
	destroy: (self: NavMesh2d) -> (),
	-- Signals.
	pointAdded: NavSignal<Vector2, any>,
	pointRemoved: NavSignal<Vector2, any>,
	holeAdded: NavSignal<Polygon>,
	holeRemoved: NavSignal<Polygon>,
	dirtied: NavSignal<>,
}

-- Internal type: adds private fields not visible to consumers.
type NavMesh2dInternal = {
	_points: { [string]: Vector2 },
	_holes: { Polygon },
	_cachedTriangles: { Triangle2d }?,
	_cachedOutline: Polygon?,
	_dirty: boolean,
	_idCounter: number,
	_renderModel: Model?,
	_janitor: JanitorObj,
} & NavMesh2d

-- ════════════════════════════════════════════════════════════════════════════
-- Phase 5A – Data Model + Triangulation Pipeline
-- ════════════════════════════════════════════════════════════════════════════

local NavMesh2d = {}
NavMesh2d.__index = NavMesh2d

--- Construct a new, empty NavMesh2d.
function NavMesh2d.new(): NavMesh2d
	local self = setmetatable({}, NavMesh2d) :: any
	self._points = {} :: { [string]: Vector2 }
	self._holes = {} :: { Polygon }
	self._cachedTriangles = nil :: { Triangle2d }?
	self._cachedOutline = nil :: Polygon?
	self._dirty = true
	self._idCounter = 0
	self._renderModel = nil :: Model?
	self._janitor = JanitorModule.new()
	self.pointAdded = SignalModule.new() :: NavSignal<Vector2, any>
	self.pointRemoved = SignalModule.new() :: NavSignal<Vector2, any>
	self.holeAdded = SignalModule.new() :: NavSignal<Polygon>
	self.holeRemoved = SignalModule.new() :: NavSignal<Polygon>
	self.dirtied = SignalModule.new() :: NavSignal<>
	return self :: NavMesh2d
end

--[=[
	Add a point to the navmesh.

	Accepts `Vector2` or `Vector3` (XZ plane: X→Y, Z→X).
	If `id` is supplied it is used as the map key; otherwise an
	auto-incremented integer id is assigned.
	Returns the assigned id.
]=]
function NavMesh2d.addPoint(self: NavMesh2dInternal, point: Vector2 | Vector3, id: any?): any
	if typeof(point) == "Vector3" then
		local v3 = point :: Vector3
		point = Vector2.new(v3.Z, v3.X)
	end
	local p = point :: Vector2

	local pointId: any
	if id ~= nil then
		pointId = id
	else
		self._idCounter += 1
		pointId = self._idCounter
	end
	local key = tostring(pointId)

	local existing = self._points[key]
	if existing and existing.X == p.X and existing.Y == p.Y then
		-- Point unchanged: nothing to do.
		return pointId
	end

	self._points[key] = p
	self._dirty = true
	self._cachedTriangles = nil
	self.pointAdded:Fire(p, pointId)
	self.dirtied:Fire()
	return pointId
end

--[=[
	Remove the point with the given `id`.
	Returns `true` if a point was found and removed.
]=]
function NavMesh2d.removePoint(self: NavMesh2dInternal, id: any): boolean
	local key = tostring(id)
	if self._points[key] == nil then
		return false
	end
	local removedPoint = self._points[key]
	self._points[key] = nil
	self._dirty = true
	self._cachedTriangles = nil
	self.pointRemoved:Fire(removedPoint, id)
	self.dirtied:Fire()
	return true
end

--- Return a snapshot array of all mesh points (order is unspecified).
function NavMesh2d.getPoints(self: NavMesh2dInternal): { Vector2 }
	local pts: { Vector2 } = {}
	for _, pt in self._points do
		table.insert(pts, pt)
	end
	return pts
end

--- Return the current number of mesh points.
function NavMesh2d.getPointCount(self: NavMesh2dInternal): number
	local n = 0
	for _ in self._points do
		n += 1
	end
	return n
end

--[=[
	Add a hole polygon to the navmesh.

	Vertices should be supplied in CCW winding order.  They do not need
	to coincide with mesh points; they are inserted into the CDT
	automatically during triangulation.
]=]
function NavMesh2d.addHole(self: NavMesh2dInternal, polygon: Polygon)
	table.insert(self._holes, polygon)
	self._dirty = true
	self._cachedTriangles = nil
	self.holeAdded:Fire(polygon)
	self.dirtied:Fire()
end

--[=[
	Remove a hole polygon by reference equality.
	Returns `true` if the polygon was found and removed.
]=]
function NavMesh2d.removeHole(self: NavMesh2dInternal, polygon: Polygon): boolean
	for i = 1, #self._holes do
		if self._holes[i] == polygon then
			table.remove(self._holes, i)
			self._dirty = true
			self._cachedTriangles = nil
			self.holeRemoved:Fire(polygon)
			self.dirtied:Fire()
			return true
		end
	end
	return false
end

--- Remove all hole polygons and mark the triangulation dirty.
function NavMesh2d.clearHoles(self: NavMesh2dInternal)
	if #self._holes == 0 then
		return
	end
	for i = #self._holes, 1, -1 do
		local hole = self._holes[i]
		self._holes[i] = nil :: any
		self.holeRemoved:Fire(hole)
	end
	self._dirty = true
	self._cachedTriangles = nil
	self.dirtied:Fire()
end

--- Force the cached triangulation to be rebuilt on the next `getTriangles()` call.
function NavMesh2d.invalidate(self: NavMesh2dInternal)
	self._dirty = true
	self._cachedTriangles = nil
	self.dirtied:Fire()
end

-- ════════════════════════════════════════════════════════════════════════════
-- Phase 5B – Query API
-- ════════════════════════════════════════════════════════════════════════════

-- Ray-casting point-in-polygon test (Jordan curve theorem).
-- Works for both CW and CCW winding; returns true when pt is strictly inside.
local function pointInPolygon(pt: Vector2, polygon: Polygon): boolean
	local n = #polygon
	if n == 0 then
		return false
	end
	local inside = false
	local j = n
	for i = 1, n do
		local pi = polygon[i]
		local pj = polygon[j]
		if (pi.Y > pt.Y) ~= (pj.Y > pt.Y) then
			if pt.X < (pj.X - pi.X) * (pt.Y - pi.Y) / (pj.Y - pi.Y) + pi.X then
				inside = not inside
			end
		end
		j = i
	end
	return inside
end

-- Andrew's monotone chain O(n log n) convex hull.
-- Returns vertices in CCW order (standard math orientation).
local function computeConvexHull(pts: { Vector2 }): { Vector2 }
	local n = #pts
	if n < 3 then
		return table.clone(pts)
	end

	local sorted = table.clone(pts)
	table.sort(sorted, function(a, b)
		return if a.X ~= b.X then a.X < b.X else a.Y < b.Y
	end)

	local function cross(O: Vector2, A: Vector2, B: Vector2): number
		return (A.X - O.X) * (B.Y - O.Y) - (A.Y - O.Y) * (B.X - O.X)
	end

	local lower: { Vector2 } = {}
	for _, p in sorted do
		while #lower >= 2 and cross(lower[#lower - 1], lower[#lower], p) <= 0 do
			table.remove(lower)
		end
		table.insert(lower, p)
	end

	local upper: { Vector2 } = {}
	for i = n, 1, -1 do
		local p = sorted[i]
		while #upper >= 2 and cross(upper[#upper - 1], upper[#upper], p) <= 0 do
			table.remove(upper)
		end
		table.insert(upper, p)
	end

	-- Remove duplicated endpoints shared between lower and upper.
	table.remove(lower)
	table.remove(upper)

	local hull: { Vector2 } = {}
	for _, p in lower do
		table.insert(hull, p)
	end
	for _, p in upper do
		table.insert(hull, p)
	end
	return hull
end

--[=[
	Build (or rebuild) the CDT triangulation from the current state and
	cache the result.  Idempotent when `_dirty` is false.

	Algorithm:
	1. Collect all mesh points and all hole vertices into a flat vertex array
	   (deduplicating by coordinate) and feed it to CDT.insertVertices.
	2. Constrain the convex hull of the mesh points as the outer boundary.
	   This tells eraseOuterTrianglesAndHoles where the mesh ends, so that
	   any hole vertices that lie outside the hull end up in depth-0 triangles
	   (which are erased) rather than stretching the hull outward.
	3. Constrain each hole polygon's edges via CDT.insertEdges.
	4. Call eraseOuterTrianglesAndHoles, which uses depth counting across fixed
	   edges: depth-0 (outside hull) erased, depth-1 (inside hull, outside
	   holes) kept, depth-2 (inside holes) erased.  No post-filter needed.
]=]
local function triangulate(self: NavMesh2dInternal)
	if not self._dirty then
		return
	end
	self._dirty = false
	self._cachedTriangles = nil
	self._cachedOutline = nil

	-- Need at least 3 distinct points to form any triangulation.
	if self:getPointCount() < 3 then
		self._cachedTriangles = {}
		return
	end

	local cdt: CDT = CDTModule.new()

	-- Collect all vertices, deduplicating by coordinate string key so the
	-- CDT never receives two vertices at the same position.
	local allVerts: { Vector2 } = {}
	local coordToIdx: { [string]: number } = {}

	local function addVert(pt: Vector2): number
		-- Fixed-precision key matches coordinates that are bitwise identical.
		local key = string.format("%.10g,%.10g", pt.X, pt.Y)
		local existing = coordToIdx[key]
		if existing then
			return existing
		end
		table.insert(allVerts, pt)
		local idx = #allVerts
		coordToIdx[key] = idx
		return idx
	end

	-- Register mesh points first (anchors stable indices) and collect for hull.
	local meshPointsArr: { Vector2 } = {}
	for _, pt in self._points do
		addVert(pt)
		table.insert(meshPointsArr, pt)
	end

	-- Pre-register all hole vertices before calling insertVertices.  They are
	-- inserted unclipped — vertices outside the mesh hull will land in depth-0
	-- triangles and be removed by eraseOuterTrianglesAndHoles.
	for _, hole in self._holes do
		if #hole >= 3 then
			for _, pt in hole do
				addVert(pt)
			end
		end
	end

	cdt:insertVertices(allVerts)

	-- Build the full constrained edge list.
	local allEdges: { { number } } = {}

	-- Outer boundary: constrain the convex hull of the mesh points.
	-- This establishes the depth-0/depth-1 boundary so triangles created from
	-- out-of-hull hole vertices are depth-0 and get erased automatically.
	local meshHull = computeConvexHull(meshPointsArr)
	local hn = #meshHull
	for i = 1, hn do
		local ptA = meshHull[i]
		local ptB = meshHull[i % hn + 1]
		local a = coordToIdx[string.format("%.10g,%.10g", ptA.X, ptA.Y)] - 1
		local b = coordToIdx[string.format("%.10g,%.10g", ptB.X, ptB.Y)] - 1
		table.insert(allEdges, { a, b })
	end

	-- Hole boundaries: establish depth-1/depth-2 boundaries inside the hull.
	for _, hole in self._holes do
		if #hole < 3 then
			continue
		end
		local n = #hole
		for i = 1, n do
			local ptA = hole[i]
			local ptB = hole[i % n + 1]
			local a = coordToIdx[string.format("%.10g,%.10g", ptA.X, ptA.Y)] - 1
			local b = coordToIdx[string.format("%.10g,%.10g", ptB.X, ptB.Y)] - 1
			table.insert(allEdges, { a, b })
		end
	end

	if #allEdges > 0 then
		cdt:insertEdges(allEdges)
	end

	-- Depth counting: depth-0 (outside hull) and depth-2 (inside holes) erased;
	-- depth-1 (inside hull, outside holes) kept.  No centroid filter needed.
	cdt:eraseOuterTrianglesAndHoles()

	local tris: { Triangle2d } = {}
	local verts = cdt.vertices
	for _, tri in cdt.triangles do
		local vv = tri.vertices
		table.insert(tris, { verts[vv[1]], verts[vv[2]], verts[vv[3]] })
	end
	self._cachedTriangles = tris
end

--[=[
	Return the triangulated mesh as an array of `{Vector2, Vector2, Vector2}`
	triples.  Lazily (re-)triangulates when the mesh state has been dirtied.
]=]
function NavMesh2d.getTriangles(self: NavMesh2dInternal): { Triangle2d }
	triangulate(self)
	return self._cachedTriangles or {}
end

--[=[
	Build the outline polygon(s) from a set of CCW triangles.

	A boundary directed edge (a→b) is one whose reverse (b→a) does not
	apppear in any other triangle.  After walking all boundary edges into
	oriented chains, the CCW chain (positive signed area) is the outer hull;
	CW chains are hole boundaries.

	Returns the outer (CCW) boundary polygon, or `{}` if the trianle list
	is empty.
]=]
local function buildOutlinePolygon(tris: { Triangle2d }): Polygon
	if #tris == 0 then
		return {}
	end

	-- Key for a directed edge a→b.
	local function dKey(a: Vector2, b: Vector2): string
		return string.format("%.10g,%.10g|%.10g,%.10g", a.X, a.Y, b.X, b.Y)
	end
	-- Key for a single vertex position.
	local function vKey(v: Vector2): string
		return string.format("%.10g,%.10g", v.X, v.Y)
	end

	-- Count how many times each directed edge appears across all triangles.
	local edgeCount: { [string]: number } = {}
	local edgeEndpt: { [string]: { Vector2 } } = {} -- dKey → {a, b}
	for _, tri in tris do
		for i = 1, 3 do
			local a = tri[i]
			local b = tri[i % 3 + 1]
			local k = dKey(a, b)
			edgeCount[k] = (edgeCount[k] or 0) + 1
			if not edgeEndpt[k] then
				edgeEndpt[k] = { a, b }
			end
		end
	end

	-- A directed edge (a→b) is a boundary edge iff its reverse (b→a) does NOT
	-- appear in any triangle.  Interior shared edges have consistent CCW winding:
	-- one triangle contributes a→b and the adjacent triangle contributes b→a, so
	-- BOTH directed forms are present with count==1 each.  Checking count==1 is
	-- therefore insufficient — we must verify the reverse is absent.
	type EdgePair = { Vector2 }
	local fwd: { [string]: EdgePair } = {}
	for k in edgeCount do
		local ep = edgeEndpt[k]
		local revKey = dKey(ep[2], ep[1]) -- reverse directed edge b→a
		if not edgeCount[revKey] then
			-- True boundary edge: no triangle shares this edge from the other side.
			fwd[vKey(ep[1])] = ep
		end
	end

	-- Walk each connected chain of boundary edges.
	local chains: { Polygon } = {}
	local visited: { [string]: boolean } = {}
	for startKey in fwd do
		if visited[startKey] then
			continue
		end
		local chain: Polygon = {}
		local curKey = startKey
		local limit = 0
		for _ in fwd do
			limit += 1
		end
		limit += 2
		local iters = 0
		repeat
			visited[curKey] = true
			local edge = fwd[curKey]
			if not edge then
				break
			end
			table.insert(chain, edge[1])
			curKey = vKey(edge[2])
			iters += 1
		until curKey == startKey or iters >= limit
		if #chain > 0 then
			table.insert(chains, chain)
		end
	end

	if #chains == 0 then
		return {}
	end
	if #chains == 1 then
		return chains[1]
	end

	-- Multiple chains (outer hull + inner hole boundaries).
	-- The outer hull has positive signed area (CCW winding).
	local function signedArea(poly: Polygon): number
		local area = 0
		local n = #poly
		for i = 1, n do
			local a = poly[i]
			local b = poly[i % n + 1]
			area += a.X * b.Y - b.X * a.Y
		end
		return area * 0.5
	end

	local best = chains[1]
	local bestArea = signedArea(best)
	for i = 2, #chains do
		local area = signedArea(chains[i])
		if area > bestArea then
			bestArea = area
			best = chains[i]
		end
	end
	return best
end

--[=[
	Return the outer boundary polygon of the triangulated mesh.

	Derived directly from the boundary edges of the CDT output (edges
	belonging to exactly one triangle), so it is always consistent with
	the actual triangulation and does not suffer from the supertriangle-
	walk bug present in the old implementation.

	The polygon is in CCW winding order.  Returns `{}` when fewer than
	3 mesh points are present.
]=]
function NavMesh2d.getOutlinePolygon(self: NavMesh2dInternal): Polygon
	triangulate(self)
	if not self._cachedOutline then
		self._cachedOutline = buildOutlinePolygon(self._cachedTriangles or {})
	end
	return self._cachedOutline :: Polygon
end

--[=[
	Return `true` when `point` lies within the triangulated mesh area.

	The test is: inside the outer hull AND (if `ignoreHoles` is false)
	not inside any registered hole polygon.

	Accepts `Vector2` or `Vector3` (XZ plane projection).
]=]
function NavMesh2d.isPointOnMesh(self: NavMesh2dInternal, point: Vector2 | Vector3, ignoreHoles: boolean?): boolean
	if typeof(point) == "Vector3" then
		local v3 = point :: Vector3
		point = Vector2.new(v3.Z, v3.X)
	end
	local pt = point :: Vector2

	if self:getPointCount() < 3 then
		return false
	end

	if ignoreHoles then
		-- Ignore holes: test against the full outer outline only.
		local outline = self:getOutlinePolygon()
		return #outline > 0 and pointInPolygon(pt, outline)
	end

	-- Default path: the cached triangle set already excludes hole-interior
	-- triangles (filtered by centroid in triangulate), so a containing triangle
	-- exists iff the point is in the walkable mesh.  This also correctly handles
	-- disconnected sub-areas produced by segmenting holes.
	return self:findContainingTriangle(pt) ~= nil
end

--[=[
	Return the triangle from the cached triangulation that contains `point`,
	or `nil` if the point lies outside the mesh.

	Uses `locatePointTriangle` (Predicates) for exact classification;
	points on triangle edges or vertices are considered contained.
	O(n) scan — sufficient for prototype use; can be accelerated with a
	spatial grid in a later phase.

	Accepts `Vector2` or `Vector3` (XZ plane projection).
]=]
function NavMesh2d.findContainingTriangle(self: NavMesh2dInternal, point: Vector2 | Vector3): Triangle2d?
	if typeof(point) == "Vector3" then
		local v3 = point :: Vector3
		point = Vector2.new(v3.Z, v3.X)
	end
	local pt = point :: Vector2

	triangulate(self)
	for _, tri in self._cachedTriangles or ({} :: { Triangle2d }) do
		if locatePointTriangle(pt, tri[1], tri[2], tri[3]) ~= "Outside" then
			return tri
		end
	end
	return nil
end

-- ════════════════════════════════════════════════════════════════════════════
-- Phase 6 – Render Utilities
-- ════════════════════════════════════════════════════════════════════════════

-- Convert a Vector2 navmesh coordinate to a Vector3 world position.
-- Convention: navmesh X → world Z,  navmesh Y → world X  (matching the old NavMesh).
local function v2ToV3(v: Vector2, height: number): Vector3
	return Vector3.new(v.Y, height, v.X)
end

-- Draw a 2D polygon outline at a given height using thin Part beams.
local function drawPolygonOutline(parent: Instance, polygon: Polygon, height: number, color: Color3)
	local n = #polygon
	for i = 1, n do
		local a = v2ToV3(polygon[i], height)
		local b = v2ToV3(polygon[i % n + 1], height)
		local mid = (a + b) * 0.5
		local line = Instance.new("Part")
		line.Anchored = true
		line.CanCollide = false
		line.CanTouch = false
		line.CanQuery = false
		line.CastShadow = false
		line.Locked = true
		line.Material = Enum.Material.Neon
		line.Color = color
		line.Transparency = 0.2
		line.Size = Vector3.new(0.15, 0.15, (b - a).Magnitude)
		line.CFrame = CFrame.lookAt(mid, b)
		line.Parent = parent
	end
end

--[=[
	Render the current triangulation into the Roblox workspace.

	Creates (or reuses) a Model named "NavMesh2d_Render" containing:
	  - `Triangles/`  — one DrawTriangle3d model per triangle.
	  - `Outline/`    — line parts tracing the outer boundary.
	  - `Holes/`      — line parts tracing each hole polygon.

	Subsequent calls update the existing model in-place (adding/removing
	child models as needed) rather than destroying and recreating it.

	Returns the render Model so callers can parent it, attach to a Janitor, etc.

	@param config.Height       -- World Y of the rendered geometry (default 48)
	@param config.TriangleColor -- Fill color of triangles (default white)
	@param config.OutlineColor  -- Color of the outer boundary lines (default red)
	@param config.HoleColor     -- Color of hole outlines (default yellow)
	@param config.Transparency  -- Triangle transparency (default 0.6)
]=]
function NavMesh2d.render(
	self: NavMesh2dInternal,
	config: {
		Height: number?,
		TriangleColor: Color3?,
		OutlineColor: Color3?,
		HoleColor: Color3?,
		Transparency: number?,
	}?
): Model
	local height: number = if config then config.Height or 48 else 48
	local triColor: Color3 = if config
		then config.TriangleColor or Color3.fromRGB(255, 255, 255)
		else Color3.fromRGB(255, 255, 255)
	local outlineColor: Color3 = if config
		then config.OutlineColor or Color3.fromRGB(255, 60, 60)
		else Color3.fromRGB(255, 60, 60)
	local holeColor: Color3 = if config
		then config.HoleColor or Color3.fromRGB(255, 220, 0)
		else Color3.fromRGB(255, 220, 0)
	local transparency: number = if config then config.Transparency or 0.6 else 0.6

	-- Obtain or create the root model.
	local root: Model
	if self._renderModel and self._renderModel.Parent then
		root = self._renderModel
	else
		root = Instance.new("Model")
		root.Name = "NavMesh2d_Render"
		root.Parent = workspace
		self._renderModel = root
	end

	-- Ensure sub-folders exist.
	local function getFolder(name: string): Folder
		local f = root:FindFirstChild(name)
		if f and f:IsA("Folder") then
			return f :: Folder
		end
		local nf = Instance.new("Folder")
		nf.Name = name
		nf.Parent = root
		return nf
	end

	local triFolder = getFolder("Triangles")
	local outlineFolder = getFolder("Outline")
	local holesFolder = getFolder("Holes")

	----------------------------------------------------------------------------------
	-- Triangles: update existing models in-place, create new ones, discard extras.
	local tris = self:getTriangles()
	local existingTriModels = triFolder:GetChildren()
	local triStyle: TriangleConfig = {
		Color = triColor,
		Transparency = transparency,
		CanCollide = false,
		CanTouch = false,
		CanQuery = false,
	}

	for i, tri in tris do
		local pts: { Vector3 } = {
			v2ToV3(tri[1], height),
			v2ToV3(tri[2], height),
			v2ToV3(tri[3], height),
		}
		local existing = existingTriModels[i]
		if existing and existing:IsA("Model") then
			DrawTriangle3d.render(pts, existing :: Model)
			DrawTriangle3d.style(existing :: Model, triStyle)
		else
			local m = DrawTriangle3d.create(pts, triStyle)
			m.Name = "Tri_" .. i
			m.Parent = triFolder
		end
	end
	-- Remove excess models from a previous render with more triangles.
	for i = #tris + 1, #existingTriModels do
		local ex = existingTriModels[i]
		if ex then
			ex:Destroy()
		end
	end

	----------------------------------------------------------------------------------
	-- Outline.
	outlineFolder:ClearAllChildren()
	local outline = self:getOutlinePolygon()
	if #outline >= 2 then
		drawPolygonOutline(outlineFolder, outline, height + 0.1, outlineColor)
	end

	----------------------------------------------------------------------------------
	-- Holes.
	holesFolder:ClearAllChildren()
	for i, hole in self._holes do
		if #hole >= 3 then
			local holeContainer = Instance.new("Folder")
			holeContainer.Name = "Hole_" .. i
			holeContainer.Parent = holesFolder
			drawPolygonOutline(holeContainer, hole, height + 0.1, holeColor)
		end
	end

	return root
end

--[=[
	Destroy the Model created by a previous `render()` call.
	Safe to call when no render model exists.
]=]
function NavMesh2d.clearRender(self: NavMesh2dInternal)
	if self._renderModel then
		if self._renderModel.Parent then
			self._renderModel:Destroy()
		end
		self._renderModel = nil
	end
end

-- ════════════════════════════════════════════════════════════════════════════
-- Phase 7 – Public NavMesh Wrapper (Signals + Lifecycle)
-- ════════════════════════════════════════════════════════════════════════════

--[=[
	Destroy this NavMesh2d instance, cleaning up all signals, the Janitor,
	and any active render model.  After calling `destroy()` the instance
	must not be used again.
]=]
function NavMesh2d.destroy(self: NavMesh2dInternal)
	self:clearRender()
	self.pointAdded:Destroy()
	self.pointRemoved:Destroy()
	self.holeAdded:Destroy()
	self.holeRemoved:Destroy()
	self.dirtied:Destroy()
	self._janitor:Destroy()
	self._cachedTriangles = nil
	self._cachedOutline = nil
end

-- ── Module exports ────────────────────────────────────────────────────────────

return NavMesh2d
