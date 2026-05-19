--!strict

return function(t: tiniest)
	local NavMesh = require(script.Parent.Parent.NavMesh)

	local describe = t.describe
	local expect = t.expect
	local test = t.test

	describe("NavMesh", function()
		test("new starts empty", function()
			local mesh = NavMesh.new()
			expect(mesh:GetPointCount()).is(0)
			expect(#mesh:GetPoints()).is(0)
			mesh:Destroy()
		end)

		test("AddPoint increments count and accepts Vector3", function()
			local mesh = NavMesh.new()

			local idA = mesh:AddPoint(Vector2.new(0, 0), "a")
			local idB = mesh:AddPoint(Vector3.new(2, 0, 1), "b")

			expect(idA).is("a")
			expect(idB).is("b")
			expect(mesh:GetPointCount()).is(2)

			mesh:Destroy()
		end)

		test("RemovePointById updates count and returns false for missing id", function()
			local mesh = NavMesh.new()
			mesh:AddPoint(Vector2.new(0, 0), "a")
			mesh:AddPoint(Vector2.new(1, 0), "b")

			expect(mesh:RemovePointById("a")).is(true)
			expect(mesh:GetPointCount()).is(1)
			expect(mesh:RemovePointById("missing")).is(false)

			mesh:Destroy()
		end)

		test("GetTriangulation returns triangles for a simple square", function()
			local mesh = NavMesh.new()
			mesh:AddPoint(Vector2.new(0, 0), "a")
			mesh:AddPoint(Vector2.new(10, 0), "b")
			mesh:AddPoint(Vector2.new(10, 10), "c")
			mesh:AddPoint(Vector2.new(0, 10), "d")

			local triangles = mesh:GetTriangulation()
			expect(#triangles > 0).is(true)

			mesh:Destroy()
		end)

		test("AddHole and ClearAllHoles update merged holes cache", function()
			local mesh = NavMesh.new()
			mesh:AddPoint(Vector2.new(0, 0), "a")
			mesh:AddPoint(Vector2.new(20, 0), "b")
			mesh:AddPoint(Vector2.new(20, 20), "c")
			mesh:AddPoint(Vector2.new(0, 20), "d")

			local hole = {
				Vector2.new(5, 5),
				Vector2.new(8, 5),
				Vector2.new(6.5, 8),
			}

			local holeId = mesh:AddHole(hole, "hole-1")
			expect(holeId).is("hole-1")

			local merged = mesh:GetMergedHoles()
			expect(#merged).is(1)

			mesh:ClearAllHoles()
			expect(#mesh:GetMergedHoles()).is(0)

			mesh:Destroy()
		end)
	end)
end
