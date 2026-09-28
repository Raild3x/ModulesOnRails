--!strict
--[=[
	Locate benchmark (ticket 17): how the snap step finds candidate triangles near a point.
	- `scan`: every tile's bounds, then the triangles of overlapping tiles (Snap as shipped).
	- `tilehash`: tiles are origin-aligned per floor, so the overlapping tiles are one lookup
	  each in a (floor, i, j) hash.
	- `ltdg`: lib/loosetightdoublegrid over triangle bounding boxes, queried with the snap box.
	- `quadtree`: lib/quadtree over triangle centres, queried with a radius covering the box
	  plus the largest centre-to-vertex distance.
	Every variant runs the same per-candidate test and must pick the same triangle per query.
	Lune, os.clock; single runs, indicative.

	lune run tools/navmesh/bench/locate_probe.luau
]=]

local NavMesh = require("../../../lib/navmesh/src/NavMesh")
local Snap = require("../../../lib/navmesh/src/Snap")
local Storage = require("../../../lib/navmesh/src/Storage")
local LTDG = require("../../../lib/loosetightdoublegrid/src/ltdg")
local LtdgVector2 = require("../../../lib/loosetightdoublegrid/src/Shims/Vector2")
local Scenes = require("./Scenes")

local QUERIES = 2000
local EXTENTS = vector.create(0.5, 4, 0.5)

-- The shipped per-candidate test, so every variant scores candidates identically.
local function best(s: any, candidates: { number }, p: vector): number
	local winner, off = 0, math.huge
	for _, t in candidates do
		local q = Snap.ClosestOnTriangle(s, t, p)
		if
			math.abs(q.X - p.X) <= EXTENTS.X
			and math.abs(q.Z - p.Z) <= EXTENTS.Z
			and math.abs(q.Y - p.Y) <= EXTENTS.Y
		then
			local d = (q.X - p.X) ^ 2 + (q.Z - p.Z) ^ 2
			if d < off or (d == off and t < winner) then
				winner, off = t, d
			end
		end
	end
	return winner
end

local function probe(name: string, desc: any)
	local s = NavMesh.Build(desc)
	local n = Storage.TriangleCount(s)
	local x0, z0, x1, z1 = Storage.GetTileBounds(s, 1)
	local minX, minZ, maxX, maxZ = x0, z0, x1, z1
	for tile = 2, Storage.TileCount(s) do
		local a, b, c, d = Storage.GetTileBounds(s, tile)
		minX, minZ, maxX, maxZ = math.min(minX, a), math.min(minZ, b), math.max(maxX, c), math.max(maxZ, d)
	end
	local seed = 99
	local function rng(): number
		seed = (seed * 1103515245 + 12345) % 2147483648
		return seed / 2147483648
	end
	local points = {}
	for i = 1, QUERIES do
		points[i] = vector.create(minX + rng() * (maxX - minX), 0, minZ + rng() * (maxZ - minZ))
	end

	local results: { [string]: { number } } = {}
	local timings = {}
	local function run(variant: string, build: () -> (vector) -> { number })
		local t0 = os.clock()
		local candidatesOf = build()
		local built = os.clock() - t0
		t0 = os.clock()
		local picks = table.create(QUERIES)
		for i, p in points do
			picks[i] = best(s, candidatesOf(p), p)
		end
		results[variant] = picks
		table.insert(
			timings,
			string.format("%s build %.1f ms, %.1f us/query", variant, built * 1000, (os.clock() - t0) * 1e6 / QUERIES)
		)
	end

	run("scan", function()
		return function(p: vector): { number }
			local out = {}
			for tile = 1, Storage.TileCount(s) do
				local a, b, c, d = Storage.GetTileBounds(s, tile)
				if not (c < p.X - EXTENTS.X or a > p.X + EXTENTS.X or d < p.Z - EXTENTS.Z or b > p.Z + EXTENTS.Z) then
					local first, count = Storage.GetTileRange(s, tile)
					for t = first, first + count - 1 do
						table.insert(out, t)
					end
				end
			end
			return out
		end
	end)

	run("tilehash", function()
		local size = x1 - x0 -- one floor here, so one tile size
		local byCell: { [number]: number } = {}
		for tile = 1, Storage.TileCount(s) do
			local a, b = Storage.GetTileBounds(s, tile)
			byCell[math.round(a / size) * 65536 + math.round(b / size)] = tile
		end
		return function(p: vector): { number }
			local out = {}
			for i = math.floor((p.X - EXTENTS.X) / size), math.floor((p.X + EXTENTS.X) / size) do
				for j = math.floor((p.Z - EXTENTS.Z) / size), math.floor((p.Z + EXTENTS.Z) / size) do
					local tile = byCell[i * 65536 + j]
					if tile then
						local first, count = Storage.GetTileRange(s, tile)
						for t = first, first + count - 1 do
							table.insert(out, t)
						end
					end
				end
			end
			return out
		end
	end)

	run("tilehash+box", function()
		local size = x1 - x0
		local byCell: { [number]: number } = {}
		for tile = 1, Storage.TileCount(s) do
			local a, b = Storage.GetTileBounds(s, tile)
			byCell[math.round(a / size) * 65536 + math.round(b / size)] = tile
		end
		return function(p: vector): { number }
			local out = {}
			local lx, hx, lz, hz = p.X - EXTENTS.X, p.X + EXTENTS.X, p.Z - EXTENTS.Z, p.Z + EXTENTS.Z
			for i = math.floor(lx / size), math.floor(hx / size) do
				for j = math.floor(lz / size), math.floor(hz / size) do
					local tile = byCell[i * 65536 + j]
					if tile then
						local first, count = Storage.GetTileRange(s, tile)
						for t = first, first + count - 1 do
							-- Reject by the triangle's box before the exact closest-point test.
							local a, b, c = Storage.GetTriangle(s, t)
							local pa, pb, pc = Storage.GetVertex(s, a), Storage.GetVertex(s, b), Storage.GetVertex(s, c)
							if
								math.max(pa.X, pb.X, pc.X) >= lx
								and math.min(pa.X, pb.X, pc.X) <= hx
								and math.max(pa.Z, pb.Z, pc.Z) >= lz
								and math.min(pa.Z, pb.Z, pc.Z) <= hz
							then
								table.insert(out, t)
							end
						end
					end
				end
			end
			return out
		end
	end)

	run("ltdg", function()
		local cell = math.max(1, (x1 - x0) / 4)
		local width = math.ceil((maxX - minX) / cell) + 2
		local height = math.ceil((maxZ - minZ) / cell) + 2
		local grid = LTDG.new {
			Position = LtdgVector2.new((minX + maxX) / 2, (minZ + maxZ) / 2),
			Size = LtdgVector2.new(width, height),
			CellSize = cell,
		}
		local triOf: { [number]: number } = {}
		for t = 1, n do
			local a, b, c = Storage.GetTriangle(s, t)
			local pa, pb, pc = Storage.GetVertex(s, a), Storage.GetVertex(s, b), Storage.GetVertex(s, c)
			local lx, hx = math.min(pa.X, pb.X, pc.X), math.max(pa.X, pb.X, pc.X)
			local lz, hz = math.min(pa.Z, pb.Z, pc.Z), math.max(pa.Z, pb.Z, pc.Z)
			local id = grid:InsertRect(LtdgVector2.new((lx + hx) / 2, (lz + hz) / 2), LtdgVector2.new(hx - lx, hz - lz))
			triOf[id] = t
		end
		return function(p: vector): { number }
			local out = {}
			for _, id in grid:QueryRect(LtdgVector2.new(p.X, p.Z), LtdgVector2.new(2 * EXTENTS.X, 2 * EXTENTS.Z)) do
				table.insert(out, triOf[id])
			end
			return out
		end
	end)

	local ok, Quadtree = pcall(require, "../../../lib/quadtree/src/quadtree")
	if ok then
		run("quadtree", function()
			local QVector2 = require("../../../test/RobloxClassShims/Vector2")
			local tree = (Quadtree :: any).new(math.max(maxX - minX, maxZ - minZ) * 2)
			local reach = 0
			for t = 1, n do
				local a, b, c = Storage.GetTriangle(s, t)
				local pa, pb, pc = Storage.GetVertex(s, a), Storage.GetVertex(s, b), Storage.GetVertex(s, c)
				local centre = (pa + pb + pc) / 3
				reach = math.max(
					reach,
					vector.magnitude(pa - centre),
					vector.magnitude(pb - centre),
					vector.magnitude(pc - centre)
				)
				tree:CreateNode(QVector2.new(centre.X - (minX + maxX) / 2, centre.Z - (minZ + maxZ) / 2), t)
			end
			local radius = reach + math.sqrt(EXTENTS.X ^ 2 + EXTENTS.Z ^ 2)
			return function(p: vector): { number }
				local out = {}
				for node in tree:ForEachInRadius(QVector2.new(p.X - (minX + maxX) / 2, p.Z - (minZ + maxZ) / 2), radius) do
					table.insert(out, node.Object)
				end
				return out
			end
		end)
	else
		table.insert(timings, "quadtree unavailable: " .. tostring(Quadtree))
	end

	local mismatches = 0
	for variant, picks in results do
		for i = 1, QUERIES do
			if picks[i] ~= results.scan[i] then
				mismatches += 1
				if mismatches <= 2 then
					print("  MISMATCH", variant, i)
				end
			end
		end
	end
	print(
		string.format(
			"%-9s %5d tris %4d tiles | %s | mismatches %d",
			name,
			n,
			Storage.TileCount(s),
			table.concat(timings, " | "),
			mismatches
		)
	)
end

for _, scene in Scenes do
	probe(scene.Name, scene.Make())
end
local open = {
	TileSize = 16,
	Floors = {
		Ground = {
			Walkable = {
				{
					vector.create(0, 0, 0),
					vector.create(512, 0, 0),
					vector.create(512, 0, 512),
					vector.create(0, 0, 512),
				},
			},
		},
	},
}
probe("open16", open)
