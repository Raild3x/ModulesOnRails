--!strict
--!native
-- Authors: Logan Hunt (Raildex)
-- September 25, 2026
--[=[
	@class ConstrainedDelaunay

	Constrained Delaunay triangulation with winding-group classification. Results are
	plain state: read them only through this module's functions.

	See `docs/plans/navmesh/spec.md` for the full API; it lands ticket by ticket.
]=]

local DrawListTypes = require("./DrawList")
local Fixtures = require("./Fixtures")
local PlainData = require("./PlainData")

export type DrawPrimitive = DrawListTypes.DrawPrimitive
export type DrawList = DrawListTypes.DrawList

local ConstrainedDelaunay = {}

--[=[
	@within ConstrainedDelaunay
	@prop PlainData PlainData
	Network-safety validator for plain state.
]=]
ConstrainedDelaunay.PlainData = PlainData

--[=[
	@within ConstrainedDelaunay
	@prop Fixtures ConstrainedDelaunayFixtures
	Shared scenarios used by specs, the render script and benchmarks.
]=]
ConstrainedDelaunay.Fixtures = Fixtures

return ConstrainedDelaunay
