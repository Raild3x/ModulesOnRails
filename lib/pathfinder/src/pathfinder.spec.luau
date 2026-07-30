local Heap = require("./init")

local test_suite = function(tiniest)
	local describe = tiniest.describe
	local test = tiniest.test
	local expect = tiniest.expect

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
	end)

	-- describe("ToArray", function() -- ToArray is not supported
	-- 	test("should return an array representation of the heap", function()
	-- 		local minHeap = Heap.min()
	-- 		minHeap:Push(5)
	-- 		minHeap:Push(3)
	-- 		minHeap:Push(8)
	-- 		minHeap:Push(3)
	-- 		minHeap:Push(3)
	-- 		minHeap:Push(10)
	-- 		expect(minHeap:ToArray()).is_shallow_equal({3, 3, 3, 5, 8, 10})
	-- 	end)
	-- end)

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