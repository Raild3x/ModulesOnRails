--!strict
-- A landform sampler (the user's reference charts, 2026-10-02): one 320 x 320 adaptive
-- heightfield of wedge-triangle Parts (cells 32 studs on flat ground down to 2 on the trail and
-- the lava, about 8,300 triangles) holding as many kinds of ground as fit, so slope-merging work
-- has a wide spread of slopes and triangle sizes to start from. X runs east, Z south.
--
--   z   0  mountains: two peaks and a saddle, a U-shaped glacier valley | volcano with a crater
--   z 100  alluvial fan | hills | terraced hill | sinkhole | plateau (cliffs, west ramp), canyon
--   z 200  basin and lake with an island | river | dunes | mesa | butte | sea cliff
--   z 290  coast: bay, cape, peninsula on an isthmus, islands; ocean to the south edge
--
-- Sea level is y 0: one Water block (an obstacle) fills everything below it, so the lake, the
-- river, the bay and the ocean can't be walked. Faces steeper than the adapter's MaxSlope (45
-- degrees) aren't walkable: cliffs, crater walls, canyon walls, the mountains' tops. An arch (a
-- walkable slab) spans the canyon; hoodoos (cylinders) stand on its floor.
-- Ordinary Parts too (the user: "overhangs and caves"): a cave into a hillside, with a walkable
-- roof; a high overhang off the plateau (walk under it) and a low tilted shelf (too low); 30
-- outcrops at random turns; a log across the river; sea stacks.
-- Triangles are coloured by slope: green (flat) through yellow and brown to grey (too steep).
-- Areas with costs (Filter): a trail (cheap), mud by the river, sand at the shore and on the
-- dunes, snow on the heights, scree on 35-45 degree slopes, and a lava flow nobody crosses.
-- Drops and jumps are generated (GenerateLinks); Studio draws them, the areas, and a draggable
-- Start and Goal (Studio.luau).
local Parts = require("../Parts")
local Terrain = require("../Terrain")

local SIZE, CELL, MIN_CELL = 320, 32, 2
-- Terrain.Adaptive's stitch; bench/adaptive_fan_repro.luau sets Fan to show the adapter's fold.
local STITCH = { Fan = false }
local N = SIZE // CELL

local function clamp01(v: number): number
	return math.clamp(v, 0, 1)
end
-- 0 below e0, 1 above e1, smooth between.
local function smooth(e0: number, e1: number, v: number): number
	local t = clamp01((v - e0) / (e1 - e0))
	return t * t * (3 - 2 * t)
end
local function dist(x: number, z: number, cx: number, cz: number): number
	return math.sqrt((x - cx) ^ 2 + (z - cz) ^ 2)
end
-- Distance from (x, z) to the polyline `pts` (flat {x, z} pairs), and the t (0..1) along it.
local function toLine(x: number, z: number, pts: { { number } }): (number, number)
	local best, bestT, total, along = math.huge, 0, 0, 0
	for i = 2, #pts do
		total += dist(pts[i][1], pts[i][2], pts[i - 1][1], pts[i - 1][2])
	end
	for i = 2, #pts do
		local ax, az, bx, bz = pts[i - 1][1], pts[i - 1][2], pts[i][1], pts[i][2]
		local dx, dz = bx - ax, bz - az
		local len = math.sqrt(dx * dx + dz * dz)
		local t = math.clamp(((x - ax) * dx + (z - az) * dz) / (len * len), 0, 1)
		local d = dist(x, z, ax + dx * t, az + dz * t)
		if d < best then
			best, bestT = d, (along + t * len) / total
		end
		along += len
	end
	return best, bestT
end

local GLACIER = { { 98, 30 }, { 96, 80 }, { 104, 130 } }
local RIVER = { { 104, 130 }, { 112, 165 }, { 96, 200 }, { 80, 225 }, { 66, 240 } }
local CANYON = { { 250, 100 }, { 262, 150 }, { 248, 200 }, { 258, 250 }, { 252, 300 } }
-- A trail (cheap to walk): from the fan to the log, and from the log up the ramp onto the plateau.
local TRAILS = {
	{ { 40, 120 }, { 62, 150 }, { 90, 150 } },
	{ { 130, 150 }, { 150, 168 }, { 200, 168 }, { 216, 160 } },
}
-- A lava flow down the volcano's south-west flank (excluded).
local LAVA = { { 256, 74 }, { 242, 92 }, { 226, 102 } }

local function dunesAt(x: number, z: number): number
	return smooth(118, 128, x) * (1 - smooth(176, 186, x)) * smooth(155, 165, z) * (1 - smooth(240, 250, z))
end
local function nearTrail(x: number, z: number): number
	local best = math.huge
	for _, trail in TRAILS do
		best = math.min(best, (toLine(x, z, trail)))
	end
	return best
end

-- The ground's height at (x, z), before the water.
local function height(x: number, z: number): number
	-- Plains: gently rolling, about 3 up.
	local h = 3 + 1.2 * math.sin(x / 23) * math.cos(z / 31)

	-- Hills (west) and the alluvial fan below the mountains.
	for _, b in { { 30, 150, 22, 9 }, { 70, 175, 18, 7 }, { 45, 195, 14, 5 }, { 85, 140, 12, 6 } } do
		h += b[4] * math.exp(-(dist(x, z, b[1], b[2]) / b[3]) ^ 2)
	end
	h += 9 * clamp01(1 - dist(x, z, 40, 95) / 40)

	-- Mountains: two sharp peaks, a saddle between, rocky ribs on their flanks.
	local peaks = 0
	for _, p in { { 58, 42, 58, 72 }, { 140, 34, 48, 56 } } do
		peaks = math.max(peaks, p[4] * clamp01(1 - dist(x, z, p[1], p[2]) / p[3]) ^ 1.3)
	end
	peaks += 26 * math.exp(-((z - 38) / 16) ^ 2) * smooth(30, 60, x) * (1 - smooth(130, 165, x)) -- the saddle
	local rocky = smooth(8, 25, peaks)
	h += peaks + rocky * 3 * math.abs(math.sin(x / 7 + z / 11))

	-- Glacier valley: a U-shaped trough down from between the peaks.
	local gd, gt = toLine(x, z, GLACIER)
	local floorY = 30 - 26 * gt
	if gd < 24 then
		local walls = 0.06 * gd * gd * (1 - smooth(0.7, 1, gt)) -- open at the mouth
		h = h + (floorY + walls - h) * (1 - smooth(18, 24, gd))
	end

	-- Volcano (north-east): a cone, a crater with steep walls.
	local vd = dist(x, z, 265, 58)
	h = math.max(h, 52 * clamp01(1 - vd / 62))
	if vd < 16 then
		h = math.min(h, 30 + 40 * smooth(9, 16, vd))
	end

	-- Sinkhole: a pit with near-vertical walls.
	local sd = dist(x, z, 176, 70)
	h -= 9 * (1 - smooth(6, 10, sd))

	-- Terraced hill: height in 3-stud bands, so flat shelves alternate with slopes.
	local td = dist(x, z, 172, 128)
	if td < 22 then
		local hill = 15 * clamp01(1 - td / 22)
		h = math.max(h, 3 + math.floor(hill / 3) * 3)
	end

	-- Plateau (east): 22 up, ringed by cliffs, with a ramp up its west side.
	local inside = smooth(186, 190, x) * (1 - smooth(312, 316, x)) * smooth(110, 114, z) * (1 - smooth(226, 230, z))
	local ramp = clamp01((x - 150) / 40) * (1 - smooth(12, 16, math.abs(z - 168))) * (1 - smooth(300, 304, x))
	h = math.max(h, 3 + 19 * math.max(inside, ramp))

	-- Canyon through the plateau and on to the sea: floor 2 up, walls near vertical.
	local cd = toLine(x, z, CANYON)
	h = h + (2 - h) * (1 - smooth(7, 11, cd))

	-- Dunes: asymmetric ridges, gentle to windward, steep to lee.
	local dunes = dunesAt(x, z)
	local phase = ((x + 6 * math.sin(z / 14)) % 18) / 18
	h += dunes * 5 * (if phase < 0.75 then phase / 0.75 else (1 - phase) / 0.25)

	-- Mesa and butte: flat tops, sheer sides.
	h = math.max(h, 3 + 16 * (1 - smooth(15, 18, dist(x, z, 212, 262))))
	h = math.max(h, 3 + 22 * (1 - smooth(6, 9, dist(x, z, 294, 262))))

	-- Basin and lake (south-west), an island in it.
	local ld = dist(x, z, 58, 252)
	h = h + (-5 - h) * (1 - smooth(22, 34, ld))
	h = math.max(h, 5 * (1 - smooth(4, 9, dist(x, z, 52, 250))) - 0.5)

	-- River: a channel below sea level from the glacier valley down to the lake.
	local rd = toLine(x, z, RIVER)
	h = h + (-2 - h) * (1 - smooth(4, 9, rd))

	-- Coast: the ocean in the south, with a bay, a cape, a peninsula on an isthmus, islands; the
	-- plateau's south side ends in a sea cliff.
	local coast = 286 + 8 * math.sin(x / 19)
	coast -= 26 * math.exp(-((x - 150) / 18) ^ 2) -- the bay
	coast += 18 * math.exp(-((x - 20) / 10) ^ 2) -- the cape
	local isthmus = math.exp(-((x - 100) / 10) ^ 2) * smooth(266, 276, z) * (1 - smooth(304, 308, z))
	local peninsula = 1 - smooth(10, 16, dist(x, z, 100, 310))
	local land = math.max(1 - smooth(coast - 4, coast + 4, z), isthmus, peninsula)
	local sea = if x > 190 and x < 316 then 1 - smooth(coast - 10, coast - 6, z) else 1
	h = h * land * sea + -8 * (1 - land * sea)
	for _, i in { { 200, 306, 6 }, { 228, 312, 5 }, { 246, 300, 4 }, { 170, 314, 7 } } do
		h = math.max(h, 4 * (1 - smooth(i[3] - 3, i[3], dist(x, z, i[1], i[2]))) - 1)
	end
	return h
end

-- Areas (NavArea on the triangles' Parts), costs in Filter. The Parts take each area's natural
-- colour; Studio draws the mesh in AREA_DRAW_COLORS (saturated, a legend in the corner).
local PART_COLORS = {
	Trail = { 225, 205, 160 },
	Lava = { 230, 70, 20 },
	Mud = { 95, 70, 45 },
	Sand = { 214, 196, 150 },
	Snow = { 235, 238, 242 },
	Scree = { 150, 140, 150 },
}
local AREA_DRAW_COLORS = {
	Trail = "#ffe14d",
	Lava = "#ff1f1f",
	Mud = "#8a4b14",
	Sand = "#ff9f0a",
	Snow = "#c77dff",
	Scree = "#6e6e6e",
}
local LINK_AREA = 20 -- no NavArea name gets this id
local AREA_COSTS = { Trail = 0.5, Mud = 4, Sand = 2, Snow = 3, Scree = 3, Lava = math.huge }

-- The area of a triangle centred at (x, y, z) with this slope, or nil for plain ground.
local function areaAt(x: number, y: number, z: number, slope: number): string?
	if slope >= 45 then
		return nil
	elseif (toLine(x, z, LAVA)) < 4 then
		return "Lava"
	elseif nearTrail(x, z) < 2.5 and slope < 30 then
		return "Trail"
	elseif y > 0 and y < 5 and (toLine(x, z, RIVER)) < 15 and slope < 30 then
		return "Mud"
	elseif (y < 1.2 or dunesAt(x, z) > 0.5) and slope < 30 then
		return "Sand"
	elseif y > 45 then
		return "Snow"
	elseif slope >= 35 then
		return "Scree"
	end
	return nil
end

-- An agent 1 stud round that pays the area costs.
local function HIGHLANDS_FILTER(areas: { [string]: number }): any
	local costs = {}
	for name, cost in AREA_COSTS do
		if areas[name] then
			costs[areas[name]] = cost
		end
	end
	return { AgentRadius = 1, AreaCosts = costs }
end

local function color(slope: number, y: number): { number }
	if slope < 5 then
		return { 92, 150, 72 }
	elseif slope < 15 then
		return { 140, 170, 80 }
	elseif slope < 30 then
		return { 190, 165, 90 }
	elseif slope < 45 then
		return { 150, 110, 70 }
	end
	return { 120, 118, 115 } -- too steep to walk
end

return {
	Name = "Highlands",
	MaxAgentRadius = 2,
	AdapterOptions = { MaxStepHeight = 1 },
	View = { From = { 160, 300, 470 }, To = { 160, 0, 150 } },
	Height = height,
	Stitch = STITCH,
	-- Studio loads the mesh baked in Lune (bake.luau): building it takes about a minute.
	Bake = true,
	AreaColors = AREA_DRAW_COLORS,
	-- Drops off ledges and jumps over gaps, generated; their area (LINK_AREA) turns them off.
	GenerateLinks = { Clearance = 1, Area = LINK_AREA },
	-- The filter the draggable Start and Goal use in Studio, and the "costs" scenarios.
	Filter = HIGHLANDS_FILTER,
	Build = function(rbx: any, parent: Instance?)
		local P = Parts(rbx, parent)
		local V3, CF = rbx.Vector3, rbx.CFrame
		local walkable, obstacles = {}, {}
		-- Fidelity varies: 32-stud cells on flat ground down to 4 on cliffs; 2 along the trail and
		-- on the lava; the mountains coarsest (a stud and a half of slack).
		local cache = {}
		local function cached(x: number, z: number): number
			local k = x * 4096 + z
			local y = cache[k]
			if y == nil then
				y = height(x, z)
				cache[k] = y
			end
			return y
		end
		local _, ground = Terrain.Adaptive(
			P,
			rbx,
			walkable,
			"H",
			0,
			0,
			CELL,
			N,
			N,
			MIN_CELL,
			cached,
			function(x, z, size)
				if nearTrail(x, z) < 6 or (toLine(x, z, LAVA)) < 6 then
					return 0.05
				elseif size <= 4 then
					return math.huge
				elseif z < 90 and x < 200 then
					return 1.5
				end
				return 0.5
			end,
			function(a, b, c, slope)
				if math.max(a.Y, b.Y, c.Y) < -0.5 then
					return nil -- under water all over: nobody walks it
				end
				local m = (a + b + c) / 3
				local area = areaAt(m.X, m.Y, m.Z, slope)
				return if area then PART_COLORS[area] else color(slope, m.Y), area
			end,
			STITCH.Fan
		)

		-- Sea level: one Water block under y 0 over the whole map.
		local water = P.box("Water", 0, 0, SIZE, SIZE, -12, 12, { 60, 110, 170 })
		water.Transparency = 0.35
		table.insert(obstacles, water)

		-- A natural arch over the canyon, flush with the plateau (top y 22), and hoodoos on its floor.
		table.insert(walkable, P.part("Part", "Arch", V3.new(44, 2, 6), CF.new(258, 21, 182), { 175, 120, 80 }))
		for k, hoodoo in { { 262, 136 }, { 255, 160 }, { 250, 214 }, { 256, 232 } } do
			local pillar = P.part(
				"Part",
				"Hoodoo",
				V3.new(10 + k * 2, 2.5, 2.5),
				CF.new(hoodoo[1], 2 + (10 + k * 2) / 2, hoodoo[2]) * CF.Angles(0, 0, math.pi / 2),
				{ 190, 120, 80 }
			)
			pillar.Shape = rbx.Enum.PartType.Cylinder
			table.insert(obstacles, pillar)
		end

		-- Ordinary Parts among the terrain (all walkable unless said): their tops add every tilt.
		local ROCK, DARK = { 128, 124, 118 }, { 96, 92, 88 }
		local function rock(name: string, size: any, cf: any, rgb: { number }?): BasePart
			local r = P.part("Part", name, size, cf, rgb or ROCK)
			table.insert(walkable, r)
			return r
		end

		-- Cave: dug into the glacier valley's side (the hill closes its west end), open to the east,
		-- 7 studs of headroom; its roof is walkable, reached by a wedge ramp on the south side.
		rock("Cave Wall", V3.new(30, 12, 5), CF.new(133, 4, 90.5), DARK)
		rock("Cave Wall", V3.new(30, 12, 5), CF.new(133, 4, 109.5), DARK)
		rock("Cave Roof", V3.new(30, 2, 24), CF.new(133, 11, 100))
		table.insert(
			obstacles,
			P.part("Part", "Rubble", V3.new(3, 2, 3), CF.new(139, 4, 98) * CF.Angles(0.3, 0.6, 0.2), DARK)
		)
		local foot = math.max(ground(128, 132), ground(138, 132)) + 0.1 -- a small step up all along
		local ramp = P.part(
			"WedgePart",
			"Cave Ramp",
			V3.new(10, 12 - foot, 20),
			CF.new(133, (12 + foot) / 2, 122) * CF.Angles(0, math.pi, 0),
			ROCK
		)
		table.insert(walkable, ramp)

		-- Overhangs. High: a slab out from the plateau's west cliff at the top, 17 studs over the
		-- ground (walk under it). Low: a tilted shelf 3.5 over the hills (too low to walk under:
		-- the ground beneath is cut).
		rock("Overhang", V3.new(20, 2, 16), CF.new(186, 21, 138))
		rock("Low Shelf", V3.new(14, 1.5, 10), CF.new(85, 7.5, 120) * CF.Angles(0, 0.4, math.rad(8)))

		-- Outcrops: rocks and slabs at random turns on the hills and the plain.
		local seed = 4245
		local function rnd(): number
			seed = seed * 16807 % 2147483647
			return seed / 2147483647
		end
		for k = 1, 30 do
			local x, z = 12 + rnd() * 120, 112 + rnd() * 90
			local size = V3.new(2 + rnd() * 8, 1 + rnd() * 5, 2 + rnd() * 8)
			local cf = CF.new(x, ground(x, z) + size.Y * 0.3, z)
				* CF.Angles((rnd() - 0.5) * 1.4, rnd() * math.pi * 2, (rnd() - 0.5) * 1.4)
			if k % 4 == 0 then
				table.insert(walkable, P.part("WedgePart", "Outcrop", size, cf, ROCK))
			else
				rock("Outcrop", size, cf)
			end
		end

		-- A fallen log across the river (a cylinder: its facets are its walkable faces), and sea
		-- stacks off the coast whose flat tops nobody can reach.
		-- It lies level (top 4.4) on a stone abutment at each end (tops 3.9), so every joint is a
		-- step the step-height rule joins. (Tilted, its higher end's disk leans out over the bank,
		-- and the rule drops that riser: known-gaps.md, "riser lean".)
		local log = P.part("Part", "Log", V3.new(24, 8, 8), CF.new(110, 0.4, 150), { 110, 80, 55 })
		for _, x in { 96, 124 } do
			local base = ground(x, 150) - 2
			rock("Abutment", V3.new(4, 3.9 - base, 9), CF.new(x, (3.9 + base) / 2, 150))
		end
		log.Shape = rbx.Enum.PartType.Cylinder
		table.insert(walkable, log)
		for _, stack in { { 140, 312, 14 }, { 268, 304, 18 }, { 300, 314, 11 } } do
			rock(
				"Sea Stack",
				V3.new(6, stack[3] + 8, 6),
				CF.new(stack[1], stack[3] / 2 - 4, stack[2]) * CF.Angles(0, stack[1], 0)
			)
		end

		local function at(x: number, z: number, lift: number?): any
			return V3.new(x, ground(x, z) + (lift or 0), z)
		end
		return {
			Walkable = walkable,
			Obstacles = obstacles,
			Points = {
				Plain = at(136, 144),
				LavaEast = at(252, 96),
				Saddle = at(104, 40),
				Peak = at(56, 40),
				FanFoot = at(40, 120),
				GlacierHead = at(98, 40),
				RampFoot = at(144, 168),
				PlateauTop = at(216, 160),
				PlateauEast = at(296, 160),
				CanyonFloor = at(256, 120),
				ArchWest = V3.new(232, 22, 182),
				ArchEast = V3.new(288, 22, 182),
				MesaTop = at(212, 262),
				CraterFloor = at(265, 58),
				VolcanoFoot = at(220, 100),
				SinkholeFloor = at(176, 70),
				TerraceTop = at(172, 128),
				DuneEast = at(176, 200),
				DuneWest = at(118, 200),
				LakeShore = at(58, 214),
				Island = at(52, 250),
				Peninsula = at(100, 310),
				Beach = at(100, 270),
				CaveBack = at(132, 100),
				CaveEast = at(153, 100),
				CaveRoof = V3.new(133, 12, 100),
				UnderOverhang = at(180, 138),
				OverhangTip = V3.new(178, 22, 138),
				LogWest = at(92, 150),
				LogEast = at(128, 150),
			},
		}
	end,
	Scenarios = {
		{
			Name = "up the west ramp onto the plateau",
			From = "Plain",
			To = "PlateauTop",
			Expect = { Status = "Success" },
		},
		{
			Name = "across the canyon by the arch",
			From = "ArchWest",
			To = "ArchEast",
			Expect = { Status = "Success", MaxStretch = 1.1 },
		},
		{
			Name = "walk under the high overhang",
			From = "Plain",
			To = "UnderOverhang",
			Expect = { Status = "Success" },
		},
		{ Name = "out on the overhang", From = "Plain", To = "OverhangTip", Expect = { Status = "Success" } },
		{
			Name = "into the cave",
			From = "CaveEast",
			To = "CaveBack",
			Expect = { Status = "Success", MaxStretch = 1.2 },
		},
		{ Name = "onto the cave roof by its ramp", From = "Plain", To = "CaveRoof", Expect = { Status = "Success" } },
		{ Name = "up the glacier valley", From = "Plain", To = "GlacierHead", Expect = { Status = "Success" } },
		{ Name = "over the saddle's foot", From = "Plain", To = "Saddle", Expect = { Status = "Success" } },
		{
			Name = "across the river on the log",
			From = "LogWest",
			To = "LogEast",
			Expect = { Status = "Success", MaxStretch = 1.3 },
		},
		{
			Name = "along the isthmus to the peninsula",
			From = "Beach",
			To = "Peninsula",
			Expect = { Status = "Success" },
		},
		{ Name = "over the dunes", From = "DuneWest", To = "DuneEast", Expect = { Status = "Success" } },
		{ Name = "down into the sinkhole", From = "Plain", To = "SinkholeFloor", Expect = { Status = "Success" } },
		{ Name = "the mesa's sheer sides: no way up", From = "Plain", To = "MesaTop", Expect = { Status = "Partial" } },
		{
			Name = "into the crater: a jump off the rim",
			From = "VolcanoFoot",
			To = "CraterFloor",
			Expect = { Status = "Success", Links = { "Jump" } },
		},
		{
			Name = "the crater, no links: no way in",
			From = "VolcanoFoot",
			To = "CraterFloor",
			Filter = { AreaCosts = { [LINK_AREA] = math.huge } },
			Expect = { Status = "Partial" },
		},
		{
			Name = "down into the canyon: jumps cut the walk",
			From = "PlateauTop",
			To = "CanyonFloor",
			Expect = { Status = "Success", MaxLength = 180 },
		},
		{
			Name = "the canyon, no links: the long way round",
			From = "PlateauTop",
			To = "CanyonFloor",
			Filter = { AreaCosts = { [LINK_AREA] = math.huge } },
			Expect = { Status = "Success", MinLength = 200 },
		},
		{
			Name = "round the lava (costs)",
			From = "VolcanoFoot",
			To = "LavaEast",
			Filter = HIGHLANDS_FILTER,
			Expect = { Status = "Success", Avoids = { "Lava" } },
		},
		{
			Name = "the lake island: water all round",
			From = "LakeShore",
			To = "Island",
			Expect = { Status = "Partial" },
		},
		{ Name = "the peak: no way up its faces", From = "Plain", To = "Peak", Expect = { Status = "Partial" } },
		-- Negative controls.
		{
			Name = "control: the mesa is not climbed",
			From = "Plain",
			To = "MesaTop",
			Expect = { Status = "Success" },
			MustFail = "Status",
		},
		{
			Name = "control: with no costs the lava is crossed",
			From = "VolcanoFoot",
			To = "LavaEast",
			Expect = { Status = "Success", Avoids = { "Lava" } },
			MustFail = "Avoids",
		},
		{
			Name = "control: the arch is not a detour",
			From = "ArchWest",
			To = "ArchEast",
			Expect = { MinLength = 80 },
			MustFail = "MinLength",
		},
	},
}
