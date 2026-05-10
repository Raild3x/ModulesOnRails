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

	describe("CreateNode", function()
		test("creates a node and increments the count", function()
			local tree = Quadtree.new(64)
			local n1 = tree:CreateNode(Vector2.new(0, 0), "A")
			local n2 = tree:CreateNode(Vector2.new(32, 24), "B")

			expect(tree:CountNodes()).is(2)
			expect(tree:FindFirstNode("A")).is(n1)
			expect(tree:FindFirstNode("B")).is(n2)
			expect(n1.Position).is(Vector2.new(0, 0))
			expect(n2.Position).is(Vector2.new(32, 24))
		end)
	end)

	describe("FindFirstNode", function()
		test("returns nil when the object is missing", function()
			local tree = Quadtree.new(64)
			tree:CreateNode(Vector2.new(0, 0), "A")

			expect(tree:FindFirstNode("missing")).is(nil)
		end)

		test("returns the first matching node", function()
			local tree = Quadtree.new(64)
			local first = tree:CreateNode(Vector2.new(0, 0), "A")
			tree:CreateNode(Vector2.new(32, 24), "B")
			local second = tree:CreateNode(Vector2.new(48, 48), "A")

			expect(tree:FindFirstNode("A")).is(first)
			expect(tree:FindFirstNode("B")).is_not(nil)
			expect(tree:FindFirstNode("A")).is_not(second)
		end)
	end)

	describe("RemoveNode", function()
		test("removes an existing node and reports success", function()
			local tree = Quadtree.new(64)
			local node = tree:CreateNode(Vector2.new(8, 8), "value")

			expect(tree:RemoveNode(node)).is(true)
			expect(tree:RemoveNode(node)).is(false)
			expect(tree:CountNodes()).is(0)
			expect(tree:FindFirstNode("value")).is(nil)
		end)

		test("does nothing when removing a stale node", function()
			local tree = Quadtree.new(64)
			local node = tree:CreateNode(Vector2.new(8, 8), "value")
			tree:RemoveNode(node)

			expect(tree:RemoveNode(node)).is(false)
			expect(tree:CountNodes()).is(0)
		end)
	end)

	describe("ChangeNodePosition", function()
		test("moves a node between regions", function()
			local tree = Quadtree.new(64)
			local node = tree:CreateNode(Vector2.new(0, 0), "moving")

			tree:ChangeNodePosition(node, Vector2.new(100, 0))

			local nearOld = tree:SearchRadius(Vector2.new(0, 0), 16)
			local nearNew = tree:SearchRadius(Vector2.new(100, 0), 16)
			expect(hasObject(nearOld, "moving")).is(false)
			expect(hasObject(nearNew, "moving")).is(true)
			expect(node.Position).is(Vector2.new(100, 0))
		end)

		test("keeps the node in place when the position is unchanged", function()
			local tree = Quadtree.new(64)
			local node = tree:CreateNode(Vector2.new(10, 10), "steady")

			tree:ChangeNodePosition(node, Vector2.new(10, 10))

			expect(tree:FindFirstNode("steady")).is(node)
			expect(tree:CountNodes()).is(1)
		end)
	end)

	describe("ClearAllNodes", function()
		test("removes every node from the tree", function()
			local tree = Quadtree.new(64)
			tree:CreateNode(Vector2.new(-10, -10), "A")
			tree:CreateNode(Vector2.new(10, 10), "B")

			tree:ClearAllNodes()

			expect(tree:CountNodes()).is(0)
			expect(#tree:GetAllNodes()).is(0)
		end)
	end)

	describe("GetAllNodes", function()
		test("returns all created nodes", function()
			local tree = Quadtree.new(64)
			tree:CreateNode(Vector2.new(0, 0), "A")
			tree:CreateNode(Vector2.new(64, 64), "B")

			local all = tree:GetAllNodes()
			expect(hasObject(all, "A")).is(true)
			expect(hasObject(all, "B")).is(true)
			expect(#all).is(2)
		end)
	end)

	describe("SearchRadius", function()
		test("returns only nodes inside the radius", function()
			local tree = Quadtree.new(64)
			tree:CreateNode(Vector2.new(0, 0), "center")
			tree:CreateNode(Vector2.new(3, 4), "near") -- distance 5
			tree:CreateNode(Vector2.new(20, 0), "far")

			local results = tree:SearchRadius(Vector2.new(0, 0), 6)
			expect(hasObject(results, "center")).is(true)
			expect(hasObject(results, "near")).is(true)
			expect(hasObject(results, "far")).is(false)
		end)

		test("returns an empty array when nothing is in range", function()
			local tree = Quadtree.new(64)
			tree:CreateNode(Vector2.new(100, 100), "far")

			local results = tree:SearchRadius(Vector2.new(0, 0), 10)
			expect(#results).is(0)
		end)
	end)

	describe("ForEachInRadius", function()
		test("iterates nodes inside the radius", function()
			local tree = Quadtree.new(64)
			tree:CreateNode(Vector2.new(1, 0), "insideA")
			tree:CreateNode(Vector2.new(2, 2), "insideB")
			tree:CreateNode(Vector2.new(50, 50), "outside")

			local values = collectIterator(tree:ForEachInRadius(Vector2.new(0, 0), 5))
			expect(hasObject(values, "insideA")).is(true)
			expect(hasObject(values, "insideB")).is(true)
			expect(hasObject(values, "outside")).is(false)
		end)

		test("returns no nodes when the radius misses every node", function()
			local tree = Quadtree.new(64)
			tree:CreateNode(Vector2.new(50, 50), "outside")

			local values = collectIterator(tree:ForEachInRadius(Vector2.new(0, 0), 5))
			expect(#values).is(0)
		end)
	end)

	describe("ForEachNode", function()
		test("iterates every node in the tree", function()
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

		test("returns an empty iterator for an empty tree", function()
			local tree = Quadtree.new(64)

			local iterated = collectIterator(tree:ForEachNode())
			expect(#iterated).is(0)
		end)
	end)

	describe("GetNearest", function()
		test("returns nodes sorted by distance", function()
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

		test("returns an empty array when no nodes are in range", function()
			local tree = Quadtree.new(64)
			tree:CreateNode(Vector2.new(100, 100), "far")

			local nearest = tree:GetNearest(Vector2.new(0, 0), 10)
			expect(#nearest).is(0)
		end)
	end)
end

return test_suite
