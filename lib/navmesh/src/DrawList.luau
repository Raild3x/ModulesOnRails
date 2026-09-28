--!strict
-- Authors: Logan Hunt (Raildex)
-- September 25, 2026
--[=[
	@class NavMeshDrawList
	@private

	`NavMesh.ToDrawList`: the mesh state as a DrawList (the type lives in the CDT, P1), for the
	debug backends and goldens. Coordinates are world studs; floors are layered as
	`Floor:<name>`.
]=]

local CDT = require("../ConstrainedDelaunay")
local Storage = require("./Storage")
local Types = require("./Types")

type DrawList = CDT.DrawList

local FLOOR_COLORS = { "#43a047", "#1e88e5", "#fb8c00", "#8e24aa", "#00897b", "#e53935" }
local AREA_COLORS = { "#9e9e9e", "#8d6e63", "#29b6f6", "#ffca28", "#ab47bc", "#66bb6a" }
local WALL_COLOR = "#212121"
local TILE_COLOR = "#ff7043"
local PATH_COLOR = "#d81b60"

local DrawList = {}

local function paletteColor(palette: { string }, id: number): string
	return palette[(id - 1) % #palette + 1]
end

-- Clearance heat: the widest crossing through the triangle, from red (under 1 stud) through
-- yellow to green (8 studs and over).
local function clearanceColor(s: Storage.State, t: number): string
	local widest = 0
	for k = 1, 3 do
		if Storage.GetNeighbor(s, t, k % 3 + 1) ~= 0 and Storage.GetNeighbor(s, t, (k + 1) % 3 + 1) ~= 0 then
			widest = math.max(widest, Storage.GetCornerWidth(s, t, k))
		end
	end
	local u = math.clamp((widest - 1) / 7, 0, 1)
	local red = math.floor(255 * math.min(1, 2 * (1 - u)) + 0.5)
	local green = math.floor(200 * math.min(1, 2 * u) + 0.5)
	return string.format("#%02x%02x40", red, green)
end

function DrawList.ToDrawList(s: Storage.State, options: Types.NavMeshDrawOptions?, path: Types.PathResult?): DrawList
	local opts: Types.NavMeshDrawOptions = options or {}
	local list: DrawList = {}

	if opts.Triangles ~= false then
		for t = 1, Storage.TriangleCount(s) do
			local a, b, c = Storage.GetTriangle(s, t)
			local pa, pb, pc = Storage.GetVertex(s, a), Storage.GetVertex(s, b), Storage.GetVertex(s, c)
			local floor = Storage.GetTriangleFloor(s, t)
			table.insert(list, {
				Kind = "Tri",
				Points = { pa.X, pa.Y, pa.Z, pb.X, pb.Y, pb.Z, pc.X, pc.Y, pc.Z },
				Color = if opts.Clearance
					then clearanceColor(s, t)
					elseif opts.Areas then paletteColor(AREA_COLORS, Storage.GetTriangleArea(s, t))
					else paletteColor(FLOOR_COLORS, floor),
				Layer = `Floor:{Storage.GetFloorName(s, floor)}`,
			})
		end
		-- Walls: triangle edges with no neighbour.
		for t = 1, Storage.TriangleCount(s) do
			local verts = { Storage.GetTriangle(s, t) }
			for e = 1, 3 do
				if Storage.GetNeighbor(s, t, e) == 0 then
					local p = Storage.GetVertex(s, verts[e % 3 + 1])
					local q = Storage.GetVertex(s, verts[(e + 1) % 3 + 1])
					table.insert(list, {
						Kind = "Line",
						Points = { p.X, p.Y, p.Z, q.X, q.Y, q.Z },
						Color = WALL_COLOR,
						Layer = "Walls",
					})
				end
			end
		end
	end

	if opts.Tiles then
		for tile = 1, Storage.TileCount(s) do
			local x0, z0, x1, z1 = Storage.GetTileBounds(s, tile)
			local corners = { x0, z0, x1, z0, x1, z1, x0, z1 }
			for k = 0, 3 do
				local i, j = 2 * k + 1, (2 * k + 2) % 8 + 1
				table.insert(list, {
					Kind = "Line",
					Points = { corners[i], 0, corners[i + 1], corners[j], 0, corners[j + 1] },
					Color = TILE_COLOR,
					Layer = "Tiles",
				})
			end
		end
	end

	if path then
		local waypoints = path.Waypoints
		for i, w in waypoints do
			local p = w.Position
			if i > 1 then
				local q = waypoints[i - 1].Position
				table.insert(
					list,
					{ Kind = "Line", Points = { q.X, q.Y, q.Z, p.X, p.Y, p.Z }, Color = PATH_COLOR, Layer = "Path" }
				)
			end
			table.insert(list, { Kind = "Point", Points = { p.X, p.Y, p.Z }, Color = PATH_COLOR, Layer = "Path" })
		end
	end
	return list
end

return DrawList
