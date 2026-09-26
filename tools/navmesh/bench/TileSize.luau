--!strict
-- TileSize benchmark core (ticket 13), shared by the Studio run (tilesize.py) and a quick Lune
-- gauge. For each candidate tile size it measures, on a uniform-density map:
--   build   full-map NavMesh.Build, ms (median over interleaved rounds)
--   tris / verts / tiles   the mesh size, i.e. the tile-border overhead
--   tile    one-tile rebuild proxy: Build of one S x S patch of the same density with
--           TileSize S, ms. That is the unit of work Update will redo per dirty tile.
-- Prints [R] lines that tilesize.py aggregates; every loop checks the deadline.

type Options =
	{ NavMesh: any, Clock: () -> number, Sizes: { number }, MapSize: number, Rounds: number, Deadline: number }

-- Deterministic LCG, high bits.
local function makeRng(seed: number): (number, number) -> number
	local state = seed
	return function(lo: number, hi: number): number
		state = (state * 1103515245 + 12345) % 2147483648
		return lo + (state / 2147483648) * (hi - lo)
	end
end

-- A walkable square of side `size` at the origin, with random rotated box obstacles at a fixed
-- density (one per 100 square studs, 2-8 studs across), and one area patch per 1024 square studs.
local function map(size: number, seed: number): any
	local rng = makeRng(seed)
	local obstacles, areas = {}, {}
	local function box(cx: number, cz: number, w: number, d: number, angle: number): { vector }
		local c, s = math.cos(angle), math.sin(angle)
		local ring = {}
		for _, corner in { { -1, -1 }, { 1, -1 }, { 1, 1 }, { -1, 1 } } do
			local x, z = corner[1] * w / 2, corner[2] * d / 2
			table.insert(ring, vector.create(cx + x * c - z * s, 0, cz + x * s + z * c))
		end
		return ring
	end
	for _ = 1, math.floor(size * size / 100) do
		table.insert(obstacles, box(rng(0, size), rng(0, size), rng(2, 8), rng(2, 8), rng(0, math.pi)))
	end
	for _ = 1, math.max(1, math.floor(size * size / 1024)) do
		table.insert(
			areas,
			{ Polygon = box(rng(0, size), rng(0, size), rng(4, 16), rng(4, 16), rng(0, math.pi)), Area = 2 }
		)
	end
	local walkable = {
		{ vector.create(0, 0, 0), vector.create(size, 0, 0), vector.create(size, 0, size), vector.create(0, 0, size) },
	}
	return { Floors = { Ground = { Walkable = walkable, Obstacles = obstacles, Areas = areas } } }
end

-- One tile of the full map: the walkable square [x0, x0 + size] (a whole tile, since tiles
-- are origin-aligned) with every obstacle and area centred inside it.
local function crop(full: any, x0: number, z0: number, size: number): any
	local floor = full.Floors.Ground
	local function centredIn(ring: { vector }): boolean
		local cx, cz = 0, 0
		for _, p in ring do
			cx += p.X / #ring
			cz += p.Z / #ring
		end
		return cx >= x0 and cx < x0 + size and cz >= z0 and cz < z0 + size
	end
	local obstacles, areas = {}, {}
	for _, ring in floor.Obstacles do
		if centredIn(ring) then
			table.insert(obstacles, ring)
		end
	end
	for _, area in floor.Areas do
		if centredIn(area.Polygon) then
			table.insert(areas, area)
		end
	end
	local walkable = {
		{
			vector.create(x0, 0, z0),
			vector.create(x0 + size, 0, z0),
			vector.create(x0 + size, 0, z0 + size),
			vector.create(x0, 0, z0 + size),
		},
	}
	return { TileSize = size, Floors = { Ground = { Walkable = walkable, Obstacles = obstacles, Areas = areas } } }
end

local function median(xs: { number }): number
	local s = table.clone(xs)
	table.sort(s)
	return s[(#s + 1) // 2]
end

local function run(o: Options)
	local NavMesh, clock = o.NavMesh, o.Clock
	local full = map(o.MapSize, 7)
	local buildMs, tileMs, shape = {}, {}, {}
	for _, size in o.Sizes do
		buildMs[size], tileMs[size] = {}, {}
	end
	print(`[MARK] map {o.MapSize} studs, {#full.Floors.Ground.Obstacles} obstacles`)
	for round = 1, o.Rounds do
		for k = 0, #o.Sizes - 1 do
			if clock() > o.Deadline then
				print("[MARK] deadline hit")
				return
			end
			local size = o.Sizes[(round + k - 1) % #o.Sizes + 1] -- rotated order
			local desc = table.clone(full)
			desc.TileSize = size
			local t0 = clock()
			local mesh = NavMesh.Build(desc)
			table.insert(buildMs[size], (clock() - t0) * 1000)
			local storage = mesh :: any
			shape[size] = { storage.TriangleCount, storage.VertexCount, #storage.TileFloor }

			-- Every tile of the map in turn (bounded), so the median covers dense and sparse ones.
			local perSide = math.max(1, o.MapSize // size)
			local samples = math.min(perSide * perSide, 16)
			for i = 0, samples - 1 do
				local cell = (i * 7 + round) % (perSide * perSide)
				local patch = crop(full, (cell % perSide) * size, (cell // perSide) * size, size)
				t0 = clock()
				NavMesh.Build(patch)
				table.insert(tileMs[size], (clock() - t0) * 1000)
			end
		end
		print(`[MARK] round {round}`)
	end
	print("[HDR] size | build_ms | tris | verts | tiles | tile_ms")
	for _, size in o.Sizes do
		local sh = shape[size]
		print(
			string.format(
				"[R] %d | %.1f | %d | %d | %d | %.2f",
				size,
				median(buildMs[size]),
				sh[1],
				sh[2],
				sh[3],
				median(tileMs[size])
			)
		)
	end
	print("[MARK] done")
end

return { Run = run, Map = map }
