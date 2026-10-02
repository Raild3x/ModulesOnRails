--!strict
-- Ticket 30 risk: Search.HeuristicScale loops over every link on every FindPath.
-- lune run tools/navmesh/bench/link_scale.luau
-- Per scene and link count (0, 100, 1000): FindPath us per call (r 0, 400 random pairs, median
-- of 7 passes), and HeuristicScale alone against the per-area candidate (the cheapest
-- price-per-length kept per link area, so a query reads one entry per area).
local NavMesh = require("../../../lib/navmesh/src/NavMesh")
local Search = require("../../../lib/navmesh/src/Search")
local Storage = require("../../../lib/navmesh/src/Storage")
local Scenes = require("./Scenes")

local function median(xs: { number }): number
	local s = table.clone(xs)
	table.sort(s)
	return s[(#s + 1) // 2]
end

-- The candidate: per link area, the cheapest enabled (Cost / length); 0 for a zero-length free
-- link. Built once per link-set change; a query then scales by its own multipliers.
local function perArea(s: Storage.State): { [number]: number }
	local best: { [number]: number } = {}
	for id = 1, Storage.LinkCount(s) do
		local _, from, _, to, cost, area, _, _, enabled = Storage.GetLink(s, id)
		if enabled then
			local length = vector.magnitude(to - from)
			local ratio = if length > 0 then cost / length elseif cost == 0 then 0 else math.huge
			best[area] = math.min(best[area] or math.huge, ratio)
		end
	end
	return best
end
local function scaleFrom(best: { [number]: number }, costs: { [number]: number }): number
	local scale = 1
	for _, multiplier in costs do
		scale = math.min(scale, multiplier)
	end
	for area, ratio in best do
		local multiplier = costs[area] or 1
		if multiplier ~= math.huge then
			scale = math.min(scale, ratio * multiplier)
		end
	end
	return scale
end

math.randomseed(30)
print("| scene | links | FindPath us | HeuristicScale us | per-area us | same answer |")
print("|---|---|---|---|---|---|")
for _, scene in Scenes do
	for _, count in { 0, 100, 1000 } do
		local desc = scene.Make()
		local base = NavMesh.Build(desc)
		-- Links between random on-mesh points, dearer than walking so routes don't change much.
		local links = {}
		while #links < count do
			local a: any =
				NavMesh.FindNearestPoint(base, vector.create(math.random() * scene.Side, 0, math.random() * scene.Side))
			local b: any =
				NavMesh.FindNearestPoint(base, vector.create(math.random() * scene.Side, 0, math.random() * scene.Side))
			if a and b and vector.magnitude(a.Position - b.Position) > 1 then
				table.insert(links, {
					From = a.Position,
					To = b.Position,
					Cost = vector.magnitude(a.Position - b.Position) * (1 + math.random()),
					Area = 1 + #links % 4,
				})
			end
		end
		desc.Links = links
		local mesh = NavMesh.Build(desc)
		local queries = {}
		for i = 1, 400 do
			queries[i] = {
				vector.create(math.random() * scene.Side, 0, math.random() * scene.Side),
				vector.create(math.random() * scene.Side, 0, math.random() * scene.Side),
			}
		end
		local find = {}
		for pass = 0, 7 do
			local t0 = os.clock()
			for _, q in queries do
				NavMesh.FindPath(mesh, q[1] :: any, q[2] :: any)
			end
			if pass > 0 then
				table.insert(find, (os.clock() - t0) * 1e6 / #queries)
			end
		end
		local costs = { [2] = 1.5, [3] = 0.8 }
		local best = perArea(mesh :: any)
		local scaleT, areaT = {}, {}
		for pass = 0, 7 do
			local t0 = os.clock()
			for _ = 1, 1000 do
				Search.HeuristicScale(mesh :: any, costs)
			end
			local t1 = os.clock()
			for _ = 1, 1000 do
				scaleFrom(best, costs)
			end
			if pass > 0 then
				table.insert(scaleT, (t1 - t0) * 1e3)
				table.insert(areaT, (os.clock() - t1) * 1e3)
			end
		end
		local same = Search.HeuristicScale(mesh :: any, costs) == scaleFrom(best, costs)
		print(
			string.format(
				"| %s | %d | %.1f | %.2f | %.3f | %s |",
				scene.Name,
				count,
				median(find),
				median(scaleT),
				median(areaT),
				tostring(same)
			)
		)
	end
end
