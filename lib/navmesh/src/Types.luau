--!strict
-- Authors: Logan Hunt (Raildex)
-- September 25, 2026
-- Shared public types, kept in their own module so leaf modules (Build, Fixtures, ...) can use
-- them without requiring the public module (which requires them back).

--[=[
	@within NavMesh
	@type Polygon { Vector3 }
	A ring in the XZ plane, in any orientation. Y is the surface height at that vertex, so ramps
	are allowed; Y is ignored for obstacle and area rings. Coordinates must lie within ±32,768
	studs.
]=]
export type Polygon = { Vector3 }

--[=[
	@within NavMesh
	@interface AreaDesc
	.Polygon Polygon
	.Area number -- area id (an integer >= 1); later entries win where areas overlap
]=]
export type AreaDesc = { Polygon: Polygon, Area: number }

--[=[
	@within NavMesh
	@interface FloorDesc
	.Walkable { Polygon } -- unioned; overlapping rings must agree in height
	.Obstacles { Polygon }? -- subtracted
	.Areas { AreaDesc }?
	.Area number? -- area id of walkable surface not covered by Areas (default 1)
]=]
export type FloorDesc = {
	Walkable: { Polygon },
	Obstacles: { Polygon }?,
	Areas: { AreaDesc }?,
	Area: number?,
}

--[=[
	@within NavMesh
	@interface NavMeshDesc
	.Floors { [string]: FloorDesc }
	.TileSize number? -- studs, from 1/256 to 32768; tiles are aligned to the world origin (default 32)

	The authored description a mesh is built from. Part→polygon conversion belongs in a separate
	adapter package (Q1).
]=]
export type NavMeshDesc = {
	Floors: { [string]: FloorDesc },
	TileSize: number?,
}

--[=[
	@within NavMesh
	@interface NavMeshDrawOptions
	.Triangles boolean? -- default true: triangles coloured by floor, plus walls
	.Areas boolean? -- colour triangles by area id instead of floor
	.Tiles boolean? -- tile bounds
]=]
export type NavMeshDrawOptions = {
	Triangles: boolean?,
	Areas: boolean?,
	Tiles: boolean?,
}

return {}
