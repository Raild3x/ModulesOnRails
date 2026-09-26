--!strict
--[=[
	A/B experiment for ticket 14 (FindPath): the A* open list over the four scenes. Spec SR11
	keeps `lib/heap` as a benchmark candidate. Candidates and the shared A* are in
	OpenLists.luau.
	- **Graph:** each scene is built at its balanced TileSize and flattened.
	- **Workload:** 200 seeded random start/goal pairs per scene.
	Every candidate must find the same optimal costs, rounded to 1e-6.
]=]

local BALANCED = { props = 8, bench = 32, terrain = 256, walls = 64 }
local QUERIES = 200

return function(env: any)
	local OpenLists = env.OpenLists
	local workloads = {}
	for _, scene in env.Scenes do
		local desc = scene.Make()
		desc.TileSize = BALANCED[scene.Name]
		local graph = OpenLists.Flatten(env.NavMeshStorage, env.NavMesh.Build(desc))
		local state = 12345
		local ends = table.create(2 * QUERIES)
		for i = 1, 2 * QUERIES do
			state = (state * 1103515245 + 12345) % 2147483648
			ends[i] = 1 + math.floor(state / 2147483648 * graph.N)
		end
		table.insert(workloads, { Name = scene.Name, Input = { Graph = graph, Ends = ends }, Reps = 3 })
		env.Yield()
	end

	local variants = {}
	for _, candidate in OpenLists.Candidates do
		local searches: { [any]: (number, number) -> number } = {}
		table.insert(variants, {
			Name = candidate.Name,
			Run = function(input: any)
				local search = searches[input.Graph]
				if search == nil then
					search = OpenLists.MakeSearch(input.Graph, candidate.Make(input.Graph, env.Heap))
					searches[input.Graph] = search
				end
				local costs = table.create(#input.Ends // 2)
				for q = 1, #input.Ends // 2 do
					costs[q] = search(input.Ends[2 * q - 1], input.Ends[2 * q])
				end
				return costs
			end,
		})
	end
	env.AB({
		Variants = variants,
		Workloads = workloads,
		Fingerprint = function(costs: { number }): string
			local parts = {}
			for _, c in costs do
				table.insert(parts, if c == math.huge then "x" else string.format("%.6f", c))
			end
			return table.concat(parts, ",")
		end,
		Rounds = env.Rounds,
		Clock = env.Clock,
		Yield = env.Yield,
		Deadline = env.Deadline,
	})
end
