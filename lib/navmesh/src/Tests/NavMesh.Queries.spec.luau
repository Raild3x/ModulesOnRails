-- Authors: Logan Hunt (Raildex)
-- September 27, 2026
-- Spatial queries (ticket 17): FindNearestPoint, Raycast, MoveAlongSurface,
-- FindDistanceToWall and a seeded FindRandomPoint.

return function(t: tiniest)
	local NavMesh = require("../NavMesh")
	local Snap = require("../Snap")

	local describe = t.describe
	local expect = t.expect
	local test = t.test

	local Fixtures = NavMesh.Fixtures

	local function v(x: number, y: number, z: number): any
		return vector.create(x, y, z)
	end

	local function fmt(p: any): string
		return string.format("%.4f,%.4f,%.4f", p.X, p.Y, p.Z)
	end

	local function flat(y: number, xz: { number }): any
		local ring = {}
		for i = 1, #xz, 2 do
			table.insert(ring, vector.create(xz[i], y, xz[i + 1]))
		end
		return ring
	end

	local function onMesh(mesh: any, p: any): boolean
		return Snap.Snap(mesh, p, vector.create(1e-3, 1e-3, 1e-3), {}) ~= 0
	end

	local function seeded(seed: number): () -> number
		local state = seed
		return function(): number
			state = (state * 1103515245 + 12345) % 2147483648
			return state / 2147483648
		end
	end

	describe("FindNearestPoint", function()
		test("snaps feet positions like FindPath, and misses off the mesh", function()
			local mesh = NavMesh.Build(Fixtures.ThreeFloorStairs.Desc)
			local ramp = NavMesh.FindNearestPoint(mesh, v(15, 2.4, 2)) :: NavMesh.NavPoint
			expect(fmt(ramp.Position)).is("15.0000,2.5000,2.0000")
			expect(ramp.Floor).is("Stairs")
			expect((NavMesh.FindNearestPoint(mesh, v(30, 5.2, 10)) :: NavMesh.NavPoint).Floor).is("Upper")
			expect((NavMesh.FindNearestPoint(mesh, v(30, 0.2, 10)) :: NavMesh.NavPoint).Floor).is("Ground")
			expect(NavMesh.FindNearestPoint(mesh, v(60, 0, 10))).never_exists()
		end)

		test("a snap box whose edge lies on a tile line still reaches that tile", function()
			-- 2-stud tiles: from x = 4.5 the box's left edge is exactly the tile line x = 4.
			local mesh = NavMesh.Build({
				TileSize = 2,
				Floors = { Ground = { Walkable = { flat(0, { 0, 0, 4, 0, 4, 4, 0, 4 }) } } },
			})
			local east = NavMesh.FindNearestPoint(mesh, v(4.5, 0, 1)) :: NavMesh.NavPoint
			expect(fmt(east.Position)).is("4.0000,0.0000,1.0000")
			local south = NavMesh.FindNearestPoint(mesh, v(1, 0, -0.5)) :: NavMesh.NavPoint
			expect(fmt(south.Position)).is("1.0000,0.0000,0.0000")
		end)
	end)

	describe("Raycast", function()
		local court = NavMesh.Build(Fixtures.Courtyard.Desc)

		test("reaches its target over open ground, across tiles", function()
			local tiled: any = table.clone(Fixtures.Courtyard.Desc)
			tiled.TileSize = 2
			for _, mesh in { court, NavMesh.Build(tiled) } do
				local blocked, stop = NavMesh.Raycast(mesh, v(1, 0, 1), v(10, 0, 1.5))
				expect(blocked).is(false)
				expect(fmt(stop)).is("10.0000,0.0000,1.5000")
			end
		end)

		test("stops at the first wall on its way, on the surface", function()
			local blocked, stop = NavMesh.Raycast(court, v(1, 0, 5), v(10, 0, 5))
			expect(blocked).is(true)
			expect(fmt(stop)).is("4.0000,0.0000,5.0000") -- the crate's west face
			local out, edge = NavMesh.Raycast(court, v(28, 0, 2), v(35, 0, 2))
			expect(out).is(true)
			expect(fmt(edge)).is("30.0000,0.0000,2.0000")
		end)

		test("an excluded area blocks it; a start off the mesh reports blocked", function()
			-- The area-2 patch spans x = 2..10, z = 20..28.
			local blocked, stop = NavMesh.Raycast(court, v(1, 0, 24), v(12, 0, 24), { AreaCosts = { [2] = math.huge } })
			expect(blocked).is(true)
			expect(fmt(stop)).is("2.0000,0.0000,24.0000")
			local off, at = NavMesh.Raycast(court, v(50, 0, 50), v(1, 0, 1))
			expect(off).is(true)
			expect(fmt(at)).is("50.0000,0.0000,50.0000")
		end)

		test("follows a slope and crosses seams onto the next floor", function()
			local stairs = NavMesh.Build(Fixtures.ThreeFloorStairs.Desc)
			-- Starting on the ramp, straight up onto the mezzanine.
			local blocked, stop = NavMesh.Raycast(stairs, v(12, 1, 2), v(30, 5, 2))
			expect(blocked).is(false)
			expect(fmt(stop)).is("30.0000,5.0000,2.0000")
			-- Up the ramp and into its side wall.
			local side, hit = NavMesh.Raycast(stairs, v(12, 1, 2), v(16, 3, 8))
			expect(side).is(true)
			expect(math.abs(hit.Z - 4) < 1e-6).is_true()
			-- All the way down from the mezzanine: over both seams, onto Ground.
			for _, z in { 0.5, 2, 3.5 } do
				local down, at = NavMesh.Raycast(stairs, v(30, 5, z), v(5, 0, z))
				expect(down).with_context(`z {z}`).is(false)
				expect(fmt(at)).is(fmt(v(5, 0, z)))
			end
		end)

		test("crosses a slanted seam wherever the ray meets it, both ways", function()
			-- Two floors meeting along the slanted line (10, 0) - (14, 10); 4-stud tiles cut the
			-- seam into several portals, and a sliver on the Deck touching the seam at (12, 5)
			-- splits the Deck's side there only: one Ground edge faces two portals.
			local deck = NavMesh.Build({
				TileSize = 4,
				Floors = {
					Ground = { Walkable = { flat(0, { 0, 0, 10, 0, 14, 10, 0, 10 }) } },
					Deck = {
						Walkable = { flat(0, { 10, 0, 20, 0, 20, 10, 14, 10 }) },
						Obstacles = { flat(0, { 12, 5, 14, 5.1, 14, 5.3 }) },
					},
				},
				Seams = { { FloorA = "Ground", FloorB = "Deck", From = v(10, 0, 0), To = v(14, 0, 10) } },
			})
			for _, z in { 0.7, 3.3, 4.6, 6.2, 8.9 } do
				local over, at = NavMesh.Raycast(deck, v(2, 0, z), v(18, 0, z))
				expect(over).with_context(`z {z}`).is(false)
				expect(fmt(at)).is(fmt(v(18, 0, z)))
				local back, home = NavMesh.Raycast(deck, v(18, 0, z), v(2, 0, z))
				expect(back).with_context(`back, z {z}`).is(false)
				expect(fmt(home)).is(fmt(v(2, 0, z)))
			end
		end)
	end)

	-- A 20 x 20 floor with a slanted bar whose south face runs from (4, 12) to (16, 8).
	local slanted: any = {
		Floors = {
			Ground = {
				Walkable = { flat(0, { 0, 0, 20, 0, 20, 20, 0, 20 }) },
				Obstacles = { flat(0, { 4, 12, 16, 8, 16, 10, 4, 14 }) },
			},
		},
	}
	local faceA, faceB = v(4, 0, 12), v(16, 0, 8)
	local faceDir = (faceB - faceA) / vector.magnitude(faceB - faceA)

	-- Distance in plan from p to the bar's south face line.
	local function toFace(p: any): number
		local d = p - faceA
		return math.abs(d.X * faceDir.Z - d.Z * faceDir.X)
	end

	describe("MoveAlongSurface", function()
		local court = NavMesh.Build(Fixtures.Courtyard.Desc)

		test("moves freely in the open, and slides along a wall it meets", function()
			expect(fmt(NavMesh.MoveAlongSurface(court, v(1, 0, 1), v(2, 0, 2)).Position)).is("2.0000,0.0000,2.0000")
			local slid = NavMesh.MoveAlongSurface(court, v(2, 0, 5), v(6, 0, 6))
			expect(math.abs(slid.Position.X - 4) < 1e-3 and math.abs(slid.Position.Z - 6) < 1e-6).is_true()
			expect(slid.Floor).is("Ground")
		end)

		test("keeps the agent's radius from walls", function()
			local held = NavMesh.MoveAlongSurface(court, v(2, 0, 5), v(6, 0, 6), { AgentRadius = 0.5 })
			local d = NavMesh.FindDistanceToWall(court, held.Position, 5)
			expect(math.abs(d - 0.5) < 1e-3).with_context(`distance {d}`).is_true()
		end)

		test("slides along a slanted wall to where the move projects onto it", function()
			local mesh = NavMesh.Build(slanted)
			-- The move heads north through the face; sliding keeps its component along the face:
			-- it ends at the foot of the target on the face line, (7.3, 10.9).
			local target = v(9, 0, 16)
			local foot = faceA + faceDir * ((target - faceA).X * faceDir.X + (target - faceA).Z * faceDir.Z)
			local slid = NavMesh.MoveAlongSurface(mesh, v(8, 0, 6), target).Position
			expect(vector.magnitude(vector.create(slid.X - foot.X, 0, slid.Z - foot.Z)) < 1e-3)
				.with_context(`{fmt(slid)} vs {fmt(foot)}`)
				.is_true()
			-- With a radius the agent ends exactly that far from the face, still beside the foot.
			local held = NavMesh.MoveAlongSurface(mesh, v(8, 0, 6), target, { AgentRadius = 0.5 }).Position
			expect(math.abs(toFace(held) - 0.5) < 1e-6).with_context(`{toFace(held)} from the face`).is_true()
			expect(math.abs((held - foot).X * faceDir.X + (held - foot).Z * faceDir.Z) < 1e-2).is_true()
		end)

		test("never leaves the mesh, over many random moves", function()
			local rng = seeded(17)
			local position = v(1, 0, 1)
			for _ = 1, 300 do
				local goal = v(position.X + (rng() - 0.5) * 12, 0, position.Z + (rng() - 0.5) * 12)
				position = NavMesh.MoveAlongSurface(court, position, goal).Position
				expect(onMesh(court, position)).with_context(fmt(position)).is_true()
			end
		end)

		test("errors when it starts off the mesh", function()
			expect(function()
				NavMesh.MoveAlongSurface(court, v(50, 0, 50), v(1, 0, 1))
			end).fails_with("not on the mesh")
		end)
	end)

	describe("FindDistanceToWall", function()
		test("finds the nearest wall with a normal pointing away from it", function()
			local mesh = NavMesh.Build({
				Floors = { Ground = { Walkable = { flat(0, { 0, 0, 20, 0, 20, 10, 0, 10 }) } } },
			})
			local d, hit, normal = NavMesh.FindDistanceToWall(mesh, v(5, 0, 3), 10)
			expect(d).is(3)
			expect(fmt(hit)).is("5.0000,0.0000,0.0000")
			expect(fmt(normal)).is("0.0000,0.0000,1.0000")
			-- Out of range, and off the mesh.
			local far, none = NavMesh.FindDistanceToWall(mesh, v(10, 0, 5), 2)
			expect(far).is(2)
			expect(none).never_exists()
			expect((NavMesh.FindDistanceToWall(mesh, v(50, 0, 5), 2))).is(0)
			expect(function()
				NavMesh.FindDistanceToWall(mesh, v(5, 0, 3), 0)
			end).fails_with("maxRadius")
		end)

		test("a point on a wall is at 0, with the wall's inward unit normal", function()
			local mesh = NavMesh.Build(slanted)
			-- On the bar's slanted face, and on the floor's straight south edge.
			for _, case in { { faceA + faceDir * 5, v(8, 0, 6) }, { v(5, 0, 0), v(5, 0, 3) } } do
				local d, hit, normal = NavMesh.FindDistanceToWall(mesh, case[1], 3)
				local n = normal :: any
				expect(d < 1e-9).with_context(`distance {d}`).is_true()
				expect(vector.magnitude(hit :: any - case[1]) < 1e-6).is_true()
				expect(math.abs(vector.magnitude(n) - 1) < 1e-6).with_context(fmt(n)).is_true()
				expect(n.Y).is(0) -- a normal in (X, Z)
				-- Perpendicular to the wall, towards the walkable side.
				local inward = case[2] - case[1]
				expect(n.X * inward.X + n.Z * inward.Z > 0).with_context(fmt(n)).is_true()
				local along = if case[2] == v(8, 0, 6) then faceDir else v(1, 0, 0)
				expect(math.abs(n.X * along.X + n.Z * along.Z) < 1e-6).with_context(fmt(n)).is_true()
			end
		end)

		test("agrees with a brute-force scan of every wall", function()
			local mesh = NavMesh.Build(Fixtures.Courtyard.Desc)
			local rng = seeded(4)
			for _ = 1, 60 do
				local p = v(rng() * 30, 0, rng() * 30)
				local snapped = NavMesh.FindNearestPoint(mesh, p)
				if snapped == nil then
					continue
				end
				local d = NavMesh.FindDistanceToWall(mesh, snapped.Position, 100)
				local wide = NavMesh.FindDistanceToWall(mesh, snapped.Position, 1000)
				expect(d).is(wide)
				-- No wall is nearer than d: a ray to any point closer than d stays unblocked.
				for k = 0, 11 do
					local angle = k * math.pi / 6
					local q = v(
						snapped.Position.X + math.cos(angle) * d * 0.99,
						0,
						snapped.Position.Z + math.sin(angle) * d * 0.99
					)
					local blocked = NavMesh.Raycast(mesh, snapped.Position, q)
					expect(blocked).with_context(`{fmt(snapped.Position)} towards {fmt(q)}`).is(false)
				end
			end
		end)
	end)

	describe("FindRandomPoint", function()
		test("is reproducible with a seeded rng, on the mesh, and inside the circle", function()
			local mesh = NavMesh.Build(Fixtures.Courtyard.Desc)
			local a, b = seeded(9), seeded(9)
			for _ = 1, 50 do
				local p = NavMesh.FindRandomPoint(mesh, nil, v(20, 0, 5), 3, a) :: NavMesh.NavPoint
				local q = NavMesh.FindRandomPoint(mesh, nil, v(20, 0, 5), 3, b) :: NavMesh.NavPoint
				expect(fmt(p.Position)).is(fmt(q.Position))
				expect(onMesh(mesh, p.Position)).is_true()
				expect((p.Position.X - 20) ^ 2 + (p.Position.Z - 5) ^ 2 <= 9 + 1e-9).is_true()
			end
		end)

		test("is uniform in plan: halves of a floor get about half the points", function()
			local mesh = NavMesh.Build({
				Floors = { Ground = { Walkable = { flat(0, { 0, 0, 20, 0, 20, 10, 0, 10 }) } } },
				TileSize = 4,
			})
			local rng, left = seeded(3), 0
			for _ = 1, 2000 do
				if (NavMesh.FindRandomPoint(mesh, nil, nil, nil, rng) :: NavMesh.NavPoint).Position.X < 10 then
					left += 1
				end
			end
			expect(math.abs(left - 1000) < 100).with_context(`{left} of 2000 on the left`).is_true()
		end)

		test("evenly spread picks land in triangles in proportion to their areas", function()
			local Queries = require("../Queries")
			local Storage = require("../Storage")
			local mesh = NavMesh.Build(Fixtures.Courtyard.Desc)
			for _, costs in { {}, { [2] = math.huge } } do
				-- The rng's first draw of each attempt picks the triangle: feed it (k - 0.5) / N.
				-- The other two place the point inside it.
				local count, calls = 2000, 0
				local function rng(): number
					calls += 1
					return if calls % 3 == 1 then ((calls + 2) / 3 - 0.5) / count else 0.5
				end
				local hits, total = {}, 0
				local areas = {}
				for tri = 1, Storage.TriangleCount(mesh) do
					if costs[Storage.GetTriangleArea(mesh, tri)] == math.huge then
						continue
					end
					local a, b, c = Storage.GetTriangle(mesh, tri)
					local pa, pb, pc =
						Storage.GetVertex(mesh, a), Storage.GetVertex(mesh, b), Storage.GetVertex(mesh, c)
					areas[tri] = math.abs((pb.X - pa.X) * (pc.Z - pa.Z) - (pb.Z - pa.Z) * (pc.X - pa.X)) / 2
					total += areas[tri]
				end
				for _ = 1, count do
					local _, tri = Queries.RandomPoint(mesh, costs, nil, 0, rng)
					hits[tri] = (hits[tri] or 0) + 1
				end
				for tri, area in areas do
					local expected = area / total * count
					expect(math.abs((hits[tri] or 0) - expected) <= 1.5)
						.with_context(`triangle {tri}: {hits[tri] or 0} vs {expected}`)
						.is_true()
				end
			end
		end)

		test("points in a circle fill it evenly, out to its edge", function()
			local mesh = NavMesh.Build({
				Floors = { Ground = { Walkable = { flat(0, { 0, 0, 20, 0, 20, 10, 0, 10 }) } } },
				TileSize = 4,
			})
			-- Uniform in a radius-4 disc: three quarters of the points lie beyond radius 2.
			local rng, outer = seeded(11), 0
			for _ = 1, 800 do
				local p = (NavMesh.FindRandomPoint(mesh, nil, v(10, 0, 5), 4, rng) :: NavMesh.NavPoint).Position
				if (p.X - 10) ^ 2 + (p.Z - 5) ^ 2 > 4 then
					outer += 1
				end
			end
			expect(math.abs(outer / 800 - 0.75) < 0.06).with_context(`{outer} of 800 beyond radius 2`).is_true()
		end)

		test("argument errors point at the caller's line; small and zero radii are fine", function()
			local mesh = NavMesh.Build(Fixtures.Courtyard.Desc)
			for i, call in
				{
					function()
						NavMesh.MoveAlongSurface(mesh, v(50, 0, 50), v(1, 0, 1))
					end,
					function()
						NavMesh.FindDistanceToWall(mesh, v(5, 0, 3), 0)
					end,
					function()
						NavMesh.FindRandomPoint(mesh, nil, v(1, 0, 1))
					end,
				}
			do
				local ok, err = pcall(call)
				expect(ok).is(false)
				expect(tostring(err):find("Queries.spec", 1, true) ~= nil).with_context(`call {i}: {err}`).is_true()
			end
			expect((NavMesh.FindDistanceToWall(mesh, v(1, 0, 1), 0.5))).is(0.5)
			-- (A small circle may still come back empty: rejection sampling has 32 tries.)
			local rng = seeded(8)
			for _, radius in { 0.5, 0 } do
				expect((pcall(NavMesh.FindRandomPoint, mesh, nil, v(1, 0, 1), radius, rng)))
					.with_context(`radius {radius}`)
					.is_true()
			end
		end)

		test("skips excluded areas, and finds nothing where nothing qualifies", function()
			local mesh = NavMesh.Build(Fixtures.Courtyard.Desc)
			local rng = seeded(5)
			for _ = 1, 50 do
				local p =
					NavMesh.FindRandomPoint(mesh, { AreaCosts = { [1] = math.huge } }, nil, nil, rng) :: NavMesh.NavPoint
				-- Only the area-2 patch (x = 2..10, z = 20..28) is left.
				expect(p.Position.X >= 2 and p.Position.X <= 10 and p.Position.Z >= 20 and p.Position.Z <= 28).is_true()
			end
			expect(NavMesh.FindRandomPoint(mesh, nil, v(100, 0, 100), 5, rng)).never_exists()
			expect(function()
				NavMesh.FindRandomPoint(mesh, nil, v(1, 0, 1))
			end).fails_with("needs a radius")
		end)
	end)
end
