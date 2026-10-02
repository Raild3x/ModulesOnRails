--!strict
-- A map's mesh seen from above, as SVG and PNG (headless Edge): no Studio needed. North (low Z)
-- is up, east right. Reads the bake (bake.luau's Mesh.txt and Data.json) so a big map isn't
-- rebuilt each time; bake first (studio.py does, or run bake.luau yourself).
--   lune run tools/navmesh/maps/plan.luau <Map> <outDir> [options]
-- Options:
--   --baked DIR          the bake to read (default .bench/navmesh/maps/Baked)
--   --region x0,z0,x1,z1 only this part of the map (default all)
--   --color area|floor|slope   triangle colours (default area): area as Studio's legend; floor
--                        a colour per floor (shows how the ground splits); slope by 5-degree band
--   --hide links,paths,walls,seams,mesh   layers to leave out
--   --from x,y,z --to x,y,z    a probe path (magenta), printed too; with
--   --radius r (default 1) --costs on|off (default on: the map's Filter) --links on|off
--   --size px            image width and height (default 1400)
--   --name NAME          output file name (default <Map>)
local fs = require("@lune/fs")
local process = require("@lune/process")
local serde = require("@lune/serde")
local roblox = require("@lune/roblox") :: any
local NavMesh = require("../../../lib/navmesh/src/NavMesh")
local Storage = require("../../../lib/navmesh/src/Storage")
local SvgBackend = require("../../../lib/constraineddelaunaydebug/src/SvgBackend")
local Draw = require("./Draw")

local EDGE = "C:/Program Files (x86)/Microsoft/Edge/Application/msedge.exe"
local V3 = roblox.Vector3
local LINK_COLORS = { Drop = "#000000", Jump = "#00a040" }
local SLOPE_COLORS =
	{ "#1a9850", "#66bd63", "#a6d96a", "#d9ef8b", "#fee08b", "#fdae61", "#f46d43", "#d73027", "#a50026" }
local FLOOR_COLORS = { "#e6194b", "#3cb44b", "#ffe119", "#4363d8", "#f58231", "#911eb4", "#46f0f0", "#f032e6" }

local args = process.args
local mapName, outDir = args[1], args[2]
assert(mapName and outDir, "usage: lune run tools/navmesh/maps/plan.luau <Map> <outDir> [options]")
local opt: { [string]: string } = {}
for i = 3, #args, 2 do
	opt[args[i]:gsub("^%-%-", "")] = args[i + 1]
end
local function numbers(s: string): { number }
	local out = {}
	for v in s:gmatch("[^,]+") do
		local n = tonumber(v)
		assert(n, `not a number: {v}`)
		table.insert(out, n)
	end
	return out
end
local hide = {}
for layer in (opt.hide or ""):gmatch("[^,]+") do
	hide[layer] = true
end

local map = (require :: any)("./Maps/" .. mapName)
local baked = opt.baked or ".bench/navmesh/maps/Baked"
local data = serde.decode("json", fs.readFile(`{baked}/Data.json`))
assert(data.Text:find("== " .. mapName .. "\n", 1, true), `{baked} holds another map's bake`)
local hex = fs.readFile(`{baked}/Mesh.txt`)
local bytes = buffer.create(#hex // 2)
for i = 0, #hex // 2 - 1 do
	buffer.writeu8(bytes, i, tonumber(hex:sub(2 * i + 1, 2 * i + 2), 16) :: number)
end
local mesh = NavMesh.Deserialize(bytes)
local function v3(p: { number }): any
	return V3.new(p[1], p[2], p[3])
end

-- Triangles.
local list = {}
local color = opt.color or "area"
if not hide.mesh then
	if color == "area" then
		list = Draw.Areas(NavMesh, mesh, data.Areas, map.AreaColors or {})
	else
		list = NavMesh.ToDrawList(mesh, { Seams = true, WallColor = "#000000" })
		for _, p in list do
			if p.Kind ~= "Tri" then
				continue
			end
			local pts = p.Points
			if color == "slope" then
				local a = vector.create(pts[1], pts[2], pts[3])
				local n =
					vector.cross(vector.create(pts[4], pts[5], pts[6]) - a, vector.create(pts[7], pts[8], pts[9]) - a)
				local deg = math.deg(math.acos(math.abs(vector.normalize(n).y)))
				p.Color = SLOPE_COLORS[math.min(#SLOPE_COLORS, deg // 5 + 1)]
			else
				local floor = tonumber((p.Layer :: string):match("%d+$")) or #p.Layer
				p.Color = FLOOR_COLORS[floor % #FLOOR_COLORS + 1]
			end
			p.Layer = "Mesh"
		end
	end
end
for _, p in list do
	if p.Layer == "Walls" then
		p.Color = "#000000"
	end
end

local links = {}
for _, link in data.Links do
	table.insert(
		links,
		{ From = v3(link.From), To = v3(link.To), Label = link.Label, Bidirectional = link.Bidirectional }
	)
end
if not hide.links then
	for _, p in Draw.Links(links, V3, LINK_COLORS, "#a020f0") do
		table.insert(list, p)
	end
end
if not hide.paths then
	local paths = {}
	for _, waypoints in data.Paths do
		local path = { Waypoints = {} }
		for _, w in waypoints do
			table.insert(path.Waypoints, { Position = v3(w.Position), Label = w.Label })
		end
		table.insert(paths, path)
	end
	for _, p in NavMesh.ToDrawList(mesh, { Triangles = false, PathColors = { "#ff3b30", "#2f8cff", "#bf5af2" } }, paths) do
		table.insert(list, p)
	end
end

-- The probe.
if opt.from and opt.to then
	local filter = if opt.costs ~= "off" and map.Filter then table.clone(map.Filter(data.Areas)) else {}
	filter.AgentRadius = tonumber(opt.radius) or 1
	if opt.links == "off" then
		for id = 1, #links do
			NavMesh.SetLinkEnabled(mesh, id, false)
		end
	end
	local path = NavMesh.FindPath(mesh, v3(numbers(opt.from)), v3(numbers(opt.to)), filter)
	local used = {}
	for _, w in path.Waypoints do
		if w.Label then
			table.insert(used, w.Label)
		end
	end
	print(
		string.format(
			"probe: %s, length %.1f, cost %.1f, %d waypoints%s",
			path.Status,
			path.Length,
			path.Cost,
			#path.Waypoints,
			if #used > 0 then ", via " .. table.concat(used, ", ") else ""
		)
	)
	for _, w in path.Waypoints do
		print(
			string.format(
				"  %.1f %.1f %.1f  %s%s",
				w.Position.X,
				w.Position.Y,
				w.Position.Z,
				w.Floor,
				if w.Label then "  " .. w.Label else ""
			)
		)
	end
	for _, p in NavMesh.ToDrawList(mesh, { Triangles = false, PathColors = { "#ff00ff" } }, path) do
		p.Layer = "Probe"
		table.insert(list, p)
	end
end

-- Keep the region, then mirror Z so north is up.
local region = if opt.region then numbers(opt.region) else nil
local kept = {}
for _, p in list do
	if (p.Layer == "Walls" and hide.walls) or (p.Layer == "Seams" and hide.seams) then
		continue
	end
	local pts = p.Points
	local inside = region == nil
	for i = 1, #pts, 3 do
		if
			region
			and pts[i] >= region[1]
			and pts[i] <= region[3]
			and pts[i + 2] >= region[2]
			and pts[i + 2] <= region[4]
		then
			inside = true
		end
	end
	if inside then
		local q = table.clone(pts)
		for i = 3, #q, 3 do
			q[i] = -q[i]
		end
		p.Points = q
		table.insert(kept, p)
	end
end

local size = tonumber(opt.size) or 1400
local name = opt.name or mapName
local title = `{mapName} {opt.region or "all"}, colour {color} (north up)`
local svg = SvgBackend.Render(kept, { Width = size, Height = size, Title = title })
fs.writeDir(outDir)
local svgPath = `{outDir}/{name}.svg`
fs.writeFile(svgPath, svg)
local cwd = process.cwd:gsub("\\", "/")
local function abs(path: string): string
	return if path:match("^%a:") then path else `{cwd}/{path}`
end
local result = process.exec(EDGE, {
	"--headless",
	"--disable-gpu",
	"--hide-scrollbars",
	`--window-size={size},{size}`,
	`--screenshot={abs(outDir)}/{name}.png`,
	`file:///{abs(svgPath)}`,
})
print(if result.ok then `wrote {outDir}/{name}.png ({#kept} shapes)` else `edge failed: {result.stderr}`)
