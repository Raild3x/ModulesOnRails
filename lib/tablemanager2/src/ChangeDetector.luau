--!strict
--[=[
	@class ChangeDetector
	@ignore

	Detects and reports nested table/value changes using snapshot-based diffing.

	## Workflows
	1. Capture then check (stateful):
	```lua
	local snapshot = detector:CaptureSnapshot(root, {"player", "stats"})
	-- mutate root...
	detector:CheckForChanges(snapshot)
	```
	2. Direct compare (one-off):
	```lua
	detector:CheckForChangesBetween(oldValue, newValue, {"player", "stats"})
	```

	## Change Types
	The detector handles table/scalar/nil transitions, including root-level changes.

	## Callback Semantics
	- Leaf callbacks include `metadata.Diff` with the exact changed node.
	- Ancestor callbacks use `metadata.Diff = nil` and fire once per assignment operation.
	- `metadata.OriginPath` always points to the assignment origin (captured path), not each leaf.
]=]

local Diff = require("./Diff")
local PathHelpers = require("./PathHelpers")
local ArrayDiffModule = require("./ArrayDiff")

--// Types //--
type Path<S = string> = PathHelpers.Path<S>
type PathArray<S = string> = PathHelpers.PathArray<S>
type MoveMetadata = ArrayDiffModule.MoveMetadata

--[=[
	@within ChangeDetector
	@interface Snapshot
	.RootTable { [any]: any } -- Reference to the root table being tracked (for ancestor navigation)
	.Path PathArray -- The path where the snapshot was captured (e.g., {"Player", "Stats"})
	.Data Diff.Snapshot -- The Diff.Snapshot of the value at the captured path
	.Timestamp number -- Capture timestamp (debugging/ordering)

	State captured at a path and reused by CheckForChanges.
]=]
export type Snapshot<T = { [any]: any }, S = string> = {
	RootTable: T,
	Path: PathArray<S>,
	Data: Diff.Snapshot,
	Timestamp: number,
}

export type ChangeDetector = {
	CaptureSnapshot: <T, S>(self: ChangeDetector, rootTable: T, path: PathArray<S>) -> Snapshot<T, S>,
	CheckForChanges: <T, S>(self: ChangeDetector, snapshot: Snapshot<T, S>) -> (),
	CheckForChangesBetween: <T, S>(
		self: ChangeDetector,
		oldValue: any,
		newValue: any,
		basePath: PathArray<S>,
		rootTable: T?
	) -> (),
	SetDebugMode: (self: ChangeDetector, enabled: boolean) -> (),
	--- Suspends change detection. While suspended, `CaptureSnapshot` and
	--- `CheckForChanges` are no-ops (O(1)). Used by `TableManager:Batch()`.
	Suspend: (self: ChangeDetector) -> (),
	--- Resumes change detection after a `Suspend` call.
	Resume: (self: ChangeDetector) -> (),
}

--[=[
	@within ChangeDetector
	@interface ChangeMetadata
	Diff Diff.DiffNode -- Diff node for this callback level; nil for ancestor notifications.
	OriginPath Path -- The path where the assignment operation occurred (captured path)
	OriginDiff Diff.DiffNode -- Root diff node for the assignment operation.
	Snapshot Snapshot -- Snapshot used for this comparison.

	`OriginPath` is the assignment origin for both leaf and ancestor callbacks.
]=]
export type ChangeMetadata = {
	Diff: Diff.DiffNode?,
	OriginPath: PathArray,
	OriginDiff: Diff.DiffNode,
	Snapshot: Snapshot,
	-- The literal keys matched by each "*" segment of the listener's registered
	-- path, in left-to-right order. Set by ListenerRegistry; nil if the
	-- listener path had no wildcards.
	WildcardMatches: { any }?,
	-- Set on ArrayRemoved/ArrayInserted/ArrayMoved when the operation is part of
	-- a detected move (Branch B coalescing only). nil otherwise.
	Move: MoveMetadata?,
	-- Set on synthetic array-operation events (ArrayInserted/ArrayRemoved/
	-- ArraySet), including their ancestor notifications. Carries explicit shift
	-- semantics for consumers that apply the OriginDiff tree: a flattened
	-- "removed" entry at a numeric leaf cannot otherwise be distinguished from
	-- an in-place nil write (a hole), nor "added" from a non-shifting index
	-- write. ArrayInserted/ArrayRemoved shift later elements; ArraySet does not.
	ArrayOp: { Kind: "ArrayInserted" | "ArrayRemoved" | "ArraySet", Index: number }?,
}

--------------------------------------------------------------------------------
--// Module //--
--------------------------------------------------------------------------------

local ChangeDetector = {}
local ChangeDetector_MT = { __index = ChangeDetector }

--------------------------------------------------------------------------------
--// Constructor //--
--------------------------------------------------------------------------------

--[=[
	Creates a new ChangeDetector instance.
	
	@param callbacks -- Callbacks for different change events
	@param debugMode -- Optional flag to enable debug logging
	@return ChangeDetector
]=]
function ChangeDetector.new(
	callbacks: {
		OnKeyAdded: <S>(path: PathArray<S>, key: any, newValue: any, metadata: ChangeMetadata) -> ()?,
		OnKeyRemoved: <S>(path: PathArray<S>, key: any, oldValue: any, metadata: ChangeMetadata) -> ()?,
		OnKeyChanged: <S>(path: PathArray<S>, key: any, newValue: any, oldValue: any, metadata: ChangeMetadata) -> ()?,
		OnValueChanged: <S>(path: PathArray<S>, newValue: any, oldValue: any?, metadata: ChangeMetadata) -> ()?,
	},
	debugMode: boolean?
): ChangeDetector
	callbacks.OnKeyAdded = callbacks.OnKeyAdded or function() end
	callbacks.OnKeyRemoved = callbacks.OnKeyRemoved or function() end
	callbacks.OnKeyChanged = callbacks.OnKeyChanged or function() end
	callbacks.OnValueChanged = callbacks.OnValueChanged or function() end

	local self = setmetatable({
		_callbacks = callbacks,
		_debugMode = debugMode or false,
		_suspended = false,
		-- Sentinel snapshot: a fixed table that CaptureSnapshot returns when
		-- suspended. CheckForChanges recognises it and returns immediately.
		_sentinelSnapshot = {} :: any,
		-- Re-entrancy guard: while a check is dispatching callbacks, checks
		-- triggered from inside those callbacks are queued and run afterwards.
		_dispatching = false,
		_dispatchQueue = {} :: { () -> () },
	}, ChangeDetector_MT) :: any

	return self :: ChangeDetector
end

--------------------------------------------------------------------------------
--// Public Methods //--
--------------------------------------------------------------------------------

--[=[
	Captures a snapshot of the table at the specified path and returns a snapshot object.
	The snapshot can later be passed to CheckForChanges.
	
	@param rootTable -- The root table to track changes on
	@param path -- The path to the value to snapshot (e.g., {"player", "stats"})
	@return Snapshot
	
	```lua
	local gameState = { player = { health = 50 } }
	local snapshot = detector:CaptureSnapshot(gameState, {"player"})
	gameState.player.health = 100
	detector:CheckForChanges(snapshot)
	```
]=]
function ChangeDetector:CaptureSnapshot(rootTable: { [any]: any }, path: PathArray): Snapshot
	-- While suspended, skip all snapshot work and return the sentinel.
	-- CheckForChanges will recognise it and return immediately too.
	if self._suspended then
		return self._sentinelSnapshot
	end

	if type(rootTable) ~= "table" then
		error("CaptureSnapshot expects rootTable to be a plain table.")
	end

	if self._debugMode then
		print("CaptureSnapshot called:")
		print("  path:", table.concat(path, "."))
		print("  rootTable type:", type(rootTable))
	end

	-- Navigate to the value at the path
	local valueAtPath = rootTable
	for _, key in ipairs(path) do
		if valueAtPath == nil then
			error(`Failed to reach key: {key}, Path {table.concat(path, ".")} does not exist in table`)
		end
		valueAtPath = valueAtPath[key]
	end

	-- Create snapshot using Diff.snapshot (includes reference tracking)
	local snapshot: Snapshot = {
		RootTable = rootTable, -- Keep reference to root (not copied)
		Path = table.clone(path), -- Clone the path array
		Data = Diff.snapshot(valueAtPath), -- Diff.Snapshot with ref tracking
		Timestamp = os.clock(),
	}

	return snapshot
end

--[=[
	Checks for changes between a captured snapshot and the current state of the table.
	
	@param snapshot -- The snapshot object to compare against (from CaptureSnapshot)
	
	```lua
	local detector = ChangeDetector.new({
		OnKeyRemoved = function(path, key, oldValue, metadata)
			print("Key removed:", key, "from", table.concat(path, "."))
			print("  Had value:", oldValue)
		end,
		OnValueChanged = function(path, newValue, oldValue, metadata)
			if metadata.Diff then
				print("Value at", table.concat(path, "."), "changed")
				print("  ", oldValue, "->", newValue)
			else
				print("Ancestor at", table.concat(path, "."), "notified")
				print("  Origin:", table.concat(metadata.OriginPath, "."))
			end
		end,
	})
	
	local myTable = { 
		player = { 
			name = "Alice", 
			inventory = { "sword", "shield" } 
		} 
	}
	
	local snapshot = detector:CaptureSnapshot(myTable, {"player"})
	
	-- Make changes...
	myTable.player.name = "Bob"
	myTable.player.inventory = nil
	
	-- Detect changes
	detector:CheckForChanges(snapshot)
	
	-- Output:
	-- Value at player.name changed
	--   Alice -> Bob
	-- Key removed: inventory from player
	--   Had value: table
	-- Ancestor at player has changes
	--   Current: { name = "Bob" }
	```
]=]
function ChangeDetector:CheckForChanges(snapshot: Snapshot)
	-- Sentinel returned by CaptureSnapshot while suspended — nothing to diff.
	if snapshot == self._sentinelSnapshot then
		return
	end

	if not snapshot or not snapshot.RootTable then
		error("Invalid snapshot object. Must be created with CaptureSnapshot().")
	end

	if type(snapshot.RootTable) ~= "table" then
		error("Invalid snapshot object. Snapshot.RootTable must be a plain table.")
	end

	if self._debugMode then
		print("CheckForChanges called:")
		print("  path:", table.concat(snapshot.Path, "."))
		print("  timestamp:", snapshot.Timestamp)
	end

	self:_dispatch(function()
		-- Navigate to current state using stored path and root table reference
		local currentValue = snapshot.RootTable
		for _, key in ipairs(snapshot.Path) do
			currentValue = currentValue[key]
			if currentValue == nil then
				-- Path no longer exists - entire subtree was removed
				break
			end
		end

		-- Use diffFromSnapshot to compare against the captured Diff.Snapshot
		local rootDiffNode = Diff.diffFromSnapshot(snapshot.Data, currentValue)

		-- Process the root node if there are changes
		if rootDiffNode then
			local rootParentPath: Path = {}
			local rootKey: any? = nil
			if #snapshot.Path > 0 then
				rootParentPath = table.create(#snapshot.Path - 1)
				table.move(snapshot.Path, 1, #snapshot.Path - 1, 1, rootParentPath)
				rootKey = snapshot.Path[#snapshot.Path]
			end

			-- Process all leaf changes via DFS
			-- Pass the snapshot to all callbacks for context
			self:_processDiffNode(
				rootDiffNode,
				snapshot.Path,
				rootParentPath,
				rootKey,
				snapshot.Path,
				rootDiffNode,
				snapshot
			)

			-- Fire ancestor callbacks for the captured level
			-- The origin is the captured path (where the assignment happened)
			self:_fireAncestorCallbacks(snapshot.Path, rootDiffNode, snapshot)
		end
	end)
end

--[=[
	Directly compares two values and detects changes without requiring a snapshot.
	
	@param oldValue -- The old value (before change)
	@param newValue -- The new value (after change)
	@param basePath -- The path to this value in the table hierarchy
	
	```lua
	local detector = ChangeDetector.new({
		OnKeyChanged = function(path, key, newValue, oldValue, metadata)
			print("Key", key, "changed at", table.concat(path, "."))
			print("  Old:", oldValue, "-> New:", newValue)
			print("  Type:", metadata.Diff and metadata.Diff.type)
		end,
		OnKeyAdded = function(path, key, newValue, metadata)
			print("Key", key, "added at", table.concat(path, "."))
			print("  Value:", newValue)
			print("  Type:", metadata.Diff and metadata.Diff.type)
		end,
	})
	
	local oldTable = { 
		config = { 
			host = "localhost", 
			port = 8080 
		} 
	}
	local newTable = { 
		config = { 
			host = "example.com", 
			port = 8080,
			ssl = true
		} 
	}
	
	-- Direct comparison without snapshot
	detector:CheckForChangesBetween(oldTable, newTable, {"server"})
	
	-- Output:
	-- Key host changed at server.config.host
	--   Old: localhost -> New: example.com
	-- Key ssl added at server.config.ssl
	--   Value: true
	```
]=]
function ChangeDetector:CheckForChangesBetween(
	oldValue: any,
	newValue: any,
	basePath: PathArray,
	rootTable: { [any]: any }?
)
	if self._debugMode then
		print("CheckForChangesBetween called:")
		print("  basePath:", table.concat(basePath, "."))
		print("  oldValue type:", type(oldValue))
		print("  newValue type:", type(newValue))
	end

	-- Create a temporary snapshot for the old value.
	-- If no real root table is provided, synthesize one so ancestor callbacks remain
	-- backward-compatible and can still navigate values at `basePath`.
	local tempRootTable: { [any]: any }
	if rootTable then
		tempRootTable = rootTable
	else
		warn(
			"No Root Table Provided. Ancestor callbacks will receive a synthetic root with the changed value at the base path."
		)
		if #basePath == 0 then
			tempRootTable = if type(newValue) == "table" then newValue else { __value = newValue }
		else
			tempRootTable = {}
			local cursor: any = tempRootTable
			for i = 1, #basePath - 1 do
				local segment = basePath[i]
				cursor[segment] = {}
				cursor = cursor[segment]
			end
			cursor[basePath[#basePath]] = newValue
		end
	end
	local tempSnapshot: Snapshot = {
		RootTable = tempRootTable,
		Path = basePath,
		Data = Diff.snapshot(oldValue), -- Snapshot the old value
		Timestamp = os.clock(),
	}

	self:_dispatch(function()
		-- Use Diff module to generate tree
		local rootDiffNode = Diff.diff(oldValue, newValue)

		-- Process the root node if there are changes
		if rootDiffNode then
			local rootParentPath: Path = {}
			local rootKey: any? = nil
			if #basePath > 0 then
				rootParentPath = table.create(#basePath - 1)
				table.move(basePath, 1, #basePath - 1, 1, rootParentPath)
				rootKey = basePath[#basePath]
			end

			-- Process all leaf changes via DFS
			-- Pass the basePath as both the current path and origin
			-- Include the temporary snapshot for context
			self:_processDiffNode(rootDiffNode, basePath, rootParentPath, rootKey, basePath, rootDiffNode, tempSnapshot)

			-- Fire ancestor callbacks for the base level
			-- The origin is the basePath (where the assignment happened)
			self:_fireAncestorCallbacks(basePath, rootDiffNode, tempSnapshot)
		end
	end)
end

--[=[
	Sets debug mode on or off.
	
	@param enabled -- Whether to enable debug logging
]=]
function ChangeDetector:SetDebugMode(enabled: boolean)
	self._debugMode = enabled
end

--[=[
	Suspends change detection.

	While suspended, `CaptureSnapshot` returns a cheap sentinel value and
	`CheckForChanges` is a no-op when given that sentinel. This means every
	assignment through `ProxyManager.__newindex` costs O(1) instead of performing
	a full snapshot + diff cycle.

	Used by `TableManager:Suspend()` / `TableManager:Batch()`. Always pair with
	a matching `Resume()` call.
]=]
function ChangeDetector:Suspend()
	self._suspended = true
end

--[=[
	Resumes change detection after a `Suspend` call.
]=]
function ChangeDetector:Resume()
	self._suspended = false
end

--------------------------------------------------------------------------------
--// Private Methods //--
--------------------------------------------------------------------------------

--[[
	Runs `job` now, or queues it when a check is already dispatching callbacks
	(a re-entrant check triggered by a write from inside a listener). Queued
	jobs run after the current dispatch fully completes, so the event stream
	for the OUTER write is always delivered before the events of any write it
	triggered. Without this, a listener writing back during notification (e.g.
	a clamp) emits its nested events FIRST, and a consumer applying events in
	receipt order ends on the pre-clamp value.

	Note: a queued check diffs against the state at DRAIN time, so chained
	re-entrant writes may collapse into fewer events; the net result is
	unchanged.
]]
function ChangeDetector:_dispatch(job: () -> ())
	if self._dispatching then
		table.insert(self._dispatchQueue, job)
		return
	end

	self._dispatching = true
	local ok, err = pcall(function()
		job()
		while #self._dispatchQueue > 0 do
			local queued = table.remove(self._dispatchQueue, 1) :: () -> ()
			queued()
		end
	end)
	self._dispatching = false
	if not ok then
		table.clear(self._dispatchQueue)
		error(err, 3)
	end
end

--[[
	Helper to fire callbacks for a single node in the diff tree.
	Encapsulates the common callback firing logic to reduce duplication.
]]
local function fireNodeCallbacks(
	callbacks: any,
	basePath: Path,
	nodePath: Path,
	nodeKey: any?,
	diffNode: Diff.DiffNode,
	metadata: ChangeMetadata
)
	local OnKeyAdded = callbacks.OnKeyAdded
	local OnKeyRemoved = callbacks.OnKeyRemoved
	local OnKeyChanged = callbacks.OnKeyChanged
	local OnValueChanged = callbacks.OnValueChanged

	if diffNode.type == "changed" or diffNode.type == "descendantChanged" then
		-- Only fire OnKeyChanged if there's actually a key (not at root level)
		if nodeKey ~= nil then
			OnKeyChanged(basePath, nodeKey, diffNode.new, diffNode.old, metadata)
		end
		OnValueChanged(nodePath, diffNode.new, diffNode.old, metadata)
	elseif diffNode.type == "added" then
		-- Only fire OnKeyAdded if there's actually a key (not at root level)
		if nodeKey ~= nil then
			OnKeyAdded(basePath, nodeKey, diffNode.new, metadata)
		end
		OnValueChanged(nodePath, diffNode.new, nil, metadata)
	elseif diffNode.type == "removed" then
		-- Only fire OnKeyRemoved if there's actually a key (not at root level)
		if nodeKey ~= nil then
			OnKeyRemoved(basePath, nodeKey, diffNode.old, metadata)
		end
		OnValueChanged(nodePath, nil, diffNode.old, metadata)
	end
end

--[=[
	DFS traversal for diff nodes.
	Fires callbacks for each node with origin metadata from the root assignment.
]=]
function ChangeDetector:_processDiffNode(
	node: Diff.DiffNode,
	nodePath: PathArray,
	parentPath: PathArray,
	nodeKey: any?,
	originPath: PathArray,
	originDiff: Diff.DiffNode,
	snapshot: Snapshot
)
	local callbacks = self._callbacks
	local debugMode = self._debugMode

	if debugMode then
		print(`Processing diff node at path: {table.concat(nodePath, ".")}, type: {node.type}`)
	end

	-- Recurse into children if present. The scalar-sentinel child (the scalar
	-- side of a table<->scalar transition) is processed LAST: it represents
	-- this node's own replacement value, so consumers must receive the
	-- subtree's teardown events (e.g. removed {b,v}) BEFORE the event that
	-- collapses the node to a scalar ({b}=5). pairs() order would otherwise
	-- make this nondeterministic, and a consumer that applied the scalar first
	-- would then try to apply child events through a non-table value.
	if node.children then
		local sentinelChild: Diff.DiffNode? = nil
		for key, childNode in node.children do
			if key == Diff.ScalarSentinel then
				sentinelChild = childNode
				continue
			end
			local childPath = table.clone(nodePath)
			table.insert(childPath, key)

			-- Pass the same origin path, origin diff, and snapshot down through recursion
			self:_processDiffNode(childNode, childPath, nodePath, key, originPath, originDiff, snapshot)
		end

		if sentinelChild then
			-- The sentinel child represents a scalar replacement at this exact
			-- node, so it keeps the same nodePath and key as its parent node.
			self:_processDiffNode(
				sentinelChild,
				table.clone(nodePath),
				parentPath,
				nodeKey,
				originPath,
				originDiff,
				snapshot
			)
		end
	end

	-- Create metadata for this node
	-- OriginPath is the captured path (where the assignment occurred)
	-- OriginDiff is the root diff (the entire operation)
	-- Snapshot provides context for ancestor value navigation
	local metadata: ChangeMetadata = {
		Diff = node,
		OriginPath = originPath, -- Where the assignment happened
		OriginDiff = originDiff, -- The root diff of the entire operation
		Snapshot = snapshot, -- Snapshot object with root table + path
	}

	-- Fire callbacks for this node
	fireNodeCallbacks(callbacks, parentPath, nodePath, nodeKey, node, metadata)
end

--[=[
	Notifies parent levels above the captured path once per assignment operation.
	Ancestor callbacks receive Diff=nil and share OriginPath/OriginDiff metadata.
]=]
function ChangeDetector:_fireAncestorCallbacks(capturedPath: PathArray, rootDiff: Diff.DiffNode, snapshot: Snapshot)
	-- If captured at root level (empty path), no ancestors to notify
	if #capturedPath == 0 then
		return
	end

	if self._debugMode then
		print(`Firing ancestor callbacks above captured path: {table.concat(capturedPath, ".")}`)
	end

	local callbacks = self._callbacks
	local OnKeyChanged = callbacks.OnKeyChanged
	local OnValueChanged = callbacks.OnValueChanged

	-- Create metadata for ancestor notifications
	-- Diff is nil to indicate these are ancestor notifications
	-- OriginPath is the captured path (where the assignment operation occurred)
	-- Snapshot provides context for ancestor value access
	local metadata: ChangeMetadata = {
		Diff = nil,
		OriginPath = capturedPath,
		OriginDiff = rootDiff,
		Snapshot = snapshot,
	}

	-- Walk up from the PARENT of the captured level to root
	-- Start at i = #capturedPath - 1 to skip the captured level (already processed by DFS)
	for i = #capturedPath - 1, 1, -1 do
		local currentPath = { unpack(capturedPath, 1, i) }
		local parentPath = if i > 1 then { unpack(capturedPath, 1, i - 1) } else {}
		local key = capturedPath[i]

		-- Navigate to the current value at this ancestor level once and reuse it.
		local currentValue = snapshot.RootTable
		for _, k in ipairs(currentPath) do
			currentValue = currentValue[k]
			if currentValue == nil then
				break
			end
		end

		-- Get the value at the key for OnKeyChanged
		local keyValue = nil
		if currentValue ~= nil and type(currentValue) == "table" then
			keyValue = currentValue[key]
		end

		if self._debugMode then
			print(
				`  Ancestor: parentPath=[{table.concat(parentPath, ", ")}], key={key}, currentPath=[{table.concat(
					currentPath,
					", "
				)}], value type={type(keyValue)}`
			)
		end

		-- Fire OnKeyChanged for this level with the true current value
		OnKeyChanged(parentPath, key, keyValue, nil, metadata)

		-- Fire OnValueChanged for this level with the true current value
		OnValueChanged(currentPath, currentValue, currentValue, metadata)
	end

	-- Always fire OnValueChanged for root (unless captured at root)
	if #capturedPath > 0 then
		-- Root is just the RootTable itself
		OnValueChanged({}, snapshot.RootTable, snapshot.RootTable, metadata)
	end
end

return ChangeDetector
