--!strict
-- Ticket 31: what a loaded mesh holds in memory. Deserializes a bake large_world.luau wrote (its
-- `bakes` option) and lists the Storage fields by size: a buffer's allocated length, and a
-- rough size for tables (16 bytes per entry plus contents, 4 levels deep). "per tri" divides
-- by the live triangle count, which shows the growth capacity left in each buffer.
--   lune run tools/navmesh/bench/heap_fields.luau [bake=open-2048]
local fs = require("@lune/fs")
local process = require("@lune/process")
local NavMesh = require("../../../lib/navmesh/src/NavMesh")
local Storage = require("../../../lib/navmesh/src/Storage")

local name = process.args[1] or "open-2048"
local mesh = NavMesh.Deserialize(buffer.fromstring(fs.readFile(`.bench/navmesh/large_world/{name}.bin`)))
local tris = Storage.TriangleCount(mesh)

local function size(v: any, depth: number): number
	if type(v) == "buffer" then
		return buffer.len(v)
	elseif type(v) == "string" then
		return #v
	elseif type(v) == "table" and depth < 4 then
		local n = 0
		for _, x in v do
			n += 16 + size(x, depth + 1)
		end
		return n
	end
	return 0
end

local rows, total, buffers = {}, 0, 0
for key, value in mesh :: any do
	local bytes = size(value, 0)
	total += bytes
	if type(value) == "buffer" then
		buffers += bytes
	end
	table.insert(rows, { key, typeof(value), bytes })
end
table.sort(rows, function(a, b)
	return a[3] > b[3]
end)
print(`{name}: {tris} triangles, {Storage.VertexCount(mesh)} vertices`)
print("| field | type | KB | bytes per tri |")
print("|---|---|---|---|")
for _, row in rows do
	if row[3] >= 1024 then
		print(string.format("| %s | %s | %.0f | %.1f |", row[1], row[2], row[3] / 1024, row[3] / tris))
	end
end
print(string.format("| total | | %.0f | %.1f |", total / 1024, total / tris))
print(string.format("| of which buffers | | %.0f | %.1f |", buffers / 1024, buffers / tris))
