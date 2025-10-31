local Heap = require("./init")

local test_suite = function(tiniest)
	local describe = tiniest.describe
	local test = tiniest.test
	local expect = tiniest.expect
	
	-- Utility function for efficient array removal (swap with last element)
	local function swapRemove(array, index)
		local lastIdx = #array
		array[index] = array[lastIdx]
		array[lastIdx] = nil
	end

	describe("Push", function()
		test("should insert elements in correct order for minHeap", function()
			local minHeap = Heap.min()
			minHeap:Push(5)
			minHeap:Push(2)
			minHeap:Push(8)
			expect(minHeap:Peek()).is(2)
		end)

		test("should insert elements in correct order for maxHeap", function()
			local maxHeap = Heap.max()
			maxHeap:Push(5)
			maxHeap:Push(2)
			maxHeap:Push(8)
			expect(maxHeap:Peek()).is(8)
		end)

		test("should maintain heap property with ascending insertions", function()
			local minHeap = Heap.min()
			for i = 1, 10 do
				minHeap:Push(i)
				expect(minHeap:Peek()).is(1) -- Min should always be 1
			end
			expect(#minHeap).is(10)
		end)

		test("should maintain heap property with descending insertions", function()
			local maxHeap = Heap.max()
			for i = 10, 1, -1 do
				maxHeap:Push(i)
				expect(maxHeap:Peek()).is(10) -- Max should always be 10
			end
			expect(#maxHeap).is(10)
		end)

		test("should handle duplicate values correctly", function()
			local minHeap = Heap.min()
			minHeap:Push(5)
			minHeap:Push(5)
			minHeap:Push(5)
			expect(#minHeap).is(3)
			expect(minHeap:Pop()).is(5)
			expect(minHeap:Pop()).is(5)
			expect(minHeap:Pop()).is(5)
		end)

		test("should handle random insertion order", function()
			local minHeap = Heap.min()
			local values = {7, 3, 9, 1, 5, 8, 2, 4, 6}
			for _, v in ipairs(values) do
				minHeap:Push(v)
			end
			expect(minHeap:Peek()).is(1)
			expect(#minHeap).is(9)
		end)

		test("should handle pushing with custom costs", function()
			local minHeap = Heap.min()
			minHeap:Push("High", 100)
			minHeap:Push("Low", 1)
			minHeap:Push("Medium", 50)
			
			local val, cost = minHeap:Peek()
			expect(val).is("Low")
			expect(cost).is(1)
		end)

		test("should handle negative values", function()
			local minHeap = Heap.min()
			minHeap:Push(-5)
			minHeap:Push(0)
			minHeap:Push(-10)
			minHeap:Push(5)
			
			expect(minHeap:Peek()).is(-10)
		end)
	end)

	describe("Pop", function()
		test("should remove and return elements in correct order for minHeap", function()
			local minHeap = Heap.min()
			minHeap:Push(3)
			minHeap:Push(1)
			minHeap:Push(4)
			expect(minHeap:Pop()).is(1)
			expect(minHeap:Pop()).is(3)
			expect(minHeap:Pop()).is(4)
		end)

		test("should remove and return elements in correct order for maxHeap", function()
			local maxHeap = Heap.max()
			maxHeap:Push(3)
			maxHeap:Push(1)
			maxHeap:Push(4)
			expect(maxHeap:Pop()).is(4)
			expect(maxHeap:Pop()).is(3)
			expect(maxHeap:Pop()).is(1)
		end)

		test("should return nil when popping from empty heap", function()
			local minHeap = Heap.min()
			local val, cost = minHeap:Pop()
			expect(val).is(nil)
			expect(cost).is(nil)
		end)

		test("should maintain correct size after pops", function()
			local minHeap = Heap.min()
			for i = 1, 5 do
				minHeap:Push(i)
			end
			expect(#minHeap).is(5)
			
			minHeap:Pop()
			expect(#minHeap).is(4)
			minHeap:Pop()
			expect(#minHeap).is(3)
			minHeap:Pop()
			minHeap:Pop()
			minHeap:Pop()
			expect(#minHeap).is(0)
		end)

		test("should handle alternating push and pop", function()
			local minHeap = Heap.min()
			minHeap:Push(5)
			minHeap:Push(3)
			expect(minHeap:Pop()).is(3)
			
			minHeap:Push(1)
			minHeap:Push(7)
			expect(minHeap:Pop()).is(1)
			expect(minHeap:Pop()).is(5)
			expect(minHeap:Pop()).is(7)
			expect(#minHeap).is(0)
		end)

		test("should maintain heap property after multiple pops", function()
			local minHeap = Heap.min()
			local values = {50, 30, 70, 20, 40, 60, 80, 10}
			for _, v in ipairs(values) do
				minHeap:Push(v)
			end
			
			-- Pop and verify each element comes out in sorted order
			expect(minHeap:Pop()).is(10)
			expect(minHeap:Pop()).is(20)
			expect(minHeap:Pop()).is(30)
			expect(minHeap:Pop()).is(40)
			expect(minHeap:Pop()).is(50)
			expect(minHeap:Pop()).is(60)
			expect(minHeap:Pop()).is(70)
			expect(minHeap:Pop()).is(80)
		end)

		test("should handle complex push/pop sequences", function()
			local maxHeap = Heap.max()
			
			-- Build up heap
			maxHeap:Push(5)
			maxHeap:Push(3)
			maxHeap:Push(7)
			expect(maxHeap:Peek()).is(7)
			
			-- Pop one
			expect(maxHeap:Pop()).is(7)
			expect(maxHeap:Peek()).is(5)
			
			-- Add more
			maxHeap:Push(9)
			maxHeap:Push(2)
			maxHeap:Push(8)
			expect(maxHeap:Peek()).is(9)
			
			-- Pop several
			expect(maxHeap:Pop()).is(9)
			expect(maxHeap:Pop()).is(8)
			expect(maxHeap:Peek()).is(5)
		end)

		test("should return both value and cost correctly", function()
			local minHeap = Heap.min()
			minHeap:Push("First", 10)
			minHeap:Push("Second", 5)
			minHeap:Push("Third", 15)
			
			local val1, cost1 = minHeap:Pop()
			expect(val1).is("Second")
			expect(cost1).is(5)
			
			local val2, cost2 = minHeap:Pop()
			expect(val2).is("First")
			expect(cost2).is(10)
			
			local val3, cost3 = minHeap:Pop()
			expect(val3).is("Third")
			expect(cost3).is(15)
		end)

		test("should handle popping all elements then pushing new ones", function()
			local minHeap = Heap.min()
			
			-- First batch
			minHeap:Push(5)
			minHeap:Push(3)
			minHeap:Push(7)
			
			-- Pop all
			minHeap:Pop()
			minHeap:Pop()
			minHeap:Pop()
			expect(#minHeap).is(0)
			
			-- Second batch
			minHeap:Push(2)
			minHeap:Push(6)
			minHeap:Push(4)
			
			expect(minHeap:Peek()).is(2)
			expect(#minHeap).is(3)
		end)

		test("should handle large number of pops in sorted order", function()
			local minHeap = Heap.min()
			local n = 100
			
			-- Insert random values
			local inserted = {}
			for i = 1, n do
				local val = math.random(1, 1000)
				minHeap:Push(val)
				table.insert(inserted, val)
			end
			table.sort(inserted)
			
			-- Pop all and verify sorted order
			local prev = -math.huge
			for i = 1, n do
				local val = minHeap:Pop()
				expect(val >= prev).is(true) -- Each value should be >= previous
				expect(val).is(inserted[i])
				prev = val
			end
		end)
	end)

	describe("Complex Sequences", function()
		test("should handle stress test with mixed operations", function()
			local minHeap = Heap.min()
			
			-- Build initial heap
			for i = 1, 20 do
				minHeap:Push(i * 2)
			end
			expect(#minHeap).is(20)
			
			-- Remove half
			for i = 1, 10 do
				minHeap:Pop()
			end
			expect(#minHeap).is(10)
			
			-- Add more
			for i = 1, 15 do
				minHeap:Push(i * 3)
			end
			expect(#minHeap).is(25)
			
			-- Verify heap property is maintained
			local prev = -math.huge
			for i = 1, 25 do
				local val = minHeap:Pop()
				expect(val >= prev).is(true)
				prev = val
			end
		end)

		test("should handle pattern of push-push-pop", function()
			local maxHeap = Heap.max()
			local expected = {}
			
			for round = 1, 10 do
				local val1 = round * 10
				local val2 = round * 10 + 5
				maxHeap:Push(val1)
				maxHeap:Push(val2)
				table.insert(expected, val1)
				table.insert(expected, val2)
				
				local popped = maxHeap:Pop()
				-- Remove the popped value from expected
				for i, v in ipairs(expected) do
					if v == popped then
						table.remove(expected, i)
						break
					end
				end
			end
			
			-- Verify remaining elements
			table.sort(expected, function(a, b) return a > b end)
			for _, expectedVal in ipairs(expected) do
				expect(maxHeap:Pop()).is(expectedVal)
			end
		end)

		test("should maintain correctness with interleaved operations", function()
			local minHeap = Heap.min()
			
			minHeap:Push(10)
			expect(minHeap:Peek()).is(10)
			
			minHeap:Push(5)
			expect(minHeap:Peek()).is(5)
			
			minHeap:Push(15)
			expect(minHeap:Peek()).is(5)
			
			expect(minHeap:Pop()).is(5)
			expect(minHeap:Peek()).is(10)
			
			minHeap:Push(3)
			expect(minHeap:Peek()).is(3)
			
			minHeap:Push(20)
			minHeap:Push(1)
			expect(minHeap:Peek()).is(1)
			
			expect(minHeap:Pop()).is(1)
			expect(minHeap:Pop()).is(3)
			expect(minHeap:Peek()).is(10)
		end)

		test("should handle emptying and refilling multiple times", function()
			local minHeap = Heap.min()
			
			for cycle = 1, 5 do
				-- Fill
				for i = 1, 10 do
					minHeap:Push(i + (cycle * 100))
				end
				expect(#minHeap).is(10)
				
				-- Verify min
				expect(minHeap:Peek()).is(1 + (cycle * 100))
				
				-- Empty
				for i = 1, 10 do
					minHeap:Pop()
				end
				expect(#minHeap).is(0)
			end
		end)

		test("should handle priority queue simulation", function()
			local taskQueue = Heap.min() -- Min heap for task priorities (lower = higher priority)
			
			-- Add tasks with different priorities
			taskQueue:Push("Critical Bug", 1)
			taskQueue:Push("Feature Request", 5)
			taskQueue:Push("Documentation", 8)
			taskQueue:Push("Urgent Fix", 2)
			taskQueue:Push("Code Review", 4)
			
			-- Process tasks in priority order
			local task1, priority1 = taskQueue:Pop()
			expect(task1).is("Critical Bug")
			expect(priority1).is(1)
			
			local task2, priority2 = taskQueue:Pop()
			expect(task2).is("Urgent Fix")
			expect(priority2).is(2)
			
			-- Add new high priority task
			taskQueue:Push("Security Issue", 0)
			
			local task3, priority3 = taskQueue:Pop()
			expect(task3).is("Security Issue")
			expect(priority3).is(0)
		end)

		test("should maintain heap invariant with zig-zag pattern", function()
			local minHeap = Heap.min()
			
			-- Zig-zag: high, low, high, low, etc.
			local values = {100, 1, 99, 2, 98, 3, 97, 4}
			for _, v in ipairs(values) do
				minHeap:Push(v)
			end
			
			-- Should come out in sorted order
			expect(minHeap:Pop()).is(1)
			expect(minHeap:Pop()).is(2)
			expect(minHeap:Pop()).is(3)
			expect(minHeap:Pop()).is(4)
		end)

		test("should handle mixed value types with costs", function()
			local minHeap = Heap.min()
			
			minHeap:Push({id = "A"}, 5)
			minHeap:Push({id = "B"}, 2)
			minHeap:Push({id = "C"}, 8)
			minHeap:Push({id = "D"}, 2) -- Duplicate cost
			
			local val1, cost1 = minHeap:Pop()
			expect(cost1).is(2)
			expect(val1.id == "B" or val1.id == "D").is(true)
			
			local val2, cost2 = minHeap:Pop()
			expect(cost2).is(2)
			expect(val2.id == "B" or val2.id == "D").is(true)
			
			local val3, cost3 = minHeap:Pop()
			expect(val3.id).is("A")
			expect(cost3).is(5)
		end)

		test("should handle partial sorting scenario", function()
			local minHeap = Heap.min()
			
			-- Insert unsorted data
			local data = {45, 12, 78, 23, 56, 89, 34, 67, 90, 11}
			for _, v in ipairs(data) do
				minHeap:Push(v)
			end
			
			-- Extract top 3 smallest
			local first = minHeap:Pop()
			local second = minHeap:Pop()
			local third = minHeap:Pop()
			
			expect(first).is(11)
			expect(second).is(12)
			expect(third).is(23)
			
			-- Rest should still be in heap
			expect(#minHeap).is(7)
			local nextVal = minHeap:Peek()
			expect(nextVal).is(34)
		end)
	end)

	describe("Peek", function()
		test("should return top element without removing it", function()
			local minHeap = Heap.min()
			minHeap:Push(7)
			minHeap:Push(2)
			expect(minHeap:Peek()).is(2)
			expect(#minHeap).is(2)
		end)

		test("equals Pop", function()
			local minHeap = Heap.min()
			minHeap:Push(7)
			minHeap:Push(2)
			expect(minHeap:Peek()).is(minHeap:Pop())
			expect(minHeap:Peek() == minHeap:Pop())
		end)
	end)

	describe("Has", function()
		test("should return true if value exists in heap", function()
			local minHeap = Heap.min()
			minHeap:Push(5)
			minHeap:Push(3)
			expect(minHeap:Has(3)).is(true)
			expect(minHeap:Has(10)).is(false)
		end)

		test("should return false for empty heap", function()
			local minHeap = Heap.min()
			expect(minHeap:Has(3)).is(false)
		end)

		test("Should return true if a value exists in a large heap after many values are removed", function()
			local minHeap = Heap.min()
			for i = 1, 100000 do
				minHeap:Push(i)
			end
			for i = 1, 99900 do
				minHeap:Pop()
			end
			print(minHeap)
			expect(minHeap:Has(100000)).is(true)
		end)

		test("should allow for a cost argument", function()
			local minHeap = Heap.min()
			minHeap:Push("B", 5)
			minHeap:Push("B", 10)
			minHeap:Push("B", 15)
			expect(minHeap:Has("B")).is(true)
			expect(minHeap:Has("B", 5)).is(true)
			expect(minHeap:Has("B", 10)).is(true)
			expect(minHeap:Has("B", 15)).is(true)
			expect(minHeap:Has("B", 20)).is(false)
		end)

		-- test("Should work with a custom search function", function()
		-- 	local minHeap = Heap.min()
		-- 	minHeap:Push(5)
		-- 	minHeap:Push(3)
		-- 	expect(minHeap:Has(function(a) return a == 3 end)).is(true)
		-- 	expect(minHeap:Has(function(a, b) return b > 5  end)).is(false)
		-- 	expect(minHeap:Has(function(a, b) return a > b end)).is(false)
		-- end)
	end)

	describe("UpdateCost", function()
		test("should update the cost of a value", function()
			local minHeap = Heap.min()
			minHeap:Push("A", 5)
			minHeap:Push("B", 3)
			minHeap:UpdateCost("A", 2)
			expect(minHeap:GetCost("A")).is(2)
		end)

		test("should not update cost if value does not exist", function()
			local minHeap = Heap.min()
			minHeap:Push("A", 5)
			local didUpdate = minHeap:UpdateCost("B", 3)
			expect(minHeap:Peek()).is("A")
			expect(didUpdate).is(false)
			expect(minHeap:GetCost("B")).is(nil)
		end)

		test("should maintain heap order after updating cost", function()
			local minHeap = Heap.min()
			minHeap:Push(5)
			minHeap:Push(3)
			minHeap:UpdateCost(5, 1)
			local v, c = minHeap:Peek()
			expect(v).is(5)
			expect(c).is(1)
		end)

		test("should allow for a function instead of a value as its search arg", function()
			local minHeap = Heap.min()
			minHeap:Push(5)
			minHeap:Push(3)
			minHeap:UpdateCost(function(a) return a == 3 end, 1)
			local v, c = minHeap:Peek()
			expect(v).is(3)
			expect(c).is(1)
		end)

		test("should allow for a function instead of a number as its cost arg", function()
			local minHeap = Heap.min()
			minHeap:Push(5)
			minHeap:Push(3)
			minHeap:UpdateCost(3, function(a) return a + 1 end)
			local v, c = minHeap:Peek()
			expect(v).is(3)
			expect(c).is(4)
		end)

		test("should pass value and oldCost correctly to cost function", function()
			local minHeap = Heap.min()
			minHeap:Push("A", 10)
			minHeap:Push("B", 5)
			
			-- Update "A" with a function that uses both value and oldCost
			-- Expected signature: function(value, oldCost)
			minHeap:UpdateCost("A", function(value, oldCost)
				expect(value).is("A") -- First param should be the value
				expect(oldCost).is(10) -- Second param should be the old cost
				return oldCost + 5 -- New cost should be 15
			end)
			
			local cost = minHeap:GetCost("A")
			expect(cost).is(15)
		end)

		test("should pass correct parameters when value and cost are different types", function()
			local minHeap = Heap.min()
			minHeap:Push(100, 1) -- number value, number cost (different values)
			minHeap:Push(200, 2)
			
			minHeap:UpdateCost(100, function(value, oldCost)
				expect(value).is(100) -- Value should be 100
				expect(oldCost).is(1) -- Cost should be 1
				return oldCost * 10 -- New cost should be 10
			end)
			
			expect(minHeap:GetCost(100)).is(10)
		end)

		test("should update multiple occurrences when updateAll is true", function()
			local minHeap = Heap.min()
			minHeap:Push("A", 5)
			minHeap:Push("A", 10)
			minHeap:Push("A", 15)
			minHeap:Push("B", 3)
			
			local updateCount = 0
			minHeap:UpdateCost("A", function(value, oldCost)
				updateCount += 1
				return oldCost + 1
			end, true) -- updateAll = true
			
			expect(updateCount).is(3) -- Should have updated all 3 "A" values
			
			-- Verify all costs were updated
			local foundCosts = {}
			for value, cost in minHeap do
				if value == "A" then
					table.insert(foundCosts, cost)
				end
			end
			table.sort(foundCosts)
			expect(foundCosts[1]).is(6)  -- 5 + 1
			expect(foundCosts[2]).is(11) -- 10 + 1
			expect(foundCosts[3]).is(16) -- 15 + 1
		end)

		test("should only update first occurrence when updateAll is false", function()
			local minHeap = Heap.min()
			minHeap:Push("A", 5)
			minHeap:Push("A", 10)
			minHeap:Push("A", 15)
			
			local updateCount = 0
			minHeap:UpdateCost("A", function(value, oldCost)
				updateCount += 1
				return 1 -- Set to 1
			end, false) -- updateAll = false
			
			expect(updateCount).is(1) -- Should have updated only 1 "A" value
		end)

		test("should work with function selector and function cost", function()
			local minHeap = Heap.min()
			minHeap:Push(5, 50)
			minHeap:Push(10, 100)
			minHeap:Push(15, 150)
			
			minHeap:UpdateCost(
				function(value) return value > 7 end, -- Select values > 7
				function(value, oldCost)
					expect(value >= 10).is(true) -- Should only match 10 or 15
					return oldCost / 10 -- Divide cost by 10
				end,
				true -- Update all matches
			)
			
			-- Values 10 and 15 should have updated costs
			expect(minHeap:GetCost(5)).is(50)  -- Unchanged
			expect(minHeap:GetCost(10)).is(10) -- 100 / 10
			expect(minHeap:GetCost(15)).is(15) -- 150 / 10
		end)

		test("should maintain heap order after cost function update", function()
			local maxHeap = Heap.max()
			maxHeap:Push("A", 5)
			maxHeap:Push("B", 10)
			maxHeap:Push("C", 15)
			
			-- Make A have the highest cost
			maxHeap:UpdateCost("A", function(value, oldCost)
				return 20
			end)
			
			local topValue, topCost = maxHeap:Peek()
			expect(topValue).is("A")
			expect(topCost).is(20)
		end)

		test("should not update if cost function returns same cost", function()
			local minHeap = Heap.min()
			minHeap:Push("A", 10)
			minHeap:Push("B", 5)
			
			local didUpdate = minHeap:UpdateCost("A", function(value, oldCost)
				return oldCost -- Return the same cost
			end)
			
			expect(didUpdate).is(false) -- Should return false since cost didn't change
			expect(minHeap:GetCost("A")).is(10)
		end)

		test("should handle cost function with complex calculations", function()
			local minHeap = Heap.min()
			minHeap:Push({name = "Alice", age = 30}, 100)
			minHeap:Push({name = "Bob", age = 25}, 200)
			
			minHeap:UpdateCost(
				function(value) return value.name == "Alice" end,
				function(value, oldCost)
					-- Complex calculation using both params
					return oldCost + value.age * 2
				end
			)
			
			local aliceEntry = nil
			for value, cost in minHeap do
				if value.name == "Alice" then
					aliceEntry = {value, cost}
					break
				end
			end
			
			expect(aliceEntry[2]).is(160) -- 100 + 30 * 2
		end)

		test("should handle updating in max heap correctly", function()
			local maxHeap = Heap.max()
			maxHeap:Push("X", 50)
			maxHeap:Push("Y", 30)
			maxHeap:Push("Z", 40)
			
			-- Before update, X should be on top
			local topValue, topCost = maxHeap:Peek()
			expect(topValue).is("X")
			expect(topCost).is(50)
			
			maxHeap:UpdateCost("Y", function(value, oldCost)
				expect(value).is("Y")
				expect(oldCost).is(30)
				return 60 -- Make Y the new maximum
			end)
			
			-- After update, Y should be on top
			topValue, topCost = maxHeap:Peek()
			expect(topValue).is("Y")
			expect(topCost).is(60)
		end)

		test("should handle edge case where all values match selector", function()
			local minHeap = Heap.min()
			minHeap:Push("A", 10)
			minHeap:Push("A", 20)
			minHeap:Push("A", 30)
			
			local callCount = 0
			minHeap:UpdateCost(
				function(value) return value == "A" end,
				function(value, oldCost)
					callCount += 1
					return oldCost + 5
				end,
				true
			)
			
			expect(callCount).is(3)
			local topValue, topCost = minHeap:Peek()
			expect(topValue).is("A")
			expect(topCost).is(15) -- 10 + 5 should be minimum
		end)
	end)

	describe("GetCost", function()
		test("should return the cost of a value", function()
			local minHeap = Heap.min()
			minHeap:Push("A", 5)
			minHeap:Push("B", 3)
			expect(minHeap:GetCost("A")).is(5)
			expect(minHeap:GetCost("B")).is(3)
			expect(minHeap:GetCost("C")).is(nil)
		end)

		test("should return nil for empty heap", function()
			local minHeap = Heap.min()
			expect(minHeap:GetCost(3)).is(nil)
		end)
	end)

	describe("CountOccurrences", function()
		test("should count occurrences of a value", function()
			local minHeap = Heap.min()
			minHeap:Push(5)
			minHeap:Push(3)
			minHeap:Push(8)
			minHeap:Push(3)
			expect(minHeap:CountOccurrences(3)).is(2)
			expect(minHeap:CountOccurrences(5)).is(1)
			expect(minHeap:CountOccurrences(10)).is(0)
		end)

		test("should return 0 for empty heap", function()
			local minHeap = Heap.min()
			expect(minHeap:CountOccurrences(3)).is(0)
		end)

		-- test("should ")
	end)

	describe("RemoveFirstOccurrence", function()
		test("should remove the first occurrence of a value", function()
			local minHeap = Heap.min()
			minHeap:Push(5)
			minHeap:Push(3)
			minHeap:Push(8)
			minHeap:Push(3)
			expect(minHeap:RemoveFirstOccurrence(3)).is(true)
			expect(minHeap:RemoveFirstOccurrence(3)).is(true)
			expect(minHeap:RemoveFirstOccurrence(3)).is(false)
		end)

		test("should maintain heap order after removals", function()
			local minHeap = Heap.min()
			minHeap:Push(5)
			minHeap:Push(3)
			minHeap:Push(8)
			minHeap:Push(3)
			minHeap:Push(10)
			minHeap:RemoveFirstOccurrence(3)
			expect(minHeap:Peek()).is(3)
			minHeap:RemoveFirstOccurrence(3)
			expect(minHeap:Peek()).is(5)
		end)

		test("should successfully remove all occurrences", function()
			local newHeap = Heap.max()

			-- Add 10 items
			for count = 1, 10, 1 do
				local heapId = "TestHeap_" .. tostring(count)
				newHeap:Push(heapId, count * 10)
			end
			
			expect(#newHeap).is(10)

			-- Remove all 10 items
			for count = 1, 10, 1 do
				local heapId = "TestHeap_" .. tostring(count)
				local removed = newHeap:RemoveFirstOccurrence(heapId)
				expect(removed).is(true)
			end
			
			-- Heap should be empty
			expect(#newHeap).is(0)
			expect(newHeap:Peek()).is(nil)
		end)

		test("should return false when removing non-existent value", function()
			local minHeap = Heap.min()
			minHeap:Push(5)
			minHeap:Push(3)
			minHeap:Push(8)
			expect(minHeap:RemoveFirstOccurrence(99)).is(false)
			expect(#minHeap).is(3)
		end)

		test("should return false when removing from empty heap", function()
			local minHeap = Heap.min()
			expect(minHeap:RemoveFirstOccurrence(5)).is(false)
		end)

		test("should maintain heap property after removing root", function()
			local minHeap = Heap.min()
			minHeap:Push(1)
			minHeap:Push(3)
			minHeap:Push(2)
			minHeap:Push(7)
			minHeap:Push(5)
			
			expect(minHeap:Peek()).is(1)
			minHeap:RemoveFirstOccurrence(1)
			expect(minHeap:Peek()).is(2)
			
			-- Verify all remaining elements come out in sorted order
			expect(minHeap:Pop()).is(2)
			expect(minHeap:Pop()).is(3)
			expect(minHeap:Pop()).is(5)
			expect(minHeap:Pop()).is(7)
		end)

		test("should maintain heap property after removing middle element", function()
			local minHeap = Heap.min()
			for i = 1, 10 do
				minHeap:Push(i)
			end
			
			-- Remove middle value
			minHeap:RemoveFirstOccurrence(5)
			expect(#minHeap).is(9)
			
			-- Verify heap property maintained (all elements in sorted order)
			local prev = -math.huge
			for i = 1, 9 do
				local val = minHeap:Pop()
				expect(val > prev).is(true)
				prev = val
			end
		end)

		test("should maintain heap property after removing leaf element", function()
			local maxHeap = Heap.max()
			maxHeap:Push(10)
			maxHeap:Push(8)
			maxHeap:Push(9)
			maxHeap:Push(5)
			maxHeap:Push(7)
			maxHeap:Push(6)
			maxHeap:Push(3)
			
			-- Remove a leaf (3 should be a leaf)
			maxHeap:RemoveFirstOccurrence(3)
			expect(#maxHeap).is(6)
			expect(maxHeap:Peek()).is(10)
			
			-- Verify all elements come out in correct order
			local prev = math.huge
			for i = 1, 6 do
				local val = maxHeap:Pop()
				expect(val <= prev).is(true)
				prev = val
			end
		end)

		test("should handle removing last remaining element", function()
			local minHeap = Heap.min()
			minHeap:Push(42)
			
			expect(minHeap:RemoveFirstOccurrence(42)).is(true)
			expect(#minHeap).is(0)
			expect(minHeap:Peek()).is(nil)
			expect(minHeap:IsEmpty()).is(true)
		end)

		test("should handle removal with duplicate values at different positions", function()
			local minHeap = Heap.min()
			minHeap:Push("A", 5)
			minHeap:Push("B", 3)
			minHeap:Push("A", 7)
			minHeap:Push("A", 2)
			minHeap:Push("C", 6)
			
			-- Peek should be "A" with cost 2
			local peekVal, peekCost = minHeap:Peek()
			expect(peekVal).is("A")
			expect(peekCost).is(2)
			
			-- Remove first occurrence of "A" (should remove one of them)
			minHeap:RemoveFirstOccurrence("A")
			expect(#minHeap).is(4)
			
			-- After removal, top could be B(3) or A(5) depending on which A was removed
			local _topVal, topCost = minHeap:Peek()
			expect(topCost <= 5).is(true) -- Cost should be reasonable
			
			-- Remove another "A"
			minHeap:RemoveFirstOccurrence("A")
			expect(#minHeap).is(3)
			
			-- One more "A" should still exist
			expect(minHeap:Has("A")).is(true)
			
			-- Remove the last "A"
			minHeap:RemoveFirstOccurrence("A")
			expect(#minHeap).is(2)
			expect(minHeap:Has("A")).is(false)
		end)

		test("should work correctly after multiple mixed operations", function()
			local minHeap = Heap.min()
			
			-- Build heap
			for i = 1, 20 do
				minHeap:Push(i)
			end
			
			-- Remove some elements
			minHeap:RemoveFirstOccurrence(5)
			minHeap:RemoveFirstOccurrence(10)
			minHeap:RemoveFirstOccurrence(15)
			expect(#minHeap).is(17)
			
			-- Add more elements
			minHeap:Push(25)
			minHeap:Push(30)
			expect(#minHeap).is(19)
			
			-- Verify heap property
			local prev = -math.huge
			for i = 1, 19 do
				local val = minHeap:Pop()
				expect(val > prev).is(true)
				prev = val
			end
		end)

		test("should handle removal with custom cost values", function()
			local minHeap = Heap.min()
			local item1 = {id = 1}
			local item2 = {id = 2}
			local item3 = {id = 3}
			local item4 = {id = 4}
			
			minHeap:Push(item1, 10)
			minHeap:Push(item2, 5)
			minHeap:Push(item3, 15)
			minHeap:Push(item4, 3)
			
			-- Remove item2 by reference
			minHeap:RemoveFirstOccurrence(item2)
			
			expect(#minHeap).is(3)
			local val, cost = minHeap:Peek()
			expect(val.id).is(4)
			expect(cost).is(3)
		end)
	end)

	describe("RemoveAllOccurrences", function()
		test("should remove all occurrences of a value", function()
			local minHeap = Heap.min()
			minHeap:Push(5)
			minHeap:Push(3)
			minHeap:Push(8)
			minHeap:Push(3)
			minHeap:Push(3)
			minHeap:Push(10)
			expect(minHeap:RemoveAllOccurrences(3)).is(3)
			expect(#minHeap).is(3)
			expect(minHeap:RemoveAllOccurrences(3)).is(0)
			expect(#minHeap).is(3)
		end)

		test("should return 0 when value doesn't exist", function()
			local minHeap = Heap.min()
			minHeap:Push(5)
			minHeap:Push(3)
			minHeap:Push(8)
			expect(minHeap:RemoveAllOccurrences(99)).is(0)
			expect(#minHeap).is(3)
		end)

		test("should maintain heap property after removing all occurrences", function()
			local minHeap = Heap.min()
			minHeap:Push("A", 1)
			minHeap:Push("B", 2)
			minHeap:Push("A", 3)
			minHeap:Push("C", 4)
			minHeap:Push("A", 5)
			minHeap:Push("D", 6)
			
			expect(minHeap:RemoveAllOccurrences("A")).is(3)
			expect(#minHeap).is(3)
			
			-- Remaining elements should be in sorted order
			expect(minHeap:Pop()).is("B")
			expect(minHeap:Pop()).is("C")
			expect(minHeap:Pop()).is("D")
		end)

		test("should handle removing all elements", function()
			local minHeap = Heap.min()
			minHeap:Push("X", 1)
			minHeap:Push("X", 2)
			minHeap:Push("X", 3)
			
			expect(minHeap:RemoveAllOccurrences("X")).is(3)
			expect(#minHeap).is(0)
			expect(minHeap:IsEmpty()).is(true)
			expect(minHeap:Peek()).is(nil)
		end)

		test("should handle large number of duplicates", function()
			local maxHeap = Heap.max()
			
			-- Add 50 duplicates mixed with other values
			for i = 1, 50 do
				maxHeap:Push("DUP", i)
				maxHeap:Push("OTHER", i + 100)
			end
			
			expect(#maxHeap).is(100)
			expect(maxHeap:RemoveAllOccurrences("DUP")).is(50)
			expect(#maxHeap).is(50)
			
			-- Verify all remaining are "OTHER"
			for i = 1, 50 do
				local val = maxHeap:Pop()
				expect(val).is("OTHER")
			end
		end)

		test("should work correctly with interleaved duplicates", function()
			local minHeap = Heap.min()
			-- Create pattern: A, B, A, C, A, D
			minHeap:Push("A", 1)
			minHeap:Push("B", 2)
			minHeap:Push("A", 3)
			minHeap:Push("C", 4)
			minHeap:Push("A", 5)
			minHeap:Push("D", 6)
			
			expect(minHeap:RemoveAllOccurrences("A")).is(3)
			expect(#minHeap).is(3)
			
			-- Verify remaining structure
			expect(minHeap:Has("A")).is(false)
			expect(minHeap:Has("B")).is(true)
			expect(minHeap:Has("C")).is(true)
			expect(minHeap:Has("D")).is(true)
		end)

		test("should maintain heap property after complex removal", function()
			local minHeap = Heap.min()
			
			-- Build heap with many duplicates
			for i = 1, 10 do
				minHeap:Push("REMOVE", i)
				minHeap:Push("KEEP", i + 100)
			end
			
			local removed = minHeap:RemoveAllOccurrences("REMOVE")
			expect(removed).is(10)
			expect(#minHeap).is(10)
			
			-- All remaining should be in sorted order
			local prev = -math.huge
			for i = 1, 10 do
				local val, cost = minHeap:Pop()
				expect(val).is("KEEP")
				expect(cost > prev).is(true)
				prev = cost
			end
		end)

		test("should handle empty heap", function()
			local minHeap = Heap.min()
			expect(minHeap:RemoveAllOccurrences("anything")).is(0)
		end)

		test("should work after push/pop/remove cycles", function()
			local maxHeap = Heap.max()
			
			-- Cycle 1: Add and remove some
			for i = 1, 10 do
				maxHeap:Push("A", i)
			end
			maxHeap:RemoveAllOccurrences("A")
			expect(#maxHeap).is(0)
			
			-- Cycle 2: Add different values
			for i = 1, 5 do
				maxHeap:Push("B", i)
				maxHeap:Push("C", i + 10)
			end
			expect(#maxHeap).is(10)
			
			-- Remove one type
			expect(maxHeap:RemoveAllOccurrences("B")).is(5)
			expect(#maxHeap).is(5)
			
			-- Verify remaining
			for i = 1, 5 do
				local val = maxHeap:Pop()
				expect(val).is("C")
			end
		end)
	end)

	describe("Edge Cases and Stress Tests", function()
		test("should handle alternating push and remove operations", function()
			local minHeap = Heap.min()
			
			for round = 1, 10 do
				-- Add 5 elements
				for i = 1, 5 do
					minHeap:Push(round * 10 + i)
				end
				
				-- Remove 2 elements
				minHeap:RemoveFirstOccurrence(round * 10 + 2)
				minHeap:RemoveFirstOccurrence(round * 10 + 4)
			end
			
			-- Should have 30 elements left (50 added - 20 removed)
			expect(#minHeap).is(30)
			
			-- Verify heap property
			local prev = -math.huge
			while #minHeap > 0 do
				local val = minHeap:Pop()
				expect(val > prev).is(true)
				prev = val
			end
		end)

		test("should handle removing elements with same cost", function()
			local minHeap = Heap.min()
			minHeap:Push("A", 5)
			minHeap:Push("B", 5)
			minHeap:Push("C", 5)
			minHeap:Push("D", 3)
			minHeap:Push("E", 7)
			
			minHeap:RemoveFirstOccurrence("B")
			expect(#minHeap).is(4)
			
			-- Verify heap is still valid
			expect(minHeap:Peek()).is("D") -- Should be D with cost 3
			minHeap:Pop()
			
			local val = minHeap:Peek()
			expect(val == "A" or val == "C").is(true) -- One of the cost-5 elements
		end)

		test("should handle remove after UpdateCost", function()
			local minHeap = Heap.min()
			minHeap:Push("A", 10)
			minHeap:Push("B", 5)
			minHeap:Push("C", 15)
			
			-- Update cost then remove
			minHeap:UpdateCost("B", 20)
			minHeap:RemoveFirstOccurrence("B")
			
			expect(#minHeap).is(2)
			expect(minHeap:Peek()).is("A")
		end)

		test("should handle stress test with random operations", function()
			local minHeap = Heap.min()
			local existingValues = {}
			
			-- Perform 100 random operations
			for i = 1, 100 do
				local op = math.random(1, 3)
				
				if op == 1 or #existingValues == 0 then
					-- Push
					local val = math.random(1, 50)
					minHeap:Push(val)
					table.insert(existingValues, val)
				elseif op == 2 and #existingValues > 0 then
					-- Pop
					minHeap:Pop()
					table.remove(existingValues, 1)
				else
					-- Remove random existing value
					if #existingValues > 0 then
						local idx = math.random(1, #existingValues)
						local val = existingValues[idx]
						minHeap:RemoveFirstOccurrence(val)
						table.remove(existingValues, idx)
					end
				end
			end
			
			-- Verify heap is still valid by popping all elements
			local prev = -math.huge
			while #minHeap > 0 do
				local val = minHeap:Pop()
				expect(val >= prev).is(true)
				prev = val
			end
		end)

		test("should handle removing all elements one by one", function()
			local maxHeap = Heap.max()
			local values = {}
			
			for i = 1, 20 do
				local val = "Item_" .. i
				maxHeap:Push(val, i)
				table.insert(values, val)
			end
			
			-- Remove all in random order
			for i = #values, 1, -1 do
				local idx = math.random(1, i)
				local val = values[idx]
				expect(maxHeap:RemoveFirstOccurrence(val)).is(true)
				table.remove(values, idx)
				
				-- Verify heap property maintained after each removal
				if #maxHeap > 0 then
					local peek = maxHeap:Peek()
					expect(peek).never_is(nil)
				end
			end
			
			expect(#maxHeap).is(0)
		end)

		test("should handle remove on heap with negative costs", function()
			local minHeap = Heap.min()
			minHeap:Push("A", -10)
			minHeap:Push("B", -5)
			minHeap:Push("C", 0)
			minHeap:Push("D", 5)
			
			expect(minHeap:Peek()).is("A")
			minHeap:RemoveFirstOccurrence("A")
			expect(minHeap:Peek()).is("B")
			minHeap:RemoveFirstOccurrence("B")
			expect(minHeap:Peek()).is("C")
		end)

		test("should handle remove with very large heap", function()
			local minHeap = Heap.min()
			
			-- Build large heap
			for i = 1, 1000 do
				minHeap:Push(i)
			end
			
			-- Remove several elements from different positions
			minHeap:RemoveFirstOccurrence(1)    -- root
			minHeap:RemoveFirstOccurrence(500)  -- middle
			minHeap:RemoveFirstOccurrence(1000) -- likely a leaf
			minHeap:RemoveFirstOccurrence(250)  -- another middle
			
			expect(#minHeap).is(996)
			
			-- Verify heap property still holds
			local prev = -math.huge
			for i = 1, 996 do
				local val = minHeap:Pop()
				expect(val > prev).is(true)
				prev = val
			end
		end)

		test("should maintain correctness with mixed value types", function()
			local minHeap = Heap.min()
			local items = {}
			
			-- Add different table values with same structure, keep references
			for i = 1, 10 do
				local item = {id = i, name = "Item" .. i}
				items[i] = item
				minHeap:Push(item, i)
			end
			
			-- Remove item 5 by reference
			minHeap:RemoveFirstOccurrence(items[5])
			
			expect(#minHeap).is(9)
			
			-- Verify heap is still sorted by cost
			local prevCost = -math.huge
			while #minHeap > 0 do
				local _val, cost = minHeap:Pop()
				expect(cost > prevCost).is(true)
				prevCost = cost
			end
		end)

		test("should handle edge case: remove then immediately push same value", function()
			local minHeap = Heap.min()
			minHeap:Push("A", 5)
			minHeap:Push("B", 3)
			minHeap:Push("C", 7)
			
			minHeap:RemoveFirstOccurrence("B")
			minHeap:Push("B", 1) -- Push with different cost
			
			expect(minHeap:Peek()).is("B") -- Should be new "B" with cost 1
			local poppedVal, poppedCost = minHeap:Pop()
			expect(poppedVal).is("B")
			expect(poppedCost).is(1)
		end)

		test("should handle remove when heap has been rebuilt multiple times", function()
			local maxHeap = Heap.max()
			
			-- Build, drain, rebuild cycle
			for cycle = 1, 3 do
				for i = 1, 10 do
					maxHeap:Push(i + (cycle * 100))
				end
				
				-- Drain partially
				for i = 1, 5 do
					maxHeap:Pop()
				end
				
				-- Remove some
				maxHeap:RemoveFirstOccurrence(2 + (cycle * 100))
				maxHeap:RemoveFirstOccurrence(4 + (cycle * 100))
			end
			
			-- Should have 9 elements left (15 added - 15 removed via pop - 6 via remove = -6, but cycles...)
			-- Actually: 30 added, 15 popped, 6 removed = 9 left
			expect(#maxHeap).is(9)
			
			-- Verify heap property
			local prev = math.huge
			while #maxHeap > 0 do
				local val = maxHeap:Pop()
				expect(val <= prev).is(true)
				prev = val
			end
		end)

		test("should correctly heapify when removed element's replacement needs to go down", function()
			local minHeap = Heap.min()
			-- Build a specific structure where removing middle element 
			-- causes last element to be moved and need to heapify down
			minHeap:Push(1)  -- root
			minHeap:Push(3)  -- left child
			minHeap:Push(5)  -- right child
			minHeap:Push(7)  -- left-left
			minHeap:Push(9)  -- left-right
			minHeap:Push(6)  -- right-left
			minHeap:Push(8)  -- right-right
			
			-- Remove 3 (left child of root)
			-- Last element (8) will be moved to position of 3
			-- 8 is greater than parent (1) but needs to move down
			minHeap:RemoveFirstOccurrence(3)
			
			-- Verify heap property maintained
			expect(minHeap:Peek()).is(1)
			local prev = -math.huge
			while #minHeap > 0 do
				local val = minHeap:Pop()
				expect(val >= prev).is(true)
				prev = val
			end
		end)

		test("should correctly heapify when removed element's replacement needs to go up", function()
			local minHeap = Heap.min()
			-- Build structure where removing causes upward heapify
			minHeap:Push(5)
			minHeap:Push(10)
			minHeap:Push(15)
			minHeap:Push(20)
			minHeap:Push(25)
			minHeap:Push(30)
			minHeap:Push(1)  -- This will be last element
			
			-- Remove 15 (right child of root)
			-- Element 1 (last) will be moved to position of 15
			-- 1 is less than parent (5) and needs to move up
			minHeap:RemoveFirstOccurrence(15)
			
			-- After proper heapify, 1 should be at root
			expect(minHeap:Peek()).is(1)
			
			local prev = -math.huge
			while #minHeap > 0 do
				local val = minHeap:Pop()
				expect(val >= prev).is(true)
				prev = val
			end
		end)

		test("should handle max heap removal requiring downward heapify", function()
			local maxHeap = Heap.max()
			maxHeap:Push(100) -- root
			maxHeap:Push(80)  -- left
			maxHeap:Push(90)  -- right
			maxHeap:Push(70)  -- left-left
			maxHeap:Push(75)  -- left-right
			maxHeap:Push(85)  -- right-left
			maxHeap:Push(60)  -- right-right (will be last)
			
			-- Remove 90 (right child)
			-- Element 60 moved to position of 90
			-- 60 < 100 (parent) so no upward move, but needs to go down
			maxHeap:RemoveFirstOccurrence(90)
			
			expect(maxHeap:Peek()).is(100)
			local prev = math.huge
			while #maxHeap > 0 do
				local val = maxHeap:Pop()
				expect(val <= prev).is(true)
				prev = val
			end
		end)

		test("should handle max heap removal requiring upward heapify", function()
			local maxHeap = Heap.max()
			maxHeap:Push(50)  -- root
			maxHeap:Push(30)  -- left
			maxHeap:Push(40)  -- right
			maxHeap:Push(20)  -- left-left
			maxHeap:Push(25)  -- left-right
			maxHeap:Push(35)  -- right-left
			maxHeap:Push(200) -- right-right (will be last, should bubble to top)
			
			-- Remove 30 (left child)
			-- Element 200 moved to position of 30
			-- 200 > 50 (parent) so needs to move up to become new root
			maxHeap:RemoveFirstOccurrence(30)
			
			expect(maxHeap:Peek()).is(200)
			local prev = math.huge
			while #maxHeap > 0 do
				local val = maxHeap:Pop()
				expect(val <= prev).is(true)
				prev = val
			end
		end)

		test("should handle removal at different depths correctly", function()
			local minHeap = Heap.min()
			
			-- Build larger heap
			for i = 1, 31 do
				minHeap:Push(i)
			end
			
			-- Remove from different depths
			minHeap:RemoveFirstOccurrence(2)   -- depth 1
			minHeap:RemoveFirstOccurrence(7)   -- depth 2
			minHeap:RemoveFirstOccurrence(15)  -- depth 3
			minHeap:RemoveFirstOccurrence(25)  -- depth 4
			
			-- Verify heap property maintained
			local prev = -math.huge
			while #minHeap > 0 do
				local val = minHeap:Pop()
				expect(val > prev).is(true)
				prev = val
			end
		end)

		test("should handle RemoveAllOccurrences with changing heap structure", function()
			local minHeap = Heap.min()
			
			-- Create a pattern where removals will cause significant restructuring
			for i = 1, 20 do
				minHeap:Push("KEEP", i)
				minHeap:Push("REMOVE", i + 100)
			end
			
			-- Remove all "REMOVE" entries (20 removals with changing structure)
			local removed = minHeap:RemoveAllOccurrences("REMOVE")
			expect(removed).is(20)
			expect(#minHeap).is(20)
			
			-- Verify heap property maintained after all removals
			local prev = -math.huge
			for i = 1, 20 do
				local val, cost = minHeap:Pop()
				expect(val).is("KEEP")
				expect(cost > prev).is(true)
				prev = cost
			end
		end)

		test("should handle edge case: remove element equal to parent and children", function()
			local minHeap = Heap.min()
			minHeap:Push("A", 5)
			minHeap:Push("B", 5)  -- Same cost as parent
			minHeap:Push("C", 5)  -- Same cost as parent
			minHeap:Push("D", 5)  -- Will be moved
			
			minHeap:RemoveFirstOccurrence("B")
			
			-- Should still maintain valid heap (all costs same, so any order valid)
			expect(#minHeap).is(3)
			local prev = -math.huge
			while #minHeap > 0 do
				local _val, cost = minHeap:Pop()
				expect(cost >= prev).is(true)
				prev = cost
			end
		end)
		end)

	--------------------------------------------------------------------------------
		--// Metamethods //--
	--------------------------------------------------------------------------------
	
	describe("__len", function()
		test("should return correct number of elements", function()
			local minHeap = Heap.min()
			minHeap:Push(5)
			minHeap:Push(10)
			expect(#minHeap).is(2)
			minHeap:Pop()
			expect(#minHeap).is(1)
			minHeap:Pop()
			expect(#minHeap).is(0)
			minHeap:Pop()
			expect(#minHeap).is(0)
			minHeap:Push(20)
			expect(#minHeap).is(1)
		end)
	end)

	describe("__tostring", function()
		test("should return a string representation of the heap", function()
			local minHeap = Heap.min()
			for i = 1, 10 do
				minHeap:Push(math.random(1, 10))
			end
			
			local heapStr = tostring(minHeap)
			expect(heapStr:find("Heap:")).never_is(nil)
			-- print(heapStr)
		end)
	end)

	describe("__iter", function()
		test("should iterate over the heap", function()
			local minHeap = Heap.min()
			local values = {}
			local costs = {}

			for i = 1, 100 do
				local cost = math.random(1, 20)
				local value = string.char(math.random(97, 110))
				minHeap:Push(value, cost)
				table.insert(values, value)
				table.insert(costs, cost)
			end
			
			local i = 0
			for value, cost in minHeap do
				i = i + 1
				local vIdx = table.find(values, value)
				local cIdx = table.find(costs, cost)
				expect(vIdx)
				expect(cIdx)
				table.remove(values, vIdx)
				table.remove(costs, cIdx)
				print(value, cost)
			end
			expect(i).is(#minHeap)
			expect(#values).is(0)
			expect(#costs).is(0)
		end)
		
		test("should atleast give us the peeked value as the first value", function()
			local minHeap = Heap.min()
			minHeap:Push("A", 5)
			minHeap:Push("B", 2)
			minHeap:Push("C", 8)
			minHeap:Push("A", 4)
			minHeap:Push("D", 10)
			local peekedValue, peekedCost = minHeap:Peek()
			for iteratedValue, iteratedCost in minHeap do
				expect(peekedValue).is(iteratedValue)
				expect(peekedCost).is(iteratedCost)
				break
			end
		end)

		-- [We make no guarantees about iteration order]
		-- test("Iteration order test", function()
		-- 	local minHeap = Heap.min()
		-- 	minHeap:Push("A", 5)
		-- 	minHeap:Push("B", 2)
		-- 	minHeap:Push("C", 8)
		-- 	minHeap:Push("A", 4)
		-- 	minHeap:Push("D", 10)

		-- 	local expectedResults = {
		-- 		{"B", 2},
		-- 		{"A", 5},
		-- 		{"C", 8},
		-- 		{"A", 4},
		-- 		{"D", 10}
		-- 	}
		
		-- 	local i = 0
		-- 	for value: string, cost: number in minHeap do
		-- 		i = i + 1
		-- 		expect({value, cost}).is_shallow_equal(expectedResults[i])
		-- 	end
		-- end)
	end)

	--------------------------------------------------------------------------------
		--// Info Tests (Kept so I can analyze perf) //--
	--------------------------------------------------------------------------------

	describe("Performance Benchmarks", function()
		test("Compare heap vs array for finding minimum", function()
			local sizes = {10, 50, 100, 500, 1000}
			print("\n=== Heap vs Array Performance Comparison ===")
			print("Finding minimum element repeatedly:\n")
			
			for _, n in ipairs(sizes) do
				-- Generate random data
				local data = {}
				for i = 1, n do
					table.insert(data, math.random(1, 10000))
				end
				
				-- Test Heap Performance
				local heapTime = 0
				local minHeap = Heap.min()
				
				-- Build heap
				for _, v in ipairs(data) do
					minHeap:Push(v)
				end
				
				-- Extract all minimums
				local startExtract = os.clock()
				for i = 1, n do
					minHeap:Pop()
				end
				heapTime = os.clock() - startExtract
				
				-- Test Array Performance
				local arrayTime = 0
				local arrayData = {}
				for _, v in ipairs(data) do
					table.insert(arrayData, v)
				end
				
				-- Extract all minimums (find min, remove with swap removal)
				local startArray = os.clock()
				for i = 1, n do
					local minIdx = 1
					local minVal = arrayData[1]
					for j = 2, #arrayData do
						if arrayData[j] < minVal then
							minVal = arrayData[j]
							minIdx = j
						end
					end
					swapRemove(arrayData, minIdx)
				end
				arrayTime = os.clock() - startArray
				
				local speedup = arrayTime / heapTime
				local heapMs = heapTime * 1000
				local arrayMs = arrayTime * 1000
				
				print(string.format("n=%4d: Heap=%6.3fms, Array=%7.3fms, Speedup=%.3fx", 
					n, heapMs, arrayMs, speedup))
			end
			
			print("\n=== Analysis ===")
			print("Heap Operations: O(n log n) total")
			print("Array Operations: O(n²) total")
			print("Heap becomes significantly faster as n grows")
			print("(Note: Performance can vary based on system load)")
		end)

		test("Compare heap vs sorted array for priority queue operations", function()
			local initialSize = 100
			local operations = 500
			print("\n=== Priority Queue: Heap vs Sorted Array ===")
			print(string.format("Testing with %d initial items + %d mixed operations:\n", initialSize, operations))
			
			-- Generate random data for consistent comparison
			local initialData = {}
			for i = 1, initialSize do
				table.insert(initialData, math.random(1, 1000))
			end
			local operationData = {}
			for i = 1, operations do
				table.insert(operationData, math.random(1, 1000))
			end
			
			-- Test Heap
			local minHeap = Heap.min()
			local heapStart = os.clock()
			-- Build initial queue
			for _, v in ipairs(initialData) do
				minHeap:Push(v)
			end
			-- Mixed push/pop operations
			for i = 1, operations do
				if i % 3 == 0 then
					minHeap:Pop() -- Pop every 3rd operation
				else
					minHeap:Push(operationData[i]) -- Push otherwise
				end
			end
			local heapTime = (os.clock() - heapStart) * 1000
			
			-- Test Sorted Array (always keep sorted)
			local sortedArray = {}
			local arrayStart = os.clock()
			-- Build initial queue
			for _, v in ipairs(initialData) do
				table.insert(sortedArray, v)
			end
			table.sort(sortedArray)
			-- Mixed push/pop operations
			for i = 1, operations do
				if i % 3 == 0 then
					-- Remove minimum (first element)
					if #sortedArray > 0 then
						table.remove(sortedArray, 1)
					end
				else
					-- Insert and maintain sorted order
					local val = operationData[i]
					-- Binary search insert would be optimal, but using simple insertion
					local inserted = false
					for j = 1, #sortedArray do
						if val < sortedArray[j] then
							table.insert(sortedArray, j, val)
							inserted = true
							break
						end
					end
					if not inserted then
						table.insert(sortedArray, val)
					end
				end
			end
			local arrayTime = (os.clock() - arrayStart) * 1000
			
			local speedup = arrayTime / heapTime
			
			print(string.format("Heap:         %.3fms", heapTime))
			print(string.format("Sorted Array: %.3fms", arrayTime))
			print(string.format("Speedup:      %.3fx", speedup))
			print(string.format("Final sizes:  Heap=%d, Array=%d", minHeap:Size(), #sortedArray))
			print("\nHeap should be faster for mixed push/pop operations")
			print("(Note: Actual performance can vary based on system load)")
		end)

		test("Heap efficiency for top-K elements", function()
			local n = 1000
			local k = 10
			print(string.format("\n=== Finding top %d elements from %d items ===\n", k, n))
			
			local data = {}
			for i = 1, n do
				table.insert(data, math.random(1, 10000))
			end
			
			-- Using Heap (optimal approach)
			local heapStart = os.clock()
			local minHeap = Heap.min()
			for _, v in ipairs(data) do
				if minHeap:Size() < k then
					minHeap:Push(v)
				else
					local minVal = minHeap:Peek()
					if v > minVal then
						minHeap:Pop()
						minHeap:Push(v)
					end
				end
			end
			local heapTime = (os.clock() - heapStart) * 1000
			
			-- Using Full Sort
			local sortStart = os.clock()
			local sortedData = {}
			for _, v in ipairs(data) do
				table.insert(sortedData, v)
			end
			table.sort(sortedData, function(a, b) return a > b end)
			local topK = {}
			for i = 1, k do
				table.insert(topK, sortedData[i])
			end
			local sortTime = (os.clock() - sortStart) * 1000
			
			local speedup = sortTime / heapTime
			
			print(string.format("Heap approach:  %.3fms (O(n log k))", heapTime))
			print(string.format("Full sort:      %.3fms (O(n log n))", sortTime))
			print(string.format("Speedup:        %.3fx", speedup))
			print(string.format("\nFor k << n, heap approach is more efficient (%.2fx faster)", speedup))
			print("(Note: Actual performance can vary based on system load)")
		end)

		test("Heap vs array for dynamic priority changes", function()
			local n = 200
			print(string.format("\n=== Dynamic Priority Updates (%d items) ===\n", n))
			
			-- Using Heap with UpdateCost
			local heapStart = os.clock()
			local minHeap = Heap.min()
			
			-- Initial insertion
			for i = 1, n do
				minHeap:Push(i, math.random(1, 100))
			end
			
			-- Update priorities
			for i = 1, n // 2 do
				local target = math.random(1, n)
				minHeap:UpdateCost(target, math.random(1, 100))
			end
			
			-- Extract all
			for i = 1, n do
				minHeap:Pop()
			end
			local heapTime = (os.clock() - heapStart) * 1000
			
			-- Using Array (rebuild sort after each update)
			local arrayStart = os.clock()
			local array = {}
			
			-- Initial insertion
			for i = 1, n do
				table.insert(array, {val = i, cost = math.random(1, 100)})
			end
			table.sort(array, function(a, b) return a.cost < b.cost end)
			
			-- Update priorities (re-sort after each)
			for i = 1, n // 2 do
				local target = math.random(1, #array)
				array[target].cost = math.random(1, 100)
				table.sort(array, function(a, b) return a.cost < b.cost end)
			end
			
			-- Extract all
			array = {}
			local arrayTime = (os.clock() - arrayStart) * 1000
			
			local speedup = arrayTime / heapTime
			
			print(string.format("Heap:  %.3fms (O(log n) per update)", heapTime))
			print(string.format("Array: %.3fms (O(n log n) per update)", arrayTime))
			print(string.format("Speedup: %.2fx", speedup))
			print("\nHeap excels at dynamic priority updates (should be significantly faster)")
			print("(Note: Actual performance can vary based on system load)")
		end)

		test("Break-even point analysis: Push + Pop operations", function()
			print("\n=== Break-even Point Analysis: Push + Pop ===")
			print("Finding where heap becomes faster than array:\n")
			
			local heapFaster = nil
			
			for n = 5, 100, 5 do
				local data = {}
				for i = 1, n do
					table.insert(data, math.random(1, 1000))
				end
				
				-- Heap
				local heapStart = os.clock()
				local minHeap = Heap.min()
				for _, v in ipairs(data) do
					minHeap:Push(v)
				end
				for i = 1, n do
					minHeap:Pop()
				end
				local heapTime = os.clock() - heapStart
				
				-- Array
				local arrayStart = os.clock()
				local arr = {}
				for _, v in ipairs(data) do
					table.insert(arr, v)
				end
				for i = 1, n do
					local minIdx = 1
					for j = 2, #arr do
						if arr[j] < arr[minIdx] then
							minIdx = j
						end
					end
					swapRemove(arr, minIdx)
				end
				local arrayTime = os.clock() - arrayStart
				
				if heapTime < arrayTime and heapFaster == nil then
					heapFaster = n
					print(string.format("n=%d: Heap becomes faster! (%.3fms vs %.3fms)", 
						n, heapTime * 1000, arrayTime * 1000))
					break
				end
			end
			
			if heapFaster then
				print(string.format("\nBreak-even point: ~%d elements", heapFaster))
				print("Use array for: n < " .. heapFaster)
				print("Use heap for:  n >= " .. heapFaster)
			else
				print("\nNo clear break-even point found in tested range")
				print("For this workload (push all + pop all), heap scales better")
				print("But array may be faster for very small n (< 5)")
			end
		end)

		test("Break-even point analysis: Push only", function()
			print("\n=== Break-even Point Analysis: Push Only ===")
			print("Comparing heap building vs maintaining sorted array:\n")
			
			local heapFaster = nil
			
			for n = 10, 200, 10 do
				local data = {}
				for i = 1, n do
					table.insert(data, math.random(1, 1000))
				end
				
				-- Heap: O(n log n) - heapify on each insert
				local heapStart = os.clock()
				local minHeap = Heap.min()
				for _, v in ipairs(data) do
					minHeap:Push(v)
				end
				local heapTime = os.clock() - heapStart
				
				-- Sorted Array: O(n²) - insertion sort
				local arrayStart = os.clock()
				local sortedArray = {}
				for _, v in ipairs(data) do
					local inserted = false
					for j = 1, #sortedArray do
						if v < sortedArray[j] then
							table.insert(sortedArray, j, v)
							inserted = true
							break
						end
					end
					if not inserted then
						table.insert(sortedArray, v)
					end
				end
				local arrayTime = os.clock() - arrayStart
				
				if heapTime < arrayTime and heapFaster == nil then
					heapFaster = n
					print(string.format("n=%d: Heap becomes faster! (%.3fms vs %.3fms)", 
						n, heapTime * 1000, arrayTime * 1000))
					break
				end
			end
			
			if heapFaster then
				print(string.format("\nBreak-even point for push: ~%d elements", heapFaster))
				print("Heap Push: O(log n), Sorted Array Insert: O(n)")
			else
				print("\nHeap is consistently faster even for small n")
			end
		end)

		test("Break-even point analysis: Pop only", function()
			print("\n=== Break-even Point Analysis: Pop Only ===")
			print("Pre-built structures, comparing extraction performance:\n")
			
			local heapFaster = nil
			
			for n = 5, 100, 5 do
				local data = {}
				for i = 1, n do
					table.insert(data, math.random(1, 1000))
				end
				
				-- Pre-build heap
				local minHeap = Heap.min()
				for _, v in ipairs(data) do
					minHeap:Push(v)
				end
				
				-- Pre-build sorted array
				local sortedArray = {}
				for _, v in ipairs(data) do
					table.insert(sortedArray, v)
				end
				table.sort(sortedArray)
				
				-- Heap: O(n log n) total for n pops
				local heapStart = os.clock()
				for i = 1, n do
					minHeap:Pop()
				end
				local heapTime = os.clock() - heapStart
				
				-- Sorted Array: O(n) total - just remove from front
				local arrayStart = os.clock()
				for i = 1, n do
					table.remove(sortedArray, 1)
				end
				local arrayTime = os.clock() - arrayStart
				
				local heapMs = heapTime * 1000
				local arrayMs = arrayTime * 1000
				
				-- For pop-only from sorted array, results may vary
				-- This test shows the actual performance comparison
				if n == 5 or n % 20 == 0 then
					local ratio = heapMs / arrayMs
					print(string.format("n=%3d: Heap=%.3fms, Array=%.3fms (Heap/Array=%.2fx)", 
						n, heapMs, arrayMs, ratio))
				end
			end
			
			print("\n=== Analysis ===")
			print("For Pop-only operations on pre-built structures:")
			print("- Heap: O(log n) per pop")
			print("- Sorted Array: O(n) per pop via table.remove(array, 1)")
			print("Surprisingly, the array implementation can be competitive due to:")
			print("  * LuaJIT optimization of table.remove at index 1")
			print("  * Lower constant factors for simple removal")
			print("For this specific case, array performance may beat heap for small n")
			print("But combining build + pop operations, heap wins overall")
		end)
	end)

	describe("Large Dataset Test", function()
		print("[Beginning Large Dataset Test]")
		local minHeap = Heap.min()
		local elementsToInsert = 100000
		local elementsToRemove = 99900

		test("Insertion: "..elementsToInsert.." Items", function()
			for i = 1, elementsToInsert do
				minHeap:Push(i)
			end
		end)

		test("Removal of one item", function()
			local t = os.clock()
			minHeap:Pop()
			t = os.clock() - t
			print("Time taken to remove one item: "..(t*1000).."ms")
		end)

		test("Removal: "..elementsToRemove.." Items", function()
			for i = 1, elementsToRemove do
				minHeap:Pop()
			end
		end)
	end)
end

return test_suite