--!strict
-- Ticket 27 cost: FindPath with AgentRadius, an old build (lib/navmesh/src_old, a copy of the
-- sources before ticket 27) vs this one. lune run tools/navmesh/bench/findpath_radius_cost.luau
-- 400 random queries per scene, radius 0.3-2; passes interleaved, order rotated; median of 7.
local Old = require("../../../lib/navmesh/src_old/NavMesh")
local New = require("../../../lib/navmesh/src/NavMesh")
local Scenes = require("./Scenes")

local function makeRng(seed: number): (number, number) -> number
	local state = seed
	return function(lo: number, hi: number): number
		state = (state * 1103515245 + 12345) % 2147483648
		return lo + (state / 2147483648) * (hi - lo)
	end
end
local function median(xs: { number }): number
	local s = table.clone(xs)
	table.sort(s)
	return s[(#s + 1) // 2]
end

print("| scene | TileSize | Old ms / 400 | New ms / 400 | ratio |")
print("|---|---|---|---|---|")
for _, scene in Scenes do
	for _, ts in { 0, 64 } do
		local desc = scene.Make()
		desc.TileSize = if ts == 0 then nil else ts
		local meshes = { Old.Build(desc), New.Build(desc) }
		local libs = { Old, New }
		local rng = makeRng(11)
		local queries = {}
		for i = 1, 400 do
			queries[i] = {
				vector.create(rng(0, scene.Side), 0, rng(0, scene.Side)),
				vector.create(rng(0, scene.Side), 0, rng(0, scene.Side)),
				{ AgentRadius = rng(0.3, 2) },
			}
		end
		local times = { {}, {} }
		for pass = 0, 7 do
			for i = 0, 1 do
				local v = (pass + i) % 2 + 1
				local t0 = os.clock()
				for _, q in queries do
					libs[v].FindPath(meshes[v], q[1], q[2], q[3])
				end
				if pass > 0 then
					table.insert(times[v], (os.clock() - t0) * 1000)
				end
			end
		end
		local a, b = median(times[1]), median(times[2])
		print(
			string.format(
				"| %s | %s | %.1f | %.1f | %.2f |",
				scene.Name,
				if ts == 0 then "default" else tostring(ts),
				a,
				b,
				b / a
			)
		)
	end
end
