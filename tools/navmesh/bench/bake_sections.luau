--!strict
-- Ticket 31: where a bake's bytes go. Reads the bakes large_world.luau wrote (its `bakes`
-- option) and prints each v3 section's share, raw and zstd-compressed alone, then the triangle
-- section re-encoded with narrower widths.
--   lune run tools/navmesh/bench/bake_sections.luau [side=4096]
-- The section names follow the table at the top of lib/navmesh/src/Serialize.luau.
local fs = require("@lune/fs")
local process = require("@lune/process")
local serde = require("@lune/serde")
local NavMesh = require("../../../lib/navmesh/src/NavMesh")
local Storage = require("../../../lib/navmesh/src/Storage")

local NAMES = {
	[0x8001] = "cap",
	[0x8002] = "floors + authored rings",
	[0x8003] = "tiles",
	[0x8004] = "vertices",
	[0x8005] = "triangles",
	[0x8006] = "seams",
	[0x8007] = "links",
	[0x8008] = "obstacles",
}
local DIR = ".bench/navmesh/large_world"
local side = process.args[1] or "4096"

print("| bake | section | KB | share | zstd KB |")
print("|---|---|---|---|---|")
for _, file in fs.readDir(DIR) do
	if not string.find(file, `-{side}%.bin$`) then
		continue
	end
	local data = buffer.fromstring(fs.readFile(`{DIR}/{file}`))
	local total = buffer.len(data)
	local at = 6 -- "NVMS" and the u16 version
	while at < total do
		local tag, length = buffer.readu16(data, at), buffer.readu32(data, at + 2)
		local payload = buffer.create(length)
		buffer.copy(payload, 0, data, at + 6, length)
		print(
			string.format(
				"| %s | %s | %.0f | %.1f%% | %.0f |",
				file,
				NAMES[tag] or string.format("0x%04x", tag),
				length / 1024,
				100 * length / total,
				#serde.compress("zstd", payload, 19) / 1024
			)
		)
		at += 6 + length
	end

	-- The triangle section re-encoded with narrower widths (a size prototype, never read
	-- back): f32 widths, and u16 widths in 1/256 studs (rounded down, so never wider than
	-- built; a radius-2 cap needs at most 4 studs, so u16 holds any capped width).
	local mesh = NavMesh.Deserialize(data)
	for _, variant in { { "f32 widths", 4 }, { "u16 widths", 2 } } do
		local name, bytes = variant[1], variant[2]
		local count = Storage.TriangleCount(mesh)
		local out = buffer.create(Storage.TileCount(mesh) * 4 + count * (29 + 6 * bytes))
		local at2 = 0
		local function put(write: (buffer, number, number) -> (), size: number, v: number)
			write(out, at2, v)
			at2 += size
		end
		for tile = 1, Storage.TileCount(mesh) do
			local first, n = Storage.GetTileRange(mesh, tile)
			put(buffer.writeu32, 4, n)
			for t = first, first + n - 1 do
				for _, v in { Storage.GetTriangle(mesh, t) } do
					put(buffer.writeu32, 4, v)
				end
				for e = 1, 3 do
					put(buffer.writeu32, 4, Storage.GetNeighbor(mesh, t, e))
				end
				put(buffer.writeu32, 4, Storage.GetTriangleArea(mesh, t))
				put(buffer.writeu8, 1, 0)
				for k = 1, 3 do
					for _, w in { Storage.GetCornerWidth(mesh, t, k), Storage.GetPortalWidth(mesh, t, k) } do
						if bytes == 4 then
							put(buffer.writef32, 4, w)
						else
							put(buffer.writeu16, 2, math.clamp(math.floor(w * 256), 0, 65535))
						end
					end
				end
			end
		end
		print(
			string.format(
				"| %s | triangles, %s | %.0f | | %.0f |",
				file,
				name,
				at2 / 1024,
				#serde.compress("zstd", out, 19) / 1024
			)
		)
	end
end
