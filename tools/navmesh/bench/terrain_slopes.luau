--!strict
-- How a map's walkable ground spreads over slope: floors, their mesh triangles and their area by
-- slope band, plus the build costs. The baseline for merging floors of similar slope.
--   lune run tools/navmesh/bench/terrain_slopes.luau [Map=Highlands]
local process = require("@lune/process")
local roblox = require("@lune/roblox") :: any
local NavMesh = require("../../../lib/navmesh/src/NavMesh")
local Adapter = require("../../../lib/navmeshadapter/src/NavMeshAdapter")
local Storage = require("../../../lib/navmesh/src/Storage")

local name = process.args[1] or "Highlands"
local map = (require :: any)("../maps/Maps/" .. name)
local BANDS = { 0.5, 2, 5, 10, 15, 20, 25, 30, 35, 40, 45 }

local built = map.Build(roblox)
local t0 = os.clock()
local desc = Adapter.FromParts(built.Walkable, built.Obstacles, map.AdapterOptions) :: any
local fromParts = (os.clock() - t0) * 1000
desc.MaxAgentRadius = map.MaxAgentRadius or 2
desc.Links = built.Links
t0 = os.clock()
local mesh = NavMesh.Build(desc)
local build = (os.clock() - t0) * 1000

-- A floor's slope: the plane through its first ring (the adapter puts every ring on it).
local function slope(ring: { any }): number
	local a = ring[1]
	for i = 2, #ring - 1 do
		local n = vector.cross(ring[i] - a, ring[i + 1] - a)
		if vector.magnitude(n) > 1e-6 then
			return math.deg(math.acos(math.abs(vector.normalize(n).y)))
		end
	end
	return 0
end
local function area(ring: { any }): number
	local s = 0
	for i, p in ring do
		local q = ring[i % #ring + 1]
		s += p.x * q.z - q.x * p.z
	end
	return math.abs(s) / 2
end
local function band(deg: number): number
	for k, b in BANDS do
		if deg < b then
			return k
		end
	end
	return #BANDS + 1
end

local rows = {}
for k = 1, #BANDS + 1 do
	rows[k] = { Floors = 0, Area = 0, Triangles = 0 }
end
local floorBand, total = {}, 0
for floorName, f in desc.Floors do
	local k = band(slope(f.Walkable[1]))
	floorBand[floorName] = k
	rows[k].Floors += 1
	for _, r in f.Walkable do
		rows[k].Area += area(r)
		total += area(r)
	end
end
-- Mesh triangles by their floor's band.
for t = 1, mesh.TriangleCount do
	local k = floorBand[Storage.GetFloorName(mesh, Storage.GetTriangleFloor(mesh, t))]
	if k then
		rows[k].Triangles += 1
	end
end

local floors = 0
for _ in desc.Floors do
	floors += 1
end
print(
	string.format(
		"%s: %d Parts; FromParts %.0f ms, Build %.0f ms; %d triangles, %d floors, %d seams; bake %d bytes",
		name,
		#built.Walkable + #built.Obstacles,
		fromParts,
		build,
		mesh.TriangleCount,
		floors,
		#desc.Seams,
		buffer.len(NavMesh.Serialize(mesh))
	)
)
print("| slope | floors | mesh triangles | walkable area (authored) |")
print("|---|---|---|---|")
for k, r in rows do
	local lo = if k == 1 then 0 else BANDS[k - 1]
	local hi = BANDS[k]
	print(
		string.format(
			"| %s | %d | %d | %.0f%% |",
			if hi then `{lo}-{hi}` else `{lo}+`,
			r.Floors,
			r.Triangles,
			r.Area / total * 100
		)
	)
end
