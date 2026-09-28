--!strict
-- The demo level as Parts: the one source for both the Studio scene and, through
-- NavMeshAdapter, the NavMesh description (Level.luau is the same level hand-written as
-- polygons). `rbx` carries Instance, Vector3, CFrame and Color3, so Lune (`@lune/roblox`) can build it
-- too. Returns the walkable Parts, the solid obstacle Parts, and the door (a dynamic obstacle,
-- left out of the bake).

type Rbx = { Instance: any, Vector3: any, CFrame: any, Color3: any }

return function(rbx: Rbx, parent: Instance?): ({ BasePart }, { BasePart }, BasePart)
	local Vector3, CFrame = rbx.Vector3, rbx.CFrame

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

	-- A block standing on y = y0 over the box x0..x1, z0..z1.
	local function box(
		name: string,
		x0: number,
		z0: number,
		x1: number,
		z1: number,
		y0: number,
		h: number,
		rgb: { number }?
	): BasePart
		return part(
			"Part",
			name,
			Vector3.new(x1 - x0, h, z1 - z0),
			CFrame.new((x0 + x1) / 2, y0 + h / 2, (z0 + z1) / 2),
			rgb or { 45, 45, 50 }
		)
	end

	-- The ground in pieces around the mud, which fills the gap (one Part on top would z-fight).
	local grounds = {
		box("Ground", 0, 0, 60, 18, -1, 1),
		box("Ground", 0, 26, 60, 40, -1, 1),
		box("Ground", 30, 18, 60, 26, -1, 1),
	}
	local mud = box("Mud", 0, 18, 30, 26, -1, 1)
	mud.Color = rbx.Color3.fromRGB(110, 75, 40)
	mud:SetAttribute("NavArea", 2)
	-- Rises from y 0 at x 20 to y 6 at x 32 (a wedge rises towards its +Z, turned to face +X).
	local ramp = part(
		"WedgePart",
		"Ramp",
		Vector3.new(6, 6, 12),
		CFrame.new(26, 3, 37) * CFrame.Angles(0, math.pi / 2, 0),
		{ 200, 180, 140 }
	)
	local balcony = part("Part", "Balcony", Vector3.new(20, 0.4, 6), CFrame.new(42, 5.8, 37), { 200, 180, 140 })

	local crate, wall = { 160, 110, 60 }, { 90, 90, 100 }
	local obstacles = {
		box("Crate", 10, 6, 14, 10, 0, 3, crate), -- crate pair with a 2-stud gap between them
		box("Crate", 10, 12, 14, 16, 0, 3, crate),
		box("Crate", 24, 4, 28, 8, 0, 3, crate),
		box("Crate", 50, 8, 54, 12, 0, 3, crate), -- in the east room
		-- The east wall stops under the balcony, which runs over it.
		box("Wall", 40, 0, 41, 18, 0, 5.6, wall),
		box("Wall", 40, 22, 41, 40, 0, 5.6, wall),
	}
	local door = box("Door", 40, 18, 41, 22, 0, 5.6, { 200, 40, 40 })
	return { grounds[1], grounds[2], grounds[3], mud, ramp, balcony }, obstacles, door
end
