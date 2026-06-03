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

local PathHelpers = require(script.Parent.PathHelpers)
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
	Path: Path, -- Path from root to this table
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
	GetMetadata: <T>(self: ProxyManager, proxy: Proxy<T>) -> ProxyMetadata<T>?,
	CreateProxy: <T>(self: ProxyManager, original: T, path: Path, rootTable: { [any]: any }?) -> Proxy<T>,
	IsArray: (self: ProxyManager, t: any) -> boolean,
	GetArrayLength: (self: ProxyManager, t: any) -> number,
	SetChangeDetector: (self: ProxyManager, changeDetector: ChangeDetector) -> (),
	SetArrayInsertedCallback: (self: ProxyManager, callback: (path: Path, index: number, newValue: any) -> ()) -> (),
	Destroy: (self: ProxyManager) -> (),

	-- Private fields
	_proxyMeta: { [any]: ProxyMetadata<any> },
	_originalToProxy: { [any]: Proxy<any> },
	_changeDetector: ChangeDetector?,
	_onArrayInserted: ((path: Path, index: number, newValue: any) -> ())?,
	_sharedMetatable: { [any]: any },
}

--------------------------------------------------------------------------------
--// Module //--
--------------------------------------------------------------------------------

local ProxyManager = {}
local ProxyManager_MT = { __index = ProxyManager }

--[=[
	Creates a new ProxyManager instance.
]=]
function ProxyManager.new(): ProxyManager
	local self = setmetatable({} :: any, ProxyManager_MT) :: ProxyManager

	self._proxyMeta = {}
	self._originalToProxy = {}
	self._changeDetector = nil
	self._onArrayInserted = nil

	-- Create the shared metatable for all proxies
	self._sharedMetatable = {
		__index = function(proxy, key)
			local meta = self._proxyMeta[proxy]
			if not meta then
				error("Proxy metadata not found - proxy may have been destroyed")
			end

			local originalTable = meta.Original
			local value = originalTable[key]

			-- Return nested proxy for tables
			if type(value) == "table" then
				-- Check if we already have a proxy for this table
				if self._originalToProxy[value] then
					return self._originalToProxy[value]
				end

				-- Create new proxy for nested table (inherit root table)
				local nestedPath = table.clone(meta.Path)
				table.insert(nestedPath, key)
				return self:CreateProxy(value, nestedPath, meta.RootTable)
			end

			-- Return raw value for scalars
			return value
		end,

		__newindex = function(proxy, key, value)
			local meta = self._proxyMeta[proxy]
			if not meta then
				error("Proxy metadata not found - proxy may have been destroyed")
			end

			local originalTable = meta.Original
			local currentPath = table.clone(meta.Path)
			table.insert(currentPath, key)

			-- Special case: Array append (key == length + 1)
			if meta.IsArray and type(key) == "number" and key == meta.ArrayLength + 1 then
				-- Unwrap and apply
				local unwrappedValue = getOriginal(value)
				originalTable[key] = unwrappedValue
				meta.ArrayLength = key

				-- Fire array inserted callback directly
				if self._onArrayInserted then
					self._onArrayInserted(meta.Path, key, unwrappedValue)
				end
				return
			end

			-- Standard change detection workflow:
			-- 1. Capture snapshot BEFORE the change (returns snapshot object)
			local snapshot = nil
			if self._changeDetector then
				snapshot = self._changeDetector:CaptureSnapshot(meta.RootTable, currentPath)
			end

			-- 2. Apply the change
			local unwrappedValue = getOriginal(value)
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
			local meta = self._proxyMeta[proxy]
			if not meta then
				error("Proxy metadata not found - proxy may have been destroyed")
			end

			-- Use next() on the original table, but wrap returned values in proxies
			local originalTable = meta.Original
			return function(_, key)
				local nextKey, nextValue = next(originalTable, key)
				if nextKey == nil then
					return nil, nil
				end

				-- Wrap table values in proxies
				if type(nextValue) == "table" then
					if self._originalToProxy[nextValue] then
						return nextKey, self._originalToProxy[nextValue]
					end

					local nestedPath = table.clone(meta.Path)
					table.insert(nestedPath, nextKey)
					local nestedProxy = self:CreateProxy(nextValue, nestedPath, meta.RootTable)
					return nextKey, nestedProxy
				end

				return nextKey, nextValue
			end,
				nil,
				nil
		end,

		__len = function(proxy)
			local meta = self._proxyMeta[proxy]
			if not meta then
				error("Proxy metadata not found - proxy may have been destroyed")
			end
			return #meta.Original
		end,

		__tostring = function(proxy)
			local meta = self._proxyMeta[proxy]
			if not meta then
				return "TableManager.Data(?)"
			end
			if #meta.Path == 0 then
				return "TableManager.Data"
			end
			return "TableManager.Data(" .. table.concat(meta.Path, ".") .. ")"
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
	Check if a value is a proxy.
]=]
function ProxyManager:IsProxy(t: any): boolean
	return isProxy(t)
end

--[=[
	Get the original (unwrapped) table from a proxy.
]=]
function ProxyManager:GetOriginal<T>(t: Proxy<T> | T): T
	return getOriginal(t)
end

--[=[
	Get the metadata for a proxy.
]=]
function ProxyManager:GetMetadata<T>(proxy: Proxy<T>): ProxyMetadata<T>?
	return self._proxyMeta[proxy]
end

--[=[
	Create a new proxy for a table at the given path.
	
	@param original -- The original table to wrap
	@param path -- The path from root to this table
	@param rootTable -- Optional root table reference (defaults to original for root proxy)
]=]
function ProxyManager:CreateProxy<T>(original: T, path: Path, rootTable: { [any]: any }?): Proxy<T>
	if type(original) ~= "table" then
		return original :: any
	end

	-- Return existing proxy if already created
	if self._originalToProxy[original] then
		return self._originalToProxy[original] :: any
	end

	-- For root proxy, original IS the root table
	local root = rootTable or (original :: any)

	-- Create new proxy
	local proxy = setmetatable({}, self._sharedMetatable) :: any

	-- Store bidirectional mapping
	PROXY_TO_ORIGINAL[proxy] = original
	self._originalToProxy[original] = proxy

	-- Store metadata
	local isArr = isArray(original)
	self._proxyMeta[proxy] = {
		Original = original,
		Path = table.clone(path),
		IsArray = isArr,
		ArrayLength = if isArr then getArrayLength(original) else 0,
		RootTable = root,
	}

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
	Clean up all proxies and metadata.
]=]
function ProxyManager:Destroy()
	-- Clear all metadata
	table.clear(self._proxyMeta)
	table.clear(self._originalToProxy)

	-- Clear weak table entries (they'll be GC'd automatically, but we can help)
	for proxy in self._proxyMeta do
		PROXY_TO_ORIGINAL[proxy] = nil
	end

	self._changeDetector = nil
	self._onArrayInserted = nil
end

return ProxyManager
