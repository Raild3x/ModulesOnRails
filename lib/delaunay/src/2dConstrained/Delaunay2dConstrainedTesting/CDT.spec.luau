--!strict

return function(t: tiniest)
	local ConstrainedDelaunayTriangulation = require("../ConstrainedDelaunayTriangulation")
	local DrawUtil = require("../Utils/DrawUtil")

	local describe = t.describe
	local expect = t.expect
	local test = t.test

	local function key(v: Vector2): string
		return string.format("%.6f,%.6f", v.X, v.Y)
	end

	local function triKey(a: Vector2, b: Vector2, c: Vector2): string
		local p = { key(a), key(b), key(c) }
		table.sort(p)
		return p[1] .. "|" .. p[2] .. "|" .. p[3]
	end

	local function makeSquarePoints(scale: number?): { Vector2 }
		local s = scale or 1
		return {
			Vector2.new(0, 0),
			Vector2.new(1 * s, 0),
			Vector2.new(1 * s, 1 * s),
			Vector2.new(0, 1 * s),
		}
		-- return {
		-- 	-- Slightly perturbed convex quad to avoid cocircular/symmetric degeneracies.
		-- 	Vector2.new(0 * s, 0 * s),
		-- 	Vector2.new(1.0 * s, 0.0 * s),
		-- 	Vector2.new(1.07 * s, 0.93 * s),
		-- 	Vector2.new(-0.02 * s, 1.0 * s),
		-- }
	end

	local function makeSquareWithCenterPoints(): { Vector2 }
		return {
			Vector2.new(0, 0),
			Vector2.new(1, 0),
			Vector2.new(1, 1),
			Vector2.new(0, 1),
			Vector2.new(0.5, 0.5),
		}
	end

	local function triangulatedSquare(points: { Vector2 }?): ConstrainedDelaunayTriangulation.CDTInternal
		local cdt = ConstrainedDelaunayTriangulation.new()
		cdt:Triangulate(points or makeSquarePoints())
		return cdt :: any
	end

	describe("ConstrainedDelaunayTriangulation", function()
		describe("new", function()
			test("initializes empty state", function()
				local cdt = ConstrainedDelaunayTriangulation.new()
				expect(cdt.TriangleSet:GetTriangleCount()).is(0)
				expect(#cdt.DiscardedTriangles).is(0)
				expect(cdt.Grid).is(nil)
			end)

			test("initializes processing stacks", function()
				local cdt = ConstrainedDelaunayTriangulation.new()
				expect(#cdt.AdjacentTriangleStack).is(0)
				expect(#cdt.AdjacentTriangleEdgeStack).is(0)
			end)
		end)

		describe("CalculateBoundsWithLeftBottomCornerAtOrigin", function()
			test("computes min max size and center", function()
				local cdt = ConstrainedDelaunayTriangulation.new()
				local points = { Vector2.new(2, 4), Vector2.new(10, 8), Vector2.new(6, 2) }
				local bounds = cdt:CalculateBoundsWithLeftBottomCornerAtOrigin(points)
				expect(bounds.min).is(Vector2.new(2, 2))
				expect(bounds.max).is(Vector2.new(10, 8))
				expect(bounds.size).is(Vector2.new(8, 6))
				expect(bounds.center).is(Vector2.new(6, 5))
			end)

			test("handles negative coordinates", function()
				local cdt = ConstrainedDelaunayTriangulation.new()
				local points = { Vector2.new(-5, -1), Vector2.new(1, -3), Vector2.new(-2, 4) }
				local bounds = cdt:CalculateBoundsWithLeftBottomCornerAtOrigin(points)
				expect(bounds.min).is(Vector2.new(-5, -3))
				expect(bounds.max).is(Vector2.new(1, 4))
			end)
		end)

		describe("NormalizePoints", function()
			test("normalizes coordinates into 0..1-ish space", function()
				local cdt = ConstrainedDelaunayTriangulation.new()
				local points = { Vector2.new(5, 10), Vector2.new(15, 20), Vector2.new(25, 40) }
				local bounds = cdt:CalculateBoundsWithLeftBottomCornerAtOrigin(points)
				local normalized = cdt:NormalizePoints(points, bounds)
				expect(normalized[1].X >= 0 and normalized[1].Y >= 0).is(true)
				expect(normalized[#normalized].X <= 1 and normalized[#normalized].Y <= 1).is(true)
			end)

			test("preserves relative ordering along X", function()
				local cdt = ConstrainedDelaunayTriangulation.new()
				local points = { Vector2.new(1, 1), Vector2.new(2, 9), Vector2.new(3, 4) }
				local bounds = cdt:CalculateBoundsWithLeftBottomCornerAtOrigin(points)
				local normalized = cdt:NormalizePoints(points, bounds)
				expect(normalized[1].X < normalized[2].X).is(true)
				expect(normalized[2].X < normalized[3].X).is(true)
			end)
		end)

		describe("DenormalizePoints", function()
			test("inverts NormalizePoints for same bounds", function()
				local cdt = ConstrainedDelaunayTriangulation.new()
				local points = { Vector2.new(5, 10), Vector2.new(15, 20), Vector2.new(25, 40) }
				local bounds = cdt:CalculateBoundsWithLeftBottomCornerAtOrigin(points)
				local normalized = cdt:NormalizePoints(points, bounds)
				local denormalized = cdt:DenormalizePoints(normalized, bounds)
				for i = 1, #points do
					expect(denormalized[i]:FuzzyEq(points[i])).is(true)
				end
			end)

			test("keeps point count unchanged", function()
				local cdt = ConstrainedDelaunayTriangulation.new()
				local points = makeSquarePoints()
				local bounds = cdt:CalculateBoundsWithLeftBottomCornerAtOrigin(points)
				local denormalized = cdt:DenormalizePoints(cdt:NormalizePoints(points, bounds), bounds)
				expect(#denormalized).is(#points)
			end)
		end)

		describe("Triangulate", function()
			test("produces triangles for a simple square cloud", function()
				local cdt = triangulatedSquare()
				local triangles = cdt:GetTrianglesDiscardingHoles()
				expect(#triangles > 0).is(true)
			end)

			test("accepts optional hole polygons", function()
				local cdt = ConstrainedDelaunayTriangulation.new()
				local points = makeSquarePoints(10)
				local holes = { { Vector2.new(3, 3), Vector2.new(7, 3), Vector2.new(5, 7) } }
				cdt:Triangulate(points, nil, holes)
				expect(cdt.TriangleSet:GetTriangleCount() > 0).is(true)
			end)

			test("resets internal processing stacks", function()
				local cdt = ConstrainedDelaunayTriangulation.new()
				cdt.AdjacentTriangleStack = { 1, 2, 3 }
				cdt.AdjacentTriangleEdgeStack = { 1, 2, 3 }
				cdt:Triangulate(makeSquarePoints())
				expect(#cdt.AdjacentTriangleStack).is(0)
				expect(#cdt.AdjacentTriangleEdgeStack).is(0)
			end)

			test("Mass Triangulation Test", function()
				for j = 1, 250 do
					local cdt = ConstrainedDelaunayTriangulation.new()
					local points = {}
					for i = 1, 20 do
						table.insert(points, Vector2.new(math.random() * 100 - 50, math.random() * 100 - 50))
					end
					cdt:Triangulate(points)
					expect(cdt.TriangleSet:GetTriangleCount() > 0).is(true)
				end
			end)

			-- Note: This test is primarily to check for performance issues or errors with larger point sets. We won't assert specific triangle counts or properties here.
			-- Visual inspection can be done by drawing the triangles if needed.
			-- For example:
			-- local triangles = cdt:GetTrianglesDiscardingHoles()
			-- for _, tri in triangles do
			--     DrawUtil.DrawLine(tri[1], tri[2], Color3.fromRGB(255, 0, 0))
			--     DrawUtil.DrawLine(tri[2], tri[3], Color3.fromRGB(255, 0, 0))
			--     DrawUtil.DrawLine(tri[3], tri[1], Color3.fromRGB(255, 0, 0))
			-- end
			-- This would draw the triangulation in red lines for visual verification.

			-- test("Points with known issue", function()
			-- 	local cdt = ConstrainedDelaunayTriangulation.new()
			-- 	local points = {
			-- 		Vector2.new(77, 42),
			-- 		Vector2.new(5, 55),
			-- 		Vector2.new(42, 56),
			-- 		Vector2.new(52, 2),
			-- 		Vector2.new(22, 10),
			-- 		Vector2.new(56, 97),
			-- 		Vector2.new(16, 4),
			-- 		Vector2.new(88, 97),
			-- 		Vector2.new(18, 33),
			-- 		Vector2.new(83, 77),
			-- 	}
			-- 	for _, p in points do
			-- 		DrawUtil.DrawPoint(p, Color3.fromRGB(212, 0, 255), 2)
			-- 	end
			-- 	cdt:Triangulate(points)
			-- end)
		end)

		describe("GetTrianglesDiscardingHoles", function()
			test("returns generated triangles", function()
				local cdt = triangulatedSquare()
				local triangles = cdt:GetTrianglesDiscardingHoles()
				expect(#triangles > 0).is(true)
			end)

			test("appends into provided output array", function()
				local cdt = triangulatedSquare()
				local out = {}
				local result = cdt:GetTrianglesDiscardingHoles(out)
				expect(result).is(out)
				expect(#result > 0).is(true)
			end)

			test("returns only input vertices for basic square", function()
				local points = makeSquarePoints()
				local cdt = triangulatedSquare(points)
				local triangles = cdt:GetTrianglesDiscardingHoles()
				local inputSet = {}
				for _, p in points do
					inputSet[key(p)] = true
				end
				for _, tri in triangles do
					expect(inputSet[key(tri[1])]).is(true)
					expect(inputSet[key(tri[2])]).is(true)
					expect(inputSet[key(tri[3])]).is(true)
				end
			end)
		end)

		describe("GetAllTriangles", function()
			test("returns triangles including non-discarded and discarded", function()
				local cdt = triangulatedSquare()
				local allTriangles = cdt:GetAllTriangles()
				expect(#allTriangles > 0).is(true)
			end)

			test("appends into provided output array", function()
				local cdt = triangulatedSquare()
				local out = {}
				local result = cdt:GetAllTriangles(out)
				expect(result).is(out)
				expect(#result > 0).is(true)
			end)

			test("is not smaller than hole-discarding output", function()
				local cdt = triangulatedSquare()
				local allTriangles = cdt:GetAllTriangles()
				local keptTriangles = cdt:GetTrianglesDiscardingHoles()
				expect(#allTriangles >= #keptTriangles).is(true)
			end)
		end)

		describe("GetOutlinePolygon", function()
			test("returns an outline after triangulation", function()
				local cdt = triangulatedSquare()
				local outline = cdt:GetOutlinePolygon()
				expect(#outline >= 3).is(true)
			end)

			test("outline points come from triangle set point list", function()
				local cdt = triangulatedSquare()
				local allSetPoints = {}
				for _, p in cdt.TriangleSet.Points do
					allSetPoints[key(p)] = true
				end
				for _, p in cdt:GetOutlinePolygon() do
					expect(allSetPoints[key(p)]).is(true)
				end
			end)

			test("returns non-empty polygon for square cloud", function()
				local cdt = triangulatedSquare(makeSquareWithCenterPoints())
				expect(#cdt:GetOutlinePolygon() > 0).is(true)
			end)
		end)

		describe("GetSharedEdge", function()
			test("returns shared edge index for adjacent triangles", function()
				local cdt = triangulatedSquare()
				local t1 = cdt.TriangleSet:GetDelaunayTriangle(1)
				local adjacentTriangleIndex = -1
				for _, adjacent in t1.AdjacentTriangles do
					if adjacent > 0 then
						adjacentTriangleIndex = adjacent
						break
					end
				end
				expect(adjacentTriangleIndex > 0).is(true)
				local edgeIdx = cdt:GetSharedEdge(t1, adjacentTriangleIndex)
				expect(edgeIdx >= 1 and edgeIdx <= 3).is(true)
			end)

			test("returns -1 when adjacent triangle is not found", function()
				local cdt = triangulatedSquare()
				local t1 = cdt.TriangleSet:GetDelaunayTriangle(1)
				expect(cdt:GetSharedEdge(t1, 999)).is(-1)
			end)

			test("matches reciprocal adjacency lookup", function()
				local cdt = triangulatedSquare()
				local t1 = cdt.TriangleSet:GetDelaunayTriangle(1)
				local adjacentTriangleIndex = -1
				for _, adjacent in t1.AdjacentTriangles do
					if adjacent > 0 then
						adjacentTriangleIndex = adjacent
						break
					end
				end
				expect(adjacentTriangleIndex > 0).is(true)
				local idx = cdt:GetSharedEdge(t1, adjacentTriangleIndex)
				if idx ~= -1 then
					expect(t1.AdjacentTriangles[idx]).is(adjacentTriangleIndex)
				else
					expect(idx).is(-1)
				end
			end)
		end)

		describe("GetSupertriangleTriangles", function()
			test("returns at least one triangle index", function()
				local cdt = triangulatedSquare()
				local super = cdt:GetSupertriangleTriangles()
				expect(#super > 0).is(true)
			end)

			test("appends to provided output array", function()
				local cdt = triangulatedSquare()
				local out = {}
				local result = cdt:GetSupertriangleTriangles(out)
				expect(result).is(out)
				expect(#result > 0).is(true)
			end)

			test("returns unique indices", function()
				local cdt = triangulatedSquare()
				local super = cdt:GetSupertriangleTriangles()
				local seen = {}
				for _, index in super do
					expect(seen[index] == nil).is(true)
					seen[index] = true
				end
			end)
		end)

		describe("Tesselate", function()
			test("keeps triangulation valid when threshold is large", function()
				local cdt = triangulatedSquare(makeSquareWithCenterPoints())
				local before = #cdt:GetTrianglesDiscardingHoles()
				cdt:Tesselate(9999)
				local after = #cdt:GetTrianglesDiscardingHoles()
				expect(after >= before).is(true)
			end)

			test("can increase triangle count with small threshold", function()
				local cdt = triangulatedSquare(makeSquareWithCenterPoints())
				local before = #cdt:GetTrianglesDiscardingHoles()
				cdt:Tesselate(0.02)
				local after = #cdt:GetTrianglesDiscardingHoles()
				expect(after >= before).is(true)
			end)

			test("preserves triangle coordinate uniqueness set keys", function()
				local cdt = triangulatedSquare(makeSquareWithCenterPoints())
				cdt:Tesselate(0.02)
				local triangles = cdt:GetTrianglesDiscardingHoles()
				local keys = {}
				for _, tri in triangles do
					keys[triKey(tri[1], tri[2], tri[3])] = true
				end
				expect(next(keys) ~= nil).is(true)
			end)
		end)

		describe("_AddPointToTriangulation", function()
			test("returns existing point index when point already exists", function()
				local cdt = triangulatedSquare()
				local existing = cdt.TriangleSet.Points[4]
				local idx = cdt:_AddPointToTriangulation(existing)
				expect(cdt.TriangleSet.Points[idx]).is(existing)
			end)

			test("adds a new point when point is not present", function()
				local cdt = triangulatedSquare()
				local before = #cdt.TriangleSet.Points
				local idx = cdt:_AddPointToTriangulation(Vector2.new(0.25, 0.35))
				expect(idx > before).is(true)
				expect(#cdt.TriangleSet.Points).is(before + 1)
			end)

			test("returns a valid index", function()
				local cdt = triangulatedSquare()
				local idx = cdt:_AddPointToTriangulation(Vector2.new(0.35, 0.25))
				expect(idx >= 1 and idx <= #cdt.TriangleSet.Points).is(true)
			end)
		end)

		describe("_FulfillDelaunayConstraint", function()
			test("no-ops on empty stacks", function()
				local cdt = triangulatedSquare()
				cdt:_FulfillDelaunayConstraint({}, {})
				expect(true).is(true)
			end)

			test("consumes provided stacks", function()
				local cdt = triangulatedSquare()
				local triangles = { 1 }
				local edges = { 1 }
				cdt:_FulfillDelaunayConstraint(triangles, edges)
				expect(#triangles).is(0)
				expect(#edges).is(0)
			end)

			test("handles non-swapping inputs safely", function()
				local cdt = triangulatedSquare()
				local triangles = { 1 }
				local edges = { 3 }
				cdt:_FulfillDelaunayConstraint(triangles, edges)
				expect(true).is(true)
			end)
		end)

		describe("_SwapEdges", function()
			test("updates triangle vertex buffers for a valid swap setup", function()
				local cdt = triangulatedSquare()
				local t1 = cdt.TriangleSet:GetDelaunayTriangle(1)
				local t2 = cdt.TriangleSet:GetDelaunayTriangle(2)
				local before1 = { t1.Points[1], t1.Points[2], t1.Points[3] }
				cdt:_SwapEdges(1, t1, 1, t2, 1)
				local after1a, after1b, after1c = cdt.TriangleSet:GetTriangleVertexIndices(1)
				expect(after1a ~= before1[1] or after1b ~= before1[2] or after1c ~= before1[3]).is(true)
			end)

			test("keeps triangle count unchanged", function()
				local cdt = triangulatedSquare()
				local before = cdt.TriangleSet:GetTriangleCount()
				local t1 = cdt.TriangleSet:GetDelaunayTriangle(1)
				local t2 = cdt.TriangleSet:GetDelaunayTriangle(2)
				cdt:_SwapEdges(1, t1, 1, t2, 1)
				expect(cdt.TriangleSet:GetTriangleCount()).is(before)
			end)

			test("keeps adjacency table populated", function()
				local cdt = triangulatedSquare()
				local t1 = cdt.TriangleSet:GetDelaunayTriangle(1)
				local t2 = cdt.TriangleSet:GetDelaunayTriangle(2)
				cdt:_SwapEdges(1, t1, 1, t2, 1)
				expect(#cdt.TriangleSet.AdjacentTriangles >= 6).is(true)
			end)

			test("maintains bidirectional adjacency after swap", function()
				-- Critical: verify that if triangle A says it's adjacent to triangle B on edge i,
				-- then triangle B must reference triangle A on some edge.
				local cdt = triangulatedSquare(makeSquareWithCenterPoints())

				local function checkBidirectionalAdjacency()
					local triangleSet = cdt.TriangleSet
					for triangleIdx = 1, triangleSet:GetTriangleCount() do
						local adjacents = { triangleSet:GetAdjacentTriangleVertexIndices(triangleIdx) }
						for edgeIdx = 1, 3 do
							local adjacentTriangleIdx = adjacents[edgeIdx]
							if adjacentTriangleIdx ~= -1 then
								local adjacentsOfAdjacent =
									{ triangleSet:GetAdjacentTriangleVertexIndices(adjacentTriangleIdx) }
								local foundBackRef = false
								for adjacentEdgeIdx = 1, 3 do
									if adjacentsOfAdjacent[adjacentEdgeIdx] == triangleIdx then
										foundBackRef = true
										break
									end
								end
								expect(foundBackRef).is(true)
							end
						end
					end
				end

				checkBidirectionalAdjacency()

				local t1 = cdt.TriangleSet:GetDelaunayTriangle(1)
				local t2 = cdt.TriangleSet:GetDelaunayTriangle(2)
				if t2 then
					cdt:_SwapEdges(1, t1, 1, t2, 1)
					checkBidirectionalAdjacency()
				end
			end)

			test("can expose external neighbor corruption under original _SwapEdges api", function()
				local cdt = triangulatedSquare(makeSquareWithCenterPoints())
				local triangleSet = cdt.TriangleSet

				local t1 = triangleSet:GetDelaunayTriangle(2)
				if not t1 then
					error("Test setup failed: expected triangle 2 to exist")
				end

				local adj2 = t1.AdjacentTriangles[2]
				if adj2 == -1 then
					error("Test setup failed: expected triangle 2 to have an adjacent triangle on edge 2")
				end

				local t2 = triangleSet:GetDelaunayTriangle(adj2)
				if not t2 then
					error("Test setup failed: expected adjacent triangle to exist")
				end

				cdt:_SwapEdges(2, t1, 1, t2, 1)

				local t1_after = triangleSet:GetDelaunayTriangle(2)
				for i = 1, 3 do
					if t1_after.AdjacentTriangles[i] ~= -1 then
						local neighbor = t1_after.AdjacentTriangles[i]
						local neighborData = triangleSet:GetDelaunayTriangle(neighbor)
						local foundRef = false
						for j = 1, 3 do
							if neighborData.AdjacentTriangles[j] == 2 then
								foundRef = true
								break
							end
						end
						expect(foundRef).is(true)
					end
				end
			end)
		end)

		describe("_AddConstrainedEdgeToTriangulation", function()
			test("no-ops when constrained edge already exists", function()
				local cdt = triangulatedSquare()
				local before = cdt.TriangleSet:GetTriangleCount()
				cdt:_AddConstrainedEdgeToTriangulation(1, 2)
				expect(cdt.TriangleSet:GetTriangleCount()).is(before)
			end)

			test("can process a non-existing diagonal edge", function()
				local cdt = triangulatedSquare()
				cdt:_AddConstrainedEdgeToTriangulation(2, 4)
				expect(cdt.TriangleSet:GetTriangleCount() > 0).is(true)
			end)

			test("does not remove all triangles", function()
				local cdt = triangulatedSquare()
				cdt:_AddConstrainedEdgeToTriangulation(2, 4)
				expect(cdt.TriangleSet:GetTriangleCount() >= 2).is(true)
			end)
		end)

		describe("GetOutlinePolygon regression tests", function()
			test("outline found for collinear points horizontally", function()
				local cdt = ConstrainedDelaunayTriangulation.new()
				-- Collinear points on horizontal line
				local collinearHorizontal = {
					Vector2.new(0, 0),
					Vector2.new(1, 0),
					Vector2.new(2, 0),
					Vector2.new(3, 0),
				}
				cdt:Triangulate(collinearHorizontal)
				local outline = cdt:GetOutlinePolygon()
				expect(#outline > 0).is(true)
			end)

			test("outline found for collinear points vertically", function()
				local cdt = ConstrainedDelaunayTriangulation.new()
				-- Collinear points on vertical line
				local collinearVertical = {
					Vector2.new(0, 0),
					Vector2.new(0, 1),
					Vector2.new(0, 2),
					Vector2.new(0, 3),
				}
				cdt:Triangulate(collinearVertical)
				local outline = cdt:GetOutlinePolygon()
				expect(#outline > 0).is(true)
			end)

			test("outline found for concave shape", function()
				local cdt = ConstrainedDelaunayTriangulation.new()
				-- L-shaped point cloud (concave)
				local concavePoints = {
					Vector2.new(0, 0),
					Vector2.new(2, 0),
					Vector2.new(2, 1),
					Vector2.new(1, 1),
					Vector2.new(1, 2),
					Vector2.new(0, 2),
				}
				cdt:Triangulate(concavePoints)
				local outline = cdt:GetOutlinePolygon()
				expect(#outline > 0).is(true)
			end)

			test("outline found for dense interior point set", function()
				local cdt = ConstrainedDelaunayTriangulation.new()
				-- Square boundary with interior point
				local boundaryWithInterior = {
					Vector2.new(0, 0),
					Vector2.new(4, 0),
					Vector2.new(4, 4),
					Vector2.new(0, 4),
					Vector2.new(2, 2), -- Interior point
				}
				cdt:Triangulate(boundaryWithInterior)
				local outline = cdt:GetOutlinePolygon()
				expect(#outline > 0).is(true)
			end)

			test("outline found for multi-interior points", function()
				local cdt = ConstrainedDelaunayTriangulation.new()
				-- Square boundary with multiple interior points
				local manyInterior = {
					Vector2.new(0, 0),
					Vector2.new(5, 0),
					Vector2.new(5, 5),
					Vector2.new(0, 5),
					Vector2.new(1, 1),
					Vector2.new(2, 2),
					Vector2.new(3, 1),
					Vector2.new(4, 3),
				}
				cdt:Triangulate(manyInterior)
				local outline = cdt:GetOutlinePolygon()
				expect(#outline > 0).is(true)
			end)
		end)
	end)
end
