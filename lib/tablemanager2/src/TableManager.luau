--!strict
--[=[
	@class TableManager
	
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
]=]

--// Imports //--
const T = require("../T")
const Signal = require("../Signal")
const PathHelpers = require("./PathHelpers")
const ProxyManagerModule = require("./ProxyManager")
const ListenerRegistryModule = require("./ListenerRegistry")
const ChangeDetectorModule = require("./ChangeDetector")
const SchemaNavigatorModule = require("./SchemaNavigator")
const ArrayBatchRecorderModule = require("./ArrayBatchRecorder")
const ArrayDiffModule = require("./ArrayDiff")
const Diff = require("./Diff")
const BatchUtilsModule = require("./BatchUtils")

--// Localize batch utils to avoid function call overhead //--
const createSyntheticSnapshot = BatchUtilsModule.CreateSyntheticSnapshot
const serializeBatchPath = BatchUtilsModule.SerializeBatchPath
const getSnapshotValue = BatchUtilsModule.GetSnapshotValue
const getBatchBranchKey = BatchUtilsModule.GetBatchBranchKey
const markBatchBranchDirty = BatchUtilsModule.MarkBatchBranchDirty
const ensureBatchPathTracking = BatchUtilsModule.EnsureBatchPathTracking

--// Types //--
type Path<S = string> = PathHelpers.Path<S>
type PathArray<S = string> = PathHelpers.PathArray<S>
type ValueAtPath<T, S> = PathHelpers.ValueAtPath<T, S>
type ProxyManager = ProxyManagerModule.ProxyManager
type ListenerRegistry = ListenerRegistryModule.ListenerRegistry
type ChangeDetector = ChangeDetectorModule.ChangeDetector
type ChangeMetadata = ChangeDetectorModule.ChangeMetadata
type ListenerOptions = ListenerRegistryModule.ListenerOptions
type Connection = ListenerRegistryModule.Connection
type Signal<Fn, Args...> = Signal.Signal<Fn, Args...>
type ArrayBatchRecorder = ArrayBatchRecorderModule.ArrayBatchRecorder
type SchemaCheck = SchemaNavigatorModule.Check

type BatchState = {
	Recorder: ArrayBatchRecorder,
	StartSnapshot: any,
	TrackedPaths: { [string]: PathArray },
	DirtyBranches: { [any]: boolean },
	Flushing: boolean,
}

export type Proxy<T = any, S = ""> = ProxyManagerModule.Proxy<T, S>

export type DuplicateReferenceMode = "error" | "warn" | "allow" | "move" | "copy"

export type TableManagerConfig = {
	Schema: SchemaCheck?,
	OnValidationFailed: ((path: PathArray, value: any, err: string) -> ())?,
	ListenersFireDeferred: boolean?,
	DuplicateReferenceMode: DuplicateReferenceMode?, -- Experimental
}

export type TableManager<T = { [any]: any }> = {
	Proxy: Proxy<T>,
	Raw: T,

	-- Signals (fire once per change)
	ValueChanged: Signal<(path: PathArray, newValue: any, oldValue: any) -> (), PathArray, any, any>,
	KeyAdded: Signal<(path: PathArray, key: any, newValue: any) -> (), PathArray, any, any>,
	KeyRemoved: Signal<(path: PathArray, key: any, oldValue: any) -> (), PathArray, any, any>,
	KeyChanged: Signal<(path: PathArray, key: any, newValue: any, oldValue: any) -> (), PathArray, any, any, any>,
	ArrayInserted: Signal<(path: PathArray, index: number, newValue: any) -> (), PathArray, number, any>,
	ArrayRemoved: Signal<(path: PathArray, index: number, oldValue: any) -> (), PathArray, number, any>,
	ArraySet: Signal<(path: PathArray, index: number, newValue: any, oldValue: any) -> (), PathArray, number, any, any>,

	-- Listener registration (fire for ancestors/descendants)
	OnValueChange: <S>(
		self: TableManager<T>,
		path: Path<S>,
		callback: (newValue: ValueAtPath<T, S>, oldValue: ValueAtPath<T, S>?, metadata: ChangeMetadata) -> (),
		options: ListenerOptions?
	) -> Connection,
	--- Fires ONLY when this exact path is directly reassigned (not when a
	--- descendant changes). Shorthand for `OnValueChange` with
	--- `ListenDepth = 0, ListenDepthStyle = "=="`.
	OnValueChanged: <S>(
		self: TableManager<T>,
		path: Path<S>,
		callback: (newValue: ValueAtPath<T, S>, oldValue: ValueAtPath<T, S>?, metadata: ChangeMetadata) -> (),
		options: ListenerOptions?
	) -> Connection,
	--- Fires when this path is directly reassigned OR any descendant of it
	--- changes. Alias for `OnValueChange`.
	OnChanged: <S>(
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
	OnKeyAdd: (
		self: TableManager<T>,
		path: Path,
		callback: (key: any, newValue: any, metadata: ChangeMetadata) -> (),
		options: ListenerOptions?
	) -> Connection,
	OnKeyRemove: (
		self: TableManager<T>,
		path: Path,
		callback: (key: any, oldValue: any, metadata: ChangeMetadata) -> (),
		options: ListenerOptions?
	) -> Connection,
	OnKeyChange: <S>(
		self: TableManager<T>,
		path: Path<S>,
		callback: (key: any, newValue: ValueAtPath<T, S>, oldValue: ValueAtPath<T, S>, metadata: ChangeMetadata) -> (),
		options: ListenerOptions?
	) -> Connection,
	OnArrayInsert: (
		self: TableManager<T>,
		path: Path,
		callback: (index: number, newValue: any, metadata: ChangeMetadata) -> (),
		options: ListenerOptions?
	) -> Connection,
	OnArrayRemove: (
		self: TableManager<T>,
		path: Path,
		callback: (index: number, oldValue: any, metadata: ChangeMetadata) -> (),
		options: ListenerOptions?
	) -> Connection,
	OnArraySet: (
		self: TableManager<T>,
		path: Path,
		callback: (index: number, newValue: any, oldValue: any, metadata: ChangeMetadata) -> (),
		options: ListenerOptions?
	) -> Connection,

	-- Helper methods
	Get: <S>(self: TableManager<T>, path: Path<S>, suppressNilPartialPaths: boolean?) -> ValueAtPath<T, S>,
	GetProxy: <S>(self: TableManager<T>, path: Path<S>, suppressNilPartialPaths: boolean?) -> Proxy<T, S>,
	Set: <S>(self: TableManager<T>, path: Path<S>, value: ValueAtPath<T, S>) -> (),
	ArrayInsert: (self: TableManager<T>, arrPath: Path | Proxy, newValue: any) -> ()
		& (self: TableManager<T>, arrPath: Path | Proxy, index: number, newValue: any) -> (),
	ArrayRemove: <S>(self: TableManager<T>, arrPath: Path | Proxy, index: number) -> any,
	ArrayRemoveFirstValue: (self: TableManager<T>, arrPath: Path | Proxy, valueToFind: any) -> number?,
	ArraySwapRemove: (self: TableManager<T>, arrPath: Path | Proxy, index: number) -> any,
	ArraySwapRemoveFirstValue: (self: TableManager<T>, arrPath: Path | Proxy, valueToFind: any) -> number?,
	MoveTo: <S1, S2>(self: TableManager<T>, currentPath: Path<S1>, newPath: Path<S2>) -> (),
	CopyTo: <S1, S2>(self: TableManager<T>, currentPath: Path<S1>, newPath: Path<S2>) -> (),
	Swap: <S1, S2>(self: TableManager<T>, a: Path<S1>, b: Path<S2>) -> (),
	ForceNotify: (self: TableManager<T>, path: Path<string> | Proxy) -> (),
	Batch: (self: TableManager<T>, fn: () -> ()) -> (),
	--- Manually suspend signal/listener firing. Pair with `Resume()` to flush.
	Suspend: (self: TableManager<T>) -> (),
	--- Resume after `Suspend()`. Flushes all pending changes.
	Resume: (self: TableManager<T>) -> (),
	Destroy: (self: TableManager<T>) -> (),
}

export type TM_Internal<T = { [any]: any }> = TableManager<T> & {
	-- fields
	_proxyManager: ProxyManager,
	_listenerRegistry: ListenerRegistry,
	_changeDetector: ChangeDetector,
	_originalData: T,
	_schema: SchemaCheck?,
	_onValidationFailed: ((path: Path, value: any, err: string) -> ())?,
	_duplicateReferenceMode: DuplicateReferenceMode,
	_Destroyed: boolean?,
	-- Batch state
	_batchDepth: number,
	_batch: BatchState?,
}

--------------------------------------------------------------------------------
--// Module //--
--------------------------------------------------------------------------------

const TableManager = {}
const TableManager_MT = { __index = TableManager }

-- Re-export T so schema users do not need to import it separately.
TableManager.T = T

const function resolvePathFromPathOrProxy<T, S>(self: TM_Internal<T>, pathOrProxy: Path<S> | Proxy<T, S>): PathArray<S>
	if self._proxyManager:IsProxy(pathOrProxy) then
		const proxy = pathOrProxy :: Proxy<T, S>
		const potentialPath = self._proxyManager:GetPath(proxy)
		assert(potentialPath, "Proxy does not have a path")
		return potentialPath
	end
	return PathHelpers.ParsePath(pathOrProxy :: Path)
end

const function resolveArrayPathAndProxy<T, S>(
	self: TM_Internal<T & any>,
	pathOrProxy: Path<S> | Proxy<T, S>
): (PathArray<S>, Proxy<T, S>)
	if self._proxyManager:IsProxy(pathOrProxy) then
		const proxy = pathOrProxy :: Proxy<T, S>
		const parsedPath = resolvePathFromPathOrProxy(self, proxy)
		return parsedPath, proxy
	end

	const parsedPath = PathHelpers.ParsePath(pathOrProxy :: Path)
	const proxy = self:GetProxy(parsedPath)
	return parsedPath, proxy
end

const function getParentOriginalAtPath(self: TM_Internal<any>, parentPath: PathArray, opName: string): any
	local parentOriginal: any = if #parentPath == 0 then self._originalData else self:Get(parentPath)
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

const function createSyntheticMetadata(
	rootTable: any,
	leafPath: PathArray,
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

type ReparentRollback = {
	Proxy: Proxy<any>,
	Parent: any?,
	Key: any?,
}

const function reparentWithRollback(
	self: TM_Internal<any>,
	proxy: Proxy<any>?,
	newParent: any,
	newKey: any
): ReparentRollback?
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

const function restoreReparent(self: TM_Internal<any>, rollback: ReparentRollback?)
	if rollback == nil then
		return
	end
	self._proxyManager:ReparentProxy(rollback.Proxy, rollback.Parent, rollback.Key)
end

const function fireAncestorValueChangedNotifications(
	manager: TM_Internal<any>,
	basePath: PathArray,
	metadata: ChangeMetadata,
	includeKeyChanged: boolean?
)
	const shouldIncludeKeyChanged = if includeKeyChanged == nil then true else includeKeyChanged

	for i = #basePath, 0, -1 do
		const ancestorPath = {}
		for j = 1, i do
			table.insert(ancestorPath, basePath[j])
		end

		const ancestorMetadata: ChangeMetadata = {
			Diff = nil,
			OriginPath = metadata.OriginPath,
			OriginDiff = metadata.OriginDiff,
			Snapshot = metadata.Snapshot,
		}

		manager._listenerRegistry:FireListenersExact("ValueChanged", ancestorPath, {
			NewValue = nil,
			OldValue = nil,
			Metadata = ancestorMetadata,
		})

		if shouldIncludeKeyChanged and i < #basePath then
			const changedKey = basePath[i + 1]
			manager._listenerRegistry:FireListenersExact("KeyChanged", ancestorPath, {
				Key = changedKey,
				NewValue = nil,
				OldValue = nil,
				Metadata = ancestorMetadata,
			})
		end
	end
end

const function fireArrayOperation(
	manager: TM_Internal<any>,
	eventName: "ArrayInserted" | "ArrayRemoved" | "ArraySet",
	basePath: PathArray,
	leafPath: PathArray,
	payload: any
)
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
end

const function validateWrite(self: TM_Internal<any>, path: PathArray, value: any): (boolean, string?)
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
	Builds the `Emit` interface for a single array path, wiring the three
	callbacks to fire `ArrayRemoved` / `ArrayInserted` / `ArraySet` signals,
	exact-path listeners, and ancestor callbacks in the correct order.
]]
const function makeEmit<S>(self: TM_Internal<any>, path: PathArray<S>)
	return {
		removed = function(index: number, oldValue: any)
			const removedPath = table.clone(path)
			table.insert(removedPath, index)
			const metadata = createSyntheticMetadata(self._originalData, removedPath, "removed", index, nil, oldValue)
			fireArrayOperation(self, "ArrayRemoved", path, removedPath, {
				Index = index,
				OldValue = oldValue,
				Metadata = metadata,
			})
		end,
		inserted = function(index: number, newValue: any)
			const insertedPath = table.clone(path)
			table.insert(insertedPath, index)
			const metadata = createSyntheticMetadata(self._originalData, insertedPath, "added", index, newValue, nil)
			fireArrayOperation(self, "ArrayInserted", path, insertedPath, {
				Index = index,
				NewValue = newValue,
				Metadata = metadata,
			})
		end,
		set = function(index: number, newValue: any, oldValue: any)
			const setPath = table.clone(path)
			table.insert(setPath, index)
			const metadata = createSyntheticMetadata(self._originalData, setPath, "changed", index, newValue, oldValue)
			fireArrayOperation(self, "ArraySet", path, setPath, {
				Index = index,
				NewValue = newValue,
				OldValue = oldValue,
				Metadata = metadata,
			})
		end,
	}
end

--[=[
	@unreleased
	Utility for peeking at the current value of a proxy without triggering any
	side effects. Used internally for array operations to get old values.
]=]
-- function TableManager.peek<T>(proxy: Proxy<T> | T): T
-- 	error("TableManager.peek() is not yet implemented. This is a placeholder.")
-- end

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
	const self = (setmetatable({}, TableManager_MT) :: any) :: TM_Internal<{ [any]: any }>
	const resolvedConfig = config or {} :: { [string]: any? }
	const duplicateReferenceMode: DuplicateReferenceMode = resolvedConfig.DuplicateReferenceMode or "error"

	-- Store original data
	self._originalData = initialData or {}
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

	-- Initialize subsystems
	self._proxyManager = ProxyManagerModule.new(self._originalData)
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

	-- During batch array flush: suppress numeric-key events on tracked array paths.
	-- Those arrays will emit their own coalesced events via the array flush.
	const function shouldSuppressBatchArrayKeyEvent(path: Path, key: any): boolean
		const batch = self._batch
		if batch == nil or not batch.Flushing or type(key) ~= "number" then
			return false
		end
		return batch.TrackedPaths[serializeBatchPath(path)] ~= nil
	end

	-- Initialize ChangeDetector with callbacks
	-- NOTE: Use FireListenersExact() to prevent double ancestor propagation
	-- ChangeDetector already handles ancestor notifications, so we only fire at exact paths
	self._changeDetector = ChangeDetectorModule.new {
		OnKeyAdded = function(path: PathArray, key: any, newValue: any, metadata: ChangeMetadata)
			if shouldSuppressBatchArrayKeyEvent(path, key) then
				return
			end

			-- Fire listeners ONLY at exact path (ChangeDetector handles ancestors)
			self._listenerRegistry:FireListenersExact("KeyAdded", path, {
				NewValue = newValue,
				Key = key,
				Metadata = metadata,
			})

			-- Fire signal ONLY for leaf changes (not descendantChanged)
			if metadata.Diff and metadata.Diff.type ~= "descendantChanged" then
				self.KeyAdded:Fire(path, key, newValue)
			end
		end,

		OnKeyRemoved = function(path: PathArray, key: any, oldValue: any, metadata: ChangeMetadata)
			if shouldSuppressBatchArrayKeyEvent(path, key) then
				return
			end

			self._listenerRegistry:FireListenersExact("KeyRemoved", path, {
				OldValue = oldValue,
				Key = key,
				Metadata = metadata,
			})

			-- Fire signal ONLY for leaf changes (not descendantChanged)
			if metadata.Diff and metadata.Diff.type ~= "descendantChanged" then
				self.KeyRemoved:Fire(path, key, oldValue)
			end
		end,

		OnKeyChanged = function(path: PathArray, key: any, newValue: any, oldValue: any, metadata: ChangeMetadata)
			if shouldSuppressBatchArrayKeyEvent(path, key) then
				return
			end

			self._listenerRegistry:FireListenersExact("KeyChanged", path, {
				NewValue = newValue,
				OldValue = oldValue,
				Key = key,
				Metadata = metadata,
			})

			-- Fire signal ONLY for leaf changes (not descendantChanged)
			if metadata.Diff and metadata.Diff.type ~= "descendantChanged" then
				self.KeyChanged:Fire(path, key, newValue, oldValue)
			end
		end,

		OnValueChanged = function(path: PathArray, newValue: any, oldValue: any?, metadata: ChangeMetadata)
			self._listenerRegistry:FireListenersExact("ValueChanged", path, {
				NewValue = newValue,
				OldValue = oldValue,
				Metadata = metadata,
			})

			-- Fire signal ONLY for leaf changes (not descendantChanged)
			if metadata.Diff and metadata.Diff.type ~= "descendantChanged" then
				self.ValueChanged:Fire(path, newValue, oldValue)
			end
		end,
	}

	-- Wire up ProxyManager to ChangeDetector
	self._proxyManager:SetChangeDetector(self._changeDetector)
	if self._schema then
		self._proxyManager:SetValidateCallback(function(path: PathArray, value: any): (boolean, string?)
			return validateWrite(self :: any, path, value)
		end)
	end

	-- Wire up array append callback
	self._proxyManager:SetArrayInsertedCallback(function(path: PathArray, index: number, newValue: any)
		-- During batch: log the insert and skip fires.
		-- The element is already appended to the original table at this point, so we
		-- reconstruct the pre-append array (original[1..index-1]) for StartTracking.
		if self._batchDepth > 0 then
			const batch = self._batch
			if batch then
				const recorder = batch.Recorder
				ensureBatchPathTracking(batch, path, function()
					-- Build a pre-append shallow copy: original[1..index-1]
					const original: { any } = self:Get(path)
					const preBatch: { any } = table.create(index - 1)
					for i = 1, index - 1 do
						preBatch[i] = original[i]
					end
					recorder:StartTracking(path, preBatch)
				end)
				recorder:RecordInsert(path, index, newValue)
			end
			markBatchBranchDirty(batch, path)
			return
		end

		-- Create synthetic metadata for array append
		const insertPath: { any } = table.clone(path :: any)
		table.insert(insertPath, index)

		const metadata = createSyntheticMetadata(self._originalData, insertPath, "added", index, newValue, nil)

		-- Fire listeners at inserted element's path ONLY (we handle ancestors separately)
		fireArrayOperation(self, "ArrayInserted", path, insertPath, {
			Index = index,
			NewValue = newValue,
			Metadata = metadata,
		})
	end)

	-- Wire up direct numeric-index write callback (for batch poisoning)
	self._proxyManager:SetBatchDirectArraySetCallback(function(path: PathArray, _index: number)
		if self._batchDepth > 0 then
			const batch = self._batch
			if batch then
				const recorder = batch.Recorder
				ensureBatchPathTracking(batch, path, function()
					-- StartTracking with the post-mutation array; Branch A will use
					-- _batchStartSnapshot for the true pre-batch state anyway.
					const current: any = self:Get(path)
					if type(current) == "table" then
						recorder:StartTracking(path, current)
					end
				end)
				recorder:MarkPoisoned(path)
			end
		end
	end)

	-- Track which top-level branches are dirtied by non-array scalar writes.
	-- `parentPath` is the path of the proxy table that owns the written key.
	-- The branch key is `parentPath[1]` (or "__root__" for root-level writes).
	self._proxyManager:SetBatchScalarWrittenCallback(function(parentPath: PathArray)
		if self._batchDepth > 0 then
			markBatchBranchDirty(self._batch, parentPath)
		end
	end)

	local isMoveInProgress = false
	self._proxyManager:SetDuplicateTableWriteCallback(
		function(writePath: PathArray, existingPath: PathArray, value: any): boolean
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
				if isMoveInProgress then
					return true
				end

				isMoveInProgress = true
				local ok, moveErr = pcall(function()
					self:MoveTo(existingPath, writePath)
				end)
				isMoveInProgress = false

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
	)

	-- Create root proxy (no parent, no key)
	self.Proxy = self._proxyManager:CreateProxy(self._originalData, nil, nil)

	return self :: any
end
--------------------------------------------------------------------------------
--// Listener Registration //--
--------------------------------------------------------------------------------

function TableManager.OnValueChange(
	self: TM_Internal,
	path: Path,
	callback: (newValue: any, oldValue: any?, metadata: ChangeMetadata) -> (),
	options: ListenerOptions?
): Connection
	return self._listenerRegistry:RegisterListener("ValueChanged", PathHelpers.ParsePath(path), callback, options)
end

function TableManager.OnKeyAdd(
	self: TM_Internal,
	path: Path,
	callback: (newValue: any, metadata: ChangeMetadata) -> (),
	options: ListenerOptions?
): Connection
	return self._listenerRegistry:RegisterListener("KeyAdded", PathHelpers.ParsePath(path), callback, options)
end

function TableManager.OnKeyRemove(
	self: TM_Internal,
	path: Path,
	callback: (oldValue: any, metadata: ChangeMetadata) -> (),
	options: ListenerOptions?
): Connection
	return self._listenerRegistry:RegisterListener("KeyRemoved", PathHelpers.ParsePath(path), callback, options)
end

function TableManager.OnKeyChange(
	self: TM_Internal,
	path: Path,
	callback: (key: any, newValue: any, oldValue: any, metadata: ChangeMetadata) -> (),
	options: ListenerOptions?
): Connection
	return self._listenerRegistry:RegisterListener("KeyChanged", PathHelpers.ParsePath(path), callback, options)
end

function TableManager.OnArrayInsert(
	self: TM_Internal,
	path: Path,
	callback: (index: number, newValue: any, metadata: ChangeMetadata) -> (),
	options: ListenerOptions?
): Connection
	return self._listenerRegistry:RegisterListener("ArrayInserted", PathHelpers.ParsePath(path), callback, options)
end

function TableManager.OnArrayRemove(
	self: TM_Internal,
	path: Path,
	callback: (index: number, oldValue: any, metadata: ChangeMetadata) -> (),
	options: ListenerOptions?
): Connection
	return self._listenerRegistry:RegisterListener("ArrayRemoved", PathHelpers.ParsePath(path), callback, options)
end

function TableManager.OnArraySet(
	self: TM_Internal,
	path: Path,
	callback: (index: number, newValue: any, oldValue: any, metadata: ChangeMetadata) -> (),
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
function TableManager.Get(self: TM_Internal, path: Path, suppressNilPartialPaths: boolean?): any?
	const parsedPath = PathHelpers.ParsePath(path)
	local current = self._originalData
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
function TableManager.GetProxy(self: TM_Internal, path: Path, suppressNilPartialPaths: boolean?): (Proxy<any> | any)?
	const parsedPath = PathHelpers.ParsePath(path)
	local current = self.Proxy
	local previousKey: any = nil
	for _, key in parsedPath do
		if not self._proxyManager:IsProxy(current) then
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
function TableManager.Set(self: TM_Internal, path: Path, value: any, buildTablesDynamically: boolean?)
	const parsedPath = PathHelpers.ParsePath(path)
	if #parsedPath == 0 then
		error("Cannot set root path")
	end

	local parent = self.Proxy
	for i = 1, #parsedPath - 1 do
		parent = parent[parsedPath[i]]
		if not self._proxyManager:IsProxy(parent) then
			if buildTablesDynamically then
				parent[parsedPath[i]] = {} -- TODO: Change this to use ProxyManager to create a proxy for the new table
				parent = parent[parsedPath[i]]
			else
				error(`Path segment {parsedPath[i]} is not a table`)
			end
		end
	end

	parent[parsedPath[#parsedPath]] = value
end

--[=[
	Insert value(s) into an array at a specific position or at the end.
]=]
function TableManager.ArrayInsert<T, S>(self: TM_Internal<T>, pathOrProxy: Path<S> | Proxy<T, S>, ...: any): ()
	const proxyManager = self._proxyManager
	local parsedPath, proxy = resolveArrayPathAndProxy(self, pathOrProxy)

	const meta: ProxyManagerModule.ProxyMetadata = proxyManager:GetMetadata(proxy)
	const array = proxyManager:GetOriginal(meta.Original)
	assert(type(array) == "table", "Target is not a table")

	-- Determine if a position was provided or default to appending.
	local pos: number
	local newValue: any
	if select("#", ...) >= 2 then
		local secondArg
		pos, secondArg = ...
		newValue = secondArg
	else
		pos = meta.ArrayLength + 1
		newValue = ...
	end

	-- Get original table
	const unwrappedValue = proxyManager:GetOriginal(newValue)

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

	-- Batch: start tracking before any mutations so startCopy captures pre-batch state.
	if self._batchDepth > 0 and self._batch then
		const batch = self._batch
		ensureBatchPathTracking(batch, parsedPath, function()
			batch.Recorder:StartTracking(parsedPath, array)
		end)
		markBatchBranchDirty(batch, parsedPath)
	end

	-- Insert the value (handles shifting when inserting into the middle).
	table.insert(array, pos, unwrappedValue)
	-- Update Key metadata for all proxies that were shifted right by this insert.
	proxyManager:ShiftKeys(array, pos, 1)

	-- Batch: log the insert and skip fires
	if self._batchDepth > 0 then
		if self._batch then
			self._batch.Recorder:RecordInsert(parsedPath, pos, unwrappedValue)
		end
		meta.ArrayLength = #array
		return
	end

	-- Create synthetic metadata
	const insertPath: { any } = table.clone(parsedPath :: any)
	table.insert(insertPath, pos)

	const metadata = createSyntheticMetadata(self._originalData, insertPath, "added", pos, unwrappedValue, nil)

	-- Fire element-level and array-level listeners, ancestor callbacks, and signal.
	fireArrayOperation(self, "ArrayInserted", parsedPath, insertPath, {
		Index = pos,
		NewValue = unwrappedValue,
		Metadata = metadata,
	})

	-- Update metadata
	meta.ArrayLength = #array
end
TableManager.Insert = TableManager.ArrayInsert

--[=[
	Remove an element from an array at a specific index.
]=]
function TableManager.ArrayRemove<T, S>(self: TM_Internal<T>, pathOrProxy: Path<S> | Proxy<T, S>, index: number): any
	const proxyManager = self._proxyManager
	local parsedPath, proxy = resolveArrayPathAndProxy(self, pathOrProxy)

	const meta: ProxyManagerModule.ProxyMetadata = self._proxyManager:GetMetadata(proxy)
	const array = proxyManager:GetOriginal(meta.Original)
	assert(type(array) == "table", "Target is not a table")

	-- Batch: start tracking and log the removal BEFORE mutating, so that
	-- _computeLiveIds in RecordRemove sees the correct pre-removal id sequence.
	if self._batchDepth > 0 and self._batch then
		const batch = self._batch
		ensureBatchPathTracking(batch, parsedPath, function()
			batch.Recorder:StartTracking(parsedPath, array)
		end)
		batch.Recorder:RecordRemove(parsedPath, index)
		markBatchBranchDirty(batch, parsedPath)
	end

	-- Remove the element (handles shifting automatically).
	const oldValue = table.remove(array, index)
	-- Shift proxies after the removed slot left by 1. Pass index+1 as fromIndex
	-- so the removed item's own proxy (if held) keeps its original key rather than
	-- being shifted to key=0.
	proxyManager:ShiftKeys(array, index + 1, -1)

	-- Batch: skip fires
	if self._batchDepth > 0 then
		meta.ArrayLength = #array
		return oldValue
	end

	-- Create synthetic metadata
	const removePath: { any } = table.clone(parsedPath :: any)
	table.insert(removePath, index)

	local metadata = createSyntheticMetadata(self._originalData, removePath, "removed", index, nil, oldValue)

	-- Fire listeners EXACTLY at remove path (we handle ancestors separately)
	fireArrayOperation(self, "ArrayRemoved", parsedPath, removePath, {
		Index = index,
		OldValue = oldValue,
		Metadata = metadata,
	})

	-- Update metadata
	meta.ArrayLength = #array

	return oldValue
end
TableManager.Remove = TableManager.ArrayRemove

--[=[
	Remove the first matching value from an array.
	Returns the index it was removed from, or nil if not found.
]=]
function TableManager.ArrayRemoveFirstValue<T, S>(self: TM_Internal<T>, pathOrProxy: Path<S>, valueToFind: any): number?
	const proxyManager = self._proxyManager
	local _parsedPath, proxy = resolveArrayPathAndProxy(self, pathOrProxy)

	const meta: ProxyManagerModule.ProxyMetadata = proxyManager:GetMetadata(proxy)
	const array = proxyManager:GetOriginal(meta.Original)
	assert(type(array) == "table", "Target is not a table")

	const index = table.find(array, valueToFind)
	if index == nil then
		return nil
	end

	self:ArrayRemove(pathOrProxy, index)
	return index
end
TableManager.RemoveFirstValue = TableManager.ArrayRemoveFirstValue

--[=[
	Remove an array element in O(1) by swapping in the last element.
	Order is not preserved.
]=]
function TableManager.ArraySwapRemove<T, S>(self: TM_Internal<T>, pathOrProxy: Path<S> | Proxy<T, S>, index: number): any
	const proxyManager = self._proxyManager
	local parsedPath, proxy = resolveArrayPathAndProxy(self, pathOrProxy)

	const meta: ProxyManagerModule.ProxyMetadata = proxyManager:GetMetadata(proxy)
	const array = proxyManager:GetOriginal(meta.Original)
	assert(type(array) == "table", "Target is not a table")

	const lastIndex = #array
	if index < 1 or index > lastIndex then
		return nil
	end

	const oldValue = array[index]
	const movedValue = array[lastIndex]

	-- Batch: start tracking and record remove/set intent before mutating.
	if self._batchDepth > 0 and self._batch then
		const batch = self._batch
		ensureBatchPathTracking(batch, parsedPath, function()
			batch.Recorder:StartTracking(parsedPath, array)
		end)
		batch.Recorder:RecordRemove(parsedPath, index)
		if index ~= lastIndex then
			batch.Recorder:RecordSet(parsedPath, index, movedValue, oldValue)
		end
		markBatchBranchDirty(batch, parsedPath)
	end

	if index ~= lastIndex then
		array[index] = movedValue
	end
	array[lastIndex] = nil

	-- Batch: skip immediate fires
	if self._batchDepth > 0 then
		meta.ArrayLength = #array
		return oldValue
	end

	const removePath: { any } = table.clone(parsedPath :: any)
	table.insert(removePath, index)

	const removeMetadata = createSyntheticMetadata(self._originalData, removePath, "removed", index, nil, oldValue)

	fireArrayOperation(self, "ArrayRemoved", parsedPath, removePath, {
		Index = index,
		OldValue = oldValue,
		Metadata = removeMetadata,
	})

	if index ~= lastIndex then
		const setPath: { any } = table.clone(parsedPath :: any)
		table.insert(setPath, index)

		const setMetadata = createSyntheticMetadata(self._originalData, setPath, "changed", index, movedValue, oldValue)

		fireArrayOperation(self, "ArraySet", parsedPath, setPath, {
			Index = index,
			NewValue = movedValue,
			OldValue = oldValue,
			Metadata = setMetadata,
		})
	end

	meta.ArrayLength = #array
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
	const proxyManager = self._proxyManager
	local _parsedPath, proxy = resolveArrayPathAndProxy(self, pathOrProxy)

	const meta: ProxyManagerModule.ProxyMetadata = proxyManager:GetMetadata(proxy)
	const array = proxyManager:GetOriginal(meta.Original)
	assert(type(array) == "table", "Target is not a table")

	const index = table.find(array, valueToFind)
	if index == nil then
		return nil
	end

	self:ArraySwapRemove(pathOrProxy, index)
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
	if self._batchDepth > 0 then
		return -- Already suspended; nested Suspend is a no-op
	end
	-- Capture the pre-batch snapshot BEFORE suspending ChangeDetector so that
	-- CheckForChanges at flush time can diff old-vs-current correctly.
	-- `CaptureSnapshot` inside `ChangeDetector` returns a sentinel (O(1)) so no
	-- snapshot/diff work is done during the window. Array ops are logged to an
	-- `ArrayBatchRecorder` instead of firing immediately.
	self._batch = {
		Recorder = ArrayBatchRecorderModule.new(),
		StartSnapshot = self._changeDetector:CaptureSnapshot(self._originalData, {}),
		TrackedPaths = {},
		DirtyBranches = {},
		Flushing = false,
	}
	self._batchDepth = 1
	self._changeDetector:Suspend()
end

--[=[
	Resumes after `Suspend()` and flushes all pending changes.

	Flush is two-phase:
	1. **Non-array flush** — `ChangeDetector:CheckForChanges` replays the full
	   pre-batch snapshot diff, firing all non-array change events.
	2. **Array flush** — For each tracked array path, routes through Branch A
	   (LCS `ArrayDiff.emitDiff`) when the op log is poisoned or the array
	   reference changed, or Branch B (`ArrayBatchRecorder:Coalesce`) otherwise.
]=]
function TableManager.Resume<T>(self: TM_Internal<T & { [any]: any }>)
	if self._batchDepth == 0 then
		return -- Not suspended
	end

	-- Re-enable ChangeDetector before the flush so CheckForChanges works normally.
	self._changeDetector:Resume()
	const batch = self._batch
	if not batch then
		self._batchDepth = 0
		return
	end
	batch.Flushing = true

	-- Non-array flush: diff only the branches that were actually mutated during
	-- the batch. This avoids traversing the whole table when only a small subset
	-- of keys changed. For each dirty branch key we extract the pre-batch value
	-- from the root snapshot's Diff.Snapshot children and compare it against the
	-- current live value, letting ChangeDetector fire all leaf + ancestor events.
	--
	-- The OnKey* callbacks suppress numeric-key events for tracked array paths so
	-- those are not double-fired by both the non-array and array flush phases.
	if batch.StartSnapshot then
		const rootSnapshot = batch.StartSnapshot
		const rootSnapshotData: any = rootSnapshot.Data -- Diff.Snapshot

		for branchKey in batch.DirtyBranches do
			if branchKey == "__root__" then
				-- Root-level scalar assignment: just diff the whole root (rare).
				self._changeDetector:CheckForChanges(rootSnapshot)
				continue
			end

			-- Extract old branch value from the pre-batch snapshot's children map.
			const oldBranchValue: any = if rootSnapshotData and rootSnapshotData.children
				then (rootSnapshotData.children :: any)[branchKey]
						and (rootSnapshotData.children :: any)[branchKey].value
					or nil
				else nil

			-- Current live value for this branch.
			const newBranchValue: any = self._originalData[branchKey]

			self._changeDetector:CheckForChangesBetween(
				oldBranchValue,
				newBranchValue,
				{ branchKey },
				self._originalData
			)
		end
	end

	-- Array flush: emit coalesced events for each tracked array path.
	const recorder = batch.Recorder
	if recorder then
		for _, path in batch.TrackedPaths do
			const log = recorder:GetLog(path)
			if not log then
				continue
			end

			const currentArray = self:Get(path)
			if type(currentArray) ~= "table" then
				continue
			end

			-- Get the old array from the pre-batch snapshot (always authoritative for
			-- Branch A; Branch B uses log.startCopy built at StartTracking time).
			const oldArray: { any } = getSnapshotValue(batch.StartSnapshot, path) or {}
			const emit = makeEmit(self, path)

			if log.poisoned or currentArray ~= log.startRef then
				-- Branch A: LCS diff — pre-batch snapshot vs current state
				ArrayDiffModule.emitDiff(oldArray, currentArray, emit, true)
			else
				-- Branch B: op-log coalescer — net-change semantics with intent honoured
				recorder:Coalesce(log, currentArray, emit, true)
			end
		end
	end

	-- Clear batch state
	batch.Flushing = false
	self._batchDepth = 0
	batch.Recorder:Destroy()
	self._batch = nil
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

	const sourceValue: ValueAtPath<T, S1> = self:Get(sourcePath)
	if type(sourceValue) ~= "table" then
		error("MoveTo source must be a table")
	end

	const targetParentPath, targetKey = PathHelpers.GetPathParentAndKey(targetPath)
	const targetParentOriginal = getParentOriginalAtPath(self, targetParentPath, "MoveTo")

	const existingProxy: Proxy<T, S1> = self._proxyManager:GetProxyFromOriginal(sourceValue)
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
function TableManager.Swap<T>(self: TM_Internal<T>, a: Path | Proxy<T>, b: Path<T> | Proxy<T>)
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

	const proxyA: Proxy<any>? = if type(valueA) == "table" then self._proxyManager:GetProxyFromOriginal(valueA) else nil
	const proxyB: Proxy<any>? = if type(valueB) == "table" then self._proxyManager:GetProxyFromOriginal(valueB) else nil
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
function TableManager.ForceNotify(self: TM_Internal, path: Path)
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
		const parentPath = {}
		for i = 1, #parsedPath - 1 do
			table.insert(parentPath, parsedPath[i])
		end
		fireAncestorValueChangedNotifications(self, parentPath, metadata, false)
	end
end

--[=[
	Destroy the TableManager and clean up all resources.
]=]
function TableManager.Destroy(self: TM_Internal)
	if self._Destroyed then
		return
	end
	self._Destroyed = true
	self._listenerRegistry:Destroy()
	self._proxyManager:Destroy()

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
