--!strict
-- Uneven terrain (ticket 37): a 200 x 160 outdoor map from Parts. X runs east, Z south.
-- - West meadow (x 0-90): a heightfield of 10-stud cells, each cell two triangles, each
--   triangle two thin WedgeParts (the usual Roblox triangle trick). Slopes up to `tilt`.
-- - River (x 90-110), along Z: 20-degree banks down to a channel that can't be walked (Water
--   blocks), a bridge (z 36-42) with a ramp at each end, and a shallow ford (z 110-125) whose
--   bed is area FORD.
-- - East forest (x 110-200): terraces of slabs hinged edge to edge along X, tilted up to `tilt`.
--   South of z 80 and east of x 160 the ground is raised 0.5 studs: steps, walkable by the
--   adapter's step-height rule (MaxStepHeight 1, ticket 34). Trees (upright cylinders) and rocks fill x 135-190, z 0-100,
--   leaving a 5-stud trail from the bridge east.
-- `WithTilt(degrees, seed?, options?)` builds the same layout at another tilt (or seed) (the sweep in
-- tools/navmesh/bench/terrain_sweep.luau); this module is the 5-degree map.
local Parts = require("../Parts")
local Terrain = require("../Terrain")

local FORD = 7
local BANK = math.rad(20)
local WATER_TOP = -1.5
local FORD_BED = -2
local STEP = 0.5

-- Park-Miller: the same numbers in Lune and Studio.
local function random(seed: number): () -> number
	local s = seed
	return function()
		s = s * 16807 % 2147483647
		return s / 2147483647
	end
end

-- The trail's centre line, bridge foot to the forest's east edge.
local TRAIL = { { 130, 39 }, { 150, 46 }, { 165, 31 }, { 180, 40 }, { 200, 36 } }

local function trailDistance(x: number, z: number): number
	local best = math.huge
	for i = 2, #TRAIL do
		local ax, az, bx, bz = TRAIL[i - 1][1], TRAIL[i - 1][2], TRAIL[i][1], TRAIL[i][2]
		local dx, dz = bx - ax, bz - az
		local t = math.clamp(((x - ax) * dx + (z - az) * dz) / (dx * dx + dz * dz), 0, 1)
		best = math.min(best, math.sqrt((x - ax - dx * t) ^ 2 + (z - az - dz * t) ^ 2))
	end
	return best
end

-- `options.LevelSouth`: the meadow's south edge (z 160) is level too, to meet a sidewalk (ticket 38).
local function make(tilt: number, seed: number?, options: { LevelSouth: boolean? }?)
	local seed0 = seed or 37
	local rise = 10 * math.tan(math.rad(tilt)) -- the most a 10-stud piece climbs

	-- The meadow's vertex heights (i, j: x = 10 i, z = 10 j): landforms, not noise. Two hills, a
	-- valley running diagonally, a ridge along the south edge and a gentle fall to the river; the
	-- ground between them is close to flat. The seed moves and sizes each one. Everything fades
	-- to 0 at the river edge and on the pad under the west ramp, so the bank and the ramp's foot
	-- meet level ground. Then the heights are scaled so the steepest triangle is `tilt` degrees.
	local function meadow(): { { number } }
		local r = random(seed0)
		local function jitter(v: number, by: number): number
			return v + (r() * 2 - 1) * by
		end
		local bump = function(x: number, z: number, cx: number, cz: number, radius: number): number
			return math.exp(-((x - cx) ^ 2 + (z - cz) ^ 2) / (radius * radius))
		end
		local hill1 = { jitter(25, 8), jitter(35, 8), jitter(22, 4), jitter(1, 0.3) }
		local hill2 = { jitter(50, 8), jitter(125, 8), jitter(13, 3), jitter(0.7, 0.2) }
		local valley = { jitter(0, 5), jitter(70, 8), jitter(60, 5), jitter(100, 8), jitter(0.8, 0.2) }
		local function shape(x: number, z: number): number
			-- distance from the valley's line, in plan
			local ax, az, bx, bz = valley[1], valley[2], valley[3], valley[4]
			local dx, dz = bx - ax, bz - az
			local t = math.clamp(((x - ax) * dx + (z - az) * dz) / (dx * dx + dz * dz), 0, 1)
			local d = math.sqrt((x - ax - dx * t) ^ 2 + (z - az - dz * t) ^ 2)
			local y = hill1[4] * bump(x, z, hill1[1], hill1[2], hill1[3])
				+ hill2[4] * bump(x, z, hill2[1], hill2[2], hill2[3])
				- valley[5] * math.exp(-(d * d) / 100)
				+ 0.6 * math.exp(-((z - 155) ^ 2) / 40) * math.clamp((45 - x) / 20, 0, 1) -- ridge
				+ 0.3 * (90 - x) / 90 -- the fall to the river
			local edge = math.clamp((90 - x) / 20, 0, 1) -- level at the river
			local pad = math.clamp(math.max(60 - x, z - 50, 30 - z) / 10, 0, 1) -- level on the pad
			local south = if options and options.LevelSouth then math.clamp((160 - z) / 20, 0, 1) else 1
			return y * edge * pad * south
		end
		local h = {}
		for i = 0, 9 do
			h[i] = {}
			for j = 0, 16 do
				h[i][j] = shape(10 * i, 10 * j)
			end
		end
		-- The steepest triangle's rise over 10 studs (its plane's gradient), to scale by.
		local steepest = 0
		for i = 0, 8 do
			for j = 0, 15 do
				local a, b, c, d = h[i][j], h[i + 1][j], h[i + 1][j + 1], h[i][j + 1]
				steepest =
					math.max(steepest, math.sqrt((b - a) ^ 2 + (c - b) ^ 2), math.sqrt((c - d) ^ 2 + (d - a) ^ 2))
			end
		end
		local scale = if steepest > 0 then 10 * math.tan(math.rad(tilt)) / steepest else 0
		for i = 0, 9 do
			for j = 0, 16 do
				h[i][j] *= scale
			end
		end
		return h
	end

	-- The forest's profile: heights at x = 110, 140, 150, ..., 200. The first piece is flat at 0,
	-- with the east ramp's foot inside it; then a walk that stays within 2 studs of 0.
	local function profile(): ({ number }, { number })
		local r, xs, ys = random(seed0 + 1), { 110, 140 }, { 0, 0 }
		for x = 150, 200, 10 do
			local y = ys[#ys] + (r() * 2 - 1) * rise
			if math.abs(y) > 2 then
				y = ys[#ys] - (y - ys[#ys])
			end
			table.insert(xs, x)
			table.insert(ys, y)
		end
		return xs, ys
	end
	local xs, ys = profile()

	-- The forest ground's height at (x, z), raised past the steps.
	local function forestY(x: number, z: number): number
		for k = 2, #xs do
			if x <= xs[k] then
				local y = ys[k - 1] + (ys[k] - ys[k - 1]) * (x - xs[k - 1]) / (xs[k] - xs[k - 1])
				return y + if x > 160 and z > 80 then STEP else 0
			end
		end
		return ys[#ys]
	end

	local function build(rbx: any, parent: Instance?)
		local P = Parts(rbx, parent)
		local V3, CF = rbx.Vector3, rbx.CFrame
		local walkable, obstacles = {}, {}

		-- A slab whose top runs from (x0, y0) to (x1, y1) along X, over z0..z1, 1 thick.
		local function hinged(name: string, x0: number, y0: number, x1: number, y1: number, z0: number, z1: number, rgb)
			local dx, dy = x1 - x0, y1 - y0
			local len = math.sqrt(dx * dx + dy * dy)
			local nx, ny = -dy / len, dx / len -- the top's normal; the slab hangs below it
			local cf = CF.new((x0 + x1) / 2 - nx / 2, (y0 + y1) / 2 - ny / 2, (z0 + z1) / 2)
				* CF.Angles(0, 0, math.atan2(dy, dx))
			table.insert(walkable, P.part("Part", name, V3.new(len, 1, z1 - z0), cf, rgb))
		end

		-- West meadow.
		local h = meadow()
		Terrain.Heightfield(P, rbx, walkable, "Meadow", 0, 0, 10, 9, 16, function(i, j)
			return h[i][j]
		end, function(i, j)
			return { 86 + (i * 7 + j * 3) % 12, 125 + (i * 5 + j * 11) % 14, 70 }
		end)

		-- The river: banks down to the channel's floor at -3, water over it but the ford.
		local run = 3 / math.tan(BANK)
		hinged("WestBank", 90, 0, 90 + run, -3, 0, 160, { 120, 105, 80 })
		hinged("EastBank", 110 - run, -3, 110, 0, 0, 160, { 120, 105, 80 })
		for _, zs in { { 0, 110 }, { 125, 160 } } do
			local water = P.box("Water", 90, zs[1], 110, zs[2], WATER_TOP - 2, 2, { 60, 110, 170 })
			water.Transparency = 0.3
			table.insert(obstacles, water)
		end
		local bedX = -FORD_BED / math.tan(BANK) -- where each bank reaches the ford's bed
		local ford = P.slab("Ford", 90 + bedX, 110, 110 - bedX, 125, FORD_BED, { 150, 140, 110 })
		ford:SetAttribute("NavArea", FORD)
		table.insert(walkable, ford)

		-- The bridge: a deck 2.5 up from x 80 to 120, a 10-stud ramp at each end.
		table.insert(walkable, P.slab("Bridge", 80, 36, 120, 42, 2.5, { 110, 80, 55 }))
		local brown = rbx.Color3.fromRGB(110, 80, 55)
		for _, ramp in { { "WestRamp", 75, math.pi / 2 }, { "EastRamp", 125, -math.pi / 2 } } do
			local w = P.part(
				"WedgePart",
				ramp[1],
				V3.new(6, 2.5, 10),
				CF.new(ramp[2], 1.25, 39) * CF.Angles(0, ramp[3], 0),
				{}
			)
			w.Color = brown
			table.insert(walkable, w)
		end

		-- East forest: terraces, the south-east part raised by a step.
		for k = 2, #xs do
			local tone = { 70 + k * 4, 95 + k * 3, 60 }
			if xs[k] <= 160 then
				hinged(`Forest{k}`, xs[k - 1], ys[k - 1], xs[k], ys[k], 0, 160, tone)
			else
				hinged(`Forest{k}`, xs[k - 1], ys[k - 1], xs[k], ys[k], 0, 80, tone)
				local x0, y0 = xs[k - 1], ys[k - 1] + STEP
				if x0 == 160 then
					-- A slab tilted down from the step leans its end face out over the lower strip,
					-- and the step-height rule reads that as a cut in the riser's band: start the
					-- slab past its own lean (1 thick, the slope's sine) plus a hundredth.
					local dx, dy = xs[k] - x0, ys[k] - ys[k - 1]
					local lean = math.max(0, -dy / math.sqrt(dx * dx + dy * dy)) + 0.01
					x0, y0 = x0 + lean, y0 + dy * lean / dx
				end
				hinged(`Plateau{k}`, x0, y0, xs[k], ys[k] + STEP, 80, 160, tone)
			end
		end

		-- Trees: dart throwing, at least 2 studs between trunks, none on the trail.
		local r = random(seed0 + 2)
		local trees = {}
		for _ = 1, 6000 do
			local x, z, radius = 135 + r() * 55, r() * 100, 0.6 + r() * 1.4
			local ok = trailDistance(x, z) > 2.5 + radius
			for _, t in trees do
				ok = ok and math.sqrt((x - t[1]) ^ 2 + (z - t[2]) ^ 2) - radius - t[3] >= 2
				if not ok then
					break
				end
			end
			if ok then
				table.insert(trees, { x, z, radius })
				local y = forestY(x, z)
				local trunk = P.part(
					"Part",
					"Tree",
					V3.new(14, radius * 2, radius * 2),
					CF.new(x, y + 5, z) * CF.Angles(0, 0, math.pi / 2),
					{ 95, 70, 45 }
				)
				trunk.Shape = rbx.Enum.PartType.Cylinder
				table.insert(obstacles, trunk)
			end
		end

		-- Rocks: turned blocks and wedges, half sunk, in the meadow and the forest's edge.
		for k = 1, 30 do
			local x, z = if k <= 10 then 5 + r() * 60 else 112 + r() * 22, r() * 160
			if k > 10 and math.abs(z - 39) < 6 then
				z += 12 -- keep the east ramp's foot clear
			end
			local s = V3.new(2 + r() * 3, 1.5 + r() * 2, 2 + r() * 3)
			local y = if k <= 10 then 0 else forestY(x, z)
			local cf = CF.new(x, y + s.Y * 0.25, z) * CF.Angles(r() * 0.3, r() * math.pi, r() * 0.3)
			table.insert(
				obstacles,
				P.part(if k % 3 == 0 then "WedgePart" else "Part", "Rock", s, cf, { 128, 128, 124 })
			)
		end

		local function at(x: number, z: number): any
			return V3.new(x, if x >= 110 then forestY(x, z) else 0, z)
		end
		return {
			Walkable = walkable,
			Obstacles = obstacles,
			Points = {
				MeadowWest = at(5, 80),
				MeadowFord = at(60, 118),
				EastFord = at(125, 118),
				BridgeEast = at(132, 39),
				ForestEast = at(196, 60),
				Plateau = at(180, 130),
				River = V3.new(100, WATER_TOP, 60),
			},
		}
	end

	return {
		Name = "ForestRiver",
		Build = build,
		AdapterOptions = { MaxStepHeight = 1 },
		View = { From = { 100, 190, 230 }, To = { 100, 0, 75 } },
		Scenarios = {
			{
				Name = "forest, radius 0.5",
				From = "BridgeEast",
				To = "ForestEast",
				Filter = { AgentRadius = 0.5 },
				Expect = { Status = "Success", MaxStretch = 1.25 },
			},
			{
				-- Tree gaps are under 4 studs off the trail: the trail, or round the forest.
				Name = "forest, radius 2",
				From = "BridgeEast",
				To = "ForestEast",
				Filter = { AgentRadius = 2 },
				Expect = { Status = "Success", MinLength = 72 },
			},
			{
				Name = "bridge when the ford is costly",
				From = "MeadowFord",
				To = "EastFord",
				Filter = { AgentRadius = 1, AreaCosts = { [FORD] = 50 } },
				Expect = { Status = "Success", Visits = { "Bridge" }, Avoids = { FORD }, MinLength = 150 },
			},
			{
				Name = "ford when it is cheap",
				From = "MeadowFord",
				To = "EastFord",
				Filter = { AgentRadius = 1, AreaCosts = { [FORD] = 1 } },
				Expect = { Status = "Success", Visits = { "Ford" }, MaxLength = 75 },
			},
			{
				Name = "west to east, radius 1",
				From = "MeadowWest",
				To = "ForestEast",
				Filter = { AgentRadius = 1 },
				Expect = { Status = "Success" },
			},
			{
				Name = "no goal in the water",
				From = "MeadowFord",
				To = "River",
				Expect = { Status = "NoGoal" },
			},
			{
				Name = "up the 0.5-stud steps onto the plateau",
				From = "EastFord",
				To = "Plateau",
				Filter = { AgentRadius = 1 },
				Expect = { Status = "Success", MaxStretch = 1.3 },
			},
			-- Negative controls.
			{
				Name = "control: ford walked at cost 1",
				From = "MeadowFord",
				To = "EastFord",
				Filter = { AgentRadius = 1, AreaCosts = { [FORD] = 1 } },
				Expect = { Avoids = { FORD } },
				MustFail = "Avoids",
			},
			{
				Name = "control: the costly ford's route crosses the ford",
				From = "MeadowFord",
				To = "EastFord",
				Filter = { AgentRadius = 1, AreaCosts = { [FORD] = 50 } },
				Expect = { Visits = { "Ford" } },
				MustFail = "Visits",
			},
			{
				Name = "control: radius 2 as short as 0.5",
				From = "BridgeEast",
				To = "ForestEast",
				Filter = { AgentRadius = 2 },
				Expect = { MaxLength = 68 },
				MustFail = "MaxLength",
			},
		},
	}
end

local map: any = make(5)
map.WithTilt = make
map.Ford = FORD
return map
