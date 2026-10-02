-- Authors: Logan Hunt (Raildex)
-- October 2, 2026
-- Geometry simplification (Track F; docs/plans/navmesh/simplification-plan.md, guarantees
-- G1-G8). R1: one-sided ring simplification under NavMeshDesc.SimplifyTolerance.

return function(t: tiniest)
	local NavMesh = require("../NavMesh")
	local Build = require("../Build")
	local Storage = require("../Storage")
	local CDT = require("../../ConstrainedDelaunay")
	local MeshChecks = require("./Helpers/MeshChecks")
	local Flood = require("./Helpers/Flood")

	local describe = t.describe
	local expect = t.expect
	local test = t.test

	local Internal = Build.Internal
	local Orient2D = CDT.Orient2D

	local function v(x: number, y: number, z: number): any
		return vector.create(x, y, z)
	end

	-- A star-shaped ring of n points round (cx, cz): radius r, plus `noise` studs at random.
	local function blob(cx: number, cz: number, r: number, n: number, noise: number, y: number?): { any }
		local out = {}
		for i = 1, n do
			local a = (i - 1) / n * 2 * math.pi
			local rr = r + (math.random() - 0.5) * noise
			out[i] = v(cx + rr * math.cos(a), y or 0, cz + rr * math.sin(a))
		end
		return out
	end

	-- Where grid point (px, pz) is against the grid ring: 1 inside, 0 on it, -1 outside (exact).
	local function locate(xs: { number }, zs: { number }, px: number, pz: number): number
		local n, winding = #xs, 0
		for i = 1, n do
			local j = i % n + 1
			local o = Orient2D(xs[i], zs[i], xs[j], zs[j], px, pz)
			if
				o == 0
				and math.min(xs[i], xs[j]) <= px
				and px <= math.max(xs[i], xs[j])
				and math.min(zs[i], zs[j]) <= pz
				and pz <= math.max(zs[i], zs[j])
			then
				return 0
			end
			if zs[i] <= pz then
				if zs[j] > pz and o > 0 then
					winding += 1
				end
			elseif zs[j] <= pz and o < 0 then
				winding -= 1
			end
		end
		return if winding ~= 0 then 1 else -1
	end

	-- Distance (grid units) from a point to the grid ring's boundary.
	local function edgeDistance(xs: { number }, zs: { number }, px: number, pz: number): number
		local best = math.huge
		for i = 1, #xs do
			local j = i % #xs + 1
			local dx, dz = xs[j] - xs[i], zs[j] - zs[i]
			local s = math.clamp(((px - xs[i]) * dx + (pz - zs[i]) * dz) / (dx * dx + dz * dz), 0, 1)
			best = math.min(best, math.sqrt((xs[i] + s * dx - px) ^ 2 + (zs[i] + s * dz - pz) ^ 2))
		end
		return best
	end

	-- G1 and G2 for a ring and its simplified form (grid units): `grow` true when the ring may only
	-- grow (an obstacle). Returns the first breach, or "".
	local function oneSided(before: any, after: any, grow: boolean, eps: number): string
		local inner, outer = if grow then before else after, if grow then after else before
		-- inner within outer: every inner point in or on outer, every outer point out of or on inner.
		for i = 1, #inner.X do
			if locate(outer.X, outer.Z, inner.X[i], inner.Z[i]) < 0 then
				return `point ({inner.X[i]}, {inner.Z[i]}) leaves the region on the wrong side`
			end
		end
		for i = 1, #outer.X do
			if locate(inner.X, inner.Z, outer.X[i], outer.Z[i]) > 0 then
				return `point ({outer.X[i]}, {outer.Z[i]}) cuts into the region`
			end
		end
		-- Within eps both ways, point by point.
		for _, pair in { { before, after }, { after, before } } do
			local from, to = pair[1], pair[2]
			for i = 1, #from.X do
				local d = edgeDistance(to.X, to.Z, from.X[i], from.Z[i])
				if d > eps + 1e-9 then
					return `point ({from.X[i]}, {from.Z[i]}) is {d} from the other ring (eps {eps})`
				end
			end
		end
		return ""
	end

	describe("R1: one-sided ring simplification (G1, G2)", function()
		test("random dense rings only grow (obstacles) or shrink (walkable), within the tolerance", function()
			math.randomseed(11)
			local removed, kept = 0, 0
			for trial = 1, 60 do
				local n = math.random(8, 160)
				local ring = blob(math.random() * 50, math.random() * 50, 1 + math.random() * 8, n, math.random() * 0.6)
				for _, eps in { 1 / 16, 0.1, 0.25 } do
					local before = Internal.ObstacleRing(ring, "ring", 0)
					local grown = Internal.ObstacleRing(ring, "ring", eps)
					expect(oneSided(before, grown, true, eps * 256))
						.with_context(`trial {trial} eps {eps} obstacle`)
						.is("")
					local shrunk = Build.Build { SimplifyTolerance = eps, Floors = { G = { Walkable = { ring } } } }
					local _, _, _, rings = Storage.GetFloorSources(shrunk, 1)
					expect(oneSided(before, rings[1], false, eps * 256))
						.with_context(`trial {trial} eps {eps} walkable`)
						.is("")
					removed += 2 * #before.X - #grown.X - #rings[1].X
					kept += #grown.X + #rings[1].X
				end
			end
			-- Not vacuous: the noise is well above the tolerances, so many points go.
			expect(removed > kept / 4).with_context(`{removed} removed, {kept} kept`).is_true()
		end)

		test("a cylinder's convex 24-gon collapses outward; tolerance 0 keeps every point", function()
			local cylinder = blob(10, 10, 2, 24, 0)
			expect(#Internal.ObstacleRing(cylinder, "c", 0).X).is(24)
			-- Each collapse adds a triangle about 0.07 studs high: too much for 1/16, fine for 0.1.
			expect(#Internal.ObstacleRing(cylinder, "c", 1 / 16).X).is(24)
			local grown = Internal.ObstacleRing(cylinder, "c", 0.1)
			expect(#grown.X < 24).with_context(`{#grown.X} points`).is_true()
			expect(oneSided(Internal.ObstacleRing(cylinder, "c", 0), grown, true, 0.1 * 256)).is("")
		end)

		test("box rings lose nothing, and a ring that would stop being simple is kept as given", function()
			local box = { v(0, 0, 0), v(4, 0, 0), v(4, 0, 4), v(0, 0, 4) }
			expect(#Internal.ObstacleRing(box, "b", 0.25).X).is(4)
			-- A thin comb: chords across its teeth would cross the next tooth.
			local comb = { v(0, 0, 0), v(10, 0, 0), v(10, 0, 1) }
			for i = 9, 1, -1 do
				table.insert(comb, v(i + 0.5, 0, 1))
				table.insert(comb, v(i + 0.5, 0, 1.05))
				table.insert(comb, v(i, 0, 1.05))
				table.insert(comb, v(i, 0, 1))
			end
			table.insert(comb, v(0, 0, 1))
			local before = Internal.ObstacleRing(comb, "comb", 0)
			local after = Internal.ObstacleRing(comb, "comb", 0.1)
			expect(oneSided(before, after, true, 0.1 * 256)).is("")
		end)

		test("planar walkable rings are simplified, tilted ones on their plane; non-planar ones are not", function()
			math.randomseed(5)
			local ring = blob(0, 0, 20, 400, 0.4)
			local tilted, bumpy = {}, {}
			for i, p in ring do
				tilted[i] = v(p.X, 0.25 * p.X - 0.5 * p.Z + 3.3, p.Z)
				bumpy[i] = v(p.X, if i % 2 == 0 then 0 else 0.5, p.Z)
			end
			for _, case in { { tilted, true }, { bumpy, false } } do
				local mesh = Build.Build { SimplifyTolerance = 0.25, Floors = { G = { Walkable = { case[1] } } } }
				local _, _, _, rings = Storage.GetFloorSources(mesh, 1)
				expect(#rings[1].X < 400).is(case[2])
			end
			local mesh = Build.Build { SimplifyTolerance = 0.25, Floors = { G = { Walkable = { tilted } } } }
			for vtx = 1, Storage.VertexCount(mesh) do
				local p = Storage.GetVertex(mesh, vtx)
				-- Heights were authored off the grid: a step's rise (0.75 / 256) of slack, as Build allows.
				expect(math.abs(p.Y - (0.25 * p.X - 0.5 * p.Z + 3.3)) < 0.004)
					.with_context(`vertex ({p.X}, {p.Z}) height {p.Y}`)
					.is_true()
			end
		end)

		test("SimplifyTolerance defaults to 1/4 stud, and must be a number of studs from 0", function()
			local square = { v(0, 0, 0), v(10, 0, 0), v(10, 0, 10), v(0, 0, 10) }
			expect(Storage.GetSimplifyTolerance(NavMesh.Build { Floors = { G = { Walkable = { square } } } })).is(0.25)
			for _, bad in { -1, 0 / 0, "x", math.huge } do
				expect(function()
					NavMesh.Build { SimplifyTolerance = bad :: any, Floors = { G = { Walkable = { square } } } }
				end).fails_with("SimplifyTolerance must be a number")
			end
		end)
	end)

	-- A dense room: a noisy outline round noisy rocks and cylinders.
	local function denseRoom(seed: number): any
		math.randomseed(seed)
		local obstacles = {}
		for _ = 1, 10 do
			table.insert(
				obstacles,
				blob(8 + math.random() * 48, 8 + math.random() * 48, 1 + math.random() * 3, 40, 0.4)
			)
		end
		for _ = 1, 4 do
			table.insert(obstacles, blob(8 + math.random() * 48, 8 + math.random() * 48, 1 + math.random(), 24, 0))
		end
		return {
			MaxAgentRadius = 2,
			Floors = { Ground = { Walkable = { blob(32, 32, 34, 300, 0.5) }, Obstacles = obstacles } },
		}
	end

	local function withTolerance(desc: any, eps: number): any
		local copy = table.clone(desc)
		copy.SimplifyTolerance = eps
		return copy
	end

	describe("R1 on a dense room (G3, G4, G8)", function()
		test("the kept region is one-sided within the tolerance, and fewer triangles", function()
			local desc = denseRoom(1)
			local base, simple = NavMesh.Build(withTolerance(desc, 0)), NavMesh.Build(withTolerance(desc, 0.1))
			expect(Storage.TriangleCount(simple) < Storage.TriangleCount(base)).is_true()
			for _, mesh in { base, simple } do
				expect(table.concat(MeshChecks.Structure(mesh), "\n")).is("")
			end
			local floor = desc.Floors.Ground
			expect(MeshChecks.Region(simple, 1, floor, 1 / 128, 0.7, 0.1)[1]).is(nil)
			expect(MeshChecks.Walls(simple, 1, floor, 1 / 128, 0.1)[1]).is(nil)
		end)

		test("distance to the wall only drops, and by at most the tolerance (G3)", function()
			local desc = denseRoom(2)
			local base, simple = NavMesh.Build(withTolerance(desc, 0)), NavMesh.Build(withTolerance(desc, 0.1))
			math.randomseed(3)
			local checked = 0
			for _ = 1, 400 do
				local p = v(math.random() * 64, 0, math.random() * 64)
				local d1 = NavMesh.FindDistanceToWall(simple, p, 10)
				if d1 == 0 then
					continue -- off the simplified mesh (or under an obstacle)
				end
				local d0 = NavMesh.FindDistanceToWall(base, p, 10)
				-- Snap rounding wobbles each wall by up to half a pixel diagonal either way.
				expect(d1 <= d0 + 0.006 and d1 >= d0 - 0.1 - 0.006)
					.with_context(`({p.X}, {p.Z}): {d1} with, {d0} without`)
					.is_true()
				checked += 1
			end
			expect(checked > 200).is_true()
		end)

		test("reachability is never invented (G4)", function()
			-- With a radius the search is optimistic in places (known-gaps.md, barrier
			-- completeness), so there the independent grid flood judges reachability.
			local desc = denseRoom(3)
			local base, simple = NavMesh.Build(withTolerance(desc, 0)), NavMesh.Build(withTolerance(desc, 0.25))
			math.randomseed(4)
			local found = 0
			for _ = 1, 150 do
				local a, b = v(math.random() * 64, 0, math.random() * 64), v(math.random() * 64, 0, math.random() * 64)
				if NavMesh.FindPath(simple, a, b).Status == "Success" then
					found += 1
					expect(NavMesh.FindPath(base, a, b).Status)
						.with_context(`({a.X}, {a.Z}) to ({b.X}, {b.Z})`)
						.is("Success")
				end
			end
			expect(found > 50).is_true()
			-- At radius 0.5, on a small room (a grid flood is slow): rocks 1 to 2 studs apart.
			math.randomseed(9)
			local rocks = {}
			for i = 0, 3 do
				for j = 0, 3 do
					table.insert(rocks, blob(3 + 4.5 * i + math.random(), 3 + 4.5 * j + math.random(), 1.2, 30, 0.4))
				end
			end
			local small = { Floors = { Ground = { Walkable = { blob(10, 10, 11, 120, 0.4) }, Obstacles = rocks } } }
			local smallSimple = NavMesh.Build(withTolerance(small, 0.25))
			local floodBase = Flood.New(NavMesh.Build(withTolerance(small, 0)))
			local floodSimple = Flood.New(smallSimple)
			-- Ends that stand clear of the walls (an end in a pinch is judged by the cell it lands in,
			-- which a hair's wall shift can flip either way).
			local function clearPoint(): any
				while true do
					local p = v(math.random() * 20, 0, math.random() * 20)
					if NavMesh.FindDistanceToWall(smallSimple, p, 1) >= 0.8 then
						return p
					end
				end
			end
			local flooded = 0
			for _ = 1, 12 do
				local a, b = clearPoint(), clearPoint()
				if Flood.Connected(floodSimple, 0.5, a, b) then
					flooded += 1
					expect(Flood.Connected(floodBase, 0.5, a, b))
						.with_context(`({a.X}, {a.Z}) to ({b.X}, {b.Z}) at radius 0.5`)
						.is_true()
				end
			end
			expect(flooded > 3).with_context(`{flooded} connected`).is_true()
		end)
	end)

	-- From the Obstacles spec: triangles by grid points with their widths and wall flags.
	local function byTriangle(mesh: any): { [string]: string }
		local out = {}
		for tri = 1, Storage.TriangleCount(mesh) do
			local keys = {}
			for k, id in { Storage.GetTriangle(mesh, tri) } do
				local p = Storage.GetVertex(mesh, id)
				keys[k] = math.round(p.X * 256) * 1e7 + math.round(p.Z * 256)
			end
			local first = if keys[1] < keys[2] and keys[1] < keys[3] then 1 elseif keys[2] < keys[3] then 2 else 3
			local ids = { Storage.GetTriangle(mesh, tri) }
			local row = {}
			for i = 0, 2 do
				local k = (first + i - 1) % 3 + 1
				table.insert(
					row,
					string.format(
						"%.6f/%.6f/%s",
						Storage.GetCornerWidth(mesh, tri, k),
						Storage.GetPortalWidth(mesh, tri, k),
						if Storage.IsWallVertex(mesh, ids[k]) then "w" else "-"
					)
				)
			end
			out[`{keys[first]}:{keys[first % 3 + 1]}:{keys[(first + 1) % 3 + 1]}`] = table.concat(row, " ")
		end
		return out
	end

	local function differs(mesh: any, fresh: any): string
		if Storage.TriangleCount(mesh) ~= Storage.TriangleCount(fresh) then
			return `{Storage.TriangleCount(mesh)} triangles vs {Storage.TriangleCount(fresh)}`
		end
		local got, want = byTriangle(mesh), byTriangle(fresh)
		for key, row in want do
			if got[key] ~= row then
				return `{key}: {got[key]} vs {row}`
			end
		end
		return table.concat(MeshChecks.Structure(mesh), "\n")
	end

	local function baked(desc: any, extra: { any }): any
		local copy = table.clone(desc)
		local floor = table.clone(desc.Floors.Ground)
		floor.Obstacles = table.clone(floor.Obstacles)
		for _, ring in extra do
			table.insert(floor.Obstacles, ring)
		end
		copy.Floors = { Ground = floor }
		return copy
	end

	describe("R1 with Update and Serialize (G7)", function()
		test("adding and removing dense obstacles equals a fresh Build", function()
			for _, eps in { 0.1, 0.25 } do
				local desc = withTolerance(denseRoom(4), eps)
				local mesh = NavMesh.Build(desc)
				math.randomseed(6)
				local added = {}
				for k = 1, 4 do
					local ring = blob(10 + math.random() * 44, 10 + math.random() * 44, 1.5, 60, 0.5)
					-- Not vacuous: each dynamic obstacle loses points.
					expect(#Internal.ObstacleRing(ring, "r", eps).X < 60).is_true()
					table.insert(added, ring)
					local id = NavMesh.AddObstacle(mesh, "Ground", ring)
					NavMesh.Update(mesh)
					expect(differs(mesh, NavMesh.Build(baked(desc, added)))).with_context(`eps {eps} add {k}`).is("")
					if k == 2 then
						NavMesh.RemoveObstacle(mesh, id)
						table.remove(added)
						NavMesh.Update(mesh)
						expect(differs(mesh, NavMesh.Build(baked(desc, added))))
							.with_context(`eps {eps} remove {k}`)
							.is("")
					end
				end
			end
		end)

		test("AddObstacle after Deserialize simplifies like the live mesh", function()
			local desc = withTolerance(denseRoom(5), 0.25)
			local live = NavMesh.Build(desc)
			local loaded = NavMesh.Deserialize(NavMesh.Serialize(live))
			math.randomseed(7)
			local ring = blob(30, 30, 2, 80, 0.5)
			for _, mesh in { live, loaded } do
				NavMesh.AddObstacle(mesh, "Ground", ring)
				NavMesh.Update(mesh)
			end
			expect(differs(loaded, live)).is("")
			expect(Storage.GetSimplifyTolerance(loaded)).is(0.25)
			-- At tolerance 0 the section isn't written, and a bake without it reads as 0.
			local off = NavMesh.Deserialize(NavMesh.Serialize(NavMesh.Build(withTolerance(desc, 0))))
			expect(Storage.GetSimplifyTolerance(off)).is(0)
		end)
	end)

	describe("R1 near seams (G6)", function()
		test("a dense walkable ring keeps its edge on a seam, so the floors still join", function()
			-- Floor A: the square 0..10, its seam side x = 10 one long edge, its other sides dense
			-- and noisy. Cutting corner (10, 0) to the dense point before it would tilt that edge
			-- off the seam (0.06 studs at its middle); floor B lies beyond x = 10.
			math.randomseed(8)
			local a = { v(0, 0, 0) }
			for i = 1, 79 do
				table.insert(a, v(i / 8, 0, 0.03 * math.random()))
			end
			table.insert(a, v(10, 0, 0))
			table.insert(a, v(10, 0, 10))
			for i = 79, 1, -1 do
				table.insert(a, v(i / 8, 0, 10 - 0.03 * math.random()))
			end
			table.insert(a, v(0, 0, 10))
			local b = { v(10, 0, 0), v(20, 0, 0), v(20, 0, 10), v(10, 0, 10) }
			local desc = {
				SimplifyTolerance = 0.25,
				Floors = { A = { Walkable = { a } }, B = { Walkable = { b } } },
				Seams = { { FloorA = "A", FloorB = "B", From = v(10, 0, 0), To = v(10, 0, 10) } },
			}
			local mesh = NavMesh.Build(desc)
			local _, _, _, rings = Storage.GetFloorSources(mesh, 1)
			expect(#rings[1].X < #a).with_context(`{#rings[1].X} of {#a} points kept`).is_true()
			local path = NavMesh.FindPath(mesh, v(5, 0, 5), v(15, 0, 5))
			expect(path.Status).is("Success")
		end)
	end)

	-- A rectangle (cx, cz) half-sizes (hx, hz), turned by `turn` radians, at height y.
	local function piece(cx: number, cz: number, hx: number, hz: number, turn: number, y: number?): { any }
		local c, s = math.cos(turn), math.sin(turn)
		local out = {}
		for _, corner in { { -hx, -hz }, { hx, -hz }, { hx, hz }, { -hx, hz } } do
			table.insert(out, v(cx + corner[1] * c - corner[2] * s, y or 0, cz + corner[1] * s + corner[2] * c))
		end
		return out
	end

	-- A floor authored in overlapping pieces, with same-id areas and a few crates.
	local function piecesFloor(seed: number): any
		math.randomseed(seed)
		local walkable, areas, obstacles = {}, {}, {}
		for i = 0, 3 do
			for j = 0, 3 do
				if math.random() > 0.1 then
					table.insert(walkable, piece(8 * i + 4, 8 * j + 4, 4.3, 4.3, (math.random() - 0.5) * 0.01))
				end
			end
		end
		for _ = 1, 3 do
			local x, z = 4 + math.random() * 24, 4 + math.random() * 24
			table.insert(areas, { Polygon = piece(x, z, 3, 2, math.random()), Area = 2 })
			table.insert(areas, { Polygon = piece(x + 2, z + 1, 2, 3, math.random()), Area = 2 })
		end
		for _ = 1, 3 do
			table.insert(obstacles, piece(4 + math.random() * 24, 4 + math.random() * 24, 0.8, 0.8, math.random()))
		end
		return { TileSize = 8, Floors = { Ground = { Walkable = walkable, Areas = areas, Obstacles = obstacles } } }
	end

	-- The kept plan area per area id, and the walls as a set of grid-point pairs.
	local function regions(mesh: any): ({ [number]: number }, { [string]: boolean })
		local areas, walls = {}, {}
		for tri = 1, Storage.TriangleCount(mesh) do
			local ids = { Storage.GetTriangle(mesh, tri) }
			local p = {}
			for k, id in ids do
				p[k] = Storage.GetVertex(mesh, id)
			end
			local area = Storage.GetTriangleArea(mesh, tri)
			areas[area] = (areas[area] or 0)
				+ ((p[2].X - p[1].X) * (p[3].Z - p[1].Z) - (p[3].X - p[1].X) * (p[2].Z - p[1].Z)) / 2
			for e = 1, 3 do
				if Storage.IsWallEdge(mesh, tri, e) then
					local a, b = p[e % 3 + 1], p[(e + 1) % 3 + 1]
					walls[`{math.round(a.X * 256)},{math.round(a.Z * 256)}>{math.round(b.X * 256)},{math.round(
						b.Z * 256
					)}`] =
						true
				end
			end
		end
		return areas, walls
	end

	local function withDissolve(on: boolean, f: () -> any): any
		Internal.Dissolve.Enabled = on
		local ok, result = pcall(f)
		Internal.Dissolve.Enabled = true
		if not ok then
			error(result, 0)
		end
		return result
	end

	describe("R2: exact dissolve of same-class edges (G5, G6, G7, G8)", function()
		test("overlapping pieces: the same areas, walls and wall distances, in fewer triangles", function()
			for seed = 1, 6 do
				local desc = piecesFloor(seed)
				local off = withDissolve(false, function()
					return NavMesh.Build(desc)
				end)
				local on = NavMesh.Build(desc)
				expect(table.concat(MeshChecks.Structure(on), "\n")).is("")
				expect(Storage.TriangleCount(on) < Storage.TriangleCount(off))
					.with_context(`seed {seed}: {Storage.TriangleCount(on)} vs {Storage.TriangleCount(off)}`)
					.is_true()
				local areasOff, wallsOff = regions(off)
				local areasOn, wallsOn = regions(on)
				for area, size in areasOff do
					expect(math.abs((areasOn[area] or 0) - size) < 1e-6)
						.with_context(`seed {seed} area {area}: {areasOn[area]} vs {size}`)
						.is_true()
				end
				for key in wallsOff do
					expect(wallsOn[key]).with_context(`seed {seed} wall {key}`).is(true)
				end
				for key in wallsOn do
					expect(wallsOff[key]).with_context(`seed {seed} wall {key}`).is(true)
				end
				for _ = 1, 40 do
					local p = v(math.random() * 32, 0, math.random() * 32)
					expect(NavMesh.FindDistanceToWall(on, p, 4)).is(NavMesh.FindDistanceToWall(off, p, 4))
				end
			end
		end)

		test("adding and removing a crate across dissolved strips and tile lines equals a fresh Build", function()
			local desc = piecesFloor(7)
			local mesh = NavMesh.Build(desc)
			for _, crate in { piece(8, 8, 1.5, 1.5, 0.3), piece(16.2, 11, 2.5, 1, 0.1) } do
				local id = NavMesh.AddObstacle(mesh, "Ground", crate)
				NavMesh.Update(mesh)
				expect(differs(mesh, NavMesh.Build(baked(desc, { crate })))).with_context("added").is("")
				NavMesh.RemoveObstacle(mesh, id)
				NavMesh.Update(mesh)
				expect(differs(mesh, NavMesh.Build(desc))).with_context("removed").is("")
			end
		end)

		test("coplanar pieces dissolve, but never across a change of plane", function()
			-- Flat piece B starts inside flat piece A (its corners at x = 6 dissolve); ramp C meets B
			-- along x = 20 and rises to y = 2.
			local ramp = { v(20, 0, 2), v(30, 2, 2), v(30, 2, 8), v(20, 0, 8) }
			local desc = {
				TileSize = 32,
				Floors = { Ground = { Walkable = { piece(5, 5, 5, 5, 0), piece(13, 5, 7, 3, 0), ramp } } },
			}
			local off = withDissolve(false, function()
				return NavMesh.Build(desc)
			end)
			local on = NavMesh.Build(desc)
			expect(Storage.TriangleCount(on) < Storage.TriangleCount(off)).is_true()
			for vtx = 1, Storage.VertexCount(on) do
				local p = Storage.GetVertex(on, vtx)
				local want = if p.X <= 20 then 0 else 0.2 * (p.X - 20)
				expect(math.abs(p.Y - want) < 1e-4).with_context(`vertex ({p.X}, {p.Z}) height {p.Y}`).is_true()
			end
		end)
	end)
end
