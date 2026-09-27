--!strict
--!native
-- Authors: Logan Hunt (Raildex)
-- September 25, 2026
--[=[
	@class ConstrainedDelaunay

	Constrained Delaunay triangulation with winding-group classification. Results are
	plain state (network-safe): read them only through this module's functions.

	```lua
	local CDT = require(Packages.ConstrainedDelaunay)
	local triangulation = CDT.Triangulate({ Coords = { 0,0, 10,0, 10,10, 0,10, 5,5 } })
	for t = 1, CDT.TriangleCount(triangulation) do
		local a, b, c = CDT.GetTriangle(triangulation, t) -- counter-clockwise vertex ids
	end
	local hit = CDT.Locate(triangulation, 2, 3) -- 0 when outside the convex hull
	```

	See `docs/plans/navmesh/spec.md` for the full API; it lands ticket by ticket.
]=]

local DrawListModule = require("./DrawList")
local Fixtures = require("./Fixtures")
local Locate = require("./Locate")
local PlainData = require("./PlainData")
local Predicates = require("./Predicates")
local Refine = require("./Refine")
local Storage = require("./Storage")
local Triangulator = require("./Triangulator")
local Types = require("./Types")

export type DrawPrimitive = DrawListModule.DrawPrimitive
export type DrawList = DrawListModule.DrawList
export type CDTDrawOptions = DrawListModule.CDTDrawOptions
export type TriangulateInput = Types.TriangulateInput
export type RefineOptions = Refine.RefineOptions
--[=[
	@within ConstrainedDelaunay
	@type Triangulation {}
	Opaque plain state; read it only through this module's functions (S1).
]=]
export type Triangulation = Storage.State

local ConstrainedDelaunay = {}

--[=[
	@within ConstrainedDelaunay
	Builds the (constrained) Delaunay triangulation of the input. Covers the convex hull;
	exact duplicate points merge.
]=]
function ConstrainedDelaunay.Triangulate(input: TriangulateInput): Triangulation
	return Triangulator.Build(input)
end

-- Readers re-export the Storage function of the same name (S1).
ConstrainedDelaunay.VertexCount = Storage.VertexCount
ConstrainedDelaunay.TriangleCount = Storage.TriangleCount
ConstrainedDelaunay.GroupCount = Storage.GroupCount
ConstrainedDelaunay.GetVertex = Storage.GetVertex
ConstrainedDelaunay.InputVertexOf = Storage.InputVertexOf
ConstrainedDelaunay.VertexOfInput = Storage.VertexOfInput
ConstrainedDelaunay.GetTriangle = Storage.GetTriangle
ConstrainedDelaunay.GetNeighbor = Storage.GetNeighbor
ConstrainedDelaunay.GetCoveringEdgeCount = Storage.GetCoveringEdgeCount
ConstrainedDelaunay.GetCoveringEdge = Storage.GetCoveringEdge
ConstrainedDelaunay.GetWinding = Storage.GetWinding

ConstrainedDelaunay.Locate = Locate.Locate

--[=[
	@within ConstrainedDelaunay
	@interface RefineOptions
	.MinAngle number? -- degrees, from 0 to below 60 (default 0). Termination is guaranteed only up to about 20.7 with no input angle below 60; triangles whose small angle comes from the input are skipped (P6)
	.MaxArea number? -- default unlimited
	.MaxSteiner number? -- vertices this call may add; default max(1024, 4 * input point count)
]=]

--[=[
	@within ConstrainedDelaunay
	Refines the triangulation in place (Ruppert) until every triangle meets `MinAngle` and
	`MaxArea`. Constrained and hull edges act as segments (SR8): they are split, never crossed,
	so new vertices stay inside the hull. Every triangle is refined, whatever its winding (the
	caller filters). Winding and constraint coverage are kept. Returns false when `MaxSteiner`
	vertices were added before the bounds were met.

	```lua
	local done = CDT.Refine(triangulation, { MinAngle = 20, MaxArea = 4 })
	```
]=]
function ConstrainedDelaunay.Refine(triangulation: Triangulation, options: RefineOptions): boolean
	return Refine.Refine(triangulation, options)
end
ConstrainedDelaunay.ToDrawList = DrawListModule.ToDrawList

--[=[
	@within ConstrainedDelaunay
	@prop PlainData PlainData
	Network-safety validator for plain state.
]=]
ConstrainedDelaunay.PlainData = PlainData

--[=[
	@within ConstrainedDelaunay
	@prop Fixtures ConstrainedDelaunayFixtures
	Shared scenarios used by specs, the render script and benchmarks.
]=]
ConstrainedDelaunay.Fixtures = Fixtures

-- Exact predicates (stable public API; NavMesh's snap rounding uses the same implementation).
ConstrainedDelaunay.Orient2D = Predicates.Orient2D
ConstrainedDelaunay.InCircle = Predicates.InCircle

return ConstrainedDelaunay
