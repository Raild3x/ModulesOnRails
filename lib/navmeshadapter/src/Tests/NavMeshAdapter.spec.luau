-- Authors: Logan Hunt (Raildex)
-- September 28, 2026
-- Parts to NavMeshDesc (ticket 26): floors from walkable faces, cuts from solids, seams at ramp
-- feet and tops, areas, crack welding (D3). Parts come from `@lune/roblox`: the adapter reads
-- only Shape, Size, CFrame, Name and attributes, which Lune models exactly.

return function(t: tiniest)
	local roblox = require("@lune/roblox") :: any
	local NavMesh = require("../../NavMesh")
	local NavMeshAdapter = require("../NavMeshAdapter")

	local describe = t.describe
	local expect = t.expect
	local test = t.test

	local CFrame, Vector3, Enum = roblox.CFrame, roblox.Vector3, roblox.Enum
	-- Not spelled as the datamodel global: the coverage tool's pipeline classifier would send this
	-- Lune-only suite to Studio.
	local newInstance = (roblox.Instance :: any).new

	local function part(class: string, name: string, size: { number }, cframe: any): any
		local p = newInstance(class)
		p.Name = name
		p.Size = Vector3.new(size[1], size[2], size[3])
		p.CFrame = cframe
		return p
	end

	-- A block standing on y = y0 over the box x0..x1, z0..z1, h tall.
	local function box(name: string, x0: number, z0: number, x1: number, z1: number, y0: number, h: number): any
		return part("Part", name, { x1 - x0, h, z1 - z0 }, CFrame.new((x0 + x1) / 2, y0 + h / 2, (z0 + z1) / 2))
	end

	-- A 1-stud slab whose top is at y over the box.
	local function slab(name: string, x0: number, z0: number, x1: number, z1: number, y: number): any
		return box(name, x0, z0, x1, z1, y - 1, 1)
	end

	-- Rises from y 0 at x0 to y h at x0 + run, over z0..z1.
	local function ramp(name: string, x0: number, run: number, h: number, z0: number, z1: number): any
		return part(
			"WedgePart",
			name,
			{ z1 - z0, h, run },
			CFrame.new(x0 + run / 2, h / 2, (z0 + z1) / 2) * CFrame.Angles(0, math.pi / 2, 0)
		)
	end

	local function bounds(ring: { vector }): (vector, vector)
		local lo, hi = vector.one * math.huge, vector.one * -math.huge
		for _, p in ring do
			lo, hi = vector.min(lo, p), vector.max(hi, p)
		end
		return lo, hi
	end

	local function near(a: vector, b: vector): boolean
		return vector.magnitude(a - b) < 1e-4
	end

	-- Turns the Parts about the world's Y axis, as if the whole scene were built at an angle.
	local function turn(parts: { any }, degrees: number): { any }
		for _, p in parts do
			p.CFrame = CFrame.Angles(0, math.rad(degrees), 0) * p.CFrame
		end
		return parts
	end

	local function turned(x: number, y: number, z: number, degrees: number): any
		local p = (CFrame.Angles(0, math.rad(degrees), 0) * CFrame.new(x, y, z)).Position
		return vector.create(p.X, p.Y, p.Z)
	end

	local function area(ring: { vector }): number
		local sum = 0
		for i, a in ring do
			local b = ring[i % #ring + 1]
			sum += a.x * b.z - b.x * a.z
		end
		return sum / 2
	end

	local function sortedNames(desc: any): string
		local names = {}
		for name in desc.Floors do
			table.insert(names, name)
		end
		table.sort(names)
		return table.concat(names, ",")
	end

	describe("floors", function()
		test("a block's top face is one floor, named after the Part", function()
			local desc: any = NavMeshAdapter.FromParts({ slab("Ground", 0, 0, 10, 8, 0) }, {})
			expect(sortedNames(desc)).is("Ground")
			local rings = desc.Floors.Ground.Walkable
			expect(#rings).is(1)
			expect(#rings[1]).is(4)
			local lo, hi = bounds(rings[1])
			expect(near(lo, vector.create(0, 0, 0)) and near(hi, vector.create(10, 0, 8))).is_true()
			expect(desc.Floors.Ground.Obstacles).never_exists()
			expect(desc.Floors.Ground.Areas).never_exists()
			expect(#desc.Seams).is(0)
		end)

		test("coplanar faces from several Parts share a floor; another plane gets its own name", function()
			local desc: any = NavMeshAdapter.FromParts({
				slab("Step", 0, 0, 4, 4, 0),
				slab("Step", 10, 0, 14, 4, 2),
				slab("Pad", 20, 0, 24, 4, 0),
				slab("Step", 30, 0, 34, 4, 4),
				slab("Pad", 40, 0, 44, 4, 2),
			}, {})
			expect(sortedNames(desc)).is("Step,Step 2,Step 3")
			expect(#desc.Floors.Step.Walkable).is(2)
			expect(#desc.Floors["Step 2"].Walkable).is(2)
			expect(desc.Floors["Step 2"].Walkable[1][1].y).is(2)
			expect(desc.Floors["Step 3"].Walkable[1][1].y).is(4)
		end)

		test("a turned block's floor turns with it", function()
			local p = part("Part", "Deck", { 8, 1, 4 }, CFrame.new(5, 2.5, 5) * CFrame.Angles(0, math.rad(30), 0))
			local desc: any = NavMeshAdapter.FromParts({ p }, {})
			local ring = desc.Floors.Deck.Walkable[1]
			local corner = p.CFrame:PointToWorldSpace(Vector3.new(4, 0.5, 2))
			local found = false
			for _, q in ring do
				found = found or near(q, vector.create(corner.X, corner.Y, corner.Z))
			end
			expect(found).is_true()
			for _, q in ring do
				expect(q.y).is(3)
			end
		end)

		test("an upright cylinder's top is a CylinderSides-gon of its radius", function()
			local p = part("Part", "Pillar", { 2, 6, 6 }, CFrame.new(0, 1, 0) * CFrame.Angles(0, 0, math.pi / 2))
			p.Shape = Enum.PartType.Cylinder
			local sixteen: any = NavMeshAdapter.FromParts({ p }, {})
			expect(#sixteen.Floors.Pillar.Walkable).is(1)
			expect(#sixteen.Floors.Pillar.Walkable[1]).is(16)
			for _, q in sixteen.Floors.Pillar.Walkable[1] do
				expect(math.abs(vector.magnitude(vector.create(q.x, 0, q.z)) - 3) < 1e-4).is_true()
				expect(math.abs(q.y - 2) < 1e-4).is_true()
			end
			local eight: any = NavMeshAdapter.FromParts({ p }, {}, { CylinderSides = 8 })
			expect(#eight.Floors.Pillar.Walkable[1]).is(8)
		end)

		test("a face steeper than MaxSlope is not walkable", function()
			local steep = ramp("Steep", 0, 2, 4, 0, 4) -- 63 degrees
			expect(sortedNames(NavMeshAdapter.FromParts({ steep }, {}))).is("")
			expect(sortedNames(NavMeshAdapter.FromParts({ steep }, {}, { MaxSlope = 70 }))).is("Steep")
		end)

		test("NavArea marks a Part's faces as an area of its floor", function()
			-- A thin Part whose top lands a few millionths off the ground (f32): still the same floor.
			local mud = part("Part", "Mud", { 4, 0.2, 4 }, CFrame.new(4, -0.1, 4))
			mud:SetAttribute("NavArea", 3)
			local desc: any = NavMeshAdapter.FromParts({ slab("Ground", 0, 0, 10, 10, 0), mud }, {})
			expect(sortedNames(desc)).is("Ground")
			local areas = desc.Floors.Ground.Areas
			expect(#areas).is(1)
			expect(areas[1].Area).is(3)
			local lo, hi = bounds(areas[1].Polygon)
			expect(near(lo, vector.create(2, 0, 2)) and near(hi, vector.create(6, 0, 6))).is_true()
		end)

		test("floor rings run counter-clockwise: upside-down Parts, tiny faces", function()
			local flipped = part("Part", "Deck", { 4, 1, 4 }, CFrame.new(0, 0, 0) * CFrame.Angles(math.pi, 0, 0))
			local tiny = part("Part", "Tiny", { 0.5, 1, 0.5 }, CFrame.new(10, 3, 0)) -- upright, under 1 square stud
			local desc: any = NavMeshAdapter.FromParts({ flipped, tiny }, {})
			expect(area(desc.Floors.Deck.Walkable[1]) > 0).is_true()
			expect(area(desc.Floors.Tiny.Walkable[1]) > 0).is_true()
		end)

		test("an unsupported shape errors, naming the Part", function()
			local ball = part("Part", "Boulder", { 4, 4, 4 }, CFrame.new())
			ball.Shape = Enum.PartType.Ball
			local ok, message = pcall(NavMeshAdapter.FromParts, {}, { ball })
			expect(ok).is(false)
			expect(string.find(tostring(message), "Boulder", 1, true) ~= nil).is_true()
			expect(string.find(tostring(message), "Ball", 1, true) ~= nil).is_true()
		end)
	end)

	describe("cuts", function()
		test("a crate cuts its footprint; a deck above AgentHeight does not", function()
			local ground = slab("Ground", 0, 0, 20, 20, 0)
			local crate = box("Crate", 2, 2, 6, 5, 0, 3)
			local deck = box("Deck", 10, 10, 16, 16, 5.5, 0.5)
			local desc: any = NavMeshAdapter.FromParts({ ground }, { crate, deck })
			local cuts = desc.Floors.Ground.Obstacles
			expect(#cuts).is(1)
			local lo, hi = bounds(cuts[1])
			expect(near(lo, vector.create(2, 0, 2)) and near(hi, vector.create(6, 0, 5))).is_true()
			local taller: any = NavMeshAdapter.FromParts({ ground }, { crate, deck }, { AgentHeight = 6 })
			expect(#taller.Floors.Ground.Obstacles).is(2)
		end)

		test("a deck exactly AgentHeight up does not cut: the agent fits under it", function()
			local desc: any = NavMeshAdapter.FromParts(
				{ slab("Ground", 0, 0, 20, 20, 0) },
				{ box("Deck", 10, 10, 16, 16, 5, 0.5) }
			)
			expect(desc.Floors.Ground.Obstacles).never_exists()
		end)

		test("a turned crate taller than AgentHeight cuts exactly its turned footprint", function()
			local crate = part("Part", "Crate", { 4, 10, 2 }, CFrame.new(10, 5, 10) * CFrame.Angles(0, math.rad(45), 0))
			local desc: any = NavMeshAdapter.FromParts({ slab("Ground", 0, 0, 20, 20, 0) }, { crate })
			local ring = desc.Floors.Ground.Obstacles[1]
			expect(#ring).is(4)
			expect(math.abs(area(ring) - 8) < 1e-3).is_true()
		end)

		test("a wedge sunk into the floor cuts only where it stands above it", function()
			-- Rises from y -3 at x 0 to y 3 at x 12: above the ground from x 6 on.
			local sunk = part("WedgePart", "Bank", { 4, 6, 12 }, CFrame.new(6, 0, 2) * CFrame.Angles(0, math.pi / 2, 0))
			local desc: any = NavMeshAdapter.FromParts({ slab("Ground", 0, 0, 20, 20, 0) }, { sunk })
			local lo, hi = bounds(desc.Floors.Ground.Obstacles[1])
			expect(near(lo, vector.create(6, 0, 0)) and near(hi, vector.create(12, 0, 4))).is_true()
		end)

		test("a plate with no thickness leaves no degenerate ring", function()
			local plate = part("Part", "Sign", { 4, 3, 0 }, CFrame.new(10, 1.5, 10))
			local desc: any = NavMeshAdapter.FromParts({ slab("Ground", 0, 0, 20, 20, 0) }, { plate })
			expect(desc.Floors.Ground.Obstacles).never_exists()
		end)

		test("the floor's own Parts and Parts below it do not cut it", function()
			local desc: any = NavMeshAdapter.FromParts(
				{ slab("Ground", 0, 0, 10, 10, 0), slab("Ground", 10, 0, 20, 10, 0) },
				{ box("Pipe", 0, 4, 20, 6, -3, 2) }
			)
			expect(desc.Floors.Ground.Obstacles).never_exists()
		end)

		test("a lying cylinder is an obstacle with its outline as the footprint", function()
			local log = part("Part", "Log", { 8, 2, 2 }, CFrame.new(10, 1, 10))
			log.Shape = Enum.PartType.Cylinder
			local desc: any = NavMeshAdapter.FromParts({ slab("Ground", 0, 0, 20, 20, 0) }, { log })
			local lo, hi = bounds(desc.Floors.Ground.Obstacles[1])
			expect(near(lo, vector.create(6, 0, 9)) and near(hi, vector.create(14, 0, 11))).is_true()
		end)

		test("a Part off the floor's faces does not cut it, though it crosses the floor's plane", function()
			-- The ramp's plane runs on through every tower, off the ramp in +X, -X, -Z and +Z.
			local desc: any = NavMeshAdapter.FromParts({ ramp("Ramp", 20, 12, 6, 0, 6) }, {
				box("Tower", 98, 0, 102, 4, 0, 60),
				box("Tower", 4, 0, 8, 4, -20, 80),
				box("Tower", 24, -10, 28, -6, -20, 80),
				box("Tower", 24, 12, 28, 16, -20, 80),
			})
			expect(desc.Floors.Ramp.Obstacles).never_exists()
		end)
	end)

	describe("ramps and seams", function()
		test("a wedge ramp: sloped floor, a seam at its foot and top, the ground under it cut", function()
			local desc: any = NavMeshAdapter.FromParts({
				slab("Ground", 0, 0, 40, 20, 0),
				ramp("Ramp", 10, 12, 6, 14, 20),
				slab("Landing", 22, 14, 32, 20, 6),
			}, {})
			expect(sortedNames(desc)).is("Ground,Landing,Ramp")
			local lo, hi = bounds(desc.Floors.Ground.Obstacles[1])
			expect(near(lo, vector.create(10, 0, 14)) and near(hi, vector.create(22, 0, 20))).is_true()
			expect(desc.Floors.Landing.Obstacles).never_exists()
			expect(desc.Floors.Ramp.Obstacles).never_exists()
			expect(#desc.Seams).is(2)
			local feet = {}
			for _, seam in desc.Seams do
				local pair = { seam.FloorA, seam.FloorB }
				table.sort(pair)
				feet[table.concat(pair, "-")] = seam
			end
			local foot, top = feet["Ground-Ramp"], feet["Landing-Ramp"]
			expect(foot.From.x).is(10)
			expect(foot.To.x).is(10)
			expect(math.abs(foot.From.z - foot.To.z)).is(6)
			expect(top.From.x).is(22)
			expect(top.From.y).is(6)

			desc.MaxAgentRadius = 1
			local mesh = NavMesh.Build(desc)
			local path = NavMesh.FindPath(mesh, vector.create(2, 0, 2) :: any, vector.create(30, 6, 17) :: any)
			expect(path.Status).is("Success")
			expect(path.Waypoints[#path.Waypoints].Floor).is("Landing") -- over the seams (no waypoint on the ramp)
		end)

		test("a turned ramp scene gets the same seams", function()
			local desc: any = NavMeshAdapter.FromParts(
				turn({
					slab("Ground", 0, 0, 40, 20, 0),
					ramp("Ramp", 10, 12, 6, 14, 20),
					slab("Landing", 22, 14, 32, 20, 6),
				}, 30),
				{}
			)
			expect(#desc.Seams).is(2)
			for _, seam in desc.Seams do
				expect(math.abs(vector.magnitude(seam.From - seam.To) - 6) < 1e-3).is_true()
			end
			desc.MaxAgentRadius = 1
			local path = NavMesh.FindPath(NavMesh.Build(desc), turned(2, 0, 2, 30), turned(30, 6, 17, 30))
			expect(path.Status).is("Success")
		end)

		test("a ramp along Z, onto an upside-down landing, from ground in overlapping pieces", function()
			local desc: any = NavMeshAdapter.FromParts({
				slab("Ground", 0, 0, 20, 10, 0),
				slab("Ground", 0, 5, 12, 10, 0), -- a second piece under the ramp's foot
				slab("Ground", 0, 100, 10, 140, 0), -- on the foot's plane, nowhere near it
				slab("Ground", 100, 0, 110, 40, 0),
				part("WedgePart", "Ramp", { 6, 6, 12 }, CFrame.new(5, 3, 16)), -- rises towards +Z
				part("WedgePart", "Ramp", { 6, 6, 12 }, CFrame.new(15, 3, 16)), -- a second one, no landing
				part("Part", "Landing", { 6, 1, 6 }, CFrame.new(5, 5.5, 25) * CFrame.Angles(math.pi, 0, 0)),
			}, {})
			expect(#desc.Seams).is(3) -- two feet, one top
			for _, seam in desc.Seams do
				expect(math.abs(vector.magnitude(seam.From - seam.To) - 6) < 1e-3).is_true()
			end
			expect(math.abs(desc.Floors.Ramp.Walkable[1][1].y - (desc.Floors.Ramp.Walkable[1][1].z - 10) / 2) < 1e-4).is_true()
		end)

		test("a seam covers only where both floors meet", function()
			local desc: any = NavMeshAdapter.FromParts({
				ramp("Ramp", 0, 12, 6, 0, 6),
				slab("Landing", 12, 3, 20, 9, 6), -- half past the ramp's side: each clips the other
			}, {})
			expect(#desc.Seams).is(1)
			local seam = desc.Seams[1]
			expect(math.min(seam.From.z, seam.To.z)).is(3)
			expect(math.max(seam.From.z, seam.To.z)).is(6)
		end)
	end)

	describe("welding (D3)", function()
		-- Two floor Parts meant to touch, 0.02 apart: the crack is a wall unless welded.
		local function cracked(options: any?, degrees: number?): NavMesh.PathResult
			local angle = degrees or 0
			local desc: any = NavMeshAdapter.FromParts(
				turn({
					slab("Ground", 0, 0, 10, 10, 0),
					slab("Ground", 10.02, -5, 20, 15, 0), -- wider: its corners are far from the crack
				}, angle),
				{},
				options
			)
			local mesh = NavMesh.Build(desc)
			return NavMesh.FindPath(mesh, turned(2, 0, 5, angle), turned(18, 0, 5, angle))
		end

		test("a crack between a floor's Parts is welded shut", function()
			expect(cracked().Status).is("Success")
		end)

		test("WeldTolerance 0 leaves it a wall", function()
			expect(cracked({ WeldTolerance = 0 }).Status).is("Partial")
		end)

		test("a crack at an angle is welded too", function()
			expect(cracked(nil, 60).Status).is("Success")
			expect(cracked({ WeldTolerance = 0 }, 60).Status).is("Partial")
		end)

		test("a crack wider than WeldTolerance stays", function()
			expect(cracked({ WeldTolerance = 0.01 }).Status).is("Partial")
		end)

		test("a vertex inside another face does not move", function()
			local a, b = slab("Ground", 0, 0, 10, 10, 0), slab("Ground", 9.99, 2, 20, 8, 0)
			local desc: any = NavMeshAdapter.FromParts({ a, b }, {})
			local lo = bounds(desc.Floors.Ground.Walkable[2])
			expect(near(lo, vector.create(9.99, 0, 2))).is_true()
		end)
	end)
end
