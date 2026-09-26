--!strict
--[=[
	Benchmark scenes: contrasting NavMesh workloads, each a flat square floor at the origin
	with deterministic obstacles. Shared by the TileSize benchmark and the A/B experiments.
	- `props`: a 64-stud room packed with small props (0.3-2 studs, one per 8 square studs);
	- `bench`: the original TileSize map (256 studs, 2-8 stud boxes, one per 100 square
	  studs, plus area patches);
	- `terrain`: 1024 studs of sparse large rocks (15-60 studs, one per 4000 square studs);
	- `walls`: 256 studs of long thin maze walls (20-120 studs x 0.5).
	`Sizes` are the tile sizes worth measuring for that scene; `SnapTile` is the tile size the
	snap-rounding experiments used.
]=]

export type Scene = { Name: string, Side: number, Sizes: { number }, SnapTile: number, Make: () -> any }

local function makeRng(seed: number): (number, number) -> number
	local state = seed
	return function(lo: number, hi: number): number
		state = (state * 1103515245 + 12345) % 2147483648
		return lo + (state / 2147483648) * (hi - lo)
	end
end

local function box(cx: number, cz: number, w: number, d: number, angle: number): { vector }
	local c, s = math.cos(angle), math.sin(angle)
	local ring = {}
	for _, corner in { { -1, -1 }, { 1, -1 }, { 1, 1 }, { -1, 1 } } do
		local x, z = corner[1] * w / 2, corner[2] * d / 2
		table.insert(ring, vector.create(cx + x * c - z * s, 0, cz + x * s + z * c))
	end
	return ring
end

local function floor(side: number, obstacles: { { vector } }, areas: { any }?): any
	local walkable = {
		vector.create(0, 0, 0),
		vector.create(side, 0, 0),
		vector.create(side, 0, side),
		vector.create(0, 0, side),
	}
	return { Floors = { Ground = { Walkable = { walkable }, Obstacles = obstacles, Areas = areas } } }
end

local function scatter(
	seed: number,
	count: number,
	shape: (rng: (number, number) -> number) -> { vector }
): { { vector } }
	local rng = makeRng(seed)
	local out = {}
	for _ = 1, count do
		table.insert(out, shape(rng))
	end
	return out
end

local Scenes: { Scene } = {
	{
		Name = "props",
		Side = 64,
		Sizes = { 4, 8, 16, 32, 64 },
		SnapTile = 32,
		Make = function()
			return floor(
				64,
				scatter(3, 512, function(rng)
					return box(rng(0, 64), rng(0, 64), rng(0.3, 2), rng(0.3, 2), rng(0, math.pi))
				end)
			)
		end,
	},
	{
		Name = "bench",
		Side = 256,
		Sizes = { 8, 16, 32, 64, 128 },
		SnapTile = 32,
		Make = function()
			local rng = makeRng(7)
			local obstacles, areas = {}, {}
			for _ = 1, math.floor(256 * 256 / 100) do
				table.insert(obstacles, box(rng(0, 256), rng(0, 256), rng(2, 8), rng(2, 8), rng(0, math.pi)))
			end
			for _ = 1, math.floor(256 * 256 / 1024) do
				table.insert(
					areas,
					{ Polygon = box(rng(0, 256), rng(0, 256), rng(4, 16), rng(4, 16), rng(0, math.pi)), Area = 2 }
				)
			end
			return floor(256, obstacles, areas)
		end,
	},
	{
		Name = "terrain",
		Side = 1024,
		Sizes = { 32, 64, 128, 256 },
		SnapTile = 128,
		Make = function()
			return floor(
				1024,
				scatter(5, 262, function(rng)
					return box(rng(0, 1024), rng(0, 1024), rng(15, 60), rng(15, 60), rng(0, math.pi))
				end)
			)
		end,
	},
	{
		Name = "walls",
		Side = 256,
		Sizes = { 8, 16, 32, 64, 128 },
		SnapTile = 32,
		Make = function()
			return floor(
				256,
				scatter(9, 160, function(rng)
					local horizontal = rng(0, 1) < 0.5
					local length = rng(20, 120)
					return box(
						rng(0, 256),
						rng(0, 256),
						if horizontal then length else 0.5,
						if horizontal then 0.5 else length,
						0
					)
				end)
			)
		end,
	},
}

return Scenes
