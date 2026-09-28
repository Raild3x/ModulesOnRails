--!strict
-- Authors: Logan Hunt (Raildex)
-- September 25, 2026
--[=[
	@class NavMeshDebug

	Debug tooling for NavMesh: the interactive editor, and `DrawListRenderer` (from
	ConstrainedDelaunayDebug) to draw `NavMesh.ToDrawList` in the world. Reach submodules as
	fields (`require(Packages.NavMeshDebug).NavMeshEditor`); Wally link modules have no children.
]=]

local ConstrainedDelaunayDebug = require("../ConstrainedDelaunayDebug")

return {
	NavMeshEditor = require("./NavMeshEditor"),
	DrawListRenderer = ConstrainedDelaunayDebug.DrawListRenderer,
}
