--!strict
--!native
-- Authors: Logan Hunt (Raildex)
-- September 25, 2026
-- Public point location: the triangulator's visibility walk, returning 0 outside the hull.

local Storage = require("./Storage")
local Triangulator = require("./Triangulator")

local Locate = {}

--[=[
	@within ConstrainedDelaunay

	The triangle containing (x, y) (points on edges or vertices count as inside), or `0` when
	the point lies outside the convex hull. `hintTriangle` starts the walk; pass the previous
	result for fast nearby lookups.
]=]
function Locate.Locate(s: Storage.State, x: number, y: number, hintTriangle: number?): number
	local count = Storage.TriangleCount(s)
	if count == 0 then
		return 0
	end
	local start = hintTriangle
	if start == nil or start < 1 or start > count then
		start = 1
	end
	local t = Triangulator.Walk(s, x, y, start :: number)
	return t
end

return Locate
