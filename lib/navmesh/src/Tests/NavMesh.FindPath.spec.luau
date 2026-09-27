-- Authors: Logan Hunt (Raildex)
-- September 27, 2026
-- FindPath (ticket 14): snapping from feet positions (U-b), A* with the SR7 heuristic, the
-- funnel at radius 0, and all five statuses.

return function(t: tiniest)
	local NavMesh = require("../NavMesh")
	local Snap = require("../Snap")
	local Storage = require("../Storage")

	local describe = t.describe
	local expect = t.expect
	local test = t.test

	local function flat(y: number, xz: { number }): any
		local ring = {}
		for i = 1, #xz, 2 do
			table.insert(ring, vector.create(xz[i], y, xz[i + 1]))
		end
		return ring
	end

	local function v(x: number, y: number, z: number): any
		return vector.create(x, y, z)
	end

	local function fmt(p: any): string
		return string.format("%.4f,%.4f,%.4f", p.X, p.Y, p.Z)
	end

	local function route(path: NavMesh.PathResult): string
		local parts = {}
		for _, w in path.Waypoints do
			table.insert(parts, fmt(w.Position))
		end
		return table.concat(parts, " ")
	end

	-- Every segment of the path, sampled finely, lies on a triangle the filter allows.
	local function offMesh(mesh: any, path: NavMesh.PathResult, costs: { [number]: number }?): { string }
		local found = {}
		local extents = vector.create(1e-3, 1e-3, 1e-3)
		local waypoints = path.Waypoints
		for i = 2, #waypoints do
			local p, q = waypoints[i - 1].Position :: any, waypoints[i].Position :: any
			for k = 0, 20 do
				local x = p + (q - p) * (k / 20)
				local tri = Snap.Snap(mesh, x, extents, costs or {})
				if tri == 0 then
					table.insert(found, `segment {i - 1} leaves the mesh at {fmt(x)}`)
				end
			end
		end
		return found
	end

	local square: any = { Floors = { Ground = { Walkable = { flat(0, { 0, 0, 20, 0, 20, 20, 0, 20 }) } } } }
	-- A wall from the south edge to z = 15 splits the square except over its top.
	local walled: any = {
		Floors = {
			Ground = {
				Walkable = { flat(0, { 0, 0, 20, 0, 20, 20, 0, 20 }) },
				Obstacles = { flat(0, { 8, -1, 12, -1, 12, 15, 8, 15 }) },
			},
		},
	}
	local islands: any = {
		Floors = {
			Ground = {
				Walkable = { flat(0, { 0, 0, 10, 0, 10, 10, 0, 10 }), flat(0, { 20, 0, 30, 0, 30, 10, 20, 10 }) },
			},
		},
	}
	-- From (2, 1) to (38, 1): a direct strip along the south edge (area 1, 36 studs), or a
	-- 110-stud loop around the block through area 2.
	local loop: any = {
		Floors = {
			Ground = {
				Walkable = { flat(0, { 0, 0, 40, 0, 40, 40, 0, 40 }) },
				Obstacles = { flat(0, { 4, 2, 36, 2, 36, 36, 4, 36 }) },
				Areas = {
					{ Polygon = flat(0, { 0, 2, 4, 2, 4, 40, 0, 40 }), Area = 2 },
					{ Polygon = flat(0, { 4, 36, 36, 36, 36, 40, 4, 40 }), Area = 2 },
					{ Polygon = flat(0, { 36, 2, 40, 2, 40, 40, 36, 40 }), Area = 2 },
				},
			},
		},
	}
	local stacked: any = {
		Floors = {
			Ground = { Walkable = { flat(0, { 0, 0, 10, 0, 10, 10, 0, 10 }) } },
			Upper = { Walkable = { flat(3, { 0, 0, 10, 0, 10, 10, 0, 10 }) } },
		},
	}

	describe("FindPath", function()
		test("an open floor gives a straight two-waypoint path", function()
			local mesh = NavMesh.Build(square)
			local path = NavMesh.FindPath(mesh, v(1, 0, 1), v(19, 0, 17))
			expect(path.Status).is("Success")
			expect(route(path)).is("1.0000,0.0000,1.0000 19.0000,0.0000,17.0000")
			expect(path.Waypoints[1].Floor).is("Ground")
			expect(#path.TileStamps).is(0)
		end)

		test("the funnel bends only at the wall's corners", function()
			local mesh = NavMesh.Build(walled)
			local path = NavMesh.FindPath(mesh, v(2, 0, 2), v(18, 0, 2))
			expect(path.Status).is("Success")
			expect(route(path)).is(
				"2.0000,0.0000,2.0000 8.0000,0.0000,15.0000 12.0000,0.0000,15.0000 18.0000,0.0000,2.0000"
			)
			-- The search cost runs between edge midpoints, so it is at least the smoothed length.
			local length = 2 * math.sqrt(6 * 6 + 13 * 13) + 4
			expect(path.Cost >= length - 1e-6).with_context(`cost {path.Cost} < length {length}`).is_true()
		end)

		test("heights follow the surface, and waypoints keep them", function()
			local mesh = NavMesh.Build(NavMesh.Fixtures.SplitLevel.Desc)
			local path = NavMesh.FindPath(mesh, v(2, 0, 5), v(18, 4, 5))
			expect(path.Status).is("Success")
			local last = path.Waypoints[#path.Waypoints].Position
			expect(fmt(last)).is("18.0000,4.0000,5.0000")
		end)

		test("paths over the Courtyard stay on the mesh", function()
			local mesh = NavMesh.Build(NavMesh.Fixtures.Courtyard.Desc)
			local spots =
				{ v(1, 0, 1), v(29, 0, 1), v(29, 0, 19), v(1, 0, 29), v(17, 0, 29), v(14, 0, 18), v(6, 0, 10) }
			local successes = 0
			for _, a in spots do
				for _, b in spots do
					local path = NavMesh.FindPath(mesh, a, b)
					if path.Status == "Success" then
						successes += 1
					end
					expect(table.concat(offMesh(mesh, path), "\n")).is("")
				end
			end
			expect(successes).is(#spots * #spots)
		end)

		test("repeated and interleaved queries reuse scratch without leaking state", function()
			local mesh = NavMesh.Build(walled)
			local other = NavMesh.Build(NavMesh.Fixtures.Courtyard.Desc)
			local first = route(NavMesh.FindPath(mesh, v(2, 0, 2), v(18, 0, 2)))
			NavMesh.FindPath(other, v(1, 0, 1), v(29, 0, 1))
			NavMesh.FindPath(mesh, v(18, 0, 18), v(2, 0, 18))
			expect(route(NavMesh.FindPath(mesh, v(2, 0, 2), v(18, 0, 2)))).is(first)
		end)
	end)

	describe("FindPath oracles", function()
		-- The funnel against its own corridor: every segment stays inside the corridor's
		-- triangles, and every interior corner is a corridor vertex that can't be skipped (the
		-- straight line past it leaves the corridor).
		local function funnelViolations(mesh: any, corridor: { number }, points: { vector }): { string }
			local found = {}
			local tris = {}
			local vertices = {}
			for _, tri in corridor do
				local verts = { Storage.GetTriangle(mesh, tri) }
				local P = {}
				for k = 1, 3 do
					P[k] = Storage.GetVertex(mesh, verts[k])
					vertices[fmt(P[k])] = true
				end
				table.insert(tris, P)
			end
			local function inside(x: vector): boolean
				for _, P in tris do
					local ok = true
					for k = 1, 3 do
						local a, b = P[k], P[k % 3 + 1]
						if (b.X - a.X) * (x.Z - a.Z) - (b.Z - a.Z) * (x.X - a.X) < -1e-9 then
							ok = false
							break
						end
					end
					if ok then
						return true
					end
				end
				return false
			end
			local function stays(p: vector, q: vector): boolean
				for k = 1, 99 do
					if not inside(p + (q - p) * (k / 100)) then
						return false
					end
				end
				return true
			end
			for i = 2, #points do
				if not stays(points[i - 1], points[i]) then
					table.insert(found, `segment {i - 1} leaves the corridor`)
				end
			end
			for i = 2, #points - 1 do
				if not vertices[fmt(points[i])] then
					table.insert(found, `corner {i} is not a corridor vertex`)
				elseif stays(points[i - 1], points[i + 1]) then
					table.insert(found, `corner {i} could be skipped`)
				end
			end
			return found
		end

		test("the funnel is the tight string through its corridor", function()
			local Search = require("../Search")
			local Funnel = require("../Funnel")
			local corners = 0
			for _, scenario in { NavMesh.Fixtures.Courtyard, NavMesh.Fixtures.ShallowObstacles } do
				local mesh = NavMesh.Build(scenario.Desc)
				local extents = vector.create(0.5, 4, 0.5)
				local spots = if scenario == NavMesh.Fixtures.Courtyard
					then { v(1, 0, 1), v(29, 0, 1), v(29, 0, 19), v(1, 0, 29), v(17, 0, 29), v(14, 0, 18), v(6, 0, 10) }
					else { v(1, 0, 1), v(39, 0, 19), v(20, 0, 2), v(20, 0, 18), v(1, 0, 19), v(39, 0, 1) }
				for _, a in spots do
					for _, b in spots do
						local st, sp = Snap.Snap(mesh, a, extents, {})
						local gt, gp = Snap.Snap(mesh, b, extents, {})
						local _, corridor, endP = Search.Run(mesh, st, sp :: any, gt, gp :: any, {}, math.huge, 0)
						local points = Funnel.StringPull(mesh, corridor, sp :: any, endP, 0)
						corners += #points - 2
						expect(table.concat(funnelViolations(mesh, corridor, points), "\n"))
							.with_context(`{scenario.Name} {fmt(a)} -> {fmt(b)}`)
							.is("")
					end
				end
			end
			expect(corners > 10).is_true()
		end)

		test("snapping does not depend on the tiling", function()
			for _, scenario in { NavMesh.Fixtures.Courtyard, NavMesh.Fixtures.SplitLevel } do
				local whole: any, fine: any = table.clone(scenario.Desc), table.clone(scenario.Desc)
				whole.TileSize, fine.TileSize = 1024, 2
				local a, b = NavMesh.Build(whole), NavMesh.Build(fine)
				local extents = vector.create(0.5, 4, 0.5)
				for x = -0.75, 30.75, 0.9 do
					for z = -0.75, 30.75, 0.9 do
						local feet = vector.create(x, 1.3, z)
						local ta, pa = Snap.Snap(a, feet, extents, {})
						local tb, pb = Snap.Snap(b, feet, extents, {})
						expect(ta == 0).with_context(`{scenario.Name} at {fmt(feet)}`).is(tb == 0)
						if pa and pb then
							-- Equally near, and equally high (ties may pick different points).
							local da = vector.magnitude(vector.create(pa.X - feet.X, 0, pa.Z - feet.Z))
							local db = vector.magnitude(vector.create(pb.X - feet.X, 0, pb.Z - feet.Z))
							expect(math.abs(da - db) < 1e-4 and math.abs((pa.Y - feet.Y) - (pb.Y - feet.Y)) < 1e-4)
								.with_context(`{scenario.Name} at {fmt(feet)}: {fmt(pa)} vs {fmt(pb)}`)
								.is_true()
						end
					end
				end
			end
		end)
	end)

	describe("FindPath statuses", function()
		test("NoStart and NoGoal when an end cannot be snapped", function()
			local mesh = NavMesh.Build(square)
			local noStart = NavMesh.FindPath(mesh, v(50, 0, 50), v(5, 0, 5))
			expect(noStart.Status).is("NoStart")
			expect(#noStart.Waypoints).is(0)
			local noGoal = NavMesh.FindPath(mesh, v(5, 0, 5), v(5, 9, 5))
			expect(noGoal.Status).is("NoGoal")
			expect(#noGoal.Waypoints).is(0)
			expect(noStart.Cost).is(0)
			expect(noGoal.Cost).is(0)
		end)

		test("Partial ends at the reachable point nearest the goal", function()
			local mesh = NavMesh.Build(islands)
			local path = NavMesh.FindPath(mesh, v(2, 0, 3), v(25, 0, 7))
			expect(path.Status).is("Partial")
			expect(fmt(path.Waypoints[1].Position)).is("2.0000,0.0000,3.0000")
			expect(fmt(path.Waypoints[#path.Waypoints].Position)).is("10.0000,0.0000,7.0000")
		end)

		test("Budget ends at the best point found so far", function()
			local mesh = NavMesh.Build(NavMesh.Fixtures.Courtyard.Desc)
			local goal = v(29, 0, 1)
			local full = NavMesh.FindPath(mesh, v(1, 0, 1), goal)
			expect(full.Status).is("Success")
			local path = NavMesh.FindPath(mesh, v(1, 0, 1), goal, { MaxExpansions = 3 })
			expect(path.Status).is("Budget")
			local last = path.Waypoints[#path.Waypoints].Position :: any
			expect(vector.magnitude(last - goal) < 28).is_true()
			expect(table.concat(offMesh(mesh, path), "\n")).is("")
			-- A zero budget stays in the start triangle; one expansion already gets closer.
			local none = NavMesh.FindPath(mesh, v(1, 0, 1), goal, { MaxExpansions = 0 })
			expect(none.Status).is("Budget")
			expect(none.Cost).is(0)
			local one = NavMesh.FindPath(mesh, v(1, 0, 1), goal, { MaxExpansions = 1 })
			local function reach(p: NavMesh.PathResult): number
				return vector.magnitude((p.Waypoints[#p.Waypoints].Position :: any) - goal)
			end
			expect(reach(one) < reach(none)).with_context(`{reach(one)} vs {reach(none)}`).is_true()
		end)
	end)

	describe("FindPath snapping (U-b feet positions)", function()
		test("the nearest floor vertically wins, and a tie goes below", function()
			local mesh = NavMesh.Build(stacked)
			local function floorAt(y: number): string
				local path = NavMesh.FindPath(mesh, v(5, y, 5), v(5, y, 5))
				return if path.Status == "Success" then path.Waypoints[1].Floor else path.Status
			end
			expect(floorAt(0.2)).is("Ground")
			expect(floorAt(2.8)).is("Upper")
			expect(floorAt(1.5)).is("Ground")
			expect(floorAt(-3.9)).is("Ground")
			expect(floorAt(6.9)).is("Upper")
			expect(floorAt(7.1)).is("NoStart")
		end)

		test("a point just off the edge snaps onto it, and the extents are honoured", function()
			local mesh = NavMesh.Build(square)
			local path = NavMesh.FindPath(mesh, v(20.3, 0, 5), v(10, 0, 5))
			expect(path.Status).is("Success")
			expect(fmt(path.Waypoints[1].Position)).is("20.0000,0.0000,5.0000")
			local wide = NavMesh.FindPath(mesh, v(22, 0, 5), v(10, 0, 5), { SnapExtents = v(3, 1, 3) })
			expect(wide.Status).is("Success")
			expect(NavMesh.FindPath(mesh, v(22, 0, 5), v(10, 0, 5)).Status).is("NoStart")
			-- The default extents: 0.5 across in Z too, and exactly 4 vertically.
			expect(fmt(NavMesh.FindPath(mesh, v(5, 0, -0.4), v(10, 0, 5)).Waypoints[1].Position)).is("5.0000,0.0000,0.0000")
			expect(NavMesh.FindPath(mesh, v(5, 0, -0.6), v(10, 0, 5)).Status).is("NoStart")
			expect(NavMesh.FindPath(mesh, v(5, 4, 5), v(10, 0, 5)).Status).is("Success")
			expect(NavMesh.FindPath(mesh, v(5, 4.001, 5), v(10, 0, 5)).Status).is("NoStart")
			-- A zero-size box is allowed: only the column under the feet counts.
			expect(NavMesh.FindPath(mesh, v(5, 1, 5), v(10, 0, 5), { SnapExtents = v(0, 1, 0) }).Status).is("Success")
		end)

		test("snapped points lie on a sloped surface, from above and from off its edges", function()
			-- SplitLevel's ramp runs x = 10..20 at y = 0.5 (x - 10), z = 0..10.
			local mesh = NavMesh.Build(NavMesh.Fixtures.SplitLevel.Desc)
			local function snapped(feet: any): string
				local path = NavMesh.FindPath(mesh, feet, feet)
				return if path.Status == "Success" then fmt(path.Waypoints[1].Position) else path.Status
			end
			expect(snapped(v(15, 3, 5))).is("15.0000,2.5000,5.0000")
			expect(snapped(v(13, 0.5, 7.5))).is("13.0000,1.5000,7.5000")
			expect(snapped(v(15, 2.5, 10.3))).is("15.0000,2.5000,10.0000")
			expect(snapped(v(17, 3.5, -0.2))).is("17.0000,3.5000,0.0000")
			expect(snapped(v(20.4, 5, 3))).is("20.0000,5.0000,3.0000")
		end)
	end)

	describe("FindPath area costs (SR7)", function()
		test("the scaled heuristic stays admissible: A* costs equal Dijkstra's", function()
			local mesh = NavMesh.Build(NavMesh.Fixtures.Courtyard.Desc)
			local spots = { v(1, 0, 1), v(29, 0, 1), v(1, 0, 29), v(17, 0, 29), v(6, 0, 24), v(6, 0, 10) }
			local cheap = { AreaCosts = { [2] = 0.25 } }
			-- A zero multiplier on an unused area scales the heuristic to 0: plain Dijkstra.
			local dijkstra = { AreaCosts = { [2] = 0.25, [99] = 0 } }
			for _, a in spots do
				for _, b in spots do
					local x, y = NavMesh.FindPath(mesh, a, b, cheap), NavMesh.FindPath(mesh, a, b, dijkstra)
					expect(math.abs(x.Cost - y.Cost) < 1e-6)
						.with_context(`{fmt(a)} -> {fmt(b)}: {x.Cost} vs {y.Cost}`)
						.is_true()
				end
			end
		end)

		test("a cheap detour wins: the heuristic is scaled by the cheapest multiplier", function()
			local mesh = NavMesh.Build(loop)
			local direct = NavMesh.FindPath(mesh, v(2, 0, 1), v(38, 0, 1))
			-- Both ends lie on a portal edge, so the funnel starts flat: no false corner at (4, 2).
			expect(#direct.Waypoints).is(2)
			-- At 0.1 per stud the loop costs about 11, against 36 for the strip. An unscaled
			-- heuristic would return the strip: its f-values stay below the loop's.
			local cheap = NavMesh.FindPath(mesh, v(2, 0, 1), v(38, 0, 1), { AreaCosts = { [2] = 0.1 } })
			local dijkstra = NavMesh.FindPath(mesh, v(2, 0, 1), v(38, 0, 1), { AreaCosts = { [2] = 0.1, [99] = 0 } })
			expect(cheap.Cost < 20).with_context(`cost {cheap.Cost}`).is_true()
			expect(math.abs(cheap.Cost - dijkstra.Cost) < 1e-6).is_true()
			local north = 0
			for _, w in cheap.Waypoints do
				north = math.max(north, w.Position.Z)
			end
			expect(north >= 36).is_true()
		end)

		test("an excluded area is never snapped onto or crossed", function()
			local mesh = NavMesh.Build(NavMesh.Fixtures.Courtyard.Desc)
			local costs = { [2] = math.huge }
			expect(NavMesh.FindPath(mesh, v(6, 0, 24), v(1, 0, 1), { AreaCosts = costs }).Status).is("NoStart")
			-- Unfiltered, the line through the patch is clear. (Nodes at triangle centres once bent
			-- it around the patch's two large triangles, 30% longer.)
			local open = NavMesh.FindPath(mesh, v(6, 0, 18), v(6, 0, 29.5))
			expect(route(open)).is("6.0000,0.0000,18.0000 6.0000,0.0000,29.5000")
			local around = NavMesh.FindPath(mesh, v(6, 0, 18), v(6, 0, 29.5), { AreaCosts = costs })
			expect(around.Status).is("Success")
			expect(#around.Waypoints > 2).is_true()
			expect(table.concat(offMesh(mesh, around, costs), "\n")).is("")
		end)

		test("filters are validated at the call", function()
			local mesh = NavMesh.Build(square)
			expect(function()
				NavMesh.FindPath(mesh, v(1, 0, 1), v(2, 0, 2), { AreaCosts = { [1] = -1 } })
			end).fails_with("AreaCosts%[1%]")
			expect(function()
				NavMesh.FindPath(mesh, v(1, 0, 1), v(2, 0, 2), { AreaCosts = { [1] = 0 / 0 } })
			end).fails_with("AreaCosts")
			expect(function()
				NavMesh.FindPath(mesh, v(1, 0, 1), v(2, 0, 2), { MaxExpansions = -1 })
			end).fails_with("MaxExpansions")
			expect(function()
				NavMesh.FindPath(mesh, v(1, 0, 1), v(2, 0, 2), { SnapExtents = v(-1, 1, 1) })
			end).fails_with("SnapExtents")
		end)
	end)
end
