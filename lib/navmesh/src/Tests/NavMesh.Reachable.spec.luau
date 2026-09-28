-- Authors: Logan Hunt (Raildex)
-- September 28, 2026
-- Ticket 24: the off-mesh policy and closest-reachable queries. FindPath's end point is offset
-- by AgentRadius, MoveAlongSurface reports an off-mesh start instead of throwing,
-- FindNearestPoint takes a search radius, FindRandomPoint takes options and honours
-- AgentRadius, and FindPath's GoalFallback paths to the closest reachable point.

return function(t: tiniest)
	local NavMesh = require("../NavMesh")
	local Queries = require("../Queries")

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

	local function rect(x0: number, z0: number, x1: number, z1: number): any
		return flat(0, { x0, z0, x1, z0, x1, z1, x0, z1 })
	end

	local function seeded(seed: number): () -> number
		local state = seed
		return function(): number
			state = (state * 1103515245 + 12345) % 2147483648
			return state / 2147483648
		end
	end

	local function near(a: any, b: any): boolean
		return vector.magnitude(a - b) < 1e-6
	end

	local function wallDistance(mesh: any, p: any, radius: number): number
		return (NavMesh.FindDistanceToWall(mesh, p, radius + 1))
	end

	local function last(path: NavMesh.PathResult): any
		return path.Waypoints[#path.Waypoints].Position
	end

	local square = NavMesh.Build { Floors = { Ground = { Walkable = { rect(0, 0, 20, 20) } } } }
	-- Two pads with no way between them: the east one is never reachable from the west.
	local islands = NavMesh.Build { Floors = { Ground = { Walkable = { rect(0, 0, 10, 10), rect(12, 0, 20, 10) } } } }
	local court = NavMesh.Build(Fixtures.Courtyard.Desc)

	describe("FindPath end point", function()
		test("a goal against a wall ends AgentRadius off it; radius 0 keeps the goal", function()
			local held = NavMesh.FindPath(square, v(10, 0, 10), v(10, 0, 0.1), { AgentRadius = 0.5 })
			expect(held.Status).is("Success")
			expect(fmt(last(held))).is("10.0000,0.0000,0.5000")
			local corner = NavMesh.FindPath(square, v(10, 0, 10), v(19.9, 0, 19.9), { AgentRadius = 1 })
			expect(fmt(last(corner))).is("19.0000,0.0000,19.0000")
			local exact = NavMesh.FindPath(square, v(10, 0, 10), v(10, 0, 0.1))
			expect(fmt(last(exact))).is("10.0000,0.0000,0.1000")
			-- A goal already clear of the walls is kept.
			local open = NavMesh.FindPath(square, v(2, 0, 2), v(10, 0, 10), { AgentRadius = 1 })
			expect(fmt(last(open))).is("10.0000,0.0000,10.0000")
		end)

		test("a Partial end on the edge it stops at is pushed off it too", function()
			local path = NavMesh.FindPath(islands, v(2, 0, 5), v(15, 0, 5), { AgentRadius = 0.5 })
			expect(path.Status).is("Partial")
			expect(fmt(last(path))).is("9.5000,0.0000,5.0000")
		end)

		test("a push across a seam reports the floor it lands on, and stamps its tile", function()
			-- Floors A and B meet along x = 10. A crate on A ends 0.25 short of the seam, so a
			-- radius-1 push from a goal beside it crosses onto B.
			local desc: any = {
				Floors = {
					A = { Walkable = { rect(0, 0, 10, 10) }, Obstacles = { rect(8, 4, 9.75, 6) } },
					B = { Walkable = { rect(10, 0, 20, 10) } },
				},
				Seams = { { FloorA = "A", FloorB = "B", From = v(10, 0, 0), To = v(10, 0, 10) } },
			}
			local mesh = NavMesh.Build(desc)
			local path = NavMesh.FindPath(mesh, v(2, 0, 5), v(9.9, 0, 5), { AgentRadius = 1 })
			local w = path.Waypoints[#path.Waypoints]
			expect(fmt(w.Position)).is("10.7500,0.0000,5.0000")
			expect(w.Floor).is("B")
			-- The corridor stays on A; only the pushed end is on B. A crate added on B's tile
			-- invalidates the path.
			NavMesh.AddObstacle(mesh, "B", rect(16, 8, 17, 9))
			NavMesh.Update(mesh)
			expect(NavMesh.IsPathValid(mesh, path)).is(false)
		end)

		test("every end is at least AgentRadius from the walls, for Success, Partial and Budget", function()
			local rng = seeded(24)
			local seen = {}
			for i = 1, 300 do
				local radius = ({ 0.3, 0.5, 1 })[i % 3 + 1]
				local a = NavMesh.FindNearestPoint(court, v(rng() * 30, 0, rng() * 30), nil, 30)
				local b = NavMesh.FindNearestPoint(court, v(rng() * 30, 0, rng() * 30), nil, 30)
				if a == nil or b == nil then
					continue
				end
				-- Some goals sit in the area-2 patch with the patch excluded: GoalFallback ends
				-- those Partial on the patch's edge.
				local filter = {
					AgentRadius = radius,
					MaxExpansions = if i % 7 == 0 then 2 else nil,
					AreaCosts = if i % 5 == 0 then { [2] = math.huge } else nil,
					GoalFallback = true,
				}
				local path = NavMesh.FindPath(court, a.Position, b.Position, filter)
				seen[path.Status] = true
				if path.Status == "NoStart" then
					continue -- a start in the excluded patch
				end
				local d = wallDistance(court, last(path), radius)
				expect(d >= radius - 1e-3)
					.with_context(`{path.Status} r {radius} {fmt(a.Position)} -> {fmt(b.Position)}: end {fmt(last(path))} at {d}`)
					.is_true()
			end
			expect(seen.Success and seen.Partial and seen.Budget or false).is_true()
		end)
	end)

	describe("Off-mesh policy", function()
		-- Repro 5: a door closes on an agent standing in the doorway.
		local mesh = NavMesh.Build { Floors = { Ground = { Walkable = { rect(0, 0, 20, 20) } } } }
		NavMesh.AddObstacle(mesh, "Ground", rect(9, 0, 11, 20))
		NavMesh.Update(mesh)
		local inDoor = v(10.2, 0, 10)

		test("a door closed on an agent: every query answers with a status, none throws", function()
			expect(NavMesh.FindPath(mesh, inDoor, v(2, 0, 2)).Status).is("NoStart")
			expect(NavMesh.FindNearestPoint(mesh, inDoor)).never_exists()
			local blocked, stop = NavMesh.Raycast(mesh, inDoor, v(2, 0, 2))
			expect(blocked).is(true)
			expect(near(stop, inDoor)).is_true()
			local d, hit, normal = NavMesh.FindDistanceToWall(mesh, inDoor, 5)
			expect(d).is(0)
			expect(hit).never_exists()
			expect(normal).never_exists()
			local moved = NavMesh.MoveAlongSurface(mesh, inDoor, v(2, 0, 2))
			expect(moved.Status).is("NoStart")
			expect(near(moved.Position, inDoor)).is_true()
			expect(moved.Floor).never_exists()
		end)

		test("MoveAlongSurface on the mesh reports Success", function()
			local moved = NavMesh.MoveAlongSurface(mesh, v(2, 0, 2), v(3, 0, 3))
			expect(moved.Status).is("Success")
			expect(moved.Floor).is("Ground")
			expect(fmt(moved.Position)).is("3.0000,0.0000,3.0000")
		end)
	end)

	describe("FindNearestPoint search radius", function()
		local mesh = NavMesh.Build { Floors = { Ground = { Walkable = { rect(0, 0, 20, 20) } } } }
		NavMesh.AddObstacle(mesh, "Ground", rect(9, 0, 11, 20))
		NavMesh.Update(mesh)

		test("finds the closest point beyond SnapExtents, within the radius in plan", function()
			local rescued = NavMesh.FindNearestPoint(mesh, v(10.2, 0, 10), nil, 1) :: NavMesh.NavPoint
			expect(fmt(rescued.Position)).is("11.0000,0.0000,10.0000")
			expect(rescued.Floor).is("Ground")
			expect(NavMesh.FindNearestPoint(mesh, v(10.2, 0, 10), nil, 0.5)).never_exists()
			-- A point that snaps keeps its snap, whatever the radius.
			expect(fmt((NavMesh.FindNearestPoint(mesh, v(3, 1, 3), nil, 5) :: NavMesh.NavPoint).Position)).is(
				"3.0000,0.0000,3.0000"
			)
		end)

		test("has no vertical limit: a point high above a floor lands below it", function()
			expect(NavMesh.FindNearestPoint(square, v(5, 10, 5))).never_exists()
			local below = NavMesh.FindNearestPoint(square, v(5, 10, 5), nil, 0) :: NavMesh.NavPoint
			expect(fmt(below.Position)).is("5.0000,0.0000,5.0000")
		end)

		test("ranks candidates by 3D distance: under a deck it keeps to the floor below", function()
			-- Ground has a hole under a deck 6 studs up. From the hole's middle the deck is 0 away
			-- in plan but 6 in 3D; the hole's edge is 2 away.
			local decked = NavMesh.Build {
				Floors = {
					Ground = { Walkable = { rect(0, 0, 20, 20) }, Obstacles = { rect(8, 8, 12, 12) } },
					Deck = { Walkable = { flat(6, { 5, 5, 15, 5, 15, 15, 5, 15 }) } },
				},
			}
			local p = NavMesh.FindNearestPoint(decked, v(10, 0, 10), nil, 3) :: NavMesh.NavPoint
			expect(p.Floor).is("Ground")
			expect(math.abs(vector.magnitude(p.Position - v(10, 0, 10)) - 2) < 1e-9).is_true()
		end)

		test("skips excluded areas", function()
			local p = NavMesh.FindNearestPoint(court, v(6, 0, 18), { AreaCosts = { [2] = math.huge } }, 5)
			expect(fmt((p :: NavMesh.NavPoint).Position)).is("6.0000,0.0000,18.0000")
			local q = NavMesh.FindNearestPoint(court, v(6, 0, 21), { AreaCosts = { [2] = math.huge } }, 5)
			expect(fmt((q :: NavMesh.NavPoint).Position)).is("6.0000,0.0000,20.0000")
		end)

		test("a radius far wider than the mesh scans its tiles, not every cell of the circle", function()
			local p = NavMesh.FindNearestPoint(square, v(1e6, 0, 5), nil, 1e7) :: NavMesh.NavPoint
			expect(fmt(p.Position)).is("20.0000,0.0000,5.0000")
			-- Several floors and tiles: Ground's east edge is nearer in 3D than Upper's.
			local stairs = NavMesh.Build(Fixtures.ThreeFloorStairs.Desc)
			local q = NavMesh.FindNearestPoint(stairs, v(1e6, 1, 2), nil, 1e7) :: NavMesh.NavPoint
			expect(fmt(q.Position)).is("40.0000,0.0000,2.0000")
			expect(q.Floor).is("Ground")
		end)

		test("the radius must be a finite number >= 0", function()
			for _, bad in { -1, math.huge, 0 / 0, "2" :: any } do
				expect(function()
					NavMesh.FindNearestPoint(square, v(5, 0, 5), nil, bad)
				end).fails_with("searchRadius")
			end
		end)
	end)

	describe("FindRandomPoint options", function()
		test("takes Filter, Center, Radius and Rng, reproducibly", function()
			local a, b = seeded(9), seeded(9)
			for _ = 1, 30 do
				local p =
					NavMesh.FindRandomPoint(court, { Center = v(20, 0, 5), Radius = 3, Rng = a }) :: NavMesh.NavPoint
				local q =
					NavMesh.FindRandomPoint(court, { Center = v(20, 0, 5), Radius = 3, Rng = b }) :: NavMesh.NavPoint
				expect(fmt(p.Position)).is(fmt(q.Position))
				expect((p.Position.X - 20) ^ 2 + (p.Position.Z - 5) ^ 2 <= 9 + 1e-9).is_true()
			end
			expect(NavMesh.FindRandomPoint(court)).exists()
		end)

		test("an unknown option errors, naming the shape (a QueryFilter passed as options)", function()
			expect(function()
				NavMesh.FindRandomPoint(court, { AgentRadius = 1 } :: any)
			end).fails_with("Filter, Center, Radius, Rng")
			expect(function()
				NavMesh.FindRandomPoint(court, { Center = v(1, 0, 1) })
			end).fails_with("needs a Radius")
		end)

		test("with AgentRadius r, no point is closer than r to a wall, over many seeds", function()
			for _, mesh in
				{ square, court, NavMesh.Build { Floors = { Ground = { Walkable = { rect(0, 0, 10, 10) } } } } }
			do
				for seed = 1, 20 do
					local rng = seeded(seed)
					for _, radius in { 0.5, 1, 2 } do
						for _ = 1, 10 do
							local p = NavMesh.FindRandomPoint(mesh, { Filter = { AgentRadius = radius }, Rng = rng })
							if p then
								local d = wallDistance(mesh, p.Position, radius)
								expect(d >= radius - 1e-6)
									.with_context(`seed {seed} r {radius}: {fmt(p.Position)} at {d}`)
									.is_true()
							end
						end
					end
				end
			end
		end)

		test("stays uniform over where the agent fits: no pile-up at the radius line", function()
			-- A 10 x 10 floor at r = 2: the agent fits in the inner 6 x 6 square. Uniform in it,
			-- 11/36 of the points lie within 0.5 of its edge; pushing near-wall samples out onto
			-- that edge would put three quarters there.
			local mesh = NavMesh.Build { Floors = { Ground = { Walkable = { rect(0, 0, 10, 10) } } } }
			local rng, rim, left = seeded(5), 0, 0
			for _ = 1, 1000 do
				local p = (
					NavMesh.FindRandomPoint(mesh, { Filter = { AgentRadius = 2 }, Rng = rng }) :: NavMesh.NavPoint
				).Position
				if math.min(p.X - 2, 8 - p.X, p.Z - 2, 8 - p.Z) < 0.5 then
					rim += 1
				end
				if p.X < 5 then
					left += 1
				end
			end
			expect(math.abs(rim / 1000 - 11 / 36) < 0.05).with_context(`{rim} of 1000 on the rim`).is_true()
			expect(math.abs(left - 500) < 60).with_context(`{left} of 1000 on the left`).is_true()
		end)

		test("where the agent fits nowhere, it returns nil without sampling", function()
			-- A 1.5-stud corridor: no edge of any triangle admits 2 x 1.
			local corridor = NavMesh.Build { Floors = { Ground = { Walkable = { rect(0, 0, 20, 1.5) } } } }
			local calls = 0
			local function rng(): number
				calls += 1
				return 0.5
			end
			expect(NavMesh.FindRandomPoint(corridor, { Filter = { AgentRadius = 1 }, Rng = rng })).never_exists()
			expect(calls).is(0)
			expect(NavMesh.FindRandomPoint(corridor, { Filter = { AgentRadius = 0.5 }, Rng = rng })).exists()
		end)

		test("a circle hugging a wall has no fitting point: the push would leave it, so nil", function()
			-- A 2 x 2 floor fits a radius-1 agent only at its centre.
			local small = NavMesh.Build { Floors = { Ground = { Walkable = { rect(0, 0, 2, 2) } } } }
			local rng = seeded(2)
			for _ = 1, 20 do
				local p = NavMesh.FindRandomPoint(
					small,
					{ Filter = { AgentRadius = 1 }, Center = v(1, 0, 0.2), Radius = 0.3, Rng = rng }
				)
				expect(p).never_exists()
			end
		end)

		test("a push that can't clear the walls gives nil, not a point too near them", function()
			-- An equilateral floor whose inscribed circle (radius 1.05) barely fits a radius-1
			-- agent. Samples at a 60-degree corner miss, and two pushes off its walls don't
			-- reach the small region that fits.
			local side = 1.05 * 2 * math.sqrt(3)
			local wedge = NavMesh.Build {
				TileSize = 1,
				Floors = {
					Ground = { Walkable = { { v(0, 0, 0), v(side, 0, 0), v(side / 2, 0, side * math.sqrt(3) / 2) } } },
				},
			}
			local p = Queries.RandomPoint(wedge, {}, nil, 0, 1, function()
				return 0.02
			end)
			expect(p).never_exists()
		end)

		test("a tight fit falls back to pushing a sample off the walls", function()
			-- A 2.2-stud corridor at r = 1: the fitting band is 0.2 wide, so most samples miss it.
			-- An rng that always lands 0.1 from the south wall misses every time; the last try is
			-- pushed onto the band instead.
			local corridor = NavMesh.Build { Floors = { Ground = { Walkable = { rect(0, 0, 20, 2.2) } } } }
			local p = Queries.RandomPoint(corridor, {}, nil, 0, 1, function()
				return 0.02
			end)
			expect(p).exists()
			local d = wallDistance(corridor, p, 1)
			expect(d >= 1 - 1e-6).with_context(`{fmt(p)} at {d}`).is_true()
		end)
	end)

	describe("FindPath GoalFallback", function()
		test("an off-mesh goal is NoGoal without it, and Partial to the closest reachable point with it", function()
			local off = v(25, 0, 10)
			expect(NavMesh.FindPath(square, v(2, 0, 10), off).Status).is("NoGoal")
			local path = NavMesh.FindPath(square, v(2, 0, 10), off, { GoalFallback = true })
			expect(path.Status).is("Partial")
			expect(fmt(last(path))).is("20.0000,0.0000,10.0000")
			local held = NavMesh.FindPath(square, v(2, 0, 10), off, { GoalFallback = true, AgentRadius = 0.5 })
			expect(fmt(last(held))).is("19.5000,0.0000,10.0000")
		end)

		test("reachable first: a nearer island the start can't reach is skipped", function()
			local path = NavMesh.FindPath(islands, v(2, 0, 5), v(25, 0, 5), { GoalFallback = true })
			expect(path.Status).is("Partial")
			expect(fmt(last(path))).is("10.0000,0.0000,5.0000")
		end)

		test("a goal high above the floor (a target mid-jump) falls back to the floor below it", function()
			local path = NavMesh.FindPath(square, v(2, 0, 2), v(15, 9, 5), { GoalFallback = true })
			expect(path.Status).is("Partial")
			expect(fmt(last(path))).is("15.0000,0.0000,5.0000")
		end)

		test("MaxExpansions still bounds it; an off-mesh start is still NoStart", function()
			local path = NavMesh.FindPath(court, v(1, 0, 1), v(50, 0, 50), { GoalFallback = true, MaxExpansions = 1 })
			expect(path.Status).is("Budget")
			expect(NavMesh.FindPath(court, v(50, 0, 50), v(1, 0, 1), { GoalFallback = true }).Status).is("NoStart")
		end)

		test("GoalFallback must be a boolean", function()
			expect(function()
				NavMesh.FindPath(square, v(1, 0, 1), v(2, 0, 2), { GoalFallback = 1 } :: any)
			end).fails_with("GoalFallback")
		end)

		test("the fallback end is always reachable: FindPath to it succeeds", function()
			local rng = seeded(31)
			local tried = 0
			for i = 1, 200 do
				local radius = ({ 0, 0.5, 1 })[i % 3 + 1]
				local start = NavMesh.FindNearestPoint(court, v(rng() * 30, 0, rng() * 30), nil, 30) :: NavMesh.NavPoint
				-- Goals anywhere around the yard: in the hole, on crates, outside it, up in the air.
				local goal = v(rng() * 40 - 5, rng() * 6, rng() * 40 - 5)
				local filter = { AgentRadius = radius, GoalFallback = true }
				local path = NavMesh.FindPath(court, start.Position, goal, filter)
				expect(path.Status == "Success" or path.Status == "Partial").with_context(path.Status).is_true()
				local again = NavMesh.FindPath(court, start.Position, last(path), { AgentRadius = radius })
				expect(again.Status)
					.with_context(`r {radius} {fmt(start.Position)} -> {fmt(goal)}: end {fmt(last(path))}`)
					.is("Success")
				tried += 1
			end
			expect(tried).is(200)
		end)
	end)
end
