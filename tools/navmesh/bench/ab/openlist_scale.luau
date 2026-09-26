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
		-- Queries run corner to corner inside the largest connected component (a corner triangle
		-- can sit in a pocket sealed off by obstacles): the QUERIES triangles nearest (0, 0) to
		-- those nearest (side, side), paired in order.
		local component, best = table.create(graph.N, 0), 0
		local sizes = {}
		for seed = 1, graph.N do
			if component[seed] == 0 then
				local id = #sizes + 1
				local stack, count = { seed }, 0
				component[seed] = id
				while #stack > 0 do
					local t = table.remove(stack) :: number
					count += 1
					for e = 1, 3 do
						local m = graph.Nbr[3 * (t - 1) + e]
						if m ~= 0 and component[m] == 0 then
							component[m] = id
							table.insert(stack, m)
						end
					end
				end
				sizes[id] = count
				if count > (sizes[best] or 0) then
					best = id
				end
			end
		end
		local members = {}
		for t = 1, graph.N do
			if component[t] == best then
				table.insert(members, t)
			end
		end
		local function nearest(cx: number, cz: number): { number }
			local sorted = table.clone(members)
			table.sort(sorted, function(a: number, b: number): boolean
				local da = (graph.X[a] - cx) ^ 2 + (graph.Z[a] - cz) ^ 2
				local db = (graph.X[b] - cx) ^ 2 + (graph.Z[b] - cz) ^ 2
				return da < db or (da == db and a < b)
			end)
			return sorted
		end
		local low, high = nearest(0, 0), nearest(side, side)
		local ends = table.create(2 * QUERIES)
		for q = 1, QUERIES do
			ends[2 * q - 1], ends[2 * q] = low[q], high[q]
		end
		-- The chart's x axis: open-list size and pops per query (through `binary`).
		local open, stats = OpenLists.Counted(OpenLists.Candidates[3].Make(graph, env.Heap))
		local search = OpenLists.MakeSearch(graph, open)
		local peaks, pops = {}, {}
		for q = 1, QUERIES do
			search(ends[2 * q - 1], ends[2 * q])
			table.insert(peaks, stats.Peak)
			table.insert(pops, stats.Pops)
		end
		print(
			string.format(
				"[SCALE] side%d | %d | %d | %d",
				side,
				graph.N,
				median(peaks),
				median(pops)
			)
		)
		table.insert(workloads, { Name = `side{side}`, Input = { Graph = graph, Ends = ends }, Reps = if side >= 512 then 1 else 3 })
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
				local costs = table.create(QUERIES)
				for q = 1, QUERIES do
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
