-- Authors: Logan Hunt (Raildex)
-- September 25, 2026
-- Test layer 1: constraint edges through the public API + the invariant checker (incl. (b)).

return function(t: tiniest)
	local CDT = require("../ConstrainedDelaunay")
	local Invariants = require("./Helpers/Invariants")

	local describe = t.describe
	local expect = t.expect
	local test = t.test
	local snapshot = t.snapshot

	local function makeRng(seed: number): (number, number) -> number
		local state = seed
		return function(lo: number, hi: number): number
			state = (state * 1103515245 + 12345) % 2147483648
			return lo + (state / 2147483648) * (hi - lo)
		end
	end

	local function checked(input: CDT.TriangulateInput, label: string): CDT.Triangulation
		local tri = CDT.Triangulate(input)
		local ok, reason = Invariants.Check(tri, input.Coords, input.Edges)
		expect(ok).with_context(`{label}: {reason}`).is_true()
		return tri
	end

	local function steinerCount(tri: CDT.Triangulation): number
		local count = 0
		for v = 1, CDT.VertexCount(tri) do
			if CDT.InputVertexOf(tri, v) == nil then
				count += 1
			end
		end
		return count
	end

	-- Every edge of the triangulation covered by `id`, as a count.
	local function coveredEdges(tri: CDT.Triangulation, id: number): number
		local count = 0
		for tt = 1, CDT.TriangleCount(tri) do
			for e = 1, 3 do
				for k = 1, CDT.GetCoveringEdgeCount(tri, tt, e) do
					if CDT.GetCoveringEdge(tri, tt, e, k) == id then
						count += 1
					end
				end
			end
		end
		return count
	end

	describe("constraints", function()
		test("every fixture with its rings as constraints", function()
			for _, scenario in CDT.Fixtures.All do
				checked(CDT.Fixtures.ToInput(scenario), scenario.Name)
			end
		end)

		test("a constraint that is not Delaunay is forced in", function()
			-- A thin rhombus: Delaunay picks the short diagonal (2-4); constrain the long one (1-3).
			local input = { Coords = { 0, 0, 10, 1, 20, 0, 10, -1 }, Edges = { 1, 3 } }
			local tri = checked(input, "long diagonal")
			expect(coveredEdges(tri, 1)).is(2) -- one edge, seen from both sides
		end)

		test("crossing constraints meet at a Steiner vertex", function()
			local input = { Coords = { 0, 0, 10, 10, 0, 10, 10, 0 }, Edges = { 1, 2, 3, 4 } }
			local tri = checked(input, "X")
			expect(steinerCount(tri)).is(1)
			local steiner = CDT.VertexCount(tri)
			local x, y = CDT.GetVertex(tri, steiner)
			expect(x).is(5)
			expect(y).is(5)
		end)

		test("a constraint through collinear vertices covers each sub-edge", function()
			local input = { Coords = { 0, 0, 3, 0, 6, 0, 9, 0, 4, 5, 4, -5 }, Edges = { 1, 4 } }
			local tri = checked(input, "collinear")
			expect(coveredEdges(tri, 1)).is(6) -- 3 sub-edges x 2 sides
			expect(steinerCount(tri)).is(0)
		end)

		test("overlapping collinear constraints share covered edges", function()
			local input = { Coords = { 0, 0, 4, 0, 8, 0, 12, 0, 6, 4, 6, -4 }, Edges = { 1, 3, 2, 4 } }
			local tri = checked(input, "overlap")
			-- Edge 2-3 (x 4..8) is covered by both constraints.
			local both = 0
			for tt = 1, CDT.TriangleCount(tri) do
				for e = 1, 3 do
					if CDT.GetCoveringEdgeCount(tri, tt, e) == 2 then
						both += 1
					end
				end
			end
			expect(both).is(2)
		end)

		test("duplicate and zero-length constraints", function()
			local input = { Coords = { 0, 0, 5, 0, 0, 5, 5, 5, 0, 0 }, Edges = { 1, 4, 4, 1, 1, 5 } }
			local tri = checked(input, "duplicates")
			expect(coveredEdges(tri, 1) + coveredEdges(tri, 2)).is(4)
			expect(coveredEdges(tri, 3)).is(0) -- 1 and 5 are the same point
		end)

		test("constraints crossing several existing constraints (a grid of bars)", function()
			local coords, edges = {}, {}
			local function point(x: number, y: number): number
				table.insert(coords, x)
				table.insert(coords, y)
				return #coords // 2
			end
			for i = 0, 5 do
				local a, b = point(i * 2, -1), point(i * 2, 11)
				table.insert(edges, a)
				table.insert(edges, b)
			end
			for i = 0, 5 do
				local a, b = point(-1, i * 2 + 0.5), point(11, i * 2 + 0.5)
				table.insert(edges, a)
				table.insert(edges, b)
			end
			local tri = checked({ Coords = coords, Edges = edges }, "grid of bars")
			expect(steinerCount(tri)).is(36)
		end)

		-- Random soups found two real bugs (flip-restoration re-checking only 2 of 4 quad
		-- edges; un-constrained crossing edges left non-Delaunay), so keep them broad:
		-- integer and fractional coordinates, many crossings and collinear hits.
		test("seeded random segment soups", function()
			for trial = 1, 60 do
				local rng = makeRng(1000 + trial)
				local coords, edges = {}, {}
				local pointCount = 10 + (trial % 40)
				local integer = trial % 2 == 0
				for _ = 1, pointCount do
					local x, y = rng(0, 64), rng(0, 64)
					if integer then
						x, y = math.floor(x), math.floor(y)
					end
					table.insert(coords, x)
					table.insert(coords, y)
				end
				for _ = 1, 3 + (trial % 25) do
					table.insert(edges, math.floor(rng(1, pointCount + 0.999)))
					table.insert(edges, math.floor(rng(1, pointCount + 0.999)))
				end
				checked({ Coords = coords, Edges = edges }, `soup {trial}`)
			end
		end)
	end)

	describe("invariant (b) negative control", function()
		test("a constraint left uncovered is caught", function()
			local input = { Coords = { 0, 0, 10, 1, 20, 0, 10, -1 }, Edges = { 1, 3 } }
			local plain = CDT.Triangulate({ Coords = input.Coords }) -- built WITHOUT the constraint
			local ok, reason = Invariants.Check(plain, input.Coords, input.Edges)
			expect(ok).never_is_true()
			expect((reason or ""):find("covered chain") ~= nil).is_true()
		end)
	end)

	describe("ToDrawList goldens (constrained)", function()
		test("square with hole", function()
			snapshot(CDT.ToDrawList(CDT.Triangulate(CDT.Fixtures.ToInput(CDT.Fixtures.SquareWithHole))))
		end)

		test("crossing constraints", function()
			snapshot(CDT.ToDrawList(CDT.Triangulate({ Coords = { 0, 0, 10, 10, 0, 10, 10, 0 }, Edges = { 1, 2, 3, 4 } })))
		end)
	end)
end
