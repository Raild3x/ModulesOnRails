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

const PathHelpers = require("../PathHelpers")
const ArrayDiffModule = require("../Diffing/ArrayDiff")
const IsDeferred = require("./IsDeferred")

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

-- Metadata structure from ChangeDetector
export type ChangeMetadata = {
	Diff: any?, -- DiffNode from ChangeDetector (present for direct changes, nil for ancestor)
	OriginPath: PathArray,
	OriginDiff: any, -- The actual diff at the origin
	-- The literal keys matched by each "*" segment of the listener's registered
	-- path, in left-to-right order. nil if the listener path had no wildcards.
	WildcardMatches: { any }?,
	-- Set on the ArrayRemoved/ArrayInserted pair from a non-batched
	-- ArraySwapRemove that constitutes a move. nil otherwise.
	Move: MoveMetadata?,
}

export type EventData = {
	NewValue: any?,
	OldValue: any?,
	-- Frozen, opacity-aware copy of the old value at this event's old-value path,
	-- present only when some listener on the firing node opted into
	-- `SnapshotOldValues` AND the caller computed a snapshot for this change (see
	-- `ListenerRegistry.SnapshotRootFor`). `fireListenersOnNode` swaps this in for
	-- `OldValue` only for the listeners that asked for it; non-opted listeners on
	-- the same node still receive the raw `OldValue` above.
	OldValueSnapshot: any?,
	Key: any?,
	Index: number?,
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
	--- When true, a table `oldValue` delivered to this listener is a frozen,
	--- opacity-aware deep copy captured BEFORE the change is applied, instead of
	--- the raw (and, outside batches, baseline-backed/mutable) reference. Has no
	--- effect on scalar old values. Does not affect `metadata.Diff.old`, which is
	--- always the raw diff-tree value regardless of this option. Costs an extra
	--- copy only when at least one listener on the affected path opts in.
	SnapshotOldValues: boolean?,
	--- When true, this listener is guaranteed the full granular diff subtree in
	--- `metadata.Diff` / `metadata.OriginDiff`, even when the transparent depth
	--- bound would otherwise elide the subtree below it (see
	--- `Coverage.ResolveDiffMaxDepth`). Set this if the callback walks
	--- `metadata.Diff.children` / `OriginDiff` beyond its own `ListenDepth` reach.
	--- Forces a full-depth diff for any change it covers — the deliberate, opt-in
	--- cost. Has no effect on the values delivered (`newValue`/`oldValue`), which
	--- are always exact.
	ProvideDiff: boolean?,
}

export type Connection = {
	Disconnect: (Connection) -> (),
	Connected: boolean,
}

-- How listener callbacks are scheduled when fired:
-- "immediate": run now via the free-thread pool (task.spawn), like an RBXScriptSignal in immediate mode.
-- "deferred": run via task.defer, like an RBXScriptSignal in deferred mode.
-- "bindable": mirrors the engine's actual Enum.SignalBehavior (resolved once, at construction time).
-- "coalesced": like "deferred", but repeated fires of the SAME listener before the deferred flush runs
-- collapse into a single call carrying the latest event data, instead of one call per fire.
export type FireMode = "immediate" | "deferred" | "bindable" | "coalesced"

export type ListenerRegistryConfig = {
	DebugMode: boolean?,
	FireMode: FireMode,
}

type Listener = {
	Callback: (...any) -> (),
	Depth: number?,
	DepthStyle: "<=" | "==",
	Once: boolean,
	SnapshotOldValues: boolean,
	ProvideDiff: boolean,
	PathLength: number,
	Connection: Connection,
	-- "coalesced" fire-mode pending state; see `flushCoalescedListener`.
	_coalescePending: boolean?,
	_coalesceEventData: EventData?,
}

-- Tree node structure for efficient path-based lookups. A single tree serves
-- every event type: each node stores its listeners bucketed by EventType
-- alongside Count (listeners AT this exact node, all event types) and Subtree
-- (listeners at or below this node), so one walk both fires listeners and
-- answers "is anyone watching here?" (CoversChangesAt) with no parallel
-- structure to keep in sync.
type ListenerNode = {
	-- Listeners registered at this exact path, bucketed by event type. A
	-- bucket is deleted (set to nil) as soon as it goes empty.
	Listeners: { [EventType]: { Listener } },
	-- Total listeners (all event types) registered at this exact node.
	Count: number,
	-- Total listeners at or below this node (Count + every descendant's Subtree).
	Subtree: number,
	-- Listeners (any event type) registered at this exact node with
	-- `SnapshotOldValues = true`. Subset of Count.
	SnapshotCount: number,
	-- SnapshotCount at or below this node (mirrors Subtree, but counting only
	-- opted-in listeners). Used by `SnapshotRootFor` to find the shallowest path
	-- that needs a snapshot built for a given change, without visiting listeners.
	SnapshotSubtree: number,
	-- Listeners (any event type) registered at this exact node with
	-- `ProvideDiff = true`. Subset of Count.
	ProvideDiffCount: number,
	-- ProvideDiffCount at or below this node (mirrors SnapshotSubtree). Used by
	-- `WantsFullDiff` to answer "does any opted-in listener cover this change?"
	-- without visiting listeners.
	ProvideDiffSubtree: number,
	-- Child nodes keyed by path segment.
	Children: { [any]: ListenerNode },
	-- Back-pointer and this node's key within Parent.Children, used to prune
	-- now-empty nodes back toward the root on disconnect. nil for the root.
	Parent: ListenerNode?,
	Key: any?,
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
	-- Conservative O(depth) check: true if a change at `path` could reach some
	-- registered listener — one AT path, an ANCESTOR of it (ancestor
	-- ValueChanged/KeyChanged delivery), or a DESCENDANT of it (a deep write
	-- restructures the subtree a descendant listener watches). Never under-
	-- reports, so callers can safely skip diff work whenever this is false.
	CoversChangesAt: (self: ListenerRegistry, path: PathArray) -> boolean,
	-- Returns the absolute path a caller should snapshot the old value at for a
	-- change at `path`, or `nil` if no opted-in (`SnapshotOldValues`) listener
	-- would receive a real old value for this change. The returned path is the
	-- shallowest point that covers every opted-in listener in `path`'s subtree
	-- (their lowest common ancestor), so callers copy the smallest value that
	-- still lets every opted-in listener slice out its own old value.
	SnapshotRootFor: (self: ListenerRegistry, path: PathArray) -> PathArray?,
	-- Deepest reach (`relativeDepth + ListenDepth`) of any listener registered
	-- STRICTLY BELOW `path`; `math.huge` if any such listener is unbounded
	-- (`ListenDepth == nil`), `0` if none. The diff at `path` must be built this
	-- many levels deep for every covering descendant listener to fire correctly —
	-- drives the transparent depth bound. Listeners AT or ABOVE `path` are not
	-- counted (they fire from the root node / ancestor walk, not the subtree).
	MaxObservedDepth: (self: ListenerRegistry, path: PathArray) -> number,
	-- True if any listener that would fire for a change at `path` opted into
	-- `ProvideDiff` — an opted-in ancestor of `path` (receives `OriginDiff`) or one
	-- at/below `path`. When true the caller must diff at full depth.
	WantsFullDiff: (self: ListenerRegistry, path: PathArray) -> boolean,
	Destroy: (self: ListenerRegistry) -> (),

	_root: ListenerNode,
	_debugMode: boolean,
	-- Resolved fire mode; "bindable" is collapsed into "immediate"/"deferred" at construction.
	_fireMode: "immediate" | "deferred" | "coalesced",
	_destroyed: boolean,
	_hasWildcards: boolean,
	-- One-way latch: true once any SnapshotOldValues listener is registered at a
	-- wildcard path. SnapshotRootFor degrades to "snapshot the whole subtree" in
	-- that case rather than walking wildcard branches.
	_hasSnapshotWildcards: boolean,
}

--------------------------------------------------------------------------------
--// Module //--
--------------------------------------------------------------------------------

const ListenerRegistry = {}
const ListenerRegistry_MT = { __index = ListenerRegistry }

-- The currently idle thread to run the next listener callback on.
local freeRunnerThread: thread? = nil

const function executeListenerCallback(
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
	end

	if not success and debugMode then
		warn(`ListenerRegistry: Error in {eventType} callback: {err}`)
	end
end

const function acquireRunnerThreadAndCall(
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
-- eventData, including its Metadata.Snapshot.RootTable reference) on the
-- thread's stack for the thread's entire lifetime.
const function runListenerCallbackInFreeThread()
	while true do
		acquireRunnerThreadAndCall(coroutine.yield())
	end
end

-- "coalesced" fire-mode flush: runs once via task.defer per pending listener,
-- regardless of how many times that listener was "fired" before this ran.
-- Re-checks Connected at flush time (unlike the "deferred" path) since a
-- coalesced flush can be scheduled well after the listener disconnects.
const function flushCoalescedListener(listener: Listener, eventType: EventType, debugMode: boolean)
	listener._coalescePending = false
	local eventData = listener._coalesceEventData :: EventData
	listener._coalesceEventData = nil
	if listener.Connection.Connected then
		executeListenerCallback(listener.Callback, eventType, eventData, debugMode)
	end
end

-- Helper to create a new tree node
const function createNode(parent: ListenerNode?, key: any?): ListenerNode
	return {
		Listeners = {},
		Count = 0,
		Subtree = 0,
		SnapshotCount = 0,
		SnapshotSubtree = 0,
		ProvideDiffCount = 0,
		ProvideDiffSubtree = 0,
		Children = {},
		Parent = parent,
		Key = key,
	}
end

-- Helper to get or create a node at a path. Bumps Subtree by 1 at every node
-- visited (root included) since the caller is about to register exactly one
-- listener at the returned node.
const function getOrCreateNode(root: ListenerNode, path: PathArray): ListenerNode
	local current = root
	current.Subtree += 1
	for _, segment in path do
		local child = current.Children[segment]
		if not child then
			child = createNode(current, segment)
			current.Children[segment] = child
		end
		child.Subtree += 1
		current = child
	end
	return current
end

-- Reserved path segment used to register a listener that matches any literal
-- key at that position (e.g. {"Players", "*", "Health"}).
const WILDCARD = PathHelpers.WILDCARD

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
const function collectMatchingNodes(
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
		local childPath = PathHelpers.Append(nodePath, segment)
		collectMatchingNodes(literalChild, path, index + 1, matches, childPath, results)
	end

	if segment ~= WILDCARD then
		local wildcardChild = node.Children[WILDCARD]
		if wildcardChild then
			local newMatches = PathHelpers.Append(matches, segment)
			local childPath = PathHelpers.Append(nodePath, WILDCARD)
			collectMatchingNodes(wildcardChild, path, index + 1, newMatches, childPath, results)
		end
	end
end

-- Decrements `node`'s Subtree (and every ancestor's, up to and including the
-- root) by `amount`, pruning any non-root node that becomes fully empty
-- (Count == 0 and Subtree == 0) along the way. `node.Count` must already
-- reflect the removal before this runs. Pruning is mandatory (not optional)
-- so a registry with churny listeners never accumulates dead spine nodes.
const function decrementAndPrune(node: ListenerNode, amount: number)
	local current: ListenerNode? = node
	while current ~= nil do
		current.Subtree -= amount
		local parent = current.Parent
		if parent ~= nil and current.Count == 0 and current.Subtree == 0 then
			parent.Children[current.Key] = nil
		end
		current = parent
	end
end

-- Adjusts `node`'s SnapshotSubtree (and every ancestor's, up to and including
-- the root) by `delta`. Walked via Parent pointers (not the registered path),
-- so it works equally for registration (delta = +1) and disconnect/Once
-- cleanup (delta = -1) regardless of wildcard segments. No pruning here:
-- node removal is already driven by Count/Subtree in `decrementAndPrune`, and
-- every opted-in listener is also a regular listener, so SnapshotSubtree is
-- always 0 by the time a node is pruned.
const function adjustSnapshotSubtree(node: ListenerNode, delta: number)
	local current: ListenerNode? = node
	while current ~= nil do
		current.SnapshotSubtree += delta
		current = current.Parent
	end
end

-- Parallel to `adjustSnapshotSubtree` for `ProvideDiff` listeners; see
-- `WantsFullDiff`. No pruning here for the same reason.
const function adjustProvideDiffSubtree(node: ListenerNode, delta: number)
	local current: ListenerNode? = node
	while current ~= nil do
		current.ProvideDiffSubtree += delta
		current = current.Parent
	end
end

-- Non-creating node lookup: returns the node at `path` or nil if any segment is absent.
const function getNode(root: ListenerNode, path: PathArray): ListenerNode?
	local current = root
	for _, segment in path do
		current = current.Children[segment]
		if not current then
			return nil
		end
	end
	return current
end

-- Returns true if the listener should fire given how many path segments below the
-- listener's registered path the change originated.
-- relativeDepth = 0: change is AT the listener's exact path.
-- relativeDepth > 0: change originated that many levels deeper (ancestor notification).
const function shouldFireListener(listener: Listener, relativeDepth: number): boolean
	if listener.Depth == nil then
		return true
	end
	if listener.DepthStyle == "==" then
		return relativeDepth == listener.Depth
	else -- "<="
		return relativeDepth <= listener.Depth
	end
end

-- Fires all listeners of `eventType` on a single already-located node and
-- handles Once cleanup. Extracted so both the no-wildcard fast path and the
-- wildcard path share one implementation of the inner fire loop.
const function fireListenersOnNode(
	node: ListenerNode,
	eventType: EventType,
	fireEventData: EventData,
	baseRelativeDepth: number,
	fireMode: "immediate" | "deferred" | "coalesced",
	debugMode: boolean
)
	local listeners = node.Listeners[eventType]
	if listeners == nil then
		return
	end
	-- Lazily built once per node/event, shared by every opted-in listener here:
	-- only built when some listener actually opted in AND the caller computed a
	-- snapshot for this change (`fireEventData.OldValueSnapshot ~= nil`).
	local snapshotEventData: EventData? = nil
	local hasOnceFired = false
	for _, listener in listeners do
		if not listener.Connection.Connected then
			continue
		end
		if not shouldFireListener(listener, baseRelativeDepth) then
			continue
		end
		local eventDataToUse = fireEventData
		if listener.SnapshotOldValues and fireEventData.OldValueSnapshot ~= nil then
			if snapshotEventData == nil then
				snapshotEventData = table.clone(fireEventData)
				snapshotEventData.OldValue = fireEventData.OldValueSnapshot
			end
			eventDataToUse = snapshotEventData
		end
		if listener.Once then
			listener.Connection.Connected = false
			hasOnceFired = true
		end
		if fireMode == "deferred" then
			task.defer(executeListenerCallback, listener.Callback, eventType, eventDataToUse, debugMode)
		elseif fireMode == "coalesced" then
			if listener._coalescePending then
				listener._coalesceEventData = eventDataToUse
			else
				listener._coalescePending = true
				listener._coalesceEventData = eventDataToUse
				task.defer(flushCoalescedListener, listener, eventType, debugMode)
			end
		else
			if not freeRunnerThread then
				freeRunnerThread = coroutine.create(runListenerCallbackInFreeThread)
				coroutine.resume(freeRunnerThread :: thread)
			end
			task.spawn(freeRunnerThread :: thread, listener.Callback, eventType, eventDataToUse, debugMode)
		end
	end
	if hasOnceFired then
		local removed = 0
		for i = #listeners, 1, -1 do
			if listeners[i].Once and not listeners[i].Connection.Connected then
				if listeners[i].SnapshotOldValues then
					node.SnapshotCount -= 1
					adjustSnapshotSubtree(node, -1)
				end
				if listeners[i].ProvideDiff then
					node.ProvideDiffCount -= 1
					adjustProvideDiffSubtree(node, -1)
				end
				table.remove(listeners, i)
				removed += 1
			end
		end
		if next(listeners) == nil then
			node.Listeners[eventType] = nil
		end
		node.Count -= removed
		decrementAndPrune(node, removed)
	end
end

const function resolveFireMode(configuredMode: FireMode): "immediate" | "deferred" | "coalesced"
	assert(
		type(configuredMode) == "string",
		`ListenerRegistry: FireMode must be a string, got {typeof(configuredMode)}`
	)
	configuredMode = configuredMode:lower()
	if configuredMode == "bindable" then
		return if IsDeferred() then "deferred" else "immediate"
	elseif configuredMode == "immediate" or configuredMode == "deferred" or configuredMode == "coalesced" then
		return configuredMode
	end
	error(
		`ListenerRegistry: Invalid FireMode "{configuredMode}". Must be "immediate", "deferred", "bindable", or "coalesced".`
	)
end

function ListenerRegistry.new(config: ListenerRegistryConfig?): ListenerRegistry
	local self: ListenerRegistry = setmetatable({}, ListenerRegistry_MT) :: ListenerRegistry
	const resolvedConfig: ListenerRegistryConfig = config or {} :: any
	local debugMode = if resolvedConfig.DebugMode ~= nil then resolvedConfig.DebugMode else false

	self._root = createNode(nil, nil)
	self._debugMode = debugMode
	self._fireMode = resolveFireMode(resolvedConfig.FireMode or "bindable")
	self._destroyed = false
	self._hasWildcards = false
	self._hasSnapshotWildcards = false

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
	local snapshotOldValues: boolean = if options and options.SnapshotOldValues == true then true else false
	local provideDiff: boolean = if options and options.ProvideDiff == true then true else false

	-- One-way latch: once any wildcard listener is registered the fast path in
	-- FireListenersExact is permanently bypassed for this registry.
	if not self._hasWildcards then
		for _, segment in path do
			if segment == WILDCARD then
				self._hasWildcards = true
				break
			end
		end
	end
	if snapshotOldValues and not self._hasSnapshotWildcards then
		for _, segment in path do
			if segment == WILDCARD then
				self._hasSnapshotWildcards = true
				break
			end
		end
	end

	-- Navigate to the node for this path, creating nodes as needed (bumps
	-- Subtree along the way for the listener being added below).
	local node = getOrCreateNode(self._root, path)

	-- Create listener first
	local listener: Listener = {
		Callback = callback,
		Depth = depth,
		DepthStyle = depthStyle,
		Once = once,
		SnapshotOldValues = snapshotOldValues,
		ProvideDiff = provideDiff,
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
			-- Remove listener from its event-type bucket on the node
			local bucket = node.Listeners[eventType]
			if bucket then
				for i, l in bucket do
					if l.Connection == conn then
						table.remove(bucket, i)
						break
					end
				end
				if next(bucket) == nil then
					node.Listeners[eventType] = nil
				end
			end
			-- Decrement snapshot coverage counts (must happen before/independently
			-- of pruning below; node removal never depends on these fields).
			if listener.SnapshotOldValues then
				node.SnapshotCount -= 1
				adjustSnapshotSubtree(node, -1)
			end
			if listener.ProvideDiff then
				node.ProvideDiffCount -= 1
				adjustProvideDiffSubtree(node, -1)
			end
			-- Decrement coverage counts and prune now-empty nodes
			node.Count -= 1
			decrementAndPrune(node, 1)
		end,
	} :: Connection

	-- Set connection in listener
	listener.Connection = connection

	-- Store listener in the node's event-type bucket
	local bucket = node.Listeners[eventType]
	if bucket == nil then
		bucket = {}
		node.Listeners[eventType] = bucket
	end
	table.insert(bucket, listener)
	node.Count += 1
	if snapshotOldValues then
		node.SnapshotCount += 1
		adjustSnapshotSubtree(node, 1)
	end
	if provideDiff then
		node.ProvideDiffCount += 1
		adjustProvideDiffSubtree(node, 1)
	end

	return connection
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
	local root = self._root
	local debugMode = self._debugMode
	local fireMode = self._fireMode

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

	if not self._hasWildcards then
		-- Fast path: no wildcard listeners have ever been registered; walk directly to
		-- the exact node without the O(depth²) collectMatchingNodes traversal.
		local node = getNode(root, path)
		if node == nil then
			return
		end
		fireListenersOnNode(node, eventType, eventData, baseRelativeDepth, fireMode, debugMode)
		return
	end

	-- Wildcard path: collect all matching nodes (literal + wildcard branches).
	local results: { MatchedNode } = {}
	collectMatchingNodes(root, path, 1, {}, {}, results)
	if #results == 0 then
		return
	end

	for _, result in results do
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
		fireListenersOnNode(result.node, eventType, fireEventData, baseRelativeDepth, fireMode, debugMode)
	end
end

--[=[
	Conservative O(depth) coverage check: true if a change at `path` could
	reach some registered listener — one AT path, an ANCESTOR of it (ancestor
	ValueChanged/KeyChanged delivery), or a DESCENDANT of it (a deep write
	restructures the subtree a descendant listener watches). Never under-
	reports (a depth-limited listener that wouldn't actually fire still counts
	as coverage), so callers can safely skip diff work whenever this is false.

	@param path The path a write is about to land on.
	@return true if some listener could be affected by a change at `path`.
]=]
function ListenerRegistry:CoversChangesAt(path: PathArray): boolean
	if self._hasWildcards then
		return true -- a wildcard could match anywhere; no cheap way to rule it out
	end
	local node = self._root
	if node.Count > 0 then
		return true -- a root listener is an ancestor of every path
	end
	for _, segment in path do
		local child = node.Children[segment]
		if child == nil then
			return false -- no listener at this prefix, nor anywhere below it
		end
		node = child
		if node.Count > 0 then
			return true -- listener at an ancestor of `path` (or at `path` itself)
		end
	end
	return node.Subtree > 0 -- listener at `path` or somewhere in its subtree
end

-- KeyAdded/KeyRemoved/KeyChanged listeners are dispatched by ChangeDetector
-- inspecting the diff node's own CHILDREN (one level below the listener's
-- registration path) — unlike ValueChanged, which fires from the node's own
-- value with no children needed. So each such listener needs the diff to reach
-- at least 1 level below ITS OWN registration node, regardless of its own
-- ListenDepth (direct Key* dispatch ignores it; `FireListenersExact` uses
-- relativeDepth = 0 for these non-ancestor fires either way — see
-- `shouldFireListener`). KeyChanged additionally participates in the ancestor
-- walk like ValueChanged, so its own ListenDepth still matters there; this floor
-- only raises it when ListenDepth would otherwise be too shallow (< 1).
const KEY_EVENT_NEEDS_CHILD_DEPTH = {
	KeyAdded = true,
	KeyRemoved = true,
	KeyChanged = true,
}

-- Max reach (`relDepth + ListenDepth`) among listeners at or below `node`, where
-- `relDepth` is `node`'s depth below the query path. Returns `math.huge` as soon
-- as an unbounded (`ListenDepth == nil`) listener is found. Walks only the sparse
-- registry tree (listener-bearing nodes + spine), pruning empty branches via
-- `Subtree`, so it is O(observed nodes), not O(data).
const function maxReachAtOrBelow(node: ListenerNode, relDepth: number): number
	local best = 0
	if node.Count > 0 then
		for eventType, bucket in node.Listeners do
			const needsChildDepth = KEY_EVENT_NEEDS_CHILD_DEPTH[eventType]
			for _, listener in bucket do
				const d = listener.Depth
				if d == nil then
					return math.huge
				end
				const effectiveD = if needsChildDepth and d < 1 then 1 else d
				const reach = relDepth + effectiveD
				if reach > best then
					best = reach
				end
			end
		end
	end
	for _, child in node.Children do
		if child.Subtree > 0 then
			const childBest = maxReachAtOrBelow(child, relDepth + 1)
			if childBest > best then
				best = childBest
			end
		end
	end
	return best
end

--[=[
	Deepest reach (`relativeDepth + ListenDepth`) of any listener registered
	STRICTLY BELOW `path`, PLUS at least 1 if a KeyAdded/KeyRemoved/KeyChanged
	listener is registered exactly AT `path` (see `KEY_EVENT_NEEDS_CHILD_DEPTH` —
	those fire from `path`'s own children, even though registered at `path`
	itself, so they are not purely "above" the depth this query bounds).
	`math.huge` if any covered listener is unbounded, `0` if none.
]=]
function ListenerRegistry:MaxObservedDepth(path: PathArray): number
	const node = getNode(self._root, path)
	if node == nil then
		return 0
	end
	local best = 0
	for eventType in node.Listeners do
		if KEY_EVENT_NEEDS_CHILD_DEPTH[eventType] then
			best = 1
			break
		end
	end
	-- `Subtree == Count` ⇒ no descendant of `node` carries a listener.
	if node.Subtree == node.Count then
		return best
	end
	for _, child in node.Children do
		if child.Subtree > 0 then
			const childBest = maxReachAtOrBelow(child, 1) -- child is one level below `path`
			if childBest > best then
				best = childBest
			end
		end
	end
	return best
end

--[=[
	True if any listener that would fire for a change at `path` opted into
	`ProvideDiff` — an opted-in ancestor of `path` (root included; ancestors
	receive `OriginDiff`), one at `path`, or one in `path`'s subtree. When true the
	caller must diff at full depth. Mirrors `CoversChangesAt`'s walk.
]=]
function ListenerRegistry:WantsFullDiff(path: PathArray): boolean
	local node = self._root
	if node.ProvideDiffCount > 0 then
		return true -- a root opted-in listener is an ancestor of every path
	end
	for _, segment in path do
		const child = node.Children[segment]
		if child == nil then
			return false -- no node at this prefix, nor anywhere at/below `path`
		end
		node = child
		if node.ProvideDiffCount > 0 then
			return true -- opted-in listener at an ancestor of, or at, `path`
		end
	end
	return node.ProvideDiffSubtree > 0 -- opted-in listener at or below `path`
end

--[=[
	Returns the absolute path a caller should snapshot the OLD value at for a
	change landing at `path`, or `nil` if no `SnapshotOldValues` listener would
	receive a real old value for this change.

	Two kinds of listener can receive a genuine (non-synthetic) old value for
	this change:
	- One at or below `path` itself (`OnChange`/`OnValueChange` at `path` or a
	  descendant within the diff tree this change produces).
	- One at `path`'s DIRECT PARENT for the "KeyChanged"/"KeyRemoved" delivery
	  `_processDiffNode` fires one level up from EVERY node in the diff tree
	  (including `path` itself, the write's own root) — the one ancestor level
	  that carries the real diff, as opposed to the synthetic
	  `old == new == currentValue` notifications further up. A listener there
	  needs `path`'s value specifically, so when present this pins the result
	  to `path` itself (never deeper) regardless of what else qualifies below.

	Below `path`, the result is the shallowest point that still covers every
	opted-in listener in its subtree: starting at `path`, it descends while
	exactly one child branch carries opted-in listeners (`SnapshotSubtree > 0`)
	and the current node itself has none directly registered
	(`SnapshotCount == 0`). The moment two branches diverge — or a node has its
	own opted-in listener — that node is the answer, since deeper opted-in
	listeners only need to slice the resulting snapshot, never re-copy it.

	Conservative on wildcards (returns `path` itself, i.e. "snapshot everything
	at the change root") since matching wildcard branches against a concrete
	path here would duplicate `collectMatchingNodes`' job for a rare option.
	Likewise conservative about WHICH event type sits at the parent node above
	(`SnapshotCount` doesn't distinguish "KeyChanged" from "ValueChanged"): an
	opted-in `OnChange` at the parent — which would only ever see this change as
	a synthetic ancestor notification — still pins the result to `path`, same as
	a genuine `OnKeyChange` would. Over-copying in that narrow case is cheaper
	than threading event-type filtering through the aggregate counts.
]=]
function ListenerRegistry:SnapshotRootFor(path: PathArray): PathArray?
	if self._hasSnapshotWildcards then
		return path
	end

	if #path > 0 then
		local parentPath, _key = PathHelpers.GetPathParentAndKey(path)
		local parentNode = getNode(self._root, parentPath)
		if parentNode and parentNode.SnapshotCount > 0 then
			return table.clone(path)
		end
	end

	local node = getNode(self._root, path)
	if node == nil or node.SnapshotSubtree == 0 then
		return nil
	end

	local resultPath = table.clone(path)
	local current = node
	while current.SnapshotCount == 0 do
		local chosenKey: any = nil
		local chosenChild: ListenerNode? = nil
		local branches = 0
		for key, child in current.Children do
			if child.SnapshotSubtree > 0 then
				branches += 1
				if branches > 1 then
					break
				end
				chosenKey = key
				chosenChild = child
			end
		end
		if branches ~= 1 or chosenChild == nil then
			break
		end
		table.insert(resultPath, chosenKey)
		current = chosenChild
	end
	return resultPath
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
		for _, bucket in node.Listeners do
			for _, listener in bucket do
				listener.Connection.Connected = false
			end
		end
		table.clear(node.Listeners)
		node.Count = 0
		node.Subtree = 0
		node.SnapshotCount = 0
		node.SnapshotSubtree = 0
		node.ProvideDiffCount = 0
		node.ProvideDiffSubtree = 0

		for _, child in node.Children do
			destroyNode(child)
		end
		table.clear(node.Children)
	end

	destroyNode(self._root)
end

return ListenerRegistry
