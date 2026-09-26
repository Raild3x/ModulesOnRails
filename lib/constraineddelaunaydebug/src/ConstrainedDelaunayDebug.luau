--!strict
-- Authors: Logan Hunt (Raildex)
-- September 25, 2026
--[=[
	@class ConstrainedDelaunayDebug

	Debug backends for DrawLists built by `CDT.ToDrawList` / `NavMesh.ToDrawList`:
	[SvgBackend] (pure Luau, for the screenshot loop) and [DrawListRenderer] (Roblox world).
]=]

return {
	SvgBackend = require("./SvgBackend"),
	DrawListRenderer = require("./DrawListRenderer"),
}
