-- Authors: Logan Hunt (Raildex)
-- September 27, 2026
-- Clearance (ticket 15, SR4, ruling U-a): widths measured to walls only, agent radius on paths,
-- funnel offsets at wall corners, and the optional MaxAgentRadius cap.

return function(t: tiniest)
	local NavMesh = require("../NavMesh")
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

	local function v(x: number, z: number): any
		return vector.create(x, 0, z)
	end

	-- Distance in (X, Z) from a point to a segment.
	local function pointSeg(px: number, pz: number, a: vector, b: vector): number
		local dx, dz = b.X - a.X, b.Z - a.Z
		local u = math.clamp(((px - a.X) * dx + (pz - a.Z) * dz) / (dx * dx + dz * dz), 0, 1)
		return math.sqrt((a.X + u * dx - px) ^ 2 + (a.Z + u * dz - pz) ^ 2)
	end

	-- Every wall edge of the mesh, as vertex pairs.
	local function walls(mesh: any): { { vector } }
		local found = {}
		for tri = 1, Storage.TriangleCount(mesh) do
			local vs = { Storage.GetTriangle(mesh, tri) }
			for e = 1, 3 do
				if Storage.GetNeighbor(mesh, tri, e) == 0 then
					table.insert(
						found,
						{ Storage.GetVertex(mesh, vs[e % 3 + 1]), Storage.GetVertex(mesh, vs[(e + 1) % 3 + 1]) }
					)
				end
			end
		end
		return found
	end

	-- Distance from triangle `tri` to the nearest wall (0 when it touches one), sampled densely
	-- along its edges (walls never cross a triangle).
	local function triToWalls(mesh: any, tri: number, wallList: { { vector } }): number
		local vs = { Storage.GetTriangle(mesh, tri) }
		local P = { Storage.GetVertex(mesh, vs[1]), Storage.GetVertex(mesh, vs[2]), Storage.GetVertex(mesh, vs[3]) }
		local best = math.huge
		for e = 1, 3 do
			local a, b = P[e], P[e % 3 + 1]
			for k = 0, 40 do
				local p = a + (b - a) * (k / 40)
				for _, w in wallList do
					best = math.min(best, pointSeg(p.X, p.Z, w[1], w[2]))
				end
			end
		end
		return best
	end

	-- A 40 x 4 corridor along X.
	local corridor: any = { Floors = { Ground = { Walkable = { flat(0, { 0, 0, 40, 0, 40, 4, 0, 4 }) } } } }
	-- A 20 x 20 room split by a wall from the south edge to z = 15, leaving a 5-stud gap on top.
	local walled: any = {
		Floors = {
			Ground = {
				Walkable = { flat(0, { 0, 0, 20, 0, 20, 20, 0, 20 }) },
				Obstacles = { flat(0, { 8, -1, 12, -1, 12, 15, 8, 15 }) },
			},
		},
	}

	describe("Clearance widths", function()
		test("a straight corridor's crossings are exactly its width", function()
			local mesh = NavMesh.Build(corridor)
			local crossings = 0
			for tri = 1, Storage.TriangleCount(mesh) do
				local vs = { Storage.GetTriangle(mesh, tri) }
				for e = 1, 3 do
					if Storage.GetNeighbor(mesh, tri, e) == 0 then
						continue
					end
					-- An edge from the south wall to the north wall spans the corridor.
					local a, b = Storage.GetVertex(mesh, vs[e % 3 + 1]), Storage.GetVertex(mesh, vs[(e + 1) % 3 + 1])
					if math.abs(a.Z - b.Z) == 4 then
						crossings += 1
						local w = Storage.GetPortalWidth(mesh, tri, e)
						expect(w >= 4 and w < 4 + 1e-9).with_context(`width {w}`).is_true()
					end
				end
			end
			expect(crossings > 0).is_true()
		end)

		test("widths are never below twice the distance to the nearest wall", function()
			for _, scenario in NavMesh.Fixtures.All do
				local mesh = NavMesh.Build(scenario.Desc)
				local wallList = walls(mesh)
				for tri = 1, Storage.TriangleCount(mesh) do
					local floor = 2 * triToWalls(mesh, tri, wallList) - 1e-6
					for k = 1, 3 do
						expect(Storage.GetCornerWidth(mesh, tri, k) >= floor)
							.with_context(
								`{scenario.Name} triangle {tri} corner {k}: {Storage.GetCornerWidth(mesh, tri, k)} < {floor}`
							)
							.is_true()
					end
				end
			end
		end)

		test("an open floor across a tile corner admits its true free width (SR4)", function()
			-- 40 x 40 with 8-stud tiles: the middle triangles have only free (tile) vertices.
			local mesh = NavMesh.Build {
				TileSize = 8,
				Floors = { Ground = { Walkable = { flat(0, { 0, 0, 40, 0, 40, 40, 0, 40 }) } } },
			}
			local wallList = walls(mesh)
			local checked = 0
			for tri = 1, Storage.TriangleCount(mesh) do
				local vs = { Storage.GetTriangle(mesh, tri) }
				if
					Storage.IsWallVertex(mesh, vs[1])
					or Storage.IsWallVertex(mesh, vs[2])
					or Storage.IsWallVertex(mesh, vs[3])
				then
					continue
				end
				checked += 1
				local free = triToWalls(mesh, tri, wallList)
				for k = 1, 3 do
					expect(Storage.GetCornerWidth(mesh, tri, k) >= 2 * free - 1e-6).is_true()
				end
			end
			expect(checked > 0).is_true()
			-- A 16-stud-radius agent crosses the middle, across tile corners.
			local path = NavMesh.FindPath(mesh, v(20, 17), v(20, 23), { AgentRadius = 16 })
			expect(path.Status).is("Success")
		end)

		-- Brute force, independent of Clearance: a width is blocked at radius r exactly when the
		-- points of the triangle within r of a wall (the union of the cut discs) connect the
		-- corner to the far edge (for a portal: cover the whole edge). Sample the triangle on a
		-- barycentric grid, add the points in order of their distance to the floor's walls, and
		-- read off the distance at which the corner's component first touches the far edge.
		-- Exact up to the grid spacing h, so compare within about h.
		local function bruteWidths(mesh: any, tri: number, wallList: { { vector } }): ({ number }, { number }, number)
			local vs = { Storage.GetTriangle(mesh, tri) }
			local P = { Storage.GetVertex(mesh, vs[1]), Storage.GetVertex(mesh, vs[2]), Storage.GetVertex(mesh, vs[3]) }
			local longest =
				math.max(vector.magnitude(P[1] - P[2]), vector.magnitude(P[2] - P[3]), vector.magnitude(P[3] - P[1]))
			local n = math.clamp(math.ceil(longest / 0.1), 8, 96)
			local ids, bary, dist = {}, {}, {}
			for i = 0, n do
				for j = 0, n - i do
					local p = (P[1] * i + P[2] * j + P[3] * (n - i - j)) / n
					local d = math.huge
					for _, w in wallList do
						d = math.min(d, pointSeg(p.X, p.Z, w[1], w[2]))
					end
					table.insert(bary, { i, j, n - i - j })
					table.insert(dist, d)
					ids[i * (n + 1) + j] = #bary
				end
			end
			local order = {}
			for id = 1, #bary do
				order[id] = id
			end
			table.sort(order, function(a: number, b: number): boolean
				return dist[a] < dist[b]
			end)
			local function neighbours(id: number): { number }
				local out = {}
				local i, j = bary[id][1], bary[id][2]
				for _, step in { { 1, 0 }, { -1, 0 }, { 0, 1 }, { 0, -1 }, { 1, -1 }, { -1, 1 } } do
					local ni, nj = i + step[1], j + step[2]
					if ni >= 0 and nj >= 0 and ni + nj <= n then
						table.insert(out, ids[ni * (n + 1) + nj])
					end
				end
				return out
			end
			local corners = {}
			for k = 1, 3 do
				-- Union-find over the added points; the corner is the point with bary[k] = n.
				local parent, added = {}, {}
				local function find(x: number): number
					while parent[x] ~= x do
						parent[x] = parent[parent[x]]
						x = parent[x]
					end
					return x
				end
				local corner = 0
				for id = 1, #bary do
					if bary[id][k] == n then
						corner = id
					end
				end
				local touchesSink = {}
				local r = math.huge
				for _, id in order do
					parent[id], added[id] = id, true
					touchesSink[id] = bary[id][k] == 0
					for _, other in neighbours(id) do
						if added[other] then
							local a, b = find(id), find(other)
							if a ~= b then
								parent[b] = a
								touchesSink[a] = touchesSink[a] or touchesSink[b]
							end
						end
					end
					if added[corner] and touchesSink[find(corner)] then
						r = dist[id]
						break
					end
				end
				corners[k] = 2 * r
			end
			local portals = {}
			for k = 1, 3 do
				local u, w = P[k % 3 + 1], P[(k + 1) % 3 + 1]
				local r = 0
				for s = 0, 4 * n do
					local p = u + (w - u) * (s / (4 * n))
					local d = math.huge
					for _, wall in wallList do
						d = math.min(d, pointSeg(p.X, p.Z, wall[1], wall[2]))
					end
					r = math.max(r, d)
				end
				portals[k] = 2 * r
			end
			return corners, portals, 2.2 * longest / n
		end

		-- Walls of one floor.
		local function floorWalls(mesh: any, floor: number): { { vector } }
			local found = {}
			for tri = 1, Storage.TriangleCount(mesh) do
				if Storage.GetTriangleFloor(mesh, tri) ~= floor then
					continue
				end
				local vs = { Storage.GetTriangle(mesh, tri) }
				for e = 1, 3 do
					if Storage.IsWallEdge(mesh, tri, e) then
						table.insert(
							found,
							{ Storage.GetVertex(mesh, vs[e % 3 + 1]), Storage.GetVertex(mesh, vs[(e + 1) % 3 + 1]) }
						)
					end
				end
			end
			return found
		end

		test("widths match a brute-force flood of the wall discs", function()
			-- Slanted walls and narrow gaps; two stacked floors with different walls (a floor's
			-- widths never see another floor's walls); and seams.
			local slanted: any = {
				TileSize = 8,
				Floors = {
					Ground = {
						Walkable = { flat(0, { 0, 0, 16, 0, 16, 8, 0, 8 }) },
						Obstacles = {
							flat(0, { 3, 1.5, 5.5, 2.25, 4.75, 4.5, 2.5, 3.5 }),
							flat(0, { 6.25, 3, 9, 1.25, 9.5, 2, 6.75, 4 }),
							flat(0, { 11, 5, 13.5, 6.5, 12, 7.25 }),
						},
					},
				},
			}
			local stackedWalls: any = {
				TileSize = 8,
				Floors = {
					Ground = {
						Walkable = { flat(0, { 0, 0, 8, 0, 8, 8, 0, 8 }) },
						Obstacles = { flat(0, { 1, 1, 3, 1, 3, 3, 1, 3 }) },
					},
					Upper = {
						Walkable = { flat(3, { 0, 0, 8, 0, 8, 8, 0, 8 }) },
						Obstacles = { flat(3, { 5, 4.5, 6.5, 4.5, 6.5, 7, 5, 7 }) },
					},
				},
			}
			-- The slanted floor at 1/16 scale: the same shapes, sub-stud walls (no absolute
			-- threshold may leak into the geometry).
			local tiny: any = { TileSize = 0.5, Floors = { Ground = { Walkable = {}, Obstacles = {} } } }
			for key, rings in slanted.Floors.Ground do
				for i, ring in rings do
					tiny.Floors.Ground[key][i] = {}
					for j, p in ring do
						tiny.Floors.Ground[key][i][j] = p / 16
					end
				end
			end
			local checked = 0
			for _, desc in
				{ slanted, tiny, stackedWalls, NavMesh.Fixtures.ThreeFloorStairs.Desc, NavMesh.Fixtures.Courtyard.Desc }
			do
				local mesh = NavMesh.Build(desc)
				local wallsByFloor = {}
				for tri = 1, Storage.TriangleCount(mesh) do
					local floor = Storage.GetTriangleFloor(mesh, tri)
					wallsByFloor[floor] = wallsByFloor[floor] or floorWalls(mesh, floor)
					local corners, portals, tolerance = bruteWidths(mesh, tri, wallsByFloor[floor])
					local function near(got: number, want: number): boolean
						return (got > 1000 and want > 1000) or math.abs(got - want) <= tolerance
					end
					for k = 1, 3 do
						local open1 = not Storage.IsWallEdge(mesh, tri, k % 3 + 1)
						local open2 = not Storage.IsWallEdge(mesh, tri, (k + 1) % 3 + 1)
						if open1 and open2 then
							checked += 1
							local got = Storage.GetCornerWidth(mesh, tri, k)
							expect(near(got, corners[k]))
								.with_context(`triangle {tri} corner {k}: {got} vs brute {corners[k]} (h {tolerance})`)
								.is_true()
						end
						if not Storage.IsWallEdge(mesh, tri, k) then
							local got = Storage.GetPortalWidth(mesh, tri, k)
							expect(near(got, portals[k]))
								.with_context(`triangle {tri} portal {k}: {got} vs brute {portals[k]} (h {tolerance})`)
								.is_true()
						end
					end
				end
			end
			expect(checked > 100).is_true()
		end)

		test("a wall corner facing a wall edge is bounded by its gap (Demyen)", function()
			local mesh = NavMesh.Build(walled)
			for tri = 1, Storage.TriangleCount(mesh) do
				local vs = { Storage.GetTriangle(mesh, tri) }
				for k = 1, 3 do
					if Storage.IsWallVertex(mesh, vs[k]) and Storage.GetNeighbor(mesh, tri, k) == 0 then
						local c = Storage.GetVertex(mesh, vs[k])
						local a, b =
							Storage.GetVertex(mesh, vs[k % 3 + 1]), Storage.GetVertex(mesh, vs[(k + 1) % 3 + 1])
						local gap = pointSeg(c.X, c.Z, a, b)
						expect(Storage.GetCornerWidth(mesh, tri, k) <= gap + 1e-9).is_true()
					end
				end
			end
		end)
	end)

	describe("FindPath with AgentRadius", function()
		test("an agent fits a gap up to half its width, and no wider", function()
			local mesh = NavMesh.Build(walled)
			expect(NavMesh.FindPath(mesh, v(2, 2), v(18, 2), { AgentRadius = 2.4 }).Status).is("Success")
			local blocked = NavMesh.FindPath(mesh, v(2, 2), v(18, 2), { AgentRadius = 2.6 })
			expect(blocked.Status).is("Partial")
			local corridorMesh = NavMesh.Build(corridor)
			expect(NavMesh.FindPath(corridorMesh, v(1, 2), v(39, 2), { AgentRadius = 2 }).Status).is("Success")
			expect(NavMesh.FindPath(corridorMesh, v(1, 2), v(39, 2), { AgentRadius = 2.0001 }).Status).is("Partial")
		end)

		test("corners are passed at the agent's radius", function()
			local mesh = NavMesh.Build(walled)
			local corners = { v(8, 15), v(12, 15) }
			-- Both ways round, so the corners are portal lefts one way and rights the other.
			for _, case in { { 1.5, v(2, 2), v(18, 2) }, { 0.5, v(2, 2), v(18, 2) }, { 0.5, v(18, 2), v(2, 2) } } do
				local r = case[1]
				local path = NavMesh.FindPath(mesh, case[2], case[3], { AgentRadius = r })
				expect(path.Status).is("Success")
				local waypoints = path.Waypoints
				expect(#waypoints).is(4)
				for i = 2, #waypoints - 1 do
					local p = waypoints[i].Position :: any
					local nearest = math.min(vector.magnitude(p - corners[1]), vector.magnitude(p - corners[2]))
					expect(math.abs(nearest - r) < 1e-6)
						.with_context(`r {r}: waypoint {i} is {nearest} from its corner`)
						.is_true()
					-- On the walkable side of the corner: r from the walls, not inside the wall.
					local d = NavMesh.FindDistanceToWall(mesh, p, 10)
					expect(math.abs(d - r) < 1e-4).with_context(`r {r}: waypoint {i} is {d} from the walls`).is_true()
				end
			end
			-- Radius 0 still bends exactly at the corners.
			local tight = NavMesh.FindPath(mesh, v(2, 2), v(18, 2))
			expect(vector.magnitude((tight.Waypoints[2].Position :: any) - corners[1])).is(0)
		end)

		test("MaxAgentRadius caps widths, and a wider agent is refused", function()
			local capped: any = table.clone(walled)
			capped.MaxAgentRadius = 1
			local mesh = NavMesh.Build(capped)
			for tri = 1, Storage.TriangleCount(mesh) do
				for k = 1, 3 do
					expect(Storage.GetCornerWidth(mesh, tri, k) <= 2).is_true()
				end
			end
			expect(NavMesh.FindPath(mesh, v(2, 2), v(18, 2), { AgentRadius = 1 }).Status).is("Success")
			expect(function()
				NavMesh.FindPath(mesh, v(2, 2), v(18, 2), { AgentRadius = 1.5 })
			end).fails_with("MaxAgentRadius")
			for _, bad in { 0, -1, "2" :: any } do
				local desc: any = table.clone(walled)
				desc.MaxAgentRadius = bad
				expect(function()
					NavMesh.Build(desc)
				end).fails_with("MaxAgentRadius must be")
			end
			expect(function()
				NavMesh.FindPath(mesh, v(2, 2), v(18, 2), { AgentRadius = -1 })
			end).fails_with("AgentRadius must be")
		end)
	end)

	describe("Barriers inside a triangle (ticket 27)", function()
		local Clearance = require("../Clearance")
		local Search = require("../Search")
		local Snap = require("../Snap")
		local Flood = require("./Helpers/Flood")
		local extents = vector.create(0.5, 4, 0.5)
		-- The ticket's room: 20 x 10 in one tile, a slab up to z = 9 (a 1-stud gap over it), and
		-- the sliver (0, 10) (10, 9) (20, 10) spanning the gap. `south` and `slabFrom` open a way
		-- round under the slab.
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
		local function status(mesh: any, a: any, b: any, r: number): (string, number)
			local path = NavMesh.FindPath(mesh, a, b, { AgentRadius = r })
			return path.Status, #path.Waypoints
		end

		test("an end touching a wall is judged where it stands pushed out to r", function()
			local mesh = room(0, -1)
			-- 0.2 from the north wall, past the gap: pushed out it stands on the gap's far side.
			expect(status(mesh, v(14, 9.8), v(15, 5), 0.51)).is("Success")
			-- 0.5 from the north wall, before the gap: pushed out it is still before it.
			expect(status(mesh, v(9.6, 9.5), v(15, 5), 0.51)).is("Partial")
		end)

		test(
			"a point pushed out of the triangle is parted from one only if that is cut off from the edge it crossed",
			function()
				-- (15, 9.9) is 0.1 under the north wall: pushed to r 0.51 it stands at z 9.49, under the
				-- sliver's east edge (z 9.5 there), outside the sliver (E3: a link's start there).
				local mesh = room(0, -1)
				local sliver = Snap.Snap(mesh, v(15, 9.9), extents, {})
				expect(Snap.Snap(mesh, v(9.6, 9.5), extents, {})).is(sliver)
				-- From east of the gap it is a step away; from west of it, past the gap.
				expect(Clearance.Separated(mesh, sliver, 0.51, 12, 9.45, 15, 9.9)).is(false)
				expect(Clearance.Separated(mesh, sliver, 0.51, 15, 9.9, 12, 9.45)).is(false)
				expect(Clearance.Separated(mesh, sliver, 0.51, 9.6, 9.5, 15, 9.9)).is(true)
				expect(Clearance.Separated(mesh, sliver, 0.51, 15, 9.9, 9.6, 9.5)).is(true)
			end
		)

		test("remembered verdicts don't depend on the order asked, across radii (E3)", function()
			-- Verdicts are kept per triangle and radius (a few radii each). Ask the same questions
			-- of two copies of the room, in opposite orders: every answer must match.
			local questions = {}
			for _, r in { 0.45, 0.51, 0.6, 0.7, 0.8 } do
				for _, p in { v(9.6, 9.5), v(12, 9.45), v(15, 9.9), v(5, 5), v(10, 9.05) } do
					table.insert(questions, { r, p })
				end
			end
			local function ask(mesh: any, order: { number }): { string }
				local out = {}
				for _, k in order do
					local r, p = questions[k][1], questions[k][2]
					local tri = Snap.Snap(mesh, p, extents, {})
					local bits = {}
					for e = 1, 3 do
						table.insert(bits, if Clearance.CutOff(mesh, tri, e, r, p.X, p.Z) then "1" else "0")
					end
					local sep = Clearance.Separated(mesh, tri, r, p.X, p.Z, 9.6, 9.5)
					table.insert(bits, if sep then "S" else "s")
					out[k] = table.concat(bits)
				end
				return out
			end
			local forward, backward = {}, {}
			for k = 1, #questions do
				table.insert(forward, k)
				table.insert(backward, 1, k)
			end
			local first = room(0, -1)
			local a, b = ask(first, forward), ask(room(0, -1), backward)
			expect(table.concat(b, " ")).is(table.concat(a, " "))
			-- And a second pass on the first copy, now all remembered.
			expect(table.concat(ask(first, backward), " ")).is(table.concat(a, " "))
			-- The questions are not all one answer.
			expect(string.find(table.concat(a), "1") ~= nil and string.find(table.concat(a), "S") ~= nil).is_true()
		end)

		test("remembered verdicts are told apart by every input (E3)", function()
			-- Pairs of questions that differ in one input only, with different answers, asked in
			-- turn of one mesh: a verdict kept under too loose a key would answer the second.
			local function edgeWhere(mesh: any, t: number, pick: (a: vector, b: vector) -> boolean): number
				local ids = { Storage.GetTriangle(mesh, t) }
				for e = 1, 3 do
					if pick(Storage.GetVertex(mesh, ids[e % 3 + 1]), Storage.GetVertex(mesh, ids[(e + 1) % 3 + 1])) then
						return e
					end
				end
				error("no such edge")
			end
			-- The room, and the room turned a quarter (the gap at x 9..10 over a slab from the
			-- west wall), for questions that differ in z only.
			local turned = NavMesh.Build {
				TileSize = 64,
				Floors = {
					Ground = {
						Walkable = { flat(0, { 0, 0, 10, 0, 10, 20, 0, 20 }) },
						Obstacles = { flat(0, { -1, 10, 9, 10, 9, 11, -1, 11 }) },
					},
				},
			}
			local mesh = room(0, -1)
			local sliver = Snap.Snap(mesh, v(9.6, 9.5), extents, {})
			local strip = Snap.Snap(turned, v(9.5, 9.6), extents, {})
			expect(Snap.Snap(turned, v(9.5, 12), extents, {})).is(strip)
			local east = edgeWhere(mesh, sliver, function(a, b)
				return a.X >= 10 and b.X >= 10
			end)
			local north = edgeWhere(turned, strip, function(a, b)
				return a.Z >= 10 and b.Z >= 10
			end)
			local function answers(): string
				return table.concat({
					tostring(Clearance.CutOff(mesh, sliver, east, 0.51, 9.6, 9.5)),
					tostring(Clearance.CutOff(mesh, sliver, east, 0.51, 12, 9.5)), -- x differs
					tostring(Clearance.CutOff(turned, strip, north, 0.51, 9.5, 9.6)),
					tostring(Clearance.CutOff(turned, strip, north, 0.51, 9.5, 12)), -- z differs
					tostring(Clearance.Separated(mesh, sliver, 0.51, 9.6, 9.5, 12, 9.45)),
					tostring(Clearance.Separated(mesh, sliver, 0.51, 9.6, 9.5, 9.65, 9.45)), -- qx
					tostring(Clearance.Separated(turned, strip, 0.51, 9.5, 9.6, 9.45, 12)),
					tostring(Clearance.Separated(turned, strip, 0.51, 9.5, 9.6, 9.45, 9.65)), -- qz
				}, " ")
			end
			local expected = "true false true false true false true false"
			expect(answers()).is(expected)
			-- Asked again, now all remembered, and once more after a question at another radius.
			expect(answers()).is(expected)
			Clearance.CutOff(mesh, sliver, east, 0.6, 9.6, 9.5)
			expect(answers()).is(expected)
		end)

		test("a point pushed over an edge the other reaches is not parted from it (E3)", function()
			-- A long sliver on the south wall of a floor of 400 small posts: both points stand
			-- pushed off the wall, one past the sliver's edge, and the flood connects them. Read
			-- by its barrier parity alone (it lies in no barrier polygon), they came out parted.
			math.randomseed(2727)
			local posts = {}
			for _ = 1, 400 do
				local cx, cz = 1 + math.random() * 62, 1 + math.random() * 30
				local w, d = 0.1 + math.random() * 0.3, 0.1 + math.random() * 0.3
				table.insert(posts, flat(0, { cx, cz, cx + w, cz, cx + w, cz + d, cx, cz + d }))
			end
			local mesh = NavMesh.Build {
				TileSize = 64,
				Floors = { Ground = { Walkable = { flat(0, { 0, 0, 64, 0, 64, 32, 0, 32 }) }, Obstacles = posts } },
			}
			local p, q, r =
				v(42.976383209228516, 0.49771571159362793),
				v(2.6359567642211914, 0.03136702626943588),
				0.8229155590030512
			local tri = Snap.Snap(mesh, p, vector.create(1e-4, 4, 1e-4), {})
			expect(Snap.Snap(mesh, q, vector.create(1e-4, 4, 1e-4), {})).is(tri)
			expect(Clearance.Separated(mesh, tri, r, p.X, p.Z, q.X, q.Z)).is(false)
			expect(Flood.Connected(Flood.New(mesh), r, p, q)).is(true)
		end)

		test("an end still covered once pushed out has no side, and is not cut off", function()
			local mesh = room(0, -1)
			-- 0.05 over the slab's corner: pushed 0.51 from it, it is 0.49 from the north wall.
			local a = v(10, 9.05)
			expect(status(mesh, a, v(15, 5), 0.51)).is("Success")
			local s, count = status(mesh, a, v(12, 9.45), 0.51)
			expect(s).is("Success")
			expect(count).is(2)
		end)

		test("ends with no clear line between them but nothing parting them keep one triangle", function()
			-- r 0.45 passes the 1-stud gap, though the straight line grazes the slab's corner.
			local mesh = room(0, -1)
			local a, b = v(9.6, 9.3), v(11.5, 9.3)
			expect(Snap.Snap(mesh, a, extents, {})).is(Snap.Snap(mesh, b, extents, {}))
			local s, count = status(mesh, a, b, 0.45)
			expect(s).is("Success")
			expect(count).is(2)
		end)

		test("a detour leaves the shared triangle and comes back into it", function()
			local mesh = room(-6, -3)
			local a, b = v(9.6, 9.5), v(12, 9.45)
			local t = Snap.Snap(mesh, a, extents, {})
			local result, corridor = Search.Run(mesh, t, a, t, b, {}, math.huge, 0.51)
			expect(result).is("Success")
			expect(corridor[1]).is(t)
			expect(corridor[#corridor]).is(t)
			expect(#corridor > 4).with_context(table.concat(corridor, " ")).is_true()
			for i = 2, #corridor - 1 do
				expect(corridor[i] >= 1 and corridor[i] <= Storage.TriangleCount(mesh)).is_true()
			end
		end)

		test("a goal cut off from the edge it is reached by is passed through, then reached round", function()
			-- The reversed repro with a way under the slab: entering the sliver from the east, the
			-- goal is past the gap; the search passes through and goes round to its west edge.
			local mesh = room(-6, -3)
			local a, b = v(15, 5), v(9.6, 9.5)
			local startT = Snap.Snap(mesh, a, extents, {})
			local goalT = Snap.Snap(mesh, b, extents, {})
			local result, corridor = Search.Run(mesh, startT, a, goalT, b, {}, math.huge, 0.51)
			expect(result).is("Success")
			expect(corridor[1]).is(startT)
			expect(corridor[#corridor]).is(goalT)
			for i = 1, #corridor do
				expect(corridor[i] >= 1 and corridor[i] <= Storage.TriangleCount(mesh)).is_true()
				expect(corridor[i] ~= goalT or i == #corridor).with_context(table.concat(corridor, " ")).is_true()
			end
			local path = NavMesh.FindPath(mesh, a, b, { AgentRadius = 0.51 })
			expect(path.Status).is("Success")
			local lowest = math.huge
			for _, w in path.Waypoints do
				lowest = math.min(lowest, (w.Position :: any).Z)
			end
			expect(lowest < -3).is_true()
		end)

		test("a Partial from a lone triangle ends at its point nearest the goal", function()
			local mesh = NavMesh.Build {
				Floors = { Ground = { Walkable = { flat(0, { 0, 0, 4, 0, 0, 4 }), flat(0, { 10, 0, 14, 0, 14, 4 }) } } },
			}
			local path = NavMesh.FindPath(mesh, v(1, 1), v(13, 1), { AgentRadius = 0.1 })
			expect(path.Status).is("Partial")
			local last = path.Waypoints[#path.Waypoints].Position :: any
			expect(math.abs(last.X - 4) < 1e-6 and math.abs(last.Z) < 1e-6).with_context(`{last.X}, {last.Z}`).is_true()
		end)

		test("remembered walls belong to their own triangle", function()
			local mesh = room(0, -1)
			local sliver = Snap.Snap(mesh, v(9.6, 9.5), extents, {})
			local other = Snap.Snap(mesh, v(15, 5), extents, {})
			expect(sliver ~= other).is_true()
			-- The sliver's edge towards (20, 10) from (10, 9): the one the start can't reach.
			local exit = 0
			local verts = { Storage.GetTriangle(mesh, sliver) }
			for e = 1, 3 do
				local p, q = Storage.GetVertex(mesh, verts[e % 3 + 1]), Storage.GetVertex(mesh, verts[(e + 1) % 3 + 1])
				if math.max(p.X, q.X) == 20 and math.min(p.X, q.X) == 10 then
					exit = e
				end
			end
			expect(exit ~= 0).is_true()
			-- Both orders: each call must see its own triangle's walls, not the last one's.
			for _ = 1, 2 do
				expect(Clearance.CutOff(mesh, other, 1, 0.51, 15, 5)).is(false)
				expect(Clearance.CutOff(mesh, sliver, exit, 0.51, 9.6, 9.5)).is(true)
				expect(Clearance.CutOff(mesh, other, 1, 0.51, 15, 5)).is(false)
			end
		end)

		test("what the barriers catch over fixed queries is pinned (soundness: the flood spec)", function()
			-- A characterization: every cut-off verdict over fixed random queries, as a count and a
			-- hash. The FindPath flood spec proves the verdicts sound; this pins how many blocks
			-- they catch, so a change that loses (or adds) one is seen. Re-pin only after the
			-- flood spec and tools/navmesh/bench/radius_oracle.luau still pass.
			math.randomseed(2727)
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
			for _ = 1, 40 do
				local cx, cz, w, d = rnd(1, 63), rnd(12, 30), rnd(0.3, 2), rnd(0.3, 2)
				table.insert(
					obstacles,
					flat(0, { cx, cz, cx + w, cz + 0.2, cx + w - 0.1, cz + d, cx - 0.2, cz + d - 0.1 })
				)
			end
			local mesh = NavMesh.Build {
				TileSize = 64,
				Floors = { Ground = { Walkable = { flat(0, { 0, 0, 64, 0, 64, 32, 0, 32 }) }, Obstacles = obstacles } },
			}
			local bits, cuts, parted = {}, 0, 0
			for i = 1, 600 do
				local r = rnd(0.2, 1.2)
				-- Half in the strip along the north of the slabs, where the gap slivers are.
				local p = v(rnd(0, 64), if i % 2 == 0 then rnd(8, 10) else rnd(0, 32))
				local tri = Snap.Snap(mesh, p, vector.create(1e-4, 4, 1e-4), {})
				if tri == 0 then
					continue
				end
				for e = 1, 3 do
					local cut = Clearance.CutOff(mesh, tri, e, r, p.X, p.Z)
					table.insert(bits, if cut then "1" else "0")
					cuts += if cut then 1 else 0
				end
				local q = v(p.X + rnd(-4, 4), p.Z + rnd(-0.4, 0.4))
				if Snap.Snap(mesh, q, vector.create(1e-4, 4, 1e-4), {}) == tri then
					local apart = Clearance.Separated(mesh, tri, r, p.X, p.Z, q.X, q.Z)
					table.insert(bits, if apart then "S" else "s")
					parted += if apart then 1 else 0
				end
			end
			local hash = 0
			for i, b in bits do
				hash = (hash * 31 + string.byte(b) * i) % 1000000007
			end
			-- Re-pinned in E3 (was 3 parted): all three had a point pushed out of its thin
			-- triangle, and the flood connects the two pushed points in each.
			expect(`{#bits} verdicts, {cuts} cut off, {parted} parted, hash {hash}`).is(
				"1844 verdicts, 221 cut off, 0 parted, hash 557876296"
			)
		end)
	end)
end
