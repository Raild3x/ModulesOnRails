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
local Storage = require("./Storage")
local Triangulator = require("./Triangulator")
local Types = require("./Types")

export type DrawPrimitive = DrawListModule.DrawPrimitive
export type DrawList = DrawListModule.DrawList
export type CDTDrawOptions = DrawListModule.CDTDrawOptions
export type TriangulateInput = Types.TriangulateInput
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
