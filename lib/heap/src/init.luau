-- Author: Logan Hunt (Raild3x)
--[=[
    @class Heap
    A generic heap implementation supporting both min-heap, max-heap, and custom comparators.

    Heaps are useful datastructures for tracking the smallest or largest element in an array.
    They are commonly used in algorithms like Dijkstra's shortest path algorithm and Huffman coding.

    ```lua
    local minHeap = Heap.min()
    minHeap:Push(5)
    minHeap:Push(2)
    minHeap:Push(8)
    print(minHeap:Peek()) -- 2
    ```

    ```lua
    local maxHeap = Heap.max()
    maxHeap:Push(5)
    maxHeap:Push(2)
    maxHeap:Push(8)
    print(maxHeap:Peek()) -- 8
    ```

    :::info MetaMethods
    Supports the following metamethods:
    - `__tostring`: Returns a string representation of the heap in a tree like display.
    - `__len`: Returns the number of elements in the heap. Equivalent to calling `:Size()`.
]=]


export type Heap<T> = {
    ClassName: "Heap",

    --- Inserts a value into the heap.
    Push: (self: Heap<T>, value: T) -> (),

    --- Removes and returns the top value from the heap.
    Pop: (self: Heap<T>) -> T?,

    --- Returns the top value from the heap without removing it.
    Peek: (self: Heap<T>) -> T?,

    --- Checks if the heap contains a specified value.
    Has: (self: Heap<T>, valueToCheck: T) -> boolean,

    --- Returns the number of elements in the heap.
    Size: (self: Heap<T>) -> number,

    --- Removes the first occurrence of a given value from the heap.
    RemoveFirst: (self: Heap<T>, value: T) -> boolean,

    --- Removes all occurrences of a given value from the heap.
    RemoveAll: (self: Heap<T>, value: T) -> boolean,
}


local Heap = {}
Heap.__index = Heap
Heap.ClassName = "Heap"

--[=[
    Creates a new heap with a custom comparator.

    @param comparator -- A function that defines the heap ordering.
    @return Heap<T> -- A new heap instance.

    ```lua
    local personA = { name = "Alice", age = 25 }
    local personB = { name = "Bob", age = 30 }
    local personC = { name = "Charlie", age = 20 }


    local youngestPersonHeap = Heap.new(function(a, b)
        return a.age < b.age
    end)

    minHeap:Push(personA)
    print(minHeap:Peek()) -- { name = "Alice", age = 25 }
    minHeap:Push(personB)
    print(minHeap:Peek()) -- { name = "Alice", age = 25 }
    minHeap:Push(personC)
    print(minHeap:Peek()) -- { name = "Charlie", age = 20 }
    ```
]=]
function Heap.new<T>(comparator: (a: T, b: T) -> boolean): Heap<T>
    assert(typeof(comparator) == "function", "comparator must be a function")
    return setmetatable({
        _Data = {} :: {T},
        _Comparator = comparator,
    }, Heap) :: any
end

--[=[
    Creates a min-heap where the smallest element is always on top.
    @return Heap<T> -- A min-heap instance.
]=]
function Heap.min<T>(): Heap<T>
    return Heap.new(function(a, b) return a < b end)
end

--[=[
    Creates a max-heap where the largest element is always on top.
    @return Heap<T> -- A max-heap instance.
]=]
function Heap.max<T>(): Heap<T>
    return Heap.new(function(a, b) return a > b end)
end

--[=[
    Inserts a value into the heap.
]=]
function Heap:Push<T>(value: T)
    table.insert(self._Data, value)
    self:_heapifyUp(#self._Data)
end

--[=[
    Removes and returns the top value from the heap.
]=]
function Heap:Pop<T>(): T?
    local Data = self._Data
    if #Data == 0 then return nil end
    local root = Data[1]
    Data[1] = Data[#Data]
    Data[#Data] = nil
    self:_heapifyDown(1)
    return root
end

--[=[
    Returns the top value from the heap without removing it.
]=]
function Heap:Peek<T>(): T?
    return self._Data[1]
end

--[=[
    Checks if the heap contains a specified value.
]=]
function Heap:Has<T>(valueToCheck: T): boolean
    return table.find(self._Data, valueToCheck) ~= nil    
end

--[=[
    Returns the number of elements in the heap.
]=]
function Heap:Size(): number
    return #self._Data
end

--[=[
    Removes the first occurrence of a given value from the heap.
    Heaps are not optimized for removals, so this method should
    be used sparingly.
]=]
function Heap:RemoveFirst<T>(value: T): boolean
    local Data = self._Data
    for i = 1, #Data do
        if Data[i] == value then
            Data[i] = Data[#Data]
            Data[#Data] = nil
            self:_heapifyDown(i)
            self:_heapifyUp(i)
            return true
        end
    end
    return false
end

--[=[
    Removes all occurrences of a value from the heap and returns the number of occurrences removed.
]=]
function Heap:RemoveAll<T>(value: T): number
    local Data = self._Data
    local count = 0
    local i = 1
    while i <= #Data do
        if Data[i] == value then
            Data[i] = Data[#Data]
            Data[#Data] = nil
            self:_heapifyDown(i)
            self:_heapifyUp(i)
            count += 1
        else
            i += 1
        end
    end
    return count
end

--[=[
    @private
    Restores the heap order by moving a node up.

    @param index number -- The index to adjust.
]=]
function Heap:_heapifyUp(index: number)
    local data, comparator = self._Data, self._Comparator
    while index > 1 do
        local parent = math.floor(index / 2)
        if comparator(data[index], data[parent]) then
            data[index], data[parent] = data[parent], data[index]
            index = parent
        else
            break
        end
    end
end

--[=[
    @private
    Restores the heap order by moving a node down.

    @param index number -- The index to adjust.
]=]
function Heap:_heapifyDown(index: number)
    local data, comparator = self._Data, self._Comparator
    local size = #data
    while true do
        local left, right, best = index * 2, index * 2 + 1, index

        if left <= size and comparator(data[left], data[best]) then 
            best = left
        end
        if right <= size and comparator(data[right], data[best]) then 
            best = right 
        end

        if best == index then break end
        data[index], data[best] = data[best], data[index]
        index = best
    end
end

--[=[
    @private
    Metamethod for the len operator `#`.
    Returns the number of elements in the heap.
]=]
function Heap:__len(): number
    return self:Size()
end

--[=[
    @private
    Metamethod for tostring.
    Attempts to return a string representation of the heap in a tree like display.
]=]
function Heap:__tostring(): string
    local function buildTree(index, depth)
        if index > #self._Data then return "" end
        local left = buildTree(index * 2, depth + 1)
        local right = buildTree(index * 2 + 1, depth + 1)
        return right .. string.rep("  ", depth) .. tostring(self._Data[index]) .. "\n" .. left
    end
    return "Heap:\n" .. buildTree(1, 0)
end


return table.freeze(Heap)