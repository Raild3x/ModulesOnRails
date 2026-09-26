--!strict
--!native
-- Authors: Logan Hunt (Raildex)
-- September 25, 2026
--[=[
	@class NavMesh

	Layered 2.5D navigation mesh with clearance-aware pathfinding, built on
	ConstrainedDelaunay. Mesh state is plain data: operate on it through this module.

	See `docs/plans/navmesh/spec.md` for the full API; it lands ticket by ticket.
]=]

local Fixtures = require("./Fixtures")

local NavMesh = {}

--[=[
	@within NavMesh
	@prop Fixtures NavMeshFixtures
	Shared NavMesh scenarios used by specs, the render script and benchmarks.
]=]
NavMesh.Fixtures = Fixtures

return NavMesh
