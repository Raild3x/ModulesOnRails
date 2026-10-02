--!strict
-- Bakes a map for Studio: runs its scenarios here (Harness, as run.luau) and writes what Studio
-- draws, so Studio only builds the Parts. A big map's FromParts, Build and GenerateLinks run for
-- longer than Studio's 10-second "plugin not responding" watchdog. studio.py runs this for a map
-- with `Bake = true`.
--   lune run tools/navmesh/maps/bake.luau <Map> <outDir>
-- Writes <outDir>/Mesh.txt (NavMesh.Serialize, hex: a StringValue under Rojo) and
-- <outDir>/Data.json (the table text, the area names, the links, each scenario's waypoints).
local fs = require("@lune/fs")
local process = require("@lune/process")
local serde = require("@lune/serde")
local roblox = require("@lune/roblox") :: any
local NavMesh = require("../../../lib/navmesh/src/NavMesh")
local Adapter = require("../../../lib/navmeshadapter/src/NavMeshAdapter")
local Harness = require("./Harness")

local name, out = process.args[1], process.args[2]
assert(name and out, "usage: lune run tools/navmesh/maps/bake.luau <Map> <outDir>")
local report = Harness.Run((require :: any)("./Maps/" .. name), NavMesh, Adapter, roblox)
local text = Harness.Format(report)
print(text)

local function xyz(p: any): { number }
	return { p.X, p.Y, p.Z }
end
local links = {}
for _, link in report.Desc.Links or {} do
	table.insert(
		links,
		{ From = xyz(link.From), To = xyz(link.To), Label = link.Label, Bidirectional = link.Bidirectional }
	)
end
local paths = {}
for _, row in report.Rows do
	local waypoints = {}
	for _, w in row.Path.Waypoints do
		table.insert(waypoints, { Position = xyz(w.Position), Label = w.Label })
	end
	table.insert(paths, waypoints)
end
local bytes = buffer.tostring(NavMesh.Serialize(report.Mesh))
fs.writeDir(out)
fs.writeFile(`{out}/Mesh.txt`, (bytes:gsub(".", function(c: string): string
	return string.format("%02x", string.byte(c))
end)))
fs.writeFile(
	`{out}/Data.json`,
	serde.encode("json", { Text = text, Areas = report.Areas, Links = links, Paths = paths })
)
process.exit(if report.Pass then 0 else 1)
