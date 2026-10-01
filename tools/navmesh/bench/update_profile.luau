--!strict
-- Ticket 31: where a warm Update's time goes as the mesh grows. Copies lib/navmesh to
-- .bench/navmesh/prof/ and inserts clock marks into the copy's Tiles.luau (anchored on code
-- text, so they survive line shifts; library code is untouched), wraps Build.Internal's
-- TileInputs and TriangulateTile, then loads the default-TileSize bakes
-- large_world.luau wrote (its `bakes` option) and adds and removes one 4 x 4 crate near the
-- centre (LargeWorld.luau's crate), cycles times each. Cells are medians in ms.
--   lune run tools/navmesh/bench/update_profile.luau [map=open] [cycles=7]
-- "ring scan" is re-snap minus TileInputs and TriangulateTile: the bounds test of every authored
-- ring on the floor (reSnap) and the cached ring surfaces.
local fs = require("@lune/fs")
local process = require("@lune/process")

local map = process.args[1] or "open"
local cycles = tonumber(process.args[2]) or 7
local DIR = ".bench/navmesh/large_world"
local PROF = ".bench/navmesh/prof"

local function copyDir(from: string, to: string)
	fs.writeDir(to)
	for _, name in fs.readDir(from) do
		local a, b = `{from}/{name}`, `{to}/{name}`
		if fs.isDir(a) then
			copyDir(a, b)
		else
			fs.writeFile(b, fs.readFile(a))
		end
	end
end
if fs.isDir(PROF) then
	fs.removeDir(PROF)
end
copyDir("lib/navmesh", `{PROF}/navmesh`)

-- Marks, each inserted before the first match of its anchor after its function's start. A mark
-- charges the time since the previous one to its name.
local MARK =
	'do local P = _G.PROF; if P then local c = os.clock(); P["%s"] = (P["%s"] or 0) + (c - P._t) * 1000; P._t = c end end\n\t'
local MARKS = {
	{ "local function prepare", "-- Heights and vertex ids by grid point", "dirty tiles" },
	{ "local function prepare", "-- New triangles for each dirty tile.", "height scan" },
	{ "local function prepare", "-- Scratch: vertices interned", "re-snap" },
	{ "local function prepare", "-- Vertex slots.", "scratch" },
	{ "local function prepare", "-- The new triangle layout", "vertex slots" },
	{ "local function prepare", "return {\n\t\tPendingFloors", "layout" },
	{ "local function apply", "for _, tile in plan.DirtyList do", "clean copy" },
	{ "local function apply", "-- Vertices: moved ones down", "dirty write" },
	{ "local function apply", "-- Cross-tile neighbours", "vertices" },
	{ "local function apply", "-- Seams: clean pieces renumbered", "open edges" },
	{ "local function apply", "Internal.Connect(n)", "seams, links" },
	{ "local function apply", "-- Obstacles: the pending changes committed", "Connect" },
	{ "local function apply", "-- Clearance. A rebuilt triangle", "obstacles" },
	{ "local function apply", "local changedTiles = Clearance.Refresh", "width carry" },
	{ "local function apply", "for tile in dirty do", "Refresh" },
	{ "local function apply", "return n, changedRegions", "stamps" },
}
local path = `{PROF}/navmesh/src/Tiles.luau`
local source = string.gsub(fs.readFile(path), "\r\n", "\n") -- autocrlf checkouts
for _, m in MARKS do
	local start = assert(string.find(source, m[1], 1, true), m[1])
	local at = assert(string.find(source, m[2], start, true), m[2])
	source = string.sub(source, 1, at - 1) .. string.format(MARK, m[3], m[3]) .. string.sub(source, at)
end
source = string.gsub(
	source,
	"(local function prepare%(s: State%): Plan\n)",
	"%1\tif _G.PROF then _G.PROF._t = os.clock() end\n"
)
fs.writeFile(path, source)

local NavMesh = (require :: any)("../../../.bench/navmesh/prof/navmesh/src/NavMesh")
local Build = (require :: any)("../../../.bench/navmesh/prof/navmesh/src/Build")
local Storage = (require :: any)("../../../.bench/navmesh/prof/navmesh/src/Storage")
-- Wrapped calls are charged to their own names and kept out of the marks around them.
local function wrap(module: any, name: string, label: string)
	local f = module[name]
	module[name] = function(...)
		local P = _G.PROF
		local t0 = os.clock()
		local a, b, c = f(...)
		if P then
			local spent = (os.clock() - t0) * 1000
			P[label] = (P[label] or 0) + spent
			P._t += spent / 1000
		end
		return a, b, c
	end
end
wrap(Build.Internal, "TileInputs", "TileInputs")
wrap(Build.Internal, "TriangulateTile", "TriangulateTile")

local ORDER = {
	"dirty tiles",
	"height scan",
	"re-snap",
	"TileInputs",
	"TriangulateTile",
	"scratch",
	"vertex slots",
	"layout",
	"clean copy",
	"dirty write",
	"vertices",
	"open edges",
	"seams, links",
	"Connect",
	"obstacles",
	"width carry",
	"Refresh",
	"stamps",
}

local function median(xs: { number }): number
	local s = table.clone(xs)
	table.sort(s)
	return s[(#s + 1) // 2]
end

print(`map {map}; ms per Update, median of {cycles * 2} (re-snap here is the ring scan)`)
print("| side | tris | rings | total | " .. table.concat(ORDER, " | ") .. " |")
print("|" .. string.rep("---|", #ORDER + 4))
for _, side in { 1024, 2048, 4096 } do
	local bake = `{DIR}/{map}-{side}.bin`
	if not fs.isFile(bake) then
		continue
	end
	local mesh = NavMesh.Deserialize(buffer.fromstring(fs.readFile(bake)))
	local rings = 0
	for f = 1, Storage.FloorCount(mesh) do
		local _, _, _, r = Storage.GetFloorSources(mesh, f)
		rings += #r
	end
	math.randomseed(3100 + side)
	local at = NavMesh.FindRandomPoint(mesh, { Center = vector.create(side / 2, 0, side / 2), Radius = side / 8 })
	local p = at.Position
	local crate = {
		vector.create(p.X - 2, p.Y, p.Z - 2),
		vector.create(p.X + 2, p.Y, p.Z - 2),
		vector.create(p.X + 2, p.Y, p.Z + 2),
		vector.create(p.X - 2, p.Y, p.Z + 2),
	}
	-- One untimed cycle builds the wall index (the load spike).
	local id = NavMesh.AddObstacle(mesh, at.Floor, crate)
	NavMesh.Update(mesh)
	NavMesh.RemoveObstacle(mesh, id)
	NavMesh.Update(mesh)
	local runs, totals = {}, {}
	for i = 1, cycles * 2 do
		if i % 2 == 1 then
			id = NavMesh.AddObstacle(mesh, at.Floor, crate)
		else
			NavMesh.RemoveObstacle(mesh, id)
		end
		_G.PROF = {}
		local t0 = os.clock()
		NavMesh.Update(mesh)
		table.insert(totals, (os.clock() - t0) * 1000)
		table.insert(runs, _G.PROF)
	end
	_G.PROF = nil
	local cells = {}
	for _, name in ORDER do
		local xs = {}
		for _, r in runs do
			table.insert(xs, r[name] or 0)
		end
		table.insert(cells, string.format("%.1f", median(xs)))
	end
	print(
		string.format("| %d | %d | %d | %.1f | ", side, Storage.TriangleCount(mesh), rings, median(totals))
			.. table.concat(cells, " | ")
			.. " |"
	)
end
