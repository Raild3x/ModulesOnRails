-- Authors: Logan Hunt (Raildex)
-- September 27, 2026
-- Dynamic obstacles (ticket 18): AddObstacle, RemoveObstacle and Update. Atomic updates with
-- rollback (SR13), add-then-remove equal to a fresh Build and no growth when toggling (SR14),
-- dirty tiles from the snapped box, and the clearance refresh.

return function(t: tiniest)
	local NavMesh = require("../NavMesh")
	local Build = require("../Build")
	local Storage = require("../Storage")
	local MeshChecks = require("./Helpers/MeshChecks")

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

	-- The mesh as a sorted list of drawn primitives: equal meshes draw equal lists, whatever
	-- their triangle ids.
	local function canonical(mesh: any): string
		local rows = {}
		for _, primitive in NavMesh.ToDrawList(mesh, { Tiles = true, Areas = true, Seams = true, Links = true }) do
			local numbers = {}
			for _, x in primitive.Points do
				table.insert(numbers, string.format("%.4f", x))
			end
			table.insert(rows, `{primitive.Kind}|{primitive.Layer}|{primitive.Color}|{table.concat(numbers, ",")}`)
		end
		table.sort(rows)
		return table.concat(rows, "\n")
	end

	local function structureOk(mesh: any): string
		return table.concat(MeshChecks.Structure(mesh), "\n")
	end

	-- A 40 x 4 corridor in 8-stud tiles, and a door across it at x = 15..17.
	local corridor: any =
		{ TileSize = 8, Floors = { Ground = { Walkable = { flat(0, { 0, 0, 40, 0, 40, 4, 0, 4 }) } } } }
	local door = flat(0, { 15, -1, 17, -1, 17, 5, 15, 5 })

	describe("Update", function()
		test("an obstacle takes effect at Update, blocking paths and invalidating them", function()
			local mesh = NavMesh.Build(corridor)
			local path = NavMesh.FindPath(mesh, v(1, 0, 2), v(39, 0, 2))
			expect(path.Status).is("Success")
			local id = NavMesh.AddObstacle(mesh, "Ground", door)
			-- Pending until Update.
			expect(NavMesh.FindPath(mesh, v(1, 0, 2), v(39, 0, 2)).Status).is("Success")
			expect(NavMesh.IsPathValid(mesh, path)).is_true()
			NavMesh.Update(mesh)
			expect(NavMesh.IsPathValid(mesh, path)).is(false)
			expect(NavMesh.FindPath(mesh, v(1, 0, 2), v(39, 0, 2)).Status).is("Partial")
			expect(structureOk(mesh)).is("")
			NavMesh.RemoveObstacle(mesh, id)
			NavMesh.Update(mesh)
			expect(NavMesh.FindPath(mesh, v(1, 0, 2), v(39, 0, 2)).Status).is("Success")
		end)

		test("adding then removing matches a fresh Build exactly", function()
			for _, scenario in { Fixtures.Courtyard, Fixtures.ThreeFloorStairs, Fixtures.LinkJump } do
				local desc: any = table.clone(scenario.Desc)
				desc.TileSize = 4
				local fresh = canonical(NavMesh.Build(desc))
				local mesh = NavMesh.Build(desc)
				local id = NavMesh.AddObstacle(mesh, "Ground", flat(0, { 5.3, 1.2, 8.9, 1.9, 8.1, 3.7, 5.7, 3.4 }))
				NavMesh.Update(mesh)
				expect(canonical(mesh) ~= fresh).with_context(scenario.Name).is_true()
				expect(structureOk(mesh)).with_context(scenario.Name).is("")
				NavMesh.RemoveObstacle(mesh, id)
				NavMesh.Update(mesh)
				expect(canonical(mesh)).with_context(scenario.Name).is(fresh)
			end
		end)

		test("an update equals a fresh Build with the obstacle baked in, widths included", function()
			-- Triangles by grid points (rotation-normalized), with their corner and portal widths.
			local function byTriangle(mesh: any): { [string]: string }
				local out = {}
				for tri = 1, Storage.TriangleCount(mesh) do
					local keys = {}
					for k, id in { Storage.GetTriangle(mesh, tri) } do
						local p = Storage.GetVertex(mesh, id)
						keys[k] = math.round(p.X * 256) * 1e7 + math.round(p.Z * 256)
					end
					local first = if keys[1] < keys[2] and keys[1] < keys[3]
						then 1
						elseif keys[2] < keys[3] then 2
						else 3
					local widths = {}
					for i = 0, 2 do
						local k = (first + i - 1) % 3 + 1
						table.insert(
							widths,
							string.format(
								"%.6f/%.6f",
								Storage.GetCornerWidth(mesh, tri, k),
								Storage.GetPortalWidth(mesh, tri, k)
							)
						)
					end
					out[`{keys[first]}:{keys[first % 3 + 1]}:{keys[(first + 1) % 3 + 1]}`] = table.concat(widths, " ")
				end
				return out
			end
			local crate = flat(0, { 12.3, 1.1, 15.8, 1.6, 15.2, 3.4, 12.7, 2.9 })
			for _, scenario in { Fixtures.Courtyard, Fixtures.ShallowObstacles } do
				local desc: any = table.clone(scenario.Desc)
				desc.TileSize = 4
				local mesh = NavMesh.Build(desc)
				NavMesh.AddObstacle(mesh, "Ground", crate)
				NavMesh.Update(mesh)
				local baked: any = table.clone(desc)
				baked.Floors = { Ground = table.clone(desc.Floors.Ground) }
				baked.Floors.Ground.Obstacles = table.clone(desc.Floors.Ground.Obstacles or {})
				table.insert(baked.Floors.Ground.Obstacles, crate)
				local updated, fresh = byTriangle(mesh), byTriangle(NavMesh.Build(baked))
				local mismatches = {}
				for key, widths in fresh do
					if updated[key] ~= widths then
						table.insert(mismatches, `{key}: {updated[key]} vs {widths}`)
					end
				end
				expect(Storage.TriangleCount(mesh))
					.with_context(scenario.Name)
					.is(Storage.TriangleCount(NavMesh.Build(baked)))
				expect(#mismatches).with_context(`{scenario.Name}: {mismatches[1]}`).is(0)
			end
		end)

		test("toggling a door many times never grows the mesh (SR14)", function()
			local mesh = NavMesh.Build(corridor)
			local triangles, vertices = Storage.TriangleCount(mesh), Storage.VertexCount(mesh)
			local sizes
			for cycle = 1, 20 do
				local id = NavMesh.AddObstacle(mesh, "Ground", door)
				NavMesh.Update(mesh)
				NavMesh.RemoveObstacle(mesh, id)
				NavMesh.Update(mesh)
				expect(Storage.TriangleCount(mesh)).is(triangles)
				expect(Storage.VertexCount(mesh)).is(vertices)
				local now = `{#mesh.SrcCoords},{#mesh.ExtraNext},{#mesh.PieceSeam},{mesh.TriangleCapacity}`
				if cycle == 1 then
					sizes = now
				end
				expect(now).with_context(`cycle {cycle}`).is(sizes)
			end
		end)

		test("an obstacle touching a tile line dirties the tile beyond it too (the pixel margin)", function()
			-- Its east side lies exactly on the tile line x = 16: that line gains vertices at
			-- z = 1 and 3, so the tile east of it must be rebuilt too, or the edges no longer
			-- meet and the corridor is cut.
			local mesh = NavMesh.Build(corridor)
			NavMesh.AddObstacle(mesh, "Ground", flat(0, { 14.5, 1, 16, 1, 16, 3, 14.5, 3 }))
			NavMesh.Update(mesh)
			expect(structureOk(mesh)).is("")
			expect(NavMesh.FindPath(mesh, v(1, 0, 2), v(39, 0, 2)).Status).is("Success")
		end)

		test("an obstacle straddling a tile line leaves no T-junction", function()
			local mesh = NavMesh.Build(corridor)
			NavMesh.AddObstacle(mesh, "Ground", flat(0, { 23.3, 0.5, 24.7, 0.5, 24.7, 1.5, 23.3, 1.5 }))
			NavMesh.Update(mesh)
			expect(structureOk(mesh)).is("")
			expect(NavMesh.FindPath(mesh, v(1, 0, 2), v(39, 0, 2)).Status).is("Success")
		end)

		test("only tiles near the change get new stamps", function()
			local mesh = NavMesh.Build(corridor)
			local near = NavMesh.FindPath(mesh, v(13, 0, 2), v(19, 0, 2))
			local far = NavMesh.FindPath(mesh, v(33, 0, 1), v(39, 0, 3))
			NavMesh.AddObstacle(mesh, "Ground", flat(0, { 15.5, 1.5, 16.5, 1.5, 16.5, 2.5, 15.5, 2.5 }))
			NavMesh.Update(mesh)
			expect(NavMesh.IsPathValid(mesh, near)).is(false)
			expect(NavMesh.IsPathValid(mesh, far)).is_true()
		end)

		test("clearance follows the obstacles", function()
			local mesh = NavMesh.Build(corridor)
			-- A pillar leaving a 1.5-stud gap on each side.
			local pillar = NavMesh.AddObstacle(mesh, "Ground", flat(0, { 19.5, 1.5, 20.5, 1.5, 20.5, 2.5, 19.5, 2.5 }))
			NavMesh.Update(mesh)
			expect(NavMesh.FindPath(mesh, v(1, 0, 2), v(39, 0, 2), { AgentRadius = 0.7 }).Status).is("Success")
			expect(NavMesh.FindPath(mesh, v(1, 0, 2), v(39, 0, 2), { AgentRadius = 0.8 }).Status).is("Partial")
			NavMesh.RemoveObstacle(mesh, pillar)
			NavMesh.Update(mesh)
			expect(NavMesh.FindPath(mesh, v(1, 0, 2), v(39, 0, 2), { AgentRadius = 1.9 }).Status).is("Success")
		end)

		test("seams and links keep working across an update", function()
			local mesh = NavMesh.Build(Fixtures.ThreeFloorStairs.Desc)
			NavMesh.AddObstacle(mesh, "Ground", flat(0, { 30, 12, 34, 12, 34, 16, 30, 16 }))
			NavMesh.Update(mesh)
			expect(NavMesh.FindPath(mesh, v(2, 0, 2), v(30, 5, 10)).Status).is("Success")
			-- A crate over a link's start takes the link out until it's removed.
			local jump = NavMesh.Build(Fixtures.LinkJump.Desc)
			local crate = NavMesh.AddObstacle(jump, "Ground", flat(0, { 8, 4, 10, 4, 10, 6, 8, 6 }))
			NavMesh.Update(jump)
			expect(NavMesh.FindPath(jump, v(2, 0, 2), v(22, 0, 8)).Status).is("Partial")
			NavMesh.SetLinkEnabled(jump, 1, true) -- still fine with an end off the mesh
			NavMesh.RemoveObstacle(jump, crate)
			NavMesh.Update(jump)
			expect(NavMesh.FindPath(jump, v(2, 0, 2), v(22, 0, 8)).Status).is("Success")
		end)

		test("link ends follow their triangles through a renumbering update", function()
			local desc: any = table.clone(Fixtures.LinkJump.Desc)
			desc.TileSize = 2
			local mesh = NavMesh.Build(desc)
			-- An obstacle on the first pad, away from the link, renumbers the triangles.
			NavMesh.AddObstacle(mesh, "Ground", flat(0, { 1, 1, 3, 1, 3, 3, 1, 3 }))
			NavMesh.Update(mesh)
			local Snap = require("../Snap")
			for id = 1, Storage.LinkCount(mesh) do
				local fromTri, from, toTri, to = Storage.GetLink(mesh, id)
				for _, pair in { { fromTri, from }, { toTri, to } } do
					local on = Snap.ClosestOnTriangle(mesh, pair[1], pair[2])
					expect(vector.magnitude(on - pair[2]) < 1e-6).with_context(`link {id}`).is_true()
				end
			end
			expect(NavMesh.FindPath(mesh, v(8, 0, 8), v(22, 0, 8)).Status).is("Success")
		end)

		test("an Update with nothing pending changes nothing", function()
			local mesh = NavMesh.Build(corridor)
			local path = NavMesh.FindPath(mesh, v(1, 0, 2), v(39, 0, 2))
			NavMesh.Update(mesh)
			expect(NavMesh.IsPathValid(mesh, path)).is_true()
		end)
	end)

	describe("Obstacle records", function()
		test("a bad obstacle errors at AddObstacle", function()
			local mesh = NavMesh.Build(corridor)
			expect(function()
				NavMesh.AddObstacle(mesh, "Upper", door)
			end).fails_with("no floor 'Upper'")
			expect(function()
				NavMesh.AddObstacle(mesh, "Ground", flat(0, { 0, 0, 4, 4, 4, 0, 0, 4 }))
			end).fails_with("AddObstacle: .*intersects itself")
			expect(function()
				NavMesh.RemoveObstacle(mesh, 3)
			end).fails_with("no obstacle 3")
			local id = NavMesh.AddObstacle(mesh, "Ground", door)
			NavMesh.RemoveObstacle(mesh, id)
			expect(function()
				NavMesh.RemoveObstacle(mesh, id)
			end).fails_with("already removed")
		end)

		test("a failing Update leaves the mesh as it was and rolls its records back (SR13)", function()
			local mesh = NavMesh.Build(corridor)
			local before = canonical(mesh)
			local path = NavMesh.FindPath(mesh, v(1, 0, 2), v(39, 0, 2))
			NavMesh.AddObstacle(mesh, "Ground", door)
			local original = Build.Internal.TriangulateTile
			Build.Internal.TriangulateTile = function(): any
				error("NavMesh.Build: injected failure", 0)
			end
			local ok, err = pcall(NavMesh.Update, mesh)
			Build.Internal.TriangulateTile = original
			expect(ok).is(false)
			expect(tostring(err)).is("NavMesh.Build: injected failure")
			expect(canonical(mesh)).is(before)
			expect(NavMesh.IsPathValid(mesh, path)).is_true()
			expect(NavMesh.FindPath(mesh, v(1, 0, 2), v(39, 0, 2)).Status).is("Success")
			-- The rolled-back door is gone: the next Update has nothing to do.
			NavMesh.Update(mesh)
			expect(canonical(mesh)).is(before)
		end)
	end)
end
