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
			local mesh = NavMesh.Build {
				TileSize = 2,
				Floors = { Ground = { Walkable = { flat(0, { 0, 0, 4, 0, 4, 4, 0, 4 }) } } },
			}
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
		end)
	end)

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
			local mesh = NavMesh.Build {
				Floors = { Ground = { Walkable = { flat(0, { 0, 0, 20, 0, 20, 10, 0, 10 }) } } },
			}
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
			local mesh = NavMesh.Build {
				Floors = { Ground = { Walkable = { flat(0, { 0, 0, 20, 0, 20, 10, 0, 10 }) } } },
				TileSize = 4,
			}
			local rng, left = seeded(3), 0
			for _ = 1, 2000 do
				if (NavMesh.FindRandomPoint(mesh, nil, nil, nil, rng) :: NavMesh.NavPoint).Position.X < 10 then
					left += 1
				end
			end
			expect(math.abs(left - 1000) < 100).with_context(`{left} of 2000 on the left`).is_true()
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
