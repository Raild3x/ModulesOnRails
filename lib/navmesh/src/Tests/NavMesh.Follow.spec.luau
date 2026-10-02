-- Authors: Logan Hunt (Raildex)
-- September 28, 2026
-- Ticket 23: the path follower. NewFollower wraps a PathResult; Advance walks it a step at a
-- time with MoveAlongSurface, and reports Arrived, Link (without walking the link) and Blocked
-- (stalled, or knocked off the mesh).

return function(t: tiniest)
	local NavMesh = require("../NavMesh")

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

	local function rect(x0: number, z0: number, x1: number, z1: number): any
		return { v(x0, 0, z0), v(x1, 0, z0), v(x1, 0, z1), v(x0, 0, z1) }
	end

	local function seeded(seed: number): () -> number
		local state = seed
		return function(): number
			state = (state * 1103515245 + 12345) % 2147483648
			return state / 2147483648
		end
	end

	-- Advances until an event (or `limit` steps). Returns the event, the position, the floor, the
	-- step count and every position visited.
	local function run(mesh: any, f: any, from: any, maxStep: number, filter: any?, limit: number?)
		local p, floor, event = from, nil, nil
		local visited = {}
		for i = 1, limit or 1000 do
			p, floor, event = NavMesh.Advance(mesh, f, p, maxStep, filter)
			table.insert(visited, p)
			if event then
				return event, p, floor, i, visited
			end
		end
		return nil, p, floor, limit or 1000, visited
	end

	local court = NavMesh.Build(Fixtures.Courtyard.Desc)

	describe("Advance", function()
		test("walks a path to Arrived, maxStep at a time, reporting the floor", function()
			local square = NavMesh.Build { Floors = { Ground = { Walkable = { rect(0, 0, 20, 20) } } } }
			local path = NavMesh.FindPath(square, v(2, 0, 2), v(12, 0, 2))
			local f = NavMesh.NewFollower(path)
			local event, p, floor, steps, visited = run(square, f, v(2, 0, 2), 1)
			expect(event).is("Arrived")
			expect(fmt(p)).is("12.0000,0.0000,2.0000")
			expect(floor).is("Ground")
			expect(steps).is(10)
			expect(fmt(visited[1])).is("3.0000,0.0000,2.0000")
			-- Arrived again on every later call, without moving.
			local again, stay = NavMesh.Advance(square, f, p, 1)
			expect(fmt(again :: any)).is(fmt(p))
			expect(select(3, NavMesh.Advance(square, f, p, 1))).is("Arrived")
			expect(stay).is("Ground")
		end)

		test("a path with no waypoints (NoStart, NoGoal) arrives at once, where it stands", function()
			local f = NavMesh.NewFollower(NavMesh.FindPath(court, v(-50, 0, -50), v(5, 0, 5)))
			local p, floor, event = NavMesh.Advance(court, f, v(-50, 0, -50), 1)
			expect(event).is("Arrived")
			expect(fmt(p)).is("-50.0000,0.0000,-50.0000")
			expect(floor).never_exists()
		end)

		test("a Partial end against a wall is arrived at, not a stall (the end is offset)", function()
			-- The goal is in the hole (12..16); r = 1 stops the agent 1 off its face.
			local filter = { AgentRadius = 1, GoalFallback = true }
			local path = NavMesh.FindPath(court, v(2, 0, 14), v(14, 0, 14), filter)
			expect(path.Status).is("Partial")
			local event, p = run(court, NavMesh.NewFollower(path, 1), v(2, 0, 14), 0.5, filter)
			expect(event).is("Arrived")
			expect(math.abs(p.X - 11) < 1e-3).with_context(fmt(p)).is_true()
		end)

		test("a corner waypoint closer than the radius to a wall is passed, not a stall", function()
			-- Round the crate pair from the south-west to its north-east: the corner waypoints
			-- sit on the portals, inside the radius of the walls. StallSteps 1: any stall fails.
			local filter = { AgentRadius = 1 }
			local path = NavMesh.FindPath(court, v(5, 0, 1.5), v(10, 0, 11), filter)
			expect(path.Status).is("Success")
			expect(#path.Waypoints >= 3).is_true()
			local event = run(court, NavMesh.NewFollower(path, 1), v(5, 0, 1.5), 0.25, filter)
			expect(event).is("Arrived")
		end)

		test("a wall corner where several floors meet is rounded at the radius, and arrived past", function()
			-- Four 10 x 10 quadrant floors meet at the origin. NE and SE touch along z = 0 (x > 0)
			-- with no seam: a wall that ends at the origin. The way round runs NE, NW, SW, SE
			-- across seams, and on NW and SW the origin is free space: only NE's and SE's
			-- copies of it are wall vertices (City's meadow, follower_vertex_stall.luau).
			local mesh = NavMesh.Build {
				Floors = {
					NE = { Walkable = { rect(0, 0, 10, 10) } },
					NW = { Walkable = { rect(-10, 0, 0, 10) } },
					SW = { Walkable = { rect(-10, -10, 0, 0) } },
					SE = { Walkable = { rect(0, -10, 10, 0) } },
				},
				Seams = {
					{ FloorA = "NE", FloorB = "NW", From = v(0, 0, 0), To = v(0, 0, 10) },
					{ FloorA = "NW", FloorB = "SW", From = v(-10, 0, 0), To = v(0, 0, 0) },
					{ FloorA = "SW", FloorB = "SE", From = v(0, 0, -10), To = v(0, 0, 0) },
				},
			}
			local filter = { AgentRadius = 1 }
			local from = v(3, 0, 1.5)
			local path = NavMesh.FindPath(mesh, from, v(3, 0, -1.5), filter)
			expect(path.Status).is("Success")
			-- No leg of the path comes within half the radius of the wall's end.
			local w = path.Waypoints
			for i = 1, #w - 1 do
				local a, b = w[i].Position, w[i + 1].Position
				local dx, dz = b.X - a.X, b.Z - a.Z
				local k = math.clamp(-(a.X * dx + a.Z * dz) / (dx * dx + dz * dz), 0, 1)
				local d = math.sqrt((a.X + k * dx) ^ 2 + (a.Z + k * dz) ^ 2)
				expect(d >= 0.5).with_context(`leg {i}: {fmt(a)} -> {fmt(b)} is {d} from the corner`).is_true()
			end
			local event, p = run(mesh, NavMesh.NewFollower(path), from, 0.5, filter)
			expect(event).with_context(fmt(p)).is("Arrived")
		end)

		test("every path on the courtyard is followed to Arrived without a stall, over many seeds", function()
			local rng = seeded(23)
			for i = 1, 150 do
				local radius = ({ 0, 0.5, 1 })[i % 3 + 1]
				local filter = { AgentRadius = radius }
				local a = NavMesh.FindRandomPoint(court, { Filter = filter, Rng = rng })
				local b = NavMesh.FindRandomPoint(court, { Filter = filter, Rng = rng })
				if a == nil or b == nil then
					continue
				end
				local path = NavMesh.FindPath(court, a.Position, b.Position, filter)
				local step = ({ 0.1, 0.4, 1.3 })[i % 3 + 1]
				local event, p =
					run(court, NavMesh.NewFollower(path, 1), path.Waypoints[1].Position, step, filter, 2000)
				expect(event)
					.with_context(`r {radius} step {step} {fmt(a.Position)} -> {fmt(b.Position)}: at {fmt(p)}`)
					.is("Arrived")
			end
		end)
	end)

	describe("Links", function()
		local mesh = NavMesh.Build(Fixtures.LinkJump.Desc)

		test("emits Link with the label and both ends, and never walks the link", function()
			local path = NavMesh.FindPath(mesh, v(2, 0, 5), v(22, 0, 5))
			local f = NavMesh.NewFollower(path)
			local event, p, floor, _, visited = run(mesh, f, v(2, 0, 5), 1)
			expect(event).is("Link")
			expect(floor).is("Ground")
			local link = f.Link :: NavMesh.FollowerLink
			expect(link.Label).is("Jump")
			expect(fmt(link.From)).is("9.0000,0.0000,5.0000")
			expect(fmt(link.To)).is("15.0000,0.0000,5.0000")
			-- Stopped at the link's start; nothing past it (the gap is 10 < x < 14).
			expect(fmt(p)).is(fmt(link.From))
			for _, q in visited do
				expect(q.X <= 9 + 1e-9).with_context(fmt(q)).is_true()
			end
			-- The game hops; from the landing the follower walks on to the goal.
			local after, q = run(mesh, f, link.To, 1)
			expect(f.Link).never_exists()
			expect(after).is("Arrived")
			expect(fmt(q)).is("22.0000,0.0000,5.0000")
		end)

		test("a path that starts on a link emits Link at once", function()
			local path = NavMesh.FindPath(mesh, v(9, 0, 5), v(22, 0, 5))
			expect(path.Waypoints[1].Label).is("Jump")
			local f = NavMesh.NewFollower(path)
			local p, _, event = NavMesh.Advance(mesh, f, v(9, 0, 5), 1)
			expect(event).is("Link")
			expect(fmt(p)).is("9.0000,0.0000,5.0000")
		end)
	end)

	describe("Blocked", function()
		test("a door closed on the agent: Blocked at once, with no floor, and no throw", function()
			local mesh = NavMesh.Build { Floors = { Ground = { Walkable = { rect(0, 0, 20, 20) } } } }
			local path = NavMesh.FindPath(mesh, v(2, 0, 10), v(18, 0, 10))
			local f = NavMesh.NewFollower(path, 100)
			local none = run(mesh, f, v(2, 0, 10), 1, nil, 8)
			expect(none).never_exists() -- no event yet
			NavMesh.AddObstacle(mesh, "Ground", rect(9, 0, 11, 20))
			NavMesh.Update(mesh)
			local q, floor, event = NavMesh.Advance(mesh, f, v(10, 0, 10), 1)
			expect(event).is("Blocked")
			expect(floor).never_exists()
			expect(fmt(q)).is("10.0000,0.0000,10.0000")
		end)

		test("a wall that appears in the way: Blocked after StallSteps steps without progress", function()
			local mesh = NavMesh.Build { Floors = { Ground = { Walkable = { rect(0, 0, 20, 20) } } } }
			local path = NavMesh.FindPath(mesh, v(2, 0, 10), v(18, 0, 10))
			NavMesh.AddObstacle(mesh, "Ground", rect(9, 0, 11, 20))
			NavMesh.Update(mesh)
			local f = NavMesh.NewFollower(path, 5)
			local event, p, floor, steps = run(mesh, f, v(2, 0, 10), 1)
			expect(event).is("Blocked")
			expect(floor).is("Ground")
			expect(fmt(p)).is("9.0000,0.0000,10.0000")
			-- 7 steps to reach the wall, then 5 without progress.
			expect(steps).is(12)
			expect(f.Stalled).is(5)
		end)

		test("with no AgentRadius, a stall just short of a waypoint is Blocked, not arrived", function()
			-- The goal is 1 inside a wall that appears: at radius 0 only 0.05 of slack counts.
			for i = 1, 2 do
				local filter = if i == 1 then nil else {}
				local mesh = NavMesh.Build { Floors = { Ground = { Walkable = { rect(0, 0, 20, 20) } } } }
				local path = NavMesh.FindPath(mesh, v(2, 0, 10), v(10, 0, 10), filter)
				NavMesh.AddObstacle(mesh, "Ground", rect(9, 0, 11, 20))
				NavMesh.Update(mesh)
				expect((run(mesh, NavMesh.NewFollower(path, 3), v(2, 0, 10), 1, filter))).is("Blocked")
			end
		end)

		test("a step of 0 (a paused frame) is never a stall", function()
			local f = NavMesh.NewFollower(NavMesh.FindPath(court, v(2, 0, 2), v(5, 0, 2)), 1)
			expect(f.Stalled).is(0)
			for _ = 1, 3 do
				local p, floor, event = NavMesh.Advance(court, f, v(2, 0, 2), 0)
				expect(event).never_exists()
				expect(fmt(p)).is("2.0000,0.0000,2.0000")
				expect(floor).is("Ground")
			end
			expect(f.Stalled).is(0)
		end)

		test("progress resets the stall count", function()
			local mesh = NavMesh.Build { Floors = { Ground = { Walkable = { rect(0, 0, 20, 20) } } } }
			local path = NavMesh.FindPath(mesh, v(2, 0, 10), v(18, 0, 10))
			NavMesh.AddObstacle(mesh, "Ground", rect(9, 0, 11, 20))
			NavMesh.Update(mesh)
			local f = NavMesh.NewFollower(path, 5)
			run(mesh, f, v(2, 0, 10), 1, nil, 10) -- 3 stalled steps
			expect(f.Stalled).is(3)
			NavMesh.Advance(mesh, f, v(2, 0, 10), 1) -- from further back: progress
			expect(f.Stalled).is(0)
		end)
	end)

	describe("Validation", function()
		test("NewFollower needs a PathResult and a StallSteps >= 1", function()
			expect(function()
				NavMesh.NewFollower(nil :: any)
			end).fails_with("PathResult")
			local path = NavMesh.FindPath(court, v(2, 0, 2), v(5, 0, 2))
			for _, bad in { 0, 1.5, -1, math.huge, "3" :: any } do
				expect(function()
					NavMesh.NewFollower(path, bad)
				end).fails_with("stallSteps")
			end
			expect(NavMesh.NewFollower(path).StallSteps).is(10)
		end)

		test("maxStep must be a finite number >= 0", function()
			local f = NavMesh.NewFollower(NavMesh.FindPath(court, v(2, 0, 2), v(5, 0, 2)))
			for _, bad in { -1, math.huge, 0 / 0, "1" :: any } do
				expect(function()
					NavMesh.Advance(court, f, v(2, 0, 2), bad)
				end).fails_with("maxStep")
			end
		end)

		test("follower errors point at the caller's line", function()
			local path = NavMesh.FindPath(court, v(2, 0, 2), v(5, 0, 2))
			for i, call in
				{
					function()
						NavMesh.NewFollower(nil :: any)
					end,
					function()
						NavMesh.NewFollower(path, 0)
					end,
					function()
						NavMesh.Advance(court, NavMesh.NewFollower(path), v(2, 0, 2), -1)
					end,
				}
			do
				local ok, err = pcall(call)
				expect(ok).is(false)
				expect(tostring(err):find("Follow.spec", 1, true) ~= nil).with_context(`call {i}: {err}`).is_true()
			end
		end)
	end)
end
