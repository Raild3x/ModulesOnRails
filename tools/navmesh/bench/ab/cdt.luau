--!strict
--[=[
	A/B experiment: the cost of the CDT's module-boundary calls (profile: `Triangulate` is 24% of
	Build, and its hot loops read Storage through accessor functions).
	- **Workloads:**
	  - `tiles256`, `tiles512`: every real `CDT.Triangulate` input from `NavMesh.Build` of the
	    benchmark map at 256 and 512 studs (TileSize 32), run in sequence;
	  - `floor256`: the same map as one 1024-stud tile, a single large triangulation.
	- **Variants:**
	  - `base`: the shipped CDT (since the landing, with local accessor copies);
	  - `pre`: the CDT as it was before the landing (variants/CDTPre, from git), for the
	    before/after confirmation;
	  - `local`: the Storage accessors copied as local functions in Triangulator and Classify,
	    so the compiler can inline them (variants/CDTLocal);
	  - `local+pred`: `local`, plus the predicates' floating-point filters as local functions
	    (variants/CDTLocalPred);
	  - `inline`: `local+pred`, with the walk and legalize loops reading the buffers by hand
	    (variants/CDTInline).
	Every variant must reproduce `base`'s triangles, neighbours and windings exactly.
]=]

return function(env: any)
	local captured: { any } = {}
	local original = env.CDT.Triangulate
	env.CDT.Triangulate = function(input)
		table.insert(captured, input)
		return original(input)
	end
	local workloads = {}
	for _, case in { { "tiles256", 256, 32 }, { "tiles512", 512, 32 }, { "floor256", 256, 1024 } } do
		table.clear(captured)
		local desc = env.TileSize.Map(case[2], 7)
		desc.TileSize = case[3]
		env.NavMesh.Build(desc)
		local inputs = table.clone(captured)
		if case[1] == "floor256" then
			-- The per-ring surface triangulations come first; keep only the floor's one tile.
			inputs = { inputs[#inputs] }
		end
		table.insert(workloads, { Name = case[1], Input = inputs, Reps = 3 })
		env.Yield()
	end
	env.CDT.Triangulate = original

	local function variant(name: string, module: any)
		return {
			Name = name,
			Run = function(inputs: { any })
				local results = table.create(#inputs)
				for i, input in inputs do
					results[i] = module.Triangulate(input)
				end
				return { module, results }
			end,
		}
	end
	env.AB {
		Variants = {
			variant("base", env.CDT),
			variant("pre", env.Variants.CDTPre),
			variant("local", env.Variants.CDTLocal),
			variant("local+pred", env.Variants.CDTLocalPred),
			variant("inline", env.Variants.CDTInline),
		},
		Workloads = workloads,
		Fingerprint = function(out: any): string
			local module, results = out[1], out[2]
			local h, triangles = 0, 0
			for _, tri in results do
				for t = 1, module.TriangleCount(tri) do
					local a, b, c = module.GetTriangle(tri, t)
					h = (h * 31 + a * 7 + b * 11 + c * 13) % 1000000007
					for e = 1, 3 do
						h = (h * 31 + module.GetNeighbor(tri, t, e)) % 1000000007
					end
					for g = 0, module.GroupCount(tri) do
						h = (h * 31 + module.GetWinding(tri, t, g) + 7) % 1000000007
					end
				end
				triangles += module.TriangleCount(tri)
			end
			return `{#results}:{triangles}:{h}`
		end,
		Rounds = env.Rounds,
		Clock = env.Clock,
		Yield = env.Yield,
		Deadline = env.Deadline,
	}
end
