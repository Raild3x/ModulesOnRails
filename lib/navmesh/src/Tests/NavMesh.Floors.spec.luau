-- Authors: Logan Hunt (Raildex)
-- September 27, 2026
-- Floors, seams and links (ticket 16): seam portals between floors (ruling: overlap portals),
-- link labels, one-way links, link costs in the heuristic (SR7), toggles and IsPathValid (SR5).

return function(t: tiniest)
	local NavMesh = require("../NavMesh")
	local Storage = require("../Storage")

	local describe = t.describe
	local expect = t.expect
	local test = t.test

	local Fixtures = NavMesh.Fixtures

	local function v(x: number, y: number, z: number): any
		return vector.create(x, y, z)
	end

	local function flat(y: number, xz: { number }): any
		local ring = {}
		for i = 1, #xz, 2 do
			table.insert(ring, vector.create(xz[i], y, xz[i + 1]))
		end
		return ring
	end

	local function floors(path: NavMesh.PathResult): string
		local names = {}
		for _, w in path.Waypoints do
			if names[#names] ~= w.Floor then
				table.insert(names, w.Floor)
			end
		end
		return table.concat(names, ">")
	end

	local function labels(path: NavMesh.PathResult): string
		local found = {}
		for i, w in path.Waypoints do
			if w.Label then
				table.insert(found, `{i}:{w.Label}`)
			end
		end
		return table.concat(found, ",")
	end

	describe("Seams", function()
		test("a path climbs from Ground over the Stairs onto Upper, and back", function()
			local mesh = NavMesh.Build(Fixtures.ThreeFloorStairs.Desc)
			local up = NavMesh.FindPath(mesh, v(2, 0, 2), v(30, 5, 10))
			expect(up.Status).is("Success")
			local first, last = up.Waypoints[1], up.Waypoints[#up.Waypoints]
			expect(first.Floor).is("Ground")
			expect(last.Floor).is("Upper")
			expect(last.Position.Y).is(5)
			expect(NavMesh.IsPathValid(mesh, up)).is_true()
			local down = NavMesh.FindPath(mesh, v(30, 5, 10), v(2, 0, 2))
			expect(down.Status).is("Success")
			expect(down.Waypoints[#down.Waypoints].Floor).is("Ground")
		end)

		test("Ground runs on under the ramp: a seam edge can lead onto either floor", function()
			local mesh = NavMesh.Build(Fixtures.ThreeFloorStairs.Desc)
			-- Under the ramp, and far along Ground under the mezzanine.
			expect(floors(NavMesh.FindPath(mesh, v(15, 0, 2), v(2, 0, 18)))).is("Ground")
			expect(floors(NavMesh.FindPath(mesh, v(2, 0, 2), v(30, 0, 10)))).is("Ground")
		end)

		test("seam edges are open, not walls, so agents fit across them", function()
			local mesh = NavMesh.Build(Fixtures.ThreeFloorStairs.Desc)
			local open = 0
			for tri = 1, Storage.TriangleCount(mesh) do
				for e = 1, 3 do
					if Storage.IsEdgeOpen(mesh, tri, e) then
						open += 1
						expect(Storage.IsWallEdge(mesh, tri, e)).is(false)
					end
				end
			end
			-- The ramp's two ends and Upper's edge. Ground's seam edge keeps a Ground neighbour on both sides.
			expect(open).is(3)
			-- The ramp is 4 wide.
			expect(NavMesh.FindPath(mesh, v(2, 0, 2), v(30, 5, 10), { AgentRadius = 1.5 }).Status).is("Success")
			expect(NavMesh.FindPath(mesh, v(2, 0, 2), v(30, 5, 10), { AgentRadius = 2.5 }).Status).is("Partial")
		end)

		test("a small agent crosses a narrow seam up to half its width, and no wider", function()
			-- A 0.75-wide bridge floor between two pads, joined by seams at x = 6 and x = 14.
			local mesh = NavMesh.Build {
				Floors = {
					West = { Walkable = { flat(0, { 0, 0, 6, 0, 6, 6, 0, 6 }) } },
					Bridge = { Walkable = { flat(0, { 6, 2.625, 14, 2.625, 14, 3.375, 6, 3.375 }) } },
					East = { Walkable = { flat(0, { 14, 0, 20, 0, 20, 6, 14, 6 }) } },
				},
				Seams = {
					{ FloorA = "West", FloorB = "Bridge", From = v(6, 0, 2.625), To = v(6, 0, 3.375) },
					{ FloorA = "Bridge", FloorB = "East", From = v(14, 0, 2.625), To = v(14, 0, 3.375) },
				},
			}
			local function status(radius: number): string
				return NavMesh.FindPath(mesh, v(2, 0, 3), v(18, 0, 3), { AgentRadius = radius }).Status
			end
			expect(status(0.3)).is("Success")
			expect(status(0.375)).is("Success") -- exactly half the width
			expect(status(0.4)).is("Partial")
			-- From a start on the bridge itself (entered by no edge): the portal widths apply.
			expect(NavMesh.FindPath(mesh, v(10, 0, 3), v(18, 0, 3), { AgentRadius = 0.375 }).Status).is("Success")
			expect(NavMesh.FindPath(mesh, v(10, 0, 3), v(18, 0, 3), { AgentRadius = 0.4 }).Status).is("Partial")
		end)

		test("a non-planar floor's creases never become seam portals", function()
			-- A twisted quad (its diagonal is a crease) joined along x = 0 to a flat pad.
			local mesh = NavMesh.Build {
				TileSize = 4,
				Floors = {
					Twisted = { Walkable = { { v(0, 0, 0), v(10, 0, 0), v(10, 2, 10), v(0, 0, 10) } } },
					Pad = { Walkable = { flat(0, { -10, 0, 0, 0, 0, 10, -10, 10 }) } },
				},
				Seams = { { FloorA = "Twisted", FloorB = "Pad", From = v(0, 0, 0), To = v(0, 0, 10) } },
			}
			local portals = 0
			for tri = 1, Storage.TriangleCount(mesh) do
				local id = Storage.GetExtraHead(mesh, tri)
				while id ~= 0 do
					local nextId, _, kind, _, a, b = Storage.GetExtra(mesh, id)
					if kind == Storage.EXTRA_SEAM then
						portals += 1
						expect(a.X == 0 and b.X == 0).with_context(`portal {id}: {a} {b}`).is_true()
					end
					id = nextId
				end
			end
			expect(portals > 0).is_true()
		end)

		test("a seam at 45 degrees joins its floors like any other", function()
			local mesh = NavMesh.Build {
				Floors = {
					Below = { Walkable = { flat(0, { 0, 0, 10, 0, 10, 10 }) } },
					Above = { Walkable = { flat(0, { 0, 0, 10, 10, 0, 10 }) } },
				},
				Seams = { { FloorA = "Below", FloorB = "Above", From = v(0, 0, 0), To = v(10, 0, 10) } },
			}
			local path = NavMesh.FindPath(mesh, v(8, 0, 2), v(2, 0, 8))
			expect(path.Status).is("Success")
			expect(floors(path)).is("Below>Above")
			expect((NavMesh.Raycast(mesh, v(8, 0, 2), v(2, 0, 8)))).is(false)
		end)

		test("an excluded area on the stairs cuts the floors apart", function()
			local desc: any = table.clone(Fixtures.ThreeFloorStairs.Desc)
			desc.Floors = table.clone(desc.Floors)
			desc.Floors.Stairs = { Walkable = desc.Floors.Stairs.Walkable, Area = 2 }
			local mesh = NavMesh.Build(desc)
			local path = NavMesh.FindPath(mesh, v(2, 0, 2), v(30, 5, 10), { AreaCosts = { [2] = math.huge } })
			expect(path.Status).is("Partial")
		end)

		test("a wall corner at a seam's end is passed at the agent's radius, on either floor (SR4)", function()
			-- A ramp between two pads, seams at both ends. Every seam end is a wall corner: on both
			-- floors for the ramp (Ground and Top stop or turn there), on the ramp only for the
			-- stairs fixture's (10, 4), where Ground runs on under the stairs.
			local ramp = NavMesh.Build {
				Floors = {
					Ground = { Walkable = { flat(0, { 0, 0, 10, 0, 10, 20, 0, 20 }) } },
					Ramp = { Walkable = { { v(10, 0, 8), v(20, 5, 8), v(20, 5, 12), v(10, 0, 12) } } },
					Top = { Walkable = { flat(5, { 20, 0, 30, 0, 30, 20, 20, 20 }) } },
				},
				Seams = {
					{ FloorA = "Ground", FloorB = "Ramp", From = v(10, 0, 8), To = v(10, 0, 12) },
					{ FloorA = "Ramp", FloorB = "Top", From = v(20, 5, 8), To = v(20, 5, 12) },
				},
			}
			local stairs = NavMesh.Build(Fixtures.ThreeFloorStairs.Desc)
			-- The ramp fixture's floors don't overlap in plan, so its walls can be measured in plan.
			local rampWalls = {}
			for tri = 1, Storage.TriangleCount(ramp) do
				local vs = { Storage.GetTriangle(ramp, tri) }
				for e = 1, 3 do
					if Storage.IsWallEdge(ramp, tri, e) then
						table.insert(
							rampWalls,
							{ Storage.GetVertex(ramp, vs[e % 3 + 1]), Storage.GetVertex(ramp, vs[(e + 1) % 3 + 1]) }
						)
					end
				end
			end
			-- Plan distance between segments pq and ab (they never cross here: sample pq finely).
			local function segDistance(p: vector, q: vector, a: vector, b: vector): number
				local best = math.huge
				local dx, dz = b.X - a.X, b.Z - a.Z
				for s = 0, 200 do
					local x, z = p.X + (q.X - p.X) * s / 200, p.Z + (q.Z - p.Z) * s / 200
					local u = math.clamp(((x - a.X) * dx + (z - a.Z) * dz) / (dx * dx + dz * dz), 0, 1)
					best = math.min(best, math.sqrt((a.X + u * dx - x) ^ 2 + (a.Z + u * dz - z) ^ 2))
				end
				return best
			end
			local cases = {
				-- mesh, from, to, radius, the seam corners the path turns round, walls to measure the path against
				{ ramp, v(2, 0, 2), v(28, 5, 18), 1.5, { v(10, 0, 8), v(20, 5, 12) }, rampWalls },
				{ ramp, v(28, 5, 18), v(2, 0, 2), 1.5, { v(10, 0, 8), v(20, 5, 12) }, rampWalls }, -- lefts and rights swap
				{ ramp, v(2, 0, 2), v(28, 5, 18), 0.5, { v(10, 0, 8), v(20, 5, 12) }, rampWalls },
				-- (10, 4) is a wall corner of Stairs only: Ground runs on under the stairs.
				{ stairs, v(2, 0, 12), v(30, 5, 2), 1, { v(10, 0, 4) }, {} },
				{ stairs, v(30, 5, 2), v(2, 0, 12), 1, { v(10, 0, 4) }, {} },
			}
			for i, case in cases do
				local mesh, r, corners, walls = case[1], case[4], case[5], case[6]
				local path = NavMesh.FindPath(mesh, case[2], case[3], { AgentRadius = r })
				expect(path.Status).with_context(`case {i}`).is("Success")
				local w = path.Waypoints
				-- As at a flat corner (Clearance spec): the path turns r from the corner, not at it.
				for k, waypoint in w do
					local p = waypoint.Position :: any
					for _, c in corners do
						local d = math.sqrt((p.X - c.X) ^ 2 + (p.Z - c.Z) ^ 2)
						expect(d >= r - 1e-6).with_context(`case {i}: waypoint {k} is {d} from {c}`).is_true()
					end
				end
				-- Between two turns the straight segment is not offset (Funnel docs: no general bound
				-- holds there). On this fixture it stays at least r/2 from the walls; before the fix
				-- it touched the corner.
				for k = 1, #w - 1 do
					for _, wall in walls do
						local d = segDistance(w[k].Position :: any, w[k + 1].Position :: any, wall[1], wall[2])
						expect(d >= r / 2).with_context(`case {i}: segment {k} comes {d} from a wall`).is_true()
					end
				end
			end
		end)

		test("a point on a floor stays on it next to a seam at the same height (snap tie-break)", function()
			-- Ramp and Top meet at x = 20, both at y = 5 there. A feet point on Top, 0.32 from the
			-- seam, is at vertical distance 0 from both: it must stay where it is, on Top, not
			-- slide onto the Ramp's edge (x = 20) inside the 0.5-stud snap box.
			local mesh = NavMesh.Build {
				Floors = {
					Ground = { Walkable = { flat(0, { 0, 0, 10, 0, 10, 20, 0, 20 }) } },
					Ramp = { Walkable = { { v(10, 0, 8), v(20, 5, 8), v(20, 5, 12), v(10, 0, 12) } } },
					Top = { Walkable = { flat(5, { 20, 0, 30, 0, 30, 20, 20, 20 }) } },
				},
				Seams = {
					{ FloorA = "Ground", FloorB = "Ramp", From = v(10, 0, 8), To = v(10, 0, 12) },
					{ FloorA = "Ramp", FloorB = "Top", From = v(20, 5, 8), To = v(20, 5, 12) },
				},
			}
			local feet = v(20.32, 5, 11.62)
			local function same(p: any): boolean
				return math.abs(p.X - feet.X) < 1e-4 and math.abs(p.Y - feet.Y) < 1e-4 and math.abs(p.Z - feet.Z) < 1e-4
			end
			local snapped = NavMesh.FindNearestPoint(mesh, feet) :: NavMesh.NavPoint
			expect(snapped.Floor).is("Top")
			expect(same(snapped.Position)).with_context(`snapped to {snapped.Position}`).is_true()
			-- The nearest wall is the corner (20, 12), not the Ramp's edge line through it.
			local d = NavMesh.FindDistanceToWall(mesh, feet, 10)
			local corner = math.sqrt(0.32 ^ 2 + 0.38 ^ 2) -- 0.4968
			expect(math.abs(d - corner) < 1e-3).with_context(`distance {d}`).is_true()
			-- FindPath starts where the agent stands.
			local path = NavMesh.FindPath(mesh, feet, v(28, 5, 18))
			expect(path.Waypoints[1].Floor).is("Top")
			expect(same(path.Waypoints[1].Position)).is_true()
			-- On the seam itself both floors contain the point: it stays put, on either floor.
			local onSeam = NavMesh.FindNearestPoint(mesh, v(20, 5, 10)) :: NavMesh.NavPoint
			expect(vector.magnitude((onSeam.Position :: any) - v(20, 5, 10)) < 1e-4).is_true()
		end)
	end)

	describe("Links", function()
		test("a link's label rides on the waypoint where it starts, both ways", function()
			local mesh = NavMesh.Build(Fixtures.LinkJump.Desc)
			local there = NavMesh.FindPath(mesh, v(2, 0, 2), v(22, 0, 8))
			expect(there.Status).is("Success")
			expect(labels(there)).is("2:Jump")
			expect(there.Waypoints[2].Position.X).is(9)
			expect(there.Waypoints[3].Position.X).is(15)
			local back = NavMesh.FindPath(mesh, v(22, 0, 8), v(2, 0, 2))
			expect(back.Status).is("Success")
			expect(labels(back)).is("2:Jump")
			expect(back.Waypoints[2].Position.X).is(15)
		end)

		test("a one-way link only goes one way", function()
			local mesh = NavMesh.Build(Fixtures.OneWayLink.Desc)
			local drop = NavMesh.FindPath(mesh, v(2, 4, 2), v(20, 0, 8))
			expect(drop.Status).is("Success")
			expect(floors(drop)).is("Ledge>Ground")
			expect(labels(drop)).is("2:Drop")
			expect(NavMesh.FindPath(mesh, v(20, 0, 8), v(2, 4, 2)).Status).is("Partial")
		end)

		test("a cheap link wins over a long walk, a dear one doesn't (SR7)", function()
			local corridor = { Walkable = { flat(0, { 0, 0, 40, 0, 40, 4, 0, 4 }) } }
			local function via(cost: number): NavMesh.PathResult
				local mesh = NavMesh.Build {
					Floors = { Ground = corridor },
					Links = { { From = v(1, 0, 2), To = v(39, 0, 2), Cost = cost, Label = "Warp" } },
				}
				return NavMesh.FindPath(mesh, v(1, 0, 2), v(39, 0, 2))
			end
			local cheap = via(1)
			expect(labels(cheap)).is("1:Warp")
			expect(cheap.Cost).is(1)
			local dear = via(100)
			expect(labels(dear)).is("")
			expect(math.abs(dear.Cost - 38) < 1e-6).is_true()
			-- A free link makes the heuristic 0 (Dijkstra) and is still taken.
			expect(via(0).Cost).is(0)
		end)

		test("a link defaults to its length as Cost and area 1, and snaps ends authored off the mesh", function()
			local mesh = NavMesh.Build(Fixtures.LinkJump.Desc)
			expect(math.abs(NavMesh.FindPath(mesh, v(9, 0, 5), v(15, 0, 5)).Cost - 6) < 1e-6).is_true()
			-- Area 1's multiplier prices the link (and the pads, walked for zero distance here).
			local dear = NavMesh.FindPath(mesh, v(9, 0, 5), v(15, 0, 5), { AreaCosts = { [1] = 2 } })
			expect(math.abs(dear.Cost - 12) < 1e-6).with_context(`cost {dear.Cost}`).is_true()
			-- Ends 0.3 off the pads in X or Z, 3 above or 2 below: within the link snap.
			local loose: any = table.clone(Fixtures.LinkJump.Desc)
			loose.Links = {
				{ From = v(10.3, 3, 5), To = v(14, -2, 10.3), Label = "Loose" },
				{ From = v(24.3, 0, 5), To = v(5, 0, -0.3), Bidirectional = false },
			}
			local mesh2 = NavMesh.Build(loose)
			expect(labels(NavMesh.FindPath(mesh2, v(2, 0, 2), v(22, 0, 8)))).is("2:Loose")
			local _, from, _, to = Storage.GetLink(mesh2, 2)
			expect(from.X == 24 and to.Z == 0).is_true()
		end)

		test("a link's area is filtered like a surface area", function()
			local mesh = NavMesh.Build {
				Floors = { Ground = { Walkable = { flat(0, { 0, 0, 40, 0, 40, 4, 0, 4 }) } } },
				Links = { { From = v(1, 0, 2), To = v(39, 0, 2), Cost = 1, Area = 5 } },
			}
			expect(NavMesh.FindPath(mesh, v(1, 0, 2), v(39, 0, 2)).Cost).is(1)
			local walked = NavMesh.FindPath(mesh, v(1, 0, 2), v(39, 0, 2), { AreaCosts = { [5] = math.huge } })
			expect(math.abs(walked.Cost - 38) < 1e-6).is_true()
			-- Its multiplier scales its cost.
			expect(NavMesh.FindPath(mesh, v(1, 0, 2), v(39, 0, 2), { AreaCosts = { [5] = 3 } }).Cost).is(3)
		end)

		test("toggling a link invalidates paths through its tiles, and nothing else (SR5)", function()
			local desc: any = table.clone(Fixtures.LinkJump.Desc)
			desc.TileSize = 4
			local mesh = NavMesh.Build(desc)
			local jump = NavMesh.FindPath(mesh, v(2, 0, 2), v(22, 0, 8))
			local elsewhere = NavMesh.FindPath(mesh, v(20, 0, 1), v(23, 0, 1))
			expect(NavMesh.IsPathValid(mesh, jump)).is_true()
			NavMesh.SetLinkEnabled(mesh, 1, false)
			expect(NavMesh.IsPathValid(mesh, jump)).is(false)
			expect(NavMesh.IsPathValid(mesh, elsewhere)).is_true()
			expect(NavMesh.FindPath(mesh, v(2, 0, 2), v(22, 0, 8)).Status).is("Partial")
			-- Enabling invalidates too (conservative both ways).
			local stuck = NavMesh.FindPath(mesh, v(8, 0, 5), v(9, 0, 6))
			NavMesh.SetLinkEnabled(mesh, 1, true)
			expect(NavMesh.IsPathValid(mesh, stuck)).is(false)
			expect(NavMesh.FindPath(mesh, v(2, 0, 2), v(22, 0, 8)).Status).is("Success")
			expect(function()
				NavMesh.SetLinkEnabled(mesh, 2, true)
			end).fails_with("no link 2")
			expect(function()
				NavMesh.SetLinkEnabled(mesh, 1, "yes" :: any)
			end).fails_with("must be a boolean")
			for _, id in { 0, 1.5, true } do
				expect(function()
						NavMesh.SetLinkEnabled(mesh, id :: any, true)
					end)
					.with_context(tostring(id))
					.fails_with(`no link {id}`)
			end
			-- A string is a name (ticket 25); no link has one here.
			expect(function()
				NavMesh.SetLinkEnabled(mesh, "1", true)
			end).fails_with("no link named '1'")
			for i, call in
				{
					function()
						NavMesh.SetLinkEnabled(mesh, 2, true)
					end,
					function()
						NavMesh.SetLinkEnabled(mesh, 1, "yes" :: any)
					end,
				}
			do
				local ok, err = pcall(call)
				expect(ok).is(false)
				expect(tostring(err):find("Floors.spec", 1, true) ~= nil).with_context(`call {i}: {err}`).is_true()
			end
		end)

		test("toggling a link with a covered end bumps only its other end's tile", function()
			local desc: any = table.clone(Fixtures.LinkJump.Desc)
			desc.TileSize = 4
			local mesh = NavMesh.Build(desc)
			NavMesh.AddObstacle(mesh, "Ground", flat(0, { 8, 4, 10, 4, 10, 6, 8, 6 }))
			NavMesh.Update(mesh)
			expect((Storage.GetLink(mesh, 1))).is(0) -- the From end is under the crate
			-- A path in the first tile, far from both ends.
			local corner = NavMesh.FindPath(mesh, v(1, 0, 1), v(3, 0, 3))
			NavMesh.SetLinkEnabled(mesh, 1, false)
			expect(NavMesh.IsPathValid(mesh, corner)).is_true()
		end)
	end)

	describe("Seam and link Build errors", function()
		local ground = { Walkable = { flat(0, { 0, 0, 10, 0, 10, 10, 0, 10 }) } }
		local cases = {
			{
				"a seam off a floor",
				{
					Floors = { A = ground, B = { Walkable = { flat(0, { 10, 0, 20, 0, 20, 10, 10, 10 }) } } },
					Seams = { { FloorA = "A", FloorB = "B", From = v(30, 0, 0), To = v(30, 0, 5) } },
				},
				"seam 1: does not lie on floor",
			},
			{
				"a seam on one floor's edge but off the other",
				{
					Floors = { A = ground, B = { Walkable = { flat(0, { 20, 0, 30, 0, 30, 10, 20, 10 }) } } },
					Seams = { { FloorA = "A", FloorB = "B", From = v(10, 0, 0), To = v(10, 0, 5) } },
				},
				"does not lie on floor 'B'",
			},
			{
				-- Not an obstacle cutting the seam away (ticket 37): it never lay on B.
				"a seam off a floor that has obstacles",
				{
					Floors = {
						A = ground,
						B = {
							Walkable = { flat(0, { 20, 0, 30, 0, 30, 10, 20, 10 }) },
							Obstacles = { flat(0, { 22, 2, 24, 2, 24, 4, 22, 4 }) },
						},
					},
					Seams = { { FloorA = "A", FloorB = "B", From = v(10, 0, 0), To = v(10, 0, 5) } },
				},
				"does not lie on floor 'B'",
			},
			{
				"floors on the same side of a seam",
				{
					Floors = { A = ground, B = { Walkable = { flat(0, { 5, 0, 10, 0, 10, 10, 5, 10 }) } } },
					Seams = { { FloorA = "A", FloorB = "B", From = v(10, 0, 0), To = v(10, 0, 5) } },
				},
				"don't meet across it",
			},
			{
				-- An obstacle cutting part of the seam away doesn't hide it (ticket 37).
				"floors on the same side of a seam, one partly cut",
				{
					Floors = {
						A = { Walkable = ground.Walkable, Obstacles = { flat(0, { 8, 1, 11, 1, 11, 3, 8, 3 }) } },
						B = { Walkable = { flat(0, { 5, 0, 10, 0, 10, 10, 5, 10 }) } },
					},
					Seams = { { FloorA = "A", FloorB = "B", From = v(10, 0, 0), To = v(10, 0, 5) } },
				},
				"don't meet across it",
			},
			{
				"floors at different heights along a seam",
				{
					Floors = { A = ground, B = { Walkable = { flat(3, { 10, 0, 20, 0, 20, 10, 10, 10 }) } } },
					Seams = { { FloorA = "A", FloorB = "B", From = v(10, 0, 0), To = v(10, 0, 5) } },
				},
				"at different heights along it",
			},
			{
				"a seam joining a floor to itself",
				{
					Floors = { A = ground },
					Seams = { { FloorA = "A", FloorB = "A", From = v(0, 0, 0), To = v(5, 0, 0) } },
				},
				"joins a floor to itself",
			},
			{
				"a zero-length seam",
				{
					Floors = { A = ground, B = ground },
					Seams = { { FloorA = "A", FloorB = "B", From = v(1, 0, 1), To = v(1.001, 0, 1) } },
				},
				"zero length",
			},
			{
				"a link off the mesh",
				{ Floors = { A = ground }, Links = { { From = v(1, 0, 1), To = v(50, 0, 1) } } },
				"link 1: To %(50",
			},
			{
				"a negative link cost",
				{ Floors = { A = ground }, Links = { { From = v(1, 0, 1), To = v(5, 0, 1), Cost = -1 } } },
				"Cost must be",
			},
			{
				"a bad link label",
				{ Floors = { A = ground }, Links = { { From = v(1, 0, 1), To = v(5, 0, 1), Label = 3 } } },
				"Label must be a string",
			},
			{
				"an infinite link cost",
				{ Floors = { A = ground }, Links = { { From = v(1, 0, 1), To = v(5, 0, 1), Cost = math.huge } } },
				"Cost must be",
			},
			{
				"a link end that is not a vector",
				{ Floors = { A = ground }, Links = { { From = 5, To = v(5, 0, 1) } } },
				"link 1: From must be a Vector3",
			},
		}
		for _, case in cases do
			test(`errors on {case[1]}`, function()
				expect(function()
					NavMesh.Build(case[2] :: any)
				end).fails_with(case[3])
			end)
		end
	end)

	describe("Drawing", function()
		test("seams and links draw on their own layers", function()
			local count = function(list: any, layer: string): number
				local n = 0
				for _, primitive in list do
					if primitive.Layer == layer then
						n += 1
					end
				end
				return n
			end
			local stairs = NavMesh.ToDrawList(NavMesh.Build(Fixtures.ThreeFloorStairs.Desc), { Seams = true })
			expect(count(stairs, "Seams") >= 2).is_true()
			local jump = NavMesh.ToDrawList(NavMesh.Build(Fixtures.LinkJump.Desc), { Links = true })
			expect(count(jump, "Links")).is(2) -- two-way: an arrow each way
			local drop = NavMesh.ToDrawList(NavMesh.Build(Fixtures.OneWayLink.Desc), { Links = true })
			expect(count(drop, "Links")).is(1)
		end)
	end)
end
