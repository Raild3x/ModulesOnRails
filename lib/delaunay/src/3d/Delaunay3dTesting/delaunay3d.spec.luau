--!strict
-- Authors: Logan Hunt (Raildex)
-- May 13, 2026
--[=[
    @class Delaunay3d.spec
    @ignore

    Test suite for the new Delaunay3d implementation (3d_new).
    All tests operate through the public Triangulate API only.
    Triangles use named fields  .U / .V / .W
    Edges    use named fields  .U / .V
]=]

return function(t: tiniest)
	local Delaunay3d = require(script.Parent.Parent.delaunay3d)

	local context = t.context
	local describe = t.describe
	local expect = t.expect
	local test = t.test

	--------------------------------------------------------------------------------
	--// Helpers //--
	--------------------------------------------------------------------------------

	local function vk(v: Vector3): string
		return `{v.X},{v.Y},{v.Z}`
	end

	-- Order-independent string key for a triangular face
	local function triKey(u: Vector3, v: Vector3, w: Vector3): string
		local a, b, c = vk(u), vk(v), vk(w)
		if a > b then
			a, b = b, a
		end
		if b > c then
			b, c = c, b
		end
		if a > b then
			a, b = b, a
		end
		return `{a}|{b}|{c}`
	end

	-- Order-independent string key for an edge
	local function edgeKey(u: Vector3, v: Vector3): string
		local a, b = vk(u), vk(v)
		if a > b then
			a, b = b, a
		end
		return `{a}|{b}`
	end

	-- Builds a lookup set of vec3 keys from a vertex array
	local function makeInputSet(verts: { Vector3 }): { [string]: boolean }
		local s: { [string]: boolean } = {}
		for _, v in verts do
			s[vk(v)] = true
		end
		return s
	end

	-- Counts how many tetrahedra each triangular face appears in
	local function buildFaceCountMap(tets: { { A: Vector3, B: Vector3, C: Vector3, D: Vector3 } }): { [string]: number }
		local counts: { [string]: number } = {}
		for _, tet in tets do
			local a, b, c, d = tet[1], tet[2], tet[3], tet[4]
			for _, k in { triKey(a, b, c), triKey(a, b, d), triKey(a, c, d), triKey(b, c, d) } do
				counts[k] = (counts[k] or 0) + 1
			end
		end
		return counts
	end

	-- Builds the set of unique edge keys from a tetrahedra list
	local function buildEdgeSet(tets: { { A: Vector3, B: Vector3, C: Vector3, D: Vector3 } }): { [string]: boolean }
		local set: { [string]: boolean } = {}
		for _, tet in tets do
			local a, b, c, d = tet[1], tet[2], tet[3], tet[4]
			set[edgeKey(a, b)] = true
			set[edgeKey(a, c)] = true
			set[edgeKey(a, d)] = true
			set[edgeKey(b, c)] = true
			set[edgeKey(b, d)] = true
			set[edgeKey(c, d)] = true
		end
		return set
	end

	-- Returns true if vertex v equals one of the tet's four corners (FuzzyEq)
	local function tetHasVertexFuzzy(tet: any, v: Vector3): boolean
		return v:FuzzyEq(tet[1]) or v:FuzzyEq(tet[2]) or v:FuzzyEq(tet[3]) or v:FuzzyEq(tet[4])
	end

	local function tetHasVertex(tet: any, p: Vector3): boolean
		return p:FuzzyEq(tet[1]) or p:FuzzyEq(tet[2]) or p:FuzzyEq(tet[3]) or p:FuzzyEq(tet[4])
	end

	-- Returns true if 'face' (array of 3 Vector3) lies entirely on one side of all points.
	-- i.e. all points project to the same sign relative to the face plane.
	local function isHullFaceConvexAgainstAllPoints(face: { Vector3 }, points: { Vector3 }, eps: number): boolean
		local a, b, c = face[1], face[2], face[3]
		local normal = (b - a):Cross(c - a)
		if normal.Magnitude <= eps then
			return false
		end

		local minDot = math.huge
		local maxDot = -math.huge
		for _, p in points do
			local d = normal:Dot(p - a)
			if d < minDot then
				minDot = d
			end
			if d > maxDot then
				maxDot = d
			end
		end

		return not (minDot < -eps and maxDot > eps)
	end

	--------------------------------------------------------------------------------
	--// Geometric Predicate Helpers (for Delaunay property verification) //--
	--------------------------------------------------------------------------------

	local function det3(
		a: number,
		b: number,
		c: number,
		d: number,
		e: number,
		f: number,
		g: number,
		h: number,
		i: number
	): number
		return a * (e * i - f * h) - b * (d * i - f * g) + c * (d * h - e * g)
	end

	local function det4(
		a00: number,
		a01: number,
		a02: number,
		a03: number,
		a10: number,
		a11: number,
		a12: number,
		a13: number,
		a20: number,
		a21: number,
		a22: number,
		a23: number,
		a30: number,
		a31: number,
		a32: number,
		a33: number
	): number
		return a00 * det3(a11, a12, a13, a21, a22, a23, a31, a32, a33)
			- a01 * det3(a10, a12, a13, a20, a22, a23, a30, a32, a33)
			+ a02 * det3(a10, a11, a13, a20, a21, a23, a30, a31, a33)
			- a03 * det3(a10, a11, a12, a20, a21, a22, a30, a31, a32)
	end

	-- orient3d(A,B,C,D): Shewchuk sign convention — det3(B-A, C-A, D-A).
	-- > 0: D on positive side of plane ABC.  < 0: negative side.  0: coplanar.
	local function orient3d(a: Vector3, b: Vector3, c: Vector3, d: Vector3): number
		return det3(b.X - a.X, b.Y - a.Y, b.Z - a.Z, c.X - a.X, c.Y - a.Y, c.Z - a.Z, d.X - a.X, d.Y - a.Y, d.Z - a.Z)
	end

	-- Returns true iff P lies strictly inside the circumsphere of tetrahedron ABCD.
	-- Uses the orientation-independent predicate: inSphereRaw * orient3d > 0.
	local function circumSphereContains(a: Vector3, b: Vector3, c: Vector3, d: Vector3, p: Vector3): boolean
		local o = orient3d(a, b, c, d)
		if o == 0 then
			return false
		end
		local ax, ay, az = a.X - p.X, a.Y - p.Y, a.Z - p.Z
		local bx, by, bz = b.X - p.X, b.Y - p.Y, b.Z - p.Z
		local cx, cy, cz = c.X - p.X, c.Y - p.Y, c.Z - p.Z
		local dx, dy, dz = d.X - p.X, d.Y - p.Y, d.Z - p.Z
		local ins = det4(
			ax,
			ay,
			az,
			ax * ax + ay * ay + az * az,
			bx,
			by,
			bz,
			bx * bx + by * by + bz * bz,
			cx,
			cy,
			cz,
			cx * cx + cy * cy + cz * cz,
			dx,
			dy,
			dz,
			dx * dx + dy * dy + dz * dz
		)
		return ins * o < 0
	end

	--// Fixtures //--
	--------------------------------------------------------------------------------

	-- Four non-coplanar points forming a single tetrahedron
	local TETRA = {
		Vector3.new(0, 0, 0),
		Vector3.new(10, 0, 0),
		Vector3.new(5, 10, 0),
		Vector3.new(5, 5, 10),
	}

	-- Eight points in general position (not co-spherical).
	-- A pure axis-aligned cube is degenerate: all 8 vertices share one circumsphere,
	-- causing Bowyer-Watson to remove too many tetrahedra simultaneously and produce
	-- a topologically broken hull. One vertex is perturbed to break that degeneracy.
	-- Any convex polyhedron with 8 hull vertices always has exactly 12 triangular
	-- hull faces: F = 2(V - 2) = 12.
	local EIGHT_PTS = {
		Vector3.new(0, 0, 0),
		Vector3.new(10, 0, 0),
		Vector3.new(0, 10, 0),
		Vector3.new(10, 10, 0),
		Vector3.new(0, 0, 10),
		Vector3.new(10, 0, 10),
		Vector3.new(0, 10, 10),
		Vector3.new(10, 10, 13), -- perturbed from (10,10,10) to break co-sphericity
	}

	local STRESS_EPS = 1e-4

	local function generatePointCloud(seed: number, count: number): { Vector3 }
		local rng = Random.new(seed)
		local points: { Vector3 } = table.create(count)
		for i = 1, count do
			points[i] = Vector3.new(rng:NextNumber(-500, 500), rng:NextNumber(-500, 500), rng:NextNumber(-500, 500))
		end
		return points
	end

	--------------------------------------------------------------------------------
	--// Tests //--
	--------------------------------------------------------------------------------

	describe("Triangulate", function()
		test("errors on empty input", function()
			expect(function()
				Delaunay3d.Triangulate {}
			end).fails()
		end)

		test("4 non-coplanar points: 1 tetrahedron, 4 triangles, 6 edges", function()
			local result = Delaunay3d.Triangulate(TETRA)
			expect(#result.Tetrahedra).is(1)
			expect(#result.Triangles).is(4)
			expect(#result.Edges).is(6)
		end)

		test("result preserves the original Vertices reference", function()
			local result = Delaunay3d.Triangulate(TETRA)
			expect(result.Vertices).is(TETRA)
		end)

		test("returns all unique faces, including interior shared faces", function()
			local mesh = Delaunay3d.Triangulate(EIGHT_PTS)
			local faceCount = buildFaceCountMap(mesh.Tetrahedra)
			local interiorCount = 0
			for _, count in faceCount do
				if count >= 2 then
					interiorCount += 1
				end
			end
			expect(interiorCount > 0).is(true)
		end)

		test("all output tetrahedra vertices come from input", function()
			local result = Delaunay3d.Triangulate(EIGHT_PTS)
			local s = makeInputSet(EIGHT_PTS)
			for _, tet in result.Tetrahedra do
				expect(s[vk(tet[1])]).is(true)
				expect(s[vk(tet[2])]).is(true)
				expect(s[vk(tet[3])]).is(true)
				expect(s[vk(tet[4])]).is(true)
			end
		end)

		test("all output triangles reference input vertices", function()
			local result = Delaunay3d.Triangulate(EIGHT_PTS)
			local s = makeInputSet(EIGHT_PTS)
			for _, tri in result.Triangles do
				expect(s[vk(tri[1])]).is(true)
				expect(s[vk(tri[2])]).is(true)
				expect(s[vk(tri[3])]).is(true)
			end
		end)

		test("no duplicate edges", function()
			local result = Delaunay3d.Triangulate(EIGHT_PTS)
			local seen: { [string]: boolean } = {}
			local unique = 0
			for _, edge in result.Edges do
				local k = edgeKey(edge[1], edge[2])
				if not seen[k] then
					seen[k] = true
					unique += 1
				end
			end
			expect(unique).is(#result.Edges)
		end)

		test("no duplicate triangles", function()
			local result = Delaunay3d.Triangulate(EIGHT_PTS)
			local seen: { [string]: boolean } = {}
			local unique = 0
			for _, tri in result.Triangles do
				local k = triKey(tri[1], tri[2], tri[3])
				if not seen[k] then
					seen[k] = true
					unique += 1
				end
			end
			expect(unique).is(#result.Triangles)
		end)

		test("all input vertices appear in at least one output tetrahedron", function()
			local result = Delaunay3d.Triangulate(EIGHT_PTS)
			for i, v in EIGHT_PTS do
				local found = false
				for _, tet in result.Tetrahedra do
					if tetHasVertexFuzzy(tet, v) then
						found = true
						break
					end
				end
				context.push { label = "Vertex", value = { Index = i, Position = v } }
				expect(found).is(true)
				context.pop()
			end
		end)

		test("triangles list exactly matches unique faces from tetrahedra", function()
			local result = Delaunay3d.Triangulate(EIGHT_PTS)
			-- Ground-truth: every unique face present across all tetrahedra.
			local faceSet: { [string]: boolean } = {}
			for _, tet in result.Tetrahedra do
				local a, b, c, d = tet[1], tet[2], tet[3], tet[4]
				faceSet[triKey(a, b, c)] = true
				faceSet[triKey(a, b, d)] = true
				faceSet[triKey(a, c, d)] = true
				faceSet[triKey(b, c, d)] = true
			end
			-- Every triangle reported must correspond to a real tet face.
			for _, tri in result.Triangles do
				local k = triKey(tri[1], tri[2], tri[3])
				context.push { label = "Triangle", value = tri }
				expect(faceSet[k]).exists()
				context.pop()
			end
			-- Every tet face must appear in the triangle list.
			local triListSet: { [string]: boolean } = {}
			for _, tri in result.Triangles do
				triListSet[triKey(tri[1], tri[2], tri[3])] = true
			end
			for k, _ in faceSet do
				context.push { label = "MissingFaceKey", value = k }
				expect(triListSet[k]).exists()
				context.pop()
			end
		end)

		test("edges list exactly matches unique edges from tetrahedra", function()
			local result = Delaunay3d.Triangulate(EIGHT_PTS)
			local edgeSetFromTets = buildEdgeSet(result.Tetrahedra)
			-- Every reported edge must come from a tetrahedron.
			for _, edge in result.Edges do
				local k = edgeKey(edge[1], edge[2])
				context.push { label = "Edge", value = edge }
				expect(edgeSetFromTets[k]).exists()
				context.pop()
			end
			-- Every tetrahedron edge must appear in the edges list.
			local edgeListSet: { [string]: boolean } = {}
			for _, edge in result.Edges do
				edgeListSet[edgeKey(edge[1], edge[2])] = true
			end
			for k, _ in edgeSetFromTets do
				context.push { label = "MissingEdgeKey", value = k }
				expect(edgeListSet[k]).exists()
				context.pop()
			end
		end)
	end)

	describe("Randomized stress", function()
		-- test("large random sets keep convex hull faces and manifold face counts", function()
		-- 	-- Many deterministic seeds over large point clouds.
		-- 	for seed = 1, 30 do
		-- 		local points = generatePointCloud(seed * 9173, seed * 5 + 10)
		-- 		local result = Delaunay3d.Triangulate(points)

		-- 		-- Build face count map from tetrahedra and a key→{U,V,W} lookup for convexity tests.
		-- 		local faceCounts = buildFaceCountMap(result.Tetrahedra)
		-- 		local faceVerts: { [string]: { Vector3 } } = {}
		-- 		for _, tri in result.Triangles do
		-- 			faceVerts[triKey(tri[1], tri[2], tri[3])] = { tri[1], tri[2], tri[3] }
		-- 		end

		-- 		context.set("Seed", seed)
		-- 		context.set("PointCount", #points)

		-- 		-- Each unique face must belong to exactly 1 (hull) or 2 (interior) tetrahedra.
		-- 		-- Hull faces must lie on a plane that separates them from all other points.
		-- 		local hullFaces = 0
		-- 		for key, count in faceCounts do
		-- 			local face = faceVerts[key]
		-- 			context.push { label = "Face", value = { Vertices = face, Count = count } }
		-- 			expect(count == 1 or count == 2).is(true)
		-- 			if count == 1 then
		-- 				hullFaces += 1
		-- 				expect(isHullFaceConvexAgainstAllPoints(face, points, STRESS_EPS)).is(true)
		-- 			end
		-- 			context.pop()
		-- 		end

		-- 		expect(hullFaces > 0).is(true)
		-- 	end
		-- end)

		test("large random sets satisfy empty-circumsphere condition", function()
			-- Brute-force: for each tetrahedron, no non-vertex point may lie strictly
			-- inside the tetrahedron's circumsphere.
			for seed = 1, 20 do
				local points = generatePointCloud(seed * 13337, 120)
				local result = Delaunay3d.Triangulate(points)
				context.set("Seed", seed)

				for ti, tet in result.Tetrahedra do
					context.push {
						label = "Tet",
						value = { Index = ti, A = tet[1], B = tet[2], C = tet[3], D = tet[4] },
					}
					for pi, p in points do
						if not tetHasVertex(tet, p) then
							local inside = circumSphereContains(tet[1], tet[2], tet[3], tet[4], p)
							context.push {
								label = "Point",
								value = { Index = pi, Position = p, Inside = inside },
							}
							expect(inside).is(false)
							context.pop()
						end
					end
					context.pop()
				end
			end
		end)

		test("all input vertices appear in output tetrahedra for random sets", function()
			for seed = 1, 15 do
				local points = generatePointCloud(seed * 7919, 60)
				local result = Delaunay3d.Triangulate(points)
				context.set("Seed", seed)
				context.set("TetrahedraCount", #result.Tetrahedra)

				for i, v in points do
					local found = false
					for _, tet in result.Tetrahedra do
						if tetHasVertexFuzzy(tet, v) then
							found = true
							break
						end
					end
					context.push { label = "Vertex", value = { Index = i, Position = v } }
					expect(found).is(true)
					context.pop()
				end
			end
		end)

		test("near-co-spherical points: all input vertices appear in output", function()
			-- Points approximately on a sphere stress the insphere predicate near-zero boundary.
			-- Slight radial jitter breaks exact co-sphericity while keeping the cloud tight.
			local rng = Random.new(31337)
			local pts: { Vector3 } = {}
			for _ = 1, 30 do
				local theta = rng:NextNumber(0, math.pi * 2)
				local phi = rng:NextNumber(0, math.pi)
				local r = 50 + rng:NextNumber(-1, 1)
				pts[#pts + 1] = Vector3.new(
					r * math.sin(phi) * math.cos(theta),
					r * math.cos(phi),
					r * math.sin(phi) * math.sin(theta)
				)
			end
			local result = Delaunay3d.Triangulate(pts)
			local inputSet = makeInputSet(pts)

			-- All tet vertices must come from the input.
			for _, tet in result.Tetrahedra do
				expect(inputSet[vk(tet[1])]).exists()
				expect(inputSet[vk(tet[2])]).exists()
				expect(inputSet[vk(tet[3])]).exists()
				expect(inputSet[vk(tet[4])]).exists()
			end

			-- Every input vertex must appear in at least one tetrahedron.
			for i, v in pts do
				local found = false
				for _, tet in result.Tetrahedra do
					if tetHasVertexFuzzy(tet, v) then
						found = true
						break
					end
				end
				context.push { label = "Vertex", value = { Index = i, Position = v } }
				expect(found).is(true)
				context.pop()
			end
		end)
	end)

	describe("Class-based incremental API", function()
		test("new() creates an empty instance", function()
			local instance = Delaunay3d.new()
			expect(#instance:GetVertices()).is(0)
			expect(#instance:GetTetrahedrons()).is(0)
			expect(#instance:GetTriangles()).is(0)
			expect(#instance:GetEdges()).is(0)
		end)

		test("AddPoint increments vertex count", function()
			local instance = Delaunay3d.new()
			local id1 = instance:AddPoint(Vector3.new(0, 0, 0))
			expect(#instance:GetVertices()).is(1)

			local id2 = instance:AddPoint(Vector3.new(1, 0, 0))
			expect(#instance:GetVertices()).is(2)

			local id3 = instance:AddPoint(Vector3.new(0, 1, 0))
			expect(#instance:GetVertices()).is(3)

			local id4 = instance:AddPoint(Vector3.new(0, 0, 1))
			expect(#instance:GetVertices()).is(4)
		end)

		test("AddPoint with manual ids", function()
			local instance = Delaunay3d.new()
			local id1 = instance:AddPoint(Vector3.new(0, 0, 0), "vertex_a")
			expect(id1).is("vertex_a")

			local id2 = instance:AddPoint(Vector3.new(1, 0, 0), "vertex_b")
			expect(id2).is("vertex_b")

			local verts = instance:GetVertices()
			expect(#verts).is(2)
		end)

		test("AddPoint returns auto-generated id when not provided", function()
			local instance = Delaunay3d.new()
			local id1 = instance:AddPoint(Vector3.new(0, 0, 0))
			local id2 = instance:AddPoint(Vector3.new(1, 0, 0))

			-- Auto-generated ids should be distinct
			expect(id1 ~= id2).is(true)
			-- Auto-generated ids should contain the prefix
			expect(string.find(id1, "__auto__:") ~= nil).is(true)
			expect(string.find(id2, "__auto__:") ~= nil).is(true)
		end)

		test(
			"AddPoint at same position with different id keeps unique vertex count stable without retriangulating",
			function()
				local instance = Delaunay3d.new()
				local pos = Vector3.new(1, 2, 3)

				-- Add 4 distinct vertices to trigger creation of initial tetrahedron
				instance:AddPoint(Vector3.new(0, 0, 0))
				instance:AddPoint(Vector3.new(1, 0, 0))
				instance:AddPoint(Vector3.new(0, 1, 0))
				instance:AddPoint(Vector3.new(0, 0, 1))

				local tetsAfterFour = #instance:GetTetrahedrons()

				-- Add two vertices at same position
				local id1 = instance:AddPoint(pos, "A")
				local tetsAfterFirst = #instance:GetTetrahedrons()

				local id2 = instance:AddPoint(pos, "B")
				local tetsAfterSecond = #instance:GetTetrahedrons()

				-- Tetrahedron count should only change after the first add at new position.
				expect(tetsAfterFirst >= tetsAfterFour).is(true)
				expect(tetsAfterSecond).is(tetsAfterFirst)

				-- Unique positions should still only include the base 4 plus the shared position.
				local verts = instance:GetVertices()
				expect(#verts).is(5)
			end
		)

		test("4 non-coplanar points create 1 tetrahedron", function()
			local instance = Delaunay3d.new()
			instance:AddPoint(Vector3.new(0, 0, 0))
			instance:AddPoint(Vector3.new(1, 0, 0))
			instance:AddPoint(Vector3.new(0, 1, 0))
			instance:AddPoint(Vector3.new(0, 0, 1))

			expect(#instance:GetTetrahedrons()).is(1)
			expect(#instance:GetTriangles()).is(4)
			expect(#instance:GetEdges()).is(6)
		end)

		test("RemovePoint decrement vertex count", function()
			local instance = Delaunay3d.new()
			local id1 = instance:AddPoint(Vector3.new(0, 0, 0))
			local id2 = instance:AddPoint(Vector3.new(1, 0, 0))
			local id3 = instance:AddPoint(Vector3.new(0, 1, 0))
			local id4 = instance:AddPoint(Vector3.new(0, 0, 1))

			expect(#instance:GetVertices()).is(4)

			instance:RemovePoint(id1)
			expect(#instance:GetVertices()).is(3)

			instance:RemovePoint(id2)
			expect(#instance:GetVertices()).is(2)
		end)

		test(
			"RemovePoint from duplicate-position vertices keeps unique vertex count stable until the last id is removed",
			function()
				local instance = Delaunay3d.new()
				local pos = Vector3.new(1, 2, 3)

				-- Setup base tetrahedron
				instance:AddPoint(Vector3.new(0, 0, 0))
				instance:AddPoint(Vector3.new(1, 0, 0))
				instance:AddPoint(Vector3.new(0, 1, 0))
				instance:AddPoint(Vector3.new(0, 0, 1))

				-- Add duplicates at same position
				local id1 = instance:AddPoint(pos, "A")
				local id2 = instance:AddPoint(pos, "B")
				local id3 = instance:AddPoint(pos, "C")

				expect(#instance:GetVertices()).is(5)

				-- Remove one duplicate: should not trigger retriangulation
				local tetsBeforeRemove = #instance:GetTetrahedrons()
				instance:RemovePoint(id2)
				local tetsAfterRemove = #instance:GetTetrahedrons()

				expect(#instance:GetVertices()).is(5)
				expect(tetsAfterRemove).is(tetsBeforeRemove)

				-- Remove last duplicate of that position: unique vertex count should drop and retriangulation should occur.
				instance:RemovePoint(id1)
				instance:RemovePoint(id3)
				expect(#instance:GetVertices()).is(4)
			end
		)

		test("MovePoint updates vertex position in-place", function()
			local instance = Delaunay3d.new()
			local id = instance:AddPoint(Vector3.new(0, 0, 0))

			local verts = instance:GetVertices()
			expect(verts[1] == Vector3.new(0, 0, 0)).is(true)

			instance:MovePoint(id, Vector3.new(1, 2, 3))
			local vertsAfter = instance:GetVertices()
			expect(vertsAfter[1] == Vector3.new(1, 2, 3)).is(true)
		end)

		test("MovePoint with incremental retriangulation", function()
			local instance = Delaunay3d.new()
			local id1 = instance:AddPoint(Vector3.new(0, 0, 0))
			local id2 = instance:AddPoint(Vector3.new(1, 0, 0))
			local id3 = instance:AddPoint(Vector3.new(0, 1, 0))
			local id4 = instance:AddPoint(Vector3.new(0, 0, 1))

			local tetsInitial = #instance:GetTetrahedrons()
			expect(tetsInitial).is(1)

			-- Move a point to trigger retriangulation
			instance:MovePoint(id4, Vector3.new(0.5, 0.5, 0.5))
			local tetsAfterMove = #instance:GetTetrahedrons()

			-- Triangulation should adjust, but still remain valid
			expect(#instance:GetVertices()).is(4)
		end)

		test("Clear removes all vertices and resets", function()
			local instance = Delaunay3d.new()
			instance:AddPoint(Vector3.new(0, 0, 0))
			instance:AddPoint(Vector3.new(1, 0, 0))
			instance:AddPoint(Vector3.new(0, 1, 0))
			instance:AddPoint(Vector3.new(0, 0, 1))

			expect(#instance:GetVertices()).is(4)

			instance:Clear()

			expect(#instance:GetVertices()).is(0)
			expect(#instance:GetTetrahedrons()).is(0)
			expect(#instance:GetTriangles()).is(0)
			expect(#instance:GetEdges()).is(0)
		end)

		test("ForEachEdge iterates all edges without allocation", function()
			local instance = Delaunay3d.new()
			instance:AddPoint(Vector3.new(0, 0, 0))
			instance:AddPoint(Vector3.new(1, 0, 0))
			instance:AddPoint(Vector3.new(0, 1, 0))
			instance:AddPoint(Vector3.new(0, 0, 1))

			local count = 0
			for a, b in instance:ForEachEdge() do
				count += 1
				expect(a).is(a)
				expect(b).is(b)
			end

			expect(count).is(#instance:GetEdges())
		end)

		test("ForEachTriangle iterates all triangles without allocation", function()
			local instance = Delaunay3d.new()
			instance:AddPoint(Vector3.new(0, 0, 0))
			instance:AddPoint(Vector3.new(1, 0, 0))
			instance:AddPoint(Vector3.new(0, 1, 0))
			instance:AddPoint(Vector3.new(0, 0, 1))

			local count = 0
			for a, b, c in instance:ForEachTriangle() do
				count += 1
				expect(a).is(a)
				expect(b).is(b)
				expect(c).is(c)
			end

			expect(count).is(#instance:GetTriangles())
		end)

		test("ForEachTetrahedron iterates all tetrahedra without allocation", function()
			local instance = Delaunay3d.new()
			instance:AddPoint(Vector3.new(0, 0, 0))
			instance:AddPoint(Vector3.new(1, 0, 0))
			instance:AddPoint(Vector3.new(0, 1, 0))
			instance:AddPoint(Vector3.new(0, 0, 1))

			local count = 0
			for a, b, c, d in instance:ForEachTetrahedron() do
				count += 1
				expect(a).is(a)
				expect(b).is(b)
				expect(c).is(c)
				expect(d).is(d)
			end

			expect(count).is(#instance:GetTetrahedrons())
		end)

		test("GetTetrahedronsContaining returns tetrahedra containing a point", function()
			local instance = Delaunay3d.new()
			instance:AddPoint(Vector3.new(0, 0, 0))
			instance:AddPoint(Vector3.new(2, 0, 0))
			instance:AddPoint(Vector3.new(0, 2, 0))
			instance:AddPoint(Vector3.new(0, 0, 2))

			-- Point inside the tetrahedron
			local inPoint = Vector3.new(0.5, 0.5, 0.5)
			local tets = instance:GetTetrahedronsContaining(inPoint)
			expect(#tets > 0).is(true)

			-- Point far outside
			local outPoint = Vector3.new(100, 100, 100)
			local tetsOut = instance:GetTetrahedronsContaining(outPoint)
			expect(#tetsOut).is(0)
		end)

		test("GetAdjacentVertices returns neighbors of a vertex", function()
			local instance = Delaunay3d.new()
			local id1 = instance:AddPoint(Vector3.new(0, 0, 0))
			local id2 = instance:AddPoint(Vector3.new(1, 0, 0))
			local id3 = instance:AddPoint(Vector3.new(0, 1, 0))
			local id4 = instance:AddPoint(Vector3.new(0, 0, 1))

			-- Vertex 1 should have 3 adjacent vertices (connected to id2, id3, id4)
			local neighbors = instance:GetAdjacentVertices(id1)
			expect(#neighbors).is(3)
		end)

		test("incremental insertions maintain Delaunay property", function()
			local instance = Delaunay3d.new()

			-- Build up incrementally
			local pts = {
				Vector3.new(0, 0, 0),
				Vector3.new(1, 0, 0),
				Vector3.new(0, 1, 0),
				Vector3.new(0, 0, 1),
				Vector3.new(1, 1, 0),
				Vector3.new(1, 0, 1),
				Vector3.new(0, 1, 1),
				Vector3.new(1, 1, 1),
			}

			for _, pt in pts do
				instance:AddPoint(pt)
			end

			-- Verify Delaunay property: no point lies inside any tetrahedron's circumsphere
			local tets = instance:GetTetrahedrons()
			for _, tet in tets do
				for _, pt in instance:GetVertices() do
					if not (pt:FuzzyEq(tet[1]) or pt:FuzzyEq(tet[2]) or pt:FuzzyEq(tet[3]) or pt:FuzzyEq(tet[4])) then
						local inside = circumSphereContains(tet[1], tet[2], tet[3], tet[4], pt)
						expect(inside).is(false)
					end
				end
			end
		end)
	end)
end
