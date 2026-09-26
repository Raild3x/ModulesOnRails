--!strict
--[=[
	A/B experiment: does the best snap-rounding grid cell depend on the scene? Fixed cell sizes
	are swept over contrasting scenes, against a density rule that picks the cell from the input
	itself:
		cell = nextPow2(K * sqrt(boundsArea / segmentCount)), clamped to [64, 32768] grid units,
	for K = 1, 2 and 4.
	Scenes (TileSize 32 unless noted):
	- `props`: a 64-stud room packed with small props (0.3-2 studs, one per 8 square studs);
	- `bench`: the TileSize benchmark map (256 studs, 2-8 stud boxes, one per 100 square studs);
	- `terrain`: 1024 studs of sparse large rocks (15-60 studs, one per 4000 square studs),
	  TileSize 128;
	- `walls`: 256 studs of long thin wall segments (20-120 studs x 0.5), a maze-like layout.
	Every variant must reproduce `base` exactly; the best cell per scene is the answer.
]=]

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

local function scene(size: number, count: number, seed: number, shape: (rng: (number, number) -> number) -> { vector }): any
	local rng = makeRng(seed)
	local obstacles = {}
	for _ = 1, count do
		table.insert(obstacles, shape(rng))
	end
	local walkable = {
		{ vector.create(0, 0, 0), vector.create(size, 0, 0), vector.create(size, 0, size), vector.create(0, 0, size) },
	}
	return { Floors = { Ground = { Walkable = { walkable[1] }, Obstacles = obstacles } } }
end

return function(env: any)
	local scenes = {
		{
			"props",
			32,
			scene(64, 512, 3, function(rng)
				return box(rng(0, 64), rng(0, 64), rng(0.3, 2), rng(0.3, 2), rng(0, math.pi))
			end),
		},
		{ "bench", 32, env.TileSize.Map(256, 7) },
		{
			"terrain",
			128,
			scene(1024, 262, 5, function(rng)
				return box(rng(0, 1024), rng(0, 1024), rng(15, 60), rng(15, 60), rng(0, math.pi))
			end),
		},
		{
			"walls",
			32,
			scene(256, 160, 9, function(rng)
				local horizontal = rng(0, 1) < 0.5
				local length = rng(20, 120)
				return box(rng(0, 256), rng(0, 256), if horizontal then length else 0.5, if horizontal then 0.5 else length, 0)
			end),
		},
	}

	local captured
	local original = env.Quantize.SnapRound
	env.Quantize.SnapRound = function(coords, edges)
		captured = { coords, edges }
		return original(coords, edges)
	end
	local workloads = {}
	for _, s in scenes do
		local desc = s[3]
		desc.TileSize = s[2]
		env.NavMesh.Build(desc)
		table.insert(workloads, { Name = s[1], Input = captured, Reps = 3 })
		env.Yield()
	end
	env.Quantize.SnapRound = original

	local Orient2D = env.CDT.Orient2D
	local make = env.Variants.SnapRound
	local cache: { [number]: any } = {}
	local function withCell(cell: number): any
		if cache[cell] == nil then
			cache[cell] = make(Orient2D, { Cell = cell, Crossings = "grid" })
		end
		return cache[cell]
	end
	-- The density rule: cell from the input's bounds and segment count.
	local function densityCell(coords: { number }, edges: { number }, k: number): number
		local x0, z0, x1, z1 = math.huge, math.huge, -math.huge, -math.huge
		for i = 1, #coords, 2 do
			x0, x1 = math.min(x0, coords[i]), math.max(x1, coords[i])
			z0, z1 = math.min(z0, coords[i + 1]), math.max(z1, coords[i + 1])
		end
		local spacing = math.sqrt(math.max(1, (x1 - x0) * (z1 - z0)) / math.max(1, #edges // 2))
		return math.clamp(2 ^ math.ceil(math.log(k * spacing, 2)), 64, 32768)
	end
	for _, w in workloads do
		local input = w.Input
		print(string.format("[INFO] %s: %d segments, density cell K=1 %d, K=2 %d, K=4 %d", w.Name, #input[2] // 2,
			densityCell(input[1], input[2], 1), densityCell(input[1], input[2], 2), densityCell(input[1], input[2], 4)))
	end

	local variants = {
		{
			Name = "base",
			Run = function(input)
				return table.pack(original(input[1], input[2]))
			end,
		},
	}
	for _, cell in { 256, 512, 1024, 2048, 4096, 8192, 16384 } do
		table.insert(variants, {
			Name = `cell{cell}`,
			Run = function(input)
				return table.pack(withCell(cell)(input[1], input[2]))
			end,
		})
	end
	for _, k in { 1, 2, 4 } do
		table.insert(variants, {
			Name = `densityK{k}`,
			Run = function(input)
				return table.pack(withCell(densityCell(input[1], input[2], k))(input[1], input[2]))
			end,
		})
	end
	env.AB({
		Variants = variants,
		Workloads = workloads,
		Fingerprint = function(out: any): string
			local parts = {}
			for k = 1, 3 do
				local h = 0
				for i, v in out[k] do
					h = (h * 31 + v * 7 + i) % 1000000007
				end
				parts[k] = `{#out[k]}:{h}`
			end
			return table.concat(parts, "/")
		end,
		Rounds = env.Rounds,
		Clock = env.Clock,
		Yield = env.Yield,
		Deadline = env.Deadline,
	})
end
