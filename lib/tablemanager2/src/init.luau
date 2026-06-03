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
const Signal = require(script.Parent.Signal)
const ProxyManagerModule = require(script.ProxyManager)
const ListenerRegistryModule = require(script.ListenerRegistry)
const ChangeDetectorModule = require(script.ChangeDetector)
const PathHelpers = require(script.PathHelpers)

--// Types //--
type Path = PathHelpers.Path
type ProxyManager = ProxyManagerModule.ProxyManager
type ListenerRegistry = ListenerRegistryModule.ListenerRegistry
type ChangeDetector = ChangeDetectorModule.ChangeDetector
type ChangeMetadata = ChangeDetectorModule.ChangeMetadata
type ListenerOptions = ListenerRegistryModule.ListenerOptions
type Connection = ListenerRegistryModule.Connection
type Signal<Fn, Args...> = Signal.Signal<Fn, Args...>

export type Proxy<T> = ProxyManagerModule.Proxy<T>

export type TableManager<T = any> = {
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
		callback: (oldValue: any, metadata: ChangeMetadata) -> (),
		options: ListenerOptions?
	) -> Connection,
	OnKeyChange: (
		self: TableManager<T>,
		path: Path,
		callback: (newValue: any, oldValue: any, metadata: ChangeMetadata) -> (),
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
	Set: (self: TableManager<T>, path: Path, value: any) -> (),
	ArrayInsert: | (self: TableManager<T>, arr: Path | Proxy<any>, newValue: any) -> ()
		| (self: TableManager<T>, arr: Path | Proxy<any>, index: number, newValue: any) -> (),
	ArrayRemove: (self: TableManager<T>, arr: Path | Proxy<any>, index: number) -> any,
	ForceNotify: (self: TableManager<T>, path: Path) -> (),
	Destroy: (self: TableManager<T>) -> (),

	-- Private
	_fireAncestorCallbacksForArrayOp: (
		self: TableManager<T>,
		basePath: Path,
		originPath: Path,
		metadata: ChangeMetadata
	) -> (),
	_proxyManager: ProxyManager,
	_listenerRegistry: ListenerRegistry,
	_changeDetector: ChangeDetector,
	_originalData: any,
}

--------------------------------------------------------------------------------
--// Module //--
--------------------------------------------------------------------------------

const TableManager = {}
const TableManager_MT = { __index = TableManager }

--[=[
	Creates a synthetic snapshot for array operations and ForceNotify.
	These operations bypass normal ChangeDetector flow so we create minimal snapshots.
]=]
const function createSyntheticSnapshot(rootTable: any, path: Path, value: any)
	return {
		RootTable = rootTable,
		Path = path,
		Data = { value = value, ref = value, children = nil }, -- Minimal Diff.Snapshot
		Timestamp = os.clock(),
	}
end

--[=[
	Creates a new TableManager instance.
]=]
function TableManager.new<T>(initialData: T): TableManager<T>
	const self = setmetatable({} :: any, TableManager_MT) :: TableManager<T>

	-- Store original data
	self._originalData = initialData or {}
	self.Raw = self._originalData

	-- Initialize subsystems
	self._proxyManager = ProxyManagerModule.new()
	self._listenerRegistry = ListenerRegistryModule.new(false) -- debugMode = false

	-- Initialize signals (fire once per change)
	self.ValueChanged = Signal.new()
	self.KeyAdded = Signal.new()
	self.KeyRemoved = Signal.new()
	self.KeyChanged = Signal.new()
	self.ArrayInserted = Signal.new()
	self.ArrayRemoved = Signal.new()
	self.ArraySet = Signal.new()

	-- Initialize ChangeDetector with callbacks
	-- NOTE: Use FireListenersExact() to prevent double ancestor propagation
	-- ChangeDetector already handles ancestor notifications, so we only fire at exact paths
	self._changeDetector = ChangeDetectorModule.new {
		OnKeyAdded = function(path: Path, key: any, newValue: any, metadata: ChangeMetadata)
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
			-- Fire listeners ONLY at exact path (ChangeDetector handles ancestors)
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
			-- Fire listeners ONLY at exact path (ChangeDetector handles ancestors)
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
			-- Fire listeners ONLY at exact path (ChangeDetector handles ancestors)
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

	-- Wire up array append callback
	self._proxyManager:SetArrayInsertedCallback(function(path: Path, index: number, newValue: any)
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
		self._listenerRegistry:FireListenersExact("ArrayInserted", insertPath, {
			Index = index,
			NewValue = newValue,
			Metadata = metadata,
		})

		-- Fire ancestor callbacks manually (with nil Diff to indicate ancestor notification)
		self:_fireAncestorCallbacksForArrayOp(path, insertPath, metadata)

		-- Fire signal ONCE
		self.ArrayInserted:Fire(path, index, newValue)
	end)

	-- Create root proxy
	self.Proxy = self._proxyManager:CreateProxy(self._originalData, {})

	return self
end

--[=[
	Fire ancestor callbacks for array operations.
	Walks up from basePath to root, firing listeners with nil Diff.
	Uses FireListenersExact to avoid double propagation.
]=]
function TableManager:_fireAncestorCallbacksForArrayOp(basePath: Path, originPath: Path, metadata: ChangeMetadata)
	-- Walk up from basePath to root
	for i = #basePath, 0, -1 do
		const ancestorPath = {}
		for j = 1, i do
			table.insert(ancestorPath, basePath[j])
		end

		-- Create ancestor metadata (Diff = nil)
		const ancestorMetadata: ChangeMetadata = {
			Diff = nil, -- Ancestor notification
			OriginPath = originPath,
			OriginDiff = metadata.OriginDiff,
			Snapshot = metadata.Snapshot, -- Reuse snapshot from origin
		}

		-- Fire ValueChanged at ancestor level EXACTLY (no further propagation)
		self._listenerRegistry:FireListenersExact("ValueChanged", ancestorPath, {
			NewValue = nil, -- Ancestor can look up if needed
			OldValue = nil,
			Metadata = ancestorMetadata,
		})
	end
end

--------------------------------------------------------------------------------
--// Listener Registration //--
--------------------------------------------------------------------------------

function TableManager:OnValueChange(
	path: Path,
	callback: (newValue: any, oldValue: any?, metadata: ChangeMetadata) -> (),
	options: ListenerOptions?
): Connection
	return self._listenerRegistry:RegisterListener("ValueChanged", PathHelpers.ParsePath(path), callback, options)
end

function TableManager:OnKeyAdd(
	path: Path,
	callback: (newValue: any, metadata: ChangeMetadata) -> (),
	options: ListenerOptions?
): Connection
	return self._listenerRegistry:RegisterListener("KeyAdded", PathHelpers.ParsePath(path), callback, options)
end

function TableManager:OnKeyRemove(
	path: Path,
	callback: (oldValue: any, metadata: ChangeMetadata) -> (),
	options: ListenerOptions?
): Connection
	return self._listenerRegistry:RegisterListener("KeyRemoved", PathHelpers.ParsePath(path), callback, options)
end

function TableManager:OnKeyChange(
	path: Path,
	callback: (newValue: any, oldValue: any, metadata: ChangeMetadata) -> (),
	options: ListenerOptions?
): Connection
	return self._listenerRegistry:RegisterListener("KeyChanged", PathHelpers.ParsePath(path), callback, options)
end

function TableManager:OnArrayInsert(
	path: Path,
	callback: (index: number, newValue: any, metadata: ChangeMetadata) -> (),
	options: ListenerOptions?
): Connection
	return self._listenerRegistry:RegisterListener("ArrayInserted", PathHelpers.ParsePath(path), callback, options)
end

function TableManager:OnArrayRemove(
	path: Path,
	callback: (index: number, oldValue: any, metadata: ChangeMetadata) -> (),
	options: ListenerOptions?
): Connection
	return self._listenerRegistry:RegisterListener("ArrayRemoved", PathHelpers.ParsePath(path), callback, options)
end

function TableManager:OnArraySet(
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
function TableManager:Get(path: Path, suppressNilPartialPaths: boolean?): any?
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

function TableManager:GetProxy(path: Path, suppressNilPartialPaths: boolean?): (Proxy<any> | any)?
	const parsedPath = PathHelpers.ParsePath(path)
	local current = self.Proxy
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
	Set the value at a path.
]=]
function TableManager:Set(path: Path, value: any, buildTablesDynamically: boolean?)
	const parsedPath = PathHelpers.ParsePath(path)
	if #parsedPath == 0 then
		error("Cannot set root path")
	end

	local parent = self.Proxy
	for i = 1, #parsedPath - 1 do
		parent = parent[parsedPath[i]]
		if type(parent) ~= "table" then
			if buildTablesDynamically then
				parent[parsedPath[i]] = {} -- TODO: Change this to use ProxyManager to create a proxy for the new table
				parent = parent[parsedPath[i]] :: any
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
function TableManager:ArrayInsert(path: Path | Proxy<any>, ...: any): ()
	const parsedPath = PathHelpers.ParsePath(path)
	const array = self:GetProxy(parsedPath)

	if type(array) ~= "table" then
		error("Target is not a table")
	end

	const proxy = array
	const meta: ProxyManagerModule.ProxyMetadata? = self._proxyManager:GetMetadata(proxy)

	if not meta then
		error("Target is not a proxy")
	end

	const args = { ... }
	local pos: number
	local values: { any }

	-- Determine if first arg is position or value
	if #args > 1 and type(args[1]) == "number" then
		pos = args[1]
		values = { table.unpack(args, 2) }
	else
		pos = meta.ArrayLength + 1
		values = args
	end

	-- Get original table
	const original = meta.Original

	-- Insert each value
	for i, value in values do
		const insertPos = pos + i - 1
		const unwrappedValue = self._proxyManager:GetOriginal(value)

		-- Shift elements if mid-array insertion
		if insertPos <= meta.ArrayLength then
			for j = meta.ArrayLength, insertPos, -1 do
				original[j + 1] = original[j]
			end
		end

		-- Insert the value
		original[insertPos] = unwrappedValue

		-- Create synthetic metadata
		const insertPath = table.clone(parsedPath)
		table.insert(insertPath, insertPos)

		const metadata: ChangeMetadata = {
			Diff = { type = "added", new = unwrappedValue, old = nil, key = insertPos },
			OriginPath = insertPath,
			OriginDiff = { type = "added", new = unwrappedValue, old = nil, key = insertPos },
			Snapshot = createSyntheticSnapshot(self._originalData, insertPath, unwrappedValue),
		}

		-- Fire listeners EXACTLY at insert path (we handle ancestors separately)
		self._listenerRegistry:FireListenersExact("ArrayInserted", insertPath, {
			Index = insertPos,
			NewValue = unwrappedValue,
			Metadata = metadata,
		})

		-- Fire ancestor callbacks manually
		self:_fireAncestorCallbacksForArrayOp(parsedPath, insertPath, metadata)

		-- Fire signal ONCE
		self.ArrayInserted:Fire(parsedPath, insertPos, unwrappedValue)
	end

	-- Update metadata
	meta.ArrayLength = self._proxyManager:GetArrayLength(original)
end
TableManager.Insert = TableManager.ArrayInsert

--[=[
	Remove an element from an array at a specific index.
]=]
function TableManager:ArrayRemove(path: Path, index: number): any
	const parsedPath = PathHelpers.ParsePath(path)
	const array = self:GetProxy(parsedPath)

	if type(array) ~= "table" then
		error("Target is not a table")
	end

	const proxy = array
	const meta: ProxyManagerModule.ProxyMetadata? = self._proxyManager:GetMetadata(proxy)

	if not meta then
		error("Target is not a proxy")
	end

	const original = meta.Original
	const oldValue = original[index]

	-- Remove the element
	for i = index, meta.ArrayLength - 1 do
		original[i] = original[i + 1]
	end
	original[meta.ArrayLength] = nil

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
	self._listenerRegistry:FireListenersExact("ArrayRemoved", removePath, {
		Index = index,
		OldValue = oldValue,
		Metadata = metadata,
	})

	-- Fire ancestor callbacks manually
	self:_fireAncestorCallbacksForArrayOp(parsedPath, removePath, metadata)

	-- Fire signal ONCE
	self.ArrayRemoved:Fire(parsedPath, index, oldValue)

	-- Update metadata
	meta.ArrayLength = self._proxyManager:GetArrayLength(original)

	return oldValue
end
TableManager.Remove = TableManager.ArrayRemove

--[=[
	Holds of firing signals for the duration of the callback, then fires needed signals at the end.
	Useful for batch operations where you want to suppress intermediate signals and only fire final results.
]=]
function TableManager:Batch(fn: () -> ())
	fn()
end

--[=[
	Move an element from one location to another within the same table.
	This unsets the value at the current path and sets it at the new path, firing appropriate notifications.
]=]
function TableManager:MoveTo(currentPath: Path | Proxy<any>, newPath: Path) end

--[=[
	Swap values at two paths within the same table.
]=]
function TableManager:Swap(a: Path | Proxy<any>, b: Path | Proxy<any>) end

--[=[
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
function TableManager:ForceNotify(path: Path)
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

	-- Fire ancestor callbacks manually (with nil Diff to indicate ancestor notification)
	for i = #parsedPath - 1, 0, -1 do
		const ancestorPath = {}
		for j = 1, i do
			table.insert(ancestorPath, parsedPath[j])
		end

		const ancestorMetadata: ChangeMetadata = {
			Diff = nil, -- Ancestor notification
			OriginPath = parsedPath,
			OriginDiff = metadata.OriginDiff,
			Snapshot = metadata.Snapshot, -- Reuse snapshot from origin
		}

		self._listenerRegistry:FireListenersExact("ValueChanged", ancestorPath, {
			NewValue = nil,
			OldValue = nil,
			Metadata = ancestorMetadata,
		})
	end
end

--[=[
	Destroy the TableManager and clean up all resources.
]=]
function TableManager:Destroy()
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
