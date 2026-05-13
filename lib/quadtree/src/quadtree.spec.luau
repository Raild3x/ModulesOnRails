local test_suite = function(tiniest)
	local describe = tiniest.describe
	local test = tiniest.test
	local expect = tiniest.expect

	local Quadtree = require("./quadtree")
	print("Running Quadtree tests...", Quadtree)

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

		test("normalizes Vector3 input to Vector2 position", function()
			local tree = Quadtree.new(64)
			local node = tree:CreateNode(Vector3.new(12, 999, 34), "A")

			expect(node.Position).is(Vector2.new(12, 34))
			expect(tree:FindFirstNode("A")).is(node)
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

		test("removes empty top-level regions after deleting the last node", function()
			local tree = Quadtree.new(64)
			local node = tree:CreateNode(Vector2.new(1000, 0), "value")

			expect(tree:RemoveNode(node)).is(true)
			expect(tree:CountNodes()).is(0)

			local regions = (tree :: any).Regions
			local topRegionCount = 0
			for _ in pairs(regions) do
				topRegionCount += 1
			end
			expect(topRegionCount).is(0)
		end)

		test("does not retain empty top-level regions after moving then removing a node", function()
			local tree = Quadtree.new(64)
			local node = tree:CreateNode(Vector2.new(0, 0), "value")
			tree:ChangeNodePosition(node, Vector2.new(1000, 0))

			expect(tree:RemoveNode(node)).is(true)
			expect(tree:CountNodes()).is(0)

			local regions = (tree :: any).Regions
			local topRegionCount = 0
			for _ in pairs(regions) do
				topRegionCount += 1
			end
			expect(topRegionCount).is(0)
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

		test("excludes nodes exactly on the radius boundary", function()
			local tree = Quadtree.new(64)
			tree:CreateNode(Vector2.new(5, 0), "edge")

			local results = tree:SearchRadius(Vector2.new(0, 0), 5)
			expect(hasObject(results, "edge")).is(false)
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

		test("skips nodes exactly on the radius boundary", function()
			local tree = Quadtree.new(64)
			tree:CreateNode(Vector2.new(5, 0), "edge")

			local values = collectIterator(tree:ForEachInRadius(Vector2.new(0, 0), 5))
			expect(hasObject(values, "edge")).is(false)
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

		test("returns all matches when maxNodes exceeds the result count", function()
			local tree = Quadtree.new(64)
			tree:CreateNode(Vector2.new(1, 0), "n1")
			tree:CreateNode(Vector2.new(3, 0), "n2")

			local nearest = tree:GetNearest(Vector2.new(0, 0), 10, 10)
			expect(#nearest).is(2)
			expect(nearest[1].Object).is("n1")
			expect(nearest[2].Object).is("n2")
		end)

		test("returns an empty array when no nodes are in range", function()
			local tree = Quadtree.new(64)
			tree:CreateNode(Vector2.new(100, 100), "far")

			local nearest = tree:GetNearest(Vector2.new(0, 0), 10)
			expect(#nearest).is(0)
		end)
	end)

	describe("_getRegion", function()
		test("allocates Nodes on the requested maxLevel leaf", function()
			local tree = Quadtree.new(64)
			local region = (tree :: any):_getRegion(3, Vector2.new(10, 10))

			expect(region.Level).is(3)
			expect(region.Nodes).is_not(nil)
		end)

		test("supports maxLevel values greater than the default depth", function()
			local tree = Quadtree.new(64)
			local region = (tree :: any):_getRegion(5, Vector2.new(10, 10))

			expect(region.Level).is(5)
			expect(region.Nodes).is_not(nil)
		end)
	end)

	-- ── Cross-region and sub-region Radius correctness ──────────────────────────
	--
	-- The previous tests only placed nodes inside a single top-level grid cell,
	-- so the sub-region Radius value never affected which regions were visited—the
	-- per-node distance check always produced the right answer regardless of how
	-- wide the bounding circle was.
	--
	-- The Radius field is used in GetRegionsInRadius to prune sub-regions whose
	-- bounding circles do not overlap the search circle.  If Radius were larger
	-- than the true circumradius (√2·size/2) extra regions are scanned (wasted
	-- work).  If it were *smaller* valid regions could be pruned and in-radius
	-- nodes silently missed.
	--
	-- The tests below address three gaps:
	--   1. Cross-top-level-region traversal (nodes in different grid cells).
	--   2. Near-boundary geometry: a node inside the search radius whose leaf
	--      sub-region center is *outside* the search circle, so the bounding-circle
	--      overlap check is the only thing that prevents the region from being
	--      wrongly pruned.
	--   3. Correct exclusion of nodes that are just outside the search radius but
	--      share a sub-region with an in-radius node.
	-- ────────────────────────────────────────────────────────────────────────────

	describe("cross-region traversal", function()
		-- With topRegionSize=64, math.round(x/64)*64 determines the top-region
		-- grid cell.  Positions above ~32 or below ~-32 fall into adjacent cells.

		test("SearchRadius returns nodes from two adjacent top-level regions", function()
			local tree = Quadtree.new(64)
			-- math.round(10/64)*64 = 0  → top region (0,0)
			-- math.round(60/64)*64 = 64 → top region (64,0)
			tree:CreateNode(Vector2.new(10, 0), "A")
			tree:CreateNode(Vector2.new(60, 0), "B")
			tree:CreateNode(Vector2.new(200, 0), "C")
			local results = tree:SearchRadius(Vector2.new(35, 0), 30)
			-- A: dist 25 < 30 ✓   B: dist 25 < 30 ✓   C: dist 165 > 30 ✗

			expect(hasObject(results, "A")).is(true)
			expect(hasObject(results, "B")).is(true)
			expect(hasObject(results, "C")).is(false)
			expect(#results).is(2)
		end)

		test("SearchRadius spans positive and negative top-level regions", function()
			local tree = Quadtree.new(64)
			-- math.round(-33/64)*64 = -64 → top region (-64,0)
			-- math.round( 10/64)*64 =   0 → top region (0,0)
			tree:CreateNode(Vector2.new(-33, 0), "neg")
			tree:CreateNode(Vector2.new(10, 0), "pos")
			tree:CreateNode(Vector2.new(-200, 0), "far")

			local results = tree:SearchRadius(Vector2.new(0, 0), 34)
			expect(hasObject(results, "neg")).is(true) -- dist 33 < 34
			expect(hasObject(results, "pos")).is(true) -- dist 10 < 34
			expect(hasObject(results, "far")).is(false) -- dist 200 > 34
			expect(#results).is(2)
		end)

		test("SearchRadius finds nodes in all four diagonal top-level regions", function()
			local tree = Quadtree.new(64)
			-- Each node is at dist √(33²+33²) ≈ 46.67 from origin, in its own
			-- top-level grid cell (math.round(±33/64) = ±1).
			tree:CreateNode(Vector2.new(33, 33), "Q1") -- top region ( 64, 64)
			tree:CreateNode(Vector2.new(-33, 33), "Q2") -- top region (-64, 64)
			tree:CreateNode(Vector2.new(-33, -33), "Q3") -- top region (-64,-64)
			tree:CreateNode(Vector2.new(33, -33), "Q4") -- top region ( 64,-64)
			tree:CreateNode(Vector2.new(100, 0), "out")

			local results = tree:SearchRadius(Vector2.new(0, 0), 50)
			expect(hasObject(results, "Q1")).is(true)
			expect(hasObject(results, "Q2")).is(true)
			expect(hasObject(results, "Q3")).is(true)
			expect(hasObject(results, "Q4")).is(true)
			expect(hasObject(results, "out")).is(false)
			expect(#results).is(4)
		end)

		test("ForEachInRadius spans adjacent top-level regions", function()
			local tree = Quadtree.new(64)
			tree:CreateNode(Vector2.new(10, 0), "A") -- top region (0,0)
			tree:CreateNode(Vector2.new(60, 0), "B") -- top region (64,0)

			local values = collectIterator(tree:ForEachInRadius(Vector2.new(35, 0), 30))

			expect(hasObject(values, "A")).is(true)
			expect(hasObject(values, "B")).is(true)
			expect(#values).is(2)
		end)

		test("GetNearest returns cross-region nodes in ascending distance order", function()
			local tree = Quadtree.new(64)
			tree:CreateNode(Vector2.new(10, 0), "close") -- top region (0,0)
			tree:CreateNode(Vector2.new(60, 0), "far") -- top region (64,0)

			local nearest = tree:GetNearest(Vector2.new(0, 0), 100, 2)
			expect(#nearest).is(2)
			expect(nearest[1].Object).is("close") -- dist 10
			expect(nearest[2].Object).is("far") -- dist 60
		end)
	end)

	describe("sub-region bounding-radius correctness", function()
		-- topRegionSize=64, MAX_SUB_REGIONS=4 → leaf size = 64/2^3 = 8
		-- Leaf circumradius = √2·(8/2) = √2·4 ≈ 5.66
		--
		-- The critical geometry used here:
		--   A node at (24,0) lands in the leaf region centred at (28,−4).
		--   Distance from origin to that leaf centre ≈ 28.28.
		--   With search radius 27 the leaf centre is *outside* the search circle
		--   (28.28 > 27), so the bounding-circle overlap is the sole reason the
		--   leaf is scanned.  threshold = 27 + 5.66 = 32.66 > 28.28 → scanned ✓
		--   If Radius were 0 the leaf would be pruned and the node silently lost.

		test("node is found when its leaf sub-region center is outside the search circle", function()
			local tree = Quadtree.new(64)
			-- Leaf for (24,0): centre (28,−4), dist from origin ≈ 28.28 > 27
			tree:CreateNode(Vector2.new(24, 0), "target")

			local results = tree:SearchRadius(Vector2.new(0, 0), 27)
			expect(hasObject(results, "target")).is(true) -- dist 24 < 27 ✓
		end)

		test("node just outside search radius that shares a leaf with an in-radius node is excluded", function()
			-- (24,0) and (31,0) trace to the same leaf region.
			-- Only (24,0) is within radius 27; (31,0) must be excluded.
			local tree = Quadtree.new(64)
			tree:CreateNode(Vector2.new(24, 0), "inside")
			tree:CreateNode(Vector2.new(31, 0), "outside")

			local results = tree:SearchRadius(Vector2.new(0, 0), 27)
			expect(hasObject(results, "inside")).is(true)
			expect(hasObject(results, "outside")).is(false)
			expect(#results).is(1)
		end)

		test("node near the far corner of its leaf sub-region is still returned", function()
			-- The circumradius guarantees a node at any corner of its leaf region
			-- is never farther from the leaf centre than Radius.
			-- Place a node near (32,0)—boundary of the level-2 sub-region split—
			-- and verify it is found with a radius that just covers it.
			local tree = Quadtree.new(64)
			tree:CreateNode(Vector2.new(29, 0), "corner-near")
			tree:CreateNode(Vector2.new(31, 0), "corner-out")

			local results = tree:SearchRadius(Vector2.new(0, 0), 30)
			expect(hasObject(results, "corner-near")).is(true) -- dist 29 < 30
			expect(hasObject(results, "corner-out")).is(false) -- dist 31 > 30
		end)

		test("high-density cluster spanning multiple leaf sub-regions returns all in-radius nodes", function()
			-- Many nodes close together force the traversal to visit several
			-- distinct leaf regions.  All must be returned when the search radius
			-- covers all of them.
			local tree = Quadtree.new(64)
			local positions = {
				Vector2.new(1, 0),
				Vector2.new(-1, 0),
				Vector2.new(0, 1),
				Vector2.new(0, -1),
				Vector2.new(2, 2),
				Vector2.new(-2, 2),
				Vector2.new(2, -2),
				Vector2.new(-2, -2),
				Vector2.new(3, 0),
				Vector2.new(0, 3),
				Vector2.new(-3, 0),
				Vector2.new(0, -3),
			}
			for i, pos in ipairs(positions) do
				tree:CreateNode(pos, i)
			end

			-- Max distance across all positions is 3 (< 5), all must be found.
			local results = tree:SearchRadius(Vector2.new(0, 0), 5)

			expect(#results).is(#positions)
		end)

		test(
			"nodes outside the search radius in sub-regions the inflated Radius would have scanned are still excluded",
			function()
				-- This guards the correctness of the per-node check even when the
				-- bounding-circle pruning lets a region through.
				local tree = Quadtree.new(64)
				tree:CreateNode(Vector2.new(0, 0), "inside")
				tree:CreateNode(Vector2.new(60, 0), "outside") -- same top region as (64,0)... actually:
				-- math.round(60/64)=1 → top region (64,0).  dist=60 > 50.
				tree:CreateNode(Vector2.new(-60, 0), "outside2") -- top region (-64,0)

				local results = tree:SearchRadius(Vector2.new(0, 0), 50)
				expect(hasObject(results, "inside")).is(true)
				expect(hasObject(results, "outside")).is(false)
				expect(hasObject(results, "outside2")).is(false)
				expect(#results).is(1)
			end
		)

		test("Vector3 input produces correct cross-region results", function()
			local tree = Quadtree.new(64)
			-- Vector3: X/Z are used, Y is dropped
			tree:CreateNode(Vector3.new(10, 999, 0), "A") -- → (10,0), top region (0,0)
			tree:CreateNode(Vector3.new(60, 0, 0), "B") -- → (60,0), top region (64,0)
			local results = tree:SearchRadius(Vector2.new(35, 0), 30)

			expect(hasObject(results, "A")).is(true)
			expect(hasObject(results, "B")).is(true)
			expect(#results).is(2)
		end)
	end)
end

return test_suite
