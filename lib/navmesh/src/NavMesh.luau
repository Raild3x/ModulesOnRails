--!strict
--!native
-- Authors: Logan Hunt (Raildex)
-- September 25, 2026
--[=[
	@class NavMesh

	Layered 2.5D navigation mesh with clearance-aware pathfinding, built on
	ConstrainedDelaunay. Mesh state is plain data (no metatable, safe to send over the
	network): operate on it through this module.

	```lua
	local mesh = NavMesh.Build({
		Floors = {
			Ground = {
				Walkable = { { Vector3.new(0, 0, 0), Vector3.new(40, 0, 0), Vector3.new(40, 0, 30), Vector3.new(0, 0, 30) } },
				Obstacles = { { Vector3.new(10, 0, 10), Vector3.new(14, 0, 10), Vector3.new(14, 0, 14), Vector3.new(10, 0, 14) } },
			},
		},
		MaxAgentRadius = 2, -- optional, but Build and Update run faster with a cap
	})
	local path = NavMesh.FindPath(mesh, Vector3.new(2, 0, 2), Vector3.new(30, 0, 25), { AgentRadius = 1 })
	```

	`examples/navmesh-demo` is a small game on this API, and `docs/plans/navmesh/spec.md` has the
	design rationale (search nodes, radius offsets, invalidation).

	**Off the mesh.** A query position is on the mesh when it snaps within
	`QueryFilter.SnapExtents`. No query throws for a position that doesn't; each answers "nothing
	here" in its own result:

	| Query | Off-mesh answer |
	|---|---|
	| `FindPath` | `Status` `"NoStart"`, or `"NoGoal"` (with `GoalFallback`: `"Partial"` to the closest reachable point) |
	| `MoveAlongSurface` | `Status` `"NoStart"`, `Position` = `from`, no `Floor` |
	| `Advance` | `"Blocked"` at once, the position unchanged, no floor |
	| `Raycast` | blocked at `from`: `(true, from)` |
	| `FindDistanceToWall` | `(0, nil, nil)`: in a wall (a point on a wall gets a hit point and normal) |
	| `FindNearestPoint` | `nil` |

	To rescue an agent that a closed door left off the mesh, snap it back with
	`FindNearestPoint(mesh, position, filter, searchRadius)`.
]=]

local Build = require("./Build")
local DrawList = require("./DrawList")
local Fixtures = require("./Fixtures")
local Funnel = require("./Funnel")
local Queries = require("./Queries")
local Search = require("./Search")
local Serialize = require("./Serialize")
local Snap = require("./Snap")
local Storage = require("./Storage")
local Tiles = require("./Tiles")
local Types = require("./Types")

export type Polygon = Types.Polygon
export type AreaDesc = Types.AreaDesc
export type FloorDesc = Types.FloorDesc
export type NavMeshDesc = Types.NavMeshDesc
export type NavMeshDrawOptions = Types.NavMeshDrawOptions
export type QueryFilter = Types.QueryFilter
export type Waypoint = Types.Waypoint
export type PathStatus = Types.PathStatus
export type PathResult = Types.PathResult
export type NavPoint = Types.NavPoint
export type MoveStatus = Types.MoveStatus
export type MoveResult = Types.MoveResult
export type FollowEvent = Types.FollowEvent
export type FollowerLink = Types.FollowerLink
export type Follower = Types.Follower
export type RandomPointOptions = Types.RandomPointOptions
export type ChangedRegion = Types.ChangedRegion
export type SeamDesc = Types.SeamDesc
export type LinkDesc = Types.LinkDesc
export type NavMeshData = Storage.State

local DEFAULT_SNAP_EXTENTS = vector.create(0.5, 4, 0.5)
local FILTER_KEYS =
	{ AgentRadius = true, AreaCosts = true, MaxExpansions = true, SnapExtents = true, GoalFallback = true }

local NavMesh = {}

-- Validates a filter at the API boundary and returns its parts with defaults applied.
local function readFilter(
	mesh: NavMeshData,
	filter: QueryFilter?
): ({ [number]: number }, number, vector, number, boolean)
	local f: QueryFilter = filter or {}
	for key in f :: any do
		if not FILTER_KEYS[key] then
			error(
				`unknown QueryFilter key '{key}' (known: AgentRadius, AreaCosts, MaxExpansions, SnapExtents, GoalFallback)`,
				3
			)
		end
	end
	local radius = f.AgentRadius or 0
	if type(radius) ~= "number" or not (radius >= 0 and radius < math.huge) then
		error("QueryFilter.AgentRadius must be a number of studs >= 0", 3)
	end
	local cap = Storage.GetMaxAgentRadius(mesh)
	if cap > 0 and radius > cap then
		error(`QueryFilter.AgentRadius {radius} is above the mesh's MaxAgentRadius {cap}`, 3)
	end
	local costs: { [number]: number } = f.AreaCosts or {}
	for area, multiplier in costs do
		if type(multiplier) ~= "number" or not (multiplier >= 0) then
			error(`QueryFilter.AreaCosts[{area}] must be a number >= 0 (math.huge excludes the area)`, 3)
		end
	end
	local maxExpansions = f.MaxExpansions or math.huge
	if not (maxExpansions >= 0) then
		error("QueryFilter.MaxExpansions must be >= 0", 3)
	end
	local e = f.SnapExtents
	local extents = if e then vector.create(e.X, e.Y, e.Z) else DEFAULT_SNAP_EXTENTS
	if not (extents.X >= 0 and extents.Y >= 0 and extents.Z >= 0) then
		error("QueryFilter.SnapExtents must not be negative", 3)
	end
	local fallback = f.GoalFallback
	if fallback ~= nil and type(fallback) ~= "boolean" then
		error("QueryFilter.GoalFallback must be a boolean", 3)
	end
	return costs, maxExpansions, extents, radius, fallback == true
end

--[=[
	@within NavMesh
	@function Build
	@param desc NavMeshDesc
	@return NavMeshData

	Builds mesh state from an authored description. Errors with a message that names the floor
	and ring on an authoring mistake:
	- a ring that intersects itself or degenerates on the 1/256-stud grid;
	- overlapping or touching walkable rings with different heights;
	- a coordinate outside ±32,768 studs.
]=]
NavMesh.Build = Build.Build

--[=[
	@within NavMesh
	Finds a smoothed path between two **feet** positions (U-b). Each end is snapped within
	`SnapExtents`: the nearest surface vertically; ties go to a surface under the point, then below.
	The path is the shortest one through the cheapest triangle corridor.

	**The end point** is pushed `AgentRadius` off the walls (as `MoveAlongSurface` does), so an
	agent can stand there: for `Success`, `Partial` and `Budget` alike. So the last waypoint can
	differ from the requested goal by up to `AgentRadius` (about 1.41 times it in a corner) even
	on `Success`. At radius 0 it is the snapped goal.

	**`GoalFallback`:** a goal that doesn't snap then gives `Partial` to the closest reachable
	point instead of `NoGoal` (see `QueryFilter`).

	```lua
	local path = NavMesh.FindPath(mesh, npcFeet, goal, { AreaCosts = { [2] = 1.5 } })
	if path.Status == "Success" then
		for _, waypoint in path.Waypoints do moveTo(waypoint.Position) end
	end
	```
]=]
function NavMesh.FindPath(mesh: NavMeshData, from: Vector3, to: Vector3, filter: QueryFilter?): PathResult
	local costs, maxExpansions, extents, radius, fallback = readFilter(mesh, filter)
	local startT, startP = Snap.Snap(mesh, vector.create(from.X, from.Y, from.Z), extents, costs)
	if startP == nil then
		return { Status = "NoStart" :: PathStatus, Waypoints = {}, Cost = 0, Length = 0, TileStamps = {} }
	end
	local goal = vector.create(to.X, to.Y, to.Z)
	local goalT, goalP = Snap.Snap(mesh, goal, extents, costs)
	if goalP == nil then
		if not fallback then
			return { Status = "NoGoal" :: PathStatus, Waypoints = {}, Cost = 0, Length = 0, TileStamps = {} }
		end
		-- No goal triangle: the search ends Partial (or Budget) at the reached point nearest it.
		goalT, goalP = 0, goal
	end
	local status, corridor, vias, endP, cost =
		Search.Run(mesh, startT, startP, goalT, goalP :: vector, costs, maxExpansions, radius)
	local points, owners, labels =
		Funnel.StringPull(mesh, corridor, vias, startP, endP, radius, if next(costs) then costs else nil)
	local n = #points
	points[n], owners[n] = Queries.Push(mesh, owners[n], points[n], radius, costs)
	local waypoints = table.create(#points)
	local length = 0
	for i, p in points do
		if i > 1 then
			length += vector.magnitude(p - points[i - 1])
		end
		waypoints[i] = {
			Position = p :: any, -- a vector is a Vector3 on Roblox
			Floor = Storage.GetFloorName(mesh, Storage.GetTriangleFloor(mesh, owners[i])),
			Label = labels[i],
		}
	end
	-- Every tile the corridor passes through, and the pushed end's, with its stamp now (tile,
	-- stamp, tile, stamp, ...).
	table.insert(corridor, owners[n])
	local stamps, seen = {}, {}
	for _, t in corridor do
		local tile = Storage.GetTriangleTile(mesh, t)
		if not seen[tile] then
			seen[tile] = true
			table.insert(stamps, tile)
			table.insert(stamps, Storage.GetTileStamp(mesh, tile))
		end
	end
	return {
		Status = status :: PathStatus,
		Waypoints = waypoints,
		Cost = cost,
		Length = length,
		TileStamps = stamps,
	}
end

local function toVector(p: Vector3): vector
	return vector.create(p.X, p.Y, p.Z)
end

local function navPoint(mesh: NavMeshData, p: vector, t: number): NavPoint
	return { Position = p :: any, Floor = Storage.GetFloorName(mesh, Storage.GetTriangleFloor(mesh, t)) }
end

--[=[
	@within NavMesh
	Snaps a **feet** position onto the mesh (U-b): within `SnapExtents`, the nearest surface
	vertically; ties go to a surface under the point, then below. Returns nil when nothing is in range.

	With `searchRadius`, a position that doesn't snap takes the nearest surface point within
	`searchRadius` of it in plan (X, Z), however far outside `SnapExtents` and with no vertical
	limit: each triangle offers its point nearest the position in plan, at its surface height,
	and the one nearest in 3D wins. The cost is bounded by the radius. Use it to rescue an agent
	a closed door left off the mesh, or to find the floor under a point high in the air.

	```lua
	local back = NavMesh.FindNearestPoint(mesh, npcFeet, filter, 4)
	```
]=]
function NavMesh.FindNearestPoint(
	mesh: NavMeshData,
	position: Vector3,
	filter: QueryFilter?,
	searchRadius: number?
): NavPoint?
	local costs, _, extents = readFilter(mesh, filter)
	if
		searchRadius ~= nil
		and (type(searchRadius) ~= "number" or not (searchRadius >= 0 and searchRadius < math.huge))
	then
		error("NavMesh.FindNearestPoint: searchRadius must be a number of studs >= 0", 2)
	end
	local at = toVector(position)
	local t, p = Snap.Snap(mesh, at, extents, costs)
	if p == nil and searchRadius then
		t, p = Snap.Nearest(mesh, at, searchRadius, costs)
	end
	return if p then navPoint(mesh, p, t) else nil
end

--[=[
	@within NavMesh
	Walks straight over the surface from `from` (a feet position, snapped) towards `to` in
	(X, Z), across tiles and seams. Returns (blocked, stopPoint): blocked when a wall or an
	excluded area stops the walk before `to`, and the point on the surface where it stopped (or
	`to`, lifted onto the surface). A `from` that doesn't snap returns (true, from). The ray is a
	point: `AgentRadius` is not applied.
]=]
function NavMesh.Raycast(mesh: NavMeshData, from: Vector3, to: Vector3, filter: QueryFilter?): (boolean, Vector3)
	local costs, _, extents = readFilter(mesh, filter)
	local t, p = Snap.Snap(mesh, toVector(from), extents, costs)
	if p == nil then
		return true, from
	end
	local blocked, stop = Queries.Walk(mesh, t, p, toVector(to), costs)
	return blocked, stop :: any
end

--[=[
	@within NavMesh
	Moves from `from` towards `to` over the surface, sliding along walls it meets, and keeps the
	end `AgentRadius` from the nearest wall where there is room (V3, SR4). For per-frame
	movement. When `from` doesn't snap onto the mesh (a door closed on the agent) it returns
	`Status` `"NoStart"` with `Position` = `from` and no `Floor`, like `FindPath`: rescue the
	agent with `FindNearestPoint`'s `searchRadius`.

	```lua
	local moved = NavMesh.MoveAlongSurface(mesh, feet, feet + step, filter)
	if moved.Status == "NoStart" then
		local back = NavMesh.FindNearestPoint(mesh, feet, filter, 4)
	end
	```
]=]
function NavMesh.MoveAlongSurface(mesh: NavMeshData, from: Vector3, to: Vector3, filter: QueryFilter?): MoveResult
	local costs, _, extents, radius = readFilter(mesh, filter)
	local t, p = Snap.Snap(mesh, toVector(from), extents, costs)
	if p == nil then
		return { Status = "NoStart" :: MoveStatus, Position = from }
	end
	local stop, at = Queries.Move(mesh, t, p, toVector(to), radius, costs)
	return {
		Status = "Success" :: MoveStatus,
		Position = stop :: any,
		Floor = Storage.GetFloorName(mesh, Storage.GetTriangleFloor(mesh, at)),
	}
end

--[=[
	@within NavMesh
	A `Follower` for `path`, walking from its first waypoint (the snapped start) to its second.
	`Advance` reports `Blocked` after `stallSteps` steps in a row without progress (default 10).
]=]
function NavMesh.NewFollower(path: PathResult, stallSteps: number?): Follower
	if type(path) ~= "table" or type(path.Waypoints) ~= "table" then
		error("NavMesh.NewFollower: path must be a PathResult", 2)
	end
	local steps = if stallSteps == nil then 10 else stallSteps
	if type(steps) ~= "number" or not (steps >= 1 and steps < math.huge and steps % 1 == 0) then
		error("NavMesh.NewFollower: stallSteps must be a whole number >= 1", 2)
	end
	return { Path = path, Next = 2, Stalled = 0, StallSteps = steps, Link = nil }
end

local STALL = 0.1 -- a step that moves less than this fraction of maxStep made no progress

--[=[
	@within NavMesh
	Moves an agent at feet `position` up to `maxStep` studs along `follower`'s path with
	`MoveAlongSurface` (use the same `filter` as the `FindPath` call), and updates `follower`.
	Returns (position, floor, event); `event` is nil while walking (see `FollowEvent`), and
	`floor` is nil only when the agent is off the mesh or the path has no waypoints.

	- **Arrival:** a waypoint counts as reached when the step gets to it, or when the agent
	  stalls within `AgentRadius` of it: the funnel puts corner waypoints on the
	  portal, which can be nearer a wall than the radius (SR4), and the push keeps the agent
	  off it. The path's end is already offset.
	- **Links:** at a waypoint with a `Label`, it returns `"Link"` without moving; move the agent
	  to `follower.Link.To` yourself, then call again from there.
	- It never throws for an agent off the mesh (a door closed on it): that is `"Blocked"` at
	  once, with no floor.

	```lua
	local follower = NavMesh.NewFollower(NavMesh.FindPath(mesh, feet, goal, filter))
	-- each frame:
	local position, floor, event = NavMesh.Advance(mesh, follower, feet, speed * dt, filter)
	if event == "Link" then
		hop(follower.Link.To)
	elseif event == "Blocked" then
		repath()
	end
	```
]=]
function NavMesh.Advance(
	mesh: NavMeshData,
	follower: Follower,
	position: Vector3,
	maxStep: number,
	filter: QueryFilter?
): (Vector3, string?, FollowEvent?)
	if type(maxStep) ~= "number" or not (maxStep >= 0 and maxStep < math.huge) then
		error("NavMesh.Advance: maxStep must be a number of studs >= 0", 2)
	end
	follower.Link = nil
	local waypoints = follower.Path.Waypoints
	local target = waypoints[follower.Next]
	if target == nil then
		local last = waypoints[#waypoints]
		return position, last and last.Floor, "Arrived" :: FollowEvent
	end
	local here = waypoints[follower.Next - 1]
	if here.Label then
		-- The next waypoint is the link's landing: never walk that segment.
		follower.Next += 1
		follower.Link = { Label = here.Label, From = here.Position, To = target.Position }
		return position, here.Floor, "Link" :: FollowEvent
	end
	local p, goal = toVector(position), toVector(target.Position)
	local remaining = math.sqrt((goal.X - p.X) ^ 2 + (goal.Z - p.Z) ^ 2)
	local to = if remaining <= maxStep then goal else p + (goal - p) * (maxStep / remaining)
	local moved = NavMesh.MoveAlongSurface(mesh, position, to :: any, filter)
	if moved.Status == "NoStart" then
		return position, nil, "Blocked" :: FollowEvent
	end
	local stop = toVector(moved.Position)
	local stalled = math.sqrt((stop.X - p.X) ^ 2 + (stop.Z - p.Z) ^ 2) < STALL * maxStep
	local radius = if filter then filter.AgentRadius or 0 else 0
	-- The allowance is f32 rounding: an ulp is 0.004 at 32768 studs.
	local near = math.sqrt((goal.X - stop.X) ^ 2 + (goal.Z - stop.Z) ^ 2) <= radius + 0.01
	if near and (remaining <= maxStep or stalled) then
		follower.Next += 1
		follower.Stalled = 0
		return moved.Position, moved.Floor, if waypoints[follower.Next] then nil else "Arrived" :: FollowEvent
	end
	follower.Stalled = if stalled then follower.Stalled + 1 else 0
	return moved.Position,
		moved.Floor,
		if follower.Stalled >= follower.StallSteps then "Blocked" :: FollowEvent else nil
end

--[=[
	@within NavMesh
	The distance from a feet position to the nearest wall reachable over the mesh, up to
	`maxRadius`. Returns (distance, hitPoint, wallNormal), with the normal pointing away from the
	wall in (X, Z); (maxRadius, nil, nil) when no wall is that close; (0, nil, nil) when the
	position is off the mesh (in a wall; a point on a wall gets its hit point and normal).
]=]
function NavMesh.FindDistanceToWall(
	mesh: NavMeshData,
	position: Vector3,
	maxRadius: number,
	filter: QueryFilter?
): (number, Vector3?, Vector3?)
	if type(maxRadius) ~= "number" or not (maxRadius > 0) then
		error("NavMesh.FindDistanceToWall: maxRadius must be a number above 0", 2)
	end
	local costs, _, extents = readFilter(mesh, filter)
	local t, p = Snap.Snap(mesh, toVector(position), extents, costs)
	if p == nil then
		return 0, nil, nil
	end
	local d, hit, normal = Queries.DistanceToWall(mesh, t, p, maxRadius, costs)
	return d, hit :: any, normal :: any
end

local RANDOM_OPTIONS = { Filter = true, Center = true, Radius = true, Rng = true }

--[=[
	@within NavMesh
	A random point where an agent can stand, uniform in plan (X, Z) over the areas
	`options.Filter` allows, within `Radius` of `Center` (in plan) when given. `Rng` returns
	numbers in [0, 1) (default `math.random`), so a seeded generator gives reproducible points.
	Returns nil when no such point is in range.

	With `Filter.AgentRadius` r > 0 it only picks points at least r from every wall, in triangles
	such an agent can enter (one of its edges admits a width of 2r). It draws up to 32 points and
	keeps the first that qualifies, which is exactly uniform over that region. The biases:
	- a triangle no edge of which admits 2r is skipped even if part of it is r clear, and so is
	  a floor that is a single triangle (no edge to cross);
	- when all 32 draws miss (a region barely wider than the agent), the last is pushed off the
	  walls and so lands on the region's edge; if that fails too, it returns nil.

	```lua
	local goal = NavMesh.FindRandomPoint(mesh, { Filter = filter, Center = feet, Radius = 30, Rng = rng })
	```
]=]
function NavMesh.FindRandomPoint(mesh: NavMeshData, options: RandomPointOptions?): NavPoint?
	local o: RandomPointOptions = options or {}
	for key in o :: any do
		if not RANDOM_OPTIONS[key] then
			error(
				`NavMesh.FindRandomPoint: unknown option {key} (options are Filter, Center, Radius, Rng; AgentRadius and the rest go in Filter)`,
				2
			)
		end
	end
	local costs, _, _, agentRadius = readFilter(mesh, o.Filter)
	local center, radius = o.Center, o.Radius
	if center ~= nil and (type(radius) ~= "number" or not (radius >= 0)) then
		error("NavMesh.FindRandomPoint: a Center needs a Radius >= 0", 2)
	end
	local p, t = Queries.RandomPoint(
		mesh,
		costs,
		if center then toVector(center) else nil,
		radius or 0,
		agentRadius,
		o.Rng or math.random
	)
	return if p then navPoint(mesh, p, t) else nil
end

--[=[
	@within NavMesh
	Whether a path from `FindPath` still holds: false once a link toggle or an `Update`
	touched a tile it passes through (SR5). Deliberately conservative: a change
	anywhere in such a tile invalidates it.
]=]
function NavMesh.IsPathValid(mesh: NavMeshData, path: PathResult): boolean
	local stamps = path.TileStamps
	for i = 1, #stamps, 2 do
		local tile = stamps[i]
		if tile > Storage.TileCount(mesh) or Storage.GetTileStamp(mesh, tile) ~= stamps[i + 1] then
			return false
		end
	end
	return true
end

-- Whether segment a-b, grown by `radius` into a square-cornered band, meets box `r` in plan
-- (the slab test on the box grown by the radius).
local function segmentMeets(a: vector, b: vector, r: ChangedRegion, radius: number): boolean
	local t0, t1 = 0, 1
	for axis = 1, 2 do
		local p = if axis == 1 then a.X else a.Z
		local d = (if axis == 1 then b.X else b.Z) - p
		local lo = (if axis == 1 then r.Min.X else r.Min.Z) - radius
		local hi = (if axis == 1 then r.Max.X else r.Max.Z) + radius
		if d == 0 then
			if p < lo or p > hi then
				return false
			end
		else
			local u0, u1 = (lo - p) / d, (hi - p) / d
			t0, t1 = math.max(t0, math.min(u0, u1)), math.min(t1, math.max(u0, u1))
		end
	end
	return t0 <= t1
end

--[=[
	@within NavMesh
	Which part of `path` the `regions` an `Update` returned reach (ticket 28): the index `i` of the
	first segment `Waypoints[i] -> Waypoints[i + 1]`, at or after `fromSegment` (default 1), that
	meets a region box on the floor of either of its ends, with the segment grown by `radius`
	(the path's `AgentRadius`). Returns nil when none does: then `FindPath` would return the same
	path again, unless a removal opened a better route through a box (see `ChangedRegion`).

	A link's segment (from a waypoint with a `Label`) has no surface between its ends, so only its
	two ends are tested. The radius grows boxes square, so it can report a segment the round agent
	would miss by up to 0.41 radius at a box corner, never the reverse. Plain data in and out: one
	check per agent costs O(regions) when the path's bounds miss every box.

	With a follower, test only the way ahead: the agent is on segment `follower.Next - 1`.

	```lua
	local regions = NavMesh.Update(mesh)
	for _, npc in npcs do
		if NavMesh.FirstAffectedSegment(npc.Follower.Path, regions, npc.Radius, npc.Follower.Next - 1) then
			repath(npc)
		end
	end
	```
]=]
function NavMesh.FirstAffectedSegment(
	path: PathResult,
	regions: { ChangedRegion },
	radius: number,
	fromSegment: number?
): number?
	if type(path) ~= "table" or type(path.Waypoints) ~= "table" then
		error("NavMesh.FirstAffectedSegment: path must be a PathResult", 2)
	end
	if type(regions) ~= "table" then
		error("NavMesh.FirstAffectedSegment: regions must be a list of ChangedRegion", 2)
	end
	if type(radius) ~= "number" or not (radius >= 0 and radius < math.huge) then
		error("NavMesh.FirstAffectedSegment: radius must be a number of studs >= 0", 2)
	end
	local first = if fromSegment == nil then 1 else fromSegment
	if type(first) ~= "number" or not (first >= 1 and first < math.huge and first % 1 == 0) then
		error("NavMesh.FirstAffectedSegment: fromSegment must be a whole number >= 1", 2)
	end
	local waypoints = path.Waypoints
	local n = #waypoints
	-- One waypoint is a path standing still: its point is segment 1.
	local last = math.max(n - 1, 1)
	if first > last or n == 0 then
		return nil
	end
	-- Cheap reject: the bounds of the rest of the path, grown by the radius, against every box.
	local lo, hi = toVector(waypoints[first].Position), toVector(waypoints[first].Position)
	for i = first + 1, n do
		local p = toVector(waypoints[i].Position)
		lo, hi = vector.min(lo, p), vector.max(hi, p)
	end
	local near = false
	for _, r in regions do
		if
			r.Min.X <= hi.X + radius
			and r.Max.X >= lo.X - radius
			and r.Min.Z <= hi.Z + radius
			and r.Max.Z >= lo.Z - radius
		then
			near = true
			break
		end
	end
	if not near then
		return nil
	end
	for i = first, last do
		local a, b = waypoints[i], waypoints[math.min(i + 1, n)]
		local pa, pb = toVector(a.Position), toVector(b.Position)
		for _, r in regions do
			if r.Floor ~= a.Floor and r.Floor ~= b.Floor then
				continue
			end
			local hit = if a.Label
				then segmentMeets(pa, pa, r, radius) or segmentMeets(pb, pb, r, radius)
				else segmentMeets(pa, pb, r, radius)
			if hit then
				return i
			end
		end
	end
	return nil
end

--[=[
	@within NavMesh
	Enables or disables link `linkId` (its 1-based index in `Links`). Paths through either end's
	tile become invalid (SR5), whether or not they use the link.
]=]
function NavMesh.SetLinkEnabled(mesh: NavMeshData, linkId: number, enabled: boolean)
	if type(linkId) ~= "number" or linkId % 1 ~= 0 or linkId < 1 or linkId > Storage.LinkCount(mesh) then
		error(`NavMesh.SetLinkEnabled: no link {linkId} (the mesh has {Storage.LinkCount(mesh)})`, 2)
	end
	if type(enabled) ~= "boolean" then
		error("NavMesh.SetLinkEnabled: enabled must be a boolean", 2)
	end
	local fromTri, _, toTri = Storage.GetLink(mesh, linkId)
	Storage.SetLinkFlag(mesh, linkId, enabled)
	-- An end covered by an obstacle has no triangle (0): nothing to bump there.
	local bumped = {}
	for _, t in { fromTri, toTri } do
		local tile = if t ~= 0 then Storage.GetTriangleTile(mesh, t) else 0
		if tile ~= 0 and not bumped[tile] then
			bumped[tile] = true
			Storage.BumpTileStamp(mesh, tile)
		end
	end
end

--[=[
	@within NavMesh
	Adds a dynamic obstacle (a door, a crate) on floor `floor`, as a ring in (X, Z). It takes
	effect at the next `Update`. Errors at the call on a bad polygon (SR13). Returns its id,
	which is never reused.
]=]
function NavMesh.AddObstacle(mesh: NavMeshData, floor: string, polygon: Polygon): number
	return Tiles.AddObstacle(mesh, floor, polygon)
end

--[=[
	@within NavMesh
	Removes dynamic obstacle `obstacleId`; it takes effect at the next `Update`.
]=]
function NavMesh.RemoveObstacle(mesh: NavMeshData, obstacleId: number)
	Tiles.RemoveObstacle(mesh, obstacleId)
end

--[=[
	@within NavMesh
	True while an obstacle added or removed since the last `Update` is waiting for it: until then,
	queries still see the mesh without the change.
]=]
function NavMesh.HasPendingChanges(mesh: NavMeshData): boolean
	for slot = 1, Storage.ObstacleCount(mesh) do
		if Storage.GetObstacleState(mesh, slot) ~= Storage.OBSTACLE_ACTIVE then
			return true
		end
	end
	return false
end

--[=[
	@within NavMesh
	Applies every obstacle added or removed since the last `Update`, rebuilding only the tiles
	they touch, plus the clearance within reach of the walls that changed. Paths through changed
	tiles then fail `IsPathValid`. The cost follows the tiles the change touches (smaller tiles,
	cheaper updates), plus a copy of the rest of the mesh at about 0.1-0.2 ms per 1,000 triangles
	under Lune; a `MaxAgentRadius` cap makes the clearance part much cheaper.

	Returns two lists of boxes (`ChangedRegion`), both empty when nothing was pending. Test a path
	against either with `FirstAffectedSegment`, which is finer than `IsPathValid`'s per-tile stamps:
	- **The changed regions** hold everything the Update changed: whole rebuilt tiles, so smaller
	  tiles give tighter regions. A path clear of them, fattened by its `AgentRadius`, is what
	  `FindPath` would return again (unless a removal opened a better way).
	- **The added footprints:** one box per obstacle the Update added, its ring's bounds. A path
	  clear of them is still walkable, though `FindPath` may now return another. Usually that is
	  what a game needs: it replans far fewer agents. A removal adds no box, since it blocks
	  nothing; it may open a way for a `Partial` path, so retry those after removing.

	Atomic (SR13): on an error the mesh is unchanged, the pending obstacle changes are rolled back,
	and the error is raised again. Triangle and vertex ids are only stable until the next `Update`
	(SR14).

	```lua
	local door = NavMesh.AddObstacle(mesh, "Ground", doorFootprint)
	local regions, added = NavMesh.Update(mesh) -- each { { Floor, Min, Max } }
	if NavMesh.FirstAffectedSegment(path, added, radius) then path = NavMesh.FindPath(mesh, npcFeet, goal, filter) end
	```
]=]
function NavMesh.Update(mesh: NavMeshData): ({ ChangedRegion }, { ChangedRegion })
	-- The footprints this Update adds, read before it commits them: on the 1/256 grid, grown
	-- by one pixel for the snap rounding.
	local added = {}
	for slot = 1, Storage.ObstacleCount(mesh) do
		local _, floor, state, xs, zs = Storage.GetObstacleRecord(mesh, slot)
		if state == Storage.OBSTACLE_PENDING_ADD then
			local x0, z0, x1, z1 = math.huge, math.huge, -math.huge, -math.huge
			for i, x in xs do
				x0, x1, z0, z1 = math.min(x0, x), math.max(x1, x), math.min(z0, zs[i]), math.max(z1, zs[i])
			end
			table.insert(added, {
				Floor = floor,
				Min = vector.create((x0 - 1) / 256, 0, (z0 - 1) / 256),
				Max = vector.create((x1 + 1) / 256, 0, (z1 + 1) / 256),
			})
		end
	end
	local regions = Tiles.Update(mesh)
	-- Heights: the span of the floor's changed regions, which hold every footprint.
	for _, box in added do
		local floor = Storage.GetFloorName(mesh, box.Floor)
		local y0, y1 = math.huge, -math.huge
		for _, r in regions do
			if r.Floor == floor then
				y0, y1 = math.min(y0, r.Min.Y), math.max(y1, r.Max.Y)
			end
		end
		box.Floor = floor
		box.Min = vector.create(box.Min.X, y0, box.Min.Z) :: any
		box.Max = vector.create(box.Max.X, y1, box.Max.Z) :: any
	end
	return regions, added :: any
end

--[=[
	@within NavMesh
	Bakes the mesh into a versioned buffer (P3), to ship precomputed or store. Its format is
	independent of the in-memory layout (SR9). It includes each tile's source data (R7), so a
	loaded mesh still supports `AddObstacle` and `Update`.

	**Shipping a bake in a place.** A place cannot hold a buffer (attributes reject buffers,
	and scripts cannot set `BinaryStringValue.Value`), and a script can only set a
	`StringValue` or a ModuleScript's source under 200,000 characters. So ship the bake as
	base64 text split across StringValues named `1`, `2`, ... in a Folder, compressed with
	zstd first when it is made in Studio:
	- **In Studio:** `NavMeshEditor:SaveBake(parent)` (key B in the editor) builds the
	  description and writes that Folder. Save the place (in Play mode, copy the Folder
	  before you stop). By hand, from the command bar:
	  `EncodingService:Base64Encode(EncodingService:CompressBuffer(NavMesh.Serialize(mesh), Enum.CompressionAlgorithm.Zstd, 19))`,
	  then cut the text into StringValues of at most 199,999 characters.
	- **From files (Rojo):** write the base64 of the buffer to `NavMeshBake/1.txt`,
	  `NavMeshBake/2.txt`, ... (Rojo turns each `.txt` into a StringValue). Leave it
	  uncompressed: Lune's zstd frames do not decode with `EncodingService` (they lack the
	  content size), and Lune has no base64, so a Lune script needs a small encoder.

	`NavMeshEditor.SaveBake` (package NavMeshDebug) documents the loader: join the chunks,
	`EncodingService:Base64Decode`, then `DecompressBuffer` when the bytes start with the zstd
	frame magic (`0xFD2FB528` as a u32), so one loader reads both kinds.

	Measured in Studio (`docs/plans/navmesh/bench.md`): the 256-stud bench map's 580 KB bake
	is 227 KB of text in 2 StringValues and loads in 1.4-1.7 ms, before `Deserialize`'s 7-8 ms.
	A `\xNN` string literal in a ModuleScript is 4.1x the bake, which is over the source limit
	for that map.
]=]
function NavMesh.Serialize(mesh: NavMeshData): buffer
	return Serialize.Serialize(mesh)
end

--[=[
	@within NavMesh
	Loads a mesh from `Serialize`'s buffer. Errors on another format version or a damaged buffer.
	`Serialize` shows how to ship a bake in a place and load it back.
]=]
function NavMesh.Deserialize(data: buffer): NavMeshData
	return Serialize.Deserialize(data)
end

--[=[
	@within NavMesh
	@function ToDrawList
	@param mesh NavMeshData
	@param options NavMeshDrawOptions?
	@param paths (PathResult | { PathResult })?
	@return DrawList

	The mesh as debug drawing primitives: triangles on `Floor:<name>` layers, walls, and
	optionally tile bounds, seams and links (a disabled link is drawn faded). `paths`, one path
	or a list of them, go on the `Path` layer, each in its `PathColors` entry. `FloorColors`,
	`AreaColors` and `WallColor` replace the default palette, for a grey or dark baseplate.

	```lua
	local list = NavMesh.ToDrawList(mesh, {
		WallColor = "#ffffff",
		PathColors = { "#d81b60", "#3949ab" },
	}, { pathA, pathB })
	```
]=]
NavMesh.ToDrawList = DrawList.ToDrawList

--[=[
	@within NavMesh
	@prop Fixtures NavMeshFixtures
	Shared NavMesh scenarios used by specs, the render script and benchmarks.
]=]
NavMesh.Fixtures = Fixtures

return NavMesh
