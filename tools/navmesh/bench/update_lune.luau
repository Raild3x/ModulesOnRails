--!strict
-- NavMesh.Update cost (ticket 22): one 4 x 4 crate added, then removed, on the bench scenes.
-- Local is the shipped Update. (Base, the Update as of c22136d, was removed with format v3,
-- whose storage it can't read; its numbers are in bench.md.) Interpreted Lune, os.clock.
--   lune run tools/navmesh/bench/update_lune.luau [maps|sweep] [runs]
-- Method (bench.md): each variant updates its own mesh; runs are interleaved with the variant
-- order rotated each run; one warm-up run; medians with [min-max] over the runs. The crate is the
-- dogfood bench's, 4 x 4 at side / 2 + (run % 5). Both variants must end every run with the
-- same triangle count.
local process = require("@lune/process")
local NavMesh = require("../../../lib/navmesh/src/NavMesh")
local Storage = require("../../../lib/navmesh/src/Storage")
local Scenes = require("./Scenes")

local mode = process.args[1] or "maps"
local runs = tonumber(process.args[2]) or 15

type Variant = { Name: string, Update: (mesh: any) -> () }
local variants: { Variant } = {
	{ Name = "Local", Update = NavMesh.Update },
}

local function sorted(xs: { number }): { number }
	local s = table.clone(xs)
	table.sort(s)
	return s
end
local function median(xs: { number }): number
	local s = sorted(xs)
	local n = #s
	return if n % 2 == 1 then s[(n + 1) // 2] else (s[n // 2] + s[n // 2 + 1]) / 2
end
local function cell(xs: { number }): string
	local s = sorted(xs)
	return string.format("%.1f [%.1f-%.1f]", median(xs), s[1], s[#s])
end

local function crate(c: number): { vector }
	return {
		vector.create(c - 2, 0, c - 2),
		vector.create(c + 2, 0, c - 2),
		vector.create(c + 2, 0, c + 2),
		vector.create(c - 2, 0, c + 2),
	}
end

-- Times per variant: { add = { ms }, remove = { ms } }. Returns them with the mesh's triangle
-- and tile counts.
local function measure(
	name: string,
	cap: number?,
	tileSize: number?
): ({ [string]: { [string]: { number } } }, number, number)
	local scene
	for _, s in Scenes do
		if s.Name == name then
			scene = s
		end
	end
	local desc = scene.Make()
	desc.MaxAgentRadius = cap
	desc.TileSize = tileSize
	local meshes, times = {}, {}
	for _, variant in variants do
		meshes[variant.Name] = NavMesh.Build(desc)
		times[variant.Name] = { add = {}, remove = {} }
	end
	for run = 0, runs do -- run 0 warms up
		local c = scene.Side / 2 + run % 5
		local counts = {}
		for k = 1, #variants do
			local variant = variants[(run + k - 1) % #variants + 1]
			local mesh = meshes[variant.Name]
			local id = NavMesh.AddObstacle(mesh, "Ground", crate(c) :: any)
			local t0 = os.clock()
			variant.Update(mesh)
			local added = (os.clock() - t0) * 1000
			table.insert(counts, Storage.TriangleCount(mesh))
			NavMesh.RemoveObstacle(mesh, id)
			t0 = os.clock()
			variant.Update(mesh)
			local removed = (os.clock() - t0) * 1000
			if run > 0 then
				table.insert(times[variant.Name].add, added)
				table.insert(times[variant.Name].remove, removed)
			end
		end
		assert(counts[1] == (counts[2] or counts[1]), `{name}: the variants disagree on the triangle count`)
	end
	local mesh = meshes[variants[1].Name]
	return times, Storage.TriangleCount(mesh), Storage.TileCount(mesh)
end

local rows = {}
if mode == "maps" then
	for _, scene in Scenes do
		for _, cap in { 0, 2 } do
			table.insert(rows, { scene.Name, cap, 0 })
		end
	end
elseif mode == "sweep" then
	for _, cap in { 2, 0 } do
		for _, size in { 64, 32, 16, 8, 4 } do
			table.insert(rows, { "bench", cap, size })
		end
	end
else
	error("usage: update_lune.luau [maps|sweep] [runs]")
end

print(`Update ms, add / remove, median [min-max] of {runs} interleaved runs`)
print("| scene | cap | TileSize | triangles | tiles | Local add | Local remove |")
print("|---|---|---|---|---|---|---|")
for _, row in rows do
	local name, cap, size = row[1] :: string, row[2] :: number, row[3] :: number
	local times, triangles, tiles = measure(name, if cap > 0 then cap else nil, if size > 0 then size else nil)
	print(
		string.format(
			"| %s | %s | %s | %d | %d | %s | %s |",
			name,
			if cap > 0 then tostring(cap) else "none",
			if size > 0 then tostring(size) else "default",
			triangles,
			tiles,
			cell(times.Local.add),
			cell(times.Local.remove)
		)
	)
end
