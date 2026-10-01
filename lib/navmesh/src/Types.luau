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
	.Tiles boolean? -- tile bounds, at the lowest height of each tile's triangles
	.FloorColors { string }? -- "#rrggbb" per floor, in floor-name order, cycled (default six built-in colours)
	.AreaColors { string }? -- per area id, cycled, with Areas (default: area 1 grey #9e9e9e, ...)
	.WallColor string? -- default #212121
	.PathColors { string }? -- per path when drawing several, cycled (default #d81b60 for every path)
]=]
export type NavMeshDrawOptions = {
	Triangles: boolean?,
	Areas: boolean?,
	Clearance: boolean?,
	Tiles: boolean?,
	Seams: boolean?,
	Links: boolean?,
	FloorColors: { string }?,
	AreaColors: { string }?,
	WallColor: string?,
	PathColors: { string }?,
}

--[=[
	@within NavMesh
	@interface QueryFilter
	.AgentRadius number? -- studs (default 0), up to the mesh's MaxAgentRadius; paths only go where the agent fits, and turn this far from wall corners (straight stretches are not offset from walls). The path's end point is pushed this far off the walls, so it can differ from the goal by up to the radius.
	.AreaCosts { [number]: number }? -- cost multiplier per area id (default 1, >= 0); math.huge excludes the area
	.MaxExpansions number? -- stop with "Budget" after expanding this many triangles (default unlimited)
	.SnapExtents Vector3? -- half-size of the snap box around a feet position (default (0.5, 4, 0.5))
	.GoalFallback boolean? -- FindPath only: a goal that doesn't snap gives "Partial" to the closest reachable point instead of "NoGoal" (default false)

	**Closest reachable point (`GoalFallback`):** the search runs from the start with no goal
	triangle, over every triangle it can reach for this `AgentRadius` and `AreaCosts` (up to
	`MaxExpansions`, then `Budget`). Each reached triangle offers its point nearest the goal in
	plan (X, Z), at its surface height, and the one nearest the goal in 3D wins; the end is then
	pushed off the walls like any end. There is no distance bound: the whole reachable region is
	searched, as for any unreachable goal, so bound it with `MaxExpansions` on a big mesh.
]=]
export type QueryFilter = {
	AgentRadius: number?,
	AreaCosts: { [number]: number }?,
	MaxExpansions: number?,
	SnapExtents: Vector3?,
	GoalFallback: boolean?,
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
	through a box. `NavMesh.FirstAffectedSegment` runs that test.
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
	@type MoveStatus "Success" | "NoStart"
	- `Success`: moved (it may have slid along or stopped at a wall).
	- `NoStart`: `from` did not snap onto the mesh; nothing moved.
]=]
export type MoveStatus = "Success" | "NoStart"

--[=[
	@within NavMesh
	@interface MoveResult
	.Status MoveStatus
	.Position Vector3 -- where the move ended; `from` itself on NoStart
	.Floor string? -- the floor it ended on; nil on NoStart
]=]
export type MoveResult = { Status: MoveStatus, Position: Vector3, Floor: string? }

--[=[
	@within NavMesh
	@interface RandomPointOptions
	.Filter QueryFilter? -- AreaCosts exclusions and AgentRadius apply
	.Center Vector3? -- pick within Radius of this point, in plan
	.Radius number? -- studs, >= 0; required with Center
	.Rng (() -> number)? -- returns [0, 1) (default math.random)
]=]
export type RandomPointOptions = {
	Filter: QueryFilter?,
	Center: Vector3?,
	Radius: number?,
	Rng: (() -> number)?,
}

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
	- `Partial`: the goal is unreachable (or, with `GoalFallback`, off the mesh); the waypoints
	  end at the reachable point nearest it.
	- `Budget`: `MaxExpansions` was hit; the waypoints end at the point nearest the goal found so
	  far.
	- `NoStart` / `NoGoal`: that end could not be snapped onto the mesh (no waypoints).
	Every end is pushed `AgentRadius` off the walls, so it can differ from the goal by up to that
	even on `Success`.
]=]
export type PathStatus = "Success" | "Partial" | "Budget" | "NoStart" | "NoGoal"

--[=[
	@within NavMesh
	@interface PathResult
	.Status PathStatus
	.Waypoints { Waypoint } -- from the snapped start; the last is pushed AgentRadius off the walls
	.Cost number -- the search cost: 3D length times area multipliers, measured through the midpoints of the edges crossed
	.TileStamps { number } -- opaque: for IsPathValid
]=]
export type PathResult = { Status: PathStatus, Waypoints: { Waypoint }, Cost: number, TileStamps: { number } }

--[=[
	@within NavMesh
	@type FollowEvent "Arrived" | "Link" | "Blocked"
	- `Arrived`: the last waypoint is reached (at once for a path with none).
	- `Link`: the agent is at a link's start; `Follower.Link` says where it goes. The follower
	  never walks the link: move the agent to `Link.To` (hop, climb, teleport) and keep calling.
	- `Blocked`: `StallSteps` steps in a row made no progress, or the agent is off the mesh
	  (then `Advance` returns no floor). Repath.
]=]
export type FollowEvent = "Arrived" | "Link" | "Blocked"

--[=[
	@within NavMesh
	@interface FollowerLink
	.Label string -- the link's label
	.From Vector3 -- its start (the waypoint the agent stands at)
	.To Vector3 -- its landing
]=]
export type FollowerLink = { Label: string, From: Vector3, To: Vector3 }

--[=[
	@within NavMesh
	@interface Follower
	.Path PathResult
	.Next number -- the waypoint being walked to
	.Stalled number -- steps in a row without progress
	.StallSteps number -- how many make Blocked
	.Link FollowerLink? -- set on the step that returned "Link", nil otherwise

	Plain data `Advance` updates in place; make one per path with `NewFollower`.
]=]
export type Follower = {
	Path: PathResult,
	Next: number,
	Stalled: number,
	StallSteps: number,
	Link: FollowerLink?,
}

return {}
