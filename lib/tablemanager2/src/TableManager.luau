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
const LinkGroupModule = require("./LinkGroup")
const LinkerModule = require("./Linker")
const Types = require("./TMTypes")
const EmitterModule = require("./Emitter")
const MutatorModule = require("./Mutator")

--// Localize batch utils to avoid function call overhead //--
const createSyntheticSnapshot = BatchUtilsModule.CreateSyntheticSnapshot

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
type SchemaCheck = SchemaNavigatorModule.Check
type BatchState = BatchUtilsModule.BatchState
type table = { [any]: any }

export type Proxy<T, S> = Types.Proxy<T, S>

export type LinkGroup = Types.LinkGroup
export type LinkAnchor = Types.LinkAnchor
export type AppliedOp = Types.AppliedOp

export type DuplicateReferenceMode = Types.DuplicateReferenceMode
export type TableManagerConfig = Types.TableManagerConfig
export type TableManager<T = { [any]: any }> = Types.TableManager<T>
export type Linker = Types.Linker

export type ExtendConfig = Types.ExtendConfig

export type TM_Internal<T = { [any]: any }> = Types.TM_Internal<T>
type ProxyManager<T> = ProxyManagerModule.ProxyManager<T>

--------------------------------------------------------------------------------
--// Module //--
--------------------------------------------------------------------------------

const TableManager = {}
const TableManager_MT = { __index = TableManager }

-- Re-export T so schema users do not need to import it separately.
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
const makeEmit = EmitterModule.makeEmit


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
	self._MakeEmit = function(path: PathArray)
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

	-- Initialize ChangeDetector with callbacks (signal+listener dual-fire in Emitter).
	-- `:: any` bypasses the generic-vs-non-generic callback signature mismatch
	-- (same pattern the original inline closures used to avoid).
	self._changeDetector = ChangeDetectorModule.new(EmitterModule.makeChangeDetectorCallbacks(self :: any) :: any)

	const proxyManager = self._proxyManager
	if proxyManager then
		-- Single write-integration point: every proxy write resolves its live path
		-- and unwrapped value, then flows through the proxy-free write core.
		proxyManager:SetWriteHandler(function(path: PathArray, value: any)
			applyWrite(self, path, value)
		end)

		-- Create root proxy (no parent, no key)
		self.Proxy = proxyManager:CreateProxy(self._originalData, nil, nil)
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
TableManager.Link = LinkGroupModule.Link

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
			shiftArrayKeys(self._proxyManager, self:Get(op.Path, true), index, 1)
			makeEmit(self, op.Path).inserted(index, op.NewValue)
		elseif op.Kind == "ArrayRemove" then
			const index = op.Index :: number
			shiftArrayKeys(self._proxyManager, self:Get(op.Path, true), index + 1, -1)
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
		const foundPath = if type(target) == "table" then LinkGroupModule.FindPathOf(self._originalData, target) else nil
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

	const extended = TableManager.new(object)
	LinkGroupModule.Link({ { self , anchorPath }, { extended } })

	return extended
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

	An empty path (`Set({}, newTable)` / `Set("", newTable)`) replaces the entire
	root table: its identity is swapped to `newTable`, stale proxies of the old
	tree are pruned, and root/child change listeners fire for the diff. The new
	root must be a table (the root cannot become a scalar or `nil`), and the root
	cannot be replaced while a batch is open.
]=]
function TableManager.Set<T, S>(
	self: TM_Internal<T>,
	path: Path<S>,
	value: ValueAtPath<T, S>,
	buildTablesDynamically: boolean?
)
	const parsedPath = PathHelpers.ParsePath(path)
	const unwrappedValue = ProxyManagerModule.Unwrap(value)

	-- Empty path replaces the entire root table (identity swap + full diff).
	if #parsedPath == 0 then
		applyRootSet(self, unwrappedValue)
		return
	end

	-- Only build intermediate tables when setting non-nil values; removing (nil) doesn't need them
	const shouldBuild = buildTablesDynamically and unwrappedValue ~= nil

	local parent: any = self._originalData
	for i = 1, #parsedPath - 1 do
		const nextValue = parent[parsedPath[i]]
		if type(nextValue) ~= "table" then
			if not shouldBuild then
				if unwrappedValue == nil then
					return -- Silently return if we are setting a non existent path to nil since it is already nil.
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

	if not MutatorModule.validateArrayInsert(self, parsedPath, unwrappedValue) then return end

	const inBatch = trackArrayMutation(self, parsedPath)

	-- Insert the value (handles shifting when inserting into the middle).
	table.insert(array, pos, unwrappedValue)
	-- Update Key metadata for all proxies that were shifted right by this insert.
	shiftArrayKeys(self._proxyManager, array, pos, 1)
	-- Direct auto-link for an inserted managed table.
	if self._autoLink and not self._suppressLinkFanOut then
		const elementPath = PathHelpers.Append(parsedPath, pos)
		LinkGroupModule.CheckAutoLink(self :: any, elementPath, unwrappedValue)
	end

	if inBatch then return end

	-- Fire element-level and array-level listeners, ancestor callbacks, and signal.
	makeEmit(self, parsedPath).inserted(pos, unwrappedValue)
end
TableManager.Insert = TableManager.ArrayInsert

--[=[
	Remove an element from an array at a specific index.
]=]
function TableManager.ArrayRemove<T, S>(self: TM_Internal<T>, pathOrProxy: Path<S> | Proxy<T, S>, index: number): any
	local parsedPath, array = resolveArrayForWrite(self, pathOrProxy)

	const inBatch = trackArrayMutation(self, parsedPath)

	-- Remove the element (handles shifting automatically).
	const oldValue = table.remove(array, index)
	-- Shift proxies after the removed slot left by 1. Pass index+1 as fromIndex
	-- so the removed item's own proxy (if held) keeps its original key rather than
	-- being shifted to key=0.
	shiftArrayKeys(self._proxyManager, array, index + 1, -1)
	pruneDetachedValue(self, oldValue, nil)
	if not self._suppressLinkFanOut then
		LinkGroupModule.CheckDivergence(self, parsedPath)
	end

	if inBatch then return oldValue end

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

	const inBatch = trackArrayMutation(self, parsedPath)

	if index ~= lastIndex then
		array[index] = movedValue
	end
	array[lastIndex] = nil
	pruneDetachedValue(self, oldValue, nil)
	if not self._suppressLinkFanOut then
		LinkGroupModule.CheckDivergence(self, parsedPath)
	end

	if inBatch then return oldValue end

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
TableManager.Suspend = BatchFlushModule.Suspend

--[=[
	Resumes after `Suspend()` and flushes all pending changes.

	Flush is two-phase:
	1. **Non-array flush** — per dirty branch, `CheckForChangesBetween` diffs the
	   pre-batch value against the current value (with tracked-array subtrees
	   masked out — the array flush owns those), firing all non-array events.
	2. **Array flush** — For each tracked array path, diffs the pre-batch
	   snapshot against the current value via LCS (`ArrayDiff.emitDiff`).
]=]
TableManager.Resume = BatchFlushModule.Resume

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
end

return TableManager
