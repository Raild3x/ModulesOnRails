--!strict
-- Geometry simplification: what `SimplifyTolerance` does to each scene's mesh, Build and paths
-- (docs/plans/navmesh/simplification-plan.md). Run from the repo root:
--   lune run tools/navmesh/bench/simplify_measure.luau <rounds> <scene,...> [eps,...]
-- Scenes: rocks, pieces (SimplifyScenes), props, bench, terrain, walls (Scenes), demo
-- (examples/navmesh-demo), or any map in tools/navmesh/maps/Maps by name (city, forestriver,
-- building, ...; built through NavMeshAdapter). Tolerances default to 0,1/16,1/10,1/4.
-- Each round builds every scene x tolerance once, in shuffled order. Per scene x tolerance:
-- mesh counts (round 1), Build median (min-max), the FindPath sum over 200 fixed pairs at
-- AgentRadius 0 and 1 (best of 3, median over rounds), path length against an untimed
-- tolerance-0 reference build (mean and worst ratio over pairs that succeed in both, radii
-- pooled), successes and the kept plan area.
local fs = require("@lune/fs")
local process = require("@lune/process")
local NavMesh = require("../../../lib/navmesh/src/NavMesh")
local Storage = require("../../../lib/navmesh/src/Storage")
local Scenes = require("./Scenes")
local SimplifyScenes = require("./SimplifyScenes")

local PAIRS, PAIR_SEED, REPS = 200, 2026, 3
local RADII = { 0, 1 }

local function median(xs: { number }): number
	local s = table.clone(xs)
	table.sort(s)
	return s[(#s + 1) // 2]
end

local function split(s: string?): { string }
	local out = {}
	for item in string.gmatch(s or "", "[^,]+") do
		table.insert(out, item)
	end
	return out
end

-- "1/16" or "0.0625".
local function parseEps(s: string): number
	local a, b = string.match(s, "^([%d%.]+)/([%d%.]+)$")
	local eps = if a then tonumber(a) :: number / tonumber(b) :: number else tonumber(s)
	return assert(eps, `bad tolerance {s}`)
end

-- NavMeshAdapter's `require("../NavMesh")` is a Wally link that only exists once the package is
-- vendored (scripts/setup_package_for_testing.py); load the source with that one require
-- pointed at the library instead, so a fresh worktree runs the maps too.
local function loadAdapter(): any
	local luau = require("@lune/luau")
	local source = fs.readFile("lib/navmeshadapter/src/NavMeshAdapter.luau")
	local chunk = luau.load(source, {
		debugName = "NavMeshAdapter",
		environment = {
			require = function(path: string): any
				assert(path == "../NavMesh", `NavMeshAdapter requires {path}`)
				return NavMesh
			end,
		},
	})
	return chunk()
end

-- A function returning the scene's NavMeshDesc.
local function sceneDesc(name: string): () -> any
	if name == "rocks" then
		return SimplifyScenes.Rocks
	elseif name == "pieces" then
		return SimplifyScenes.Pieces
	elseif name == "demo" then
		return function()
			return require("../../../examples/navmesh-demo/Level").Desc
		end
	end
	for _, scene in Scenes do
		if scene.Name == name then
			return scene.Make
		end
	end
	for _, file in fs.readDir("tools/navmesh/maps/Maps") do
		local mapName = file:match("^(.+)%.luau$")
		if mapName and string.lower(mapName) == name then
			return function()
				local dynRequire: any = require
				local map = dynRequire("../maps/Maps/" .. mapName)
				local Adapter = loadAdapter()
				local built = map.Build(require("@lune/roblox"))
				local desc = Adapter.FromParts(built.Walkable, built.Obstacles, map.AdapterOptions) :: any
				desc.MaxAgentRadius = map.MaxAgentRadius or 2
				desc.Links = built.Links
				return desc
			end
		end
	end
	error(`unknown scene {name}`)
end

local function withEps(desc: any, eps: number): any
	local d = table.clone(desc)
	d.SimplifyTolerance = eps
	return d
end

local function stats(mesh: any): (number, number, number, number)
	local tris, walls, area = Storage.TriangleCount(mesh), 0, 0
	for t = 1, tris do
		local a, b, c = Storage.GetTriangle(mesh, t)
		local pa, pb, pc = Storage.GetVertex(mesh, a), Storage.GetVertex(mesh, b), Storage.GetVertex(mesh, c)
		area += math.abs((pb.x - pa.x) * (pc.z - pa.z) - (pc.x - pa.x) * (pb.z - pa.z)) / 2
		for e = 1, 3 do
			if Storage.IsWallEdge(mesh, t, e) then
				walls += 1
			end
		end
	end
	return tris, walls, Storage.VertexCount(mesh), area
end

-- The FindPath sum (ms, best of REPS) and the paths, for one radius.
local function findPaths(mesh: any, pairs: { { vector } }, radius: number): (number, { any })
	local filter = { AgentRadius = radius }
	local best, paths = math.huge, {}
	for _ = 1, REPS do
		local t0 = os.clock()
		for i, pair in pairs do
			paths[i] = NavMesh.FindPath(mesh, pair[1] :: any, pair[2] :: any, filter)
		end
		best = math.min(best, (os.clock() - t0) * 1000)
	end
	return best, paths
end

local rounds = tonumber(process.args[1]) or 1
local names = split(process.args[2] or "rocks,pieces")
local epsText = split(process.args[3] or "0,1/16,1/10,1/4")

-- Setup: each scene's desc, its reference mesh (tolerance 0, untimed), pairs and paths.
type Job = { Scene: string, EpsText: string, Eps: number, Build: { number }, FP: { { number } }, Row: any? }
local scenes = {}
local jobs: { Job } = {}
for _, name in names do
	local t0 = os.clock()
	local desc = sceneDesc(name)()
	local ref = NavMesh.Build(withEps(desc, 0))
	local pairs = SimplifyScenes.Pairs(NavMesh, ref, PAIR_SEED, PAIRS)
	local refPaths = {}
	for k, radius in RADII do
		refPaths[k] = select(2, findPaths(ref, pairs, radius))
	end
	scenes[name] = { Desc = desc, Pairs = pairs, RefPaths = refPaths }
	print(
		string.format("[setup] %s: reference %d triangles, %.0f ms", name, ref.TriangleCount, (os.clock() - t0) * 1000)
	)
	for _, text in epsText do
		table.insert(jobs, { Scene = name, EpsText = text, Eps = parseEps(text), Build = {}, FP = { {}, {} } })
	end
end

for round = 1, rounds do
	math.randomseed(round)
	local order = table.clone(jobs)
	for i = #order, 2, -1 do
		local j = math.random(i)
		order[i], order[j] = order[j], order[i]
	end
	for _, job in order do
		local scene = scenes[job.Scene]
		local desc = withEps(scene.Desc, job.Eps)
		local t0 = os.clock()
		local mesh = NavMesh.Build(desc)
		local buildMs = (os.clock() - t0) * 1000
		table.insert(job.Build, buildMs)
		local paths = {}
		for k, radius in RADII do
			local ms
			ms, paths[k] = findPaths(mesh, scene.Pairs, radius)
			table.insert(job.FP[k], ms)
		end
		if job.Row == nil then
			local tris, walls, verts, area = stats(mesh)
			local sum, n, worst, ok = 0, 0, 0, { 0, 0 }
			for k in RADII do
				for i, path in paths[k] do
					local ref = scene.RefPaths[k][i]
					if path.Status == "Success" then
						ok[k] += 1
						if ref.Status == "Success" and ref.Length > 0 then
							local ratio = path.Length / ref.Length
							sum, n, worst = sum + ratio, n + 1, math.max(worst, ratio)
						end
					end
				end
			end
			job.Row = {
				Tris = tris,
				Walls = walls,
				Verts = verts,
				Area = area,
				Mean = if n > 0 then sum / n else 0 / 0,
				Worst = worst,
				Ok = ok,
			}
		end
		print(string.format("[round %d] %s eps %s: Build %.0f ms", round, job.Scene, job.EpsText, buildMs))
	end
end

local function pct(ratio: number): string
	return string.format("%+.2f%%", (ratio - 1) * 100)
end

print("")
print(`{rounds} rounds; FindPath = sum of {PAIRS} pairs, best of {REPS}, median over rounds; path vs eps 0 reference`)
print("")
print(
	"| scene | eps | triangles | wall edges | vertices | Build ms (range) | FindPath r0 | FindPath r1 | path mean / worst | success r0/r1 | kept area |"
)
print("|---|---|---|---|---|---|---|---|---|---|---|")
for _, job in jobs do
	local r = job.Row :: any
	print(
		string.format(
			"| %s | %s | %d | %d | %d | %.0f (%.0f-%.0f) | %.1f | %.1f | %s / %s | %d/%d | %.2f |",
			job.Scene,
			job.EpsText,
			r.Tris,
			r.Walls,
			r.Verts,
			median(job.Build),
			math.min(table.unpack(job.Build)),
			math.max(table.unpack(job.Build)),
			median(job.FP[1]),
			median(job.FP[2]),
			pct(r.Mean),
			pct(r.Worst),
			r.Ok[1],
			r.Ok[2],
			r.Area
		)
	)
end
