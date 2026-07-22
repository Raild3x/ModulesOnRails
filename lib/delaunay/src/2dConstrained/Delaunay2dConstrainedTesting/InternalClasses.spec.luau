--!strict

return function(t: tiniest)
	local DelaunayTriangle = require("../InternalClasses/DelaunayTriangle")
	local DelaunayTriangleEdge = require("../InternalClasses/DelaunayTriangleEdge")
	local DelaunayTriangleSet = require("../InternalClasses/DelaunayTriangleSet")
	local PointBinGrid = require("../InternalClasses/PointBinGrid")

	type DelaunayTriangle = DelaunayTriangle.DelaunayTriangle
	type DelaunayTriangleEdge = DelaunayTriangleEdge.DelaunayTriangleEdge
	type DelaunayTriangleSet = DelaunayTriangleSet.DelaunayTriangleSet
	type PointBinGrid = PointBinGrid.PointBinGrid
	type PointBinGridInternal = PointBinGrid.PointBinGridInternal

	local describe = t.describe
	local expect = t.expect
	local test = t.test

	local function edgesContain(edges: { { number } }, a: number, b: number): boolean
		for _, edge in edges do
			if edge[1] == a and edge[2] == b then
				return true
			end
		end
		return false
	end

	local function key(v: Vector2): string
		return string.format("%.6f,%.6f", v.X, v.Y)
	end

	local function makeSingleTriangleSet()
		local set = DelaunayTriangleSet.new()
		set:AddRawTriangle(Vector2.new(0, 0), Vector2.new(1, 0), Vector2.new(0, 1), -1, -1, -1)
		return set
	end

	local function makeSquareTriangleSet()
		local set = DelaunayTriangleSet.new()

		set:AddPoint(Vector2.new(0, 0)) -- 1
		set:AddPoint(Vector2.new(1, 0)) -- 2
		set:AddPoint(Vector2.new(1, 1)) -- 3
		set:AddPoint(Vector2.new(0, 1)) -- 4

		set:AddTriangle(DelaunayTriangle.new(1, 2, 3, -1, -1, 2))
		set:AddTriangle(DelaunayTriangle.new(1, 3, 4, 1, -1, -1))

		return set
	end

	describe("DelaunayTriangle", function()
		describe("new", function()
			test("assigns point and adjacency indices", function()
				local tri = DelaunayTriangle.new(4, 5, 6, 1, 2, 3)
				expect(tri.Points[1]).is(4)
				expect(tri.Points[2]).is(5)
				expect(tri.Points[3]).is(6)
				expect(tri.AdjacentTriangles[1]).is(1)
				expect(tri.AdjacentTriangles[2]).is(2)
				expect(tri.AdjacentTriangles[3]).is(3)
			end)

			test("defaults adjacency to -1 when omitted", function()
				local tri = DelaunayTriangle.new(1, 2, 3, nil, nil, nil)
				expect(tri.AdjacentTriangles[1]).is(-1)
				expect(tri.AdjacentTriangles[2]).is(-1)
				expect(tri.AdjacentTriangles[3]).is(-1)
			end)

			test("errors when point indices are not numbers", function()
				expect(function()
					(DelaunayTriangle :: any).new("x", 2, 3, nil, nil, nil)
				end).fails()
			end)

			test("errors when adjacency values are invalid types", function()
				expect(function()
					(DelaunayTriangle :: any).new(1, 2, 3, {}, nil, nil)
				end).fails()
			end)
		end)
	end)

	describe("DelaunayTriangleEdge", function()
		describe("new", function()
			test("stores all provided fields", function()
				local edge = DelaunayTriangleEdge.new(7, 2, 100, 200)
				expect(edge.TriangleIndex).is(7)
				expect(edge.EdgeIndex).is(2)
				expect(edge.EdgeVertexA).is(100)
				expect(edge.EdgeVertexB).is(200)
			end)

			test("supports negative sentinel values", function()
				local edge = DelaunayTriangleEdge.new(-1, -1, 3, 4)
				expect(edge.TriangleIndex).is(-1)
				expect(edge.EdgeIndex).is(-1)
			end)

			test("errors when triangleIndex is not a number", function()
				expect(function()
					(DelaunayTriangleEdge :: any).new("bad", 1, 2, 3)
				end).fails()
			end)

			test("errors when edge vertices are not numbers", function()
				expect(function()
					(DelaunayTriangleEdge :: any).new(1, 1, "a", "b")
				end).fails()
			end)
		end)
	end)

	describe("PointBinGrid", function()
		describe("new", function()
			test("initializes grid metadata", function()
				local grid = PointBinGrid.new(4, Vector2.new(20, 20)) :: PointBinGridInternal
				expect(grid.m_cellSize).is(Vector2.new(5, 5))
				expect(grid.m_gridSize).is(Vector2.new(20, 20))
				expect(grid.m_cellsPerSide).is(4)
				expect(grid.Cells).is_a("table")
			end)

			test("starts with no populated bins", function()
				local grid = PointBinGrid.new(3, Vector2.new(30, 30)) :: PointBinGridInternal
				local populatedBins = 0
				for _, cell in grid.Cells do
					if cell ~= nil then
						populatedBins += 1
					end
				end
				expect(populatedBins).is(0)
			end)
		end)

		describe("AddPoint", function()
			test("places points into expected bins", function()
				local grid = PointBinGrid.new(2, Vector2.new(100, 100)) :: PointBinGridInternal
				local p1 = Vector2.new(10, 10)
				local p2 = Vector2.new(90, 10)
				local p3 = Vector2.new(50, 80)

				grid:AddPoint(p1)
				grid:AddPoint(p2)
				grid:AddPoint(p3)

				expect((grid.Cells[1] :: { Vector2 })[1]).is(p1)
				expect((grid.Cells[2] :: { Vector2 })[1]).is(p2)
				expect((grid.Cells[4] :: { Vector2 })[1]).is(p3)
			end)

			test("appends multiple points to the same bin", function()
				local grid = PointBinGrid.new(2, Vector2.new(100, 100)) :: PointBinGridInternal
				local p1 = Vector2.new(10, 10)
				local p2 = Vector2.new(15, 15)

				grid:AddPoint(p1)
				grid:AddPoint(p2)

				local bin = grid.Cells[1] :: { Vector2 }
				expect(#bin).is(2)
				expect(bin[1]).is(p1)
				expect(bin[2]).is(p2)
			end)

			test("supports serpentine row indexing", function()
				local grid = PointBinGrid.new(2, Vector2.new(100, 100)) :: PointBinGridInternal
				local point = Vector2.new(10, 80)
				grid:AddPoint(point)
				expect((grid.Cells[4] :: { Vector2 })[1]).is(point)
			end)
		end)

		describe("ForEachPoint", function()
			test("visits all inserted points", function()
				local grid = PointBinGrid.new(2, Vector2.new(100, 100))
				local points = {
					Vector2.new(10, 10),
					Vector2.new(90, 10),
					Vector2.new(50, 80),
				}

				for _, point in points do
					grid:AddPoint(point)
				end

				local seen: { [string]: number } = {}
				grid:ForEachPoint(function(point)
					local pointKey = key(point)
					local count = seen[pointKey] or 0
					seen[pointKey] = count + 1
				end)

				expect(seen[key(points[1])]).is(1)
				expect(seen[key(points[2])]).is(1)
				expect(seen[key(points[3])]).is(1)
			end)

			test("iterates in cell order", function()
				local grid = PointBinGrid.new(2, Vector2.new(100, 100))
				local p1 = Vector2.new(10, 10)
				local p2 = Vector2.new(90, 10)
				local p3 = Vector2.new(50, 80)
				grid:AddPoint(p1)
				grid:AddPoint(p2)
				grid:AddPoint(p3)

				local visited = {}
				grid:ForEachPoint(function(point)
					table.insert(visited, point)
				end)

				expect(visited[1]).is(p1)
				expect(visited[2]).is(p2)
				expect(visited[3]).is(p3)
			end)

			test("does nothing when no points exist", function()
				local grid = PointBinGrid.new(2, Vector2.new(100, 100))
				local count = 0
				grid:ForEachPoint(function()
					count += 1
				end)
				expect(count).is(0)
			end)
		end)
	end)

	describe("DelaunayTriangleSet", function()
		describe("new", function()
			test("initializes empty arrays", function()
				local set = DelaunayTriangleSet.new()
				expect(#set.Points).is(0)
				expect(#set.TriangleVertices).is(0)
				expect(#set.AdjacentTriangles).is(0)
			end)

			test("creates independent tables per instance", function()
				local a = DelaunayTriangleSet.new()
				local b = DelaunayTriangleSet.new()
				a:AddPoint(Vector2.new(1, 1))
				expect(#a.Points).is(1)
				expect(#b.Points).is(0)
			end)
		end)

		describe("clear", function()
			test("empties all storage", function()
				local set = makeSquareTriangleSet()
				set:clear()
				expect(#set.Points).is(0)
				expect(#set.TriangleVertices).is(0)
				expect(#set.AdjacentTriangles).is(0)
			end)

			test("can be called on an already empty set", function()
				local set = DelaunayTriangleSet.new()
				set:clear()
				expect(#set.Points).is(0)
			end)

			test("allows reuse after clearing", function()
				local set = makeSquareTriangleSet()
				set:clear()
				local idx = set:AddPoint(Vector2.new(3, 4))
				expect(idx).is(1)
			end)
		end)

		describe("AddPoint", function()
			test("returns incrementing indices", function()
				local set = DelaunayTriangleSet.new()
				expect(set:AddPoint(Vector2.new(1, 1))).is(1)
				expect(set:AddPoint(Vector2.new(2, 2))).is(2)
			end)

			test("stores points in insertion order", function()
				local set = DelaunayTriangleSet.new()
				local p1 = Vector2.new(5, 6)
				local p2 = Vector2.new(7, 8)
				set:AddPoint(p1)
				set:AddPoint(p2)
				expect(set.Points[1]).is(p1)
				expect(set.Points[2]).is(p2)
			end)

			test("accepts duplicate coordinates as distinct entries", function()
				local set = DelaunayTriangleSet.new()
				set:AddPoint(Vector2.new(1, 1))
				set:AddPoint(Vector2.new(1, 1))
				expect(#set.Points).is(2)
			end)
		end)

		describe("GetIndexOfPoint", function()
			test("returns the first matching point index", function()
				local set = DelaunayTriangleSet.new()
				local p = Vector2.new(5, 6)
				set:AddPoint(p)
				set:AddPoint(p)
				expect(set:GetIndexOfPoint(p)).is(1)
			end)

			test("returns -1 for a missing point", function()
				local set = DelaunayTriangleSet.new()
				set:AddPoint(Vector2.new(5, 6))
				expect(set:GetIndexOfPoint(Vector2.new(1, 2))).is(-1)
			end)

			test("works after multiple insertions", function()
				local set = DelaunayTriangleSet.new()
				set:AddPoint(Vector2.new(0, 0))
				local target = Vector2.new(9, 9)
				set:AddPoint(target)
				expect(set:GetIndexOfPoint(target)).is(2)
			end)
		end)

		describe("GetPointFromIndex", function()
			test("returns the stored point", function()
				local set = DelaunayTriangleSet.new()
				local p = Vector2.new(5, 6)
				set:AddPoint(p)
				expect(set:GetPointFromIndex(1)).is(p)
			end)

			test("returns the correct point for later indices", function()
				local set = DelaunayTriangleSet.new()
				set:AddPoint(Vector2.new(1, 1))
				local p = Vector2.new(2, 2)
				set:AddPoint(p)
				expect(set:GetPointFromIndex(2)).is(p)
			end)

			test("matches Points storage directly", function()
				local set = DelaunayTriangleSet.new()
				set:AddPoint(Vector2.new(3, 4))
				expect(set:GetPointFromIndex(1)).is(set.Points[1])
			end)
		end)

		describe("GetTriangleCount", function()
			test("returns zero for an empty set", function()
				local set = DelaunayTriangleSet.new()
				expect(set:GetTriangleCount()).is(0)
			end)

			test("counts raw triangles", function()
				local set = makeSingleTriangleSet()
				expect(set:GetTriangleCount()).is(1)
			end)

			test("counts multiple triangles", function()
				local set = makeSquareTriangleSet()
				expect(set:GetTriangleCount()).is(2)
			end)
		end)

		describe("AddTriangle", function()
			test("inserts provided indices and adjacency", function()
				local set = DelaunayTriangleSet.new()
				set:AddPoint(Vector2.new(0, 0))
				set:AddPoint(Vector2.new(1, 0))
				set:AddPoint(Vector2.new(0, 1))
				local triIdx = set:AddTriangle(DelaunayTriangle.new(1, 2, 3, 9, 8, 7))
				expect(triIdx).is(1)
				expect(set.TriangleVertices[1]).is(1)
				expect(set.AdjacentTriangles[3]).is(7)
			end)

			test("increments triangle count", function()
				local set = DelaunayTriangleSet.new()
				for _, point in { Vector2.new(0, 0), Vector2.new(1, 0), Vector2.new(0, 1), Vector2.new(1, 1) } do
					set:AddPoint(point)
				end
				set:AddTriangle(DelaunayTriangle.new(1, 2, 3, -1, -1, -1))
				set:AddTriangle(DelaunayTriangle.new(2, 4, 3, 1, -1, -1))
				expect(set:GetTriangleCount()).is(2)
			end)

			test("preserves insertion order in triangle vertex buffer", function()
				local set = DelaunayTriangleSet.new()
				for _, point in { Vector2.new(0, 0), Vector2.new(1, 0), Vector2.new(0, 1) } do
					set:AddPoint(point)
				end
				set:AddTriangle(DelaunayTriangle.new(3, 1, 2, -1, -1, -1))
				expect(set.TriangleVertices[1]).is(3)
				expect(set.TriangleVertices[2]).is(1)
				expect(set.TriangleVertices[3]).is(2)
			end)
		end)

		describe("AddRawTriangle", function()
			test("creates both points and a triangle", function()
				local set = DelaunayTriangleSet.new()
				local triIndex = set:AddRawTriangle(Vector2.new(0, 0), Vector2.new(1, 0), Vector2.new(0, 1), -1, -1, -1)
				expect(triIndex).is(1)
				expect(#set.Points).is(3)
				expect(set:GetTriangleCount()).is(1)
			end)

			test("stores adjacency values", function()
				local set = DelaunayTriangleSet.new()
				set:AddRawTriangle(Vector2.new(0, 0), Vector2.new(1, 0), Vector2.new(0, 1), 3, 4, 5)
				expect(set.AdjacentTriangles[1]).is(3)
				expect(set.AdjacentTriangles[2]).is(4)
				expect(set.AdjacentTriangles[3]).is(5)
			end)

			test("assigns point indices sequentially", function()
				local set = DelaunayTriangleSet.new()
				set:AddRawTriangle(Vector2.new(5, 5), Vector2.new(6, 5), Vector2.new(5, 6), -1, -1, -1)
				local a, b, c = set:GetTriangleVertexIndices(1)
				expect(a).is(1)
				expect(b).is(2)
				expect(c).is(3)
			end)
		end)

		describe("AreEdgesEqual", function()
			test("returns true for identical orientation", function()
				local set = DelaunayTriangleSet.new()
				expect(set:AreEdgesEqual(1, 3, 1, 3)).is(true)
			end)

			test("returns true for reversed orientation", function()
				local set = DelaunayTriangleSet.new()
				expect(set:AreEdgesEqual(1, 3, 3, 1)).is(true)
			end)

			test("returns false for different edges", function()
				local set = DelaunayTriangleSet.new()
				expect(set:AreEdgesEqual(1, 2, 2, 3)).is(false)
			end)
		end)

		describe("FindTriangleWithEdge", function()
			test("finds an existing edge", function()
				local set = makeSquareTriangleSet()
				expect(set:FindTriangleWithEdge(1, 3)).is(1)
			end)

			test("matches reversed edge order", function()
				local set = makeSquareTriangleSet()
				expect(set:FindTriangleWithEdge(3, 1)).is(1)
			end)

			test("returns -1 for a missing edge", function()
				local set = makeSquareTriangleSet()
				expect(set:FindTriangleWithEdge(2, 4)).is(-1)
			end)
		end)

		describe("GetTriangleVertexIndices", function()
			test("returns the correct vertex indices", function()
				local set = makeSquareTriangleSet()
				local a, b, c = set:GetTriangleVertexIndices(1)
				expect(a).is(1)
				expect(b).is(2)
				expect(c).is(3)
			end)

			test("works for later triangles", function()
				local set = makeSquareTriangleSet()
				local a, b, c = set:GetTriangleVertexIndices(2)
				expect(a).is(1)
				expect(b).is(3)
				expect(c).is(4)
			end)

			test("reflects replaced triangle data", function()
				local set = makeSquareTriangleSet()
				set:ReplaceTriangle(2, DelaunayTriangle.new(2, 3, 4, -1, -1, -1))
				local a, b, c = set:GetTriangleVertexIndices(2)
				expect(a).is(2)
				expect(b).is(3)
				expect(c).is(4)
			end)
		end)

		describe("GetTriangleEdgeIndices", function()
			test("returns all three edges", function()
				local set = makeSquareTriangleSet()
				local edges = set:GetTriangleEdgeIndices(1)
				expect(#edges).is(3)
			end)

			test("returns edges in winding order", function()
				local set = makeSquareTriangleSet()
				local edges = set:GetTriangleEdgeIndices(1)
				expect(edges[1][1]).is(1)
				expect(edges[1][2]).is(2)
				expect(edges[2][1]).is(2)
				expect(edges[2][2]).is(3)
				expect(edges[3][1]).is(3)
				expect(edges[3][2]).is(1)
			end)

			test("contains expected edge pairs", function()
				local set = makeSquareTriangleSet()
				local edges = set:GetTriangleEdgeIndices(2)
				expect(edgesContain(edges, 1, 3)).is(true)
				expect(edgesContain(edges, 3, 4)).is(true)
				expect(edgesContain(edges, 4, 1)).is(true)
			end)
		end)

		describe("GetTrianglePoints", function()
			test("returns the expected point objects", function()
				local set = makeSquareTriangleSet()
				local triPoints = set:GetTrianglePoints(2)
				expect(triPoints[1]).is(set.Points[1])
				expect(triPoints[2]).is(set.Points[3])
				expect(triPoints[3]).is(set.Points[4])
			end)

			test("works for the first triangle", function()
				local set = makeSquareTriangleSet()
				local triPoints = set:GetTrianglePoints(1)
				expect(triPoints[1]).is(set.Points[1])
				expect(triPoints[2]).is(set.Points[2])
				expect(triPoints[3]).is(set.Points[3])
			end)

			test("errors for an out of bounds triangle index", function()
				local set = makeSquareTriangleSet()
				expect(function()
					set:GetTrianglePoints(99)
				end).fails()
			end)
		end)

		describe("GetDelaunayTriangle", function()
			test("returns the triangle data for a valid index", function()
				local set = makeSquareTriangleSet()
				local tri = set:GetDelaunayTriangle(1)
				expect(tri.Points[1]).is(1)
				expect(tri.Points[2]).is(2)
				expect(tri.Points[3]).is(3)
			end)

			test("returns adjacency data", function()
				local set = makeSquareTriangleSet()
				local tri = set:GetDelaunayTriangle(1)
				expect(tri.AdjacentTriangles[1]).is(-1)
				expect(tri.AdjacentTriangles[2]).is(-1)
				expect(tri.AdjacentTriangles[3]).is(2)
			end)

			test("returns a detached triangle object", function()
				local set = makeSquareTriangleSet()
				local tri = set:GetDelaunayTriangle(1)
				tri.Points[1] = 99
				local a = select(1, set:GetTriangleVertexIndices(1))
				expect(a).is(1)
			end)
		end)

		describe("GetTrianglesInPolygon", function()
			test("returns both triangles for the square outline", function()
				local set = makeSquareTriangleSet()
				local inPoly = set:GetTrianglesInPolygon({ 1, 2, 3, 4 }, {})
				local has1 = false
				local has2 = false
				for _, triIndex in inPoly do
					if triIndex == 1 then
						has1 = true
					elseif triIndex == 2 then
						has2 = true
					end
				end
				expect(has1).is(true)
				expect(has2).is(true)
			end)

			test("appends into the provided output array", function()
				local set = makeSquareTriangleSet()
				local out = { 99 }
				local result = set:GetTrianglesInPolygon({ 1, 2, 3, 4 }, out)
				expect(result).is(out)
				expect(result[1]).is(99)
			end)

			test("does not duplicate already collected outline triangles", function()
				local set = makeSquareTriangleSet()
				local result = set:GetTrianglesInPolygon({ 1, 2, 3, 4 }, {})
				local counts = { [1] = 0, [2] = 0 }
				for _, triIndex in result do
					if counts[triIndex] ~= nil then
						counts[triIndex] += 1
					end
				end
				expect(counts[1]).is(1)
				expect(counts[2]).is(1)
			end)
		end)

		describe("FindTriangleThatContainsEdge", function()
			test("finds an edge in the stored orientation", function()
				local set = makeSquareTriangleSet()
				local found = set:FindTriangleThatContainsEdge(1, 3)
				expect(found.TriangleIndex).is(2)
				expect(found.EdgeIndex).is(1)
			end)

			test("returns sentinels for missing edges", function()
				local set = makeSquareTriangleSet()
				local notFound = set:FindTriangleThatContainsEdge(4, 2)
				expect(notFound.TriangleIndex).is(-1)
				expect(notFound.EdgeIndex).is(-1)
			end)

			test("can find the first triangle edge", function()
				local set = makeSingleTriangleSet()
				local found = set:FindTriangleThatContainsEdge(1, 2)
				expect(found.TriangleIndex).is(1)
				expect(found.EdgeIndex).is(1)
			end)
		end)

		describe("GetTrianglesWithVertex", function()
			test("returns all triangles sharing a vertex", function()
				local set = makeSquareTriangleSet()
				local result = set:GetTrianglesWithVertex(1)
				expect(#result).is(2)
				local has1 = false
				local has2 = false
				for _, value in result do
					if value == 1 then
						has1 = true
					end
					if value == 2 then
						has2 = true
					end
				end
				expect(has1).is(true)
				expect(has2).is(true)
			end)

			test("appends into the provided output array", function()
				local set = makeSquareTriangleSet()
				local out = { 99 }
				local result = set:GetTrianglesWithVertex(1, out)
				expect(result).is(out)
				expect(result[1]).is(99)
			end)

			test("returns an empty list for a missing vertex", function()
				local set = makeSquareTriangleSet()
				local result = set:GetTrianglesWithVertex(99)
				expect(#result).is(0)
			end)
		end)

		describe("GetAdjacentTriangleVertexIndices", function()
			test("returns adjacency for the first triangle", function()
				local set = makeSquareTriangleSet()
				local a1, a2, a3 = set:GetAdjacentTriangleVertexIndices(1)
				expect(a1).is(-1)
				expect(a2).is(-1)
				expect(a3).is(2)
			end)

			test("returns adjacency for the second triangle", function()
				local set = makeSquareTriangleSet()
				local a1, a2, a3 = set:GetAdjacentTriangleVertexIndices(2)
				expect(a1).is(1)
				expect(a2).is(-1)
				expect(a3).is(-1)
			end)

			test("reflects subsequent adjacency updates", function()
				local set = makeSquareTriangleSet()
				set:SetTriangleAdjacency(1, { 7, 8, 9 })
				local a1, a2, a3 = set:GetAdjacentTriangleVertexIndices(1)
				expect(a1).is(7)
				expect(a2).is(8)
				expect(a3).is(9)
			end)
		end)

		describe("SetAdjacentTriangle", function()
			test("updates a single adjacency slot", function()
				local set = makeSquareTriangleSet()
				set:SetAdjacentTriangle(1, 2, 55)
				local _, a2 = set:GetAdjacentTriangleVertexIndices(1)
				expect(a2).is(55)
			end)

			test("does not affect other adjacency slots", function()
				local set = makeSquareTriangleSet()
				set:SetAdjacentTriangle(1, 2, 55)
				local a1, _, a3 = set:GetAdjacentTriangleVertexIndices(1)
				expect(a1).is(-1)
				expect(a3).is(2)
			end)

			test("can overwrite an existing adjacency value", function()
				local set = makeSquareTriangleSet()
				set:SetAdjacentTriangle(1, 3, 88)
				local _, _, a3 = set:GetAdjacentTriangleVertexIndices(1)
				expect(a3).is(88)
			end)
		end)

		describe("FindTriangleThatContainsPoint", function()
			test("returns a containing triangle from an explicit start", function()
				local set = makeSquareTriangleSet()
				local tri = set:FindTriangleThatContainsPoint(Vector2.new(0.2, 0.2), 1)
				expect(tri >= 1 and tri <= 2).is(true)
			end)

			test("uses the default starting triangle when omitted", function()
				local set = makeSquareTriangleSet()
				local tri = set:FindTriangleThatContainsPoint(Vector2.new(0.8, 0.8))
				expect(tri >= 1 and tri <= 2).is(true)
			end)

			test("accepts points on a shared diagonal", function()
				local set = makeSquareTriangleSet()
				local tri = set:FindTriangleThatContainsPoint(Vector2.new(0.5, 0.5), 1)
				expect(tri >= 1 and tri <= 2).is(true)
			end)
		end)

		describe("SetTriangleAdjacency", function()
			test("writes all three adjacency values", function()
				local set = makeSquareTriangleSet()
				set:SetTriangleAdjacency(1, { 7, 8, 9 })
				local a1, a2, a3 = set:GetAdjacentTriangleVertexIndices(1)
				expect(a1).is(7)
				expect(a2).is(8)
				expect(a3).is(9)
			end)

			test("overwrites existing adjacency values", function()
				local set = makeSquareTriangleSet()
				set:SetTriangleAdjacency(1, { 4, 5, 6 })
				set:SetTriangleAdjacency(1, { 1, 2, 3 })
				local a1, a2, a3 = set:GetAdjacentTriangleVertexIndices(1)
				expect(a1).is(1)
				expect(a2).is(2)
				expect(a3).is(3)
			end)

			test("does not affect other triangles", function()
				local set = makeSquareTriangleSet()
				set:SetTriangleAdjacency(1, { 7, 8, 9 })
				local a1, a2, a3 = set:GetAdjacentTriangleVertexIndices(2)
				expect(a1).is(1)
				expect(a2).is(-1)
				expect(a3).is(-1)
			end)
		end)

		describe("ReplaceAdjacent", function()
			test("replaces a matching adjacent triangle", function()
				local set = makeSquareTriangleSet()
				set:ReplaceAdjacent(1, 2, 42)
				local _, _, a3 = set:GetAdjacentTriangleVertexIndices(1)
				expect(a3).is(42)
			end)

			test("does nothing when the old adjacency is absent", function()
				local set = makeSquareTriangleSet()
				set:ReplaceAdjacent(1, 99, 42)
				local a1, a2, a3 = set:GetAdjacentTriangleVertexIndices(1)
				expect(a1).is(-1)
				expect(a2).is(-1)
				expect(a3).is(2)
			end)

			test("only replaces matching slots", function()
				local set = makeSquareTriangleSet()
				set:SetTriangleAdjacency(1, { 2, 2, 3 })
				set:ReplaceAdjacent(1, 2, 8)
				local a1, a2, a3 = set:GetAdjacentTriangleVertexIndices(1)
				expect(a1).is(8)
				expect(a2).is(8)
				expect(a3).is(3)
			end)
		end)

		describe("ReplaceTriangle", function()
			test("updates triangle vertices", function()
				local set = makeSquareTriangleSet()
				set:ReplaceTriangle(2, DelaunayTriangle.new(2, 3, 4, 5, 6, 7))
				local v1, v2, v3 = set:GetTriangleVertexIndices(2)
				expect(v1).is(2)
				expect(v2).is(3)
				expect(v3).is(4)
			end)

			test("updates triangle adjacency", function()
				local set = makeSquareTriangleSet()
				set:ReplaceTriangle(2, DelaunayTriangle.new(2, 3, 4, 5, 6, 7))
				local a1, a2, a3 = set:GetAdjacentTriangleVertexIndices(2)
				expect(a1).is(5)
				expect(a2).is(6)
				expect(a3).is(7)
			end)

			test("preserves overall triangle count", function()
				local set = makeSquareTriangleSet()
				set:ReplaceTriangle(2, DelaunayTriangle.new(2, 3, 4, 5, 6, 7))
				expect(set:GetTriangleCount()).is(2)
			end)
		end)

		describe("FindTriangleThatContainsLineEndpoint", function()
			test("finds a triangle for a cross-diagonal", function()
				local set = makeSquareTriangleSet()
				local tri = set:FindTriangleThatContainsLineEndpoint(2, 4)
				expect(tri ~= -1).is(true)
			end)

			test("returns -1 when the first endpoint is unknown", function()
				local set = makeSquareTriangleSet()
				expect(set:FindTriangleThatContainsLineEndpoint(99, 1)).is(-1)
			end)

			test("errors when endpointB index is invalid for a valid endpointA", function()
				local set = makeSquareTriangleSet()
				expect(function()
					set:FindTriangleThatContainsLineEndpoint(1, 99)
				end).fails()
			end)

			test("works when starting from a shared corner toward an interior point", function()
				local set = makeSquareTriangleSet()
				local interiorPointIndex = set:AddPoint(Vector2.new(0.15, 0.6))
				local tri = set:FindTriangleThatContainsLineEndpoint(1, interiorPointIndex)
				expect(tri).is_not(-1)
			end)
		end)

		describe("GetIntersectingEdges", function()
			test("detects an intersecting edge for a diagonal line", function()
				local set = makeSquareTriangleSet()
				local intersections =
					set:GetIntersectingEdges(set.Points[2], set.Points[4], 1, {} :: { DelaunayTriangleEdge })
				expect(#intersections > 0).is(true)
			end)

			test("appends into the provided output array", function()
				local set = makeSquareTriangleSet()
				local out = {} :: { DelaunayTriangleEdge }
				local result = set:GetIntersectingEdges(set.Points[2], set.Points[4], 1, out)
				expect(result).is(out)
			end)

			test("returns the shared diagonal as one of the intersections", function()
				local set = makeSquareTriangleSet()
				local intersections =
					set:GetIntersectingEdges(set.Points[2], set.Points[4], 1, {} :: { DelaunayTriangleEdge })
				local foundShared = false
				for _, edge in intersections do
					if
						(edge.EdgeVertexA == 1 and edge.EdgeVertexB == 3)
						or (edge.EdgeVertexA == 3 and edge.EdgeVertexB == 1)
					then
						foundShared = true
					end
				end
				expect(foundShared).is(true)
			end)
		end)
	end)
end
