-- Author: Logan Hunt (Raild3x)
-- Feb 27, 2025
--[=[
    @class Heap
    A generic [Heap](https://en.wikipedia.org/wiki/Heap_(data_structure)) implementation for both min and max heaps. It is designed
    for allowing the association of a cost to a given value so that users are not restricted to just numbers as values.

    ### *What is a Heap?*
    Heaps are an implementation of [Priority Queues](https://en.wikipedia.org/wiki/Priority_queue) that excel at tracking the smallest
    or largest element in an array. They are commonly used in algorithms like Dijkstra's shortest path algorithm and Huffman coding.

    ### Examples:
    
    ```lua title="Min Heap"
    local minHeap = Heap.min()
    minHeap:Push("A", 5) -- A is the value, and 5 is the cost associated with it
    minHeap:Push("B", 2)
    minHeap:Push("C", 8)
    minHeap:Push("D", 4)
    
    -- look at the current lowest value
    local minValue, minCost = minHeap:Peek()
    print(minValue, minCost) -- B 2
    ```
    ```lua title="Max Heap"
    local maxHeap = Heap.max()
    minHeap:Push("A", 5)
    minHeap:Push("B", 2)
    minHeap:Push("C", 8)
    minHeap:Push("D", 4)

    local poppedValue, costOfPoppedValue = maxHeap:Pop() -- pops off the top value
    print(poppedValue, costOfPoppedValue) -- C 8

    -- look at the new highest value
    print(maxHeap:Peek()) -- A 5
    ```

    ___
    :::tip MetaMethods
    Supports the following metamethods:
    - `__tostring`: Returns a string representation of the heap in a tree like display.
    - [`__len`](/api/Heap#Size): Returns the number of elements in the heap. Equivalent to calling [`:Size()`](/api/Heap#Size).
        ```lua
        local minHeap = Heap.min()
        minHeap:Push("A", 5)
        minHeap:Push("B", 2)
        print(#minHeap) -- 2
        ```
    - [`__iter`](/api/Heap#__iter): Provides an iterator for for loop usage
    :::
    
    :::tip Exported Types
    This file exports a Heap type in the form of **`Heap<T>`** where **`T`** is the type of value stored in the heap.
    Usually Luau can infer the type of **`T`** from your usage, but it may be useful to manually provide the type if
    you are using more complex datatypes.
    ```lua
    local Heap = require(ReplicatedStorage.Heap)
    type Heap<T> = Heap.Heap<T>

    local myHeap: Heap<string> = Heap.min()
    myHeap:Push("A", 5)
    ```
    :::

    :::info Info for Nerds
    *Read this only if you want to know more about the internals of this heap implmenentation.*

    In order to support the association of a cost to a value, the heap is implemented as three separate arrays.
    One to store the values, one to store the costs, and one to store the index pointing to the first two.
    I used this structure in order to optimize for cache hits on table lookups since using an object based 
    approach `Ex: {Value: T, Cost: number}` could cause the CPU to potentially miss the `Cost` data since it may
    not be stored continguously in memory.

    When a value is popped from the heap, its reference index is stored in a stack of open indices for reuse.
    This is done to hopefully reduce fragmentation of the heap and improve the likelyhood of cache hits.

    I originally opted to use a dynamic cost system such that you would provide a comparator function
    to the constructor that would be used to determine the cost of each value. However, this introduced
    a number of potential issues such as if the comparator function was not deterministic, causing the order to desync.
    There could very likely be cases where the cost could change without the heap's knowledge of it. So instead I opted
    to require the cost to be provided at the time of insertion. Although technically the type definition specifies for
    only number costs, you could in theory use any type luau considers comparable with relational operators.
    :::
]=]

type Branch<T> = { Value: T, Left: Branch<T>?, Right: Branch<T>? }

export type Heap<T> = {
	ClassName: "Heap",

	--- Inserts a value into the heap.
	Push: (self: Heap<T>, value: T, _cost: number?) -> (),

	--- Removes and returns the top value from the heap.
	Pop: (self: Heap<T>) -> (T?, number?),

	--- Returns the top value from the heap without removing it.
	Peek: (self: Heap<T>) -> (T?, number?),

	--- Returns the number of elements in the heap.
	Size: (self: Heap<T>) -> number,

	--- Checks if the heap is empty. Equivalent to checking if `#heap == 0`.
	IsEmpty: (self: Heap<T>) -> boolean,

	--- Checks if the heap contains a specified value; also compares against cost if one is provided.
	Has: (self: Heap<T>, valueToCheckFor: T, cost: number?) -> boolean,

	--- Updates the cost of a value in the heap. If no value is found, false is returned.
	UpdateCost: (
		self: Heap<T>,
		valueToUpdate: T | (value: T) -> boolean,
		newCost: number | (oldCost: number) -> number,
		updateAll: boolean?
	) -> boolean,

	--- Returns the cost given to a value. If no value is found, nil is returned.
	GetCost: (self: Heap<T>, valueToCheckCostOf: T) -> number?,

	--- Returns the number of occurrences of a value in the heap.
	CountOccurrences: (self: Heap<T>, valueToCheckFor: T) -> number,

	--- Removes the first occurrence of a given value from the heap.
	RemoveFirstOccurrence: (self: Heap<T>, value: T) -> boolean,

	--- Removes all occurrences of a given value from the heap.
	RemoveAllOccurrences: (self: Heap<T>, value: T) -> boolean,

	--- Converts the heap into a tree structure. Used for debug visualizations
	ToTree: (self: Heap<T>) -> Branch<T>?,
}

--------------------------------------------------------------------------------
--// Class //--
--------------------------------------------------------------------------------

local Heap = {}
Heap.__index = Heap

--[=[
    @within Heap
    @private
    @tag static
    @prop ClassName "Heap"

    Just a simple string identifier for the class name.
]=]
Heap.ClassName = "Heap"

--------------------------------------------------------------------------------
--// Constructors //--
--------------------------------------------------------------------------------

local HeapClass = {}

local function newHeap<T>(heapType: "min" | "max"): Heap<T>
	return setmetatable({
		_Costs = {} :: { number },
		_Values = {} :: { T },
		_HeapIndex = {} :: { number },
		_Size = 0,
		_isMinHeap = if heapType == "min" then true else false,
		_OpenIndices = {},
	}, Heap) :: any
end

--[=[
    @tag static
    Creates a min-heap where the smallest element is always on top.
    @return Heap<T> -- A min-heap instance.
]=]
function HeapClass.min<T>(): Heap<T>
	return newHeap("min")
end

--[=[
    @tag static
    Creates a max-heap where the largest element is always on top.
    @return Heap<T> -- A max-heap instance.
]=]
function HeapClass.max<T>(): Heap<T>
	return newHeap("max")
end

--------------------------------------------------------------------------------
--// Methods //--
--------------------------------------------------------------------------------

--[=[
    Returns the *top value* from the heap without removing it.
    The top value is the value with the lowest cost in a min-heap 
    and the value with the highest cost in a max-heap.
    If the heap is empty, nil is returned for both values.

    @return T? -- The top value from the heap.
    @return number? -- The cost of the top value.

    *Time Complexity:* Runs in `O(1)` time.
]=]
function Heap:Peek<T>(): (T?, number?)
	if self._Size == 0 then
		return nil, nil
	end
	local refIndex = self._HeapIndex[1]
	return self._Values[refIndex], self._Costs[refIndex]
end

--[=[
    Inserts a value into the heap.

    *Time Complexity:* Runs in worst case `O(log n)` time.

    ```lua
    local minHeap = Heap.min()

    minHeap:Push("A", 5)
    minHeap:Push("B", 2)
    minHeap:Push("C", 8)

    local minValue, minCost = minHeap:Peek()
    print(minValue, minCost) -- B 2
    ```

    :::info Cost
    If no **cost** is given, the value itself is used as the cost.
    Ensure that the given value is comparable with relational operators.
    ```lua
    local minHeap = Heap.min()
    minHeap:Push(2) -- uses 2 for both value and cost
    print(minHeap:Peek()) -- 2 2
    ```
    :::
]=]
function Heap:Push<T>(value: T, _cost: number?)
	-- If not cost is given then just use the value
	local Cost: number = _cost or value :: any

	self._Size += 1
	local index = self._Size

	-- Reuse an open index if available, attempts to reduce fragmentation
	if #self._OpenIndices > 0 then
		index = table.remove(self._OpenIndices) -- Pop from open indices stack
	end

	-- Insert new element
	self._Costs[index] = Cost
	self._Values[index] = value
	self._HeapIndex[self._Size] = index

	-- Restore heap property
	self:_heapifyUp(self._Size)

	-- Should we return the heapId? Probably not since it is not a guaranteed unique identifier
end

--[=[
    Removes and returns the top value from the heap.

    *Time Complexity:* Runs in worst case `O(log n)` time.
]=]
function Heap:Pop<T>(): (T?, number?)
	if self._Size == 0 then
		return nil, nil
	end

	-- Collect root node info
	local rootRefIndex = self._HeapIndex[1]
	local rootValue = self._Values[rootRefIndex]
	local rootCost = self._Costs[rootRefIndex]

	-- TODO: try and reuse rootRefIndex here to prevent fragmentation immediately

	-- Remove value and cost linked to current root (We could probably remove this since it's refIndex is marked for reuse)
	self._Values[rootRefIndex] = nil
	self._Costs[rootRefIndex] = nil

	-- Move last element to root and remove last entry
	self._HeapIndex[1] = self._HeapIndex[self._Size]
	self._HeapIndex[self._Size] = nil
	self._Size -= 1

	-- Store freed index for reuse
	table.insert(self._OpenIndices, rootRefIndex)

	-- Heapify down
	self:_heapifyDown(1)

	return rootValue, rootCost
end

--[=[
    Returns the number of elements in the heap.
    Equivalent to using the `#` operator on the heap.

    *Time Complexity:* Runs in `O(1)` time.
]=]
function Heap:Size(): number
	return self._Size
end

--[=[
    Checks if the heap is empty. Equivalent to checking if `#heap == 0`.
]=]
function Heap:IsEmpty(): boolean
	return self._Size == 0
end

--[=[
    Takes a value or function and checks if the heap contains it.
    If a cost is provided then it will also ensure the cost matches.
    Returns true if the heap contains a specified value.

    *Time Complexity:* Runs in worst case `O(n)` time.
]=]
function Heap:Has<T>(valueToCheckFor: T, cost: number?): boolean
	local Costs = self._Costs
	for refIdx, value in pairs(self._Values) do
		if value == valueToCheckFor and (not cost or Costs[refIdx] == cost) then
			return true
		end
	end
	return false
end

--[=[
    @private
    @unreleased

    Converts the heap into an array of `{Value: T, Cost: number}` objects.
    This is useful for iterating over the heap in a more structured way
    without the worry of it changing during iteration.

    @return {{Value: T, Cost: number}}
]=]
function Heap:ToArray<T>(): { { Value: T, Cost: number } }
	local array = table.create(self._Size)
	for refIdx, value in pairs(self._Values) do
		table.insert(array, { Value = value, Cost = self._Costs[refIdx] })
	end
	return array
end

--[=[
    @unreleased
    Updates the cost of a value in the heap. If no value is found, false is returned.
    :::caution Repeated Values
    If you have multiple instances of the same value, this method will only update the cost of the first valid instance found,
    unless the third parameter `updateAll` is set to `true`. There is no guarantee of which instance will be found first.
    Using `updateAll` can be expensive as it may need to perform a large resorting of the heap to ensure proper ordering.
    :::
    @param valueToUpdate -- The value to update the cost of.
    @param newCost -- The new cost to assign to the value. Can also be a function that takes the value and old cost and returns a new cost.
    @param updateAll -- If true, all occurrences of the value will be updated. Defaults to false.
    @return boolean -- True if the cost was updated, false otherwise.

    ```lua
    local minHeap = Heap.min()
    minHeap:Push("A", 5)
    minHeap:Push("B", 2)
    minHeap:Push("C", 8)
    minHeap:Push("D", 10)

    print(minHeap:Peek()) -- B 2
    minHeap:UpdateCost("A", 1)
    print(minHeap:Peek()) -- A 1
    ```
    ```lua
        -- update the cost of the first value that matches either "A" or "B" to 15
    minHeap:UpdateCost(function(value)
        return value == "A" or value == "B"
    end, 15, false)

    -- update the cost of all values that match "A" or "B" to 30
    minHeap:UpdateCost(function(value)
        return value == "A" or value == "B"
    end, 30, true)
    ```
]=]
function Heap:UpdateCost<T>(
	valueToUpdate: T | (value: T) -> boolean,
	newCost: number | (value: T, oldCost: number) -> number,
	updateAll: boolean?
): boolean
    local Values, Costs, HeapIndex, Size = self._Values, self._Costs, self._HeapIndex, self._Size
    local updated = 0
    local updatedHeapIdx = nil -- used to track the heap index of the updated value (used only when updating a single value)

    local newCostIsFn = type(newCost) == "function"

    -- First pass: Update costs in place
    if type(valueToUpdate) == "function" then -- I split this up intentionally to reduce the number of comparisons made
        for realIdx, refIdx in pairs(HeapIndex) do
            if valueToUpdate(Values[refIdx]) then
                local oldCost = Costs[refIdx]
                local computedNewCost: number = if newCostIsFn then (newCost :: any)(Values[refIdx], oldCost) else newCost

                if oldCost ~= computedNewCost then
                    Costs[refIdx] = computedNewCost
                    updatedHeapIdx = realIdx -- Store the heap position, not the ref index
                    updated += 1
                end

                if not updateAll then break end
            end
        end
    else
        for realIdx, refIdx in pairs(HeapIndex) do
            if Values[refIdx] == valueToUpdate then
                local oldCost = Costs[refIdx]
                local computedNewCost: number = if newCostIsFn then (newCost :: any)(Values[refIdx], oldCost) else newCost

                if oldCost ~= computedNewCost then
                    Costs[refIdx] = computedNewCost
                    updatedHeapIdx = realIdx -- Store the heap position, not the ref index
                    updated += 1
                end

				if not updateAll then
					break
				end
			end
		end
	end

    if updated == 1 then
         -- Only heapify once if a single value was updated
         -- Try heapifying up first (in case cost decreased for min-heap or increased for max-heap)
         -- then heapify down (in case cost increased for min-heap or decreased for max-heap)
        self:_heapifyUp(updatedHeapIdx)
        self:_heapifyDown(updatedHeapIdx)
    elseif updated > 1 then
        -- If we made multiple updates, we need to perform a more robust heapify
        -- Rebuild the heap from the bottom up
        for i = math.floor(Size / 2), 1, -1 do
            self:_heapifyDown(i)
        end
    end

	return if updated > 0 then true else false
end
Heap.UpdateCostOfValue = Heap.UpdateCost -- backwards compat aliases

--[=[
    @private

    *This has been removed from the public API Docs as it can be
    achieved by iterating over the heap and counting the occurrences.*

    Returns the cost given to a value. If no value is found, nil is returned.
    :::caution Repeated Values
    If you have multiple instances of the same value, this method will return the cost of the first instance found.
    There is no guarantee of which instance will be found first.
    :::
]=]
function Heap:GetCost<T>(valueToCheckCostOf: T): number?
	for refIdx, value in pairs(self._Values) do
		if value == valueToCheckCostOf then
			return self._Costs[refIdx]
		end
	end
	return nil
end
-- Alias for backwards compat of old version, this was changed to keep wording consistent between method names
Heap.GetCostFromValue = Heap.GetCost
Heap.GetCostOfValue = Heap.GetCost

--[=[
    @private
    Returns the number of occurrences of a value in the heap.

    *This has been removed from the public API Docs as it can be
    achieved by iterating over the heap and counting the occurrences.*

    *Time Complexity:* Runs in `O(n)` time.
]=]
function Heap:CountOccurrences<T>(valueToCheckFor: T): number
	local count = 0
	for _, value in pairs(self._Values) do
		if value == valueToCheckFor then
			count += 1
		end
	end
	return count
end

--[=[
    Removes the first occurrence of a given value from the heap.
    Heaps are not optimized for search removals, so this method should
    be used sparingly.
    
    :::note Performance
    This operation requires O(n) search time to locate the element, followed by O(log n) heapify.
    A reverse mapping (refIdx → heapPos) could reduce this to O(log n), but would add memory overhead
    and complexity to maintain across all heap operations. For typical use cases where Push/Pop
    dominate, the current approach favors simplicity and lower memory usage.
    :::
]=]
function Heap:RemoveFirstOccurrence<T>(valueToRemove: T): boolean
	for refIdx, value in pairs(self._Values) do
		if value == valueToRemove then
			-- Find the heap position where this refIdx is located (O(n) search)
			-- Note: Could be optimized to O(1) with a reverse mapping at cost of extra memory
			local heapPos = nil
			for i = 1, self._Size do
				if self._HeapIndex[i] == refIdx then
					heapPos = i
					break
				end
			end
			
			if not heapPos then
				-- This shouldn't happen, but handle it gracefully
				return false
			end

			-- Remove the value and cost
			self._Values[refIdx] = nil
			self._Costs[refIdx] = nil

			-- Store freed index for reuse
			table.insert(self._OpenIndices, refIdx)

			-- If this was the last element, just remove it
			if heapPos == self._Size then
				self._HeapIndex[self._Size] = nil
				self._Size -= 1
				return true
			end

			-- Move last element to the removed position
			local lastRefIdx = self._HeapIndex[self._Size]
			self._HeapIndex[heapPos] = lastRefIdx
			self._HeapIndex[self._Size] = nil
			self._Size -= 1

			-- Heapify from the position (determine direction based on heap property)
			if self._Size > 0 then
				-- Optimization: Only heapify in ONE direction by checking parent
				-- Logic: If element violates heap property with parent, it MUST go up
				--        If element satisfies heap property with parent, it CAN'T go up,
				--        so we check if it needs to go down (heapifyDown checks children)
				-- This avoids calling both heapifyUp AND heapifyDown unnecessarily
				if heapPos > 1 then
					local parent = math.floor(heapPos / 2)
					local movedCost = self._Costs[lastRefIdx]
					local parentCost = self._Costs[self._HeapIndex[parent]]
					
					-- Check if moved element violates heap property with parent
					local needsHeapifyUp = (self._isMinHeap and movedCost < parentCost)
						or (not self._isMinHeap and movedCost > parentCost)
					
					if needsHeapifyUp then
						self:_heapifyUp(heapPos)
					else
						self:_heapifyDown(heapPos)
					end
				else
					-- At root, can only heapify down
					self:_heapifyDown(heapPos)
				end
			end

			return true
		end
	end
	return false
end

--[=[
    Removes all occurrences of a value from the heap and returns the
    number of occurrences removed. Heaps are not optimized for search 
    removals, so this method should be used sparingly.
]=]
function Heap:RemoveAllOccurrences<T>(valueToRemove: T): number
	local count = 0
	-- Collect all refIdx values to remove (can't modify while iterating)
	local toRemove = {}
	for refIdx, value in pairs(self._Values) do
		if value == valueToRemove then
			table.insert(toRemove, refIdx)
		end
	end
	
	-- Remove each occurrence
	for _, refIdx in ipairs(toRemove) do
		-- Find the heap position where this refIdx is located
		local heapPos = nil
		for i = 1, self._Size do
			if self._HeapIndex[i] == refIdx then
				heapPos = i
				break
			end
		end
		
		if heapPos then
			-- Remove the value and cost
			self._Values[refIdx] = nil
			self._Costs[refIdx] = nil

			-- Store freed index for reuse
			table.insert(self._OpenIndices, refIdx)

			-- If this was the last element, just remove it
			if heapPos == self._Size then
				self._HeapIndex[self._Size] = nil
				self._Size -= 1
			else
				-- Move last element to the removed position
				local lastRefIdx = self._HeapIndex[self._Size]
				self._HeapIndex[heapPos] = lastRefIdx
				self._HeapIndex[self._Size] = nil
				self._Size -= 1

				-- Heapify from the position (determine direction based on heap property)
				if self._Size > 0 then
					-- Optimization: Only heapify in ONE direction (see RemoveFirstOccurrence for details)
					if heapPos > 1 then
						local parent = math.floor(heapPos / 2)
						local movedCost = self._Costs[lastRefIdx]
						local parentCost = self._Costs[self._HeapIndex[parent]]
						
						-- Check if moved element violates heap property with parent
						local needsHeapifyUp = (self._isMinHeap and movedCost < parentCost)
							or (not self._isMinHeap and movedCost > parentCost)
						
						if needsHeapifyUp then
							self:_heapifyUp(heapPos)
						else
							self:_heapifyDown(heapPos)
						end
					else
						-- At root, can only heapify down
						self:_heapifyDown(heapPos)
					end
				end
			end
			
			count += 1
		end
	end
	return count
end

--[=[
    A utility method that converts the heap into a tree structure.
    This is useful for debugging and visualizing the heap.
    
    `type Branch<T> = {Value: T, Left: Branch<T>?, Right: Branch<T>?}`

    @return Branch<T>? -- A tree representation of the heap.
]=]
function Heap:ToTree<T>(): Branch<T>?
	local function buildTree(index, depth)
		if index > #self._Data then
			return nil
		end
		return {
			Value = self._Data[index],
			Left = buildTree(index * 2, depth + 1),
			Right = buildTree(index * 2 + 1, depth + 1),
		}
	end
	return buildTree(1, 0)
end

--------------------------------------------------------------------------------
--// Heapify Methods //--
--------------------------------------------------------------------------------

--[=[
    @private
    Restores the heap order by moving a node up towards the root.

    This is excessively large bc splitting the min/max heap comparators reduces
    the number of comparisons each loop. Its not a huge performance boost, but
    it is a performance boost.
]=]
function Heap:_heapifyUp(index: number)
	local Costs, HeapIndex = self._Costs, self._HeapIndex
	if self._isMinHeap then
		while index > 1 do
			local parent = math.floor(index / 2)
			local currentIndex = HeapIndex[index]
			local parentIndex = HeapIndex[parent]
			if Costs[currentIndex] < Costs[parentIndex] then
				HeapIndex[index], HeapIndex[parent] = parentIndex, currentIndex
				index = parent
			else
				break
			end
		end
	else
		while index > 1 do
			local parent = math.floor(index / 2)
			local currentIndex = HeapIndex[index]
			local parentIndex = HeapIndex[parent]
			if Costs[currentIndex] > Costs[parentIndex] then
				HeapIndex[index], HeapIndex[parent] = parentIndex, currentIndex
				index = parent
			else
				break
			end
		end
	end
end

--[=[
    @private
    Restores the heap order by moving a node down towards the leaves.

    This is excessively large bc splitting the min/max heap comparators reduces
    the number of comparisons each loop. Its not a huge performance boost, but
    it is a performance boost.
]=]
function Heap:_heapifyDown(index: number)
	local Size, Costs, HeapIndex = self._Size, self._Costs, self._HeapIndex
	if self._isMinHeap then
		while true do
			local left, right, smallest = index * 2, index * 2 + 1, index

			if left <= Size and Costs[HeapIndex[left]] < Costs[HeapIndex[smallest]] then
				smallest = left
			end
			if right <= Size and Costs[HeapIndex[right]] < Costs[HeapIndex[smallest]] then
				smallest = right
			end

			if smallest == index then
				break
			end

			-- Swap the _HeapIndex pointers
			HeapIndex[index], HeapIndex[smallest] = HeapIndex[smallest], HeapIndex[index]

			index = smallest
		end
	else
		while true do
			local left, right, largest = index * 2, index * 2 + 1, index

			if left <= Size and Costs[HeapIndex[left]] > Costs[HeapIndex[largest]] then
				largest = left
			end
			if right <= Size and Costs[HeapIndex[right]] > Costs[HeapIndex[largest]] then
				largest = right
			end

			if largest == index then
				break
			end

			-- Swap the _HeapIndex pointers
			HeapIndex[index], HeapIndex[largest] = HeapIndex[largest], HeapIndex[index]

			index = largest
		end
	end
end

--------------------------------------------------------------------------------
--// MetaMethods //--
--------------------------------------------------------------------------------

--[=[
    @private
    @tag metamethod
    Metamethod for the len operator `#`.

    Returns the number of elements in the heap.
    ```lua
    local minHeap = Heap.min()
    minHeap:Push("A", 5)
    minHeap:Push("B", 2)
    print(#minHeap) -- 2
    ```
]=]
function Heap:__len(): number
	return self._Size
end

--[=[
    @private
    @tag metamethod
    Metamethod for tostring.

    Attempts to return a string representation of the heap in a tree like display.
]=]
function Heap:__tostring(): string
	local function buildTree(index, depth, isLeft)
		if index > self._Size then
			return ""
		end

		local left = buildTree(index * 2, depth + 1, true)
		local right = buildTree(index * 2 + 1, depth + 1, false)

		local prefix = string.rep("    ", depth)
		local branch = isLeft and "\\" or "/"

		if depth == 0 then
			return tostring(self._Values[self._HeapIndex[index]]) .. "\n" .. right .. left
		end

		return right .. prefix .. branch .. " " .. tostring(self._Values[self._HeapIndex[index]]) .. "\n" .. left
	end

	local success, heapString = pcall(buildTree, 1, 0)
	if not success then
		return "[Heap.__tostring() - Error building tree]"
	end
	return "Heap:\n" .. heapString
end

--[=[
    @tag metamethod
    @within Heap
    @return value: T
    @return cost: number
    MetaMethod for iterating over the heap.
    In a for loop, the first variable is the `Value` and the second variable is the `Cost`.

    ```lua
    local minHeap = Heap.min()
    minHeap:Push("A", 5)
    minHeap:Push("B", 2)
    minHeap:Push("C", 8)
    minHeap:Push("A", 4)
    minHeap:Push("D", 10)

    for value: string, cost: number in minHeap do
        print(value, cost)
    end
    ```
    ```
    -- Output: the order may vary
    B 2
    A 4
    C 8
    A 5
    D 10
    ```

    :::caution Manipulating the Heap during iteration
    It is not recommended to modify the Heap during iteration as it may cause undefined behavior.
    Internal orders may change and the iterator may not be able to find the next value.
    :::

    :::caution Iteration Order
    There is no guaranteed order of iteration. You should assume you will receive the values in a random order.
    :::
]=]
function Heap:__iter<T>()
	local index = 0
	return function()
		index += 1
		local refIdx = self._HeapIndex[index]
		if refIdx ~= nil then
			return self._Values[refIdx], self._Costs[refIdx]
		end
		return nil, nil
	end
end

table.freeze(Heap)
return table.freeze(HeapClass)
