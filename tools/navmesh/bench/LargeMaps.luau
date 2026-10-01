--!strict
--[=[
	Large-world maps for ticket 31: seeded generators of 1-4 km NavMesh descs. Shared by the Lune
	bench (large_world.luau) and the Studio run (large_world.py).
	- `city`: a street grid (96-stud pitch, 16-stud streets) with four building lots per block;
	  each building footprint is a Ground obstacle. One lot in 16 holds a two-storey building: a
	  ramp floor up its west side and a roof floor at y = 12, joined to Ground by seams.
	- `open`: one flat floor with scattered props (1-4 studs, randomly rotated, one per 400
	  square studs).
	- `terrain`: what a terrain adapter would emit. A heightfield lattice (32-stud cells,
	  rotated 3 degrees off the axes) split into two planar triangle rings per cell; cells
	  steeper than 1 in 2 are left out (cliffs), and rocks (slightly rotated hexagons, one per
	  2,000 square studs) are obstacles.
	Every generator takes the side in studs and is deterministic (math.randomseed + PCG).
]=]

export type Map = { Name: string, Make: (side: number) -> any }

local function rect(x0: number, z0: number, x1: number, z1: number, y: number): { vector }
	return { vector.create(x0, y, z0), vector.create(x1, y, z0), vector.create(x1, y, z1), vector.create(x0, y, z1) }
end

local function rotated(cx: number, cz: number, w: number, d: number, angle: number): { vector }
	local c, s = math.cos(angle), math.sin(angle)
	local ring = {}
	for _, corner in { { -1, -1 }, { 1, -1 }, { 1, 1 }, { -1, 1 } } do
		local x, z = corner[1] * w / 2, corner[2] * d / 2
		table.insert(ring, vector.create(cx + x * c - z * s, 0, cz + x * s + z * c))
	end
	return ring
end

local function between(lo: number, hi: number): number
	return lo + math.random() * (hi - lo)
end

local PITCH, STREET, LOT = 96, 16, 40
local STOREY = 12

local function city(side: number): any
	math.randomseed(31)
	local obstacles, floors, seams = {}, {}, {}
	local k = 0
	for bx = 0, side - PITCH, PITCH do
		for bz = 0, side - PITCH, PITCH do
			for a = 0, 1 do
				for b = 0, 1 do
					local lx, lz = bx + STREET / 2 + a * LOT, bz + STREET / 2 + b * LOT
					if math.random() < 1 / 16 then
						-- Two storeys: footprint x lx+16..lx+38, ramp x lx+2..lx+16 on z lz+4..lz+8.
						k += 1
						local ramp, roof = `Ramp{k}`, `Roof{k}`
						table.insert(obstacles, rect(lx + 16, lz + 4, lx + 38, lz + 36, 0))
						floors[roof] = { Walkable = { rect(lx + 16, lz + 4, lx + 38, lz + 36, STOREY) } }
						floors[ramp] = {
							Walkable = {
								{
									vector.create(lx + 2, 0, lz + 4),
									vector.create(lx + 16, STOREY, lz + 4),
									vector.create(lx + 16, STOREY, lz + 8),
									vector.create(lx + 2, 0, lz + 8),
								},
							},
						}
						table.insert(seams, {
							FloorA = "Ground",
							FloorB = ramp,
							From = vector.create(lx + 2, 0, lz + 4),
							To = vector.create(lx + 2, 0, lz + 8),
						})
						table.insert(seams, {
							FloorA = ramp,
							FloorB = roof,
							From = vector.create(lx + 16, STOREY, lz + 4),
							To = vector.create(lx + 16, STOREY, lz + 8),
						})
					else
						local w, d = between(22, 34), between(22, 34)
						local cx = lx + LOT / 2 + between(-1, 1) * (LOT - w) / 2
						local cz = lz + LOT / 2 + between(-1, 1) * (LOT - d) / 2
						local angle = if math.random() < 0.1 then between(-0.2, 0.2) else 0
						table.insert(obstacles, rotated(cx, cz, w * 0.95, d * 0.95, angle))
					end
				end
			end
		end
	end
	floors.Ground = { Walkable = { rect(0, 0, side, side, 0) }, Obstacles = obstacles }
	return { Floors = floors, Seams = seams }
end

local function open(side: number): any
	math.randomseed(32)
	local obstacles = {}
	for _ = 1, side * side // 400 do
		table.insert(
			obstacles,
			rotated(between(0, side), between(0, side), between(1, 4), between(1, 4), between(0, math.pi))
		)
	end
	return { Floors = { Ground = { Walkable = { rect(0, 0, side, side, 0) }, Obstacles = obstacles } } }
end

local CELL, TILT = 32, math.rad(3)

local function terrain(side: number): any
	math.randomseed(33)
	-- Height: a few seeded sine waves, about +-30 studs.
	local waves = {}
	for _ = 1, 4 do
		table.insert(waves, {
			kx = between(-1, 1) * 2 * math.pi / between(150, 600),
			kz = between(-1, 1) * 2 * math.pi / between(150, 600),
			phase = between(0, 2 * math.pi),
			amp = between(4, 9),
		})
	end
	local function height(x: number, z: number): number
		local h = 0
		for _, w in waves do
			h += w.amp * math.sin(w.kx * x + w.kz * z + w.phase)
		end
		return h
	end
	-- Lattice point (i, j), rotated by TILT about the map centre.
	local c, s, mid = math.cos(TILT), math.sin(TILT), side / 2
	local function at(i: number, j: number): vector
		local u, v = i * CELL - mid, j * CELL - mid
		local x, z = mid + u * c - v * s, mid + u * s + v * c
		return vector.create(x, height(x, z), z)
	end
	local function inside(p: vector): boolean
		return p.X >= 0 and p.X <= side and p.Z >= 0 and p.Z <= side
	end
	local walkable = {}
	local n = math.ceil(side * 1.1 / CELL)
	local lo = -math.floor(n * 0.05)
	for i = lo, n do
		for j = lo, n do
			local p, q, r, t = at(i, j), at(i + 1, j), at(i + 1, j + 1), at(i, j + 1)
			if inside(p) and inside(q) and inside(r) and inside(t) then
				local hs = { p.Y, q.Y, r.Y, t.Y }
				local steep = (math.max(table.unpack(hs)) - math.min(table.unpack(hs))) / CELL > 0.5
				if not steep then
					table.insert(walkable, { p, q, r })
					table.insert(walkable, { p, r, t })
				end
			end
		end
	end
	local obstacles = {}
	for _ = 1, side * side // 2000 do
		local cx, cz, radius, spin = between(0, side), between(0, side), between(2, 8), between(-0.2, 0.2)
		local ring = {}
		for v = 0, 5 do
			local angle = spin + v * math.pi / 3
			local rr = radius * between(0.8, 1.2)
			table.insert(ring, vector.create(cx + rr * math.cos(angle), 0, cz + rr * math.sin(angle)))
		end
		table.insert(obstacles, ring)
	end
	return { Floors = { Ground = { Walkable = walkable, Obstacles = obstacles } } }
end

local LargeMaps: { Map } = {
	{ Name = "city", Make = city },
	{ Name = "open", Make = open },
	{ Name = "terrain", Make = terrain },
}

return LargeMaps
