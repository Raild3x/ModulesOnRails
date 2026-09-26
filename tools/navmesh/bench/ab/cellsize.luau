--!strict
--[=[
	A/B experiment: does the best snap-rounding grid cell depend on the scene? Fixed cell sizes
	are swept over contrasting scenes, against a density rule that picks the cell from the input
	itself:
		cell = nextPow2(K * sqrt(boundsArea / segmentCount)), clamped to [64, 32768] grid units,
	for K = 1, 2 and 4.
	Scenes: every scene in Scenes.luau, at its `SnapTile` tile size.
	Every variant must reproduce `base` exactly; the best cell per scene is the answer.
]=]

return function(env: any)
	local captured
	local original = env.Quantize.SnapRound
	env.Quantize.SnapRound = function(coords, edges)
		captured = { coords, edges }
		return original(coords, edges)
	end
	local workloads = {}
	for _, scene in env.Scenes do
		local desc = scene.Make()
		desc.TileSize = scene.SnapTile
		env.NavMesh.Build(desc)
		table.insert(workloads, { Name = scene.Name, Input = captured, Reps = 3 })
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
		print(
			string.format(
				"[INFO] %s: %d segments, density cell K=1 %d, K=2 %d, K=4 %d",
				w.Name,
				#input[2] // 2,
				densityCell(input[1], input[2], 1),
				densityCell(input[1], input[2], 2),
				densityCell(input[1], input[2], 4)
			)
		)
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
	env.AB {
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
	}
end
