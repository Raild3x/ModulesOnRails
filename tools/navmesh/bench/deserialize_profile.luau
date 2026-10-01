--!strict
-- Ticket 31: where Deserialize's time goes on a big bake, and how low a bulk loader could go.
-- Loads the default-TileSize bakes large_world.luau wrote (its `bakes` option), 5 times each:
-- - total: NavMesh.Deserialize;
-- - Connect: Build.Internal.Connect (rebuilding seam portals and links), wrapped;
-- - read: the rest, the per-field reads and Storage setters (about 17 accessor calls per
--   triangle);
-- - memcpy floor: copying the bake's bytes into fresh buffers of the same size, the cost a
--   loader that copied whole sections into Storage's buffers could not beat.
-- Medians in ms.
--   lune run tools/navmesh/bench/deserialize_profile.luau [side=4096]
local fs = require("@lune/fs")
local process = require("@lune/process")
local NavMesh = require("../../../lib/navmesh/src/NavMesh")
local Build = require("../../../lib/navmesh/src/Build")
local Storage = require("../../../lib/navmesh/src/Storage")

local side = process.args[1] or "4096"
local DIR = ".bench/navmesh/large_world"

local connect = 0
local original = Build.Internal.Connect
Build.Internal.Connect = function(...)
	local t0 = os.clock()
	original(...)
	connect += os.clock() - t0
end

local function median(xs: { number }): number
	local s = table.clone(xs)
	table.sort(s)
	return s[(#s + 1) // 2]
end

print("| bake | tris | total | Connect | read | memcpy floor | total us per tri |")
print("|---|---|---|---|---|---|---|")
for _, file in fs.readDir(DIR) do
	if not string.find(file, `-{side}%.bin$`) then
		continue
	end
	local bake = buffer.fromstring(fs.readFile(`{DIR}/{file}`))
	local totals, connects, copies = {}, {}, {}
	local tris = 0
	for _ = 1, 5 do
		connect = 0
		local t0 = os.clock()
		local mesh = NavMesh.Deserialize(bake)
		table.insert(totals, (os.clock() - t0) * 1000)
		table.insert(connects, connect * 1000)
		tris = Storage.TriangleCount(mesh)
		t0 = os.clock()
		local copy = buffer.create(buffer.len(bake))
		buffer.copy(copy, 0, bake, 0)
		table.insert(copies, (os.clock() - t0) * 1000)
	end
	local total, c = median(totals), median(connects)
	print(
		string.format(
			"| %s | %d | %.0f | %.0f | %.0f | %.1f | %.2f |",
			file,
			tris,
			total,
			c,
			total - c,
			median(copies),
			total * 1000 / tris
		)
	)
end
