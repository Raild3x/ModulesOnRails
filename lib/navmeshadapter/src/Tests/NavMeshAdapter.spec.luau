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

		-- Part data is f32: a hinge between two turned Parts is only true to about 1e-5 studs.
		test("slabs tilted edge to edge join at every hinge", function()
			local ys = { 0, 0.9, 0.5, 1.6, 1.2, 0.4, 0.4, 1.1 } -- tops along X, 10 studs a piece
			local parts = {}
			for i = 1, #ys - 1 do
				local x0, y0, x1, y1 = (i - 1) * 10, ys[i], i * 10, ys[i + 1]
				local len = math.sqrt(100 + (y1 - y0) ^ 2)
				local nx, ny = -(y1 - y0) / len, 10 / len -- the top's normal; the slab hangs below it
				local cf = CFrame.new((x0 + x1) / 2 - nx / 2, (y0 + y1) / 2 - ny / 2, 4)
					* CFrame.Angles(0, 0, math.atan2(y1 - y0, 10))
				table.insert(parts, part("Part", `S{i}`, { len, 1, 8 }, cf))
			end
			local desc: any = NavMeshAdapter.FromParts(parts, {})
			expect(#desc.Seams).is(6)
			desc.MaxAgentRadius = 1
			local path =
				NavMesh.FindPath(NavMesh.Build(desc), vector.create(1, 0, 4) :: any, vector.create(69, 1.1, 4) :: any)
			expect(path.Status).is("Success")
		end)

		test("triangles of wedge pairs: a seam along every shared edge, none where faces touch at a corner", function()
			-- The usual Roblox triangle: two WedgeParts, their right-angle faces up, meeting at
			-- the foot of the altitude onto the longest edge.
			local function triangle(name: string, a: any, b: any, c: any, out: { any })
				local ab, ac, bc = b - a, c - a, c - b
				if ab:Dot(ab) > ac:Dot(ac) and ab:Dot(ab) > bc:Dot(bc) then
					c, a = a, c
				elseif ac:Dot(ac) > bc:Dot(bc) then
					a, b = b, a
				end
				ab, ac, bc = b - a, c - a, c - b
				local right = ac:Cross(ab).Unit
				local up, back = bc:Cross(right).Unit, bc.Unit
				local down = if right.Y > 0 then -right else right
				local h = math.abs(ab:Dot(up))
				local ra, rb = math.abs(ab:Dot(back)), math.abs(ac:Dot(back))
				table.insert(
					out,
					part(
						"WedgePart",
						name,
						{ 0.2, h, ra },
						CFrame.fromMatrix((a + b) / 2 + down * 0.1, right, up, back)
					)
				)
				table.insert(
					out,
					part(
						"WedgePart",
						name,
						{ 0.2, h, rb },
						CFrame.fromMatrix((a + c) / 2 + down * 0.1, -right, up, -back)
					)
				)
			end
			-- 2 x 2 cells of 10 studs, slopes up to about 10 degrees; no two triangles coplanar.
			local heights = { { 0.62, -0.47, 0.58 }, { 0.23, -0.69, 0.56 }, { -0.37, 0.22, 0.70 } }
			local function at(i: number, j: number): any
				return Vector3.new(i * 10, heights[i + 1][j + 1], j * 10)
			end
			-- Each triangle is a floor; shared: { floor, floor, the shared edge's length in plan }.
			local parts, shared = {}, {}
			for i = 0, 1 do
				for j = 0, 1 do
					local a, b = `A{i}{j}`, `B{i}{j}`
					triangle(a, at(i, j), at(i + 1, j), at(i + 1, j + 1), parts)
					triangle(b, at(i, j), at(i + 1, j + 1), at(i, j + 1), parts)
					table.insert(shared, { a, b, math.sqrt(200) })
					if i == 0 then
						table.insert(shared, { a, `B1{j}`, 10 })
					end
					if j == 1 then
						table.insert(shared, { a, `B{i}0`, 10 })
					end
				end
			end
			local desc: any = NavMeshAdapter.FromParts(parts, {})
			for _, seam in desc.Seams do
				expect(vector.magnitude(seam.To - seam.From) > 0.01).is_true()
			end
			for _, edge in shared do
				local covered = 0
				for _, seam in desc.Seams do
					local pair = seam.FloorA .. seam.FloorB
					if pair == edge[1] .. edge[2] or pair == edge[2] .. edge[1] then
						covered += vector.magnitude((seam.To - seam.From) * vector.create(1, 0, 1))
					end
				end
				expect(math.abs(covered - edge[3]) < 0.01).is_true()
			end
			desc.MaxAgentRadius = 1
			local path = NavMesh.FindPath(
				NavMesh.Build(desc),
				vector.create(1, 0.6, 1) :: any,
				vector.create(19, 0.7, 19) :: any
			)
			expect(path.Status).is("Success")
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

	describe("step-height rule (ticket 34)", function()
		-- Ground over x 0..20 with a step block on its east half (x 10..20), h tall: the step's
		-- west edge is a riser over the ground; its other edges are at the ground's border.
		local function stepped(h: number, options: any?, obstacles: { any }?): any
			return NavMeshAdapter.FromParts(
				{ slab("Ground", 0, 0, 20, 10, 0), box("Step", 10, 0, 20, 10, 0, h) },
				obstacles or {},
				options
			)
		end
		local function climb(desc: any): NavMesh.PathResult
			return NavMesh.FindPath(NavMesh.Build(desc), vector.create(2, 0, 5) :: any, vector.create(15, 1, 5) :: any)
		end
		local function risers(desc: any): { any }
			local out = {}
			for name, floor in desc.Floors do
				if string.find(name, "^Riser") then
					table.insert(out, floor)
				end
			end
			return out
		end

		test("a riser up to MaxStepHeight gets a strip floor, seamed to both floors", function()
			local desc = stepped(1, { MaxStepHeight = 1 })
			expect(sortedNames(desc)).is("Ground,Riser,Step")
			local ring = desc.Floors.Riser.Walkable[1]
			expect(area(ring) > 0).is_true()
			local lo, hi = bounds(ring)
			expect(near(lo, vector.create(9.75, 0, 0)) and near(hi, vector.create(10, 1, 10))).is_true()
			expect(#desc.Seams).is(2)
			local byPair = {}
			for _, seam in desc.Seams do
				byPair[seam.FloorA .. "/" .. seam.FloorB] = seam
			end
			local top, foot = byPair["Riser/Step"], byPair["Ground/Riser"]
			expect(top.From.x == 10 and top.To.x == 10 and top.From.y == 1).is_true()
			expect(foot.From.x == 9.75 and foot.To.x == 9.75 and foot.From.y == 0).is_true()
			-- The strip is cut out of the ground, beside the step's own cut.
			expect(#desc.Floors.Ground.Obstacles).is(2)
			local cutLo, cutHi = bounds(desc.Floors.Ground.Obstacles[#desc.Floors.Ground.Obstacles])
			expect(near(cutLo, vector.create(9.75, 0, 0)) and near(cutHi, vector.create(10, 0, 10))).is_true()
			local path = climb(desc)
			expect(path.Status).is("Success")
			local floors = {}
			for _, w in path.Waypoints do
				if floors[#floors] ~= w.Floor then
					table.insert(floors, w.Floor)
				end
			end
			expect(table.concat(floors, ",")).is("Ground,Riser,Step")
		end)

		test("off by default: the riser stays a wall", function()
			local desc = stepped(1)
			expect(sortedNames(desc)).is("Ground,Step")
			expect(climb(desc).Status).is("Partial")
		end)

		test("a rise above MaxStepHeight gets no strip", function()
			expect(#risers(stepped(1.5, { MaxStepHeight = 1 }))).is(0)
			expect(#risers(stepped(1.5, { MaxStepHeight = 1.5 }))).is(1)
		end)

		test("a ramp's foot and top meet at the same height: plain seams, no strip", function()
			local desc: any = NavMeshAdapter.FromParts({
				slab("Ground", 0, 0, 40, 30, 0),
				ramp("Ramp", 6, 12, 1, 12, 18),
				slab("Deck", 18, 12, 30, 18, 1), -- its 1-stud sides are above MaxStepHeight
			}, {}, { MaxStepHeight = 0.5 })
			expect(#risers(desc)).is(0)
			expect(#desc.Seams).is(2)
		end)

		test("only the open part of a riser gets a strip", function()
			-- A crate on the ground against the riser's south half.
			local desc = stepped(1, { MaxStepHeight = 1 }, { box("Crate", 6, 0, 10, 4, 0, 3) })
			local strips = risers(desc)
			expect(#strips).is(1)
			local lo, hi = bounds(strips[1].Walkable[1])
			expect(near(lo, vector.create(9.75, 0, 4)) and near(hi, vector.create(10, 1, 10))).is_true()
			expect(climb(desc).Status).is("Success")
		end)

		test("a riser blocked along its whole length gets no strip, and Build still succeeds", function()
			-- Build rejects a seam with no floor beside it: the strip must not be made.
			-- The last leaves a 0.0005-stud sliver of riser open: too short for a strip.
			for _, crate in
				{
					box("Crate", 6, 0, 10, 10, 0, 3),
					box("Crate", 9.8, 0, 9.9, 10, 0, 3),
					box("Crate", 6, 0.0005, 10, 10, 0, 3),
				}
			do
				local desc = stepped(1, { MaxStepHeight = 1 }, { crate })
				expect(#risers(desc)).is(0)
				expect(climb(desc).Status).is("Partial")
			end
		end)

		test("a cut poking into the strip's band trims the strip to the band, at any angle", function()
			-- A crate turned 45 degrees whose corner reaches x 9.85: inside the band (x 9.74..10)
			-- only for |z - 5| <= 0.11. Straight and with the whole scene turned 30 degrees.
			local edge = 4 * math.sqrt(2) / 2
			for _, degrees in { 0, 30 } do
				local diamond = part(
					"Part",
					"Crate",
					{ edge, 3, edge },
					CFrame.new(7.85, 1.5, 5) * CFrame.Angles(0, math.pi / 4, 0)
				)
				local desc: any = NavMeshAdapter.FromParts(
					turn({ slab("Ground", 0, 0, 20, 10, 0), box("Step", 10, 0, 20, 10, 0, 1) }, degrees),
					turn({ diamond }, degrees),
					{ MaxStepHeight = 1 }
				)
				local lengths = {}
				for _, strip in risers(desc) do
					local ring = strip.Walkable[1]
					table.insert(lengths, vector.magnitude(ring[2] - ring[3]))
				end
				table.sort(lengths)
				expect(#lengths).is(2)
				expect(math.abs(lengths[1] - 4.89) < 1e-3 and math.abs(lengths[2] - 4.89) < 1e-3).is_true()
				expect(NavMesh.Build(desc)).exists()
			end
		end)

		test("a cut on the upper step against the riser leaves that part without a strip", function()
			local half = stepped(1, { MaxStepHeight = 1 }, { box("Crate", 10, 0, 11, 4, 1, 3) })
			local strips = risers(half)
			expect(#strips).is(1)
			local lo, hi = bounds(strips[1].Walkable[1])
			expect(near(lo, vector.create(9.75, 0, 4)) and near(hi, vector.create(10, 1, 10))).is_true()
			local whole = stepped(1, { MaxStepHeight = 1 }, { box("Crate", 10, 0, 11, 10, 1, 3) })
			expect(#risers(whole)).is(0)
			expect(NavMesh.Build(whole)).exists()
		end)

		test("off the origin: heights are measured from the lower floor", function()
			local desc: any = NavMeshAdapter.FromParts(
				{ slab("Ground", 0, 0, 20, 10, 3.3), box("Step", 10, 0, 20, 10, 3.3, 1) },
				{},
				{ MaxStepHeight = 1 }
			)
			local strips = risers(desc)
			expect(#strips).is(1)
			local lo, hi = bounds(strips[1].Walkable[1])
			expect(math.abs(lo.y - 3.3) < 1e-4 and math.abs(hi.y - 4.3) < 1e-4).is_true()
		end)

		test("a tread just wider than the strip gets one", function()
			local desc: any = NavMeshAdapter.FromParts(
				{ slab("Ground", 9.5, 0, 20, 10, 0), box("Step", 10, 0, 20, 10, 0, 1) },
				{},
				{ MaxStepHeight = 1 }
			)
			expect(#risers(desc)).is(1)
		end)

		test("a tread narrower than the strip gets none", function()
			local desc: any = NavMeshAdapter.FromParts(
				{ slab("Ground", 9.8, 0, 20, 10, 0), box("Step", 10, 0, 20, 10, 0, 1) },
				{},
				{ MaxStepHeight = 1 }
			)
			expect(#risers(desc)).is(0)
		end)

		test("a block on open ground gets a strip on every side, and stays buildable", function()
			local desc: any = NavMeshAdapter.FromParts(
				{ slab("Ground", 0, 0, 20, 20, 0), box("Block", 8, 8, 12, 12, 0, 1) },
				{},
				{ MaxStepHeight = 1 }
			)
			expect(#risers(desc)).is(4)
			local mesh = NavMesh.Build(desc)
			for _, from in { vector.create(2, 0, 2), vector.create(18, 0, 10), vector.create(10, 0, 18) } do
				expect(NavMesh.FindPath(mesh, from :: any, vector.create(10, 1, 10) :: any).Status).is("Success")
			end
		end)

		test("strip names skip names a Part already took", function()
			local desc: any = NavMeshAdapter.FromParts({
				slab("Ground", 0, 0, 20, 10, 0),
				box("Step", 10, 0, 20, 10, 0, 1),
				slab("Riser", 40, 0, 44, 4, 5),
			}, {}, { MaxStepHeight = 1 })
			expect(sortedNames(desc)).is("Ground,Riser,Riser 2,Step")
			expect(#desc.Floors["Riser 2"].Walkable[1]).is(4)
		end)
	end)
end
