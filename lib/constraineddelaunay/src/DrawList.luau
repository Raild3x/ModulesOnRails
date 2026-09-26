--!strict
-- Authors: Logan Hunt (Raildex)
-- September 25, 2026
--[=[
	@class DrawList

	The plain-data debug view shared by every backend: a list of primitives in world
	coordinates. Built by `CDT.ToDrawList` / `NavMesh.ToDrawList`; drawn by the debug
	package's `SvgBackend` (SVG, for screenshots) and `DrawListRenderer` (Studio).
]=]

--[=[
	@within DrawList
	@interface DrawPrimitive
	.Kind "Line" | "Tri" | "Point" | "Circle" | "Arrow" | "Label" -- backends error on an unknown Kind
	.Points { number } -- flat world x,y,z triples; the CDT emits its 2D (x, y) as (x, 0, y)
	.Color string -- "#rrggbb"
	.Layer string -- "Triangles", "Constraints", "Path", "Floor:<name>", ...
	.Radius number? -- Circle only
	.Text string? -- Label only
]=]
export type DrawPrimitive = {
	Kind: "Line" | "Tri" | "Point" | "Circle" | "Arrow" | "Label",
	Points: { number },
	Color: string,
	Layer: string,
	Radius: number?,
	Text: string?,
}

--[=[
	@within DrawList
	@type DrawList { DrawPrimitive }
]=]
export type DrawList = { DrawPrimitive }

return {}
