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
local Storage = require("./Storage")
local Types = require("./Types")

export type Polygon = Types.Polygon
export type AreaDesc = Types.AreaDesc
export type FloorDesc = Types.FloorDesc
export type NavMeshDesc = Types.NavMeshDesc
export type NavMeshDrawOptions = Types.NavMeshDrawOptions
export type NavMeshData = Storage.State

local NavMesh = {}

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
	@function ToDrawList
	@param mesh NavMeshData
	@param options NavMeshDrawOptions?
	@return DrawList

	The mesh as debug drawing primitives: triangles on `Floor:<name>` layers, walls, and
	optionally tile bounds.
]=]
NavMesh.ToDrawList = DrawList.ToDrawList

--[=[
	@within NavMesh
	@prop Fixtures NavMeshFixtures
	Shared NavMesh scenarios used by specs, the render script and benchmarks.
]=]
NavMesh.Fixtures = Fixtures

return NavMesh
