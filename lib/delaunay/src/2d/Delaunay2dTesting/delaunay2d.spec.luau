--!strict

return function(t: tiniest)
	local Delaunay2d = require(script.Parent.Parent.Delaunay2d)

	local describe = t.describe
	local expect = t.expect
	local test = t.test

	local function sum(values: { number }): number
		if #values == 0 then
			return 0
		end

		local s = values[1]
		local err = 0
		for i = 2, #values do
			local k = values[i]
			local m = s + k
			if math.abs(s) >= math.abs(k) then
				err += s - m + k
			else
				err += k - m + s
			end
			s = m
		end
		return s + err
	end

	local function orient(p: Vector2, r: Vector2, q: Vector2): number
		local l = (r.Y - p.Y) * (q.X - p.X)
		local rr = (r.X - p.X) * (q.Y - p.Y)
		if math.abs(l - rr) >= 3.3306690738754716e-16 * math.abs(l + rr) then
			return l - rr
		end
		return 0
	end

	local function convex(r: Vector2, q: Vector2, p: Vector2): boolean
		local o1 = orient(p, r, q)
		if o1 ~= 0 then
			return o1 >= 0
		end
		local o2 = orient(r, q, p)
		if o2 ~= 0 then
			return o2 >= 0
		end
		return orient(q, p, r) >= 0
	end

	local function validate(points: { Vector2 }, triangulation: Delaunay2d.Delaunay2dObject?)
		local d = triangulation or Delaunay2d.new(points)
		local triangles = d:GetTriangles()
		local halfedges = d:GetHalfedges()
		local hull = d:GetHull()

		for i = 1, #halfedges do
			local twin = halfedges[i]
			expect(twin == -1 or halfedges[twin + 1] == (i - 1)).is(true)
		end

		if #hull >= 3 then
			local hullAreas = {}
			for i = 1, #hull do
				local j = (i == 1) and #hull or (i - 1)
				local p0 = points[hull[j] + 1]
				local p1 = points[hull[i] + 1]
				hullAreas[#hullAreas + 1] = (p1.X - p0.X) * (p1.Y + p0.Y)

				local pA = points[hull[j] + 1]
				local pB = points[hull[(j % #hull) + 1] + 1]
				local pC = points[hull[((j + 2) % #hull) + 1] + 1]
				expect(convex(pA, pB, pC)).is(true)
			end

			local triAreas = {}
			for i = 1, #triangles, 3 do
				local a = points[triangles[i] + 1]
				local b = points[triangles[i + 1] + 1]
				local c = points[triangles[i + 2] + 1]
				triAreas[#triAreas + 1] = math.abs((b.Y - a.Y) * (c.X - b.X) - (b.X - a.X) * (c.Y - b.Y))
			end

			local hullArea = sum(hullAreas)
			local trianglesArea = sum(triAreas)
			if hullArea ~= 0 then
				local err = math.abs((hullArea - trianglesArea) / hullArea)
				expect(err <= 2 ^ -45).is(true)
			end
		end
	end

	describe("Delaunay2d", function()
		test("returns empty triangulation for 0 points", function()
			local d = Delaunay2d.new {}
			expect(#d:GetTriangles()).is(0)
			expect(#d:GetHull()).is(0)
		end)

		test("returns empty triangulation for 1 point", function()
			local d = Delaunay2d.new { Vector2.new(5, 5) }
			expect(#d:GetTriangles()).is(0)
			expect(#d:GetHull()).is(1)
			expect(d:GetHull()[1]).is(0)
		end)

		test("returns empty triangulation for 2 points", function()
			local d = Delaunay2d.new { Vector2.new(1, 1), Vector2.new(2, 2) }
			expect(#d:GetTriangles()).is(0)
			expect(#d:GetHull()).is(2)
		end)

		test("returns empty triangulation for all-collinear input", function()
			local d = Delaunay2d.new {
				Vector2.new(0, 0),
				Vector2.new(1, 0),
				Vector2.new(3, 0),
				Vector2.new(2, 0),
			}
			expect(#d:GetTriangles()).is(0)
			expect(#d:GetHull()).is(4)
		end)

		test("produces valid triangulation on a basic point set", function()
			local points = {
				Vector2.new(0, 0),
				Vector2.new(1, 0),
				Vector2.new(2, 0.5),
				Vector2.new(1.25, 1.25),
				Vector2.new(0.5, 1.0),
				Vector2.new(-0.3, 0.4),
			}
			validate(points)
		end)

		test("supports update after coordinate mutation", function()
			local points = {
				Vector2.new(0, 0),
				Vector2.new(1, 0),
				Vector2.new(0, 1),
				Vector2.new(1, 1),
				Vector2.new(0.4, 0.6),
			}
			local d = Delaunay2d.new(points)
			validate(points, d)

			local coords = d:GetCoords()
			coords[1] = 2.5
			coords[2] = 0.2
			d:Update()

			local updatedPoints = {
				Vector2.new(2.5, 0.2),
				points[2],
				points[3],
				points[4],
				points[5],
			}
			validate(updatedPoints, d)
		end)

		test("triangulate static wrapper returns arrays", function()
			local result = Delaunay2d.Triangulate {
				Vector2.new(0, 0),
				Vector2.new(2, 0),
				Vector2.new(1, 1),
				Vector2.new(0.25, 0.8),
			}
			expect(result.Triangles).is_a("table")
			expect(result.Halfedges).is_a("table")
			expect(result.Hull).is_a("table")
		end)

		test("triangulate from 3d projects and triangulates", function()
			local result = Delaunay2d.TriangulateFrom3d({
				Vector3.new(0, 0, 0),
				Vector3.new(10, 0, 0),
				Vector3.new(8, 0, 7),
				Vector3.new(2, 0, 8),
				Vector3.new(5, 0, 4),
			}, Vector3.yAxis)
			expect(#result.Triangles > 0).is(true)
			expect(#result.Halfedges == #result.Triangles).is(true)
		end)

		test("edge helper returns valid point index pairs", function()
			local points = {
				Vector2.new(0, 0),
				Vector2.new(3, 0),
				Vector2.new(3, 2),
				Vector2.new(0, 2),
				Vector2.new(1.5, 1),
			}
			local d = Delaunay2d.new(points)
			local edges = d:GetEdges()
			expect(#edges > 0).is(true)
			for _, edge in edges do
				expect(edge[1] >= 0 and edge[1] < #points).is(true)
				expect(edge[2] >= 0 and edge[2] < #points).is(true)
			end
		end)
	end)
end
