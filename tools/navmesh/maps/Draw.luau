--!strict
-- Drawing shared by Studio.luau (in the world) and plan.luau (SVG from above): links as arrows,
-- the mesh's triangles by area. `V3` is Vector3 (Studio's, or Lune's @lune/roblox).

local Draw = {}

Draw.DEFAULT_AREA_COLOR = "#3a7bd5"

-- Each link as lines: straight for a drop, an arc for a jump; an arrowhead at each end it can be
-- taken from. colors[label] or `other` (stairs, elevators).
function Draw.Links(links: { any }, V3: any, colors: { [string]: string }, other: string): { any }
	local list = {}
	local function line(a: any, b: any, color: string)
		table.insert(list, { Kind = "Line", Points = { a.X, a.Y, a.Z, b.X, b.Y, b.Z }, Color = color, Layer = "Links" })
	end
	local function head(from: any, to: any, color: string)
		local d = to - from
		local flat = V3.new(d.X, 0, d.Z)
		local side = if flat.Magnitude > 1e-3 then flat.Unit:Cross(V3.new(0, 1, 0)) else V3.new(1, 0, 0)
		local back = -d.Unit * 0.8
		line(to, to + back + side * 0.4, color)
		line(to, to + back - side * 0.4, color)
	end
	for _, link in links do
		local a, b = link.From, link.To
		local color = colors[link.Label or ""] or other
		local pts = { a }
		if link.Label == "Jump" then
			local lift = math.max(1, V3.new(b.X - a.X, 0, b.Z - a.Z).Magnitude * 0.3)
			local top = math.max(a.Y, b.Y) + lift
			for k = 1, 7 do
				local t = k / 8
				local p = a:Lerp(b, t)
				-- a parabola through a and b, peaking `lift` over the higher end
				local y = (1 - t) * (1 - t) * a.Y + 2 * (1 - t) * t * (2 * top - (a.Y + b.Y) / 2) + t * t * b.Y
				table.insert(pts, V3.new(p.X, y, p.Z))
			end
		end
		table.insert(pts, b)
		for k = 2, #pts do
			line(pts[k - 1], pts[k], color)
		end
		head(pts[#pts - 1], b, color)
		if link.Bidirectional ~= false then
			head(pts[2], a, color)
		end
	end
	return list
end

-- The mesh's triangles coloured by area (AreaColors by name; others DEFAULT_AREA_COLOR), on one
-- layer "Mesh" so a renderer makes one fill per colour, not per floor; walls and seams too.
function Draw.Areas(NavMesh: any, mesh: any, areas: { [string]: number }, areaColors: { [string]: string }): { any }
	local palette = {}
	for id = 1, 64 do
		palette[id] = Draw.DEFAULT_AREA_COLOR
	end
	for name, id in areas do
		palette[id] = areaColors[name] or Draw.DEFAULT_AREA_COLOR
	end
	local list = NavMesh.ToDrawList(mesh, { Seams = true, Areas = true, AreaColors = palette, WallColor = "#ffffff" })
	for _, primitive in list do
		if primitive.Kind == "Tri" then
			primitive.Layer = "Mesh"
		end
	end
	return list
end

return Draw
