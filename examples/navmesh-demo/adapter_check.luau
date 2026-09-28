--!strict
-- Builds the demo level from Parts (LevelParts.luau, through NavMeshAdapter) and checks it
-- against the hand-written Level.luau: the same walkable region, floor by floor, with the same
-- area ids. Prints each difference and exits 1 if there is any.
--   lune run examples/navmesh-demo/adapter_check.luau [--dump]
local process = require("@lune/process")
local roblox = require("@lune/roblox") :: any
local NavMesh = require("../../lib/navmesh/src/NavMesh")
local NavMeshAdapter = require("../../lib/navmeshadapter/src/NavMeshAdapter")
local Level = require("./Level")
local LevelParts = require("./LevelParts")

local walkable, obstacles = LevelParts(roblox)
local desc = NavMeshAdapter.FromParts(walkable, obstacles) :: any
desc.MaxAgentRadius = Level.Desc.MaxAgentRadius
desc.Links = Level.Desc.Links

local function fmt(v: vector): string
	return string.format("(%g, %g, %g)", v.x, v.y, v.z)
end

if table.find(process.args, "--dump") then
	for name, floor in desc.Floors do
		print(`floor {name}`)
		for _, ring in floor.Walkable do
			local s = {}
			for _, p in ring do
				table.insert(s, fmt(p))
			end
			print("  walkable " .. table.concat(s, " "))
		end
		for _, ring in floor.Obstacles or {} do
			local s = {}
			for _, p in ring do
				table.insert(s, fmt(p))
			end
			print("  obstacle " .. table.concat(s, " "))
		end
		for _, a in floor.Areas or {} do
			print(`  area {a.Area} ({#a.Polygon} points)`)
		end
	end
	for _, seam in desc.Seams do
		print(`seam {seam.FloorA}-{seam.FloorB} {fmt(seam.From)} {fmt(seam.To)}`)
	end
end

-- The walkable region, two ways: its area per floor and area id (the area colour), and the
-- corners, edge midpoints and centroid of every triangle, which must lie on the other mesh (a
-- moved crate puts corners inside the other mesh's hole; Y tells overlapping floors apart, and
-- a point on a seam may land on either floor). Triangles
-- themselves may differ: edges between Part pieces stay in the triangulation (no edge
-- dissolve in the core yet: simplification plan C1).
local function areas(mesh): ({ [string]: number }, { vector }, number)
	local sums: { [string]: number }, points: { vector }, count = {}, {}, 0
	for _, item in NavMesh.ToDrawList(mesh, { Areas = true }) do
		if item.Kind ~= "Tri" then
			continue
		end
		count += 1
		local p = item.Points
		local a = vector.create(p[1], p[2], p[3])
		local b = vector.create(p[4], p[5], p[6])
		local c = vector.create(p[7], p[8], p[9])
		local key = `{item.Layer} {item.Color}`
		local ab, ac = b - a, c - a
		sums[key] = (sums[key] or 0) + math.abs(ab.x * ac.z - ab.z * ac.x) / 2
		for _, point in { a, b, c, (a + b) / 2, (b + c) / 2, (c + a) / 2, (a + b + c) / 3 } do
			table.insert(points, point)
		end
	end
	return sums, points, count
end

local expectedMesh, gotMesh = NavMesh.Build(Level.Desc :: any), NavMesh.Build(desc)
local expected, expectedPoints, expectedCount = areas(expectedMesh)
local got, gotPoints, gotCount = areas(gotMesh)
local problems = 0
for key, sum in expected do
	if math.abs((got[key] or 0) - sum) > 1e-3 then
		problems += 1
		print(string.format("area %s: %.3f in Level.luau, %.3f from Parts", key, sum, got[key] or 0))
	end
end
for key, sum in got do
	if expected[key] == nil then
		problems += 1
		print(string.format("area %s: only from Parts (%.3f)", key, sum))
	end
end
local function check(points: { vector }, mesh: NavMesh.NavMeshData, name: string)
	for _, point in points do
		local hit = NavMesh.FindNearestPoint(mesh, point :: any)
		if hit == nil or vector.magnitude((hit.Position :: any) - point) > 1e-3 then
			problems += 1
			print(`{fmt(point)} is not on the mesh from {name}`)
		end
	end
end
check(expectedPoints, gotMesh, "Parts")
check(gotPoints, expectedMesh, "Level.luau")
print(`Level.luau {expectedCount} triangles, Parts {gotCount}; {problems} differences in the walkable region`)
process.exit(if problems == 0 then 0 else 1)
