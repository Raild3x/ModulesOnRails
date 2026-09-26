--!strict
-- Authors: Logan Hunt (Raildex)
-- September 25, 2026
-- Shared public types, kept in their own module so leaf modules (Fixtures, Storage, ...) can
-- use them without requiring the public module (which requires them back).

--[=[
	@within ConstrainedDelaunay
	@interface TriangulateInput
	.Coords { number } -- flat x,y pairs; exact duplicates are merged
	.Edges { number }? -- directed constraint edges as flat 1-based input-point index pairs {a1,b1,a2,b2,...}
	.EdgeGroups { number }? -- group per edge (parallel to Edges/2), default 1; 0 = no winding. Groups >= 1 must be closed loops.
]=]
export type TriangulateInput = {
	Coords: { number },
	Edges: { number }?,
	EdgeGroups: { number }?,
}

return {}
