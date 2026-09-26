--!strict
--[=[
	A/B experiment: how each A* open list scales as the open list grows. Candidates and the
	shared A* are in OpenLists.luau.
	- **Workloads:** bench-density floors (TileSize.Map: 2-8 stud boxes, one per 100 square
	  studs) of 64 to 1024 studs, at TileSize 32. Each gets 12 long queries, corner to corner
	  inside the largest connected component, so the open list grows
	  with the floor.
	- **Measured:** each candidate's time for the 12 queries. `[SCALE]` lines give each floor's
	  triangle count and the median per query of the peak open-list size (stale entries
	  included) and the pops, measured through `binary`. That is the x axis for the chart.
	Every candidate must find the same optimal costs, rounded to 1e-6.
]=]

local SIDES = { 64, 128, 256, 512, 1024 }
local QUERIES = 12

local function median(xs: { number }): number
	local s = table.clone(xs)
	table.sort(s)
	return s[(#s + 1) // 2]
end

return function(env: any)
	local OpenLists = env.OpenLists
	local workloads = {}
	for _, side in SIDES do
		local desc = env.TileSize.Map(side, 7)
		desc.TileSize = 32
		local graph = OpenLists.Flatten(env.NavMeshStorage, env.NavMesh.Build(desc))
		local ends = OpenLists.CornerQueries(graph, side, QUERIES)
		-- The chart's x axis: open-list size and pops per query (through `binary`).
		local open, stats = OpenLists.Counted(OpenLists.Binary())
		local search = OpenLists.MakeSearch(graph, open)
		local peaks, pops = {}, {}
		for q = 1, QUERIES do
			search(ends[2 * q - 1], ends[2 * q])
			table.insert(peaks, stats.Peak)
			table.insert(pops, stats.Pops)
		end
		print(string.format("[SCALE] side%d | %d | %d | %d", side, graph.N, median(peaks), median(pops)))
		table.insert(
			workloads,
			{ Name = `side{side}`, Input = { Graph = graph, Ends = ends }, Reps = if side >= 512 then 1 else 3 }
		)
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
					search = candidate.Search(input.Graph, env)
					searches[input.Graph] = search
				end
				local costs = table.create(QUERIES)
				for q = 1, QUERIES do
					costs[q] = search(input.Ends[2 * q - 1], input.Ends[2 * q])
				end
				return costs
			end,
		})
	end
	env.AB {
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
	}
end
