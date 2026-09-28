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
			local r = 1.5
			local path = NavMesh.FindPath(mesh, v(2, 2), v(18, 2), { AgentRadius = r })
			expect(path.Status).is("Success")
			local corners = { v(8, 15), v(12, 15) }
			local waypoints = path.Waypoints
			expect(#waypoints).is(4)
			for i = 2, #waypoints - 1 do
				local p = waypoints[i].Position :: any
				local nearest = math.min(vector.magnitude(p - corners[1]), vector.magnitude(p - corners[2]))
				expect(math.abs(nearest - r) < 1e-6).with_context(`waypoint {i} is {nearest} from its corner`).is_true()
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
