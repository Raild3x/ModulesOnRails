--!strict
--[=[
	@class ProxyManager_new
	
	Clean implementation of ProxyManager following the unified architecture.
	
	## Architecture
	
	### Unified Change Detection
	ProxyManager delegates ALL change detection to ChangeDetector:
	1. **Capture**: __newindex captures snapshot BEFORE write using CaptureSnapshot (returns snapshot object)
	2. **Apply**: Write unwrapped value to original table
	3. **Detect**: ChangeDetector.CheckForChanges(snapshot) compares new state against snapshot object
	4. **Result**: Single source of truth for all change detection
	
	**Special Case**: Array appends (key == length + 1) fire directly
	since they don't require complex diff logic.
	
	### Proxy Implementation
	Uses a weak table (PROXY_TO_ORIGINAL) to track proxies without polluting
	their key space or interfering with metamethods.
	
	### Shared Metatable
	All proxies share one metatable per TableManager instance for memory efficiency.
	Metadata is stored in `_proxyMeta` and looked up dynamically.
	
	### Metamethods
	- __index: Returns nested proxies for tables, raw values for scalars
	- __newindex: Captures snapshot → applies change → delegates to ChangeDetector
	- __eq: Allows proxy == proxy comparisons
	- __iter: Enables `for k, v in proxy do` iteration
	- __len: Returns array length
	- __tostring: Returns "TableManager.Data(path)"
	- __metatable: Protects metatable from external access
]=]

local PathHelpers = require("./PathHelpers")
type Path = PathHelpers.Path

--[=[
	Weak table mapping proxies to their original tables.
	This allows proxies to be garbage collected when no longer referenced.
]=]
local PROXY_TO_ORIGINAL = setmetatable({}, { __mode = "k" })

--[=[
	Check if a value is a proxy by looking it up in the weak table.
]=]
local function isProxy(t: any): boolean
	return type(t) == "table" and PROXY_TO_ORIGINAL[t] ~= nil
end

--[=[
	Get the original (unwrapped) table from a proxy.
	If the input is not a proxy, returns it unchanged.
]=]
local function getOriginal<T>(t: T | Proxy<T>): T
	if isProxy(t) then
		return PROXY_TO_ORIGINAL[t] :: any
	end
	return t
end

--[=[
	Check if a table is an array (contiguous numeric keys starting at 1).
]=]
local function isArray(t: { [any]: any }): boolean
	if type(t) ~= "table" then
		return false
	end

	local count = 0
	local maxIndex = 0

	for key, _ in t do
		if type(key) ~= "number" or key < 1 or key % 1 ~= 0 then
			return false
		end
		count += 1
		maxIndex = math.max(maxIndex, key)
	end

	return count == maxIndex
end

--[=[
	Get the length of an array (highest numeric index).
]=]
local function getArrayLength(t: { [any]: any }): number
	local length = 0
	for key, _ in t do
		if type(key) == "number" and key > length then
			length = key
		end
	end
	return length
end

--// Types //--

--[=[
	A proxy wraps a table and intercepts read/write operations.
]=]
export type Proxy<T = { [any]: any }> = T & { __proxy: true }

--[=[
	Metadata stored for each proxy.
]=]
export type ProxyMetadata<T = { [any]: any }> = {
	Original: T, -- The unwrapped original table
	Parent: any?, -- The original (unwrapped) parent table; nil for the root proxy
	Key: any?, -- The key under which this table lives in its parent; nil for the root proxy
	IsArray: boolean, -- Whether this table is treated as an array
	ArrayLength: number, -- Cached length for arrays
	RootTable: { [any]: any }, -- Reference to the root table for snapshot capture
}

--[=[
	ChangeDetector instance type (minimal interface).
]=]
export type ChangeDetector = {
	CaptureSnapshot: (self: ChangeDetector, value: any, path: Path) -> (),
	CheckForChanges: (self: ChangeDetector, value: any) -> (),
}

--[=[
	The ProxyManager instance type.
]=]
export type ProxyManager = {
	IsProxy: (self: ProxyManager, t: any) -> boolean,
	GetOriginal: <T>(self: ProxyManager, t: Proxy<T> | T) -> T,
	GetMetadata: <T>(self: ProxyManager, proxy: Proxy<T>) -> ProxyMetadata<T>,
	--- Returns the live path from root to this proxy by walking the Parent chain. Returns nil if the proxy is unknown.
	GetPath: <T>(self: ProxyManager, proxy: Proxy<T>) -> Path?,
	--- Returns the existing proxy for an original table, or nil if none exists.
	GetProxyFromOriginal: <T>(self: ProxyManager, original: T) -> Proxy<T>?,
	CreateProxy: <T>(
		self: ProxyManager,
		original: T,
		_path: Path?,
		rootTable: { [any]: any }?,
		parentOriginal: any?,
		key: any?
	) -> Proxy<T>,
	IsArray: (self: ProxyManager, t: any) -> boolean,
	GetArrayLength: (self: ProxyManager, t: any) -> number,
	SetChangeDetector: (self: ProxyManager, changeDetector: ChangeDetector) -> (),
	SetArrayInsertedCallback: (self: ProxyManager, callback: (path: Path, index: number, newValue: any) -> ()) -> (),
	SetBatchDirectArraySetCallback: (self: ProxyManager, callback: (path: Path, index: number) -> ()) -> (),
	--- Set the callback fired for every non-array, non-append write during a batch.
	--- Receives the **parent table's path** (not including the written key) so the
	--- caller can record which top-level branch was dirtied.
	SetBatchScalarWrittenCallback: (self: ProxyManager, callback: (parentPath: Path) -> ()) -> (),
	SetValidateCallback: (self: ProxyManager, callback: (path: Path, value: any) -> (boolean, string?)) -> (),
	--- Update the Key metadata for all direct child proxies of `arrayOriginal` whose
	--- numeric key is >= `fromIndex` by adding `delta`. Called by TableManager after
	--- every ArrayInsert (+1) or ArrayRemove (-1) so held proxies report the correct path.
	ShiftKeys: (self: ProxyManager, arrayOriginal: { [any]: any }, fromIndex: number, delta: number) -> (),
	Destroy: (self: ProxyManager) -> (),

	-- Private fields
	_proxyMeta: { [any]: ProxyMetadata<any> },
	_originalToProxy: { [any]: Proxy<any> },
	_proxiesByParent: { [any]: { [any]: true } }, -- parentOriginal → set of child proxies
	_changeDetector: ChangeDetector?,
	_onArrayInserted: ((path: Path, index: number, newValue: any) -> ())?,
	_onBatchDirectArraySet: ((path: Path, index: number) -> ())?,
	_onBatchScalarWritten: ((parentPath: Path) -> ())?,
	_onValidateWrite: ((path: Path, value: any) -> (boolean, string?))?,
	_sharedMetatable: { [any]: any },
	_GetLivePath: (self: ProxyManager, proxy: Proxy<any>) -> Path,
}

--------------------------------------------------------------------------------
--// Module //--
--------------------------------------------------------------------------------

const ProxyManager = {}
const ProxyManager_MT = { __index = ProxyManager }

--[=[
	Creates a new ProxyManager instance.
]=]
function ProxyManager.new(): ProxyManager
	const self = setmetatable({} :: any, ProxyManager_MT) :: ProxyManager

	self._proxyMeta = {}
	self._originalToProxy = {}
	self._proxiesByParent = {}
	self._changeDetector = nil
	self._onArrayInserted = nil
	self._onBatchDirectArraySet = nil
	self._onBatchScalarWritten = nil
	self._onValidateWrite = nil

	-- Create the shared metatable for all proxies
	self._sharedMetatable = {
		__index = function(proxy, key)
			const meta = self._proxyMeta[proxy]
			if not meta then
				error("Proxy metadata not found - proxy may have been destroyed")
			end

			const originalTable = meta.Original
			const value = originalTable[key]

			-- Return nested proxy for tables
			if type(value) == "table" then
				-- Check if we already have a proxy for this table
				if self._originalToProxy[value] then
					return self._originalToProxy[value]
				end

				-- Create new proxy for nested table (inherit root table)
				return self:CreateProxy(value, nil, meta.RootTable, meta.Original, key)
			end

			-- Return raw value for scalars
			return value
		end,

		__newindex = function(proxy, key, value)
			const meta = self._proxyMeta[proxy]
			if not meta then
				error("Proxy metadata not found - proxy may have been destroyed")
			end

			const originalTable = meta.Original
			const parentPath = self:_GetLivePath(proxy)
			const currentPath = table.clone(parentPath)
			table.insert(currentPath, key)
			const unwrappedValue = getOriginal(value)

			-- Validate writes before any side effects (batch tracking, snapshots, or mutation).
			if self._onValidateWrite then
				const ok, err = self._onValidateWrite(currentPath, unwrappedValue)
				if not ok then
					if err then
						error(err, 2)
					end
					return
				end
			end

			-- Special case: Array append (key == length + 1)
			if meta.IsArray and type(key) == "number" and key == meta.ArrayLength + 1 then
				-- Apply
				originalTable[key] = unwrappedValue
				meta.ArrayLength = key

				-- Fire array inserted callback directly
				if self._onArrayInserted then
					self._onArrayInserted(parentPath, key, unwrappedValue)
				end
				return
			end

			-- Non-append numeric assignment on an array: notify the batch recorder
			-- so it can mark this array path as poisoned (forces Branch A at flush).
			if meta.IsArray and type(key) == "number" and self._onBatchDirectArraySet then
				self._onBatchDirectArraySet(parentPath, key)
			end

			-- Notify the batch system which parent branch was dirtied by this scalar write.
			if self._onBatchScalarWritten then
				self._onBatchScalarWritten(parentPath)
			end

			-- Standard change detection workflow:
			-- 1. Capture snapshot BEFORE the change (returns snapshot object)
			local snapshot = nil
			if self._changeDetector then
				snapshot = self._changeDetector:CaptureSnapshot(meta.RootTable, currentPath)
			end

			-- 2. Apply the change
			originalTable[key] = unwrappedValue

			-- 3. Detect changes (ChangeDetector compares new state against snapshot)
			if self._changeDetector and snapshot then
				self._changeDetector:CheckForChanges(snapshot)
			end

			-- 4. Update metadata
			if meta.IsArray then
				meta.ArrayLength = getArrayLength(originalTable)
			end
		end,

		__eq = function(a, b)
			-- Allow proxy == proxy comparisons
			return getOriginal(a) == getOriginal(b)
		end,

		__iter = function(proxy)
			const meta = self._proxyMeta[proxy]
			if not meta then
				error("Proxy metadata not found - proxy may have been destroyed")
			end

			-- Use next() on the original table, but wrap returned values in proxies
			const originalTable = meta.Original
			return function(_, key)
				const nextKey, nextValue = next(originalTable, key)
				if nextKey == nil then
					return nil, nil
				end

				-- Wrap table values in proxies
				if type(nextValue) == "table" then
					if self._originalToProxy[nextValue] then
						return nextKey, self._originalToProxy[nextValue]
					end

					local nestedProxy = self:CreateProxy(nextValue, nil, meta.RootTable, meta.Original, nextKey)
					return nextKey, nestedProxy
				end

				return nextKey, nextValue
			end,
				nil,
				nil
		end,

		__len = function(proxy)
			const meta = self._proxyMeta[proxy]
			if not meta then
				error("Proxy metadata not found - proxy may have been destroyed")
			end
			return #meta.Original
		end,

		__tostring = function(proxy)
			const meta = self._proxyMeta[proxy]
			if not meta then
				return "TableManager.Data(?)"
			end
			const livePath = self:_GetLivePath(proxy)
			if #livePath == 0 then
				return "TableManager.Data"
			end
			return "TableManager.Data(" .. table.concat(livePath, ".") .. ")"
		end,

		__metatable = "Locked",
	}

	return self
end

--[=[
	Set the ChangeDetector instance to delegate change detection to.
]=]
function ProxyManager:SetChangeDetector(changeDetector: ChangeDetector)
	self._changeDetector = changeDetector
end

--[=[
	Set the callback for array insertions (appends only).
]=]
function ProxyManager:SetArrayInsertedCallback(callback: (path: Path, index: number, newValue: any) -> ())
	self._onArrayInserted = callback
end

--[=[
	Set the callback fired when a non-append numeric index is directly assigned on an
	array proxy (e.g. `proxy[2] = value` when the array already has that slot).

	TableManager uses this to mark the array's batch log as poisoned, which forces
	Branch A (LCS snapshot diff) at flush time instead of the op-log coalescer.
]=]
function ProxyManager:SetBatchDirectArraySetCallback(callback: (path: Path, index: number) -> ())
	self._onBatchDirectArraySet = callback
end

--[=[
	Set the callback fired for every non-array, non-append write through a proxy.
	Receives the **parent table's path** (the path of the proxy that owns the key
	that was written, i.e. NOT including the written key itself).

	TableManager uses this during a batch to record which top-level branches were
	dirtied so that the flush can diff only those branches instead of the whole tree.
]=]
function ProxyManager:SetBatchScalarWrittenCallback(callback: (parentPath: Path) -> ())
	self._onBatchScalarWritten = callback
end

--[=[
	Set the callback fired for every proxy write before mutation.
	Returning `false` prevents the write. If an error message is returned it is raised.
]=]
function ProxyManager:SetValidateCallback(callback: (path: Path, value: any) -> (boolean, string?))
	self._onValidateWrite = callback
end

--- Check if a value is a proxy.
function ProxyManager:IsProxy(t: any): boolean
	return isProxy(t)
end

--- Get the original (unwrapped) table from a proxy. If the input is not a proxy, returns it unchanged.
function ProxyManager:GetOriginal<T>(t: Proxy<T> | T): T
	return getOriginal(t)
end

--- Get the metadata for a proxy.
function ProxyManager:GetMetadata<T>(proxy: Proxy<T>): ProxyMetadata<T>
	return self._proxyMeta[proxy]
end

--- Get the live path from root to this proxy by walking the Parent chain.
function ProxyManager:GetPath<T>(proxy: Proxy<T>): Path?
	if not self._proxyMeta[proxy] then
		return nil
	end
	return self:_GetLivePath(proxy)
end

--- Get the proxy for an original table, if it exists.
function ProxyManager:GetProxyFromOriginal<T>(original: T): Proxy<T>?
	return self._originalToProxy[original]
end

--[=[
	Walk the Parent chain from `proxy` up to the root and return the assembled path.
	O(depth). Returns a fresh table each call — safe to mutate.
]=]
function ProxyManager:_GetLivePath(proxy: Proxy<any>): Path
	const meta = self._proxyMeta[proxy]
	if meta == nil or meta.Parent == nil then
		return {}
	end

	const keys: Path = {}
	local current = meta
	while current ~= nil and current.Key ~= nil do
		table.insert(keys, 1, current.Key)
		if current.Parent == nil then
			break
		end
		const parentProxy = self._originalToProxy[current.Parent]
		if parentProxy == nil then
			break
		end
		current = self._proxyMeta[parentProxy]
	end

	return keys
end

--[=[
	Create a new proxy for a table at the given path.
	
	@param original -- The original table to wrap
	@param path -- The path from root to this table
	@param rootTable -- Optional root table reference (defaults to original for root proxy)
	@param parentOriginal -- The unwrapped parent table (nil for root proxy)
	@param key -- The key under which `original` lives in its parent (nil for root proxy)
]=]
function ProxyManager:CreateProxy<T>(
	original: T,
	_path: Path?,
	rootTable: { [any]: any }?,
	parentOriginal: any?,
	key: any?
): Proxy<T>
	if type(original) ~= "table" then
		return original :: any
	end

	-- Return existing proxy if already created
	if self._originalToProxy[original] then
		return self._originalToProxy[original] :: any
	end

	-- For root proxy, original IS the root table
	const root = rootTable or (original :: any)

	-- Create new proxy
	const proxy = setmetatable({}, self._sharedMetatable) :: any

	-- Store bidirectional mapping
	PROXY_TO_ORIGINAL[proxy] = original
	self._originalToProxy[original] = proxy

	-- Store metadata
	const isArr = isArray(original)
	self._proxyMeta[proxy] = {
		Original = original,
		Parent = parentOriginal,
		Key = key,
		IsArray = isArr,
		ArrayLength = if isArr then getArrayLength(original) else 0,
		RootTable = root,
	}

	-- Register in parent lookup so ShiftKeys can find child proxies
	if parentOriginal ~= nil then
		if not self._proxiesByParent[parentOriginal] then
			self._proxiesByParent[parentOriginal] = {}
		end
		self._proxiesByParent[parentOriginal][proxy] = true
	end

	return proxy
end

--[=[
	Check if a table is an array.
]=]
function ProxyManager:IsArray(t: any): boolean
	return isArray(t)
end

--[=[
	Get the length of an array.
]=]
function ProxyManager:GetArrayLength(t: any): number
	return getArrayLength(t)
end

--[=[
	Update the `Key` metadata for all direct child proxies of `arrayOriginal`
	whose numeric key is >= `fromIndex` by adding `delta`.

	Call with `delta = 1` after `table.insert(array, pos, value)` and
	`delta = -1` after `table.remove(array, index)` (passing `index + 1`
	as `fromIndex` for removes so the removed slot itself is not shifted).
]=]
function ProxyManager:ShiftKeys(arrayOriginal: { [any]: any }, fromIndex: number, delta: number)
	const children = self._proxiesByParent[arrayOriginal]
	if children == nil then
		return
	end
	for childProxy in children do
		const meta = self._proxyMeta[childProxy]
		if meta ~= nil and type(meta.Key) == "number" and meta.Key >= fromIndex then
			meta.Key += delta
		end
	end
end

--[=[
	Clean up all proxies and metadata.
]=]
function ProxyManager:Destroy()
	-- Clear all metadata
	table.clear(self._proxyMeta)
	table.clear(self._originalToProxy)
	table.clear(self._proxiesByParent)

	-- Clear weak table entries (they'll be GC'd automatically, but we can help)
	for proxy in self._proxyMeta do
		PROXY_TO_ORIGINAL[proxy] = nil
	end

	self._changeDetector = nil
	self._onArrayInserted = nil
	self._onValidateWrite = nil
end

return ProxyManager
