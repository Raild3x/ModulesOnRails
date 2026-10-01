--!strict
-- Ticket 31: how Build, the bake and queries scale on 1-4 km maps (LargeMaps.luau). Interpreted
-- Lune, os.clock.
--   lune run tools/navmesh/bench/large_world.luau [sides=1024,2048,4096] [runs=3] [maps=city,open,terrain] [tiles=default,32,...] [bakes]
-- Method (bench.md's audited method): every cell (map, side, TileSize) is measured once per run,
-- with the cell order rotated each run, so drift from the shared machine spreads over all cells.
-- Each run prints [R] lines as it goes; the end prints median [min-max] over runs per cell.
-- `bakes` writes each default-TileSize bake to .bench/navmesh/large_world/ for large_world.py.
local fs = require("@lune/fs")
local process = require("@lune/process")
local serde = require("@lune/serde")
local NavMesh = require("../../../lib/navmesh/src/NavMesh")
local LargeMaps = require("./LargeMaps")
local LargeWorld = require("./LargeWorld")

local args: { [string]: string } = {}
for _, a in process.args do
	local k, v = string.match(a, "^(%w+)=(.*)$")
	args[k or a] = v or "true"
end
local function list(s: string): { string }
	return string.split(s, ",")
end
local sides = list(args.sides or "1024,2048,4096")
local runs = tonumber(args.runs) or 3
local wanted = list(args.maps or "city,open,terrain")
local wantedTiles = if args.tiles then list(args.tiles) else nil
local OUT = ".bench/navmesh/large_world"

-- The default TileSize resolves to 128 on city and 64 on the others at every side (constant
-- density), so each map also gets the two neighbouring powers of two.
local TILES: { [string]: { number | false } } = {
	city = { false, 32, 64 },
	open = { false, 32, 128 },
	terrain = { false, 32, 128 },
}

type Cell = { map: any, side: number, tile: number | false }
local cells: { Cell } = {}
for _, s in sides do
	for _, map in LargeMaps do
		if table.find(wanted, map.Name) then
			for _, tile in TILES[map.Name] do
				if wantedTiles == nil or table.find(wantedTiles, if tile then tostring(tile) else "default") then
					table.insert(cells, { map = map, side = assert(tonumber(s)), tile = tile })
				end
			end
		end
	end
end

local function key(c: Cell): string
	return `{c.map.Name} | {c.side} | {if c.tile then c.tile else "default"}`
end

local results: { [string]: { any } } = {}
local med, pct = LargeWorld.Median, LargeWorld.Pct
if args.bakes then
	fs.writeDir(OUT)
end
print(
	"[HDR] map | side | tile | tris | tiles | build ms | bake KB | zstd KB | deser ms | heap MB | path p50 | path p95 | budget p50 | budget p95 | hits/pairs | cold path | warm path | cold update | update p50"
)
for run = 1, runs do
	for k = 0, #cells - 1 do
		local c = cells[(run - 1 + k) % #cells + 1]
		local desc = c.map.Make(c.side)
		desc.TileSize = c.tile or nil
		desc.MaxAgentRadius = 2
		local t0 = os.clock()
		local mesh = NavMesh.Build(desc)
		local build = (os.clock() - t0) * 1000
		local storage = mesh :: any
		local tris, tiles = storage.TriangleCount, #storage.TileFloor
		local bake = NavMesh.Serialize(mesh)
		mesh, desc, storage = nil :: any, nil, nil
		local zstd = #serde.compress("zstd", bake, 19)
		if args.bakes and not c.tile and run == 1 then
			fs.writeFile(`{OUT}/{c.map.Name}-{c.side}.bin`, bake)
		end
		local r = LargeWorld.Measure({
			NavMesh = NavMesh,
			Clock = os.clock,
			Yield = function() end,
			Reps = 3,
			Pairs = 30,
		}, bake, c.side)
		local row = {
			tris,
			tiles,
			build,
			buffer.len(bake) / 1024,
			zstd / 1024,
			med(r.deserialize),
			r.heap / 1024,
			med(r.path),
			pct(r.path, 0.95),
			med(r.pathBudget),
			pct(r.pathBudget, 0.95),
			r.budgetHits,
			r.pairs,
			r.coldPath,
			r.warmPath,
			r.coldUpdate,
			med(r.update),
		}
		results[key(c)] = results[key(c)] or {}
		table.insert(results[key(c)], row)
		print(
			string.format(
				"[R] run %d | %s | %d | %d | %.0f | %.0f | %.0f | %.1f | %.1f | %.2f | %.2f | %.2f | %.2f | %d/%d | %.2f | %.2f | %.1f | %.1f",
				run,
				key(c),
				table.unpack(row)
			)
		)
	end
end

-- Median [min-max] over runs per column.
print(`\n== median [min-max] over {runs} run(s)`)
print(
	"| map | side | TileSize | tris | tiles | Build ms | bake KB | zstd KB | Deserialize ms | heap MB | FindPath p50 | p95 | Budget p50 | p95 | Budget hits | cold FindPath | warm | cold Update | Update p50 |"
)
print("|" .. string.rep("---|", 19))
local function cell(xs: { number }, fmt: string): string
	local s = table.clone(xs)
	table.sort(s)
	if #s == 1 or s[1] == s[#s] then
		return string.format(fmt, med(xs))
	end
	return string.format(`{fmt} [{fmt}-{fmt}]`, med(xs), s[1], s[#s])
end
for _, c in cells do
	local rows = results[key(c)]
	local function col(i: number): { number }
		local out = {}
		for _, row in rows do
			table.insert(out, row[i])
		end
		return out
	end
	local parts = { key(c), cell(col(1), "%d"), cell(col(2), "%d") }
	for i, fmt in { [3] = "%.0f", [4] = "%.0f", [5] = "%.0f", [6] = "%.1f", [7] = "%.1f" } do
		parts[i + 1] = cell(col(i), fmt)
	end
	for i = 8, 11 do
		table.insert(parts, cell(col(i), "%.2f"))
	end
	table.insert(parts, `{rows[1][12]}/{rows[1][13]}`)
	for i = 14, 17 do
		table.insert(parts, cell(col(i), "%.1f"))
	end
	print("| " .. table.concat(parts, " | ") .. " |")
end
