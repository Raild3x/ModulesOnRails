--!strict
--[=[
	Synthetic scenes for the geometry-simplification measurements (docs/plans/navmesh/
	simplification-plan.md), recreating the lost prototype scenes. Each is one flat floor at y 0:
	- `Rocks()`: a 512-stud floor whose walkable outline is a 720-point noisy coast, 90 noisy
	  rocks of 48-160 points (radius 2-8, edge noise 0.05-0.3 studs) and 60 cylinder 24-gons
	  (radius 1-3). Dense rings: what a terrain or MeshPart adapter emits.
	- `Pieces()`: a 256-stud floor of 16x16 walkable Part pieces (each grown 0.05 so neighbours
	  overlap, rotated up to +-0.15 degrees, 4% missing), 150 near-touching crate pairs (gap
	  0.01-0.02, each crate rotated up to +-1 degree) and 40 cylinder 24-gons. A floor authored
	  in pieces: what a Part adapter emits.
	`Pairs(NavMesh, mesh, seed, count)` draws deterministic FindPath pairs on a built mesh.
	Every ring is star-shaped about its centre (angles strictly increasing), so simple.
]=]

local SimplifyScenes = {}

local function rand(lo: number, hi: number): number
	return lo + math.random() * (hi - lo)
end

local function box(cx: number, cz: number, w: number, d: number, angle: number): { vector }
	local c, s = math.cos(angle), math.sin(angle)
	local ring = {}
	for _, corner in { { -1, -1 }, { 1, -1 }, { 1, 1 }, { -1, 1 } } do
		local x, z = corner[1] * w / 2, corner[2] * d / 2
		table.insert(ring, vector.create(cx + x * c - z * s, 0, cz + x * s + z * c))
	end
	return ring
end

local function cylinder(cx: number, cz: number, r: number): { vector }
	local ring, phase = {}, rand(0, 2 * math.pi)
	for i = 0, 23 do
		local a = phase + i * 2 * math.pi / 24
		table.insert(ring, vector.create(cx + r * math.cos(a), 0, cz + r * math.sin(a)))
	end
	return ring
end

-- A noisy rock: `n` points at even angles, the radius bent by three low-frequency lumps (up to
-- 25% of r) plus per-point noise up to `noise` studs.
local function rock(cx: number, cz: number, r: number, n: number, noise: number): { vector }
	local lumps = {}
	for k = 1, 3 do
		lumps[k] = { amp = rand(0, 0.25 / k) * r, freq = k + 1, phase = rand(0, 2 * math.pi) }
	end
	local ring = {}
	for i = 0, n - 1 do
		local a = i * 2 * math.pi / n
		local rr = r + rand(-noise, noise)
		for _, l in lumps do
			rr += l.amp * math.sin(l.freq * a + l.phase)
		end
		table.insert(ring, vector.create(cx + rr * math.cos(a), 0, cz + rr * math.sin(a)))
	end
	return ring
end

function SimplifyScenes.Rocks(): any
	math.randomseed(37)
	local side, half = 512, 250
	-- The coast: 180 points per side of a square, each pushed out or in along its ray from the
	-- centre by a slow wave plus noise (1-2 studs in all).
	local coast, phase = {}, rand(0, 2 * math.pi)
	for i = 0, 719 do
		local u = (i % 180) / 180 * 2 - 1 -- -1..1 along the side
		local x, z
		local sideIndex = i // 180
		if sideIndex == 0 then
			x, z = u * half, -half
		elseif sideIndex == 1 then
			x, z = half, u * half
		elseif sideIndex == 2 then
			x, z = -u * half, half
		else
			x, z = -half, -u * half
		end
		local len = math.sqrt(x * x + z * z)
		local push = 1.2 * math.sin(i * 2 * math.pi / 45 + phase) + rand(-0.8, 0.8)
		local k = (len + push) / len
		table.insert(coast, vector.create(side / 2 + x * k, 0, side / 2 + z * k))
	end
	local obstacles = {}
	for _ = 1, 90 do
		local r = rand(2, 8)
		table.insert(
			obstacles,
			rock(rand(20, side - 20), rand(20, side - 20), r, math.random(48, 160), rand(0.05, 0.3))
		)
	end
	for _ = 1, 60 do
		table.insert(obstacles, cylinder(rand(10, side - 10), rand(10, side - 10), rand(1, 3)))
	end
	return { Floors = { Ground = { Walkable = { coast }, Obstacles = obstacles } } }
end

function SimplifyScenes.Pieces(): any
	math.randomseed(41)
	local side, piece, grow = 256, 16, 0.05
	local walkable = {}
	for i = 0, side // piece - 1 do
		for j = 0, side // piece - 1 do
			local angle = math.rad(rand(-0.15, 0.15))
			if math.random() >= 0.04 then
				local cx, cz = (i + 0.5) * piece, (j + 0.5) * piece
				table.insert(walkable, box(cx, cz, piece + 2 * grow, piece + 2 * grow, angle))
			end
		end
	end
	local obstacles = {}
	for _ = 1, 150 do
		local cx, cz = rand(8, side - 8), rand(8, side - 8)
		local w, gap = rand(2.8, 3.2), rand(0.01, 0.02)
		local d = rand(2.8, 3.2)
		table.insert(obstacles, box(cx - (w + gap) / 2, cz, w, d, math.rad(rand(-1, 1))))
		table.insert(obstacles, box(cx + (w + gap) / 2, cz, w, d, math.rad(rand(-1, 1))))
	end
	for _ = 1, 40 do
		table.insert(obstacles, cylinder(rand(5, side - 5), rand(5, side - 5), rand(1, 3)))
	end
	return { Floors = { Ground = { Walkable = walkable, Obstacles = obstacles } } }
end

--[=[
	`count` FindPath pairs ({from, to} feet positions) of random points on `mesh`, each clear
	for an agent of radius 1 so the pairs serve AgentRadius 0 and 1 alike. Deterministic for a
	given mesh and seed: draw them on the unsimplified mesh and reuse them for every tolerance.
]=]
function SimplifyScenes.Pairs(NavMesh: any, mesh: any, seed: number, count: number): { { vector } }
	math.randomseed(seed)
	local rng = function(): number
		return math.random()
	end
	local points = {}
	for _ = 1, count * 20 do
		if #points == 2 * count then
			break
		end
		local p = NavMesh.FindRandomPoint(mesh, { Filter = { AgentRadius = 1 }, Rng = rng })
		if p then
			table.insert(points, p.Position)
		end
	end
	assert(#points == 2 * count, "SimplifyScenes.Pairs: too few random points on this mesh")
	local pairs = {}
	for i = 1, count do
		pairs[i] = { points[2 * i - 1], points[2 * i] }
	end
	return pairs
end

return SimplifyScenes
