--!strict
--[=[
	A/B experiment for ticket 14 (FindPath): how the search reads the mesh. Every variant uses
	the shipped OpenList (4-ary) directly and the same A*; only the graph access differs.
	- `flat`: a cached flat copy of the whole graph (neighbour table plus centroid tables). This
	  is the upper bound, at extra memory, and must be rebuilt when `Update` changes the mesh.
	- `storage`: reads NavMesh Storage through its accessors every time: `GetNeighbor`, and the
	  centroid from `GetTriangle` plus 3 `GetVertex` calls. No cache.
	- `storage+centroids`: `GetNeighbor` calls, with centroids from a per-mesh cache.
	- `buffer+centroids`: neighbours read straight from Storage's i32 buffer (a tagged inlined
	  copy, as the CDT does), with centroids from a per-mesh cache;
	- `buffer+vectors`: the same, with the centroid cache as one {vector} array (f32 components,
	  vector-library distances), the shape a centroid held in Storage would take.
	**Workloads:** the `openlist_scale` floors (64-1024 studs, 12 corner-to-corner queries each).
	Every f64 variant must find the same optimal costs, rounded to 1e-6. `buffer+vectors` is a
	different precision class (f32 centroids and f32 vector math), so its DIFFERENT check is
	expected: measured against f64, its path costs differ by at most 3.4e-4 studs (1.7e-7
	relative) on these floors, which is rounding, not a different route.
]=]

local SIDES = { 64, 128, 256, 512, 1024 }
local QUERIES = 12

return function(env: any)
	local OpenLists, Storage, OL = env.OpenLists, env.NavMeshStorage, env.NavMeshOpenList
	local push, pop = OL.Push, OL.Pop

	-- Centroid cache for a mesh: flat X/Y/Z arrays (the part of `flat` a search can't avoid).
	local function centroids(mesh: any): ({ number }, { number }, { number })
		local n = Storage.TriangleCount(mesh)
		local xs, ys, zs = table.create(n), table.create(n), table.create(n)
		for t = 1, n do
			local a, b, c = Storage.GetTriangle(mesh, t)
			local pa, pb, pc = Storage.GetVertex(mesh, a), Storage.GetVertex(mesh, b), Storage.GetVertex(mesh, c)
			xs[t], ys[t], zs[t] = (pa.X + pb.X + pc.X) / 3, (pa.Y + pb.Y + pc.Y) / 3, (pa.Z + pb.Z + pc.Z) / 3
		end
		return xs, ys, zs
	end

	-- storage: no cache at all.
	local function storageSearch(mesh: any): (number, number) -> number
		local n = Storage.TriangleCount(mesh)
		local g, seen, closed = table.create(n, 0), table.create(n, 0), table.create(n, 0)
		local open, stamp = OL.new(), 0
		local GetNeighbor, GetTriangle, GetVertex = Storage.GetNeighbor, Storage.GetTriangle, Storage.GetVertex
		local function centre(t: number): (number, number, number)
			local a, b, c = GetTriangle(mesh, t)
			local pa, pb, pc = GetVertex(mesh, a), GetVertex(mesh, b), GetVertex(mesh, c)
			return (pa.X + pb.X + pc.X) / 3, (pa.Y + pb.Y + pc.Y) / 3, (pa.Z + pb.Z + pc.Z) / 3
		end
		return function(start: number, goal: number): number
			stamp += 1
			OL.Clear(open)
			local gx, gy, gz = centre(goal)
			local sx, sy, sz = centre(start)
			g[start], seen[start] = 0, stamp
			push(open, start, math.sqrt((sx - gx) ^ 2 + (sy - gy) ^ 2 + (sz - gz) ^ 2))
			while true do
				local t = pop(open)
				if t == 0 then
					return math.huge
				end
				if closed[t] == stamp then
					continue
				end
				closed[t] = stamp
				if t == goal then
					return g[t]
				end
				local tx, ty, tz = centre(t)
				local gt = g[t]
				for e = 1, 3 do
					local m = GetNeighbor(mesh, t, e)
					if m ~= 0 and closed[m] ~= stamp then
						local mx, my, mz = centre(m)
						local dx, dy, dz = mx - tx, my - ty, mz - tz
						local ng = gt + math.sqrt(dx * dx + dy * dy + dz * dz)
						if seen[m] ~= stamp or ng < g[m] then
							g[m], seen[m] = ng, stamp
							local hx, hy, hz = mx - gx, my - gy, mz - gz
							push(open, m, ng + math.sqrt(hx * hx + hy * hy + hz * hz))
						end
					end
				end
			end
		end
	end

	-- storage+centroids and buffer+centroids: cached centroids; neighbours by accessor or buffer.
	local function cachedSearch(mesh: any, inlineNeighbors: boolean): (number, number) -> number
		local n = Storage.TriangleCount(mesh)
		local xs, ys, zs = centroids(mesh)
		local g, seen, closed = table.create(n, 0), table.create(n, 0), table.create(n, 0)
		local open, stamp = OL.new(), 0
		local GetNeighbor = Storage.GetNeighbor
		return function(start: number, goal: number): number
			stamp += 1
			OL.Clear(open)
			local nb: buffer = mesh.TriNeighbors -- inlined: Storage.GetNeighbor (i32 x3 per triangle)
			local gx, gy, gz = xs[goal], ys[goal], zs[goal]
			g[start], seen[start] = 0, stamp
			push(open, start, math.sqrt((xs[start] - gx) ^ 2 + (ys[start] - gy) ^ 2 + (zs[start] - gz) ^ 2))
			while true do
				local t = pop(open)
				if t == 0 then
					return math.huge
				end
				if closed[t] == stamp then
					continue
				end
				closed[t] = stamp
				if t == goal then
					return g[t]
				end
				local tx, ty, tz, gt = xs[t], ys[t], zs[t], g[t]
				local base = (t - 1) * 12
				for e = 1, 3 do
					local m = if inlineNeighbors then buffer.readi32(nb, base + (e - 1) * 4) else GetNeighbor(mesh, t, e)
					if m ~= 0 and closed[m] ~= stamp then
						local mx, my, mz = xs[m], ys[m], zs[m]
						local dx, dy, dz = mx - tx, my - ty, mz - tz
						local ng = gt + math.sqrt(dx * dx + dy * dy + dz * dz)
						if seen[m] ~= stamp or ng < g[m] then
							g[m], seen[m] = ng, stamp
							local hx, hy, hz = mx - gx, my - gy, mz - gz
							push(open, m, ng + math.sqrt(hx * hx + hy * hy + hz * hz))
						end
					end
				end
			end
		end
	end

	-- buffer+vectors: neighbours from the buffer, centroids from one cached {vector} array (the
	-- shape a Storage-held centroid would have).
	local function vectorSearch(mesh: any): (number, number) -> number
		local n = Storage.TriangleCount(mesh)
		local xs, ys, zs = centroids(mesh)
		local cs: { vector } = table.create(n)
		for t = 1, n do
			cs[t] = vector.create(xs[t], ys[t], zs[t])
		end
		local g, seen, closed = table.create(n, 0), table.create(n, 0), table.create(n, 0)
		local open, stamp = OL.new(), 0
		return function(start: number, goal: number): number
			stamp += 1
			OL.Clear(open)
			local nb: buffer = mesh.TriNeighbors -- inlined: Storage.GetNeighbor (i32 x3 per triangle)
			local goalC = cs[goal]
			g[start], seen[start] = 0, stamp
			push(open, start, vector.magnitude(cs[start] - goalC))
			while true do
				local t = pop(open)
				if t == 0 then
					return math.huge
				end
				if closed[t] == stamp then
					continue
				end
				closed[t] = stamp
				if t == goal then
					return g[t]
				end
				local tc, gt = cs[t], g[t]
				local base = (t - 1) * 12
				for e = 1, 3 do
					local m = buffer.readi32(nb, base + (e - 1) * 4)
					if m ~= 0 and closed[m] ~= stamp then
						local mc = cs[m]
						local ng = gt + vector.magnitude(mc - tc)
						if seen[m] ~= stamp or ng < g[m] then
							g[m], seen[m] = ng, stamp
							push(open, m, ng + vector.magnitude(mc - goalC))
						end
					end
				end
			end
		end
	end

	local workloads = {}
	for _, side in SIDES do
		local desc = env.TileSize.Map(side, 7)
		desc.TileSize = 32
		local mesh = env.NavMesh.Build(desc)
		local graph = OpenLists.Flatten(Storage, mesh)
		local ends = OpenLists.CornerQueries(graph, side, QUERIES)
		table.insert(workloads, {
			Name = `side{side}`,
			Input = { Mesh = mesh, Graph = graph, Ends = ends },
			Reps = if side >= 512 then 1 else 3,
		})
		env.Yield()
	end

	local function variant(name: string, make: (input: any) -> (number, number) -> number)
		local searches: { [any]: (number, number) -> number } = {}
		return {
			Name = name,
			Run = function(input: any)
				local search = searches[input]
				if search == nil then
					search = make(input)
					searches[input] = search
				end
				local costs = table.create(QUERIES)
				for q = 1, QUERIES do
					costs[q] = search(input.Ends[2 * q - 1], input.Ends[2 * q])
				end
				return costs
			end,
		}
	end
	env.AB({
		Variants = {
			variant("flat", function(input)
				return OpenLists.MakeSearchModule(input.Graph, OL)
			end),
			variant("storage", function(input)
				return storageSearch(input.Mesh)
			end),
			variant("storage+centroids", function(input)
				return cachedSearch(input.Mesh, false)
			end),
			variant("buffer+centroids", function(input)
				return cachedSearch(input.Mesh, true)
			end),
			variant("buffer+vectors", function(input)
				return vectorSearch(input.Mesh)
			end),
		},
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
