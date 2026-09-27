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
	.TileSize number? -- studs, from 1/256 to 32768; tiles are aligned to the world origin (default: per floor, about 36 edges per tile, a power of two from 4 to 256)

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

--[=[
	@within NavMesh
	@interface QueryFilter
	.AreaCosts { [number]: number }? -- cost multiplier per area id (default 1, >= 0); math.huge excludes the area
	.MaxExpansions number? -- stop with "Budget" after expanding this many triangles (default unlimited)
	.SnapExtents Vector3? -- half-size of the snap box around a feet position (default (0.5, 4, 0.5))

	`AgentRadius` arrives with clearance (ticket 15).
]=]
export type QueryFilter = {
	AreaCosts: { [number]: number }?,
	MaxExpansions: number?,
	SnapExtents: Vector3?,
}

--[=[
	@within NavMesh
	@interface Waypoint
	.Position Vector3
	.Floor string
	.Label string? -- set where a link starts (ticket 16)
]=]
export type Waypoint = { Position: Vector3, Floor: string, Label: string? }

--[=[
	@within NavMesh
	@type PathStatus "Success" | "Partial" | "Budget" | "NoStart" | "NoGoal"
	- `Success`: reached the goal.
	- `Partial`: the goal is unreachable; the waypoints end at the reachable point nearest it.
	- `Budget`: `MaxExpansions` was hit; the waypoints end at the point nearest the goal found so
	  far.
	- `NoStart` / `NoGoal`: that end could not be snapped onto the mesh (no waypoints).
]=]
export type PathStatus = "Success" | "Partial" | "Budget" | "NoStart" | "NoGoal"

--[=[
	@within NavMesh
	@interface PathResult
	.Status PathStatus
	.Waypoints { Waypoint } -- from the snapped start
	.Cost number -- the search cost: 3D length times area multipliers, measured through the midpoints of the edges crossed
	.TileStamps { number } -- opaque; filled once Update lands (ticket 18)
]=]
export type PathResult = { Status: PathStatus, Waypoints: { Waypoint }, Cost: number, TileStamps: { number } }

return {}
