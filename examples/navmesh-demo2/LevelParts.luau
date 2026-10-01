--!strict
-- The warehouse level as Parts, the only description of it: the bake (bake.luau, through
-- NavMeshAdapter), the Lune sim and the Studio scene all start here. `rbx` carries Instance,
-- Vector3, CFrame, Color3 and Enum, so Lune (`@lune/roblox`) builds it too.
--
-- 400 x 240 studs: a west hall, a middle hall under a mezzanine (two ramps up, four pillars) and
-- an east hall, split by two walls with three doorways each. Shelf rows in the side halls leave
-- 3.5-stud aisles (radius 1.5 fits, 2 does not).
--
-- Returns the walkable Parts, the static obstacle Parts, the doors and the crates. Doors and
-- crates are dynamic: they stay out of the bake and the game adds them with AddObstacle.

type Rbx = { Instance: any, Vector3: any, CFrame: any, Color3: any, Enum: any }

export type Crate = { Part: BasePart, From: Vector3, To: Vector3 } -- slides From <-> To

return function(rbx: Rbx, parent: Instance?): ({ BasePart }, { BasePart }, { BasePart }, { Crate })
	local V3, CF = rbx.Vector3, rbx.CFrame

	local function part(class: string, name: string, size: Vector3, cframe: CFrame, rgb: { number }): BasePart
		local p = rbx.Instance.new(class)
		p.Name = name
		p.Anchored = true
		p.Size = size
		p.CFrame = cframe
		p.Color = rbx.Color3.fromRGB(rgb[1], rgb[2], rgb[3])
		p.Parent = parent
		return p
	end
	-- A block standing on y = y0 over x0..x1, z0..z1.
	local function box(name: string, x0: number, z0: number, x1: number, z1: number, y0: number, h: number, rgb)
		return part("Part", name, V3.new(x1 - x0, h, z1 - z0), CF.new((x0 + x1) / 2, y0 + h / 2, (z0 + z1) / 2), rgb)
	end

	local floorRgb, deck, wallRgb, shelfRgb = { 70, 72, 78 }, { 196, 170, 120 }, { 120, 120, 135 }, { 60, 110, 170 }
	local walkable = {
		box("Ground", 0, 0, 400, 240, -1, 1, floorRgb),
		box("Mezzanine", 170, 90, 250, 150, 9, 1, deck),
		-- Wedges rise towards their +Z: RampW turned to rise towards +X, RampS as is.
		part("WedgePart", "RampW", V3.new(12, 10, 30), CF.new(155, 5, 116) * CF.Angles(0, math.pi / 2, 0), deck),
		part("WedgePart", "RampS", V3.new(12, 10, 30), CF.new(206, 5, 75), deck),
	}

	local obstacles = {}
	local gaps = { { 40, 48 }, { 116, 124 }, { 196, 204 } } -- doorways in both walls (z ranges)
	local doors = {}
	for _, x in { 130, 270 } do
		local z = 0
		for _, gap in gaps do
			table.insert(obstacles, box("Wall", x - 1, z, x + 1, gap[1], 0, 12, wallRgb))
			table.insert(doors, box("Door", x - 0.5, gap[1], x + 0.5, gap[2], 0, 10, { 200, 50, 40 }))
			z = gap[2]
		end
		table.insert(obstacles, box("Wall", x - 1, z, x + 1, 240, 0, 12, wallRgb))
	end
	-- Shelf rows, 4 deep with 3.5-stud aisles, split by a 6-stud cross aisle.
	for k = 0, 5 do
		local nz, ez = 150 + 7.5 * k, 40 + 7.5 * k
		table.insert(obstacles, box("Shelf", 20, nz, 60, nz + 4, 0, 7, shelfRgb))
		table.insert(obstacles, box("Shelf", 66, nz, 110, nz + 4, 0, 7, shelfRgb))
		table.insert(obstacles, box("Shelf", 290, ez, 330, ez + 4, 0, 7, shelfRgb))
		table.insert(obstacles, box("Shelf", 336, ez, 380, ez + 4, 0, 7, shelfRgb))
	end
	-- Pillars under the mezzanine: cylinders (axis along X), stood up.
	for _, at in { { 176, 96 }, { 244, 96 }, { 176, 144 }, { 244, 144 } } do
		table.insert(
			obstacles,
			part("Part", "Pillar", V3.new(9, 2, 2), CF.new(at[1], 4.5, at[2]) * CF.Angles(0, 0, math.pi / 2), wallRgb)
		)
		obstacles[#obstacles].Shape = rbx.Enum.PartType.Cylinder
	end

	local crates: { Crate } = {}
	local function crate(from: Vector3, to: Vector3, y0: number)
		local p = box("Crate", from.X - 2, from.Z - 2, from.X + 2, from.Z + 2, y0, 4, { 170, 115, 60 })
		table.insert(crates, { Part = p, From = from, To = to })
	end
	for _, z in { 20, 55, 180, 220 } do
		crate(V3.new(140, 0, z), V3.new(260, 0, z), 0) -- across the middle hall
	end
	crate(V3.new(40, 0, 20), V3.new(40, 0, 130), 0) -- west hall
	crate(V3.new(90, 0, 130), V3.new(90, 0, 20), 0)
	crate(V3.new(320, 0, 150), V3.new(320, 0, 230), 0) -- east hall
	crate(V3.new(180, 10, 130), V3.new(240, 10, 130), 10) -- on the mezzanine
	return walkable, obstacles, doors, crates
end
