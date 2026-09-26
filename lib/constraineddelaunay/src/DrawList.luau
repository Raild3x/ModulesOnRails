--!strict
-- Authors: Logan Hunt (Raildex)
-- September 25, 2026
--[=[
	@class DrawList

	The plain-data debug view shared by every backend: a list of primitives in world
	coordinates. Built by `CDT.ToDrawList` / `NavMesh.ToDrawList`; drawn by the debug
	package's `SvgBackend` (SVG, for screenshots) and `DrawListRenderer` (Studio).
]=]

local Storage = require("./Storage")

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

--[=[
	@within ConstrainedDelaunay
	@interface CDTDrawOptions
	.ShowConstraints boolean? -- draw constrained edges (default true)
	.ShowSteiner boolean? -- highlight Steiner vertices (default true)
	.ColorByGroup number? -- colour triangles by winding > 0 in this group
	.ShowCircumcircles boolean? -- draw every triangle's circumcircle (default false)
]=]
export type CDTDrawOptions = {
	ShowConstraints: boolean?,
	ShowSteiner: boolean?,
	ColorByGroup: number?,
	ShowCircumcircles: boolean?,
}

local COLOR_TRIANGLE = "#43a047"
local COLOR_OUTSIDE = "#bdbdbd"
local COLOR_CONSTRAINT = "#c62828"
local COLOR_VERTEX = "#000000"
local COLOR_STEINER = "#ef6c00"
local COLOR_CIRCLE = "#90a4ae"

local DrawListModule = {}

--[=[
	@within ConstrainedDelaunay
	Builds a DrawList of a triangulation (world XZ plane, y = 0).
]=]
function DrawListModule.ToDrawList(s: Storage.State, options: CDTDrawOptions?): DrawList
	local opts: CDTDrawOptions = options or {}
	local showConstraints = opts.ShowConstraints ~= false
	local showSteiner = opts.ShowSteiner ~= false
	local list: DrawList = {}

	for t = 1, Storage.TriangleCount(s) do
		local a, b, c = Storage.GetTriangle(s, t)
		local ax, ay = Storage.GetVertex(s, a)
		local bx, by = Storage.GetVertex(s, b)
		local cx, cy = Storage.GetVertex(s, c)
		local color = COLOR_TRIANGLE
		if opts.ColorByGroup ~= nil and Storage.GetWinding(s, t, opts.ColorByGroup) <= 0 then
			color = COLOR_OUTSIDE
		end
		table.insert(
			list,
			{ Kind = "Tri", Points = { ax, 0, ay, bx, 0, by, cx, 0, cy }, Color = color, Layer = "Triangles" }
		)
		if opts.ShowCircumcircles then
			-- Debug only: circumcentre in plain floating point.
			local d = 2 * (ax * (by - cy) + bx * (cy - ay) + cx * (ay - by))
			local a2, b2, c2 = ax * ax + ay * ay, bx * bx + by * by, cx * cx + cy * cy
			local ux = (a2 * (by - cy) + b2 * (cy - ay) + c2 * (ay - by)) / d
			local uy = (a2 * (cx - bx) + b2 * (ax - cx) + c2 * (bx - ax)) / d
			local radius = math.sqrt((ax - ux) ^ 2 + (ay - uy) ^ 2)
			table.insert(list, {
				Kind = "Circle",
				Points = { ux, 0, uy },
				Radius = radius,
				Color = COLOR_CIRCLE,
				Layer = "Circumcircles",
			})
		end
	end

	-- Each constrained edge once (from the lower-numbered side, or the hull side).
	if showConstraints then
		for t = 1, Storage.TriangleCount(s) do
			for e = 1, 3 do
				local n = Storage.GetNeighbor(s, t, e)
				if Storage.GetCoveringEdgeCount(s, t, e) > 0 and (n == 0 or n > t) then
					local a, b, c = Storage.GetTriangle(s, t)
					local verts = { a, b, c }
					local u, v = verts[e % 3 + 1], verts[(e + 1) % 3 + 1]
					local ux, uy = Storage.GetVertex(s, u)
					local vx, vy = Storage.GetVertex(s, v)
					table.insert(list, {
						Kind = "Line",
						Points = { ux, 0, uy, vx, 0, vy },
						Color = COLOR_CONSTRAINT,
						Layer = "Constraints",
					})
				end
			end
		end
	end

	for v = 1, Storage.VertexCount(s) do
		local x, y = Storage.GetVertex(s, v)
		local steiner = Storage.InputVertexOf(s, v) == nil
		local color = if steiner and showSteiner then COLOR_STEINER else COLOR_VERTEX
		table.insert(
			list,
			{ Kind = "Point", Points = { x, 0, y }, Color = color, Layer = if steiner then "Steiner" else "Vertices" }
		)
	end

	return list
end

return DrawListModule
