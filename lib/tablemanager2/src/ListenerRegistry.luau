--!strict
--[=[
	@ignore
	@class ListenerRegistry
	
	Clean implementation with ListenDepth filtering support using a tree structure.
	
	## Features
	- Tree-based storage: O(path_length) lookup instead of O(total_listeners)
	- ListenDepth option: Control how many descendant levels trigger a listener
	- ListenDepthStyle option: \"<=\" (within depth) or \"==\" (exact depth only)
	- Once option: Auto-disconnect after first fire
	- Unified metadata structure: All events include ChangeMetadata
	- No ancestor tree-walk in the registry — ChangeDetector handles propagation
	
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
	-- Fire: FireListenersExact("ValueChanged", {"Players", "Player1", "Health"}, eventData)
	
	-- Listeners that fire (in order):
	-- 1. callback1 (root, no ListenDepth limit) - Ancestor of change
	-- 2. callback2 ({"Players"}, no ListenDepth limit) - Ancestor of change
	-- 3. callback3 ({"Players", "Player1"}, no ListenDepth limit) - Ancestor of change
	-- 4. callback4 ({"Players", "Player1", "Health"}) - EXACT match (always fires)
	
	-- Traversal path:
	-- [ROOT] (fire callback1 if depth filter passes)
	--   → "Players" (fire callback2 if depth filter passes)
	--   → "Player1" (fire callback3 if depth filter passes)
	--   → "Health" (fire callback4 - exact match)
	```
	
	### Example 3: Filtering descendants with ListenDepth
	```lua
	-- Register with depth limit (ancestor notifications deeper than this are skipped):
	registry:RegisterListener("ValueChanged", {"Players"}, callback2, { ListenDepth = 0 })
	registry:RegisterListener("ValueChanged", {"Players", "Player1"}, callback3)
	registry:RegisterListener("ValueChanged", {"Players", "Player1", "Health"}, callback4)
	
	-- FireListenersExact at {"Players"} as ancestor notification (OriginPath = {"Players", "Player1", "Health"}):
	-- relativeDepth = #OriginPath - #listenerPath = 3 - 1 = 2
	-- callback2: depth=0, style="<=": 2 <= 0 → false → SKIPPED
	
	-- FireListenersExact at {"Players", "Player1", "Health"} as direct change:
	-- relativeDepth = 0 (direct change)
	-- callback4: depth=nil → always fires ✓
	```
	
	### Example 4: Once option
	```lua
	-- Register a listener that fires exactly once then disconnects:
	local conn = registry:RegisterListener("ValueChanged", {"player", "health"}, function(newValue)
		print("Fired once:", newValue)
	end, { Once = true })
	
	-- First fire: callback runs, conn.Connected becomes false, listener is removed.
	-- Subsequent fires: listener is gone, callback never runs again.
	-- conn.Connected == false after the first fire.
	```
	
	### Example 5: Listener Below Change Path (No Notification)
	```lua
	-- Register:
	registry:RegisterListener("ValueChanged", {"Players", "Player1", "Health", "MaxHP"}, callback5)
	
	-- Fire: FireListenersExact("ValueChanged", {"Players", "Player1", "Health"}, eventData)
	
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

	### Example 7: Wildcard Listeners
	```lua
	-- Register a wildcard listener that matches any key at that segment:
	registry:RegisterListener("ValueChanged", {"Players", "*", "Health"}, function(newValue, oldValue, metadata)
		print(metadata.WildcardMatches[1], "health changed to", newValue)
	end)

	-- Fire: FireListenersExact("ValueChanged", {"Players", "p123", "Health"}, eventData)
	-- The "*" branch matches "p123", so the listener fires with
	-- metadata.WildcardMatches == {"p123"}.

	-- A literal listener registered at {"Players", "p123", "Health"} and the
	-- wildcard listener above are different tree nodes and BOTH fire for the
	-- same change.

	-- Multiple "*" segments accumulate matches left-to-right, e.g. a listener
	-- at {"Players", "*", "Inventory", "*"} fired at
	-- {"Players", "p123", "Inventory", "item7"} gets
	-- metadata.WildcardMatches == {"p123", "item7"}.

	-- Note: a listener registered with `Once = true` at a wildcard path fires
	-- once TOTAL across all matching keys, not once per key, since it lives on
	-- a single tree node.
	```
]=]

local PathHelpers = require("./PathHelpers")
local ArrayDiffModule = require("./ArrayDiff")

--// Types //--
-- type Path = PathHelpers.Path
type PathArray = PathHelpers.PathArray
type MoveMetadata = ArrayDiffModule.MoveMetadata

export type EventType =
	"ValueChanged"
	| "KeyAdded"
	| "KeyRemoved"
	| "KeyChanged"
	| "ArrayInserted"
	| "ArrayRemoved"
	| "ArraySet"
	| "ArrayMoved"

-- Metadata structure from ChangeDetector
export type ChangeMetadata = {
	Diff: any?, -- DiffNode from ChangeDetector (present for direct changes, nil for ancestor)
	OriginPath: PathArray,
	OriginDiff: any, -- The actual diff at the origin
	-- The literal keys matched by each "*" segment of the listener's registered
	-- path, in left-to-right order. nil if the listener path had no wildcards.
	WildcardMatches: { any }?,
	-- Set on ArrayRemoved/ArrayInserted/ArrayMoved when the operation is part of
	-- a detected move (Branch B coalescing only). nil otherwise.
	Move: MoveMetadata?,
}

export type EventData = {
	NewValue: any?,
	OldValue: any?,
	Key: any?,
	Index: number?,
	FromIndex: number?,
	ToIndex: number?,
	Metadata: ChangeMetadata?,
}

export type ListenerOptions = {
	--- Maximum depth of descendant changes that will trigger this listener.
	--- nil = fire for any depth (default). 0 = fire only for direct changes at the
	--- registered path. 1 = also fire for changes 1 level below, etc.
	ListenDepth: number?,
	--- How the depth is compared against ListenDepth.
	--- "<=" (default): fire for changes AT OR WITHIN the given depth.
	--- "==": fire ONLY for changes at EXACTLY the given depth.
	--- Ignored when ListenDepth is nil.
	ListenDepthStyle: ("<=" | "==")?,
	--- When true, the listener automatically disconnects after firing once.
	Once: boolean?,
}

export type Connection = {
	Disconnect: (Connection) -> (),
	Connected: boolean,
}

export type ListenerRegistryConfig = {
	DebugMode: boolean?,
	FireDeferred: boolean?,
}

type Listener = {
	Callback: (...any) -> (),
	Depth: number?,
	DepthStyle: "<=" | "==",
	Once: boolean,
	PathLength: number,
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
		path: PathArray,
		callback: (...any) -> (),
		options: ListenerOptions?
	) -> Connection,
	FireListenersExact: (self: ListenerRegistry, eventType: EventType, path: PathArray, eventData: EventData) -> (),
	Destroy: (self: ListenerRegistry) -> (),

	_listenerTrees: { [EventType]: ListenerNode },
	_debugMode: boolean,
	_fireDeferred: boolean,
	_destroyed: boolean,
}

--------------------------------------------------------------------------------
--// Module //--
--------------------------------------------------------------------------------

local ListenerRegistry = {}
local ListenerRegistry_MT = { __index = ListenerRegistry }

-- The currently idle thread to run the next listener callback on.
local freeRunnerThread: thread? = nil

local function executeListenerCallback(
	callback: (...any) -> (),
	eventType: EventType,
	eventData: EventData,
	debugMode: boolean
)
	local success, err
	local metadata = eventData.Metadata
	if eventType == "KeyAdded" then
		success, err = pcall(callback, eventData.Key, eventData.NewValue, metadata)
	elseif eventType == "KeyRemoved" then
		success, err = pcall(callback, eventData.Key, eventData.OldValue, metadata)
	elseif eventType == "KeyChanged" then
		success, err = pcall(callback, eventData.Key, eventData.NewValue, eventData.OldValue, metadata)
	elseif eventType == "ValueChanged" then
		success, err = pcall(callback, eventData.NewValue, eventData.OldValue, metadata)
	elseif eventType == "ArrayInserted" then
		success, err = pcall(callback, eventData.Index, eventData.NewValue, metadata)
	elseif eventType == "ArrayRemoved" then
		success, err = pcall(callback, eventData.Index, eventData.OldValue, metadata)
	elseif eventType == "ArraySet" then
		success, err = pcall(callback, eventData.Index, eventData.NewValue, eventData.OldValue, metadata)
	elseif eventType == "ArrayMoved" then
		success, err = pcall(callback, eventData.FromIndex, eventData.ToIndex, eventData.NewValue, metadata)
	end

	if not success and debugMode then
		warn(`ListenerRegistry: Error in {eventType} callback: {err}`)
	end
end

local function acquireRunnerThreadAndCall(
	callback: (...any) -> (),
	eventType: EventType,
	eventData: EventData,
	debugMode: boolean
)
	local acquiredRunnerThread = freeRunnerThread
	freeRunnerThread = nil
	executeListenerCallback(callback, eventType, eventData, debugMode)
	-- Callback finished. This runner thread can be reused.
	freeRunnerThread = acquiredRunnerThread
end

-- Argless on purpose: the runner thread is primed with an empty resume so it
-- parks at coroutine.yield() before receiving any payload. Taking the first
-- payload as function parameters instead would pin that payload (callback +
-- eventData, including its deep Metadata.Snapshot) on the thread's stack for
-- the thread's entire lifetime.
local function runListenerCallbackInFreeThread()
	while true do
		acquireRunnerThreadAndCall(coroutine.yield())
	end
end

-- Helper to create a new tree node
local function createNode(): ListenerNode
	return {
		Listeners = {},
		Children = {},
	}
end

-- Helper to get or create a node at a path
local function getOrCreateNode(root: ListenerNode, path: PathArray): ListenerNode
	local current = root
	for _, segment in path do
		if not current.Children[segment] then
			current.Children[segment] = createNode()
		end
		current = current.Children[segment]
	end
	return current
end

-- Reserved path segment used to register a listener that matches any literal
-- key at that position (e.g. {"Players", "*", "Health"}).
local WILDCARD = "*"

type MatchedNode = {
	node: ListenerNode,
	-- Literal keys matched by each "*" segment, in left-to-right order. nil if
	-- no wildcard segments were traversed to reach this node.
	matches: { any }?,
	-- The registered path used to reach this node (with "*" where a wildcard
	-- branch was taken). Used for Once-listener cleanup.
	nodePath: PathArray,
}

-- Recursively walks `path`, following both literal-segment children and "*"
-- (wildcard) children, collecting every listener node that matches.
local function collectMatchingNodes(
	node: ListenerNode,
	path: PathArray,
	index: number,
	matches: { any },
	nodePath: PathArray,
	results: { MatchedNode }
)
	if index > #path then
		table.insert(results, {
			node = node,
			matches = if #matches > 0 then matches else nil,
			nodePath = nodePath,
		})
		return
	end

	local segment = path[index]

	local literalChild = node.Children[segment]
	if literalChild then
		local childPath = table.clone(nodePath)
		table.insert(childPath, segment)
		collectMatchingNodes(literalChild, path, index + 1, matches, childPath, results)
	end

	if segment ~= WILDCARD then
		local wildcardChild = node.Children[WILDCARD]
		if wildcardChild then
			local newMatches = table.clone(matches)
			table.insert(newMatches, segment)
			local childPath = table.clone(nodePath)
			table.insert(childPath, WILDCARD)
			collectMatchingNodes(wildcardChild, path, index + 1, newMatches, childPath, results)
		end
	end
end

-- Helper to remove empty nodes recursively
local function cleanupNode(root: ListenerNode, path: PathArray, index: number): boolean
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

function ListenerRegistry.new(config: ListenerRegistryConfig?): ListenerRegistry
	local self: ListenerRegistry = setmetatable({}, ListenerRegistry_MT) :: ListenerRegistry
	local resolvedConfig = config or {} :: ListenerRegistryConfig
	local debugMode = if resolvedConfig.DebugMode ~= nil then resolvedConfig.DebugMode else false
	local fireDeferred = if resolvedConfig.FireDeferred == true then true else false

	self._listenerTrees = {
		ValueChanged = createNode(),
		KeyAdded = createNode(),
		KeyRemoved = createNode(),
		KeyChanged = createNode(),
		ArrayInserted = createNode(),
		ArrayRemoved = createNode(),
		ArraySet = createNode(),
		ArrayMoved = createNode(),
	}
	self._debugMode = debugMode
	self._fireDeferred = fireDeferred
	self._destroyed = false

	return self
end

function ListenerRegistry:RegisterListener(
	eventType: EventType,
	path: PathArray,
	callback: (...any) -> (),
	options: ListenerOptions?
): Connection
	-- A destroyed registry must stay empty: registrations would repopulate trees
	-- that will never be cleaned again. Hand back an inert, dead connection.
	if self._destroyed then
		return {
			Connected = false,
			Disconnect = function() end,
		} :: Connection
	end

	local depth: number? = if options then options.ListenDepth else nil
	local depthStyle: "<=" | "==" = if options and options.ListenDepthStyle then options.ListenDepthStyle else "<="
	local once: boolean = if options and options.Once == true then true else false

	-- Get the tree for this event type
	local root = self._listenerTrees[eventType]

	-- Navigate to the node for this path, creating nodes as needed
	local node = getOrCreateNode(root, path)

	-- Create listener first
	local listener: Listener = {
		Callback = callback,
		Depth = depth,
		DepthStyle = depthStyle,
		Once = once,
		PathLength = #path,
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

-- Returns true if the listener should fire given how many path segments below the
-- listener's registered path the change originated.
-- relativeDepth = 0: change is AT the listener's exact path.
-- relativeDepth > 0: change originated that many levels deeper (ancestor notification).
local function shouldFireListener(listener: Listener, relativeDepth: number): boolean
	if listener.Depth == nil then
		return true
	end
	if listener.DepthStyle == "==" then
		return relativeDepth == listener.Depth
	else -- "<="
		return relativeDepth <= listener.Depth
	end
end

--[=[
	Fires listeners ONLY at the exact path provided, without any ancestor/descendant matching.

	This is used for ChangeDetector callbacks, which already handle the full notification chain
	including ancestor propagation. Using this method prevents duplicate notifications.

	Depth filtering: ancestor notifications (metadata.Diff == nil) compute relative depth from
	metadata.OriginPath against the listener's registered path length. Direct change
	notifications (Diff present) always use depth 0.

	Once listeners are marked as disconnected before their callback fires (re-entrancy safe),
	then physically removed from the node in a backward sweep after the fire loop.

	@param eventType The type of event to fire
	@param path The exact path where listeners should be notified
	@param eventData The event data to pass to callbacks
]=]
function ListenerRegistry.FireListenersExact(
	self: ListenerRegistry,
	eventType: EventType,
	path: PathArray,
	eventData: EventData
)
	local root = self._listenerTrees[eventType]

	-- Navigate to every node that matches this path, including wildcard ("*") branches
	local results: { MatchedNode } = {}
	collectMatchingNodes(root, path, 1, {}, {}, results)
	if #results == 0 then
		return -- No listeners at this path
	end

	-- For ancestor notifications (Diff == nil), compute relative depth from OriginPath.
	-- Direct change notifications always have relativeDepth = 0 (change is at the listener's path).
	local isAncestorNotification = eventData.Metadata and eventData.Metadata.Diff == nil
	local baseRelativeDepth: number = 0
	if isAncestorNotification and eventData.Metadata then
		baseRelativeDepth = #eventData.Metadata.OriginPath - #path
		if baseRelativeDepth < 0 then
			baseRelativeDepth = 0
		end
	end

	local debugMode = self._debugMode
	local fireDeferred = self._fireDeferred

	for _, result in results do
		local node = result.node
		local listeners = node.Listeners
		local hasOnceFired = false

		-- Listeners reached via a wildcard branch get the matched keys attached
		-- to a per-result copy of the metadata; literal-only matches reuse eventData as-is.
		local fireEventData = eventData
		if result.matches then
			local metadata = eventData.Metadata
			local newMetadata = if metadata then table.clone(metadata) else {} :: ChangeMetadata
			newMetadata.WildcardMatches = result.matches
			fireEventData = table.clone(eventData)
			fireEventData.Metadata = newMetadata
		end

		for _, listener in listeners do
			if not listener.Connection.Connected then
				continue
			end

			if not shouldFireListener(listener, baseRelativeDepth) then
				continue
			end

			-- Mark Once listeners as consumed before firing to guard against re-entrant calls.
			if listener.Once then
				listener.Connection.Connected = false
				hasOnceFired = true
			end

			if fireDeferred then
				task.defer(executeListenerCallback, listener.Callback, eventType, fireEventData, debugMode)
			else
				if not freeRunnerThread then
					freeRunnerThread = coroutine.create(runListenerCallbackInFreeThread)
					-- Prime the thread so it parks at coroutine.yield() with an
					-- empty stack; payloads only ever arrive via task.spawn below.
					coroutine.resume(freeRunnerThread :: thread)
				end
				task.spawn(freeRunnerThread :: thread, listener.Callback, eventType, fireEventData, debugMode)
			end
		end

		-- Backward sweep: physically remove all consumed Once listeners from the node.
		-- Done after the fire loop to avoid mid-iteration mutation.
		if hasOnceFired then
			for i = #listeners, 1, -1 do
				if listeners[i].Once and not listeners[i].Connection.Connected then
					table.remove(listeners, i)
				end
			end
			cleanupNode(root, result.nodePath, 1)
		end
	end
end

function ListenerRegistry.Destroy(self: ListenerRegistry)
	if self._destroyed then
		return
	end
	self._destroyed = true

	-- Recursively disconnect all listeners in the tree. Mark connections dead
	-- directly instead of calling Disconnect(): Disconnect table.remove's from
	-- the array being iterated (skipping every other listener) and runs
	-- redundant cleanupNode passes on a tree that is being cleared wholesale.
	local function destroyNode(node: ListenerNode)
		for _, listener in node.Listeners do
			listener.Connection.Connected = false
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
