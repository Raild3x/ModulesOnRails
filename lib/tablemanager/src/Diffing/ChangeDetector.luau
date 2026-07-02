--!strict
--[=[
	@class ChangeDetector
	@ignore

	Detects and reports nested table/value changes using snapshot-based diffing.

	## Workflow
	Direct compare (one-off):
	```lua
	detector:CheckForChangesBetween(oldValue, newValue, {"player", "stats"})
	```

	`CaptureSnapshot` is also available as a standalone baseline primitive for
	callers (e.g. `TableManager`'s batch flush) that need to diff a captured
	pre-batch value against the live value later via `CheckForChangesBetween`.

	## Change Types
	The detector handles table/scalar/nil transitions, including root-level changes.

	## Callback Semantics
	- Leaf callbacks include `metadata.Diff` with the exact changed node.
	- Ancestor callbacks use `metadata.Diff = nil` and fire once per assignment operation.
	- `metadata.OriginPath` always points to the assignment origin (captured path), not each leaf.
]=]

local Diff = require("./Diff")
local PathHelpers = require("../PathHelpers")
local ArrayDiffModule = require("./ArrayDiff")
local OpaqueRegistry = require("../OpaqueRegistry")
local IgnoreTrieModule = require("../IgnoreTrie")
local ShadowNode = require("../Baseline/ShadowNode")

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

	A baseline captured at a path (e.g. at batch start), later diffed against
	a live value via `CheckForChangesBetween`.
]=]
export type Snapshot<T = { [any]: any }, S = string> = {
	RootTable: T,
	Path: PathArray<S>,
	Data: Diff.Snapshot,
	Timestamp: number,
}

--[=[
	@within TableManager
	@interface AncestorSnapshot
	.RootTable { [any]: any } -- Reference to the root table, for ancestor value navigation.

	The lightweight context handed to callbacks via `ChangeMetadata.Snapshot`.
	Unlike `Snapshot`, this carries no captured baseline — it exists solely so a
	callback can navigate to live ancestor values via `RootTable`.
]=]
export type AncestorSnapshot<T = { [any]: any }> = {
	RootTable: T,
	-- Set only when `ListenerRegistry.SnapshotRootFor` found some opted-in
	-- (`SnapshotOldValues`) listener covering this change: a frozen,
	-- opacity-aware deep copy (`Diff.snapshot(...).value`) of the OLD value at
	-- the absolute path `RootPath`, captured before the change was applied.
	-- `Emitter` slices into `Value` (using the suffix of each event's absolute
	-- old-value path past `RootPath`) to build `EventData.OldValueSnapshot`.
	OldSnapshot: { Value: any, RootPath: PathArray }?,
}

export type ChangeDetector = {
	CaptureSnapshot: <T, S>(self: ChangeDetector, rootTable: T, path: PathArray<S>) -> Snapshot<T, S>,
	CheckForChangesBetween: <T, S>(
		self: ChangeDetector,
		oldValue: any,
		newValue: any,
		basePath: PathArray<S>,
		rootTable: T?,
		-- Array-aware mode (batch flush): when provided, array-like nodes are
		-- collected here (absolute paths) and excluded from the dict diff/OriginDiff
		-- for the caller to LCS-re-diff into Array* events. nil = positional behavior.
		arraySink: { Diff.ArraySinkEntry }?,
		-- See `AncestorSnapshot.OldSnapshot`. Caller-computed; nil when no
		-- opted-in listener covers this change.
		oldSnapshot: { Value: any, RootPath: PathArray }?,
		-- Transparent diff depth bound (nil = unbounded). Honoured only on the
		-- non-`arraySink` (immediate) path; ignored when `arraySink` is present.
		-- See `Coverage.ResolveDiffMaxDepth`.
		maxDepth: number?
	) -> (),
	--- Dispatches an ALREADY-BUILT root diff node at `basePath` (fires the same
	--- leaf + ancestor callbacks as `CheckForChangesBetween`) WITHOUT running
	--- `Diff.diff`. Used by linked fan-out to reuse the origin's diff node
	--- instead of re-diffing the same old/new (see `TableManager._NotifyApplied`).
	DispatchDiffNode: <T, S>(
		self: ChangeDetector,
		node: Diff.DiffNode,
		basePath: PathArray<S>,
		rootTable: T,
		oldSnapshot: { Value: any, RootPath: PathArray }?
	) -> (),
	--- Suspends change detection. While suspended, `CaptureSnapshot` is a
	--- cheap O(1) no-op. Used by `TableManager:Batch()`.
	Suspend: (self: ChangeDetector) -> (),
	--- Resumes change detection after a `Suspend` call.
	Resume: (self: ChangeDetector) -> (),
	--- Returns the opacity oracle to pass to `Diff`, or `nil` when nothing is
	--- marked opaque (per-manager or global) — lets other modules building
	--- their own `Diff.diff`/`Diff.snapshot` calls pass the same opacity rules.
	GetOpaqueCtx: (self: ChangeDetector) -> Diff.Ctx?,
}

type CD_Internal = {
	_callbacks: any,
	_debugMode: boolean,
	_suspended: boolean,
	_sentinelSnapshot: any,
	_dispatching: boolean,
	_dispatchQueue: { () -> () },
	_registries: OpaqueRegistry.Registries?,
	_opaqueCtx: Diff.Ctx?,
	_ignoreTrie: IgnoreTrieModule.Node?,

	_dispatch: (self: CD_Internal, job: () -> ()) -> (),
	_emitRootNode: (self: CD_Internal, node: Diff.DiffNode?, basePath: PathArray, ancestorSnapshot: AncestorSnapshot) -> (),
	_processDiffNode: (self: CD_Internal, node: Diff.DiffNode, nodePath: PathArray, parentPath: PathArray, nodeKey: any?, originPath: PathArray, originDiff: Diff.DiffNode, snapshot: AncestorSnapshot) -> (),
	_fireAncestorCallbacks: (self: CD_Internal, capturedPath: PathArray, rootDiff: Diff.DiffNode, snapshot: AncestorSnapshot) -> (),
} & ChangeDetector

--[=[
	@within TableManager
	@interface ChangeMetadata
	.Diff Diff.DiffNode -- Diff node for this callback level; nil for ancestor notifications.
	.OriginPath Path -- The path where the assignment operation occurred (captured path)
	.OriginDiff Diff.DiffNode -- Root diff node for the assignment operation.
	.Snapshot AncestorSnapshot -- Carries RootTable for ancestor value navigation.

	`OriginPath` is the assignment origin for both leaf and ancestor callbacks.
]=]
export type ChangeMetadata = {
	Diff: Diff.DiffNode?,
	OriginPath: PathArray,
	OriginDiff: Diff.DiffNode,
	Snapshot: AncestorSnapshot,
	-- The literal keys matched by each "*" segment of the listener's registered
	-- path, in left-to-right order. Set by ListenerRegistry; nil if the
	-- listener path had no wildcards.
	WildcardMatches: { any }?,
	-- Set on the ArrayRemoved/ArrayInserted pair from a non-batched
	-- ArraySwapRemove that constitutes a move. nil otherwise.
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
	@param registries -- Optional per-manager opacity registries (see `OpaqueRegistry`)
	@return ChangeDetector
]=]
function ChangeDetector.new(
	callbacks: {
		OnKeyAdded: <S>(path: PathArray<S>, key: any, newValue: any, metadata: ChangeMetadata) -> ()?,
		OnKeyRemoved: <S>(path: PathArray<S>, key: any, oldValue: any, metadata: ChangeMetadata) -> ()?,
		OnKeyChanged: <S>(path: PathArray<S>, key: any, newValue: any, oldValue: any, metadata: ChangeMetadata) -> ()?,
		OnValueChanged: <S>(path: PathArray<S>, newValue: any, oldValue: any?, metadata: ChangeMetadata) -> ()?,
	},
	debugMode: boolean?,
	registries: OpaqueRegistry.Registries?,
	ignoreTrie: IgnoreTrieModule.Node?
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
		-- suspended, so callers reading it via BatchUtils.GetSnapshotValue/
		-- GetSnapshotRef get nil instead of paying for a real capture.
		_sentinelSnapshot = {} :: any,
		-- Re-entrancy guard: while a check is dispatching callbacks, checks
		-- triggered from inside those callbacks are queued and run afterwards.
		_dispatching = false,
		_dispatchQueue = {} :: { () -> () },
		-- Opacity: registries is nil for managers built before this existed in
		-- tests that construct ChangeDetector directly; `GetOpaqueCtx` treats that
		-- the same as "nothing marked" (ctx == nil, zero-cost original path).
		_registries = registries,
		-- Lazily-built once activated (see `GetOpaqueCtx`); never rebuilt afterwards
		-- since the closures close over the (mutable) registry tables.
		_opaqueCtx = nil :: Diff.Ctx?,
		-- Ignored-path pruning: the root trie node (a mutable table), so later
		-- `SetPathIgnored` calls are visible without re-handing it in. nil is
		-- the same as an empty trie (nothing pruned).
		_ignoreTrie = ignoreTrie,
	}, ChangeDetector_MT) :: any

	return self :: ChangeDetector
end

--[[
	Returns the opacity oracle when anything is marked opaque (per-manager or
	global), or `nil` otherwise. `nil` means callers should pass `ctx = nil`
	through to `Diff`, hitting the exact original (no per-node probe) path.
	A frozen-table opacity mark (see `OpaqueRegistry.RegisterIfFrozenOpaque`)
	is recorded directly into `registries.Count`, so it activates this gate
	the same way an explicit `Opaque()` mark does — no separate check needed.
]]
function ChangeDetector:GetOpaqueCtx(): Diff.Ctx?
	local registries = self._registries
	if registries == nil then
		return nil
	end
	if registries.Count == 0 and OpaqueRegistry.GlobalCount() == 0 then
		return nil
	end
	if self._opaqueCtx == nil then
		-- Wire the baseline's node -> identity resolver onto the ctx at its single
		-- construction site (every consumer reads this cached object via `GetOpaqueCtx`/
		-- `GetOpaqueCtx`), so the opaque diff branch can compare a content-node slot
		-- by the child's real identity instead of the always-unequal copy.
		local ctx = OpaqueRegistry.MakeCtx(registries) :: Diff.Ctx
		ctx.identityOf = ShadowNode.IdentityOf
		self._opaqueCtx = ctx
	end
	return self._opaqueCtx
end

--------------------------------------------------------------------------------
--// Public Methods //--
--------------------------------------------------------------------------------

--[=[
	Captures a snapshot of the table at the specified path and returns a snapshot object.
	The snapshot's `.Data` can later be read (e.g. via `BatchUtils.GetSnapshotValue`)
	or diffed against a live value via `CheckForChangesBetween`.

	@param rootTable -- The root table to track changes on
	@param path -- The path to the value to snapshot (e.g., {"player", "stats"})
	@return Snapshot

	```lua
	local gameState = { player = { health = 50 } }
	local snapshot = detector:CaptureSnapshot(gameState, {"player"})
	local oldPlayer = snapshot.Data.value
	gameState.player.health = 100
	detector:CheckForChangesBetween(oldPlayer, gameState.player, {"player"}, gameState)
	```
]=]
function ChangeDetector.CaptureSnapshot(self: CD_Internal, rootTable: { [any]: any }, path: PathArray): Snapshot
	-- While suspended, skip all snapshot work and return the sentinel.
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
	debug.profilebegin("CD:CaptureSnapshot")

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
		Data = Diff.snapshot(valueAtPath, self:GetOpaqueCtx()), -- Diff.Snapshot with ref tracking
		Timestamp = os.clock(),
	}

	debug.profileend()
	return snapshot
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
function ChangeDetector.CheckForChangesBetween(
	self: CD_Internal,
	oldValue: any,
	newValue: any,
	basePath: PathArray,
	rootTable: { [any]: any }?,
	arraySink: { Diff.ArraySinkEntry }?,
	oldSnapshot: { Value: any, RootPath: PathArray }?,
	maxDepth: number?
)
	if self._debugMode then
		print("CheckForChangesBetween called:")
		print("  basePath:", table.concat(basePath, "."))
		print("  oldValue type:", type(oldValue))
		print("  newValue type:", type(newValue))
	end
	debug.profilebegin("CD:CheckForChangesBetween")
	-- If no real root table is provided, synthesize one so ancestor callbacks
	-- can still navigate to values at `basePath`.
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
	local ctx = self:GetOpaqueCtx()
	-- No deep snapshot of oldValue here: Diff.diff below compares oldValue/
	-- newValue directly (snap1/snap2 = nil), so the only thing callbacks need
	-- from this object is RootTable for their own ancestor navigation.
	local ancestorSnapshot: AncestorSnapshot = {
		RootTable = tempRootTable,
		OldSnapshot = oldSnapshot,
	}

	-- Array-aware mode (batch flush): when `arraySink` is provided, array-like
	-- nodes are collected (relative paths) and excluded from the dict tree, so the
	-- OriginDiff stays clean. They are converted to ABSOLUTE paths and appended to
	-- the caller's sink below; the caller LCS-re-diffs them into shift-faithful
	-- Array* events after all dict branches have dispatched. `localArrays` keeps
	-- the per-call relative entries separate from the shared absolute sink.
	const localArrays: { Diff.ArraySinkEntry }? = if arraySink ~= nil then {} else nil

	-- The depth bound is only safe on the immediate (non-array-aware) path: the
	-- batch flush's LCS re-diff relies on the full dict tree to locate array
	-- nodes, so it stays unbounded for now (see plan's "Risk: batch / arraySink").
	const boundedMaxDepth: number? = if arraySink == nil then maxDepth else nil

	-- Diff.diff stays INSIDE the dispatch closure so a re-entrant check queued
	-- by _dispatch diffs against state at DRAIN time (see _dispatch's note on
	-- collapsing chained re-entrant writes).
	self:_dispatch(function()
		debug.profilebegin("Dispatch")
		local rootDiffNode = Diff.diff(oldValue, newValue, nil, nil, ctx, localArrays, boundedMaxDepth)
		self:_emitRootNode(rootDiffNode, basePath, ancestorSnapshot)
		debug.profileend()
	end)

	if arraySink ~= nil and localArrays ~= nil then
		for _, entry in localArrays do
			const absPath: Diff.Path = table.clone(basePath) :: any
			for _, segment in entry.path do
				table.insert(absPath, segment)
			end
			table.insert(arraySink, { path = absPath, old = entry.old, new = entry.new })
		end
	end
	debug.profileend()
end

--[=[
	Dispatches an already-built `node` at `basePath` against `rootTable` — fires
	the exact same leaf + ancestor callbacks as `CheckForChangesBetween`, just
	without re-running `Diff.diff`. The node is immutable here (there is nothing
	to re-diff at drain time), so it is simply emitted through the same
	re-entrancy-ordered dispatch queue.

	Used by linked fan-out (`TableManager._NotifyApplied`) to replay the ORIGIN's
	diff node on a recipient instead of recomputing the identical diff.
]=]
function ChangeDetector.DispatchDiffNode(
	self: CD_Internal,
	node: Diff.DiffNode,
	basePath: PathArray,
	rootTable: { [any]: any },
	oldSnapshot: { Value: any, RootPath: PathArray }?
)
	local ancestorSnapshot: AncestorSnapshot = {
		RootTable = rootTable,
		OldSnapshot = oldSnapshot,
	}
	self:_dispatch(function()
		self:_emitRootNode(node, basePath, ancestorSnapshot)
	end)
end

--[=[
	Suspends change detection.

	While suspended, `CaptureSnapshot` returns a cheap sentinel value instead of
	performing a full snapshot. This means every assignment through
	`ProxyManager.__newindex` costs O(1) instead of a full snapshot cycle.

	Used by `TableManager:Suspend()` / `TableManager:Batch()`. Always pair with
	a matching `Resume()` call.
]=]
function ChangeDetector.Suspend(self: CD_Internal)
	self._suspended = true
end

--[=[
	Resumes change detection after a `Suspend` call.
]=]
function ChangeDetector.Resume(self: CD_Internal)
	self._suspended = false
end

--------------------------------------------------------------------------------
--// Private Methods //--
--------------------------------------------------------------------------------

-- Runs `job` then drains `self._dispatchQueue`. A single module-level function
-- (rather than a closure literal built fresh inside `_dispatch` on every call)
-- so `pcall` below can call it by reference + args instead of allocating a new
-- closure per dispatch — `job` and `self` are passed through as `pcall` args.
const function runDispatchJob(self: CD_Internal, job: () -> ())
	job()
	while #self._dispatchQueue > 0 do
		local queued = table.remove(self._dispatchQueue, 1) :: () -> ()
		queued()
	end
end

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
function ChangeDetector._dispatch(self: CD_Internal, job: () -> ())
	if self._dispatching then
		table.insert(self._dispatchQueue, job)
		return
	end

	self._dispatching = true
	local ok, err = pcall(runDispatchJob, self, job)
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

--[[
	Shared tail of `CheckForChangesBetween` and `DispatchDiffNode`: given an
	already-built root diff `node` for `basePath`, runs the DFS leaf callbacks
	and the base-level ancestor callbacks. No-op when `node` is nil (no changes).
	Must be called inside a `_dispatch` closure.
]]
function ChangeDetector._emitRootNode(self: CD_Internal, node: Diff.DiffNode?, basePath: PathArray, ancestorSnapshot: AncestorSnapshot)
	if not node then
		return
	end
	debug.profilebegin("emitRootNode")

	local rootParentPath: PathArray = {}
	local rootKey: any? = nil
	if #basePath > 0 then
		rootParentPath = table.create(#basePath - 1)
		table.move(basePath, 1, #basePath - 1, 1, rootParentPath)
		rootKey = basePath[#basePath]
	end

	-- Process all leaf changes via DFS; basePath is both the current path and
	-- the origin. Fire ancestor callbacks for the base level afterward.
	self:_processDiffNode(node, basePath, rootParentPath, rootKey, basePath, node, ancestorSnapshot)
	self:_fireAncestorCallbacks(basePath, node, ancestorSnapshot)
	debug.profileend()
end

--[=[
	DFS traversal for diff nodes.
	Fires callbacks for each node with origin metadata from the root assignment.
]=]
function ChangeDetector._processDiffNode(
	self: CD_Internal,
	node: Diff.DiffNode,
	nodePath: PathArray,
	parentPath: PathArray,
	nodeKey: any?,
	originPath: PathArray,
	originDiff: Diff.DiffNode,
	snapshot: AncestorSnapshot
)
	-- Ignored-path pruning: skip this node AND its descendants entirely (no
	-- recursion, no callbacks). `nodePath` is already the absolute path, so
	-- this is the one place a path-ignore mark can intercept changes that
	-- arrive nested inside a larger write (e.g. a root replacement) — the
	-- write's own exact path is instead pre-pruned in `Mutator.applyWrite`,
	-- before any snapshot/diff work happens.
	if IgnoreTrieModule.IsPathIgnored(self._ignoreTrie, nodePath) then
		return
	end

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
			local childPath = PathHelpers.Append(nodePath, key)

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
	Walks ancestor levels of `basePath` from `fromDepth` down to 0 (inclusive),
	firing `emitKeyChanged`/`emitValueChanged` for each level. Shared by
	ChangeDetector's own ancestor notifications and TableManager's synthetic
	(array-operation) ancestor notifications, which differ in:

	- Walk start: ChangeDetector skips the captured level itself
	  (`fromDepth = #basePath - 1`, already processed by DFS); TableManager
	  includes its base level (`fromDepth = #basePath`).
	- Value source: `rootTable` is navigated to produce live current values
	  (ChangeDetector); `nil` to always pass nil values (TableManager's
	  synthetic notifications carry no Diff/value payload).
	- `keyChangedMode`:
	  - "parent": at level i >= 1, fires KeyChanged(parentPath, basePath[i],
	    keyValue, nil, metadata) BEFORE ValueChanged(currentPath, ...).
	    (ChangeDetector.)
	  - "child": at level i < #basePath, fires ValueChanged(currentPath, ...)
	    THEN KeyChanged(currentPath, basePath[i + 1], nil, nil, metadata).
	    (TableManager.)
	  - "none": only ValueChanged fires at each level (`includeKeyChanged =
	    false` callers, e.g. `Emitter.fireAncestorValueChangedNotifications`).
]=]
function ChangeDetector.EmitAncestorNotifications(
	basePath: PathArray,
	fromDepth: number,
	metadata: ChangeMetadata,
	rootTable: any?,
	keyChangedMode: "parent" | "child" | "none",
	emitKeyChanged: (
		path: PathArray,
		key: any,
		newValue: any,
		oldValue: any,
		metadata: ChangeMetadata
	) -> (),
	emitValueChanged: (
		path: PathArray,
		newValue: any,
		oldValue: any,
		metadata: ChangeMetadata
	) -> ()
)
	debug.profilebegin("CD:EmitAncestorNotifications")
	-- Pre-navigate rootTable once, caching the value at each depth 0..fromDepth.
	-- The original code re-navigated from the root at every ancestor level
	-- (O(0+1+…+depth) = O(depth²) hash lookups); this reduces it to one O(depth) pass.
	local cachedValues: { any }?
	if rootTable ~= nil then
		cachedValues = table.create(fromDepth + 1)
		local v: any = rootTable
		cachedValues[1] = v -- depth 0 → index 1
		for d = 1, fromDepth do
			if type(v) == "table" then
				v = (v :: any)[basePath[d]]
			else
				v = nil
			end
			cachedValues[d + 1] = v -- depth d → index d+1
		end
	end

	-- Build the deepest prefix once; every level's path is a bounded slice of
	-- it. Each fired path must still be its own fresh table (Signal:Fire leaks
	-- the reference), so a `table.move` bulk copy replaces the previous
	-- per-element Lua loop at each level — same O(i) elements copied, but as a
	-- single native bulk-copy call instead of an interpreted loop.
	local prefix: PathArray = table.create(fromDepth)
	for j = 1, fromDepth do
		prefix[j] = basePath[j]
	end

	for i = fromDepth, 0, -1 do
		local currentValue: any = if cachedValues then cachedValues[i + 1] else nil

		if keyChangedMode == "parent" and i >= 1 then
			local currentPath: PathArray = table.move(prefix, 1, i, 1, table.create(i))
			local parentPath: PathArray = table.move(prefix, 1, i - 1, 1, table.create(i - 1))

			local key = basePath[i]
			local keyValue = nil
			if currentValue ~= nil and type(currentValue) == "table" then
				keyValue = (currentValue :: any)[key]
			end
			emitKeyChanged(parentPath, key, keyValue, nil, metadata)
			emitValueChanged(currentPath, currentValue, currentValue, metadata)
		else
			local currentPath: PathArray = table.move(prefix, 1, i, 1, table.create(i))
			emitValueChanged(currentPath, currentValue, currentValue, metadata)

			if keyChangedMode == "child" and i < #basePath then
				local changedKey = basePath[i + 1]
				emitKeyChanged(currentPath, changedKey, nil, nil, metadata)
			end
		end
	end
	debug.profileend()
end

--[=[
	Notifies parent levels above the captured path once per assignment operation.
	Ancestor callbacks receive Diff=nil and share OriginPath/OriginDiff metadata.
]=]
function ChangeDetector._fireAncestorCallbacks(
	self: CD_Internal,
	capturedPath: PathArray,
	rootDiff: Diff.DiffNode,
	snapshot: AncestorSnapshot
)
	-- If captured at root level (empty path), no ancestors to notify
	if #capturedPath == 0 then
		return
	end

	local callbacks = self._callbacks

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

	ChangeDetector.EmitAncestorNotifications(
		capturedPath,
		#capturedPath - 1,
		metadata,
		snapshot.RootTable,
		"parent",
		callbacks.OnKeyChanged,
		callbacks.OnValueChanged
	)
end

return ChangeDetector
