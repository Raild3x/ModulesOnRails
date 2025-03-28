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
		end)
	end)

	describe("Large Dataset Test", function()
		local minHeap = Heap.min()
		local elementsToInsert = 100000
		local elementsToRemove = 99900

		test("Insertion: "..elementsToInsert.." Items", function()
			for i = 1, elementsToInsert do
				minHeap:Push(math.random(1, 100))
			end
		end)

		test("Removal of one item", function()
			minHeap:Pop()
		end)

		test("Removal: "..elementsToRemove.." Items", function()
			for i = 1, elementsToRemove do
				minHeap:Pop()
			end
		end)
	end)
end

return test_suite