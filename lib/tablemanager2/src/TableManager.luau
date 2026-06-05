--!strict
--[=[
	@class TableManager_new
	
	Clean implementation of TableManager following the unified architecture.
	
	## Architecture
	
	Orchestrates three subsystems:
	1. **ProxyManager_new**: Manages proxies and delegates to ChangeDetector
	2. **ChangeDetector**: Single source of truth for change detection
	3. **ListenerRegistry_new**: Path-based listeners with DescendantChanges filtering
	
	## Key Features
	
	- **Unified change detection**: All changes flow through ChangeDetector
	- **Signals fire once**: Per actual leaf change (only when metadata.Diff exists AND type != "descendantChanged")
	- **Listeners fire appropriately**: ChangeDetector handles ancestor propagation
	- **No double propagation**: Uses FireListenersExact to prevent duplicate notifications
	- **FireOnDescendantChanges filtering**: Optional control over descendant notifications
	- **Array operations with ancestors**: Insert/Remove notify parent paths
	
	## Callback Classification
	
	ChangeDetector provides metadata to distinguish callback types:
	
	**Leaf Callbacks** (direct value changes):
	- `metadata.Diff != nil AND metadata.Diff.type != "descendantChanged"`
	- Types: "added", "removed", "changed"
	- Signals fire for these
	
	**Ancestor Callbacks** (container affected by descendant):
	- `metadata.Diff == nil OR metadata.Diff.type == "descendantChanged"`
	- Signals do NOT fire for these
	- Listeners receive these if they want ancestor notifications
	
	## Ancestor Propagation Strategy
	
	**ChangeDetector** is responsible for ancestor propagation:
	- When a change occurs, it fires callbacks for the leaf change AND all ancestors
	- Each callback includes metadata indicating if it's a direct change (Diff present) or ancestor (Diff nil)
	
	**TableManager** uses `FireListenersExact()`:
	- Fires listeners ONLY at the exact path ChangeDetector specifies
	- Prevents double propagation (ChangeDetector already walked ancestors)
	- Maintains performance benefits of the tree structure
	
	Example: Changing `{"players", "John", "Health"}`:
	- ChangeDetector fires: John.Health, John, players, root
	- Each fires listeners at that EXACT path only
	- Result: Clean, single notification per registered listener
	
	## Usage
	
	```lua
	const manager = TableManager.new({
		player = { health = 100, level = 5 },
		settings = { volume = 80 }
	})
	
	-- Listen to direct changes only
	manager:OnValueChange({"player"}, function(newValue, oldValue, metadata)
		if metadata.Diff then
			print("Player table replaced!")
		end
	end)
	
	-- Listen to all changes (including descendants)
	manager:OnValueChange({"player"}, function(newValue, oldValue, metadata)
		if metadata.Diff then
			print("Direct change to player")
		else
			print("Descendant changed at:", table.concat(metadata.OriginPath, "."))
		end
	end)
	
	-- Array operations with ancestor notifications
	manager:Insert({"player", "items"}, "Sword")
	```
]=]

--// Imports //--
const Signal = require("../Signal")
const T = require("../T")
const ProxyManagerModule = require("./ProxyManager")
const ListenerRegistryModule = require("./ListenerRegistry")
const ChangeDetectorModule = require("./ChangeDetector")
const PathHelpers = require("./PathHelpers")
const ArrayBatchRecorderModule = require("./ArrayBatchRecorder")
const ArrayDiffModule = require("./ArrayDiff")
const Diff = require("./Diff")
const SchemaNavigatorModule = require("./SchemaNavigator")

--// Types //--
type Path = PathHelpers.Path
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
	TrackedPaths: { [string]: Path },
	DirtyBranches: { [any]: boolean },
	Flushing: boolean,
}

export type Proxy<T> = ProxyManagerModule.Proxy<T>

export type DuplicateReferenceMode = "error" | "warn" | "allow" | "move" | "copy"

export type TableManagerConfig = {
	Schema: SchemaCheck?,
	OnValidationFailed: ((path: Path, value: any, err: string) -> ())?,
	ListenersFireDeferred: boolean?,
	DuplicateReferenceMode: DuplicateReferenceMode?, -- Experimental
}

export type TableManager<T = { [any]: any }> = {
	Proxy: Proxy<T>,
	Raw: T,

	-- Signals (fire once per change)
	ValueChanged: Signal<(path: Path, newValue: any, oldValue: any?) -> (), Path, any, any?>,
	KeyAdded: Signal<(path: Path, key: any, newValue: any) -> (), Path, any, any>,
	KeyRemoved: Signal<(path: Path, key: any, oldValue: any) -> (), Path, any, any>,
	KeyChanged: Signal<(path: Path, key: any, newValue: any, oldValue: any) -> (), Path, any, any, any>,
	ArrayInserted: Signal<(path: Path, index: number, newValue: any) -> (), Path, number, any>,
	ArrayRemoved: Signal<(path: Path, index: number, oldValue: any) -> (), Path, number, any>,
	ArraySet: Signal<(path: Path, index: number, newValue: any, oldValue: any) -> (), Path, number, any, any>,

	-- Listener registration (fire for ancestors/descendants)
	OnValueChange: (
		self: TableManager<T>,
		path: Path,
		callback: (newValue: any, oldValue: any?, metadata: ChangeMetadata) -> (),
		options: ListenerOptions?
	) -> Connection,
	OnKeyAdd: (
		self: TableManager<T>,
		path: Path,
		callback: (newValue: any, metadata: ChangeMetadata) -> (),
		options: ListenerOptions?
	) -> Connection,
	OnKeyRemove: (
		self: TableManager<T>,
		path: Path,
		callback: (key: any, oldValue: any, metadata: ChangeMetadata) -> (),
		options: ListenerOptions?
	) -> Connection,
	OnKeyChange: (
		self: TableManager<T>,
		path: Path,
		callback: (key: any, newValue: any, oldValue: any, metadata: ChangeMetadata) -> (),
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
	Get: (self: TableManager<T>, path: Path) -> any,
	GetProxy: (self: TableManager<T>, path: Path) -> Proxy<any> | any,
	Set: (self: TableManager<T>, path: Path, value: any) -> (),
	ArrayInsert: (self: TableManager<T>, arr: Path | Proxy<any>, newValue: any) -> ()
		& (self: TableManager<T>, arr: Path | Proxy<any>, index: number, newValue: any) -> (),
	ArrayRemove: (self: TableManager<T>, arr: Path | Proxy<any>, index: number) -> any,
	MoveTo: (self: TableManager<T>, currentPath: Path | Proxy<any>, newPath: Path | Proxy<any>) -> (),
	CopyTo: (self: TableManager<T>, currentPath: Path | Proxy<any>, newPath: Path) -> (),
	Swap: (self: TableManager<T>, a: Path | Proxy<any>, b: Path | Proxy<any>) -> (),
	ForceNotify: (self: TableManager<T>, path: Path) -> (),
	Batch: (self: TableManager<T>, fn: () -> ()) -> (),
	--- Manually suspend signal/listener firing. Pair with `Resume()` to flush.
	Suspend: (self: TableManager<T>) -> (),
	--- Resume after `Suspend()`. Flushes all pending changes.
	Resume: (self: TableManager<T>) -> (),
	Destroy: (self: TableManager<T>) -> (),

	-- Private
	_validateWrite: (self: TableManager<T>, path: Path, value: any) -> (boolean, string?),
	_makeEmit: (self: TableManager<T>, path: Path) -> any,
	_proxyManager: ProxyManager,
	_listenerRegistry: ListenerRegistry,
	_changeDetector: ChangeDetector,
	_originalData: any,
	_schema: SchemaCheck?,
	_onValidationFailed: ((path: Path, value: any, err: string) -> ())?,
	_duplicateReferenceMode: DuplicateReferenceMode,
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

--[=[
	Creates a synthetic snapshot for array operations and ForceNotify.
	These operations bypass normal ChangeDetector flow, so we create a compatible
	Snapshot payload using Diff's canonical snapshot builder.
]=]
const function createSyntheticSnapshot(rootTable: any, path: Path, value: any)
	return {
		RootTable = rootTable,
		Path = path,
		Data = Diff.snapshot(value),
		Timestamp = os.clock(),
	}
end

-- Serializes a path to a string key for batch tracking.
-- Must match the serialization used by ArrayBatchRecorder.
local function serializeBatchPath(path: Path): string
	if #path == 0 then
		return "__root__"
	end
	const parts = table.create(#path)
	for i, seg in path do
		parts[i] = tostring(seg)
	end
	return table.concat(parts, "\0")
end

-- Navigates a ChangeDetector Snapshot's Diff.Snapshot children and returns
-- the deep-copied value stored at `path` (i.e., the pre-batch state).
local function getSnapshotValue(snapshot: any, path: Path): any?
	local snap: any = snapshot.Data
	for _, key in path do
		if not snap or not snap.children then
			return nil
		end
		snap = snap.children[key]
	end
	return snap and snap.value or nil
end

local function pathToString(path: Path): string
	if #path == 0 then
		return "<root>"
	end
	const parts = table.create(#path)
	for i, segment in path do
		parts[i] = tostring(segment)
	end
	return table.concat(parts, ".")
end

local function resolvePathFromPathOrProxy(self: TableManager, pathOrProxy: Path | Proxy<any>): Path
	if self._proxyManager:IsProxy(pathOrProxy) then
		const proxy = pathOrProxy :: Proxy<any>
		const potentialPath = self._proxyManager:GetPath(proxy)
		assert(potentialPath, "Proxy does not have a path")
		return potentialPath
	end
	return PathHelpers.ParsePath(pathOrProxy :: Path)
end

local function resolveArrayPathAndProxy(self: TableManager, pathOrProxy: Path | Proxy<{ any }>): (Path, Proxy<{ any }>)
	if self._proxyManager:IsProxy(pathOrProxy) then
		const proxy = pathOrProxy :: Proxy<{ any }>
		const parsedPath = resolvePathFromPathOrProxy(self, proxy)
		return parsedPath, proxy
	end

	const parsedPath = PathHelpers.ParsePath(pathOrProxy :: Path)
	const proxy = self:GetProxy(parsedPath) :: Proxy<{ any }>
	return parsedPath, proxy
end

local function arePathsEqual(a: Path, b: Path): boolean
	if #a ~= #b then
		return false
	end
	for i = 1, #a do
		if a[i] ~= b[i] then
			return false
		end
	end
	return true
end

local function isPrefixPath(prefix: Path, fullPath: Path): boolean
	if #prefix > #fullPath then
		return false
	end
	for i = 1, #prefix do
		if prefix[i] ~= fullPath[i] then
			return false
		end
	end
	return true
end

local function getPathParentAndKey(path: Path): (Path, any)
	local parentPath = table.clone(path)
	local key = table.remove(parentPath)
	assert(key ~= nil, "Path requires at least one segment")
	return parentPath, key
end

local function getParentOriginalAtPath(self: TableManager, parentPath: Path, opName: string): any
	local parentOriginal: any = if #parentPath == 0 then self._originalData else self:Get(parentPath)
	if type(parentOriginal) ~= "table" then
		error(`{opName} destination parent must be a table`)
	end
	return parentOriginal
end

local function deepCloneValue(value: any, seen: { [any]: any }?): any
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

local function fireAncestorValueChangedNotifications(
	manager: TableManager,
	basePath: Path,
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

local function fireArrayOperation(
	manager: TableManager,
	eventName: "ArrayInserted" | "ArrayRemoved" | "ArraySet",
	basePath: Path,
	leafPath: Path,
	payload: any
)
	manager._listenerRegistry:FireListenersExact(eventName, leafPath, payload)
	fireAncestorValueChangedNotifications(manager, basePath, payload.Metadata)
	if eventName == "ArrayInserted" then
		manager.ArrayInserted:Fire(basePath, payload.Index, payload.NewValue)
	elseif eventName == "ArrayRemoved" then
		manager.ArrayRemoved:Fire(basePath, payload.Index, payload.OldValue)
	elseif eventName == "ArraySet" then
		manager.ArraySet:Fire(basePath, payload.Index, payload.NewValue, payload.OldValue)
	end
end

--[=[
	Creates a new TableManager instance.
]=]
function TableManager.new<T>(initialData: T & { [any]: any }, config: TableManagerConfig?): TableManager<T>
	const self = setmetatable({} :: any, TableManager_MT) :: TableManager<T & { [any]: any }>
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
	self._proxyManager = ProxyManagerModule.new()
	self._listenerRegistry = ListenerRegistryModule.new {
		DebugMode = false,
		FireDeferred = resolvedConfig.ListenersFireDeferred == true,
	}

	-- Initialize signals (fire once per change)
	self.ValueChanged = Signal.new()
	self.KeyAdded = Signal.new()
	self.KeyRemoved = Signal.new()
	self.KeyChanged = Signal.new()
	self.ArrayInserted = Signal.new()
	self.ArrayRemoved = Signal.new()
	self.ArraySet = Signal.new()

	-- During batch array flush: suppress numeric-key events on tracked array paths.
	-- Those arrays will emit their own coalesced events via the array flush.
	local function shouldSuppressBatchArrayKeyEvent(path: Path, key: any): boolean
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
		OnKeyAdded = function(path: Path, key: any, newValue: any, metadata: ChangeMetadata)
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

		OnKeyRemoved = function(path: Path, key: any, oldValue: any, metadata: ChangeMetadata)
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

		OnKeyChanged = function(path: Path, key: any, newValue: any, oldValue: any, metadata: ChangeMetadata)
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

		OnValueChanged = function(path: Path, newValue: any, oldValue: any?, metadata: ChangeMetadata)
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
		self._proxyManager:SetValidateCallback(function(path: Path, value: any): (boolean, string?)
			return self:_validateWrite(path, value)
		end)
	end

	-- Wire up array append callback
	self._proxyManager:SetArrayInsertedCallback(function(path: Path, index: number, newValue: any)
		-- During batch: log the insert and skip fires.
		-- The element is already appended to the original table at this point, so we
		-- reconstruct the pre-append array (original[1..index-1]) for StartTracking.
		if self._batchDepth > 0 then
			const batch = self._batch
			if batch then
				const recorder = batch.Recorder
				const pathKey = serializeBatchPath(path)
				if not batch.TrackedPaths[pathKey] then
					batch.TrackedPaths[pathKey] = table.clone(path)
					-- Build a pre-append shallow copy: original[1..index-1]
					const original = self:Get(path)
					const preBatch: { any } = table.create(index - 1)
					for i = 1, index - 1 do
						preBatch[i] = original[i]
					end
					recorder:StartTracking(path, preBatch)
				end
				recorder:RecordInsert(path, index, newValue)
			end
			-- Mark this top-level branch as dirtied
			const branchKey: any = if #path > 0 then path[1] else "__root__"
			if batch then
				batch.DirtyBranches[branchKey] = true
			end
			return
		end

		-- Create synthetic metadata for array append
		const insertPath = table.clone(path)
		table.insert(insertPath, index)

		const metadata: ChangeMetadata = {
			Diff = { type = "added", new = newValue, old = nil, key = index },
			OriginPath = insertPath,
			OriginDiff = { type = "added", new = newValue, old = nil, key = index },
			Snapshot = createSyntheticSnapshot(self._originalData, insertPath, newValue),
		}

		-- Fire listeners at inserted element's path ONLY (we handle ancestors separately)
		fireArrayOperation(self, "ArrayInserted", path, insertPath, {
			Index = index,
			NewValue = newValue,
			Metadata = metadata,
		})
	end)

	-- Wire up direct numeric-index write callback (for batch poisoning)
	self._proxyManager:SetBatchDirectArraySetCallback(function(path: Path, _index: number)
		if self._batchDepth > 0 then
			const batch = self._batch
			if batch then
				const recorder = batch.Recorder
				const pathKey = serializeBatchPath(path)
				if not batch.TrackedPaths[pathKey] then
					batch.TrackedPaths[pathKey] = table.clone(path)
					-- StartTracking with the post-mutation array; Branch A will use
					-- _batchStartSnapshot for the true pre-batch state anyway.
					const current = self:Get(path)
					if type(current) == "table" then
						recorder:StartTracking(path, current)
					end
				end
				recorder:MarkPoisoned(path)
			end
		end
	end)

	-- Track which top-level branches are dirtied by non-array scalar writes.
	-- `parentPath` is the path of the proxy table that owns the written key.
	-- The branch key is `parentPath[1]` (or "__root__" for root-level writes).
	self._proxyManager:SetBatchScalarWrittenCallback(function(parentPath: Path)
		if self._batchDepth > 0 then
			const branchKey: any = if #parentPath > 0 then parentPath[1] else "__root__"
			if self._batch then
				self._batch.DirtyBranches[branchKey] = true
			end
		end
	end)

	local isMoveInProgress = false
	self._proxyManager:SetDuplicateTableWriteCallback(function(writePath: Path, existingPath: Path, value: any): boolean
		if self._duplicateReferenceMode == "allow" then
			return true
		end

		const writePathStr = pathToString(writePath)
		const existingPathStr = pathToString(existingPath)
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
	end)

	-- Create root proxy (no parent, no key)
	self.Proxy = self._proxyManager:CreateProxy(self._originalData, nil, nil, nil, nil)

	return self
end

function TableManager._validateWrite(self: TableManager, path: Path, value: any): (boolean, string?)
	if not self._schema then
		return true :: any
	end

	const ok, err = SchemaNavigatorModule.Validate(self._schema, path, value)
	if ok then
		return true :: any
	end

	const message = err or `Schema validation failed at {pathToString(path)}`
	if self._onValidationFailed then
		self._onValidationFailed(path, value, message)
		return false, nil
	end

	return false, message
end
--------------------------------------------------------------------------------
--// Listener Registration //--
--------------------------------------------------------------------------------

function TableManager.OnValueChange(
	self: TableManager,
	path: Path,
	callback: (newValue: any, oldValue: any?, metadata: ChangeMetadata) -> (),
	options: ListenerOptions?
): Connection
	return self._listenerRegistry:RegisterListener("ValueChanged", PathHelpers.ParsePath(path), callback, options)
end

function TableManager.OnKeyAdd(
	self: TableManager,
	path: Path,
	callback: (newValue: any, metadata: ChangeMetadata) -> (),
	options: ListenerOptions?
): Connection
	return self._listenerRegistry:RegisterListener("KeyAdded", PathHelpers.ParsePath(path), callback, options)
end

function TableManager.OnKeyRemove(
	self: TableManager,
	path: Path,
	callback: (oldValue: any, metadata: ChangeMetadata) -> (),
	options: ListenerOptions?
): Connection
	return self._listenerRegistry:RegisterListener("KeyRemoved", PathHelpers.ParsePath(path), callback, options)
end

function TableManager.OnKeyChange(
	self: TableManager,
	path: Path,
	callback: (key: any, newValue: any, oldValue: any, metadata: ChangeMetadata) -> (),
	options: ListenerOptions?
): Connection
	return self._listenerRegistry:RegisterListener("KeyChanged", PathHelpers.ParsePath(path), callback, options)
end

function TableManager.OnArrayInsert(
	self: TableManager,
	path: Path,
	callback: (index: number, newValue: any, metadata: ChangeMetadata) -> (),
	options: ListenerOptions?
): Connection
	return self._listenerRegistry:RegisterListener("ArrayInserted", PathHelpers.ParsePath(path), callback, options)
end

function TableManager.OnArrayRemove(
	self: TableManager,
	path: Path,
	callback: (index: number, oldValue: any, metadata: ChangeMetadata) -> (),
	options: ListenerOptions?
): Connection
	return self._listenerRegistry:RegisterListener("ArrayRemoved", PathHelpers.ParsePath(path), callback, options)
end

function TableManager.OnArraySet(
	self: TableManager,
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
function TableManager.Get(self: TableManager, path: Path, suppressNilPartialPaths: boolean?): any?
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
function TableManager.GetProxy(self: TableManager, path: Path, suppressNilPartialPaths: boolean?): (Proxy<any> | any)?
	const parsedPath = PathHelpers.ParsePath(path)
	local current = self.Proxy
	for _, key in parsedPath do
		if not self._proxyManager:IsProxy(current) then
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
	Set the value at a path.
]=]
function TableManager.Set(self: TableManager, path: Path, value: any, buildTablesDynamically: boolean?)
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
function TableManager.ArrayInsert(self: TableManager, pathOrProxy: Path | Proxy<{ any }>, ...: any): ()
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
					const message = err or `Schema validation failed at {pathToString(parsedPath)}`
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
		const pathKey = serializeBatchPath(parsedPath)
		if not batch.TrackedPaths[pathKey] then
			batch.TrackedPaths[pathKey] = table.clone(parsedPath)
			batch.Recorder:StartTracking(parsedPath, array)
		end
		-- Mark this top-level branch as dirtied
		const branchKey: any = if #parsedPath > 0 then parsedPath[1] else "__root__"
		batch.DirtyBranches[branchKey] = true
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
	const insertPath = table.clone(parsedPath)
	table.insert(insertPath, pos)

	const metadata: ChangeMetadata = {
		Diff = { type = "added", new = unwrappedValue, old = nil, key = pos },
		OriginPath = insertPath,
		OriginDiff = { type = "added", new = unwrappedValue, old = nil, key = pos },
		Snapshot = createSyntheticSnapshot(self._originalData, insertPath, unwrappedValue),
	}

	-- Fire listeners EXACTLY at insert path (we handle ancestors separately)
	self._listenerRegistry:FireListenersExact("ArrayInserted", insertPath, {
		Index = pos,
		NewValue = unwrappedValue,
		Metadata = metadata,
	})

	-- Fire ancestor callbacks manually
	fireAncestorValueChangedNotifications(self, parsedPath, metadata)

	-- Fire signal ONCE
	self.ArrayInserted:Fire(parsedPath, pos, unwrappedValue)

	-- Update metadata
	meta.ArrayLength = #array
end
TableManager.Insert = TableManager.ArrayInsert

--[=[
	Remove an element from an array at a specific index.
]=]
function TableManager.ArrayRemove(self: TableManager, pathOrProxy: Path | Proxy<{ any }>, index: number): any
	const proxyManager = self._proxyManager
	local parsedPath, proxy = resolveArrayPathAndProxy(self, pathOrProxy)

	const meta: ProxyManagerModule.ProxyMetadata = self._proxyManager:GetMetadata(proxy)
	const array = proxyManager:GetOriginal(meta.Original)
	assert(type(array) == "table", "Target is not a table")

	-- Batch: start tracking and log the removal BEFORE mutating, so that
	-- _computeLiveIds in RecordRemove sees the correct pre-removal id sequence.
	if self._batchDepth > 0 and self._batch then
		const batch = self._batch
		const pathKey = serializeBatchPath(parsedPath)
		if not batch.TrackedPaths[pathKey] then
			batch.TrackedPaths[pathKey] = table.clone(parsedPath)
			batch.Recorder:StartTracking(parsedPath, array)
		end
		batch.Recorder:RecordRemove(parsedPath, index)
		-- Mark this top-level branch as dirtied
		const branchKey: any = if #parsedPath > 0 then parsedPath[1] else "__root__"
		batch.DirtyBranches[branchKey] = true
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
	const removePath = table.clone(parsedPath)
	table.insert(removePath, index)

	local metadata: ChangeMetadata = {
		Diff = { type = "removed", new = nil, old = oldValue, key = index },
		OriginPath = removePath,
		OriginDiff = { type = "removed", new = nil, old = oldValue, key = index },
		Snapshot = createSyntheticSnapshot(self._originalData, removePath, nil),
	}

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
	Holds off firing signals for the duration of the callback, then fires needed signals at the end.
	Useful for batch operations where you want to suppress intermediate signals and only fire final results.

	Nested calls are no-ops: the outermost Batch window covers everything.

	The callback must not yield.
]=]
function TableManager.Batch(self: TableManager, fn: () -> ())
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

	`CaptureSnapshot` inside `ChangeDetector` returns a sentinel (O(1)) so no
	snapshot/diff work is done during the window. Array ops are logged to an
	`ArrayBatchRecorder` instead of firing immediately.

	Pair with `Resume()`. Nested calls are no-ops (the outermost window wins).
]=]
function TableManager.Suspend(self: TableManager)
	if self._batchDepth > 0 then
		return -- Already suspended; nested Suspend is a no-op
	end
	-- Capture the pre-batch snapshot BEFORE suspending ChangeDetector so that
	-- CheckForChanges at flush time can diff old-vs-current correctly.
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
function TableManager.Resume(self: TableManager)
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
				then (rootSnapshotData.children[branchKey] and rootSnapshotData.children[branchKey].value or nil)
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
			const emit = self:_makeEmit(path)

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
	@private
	Builds the `Emit` interface for a single array path, wiring the three
	callbacks to fire `ArrayRemoved` / `ArrayInserted` / `ArraySet` signals,
	exact-path listeners, and ancestor callbacks in the correct order.
]=]
function TableManager._makeEmit(self: TableManager, path: Path)
	return {
		removed = function(index: number, oldValue: any)
			const removedPath = table.clone(path)
			table.insert(removedPath, index)
			const metadata: ChangeMetadata = {
				Diff = { type = "removed", new = nil, old = oldValue, key = index },
				OriginPath = removedPath,
				OriginDiff = { type = "removed", new = nil, old = oldValue, key = index },
				Snapshot = createSyntheticSnapshot(self._originalData, removedPath, nil),
			}
			fireArrayOperation(self, "ArrayRemoved", path, removedPath, {
				Index = index,
				OldValue = oldValue,
				Metadata = metadata,
			})
		end,
		inserted = function(index: number, newValue: any)
			const insertedPath = table.clone(path)
			table.insert(insertedPath, index)
			const metadata: ChangeMetadata = {
				Diff = { type = "added", new = newValue, old = nil, key = index },
				OriginPath = insertedPath,
				OriginDiff = { type = "added", new = newValue, old = nil, key = index },
				Snapshot = createSyntheticSnapshot(self._originalData, insertedPath, newValue),
			}
			fireArrayOperation(self, "ArrayInserted", path, insertedPath, {
				Index = index,
				NewValue = newValue,
				Metadata = metadata,
			})
		end,
		set = function(index: number, newValue: any, oldValue: any)
			const setPath = table.clone(path)
			table.insert(setPath, index)
			const metadata: ChangeMetadata = {
				Diff = { type = "changed", new = newValue, old = oldValue, key = index },
				OriginPath = setPath,
				OriginDiff = { type = "changed", new = newValue, old = oldValue, key = index },
				Snapshot = createSyntheticSnapshot(self._originalData, setPath, newValue),
			}
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
	Move an element from one location to another within the same table.
	This unsets the value at the current path and sets it at the new path, firing appropriate notifications.
	This is specifically useful for moving tables around without breaking proxy references.
]=]
function TableManager.MoveTo(self: TableManager, currentPath: Path | Proxy<any>, newPath: Path | Proxy<any>)
	const sourcePath = resolvePathFromPathOrProxy(self, currentPath)
	const targetPath = resolvePathFromPathOrProxy(self, newPath)

	if #sourcePath == 0 or #targetPath == 0 then
		error("MoveTo cannot move the root table")
	end

	if arePathsEqual(sourcePath, targetPath) then
		return
	end

	if isPrefixPath(sourcePath, targetPath) then
		error("MoveTo cannot move a table into one of its descendants")
	end

	const sourceValue = self:Get(sourcePath)
	if type(sourceValue) ~= "table" then
		error("MoveTo source must be a table")
	end

	const targetParentPath, targetKey = getPathParentAndKey(targetPath)
	const targetParentOriginal = getParentOriginalAtPath(self, targetParentPath, "MoveTo")

	const existingProxy = self._proxyManager:GetProxyFromOriginal(sourceValue)
	local oldParent: any? = nil
	local oldKey: any? = nil
	if existingProxy ~= nil then
		const existingMeta = self._proxyManager:GetMetadata(existingProxy)
		if existingMeta ~= nil then
			oldParent = existingMeta.Parent
			oldKey = existingMeta.Key
		end
		self._proxyManager:ReparentProxy(existingProxy, targetParentOriginal, targetKey)
	end

	const ok, moveErr = pcall(function()
		self:Batch(function()
			self:Set(targetPath, sourceValue)
			self:Set(sourcePath, nil)
		end)
	end)

	if not ok then
		if existingProxy ~= nil then
			self._proxyManager:ReparentProxy(existingProxy, oldParent, oldKey)
		end
		error(moveErr, 2)
	end
end

--[=[
	DeepCopy a value from one location to another within the same table.
	This sets the value at the new path to be the same as the value at the current path, firing appropriate notifications.
	This is specifically useful for copying tables around without breaking proxy references.
]=]
function TableManager.CopyTo(self: TableManager, currentPath: Path | Proxy<any>, newPath: Path)
	const sourcePath = resolvePathFromPathOrProxy(self, currentPath)
	const targetPath = resolvePathFromPathOrProxy(self, newPath)

	if #targetPath == 0 then
		error("CopyTo cannot set the root table")
	end

	if arePathsEqual(sourcePath, targetPath) then
		return
	end

	-- Validate destination parent before any mutation.
	const targetParentPath = table.clone(targetPath)
	table.remove(targetParentPath)
	getParentOriginalAtPath(self, targetParentPath, "CopyTo")

	const sourceValue = self:Get(sourcePath)
	const copiedValue = deepCloneValue(sourceValue)

	self:Batch(function()
		self:Set(targetPath, copiedValue)
	end)
end

--[=[
	Swap values at two paths within the same TM.
]=]
function TableManager.Swap(self: TableManager, a: Path | Proxy<any>, b: Path | Proxy<any>)
	const pathA = resolvePathFromPathOrProxy(self, a)
	const pathB = resolvePathFromPathOrProxy(self, b)

	if #pathA == 0 or #pathB == 0 then
		error("Swap cannot target the root table")
	end

	if arePathsEqual(pathA, pathB) then
		return
	end

	if isPrefixPath(pathA, pathB) or isPrefixPath(pathB, pathA) then
		error("Swap cannot swap ancestor/descendant paths")
	end

	const parentPathA, keyA = getPathParentAndKey(pathA)
	const parentPathB, keyB = getPathParentAndKey(pathB)
	const parentOriginalA = getParentOriginalAtPath(self, parentPathA, "Swap")
	const parentOriginalB = getParentOriginalAtPath(self, parentPathB, "Swap")

	const valueA = self:Get(pathA)
	const valueB = self:Get(pathB)

	const proxyA = if type(valueA) == "table" then self._proxyManager:GetProxyFromOriginal(valueA) else nil
	const proxyB = if type(valueB) == "table" then self._proxyManager:GetProxyFromOriginal(valueB) else nil

	local oldParentA: any? = nil
	local oldKeyA: any? = nil
	if proxyA ~= nil then
		const metaA = self._proxyManager:GetMetadata(proxyA)
		if metaA ~= nil then
			oldParentA = metaA.Parent
			oldKeyA = metaA.Key
		end
		self._proxyManager:ReparentProxy(proxyA, parentOriginalB, keyB)
	end

	local oldParentB: any? = nil
	local oldKeyB: any? = nil
	if proxyB ~= nil then
		const metaB = self._proxyManager:GetMetadata(proxyB)
		if metaB ~= nil then
			oldParentB = metaB.Parent
			oldKeyB = metaB.Key
		end
		self._proxyManager:ReparentProxy(proxyB, parentOriginalA, keyA)
	end

	const ok, swapErr = pcall(function()
		self:Batch(function()
			self:Set(pathA, valueB)
			self:Set(pathB, valueA)
		end)
	end)

	if not ok then
		if proxyA ~= nil then
			self._proxyManager:ReparentProxy(proxyA, oldParentA, oldKeyA)
		end
		if proxyB ~= nil then
			self._proxyManager:ReparentProxy(proxyB, oldParentB, oldKeyB)
		end
		error(swapErr, 2)
	end
end

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
function TableManager.ForceNotify(self: TableManager, path: Path)
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
function TableManager.Destroy(self: TableManager)
	self._proxyManager:Destroy()
	self._listenerRegistry:Destroy()

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
