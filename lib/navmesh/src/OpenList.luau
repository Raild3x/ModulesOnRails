--!strict
--!native
-- Authors: Logan Hunt (Raildex)
-- September 26, 2026
--[=[
	@class OpenList
	@private

	The A* open list: a 4-ary min-heap of (node, key) pairs on parallel arrays.

	Chosen by benchmark (bench.md, "A* open list"): across floors of 64 to 1024 studs it was
	the fastest from about 50 entries up, and 1.5-1.7x faster than `lib/heap`. Four children
	per level halve the tree depth, so a push or pop moves about half as many entries as a
	binary heap, for a few more comparisons.

	There is no decrease-key. A node whose cost improves is pushed again, and the search
	skips the stale entry when it pops (it is already closed). Only 2-7% of pops were stale,
	and decrease-key's position index cost more than it saved.
]=]

export type OpenList = {
	Nodes: { number },
	Keys: { number },
	Size: number,
}

local OpenList = {}

function OpenList.new(): OpenList
	return { Nodes = {}, Keys = {}, Size = 0 }
end

--[=[
	Empties the list, keeping its arrays for reuse.
]=]
function OpenList.Clear(o: OpenList)
	o.Size = 0
end

function OpenList.Size(o: OpenList): number
	return o.Size
end

--[=[
	Adds `node` with priority `key` (smaller comes out first).
]=]
function OpenList.Push(o: OpenList, node: number, key: number)
	local nodes, keys = o.Nodes, o.Keys
	local i = o.Size + 1
	o.Size = i
	while i > 1 do
		local p = (i + 2) // 4 -- parent; the children of p are 4p-2 .. 4p+1
		if keys[p] <= key then
			break
		end
		nodes[i], keys[i] = nodes[p], keys[p]
		i = p
	end
	nodes[i], keys[i] = node, key
end

--[=[
	Removes and returns the entry with the smallest key: (node, key), or (0, 0) when empty.
]=]
function OpenList.Pop(o: OpenList): (number, number)
	local size = o.Size
	if size == 0 then
		return 0, 0
	end
	local nodes, keys = o.Nodes, o.Keys
	local top, topKey = nodes[1], keys[1]
	local node, key = nodes[size], keys[size]
	size -= 1
	o.Size = size
	local i = 1
	while true do
		local first = 4 * i - 2
		if first > size then
			break
		end
		local child, childKey = first, keys[first]
		for k = first + 1, math.min(first + 3, size) do
			if keys[k] < childKey then
				child, childKey = k, keys[k]
			end
		end
		if childKey >= key then
			break
		end
		nodes[i], keys[i] = nodes[child], childKey
		i = child
	end
	nodes[i], keys[i] = node, key
	return top, topKey
end

return OpenList
