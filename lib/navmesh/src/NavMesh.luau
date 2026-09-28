--!strict
--!native
-- Authors: Logan Hunt (Raildex)
-- September 25, 2026
--[=[
	@class NavMesh

	Layered 2.5D navigation mesh with clearance-aware pathfinding, built on
	ConstrainedDelaunay. Mesh state is plain data (no metatable, safe to send over the
	network): operate on it through this module.

	See `docs/plans/navmesh/spec.md` for the full API; it lands ticket by ticket.
]=]

local Build = require("./Build")
local DrawList = require("./DrawList")
local Fixtures = require("./Fixtures")
local Funnel = require("./Funnel")
local Queries = require("./Queries")
local Search = require("./Search")
local Snap = require("./Snap")
local Storage = require("./Storage")
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
export type SeamDesc = Types.SeamDesc
export type LinkDesc = Types.LinkDesc
export type NavMeshData = Storage.State

local DEFAULT_SNAP_EXTENTS = vector.create(0.5, 4, 0.5)

local NavMesh = {}

-- Validates a filter at the API boundary and returns its parts with defaults applied.
local function readFilter(mesh: NavMeshData, filter: QueryFilter?): ({ [number]: number }, number, vector, number)
	local f: QueryFilter = filter or {}
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
	return costs, maxExpansions, extents, radius
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
	`SnapExtents`: the nearest surface vertically, ties going below. The path is the shortest
	one through the cheapest triangle corridor.

	```lua
	local path = NavMesh.FindPath(mesh, npcFeet, goal, { AreaCosts = { [2] = 1.5 } })
	if path.Status == "Success" then
		for _, waypoint in path.Waypoints do moveTo(waypoint.Position) end
	end
	```
]=]
function NavMesh.FindPath(mesh: NavMeshData, from: Vector3, to: Vector3, filter: QueryFilter?): PathResult
	local costs, maxExpansions, extents, radius = readFilter(mesh, filter)
	local startT, startP = Snap.Snap(mesh, vector.create(from.X, from.Y, from.Z), extents, costs)
	if startP == nil then
		return { Status = "NoStart" :: PathStatus, Waypoints = {}, Cost = 0, TileStamps = {} }
	end
	local goalT, goalP = Snap.Snap(mesh, vector.create(to.X, to.Y, to.Z), extents, costs)
	if goalP == nil then
		return { Status = "NoGoal" :: PathStatus, Waypoints = {}, Cost = 0, TileStamps = {} }
	end
	local status, corridor, vias, endP, cost =
		Search.Run(mesh, startT, startP, goalT, goalP, costs, maxExpansions, radius)
	local points, owners, labels = Funnel.StringPull(mesh, corridor, vias, startP, endP, radius)
	local waypoints = table.create(#points)
	for i, p in points do
		waypoints[i] = {
			Position = p :: any, -- a vector is a Vector3 on Roblox
			Floor = Storage.GetFloorName(mesh, Storage.GetTriangleFloor(mesh, owners[i])),
			Label = labels[i],
		}
	end
	-- Every tile the corridor passes through, with its stamp now (tile, stamp, tile, stamp, ...).
	local stamps, seen = {}, {}
	for _, t in corridor do
		local tile = Storage.GetTriangleTile(mesh, t)
		if not seen[tile] then
			seen[tile] = true
			table.insert(stamps, tile)
			table.insert(stamps, Storage.GetTileStamp(mesh, tile))
		end
	end
	return { Status = status :: PathStatus, Waypoints = waypoints, Cost = cost, TileStamps = stamps }
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
	vertically, ties going below. Returns nil when nothing is in range.
]=]
function NavMesh.FindNearestPoint(mesh: NavMeshData, position: Vector3, filter: QueryFilter?): NavPoint?
	local costs, _, extents = readFilter(mesh, filter)
	local t, p = Snap.Snap(mesh, toVector(position), extents, costs)
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
	movement. Errors when `from` doesn't snap onto the mesh (snap it with `FindNearestPoint`).
]=]
function NavMesh.MoveAlongSurface(mesh: NavMeshData, from: Vector3, to: Vector3, filter: QueryFilter?): NavPoint
	local costs, _, extents, radius = readFilter(mesh, filter)
	local t, p = Snap.Snap(mesh, toVector(from), extents, costs)
	if p == nil then
		error("NavMesh.MoveAlongSurface: from is not on the mesh (snap it with FindNearestPoint first)", 2)
	end
	local stop, at = Queries.Move(mesh, t, p, toVector(to), radius, costs)
	return navPoint(mesh, stop, at)
end

--[=[
	@within NavMesh
	The distance from a feet position to the nearest wall reachable over the mesh, up to
	`maxRadius`. Returns (distance, hitPoint, wallNormal), with the normal pointing away from the
	wall in (X, Z); (maxRadius, nil, nil) when no wall is that close; (0, nil, nil) when the
	position is off the mesh.
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

--[=[
	@within NavMesh
	A random point on the mesh, uniform in plan (X, Z) over the areas the filter allows, and
	within `radius` of `center` (in plan) when given. `rng` returns numbers in [0, 1) (default
	`math.random`), so a seeded generator gives reproducible points. Returns nil when no allowed
	surface lies in range.
]=]
function NavMesh.FindRandomPoint(
	mesh: NavMeshData,
	filter: QueryFilter?,
	center: Vector3?,
	radius: number?,
	rng: (() -> number)?
): NavPoint?
	local costs = readFilter(mesh, filter)
	if center ~= nil and (type(radius) ~= "number" or not (radius >= 0)) then
		error("NavMesh.FindRandomPoint: a center needs a radius >= 0", 2)
	end
	local p, t =
		Queries.RandomPoint(mesh, costs, if center then toVector(center) else nil, radius or 0, rng or math.random)
	return if p then navPoint(mesh, p, t) else nil
end

--[=[
	@within NavMesh
	Whether a path from `FindPath` still holds: false once a link toggle (or, later, an
	`Update`) touched a tile it passes through (SR5). Deliberately conservative: a change
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
	Storage.BumpTileStamp(mesh, Storage.GetTriangleTile(mesh, fromTri))
	local toTile = Storage.GetTriangleTile(mesh, toTri)
	if toTile ~= Storage.GetTriangleTile(mesh, fromTri) then
		Storage.BumpTileStamp(mesh, toTile)
	end
end

--[=[
	@within NavMesh
	@function ToDrawList
	@param mesh NavMeshData
	@param options NavMeshDrawOptions?
	@param path PathResult?
	@return DrawList

	The mesh as debug drawing primitives: triangles on `Floor:<name>` layers, walls, and
	optionally tile bounds. A `path` is drawn on the `Path` layer.
]=]
NavMesh.ToDrawList = DrawList.ToDrawList

--[=[
	@within NavMesh
	@prop Fixtures NavMeshFixtures
	Shared NavMesh scenarios used by specs, the render script and benchmarks.
]=]
NavMesh.Fixtures = Fixtures

return NavMesh
