--!strict
-- Authors: Logan Hunt (Raildex)
-- September 25, 2026
--[=[
	@class SvgBackend

	Renders a DrawList to an SVG string. Pure Luau, so it runs under Lune for the
	screenshot loop (`tools/navmesh/render.luau` → headless Edge → PNG).

	Projection is top-down: world X → SVG x, world Z → SVG y (flipped so +Z points up);
	world Y is dropped. Overlapping floors are told apart by their layer colour, or by
	rendering one `Floor:<name>` layer at a time with `Layers`.
]=]

-- The DrawList type is owned by the CDT (one owner); this backend only consumes it.
local ConstrainedDelaunay = require("../ConstrainedDelaunay")

export type DrawPrimitive = ConstrainedDelaunay.DrawPrimitive
export type DrawList = ConstrainedDelaunay.DrawList

--[=[
	@within SvgBackend
	@interface RenderOptions
	.Width number? -- output width in px (default 800)
	.Height number? -- output height in px (default 800)
	.Layers { string }? -- when given, only these layers are drawn
	.Title string? -- drawn in the top-left corner
]=]
export type RenderOptions = {
	Width: number?,
	Height: number?,
	Layers: { string }?,
	Title: string?,
}

local DEFAULT_SIZE = 800
local PADDING_PX = 24
local TRI_FILL_OPACITY = 0.35
local POINT_RADIUS_PX = 3
local STROKE_WIDTH_PX = 1.5
local LABEL_FONT_PX = 12
local TITLE_FONT_PX = 14

local SvgBackend = {}

local function fmt(n: number): string
	return string.format("%.2f", n)
end

local function escapeXml(text: string): string
	return (text:gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;"):gsub('"', "&quot;"))
end

--[=[
	@within SvgBackend

	Renders `list` to an SVG document string. Errors on an unknown primitive `Kind`, so a
	backend that is missing a branch fails loudly instead of silently not drawing.
]=]
function SvgBackend.Render(list: DrawList, options: RenderOptions?): string
	local opts: RenderOptions = options or {}
	local width = opts.Width or DEFAULT_SIZE
	local height = opts.Height or DEFAULT_SIZE

	local visible: { [string]: boolean }? = nil
	if opts.Layers then
		local set = {}
		for _, layer in opts.Layers do
			set[layer] = true
		end
		visible = set
	end

	-- Fit the XZ bounds of every visible primitive into the viewport.
	local minX, minZ, maxX, maxZ = math.huge, math.huge, -math.huge, -math.huge
	for _, primitive in list do
		if visible and not visible[primitive.Layer] then
			continue
		end
		local points = primitive.Points
		local radius = primitive.Radius or 0
		for i = 1, #points, 3 do
			minX = math.min(minX, points[i] - radius)
			maxX = math.max(maxX, points[i] + radius)
			minZ = math.min(minZ, points[i + 2] - radius)
			maxZ = math.max(maxZ, points[i + 2] + radius)
		end
	end
	if minX > maxX then
		minX, minZ, maxX, maxZ = 0, 0, 1, 1
	end
	local spanX = math.max(maxX - minX, 1e-9)
	local spanZ = math.max(maxZ - minZ, 1e-9)
	local scale = math.min((width - 2 * PADDING_PX) / spanX, (height - 2 * PADDING_PX) / spanZ)

	local function sx(x: number): number
		return PADDING_PX + (x - minX) * scale
	end
	local function sy(z: number): number
		return height - PADDING_PX - (z - minZ) * scale
	end

	local out = {
		`<svg xmlns="http://www.w3.org/2000/svg" width="{width}" height="{height}" viewBox="0 0 {width} {height}">`,
		`<defs><marker id="arrow" viewBox="0 0 10 10" refX="9" refY="5" markerWidth="7" markerHeight="7" orient="auto-start-reverse"><path d="M0,0 L10,5 L0,10 z" fill="context-stroke"/></marker></defs>`,
		`<rect width="100%" height="100%" fill="#ffffff"/>`,
	}

	for _, primitive in list do
		if visible and not visible[primitive.Layer] then
			continue
		end
		local p = primitive.Points
		local color = primitive.Color
		local kind = primitive.Kind
		if kind == "Line" or kind == "Arrow" then
			local marker = if kind == "Arrow" then ` marker-end="url(#arrow)"` else ""
			table.insert(
				out,
				`<line x1="{fmt(sx(p[1]))}" y1="{fmt(sy(p[3]))}" x2="{fmt(sx(p[4]))}" y2="{fmt(sy(p[6]))}" stroke="{color}" stroke-width="{STROKE_WIDTH_PX}"{marker}/>`
			)
		elseif kind == "Tri" then
			table.insert(
				out,
				`<polygon points="{fmt(sx(p[1]))},{fmt(sy(p[3]))} {fmt(sx(p[4]))},{fmt(sy(p[6]))} {fmt(sx(p[7]))},{fmt(sy(p[9]))}" fill="{color}" fill-opacity="{TRI_FILL_OPACITY}" stroke="{color}" stroke-width="0.75"/>`
			)
		elseif kind == "Point" then
			table.insert(out, `<circle cx="{fmt(sx(p[1]))}" cy="{fmt(sy(p[3]))}" r="{POINT_RADIUS_PX}" fill="{color}"/>`)
		elseif kind == "Circle" then
			local radius = assert(primitive.Radius, "Circle primitive needs Radius")
			table.insert(
				out,
				`<circle cx="{fmt(sx(p[1]))}" cy="{fmt(sy(p[3]))}" r="{fmt(radius * scale)}" fill="none" stroke="{color}" stroke-width="1"/>`
			)
		elseif kind == "Label" then
			table.insert(
				out,
				`<text x="{fmt(sx(p[1]) + 4)}" y="{fmt(sy(p[3]) - 4)}" font-family="monospace" font-size="{LABEL_FONT_PX}" fill="{color}">{escapeXml(primitive.Text or "")}</text>`
			)
		else
			error(`SvgBackend: unknown DrawPrimitive Kind "{tostring(kind)}"`, 2)
		end
	end

	if opts.Title then
		table.insert(
			out,
			`<text x="8" y="{TITLE_FONT_PX + 4}" font-family="monospace" font-size="{TITLE_FONT_PX}" fill="#000000">{escapeXml(opts.Title)}</text>`
		)
	end
	table.insert(out, "</svg>")
	return table.concat(out, "\n")
end

return SvgBackend
