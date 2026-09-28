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

	-- Triangles by grid points (rotation-normalized), with their corner and portal widths.
	local function byTriangle(mesh: any): { [string]: string }
		local out = {}
		for tri = 1, Storage.TriangleCount(mesh) do
			local keys = {}
			for k, id in { Storage.GetTriangle(mesh, tri) } do
				local p = Storage.GetVertex(mesh, id)
				keys[k] = math.round(p.X * 256) * 1e7 + math.round(p.Z * 256)
			end
			local first = if keys[1] < keys[2] and keys[1] < keys[3] then 1 elseif keys[2] < keys[3] then 2 else 3
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
			-- Wall flags too (ticket 22: an in-place Update must re-flag the vertices it keeps).
			local ids = { Storage.GetTriangle(mesh, tri) }
			for i = 0, 2 do
				table.insert(widths, if Storage.IsWallVertex(mesh, ids[(first + i - 1) % 3 + 1]) then "w" else "-")
			end
			out[`{keys[first]}:{keys[first % 3 + 1]}:{keys[(first + 1) % 3 + 1]}`] = table.concat(widths, " ")
		end
		return out
	end

	-- `desc` with `obstacles` added to floor `floor`'s authored obstacles.
	local function baked(desc: any, floor: string, obstacles: { any }): any
		local copy = table.clone(desc)
		copy.Floors = table.clone(desc.Floors)
		copy.Floors[floor] = table.clone(desc.Floors[floor])
		local list = table.clone(desc.Floors[floor].Obstacles or {})
		for _, obstacle in obstacles do
			table.insert(list, obstacle)
		end
		copy.Floors[floor].Obstacles = list
		return copy
	end

	-- The first difference between an updated mesh and a fresh Build (triangles, widths, drawn
	-- seams and links), or "" when they are the same mesh.
	local function differsFromFresh(mesh: any, fresh: any): string
		if Storage.TriangleCount(mesh) ~= Storage.TriangleCount(fresh) then
			return `{Storage.TriangleCount(mesh)} triangles vs {Storage.TriangleCount(fresh)}`
		end
		local updated, expected = byTriangle(mesh), byTriangle(fresh)
		for key, widths in expected do
			if updated[key] ~= widths then
				return `{key}: {updated[key]} vs {widths}`
			end
		end
		if canonical(mesh) ~= canonical(fresh) then
			return "draw lists differ"
		end
		return structureOk(mesh)
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

		-- An open 32 x 24 floor: tile lines at every 8 (or 16) studs in both directions.
		local open: any = { Floors = { Ground = { Walkable = { flat(0, { 0, 0, 32, 0, 32, 24, 0, 24 }) } } } }
		local placements = {
			{ "west side on a tile line", flat(0, { 16, 9, 17.5, 9, 17.5, 11, 16, 11 }) },
			{ "east side on a tile line", flat(0, { 14.5, 9, 16, 9, 16, 11, 14.5, 11 }) },
			{ "south side on a tile line", flat(0, { 10, 8, 12, 8, 12, 9.5, 10, 9.5 }) },
			{ "north side on a tile line", flat(0, { 10, 14.5, 12, 14.5, 12, 16, 10, 16 }) },
			{ "across a tile corner", flat(0, { 15.3, 15.4, 16.8, 15.2, 16.6, 16.7, 15.1, 16.5 }) },
			{ "inside an upper tile", flat(0, { 26.2, 18.3, 27.9, 18.9, 27.1, 20.4 }) },
			{ "across the outer wall", flat(0, { 29.3, 3.1, 33, 3.4, 32.8, 5.2, 29.1, 4.9 }) },
		}

		test("an update equals a fresh Build wherever the obstacle sits against the tiles", function()
			for _, size in { 8, 16 } do
				local desc = table.clone(open)
				desc.TileSize = size
				for _, placement in placements do
					local mesh = NavMesh.Build(desc)
					NavMesh.AddObstacle(mesh, "Ground", placement[2])
					NavMesh.Update(mesh)
					local fresh = NavMesh.Build(baked(desc, "Ground", { placement[2] }))
					expect(differsFromFresh(mesh, fresh)).with_context(`{placement[1]}, tiles of {size}`).is("")
				end
			end
		end)

		test("a run of adds and removes equals a fresh Build of the obstacles left", function()
			-- Also shifted far along Z, so the floor's X and Z ranges don't overlap.
			for _, dz in { 0, 64 } do
				local function shifted(ring: { any }): { any }
					local out = {}
					for i, p in ring do
						out[i] = p + vector.create(0, 0, dz)
					end
					return out
				end
				local desc: any =
					{ TileSize = 8, Floors = { Ground = { Walkable = { shifted(open.Floors.Ground.Walkable[1]) } } } }
				local a, b = shifted(placements[1][2]), shifted(placements[5][2])
				local mesh = NavMesh.Build(desc)
				local idA = NavMesh.AddObstacle(mesh, "Ground", a)
				NavMesh.Update(mesh)
				NavMesh.AddObstacle(mesh, "Ground", b)
				NavMesh.Update(mesh)
				expect(differsFromFresh(mesh, NavMesh.Build(baked(desc, "Ground", { a, b }))))
					.with_context(`a, b; dz {dz}`)
					.is("")
				-- Removing a re-snaps the tiles below the corner with b, which also crosses the tile
				-- line x = 16 above them, beside clean tiles. (That once failed with "a ring crosses
				-- a tile line between snapped vertices": the re-snap left the tile lines out.)
				NavMesh.RemoveObstacle(mesh, idA)
				NavMesh.Update(mesh)
				expect(differsFromFresh(mesh, NavMesh.Build(baked(desc, "Ground", { b }))))
					.with_context(`b; dz {dz}`)
					.is("")
			end
		end)

		test("removing an obstacle cornered on a kept vertex leaves it as a fresh Build does (ticket 22)", function()
			-- The crate's corner is the tile corner (16, 16): a baseline vertex that is kept through
			-- the add and the remove, and is a wall vertex only while the crate is there.
			local desc = table.clone(open)
			desc.TileSize = 8
			local crate = flat(0, { 16, 16, 18, 16, 18, 18, 16, 18 })
			local mesh = NavMesh.Build(desc)
			local id = NavMesh.AddObstacle(mesh, "Ground", crate)
			NavMesh.Update(mesh)
			expect(differsFromFresh(mesh, NavMesh.Build(baked(desc, "Ground", { crate })))).with_context("added").is("")
			NavMesh.RemoveObstacle(mesh, id)
			NavMesh.Update(mesh)
			expect(differsFromFresh(mesh, NavMesh.Build(desc))).with_context("removed").is("")
		end)

		test("an update on a ramp, and one narrowing a corridor across a tile line, equal fresh Builds", function()
			-- A crate on the Stairs ramp: rebuilt vertices take the ramp's heights.
			local stairs = Fixtures.ThreeFloorStairs.Desc
			local onRamp = flat(0, { 13.1, 1.3, 14.7, 1.1, 14.9, 2.6, 13.3, 2.9 })
			local mesh = NavMesh.Build(stairs)
			NavMesh.AddObstacle(mesh, "Stairs", onRamp)
			NavMesh.Update(mesh)
			expect(differsFromFresh(mesh, NavMesh.Build(baked(stairs, "Stairs", { onRamp }))))
				.with_context("ramp")
				.is("")
			-- A 1.5-wide corridor in 4-stud tiles, and a crate just west of the tile line x = 8:
			-- the clean tile east of it narrows too, so its widths must be recomputed.
			local narrow: any =
				{ TileSize = 4, Floors = { Ground = { Walkable = { flat(0, { 0, 0, 40, 0, 40, 1.5, 0, 1.5 }) } } } }
			local crate = flat(0, { 7.6, 0.3, 7.9, 0.3, 7.9, 0.9, 7.6, 0.9 })
			local corridorMesh = NavMesh.Build(narrow)
			NavMesh.AddObstacle(corridorMesh, "Ground", crate)
			NavMesh.Update(corridorMesh)
			expect(differsFromFresh(corridorMesh, NavMesh.Build(baked(narrow, "Ground", { crate }))))
				.with_context("narrow")
				.is("")
		end)

		test("a link on a slope stays usable through an update elsewhere", function()
			local desc: any = table.clone(Fixtures.ThreeFloorStairs.Desc)
			desc.Links = { { From = v(13.3, 1.65, 2.7), To = v(13.3, 0, 12.1), Label = "Hop" } }
			local mesh = NavMesh.Build(desc)
			NavMesh.AddObstacle(mesh, "Ground", flat(0, { 30, 15, 32, 15, 32, 17, 30, 17 }))
			NavMesh.Update(mesh)
			local fromTri, _, toTri = Storage.GetLink(mesh, 1)
			expect(fromTri ~= 0 and toTri ~= 0).is_true()
		end)

		test("an obstacle beside a seam leaves the seams a fresh Build makes", function()
			local desc = Fixtures.ThreeFloorStairs.Desc
			local crate = flat(0, { 8.6, 1.2, 11.4, 1.1, 11.3, 2.7, 8.7, 2.9 })
			local mesh = NavMesh.Build(desc)
			NavMesh.AddObstacle(mesh, "Ground", crate)
			NavMesh.Update(mesh)
			expect(differsFromFresh(mesh, NavMesh.Build(baked(desc, "Ground", { crate })))).is("")
		end)

		test("a link end under an obstacle drops out even near the obstacle's edge, and comes back", function()
			-- Each crate covers one end of the jump, that end lying 0.2 to 0.3 studs inside it:
			-- within the link snap's 0.5-stud reach of the uncovered ground.
			for _, crate in
				{
					flat(0, { 8.7, 4.6, 10, 4.6, 10, 5.3, 8.7, 5.3 }), -- From (9, 5)
					flat(0, { 14.5, 4.8, 15.4, 4.8, 15.4, 6, 14.5, 6 }), -- To (15, 5)
				}
			do
				local mesh = NavMesh.Build(Fixtures.LinkJump.Desc)
				local before = canonical(mesh)
				local id = NavMesh.AddObstacle(mesh, "Ground", crate)
				NavMesh.Update(mesh)
				-- The jump is out: no path crosses the gap (none may route into the crate).
				expect(NavMesh.FindPath(mesh, v(2, 0, 2), v(22, 0, 8)).Status).is("Partial")
				NavMesh.RemoveObstacle(mesh, id)
				NavMesh.Update(mesh)
				expect(canonical(mesh)).is(before)
				expect(NavMesh.FindPath(mesh, v(2, 0, 2), v(22, 0, 8)).Status).is("Success")
			end
		end)

		test("a change on one floor leaves paths on the floor above it valid", function()
			local mesh = NavMesh.Build(Fixtures.ThreeFloorStairs.Desc)
			local upper = NavMesh.FindPath(mesh, v(24, 5, 12), v(36, 5, 14))
			local ground = NavMesh.FindPath(mesh, v(24, 0, 12), v(36, 0, 14))
			expect(upper.Waypoints[1].Floor).is("Upper")
			NavMesh.AddObstacle(mesh, "Ground", flat(0, { 29, 12.5, 31, 12.5, 31, 13.5, 29, 13.5 }))
			NavMesh.Update(mesh)
			expect(NavMesh.IsPathValid(mesh, ground)).is(false)
			expect(NavMesh.IsPathValid(mesh, upper)).is_true()
		end)

		test("any applied change invalidates paths through the tiles at a link's ends", function()
			-- Small tiles, so the change's own tiles are far from the link's.
			local desc: any = table.clone(Fixtures.LinkJump.Desc)
			desc.TileSize = 4
			local mesh = NavMesh.Build(desc)
			-- A path that stays on the far pad, through the link's To end but not over the link.
			local beside = NavMesh.FindPath(mesh, v(15, 0, 5), v(15.5, 0, 6))
			NavMesh.Update(mesh) -- nothing pending: nothing changes
			expect(NavMesh.IsPathValid(mesh, beside)).is_true()
			NavMesh.AddObstacle(mesh, "Ground", flat(0, { 1, 8, 2, 8, 2, 9, 1, 9 }))
			NavMesh.Update(mesh)
			expect(NavMesh.IsPathValid(mesh, beside)).is(false)
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
				NavMesh.AddObstacle(mesh, "Ground", door[1])
			end).fails_with(
				"AddObstacle: obstacle on floor 'Ground': expected a ring %(a list of points%), got a point"
			)
			expect(function()
				NavMesh.RemoveObstacle(mesh, 3)
			end).fails_with("no obstacle 3")
			local id = NavMesh.AddObstacle(mesh, "Ground", door)
			NavMesh.RemoveObstacle(mesh, id)
			expect(function()
				NavMesh.RemoveObstacle(mesh, id)
			end).fails_with("already removed")
		end)

		test("RemoveObstacle rejects anything but a recorded id", function()
			local mesh = NavMesh.Build(corridor)
			NavMesh.AddObstacle(mesh, "Ground", door)
			NavMesh.AddObstacle(mesh, "Ground", flat(0, { 30, 1, 31, 1, 31, 2, 30, 2 }))
			for _, id in { 0, 1.5, "1", 3 } do
				expect(function()
						NavMesh.RemoveObstacle(mesh, id :: any)
					end)
					.with_context(tostring(id))
					.fails_with(`no obstacle {id}`)
			end
		end)

		test("a door toggled all day keeps one record, a flat bake and a flat Update", function()
			local mesh = NavMesh.Build(corridor)
			local bare = buffer.len(NavMesh.Serialize(mesh))
			local times, ids = {}, {}
			for cycle = 1, 1000 do
				local id = NavMesh.AddObstacle(mesh, "Ground", door)
				local t0 = os.clock()
				NavMesh.Update(mesh)
				local added = os.clock() - t0
				expect(Storage.ObstacleCount(mesh)).with_context(`cycle {cycle}, door closed`).is(1)
				NavMesh.RemoveObstacle(mesh, id)
				t0 = os.clock()
				NavMesh.Update(mesh)
				table.insert(times, added + os.clock() - t0)
				expect(Storage.ObstacleCount(mesh)).with_context(`cycle {cycle}, door open`).is(0)
				table.insert(ids, id)
			end
			-- The record is freed, but its id is never reused and still reads as removed.
			expect(ids[1000]).is(1000)
			expect(function()
				NavMesh.RemoveObstacle(mesh, ids[1])
			end).fails_with("obstacle 1 is already removed")
			expect(function()
				NavMesh.RemoveObstacle(mesh, 1001)
			end).fails_with("no obstacle 1001")
			-- The bake is back to the obstacle-free size, and still round-trips the next id.
			local data = NavMesh.Serialize(mesh)
			expect(buffer.len(data)).is(bare)
			local loaded = NavMesh.Deserialize(data)
			expect(NavMesh.AddObstacle(loaded, "Ground", door)).is(1001)
			-- A pending add that is removed before any Update leaves no record either.
			NavMesh.RemoveObstacle(loaded, 1001)
			expect(Storage.ObstacleCount(loaded)).is(0)
			-- Update does not slow down: the last 100 cycles cost about what the first 100 did
			-- (before records were freed, 1000 cycles made it about 3x slower).
			local function median(from: number): number
				local slice = table.move(times, from, from + 99, 1, {})
				table.sort(slice)
				return slice[50]
			end
			local first, last = median(1), median(901)
			expect(last < 2 * first).with_context(`first {first * 1000} ms, last {last * 1000} ms`).is_true()
		end)

		test("obstacle errors point at the caller's line", function()
			local mesh = NavMesh.Build(corridor)
			local id = NavMesh.AddObstacle(mesh, "Ground", door)
			NavMesh.RemoveObstacle(mesh, id)
			local calls = {
				function()
					NavMesh.AddObstacle(mesh, "Upper", door)
				end,
				function()
					NavMesh.AddObstacle(mesh, "Ground", flat(0, { 0, 0, 4, 4, 4, 0, 0, 4 }))
				end,
				function()
					NavMesh.RemoveObstacle(mesh, 7)
				end,
				function()
					NavMesh.RemoveObstacle(mesh, id)
				end,
			}
			for i, call in calls do
				local ok, err = pcall(call)
				expect(ok).is(false)
				expect(tostring(err):find("Obstacles.spec", 1, true) ~= nil).with_context(`call {i}: {err}`).is_true()
			end
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
		test(
			"an Update whose seam join fails after the tiles are rebuilt leaves the mesh as it was (ticket 22)",
			function()
				-- Covering the Ground side of the Ground-Stairs seam (x = 10) removes every piece of it,
				-- so Connect fails after the rebuilt tiles are written: an in-place commit must undo.
				local stairs = Fixtures.ThreeFloorStairs.Desc
				local mesh = NavMesh.Build(stairs)
				local before = canonical(mesh)
				local widths = byTriangle(mesh)
				NavMesh.AddObstacle(mesh, "Ground", flat(0, { 8.5, -1, 11, -1, 11, 5, 8.5, 5 }))
				local ok = pcall(NavMesh.Update, mesh)
				expect(ok).is(false)
				expect(canonical(mesh)).is(before)
				local after = byTriangle(mesh)
				local same = true
				for key, value in widths do
					same = same and after[key] == value
				end
				expect(same).is_true()
				expect(structureOk(mesh)).is("")
				NavMesh.Update(mesh)
				expect(canonical(mesh)).is(before)
			end
		)
	end)
end
