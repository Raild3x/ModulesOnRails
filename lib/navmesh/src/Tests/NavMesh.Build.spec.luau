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

	describe("Tiling (SR3)", function()
		local function totalArea(mesh: any): number
			local total = 0
			for tri = 1, Storage.TriangleCount(mesh) do
				local a, b, c = Storage.GetTriangle(mesh, tri)
				local pa, pb, pc = Storage.GetVertex(mesh, a), Storage.GetVertex(mesh, b), Storage.GetVertex(mesh, c)
				total += ((pb.X - pa.X) * (pc.Z - pa.Z) - (pc.X - pa.X) * (pb.Z - pa.Z)) / 2
			end
			return total
		end
		local function withTileSize(desc: any, size: number): any
			local copy = table.clone(desc)
			copy.TileSize = size
			return copy
		end

		test("fixtures split into tiles keep structure, region, walls and total area", function()
			for _, scenario in Fixtures.All do
				local single = NavMesh.Build(withTileSize(scenario.Desc, 1024))
				for _, size in { 3, 5.5, 8 } do
					local context = `{scenario.Name} TileSize {size}`
					local mesh = NavMesh.Build(withTileSize(scenario.Desc, size))
					expect(Storage.TileCount(mesh) > 1).with_context(context).is_true()
					local floor = scenario.Desc.Floors.Ground
					for _, bad in
						{
							MeshChecks.Structure(mesh),
							MeshChecks.Region(mesh, 1, floor, 1 / 128, 0.37),
							MeshChecks.Walls(mesh, 1, floor, 1 / 128),
							MeshChecks.InTiles(mesh),
						}
					do
						expect(#bad).with_context(`{context}: {bad[1]}`).is(0)
					end
					-- Tile lines add hot pixels, and rerouting through one moves an edge by at most
					-- half a grid pixel, so the area may drift by up to perimeter x 1/512.
					local perimeter = 0
					local rings = table.clone(floor.Walkable)
					table.move(floor.Obstacles or {}, 1, #(floor.Obstacles or {}), #rings + 1, rings)
					for _, ring in rings do
						for i, p in ring do
							local q = ring[i % #ring + 1]
							perimeter += vector.magnitude(vector.create(q.X - p.X, 0, q.Z - p.Z))
						end
					end
					local drift = math.abs(totalArea(mesh) - totalArea(single))
					expect(drift <= perimeter / 512).with_context(`{context}: area drift {drift}`).is_true()
				end
			end
		end)

		test("heights and creases survive tiling", function()
			local mesh = NavMesh.Build(withTileSize(Fixtures.SplitLevel.Desc, 3))
			for v = 1, Storage.VertexCount(mesh) do
				local p = Storage.GetVertex(mesh, v)
				expect(math.abs(p.Y - math.max(0, (p.X - 10) * 0.5)) < 1e-5).with_context(`vertex {v}`).is_true()
			end
			local twisted = NavMesh.Build(withTileSize(Fixtures.TwistedQuad.Desc, 3))
			for tri = 1, Storage.TriangleCount(twisted) do
				local a, b, c = Storage.GetTriangle(twisted, tri)
				expect(
						straddles(
							Storage.GetVertex(twisted, a),
							Storage.GetVertex(twisted, b),
							Storage.GetVertex(twisted, c)
						)
					)
					.with_context(`TwistedQuad triangle {tri}`)
					.never_is_true()
			end
		end)

		test("tiles line up on the world grid, and empty tiles are skipped", function()
			-- An L-shaped floor: its bounding box has a 4x4 grid of 5-stud tiles, of which the
			-- empty top-right corner holds none.
			local mesh = NavMesh.Build {
				TileSize = 5,
				Floors = { Ground = { Walkable = { flat(0, { 0, 0, 20, 0, 20, 10, 10, 10, 10, 20, 0, 20 }) } } },
			}
			expect(Storage.TileCount(mesh)).is(12)
			for tile = 1, Storage.TileCount(mesh) do
				local x0, z0, x1, z1 = Storage.GetTileBounds(mesh, tile)
				expect(x0 % 5 == 0 and z0 % 5 == 0 and x1 - x0 == 5 and z1 - z0 == 5)
					.with_context(`tile {tile}`)
					.is_true()
			end
		end)

		test("random sloped floors with random tile sizes", function()
			-- Every walkable ring lies on y = 0.2x - 0.1z, so heights have one exact answer.
			local function plane(ring: { vector }): { vector }
				local out = {}
				for i, p in ring do
					out[i] = vector.create(p.X, 0.2 * p.X - 0.1 * p.Z, p.Z)
				end
				return out
			end
			for seed = 1, 30 do
				local rng = makeRng(seed + 100)
				local floor = { Walkable = {}, Obstacles = {}, Areas = {} }
				for _ = 1, math.floor(rng(1, 4)) do
					table.insert(floor.Walkable, plane(star(rng, rng(0, 20), rng(0, 20), 4, 14)))
				end
				for _ = 1, math.floor(rng(0, 5)) do
					table.insert(floor.Obstacles, star(rng, rng(0, 20), rng(0, 20), 1, 5))
				end
				for _ = 1, math.floor(rng(0, 3)) do
					table.insert(floor.Areas, { Polygon = star(rng, rng(0, 20), rng(0, 20), 2, 6), Area = 2 })
				end
				local size = math.floor(rng(2, 12) * 256) / 256
				local mesh = NavMesh.Build { TileSize = size, Floors = { Ground = floor } }
				for _, bad in
					{
						MeshChecks.Structure(mesh),
						MeshChecks.Region(mesh, 1, floor, 1 / 128, 0.9),
						MeshChecks.Walls(mesh, 1, floor, 1 / 128),
						MeshChecks.InTiles(mesh),
					}
				do
					expect(#bad).with_context(`seed {seed} TileSize {size}: {bad[1]}`).is(0)
				end
				for v = 1, Storage.VertexCount(mesh) do
					local p = Storage.GetVertex(mesh, v)
					expect(math.abs(p.Y - (0.2 * p.X - 0.1 * p.Z)) < 1e-3)
						.with_context(`seed {seed} vertex ({p.X}, {p.Z}) height {p.Y}`)
						.is_true()
				end
			end
		end)

		test("the wall check catches an unlinked tile border (negative control)", function()
			local mesh = NavMesh.Build(withTileSize(Fixtures.SplitLevel.Desc, 5))
			expect(#MeshChecks.Walls(mesh, 1, Fixtures.SplitLevel.Desc.Floors.Ground, 1 / 128)).is(0)
			-- Cut one cross-tile link, on both sides.
			for tri = 1, Storage.TriangleCount(mesh) do
				for e = 1, 3 do
					local n = Storage.GetNeighbor(mesh, tri, e)
					if n ~= 0 and Storage.GetTriangleTile(mesh, n) ~= Storage.GetTriangleTile(mesh, tri) then
						Storage.SetNeighbor(mesh, tri, e, 0)
						for e2 = 1, 3 do
							if Storage.GetNeighbor(mesh, n, e2) == tri then
								Storage.SetNeighbor(mesh, n, e2, 0)
							end
						end
						expect(#MeshChecks.Walls(mesh, 1, Fixtures.SplitLevel.Desc.Floors.Ground, 1 / 128) > 0).is_true()
						return
					end
				end
			end
			error("no cross-tile link found")
		end)

		-- The tile size a built floor ended up with (every tile of a floor is the same size).
		local function tileSizeOf(mesh: any, floorName: string): number
			for tile = 1, Storage.TileCount(mesh) do
				if Storage.GetFloorName(mesh, Storage.GetTileFloor(mesh, tile)) == floorName then
					local x0, _, x1 = Storage.GetTileBounds(mesh, tile)
					return x1 - x0
				end
			end
			error(`no tile on floor {floorName}`)
		end
		-- A square floor of `side` studs with `count` small boxes scattered on it.
		local function boxes(side: number, count: number, size: number): any
			local rng = makeRng(side * 1000 + count)
			local obstacles = {}
			for _ = 1, count do
				local x, z = rng(size, side - size), rng(size, side - size)
				table.insert(obstacles, flat(0, { x, z, x + size, z, x + size, z + size, x, z + size }))
			end
			return { Walkable = { flat(0, { 0, 0, side, 0, side, side, 0, side }) }, Obstacles = obstacles }
		end

		test("the default TileSize adapts to each floor: about 36 edges per tile, a power of two", function()
			local cases = {
				-- sqrt(36 x area / edges), rounded to a power of two and clamped to 4-256 studs.
				{ "plain 10-stud square: sqrt(36 x 100 / 4) = 30", boxes(10, 0, 1), 32 },
				{ "plain 2-stud square: sqrt(36 x 4 / 4) = 6", boxes(2, 0, 0.5), 8 },
				{ "dense props: sqrt(36 x 4096 / 2052) = 8.5", boxes(64, 512, 1), 8 },
				{ "denser than 4 studs clamps to 4", boxes(8, 200, 0.2), 4 },
				{ "a huge plain square clamps to 256", boxes(2000, 0, 1), 256 },
			}
			for _, case in cases do
				local mesh = NavMesh.Build { Floors = { Ground = case[2] } }
				expect(tileSizeOf(mesh, "Ground")).with_context(case[1]).is(case[3])
			end
		end)

		test("each floor gets its own default; an explicit TileSize applies to every floor", function()
			local floors = { Dense = boxes(64, 512, 1), Plain = boxes(10, 0, 1) }
			local adaptive = NavMesh.Build { Floors = floors }
			expect(tileSizeOf(adaptive, "Dense")).is(8)
			expect(tileSizeOf(adaptive, "Plain")).is(32)
			local fixed = NavMesh.Build { TileSize = 16, Floors = floors }
			expect(tileSizeOf(fixed, "Dense")).is(16)
			expect(tileSizeOf(fixed, "Plain")).is(16)
		end)

		test("TileSize must be a positive number of studs within range", function()
			local floors = { Ground = { Walkable = { flat(0, { 0, 0, 10, 0, 10, 10 }) } } }
			for _, bad in { 0, -4, 40000, "8" :: any } do
				expect(function()
					NavMesh.Build { TileSize = bad, Floors = floors }
				end).fails_with("TileSize must be a number of studs")
			end
			-- Both ends of the range are allowed: one grid pixel, and the coordinate limit.
			local tiny = { Ground = { Walkable = { flat(0, { 0, 0, 1 / 64, 0, 1 / 64, 1 / 64 }) } } }
			expect(function()
				NavMesh.Build { TileSize = 1 / 256, Floors = tiny }
			end).never_fails()
			expect(function()
				NavMesh.Build { TileSize = 32768, Floors = floors }
			end).never_fails()
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
			expect(xs[0] and xs[32]).is_true() -- one default 32-stud tile at the origin
			expect(counts.Walls > 0).is_true()
			expect(#NavMesh.ToDrawList(mesh, { Triangles = false })).is(0)
		end)
	end)
end
