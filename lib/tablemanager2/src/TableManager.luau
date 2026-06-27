--!strict
--[=[
	@class TableManager

	TableManager is a wrapper around luau tables that provide easy and automatic 
	change tracking, validation, and listener management. TableManager is designed
	to handle the bulk of your volatile data management needs, emitting detailed change 
	events and snapshots for any changes made to the managed table or its descendants — all 
	without needing to manually fire events or manage listener connections.

	### What is TableManager good for?
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

	
	### Usage
	
	```lua
	const manager = TableManager.new({
		player = { health = 100, level = 5 },
		settings = { volume = 80 }
	})
	
	-- Listen to direct changes only
	manager:OnChange("player", function(newValue, oldValue, metadata)

	end)
	
	-- Listen to all changes (including descendants)
	manager:OnValueChange("player", function(newValue, oldValue, metadata)

	end)
	
	-- Array operations with ancestor notifications
	manager:ArrayInsert("player.items", "Sword")
	```

	## Best Practices
	- Avoid keeping large datastructures within arrays contained within a tablemanager. It is best 
	to manage the array separately and have a TableManager for each object.

	- Avoid mixed tables.

	- Utilize pure string keys so the linter can try to infer your types.
]=]

--// Imports //--
const T = require("../T")
const Signal = require("../Signal")
const Janitor = require("../Janitor")
const PathHelpers = require("./PathHelpers")
const BatchUtilsModule = require("./Batching/BatchUtils")
const BatchFlushModule = require("./Batching/BatchFlush")
const ProxyManagerModule = require("./ProxyManager")
const ListenerRegistryModule = require("./Listening/ListenerRegistry")
const ChangeDetectorModule = require("./Diffing/ChangeDetector")
const SchemaNavigatorModule = require("./SchemaNavigator")
const PropagationModule = require("./Propagation")
const Types = require("./TMTypes")
const EmitterModule = require("./Listening/Emitter")
const MutatorModule = require("./Mutator")
const OpaqueRegistryModule = require("./OpaqueRegistry")
const IgnoreTrieModule = require("./IgnoreTrie")
const CoverageModule = require("./Diffing/Coverage")
const ForMapModule = require("./ForMap")
const CoalescedFlushModule = require("./Batching/CoalescedFlush")
const BaselineModule = require("./Baseline/Baseline")

--// Types //--
type Path<S> = PathHelpers.Path<S>
type PathArray<S = string> = PathHelpers.PathArray<S>
type ValueAtPath<T, S> = PathHelpers.ValueAtPath<T, S>
type KeyAtPath<T, S> = PathHelpers.KeyAtPath<T, S>
type ElementAtPath<T, S> = PathHelpers.ElementAtPath<T, S>
type ListenerRegistry = ListenerRegistryModule.ListenerRegistry
type ChangeDetector = ChangeDetectorModule.ChangeDetector
type ChangeMetadata = ChangeDetectorModule.ChangeMetadata
type ListenerOptions = ListenerRegistryModule.ListenerOptions
type Connection = ListenerRegistryModule.Connection
type Signal<Fn, Args...> = Signal.Signal<Fn, Args...>
type Janitor = Janitor.Janitor
type SchemaCheck = SchemaNavigatorModule.Check
type BatchState = BatchUtilsModule.BatchState
type table = { [any]: any }

export type Proxy<T, S> = Types.Proxy<T, S>

export type AppliedOp = Types.AppliedOp

export type DuplicateReferenceMode = Types.DuplicateReferenceMode
export type TableManagerConfig = Types.TableManagerConfig
export type ForOptions = Types.ForOptions
export type TableManager<T = { [any]: any }> = Types.TableManager<T>

export type OpaqueWrapper<T> = Types.OpaqueWrapper<T>

export type TM_Internal<T = { [any]: any }> = Types.TM_Internal<T>
type ProxyManager<T> = ProxyManagerModule.ProxyManager<T>

--// Constants //--
const DEFAULT_DUPLICATE_REFERENCE_MODE: DuplicateReferenceMode = "allow"
const DEFAULT_SIGNAL_FIRE_MODE: Types.SignalFireMode = "bindable"
const DEFAULT_LISTENER_FIRE_MODE: ListenerRegistryModule.FireMode = "bindable"
const DEFAULT_FLUSH_MODE: Types.FlushMode = "immediate"

--------------------------------------------------------------------------------
--// Module //--
--------------------------------------------------------------------------------

const TableManager = {}
const TableManager_MT = { __index = TableManager }

TableManager.T = T

-- Write-core helpers live in Mutator.luau; local aliases keep call sites unchanged.
const resolvePathFromPathOrProxy = MutatorModule.resolvePathFromPathOrProxy
const resolveArrayForWrite = MutatorModule.resolveArrayForWrite
const getParentOriginalAtPath = MutatorModule.getParentOriginalAtPath
const applyWrite = MutatorModule.applyWrite
const applyRootSet = MutatorModule.applyRootSet
const pruneDetachedValue = MutatorModule.pruneDetachedValue
const shiftArrayKeys = MutatorModule.shiftArrayKeys
const reparentWithRollback = MutatorModule.reparentWithRollback
const restoreReparent = MutatorModule.restoreReparent
const deepCloneValue = MutatorModule.deepCloneValue
const trackArrayMutation = MutatorModule.trackArrayMutation

-- Emit/notify core lives in Emitter.luau; local aliases keep call sites unchanged.
const fireAncestorValueChangedNotifications = EmitterModule.fireAncestorValueChangedNotifications
const emitInserted = EmitterModule.emitInserted
const emitRemoved = EmitterModule.emitRemoved
const emitSet = EmitterModule.emitSet

-- Shared For/Map reconcile drivers live in ForMap.luau; local aliases keep call sites unchanged.
const makeKeyedReconciler = ForMapModule.makeKeyedReconciler
const makeValueReconciler = ForMapModule.makeValueReconciler

const createAncestorSnapshot = BatchUtilsModule.CreateAncestorSnapshot

-----------------------------------------------------------------------------------
--// Constructor //--
-----------------------------------------------------------------------------------

const function validateInitialSchema<T>(self: TM_Internal<T>)
	if self._schema then
		const ok, err = SchemaNavigatorModule.Validate(self._schema, {}, self.Raw)
		if not ok then
			const message = err or "Schema validation failed at <root>"
			if self._onValidationFailed then
				self._onValidationFailed({}, self.Raw, message)
			end
			error(message, 2)
		end
	end
end

const function normalizeSignalFireMode(mode: Types.SignalFireMode?): Types.SignalFireMode
	return if mode == nil then DEFAULT_SIGNAL_FIRE_MODE else (mode :: any):lower() :: Types.SignalFireMode
end

const function initProxyManager<T>(self: TM_Internal<T>, resolvedConfig: TableManagerConfig): ProxyManager<T>?
	const enableProxies = resolvedConfig.EnableProxies ~= false
	if not enableProxies and resolvedConfig.DuplicateReferenceMode ~= nil then
		warn("DuplicateReferenceMode has no effect when Config.EnableProxies = false")
	end
	return if enableProxies then ProxyManagerModule.new(self.Raw) else nil
end

const function wireProxyWriteHandler<T>(self: TM_Internal<T>): Proxy<T, "">?
	const proxyManager = self._proxyManager
	if not proxyManager then return end
	proxyManager:SetWriteHandler(function(path: PathArray, value: any)
		applyWrite(self, path, value)
	end)
	return proxyManager:CreateProxy(self.Raw, nil, nil)
end

--[=[
	@within TableManager
	@function new

	Creates a new TableManager instance.

	@param initialData table -- The initial table data to manage. Must be a table.
	@param config TableManagerConfig? -- Optional configuration for the TableManager.
	@return TableManager -- The newly created TableManager instance.
]=]
function TableManager.new<T>(initialData: T, config: TableManagerConfig?): TableManager<T>
	debug.profilebegin("TM.new")
	const self: TM_Internal<T> = (setmetatable({}, TableManager_MT) :: any) :: TM_Internal<T>
	const resolvedConfig: TableManagerConfig = config or {} :: { [string]: any? }
	const duplicateReferenceMode: DuplicateReferenceMode = resolvedConfig.DuplicateReferenceMode or DEFAULT_DUPLICATE_REFERENCE_MODE
	
	assert(type(initialData) == "table", "Initial data must be a table")
	-- Store original data
	self.Raw = initialData
	self._schema = resolvedConfig.Schema
	self._onValidationFailed = resolvedConfig.OnValidationFailed
	self._duplicateReferenceMode = duplicateReferenceMode
	
	-- Validate initial data against the root schema at construction time.
	validateInitialSchema(self)
	
	-- Batch state (reset at start of each Suspend/Resume cycle)
	self._batchDepth = 0
	self._batch = nil
	

	self._janitor = Janitor.new()
	
	self._opaqueRegistries = OpaqueRegistryModule.NewRegistries(resolvedConfig.FrozenTablesAreOpaque)
	self._ignoreTrie = IgnoreTrieModule.new()
	for _, ignoredPath in resolvedConfig.IgnoredPaths or {} do
		IgnoreTrieModule.SetPathIgnored(self._ignoreTrie, ignoredPath, true)
	end
	
	-- Initialize subsystems
	self._proxyManager = initProxyManager(self, resolvedConfig)
	self._listenerRegistry = ListenerRegistryModule.new {
		DebugMode = false,
		FireMode = resolvedConfig.ListenerFireMode or DEFAULT_LISTENER_FIRE_MODE,
	}
	self._signalFireMode = normalizeSignalFireMode(resolvedConfig.SignalFireMode)
	self._flushMode = resolvedConfig.FlushMode or DEFAULT_FLUSH_MODE
	self._pendingFlushRoot = nil
	self._coalescedFlushScheduled = false
	self.Proxy = wireProxyWriteHandler(self)
	
	-- Initialize signals (fire once per change)
	self.ValueChanged = Signal.new() :: any
	self.KeyAdded = Signal.new() :: any
	self.KeyRemoved = Signal.new() :: any
	self.KeyChanged = Signal.new() :: any
	self.ArrayInserted = Signal.new() :: any
	self.ArrayRemoved = Signal.new() :: any
	self.ArraySet = Signal.new() :: any
	
	self._changeDetector = ChangeDetectorModule.new(
		EmitterModule.makeChangeDetectorCallbacks(self :: any) :: any,
		nil,
		self._opaqueRegistries,
		self._ignoreTrie
	)

	PropagationModule.RegisterSubtree(self, self.Raw)

	debug.profileend()
	return self :: any
end

--------------------------------------------------------------------------------
--// Linking //--
--------------------------------------------------------------------------------

--[=[
	@private
	Re-fires listeners/signals for an op that has ALREADY been applied to the
	shared raw (by another manager observing the same table identity), without
	mutating or snapshot-diffing. `op.Path` is in this manager's own coordinates.
	Used only by cross-manager fan-out (see `Propagation`).
]=]
function TableManager._NotifyApplied<T>(self: TM_Internal<T>, op: AppliedOp)
	if self._Destroyed then
		return
	end

	self._suppressLinkFanOut = true
	const ok, err = pcall(function()
		if op.Kind == "Set" then
			pruneDetachedValue(self, op.OldValue, op.NewValue)

			if CoverageModule.IsLocallyObserved(self, op.Path) then
				const oldSnapshot = BatchUtilsModule.BuildOldSnapshot(self, op.Path, op.OldValue)
				if op.Diff ~= nil and op.OriginHasNoOpacity and self._opaqueRegistries.Count == 0 then
					self._changeDetector:DispatchDiffNode(op.Diff, op.Path, self.Raw, oldSnapshot)
				else
					self._changeDetector:CheckForChangesBetween(
						op.OldValue,
						op.NewValue,
						op.Path,
						self.Raw,
						nil,
						oldSnapshot
					)
				end
			end
			-- This bypasses applyWrite entirely (the write already landed via the
			-- ORIGIN manager), so the baseline needs its own sync here —
			-- applyWrite's seed/_doFlush never run for this path. The trackable /
			-- opaque-ancestor gate (Materialize can't safely persist through an
			-- opaque ancestor) lives in `Baseline.Materialize`; the dispatch above
			-- already fired correctly using op.OldValue/op.NewValue directly.
			BaselineModule.Materialize(self, op.Path)
		elseif op.Kind == "ArrayInsert" then
			const index = op.Index :: number
			shiftArrayKeys(self._proxyManager, self:Get(op.Path, true), index, 1)
			emitInserted(self, op.Path, index, op.NewValue)
		elseif op.Kind == "ArrayRemove" then
			const index = op.Index :: number
			shiftArrayKeys(self._proxyManager, self:Get(op.Path, true), index + 1, -1)
			pruneDetachedValue(self, op.OldValue, nil)
			emitRemoved(self, op.Path, index, op.OldValue)
		elseif op.Kind == "ArraySet" then
			emitSet(self, op.Path, op.Index :: number, op.NewValue, op.OldValue)
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

	The new TM is bound to the targeted table, not its path in the extending TM.
]=]
function TableManager.Extend<T, S>(
	self: TM_Internal<T>,
	target: Proxy<T, S> | Path<S>
): TableManager<ValueAtPath<T, S>>
	local anchorPath: PathArray<S>
	if self._proxyManager and self._proxyManager:IsProxy(target) then
		-- Preferred form: a proxy already names its live path.
		const path = self._proxyManager:GetPath(target)
		if path == nil then
			error("Extend target proxy is not part of this manager's tree")
		end
		anchorPath = path
	else
		-- Raw value already in the tree: locate it by identity (it may not have
		-- a proxy yet if it was never accessed via Get/GetProxy). Falls back to
		-- treating `target` as a path (string or array) if not found.
		const foundPath = if type(target) == "table" then PropagationModule.FindPathOf(self.Raw, target) else nil
		if foundPath ~= nil then
			anchorPath = foundPath
		else
			anchorPath = PathHelpers.ParsePath(target)
		end
	end

	const object = self:Get(anchorPath)
	if type(object) ~= "table" then
		error("Extend target must resolve to a table")
	end

	-- The new manager is rooted at the SAME live `object`, so implicit sharing
	-- registers both as observers of that identity (and its subtree) at
	-- construction — writes on either side propagate to the other automatically,
	-- with no explicit link. If `self` later replaces `object`, it stops resolving
	-- to that identity and propagation between them lapses (the extended manager
	-- keeps `object` as its root).
	const extended = TableManager.new(object)

	return extended
end

--[=[
	@within TableManager
	Returns the other managers currently sharing (co-observing) at least one
	live table identity with this one — de-duplicated, excluding self.
]=]
function TableManager.GetLinkedManagers<T>(self: TM_Internal<T>): { TableManager<any> }
	return PropagationModule.GetCoObservers(self)
end

--[=[
	@within TableManager
	Returns true if this manager currently shares a live table identity with `other`.
]=]
function TableManager.IsLinkedWith<T>(self: TM_Internal<T>, other: TableManager<any>): boolean
	return PropagationModule.IsLinkedWith(self, other)
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

	if self._listenerRegistry._fireMode ~= "immediate" then
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
--// For / Map //--
--------------------------------------------------------------------------------

--[=[
	Reconciles the items found at `path` by KEY: `handler` runs once per key
	(passed a per-item Janitor, the key, and change metadata — `nil` on the
	initial fire), and is NOT re-run when the value at an existing key
	changes. The Janitor is destroyed when that key is removed or the
	connection disconnects.
]=]
function TableManager.ForKeys<T, S>(
	self: TM_Internal<T>,
	path: Path<S>,
	handler: (itemJanitor: Janitor, key: KeyAtPath<T, S>, metadata: ChangeMetadata?) -> (),
	options: ForOptions?
): Connection
	const parsedPath = PathHelpers.ParsePath(path)
	return makeKeyedReconciler(self, parsedPath, false, function(itemJanitor, key, _value, metadata)
		handler(itemJanitor, key, metadata)
	end, nil, nil, options, nil)
end

--[=[
	Reconciles the items found at `path` by VALUE (as a multiset — duplicate
	values are tracked as independent items): `handler` runs once per value
	occurrence and is NOT re-run when that value moves between keys/indices
	(e.g. an `ArraySwapRemove`). The Janitor is destroyed when that value
	occurrence is no longer present or the connection disconnects.
]=]
function TableManager.ForValues<T, S>(
	self: TM_Internal<T>,
	path: Path<S>,
	handler: (itemJanitor: Janitor, value: ElementAtPath<T, S>, metadata: ChangeMetadata?) -> (),
	options: ForOptions?
): Connection
	const parsedPath = PathHelpers.ParsePath(path)
	return makeValueReconciler(self, parsedPath, handler, options)
end

--[=[
	Reconciles the items found at `path` by KEY AND VALUE: `handler` re-runs
	(tearing down the previous item's Janitor first) whenever EITHER the key
	or the value changes — a value change at an existing key is treated as
	that item leaving and a new one appearing.
]=]
function TableManager.ForPairs<T, S>(
	self: TM_Internal<T>,
	path: Path<S>,
	handler: (
		itemJanitor: Janitor,
		key: KeyAtPath<T, S>,
		value: ElementAtPath<T, S>,
		metadata: ChangeMetadata?
	) -> (),
	options: ForOptions?
): Connection
	const parsedPath = PathHelpers.ParsePath(path)
	return makeKeyedReconciler(self, parsedPath, true, handler, nil, nil, options, nil)
end

--[=[
	@within TableManager
	@unreleased
	Returns a live `TableManager` keyed by `transform(entryJanitor, key, value)`,
	with values passed through unchanged. `transform` re-runs only when the
	source key is added/removed; a value change at an existing key refreshes
	the output value WITHOUT re-running `transform`. The output manager owns
	the source subscription: destroying it disconnects from the source and
	tears down every entry's Janitor. Destroying the SOURCE does not
	cascade-destroy the returned manager (independent lifecycles).
]=]
function TableManager.MapKeys<T, S>(
	self: TM_Internal<T>,
	path: Path<S>,
	transform: (entryJanitor: Janitor, key: KeyAtPath<T, S>, value: ElementAtPath<T, S>) -> any
): TableManager<any>
	const parsedPath = PathHelpers.ParsePath(path)
	const derived: TM_Internal<any> = TableManager.new({}) :: any
	const onAdd, onRemove, onRefresh = ForMapModule.makeKeyRemapHandlers(derived, function(itemJanitor, key, value)
		return transform(itemJanitor, key, value), value
	end)
	const connection =
		makeKeyedReconciler(self, parsedPath, false, onAdd, onRemove, onRefresh, nil, ForMapModule.batchedInitialFire(derived))
	ForMapModule.attachDerivedLifecycle(derived, connection)

	return derived :: any
end

--[=[
	@within TableManager
	@unreleased
	Returns a live `TableManager` keyed by the SOURCE key, with each entry
	recomputed via `transform(entryJanitor, value, key)` whenever its value
	changes. Same ownership/lifecycle rules as `MapKeys`.
]=]
function TableManager.MapValues<T, S>(
	self: TM_Internal<T>,
	path: Path<S>,
	transform: (entryJanitor: Janitor, value: ElementAtPath<T, S>, key: KeyAtPath<T, S>) -> any
): TableManager<any>
	const parsedPath = PathHelpers.ParsePath(path)
	const derived: TM_Internal<any> = TableManager.new({}) :: any

	const connection = makeKeyedReconciler(
		self,
		parsedPath,
		true,
		function(itemJanitor, key, value)
			derived:Set(key, transform(itemJanitor, value, key))
		end,
		function(_item, key)
			derived:Set(key, nil)
		end,
		nil,
		nil,
		ForMapModule.batchedInitialFire(derived)
	)
	ForMapModule.attachDerivedLifecycle(derived, connection)

	return derived :: any
end

--[=[
	@within TableManager
	@unreleased
	Returns a live `TableManager` keyed by `transform(entryJanitor, key, value)`'s
	first return value (the second is the output value); the entry is
	recomputed whenever the source key or value changes. On an output-key
	collision between two source entries, the last write wins. Same
	ownership/lifecycle rules as `MapKeys`.
]=]
function TableManager.MapPairs<T, S>(
	self: TM_Internal<T>,
	path: Path<S>,
	transform: (entryJanitor: Janitor, key: KeyAtPath<T, S>, value: ElementAtPath<T, S>) -> (any, any)
): TableManager<any>
	const parsedPath = PathHelpers.ParsePath(path)
	const derived: TM_Internal<any> = TableManager.new({}) :: any
	const onAdd, onRemove = ForMapModule.makeKeyRemapHandlers(derived, transform)
	const connection =
		makeKeyedReconciler(self, parsedPath, true, onAdd, onRemove, nil, nil, ForMapModule.batchedInitialFire(derived))
	ForMapModule.attachDerivedLifecycle(derived, connection)

	return derived :: any
end

--------------------------------------------------------------------------------
--// Helper Methods //--
--------------------------------------------------------------------------------

--[=[
	Get the value at a path.
]=]
function TableManager.Get<T, S>(self: TM_Internal<T>, path: Path<S>, suppressNilPartialPaths: boolean?): ValueAtPath<T, S>?
	debug.profilebegin("TM.Get")
	const parsedPath = PathHelpers.ParsePath(path)
	local current = self.Raw :: T & table
	for _, key in parsedPath do
		if type(current) ~= "table" then
			debug.profileend()
			if suppressNilPartialPaths then
				return nil
			else
				error(`Path segment {key} is not a table`)
			end
		end
		current = current[key]
	end
	debug.profileend()
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
	debug.profilebegin("TableManager.GetProxy")
	const proxyManager = self._proxyManager
	if proxyManager == nil then
		error("GetProxy requires proxies (Config.EnableProxies = false for this TableManager)")
	end
	const parsedPath = PathHelpers.ParsePath(path)
	local current = self.Proxy
	local previousKey: any = nil
	for _, key in parsedPath do
		if not proxyManager:IsProxy(current) then
			debug.profileend()
			if suppressNilPartialPaths then
				return nil
			else
				error(`Path segment {tostring(previousKey)} is not a table`)
			end
		end
		current = current[key]
		previousKey = key
	end
	debug.profileend()
	return current
end

--[=[
	Set the value at a path.

	An empty path (`Set({}, newTable)` / `Set("", newTable)`) replaces the entire
	root table: its identity is swapped to `newTable`, stale proxies of the old
	tree are pruned, and root/child change listeners fire for the diff. The new
	root must be a table (the root cannot become a scalar or `nil`), and the root
	cannot be replaced while a batch is open.
]=]
function TableManager.Set<T, S>(
	self: TM_Internal<T>,
	path: Path<S>,
	value: ValueAtPath<T, S> | Types.OpaqueWrapper<ValueAtPath<T, S>>,
	buildTablesDynamically: boolean?
)
	debug.profilebegin("TM.Set")
	local parsedPath = PathHelpers.ParsePath(path)
	local unwrappedValue = ProxyManagerModule.Unwrap(value)
	unwrappedValue = OpaqueRegistryModule.UnwrapAndRegister(self._opaqueRegistries, unwrappedValue)

	-- Empty path replaces the entire root table (identity swap + full diff).
	if #parsedPath == 0 then
		applyRootSet(self, unwrappedValue)
		debug.profileend()
		return
	end

	-- Only build intermediate tables when setting non-nil values; removing (nil) doesn't need them
	const shouldBuild = buildTablesDynamically and unwrappedValue ~= nil

	-- Fast path: a non-nil write with no dynamic-build request has no behavior
	-- left in the loop below beyond what `applyWrite`'s own parent-chain walk
	-- already performs (including reporting the identical "Path segment X is
	-- not a table" error) — so skip straight to the single walk instead of
	-- walking the parent chain twice.
	if unwrappedValue ~= nil and not buildTablesDynamically then
		applyWrite(self, parsedPath, unwrappedValue)
		debug.profileend()
		return
	end

	local parent: any = self.Raw
	for i = 1, #parsedPath - 1 do
		const nextValue = parent[parsedPath[i]]
		if type(nextValue) ~= "table" then
			if not shouldBuild then
				debug.profileend()
				if unwrappedValue == nil then
					return -- Silently return if we are setting a non existent path to nil since it is already nil.
				end
				error(`Path segment {parsedPath[i]} is not a table`)
			end

			-- Build intermediate tables for the remainder of the path, then apply the write.
			local nested: any = unwrappedValue
			for j = #parsedPath, i + 1, -1 do
				nested = { [parsedPath[j]] = nested }
			end
			const subPath = table.move(parsedPath, 1, i, 1, table.create(i))
			applyWrite(self, subPath, nested)
			debug.profileend()
			return
		end
		parent = nextValue
	end

	applyWrite(self, parsedPath, unwrappedValue)
	debug.profileend()
end

--[=[
	Insert value(s) into an array at a specific position or at the end.
]=]
function TableManager.ArrayInsert<T, S>(self: TM_Internal<T>, pathOrProxy: Path<S> | Proxy<T, S>, ...: any): ()
	debug.profilebegin("TM.ArrayInsert")
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

	local unwrappedValue = ProxyManagerModule.Unwrap(newValue)
	unwrappedValue = OpaqueRegistryModule.UnwrapAndRegister(self._opaqueRegistries, unwrappedValue)

	if not MutatorModule.validateArrayInsert(self, parsedPath, unwrappedValue) then return end

	const inBatch = trackArrayMutation(self, parsedPath)

	-- Insert the value (handles shifting when inserting into the middle).
	table.insert(array, pos, unwrappedValue)
	-- Update Key metadata for all proxies that were shifted right by this insert.
	shiftArrayKeys(self._proxyManager, array, pos, 1)
	-- Implicit sharing: an inserted table already observed elsewhere becomes a
	-- shared region (writes propagate between observers).
	if not self._suppressLinkFanOut then
		PropagationModule.RegisterSubtree(self :: any, unwrappedValue)
	end

	if not inBatch then
		-- Fire element-level and array-level listeners, ancestor callbacks, and signal.
		emitInserted(self, parsedPath, pos, unwrappedValue)
	end
	debug.profileend()
end
TableManager.Insert = TableManager.ArrayInsert

--[=[
	Remove an element from an array at a specific index.
]=]
function TableManager.ArrayRemove<T, S>(self: TM_Internal<T>, pathOrProxy: Path<S> | Proxy<T, S>, index: number): any
	debug.profilebegin("TM.ArrayRemove")
	local parsedPath, array = resolveArrayForWrite(self, pathOrProxy)

	const inBatch = trackArrayMutation(self, parsedPath)

	-- Remove the element (handles shifting automatically).
	const oldValue = table.remove(array, index)
	-- Shift proxies after the removed slot left by 1. Pass index+1 as fromIndex
	-- so the removed item's own proxy (if held) keeps its original key rather than
	-- being shifted to key=0.
	shiftArrayKeys(self._proxyManager, array, index + 1, -1)
	pruneDetachedValue(self, oldValue, nil)

	if inBatch then 
		debug.profileend()
		return oldValue 
	end

	-- Fire listeners EXACTLY at remove path (we handle ancestors separately)
	emitRemoved(self, parsedPath, index, oldValue)
	debug.profileend()
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

	const inBatch = trackArrayMutation(self, parsedPath)

	if index ~= lastIndex then
		array[index] = movedValue
	end
	array[lastIndex] = nil
	pruneDetachedValue(self, oldValue, nil)

	if inBatch then return oldValue end

	-- moveId is typed as `string` (ArrayDiff.MoveMetadata) for downstream
	-- consumers that may key off it; kept as an interpolated string rather than
	-- widening that public type for this single call site.
	const moveInfo = if index ~= lastIndex
		then { moveId = `swapremove_{index}_{lastIndex}`, fromIndex = lastIndex, toIndex = index }
		else nil

	-- 1. Emit ArraySet for the backfill: array[index] = movedValue (no-op if index == lastIndex)
	if index ~= lastIndex then
		emitSet(self, parsedPath, index, movedValue, oldValue, moveInfo)
	end

	-- 2. Emit ArrayRemoved for the shrink: array[lastIndex] = nil (the actual removal)
	emitRemoved(self, parsedPath, lastIndex, movedValue, moveInfo)

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
	BatchFlushModule.Suspend(self)
end

--[=[
	Resumes after `Suspend()` and flushes all pending changes.

	Flush is a single array-aware pass: per dirty branch, `CheckForChangesBetween`
	diffs the pre-batch value against the current value, collecting array-like
	nodes out of the dict diff; those are then re-diffed via LCS
	(`ArrayDiff.emitDiff`) into shift-faithful `Array*` events. See `BatchFlush`.
]=]
function TableManager.Resume(self: TM_Internal)
	BatchFlushModule.Resume(self)
end

--[=[
	@private
	Internal, unconditional diff+fire+reconcile for `path`: diffs the
	persistent shadow's last-flushed value against the current live value,
	fires the resulting events via `CheckForChangesBetween`, then reconciles
	the shadow to live. Callers (the immediate write path, `Flush`,
	`_NotifyApplied`, `BatchFlush.Resume`) are responsible for the coverage
	gate and batch-state check; this always runs.
]=]
function TableManager._doFlush<T>(self: TM_Internal<T>, path: PathArray)
	const old = BaselineModule.Get(self, path)
	const new_ = self:Get(path :: any, true)
	const oldSnapshot = BatchUtilsModule.BuildOldSnapshot(self, path, old)
	-- Transparent depth bound: don't diff below the deepest listener that observes
	-- `path` (nil = unbounded when a signal/link/wildcard/ProvideDiff forces it).
	const maxDepth = CoverageModule.ResolveDiffMaxDepth(self, path)
	self._changeDetector:CheckForChangesBetween(old, new_, path, self.Raw, nil, oldSnapshot, maxDepth)
	BaselineModule.Reconcile(self, path)
end

--[=[
	Diffs the persistent shadow baseline against the live value at `path`
	(the whole tree when omitted), fires any resulting events, then
	reconciles the shadow to the current live value. A no-op when nothing
	observes `path` (no registered listener covers it, no global Signal is
	connected, and no link group is active).

	Outside a batch this runs immediately. Inside a `Suspend`/`Batch` window
	it just marks the branch dirty for `Resume`'s flush instead of firing, so
	an explicit `Flush` can never break batch atomicity.

	This is also the supported way to surface a mutation made by code that
	bypassed `Set`/`Proxy` and wrote directly into the underlying table.
]=]
function TableManager.Flush<T, S>(self: TM_Internal<T>, path: Path<S>?)
	const parsedPath: PathArray = if path ~= nil then PathHelpers.ParsePath(path) else {}
	if not CoverageModule.IsTrackable(self, parsedPath) then
		return
	end
	if self._batchDepth > 0 then
		const batch = self._batch
		if batch then
			BatchUtilsModule.MarkBatchBranchDirty(batch, parsedPath)
		end
		return
	end
	CoalescedFlushModule.FlushPending(self)
	self:_doFlush(parsedPath)
end

--[=[
	Marks `path` (and every descendant of it) as ignored or not. An ignored
	write still happens — `Get`/`Raw` reflect it immediately — but skips all
	diff/snapshot/event work, so it never fires listeners/signals and is never
	cloned for change detection. See `TableManagerConfig.IgnoredPaths` for the
	config-time equivalent (seeded once at construction).
]=]
function TableManager.SetPathIgnored<T, S>(self: TM_Internal<T>, path: Path<S>, ignored: boolean)
	IgnoreTrieModule.SetPathIgnored(self._ignoreTrie, path, ignored)
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
	debug.profilebegin("TM.MoveTo")
	const sourcePath: PathArray<S1> = resolvePathFromPathOrProxy(self, currentPath)
	const targetPath: PathArray<S2> = resolvePathFromPathOrProxy(self, newPath)

	if #sourcePath == 0 or #targetPath == 0 then
		error("MoveTo cannot move the root table")
	end

	if PathHelpers.ArePathsEqual(sourcePath, targetPath) then
		debug.profileend()
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

	const rollback = reparentWithRollback(self._proxyManager, sourceValue, targetParentOriginal, targetKey)

	const ok, moveErr = pcall(function()
		self:Batch(function()
			self:Set(targetPath, sourceValue)
			self:Set(sourcePath, nil :: any)
		end)
	end)

	if not ok then
		restoreReparent(self._proxyManager, rollback)
		error(moveErr, 2)
	end
	debug.profileend()
end

--[=[
	DeepCopy a value from one location to another within the same table.
	This sets the value at the new path to be the same as the value at the current path, firing appropriate notifications.
	This is specifically useful for copying tables around without breaking proxy references.
]=]
function TableManager.CopyTo<T, S1, S2>(self: TM_Internal<T>, currentPath: Path<S1> | Proxy<T, S1>, newPath: Path<S2>)
	debug.profilebegin("TM.CopyTo")
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
	debug.profileend()
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

	const rollbackA = reparentWithRollback(self._proxyManager, valueA, parentOriginalB, keyB)
	const rollbackB = reparentWithRollback(self._proxyManager, valueB, parentOriginalA, keyA)

	const ok, swapErr = pcall(function()
		self:Batch(function()
			self:Set(pathA, valueB)
			self:Set(pathB, valueA)
		end)
	end)

	if not ok then
		restoreReparent(self._proxyManager, rollbackA)
		restoreReparent(self._proxyManager, rollbackB)
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
		Snapshot = createAncestorSnapshot(self.Raw),
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

	-- Tear down anything this manager owns (e.g. a `Map*` derived manager's
	-- subscription to its source) BEFORE dismantling our own subsystems below,
	-- since that teardown writes through `self:Set` to clear output entries.
	self._janitor:Destroy()

	-- Observer entries are weak-keyed by manager, so this manager drops out of
	-- the propagation registry automatically once it is unreferenced; dispatch
	-- also skips `_Destroyed` managers immediately (see `Propagation`).

	const batch = self._batch
	if batch then
		self._batch = nil
		self._batchDepth = 0
	end

	self._listenerRegistry:Destroy()
	const proxyManager = self._proxyManager
	if proxyManager then
		proxyManager:Destroy()
	end

	-- Disconnect all signals
	self.ValueChanged:Destroy()
	self.KeyAdded:Destroy()
	self.KeyRemoved:Destroy()
	self.KeyChanged:Destroy()
	self.ArrayInserted:Destroy()
	self.ArrayRemoved:Destroy()
	self.ArraySet:Destroy()

	setmetatable(self, nil)

	-- Setup No-op Destroy to avoid double-destroying errors
	const tm = self :: any
	tm.Destroy = function() end
end

-- Opacity wrapper constructors (see OpaqueRegistry): mark a value (or a
-- container's direct children) opaque to the diff engine — no clone/freeze/
-- walk of its internals, only identity compares. `Global*` variants register
-- in a registry shared by every TableManager rather than just this one.
TableManager.Opaque = OpaqueRegistryModule.Opaque
TableManager.GlobalOpaque = OpaqueRegistryModule.GlobalOpaque
TableManager.OpaqueChildren = OpaqueRegistryModule.OpaqueChildren
TableManager.GlobalOpaqueChildren = OpaqueRegistryModule.GlobalOpaqueChildren

return TableManager
