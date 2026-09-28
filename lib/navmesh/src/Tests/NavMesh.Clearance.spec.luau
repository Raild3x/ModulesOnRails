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
			local mesh = NavMesh.Build({
				TileSize = 8,
				Floors = { Ground = { Walkable = { flat(0, { 0, 0, 40, 0, 40, 40, 0, 40 }) } } },
			})
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
end
