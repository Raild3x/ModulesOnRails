-- Authors: Logan Hunt (Raildex)
-- September 25, 2026

return function(t: tiniest)
	local NavMesh = require("../NavMesh")
	local CDT = require("../../ConstrainedDelaunay")
	local Storage = require("../Storage")
	local MeshChecks = require("./Helpers/MeshChecks")

	local describe = t.describe
	local expect = t.expect
	local test = t.test
	local snapshot = t.snapshot

	local Fixtures = NavMesh.Fixtures

	local function flat(y: number, xz: { number }): { vector }
		local ring = {}
		for i = 1, #xz, 2 do
			table.insert(ring, vector.create(xz[i], y, xz[i + 1]))
		end
		return ring
	end

	local function oneFloor(floor: any): any
		return { Floors = { Ground = floor } }
	end

	-- Deterministic LCG (Lune has no Random); high bits, as a float in [lo, hi).
	local function makeRng(seed: number): (number, number) -> number
		local state = seed
		return function(lo: number, hi: number): number
			state = (state * 1103515245 + 12345) % 2147483648
			return lo + (state / 2147483648) * (hi - lo)
		end
	end

	-- A simple (star-shaped) ring: increasing angles around a centre, random radii.
	local function star(rng: (number, number) -> number, cx: number, cz: number, r0: number, r1: number): { vector }
		local ring = {}
		local count = math.floor(rng(5, 11))
		for i = 0, count - 1 do
			local angle = (i + rng(0.1, 0.9)) / count * 2 * math.pi
			local r = rng(r0, r1)
			table.insert(ring, vector.create(cx + r * math.cos(angle), 0, cz + r * math.sin(angle)))
		end
		return ring
	end

	describe("Build fixtures", function()
		test("every fixture builds into structurally valid, network-safe state", function()
			for _, scenario in Fixtures.All do
				local mesh = NavMesh.Build(scenario.Desc)
				expect(Storage.TriangleCount(mesh) > 0).with_context(scenario.Name).is_true()
				local bad = MeshChecks.Structure(mesh)
				expect(#bad).with_context(`{scenario.Name}: {bad[1]}`).is(0)
				expect(CDT.PlainData.Check(mesh)).with_context(scenario.Name).is_true()
			end
		end)

		test("the kept region is walkable minus obstacles", function()
			for _, scenario in Fixtures.All do
				local mesh = NavMesh.Build(scenario.Desc)
				local bad = MeshChecks.Region(mesh, 1, scenario.Desc.Floors.Ground, 1 / 128, 0.37)
				expect(#bad).with_context(`{scenario.Name}: {bad[1]}`).is(0)
			end
		end)

		test("area ids follow the area rings; the rest take the floor default", function()
			local desc = Fixtures.Courtyard.Desc
			local mud = desc.Floors.Ground.Areas[1].Polygon
			local mesh = NavMesh.Build(desc)
			local seen = { [1] = 0, [2] = 0 }
			for tri = 1, Storage.TriangleCount(mesh) do
				local a, b, c = Storage.GetTriangle(mesh, tri)
				local pa, pb, pc = Storage.GetVertex(mesh, a), Storage.GetVertex(mesh, b), Storage.GetVertex(mesh, c)
				local cx, cz = (pa.X + pb.X + pc.X) / 3, (pa.Z + pb.Z + pc.Z) / 3
				local area = Storage.GetTriangleArea(mesh, tri)
				expect(area).with_context(`triangle {tri}`).is(if MeshChecks.Inside(mud, cx, cz) then 2 else 1)
				seen[area] += 1
			end
			expect(seen[2] > 0 and seen[1] > 0).is_true()
		end)

		test("golden DrawLists", function()
			for _, scenario in Fixtures.All do
				local list = NavMesh.ToDrawList(NavMesh.Build(scenario.Desc), { Tiles = true, Areas = true })
				-- f32 storage: round so the golden reads as studs.
				for _, primitive in list do
					for i, v in primitive.Points do
						primitive.Points[i] = math.round(v * 1e4) / 1e4
					end
				end
				snapshot(list)
			end
		end)
	end)

	describe("Build heights (SR6)", function()
		test("a flat pad and a ramp sharing an edge keep the crease between them", function()
			local mesh = NavMesh.Build(Fixtures.SplitLevel.Desc)
			for v = 1, Storage.VertexCount(mesh) do
				local p = Storage.GetVertex(mesh, v)
				local expected = math.max(0, (p.X - 10) * 0.5)
				expect(math.abs(p.Y - expected) < 1e-5).with_context(`vertex {v} at ({p.X}, {p.Z}): {p.Y}`).is_true()
			end
		end)

		-- The twisted quad's surface: diagonal B(12,0)-D(0,8) splits it into ABD (all at y = 0)
		-- and BCD with C = (10, 10) lifted to 5.
		local function twistedHeight(x: number, z: number): number
			if CDT.Orient2D(12, 0, 0, 8, x, z) >= 0 then -- A's side of BD (C's side is negative)
				return 0
			end
			local det = (10 - 12) * (8 - 0) - (0 - 12) * (10 - 0)
			local wc = ((x - 12) * (8 - 0) - (0 - 12) * (z - 0)) / det
			return 5 * wc
		end
		local function straddles(pa: any, pb: any, pc: any): boolean
			local cx, cz = (pa.X + pb.X + pc.X) / 3, (pa.Z + pb.Z + pc.Z) / 3
			return math.abs((pa.Y + pb.Y + pc.Y) / 3 - twistedHeight(cx, cz)) > 1e-4
		end

		test("a non-planar ring's diagonal is a crease no triangle crosses", function()
			local mesh = NavMesh.Build(Fixtures.TwistedQuad.Desc)
			for v = 1, Storage.VertexCount(mesh) do
				local p = Storage.GetVertex(mesh, v)
				expect(math.abs(p.Y - twistedHeight(p.X, p.Z)) < 1e-4).with_context(`vertex {v}`).is_true()
			end
			for tri = 1, Storage.TriangleCount(mesh) do
				local a, b, c = Storage.GetTriangle(mesh, tri)
				expect(straddles(Storage.GetVertex(mesh, a), Storage.GetVertex(mesh, b), Storage.GetVertex(mesh, c)))
					.with_context(`triangle {tri}`)
					.never_is_true()
			end
			-- Negative control: a triangle across the crease is caught.
			expect(straddles(vector.create(0, 0, 0), vector.create(12, 0, 0), vector.create(10, 5, 10))).is_true()
		end)

		test("overlapping rings that agree in height build", function()
			local mesh = NavMesh.Build(oneFloor {
				Walkable = { flat(2, { 0, 0, 10, 0, 10, 10, 0, 10 }), flat(2, { 5, 5, 15, 5, 15, 15, 5, 15 }) },
			})
			for v = 1, Storage.VertexCount(mesh) do
				expect(Storage.GetVertex(mesh, v).Y).is(2)
			end
		end)
	end)

	describe("Build ring normalisation", function()
		local function area(mesh: any): number
			local total = 0
			for tri = 1, Storage.TriangleCount(mesh) do
				local a, b, c = Storage.GetTriangle(mesh, tri)
				local pa, pb, pc = Storage.GetVertex(mesh, a), Storage.GetVertex(mesh, b), Storage.GetVertex(mesh, c)
				total += ((pb.X - pa.X) * (pc.Z - pa.Z) - (pc.X - pa.X) * (pb.Z - pa.Z)) / 2
			end
			return total
		end
		local L = { 0, 0, 10, 0, 10, 4, 4, 4, 4, 10, 0, 10 } -- L-shape, area 64

		test("CW rings, a repeated closing point and redundant collinear points build the same region", function()
			local reversed = {}
			for i = #L - 1, 1, -2 do
				table.insert(reversed, L[i])
				table.insert(reversed, L[i + 1])
			end
			local closed = table.clone(L)
			table.insert(closed, 0)
			table.insert(closed, 0)
			local collinear = { 0, 0, 5, 0, 10, 0, 10, 4, 4, 4, 4, 10, 0, 10, 0, 5 }
			local collinearReversed = {}
			for i = #collinear - 1, 1, -2 do
				table.insert(collinearReversed, collinear[i])
				table.insert(collinearReversed, collinear[i + 1])
			end
			local repeated = { 0, 0, 10, 0, 10, 0, 10, 4, 4, 4, 4, 10, 0, 10 }
			for _, xz in { L, reversed, closed, collinear, collinearReversed, repeated } do
				local mesh = NavMesh.Build(
					oneFloor { Walkable = { flat(0, xz) }, Obstacles = { flat(0, { 1, 1, 2, 1, 2, 2 }) } }
				)
				expect(area(mesh)).is(64 - 0.5)
				expect(#MeshChecks.Structure(mesh)).is(0)
			end
		end)

		test("a non-planar ring whose first points are collinear, and a concave one, keep their heights", function()
			-- Lifted corner at (10, 10); the first three points are collinear.
			local lifted = { 0, 0, 0, 5, 0, 0, 10, 0, 0, 10, 5, 10, 0, 0, 10 }
			-- Concave: a notch, with the far corner lifted.
			local notch = { 0, 0, 0, 10, 0, 0, 10, 3, 10, 5, 0, 5, 0, 0, 10 }
			for _, xyz in { lifted, notch } do
				local ring = {}
				for i = 1, #xyz, 3 do
					table.insert(ring, vector.create(xyz[i], xyz[i + 1], xyz[i + 2]))
				end
				local mesh = NavMesh.Build(oneFloor { Walkable = { ring } })
				for _, p in ring do
					local found = false
					for v = 1, Storage.VertexCount(mesh) do
						local q = Storage.GetVertex(mesh, v)
						found = found or (q.X == p.X and q.Z == p.Z and q.Y == p.Y)
					end
					expect(found).with_context(`authored point ({p.X}, {p.Y}, {p.Z})`).is_true()
				end
			end
		end)
	end)

	describe("Build heights, more", function()
		local function tilted(xz: { number }): { vector }
			local ring = {}
			for i = 1, #xz, 2 do
				table.insert(ring, vector.create(xz[i], 0.3 * xz[i] + 0.2 * xz[i + 1], xz[i + 1]))
			end
			return ring
		end

		test("a tilted planar ring gets no crease constraints: same triangles as flat", function()
			-- The first three points are collinear, so the plane comes from a later point.
			local xz = { 3, 2, 8, 2, 13, 2, 13, 12, 3, 12 } -- away from the origin, so x - x1 ~= x + x1
			local obstacle = { flat(0, { 6, 5, 10, 6, 8, 9 }) }
			local flatMesh = NavMesh.Build(oneFloor { Walkable = { flat(0, xz) }, Obstacles = obstacle })
			local tiltedMesh = NavMesh.Build(oneFloor { Walkable = { tilted(xz) }, Obstacles = obstacle })
			expect(Storage.TriangleCount(tiltedMesh)).is(Storage.TriangleCount(flatMesh))
			for v = 1, Storage.VertexCount(tiltedMesh) do
				local p = Storage.GetVertex(tiltedMesh, v)
				expect(math.abs(p.Y - (0.3 * p.X + 0.2 * p.Z)) < 1e-4).with_context(`vertex {v}`).is_true()
			end
		end)

		test("a raised pad inside another ring's concave notch builds (no false overlap)", function()
			local yard = flat(0, { 0, 0, 20, 0, 20, 20, 12, 20, 12, 8, 8, 8, 8, 20, 0, 20 })
			local pad = flat(5, { 9, 12, 11, 12, 11, 18, 9, 18 })
			local mesh = NavMesh.Build(oneFloor { Walkable = { yard, pad } })
			local raised = 0
			for v = 1, Storage.VertexCount(mesh) do
				local p = Storage.GetVertex(mesh, v)
				if p.Y == 5 then
					raised += 1
				end
			end
			expect(raised).is(4)
		end)

		test("a snapped crossing just off a slanted crease is within tolerance", function()
			-- Pad (y = 0) and ramp (y = 0.5(x - 10) - 0.1z) share the slanted crease (10,0)-(12,10).
			-- An obstacle crosses it at non-grid points, and the snapped crossing vertices sit up to
			-- half a pixel off the crease, where the two surfaces differ slightly.
			local pad = flat(0, { 0, 0, 10, 0, 12, 10, 0, 10 })
			local ramp =
				{ vector.create(10, 0, 0), vector.create(20, 5, 0), vector.create(20, 4, 10), vector.create(12, 0, 10) }
			local obstacle = flat(0, { 10.31, 4.137, 11.73, 4.291, 11.83, 5.917, 10.42, 5.633 })
			expect(function()
				NavMesh.Build(oneFloor { Walkable = { pad, ramp }, Obstacles = { obstacle } })
			end).never_fails()
		end)

		test("area ids: an explicit floor default and area 1 are accepted", function()
			local square = flat(0, { 0, 0, 10, 0, 10, 10, 0, 10 })
			local mesh = NavMesh.Build(oneFloor {
				Walkable = { square },
				Area = 3,
				Areas = { { Polygon = flat(0, { 0, 0, 5, 0, 5, 10, 0, 10 }), Area = 1 } },
			})
			local seen = {}
			for tri = 1, Storage.TriangleCount(mesh) do
				seen[Storage.GetTriangleArea(mesh, tri)] = true
			end
			expect(seen[1] and seen[3]).is_true()
		end)

		test("a coordinate of exactly 32,768 studs is accepted", function()
			expect(function()
				NavMesh.Build(oneFloor { Walkable = { flat(0, { 32758, 0, 32768, 0, 32768, 10 }) } })
			end).never_fails()
		end)
	end)

	describe("Build errors", function()
		local square = flat(0, { 0, 0, 10, 0, 10, 10, 0, 10 })
		local cases = {
			{ "no Floors table", {}, "needs a Floors table" },
			{ "no floors", { Floors = {} }, "has no floors" },
			{ "a non-string floor name", { Floors = { square } }, "floor names must be strings" },
			{
				"a ring with fewer than 3 points",
				oneFloor { Walkable = { flat(0, { 0, 0, 1, 1 }) } },
				"walkable ring 1: a ring needs at least 3 points",
			},
			{ "no walkable ring", oneFloor { Walkable = {} }, "floor 'Ground': needs at least one Walkable ring" },
			{
				"a self-intersecting walkable ring",
				oneFloor { Walkable = { flat(0, { 0, 0, 10, 10, 10, 0, 0, 10 }) } },
				"walkable ring 1: the ring intersects itself",
			},
			{
				"a self-intersecting obstacle",
				oneFloor { Walkable = { square }, Obstacles = { flat(0, { 1, 1, 4, 4, 4, 1, 1, 4 }) } },
				"obstacle 1: the ring intersects itself",
			},
			{
				"a ring folding back on itself",
				oneFloor { Walkable = { flat(0, { 0, 0, 10, 0, 5, 0, 5, 5 }) } },
				"folds back on itself at point 2",
			},
			{
				"a ring that degenerates on the grid",
				oneFloor { Walkable = { flat(0, { 0, 0, 0.001, 0, 0, 0.001 }) } },
				"degenerates after quantization",
			},
			{
				"a coordinate beyond 32,768 studs (U-d)",
				oneFloor { Walkable = { flat(0, { 0, 0, 40000, 0, 0, 10 }) } },
				"walkable ring 1: point 2 %(40000, 0%) is outside the supported range",
			},
			{
				"a z coordinate beyond 32,768 studs",
				oneFloor { Walkable = { flat(0, { 0, 0, 10, 0, 0, -40000 }) } },
				"walkable ring 1: point 3",
			},
			{
				"a ring touching itself at a vertex",
				oneFloor { Walkable = { flat(0, { 0, 0, 10, 0, 5, 5, 10, 10, 0, 10, 5, 5 }) } },
				"the ring intersects itself",
			},
			{ "a non-table floor", { Floors = { Ground = true } }, "floor 'Ground': needs at least one Walkable ring" },
			{
				"a fractional area id",
				oneFloor { Walkable = { square }, Areas = { { Polygon = square, Area = 1.5 } } },
				"area id must be an integer",
			},
			{
				"a non-finite height",
				oneFloor { Walkable = { flat(0 / 0, { 0, 0, 10, 0, 0, 10 }) } },
				"non%-finite height",
			},
			{
				"overlapping rings at different heights",
				oneFloor { Walkable = { square, flat(1, { 5, 5, 15, 5, 15, 15, 5, 15 }) } },
				"walkable rings 1 and 2 overlap with different heights",
			},
			{
				"rings meeting at a step",
				oneFloor { Walkable = { square, flat(2, { 10, 0, 20, 0, 20, 10, 10, 10 }) } },
				"meet at different heights",
			},
			{
				"a bad area id",
				oneFloor { Walkable = { square }, Areas = { { Polygon = square, Area = 0 } } },
				"area 1: area id must be an integer",
			},
			{
				"seams",
				{ Floors = { Ground = { Walkable = { square } } }, Seams = { {} } },
				"Seams are not implemented yet",
			},
		}
		for _, case in cases do
			test(`errors on {case[1]}`, function()
				expect(function()
					NavMesh.Build(case[2])
				end).fails_with(case[3])
			end)
		end
	end)

	describe("Build over random floors (SR2)", function()
		test("never trips the added-vertex guard, and keeps walkable minus obstacles", function()
			for seed = 1, 40 do
				local rng = makeRng(seed)
				local floor = { Walkable = {}, Obstacles = {}, Areas = {} }
				for _ = 1, math.floor(rng(1, 4)) do
					table.insert(floor.Walkable, star(rng, rng(0, 20), rng(0, 20), 4, 14))
				end
				for _ = 1, math.floor(rng(0, 5)) do
					table.insert(floor.Obstacles, star(rng, rng(0, 20), rng(0, 20), 1, 5))
				end
				for _ = 1, math.floor(rng(0, 3)) do
					table.insert(floor.Areas, { Polygon = star(rng, rng(0, 20), rng(0, 20), 2, 6), Area = 2 })
				end
				local mesh = NavMesh.Build(oneFloor(floor))
				local bad = MeshChecks.Structure(mesh)
				expect(#bad).with_context(`seed {seed}: {bad[1]}`).is(0)
				bad = MeshChecks.Region(mesh, 1, floor, 1 / 128, 0.9)
				expect(#bad).with_context(`seed {seed}: {bad[1]}`).is(0)
			end
		end)

		test("the region check catches a missing obstacle (negative control)", function()
			local floor = { Walkable = { flat(0, { 0, 0, 10, 0, 10, 10, 0, 10 }) } }
			local mesh = NavMesh.Build(oneFloor(floor))
			local withHole = { Walkable = floor.Walkable, Obstacles = { flat(0, { 3, 3, 7, 3, 7, 7, 3, 7 }) } }
			expect(#MeshChecks.Region(mesh, 1, withHole, 1 / 128, 0.5) > 0).is_true()
		end)
	end)

	describe("ToDrawList", function()
		test("draws triangles per floor, walls on open edges, and tile bounds on request", function()
			local mesh = NavMesh.Build(Fixtures.SplitLevel.Desc)
			local counts: { [string]: number } = {}
			for _, primitive in NavMesh.ToDrawList(mesh, { Tiles = true }) do
				counts[primitive.Layer] = (counts[primitive.Layer] or 0) + 1
			end
			expect(counts["Floor:Ground"]).is(Storage.TriangleCount(mesh))
			expect(counts.Tiles).is(4)
			local xs = {}
			for _, primitive in NavMesh.ToDrawList(mesh, { Triangles = false, Tiles = true }) do
				xs[primitive.Points[1]] = true
				xs[primitive.Points[3]] = true
			end
			expect(xs[0] and xs[20] and xs[10]).is_true() -- tile bounds 0..20 x 0..10 studs
			expect(counts.Walls > 0).is_true()
			expect(#NavMesh.ToDrawList(mesh, { Triangles = false })).is(0)
		end)
	end)
end
