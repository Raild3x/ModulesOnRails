--!strict
--[=[
	P4 probe (ticket 15, U-a): how far clearance widths depend on walls, on the bench scenes plus
	an open-floor worst case, using the shipped `Clearance` (see its docs for the width model).

	A width of 2r* can change only when a wall within r* of its triangle changes, so r* is how
	far `Update` must look. Only widths a query reads count: corners between two crossable edges.

	lune run tools/navmesh/bench/clearance_probe.luau
]=]

local NavMesh = require("../../../lib/navmesh/src/NavMesh")
local Storage = require("../../../lib/navmesh/src/Storage")
local Scenes = require("./Scenes")

local function probe(name: string, desc: any, caps: { number })
	local t0 = os.clock()
	local mesh = NavMesh.Build(desc)
	local buildMs = (os.clock() - t0) * 1000
	local x0, _, x1 = Storage.GetTileBounds(mesh, 1)
	local tileSize = x1 - x0
	local rs = {}
	for t = 1, Storage.TriangleCount(mesh) do
		for k = 1, 3 do
			if Storage.GetNeighbor(mesh, t, k % 3 + 1) ~= 0 and Storage.GetNeighbor(mesh, t, (k + 1) % 3 + 1) ~= 0 then
				table.insert(rs, Storage.GetCornerWidth(mesh, t, k) / 2)
			end
		end
	end
	table.sort(rs)
	local function pct(p: number): number
		return rs[math.max(1, math.ceil(p * #rs))]
	end
	local capped = {}
	for _, cap in caps do
		local over = 0
		for _, r in rs do
			if r > cap then
				over += 1
			end
		end
		table.insert(capped, string.format("%.1f%%", 100 * over / #rs))
	end
	print(
		string.format(
			"| %s | %g | %.1f / %.1f / %.1f / %.1f | %.2f / %.2f | %s | %.0f |",
			name,
			tileSize,
			pct(0.5),
			pct(0.9),
			pct(0.99),
			rs[#rs],
			pct(0.99) / tileSize,
			rs[#rs] / tileSize,
			table.concat(capped, " / "),
			buildMs
		)
	)
end

print("| scene | tile | r* p50 / p90 / p99 / max (studs) | reach p99 / max (tiles) | capped at R = 2 / 4 / 8 | Build ms |")
print("|---|---|---|---|---|---|")
for _, scene in Scenes do
	probe(scene.Name, scene.Make(), { 2, 4, 8 })
end
-- Worst case for an uncapped reach: a big open floor with a few pillars and small explicit tiles.
local pillars = {}
for i = 1, 6 do
	local cx, cz = 60 + 70 * i, 256 + (if i % 2 == 0 then 120 else -120)
	table.insert(pillars, {
		vector.create(cx - 2, 0, cz - 2),
		vector.create(cx + 2, 0, cz - 2),
		vector.create(cx + 2, 0, cz + 2),
		vector.create(cx - 2, 0, cz + 2),
	})
end
probe("open (TileSize 16)", {
	TileSize = 16,
	Floors = {
		Ground = {
			Walkable = {
				{ vector.create(0, 0, 0), vector.create(512, 0, 0), vector.create(512, 0, 512), vector.create(0, 0, 512) },
			},
			Obstacles = pillars,
		},
	},
}, { 2, 4, 8 })
