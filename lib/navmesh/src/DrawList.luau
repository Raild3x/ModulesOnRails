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
local SEAM_COLOR = "#00acc1"
local LINK_COLOR = "#6a1b9a"
local DISABLED_LINK_COLOR = "#ce93d8"

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

function DrawList.ToDrawList(
	s: Storage.State,
	options: Types.NavMeshDrawOptions?,
	paths: (Types.PathResult | { Types.PathResult })?
): DrawList
	local opts: Types.NavMeshDrawOptions = options or {}
	local floorColors = opts.FloorColors or FLOOR_COLORS
	local areaColors = opts.AreaColors or AREA_COLORS
	local wallColor = opts.WallColor or WALL_COLOR
	local pathColors = opts.PathColors or { PATH_COLOR }
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
					elseif opts.Areas then paletteColor(areaColors, Storage.GetTriangleArea(s, t))
					else paletteColor(floorColors, floor),
				Layer = `Floor:{Storage.GetFloorName(s, floor)}`,
			})
		end
		-- Walls: triangle edges with no neighbour.
		for t = 1, Storage.TriangleCount(s) do
			local verts = { Storage.GetTriangle(s, t) }
			for e = 1, 3 do
				if Storage.IsWallEdge(s, t, e) then
					local p = Storage.GetVertex(s, verts[e % 3 + 1])
					local q = Storage.GetVertex(s, verts[(e + 1) % 3 + 1])
					table.insert(list, {
						Kind = "Line",
						Points = { p.X, p.Y, p.Z, q.X, q.Y, q.Z },
						Color = wallColor,
						Layer = "Walls",
					})
				end
			end
		end
	end

	if opts.Tiles then
		for tile = 1, Storage.TileCount(s) do
			local x0, z0, x1, z1 = Storage.GetTileBounds(s, tile)
			-- At the lowest height of the tile's triangles (0 for an empty tile).
			local first, count = Storage.GetTileRange(s, tile)
			local y = if count > 0 then math.huge else 0
			for t = first, first + count - 1 do
				local a, b, c = Storage.GetTriangle(s, t)
				y = math.min(y, Storage.GetVertex(s, a).Y, Storage.GetVertex(s, b).Y, Storage.GetVertex(s, c).Y)
			end
			local corners = { x0, z0, x1, z0, x1, z1, x0, z1 }
			for k = 0, 3 do
				local i, j = 2 * k + 1, (2 * k + 2) % 8 + 1
				table.insert(list, {
					Kind = "Line",
					Points = { corners[i], y, corners[i + 1], corners[j], y, corners[j + 1] },
					Color = TILE_COLOR,
					Layer = "Tiles",
				})
			end
		end
	end

	if opts.Seams then
		-- Each portal once (it is stored both ways).
		for t = 1, Storage.TriangleCount(s) do
			local id = Storage.GetExtraHead(s, t)
			while id ~= 0 do
				local nextId, target, kind, _, a, b = Storage.GetExtra(s, id)
				if kind == Storage.EXTRA_SEAM and t < target then
					table.insert(list, {
						Kind = "Line",
						Points = { a.X, a.Y, a.Z, b.X, b.Y, b.Z },
						Color = SEAM_COLOR,
						Layer = "Seams",
					})
				end
				id = nextId
			end
		end
	end

	if opts.Links then
		for id = 1, Storage.LinkCount(s) do
			local _, from, _, to, _, _, _, both, enabled = Storage.GetLink(s, id)
			local color = if enabled then LINK_COLOR else DISABLED_LINK_COLOR
			table.insert(list, {
				Kind = "Arrow",
				Points = { from.X, from.Y, from.Z, to.X, to.Y, to.Z },
				Color = color,
				Layer = "Links",
			})
			if both then
				table.insert(list, {
					Kind = "Arrow",
					Points = { to.X, to.Y, to.Z, from.X, from.Y, from.Z },
					Color = color,
					Layer = "Links",
				})
			end
		end
	end

	-- One path, or a list of them (a PathResult always has Waypoints).
	local pathList: { Types.PathResult } = if paths == nil
		then {}
		elseif (paths :: any).Waypoints then { paths :: Types.PathResult }
		else paths :: { Types.PathResult }
	for n, path in pathList do
		local color = paletteColor(pathColors, n)
		local waypoints = path.Waypoints
		for i, w in waypoints do
			local p = w.Position
			if i > 1 then
				local q = waypoints[i - 1].Position
				table.insert(
					list,
					{ Kind = "Line", Points = { q.X, q.Y, q.Z, p.X, p.Y, p.Z }, Color = color, Layer = "Path" }
				)
			end
			table.insert(list, { Kind = "Point", Points = { p.X, p.Y, p.Z }, Color = color, Layer = "Path" })
		end
	end
	return list
end

return DrawList
