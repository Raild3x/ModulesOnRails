--!strict
--[=[
	A/B experiment: snap rounding's two linear scans (profile: 70% of Build).
	- **Workloads:** the real `SnapRound` inputs captured from `NavMesh.Build` of the benchmark
	  map at 128, 256 and 512 studs (TileSize 32), plus one 32-stud tile. The tile is the unit
	  an `Update` re-snaps if snapping goes local.
	- **Variants:**
	  - `base`: the shipped function;
	  - `grid256` to `grid4096`: crossings and hot pixels in grid buckets of that many
	    grid units (1 to 16 studs);
	  - `sweep+grid1024`, `sweep+grid2048`: crossings from an x sweep instead.
	Every variant must reproduce `base` exactly.
]=]

return function(env: any)
	local captured: { any } = {}
	local original = env.Quantize.SnapRound
	env.Quantize.SnapRound = function(coords, edges)
		table.insert(captured, { coords, edges })
		return original(coords, edges)
	end
	local workloads = {}
	for _, size in { 128, 256, 512 } do
		local desc = env.TileSize.Map(size, 7)
		desc.TileSize = 32
		env.NavMesh.Build(desc)
		table.insert(
			workloads,
			{ Name = `map{size}`, Input = captured[#captured], Reps = if size >= 512 then 1 else 3 }
		)
		env.Yield()
	end
	env.NavMesh.Build(env.TileSize.Crop(env.TileSize.Map(256, 7), 96, 96, 32))
	table.insert(workloads, 1, { Name = "tile32", Input = captured[#captured], Reps = 5 })
	env.Quantize.SnapRound = original

	local Orient2D = env.CDT.Orient2D
	local make = env.Variants.SnapRound
	local function variant(name: string, fn: any)
		return {
			Name = name,
			Run = function(input)
				return table.pack(fn(input[1], input[2]))
			end,
		}
	end
	env.AB {
		Variants = {
			variant("base", original),
			variant("grid256", make(Orient2D, { Cell = 256, Crossings = "grid" })),
			variant("grid1024", make(Orient2D, { Cell = 1024, Crossings = "grid" })),
			variant("grid2048", make(Orient2D, { Cell = 2048, Crossings = "grid" })),
			variant("grid4096", make(Orient2D, { Cell = 4096, Crossings = "grid" })),
			variant("sweep+grid1024", make(Orient2D, { Cell = 1024, Crossings = "sweep" })),
			variant("sweep+grid2048", make(Orient2D, { Cell = 2048, Crossings = "sweep" })),
		},
		Workloads = workloads,
		Fingerprint = function(out: any): string
			-- Exact, order-sensitive checksum of coords, edges and sources.
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
