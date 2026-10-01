--!strict
--[=[
	Ticket 31 measurement core: everything measured from a bake, shared by the Lune bench
	(large_world.luau, which also times Build) and the Studio run (large_world.py). For one bake
	of a map `side` studs square:
	- `deserialize`: ms per `Deserialize`, `Reps` times;
	- `heap`: KB the loaded mesh adds to the Luau heap (`settledHeap`: neither runtime lets a
	  script force a collection);
	- `coldPath` / `warmPath`: the first `FindPath` (AgentRadius 1) on a fresh load, then the same
	  query after the others, ms; the difference is the wall-index spike (known-gaps.md);
	- `path` / `pathBudget`: ms per `FindPath` across the map (plan distance >= side / 2, seeded
	  pairs), unbounded and with `MaxExpansions = BUDGET`; `budgetHits` counts `Budget` results;
	- `coldUpdate` / `update`: the first `Update` (one 4 x 4 crate added) on a fresh load, then
	  the add and remove of later cycles, ms.
	The pairs and the crate come from math.randomseed, so both runtimes query the same points.
]=]

type Options = {
	NavMesh: any,
	Clock: () -> number,
	Yield: () -> (),
	Reps: number,
	Pairs: number,
}

local RADIUS = 1
local BUDGET = 5000
local CYCLES = 5

local function crate(c: vector): { vector }
	return {
		vector.create(c.X - 2, c.Y, c.Z - 2),
		vector.create(c.X + 2, c.Y, c.Z - 2),
		vector.create(c.X + 2, c.Y, c.Z + 2),
		vector.create(c.X - 2, c.Y, c.Z + 2),
	}
end

-- The live heap in KB without collectgarbage("collect"): churn short-lived garbage in steps of
-- 1/32 of the heap and keep the lowest count, until twice the heap has been churned with no new
-- low. That spans at least one full GC cycle, and the low sits within a step (about 3%) of the
-- live heap.
local function settledHeap(): number
	local low, quiet = math.huge, 0
	while quiet < 64 do
		local step = math.max(collectgarbage("count") / 32, 64) -- KB
		for _ = 1, step // 2 do
			local _ = table.create(240, 0) -- about 2 KB
		end
		local now = collectgarbage("count")
		if now < low - step then
			low, quiet = now, 0
		else
			low = math.min(low, now)
			quiet += 1
		end
	end
	return low
end

local function measure(o: Options, bake: buffer, side: number): { [string]: any }
	local NavMesh, clock = o.NavMesh, o.Clock
	local r: { [string]: any } = { deserialize = {}, path = {}, pathBudget = {}, update = {}, budgetHits = 0 }
	local function time(f: () -> any): (number, any)
		local t0 = clock()
		local result = f()
		return (clock() - t0) * 1000, result
	end

	-- Deserialize and heap: one load held while the heap is read.
	local h0 = settledHeap()
	local mesh
	for _ = 1, o.Reps do
		mesh = nil
		local ms, m = time(function()
			return NavMesh.Deserialize(bake)
		end)
		table.insert(r.deserialize, ms)
		mesh = m
		o.Yield()
	end
	r.heap = settledHeap() - h0

	-- Seeded cross-map pairs on this mesh.
	math.randomseed(3100 + side)
	local pairs = {}
	local filter = { AgentRadius = RADIUS }
	local tries = 0
	while #pairs < o.Pairs and tries < o.Pairs * 50 do
		tries += 1
		local a = NavMesh.FindRandomPoint(mesh, { Filter = filter, Rng = math.random })
		local b = NavMesh.FindRandomPoint(mesh, { Filter = filter, Rng = math.random })
		if a and b and vector.magnitude((a.Position - b.Position) * vector.create(1, 0, 1)) >= side / 2 then
			table.insert(pairs, { a.Position, b.Position })
		end
	end
	assert(#pairs > 0, "no cross-map pairs")
	local crateAt = NavMesh.FindRandomPoint(
		mesh,
		{ Filter = filter, Center = vector.create(side / 2, 0, side / 2), Radius = side / 8, Rng = math.random }
	)

	-- Cold FindPath: the first radius query on a fresh load.
	mesh = NavMesh.Deserialize(bake)
	o.Yield()
	r.coldPath = time(function()
		return NavMesh.FindPath(mesh, pairs[1][1], pairs[1][2], filter)
	end)
	local budget = { AgentRadius = RADIUS, MaxExpansions = BUDGET }
	for _, pair in pairs do
		table.insert(r.path, (time(function()
			return NavMesh.FindPath(mesh, pair[1], pair[2], filter)
		end)))
		local ms, result = time(function()
			return NavMesh.FindPath(mesh, pair[1], pair[2], budget)
		end)
		table.insert(r.pathBudget, ms)
		if result.Status == "Budget" then
			r.budgetHits += 1
		end
		o.Yield()
	end
	r.warmPath = time(function()
		return NavMesh.FindPath(mesh, pairs[1][1], pairs[1][2], filter)
	end)
	r.pairs = #pairs

	-- Cold Update on a fresh load, then CYCLES add/remove cycles.
	mesh = NavMesh.Deserialize(bake)
	o.Yield()
	local box = crate(crateAt.Position)
	local id = NavMesh.AddObstacle(mesh, crateAt.Floor, box :: any)
	r.coldUpdate = time(function()
		return NavMesh.Update(mesh)
	end)
	NavMesh.RemoveObstacle(mesh, id)
	NavMesh.Update(mesh)
	for _ = 1, CYCLES do
		id = NavMesh.AddObstacle(mesh, crateAt.Floor, box :: any)
		table.insert(r.update, (time(function()
			return NavMesh.Update(mesh)
		end)))
		NavMesh.RemoveObstacle(mesh, id)
		table.insert(r.update, (time(function()
			return NavMesh.Update(mesh)
		end)))
		o.Yield()
	end
	return r
end

local function sorted(xs: { number }): { number }
	local s = table.clone(xs)
	table.sort(s)
	return s
end

-- Median, and the p-th percentile (nearest rank).
local function median(xs: { number }): number
	local s, n = sorted(xs), #xs
	return if n % 2 == 1 then s[(n + 1) // 2] else (s[n // 2] + s[n // 2 + 1]) / 2
end
local function pct(xs: { number }, p: number): number
	local s = sorted(xs)
	return s[math.clamp(math.ceil(p * #s), 1, #s)]
end

return { Measure = measure, Median = median, Pct = pct, Budget = BUDGET, Radius = RADIUS }
