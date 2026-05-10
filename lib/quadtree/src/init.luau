--!strict

--[=[
	@within Quadtree
	@type Vector Vector2 | Vector3
	Internally only Vector2 is used for positions, but Vector3 is accepted as input and will be converted to Vector2 by dropping the Y component.
]=]
type Vector = Vector2 | Vector3
export type Quadtree<T> = {
	ClearAllNodes: (self: Quadtree<T>) -> (),
	GetAllNodes: (self: Quadtree<T>) -> { Node<T> },
	ForEachNode: (self: Quadtree<T>) -> () -> Node<T>?,
	FindFirstNode: (self: Quadtree<T>, object: T) -> Node<T>?,
	CountNodes: (self: Quadtree<T>) -> number,
	CreateNode: (self: Quadtree<T>, position: Vector, object: T) -> Node<T>,
	RemoveNode: (self: Quadtree<T>, node: Node<T>) -> (),
	ChangeNodePosition: (self: Quadtree<T>, node: Node<T>, position: Vector) -> (),
	SearchRadius: (self: Quadtree<T>, position: Vector, radius: number) -> { Node<T> },
	ForEachInRadius: (self: Quadtree<T>, position: Vector, radius: number) -> () -> Node<T>?,
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

	A container for an object that is stored in the quadtree.
	These are the public properties of the node, you should
	never modify these manually.
]=]
export type Node<T> = {
	Position: Vector2,
	Object: T,
}

--[=[
	@within Quadtree
	@private
	@type NodeInternal<T> Node<T> & {Region: Region<T>?}

	Equivalent to Node<T> for end user purposes.
]=]
type NodeInternal<T> = Node<T> & {
	Region: Region<T>?,
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

local function GetTopRegionKey(position: Vector2, size: number): string
	return `{RoundTo(position.X, size)}:{RoundTo(position.Y, size)}`
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

--[=[
	Retrieves or creates a top-level region using spatial hashing.
	The string key is derived from the grid-aligned position, enabling O(1) lookups
	and efficient sparse storage of only populated grid cells.
]=]
local function GetTopRegion<T>(quadtree: QuadtreeInternal<T>, position: Vector2, create: boolean): Region<T>
	local size = quadtree.Size
	local origin = Vector2.new(RoundTo(position.X, size), RoundTo(position.Y, size))
	local regionKey = GetTopRegionKey(position, size)
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
			local distance = (position - region.Center).Magnitude
			if distance < (radius + region.Radius) then
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

--[=[
	@class Quadtree
]=]
local Quadtree = {}
Quadtree.__index = Quadtree

local function CreateQuadtree<T>(topRegionSize: number?): Quadtree<T>
	local self = (setmetatable({}, Quadtree) :: unknown) :: QuadtreeInternal<T>
	self.Size = if topRegionSize then topRegionSize else DEFAULT_TOP_REGION_SIZE
	self.Regions = {} :: { [string]: Region<T> }
	return self
end

--[=[
	@within Quadtree
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
	@within Quadtree
	Removes the given node if it resides within the quadtree, otherwise does nothing.

	Returns true if the node was removed, false otherwise.
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
	@within Quadtree
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
	@within Quadtree
]=]
function Quadtree:ClearAllNodes()
	table.clear(self.Regions)
end

--[=[
	@within Quadtree
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
	@within Quadtree
]=]
function Quadtree.CountNodes<T>(self: QuadtreeInternal<T>): number
	return #self:GetAllNodes()
end

--[=[
	@within Quadtree
]=]
function Quadtree.SearchRadius<T>(self: QuadtreeInternal<T>, position: Vector, radius: number): { Node<T> }
	local posV2 = ResolvePosition(position)
	local nodes = {}
	local regions = GetRegionsInRadius(self, posV2, radius)
	for _, region in ipairs(regions) do
		if region.Nodes ~= nil then
			for _, node: Node<T> in ipairs(region.Nodes) do
				if (node.Position - posV2).Magnitude < radius then
					table.insert(nodes, node)
				end
			end
		end
	end
	return nodes
end

--[=[
	@within Quadtree
	Returns an iterator that can be used to traverse all nodes within the given radius.

	```lua
	for node: Node<any> in quadtree:ForEachInRadius(position, radius) do
	```
]=]
function Quadtree.ForEachInRadius<T>(self: QuadtreeInternal<T>, position: Vector, radius: number): () -> Node<T>?
	local posV2 = ResolvePosition(position)
	local regions = GetRegionsInRadius(self, posV2, radius)
	return coroutine.wrap(function()
		for _, region: Region<T> in ipairs(regions) do
			if region.Nodes ~= nil then
				for _, node: Node<T> in ipairs(region.Nodes) do
					if (node.Position - posV2).Magnitude < radius then
						coroutine.yield(node)
					end
				end
			end
		end
	end) :: () -> Node<T>?
end

--[=[
	@within Quadtree
	Returns an iterator that can be used to traverse all nodes within the quadtree.
	The __iter metamethod is set to this method and thus can be used as follows:

	```lua
	for node: Node<any> in quadtree do
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
	@within Quadtree
	Returns the first node that has the given object if one resides within the quadtree.
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
	@within Quadtree
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
		local d0 = (n0.Position - posV2).Magnitude
		local d1 = (n1.Position - posV2).Magnitude
		return d0 < d1
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

Quadtree.__iter = Quadtree.ForEachNode

--[=[
	@within Quadtree
	@function new
	@tag Constructor
	@param topRegionSize number?
	@return Quadtree
]=]
return {
	new = CreateQuadtree,
}
