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
	@interface SeamDesc
	.FloorA string
	.FloorB string
	.From Vector3
	.To Vector3

	A walk-through joint between two floors, such as the foot of a staircase. The segment must
	lie on the edge of both floors' walkable surfaces (Build errors otherwise).
]=]
export type SeamDesc = { FloorA: string, FloorB: string, From: Vector3, To: Vector3 }

--[=[
	@within NavMesh
	@interface LinkDesc
	.From Vector3 -- snapped onto a floor at Build (feet position)
	.To Vector3
	.Bidirectional boolean? -- default true
	.Cost number? -- default the 3D distance From -> To; scaled by the area's cost multiplier
	.Area number? -- area id for AreaCosts (default 1)
	.Label string? -- copied onto the waypoint where the link starts

	A jump, ladder or teleport between two points. Link id = its 1-based index in `Links`.
]=]
export type LinkDesc = {
	From: Vector3,
	To: Vector3,
	Bidirectional: boolean?,
	Cost: number?,
	Area: number?,
	Label: string?,
}

--[=[
	@within NavMesh
	@interface NavMeshDesc
	.Floors { [string]: FloorDesc }
	.Seams { SeamDesc }?
	.Links { LinkDesc }? -- link id = its 1-based index
	.TileSize number? -- studs, from 1/256 to 32768; tiles are aligned to the world origin (default: per floor, about 36 edges per tile, a power of two from 4 to 256)
	.MaxAgentRadius number? -- optional cap on AgentRadius (studs); bounds how far Build and Update compute clearance, so set it when you can: uncapped, Update costs 30-50% more (default: no cap)

	The authored description a mesh is built from. Part→polygon conversion belongs in a separate
	adapter package (Q1).
]=]
export type NavMeshDesc = {
	Floors: { [string]: FloorDesc },
	Seams: { SeamDesc }?,
	Links: { LinkDesc }?,
	TileSize: number?,
	MaxAgentRadius: number?,
}

--[=[
	@within NavMesh
	@interface NavMeshDrawOptions
	.Triangles boolean? -- default true: triangles coloured by floor, plus walls
	.Areas boolean? -- colour triangles by area id instead of floor
	.Clearance boolean? -- colour triangles by their widest crossing, red (under 1 stud) to green (8 and over)
	.Seams boolean? -- seam portals, on the Seams layer
	.Links boolean? -- links as arrows (both ways when bidirectional), on the Links layer
	.Tiles boolean? -- tile bounds
]=]
export type NavMeshDrawOptions = {
	Triangles: boolean?,
	Areas: boolean?,
	Clearance: boolean?,
	Tiles: boolean?,
	Seams: boolean?,
	Links: boolean?,
}

--[=[
	@within NavMesh
	@interface QueryFilter
	.AgentRadius number? -- studs (default 0), up to the mesh's MaxAgentRadius; paths only go where the agent fits, and turn this far from wall corners (straight stretches are not offset from walls). The path's end point is not offset.
	.AreaCosts { [number]: number }? -- cost multiplier per area id (default 1, >= 0); math.huge excludes the area
	.MaxExpansions number? -- stop with "Budget" after expanding this many triangles (default unlimited)
	.SnapExtents Vector3? -- half-size of the snap box around a feet position (default (0.5, 4, 0.5))

]=]
export type QueryFilter = {
	AgentRadius: number?,
	AreaCosts: { [number]: number }?,
	MaxExpansions: number?,
	SnapExtents: Vector3?,
}

--[=[
	@within NavMesh
	@interface ChangedRegion
	.Floor string
	.Min Vector3 -- the box's low corner: X and Z in studs, Y the floor's lowest height in it
	.Max Vector3 -- the high corner

	A box `Update` returns around what it changed on one floor: the rebuilt tiles and every
	triangle whose clearance widths were recomputed. A path whose waypoints, and the straight
	segments between them fattened by its `AgentRadius`, stay outside every box on their floors
	is unaffected: `FindPath` would return it again, unless a removal opened a better route
	through a box.
]=]
export type ChangedRegion = { Floor: string, Min: Vector3, Max: Vector3 }

--[=[
	@within NavMesh
	@interface NavPoint
	.Position Vector3
	.Floor string
]=]
export type NavPoint = { Position: Vector3, Floor: string }

--[=[
	@within NavMesh
	@interface Waypoint
	.Position Vector3
	.Floor string
	.Label string? -- the link's label, on the waypoint where a link starts; the next waypoint is where it lands (not walkable between them)
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
	.TileStamps { number } -- opaque: for IsPathValid
]=]
export type PathResult = { Status: PathStatus, Waypoints: { Waypoint }, Cost: number, TileStamps: { number } }

return {}
