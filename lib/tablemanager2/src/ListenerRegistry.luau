--!strict
--[=[
	@class ListenerRegistry_new
	
	Clean implementation with FireOnDescendantChanges filtering support using a tree structure.
	
	## New Features
	- Tree-based storage: O(path_length) lookup instead of O(total_listeners)
	- FireOnDescendantChanges option: Control whether listeners fire for descendant changes
	- Unified metadata structure: All events include ChangeMetadata
	- Cleaner API: Simplified event firing logic
	- No need for explicit path relation checks - implicit in tree traversal
	
	## Examples
	
	### Example 1: Basic Tree Structure
	```lua
	-- Register listeners:
	registry:RegisterListener("ValueChanged", {}, callback1) -- Root listener
	registry:RegisterListener("ValueChanged", {"Players"}, callback2)
	registry:RegisterListener("ValueChanged", {"Players", "Player1"}, callback3)
	registry:RegisterListener("ValueChanged", {"Players", "Player1", "Health"}, callback4)
	
	-- Tree structure:
	-- [ROOT]
	--   └─ Listeners: [callback1]
	--   └─ Children:
	--       └─ "Players"
	--           └─ Listeners: [callback2]
	--           └─ Children:
	--               └─ "Player1"
	--                   └─ Listeners: [callback3]
	--                   └─ Children:
	--                       └─ "Health"
	--                           └─ Listeners: [callback4]
	```
	
	### Example 2: Change at {"Players", "Player1", "Health"}
	```lua
	-- Fire: FireListeners("ValueChanged", {"Players", "Player1", "Health"}, eventData)
	
	-- Listeners that fire (in order):
	-- 1. callback1 (root, DescendantChanges=true) - Ancestor of change
	-- 2. callback2 ({"Players"}, DescendantChanges=true) - Ancestor of change
	-- 3. callback3 ({"Players", "Player1"}, DescendantChanges=true) - Ancestor of change
	-- 4. callback4 ({"Players", "Player1", "Health"}) - EXACT match (always fires)
	
	-- Traversal path:
	-- [ROOT] (fire callback1 if DescendantChanges)
	--   → "Players" (fire callback2 if DescendantChanges)
	--   → "Player1" (fire callback3 if DescendantChanges)
	--   → "Health" (fire callback4 - exact match)
	```
	
	### Example 3: Change at {"Players", "Player1"} with FireOnDescendantChanges=false
	```lua
	-- Register:
	registry:RegisterListener("ValueChanged", {"Players"}, callback2, {FireOnDescendantChanges = false})
	registry:RegisterListener("ValueChanged", {"Players", "Player1"}, callback3)
	registry:RegisterListener("ValueChanged", {"Players", "Player1", "Health"}, callback4)
	
	-- Fire: FireListeners("ValueChanged", {"Players", "Player1", "Health"}, eventData)
	
	-- Listeners that fire:
	-- 1. callback1 (root, FireOnDescendantChanges=true) - ✓ Fires
	-- 2. callback2 ({"Players"}, FireOnDescendantChanges=FALSE) - ✗ SKIPPED (doesn't want descendant changes)
	-- 3. callback3 ({"Players", "Player1"}, FireOnDescendantChanges=true) - ✓ Fires
	-- 4. callback4 ({"Players", "Player1", "Health"}) - ✓ Fires (exact match)
	```
	
	### Example 4: FireListenersExact vs FireListeners
	```lua
	-- Same setup as Example 2
	
	-- FireListenersExact("ValueChanged", {"Players", "Player1", "Health"}, eventData)
	-- Only fires: callback4
	-- (Used by ChangeDetector which handles ancestor propagation separately)
	
	-- FireListeners("ValueChanged", {"Players", "Player1", "Health"}, eventData)
	-- Fires: callback1, callback2, callback3, callback4
	-- (Walks the entire path and notifies ancestors)
	```
	
	### Example 5: Listener Below Change Path (No Notification)
	```lua
	-- Register:
	registry:RegisterListener("ValueChanged", {"Players", "Player1", "Health", "MaxHP"}, callback5)
	
	-- Fire: FireListeners("ValueChanged", {"Players", "Player1", "Health"}, eventData)
	
	-- callback5 does NOT fire because:
	-- - The change is at an ancestor path
	-- - Listeners only fire for self or ancestor changes, not parent changes
	-- - The tree traversal stops at {"Players", "Player1", "Health"}
	```
	
	### Example 6: Performance Comparison
	```lua
	-- Old array-based approach:
	-- 1000 total listeners registered at various paths
	-- Change at {"Players", "Player1", "Health"}
	-- Must iterate ALL 1000 listeners and check path relation for each
	-- = ~1000 operations
	
	-- New tree-based approach:
	-- Same 1000 listeners
	-- Change at {"Players", "Player1", "Health"}
	-- Walk tree: [ROOT] → "Players" → "Player1" → "Health"
	-- Only check listeners at these 4 nodes (maybe 10 listeners total)
	-- = ~14 operations
	
	-- Speed improvement: 70x faster!
	```
]=]

local PathHelpers = require("./PathHelpers")

--// Types //--
type Path = PathHelpers.Path

export type EventType =
	"ValueChanged"
	| "KeyAdded"
	| "KeyRemoved"
	| "KeyChanged"
	| "ArrayInserted"
	| "ArrayRemoved"
	| "ArraySet"

-- Metadata structure from ChangeDetector
export type ChangeMetadata = {
	Diff: any?, -- DiffNode from ChangeDetector (present for direct changes, nil for ancestor)
	OriginPath: Path,
	OriginDiff: any, -- The actual diff at the origin
}

export type EventData = {
	NewValue: any?,
	OldValue: any?,
	Key: any?,
	Index: number?,
	Metadata: ChangeMetadata?, -- Will be required after full refactor
}

export type ListenerOptions = {
	-- Whether to fire this listener when a descendant (nested child) changes
	-- true = Fire for direct changes AND descendant changes (default)
	-- false = Fire ONLY for direct changes at this exact path
	-- Example: Listener at {"player"} with FireOnDescendantChanges=false
	--          will NOT fire when {"player", "health"} changes
	FireOnDescendantChanges: boolean?,
}

export type Connection = {
	Disconnect: (Connection) -> (),
	Connected: boolean,
}

type Listener = {
	Callback: (...any) -> (),
	DescendantChanges: boolean,
	Connection: Connection,
}

-- Tree node structure for efficient path-based lookups
type ListenerNode = {
	-- Listeners registered at this exact path
	Listeners: { Listener },
	-- Child nodes keyed by path segment
	Children: { [any]: ListenerNode },
}

export type ListenerRegistry = {
	RegisterListener: (
		self: ListenerRegistry,
		eventType: EventType,
		path: Path,
		callback: (...any) -> (),
		options: ListenerOptions?
	) -> Connection,
	FireListeners: (self: ListenerRegistry, eventType: EventType, path: Path, eventData: EventData) -> (),
	FireListenersExact: (self: ListenerRegistry, eventType: EventType, path: Path, eventData: EventData) -> (),
	Destroy: (self: ListenerRegistry) -> (),

	_listenerTrees: { [EventType]: ListenerNode },
	_debugMode: boolean,
}

--------------------------------------------------------------------------------
--// Module //--
--------------------------------------------------------------------------------

local ListenerRegistry = {}
local ListenerRegistry_MT = { __index = ListenerRegistry }

-- Helper to create a new tree node
local function createNode(): ListenerNode
	return {
		Listeners = {},
		Children = {},
	}
end

-- Helper to get or create a node at a path
local function getOrCreateNode(root: ListenerNode, path: Path): ListenerNode
	local current = root
	for _, segment in path do
		if not current.Children[segment] then
			current.Children[segment] = createNode()
		end
		current = current.Children[segment]
	end
	return current
end

-- Helper to get a node at a path (returns nil if doesn't exist)
local function getNode(root: ListenerNode, path: Path): ListenerNode?
	local current = root
	for _, segment in path do
		if not current.Children[segment] then
			return nil
		end
		current = current.Children[segment]
	end
	return current
end

-- Helper to remove empty nodes recursively
local function cleanupNode(root: ListenerNode, path: Path, index: number): boolean
	if index > #path then
		-- At target node, check if it's empty
		return #root.Listeners == 0 and next(root.Children) == nil
	end

	local segment = path[index]
	local child = root.Children[segment]
	if not child then
		return false
	end

	-- Recursively clean up child
	if cleanupNode(child, path, index + 1) then
		root.Children[segment] = nil
	end

	-- Return true if this node is now empty
	return #root.Listeners == 0 and next(root.Children) == nil
end

function ListenerRegistry.new(debugMode: boolean?): ListenerRegistry
	local self = setmetatable({} :: any, ListenerRegistry_MT) :: ListenerRegistry

	self._listenerTrees = {
		ValueChanged = createNode(),
		KeyAdded = createNode(),
		KeyRemoved = createNode(),
		KeyChanged = createNode(),
		ArrayInserted = createNode(),
		ArrayRemoved = createNode(),
		ArraySet = createNode(),
	}
	self._debugMode = debugMode or false

	return self
end

function ListenerRegistry:RegisterListener(
	eventType: EventType,
	path: Path,
	callback: (...any) -> (),
	options: ListenerOptions?
): Connection
	local descendantChanges = true
	if options and options.FireOnDescendantChanges ~= nil then
		descendantChanges = options.FireOnDescendantChanges
	end

	-- Get the tree for this event type
	local root = self._listenerTrees[eventType]

	-- Navigate to the node for this path, creating nodes as needed
	local node = getOrCreateNode(root, path)

	-- Create listener first
	local listener: Listener = {
		Callback = callback,
		DescendantChanges = descendantChanges,
		Connection = nil :: any, -- Will be set below
	}

	-- Create connection with access to registry and listener
	local connection: Connection = {
		Connected = true,
		Disconnect = function(conn: Connection)
			if not conn.Connected then
				return
			end
			conn.Connected = false
			-- Remove listener from node
			for i, l in node.Listeners do
				if l.Connection == conn then
					table.remove(node.Listeners, i)
					break
				end
			end
			-- Clean up empty nodes
			cleanupNode(root, path, 1)
		end,
	} :: Connection

	-- Set connection in listener
	listener.Connection = connection

	-- Store listener in the tree node
	table.insert(node.Listeners, listener)

	return connection
end

function ListenerRegistry:FireListeners(eventType: EventType, path: Path, eventData: EventData)
	local root = self._listenerTrees[eventType]

	-- Helper to fire a listener with the appropriate callback signature
	local function fireListener(listener: Listener)
		if not listener.Connection.Connected then
			return
		end

		local success, err
		if eventType == "KeyAdded" then
			success, err = pcall(listener.Callback :: any, eventData.NewValue, eventData.Metadata)
		elseif eventType == "KeyRemoved" then
			success, err = pcall(listener.Callback :: any, eventData.OldValue, eventData.Metadata)
		elseif eventType == "KeyChanged" or eventType == "ValueChanged" then
			success, err = pcall(listener.Callback :: any, eventData.NewValue, eventData.OldValue, eventData.Metadata)
		elseif eventType == "ArrayInserted" then
			success, err = pcall(listener.Callback :: any, eventData.Index, eventData.NewValue, eventData.Metadata)
		elseif eventType == "ArrayRemoved" then
			success, err = pcall(listener.Callback :: any, eventData.Index, eventData.OldValue, eventData.Metadata)
		elseif eventType == "ArraySet" then
			success, err = pcall(
				listener.Callback :: any,
				eventData.Index,
				eventData.NewValue,
				eventData.OldValue,
				eventData.Metadata
			)
		end

		if not success and self._debugMode then
			warn(`ListenerRegistry: Error in {eventType} callback: {err}`)
		end
	end

	-- Traverse the tree along the path, firing listeners at each level
	local current = root

	-- Fire root listeners (these listen to everything)
	for _, listener in current.Listeners do
		if listener.DescendantChanges then
			fireListener(listener)
		end
	end

	-- Traverse down the path
	for i, segment in path do
		local child = current.Children[segment]
		if not child then
			break -- No more listeners down this path
		end
		current = child

		-- Fire listeners at this node
		-- If we're at the target path (i == #path), fire all listeners
		-- If we're not at the target path, only fire listeners with DescendantChanges=true
		local isTargetPath = i == #path
		for _, listener in current.Listeners do
			if isTargetPath or listener.DescendantChanges then
				fireListener(listener)
			end
		end
	end

	-- If listeners at the target path want descendant changes, also fire them
	-- This handles cases where a change affects descendants of the listener's path
	if current then
		local function fireDescendants(node: ListenerNode)
			for _, child in node.Children do
				for _, listener in child.Listeners do
					if not listener.Connection.Connected then
						continue
					end
					-- These listeners are descendants of the change path
					-- They should NOT be notified (parent relation case)
				end
				fireDescendants(child)
			end
		end
		-- Only traverse descendants if needed (not in this case)
	end
end

--[=[
	Fires listeners ONLY at the exact path provided, without any ancestor/descendant matching.
	
	This is used for ChangeDetector callbacks, which already handle the full notification chain
	including ancestor propagation. Using this method prevents duplicate notifications.
	
	Respects the FireOnDescendantChanges option: if metadata.Diff is nil (ancestor notification),
	only fires listeners with FireOnDescendantChanges=true.
	
	@param eventType The type of event to fire
	@param path The exact path where listeners should be notified
	@param eventData The event data to pass to callbacks
]=]
function ListenerRegistry:FireListenersExact(eventType: EventType, path: Path, eventData: EventData)
	local root = self._listenerTrees[eventType]

	-- Navigate to the exact node for this path
	local node = getNode(root, path)
	if not node then
		return -- No listeners at this path
	end

	-- Check if this is an ancestor notification (Diff is nil)
	local isAncestorNotification = eventData.Metadata and eventData.Metadata.Diff == nil

	-- Fire all listeners at this exact node
	for _, listener in node.Listeners do
		if not listener.Connection.Connected then
			continue
		end

		-- Filter based on DescendantChanges option
		-- If this is an ancestor notification and listener doesn't want descendant changes, skip
		if isAncestorNotification and not listener.DescendantChanges then
			continue
		end

		-- Build callback args based on event type
		local success, err
		if eventType == "KeyAdded" then
			success, err = pcall(listener.Callback :: any, eventData.NewValue, eventData.Metadata)
		elseif eventType == "KeyRemoved" then
			success, err = pcall(listener.Callback :: any, eventData.OldValue, eventData.Metadata)
		elseif eventType == "KeyChanged" or eventType == "ValueChanged" then
			success, err = pcall(listener.Callback :: any, eventData.NewValue, eventData.OldValue, eventData.Metadata)
		elseif eventType == "ArrayInserted" then
			success, err = pcall(listener.Callback :: any, eventData.Index, eventData.NewValue, eventData.Metadata)
		elseif eventType == "ArrayRemoved" then
			success, err = pcall(listener.Callback :: any, eventData.Index, eventData.OldValue, eventData.Metadata)
		elseif eventType == "ArraySet" then
			success, err = pcall(
				listener.Callback :: any,
				eventData.Index,
				eventData.NewValue,
				eventData.OldValue,
				eventData.Metadata
			)
		end

		if not success and self._debugMode then
			warn(`ListenerRegistry: Error in {eventType} callback: {err}`)
		end
	end
end

function ListenerRegistry:Destroy()
	-- Recursively disconnect all listeners in the tree
	local function destroyNode(node: ListenerNode)
		for _, listener in node.Listeners do
			if listener.Connection.Connected then
				listener.Connection:Disconnect()
			end
		end
		table.clear(node.Listeners)

		for _, child in node.Children do
			destroyNode(child)
		end
		table.clear(node.Children)
	end

	for _, root in self._listenerTrees do
		destroyNode(root)
	end
end

return ListenerRegistry
