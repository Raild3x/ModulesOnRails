-- Authors: Logan Hunt (Raildex)
-- September 27, 2026
-- FindPath (ticket 14): snapping from feet positions (U-b), A* with the SR7 heuristic, the
-- funnel at radius 0, and all five statuses.

return function(t: tiniest)
	local Clearance = require("../Clearance")
	local Flood = require("./Helpers/Flood")
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
			expect(#path.TileStamps).is(2) -- one tile: (tile, stamp)
			expect(NavMesh.IsPathValid(mesh, path)).is_true()
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
			-- The Courtyard at 1/16 scale too: sub-stud corners, where no absolute threshold may
			-- leak into the orientation tests.
			local function scaled(ring: { any }, k: number): { any }
				local out = {}
				for i, p in ring do
					out[i] = p * k
				end
				return out
			end
			local court = NavMesh.Fixtures.Courtyard.Desc.Floors.Ground
			local tiny = {
				Name = "Courtyard/16",
				Scale = 1 / 16,
				Desc = {
					TileSize = 2,
					Floors = {
						Ground = {
							Walkable = { scaled(court.Walkable[1], 1 / 16) },
							Obstacles = {},
						},
					},
				},
			}
			for i, ring in court.Obstacles do
				tiny.Desc.Floors.Ground.Obstacles[i] = scaled(ring, 1 / 16)
			end
			local corners = 0
			for _, scenario: any in { NavMesh.Fixtures.Courtyard, NavMesh.Fixtures.ShallowObstacles, tiny } do
				local mesh = NavMesh.Build(scenario.Desc)
				local k = scenario.Scale or 1
				local extents = vector.create(0.5, 4, 0.5) * k
				local spots = if scenario == NavMesh.Fixtures.ShallowObstacles
					then { v(1, 0, 1), v(39, 0, 19), v(20, 0, 2), v(20, 0, 18), v(1, 0, 19), v(39, 0, 1) }
					else scaled(
						{ v(1, 0, 1), v(29, 0, 1), v(29, 0, 19), v(1, 0, 29), v(17, 0, 29), v(14, 0, 18), v(6, 0, 10) },
						k
					)
				for _, a in spots do
					for _, b in spots do
						local st, sp = Snap.Snap(mesh, a, extents, {})
						local gt, gp = Snap.Snap(mesh, b, extents, {})
						local _, corridor, vias, endP = Search.Run(mesh, st, sp :: any, gt, gp :: any, {}, math.huge, 0)
						local points = Funnel.StringPull(mesh, corridor, vias, sp :: any, endP, 0)
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

	describe("FindPath search oracles", function()
		local Search = require("../Search")
		local extents = vector.create(0.5, 4, 0.5)

		-- Deterministic points over a box (a plain LCG; a few hundred draws never repeat).
		local function points(seed: number, count: number, x0: number, z0: number, x1: number, z1: number, y: number)
			local state = seed
			local function rand(): number
				state = (state * 1103515245 + 12345) % 2147483648
				return state / 2147483648
			end
			local out = {}
			for _ = 1, count do
				table.insert(out, v(x0 + (x1 - x0) * rand(), y, z0 + (z1 - z0) * rand()))
			end
			return out
		end

		-- The edge of t that borders m (0 when none).
		local function sharedEdge(mesh: any, t: number, m: number): number
			for e = 1, 3 do
				if Storage.GetNeighbor(mesh, t, e) == m then
					return e
				end
			end
			return 0
		end

		-- Recomputes a search's cost from its corridor, independently of Search: every step
		-- walks from the current node to the next (the midpoint of the edge or seam portal
		-- crossed, the far end of a link, or the goal) at the mean of the two areas' multipliers;
		-- a link walks to its start at the leaving area's multiplier and pays Cost times its own.
		local function corridorCost(
			mesh: any,
			corridor: { number },
			vias: { number },
			startP: vector,
			goalT: number,
			goalP: vector,
			costs: { [number]: number }
		): number
			local function mult(tri: number): number
				return costs[Storage.GetTriangleArea(mesh, tri)] or 1
			end
			if #corridor == 1 then
				return if corridor[1] == goalT then vector.magnitude(goalP - startP) * mult(goalT) else 0
			end
			-- Heron nodes when every multiplier is 1 (or excluded) and no link is cheap; else midpoints.
			local heron = Search.HeuristicScale(mesh, costs) >= 1
			for _, multiplier in costs do
				heron = heron and (multiplier == 1 or multiplier == math.huge)
			end
			local total, p = 0, startP
			-- A step inside t costs t's multiplier; the last one, into the goal's triangle, is split
			-- where it crosses the edge a-b (Detour's rule).
			local function step(q: vector, a: vector, b: vector, t: number, m: number, last: boolean): number
				if not last then
					return vector.magnitude(q - p) * mult(t)
				end
				-- Where the segment p-q meets the edge's line: solve p + (q - p) s on the line a-b.
				local n = vector.create(b.Z - a.Z, 0, a.X - b.X)
				local dp, dq = vector.dot(p - a, n), vector.dot(q - a, n)
				local s = if dp ~= dq then math.clamp(dp / (dp - dq), 0, 1) else 0
				local c = p + (q - p) * s
				return vector.magnitude(c - p) * mult(t) + vector.magnitude(q - c) * mult(m)
			end
			for i = 2, #corridor do
				local t, m = corridor[i - 1], corridor[i]
				local last = m == goalT
				if vias[i] == 0 then
					local verts = { Storage.GetTriangle(mesh, t) }
					local e = sharedEdge(mesh, t, m)
					local va, vb = verts[e % 3 + 1], verts[(e + 1) % 3 + 1]
					local a, b = Storage.GetVertex(mesh, va), Storage.GetVertex(mesh, vb)
					local node = if last
						then goalP
						elseif heron then Search.HeronPoint(a, b, p, goalP)
						else (a + b) * 0.5
					total += step(node, a, b, t, m, last)
					p = node
				else
					local _, _, kind, ref, a, b = Storage.GetExtra(mesh, vias[i])
					if kind == Storage.EXTRA_LINK then
						local _, _, _, _, cost, area = Storage.GetLink(mesh, ref)
						total += vector.magnitude(a - p) * mult(t) + cost * (costs[area] or 1)
						p = b
						if last then
							total += vector.magnitude(goalP - b) * mult(m)
							p = goalP
						end
					else
						local node = if last then goalP else (a + b) * 0.5
						total += step(node, a, b, t, m, last)
						p = node
					end
				end
			end
			return total
		end

		local cases = {
			{ Fixtures = NavMesh.Fixtures.Courtyard, Box = { -1, -1, 31, 31, 0 }, Costs = { [2] = 1.7 } },
			{ Fixtures = NavMesh.Fixtures.ThreeFloorStairs, Box = { -1, -1, 41, 21, 0 }, Costs = {} },
			{ Fixtures = NavMesh.Fixtures.ThreeFloorStairs, Box = { 9, -1, 41, 21, 5 }, Costs = { [1] = 0.6 } },
			{ Fixtures = NavMesh.Fixtures.LinkJump, Box = { -1, -1, 25, 11, 0 }, Costs = { [1] = 1.3 } },
			{ Fixtures = NavMesh.Fixtures.OneWayLink, Box = { -1, -1, 23, 11, 2 }, Costs = {} },
			{ Fixtures = NavMesh.Fixtures.ShallowObstacles, Box = { -1, -1, 41, 21, 0 }, Costs = {} },
		}
		-- Spots on every floor of the stairs, so pairs cross seams both ways.
		local stairSpots = {
			v(2, 0, 2),
			v(15, 0, 15),
			v(25, 0, 12),
			v(11, 0.4, 1),
			v(12.7, 1.3, 2.2),
			v(18, 4, 3),
			v(30, 5, 10),
			v(38, 5, 18),
		}
		local function spotsFor(index: number, case: any, count: number, seed: number): { any }
			local spots = points(seed + index, count, case.Box[1], case.Box[2], case.Box[3], case.Box[4], case.Box[5])
			if case.Fixtures == NavMesh.Fixtures.ThreeFloorStairs then
				table.move(stairSpots, 1, #stairSpots, #spots + 1, spots)
			end
			return spots
		end

		test("a path's cost is the cost of its own node chain (seams, links and area costs)", function()
			local checked = 0
			for index, case in cases do
				local mesh = NavMesh.Build(case.Fixtures.Desc)
				local spots = spotsFor(index, case, 9, 0)
				for _, a in spots do
					for _, b in spots do
						local st, sp = Snap.Snap(mesh, a, extents, case.Costs)
						local gt, gp = Snap.Snap(mesh, b, extents, case.Costs)
						if sp == nil or gp == nil then
							continue
						end
						local status, corridor, vias, _, cost =
							Search.Run(mesh, st, sp :: any, gt, gp :: any, case.Costs, math.huge, 0)
						local expected = corridorCost(mesh, corridor, vias, sp :: any, gt, gp :: any, case.Costs)
						checked += 1
						expect(math.abs(cost - expected) < 1e-6 * math.max(1, expected))
							.with_context(`{case.Fixtures.Name} {fmt(a)} -> {fmt(b)} ({status}): {cost} vs {expected}`)
							.is_true()
					end
				end
			end
			expect(checked > 200).is_true()
		end)

		test("a cheap link behind the start still wins: links lower the heuristic scale", function()
			-- Walking straight to the goal costs 23; walking back to the warp costs 14, the warp 2
			-- (for 38 studs), and the last stud 1. Unscaled, the heuristic at the warp's start
			-- (37 from the goal) would bury that route under the straight one. (4-stud tiles, so
			-- the warp's ends lie many triangles away from the start and the goal.)
			-- The same scene shifted to straddle the origin must give the same costs.
			for _, dx in { 0, -20 } do
				local mesh = NavMesh.Build {
					TileSize = 4,
					Floors = { Ground = { Walkable = { flat(0, { dx, 0, dx + 40, 0, dx + 40, 4, dx, 4 }) } } },
					Links = { { From = v(dx + 1, 0, 2), To = v(dx + 39, 0, 2), Cost = 2, Area = 3 } },
				}
				local path = NavMesh.FindPath(mesh, v(dx + 15, 0, 2), v(dx + 38, 0, 2))
				expect(math.abs(path.Cost - 17) < 1e-6).with_context(`dx {dx}: cost {path.Cost}`).is_true()
				-- At 0.2 per unit of Cost the warp costs 0.4: the scale must use the multiplied price
				-- (dividing instead leaves the scale at the area's 0.2, which overestimates here: from
				-- x = 18.2 the warp route costs 18.6, the straight one 19.8).
				local cheap =
					NavMesh.FindPath(mesh, v(dx + 18.2, 0, 2), v(dx + 38, 0, 2), { AreaCosts = { [3] = 0.2 } })
				expect(math.abs(cheap.Cost - 18.6) < 1e-6).with_context(`dx {dx}: cost {cheap.Cost}`).is_true()
			end
		end)

		test("every step of a path with a radius has the clearance the rule asks for (SR4)", function()
			-- The rule, derived here from the corridor alone: leaving a triangle over edge e needs
			-- the corner width between its entry edge and e, or e's portal width when it was the
			-- start or entered by a seam or link; links themselves need nothing.
			local function violations(mesh: any, corridor: { number }, vias: { number }, radius: number): { string }
				local found = {}
				for i = 1, #corridor - 1 do
					local t, m = corridor[i], corridor[i + 1]
					local e
					if vias[i + 1] == 0 then
						e = sharedEdge(mesh, t, m)
					else
						local _, _, kind, ref = Storage.GetExtra(mesh, vias[i + 1])
						if kind == Storage.EXTRA_LINK then
							continue
						end
						e = ref
					end
					local clear
					if i == 1 or vias[i] ~= 0 then
						clear = Storage.GetPortalWidth(mesh, t, e)
					else
						clear = Storage.GetCornerWidth(mesh, t, 6 - e - sharedEdge(mesh, t, corridor[i - 1]))
					end
					if clear < 2 * radius then
						table.insert(found, `step {i}: {clear} < {2 * radius}`)
					end
				end
				return found
			end
			local successes = 0
			for index, case in cases do
				local mesh = NavMesh.Build(case.Fixtures.Desc)
				local spots = spotsFor(index, case, 8, 100)
				for _, radius in { 0.2, 0.45, 1.1 } do
					for _, a in spots do
						for _, b in spots do
							local st, sp = Snap.Snap(mesh, a, extents, {})
							local gt, gp = Snap.Snap(mesh, b, extents, {})
							if sp == nil or gp == nil then
								continue
							end
							local status, corridor, vias =
								Search.Run(mesh, st, sp :: any, gt, gp :: any, {}, math.huge, radius)
							if status == "Success" then
								successes += 1
							end
							expect(table.concat(violations(mesh, corridor, vias, radius), "; "))
								.with_context(`{case.Fixtures.Name} r {radius} {fmt(a)} -> {fmt(b)}`)
								.is("")
						end
					end
				end
			end
			expect(successes > 200).is_true()
		end)

		test("a small agent fits a small gap up to half its width, and no wider", function()
			-- The Clearance spec's walled room at a tenth of the size: a 0.5-stud gap.
			local small = NavMesh.Build {
				Floors = {
					Ground = {
						Walkable = { flat(0, { 0, 0, 2, 0, 2, 2, 0, 2 }) },
						Obstacles = { flat(0, { 0.8, -0.1, 1.2, -0.1, 1.2, 1.5, 0.8, 1.5 }) },
					},
				},
			}
			expect(NavMesh.FindPath(small, v(0.2, 0, 0.2), v(1.8, 0, 0.2), { AgentRadius = 0.24 }).Status).is("Success")
			expect(NavMesh.FindPath(small, v(0.2, 0, 0.2), v(1.8, 0, 0.2), { AgentRadius = 0.26 }).Status).is("Partial")
		end)

		test("a start right beside a gap leaves over the gap's own width", function()
			-- A wall from the south edge to z = 9 leaves a 1-stud gap on top; with 2-stud tiles the
			-- start triangle borders the gap (the tile line x = 10), so leaving it reads a portal
			-- width (it has no entry edge). (With one big tile a sliver start triangle spans the
			-- gap itself: ticket 27's specs below.)
			local gap = NavMesh.Build {
				TileSize = 2,
				Floors = {
					Ground = {
						Walkable = { flat(0, { 0, 0, 20, 0, 20, 10, 0, 10 }) },
						Obstacles = { flat(0, { 10, -1, 11, -1, 11, 9, 10, 9 }) },
					},
				},
			}
			for _, start in { v(9.6, 0, 9.5), v(9.9, 0, 9.2) } do
				expect(NavMesh.FindPath(gap, start, v(15, 0, 9.5), { AgentRadius = 0.49 }).Status)
					.with_context(fmt(start))
					.is("Success")
				expect(NavMesh.FindPath(gap, start, v(15, 0, 5), { AgentRadius = 0.51 }).Status)
					.with_context(fmt(start))
					.is("Partial")
			end
		end)

		test("A* finds Dijkstra's costs between many pairs (the scaled heuristic is admissible)", function()
			-- With midpoint nodes, which any multiplier other than 1 selects (here on an unused
			-- area): their places don't depend on the route, so A* and Dijkstra search one graph.
			-- Heron nodes depend on the route to them, so there is no fixed graph to agree on.
			local count = 0
			for index, case in cases do
				local mesh = NavMesh.Build(case.Fixtures.Desc)
				local astar = table.clone(case.Costs)
				astar[98] = 2
				local dijkstra = table.clone(astar)
				dijkstra[99] = 0 -- a zero multiplier on an unused area scales the heuristic to 0
				local spots = spotsFor(index, case, 7, 200)
				for _, a in spots do
					for _, b in spots do
						local x = NavMesh.FindPath(mesh, a, b, { AreaCosts = astar })
						if x.Status ~= "Success" then
							continue
						end
						count += 1
						local y = NavMesh.FindPath(mesh, a, b, { AreaCosts = dijkstra })
						expect(math.abs(x.Cost - y.Cost) < 1e-6)
							.with_context(`{case.Fixtures.Name} {fmt(a)} -> {fmt(b)}: {x.Cost} vs {y.Cost}`)
							.is_true()
					end
				end
			end
			expect(count > 100).is_true()
		end)
	end)

	describe("FindPath radius inside the start and goal triangles (ticket 27)", function()
		-- A 20 x 10 room, one tile, with a slab from the south wall to z = 9: a 1-stud gap over it.
		-- The start and goal points sit in the sliver (0, 10) (10, 9) (20, 10) that spans the gap.
		local function room(south: number, slabFrom: number): any
			return NavMesh.Build {
				TileSize = 64,
				Floors = {
					Ground = {
						Walkable = { flat(0, { 0, south, 20, south, 20, 10, 0, 10 }) },
						Obstacles = { flat(0, { 10, slabFrom, 11, slabFrom, 11, 9, 10, 9 }) },
					},
				},
			}
		end
		local extents = vector.create(0.5, 4, 0.5)

		test("an end in a sliver across a gap can't leave through it (both ends)", function()
			local mesh = room(0, -1)
			local sliver, left, right = v(9.6, 0, 9.5), v(9.6, 0, 9.5), v(15, 0, 5)
			expect(NavMesh.FindPath(mesh, left, right, { AgentRadius = 0.51 }).Status).is("Partial")
			expect(NavMesh.FindPath(mesh, right, left, { AgentRadius = 0.51 }).Status).is("Partial")
			expect(NavMesh.FindPath(mesh, left, right, { AgentRadius = 0.49 }).Status).is("Success")
			expect(NavMesh.FindPath(mesh, right, left, { AgentRadius = 0.49 }).Status).is("Success")
			-- A Partial path stays on its own side: it ends left of the gap.
			local partial = NavMesh.FindPath(mesh, sliver, right, { AgentRadius = 0.51 })
			for _, w in partial.Waypoints do
				expect((w.Position :: any).X <= 10).with_context(fmt(w.Position)).is_true()
			end
			-- At the reachable point nearest the goal: by the slab's west face, not back at the start.
			expect(fmt(partial.Waypoints[#partial.Waypoints].Position)).is("9.4900,0.0000,5.0000")
		end)

		test("ends parted inside one triangle go round when they can, else stop", function()
			local a, b = v(9.6, 0, 9.5), v(12, 0, 9.45)
			-- The slab reaches the south wall: no way round.
			local closed = room(0, -1)
			expect(Snap.Snap(closed, a, extents, {})).is(Snap.Snap(closed, b, extents, {}))
			expect(NavMesh.FindPath(closed, a, b, { AgentRadius = 0.51 }).Status).is("Partial")
			expect(NavMesh.FindPath(closed, a, b, { AgentRadius = 0.45 }).Status).is("Success")
			-- A floating slab: the way round goes under it, out of the shared triangle and back.
			local open = room(-6, -3)
			expect(Snap.Snap(open, a, extents, {})).is(Snap.Snap(open, b, extents, {}))
			local round = NavMesh.FindPath(open, a, b, { AgentRadius = 0.51 })
			expect(round.Status).is("Success")
			local lowest = math.huge
			for _, w in round.Waypoints do
				lowest = math.min(lowest, (w.Position :: any).Z)
			end
			expect(lowest < -3).with_context(route(round)).is_true()
			expect(#offMesh(open, round)).is(0)
			-- A narrow agent keeps the straight line.
			expect(#NavMesh.FindPath(open, a, b, { AgentRadius = 0.45 }).Waypoints).is(2)
		end)

		test("a barrier ending inside a crossable edge doesn't cut an end off", function()
			-- The start's sliver is parted from its south-west edge by the east slab's disc, but
			-- the disc ends on the sliver's north edge: the agent steps over the slab through the
			-- triangle beyond, and back down (a way out and in across one edge).
			local mesh = NavMesh.Build {
				TileSize = 16,
				Floors = {
					Ground = {
						Walkable = { flat(0, { 0, 0, 32, 0, 32, 10, 0, 10 }) },
						Obstacles = {
							flat(0, { 21.416, -1, 22.578, -1, 22.578, 8.43, 21.416, 8.43 }),
							flat(0, { 25.64, -1, 26.877, -1, 26.877, 8.178, 25.64, 8.178 }),
						},
					},
				},
			}
			local a, b = v(27.522, 0, 8.818), v(23.498, 0, 6.58)
			expect(NavMesh.FindPath(mesh, a, b, { AgentRadius = 0.805 }).Status).is("Success")
			-- Over the slab the gap is 1.822: a wider agent is refused.
			expect(NavMesh.FindPath(mesh, a, b, { AgentRadius = 0.92 }).Status).is("Partial")
		end)

		test("every Partial the check causes is a real block (a grid flood agrees)", function()
			-- Slabs standing on the south wall of a long room, each 0.5-2 studs short of the north
			-- wall, in one tile: many slivers span gaps. Every query that the start or goal check
			-- turned away and that ends Partial must be parted in the independent flood.
			math.randomseed(27)
			local function rnd(lo: number, hi: number): number
				return lo + math.random() * (hi - lo)
			end
			local obstacles = {}
			local x = 2
			while x < 60 do
				local w, gap = rnd(0.5, 2), rnd(0.5, 2)
				table.insert(obstacles, flat(0, { x, -1, x + w, -1, x + w, 10 - gap, x, 10 - gap }))
				x += w + rnd(2, 6)
			end
			local mesh = NavMesh.Build {
				TileSize = 64,
				Floors = { Ground = { Walkable = { flat(0, { 0, 0, 64, 0, 64, 10, 0, 10 }) }, Obstacles = obstacles } },
			}
			local oracle = Flood.New(mesh)
			local fired = false
			local cutOff, separated = Clearance.CutOff, Clearance.Separated
			Clearance.CutOff = function(...)
				local result = cutOff(...)
				fired = fired or result
				return result
			end
			Clearance.Separated = function(...)
				local result = separated(...)
				fired = fired or result
				return result
			end
			local checked, refuted = 0, {}
			local ok, err = pcall(function()
				for _ = 1, 400 do
					local r = rnd(0.2, 1.1)
					local a, b = v(rnd(0, 64), 0, rnd(7, 10)), v(rnd(0, 64), 0, rnd(0, 10))
					if not Flood.OnMesh(oracle, a.X, a.Z) or not Flood.OnMesh(oracle, b.X, b.Z) then
						continue
					end
					fired = false
					if NavMesh.FindPath(mesh, a, b, { AgentRadius = r }).Status == "Partial" and fired then
						checked += 1
						if Flood.Connected(oracle, r, a, b) then
							table.insert(refuted, `r {r}: {fmt(a)} -> {fmt(b)}`)
						end
					end
				end
			end)
			Clearance.CutOff, Clearance.Separated = cutOff, separated
			assert(ok, err)
			expect(table.concat(refuted, "; ")).is("")
			expect(checked >= 10).with_context(`{checked} blocked queries`).is_true()
		end)

		test("a Partial end never lies past a barrier in its last triangle", function()
			-- The sliver is entered from the west, but its point nearest a goal in the east room
			-- is past the gap (Track G, G3).
			local mesh = room(0, -1)
			for _, goal in { v(15, 0, 5), v(15, 0, 9.5), v(19, 0, 2) } do
				local path = NavMesh.FindPath(mesh, v(5, 0, 5), goal, { AgentRadius = 0.51 })
				expect(path.Status).is("Partial")
				local last = path.Waypoints[#path.Waypoints].Position :: any
				expect(last.X <= 10).with_context(`{fmt(goal)}: ends at {fmt(last)}`).is_true()
			end
			-- A narrow agent goes through.
			expect(NavMesh.FindPath(mesh, v(5, 0, 5), v(15, 0, 5), { AgentRadius = 0.49 }).Status).is("Success")
			-- An end against a wall with nothing in the way still stands just off it.
			local apart = NavMesh.FindPath(NavMesh.Build(islands), v(2, 0, 3), v(25, 0, 7), { AgentRadius = 0.5 })
			expect(apart.Status).is("Partial")
			expect(fmt(apart.Waypoints[#apart.Waypoints].Position)).is("9.5000,0.0000,7.0000")
		end)

		test("a start against a wall, boxed in by the widths, still gets a way out of the wall", function()
			-- Small props close together: a start on a wall edge often sits in a triangle no edge
			-- of which admits the agent. Its own nearest point is judged inside its triangle; the
			-- push off the wall (into a triangle the search never entered) is the way out.
			math.randomseed(17)
			local props = {}
			for _ = 1, 40 do
				local x, z, w, d = math.random() * 15, math.random() * 15, 0.3 + math.random(), 0.3 + math.random()
				table.insert(props, flat(0, { x, z, x + w, z, x + w, z + d, x, z + d }))
			end
			local mesh = NavMesh.Build {
				Floors = { Ground = { Walkable = { flat(0, { 0, 0, 16, 0, 16, 16, 0, 16 }) }, Obstacles = props } },
			}
			local starts, stuck = 0, {}
			for t = 1, Storage.TriangleCount(mesh) do
				local ids = { Storage.GetTriangle(mesh, t) }
				for e = 1, 3 do
					if Storage.IsWallEdge(mesh, t, e) then
						local a, b =
							Storage.GetVertex(mesh, ids[e % 3 + 1]), Storage.GetVertex(mesh, ids[(e + 1) % 3 + 1])
						local p = (a + b) * 0.5
						local path = NavMesh.FindPath(mesh, p, v(500, 0, 500), { AgentRadius = 1, GoalFallback = true })
						starts += 1
						if #path.Waypoints < 2 then
							table.insert(stuck, fmt(p))
						end
					end
				end
			end
			expect(table.concat(stuck, " ")).is("")
			expect(starts > 100).is_true()
		end)

		test("every Partial and Budget end is reachable from the start (a grid flood agrees)", function()
			-- Rooms like the one above, each with one slab of random place, width and gap, so
			-- every barrier lies inside one triangle (ticket 27's reach; one that spans two
			-- triangles is a known gap). Only ends the agent can stand at are judged: an end the
			-- push leaves in a pinch narrower than 2r is another known gap.
			math.randomseed(33)
			local function rnd(lo: number, hi: number): number
				return lo + math.random() * (hi - lo)
			end
			local checked, moved, refuted = 0, 0, {}
			for _ = 1, 24 do
				local x0, width, top = rnd(3, 15), rnd(0.5, 2), 10 - rnd(0.6, 1.6)
				local mesh = NavMesh.Build {
					TileSize = 64,
					Floors = {
						Ground = {
							Walkable = { flat(0, { 0, 0, 20, 0, 20, 10, 0, 10 }) },
							Obstacles = { flat(0, { x0, -1, x0 + width, -1, x0 + width, top, x0, top }) },
						},
					},
				}
				local oracle = Flood.New(mesh)
				for i = 1, 20 do
					local r = rnd(0.25, 0.9)
					local a, b = v(rnd(0, 20), 0, rnd(0, 10)), v(rnd(0, 20), 0, rnd(0, 10))
					-- A start the agent can stand at (the flood can't leave one in a wall's disc).
					if not Flood.OnMesh(oracle, a.X, a.Z) or not Flood.OnMesh(oracle, b.X, b.Z) then
						continue
					elseif oracle.Clearance(a.X, a.Z, r + 0.01) < r then
						continue
					end
					local filter = { AgentRadius = r, MaxExpansions = if i % 3 == 0 then 2 else nil }
					local path = NavMesh.FindPath(mesh, a, b, filter)
					local last = path.Waypoints[#path.Waypoints]
					last = last and last.Position :: any
					if
						(path.Status == "Partial" or path.Status == "Budget")
						and NavMesh.FindDistanceToWall(mesh, last, r) >= r * (1 - 1e-6)
					then
						checked += 1
						if (last.X - x0) * (b.X - x0) < 0 then
							moved += 1 -- it ended on the far side of the slab from the goal
						end
						if not Flood.Connected(oracle, r, path.Waypoints[1].Position :: any, last) then
							table.insert(refuted, `r {r}, slab {x0}: {fmt(a)} -> {fmt(b)} ends at {fmt(last)}`)
						end
					end
				end
			end
			expect(table.concat(refuted, "; ")).is("")
			expect(checked >= 50).with_context(`{checked} Partial or Budget`).is_true()
			expect(moved >= 20).with_context(`{moved} ended short of the slab`).is_true()
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
			expect(fmt(NavMesh.FindPath(mesh, v(5, 0, -0.4), v(10, 0, 5)).Waypoints[1].Position)).is(
				"5.0000,0.0000,0.0000"
			)
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
			expect(function()
				NavMesh.FindPath(mesh, v(1, 0, 1), v(2, 0, 2), { AgentRadius = math.huge })
			end).fails_with("AgentRadius must be")
			-- A misspelled key would otherwise be ignored in silence (ticket 26).
			expect(function()
				NavMesh.FindPath(mesh, v(1, 0, 1), v(2, 0, 2), { AgentRaduis = 1 } :: any)
			end).fails_with("unknown QueryFilter key 'AgentRaduis'")
			expect(function()
				NavMesh.FindNearestPoint(mesh, v(1, 0, 1), { snapExtents = v(1, 1, 1) } :: any)
			end).fails_with("unknown QueryFilter key 'snapExtents'")
			-- Zero and fractional extents are fine on every axis.
			for _, extents in { v(1, 0, 1), v(0.5, 0.5, 0.5), v(0, 1, 0) } do
				expect(NavMesh.FindPath(mesh, v(1, 0, 1), v(2, 0, 2), { SnapExtents = extents }).Status)
					.with_context(fmt(extents))
					.is("Success")
			end
		end)

		test("filter errors point at the caller's line", function()
			local mesh = NavMesh.Build(square)
			local capped: any = table.clone(square)
			capped.MaxAgentRadius = 1
			local cappedMesh = NavMesh.Build(capped)
			for i, filter in
				{
					{ AgentRadius = -1 },
					{ AreaCosts = { [1] = -1 } },
					{ MaxExpansions = -1 },
					{ SnapExtents = v(-1, 1, 1) },
					{ AgentRadius = 2, Capped = true },
				}
			do
				local target = if filter.Capped then cappedMesh else mesh
				filter.Capped = nil
				local ok, err = pcall(function()
					NavMesh.FindPath(target, v(1, 0, 1), v(2, 0, 2), filter :: any)
				end)
				expect(ok).is(false)
				expect(tostring(err):find("FindPath.spec", 1, true) ~= nil).with_context(`filter {i}: {err}`).is_true()
			end
		end)
	end)
end
