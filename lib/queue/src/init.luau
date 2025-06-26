--!strict
-- Logan Hunt [Raildex]
-- September 13, 2023
--[=[
    @class Queue

    A generic [Queue](https://en.wikipedia.org/wiki/Queue_(abstract_data_type)) class for Luau.

    Queues are a type of data structure that follows the First In First Out (FIFO) principle.
    This means that the first element added to the queue will be the first to be removed.

    ```lua
    local queue = Queue.new()

    queue:Push(50)
    queue:Push(100)
    queue:Push(150)

    print(queue:Peek()) -- 50

    print(queue:Pop()) -- 50
    print(queue:Pop()) -- 100
    print(queue:Pop()) -- 150

    print(queue:Pop()) -- nil (queue is empty)
    ```

    :::tip Type Export
    This module exports a type `Queue<T>` which represents a Queue with values of type `T`.
    :::

    :::info MetaMethods
    Supports the following metamethods:
    - `__tostring`: Returns a string representation of the queue.
    - `__len`: Returns the number of elements in the queue. Equivalent to calling `:Size()`.
    - `__iter`: Iterates over the values in the queue.
    Check the private documentation for more information.
    :::
]=]

local Queue = {}
Queue.ClassName = "Queue"
Queue.__index = Queue

export type Queue<T> = {
    ClassName: string;
    -- __tostring: (self: Queue<T>) -> string;
    -- __iter: (self: Queue<T>) -> (any, T);
    -- __len: (self: Queue<T>) -> number;

    ---Creates a new Queue
    new: () -> Queue<T>;
    ---Look at the first value in the queue.
    Peek: (self: Queue<T>) -> T?;
    ---Remove and return the value at the front of the queue if there is one.
    Pop: (self: Queue<T>) -> T?;
    ---Add a value to the back of the queue.
    Push: (self: Queue<T>, value: T) -> ();
    ---Add a value to the front of the queue.
    Prepend: (self: Queue<T>, value: T) -> ();
    ---Converts the Queue into an iterable array.
    ToArray: (self: Queue<T>) -> {T};
    ---Check if the queue is empty.
    IsEmpty: (self: Queue<T>) -> boolean;
    ---Get the number of items in the Queue.
    Size: (self: Queue<T>) -> number;
    ---Checks to see if a given value exists within the Queue.
    Has: (self: Queue<T>, value: T) -> boolean;
    ---Returns the number of occurrences of a given value in the queue.
    CountOccurrences: (self: Queue<T>, value: T) -> number;
    ---Removes the first occurence of a given value in the queue. Returns whether or not it did remove something.
    RemoveFirstOccurence: (self: Queue<T>, value: T) -> boolean;
    ---Removes all occurences of a given value in the queue. Returns the number of items removed.
    RemoveAllOccurences: (self: Queue<T>, value: T) -> number;
    ---Removes the item at the given index. Returns whether or not it did remove something.
    RemoveValueAt: (self: Queue<T>, index: number) -> (boolean, T?);
}

--[=[
    @prop ClassName "Queue"
    @within Queue
]=]

--[=[
    @tag metamethod
    @within Queue
    @method __iter
    @return index: number
    @return value: T
    Iterates over the values in the Queue.
    ```lua
    local queue = Queue.new()
    queue:Push(50)
    queue:Push(100)
    for i, v in queue do
        print(i, v)
    end
    ```
    ```
    1 50
    2 100
    ```
]=]
Queue.__iter = function<T>(self: Queue<T>)
    return function(t, index: any)
        local v = t._queue[index + t._first]
        if v ~= nil then
            return index + 1, v
        end
        return nil, nil
    end, self, 0
end

--[=[
    @private
    @tag metamethod
    @within Queue
    @method __tostring
    @return string
    Converts the Queue into a string for easy reading.
    ```lua
    local queue = Queue.new()
    queue:Push(50)
    queue:Push(100)
    print(queue) -- <Queue> {50, 100}
    ```
]=]
Queue.__tostring = function<T>(t)
    local str = "<Queue> {"
    for i = t._first, t._last do
        str ..= tostring(t._queue[i])
        if i < t._last then
            str ..= ", "
        end
    end
	return str .."}"
end

--[=[
    @private
    @tag metamethod
    @within Queue
    @method __len
    @return number
    Returns the number of items in the Queue. Equivalent to calling `Queue:Size()`.
    ```lua
    local queue = Queue.new()
    queue:Push(50)
    queue:Push(100)
    print(#queue) -- 2
    ```
]=]
Queue.__len = function<T>(self: Queue<T>): number
    return self:Size()
end

--[=[
    @tag static
    Creates a new Queue
]=]
function Queue.new<T>(): Queue<T>
	return setmetatable({
        _first = 0;
        _last = -1;
        _queue = {};
    }, Queue) :: any
end

--[=[
    Look at the first value in the queue.
    If there is an index provided, it will look at the value at that index instead.
    ```lua
    local queue = Queue.new()
    queue:Push(50)
    queue:Push(100)
    queue:Push(150)
    print(queue:Peek()) -- 50
    print(queue:Peek(2)) -- 100
    queue:Pop()
    print(queue:Peek()) -- 100
    ```
]=]
function Queue:Peek<T>(index: number?): T?
    if index then
        return self._queue[self._first :: number + index - 1]
    end
    return self._queue[self._first]
end

--[=[
    Remove the value at the front of the queue if there is one.
]=]
function Queue:Pop<T>(): T?
	local first: number = self._first
	if self:IsEmpty() then
		return nil
	end
	local value = self._queue[first]
	self._queue[first] = nil
	self._first = first + 1
	return value
end
Queue.Dequeue = Queue.Pop

--[=[
    Add a value to the back of the queue.
]=]
function Queue:Push<T>(value: T)
	local last = self._last :: number + 1
	self._last = last
	self._queue[last] = value :: any
end
Queue.Enqueue = Queue.Push
Queue.Append = Queue.Push

--[=[
    Add a value to the front of the queue.
]=]
function Queue:Prepend<T>(value: T)
    local first = self._first :: number - 1
    self._first = first
    self._queue[first] = value
end

--[=[
    Get the number of items in the Queue.
]=]
function Queue:Size(): number
    return (self._last :: number - self._first) + 1
end

--[=[
    Check if the queue is empty.
]=]
function Queue:IsEmpty(): boolean
	return self._first :: number > self._last :: number
end


--[=[
    Converts the Queue into an iterable array.
]=]
function Queue:ToArray<T>(): {T}
    local tbl = table.create(self:Size())
    table.move(self._queue, self._first, self._last, 1, tbl)
    return tbl
end

--[=[
    Checks to see if a given value exists within the Queue.
]=]
function Queue:Has<T>(value: T): boolean
    for i = self._first, self._last do
        if self._queue[i] == value then
            return true
        end
    end
	return false
end

--[=[
    Returns the number of occurrences of a given value in the queue.
]=]
function Queue:CountOccurrences<T>(value: T): number
    local count = 0
    for i = self._first, self._last do
        if self._queue[i] == value then
            count += 1
        end
    end
    return count
end

--[=[
    Removes the first occurrence of a given value in the queue. Returns whether or not it did remove something.
]=]
function Queue:RemoveFirstOccurrence<T>(value: T): boolean
	if self:IsEmpty() then
		return false
	end
	
	local indexToRemove = nil

    -- Search for the first occurrence of the value.
    for i = self._first, self._last do
        if self._queue[i] == value then
            indexToRemove = i
            break
        end
    end

    -- If found, remove the element and shift the subsequent elements.
    if indexToRemove then
        for i = indexToRemove, self._last - 1 do
            self._queue[i] = self._queue[i + 1]
        end
        self._queue[self._last] = nil
        self._last = self._last - 1
        return true
    end

    return false
end

--[=[
    Removes all occurrences of a given value in the queue. Returns the number of items removed.
]=]
function Queue:RemoveAllOccurrences<T>(value: T): number
    if self:IsEmpty() then
        return 0
    end

    local writeIndex = self._first
    local count = 0

    -- Iterate through the queue, shifting down non-matching values
    for readIndex = self._first, self._last do
        if self._queue[readIndex] == value then
            count += 1
        else
            self._queue[writeIndex] = self._queue[readIndex]
            writeIndex += 1
        end
    end

    -- Adjust the last index after removals
    self._last = writeIndex - 1

    return count
end

--[=[
    Removes the item at the given index. Returns whether or not it did remove something.
    If it did, it will also return the item that was removed. This method should typically
    only be used in conjunction with the iterator metamethod.

    @param index -- The index of the item to remove.
    @return T | nil -- The item that was removed, or nil if the index was out of bounds or the queue is empty.
]=]
function Queue:RemoveValueAt<T>(index: number): (T | nil)
    if self:IsEmpty() then
        warn("Queue is empty")
        return nil
    end

    local internalIndex = self._first :: number + index - 1
    if internalIndex < self._first or internalIndex > self._last then
        warn(`Index '{index}' out of bounds`)
        return nil
    end
    local item = self._queue[internalIndex]

    if internalIndex == self._first then
        self._queue[self._first] = nil
        self._first += 1
    elseif internalIndex == self._last then
        self._queue[self._last] = nil
        self._last -= 1
    else
        for i = internalIndex, self._last - 1 do
            self._queue[i] = self._queue[i + 1]
        end
        self._queue[self._last] = nil
        self._last -= 1
    end

    return item
end


return table.freeze(Queue)