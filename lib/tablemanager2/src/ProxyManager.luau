--!strict
--[=[
	@ignore
	@class ProxyManager
	
	Thin proxy front-end over a raw table. ProxyManager only maintains the
	proxy graph (creation, parent/key tracking, reparenting) and read-side
	metamethods. It performs NO change detection, validation, batching, or
	duplicate-reference checks itself.

	## Architecture

	### Single Write Integration Point
	Every proxy write (`proxy[key] = value`) resolves the live path of the
	write (via `_GetLivePath` + the written key) and unwraps any proxy value,
	then calls the handler registered via `SetWriteHandler`. The handler
	(TableManager's `applyWrite`) owns validation, duplicate-reference checks,
	array-append detection, batching, snapshotting, and change detection.

	If no handler is registered, writes apply directly to the underlying
	original table — this keeps ProxyManager usable standalone (see
	`Tests/ProxyManager.spec.luau`).

	### Proxy Implementation
	Uses a weak table (PROXY_TO_ORIGINAL) to track proxies without polluting
	their key space or interfering with metamethods.

	### Shared Metatable
	All proxies share one metatable per TableManager instance for memory efficiency.
	Metadata is stored in `_proxyMeta` and looked up dynamically.

	### Metamethods
	- __index: Returns nested proxies for tables, raw values for scalars
	- __newindex: Resolves the live write path and delegates to the write handler
	- __eq: Allows proxy == proxy comparisons
	- __iter: Enables `for k, v in proxy do` iteration
	- __len: Returns array length
	- __tostring: Returns "TableManager.Data(path)"
	- __metatable: Protects metatable from external access
]=]

local PathHelpers = require("./PathHelpers")
type Path<S> = PathHelpers.Path<S>
type PathArray<S> = PathHelpers.PathArray<S>
type PathString<S> = PathHelpers.PathString<S>
type table = { [any]: any }

--[[
	Weak table mapping proxies to their original tables.
	This allows proxies to be garbage collected when no longer referenced.
]]
local PROXY_TO_ORIGINAL = setmetatable({}, { __mode = "k" })

--// Types //--
type ValueAtPath<T, S> = PathHelpers.ValueAtPath<T, S>

--[=[
	@within ProxyManager
	@type Proxy table & { __proxy: true }

	A proxy wraps a table and intercepts read/write operations.
]=]
type function ProxyWrap(T: type, Path: type): type
	if not T:is("table") then
		return T
	end

	if Path:is("string") then
		return types.any
	end

	if not Path:is("singleton") then
		error("Path type must be a singleton string or a table of any keys. Defaulting to 'never'.")
		return types.never
	end

	T = ValueAtPath(T, Path)
	if not T:is("table") then
		return T
	end

	for k, v in T:properties() do
		if v.read and v.read:is("table") then
			T:setproperty(k, ProxyWrap(v.read, Path))
		end
	end

	T:setproperty(types.singleton("__PROXY__"), types.singleton(true))

	return T
end
export type Proxy<T, S = string> = any -- ProxyWrap<T, S>

--[=[
	@within ProxyManager
	@interface ProxyMetadata
	Original { [any]: any } -- The unwrapped original table
	Parent any? -- The original (unwrapped) parent table; nil for the root proxy
	Key any? -- The key under which this table lives in its parent; nil for the root proxy
	IsArray boolean -- Whether this table is treated as an array
	ArrayLength number -- Cached length for arrays

	Metadata stored for each proxy.
]=]
export type ProxyMetadata<T = { [any]: any }, S = string> = {
	Original: ValueAtPath<T, S> & table, -- The unwrapped original table
	Parent: any?, -- The original (unwrapped) parent table; nil for the root proxy
	Key: any?, -- The key under which this table lives in its parent; nil for the root proxy
	IsArray: boolean, -- Whether this table is treated as an array
	ArrayLength: number, -- Cached length for arrays
}

export type ProxyManager<T = { [any]: any }> = {
	IsProxy: (self: ProxyManager<T>, t: any) -> boolean,
	GetOriginal: <S>(self: ProxyManager<T>, t: Proxy<T, S>) -> ValueAtPath<T, S>,
	GetMetadata: <S>(self: ProxyManager<T>, proxy: Proxy<T, S>) -> ProxyMetadata<T, S>,
	--- Returns the live path from root to this proxy by walking the Parent chain. Returns nil if the proxy is unknown.
	GetPath: <S>(self: ProxyManager<T>, proxy: Proxy<T, S>) -> PathArray<S>?,
	--- Returns the existing proxy for an original table, or nil if none exists.
	GetProxyFromOriginal: <S>(self: ProxyManager<T>, original: ValueAtPath<T, S>) -> Proxy<T, S>?,
	CreateProxy: <S>(
		self: ProxyManager<T>,
		original: ValueAtPath<T, S>,
		parentOriginal: any?,
		key: any?
	) -> Proxy<T, S>,
	--- Sets the single write-interception handler. Every proxy write
	--- (`proxy[key] = value`) resolves the live path of the write (including
	--- `key`) and calls `handler(path, unwrappedValue)`. If no handler is set,
	--- writes apply directly to the underlying original table (used by
	--- standalone ProxyManager tests).
	SetWriteHandler: <S>(self: ProxyManager<T>, handler: (path: PathArray<S>, value: any) -> ()) -> (),
	ReparentProxy: <S>(self: ProxyManager<T>, proxy: Proxy<T, S>, newParentOriginal: any?, newKey: any?) -> (),
	--- Update the Key metadata for all direct child proxies of `arrayOriginal` whose
	--- numeric key is >= `fromIndex` by adding `delta`. Called by TableManager after
	--- every ArrayInsert (+1) or ArrayRemove (-1) so held proxies report the correct path.
	ShiftKeys: (self: ProxyManager<T>, arrayOriginal: { [any]: any }, fromIndex: number, delta: number) -> (),
	Destroy: (self: ProxyManager<T>) -> (),

	-- Private fields
	_proxyMeta: { [any]: ProxyMetadata<T, string> },
	_originalToProxy: { [any]: Proxy<T, string> },
	_proxiesByParent: { [any]: { [any]: true } }, -- parentOriginal → set of child proxies
	_rootTable: T,
	_writeHandler: (<S>(path: PathArray<S>, value: any) -> ())?,
	_metatableTemplate: { [any]: any },
	_GetLivePath: <S>(self: ProxyManager<T>, proxy: Proxy<T, S>) -> PathArray<S>,
}

--------------------------------------------------------------------------------
--// Util Functions //--
--------------------------------------------------------------------------------

-- Check if a value is a proxy by looking it up in the weak table.
const function isProxy(t: any): boolean
	const valueType = type(t)
	return (valueType == "table" or valueType == "userdata") and PROXY_TO_ORIGINAL[t] ~= nil
end

--[[
	Get the original (unwrapped) table from a proxy.
	If the input is not a proxy, returns it unchanged.
]]
const function getOriginal<T>(t: T | Proxy<T>): T
	if isProxy(t) then
		return PROXY_TO_ORIGINAL[t :: Proxy<T>] :: T
	end
	return t
end

--[[
	Classify table shape in one pass.
	Returns whether the table is an array plus its array length when true.
]]
const function classifyTable(t: { [any]: any }): (boolean, number)
	if type(t) ~= "table" then
		return false, 0
	end

	local count = 0
	local maxIndex = 0

	for key, _ in t do
		if type(key) ~= "number" or key < 1 or key % 1 ~= 0 then
			return false, 0
		end
		count += 1
		maxIndex = math.max(maxIndex, key)
	end

	if count == maxIndex then
		return true, maxIndex
	end

	return false, 0
end

--------------------------------------------------------------------------------
--// Module //--
--------------------------------------------------------------------------------

const ProxyManager = {}
const ProxyManager_MT = { __index = ProxyManager }

--[=[
	Creates a new ProxyManager instance.
]=]
function ProxyManager.new<T>(rootTable: T): ProxyManager<T>
	if type(rootTable) ~= "table" then
		error("ProxyManager.new expects rootTable to be a plain table")
	end

	const self: ProxyManager<T> = setmetatable({}, ProxyManager_MT) :: any

	self._proxyMeta = {}
	self._originalToProxy = {}
	self._proxiesByParent = {}
	self._rootTable = rootTable
	self._writeHandler = nil

	-- Create the metatable template copied into each proxy metatable.
	self._metatableTemplate = {
		__index = function(proxy, key)
			const meta = self._proxyMeta[proxy]
			assert(meta, "Proxy metadata not found - proxy may have been destroyed")

			const originalTable = meta.Original
			const value = originalTable[key]

			-- Return nested proxy for tables
			if type(value) == "table" then
				-- Check if we already have a proxy for this table
				if self._originalToProxy[value] then
					return self._originalToProxy[value]
				end

				-- Create new proxy for nested table
				return self:CreateProxy(value, meta.Original, key)
			end

			-- Return raw value for scalars
			return value
		end,

		__newindex = function(proxy: Proxy<T>, key: any, value: any)
			const meta = self._proxyMeta[proxy]
			assert(meta, "Proxy metadata not found - proxy may have been destroyed")

			const unwrappedValue = getOriginal(value)

			if self._writeHandler then
				const path = self:_GetLivePath(proxy)
				table.insert(path, key)
				self._writeHandler(path, unwrappedValue)
			else
				-- Standalone mode (no write handler registered): apply directly.
				meta.Original[key] = unwrappedValue
			end
		end,

		__eq = function(a, b)
			-- Allow proxy == proxy comparisons
			return getOriginal(a) == getOriginal(b)
		end,

		__iter = function(proxy)
			const meta = self._proxyMeta[proxy] :: ProxyMetadata
			assert(meta, "Proxy metadata not found - proxy may have been destroyed")

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
						return nextKey, self._originalToProxy[nextValue] :: any
					end

					local nestedProxy = self:CreateProxy(nextValue, meta.Original, nextKey)
					return nextKey, nestedProxy
				end

				return nextKey, nextValue
			end,
				nil,
				nil
		end,

		__len = function(proxy)
			const meta = self._proxyMeta[proxy] :: ProxyMetadata
			assert(meta, "Proxy metadata not found - proxy may have been destroyed")
			return #meta.Original
		end,

		__tostring = function(proxy)
			const meta = self._proxyMeta[proxy] :: ProxyMetadata
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
	Sets the single write-interception handler. See the `SetWriteHandler` type
	declaration for the contract.
]=]
function ProxyManager:SetWriteHandler<S>(handler: (path: PathArray<S>, value: any) -> ())
	self._writeHandler = handler :: any
end

--- Check if a value is a proxy.
function ProxyManager.IsProxy(self: ProxyManager, t: any): boolean
	return isProxy(t)
end

--- Get the original (unwrapped) table from a proxy. If the input is not a proxy, returns it unchanged.
function ProxyManager.GetOriginal<T>(self: ProxyManager, t: Proxy<T> | T): T
	return getOriginal(t)
end

--- Get the metadata for a proxy.
function ProxyManager.GetMetadata<T>(self: ProxyManager, proxy: Proxy<T>): ProxyMetadata<T>
	return self._proxyMeta[proxy]
end

--- Get the live path from root to this proxy by walking the Parent chain.
function ProxyManager.GetPath<T>(self: ProxyManager, proxy: Proxy<T>): PathArray<any>?
	if not self._proxyMeta[proxy] then
		return nil
	end
	return self:_GetLivePath(proxy)
end

--- Get the proxy for an original table, if it exists.
function ProxyManager.GetProxyFromOriginal<T>(self: ProxyManager, original: T): Proxy<T>?
	return self._originalToProxy[original] :: any
end

--[=[
	Walk the Parent chain from `proxy` up to the root and return the assembled path.
	O(depth). Returns a fresh table each call — safe to mutate.
]=]
function ProxyManager._GetLivePath(self: ProxyManager, proxy: Proxy<any>): PathArray<any>
	const meta = self._proxyMeta[proxy]
	if meta == nil or meta.Parent == nil then
		return {}
	end

	const keys: PathArray<any> = {}
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
	@param parentOriginal -- The unwrapped parent table (nil for root proxy)
	@param key -- The key under which `original` lives in its parent (nil for root proxy)
]=]
function ProxyManager.CreateProxy<T, S>(
	self: ProxyManager,
	original: ValueAtPath<T, S>,
	parentOriginal: any?,
	key: any?
): Proxy<T, S>
	if type(original) ~= "table" then
		return original :: any
	end

	-- Return existing proxy if already created
	if self._originalToProxy[original] then
		return self._originalToProxy[original] :: any
	end

	-- Create new proxy
	const proxy = newproxy(true) :: Proxy<T, S>
	local MT = getmetatable(proxy :: any)
	for k, v in self._metatableTemplate do
		MT[k] = v
	end
	table.freeze(MT) -- Per-proxy metatable is immutable for safety

	-- Store bidirectional mapping
	PROXY_TO_ORIGINAL[proxy] = original
	self._originalToProxy[original] = proxy

	-- Store metadata
	const isArr, arrayLength = classifyTable(original)
	self._proxyMeta[proxy] = {
		Original = original,
		Parent = parentOriginal,
		Key = key,
		IsArray = isArr,
		ArrayLength = arrayLength,
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
	Reparent an existing proxy to a new parent/key without changing its original table.
]=]
function ProxyManager.ReparentProxy<T, S>(self: ProxyManager<T>, proxy: Proxy<T, S>, newParentOriginal: any?, newKey: any?)
	const meta = self._proxyMeta[proxy]
	if meta == nil then
		error("Proxy metadata not found - proxy may have been destroyed")
	end

	const oldParent = meta.Parent
	if oldParent ~= nil then
		const oldChildren = self._proxiesByParent[oldParent]
		if oldChildren ~= nil then
			oldChildren[proxy] = nil
			if next(oldChildren) == nil then
				self._proxiesByParent[oldParent] = nil
			end
		end
	end

	meta.Parent = newParentOriginal
	meta.Key = newKey

	if newParentOriginal ~= nil then
		if not self._proxiesByParent[newParentOriginal] then
			self._proxiesByParent[newParentOriginal] = {}
		end
		self._proxiesByParent[newParentOriginal][proxy] = true
	end
end

--[=[
	Update the `Key` metadata for all direct child proxies of `arrayOriginal`
	whose numeric key is >= `fromIndex` by adding `delta`.

	Call with `delta = 1` after `table.insert(array, pos, value)` and
	`delta = -1` after `table.remove(array, index)` (passing `index + 1`
	as `fromIndex` for removes so the removed slot itself is not shifted).
]=]
function ProxyManager.ShiftKeys(self: ProxyManager, arrayOriginal: { [any]: any }, fromIndex: number, delta: number)
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
function ProxyManager.Destroy(self: ProxyManager)
	-- Clear weak table entries (they'll be GC'd automatically, but we can help)
	for proxy in self._proxyMeta do
		PROXY_TO_ORIGINAL[proxy] = nil
	end

	-- Clear all metadata
	table.clear(self._proxyMeta)
	table.clear(self._originalToProxy)
	table.clear(self._proxiesByParent)

	self._writeHandler = nil
end

--------------------------------------------------------------------------------
--// Instance-Free Statics //--
--------------------------------------------------------------------------------

--- Returns true if `t` is a proxy created by any ProxyManager.
function ProxyManager.IsProxyValue(t: any): boolean
	return isProxy(t)
end

--- Returns the original (unwrapped) table behind a proxy, or `t` unchanged if it isn't a proxy.
function ProxyManager.Unwrap<T>(t: T | Proxy<T>): T
	return getOriginal(t)
end

--[[
	Classify table shape in one pass.
	Returns whether the table is an array plus its array length when true.
	A table is considered an array when every key is a positive integer and
	the set of keys is exactly `{1, .., maxIndex}` (so `{}` is a length-0 array).
]]
function ProxyManager.ClassifyTable(t: { [any]: any }): (boolean, number)
	return classifyTable(t)
end

return ProxyManager
