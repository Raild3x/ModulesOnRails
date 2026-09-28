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
	local status, corridor, endP, cost = Search.Run(mesh, startT, startP, goalT, goalP, costs, maxExpansions, radius)
	local points, owners = Funnel.StringPull(mesh, corridor, startP, endP, radius)
	local waypoints = table.create(#points)
	for i, p in points do
		waypoints[i] = {
			Position = p :: any, -- a vector is a Vector3 on Roblox
			Floor = Storage.GetFloorName(mesh, Storage.GetTriangleFloor(mesh, owners[i])),
		}
	end
	-- ponytail: TileStamps stays empty until Update and IsPathValid land (ticket 18).
	return { Status = status :: PathStatus, Waypoints = waypoints, Cost = cost, TileStamps = {} }
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
