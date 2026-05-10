local Quadtree = require(script.Parent)

local test_suite = function(tiniest)
	local describe = tiniest.describe
	local test = tiniest.test
	local expect = tiniest.expect

	local function hasObject(nodes, object): boolean
		for _, node in ipairs(nodes) do
			if node.Object == object then
				return true
			end
		end
		return false
	end

	local function collectIterator<T>(iter: () -> T?): { T }
		local results = {}
		for value in iter do
			table.insert(results, value)
		end
		return results
	end

	describe("Quadtree", function()
		test("should create, find, and count nodes", function()
			local tree = Quadtree.new(64)
			local n1 = tree:CreateNode(Vector2.new(0, 0), "A")
			local n2 = tree:CreateNode(Vector2.new(32, 24), "B")

			expect(tree:CountNodes()).is(2)
			expect(tree:FindFirstNode("A")).is(n1)
			expect(tree:FindFirstNode("B")).is(n2)
			expect(tree:FindFirstNode("missing")).is(nil)
		end)

		test("should remove nodes and return removal status", function()
			local tree = Quadtree.new(64)
			local node = tree:CreateNode(Vector2.new(8, 8), "value")

			expect(tree:RemoveNode(node)).is(true)
			expect(tree:RemoveNode(node)).is(false)
			expect(tree:CountNodes()).is(0)
			expect(tree:FindFirstNode("value")).is(nil)
		end)

		test("should move nodes between regions", function()
			local tree = Quadtree.new(64)
			local node = tree:CreateNode(Vector2.new(0, 0), "moving")

			tree:ChangeNodePosition(node, Vector2.new(100, 0))

			local nearOld = tree:SearchRadius(Vector2.new(0, 0), 16)
			local nearNew = tree:SearchRadius(Vector2.new(100, 0), 16)
			expect(hasObject(nearOld, "moving")).is(false)
			expect(hasObject(nearNew, "moving")).is(true)
			expect(node.Position).is_shallow_equal(Vector2.new(100, 0))
		end)

		test("should clear all nodes", function()
			local tree = Quadtree.new(64)
			tree:CreateNode(Vector2.new(-10, -10), "A")
			tree:CreateNode(Vector2.new(10, 10), "B")

			tree:ClearAllNodes()

			expect(tree:CountNodes()).is(0)
			expect(#tree:GetAllNodes()).is(0)
		end)

		test("SearchRadius should return only nodes inside radius", function()
			local tree = Quadtree.new(64)
			tree:CreateNode(Vector2.new(0, 0), "center")
			tree:CreateNode(Vector2.new(3, 4), "near") -- distance 5
			tree:CreateNode(Vector2.new(20, 0), "far")

			local results = tree:SearchRadius(Vector2.new(0, 0), 6)
			expect(hasObject(results, "center")).is(true)
			expect(hasObject(results, "near")).is(true)
			expect(hasObject(results, "far")).is(false)
		end)

		test("ForEachInRadius should iterate matching nodes", function()
			local tree = Quadtree.new(64)
			tree:CreateNode(Vector2.new(1, 0), "insideA")
			tree:CreateNode(Vector2.new(2, 2), "insideB")
			tree:CreateNode(Vector2.new(50, 50), "outside")

			local values = collectIterator(tree:ForEachInRadius(Vector2.new(0, 0), 5))
			expect(hasObject(values, "insideA")).is(true)
			expect(hasObject(values, "insideB")).is(true)
			expect(hasObject(values, "outside")).is(false)
		end)

		test("ForEachNode should iterate all nodes", function()
			local tree = Quadtree.new(64)
			tree:CreateNode(Vector2.new(1, 1), 1)
			tree:CreateNode(Vector2.new(128, 128), 2)
			tree:CreateNode(Vector2.new(-64, -64), 3)

			local iterated = collectIterator(tree:ForEachNode())
			expect(hasObject(iterated, 1)).is(true)
			expect(hasObject(iterated, 2)).is(true)
			expect(hasObject(iterated, 3)).is(true)
			expect(#iterated).is(3)
		end)

		test("GetNearest should return sorted nearest nodes and obey maxNodes", function()
			local tree = Quadtree.new(64)
			tree:CreateNode(Vector2.new(1, 0), "n1")
			tree:CreateNode(Vector2.new(3, 0), "n2")
			tree:CreateNode(Vector2.new(6, 0), "n3")

			local nearest = tree:GetNearest(Vector2.new(0, 0), 10)
			expect(nearest[1].Object).is("n1")
			expect(nearest[2].Object).is("n2")
			expect(nearest[3].Object).is("n3")

			local topTwo = tree:GetNearest(Vector2.new(0, 0), 10, 2)
			expect(#topTwo).is(2)
			expect(topTwo[1].Object).is("n1")
			expect(topTwo[2].Object).is("n2")
		end)

		test("GetAllNodes should include every created node", function()
			local tree = Quadtree.new(64)
			tree:CreateNode(Vector2.new(0, 0), "A")
			tree:CreateNode(Vector2.new(64, 64), "B")

			local all = tree:GetAllNodes()
			expect(hasObject(all, "A")).is(true)
			expect(hasObject(all, "B")).is(true)
			expect(#all).is(2)
		end)
	end)
end

return test_suite
