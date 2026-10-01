-- Authors: Logan Hunt (Raildex)
-- October 1, 2026
-- Ticket 25: the shape of a returned path. Waypoints where a path crosses a seam or a crease,
-- so a height lerped between consecutive waypoints follows the surface; none on a flat floor.

return function(t: tiniest)
	local NavMesh = require("../NavMesh")

	local describe = t.describe
	local expect = t.expect
	local test = t.test

	local Fixtures = NavMesh.Fixtures

	local function v(x: number, y: number, z: number): any
		return vector.create(x, y, z)
	end

	local function rect(y: number, x0: number, z0: number, x1: number, z1: number): any
		return { v(x0, y, z0), v(x1, y, z0), v(x1, y, z1), v(x0, y, z1) }
	end

	local function fmt(p: any): string
		return string.format("%.3f,%.3f,%.3f", p.X, p.Y, p.Z)
	end

	-- Repro 7: a ramp up to a deck that overhangs the ground.
	local overhang = NavMesh.Build {
		Floors = {
			Ground = { Walkable = { rect(0, 0, 0, 50, 20) }, Obstacles = { rect(0, 10, 0, 20, 20) } },
			Ramp = { Walkable = { { v(10, 0, 0), v(20, 5, 0), v(20, 5, 20), v(10, 0, 20) } } },
			Top = { Walkable = { rect(5, 20, 0, 50, 20) } },
		},
		Seams = {
			{ FloorA = "Ground", FloorB = "Ramp", From = v(10, 0, 0), To = v(10, 0, 20) },
			{ FloorA = "Ramp", FloorB = "Top", From = v(20, 5, 0), To = v(20, 5, 20) },
		},
	}

	-- A gabled roof: one floor, one ring, creased along x = 10.
	local roof = NavMesh.Build {
		Floors = {
			Roof = { Walkable = { { v(0, 0, 0), v(10, 4, 0), v(20, 0, 0), v(20, 0, 20), v(10, 4, 20), v(0, 0, 20) } } },
		},
	}

	-- The largest gap between a path's lerped heights and the surface, walking each segment over
	-- the surface in 0.05-stud steps (a walk follows seams, so an overhang can't fool it), and
	-- whether every walk reached its waypoint.
	local function drift(mesh: any, path: any): (number, boolean)
		local worst, reached = 0, true
		local w = path.Waypoints
		for i = 1, #w - 1 do
			if w[i].Label then
				continue
			end
			local a, b = w[i].Position, w[i + 1].Position
			local n = math.max(1, math.ceil(vector.magnitude(b - a) / 0.05))
			local p = a
			for s = 1, n do
				local target = a + (b - a) * (s / n)
				p = NavMesh.MoveAlongSurface(mesh, p, target).Position
				worst = math.max(worst, math.abs(p.Y - target.Y))
			end
			reached = reached and math.abs(p.X - b.X) + math.abs(p.Z - b.Z) < 1e-3
		end
		return worst, reached
	end

	describe("Waypoints at seams and creases", function()
		test("a path up a ramp gets a waypoint at its foot and its top (repro 7)", function()
			local path = NavMesh.FindPath(overhang, v(2, 0, 10), v(48, 5, 10))
			expect(path.Status).is("Success")
			local rows = {}
			for _, w in path.Waypoints do
				table.insert(rows, `{fmt(w.Position)} {w.Floor}`)
			end
			expect(table.concat(rows, " | ")).is(
				"2.000,0.000,10.000 Ground | 10.000,0.000,10.000 Ground | 20.000,5.000,10.000 Ramp | 48.000,5.000,10.000 Top"
			)
		end)

		test("a path over a roof's ridge gets a waypoint on the ridge, one on a single slope none", function()
			local over = NavMesh.FindPath(roof, v(2, 0, 3), v(18, 0, 17))
			expect(#over.Waypoints).is(3)
			expect(fmt(over.Waypoints[2].Position)).is("10.000,4.000,10.000")
			local along = NavMesh.FindPath(roof, v(1, 0, 1), v(9, 0, 19))
			expect(#along.Waypoints).is(2)
		end)

		test("heights lerped between waypoints stay on the surface", function()
			math.randomseed(25)
			-- A hilly floor: a ring with uneven heights, and a crate.
			local hills = NavMesh.Build {
				Floors = {
					Hills = {
						Walkable = {
							{
								v(0, 0, 0),
								v(12, 3.3, 0),
								v(24, 0.7, 0),
								v(30, 2.1, 9),
								v(30, -1.9, 21),
								v(18, 4.6, 24),
								v(6, 1.3, 24),
								v(0, -0.4, 12),
							},
						},
						Obstacles = { rect(0, 13, 9, 16, 13) },
					},
				},
			}
			local cases = {
				{ overhang, 2, 48, 0, 20, 0 },
				{ overhang, 2, 48, 0, 20, 2 },
				{ roof, 0, 20, 0, 20, 0 },
				{ hills, 0, 30, 0, 24, 2 },
			}
			local checked = 0
			for c, case in cases do
				local mesh, x0, x1, z0, z1 = case[1], case[2], case[3], case[4], case[5]
				for _ = 1, 25 do
					local from = v(x0 + math.random() * (x1 - x0), 6, z0 + math.random() * (z1 - z0))
					local to = v(x0 + math.random() * (x1 - x0), 6, z0 + math.random() * (z1 - z0))
					local a = NavMesh.FindNearestPoint(mesh, from, nil, 30)
					local b = NavMesh.FindNearestPoint(mesh, to, nil, 30)
					if a == nil or b == nil then
						continue
					end
					local path = NavMesh.FindPath(mesh, a.Position, b.Position, { AgentRadius = case[6] * 0.25 })
					if path.Status ~= "Success" then
						continue
					end
					checked += 1
					local worst, reached = drift(mesh, path)
					expect(reached).with_context(`case {c}: {fmt(a.Position)} -> {fmt(b.Position)}`).is_true()
					-- The tolerance is 0.01; the rest is f32 heights.
					expect(worst <= 0.0101)
						.with_context(`case {c}: {fmt(a.Position)} -> {fmt(b.Position)} drifts {worst}`)
						.is_true()
				end
			end
			expect(checked > 60).with_context(`{checked} checked`).is_true()
		end)

		test("a flat floor gets no waypoint that doesn't turn", function()
			math.randomseed(7)
			local court = NavMesh.Build(Fixtures.Courtyard.Desc)
			local turns = 0
			for _ = 1, 60 do
				local a = NavMesh.FindRandomPoint(court)
				local b = NavMesh.FindRandomPoint(court)
				local path = NavMesh.FindPath(court, (a :: any).Position, (b :: any).Position, { AgentRadius = 0.5 })
				local w = path.Waypoints
				for i = 2, #w - 1 do
					local p, q, r = w[i - 1].Position, w[i].Position, w[i + 1].Position
					local cross = (q.X - p.X) * (r.Z - p.Z) - (q.Z - p.Z) * (r.X - p.X)
					expect(cross ~= 0).with_context(`waypoint {i} of {fmt(p)} -> {fmt(r)}`).is_true()
					turns += 1
				end
			end
			expect(turns > 20).is_true() -- not vacuous
		end)
	end)

	describe("PathResult.Length", function()
		test("is the 3D length of the polyline, link hops included", function()
			local function polyline(path: any): number
				local length = 0
				for i = 2, #path.Waypoints do
					length += vector.magnitude(path.Waypoints[i].Position - path.Waypoints[i - 1].Position)
				end
				return length
			end
			local up = NavMesh.FindPath(overhang, v(2, 0, 10), v(48, 5, 10))
			-- 8 on the ground, the ramp's slope (10 by 5), 28 on top.
			expect(math.abs(up.Length - (8 + math.sqrt(125) + 28)) < 1e-4).with_context(up.Length).is_true()
			local jump = NavMesh.FindPath(NavMesh.Build(Fixtures.LinkJump.Desc), v(5, 0, 5), v(20, 0, 2))
			expect(jump.Status).is("Success")
			expect(#jump.Waypoints > 3).is_true()
			expect(math.abs(jump.Length - polyline(jump)) < 1e-4).is_true()
			local nowhere = NavMesh.FindPath(overhang, v(-50, 0, 0), v(48, 5, 10))
			expect(nowhere.Status).is("NoStart")
			expect(nowhere.Length).is(0)
			expect(NavMesh.FindPath(overhang, v(2, 0, 10), v(-50, 0, 0)).Length).is(0)
		end)
	end)
end
