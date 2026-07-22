--!strict
--!native

--[=[
	Incremental 2D KD-tree for O(log n) nearest-vertex queries.

	Port of CDT's KDTree.h + LocatorKDTree.h (André Fecteau, MPL-2.0).

	Typical usage:
	  1. After adding super-triangle vertices, call `initialize(vertices)`.
	     This resets the tree, computes a tight bounding box from the supplied
	     vertices, and bulk-inserts them all.
	  2. After inserting each new user vertex into the triangulation, call
	     `addPoint(iV, vertices)` to register it with the locator.
	  3. To find the nearest already-inserted vertex to a query point, call
	     `nearPoint(query, vertices)` which returns a 1-based vertex index.
]=]

-- Leaf capacity before splitting (matches C++ LocatorKDTree default).
local LEAF_CAPACITY = 32

local DIR_X = 1
local DIR_Y = 2

-- 7 numbers per stack task in the nearPoint flat stack:
--   [base+1] nodeIdx
--   [base+2] minX     [base+3] minY
--   [base+4] maxX     [base+5] maxY
--   [base+6] dir      [base+7] distSq
local TASK_STRIDE = 7

-- ── types ────────────────────────────────────────────────────────────────────

type KDNode = {
	children: { number }, -- {c1, c2}; both 0 when leaf
	data: { number }, -- 1-based vertex indices (only used in leaves)
}

export type KDLocator = {
	initialize: (self: KDLocator, vertices: { Vector2 }) -> (),
	addPoint: (self: KDLocator, iV: number, vertices: { Vector2 }) -> (),
	nearPoint: (self: KDLocator, query: Vector2, vertices: { Vector2 }) -> number,
	isEmpty: (self: KDLocator) -> boolean,
}

type KDLocatorInternal = {
	_nodes: { KDNode },
	_root: number,
	_rootDir: number,
	_minX: number,
	_minY: number,
	_maxX: number,
	_maxY: number,
	_size: number,
	_boxInitialized: boolean,
	-- Flat stack recycled across nearPoint calls to avoid GC pressure.
	_taskStack: { number },
} & KDLocator

-- ── private helpers ──────────────────────────────────────────────────────────

local function addNode(self: KDLocatorInternal): number
	local nodes = self._nodes
	local idx = #nodes + 1
	nodes[idx] = { children = { 0, 0 }, data = {} }
	return idx
end

local function isLeaf(node: KDNode): boolean
	return node.children[1] == 0
end

-- Squared distance from point (px, py) to an axis-aligned bounding box.
-- Returns 0 when the point is inside the box.
local function distSqToBox(px: number, py: number, minX: number, minY: number, maxX: number, maxY: number): number
	local dx = math.max(math.max(minX - px, 0), px - maxX)
	local dy = math.max(math.max(minY - py, 0), py - maxY)
	return dx * dx + dy * dy
end

-- Lazy bounding-box initialisation: scan the root leaf's data bucket for the
-- actual axis extents and write them to self. Called only once, the first time
-- a leaf overflows before an explicit initialize() call.
local function initRootBox(self: KDLocatorInternal, vertices: { Vector2 })
	local rootData = self._nodes[self._root].data
	local v0 = vertices[rootData[1]]
	local minX, minY = v0.X, v0.Y
	local maxX, maxY = minX, minY
	for _, iV in rootData do
		local v = vertices[iV]
		local vx, vy = v.X, v.Y
		if vx < minX then
			minX = vx
		end
		if vy < minY then
			minY = vy
		end
		if vx > maxX then
			maxX = vx
		end
		if vy > maxY then
			maxY = vy
		end
	end
	-- Ensure the box has non-zero extent on both axes.
	if minX == maxX then
		minX -= 1
		maxX += 1
	end
	if minY == maxY then
		minY -= 1
		maxY += 1
	end
	self._minX = minX
	self._minY = minY
	self._maxX = maxX
	self._maxY = maxY
	self._boxInitialized = true
end

-- Grow the root bounding box to accommodate a point that lies outside it.
-- Creates a new root node (splitting on the opposite axis) whose children are
-- the old root and a new empty leaf. The box doubles along the out-of-bounds
-- dimension.
local function extendTree(self: KDLocatorInternal, px: number, py: number)
	local newRoot = addNode(self)
	local newLeaf = addNode(self)
	local dir = self._rootDir
	local nodes = self._nodes
	if dir == DIR_X then
		-- New root will split along Y; extend the Y range.
		self._rootDir = DIR_Y
		local height = self._maxY - self._minY
		if py < self._minY then
			self._minY -= height
			nodes[newRoot].children = { newLeaf, self._root }
		else
			self._maxY += height
			nodes[newRoot].children = { self._root, newLeaf }
		end
	else
		-- New root will split along X; extend the X range.
		self._rootDir = DIR_X
		local width = self._maxX - self._minX
		if px < self._minX then
			self._minX -= width
			nodes[newRoot].children = { newLeaf, self._root }
		else
			self._maxX += width
			nodes[newRoot].children = { self._root, newLeaf }
		end
	end
	self._root = newRoot
end

-- Insert vertex index iPoint into the tree.
-- Splits a leaf that reaches LEAF_CAPACITY into two children, distributing
-- existing data. After splitting, continues descent to insert the new point.
local function insertPoint(self: KDLocatorInternal, iPoint: number, vertices: { Vector2 })
	self._size += 1
	local pos = vertices[iPoint]
	local px, py = pos.X, pos.Y

	-- Extend the root box if this point falls outside it (only when the box
	-- has already been initialised).
	if self._boxInitialized then
		while px < self._minX or px > self._maxX or py < self._minY or py > self._maxY do
			extendTree(self, px, py)
		end
	end

	local nodeIdx = self._root
	local minX, minY = self._minX, self._minY
	local maxX, maxY = self._maxX, self._maxY
	local dir = self._rootDir
	local nodes = self._nodes

	while true do
		local node = nodes[nodeIdx]
		if isLeaf(node) then
			local data = node.data
			if #data < LEAF_CAPACITY then
				-- Leaf has room; add and finish.
				data[#data + 1] = iPoint
				return
			end
			-- Leaf is full. Lazily initialise the root box if needed.
			if not self._boxInitialized then
				initRootBox(self, vertices)
				minX = self._minX
				minY = self._minY
				maxX = self._maxX
				maxY = self._maxY
			end
			-- Split the full leaf into two children.
			local c1 = addNode(self)
			local c2 = addNode(self)
			nodes = self._nodes -- re-fetch; addNode may have grown the array
			node = nodes[nodeIdx]
			node.children[1] = c1
			node.children[2] = c2
			local c1data = nodes[c1].data
			local c2data = nodes[c2].data
			if dir == DIR_X then
				local mid = (minX + maxX) * 0.5
				for _, idx in data do
					if vertices[idx].X <= mid then
						c1data[#c1data + 1] = idx
					else
						c2data[#c2data + 1] = idx
					end
				end
			else
				local mid = (minY + maxY) * 0.5
				for _, idx in data do
					if vertices[idx].Y <= mid then
						c1data[#c1data + 1] = idx
					else
						c2data[#c2data + 1] = idx
					end
				end
			end
			table.clear(data)
			-- node is now internal; fall through to navigate down.
		end

		-- Navigate into the appropriate child based on the split direction.
		if dir == DIR_X then
			local mid = (minX + maxX) * 0.5
			dir = DIR_Y
			if px <= mid then
				maxX = mid
				nodeIdx = nodes[nodeIdx].children[1]
			else
				minX = mid
				nodeIdx = nodes[nodeIdx].children[2]
			end
		else
			local mid = (minY + maxY) * 0.5
			dir = DIR_X
			if py <= mid then
				maxY = mid
				nodeIdx = nodes[nodeIdx].children[1]
			else
				minY = mid
				nodeIdx = nodes[nodeIdx].children[2]
			end
		end
	end
end

-- ── public class ─────────────────────────────────────────────────────────────

local KDLocator = {}
KDLocator.__index = KDLocator

--[=[
	Construct a new, empty KDLocator.

	@return KDLocator
]=]
function KDLocator.new(): KDLocator
	local self = setmetatable({}, KDLocator) :: any
	self._nodes = { { children = { 0, 0 }, data = {} } }
	self._root = 1
	self._rootDir = DIR_X
	self._minX = -math.huge
	self._minY = -math.huge
	self._maxX = math.huge
	self._maxY = math.huge
	self._size = 0
	self._boxInitialized = false
	self._taskStack = {}
	return self :: any
end

--[=[
	Reset the tree and bulk-insert every vertex in `vertices`.

	Computes a tight axis-aligned bounding box from the supplied vertices
	before inserting, which ensures that no subsequent insertion will trigger
	extendTree (provided all future vertices lie inside the same spatial
	envelope, as guaranteed when vertices includes the super-triangle).

	@param vertices -- the full vertex array (1-based Vector2 values)
]=]
function KDLocator.initialize(self: KDLocatorInternal, vertices: { Vector2 })
	-- Reset to a single empty root leaf.
	self._nodes = { { children = { 0, 0 }, data = {} } }
	self._root = 1
	self._rootDir = DIR_X
	self._size = 0
	self._boxInitialized = false

	local count = #vertices
	if count == 0 then
		return
	end

	-- Compute bounding box from all provided vertices.
	local v0 = vertices[1]
	local minX, minY = v0.X, v0.Y
	local maxX, maxY = minX, minY
	for i = 2, count do
		local v = vertices[i]
		local vx, vy = v.X, v.Y
		if vx < minX then
			minX = vx
		end
		if vy < minY then
			minY = vy
		end
		if vx > maxX then
			maxX = vx
		end
		if vy > maxY then
			maxY = vy
		end
	end
	if minX == maxX then
		minX -= 1
		maxX += 1
	end
	if minY == maxY then
		minY -= 1
		maxY += 1
	end
	self._minX = minX
	self._minY = minY
	self._maxX = maxX
	self._maxY = maxY
	self._boxInitialized = true

	-- Bulk-insert all vertices.
	for i = 1, count do
		insertPoint(self, i, vertices)
	end
end

--[=[
	Incrementally register vertex iV after it has been added to the
	triangulation's vertex array.

	@param iV      -- 1-based index of the newly added vertex
	@param vertices -- the full vertex array
]=]
function KDLocator.addPoint(self: KDLocatorInternal, iV: number, vertices: { Vector2 })
	insertPoint(self, iV, vertices)
end

--[=[
	Return the 1-based index of the nearest already-inserted vertex to `query`.

	Uses a branch-and-bound stack traversal: the closer child is always
	processed before the farther child, and subtrees whose bounding-box
	distance exceeds the current best are pruned.

	Hot-path arithmetic uses raw scalar operations rather than Vector2 methods
	to avoid object allocation overhead.

	@param query    -- the query point
	@param vertices -- the full vertex array
	@return number  -- 1-based index of the nearest vertex, or 0 if empty
]=]
function KDLocator.nearPoint(self: KDLocatorInternal, query: Vector2, vertices: { Vector2 }): number
	if self._size == 0 then
		return 0
	end

	local qx, qy = query.X, query.Y
	local bestDistSq = math.huge
	local bestIdx = 0

	local nodes = self._nodes
	local s = self._taskStack

	-- Push the root task.
	s[1] = self._root
	s[2] = self._minX
	s[3] = self._minY
	s[4] = self._maxX
	s[5] = self._maxY
	s[6] = self._rootDir
	s[7] = distSqToBox(qx, qy, self._minX, self._minY, self._maxX, self._maxY)
	local top = 1

	while top > 0 do
		local base = (top - 1) * TASK_STRIDE
		local nodeIdx = s[base + 1] :: number
		local tMinX = s[base + 2] :: number
		local tMinY = s[base + 3] :: number
		local tMaxX = s[base + 4] :: number
		local tMaxY = s[base + 5] :: number
		local tDir = s[base + 6] :: number
		local tDistSq = s[base + 7] :: number
		top -= 1

		-- Prune this subtree if its closest possible point is already farther
		-- than the current best.
		if tDistSq > bestDistSq then
			continue
		end

		local node = nodes[nodeIdx]
		if isLeaf(node) then
			-- Scan every point in the leaf.
			for _, iV in node.data do
				local v = vertices[iV]
				local dx = v.X - qx
				local dy = v.Y - qy
				local d = dx * dx + dy * dy
				if d < bestDistSq then
					bestDistSq = d
					bestIdx = iV
				end
			end
		else
			-- Compute the split and boxes of both children.
			local newDir = if tDir == DIR_X then DIR_Y else DIR_X
			local c1 = node.children[1]
			local c2 = node.children[2]

			local c1MinX, c1MinY, c1MaxX, c1MaxY: number
			local c2MinX, c2MinY, c2MaxX, c2MaxY: number

			if tDir == DIR_X then
				local mid = (tMinX + tMaxX) * 0.5
				c1MinX = tMinX
				c1MinY = tMinY
				c1MaxX = mid
				c1MaxY = tMaxY
				c2MinX = mid
				c2MinY = tMinY
				c2MaxX = tMaxX
				c2MaxY = tMaxY
			else
				local mid = (tMinY + tMaxY) * 0.5
				c1MinX = tMinX
				c1MinY = tMinY
				c1MaxX = tMaxX
				c1MaxY = mid
				c2MinX = tMinX
				c2MinY = mid
				c2MaxX = tMaxX
				c2MaxY = tMaxY
			end

			local d1 = distSqToBox(qx, qy, c1MinX, c1MinY, c1MaxX, c1MaxY)
			local d2 = distSqToBox(qx, qy, c2MinX, c2MinY, c2MaxX, c2MaxY)

			-- Push the farther child first (deeper in stack) so the closer
			-- child is processed next. Only push subtrees that might improve
			-- bestDistSq.
			if d1 <= d2 then
				-- c1 is closer.
				if d2 <= bestDistSq then
					local b = top * TASK_STRIDE
					s[b + 1] = c2
					s[b + 2] = c2MinX
					s[b + 3] = c2MinY
					s[b + 4] = c2MaxX
					s[b + 5] = c2MaxY
					s[b + 6] = newDir
					s[b + 7] = d2
					top += 1
				end
				if d1 <= bestDistSq then
					local b = top * TASK_STRIDE
					s[b + 1] = c1
					s[b + 2] = c1MinX
					s[b + 3] = c1MinY
					s[b + 4] = c1MaxX
					s[b + 5] = c1MaxY
					s[b + 6] = newDir
					s[b + 7] = d1
					top += 1
				end
			else
				-- c2 is closer.
				if d1 <= bestDistSq then
					local b = top * TASK_STRIDE
					s[b + 1] = c1
					s[b + 2] = c1MinX
					s[b + 3] = c1MinY
					s[b + 4] = c1MaxX
					s[b + 5] = c1MaxY
					s[b + 6] = newDir
					s[b + 7] = d1
					top += 1
				end
				if d2 <= bestDistSq then
					local b = top * TASK_STRIDE
					s[b + 1] = c2
					s[b + 2] = c2MinX
					s[b + 3] = c2MinY
					s[b + 4] = c2MaxX
					s[b + 5] = c2MaxY
					s[b + 6] = newDir
					s[b + 7] = d2
					top += 1
				end
			end
		end
	end

	return bestIdx
end

-- Returns true when no vertices have been inserted yet.
function KDLocator.isEmpty(self: KDLocatorInternal): boolean
	return self._size == 0
end

return KDLocator
