--!strict
--[=[
	@class TableManager

	TableManager is a wrapper around luau tables that provide easy and automatic 
	change tracking, validation, and listener management. TableManager is designed
	to handle the bulk of your volatile data management needs, emitting detailed change 
	events and snapshots for any changes made to the managed table or its descendants — all 
	without needing to manually fire events or manage listener connections.

	## What is TableManager good for?
	- Tracking changes to nested tables and arrays.
	- Emitting detailed change events for any modifications.
	- Providing snapshots of the current state for debugging or synchronization.
	- Integrating with ProfileStore for easy management of player data.

	### What TableManager is Not
	- TableManager is not a state management library, and does not include any opinionated
	features for structuring your data, managing side effects, or integrating with
	other systems. It is purely a change tracking and notification system for tables.
	- TableManager is not intended to be used with tables that are mutated by external code 
	without going through TableManager's API.
	- TableManager is not meant for data with a high frequency of updates. It focuses on providing
	detailed and accurate change information, which can be expensive to generate for large or 
	rapidly changing data.

	
	## Usage
	
	```lua
	const manager = TableManager.new({
		player = { health = 100, level = 5 },
		settings = { volume = 80 }
	})
	
	-- Listen to direct changes only
	manager:OnValueChange("player", function(newValue, oldValue, metadata)
		if metadata.Diff then
			print("Player table replaced!")
		end
	end)
	
	-- Listen to all changes (including descendants)
	manager:OnValueChange("player", function(newValue, oldValue, metadata)
		if metadata.Diff then
			print("Direct change to player")
		else
			print("Descendant changed at:", table.concat(metadata.OriginPath, "."))
		end
	end)
	
	-- Array operations with ancestor notifications
	manager:ArrayInsert("player.items", "Sword")
	```

	## Best Practices
	- Avoid keeping large datastructures within arrays contained within a tablemanager. It is best 
	to manage the array separately and have a TableManager for each object.

	- Avoid mixed tables.

	- Avoid 
]=]

--// Imports //--
const T = require("../T")
const Signal = require("../Signal")
const PathHelpers = require("./PathHelpers")
const BatchUtilsModule = require("./BatchUtils")
const BatchFlushModule = require("./BatchFlush")
const ProxyManagerModule = require("./ProxyManager")
const ListenerRegistryModule = require("./ListenerRegistry")
const ChangeDetectorModule = require("./ChangeDetector")
const SchemaNavigatorModule = require("./SchemaNavigator")
const ArrayDiffModule = require("./ArrayDiff")
const Diff = require("./Diff")
const LinkGroupModule = require("./LinkGroup")
const LinkerModule = require("./Linker")

--// Localize batch utils to avoid function call overhead //--
const createSyntheticSnapshot = BatchUtilsModule.CreateSyntheticSnapshot
const markBatchBranchDirty = BatchUtilsModule.MarkBatchBranchDirty
const ensureBatchPathTracking = BatchUtilsModule.EnsureBatchPathTracking

--// Types //--
type Path<S> = PathHelpers.Path<S>
type PathArray<S = string> = PathHelpers.PathArray<S>
type ValueAtPath<T, S> = PathHelpers.ValueAtPath<T, S>
type ListenerRegistry = ListenerRegistryModule.ListenerRegistry
type ChangeDetector = ChangeDetectorModule.ChangeDetector
type ChangeMetadata = ChangeDetectorModule.ChangeMetadata
type ListenerOptions = ListenerRegistryModule.ListenerOptions
type Connection = ListenerRegistryModule.Connection
type Signal<Fn, Args...> = Signal.Signal<Fn, Args...>
type MoveMetadata = ArrayDiffModule.MoveMetadata
type SchemaCheck = SchemaNavigatorModule.Check
type BatchState = BatchUtilsModule.BatchState
type table = { [any]: any }

export type Proxy<T, S> = ProxyManagerModule.Proxy<T, S>

export type LinkGroup = LinkGroupModule.LinkGroup
export type LinkAnchor = LinkGroupModule.LinkAnchor
export type AppliedOp = LinkGroupModule.AppliedOp

export type DuplicateReferenceMode = "error" | "warn" | "allow" | "move" | "copy"

export type TableManagerConfig = {
	Schema: SchemaCheck?,
	OnValidationFailed: ((path: PathArray, value: any, err: string) -> ())?,
	ListenersFireDeferred: boolean?,
	DuplicateReferenceMode: DuplicateReferenceMode?, -- Experimental
	EnableProxies: boolean?, -- Defaults to true. When false, `Proxy`/`GetProxy` are unavailable.
	-- When true, this manager auto-links (via `tm.Linker`) with any OTHER AutoLink
	-- manager whose root table is a node inside this one's tree, or vice-versa.
	-- Directly-assigned managed tables link automatically; nested/bulk placements
	-- are hooked up with `tm.Linker:Ensure(path)`.
	AutoLink: boolean?,
}

export type TableManager<T = { [any]: any }> = {
	Proxy: Proxy<T, "">?,
	Raw: T,

	-- Signals (fire once per change)
	ValueChanged: Signal<(path: PathArray, newValue: any, oldValue: any) -> (), PathArray, any, any>,
	KeyAdded: Signal<(path: PathArray, key: any, newValue: any) -> (), PathArray, any, any>,
	KeyRemoved: Signal<(path: PathArray, key: any, oldValue: any) -> (), PathArray, any, any>,
	KeyChanged: Signal<(path: PathArray, key: any, newValue: any, oldValue: any) -> (), PathArray, any, any, any>,
	ArrayInserted: Signal<(path: PathArray, index: number, newValue: any) -> (), PathArray, number, any>,
	ArrayRemoved: Signal<(path: PathArray, index: number, oldValue: any) -> (), PathArray, number, any>,
	ArraySet: Signal<(path: PathArray, index: number, newValue: any, oldValue: any) -> (), PathArray, number, any, any>,

	-- Listener registration (fire for ancestors/descendants) --

	-- Fires when this path is directly reassigned OR any descendant of it
	OnChange: <S>(
		self: TableManager<T>,
		path: Path<S>,
		callback: (newValue: ValueAtPath<T, S>, oldValue: ValueAtPath<T, S>?, metadata: ChangeMetadata) -> (),
		options: ListenerOptions?
	) -> Connection,

	--- Fires ONLY when this exact path is directly reassigned (not when a
	--- descendant changes). Shorthand for `OnValueChange` with
	--- `ListenDepth = 0, ListenDepthStyle = "=="`.
	OnValueChange: <S>(
		self: TableManager<T>,
		path: Path<S>,
		callback: (newValue: ValueAtPath<T, S>, oldValue: ValueAtPath<T, S>?, metadata: ChangeMetadata) -> (),
		options: ListenerOptions?
	) -> Connection,

	--- Immediately invokes `callback` with the current value at `path`
	--- (`oldValue` and `metadata` both `nil`), then behaves like
	--- `OnValueChange` for subsequent changes.
	Observe: <S>(
		self: TableManager<T>,
		path: Path<S>,
		callback: (newValue: ValueAtPath<T, S>, oldValue: ValueAtPath<T, S>?, metadata: ChangeMetadata?) -> (),
		options: ListenerOptions?
	) -> Connection,

	OnKeyAdd: <S>(
		self: TableManager<T>,
		path: Path<S>,
		callback: (key: any, newValue: any, metadata: ChangeMetadata) -> (),
		options: ListenerOptions?
	) -> Connection,
	OnKeyRemove: <S>(
		self: TableManager<T>,
		path: Path<S>,
		callback: (key: any, oldValue: any, metadata: ChangeMetadata) -> (),
		options: ListenerOptions?
	) -> Connection,
	OnKeyChange: <S>(
		self: TableManager<T>,
		path: Path<S>,
		callback: (key: any, newValue: ValueAtPath<T, S>, oldValue: ValueAtPath<T, S>, metadata: ChangeMetadata) -> (),
		options: ListenerOptions?
	) -> Connection,
	OnArrayInsert: <S>(
		self: TableManager<T>,
		path: Path<S>,
		callback: (index: number, newValue: any, metadata: ChangeMetadata) -> (),
		options: ListenerOptions?
	) -> Connection,
	OnArrayRemove: <S>(
		self: TableManager<T>,
		path: Path<S>,
		callback: (index: number, oldValue: any, metadata: ChangeMetadata) -> (),
		options: ListenerOptions?
	) -> Connection,
	OnArraySet: <S>(
		self: TableManager<T>,
		path: Path<S>,
		callback: (index: number, newValue: any, oldValue: any, metadata: ChangeMetadata) -> (),
		options: ListenerOptions?
	) -> Connection,
	-- Helper methods
	Get: <S>(self: TableManager<T>, path: Path<S>, suppressNilPartialPaths: boolean?) -> ValueAtPath<T, S>,
	GetProxy: <S>(self: TableManager<T>, path: Path<S>, suppressNilPartialPaths: boolean?) -> Proxy<T, S>,
	Set: <S>(self: TableManager<T>, path: Path<S>, value: ValueAtPath<T, S>) -> (),
	ArrayInsert: <S>(self: TableManager<T>, arrPath: Path<S> | Proxy<T, S>, newValue: any) -> ()
		& <S>(self: TableManager<T>, arrPath: Path<S> | Proxy<T, S>, index: number, newValue: any) -> (),
	ArrayRemove: <S>(self: TableManager<T>, arrPath: Path<S> | Proxy<T, S>, index: number) -> any?,
	ArrayRemoveFirstValue: <S>(self: TableManager<T>, arrPath: Path<S> | Proxy<T, S>, valueToFind: any) -> number?,
	ArraySwapRemove: <S>(self: TableManager<T>, arrPath: Path<S> | Proxy<T, S>, index: number) -> any?,
	ArraySwapRemoveFirstValue: <S>(self: TableManager<T>, arrPath: Path<S> | Proxy<T, S>, valueToFind: any) -> number?,
	MoveTo: <S1, S2>(self: TableManager<T>, currentPath: Path<S1>, newPath: Path<S2>) -> (),
	CopyTo: <S1, S2>(self: TableManager<T>, currentPath: Path<S1>, newPath: Path<S2>) -> (),
	Swap: <S1, S2>(self: TableManager<T>, a: Path<S1>, b: Path<S2>) -> (),
	-- ForceNotify: <S>(self: TableManager<T>, path: Path<S> | Proxy<T, S>) -> (),
	Batch: (self: TableManager<T>, fn: () -> ()) -> (),
	Suspend: (self: TableManager<T>) -> (),
	Resume: (self: TableManager<T>) -> (),

	-- All linking lives here (see `Linker`): With / Ensure / Unlink / GetManagers
	-- / IsLinkedWith / GetGroups.
	Linker: Linker,

	-- Returns a PLAIN TableManager rooted at the shared table found at `target`
	-- (a proxy, a path, or a raw value already in this manager's tree), linked
	-- to this manager via `Link` so writes on either side fan out to the other.
	Extend: <S>(self: TableManager<T>, target: Proxy<T, S> | Path<S>, config: ExtendConfig?) -> TableManager<ValueAtPath<T, S>>,

	Destroy: (self: TableManager<T>) -> (),
}

export type Linker = LinkerModule.Linker

export type ExtendConfig = {
	-- Called when the extended manager's anchor diverges (the shared object is
	-- removed/replaced in this manager's tree) and it leaves the link group.
	-- Equivalent to listening on the group's `MemberRemoved` for the extended manager.
	OnDetached: (() -> ())?,
}

export type TM_Internal<T = { [any]: any }> = TableManager<T> & {
	-- fields
	_proxyManager: ProxyManagerModule.ProxyManager<T>?,
	_listenerRegistry: ListenerRegistry,
	_changeDetector: ChangeDetector,
	_originalData: T,
	_schema: SchemaCheck?,
	_onValidationFailed: (<S>(path: Path<S>, value: any, err: string) -> ())?,
	_duplicateReferenceMode: DuplicateReferenceMode,
	_isDuplicateMoveInProgress: boolean?,
	_Destroyed: boolean?,
	-- Batch state
	_batchDepth: number,
	_batch: BatchState?,
	-- Exposes the write/fire core's `makeEmit` to BatchFlush without a circular require.
	_MakeEmit: (path: PathArray) -> ArrayDiffModule.Emit,
	-- Link state
	_linkGroups: { LinkGroup }?,
	_suppressLinkFanOut: boolean?,
	-- Set from `Config.AutoLink`; gates the direct write-path auto-link hook.
	_autoLink: boolean?,

	-- Re-fires listeners/signals for an op that has ALREADY been applied to the
	-- shared raw, WITHOUT mutating or snapshot-diffing. Used only by LinkGroup
	-- fan-out; `op.Path` is in this manager's own coordinates.
	_NotifyApplied: (self: TM_Internal<T>, op: AppliedOp) -> (),
}

--------------------------------------------------------------------------------
--// Module //--
--------------------------------------------------------------------------------

const TableManager = {}
const TableManager_MT = { __index = TableManager }

-- Re-export T so schema users do not need to import it separately.
TableManager.T = T

const function resolvePathFromPathOrProxy<T, S>(self: TM_Internal<T>, pathOrProxy: Path<S> | Proxy<T, S>): PathArray<S>
	const proxyManager = self._proxyManager
	if proxyManager == nil then
		if ProxyManagerModule.IsProxyValue(pathOrProxy) then
			error("GetProxy requires proxies (Config.EnableProxies = false for this TableManager)")
		end
		return PathHelpers.ParsePath(pathOrProxy :: Path<S>)
	end
	if proxyManager:IsProxy(pathOrProxy) then
		const proxy = pathOrProxy :: Proxy<T, S>
		const potentialPath = proxyManager:GetPath(proxy)
		assert(potentialPath, "Proxy does not have a path")
		return potentialPath
	end
	return PathHelpers.ParsePath(pathOrProxy :: Path<S>)
end

--[[
	Resolves `pathOrProxy` to a parsed path and the raw array at that path
	(proxy-free). Proxy arguments are still accepted (resolved to their live
	path via the proxy graph).
]]
const function resolveArrayForWrite<T, S>(self: TM_Internal<T>, pathOrProxy: Path<S> | Proxy<T, S>): (PathArray<S>, { any })
	const parsedPath = resolvePathFromPathOrProxy(self, pathOrProxy)
	const array = self:Get(parsedPath)
	assert(type(array) == "table", "Target is not a table")
	return parsedPath, array :: { any }
end

const function getParentOriginalAtPath<T, S>(self: TM_Internal<T>, parentPath: PathArray<S>, opName: string): {}
	local parentOriginal = if #parentPath == 0 then self._originalData else self:Get(parentPath)
	if type(parentOriginal) ~= "table" then
		error(`{opName} destination parent must be a table`)
	end
	return parentOriginal
end

const function deepCloneValue(value: any, seen: { [any]: any }?): any
	if type(value) ~= "table" then
		return value
	end

	const memo = seen or {}
	if memo[value] ~= nil then
		return memo[value]
	end

	const clone = {}
	memo[value] = clone
	for k, v in value do
		clone[deepCloneValue(k, memo)] = deepCloneValue(v, memo)
	end
	return clone
end

const function createSyntheticDiffNode(
	kind: "added" | "removed" | "changed",
	key: any,
	newValue: any,
	oldValue: any
): Diff.DiffNode
	return {
		type = kind,
		new = newValue,
		old = oldValue,
		key = key,
	}
end

const function createSyntheticMetadata<T, S>(
	rootTable: T & table,
	leafPath: PathArray<S>,
	kind: "added" | "removed" | "changed",
	key: any,
	newValue: any,
	oldValue: any
): ChangeMetadata
	return {
		Diff = createSyntheticDiffNode(kind, key, newValue, oldValue),
		OriginPath = leafPath,
		OriginDiff = createSyntheticDiffNode(kind, key, newValue, oldValue),
		Snapshot = createSyntheticSnapshot(rootTable, leafPath, newValue),
	}
end

type ReparentRollback<T = { [any]: any }, S = string> = {
	Proxy: Proxy<T, S>,
	Parent: any?,
	Key: any?,
}

const function reparentWithRollback<T, S>(
	self: TM_Internal<T>,
	proxy: Proxy<T, S>?,
	newParent: any,
	newKey: any
): ReparentRollback<T, S>?
	if proxy == nil then
		return nil
	end

	local oldParent: any? = nil
	local oldKey: any? = nil
	const existingMeta = self._proxyManager:GetMetadata(proxy)
	if existingMeta ~= nil then
		oldParent = existingMeta.Parent
		oldKey = existingMeta.Key
	end

	self._proxyManager:ReparentProxy(proxy, newParent, newKey)

	return {
		Proxy = proxy,
		Parent = oldParent,
		Key = oldKey,
	}
end

const function restoreReparent<T, S>(self: TM_Internal<T>, rollback: ReparentRollback<T, S>?)
	if rollback == nil then
		return
	end
	self._proxyManager:ReparentProxy(rollback.Proxy, rollback.Parent, rollback.Key)
end

const function fireAncestorValueChangedNotifications<T, S>(
	manager: any, --TM_Internal<T>, -- typing this causes it to freak out for some reason
	basePath: PathArray<S>,
	metadata: ChangeMetadata,
	includeKeyChanged: boolean?
)
	const ancestorMetadata: ChangeMetadata = {
		Diff = nil,
		OriginPath = metadata.OriginPath,
		OriginDiff = metadata.OriginDiff,
		Snapshot = metadata.Snapshot,
		-- Preserve array-op shift semantics for root/ancestor diff consumers.
		ArrayOp = metadata.ArrayOp,
	}

	const keyChangedMode = if includeKeyChanged == false then "none" else "child"

	ChangeDetectorModule.EmitAncestorNotifications(
		basePath :: { any },
		#basePath,
		ancestorMetadata,
		nil,
		keyChangedMode,
		function(path, key, newValue, oldValue, m)
			manager._listenerRegistry:FireListenersExact("KeyChanged", path, {
				Key = key,
				NewValue = newValue,
				OldValue = oldValue,
				Metadata = m,
			})
		end,
		function(path, newValue, oldValue, m)
			manager._listenerRegistry:FireListenersExact("ValueChanged", path, {
				NewValue = newValue,
				OldValue = oldValue,
				Metadata = m,
			})
		end
	)
end

const function fireArrayOperation<T, S1, S2>(
	manager: TM_Internal<T>,
	eventName: "ArrayInserted" | "ArrayRemoved" | "ArraySet",
	basePath: PathArray<S1>,
	leafPath: PathArray<S2>,
	payload: any
)
	-- Tag the metadata with explicit shift semantics for diff-tree consumers
	-- (metadata.OriginDiff via root OnChange listeners): a flattened "removed"
	-- entry at a numeric leaf cannot otherwise be distinguished from an
	-- in-place nil write (a hole), nor "added" from a non-shifting index write.
	payload.Metadata.ArrayOp = { Kind = eventName, Index = payload.Index }

	-- Fire at the element path (e.g. {"items", 2}) for element-level listeners,
	-- then at the array path (e.g. {"items"}) for array-level listeners.
	manager._listenerRegistry:FireListenersExact(eventName, leafPath, payload)
	manager._listenerRegistry:FireListenersExact(eventName, basePath, payload)
	fireAncestorValueChangedNotifications(manager, basePath, payload.Metadata)
	if eventName == "ArrayInserted" then
		manager.ArrayInserted:Fire(basePath, payload.Index, payload.NewValue)
	elseif eventName == "ArrayRemoved" then
		manager.ArrayRemoved:Fire(basePath, payload.Index, payload.OldValue)
	elseif eventName == "ArraySet" then
		manager.ArraySet:Fire(basePath, payload.Index, payload.NewValue, payload.OldValue)
	end

	if not manager._suppressLinkFanOut then
		LinkGroupModule.FanOutArrayOp(manager, eventName, basePath, payload)
	end
end

const function validateWrite<T, S>(self: TM_Internal<T>, path: PathArray<S>, value: ValueAtPath<T, S>): (boolean, string?)
	if not self._schema then
		return true :: any
	end

	const ok, err = SchemaNavigatorModule.Validate(self._schema, path, value)
	if ok then
		return true :: any
	end

	const message = err or `Schema validation failed at {PathHelpers.PathToString(path)}`
	if self._onValidationFailed then
		self._onValidationFailed(path, value, message)
		return false, nil
	end

	return false, message
end

--[[
	Fires `ArrayInserted` for an append (key == length + 1) write that was just
	applied to the raw array at `path`. During a batch, marks the array path as
	tracked and the branch dirty instead of firing immediately; the flush diffs
	the pre-batch snapshot against the current array via LCS.
]]
const function onArrayAppended<T, S>(self: TM_Internal<T>, path: PathArray<S>, index: number, newValue: any)
	if self._batchDepth > 0 then
		const batch = self._batch
		if batch then
			ensureBatchPathTracking(batch, path)
		end
		markBatchBranchDirty(batch, path)
		return
	end

	const insertPath: { any } = PathHelpers.Append(path :: any, index)

	const metadata = createSyntheticMetadata(self._originalData, insertPath, "added", index, newValue, nil)

	-- Fire listeners at inserted element's path ONLY (we handle ancestors separately)
	fireArrayOperation(self, "ArrayInserted", path, insertPath, {
		Index = index,
		NewValue = newValue,
		Metadata = metadata,
	})
end

--[[
	Resolves the duplicate-table-reference policy (error/warn/allow/move/copy) for
	a write of `value` (already known to exist elsewhere at `existingPath`) to
	`writePath`. Returns true if the write should proceed.
]]
const function resolveDuplicateReferencePolicy<T, S1, S2>(
	self: TM_Internal<T>,
	writePath: PathArray<S1>,
	existingPath: PathArray<S2>,
	value: any
): boolean
	if self._duplicateReferenceMode == "allow" then
		return true
	end

	const writePathStr = PathHelpers.PathToString(writePath)
	const existingPathStr = PathHelpers.PathToString(existingPath)
	const duplicateMessage =
		`Duplicate table reference detected: existing at {existingPathStr}, attempted write to {writePathStr}`

	if self._duplicateReferenceMode == "warn" then
		warn(duplicateMessage)
		return true
	end

	if self._duplicateReferenceMode == "move" then
		if self._isDuplicateMoveInProgress then
			return true
		end

		self._isDuplicateMoveInProgress = true
		local ok, moveErr = pcall(function()
			self:MoveTo(existingPath, writePath)
		end)
		self._isDuplicateMoveInProgress = false

		if not ok then
			error(`Failed to move duplicate table reference: {tostring(moveErr)}`, 2)
		end

		if self:Get(writePath) ~= value then
			error(
				`DuplicateReferenceMode 'move' is not fully implemented yet. Expected MoveTo to place the value at {writePathStr}`,
				2
			)
		end

		return false
	end

	if self._duplicateReferenceMode == "copy" then
		error("DuplicateReferenceMode 'copy' is not implemented yet", 2)
	end

	error(duplicateMessage, 2)
end

--[[
	Checks whether `value` (a table) already lives elsewhere in the tree (tracked
	via the proxy graph). Returns true if the write should proceed. Orphaned
	proxies (whose live path no longer resolves back to the same original table)
	are treated as regular table assignments.
]]
const function checkDuplicateTableWrite<T, S>(self: TM_Internal<T>, writePath: PathArray<S>, value: any): boolean
	const proxyManager = self._proxyManager
	if proxyManager == nil then
		return true
	end

	const existingProxy = proxyManager:GetProxyFromOriginal(value)
	if existingProxy == nil then
		return true
	end

	const existingPath = proxyManager:GetPath(existingProxy)
	if existingPath == nil or PathHelpers.ArePathsEqual(existingPath, writePath) then
		return true
	end

	const isOrphan = self:Get(existingPath, true) ~= value
	if isOrphan then
		return true
	end

	return resolveDuplicateReferencePolicy(self, writePath, existingPath, value)
end

--[[
	Evicts proxy-graph bookkeeping for a table value that was just detached by a
	write (overwritten or removed), so the detached subtree can be garbage
	collected. During a batch the prune is deferred to the end of Resume: a value
	detached early in the batch may be re-homed later in the same window (e.g.
	Swap's second Set), and PruneOriginal's liveness guard then spares it.
]]
const function pruneDetachedValue<T>(self: TM_Internal<T>, oldValue: any, newValue: any)
	if type(oldValue) ~= "table" or oldValue == newValue then
		return
	end
	const proxyManager = self._proxyManager
	if proxyManager == nil then
		return
	end

	const batch = self._batch
	if self._batchDepth > 0 and batch then
		table.insert(batch.PendingPrunes, oldValue)
	else
		proxyManager:PruneOriginal(oldValue)
	end
end

--[[
	The single proxy-free write core. `parsedPath` is the full path of the write
	(including the final key); `value` must already be unwrapped
	(`ProxyManagerModule.Unwrap`). Mirrors the order of the old proxy
	`__newindex`: duplicate check -> validation -> array-append fast path ->
	batch dirty-marking -> snapshot/write/diff.
]]
const function applyWrite<T, S>(self: TM_Internal<T>, parsedPath: PathArray<S>, value: any)
	const parentPath, key = PathHelpers.GetPathParentAndKey(parsedPath :: any)

	-- Navigate to the raw parent table, mirroring Get()'s error convention: the
	-- error names the segment whose lookup produced a non-table value.
	local current: any = self._originalData
	for _, segment in parentPath do
		if type(current) ~= "table" then
			error(`Path segment {segment} is not a table`)
		end
		current = current[segment]
	end
	if type(current) ~= "table" then
		error(`Path segment {key} is not a table`)
	end
	const parentTable: { [any]: any } = current

	-- Duplicate-reference checks happen before validation/mutation. Orphaned
	-- proxies are intentionally treated as regular table assignments.
	if type(value) == "table" and self._proxyManager ~= nil then
		const shouldProceed = checkDuplicateTableWrite(self, parsedPath, value)
		if not shouldProceed then
			return
		end
	end

	-- Validate writes before any side effects (batch tracking, snapshots, or mutation).
	const ok, err = validateWrite(self, parsedPath, value)
	if not ok then
		if err then
			error(err, 2)
		end
		return
	end

	-- Array-append fast path (key == length + 1): apply immediately and report
	-- the insertion. Skips batch dirty-marking and snapshot/diff entirely.
	const isArray, arrayLength = ProxyManagerModule.ClassifyTable(parentTable)
	if isArray and type(key) == "number" and key == arrayLength + 1 then
		parentTable[key] = value
		onArrayAppended(self, parentPath, key, value)
		-- Direct auto-link for an appended managed table (parsedPath is the element path).
		if self._autoLink and not self._suppressLinkFanOut then
			LinkGroupModule.CheckAutoLink(self, parsedPath, value)
		end
		return
	end

	if self._batchDepth > 0 then
		const batch = self._batch

		-- Non-append numeric assignment on an array: track the array path so the
		-- flush diffs the pre-batch snapshot against the current array via LCS.
		if isArray and type(key) == "number" and batch then
			ensureBatchPathTracking(batch, parentPath)
		end

		markBatchBranchDirty(batch, parentPath)
	end

	-- Standard change detection workflow: capture a snapshot before the write,
	-- apply it, then let ChangeDetector diff against the captured snapshot.
	const oldValue = parentTable[key]
	const snapshot = self._changeDetector:CaptureSnapshot(self._originalData, parsedPath)
	parentTable[key] = value
	if not self._suppressLinkFanOut then
		LinkGroupModule.CheckDivergence(self, parsedPath)
		-- Direct auto-link: a managed table assigned straight to this path links O(1).
		if self._autoLink then
			LinkGroupModule.CheckAutoLink(self, parsedPath, value)
		end
	end
	pruneDetachedValue(self, oldValue, value)
	self._changeDetector:CheckForChanges(snapshot)
end

--[[
	Builds the `Emit` interface for a single array path, wiring the three
	callbacks to fire `ArrayRemoved` / `ArrayInserted` / `ArraySet` signals,
	exact-path listeners, and ancestor callbacks in the correct order.
]]
const function makeEmit<T, S>(self: TM_Internal<T>, path: PathArray<S>)
	return {
		removed = function(index: number, oldValue: any, move: MoveMetadata?)
			const removedPath: PathArray = PathHelpers.Append(path, index)
			const metadata = createSyntheticMetadata(self._originalData, removedPath, "removed", index, nil, oldValue)
			metadata.Move = move
			fireArrayOperation(self, "ArrayRemoved", path, removedPath, {
				Index = index,
				OldValue = oldValue,
				Metadata = metadata,
			})
		end,
		inserted = function(index: number, newValue: any, move: MoveMetadata?)
			const insertedPath = PathHelpers.Append(path, index)
			const metadata = createSyntheticMetadata(self._originalData, insertedPath, "added", index, newValue, nil)
			metadata.Move = move
			fireArrayOperation(self, "ArrayInserted", path, insertedPath, {
				Index = index,
				NewValue = newValue,
				Metadata = metadata,
			})
		end,
		set = function(index: number, newValue: any, oldValue: any, move: MoveMetadata?)
			const setPath = PathHelpers.Append(path, index)
			const metadata = createSyntheticMetadata(self._originalData, setPath, "changed", index, newValue, oldValue)
			metadata.Move = move
			fireArrayOperation(self, "ArraySet", path, setPath, {
				Index = index,
				NewValue = newValue,
				OldValue = oldValue,
				Metadata = metadata,
			})
		end,
	}
end

-----------------------------------------------------------------------------------
--// Constructor //--
-----------------------------------------------------------------------------------

--[=[
	@within TableManager
	@function new

	Creates a new TableManager instance.

	@param initialData table -- The initial table data to manage. Must be a table.
	@param config TableManagerConfig? -- Optional configuration for the TableManager.
	@return TableManager -- The newly created TableManager instance.
]=]
function TableManager.new<T>(initialData: T, config: TableManagerConfig?): TableManager<T>
	const self: TM_Internal<T> = (setmetatable({}, TableManager_MT) :: any) :: TM_Internal<T>
	const resolvedConfig = config or {} :: { [string]: any? }
	const duplicateReferenceMode: DuplicateReferenceMode = resolvedConfig.DuplicateReferenceMode or "error"

	assert(type(initialData) == "table", "Initial data must be a table")
	-- Store original data
	self._originalData = initialData
	self.Raw = self._originalData
	self._schema = resolvedConfig.Schema
	self._onValidationFailed = resolvedConfig.OnValidationFailed
	self._duplicateReferenceMode = duplicateReferenceMode

	-- Validate initial data against the root schema at construction time.
	if self._schema then
		const ok, err = SchemaNavigatorModule.Validate(self._schema, {}, self._originalData)
		if not ok then
			const message = err or "Schema validation failed at <root>"
			if self._onValidationFailed then
				self._onValidationFailed({}, self._originalData, message)
			end
			error(message, 2)
		end
	end

	-- Batch state (reset at start of each Suspend/Resume cycle)
	self._batchDepth = 0
	self._batch = nil

	-- Exposes `makeEmit` (write/fire core) to BatchFlush without a circular require.
	self._MakeEmit = function(path: PathArray): ArrayDiffModule.Emit
		return makeEmit(self, path)
	end

	const enableProxies = resolvedConfig.EnableProxies ~= false
	if not enableProxies and resolvedConfig.DuplicateReferenceMode ~= nil then
		warn("DuplicateReferenceMode has no effect when Config.EnableProxies = false")
	end

	-- Initialize subsystems
	if enableProxies then
		self._proxyManager = ProxyManagerModule.new(self._originalData)
	else
		self._proxyManager = nil
		self.Proxy = nil :: any
	end
	self._listenerRegistry = ListenerRegistryModule.new {
		DebugMode = false,
		FireDeferred = resolvedConfig.ListenersFireDeferred == true,
	}

	-- Initialize signals (fire once per change)
	self.ValueChanged = Signal.new() :: any
	self.KeyAdded = Signal.new() :: any
	self.KeyRemoved = Signal.new() :: any
	self.KeyChanged = Signal.new() :: any
	self.ArrayInserted = Signal.new() :: any
	self.ArrayRemoved = Signal.new() :: any
	self.ArraySet = Signal.new() :: any

	-- Suppresses non-array change events whose location is at or under a
	-- tracked array path during batch array flush (see BatchFlush.ShouldSuppress).
	const function shouldSuppressBatchArrayEvent(location: PathArray): boolean
		return BatchFlushModule.ShouldSuppress(self :: any, location)
	end

	-- Initialize ChangeDetector with callbacks
	-- NOTE: Use FireListenersExact() to prevent double ancestor propagation
	-- ChangeDetector already handles ancestor notifications, so we only fire at exact paths
	self._changeDetector = ChangeDetectorModule.new {
		OnKeyAdded = function(path: PathArray, key: any, newValue: any, metadata: ChangeMetadata)
			if shouldSuppressBatchArrayEvent(PathHelpers.Append(path, key)) then
				return
			end

			-- Fire the signal BEFORE the registry listeners. If a listener performs a
			-- re-entrant write, its nested signal then fires after this one, so the
			-- public signal stream stays in write-initiation order (deterministic for
			-- consumers like replication). Signal fires for leaf changes only.
			if metadata.Diff and metadata.Diff.type ~= "descendantChanged" then
				self.KeyAdded:Fire(path, key, newValue)
			end

			-- Fire listeners ONLY at exact path (ChangeDetector handles ancestors)
			self._listenerRegistry:FireListenersExact("KeyAdded", path, {
				NewValue = newValue,
				Key = key,
				Metadata = metadata,
			})
		end,

		OnKeyRemoved = function(path: PathArray, key: any, oldValue: any, metadata: ChangeMetadata)
			if shouldSuppressBatchArrayEvent(PathHelpers.Append(path, key)) then
				return
			end

			if metadata.Diff and metadata.Diff.type ~= "descendantChanged" then
				self.KeyRemoved:Fire(path, key, oldValue)
			end

			self._listenerRegistry:FireListenersExact("KeyRemoved", path, {
				OldValue = oldValue,
				Key = key,
				Metadata = metadata,
			})
		end,

		OnKeyChanged = function(path: PathArray, key: any, newValue: any, oldValue: any, metadata: ChangeMetadata)
			if shouldSuppressBatchArrayEvent(PathHelpers.Append(path, key)) then
				return
			end

			if metadata.Diff and metadata.Diff.type ~= "descendantChanged" then
				self.KeyChanged:Fire(path, key, newValue, oldValue)
			end

			self._listenerRegistry:FireListenersExact("KeyChanged", path, {
				NewValue = newValue,
				OldValue = oldValue,
				Key = key,
				Metadata = metadata,
			})
		end,

		OnValueChanged = function(path: PathArray, newValue: any, oldValue: any?, metadata: ChangeMetadata)
			-- During batch array flush, suppress events at or under a tracked array
			-- path; those arrays emit their own coalesced Array* events in the array
			-- flush phase, so firing ValueChanged here too would double-apply.
			if shouldSuppressBatchArrayEvent(path) then
				return
			end

			-- Signal before listeners (see OnKeyAdded for the rationale).
			if metadata.Diff and metadata.Diff.type ~= "descendantChanged" then
				self.ValueChanged:Fire(path, newValue, oldValue)
			end

			self._listenerRegistry:FireListenersExact("ValueChanged", path, {
				NewValue = newValue,
				OldValue = oldValue,
				Metadata = metadata,
			})

			-- Link fan-out: only for leaf changes (mirrors the signal-fire gate
			-- above), and never while replaying another member's fan-out.
			if metadata.Diff and metadata.Diff.type ~= "descendantChanged" and not self._suppressLinkFanOut then
				LinkGroupModule.FanOutSet(self, path, newValue, oldValue)
			end
		end,
	}

	if self._proxyManager then
		-- Single write-integration point: every proxy write resolves its live path
		-- and unwrapped value, then flows through the proxy-free write core.
		self._proxyManager:SetWriteHandler(function(path: PathArray, value: any)
			applyWrite(self, path, value)
		end)

		-- Create root proxy (no parent, no key)
		self.Proxy = self._proxyManager:CreateProxy(self._originalData, nil, nil)
	end

	-- Public linking facade (lightweight; heavy link state stays lazy).
	self.Linker = LinkerModule.new(self)

	-- Opt-in auto-link: form any links implied by the current tree topology
	-- (this manager nested inside another, or others nested inside it).
	if resolvedConfig.AutoLink then
		self._autoLink = true
		LinkGroupModule.RegisterAutoLink(self)
	end

	return self :: any
end

--------------------------------------------------------------------------------
--// Linking //--
--------------------------------------------------------------------------------

--[=[
	@within TableManager
	@function Link

	Joins TableManagers (or interior nodes within them) that share one
	underlying table by identity into a notify-only `LinkGroup`. A write
	applied through any member fans out to every other current member,
	translated into that member's own path coordinates. See `LinkGroup`.

	Two call forms:
	- `TableManager.Link({ {managerA, pathA?}, {managerB, pathB?}, ... })`
	- `TableManager.Link(managerA, pathA, managerB, pathB)`
]=]
TableManager.Link = LinkGroupModule.Link :: any

--[=[
	Re-fires listeners/signals for an op that has ALREADY been applied to the
	shared raw (by another linked manager), without mutating or
	snapshot-diffing. `op.Path` is in this manager's own coordinates. Used only
	by `LinkGroup` fan-out.
]=]
function TableManager._NotifyApplied<T>(self: TM_Internal<T>, op: AppliedOp)
	if self._Destroyed then
		return
	end

	self._suppressLinkFanOut = true
	const ok, err = pcall(function()
		if op.Kind == "Set" then
			pruneDetachedValue(self, op.OldValue, op.NewValue)
			self._changeDetector:CheckForChangesBetween(op.OldValue, op.NewValue, op.Path, self._originalData)
		elseif op.Kind == "ArrayInsert" then
			const index = op.Index :: number
			if self._proxyManager then
				const array = self:Get(op.Path, true)
				if type(array) == "table" then
					self._proxyManager:ShiftKeys(array, index, 1)
				end
			end
			makeEmit(self, op.Path).inserted(index, op.NewValue)
		elseif op.Kind == "ArrayRemove" then
			const index = op.Index :: number
			if self._proxyManager then
				const array = self:Get(op.Path, true)
				if type(array) == "table" then
					self._proxyManager:ShiftKeys(array, index + 1, -1)
				end
			end
			pruneDetachedValue(self, op.OldValue, nil)
			makeEmit(self, op.Path).removed(index, op.OldValue)
		elseif op.Kind == "ArraySet" then
			makeEmit(self, op.Path).set(op.Index :: number, op.NewValue, op.OldValue)
		end
	end)
	self._suppressLinkFanOut = false

	if not ok then
		error(err, 0)
	end
end

--[=[
	@within TableManager

	Returns a plain `TableManager` rooted at the shared table found at `target`,
	linked (via `Link`) to this manager so writes on either side fan out to the
	other. `target` may be:
	- a proxy obtained from this manager (preferred);
	- a raw table value that is already part of this manager's tree; or
	- a path (string or array) into this manager's tree.

	Requires proxies (`Config.EnableProxies` must not be `false`).
]=]
function TableManager.Extend<T, S>(
	self: TM_Internal<T>,
	target: Proxy<T, S> | Path<S>,
	config: ExtendConfig?
): TableManager<ValueAtPath<T, S>>
	const proxyManager = self._proxyManager
	if proxyManager == nil then
		error("Extend requires proxies (Config.EnableProxies = false for this TableManager)")
	end

	local anchorPath: PathArray<any>
	if proxyManager:IsProxy(target) then
		-- Preferred form: a proxy already names its live path.
		const path = proxyManager:GetPath(target :: any)
		if path == nil then
			error("Extend target proxy is not part of this manager's tree")
		end
		anchorPath = path
	else
		-- Raw value already in the tree: locate it by identity (it may not have
		-- a proxy yet if it was never accessed via Get/GetProxy). Falls back to
		-- treating `target` as a path (string or array) if not found.
		const foundPath = if type(target) == "table" then LinkGroupModule.FindPathOf(self._originalData, target) else nil
		if foundPath ~= nil then
			anchorPath = foundPath
		else
			anchorPath = PathHelpers.ParsePath(target :: any)
		end
	end

	const object = self:Get(anchorPath, true)
	if type(object) ~= "table" then
		error("Extend target must resolve to a table")
	end

	const extended = TableManager.new(object :: any)

	const group = LinkGroupModule.Link({ { self :: any, anchorPath }, { extended :: any } })

	if config and config.OnDetached then
		const onDetached = config.OnDetached
		-- Fires when EITHER `extended` itself leaves the group, or the group
		-- dissolves (the common 2-member case, where the other side diverging
		-- also orphans `extended`). Guarded so a single divergence that
		-- triggers both signals only runs the callback once.
		local fired = false
		const fireOnce = function()
			if fired then
				return
			end
			fired = true
			onDetached()
		end
		group.MemberRemoved:Connect(function(manager)
			if manager == (extended :: any) then
				fireOnce()
			end
		end)
		group.Dissolved:Connect(fireOnce)
	end

	return extended :: any
end

--------------------------------------------------------------------------------
--// Listener Registration //--
--------------------------------------------------------------------------------

--[=[
	Fires ONLY when this exact path is directly reassigned (not when a
	descendant of it changes). Shorthand for `OnChange` with
	`ListenDepth = 0, ListenDepthStyle = "=="`.
]=]
function TableManager.OnValueChange<T, S>(
	self: TM_Internal<T>,
	path: Path<S>,
	callback: (newValue: any, oldValue: any?, metadata: ChangeMetadata) -> (),
	options: ListenerOptions?
): Connection
	const mergedOptions: ListenerOptions = if options then table.clone(options :: any) else {}
	mergedOptions.ListenDepth = 0
	mergedOptions.ListenDepthStyle = "=="
	return self._listenerRegistry:RegisterListener("ValueChanged", PathHelpers.ParsePath(path), callback, mergedOptions)
end

--[=[
	Fires when this path is directly reassigned OR any descendant of it
	changes.
]=]
function TableManager.OnChange<T, S>(
	self: TM_Internal<T>,
	path: Path<S>,
	callback: (newValue: any, oldValue: any?, metadata: ChangeMetadata) -> (),
	options: ListenerOptions?
): Connection
	return self._listenerRegistry:RegisterListener("ValueChanged", PathHelpers.ParsePath(path), callback, options)
end

--[=[
	Immediately invokes `callback` with the current value at `path`
	(`oldValue` and `metadata` both `nil`), then behaves like
	`OnValueChange` for subsequent changes.
]=]
function TableManager.Observe<T, S>(
	self: TM_Internal<T>,
	path: Path<S>,
	callback: (newValue: any, oldValue: any?, metadata: ChangeMetadata?) -> (),
	options: ListenerOptions?
): Connection
	const parsedPath = PathHelpers.ParsePath(path)
	const currentValue = self:Get(parsedPath, true)

	const function fireInitial()
		callback(currentValue, nil, nil)
	end

	if self._listenerRegistry._fireDeferred then
		task.defer(fireInitial)
	else
		task.spawn(fireInitial)
	end

	return self._listenerRegistry:RegisterListener("ValueChanged", parsedPath, callback, options)
end

function TableManager.OnKeyAdd<T, S>(
	self: TM_Internal<T>,
	path: Path<S>,
	callback: (newValue: any, metadata: ChangeMetadata) -> (),
	options: ListenerOptions?
): Connection
	return self._listenerRegistry:RegisterListener("KeyAdded", PathHelpers.ParsePath(path), callback, options)
end

function TableManager.OnKeyRemove<T, S>(
	self: TM_Internal<T>,
	path: Path<S>,
	callback: (oldValue: any, metadata: ChangeMetadata) -> (),
	options: ListenerOptions?
): Connection
	return self._listenerRegistry:RegisterListener("KeyRemoved", PathHelpers.ParsePath(path), callback, options)
end

function TableManager.OnKeyChange<T, S>(
	self: TM_Internal<T>,
	path: Path<S>,
	callback: (key: any, newValue: any, oldValue: any, metadata: ChangeMetadata) -> (),
	options: ListenerOptions?
): Connection
	return self._listenerRegistry:RegisterListener("KeyChanged", PathHelpers.ParsePath(path), callback, options)
end

function TableManager.OnArrayInsert<T, S>(
	self: TM_Internal<T>,
	path: Path<S>,
	callback: (index: number, newValue: any, metadata: ChangeMetadata) -> (),
	options: ListenerOptions?
): Connection
	return self._listenerRegistry:RegisterListener("ArrayInserted", PathHelpers.ParsePath(path), callback, options)
end

function TableManager.OnArrayRemove<T, S>(
	self: TM_Internal<T>,
	path: Path<S>,
	callback: (index: number, oldValue: any, metadata: ChangeMetadata) -> (),
	options: ListenerOptions?
): Connection
	return self._listenerRegistry:RegisterListener("ArrayRemoved", PathHelpers.ParsePath(path), callback, options)
end

function TableManager.OnArraySet<T, S>(
	self: TM_Internal<T>,
	path: Path<S>,
	callback: (
		index: number,
		newValue: any,
		oldValue: any,
		metadata: ChangeMetadata
	) -> (),
	options: ListenerOptions?
): Connection
	return self._listenerRegistry:RegisterListener("ArraySet", PathHelpers.ParsePath(path), callback, options)
end

--------------------------------------------------------------------------------
--// Helper Methods //--
--------------------------------------------------------------------------------

--[=[
	Get the value at a path.
]=]
function TableManager.Get<T, S>(self: TM_Internal<T>, path: Path<S>, suppressNilPartialPaths: boolean?): ValueAtPath<T, S>?
	const parsedPath = PathHelpers.ParsePath(path)
	local current = self._originalData :: T & table
	for _, key in parsedPath do
		if type(current) ~= "table" then
			if suppressNilPartialPaths then
				return nil
			else
				error(`Path segment {key} is not a table`)
			end
		end
		current = current[key]
	end
	return current
end

--[=[
	Gets a Proxy for the table at the given path, or the raw value if the path
	doesn't point to a table.
]=]
function TableManager.GetProxy<T, S>(
	self: TM_Internal<T>,
	path: Path<S>,
	suppressNilPartialPaths: boolean?
): (Proxy<T, S> | ValueAtPath<T, S>)?
	const proxyManager = self._proxyManager
	if proxyManager == nil then
		error("GetProxy requires proxies (Config.EnableProxies = false for this TableManager)")
	end
	const parsedPath = PathHelpers.ParsePath(path)
	local current = self.Proxy
	local previousKey: any = nil
	for _, key in parsedPath do
		if not proxyManager:IsProxy(current) then
			if suppressNilPartialPaths then
				return nil
			else
				error(`Path segment {tostring(previousKey)} is not a table`)
			end
		end
		current = current[key]
		previousKey = key
	end
	return current
end

--[=[
	Set the value at a path.
]=]
function TableManager.Set<T, S>(
	self: TM_Internal<T>,
	path: Path<S>,
	value: ValueAtPath<T, S>,
	buildTablesDynamically: boolean?
)
	const parsedPath = PathHelpers.ParsePath(path)
	if #parsedPath == 0 then
		error("Cannot set root path")
	end

	const unwrappedValue = ProxyManagerModule.Unwrap(value)

	-- Only build intermediate tables when setting non-nil values; removing (nil) doesn't need them
	const shouldBuild = buildTablesDynamically and unwrappedValue ~= nil

	local parent: any = self._originalData
	for i = 1, #parsedPath - 1 do
		const nextValue = parent[parsedPath[i]]
		if type(nextValue) ~= "table" then
			if not shouldBuild then
				if unwrappedValue == nil then
					-- Removing from a path that doesn't exist (a segment is missing
					-- or holds a non-table); silently succeed (nothing to remove).
					-- Keeps replication consumers safe when a redundant child
					-- removal arrives after its parent was replaced by a scalar.
					return
				end
				error(`Path segment {parsedPath[i]} is not a table`)
			end
			-- Build the remaining segments as ONE plain subtree with the value at
			-- the leaf, then apply it as a single write so the whole creation is
			-- captured by one change-detection pass. Writing level-by-level would
			-- otherwise produce one diff per intermediate table.
			const subtree: { [any]: any } = {}
			local cursor = subtree
			for j = i + 1, #parsedPath - 1 do
				const nested: { [any]: any } = {}
				cursor[parsedPath[j]] = nested
				cursor = nested
			end
			cursor[parsedPath[#parsedPath]] = unwrappedValue

			const subtreePath: PathArray = table.create(i)
			for j = 1, i do
				subtreePath[j] = parsedPath[j]
			end
			applyWrite(self, subtreePath, subtree)
			return
		end
		parent = nextValue
	end

	applyWrite(self, parsedPath, unwrappedValue)
end

--[=[
	Insert value(s) into an array at a specific position or at the end.
]=]
function TableManager.ArrayInsert<T, S>(self: TM_Internal<T>, pathOrProxy: Path<S> | Proxy<T, S>, ...: any): ()
	local parsedPath, array = resolveArrayForWrite(self, pathOrProxy)

	-- Determine if a position was provided or default to appending.
	local pos: number
	local newValue: any
	if select("#", ...) >= 2 then
		local secondArg
		pos, secondArg = ...
		newValue = secondArg
	else
		pos = #array + 1
		newValue = ...
	end

	const unwrappedValue = ProxyManagerModule.Unwrap(newValue)

	-- Validate against the schema's element check for this array, if configured.
	if self._schema then
		const arrayCheck = SchemaNavigatorModule.Navigate(self._schema, parsedPath)
		if arrayCheck then
			const arrayMeta = T.GetMeta(arrayCheck)
			if arrayMeta and arrayMeta.kind == "array" then
				const ok, err = arrayMeta.valueCheck(unwrappedValue)
				if not ok then
					const message = err or `Schema validation failed at {PathHelpers.PathToString(parsedPath)}`
					if self._onValidationFailed then
						self._onValidationFailed(parsedPath, unwrappedValue, message)
						return
					end
					error(message, 2)
				end
			end
		end
	end

	-- Batch: track this array path so the flush can diff against the pre-batch snapshot.
	if self._batchDepth > 0 and self._batch then
		const batch = self._batch
		ensureBatchPathTracking(batch, parsedPath)
		markBatchBranchDirty(batch, parsedPath)
	end

	-- Insert the value (handles shifting when inserting into the middle).
	table.insert(array, pos, unwrappedValue)
	-- Update Key metadata for all proxies that were shifted right by this insert.
	if self._proxyManager then
		self._proxyManager:ShiftKeys(array, pos, 1)
	end
	-- Direct auto-link for an inserted managed table.
	if self._autoLink and not self._suppressLinkFanOut then
		const elementPath = PathHelpers.Append(parsedPath, pos)
		LinkGroupModule.CheckAutoLink(self :: any, elementPath, unwrappedValue)
	end

	-- Batch: skip fires
	if self._batchDepth > 0 then
		return
	end

	-- Fire element-level and array-level listeners, ancestor callbacks, and signal.
	makeEmit(self, parsedPath).inserted(pos, unwrappedValue)
end
TableManager.Insert = TableManager.ArrayInsert

--[=[
	Remove an element from an array at a specific index.
]=]
function TableManager.ArrayRemove<T, S>(self: TM_Internal<T>, pathOrProxy: Path<S> | Proxy<T, S>, index: number): any
	local parsedPath, array = resolveArrayForWrite(self, pathOrProxy)

	-- Batch: track this array path so the flush can diff against the pre-batch snapshot.
	if self._batchDepth > 0 and self._batch then
		const batch = self._batch
		ensureBatchPathTracking(batch, parsedPath)
		markBatchBranchDirty(batch, parsedPath)
	end

	-- Remove the element (handles shifting automatically).
	const oldValue = table.remove(array, index)
	-- Shift proxies after the removed slot left by 1. Pass index+1 as fromIndex
	-- so the removed item's own proxy (if held) keeps its original key rather than
	-- being shifted to key=0.
	if self._proxyManager then
		self._proxyManager:ShiftKeys(array, index + 1, -1)
	end
	pruneDetachedValue(self, oldValue, nil)
	if not self._suppressLinkFanOut then
		LinkGroupModule.CheckDivergence(self, parsedPath)
	end

	-- Batch: skip fires
	if self._batchDepth > 0 then
		return oldValue
	end

	-- Fire listeners EXACTLY at remove path (we handle ancestors separately)
	makeEmit(self, parsedPath).removed(index, oldValue)

	return oldValue
end
TableManager.Remove = TableManager.ArrayRemove

--[=[
	Remove the first matching value from an array.
	Returns the index it was removed from, or nil if not found.
]=]
function TableManager.ArrayRemoveFirstValue<T, S>(self: TM_Internal<T>, pathOrProxy: Path<S>, valueToFind: any): number?
	local parsedPath, array = resolveArrayForWrite(self, pathOrProxy)

	const index = table.find(array, valueToFind)
	if index == nil then
		return nil
	end

	self:ArrayRemove(parsedPath, index)
	return index
end
TableManager.RemoveFirstValue = TableManager.ArrayRemoveFirstValue

--[=[
	Remove an array element in O(1) by swapping in the last element.
	Order is not preserved.
]=]
function TableManager.ArraySwapRemove<T, S>(self: TM_Internal<T>, pathOrProxy: Path<S> | Proxy<T, S>, index: number): any
	local parsedPath, array = resolveArrayForWrite(self, pathOrProxy)

	const lastIndex = #array
	if index < 1 or index > lastIndex then
		return nil
	end

	const oldValue = array[index]
	const movedValue = array[lastIndex]

	-- Batch: track this array path so the flush can diff against the pre-batch snapshot.
	if self._batchDepth > 0 and self._batch then
		const batch = self._batch
		ensureBatchPathTracking(batch, parsedPath)
		markBatchBranchDirty(batch, parsedPath)
	end

	if index ~= lastIndex then
		array[index] = movedValue
	end
	array[lastIndex] = nil
	pruneDetachedValue(self, oldValue, nil)
	if not self._suppressLinkFanOut then
		LinkGroupModule.CheckDivergence(self, parsedPath)
	end

	-- Batch: skip immediate fires
	if self._batchDepth > 0 then
		return oldValue
	end

	const moveInfo = if index ~= lastIndex
		then { moveId = `swapremove_{index}_{lastIndex}`, fromIndex = lastIndex, toIndex = index }
		else nil

	const emit = makeEmit(self, parsedPath)

	-- 1. Emit ArraySet for the backfill: array[index] = movedValue (no-op if index == lastIndex)
	if index ~= lastIndex then
		emit.set(index, movedValue, oldValue, moveInfo)
	end

	-- 2. Emit ArrayRemoved for the shrink: array[lastIndex] = nil (the actual removal)
	emit.removed(lastIndex, movedValue, moveInfo)

	return oldValue
end
TableManager.SwapRemove = TableManager.ArraySwapRemove

--[=[
	Find and swap-remove the first matching value in an array.
	Returns the removed index, or nil if not found.
]=]
function TableManager.ArraySwapRemoveFirstValue<T, S>(
	self: TM_Internal<T>,
	pathOrProxy: Path<S> | Proxy<T, S>,
	valueToFind: any
): number?
	local parsedPath, array = resolveArrayForWrite(self, pathOrProxy)

	const index = table.find(array, valueToFind)
	if index == nil then
		return nil
	end

	self:ArraySwapRemove(parsedPath, index)
	return index
end
TableManager.SwapRemoveFirstValue = TableManager.ArraySwapRemoveFirstValue

--[=[
	Holds off firing signals for the duration of the callback, then fires needed signals at the end.
	Useful for batch operations where you want to suppress intermediate signals and only fire final results.

	Nested calls are no-ops: the outermost Batch window covers everything.

	:::caution yielding
	Yielding within a batch window will leave the TableManager in a suspended state, which
	can cause unexpected behavior.
	:::
]=]
function TableManager.Batch(self: TM_Internal, fn: () -> ())
	if self._batchDepth > 0 then
		-- Already inside a batch window; run the callback in-place
		fn()
		return
	end
	self:Suspend()
	const ok, err = (pcall :: any)(fn)
	self:Resume()
	if not ok then
		error(err, 2)
	end
end

--[=[
	Suspends all signal and listener firing.

	It is recommended to use `:Batch` for better ergonomics and safety,
	but `Suspend`/`Resume` can be used for more manual control if needed.

	Pair with `Resume()`. Nested calls are no-ops (the outermost window wins).
]=]
function TableManager.Suspend(self: TM_Internal)
	BatchFlushModule.Suspend(self :: any)
end

--[=[
	Resumes after `Suspend()` and flushes all pending changes.

	Flush is two-phase:
	1. **Non-array flush** — per dirty branch, `CheckForChangesBetween` diffs the
	   pre-batch value against the current value (with tracked-array subtrees
	   masked out — the array flush owns those), firing all non-array events.
	2. **Array flush** — For each tracked array path, diffs the pre-batch
	   snapshot against the current value via LCS (`ArrayDiff.emitDiff`).
]=]
function TableManager.Resume(self: TM_Internal)
	BatchFlushModule.Resume(self :: any)
end

--[=[
	Move an element from one location to another within the same table.
	This unsets the value at the current path and sets it at the new path, firing appropriate notifications.
	This is specifically useful for moving tables around without breaking proxy references.
]=]
function TableManager.MoveTo<T, S1, S2>(
	self: TM_Internal<T>,
	currentPath: Path<S1> | Proxy<T, S1>,
	newPath: Path<S2> | Proxy<T, S2>
)
	const sourcePath: PathArray<S1> = resolvePathFromPathOrProxy(self, currentPath)
	const targetPath: PathArray<S2> = resolvePathFromPathOrProxy(self, newPath)

	if #sourcePath == 0 or #targetPath == 0 then
		error("MoveTo cannot move the root table")
	end

	if PathHelpers.ArePathsEqual(sourcePath, targetPath) then
		return
	end

	if PathHelpers.IsPrefixPath(sourcePath, targetPath) then
		error("MoveTo cannot move a table into one of its descendants")
	end

	const sourceValue = self:Get(sourcePath :: Path<S1>)
	if type(sourceValue) ~= "table" then
		error("MoveTo source must be a table")
	end

	const targetParentPath, targetKey = PathHelpers.GetPathParentAndKey(targetPath)
	const targetParentOriginal = getParentOriginalAtPath(self, targetParentPath, "MoveTo")

	const existingProxy = if self._proxyManager then self._proxyManager:GetProxyFromOriginal(sourceValue) else nil
	const rollback = reparentWithRollback(self, existingProxy, targetParentOriginal, targetKey)

	const ok, moveErr = pcall(function()
		self:Batch(function()
			self:Set(targetPath, sourceValue)
			self:Set(sourcePath, nil :: any)
		end)
	end)

	if not ok then
		restoreReparent(self, rollback)
		error(moveErr, 2)
	end
end

--[=[
	DeepCopy a value from one location to another within the same table.
	This sets the value at the new path to be the same as the value at the current path, firing appropriate notifications.
	This is specifically useful for copying tables around without breaking proxy references.
]=]
function TableManager.CopyTo<T, S1, S2>(self: TM_Internal<T>, currentPath: Path<S1> | Proxy<T, S1>, newPath: Path<S2>)
	const sourcePath = resolvePathFromPathOrProxy(self, currentPath)
	const targetPath = resolvePathFromPathOrProxy(self, newPath)

	if #targetPath == 0 then
		error("CopyTo cannot set the root table")
	end

	if PathHelpers.ArePathsEqual(sourcePath, targetPath) then
		return
	end

	-- Validate destination parent before any mutation.
	const targetParentPath: { any } = table.clone(targetPath :: any)
	table.remove(targetParentPath)
	getParentOriginalAtPath(self, targetParentPath, "CopyTo")

	const sourceValue = self:Get(sourcePath)
	const copiedValue = deepCloneValue(sourceValue)
	self:Set(targetPath, copiedValue)
end

--[=[
	Swap values at two paths within the same TM.
]=]
function TableManager.Swap<T, S1, S2>(self: TM_Internal<T>, a: Path<S1> | Proxy<T, S1>, b: Path<S2> | Proxy<T, S2>)
	const pathA = resolvePathFromPathOrProxy(self, a)
	const pathB = resolvePathFromPathOrProxy(self, b)

	if #pathA == 0 or #pathB == 0 then
		error("Swap cannot target the root table")
	end

	if PathHelpers.ArePathsEqual(pathA, pathB) then
		return
	end

	if PathHelpers.IsPrefixPath(pathA, pathB) or PathHelpers.IsPrefixPath(pathB, pathA) then
		error("Swap cannot swap ancestor/descendant paths")
	end

	const parentPathA, keyA = PathHelpers.GetPathParentAndKey(pathA)
	const parentPathB, keyB = PathHelpers.GetPathParentAndKey(pathB)
	const parentOriginalA = getParentOriginalAtPath(self, parentPathA, "Swap")
	const parentOriginalB = getParentOriginalAtPath(self, parentPathB, "Swap")

	const valueA = self:Get(pathA)
	const valueB = self:Get(pathB)

	const proxyManager = self._proxyManager
	const proxyA = if proxyManager and type(valueA) == "table" then proxyManager:GetProxyFromOriginal(valueA) else nil
	const proxyB = if proxyManager and type(valueB) == "table" then proxyManager:GetProxyFromOriginal(valueB) else nil
	const rollbackA = reparentWithRollback(self, proxyA, parentOriginalB, keyB)
	const rollbackB = reparentWithRollback(self, proxyB, parentOriginalA, keyA)

	const ok, swapErr = pcall(function()
		self:Batch(function()
			self:Set(pathA, valueB)
			self:Set(pathB, valueA)
		end)
	end)

	if not ok then
		restoreReparent(self, rollbackA)
		restoreReparent(self, rollbackB)
		error(swapErr, 2)
	end
end

--------------------------------------------------------------------------------
--// Other Utility Methods //--
--------------------------------------------------------------------------------

--[=[
	@private
	@unreleased
	Force notification for a specific path, even if the value hasn't changed.

	This is useful for scenarios like:
	- Re-assigning the same table (e.g., `Data.Stats = sameStats`)
	- Forcing validation/refresh logic to run
	- Implementing "force refresh" patterns

	Example:
	```lua
	local sameStats = manager.Proxy.players.John.Stats
	manager.Proxy.players.John.Stats = sameStats  -- Normally no listeners fire
	manager:ForceNotify({"players", "John", "Stats"})  -- Force listeners to fire
	```

	Note: This creates a synthetic "changed" diff where old == new.
	Your listeners can detect this by checking if `metadata.Diff.old == metadata.Diff.new`.
]=]
function TableManager.ForceNotify<T, S>(self: TM_Internal<T>, path: Path<S>)
	if self._batchDepth > 0 then
		return -- Suppress during batch; flush will re-emit all changes
	end
	const parsedPath = PathHelpers.ParsePath(path)
	const currentValue = self:Get(parsedPath)

	-- Create synthetic metadata for a "changed" event where old == new
	const metadata: ChangeMetadata = {
		Diff = {
			type = "changed",
			old = currentValue,
			new = currentValue,
			children = nil,
		},
		OriginPath = parsedPath,
		OriginDiff = {
			type = "changed",
			old = currentValue,
			new = currentValue,
			children = nil,
		},
		Snapshot = createSyntheticSnapshot(self._originalData, parsedPath, currentValue),
	}

	-- Fire ValueChanged at exact path
	self._listenerRegistry:FireListenersExact("ValueChanged", parsedPath, {
		NewValue = currentValue,
		OldValue = currentValue,
		Metadata = metadata,
	})

	-- Fire signal
	self.ValueChanged:Fire(parsedPath, currentValue, currentValue)

	-- Fire ancestor ValueChanged callbacks from parent path up to root.
	if #parsedPath > 0 then
		const parentPath = (PathHelpers.GetPathParentAndKey(parsedPath))
		fireAncestorValueChangedNotifications(self, parentPath, metadata, false)
	end
end

--[=[
	Destroy the TableManager and clean up all resources.
]=]
function TableManager.Destroy<T>(self: TM_Internal<T>)
	if self._Destroyed then
		return
	end
	self._Destroyed = true

	self.Linker:Unlink()
	LinkGroupModule.UnregisterAutoLink(self)

	-- If destroyed mid-batch (Suspend without Resume), release the batch state.
	const batch = self._batch
	if batch then
		self._batch = nil
		self._batchDepth = 0
	end

	self._listenerRegistry:Destroy()
	if self._proxyManager then
		self._proxyManager:Destroy()
	end

	-- Disconnect all signals
	self.ValueChanged:Destroy()
	self.KeyAdded:Destroy()
	self.KeyRemoved:Destroy()
	self.KeyChanged:Destroy()
	self.ArrayInserted:Destroy()
	self.ArrayRemoved:Destroy()
	self.ArraySet:Destroy()
end

return TableManager
