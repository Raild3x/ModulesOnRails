--!strict

--[=[
	@class Quadtree

	A sparse spatial index for storing objects by 2D position.
	
	The quadtree divides space into progressively smaller regions and stores nodes
	in the smallest region that contains their position. That makes spatial queries
	like radius searches and nearest-node lookups substantially cheaper than scanning
	an entire list.

	![Quadtree example gif](../quadtree/quadtreeExample.gif)

	```lua
	local Quadtree = require(path.to.quadtree)

	local tree = Quadtree.new(128)
	local node = tree:CreateNode(Vector2.new(10, 20), {
		Name = "SpawnPoint",
	})

	for entry in tree:ForEachInRadius(Vector2.new(0, 0), 64) do
		print(entry.Object.Name)
	end
	```

	:::tip Vector3 Support
	Internally, this implementation accepts both Vector2 and Vector3 inputs. When a
	Vector3 is provided, the Y component is ignored and the node is indexed using
	its X/Z coordinates.
	:::
]=]

--[=[
	@within Quadtree
	@type Vector Vector2 | Vector3
	Internally only Vector2 is used for positions, but Vector3 is accepted as input and will be converted to Vector2 by dropping the Y component.
]=]
type Vector = Vector2 | Vector3
export type Quadtree<T> = {
	--[[
		Removes every node from the quadtree.

		This clears all top-level regions and every nested region beneath them.

		Example:
		```lua
		tree:ClearAllNodes()
		print(tree:CountNodes()) -- 0
		```
	]]
	ClearAllNodes: (self: Quadtree<T>) -> (),
	--[[
		Returns all nodes currently stored in the quadtree as a flat array.

		Useful for debugging, snapshots, and bulk operations where iterator style
		is less convenient.

		Example:
		```lua
		local all = tree:GetAllNodes()
		for _, node in ipairs(all) do
			print(node.Position, node.Object)
		end
		```
	]]
	GetAllNodes: (self: Quadtree<T>) -> { Node<T> },
	--[[
		Returns an iterator that yields every node in the quadtree.

		Example:
		```lua
		for node in tree:ForEachNode() do
			print(node.Object)
		end
		```
	]]
	ForEachNode: (self: Quadtree<T>) -> () -> Node<T>?,
	--[[
		Returns the first node whose Object equals object, or nil when missing.

		```lua
		local node = tree:FindFirstNode("SpawnPoint")
		if node then
			print("Found at", node.Position)
		end
		```
	]]
	FindFirstNode: (self: Quadtree<T>, object: T) -> Node<T>?,
	--[[
		Returns the number of nodes currently stored in the quadtree.

		Example:
		```lua
		print(tree:CountNodes())
		```
	]]
	CountNodes: (self: Quadtree<T>) -> number,
	--[[
		Creates and inserts a node at position with payload object.

		If position is Vector3, the node is indexed using X/Z.

		Example:
		```lua
		local node = tree:CreateNode(Vector3.new(10, 5, 20), "Coin")
		print(node.Position) -- Vector2.new(10, 20)
		```
	]]
	CreateNode: (self: Quadtree<T>, position: Vector, object: T) -> Node<T>,
	--[[
		Removes node from the quadtree and returns whether removal occurred.

		Returns false when the node was already removed or no longer belongs to
		this quadtree.

		Example:
		```lua
		local didRemove = tree:RemoveNode(node)
		```
	]]
	RemoveNode: (self: Quadtree<T>, node: Node<T>) -> boolean,
	--[[
		Moves node to a new position.

		Example:
		```lua
		tree:ChangeNodePosition(node, Vector2.new(100, 0))
		```
	]]
	ChangeNodePosition: (self: Quadtree<T>, node: Node<T>, position: Vector) -> (),
	--[[
		Returns nodes whose positions are strictly within radius of position.

		Nodes exactly on the radius boundary are excluded.

		Example:
		```lua
		local nearby = tree:SearchRadius(Vector2.new(0, 0), 32)
		```
	]]
	SearchRadius: (self: Quadtree<T>, position: Vector, radius: number) -> { Node<T> },
	--[[
		Returns an iterator over nodes strictly within radius of position.

		Example:
		```lua
		for node in tree:ForEachInRadius(Vector2.new(0, 0), 32) do
			print(node.Object)
		end
		```
	]]
	ForEachInRadius: (self: Quadtree<T>, position: Vector, radius: number) -> () -> Node<T>?,
	--[[
		Returns nodes in ascending distance order, optionally capped by maxNodes.

		When maxNodes is provided, the list is sorted first and then truncated.

		Example:
		```lua
		local nearest = tree:GetNearest(Vector2.new(0, 0), 64, 5)
		```
	]]
	GetNearest: (self: Quadtree<T>, position: Vector, radius: number, maxNodes: number?) -> { Node<T> },
}

--[[
	Internal quadtree structure with spatial hashing.
	Regions uses string hash keys derived from grid-aligned positions for O(1) lookups.
	This enables efficient spatial partitioning without storing all regions in an array.
]]
type QuadtreeInternal<T> = Quadtree<T> & {
	Size: number,
	Regions: { [string]: Region<T> },
	_getRegion: (self: QuadtreeInternal<T>, maxLevel: number, position: Vector2) -> Region<T>,
}

type Region<T> = {
	Center: Vector2,
	Size: number,
	Radius: number,
	Regions: { Region<T> },
	Parent: Region<T>?,
	Level: number,
	Nodes: { Node<T> }?,
}

--[=[
	@within Quadtree
	@type Node<T> {Position: Vector2, Object: T}

	A node stored inside the quadtree.

	`Position` is always normalized to Vector2. `Object` is the payload you store in
	the tree. These fields are public for read-only access and should not be mutated
	manually.


	```lua
	local node = tree:CreateNode(Vector2.new(12, 4), "Coin")
	print(node.Position, node.Object)
	```
]=]
export type Node<T> = {
	read Position: Vector2,
	read Object: T,
}

--[=[
	@within Quadtree
	@private
	@type NodeInternal<T> Node<T> & {Region: Region<T>?}

	Internal node metadata used by the implementation.

	This is the public node shape plus the owning region reference.
]=]
type NodeInternal<T> = {
	Region: Region<T>?,
	Position: Vector2,
	read Object: T,
}

local MAX_SUB_REGIONS = 4
local DEFAULT_TOP_REGION_SIZE = 512

local function ResolvePosition(position: Vector): Vector2
	return if typeof(position) == "Vector3" then Vector2.new(position.X, position.Z) else position
end

local function IsPointInBox(point: Vector2, boxCenter: Vector2, boxSize: number)
	local half = boxSize / 2
	return point.X >= boxCenter.X - half
		and point.X <= boxCenter.X + half
		and point.Y >= boxCenter.Y - half
		and point.Y <= boxCenter.Y + half
end

local function RoundTo(x: number, mult: number): number
	return math.round(x / mult) * mult
end

local function DistanceSquared(a: Vector2, b: Vector2): number
	local delta = a - b
	return delta.X * delta.X + delta.Y * delta.Y
end

local function SwapRemove(tbl: { any }, index: number)
	local n = #tbl
	tbl[index] = tbl[n]
	tbl[n] = nil
end

local function CountNodesInRegion<T>(region: Region<T>)
	local n = 0
	if region.Nodes then
		return #region.Nodes
	else
		for _, subRegion in ipairs(region.Regions) do
			n += CountNodesInRegion(subRegion)
		end
	end
	return n
end

--[[
	Retrieves or creates a top-level region using spatial hashing.
	The string key is derived from the grid-aligned position, enabling O(1) lookups
	and efficient sparse storage of only populated grid cells.
]]
local function GetTopRegion<T>(quadtree: QuadtreeInternal<T>, position: Vector2, create: boolean): Region<T>
	local size = quadtree.Size
	local origin = Vector2.new(RoundTo(position.X, size), RoundTo(position.Y, size))
	local regionKey = origin.X .. ":" .. origin.Y
	local region = quadtree.Regions[regionKey]
	if not region and create then
		region = {
			Regions = {},
			Level = 1,
			Size = size,
			Radius = math.sqrt(size * size + size * size),
			Center = origin,
		}
		table.freeze(region)
		quadtree.Regions[regionKey] = region :: Region<T>
	end
	return region :: Region<T>
end

local function GetRegionsInRadius<T>(quadtree: QuadtreeInternal<T>, position: Vector2, radius: number): { Region<T> }
	local regionsFound = {}
	local function ScanRegions(regions: { Region<T> })
		-- Find regions that have overlapping radius values
		for _, region in ipairs(regions) do
			local distanceSq = DistanceSquared(position, region.Center)
			local threshold = radius + region.Radius
			if distanceSq < (threshold * threshold) then
				if region.Nodes then
					table.insert(regionsFound, region)
				else
					ScanRegions(region.Regions)
				end
			end
		end
	end

	local startRegions = {}
	local size = quadtree.Size
	local maxOffset = math.ceil(radius / size)

	-- Adjusted logic for quadtree (2D spatial relationships only)
	for x = -maxOffset, maxOffset do
		for y = -maxOffset, maxOffset do
			local offset = Vector2.new(x * size, y * size)
			local startRegion = GetTopRegion(quadtree, position + offset, false)
			if startRegion and not startRegions[startRegion] then
				startRegions[startRegion] = true
				ScanRegions(startRegion.Regions)
			end
		end
	end

	return regionsFound
end

--------------------------------------------------------------------------------
--// Class //--
--------------------------------------------------------------------------------

local Quadtree = {}
Quadtree.__index = Quadtree

--[=[
	@within Quadtree
	@function new
	@tag Constructor
	@param topRegionSize number?
	@return Quadtree<T>

	Creates a new quadtree instance.

	`topRegionSize` controls the size of the root-level grid cells. Larger values
	mean fewer top regions, while smaller values create a denser top-level grid.

	```lua
	local tree = Quadtree.new(256)
	```

	:::tip topRegionSize
	If your objects are generally clustered together, a smaller `topRegionSize`
	can help reduce the number of nodes per region and speed up queries. By default, 
	it's 512, which means each top-level region covers a 512x512 area. Adjust this 
	based on your expected spatial distribution for better performance.
	:::

]=]
local function CreateQuadtree<T>(topRegionSize: number?): Quadtree<T>
	local self = (setmetatable({}, Quadtree) :: unknown) :: QuadtreeInternal<T>
	self.Size = if topRegionSize then topRegionSize else DEFAULT_TOP_REGION_SIZE
	self.Regions = {} :: { [string]: Region<T> }
	return self
end

--[=[
	@method CreateNode
	@within Quadtree
	@param position Vector
	@param object T
	@return Node<T>
	Creates and inserts a node into the quadtree.


	```lua
	local node = tree:CreateNode(Vector2.new(32, 16), "Pickup")
	```
]=]
function Quadtree.CreateNode<T>(self: QuadtreeInternal<T>, position: Vector, object: T): Node<T>
	local posV2 = ResolvePosition(position)
	local region = self:_getRegion(MAX_SUB_REGIONS, posV2)
	local node: NodeInternal<T> = {
		Region = region,
		Position = posV2,
		Object = object,
	}
	if region.Nodes then
		table.insert(region.Nodes, node)
	else
		error("region does not contain nodes array")
	end
	return node :: Node<T>
end

--[=[
	@method RemoveNode
	@within Quadtree
	@param node Node<T>
	@return boolean
	Removes a node from the quadtree if present.


	```lua
	local didRemove = tree:RemoveNode(node)
	```
]=]
function Quadtree.RemoveNode<T>(self: QuadtreeInternal<T>, node: NodeInternal<T>): boolean
	local didRemove = false
	if not node.Region then
		return didRemove
	end
	local nodes = node.Region.Nodes :: { NodeInternal<T> }
	local index = table.find(nodes, node)
	if index then
		SwapRemove(nodes, index)
		didRemove = true
	end
	if #nodes == 0 then
		-- Remove regions without any nodes:
		local region = node.Region
		while region do
			local parent = region.Parent
			if parent then
				local numNodes = CountNodesInRegion(region)
				if numNodes == 0 then
					local regionIndex = table.find(parent.Regions, region)
					if regionIndex then
						SwapRemove(parent.Regions, regionIndex)
					end
				end
			end
			region = parent
		end
	end
	node.Region = nil
	return didRemove
end

--[=[
	@method ChangeNodePosition
	@within Quadtree
	@param node Node<T>
	@param position Vector
	@return ()
	Changes a node's position and updates region membership.


	```lua
	tree:ChangeNodePosition(node, Vector2.new(100, 0))
	```
]=]
function Quadtree:ChangeNodePosition<T>(node: NodeInternal<T>, position: Vector)
	local posV2 = ResolvePosition(position)
	node.Position = posV2
	local newRegion = self:_getRegion(MAX_SUB_REGIONS, posV2)
	if newRegion == node.Region then
		return
	end
	table.insert(newRegion.Nodes, node)
	self:RemoveNode(node)
	node.Region = newRegion
end

--[=[
	@method ClearAllNodes
	@within Quadtree
	@return ()
	Clears all regions and nodes from the quadtree.
]=]
function Quadtree:ClearAllNodes()
	table.clear(self.Regions)
end

--[=[
	@method GetAllNodes
	@within Quadtree
	@return {Node<T>}
	Returns a flat array of all nodes.

	```lua
	local all = tree:GetAllNodes()
	for _, node in ipairs(all) do
		print(node.Object)
	end
	```
]=]
function Quadtree.GetAllNodes<T>(self: QuadtreeInternal<T>): { Node<T> }
	local all = {}
	local function GetNodes(regions: { [any]: Region<T> })
		for _, region in regions do
			local nodes = region.Nodes
			if nodes then
				table.move(nodes, 1, #nodes, #all + 1, all)
			else
				GetNodes(region.Regions)
			end
		end
	end
	GetNodes(self.Regions)
	return all
end

--[=[
	@method CountNodes
	@within Quadtree
	@return number
	Returns the current node count.
]=]
function Quadtree.CountNodes<T>(self: QuadtreeInternal<T>): number
	return #self:GetAllNodes()
end

--[=[
	@method SearchRadius
	@within Quadtree
	@param position Vector
	@param radius number
	@return {Node<T>}
	Returns nodes strictly within the given radius of position.

	```lua
	local nearbyNodes = tree:SearchRadius(Vector2.new(0, 0), 32)
	```
]=]
function Quadtree.SearchRadius<T>(self: QuadtreeInternal<T>, position: Vector, radius: number): { Node<T> }
	local posV2 = ResolvePosition(position)
	local nodes = {}
	local regions = GetRegionsInRadius(self, posV2, radius)
	local radiusSq = radius * radius
	for _, region in ipairs(regions) do
		if region.Nodes ~= nil then
			for _, node: Node<T> in ipairs(region.Nodes) do
				if DistanceSquared(node.Position, posV2) < radiusSq then
					table.insert(nodes, node)
				end
			end
		end
	end
	return nodes
end

--[=[
	@method ForEachInRadius
	@within Quadtree
	@param position Vector
	@param radius number
	@return () -> Node<T>?
	Returns an iterator for nodes strictly within radius.

	```lua
	for node in tree:ForEachInRadius(Vector2.new(0, 0), 32) do
		print(node.Object)
	end
	```
]=]
function Quadtree.ForEachInRadius<T>(self: QuadtreeInternal<T>, position: Vector, radius: number): () -> Node<T>?
	local posV2 = ResolvePosition(position)
	local regions = GetRegionsInRadius(self, posV2, radius)
	local radiusSq = radius * radius
	return coroutine.wrap(function()
		for _, region: Region<T> in ipairs(regions) do
			if region.Nodes ~= nil then
				for _, node: Node<T> in ipairs(region.Nodes) do
					if DistanceSquared(node.Position, posV2) < radiusSq then
						coroutine.yield(node)
					end
				end
			end
		end
	end) :: () -> Node<T>?
end

--[=[
	@method ForEachNode
	@within Quadtree
	@return () -> Node<T>?
	Returns an iterator across all nodes.

	```lua
	for node in tree:ForEachNode() do
		print(node.Object)
	end
	```
]=]
function Quadtree.ForEachNode<T>(self: QuadtreeInternal<T>): () -> Node<T>?
	local function GetNodes(regions: { [any]: Region<T>? })
		for _, region in regions or self.Regions do
			local nodes = region.Nodes
			if nodes then
				for _, node in nodes do
					coroutine.yield(node)
				end
			else
				GetNodes(region.Regions)
			end
		end
	end
	return coroutine.wrap(GetNodes) :: () -> Node<T>?
end

--[=[
	@method FindFirstNode
	@within Quadtree
	@param object T
	@return Node<T>?
	Returns the first node whose Object equals object.

	```lua
	local node = tree:FindFirstNode("SpawnPoint")
	if node then
		print(node.Position)
	end
	```
]=]
function Quadtree.FindFirstNode<T>(self: QuadtreeInternal<T>, object: T): Node<T>?
	for node: Node<T> in self:ForEachNode() do
		if node.Object == object then
			return node
		end
	end
	return nil
end

--[=[
	@method GetNearest
	@within Quadtree
	@param position Vector
	@param radius number
	@param maxNodes number?
	@return {Node<T>}
	Returns nearest nodes sorted by ascending distance.

	```lua
	local nearestNodes = tree:GetNearest(Vector2.new(0, 0), 64, 5)
	```
]=]
function Quadtree.GetNearest<T>(
	self: QuadtreeInternal<T>,
	position: Vector,
	radius: number,
	maxNodes: number?
): { Node<T> }
	local posV2 = ResolvePosition(position)
	local nodes = self:SearchRadius(posV2, radius)
	table.sort(nodes, function(n0: Node<T>, n1: Node<T>)
		return DistanceSquared(n0.Position, posV2) < DistanceSquared(n1.Position, posV2)
	end)
	if maxNodes ~= nil and #nodes > maxNodes then
		return table.move(nodes, 1, maxNodes, 1, table.create(maxNodes) :: any)
	end
	return nodes
end

--[=[
	@within Quadtree
	@private
]=]
function Quadtree._getRegion<T>(self: QuadtreeInternal<T>, maxLevel: number, position: Vector2): Region<T>
	local function GetRegion(regionParent: Region<T>?, regions: { Region<T> }, level: number): Region<T>
		local region: Region<T>? = nil
		-- Find region that contains the position:
		for _, r in regions do
			if IsPointInBox(position, r.Center, r.Size) then
				region = r
				break
			end
		end
		if not region then
			-- Create new region:
			local size = self.Size / (2 ^ (level - 1))
			local origin = if regionParent
				then regionParent.Center
				else Vector2.new(RoundTo(position.X, size), RoundTo(position.Y, size))
			local center = origin
			if regionParent then
				-- Offset position to fit the subregion within the parent region:
				center += Vector2.new(
					if position.X > origin.X then size / 2 else -size / 2,
					if position.Y > origin.Y then size / 2 else -size / 2
				)
			end
			local newRegion: Region<T> = table.freeze {
				Regions = {},
				Level = level,
				Size = size,
				-- Radius represents the spherical radius that contains the entirety of the cube region
				Radius = math.sqrt(size * size + size * size),
				Center = center,
				Parent = regionParent,
				Nodes = if level == MAX_SUB_REGIONS then {} else nil,
			} :: Region<T>
			table.insert(regions, newRegion)
			region = newRegion
		end
		if level == maxLevel then
			-- We've made it to the bottom-tier region
			return region :: Region<T>
		else
			-- Find the sub-region:
			return GetRegion(region :: Region<T>, (region :: Region<T>).Regions, level + 1)
		end
	end
	local startRegion = GetTopRegion(self, position, true)
	return GetRegion(startRegion, startRegion.Regions, 2)
end

--[=[
	@within Quadtree
	@tag metamethod
	@method __iter
	@return Node<T>
	Metamethod alias for ***ForEachNode***, enabling direct iteration over the quadtree.
]=]
Quadtree.__iter = Quadtree.ForEachNode

return {
	new = CreateQuadtree,
}
