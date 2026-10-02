--!strict
-- E3 cost: FindPath on link-heavy scenes, an old build (lib/navmesh/src_old, a copy of the
-- sources before the change) vs this one, at radius 0 and at radius 0.3-2.
--   lune run tools/navmesh/bench/findpath_links_cost.luau
-- 400 random queries per row; passes interleaved, order rotated; median of 7 (after a warm-up
-- pass: at one radius, "1", the barrier verdicts are then remembered; with a radius drawn per
-- query, "0.3-2", they mostly are not). Links have random
-- ends on the mesh, two in three bidirectional.
local Old = require("../../../lib/navmesh/src_old/NavMesh")
local New = require("../../../lib/navmesh/src/NavMesh")
local Flood = require("../../../lib/navmesh/src/Tests/Helpers/Flood")
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

print("| scene | links | radius | Old ms / 400 | New ms / 400 | ratio |")
print("|---|---|---|---|---|---|")
for _, scene in { Scenes[1], Scenes[2] } do
	for _, count in { 0, 100, 1000 } do
		local desc = scene.Make()
		local oracle = Flood.New(New.Build(desc))
		local rng = makeRng(5 + count)
		local function point(): vector
			while true do
				local p = vector.create(rng(0, scene.Side), 0, rng(0, scene.Side))
				if Flood.OnMesh(oracle, p.X, p.Z) then
					return p
				end
			end
		end
		local links = {}
		for i = 1, count do
			table.insert(links, { From = point(), To = point(), Bidirectional = i % 3 ~= 0 })
		end
		desc.Links = links
		local meshes = { Old.Build(desc), New.Build(desc) }
		local libs = { Old, New }
		for _, mode in { "0", "0.3-2", "1" } do
			local queries = {}
			for i = 1, 400 do
				queries[i] = {
					vector.create(rng(0, scene.Side), 0, rng(0, scene.Side)),
					vector.create(rng(0, scene.Side), 0, rng(0, scene.Side)),
					{ AgentRadius = if mode == "0.3-2" then rng(0.3, 2) else tonumber(mode) },
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
			print(string.format("| %s | %d | %s | %.1f | %.1f | %.2f |", scene.Name, count, mode, a, b, b / a))
		end
	end
end
