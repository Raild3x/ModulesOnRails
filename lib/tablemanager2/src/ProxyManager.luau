--!strict
--[=[
	@class ProxyManager
	
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
type Path<S> = PathHelpers.Path<S>
type PathArray<S> = PathHelpers.PathArray<S>
type PathString<S> = PathHelpers.PathString<S>

--[[
	Weak table mapping proxies to their original tables.
	This allows proxies to be garbage collected when no longer referenced.
]]
local PROXY_TO_ORIGINAL = setmetatable({}, { __mode = "k" })

--// Types //--

--[=[
	@within ProxyManager
	@type Proxy table & { __proxy: true }

	A proxy wraps a table and intercepts read/write operations.
]=]
-- [Disabled for now because of an internal Luau type inference issue]
type function ValueAtPath(T: type, S: type)
	if not T:is("table") then
		return types.never
	end

	-- Array/tuple path: {"Hello", "World"}. Luau doesnt support this yet so we have to fall back to 'any'
	if S:is("table") then
		return types.any
	end

	if not S:is("singleton") then
		return types.any
	end

	-- String path: "Hello.World" (existing behavior)
	local str = S:value() :: string?
	if str == nil then
		return types.never
	end
	if str == "" then -- if the path is empty, return the original type
		return T
	end

	local dot = string.find(str, ".", 1, true)
	if dot == nil then
		local result = T:readproperty(types.singleton(str))
		if result == nil then
			error(`Path segment "{str}" does not exist in the table`)
			return types.never
		end
		return result :: type
	else
		local head = string.sub(str, 1, dot - 1)
		local tail = string.sub(str, dot + 1)
		local inner = T:readproperty(types.singleton(head))
		if inner == nil then
			error(`Path segment "{head}" does not exist in the table`)
			return types.never
		end
		return ValueAtPath(inner, types.singleton(tail))
	end
end

type function ProxyWrap(T: type, Path: type): type
	if not T:is("table") then
		return T
	end

	if not Path:is("singleton") then
		return types.any
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
export type Proxy<T = any, S = ""> = ProxyWrap<T, S>

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
export type ProxyMetadata<T = { [any]: any }, S = ""> = {
	Original: ValueAtPath<T, S>, -- The unwrapped original table
	Parent: any?, -- The original (unwrapped) parent table; nil for the root proxy
	Key: any?, -- The key under which this table lives in its parent; nil for the root proxy
	IsArray: boolean, -- Whether this table is treated as an array
	ArrayLength: number, -- Cached length for arrays
}

type ChangeDetector = {
	CaptureSnapshot: <S>(self: ChangeDetector, value: any, path: PathArray<S>) -> (),
	CheckForChanges: (self: ChangeDetector, value: any) -> (),
}

export type ProxyManager<T = { [any]: any }> = {
	IsProxy: (self: ProxyManager<T>, t: any) -> boolean,
	GetOriginal: <S>(self: ProxyManager<T>, t: Proxy<T, S>) -> ValueAtPath<T, S>,
	GetMetadata: <S>(self: ProxyManager<T>, proxy: Proxy<T, S>) -> ProxyMetadata<T, S>,
	--- Returns the live path from root to this proxy by walking the Parent chain. Returns nil if the proxy is unknown.
	GetPath: <S>(self: ProxyManager<T>, proxy: Proxy<T, S>) -> PathArray<S>?,
	--- Returns the existing proxy for an original table, or nil if none exists.
	GetProxyFromOriginal: (self: ProxyManager<T>, original: any) -> Proxy<T, string>?,
	CreateProxy: <T>(self: ProxyManager<T>, original: T, parentOriginal: any?, key: any?) -> Proxy<T>,
	SetChangeDetector: (self: ProxyManager<T>, changeDetector: ChangeDetector) -> (),
	SetArrayInsertedCallback: <S>(
		self: ProxyManager<T>,
		callback: (path: PathArray<S>, index: number, newValue: any) -> ()
	) -> (),
	SetBatchDirectArraySetCallback: <S>(
		self: ProxyManager<T>,
		callback: (path: PathArray<S>, index: number) -> ()
	) -> (),
	--- Set the callback fired for every non-array, non-append write during a batch.
	--- Receives the **parent table's path** (not including the written key) so the
	--- caller can record which top-level branch was dirtied.
	SetBatchScalarWrittenCallback: <S>(self: ProxyManager<T>, callback: (parentPath: PathArray<S>) -> ()) -> (),
	SetValidateCallback: <S>(
		self: ProxyManager<T>,
		callback: (path: PathArray<S>, value: any) -> (boolean, string?)
	) -> (),
	SetDuplicateTableWriteCallback: <S1, S2>(
		self: ProxyManager<T>,
		callback: (writePath: PathArray<S1>, existingPath: PathArray<S2>, value: any) -> boolean
	) -> (),
	ReparentProxy: (self: ProxyManager<T>, proxy: Proxy<any>, newParentOriginal: any?, newKey: any?) -> (),
	--- Update the Key metadata for all direct child proxies of `arrayOriginal` whose
	--- numeric key is >= `fromIndex` by adding `delta`. Called by TableManager after
	--- every ArrayInsert (+1) or ArrayRemove (-1) so held proxies report the correct path.
	ShiftKeys: (self: ProxyManager<T>, arrayOriginal: { [any]: any }, fromIndex: number, delta: number) -> (),
	Destroy: (self: ProxyManager<T>) -> (),

	-- Private fields
	_proxyMeta: { [any]: ProxyMetadata<any> },
	_originalToProxy: { [any]: Proxy },
	_proxiesByParent: { [any]: { [any]: true } }, -- parentOriginal → set of child proxies
	_rootTable: T,
	_changeDetector: ChangeDetector?,
	_onArrayInserted: (<S>(path: PathArray<S>, index: number, newValue: any) -> ())?,
	_onBatchDirectArraySet: (<S>(path: PathArray<S>, index: number) -> ())?,
	_onBatchScalarWritten: (<S>(parentPath: PathArray<S>) -> ())?,
	_onValidateWrite: (<S>(path: PathArray<S>, value: any) -> (boolean, string?))?,
	_onDuplicateTableWrite: (<S1, S2>(writePath: PathArray<S1>, existingPath: PathArray<S2>, value: any) -> boolean)?,
	_metatableTemplate: { [any]: any },
	_GetLivePath: (self: ProxyManager<T>, proxy: Proxy<any>) -> PathArray<any>,
}

--------------------------------------------------------------------------------
--// Util Functions //--
--------------------------------------------------------------------------------

const arePathsEqual = PathHelpers.ArePathsEqual

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
		return PROXY_TO_ORIGINAL[t :: Proxy<any>] :: T
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

const function getValueAtPath<T, S>(root: T & { [any]: any }, path: PathArray<S>): (any, boolean)
	local current = root
	for _, segment in path do
		if type(current) ~= "table" then
			return nil, false
		end
		current = current[segment]
	end
	return current, true
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
	self._changeDetector = nil
	self._onArrayInserted = nil
	self._onBatchDirectArraySet = nil
	self._onBatchScalarWritten = nil
	self._onValidateWrite = nil
	self._onDuplicateTableWrite = nil

	-- Create the metatable template copied into each proxy metatable.
	self._metatableTemplate = {
		__index = function(proxy, key)
			const meta = self._proxyMeta[proxy] :: ProxyMetadata
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

		__newindex = function(proxy: Proxy, key: any, value: any)
			const meta = self._proxyMeta[proxy] :: ProxyMetadata
			assert(meta, "Proxy metadata not found - proxy may have been destroyed")

			const originalTable = meta.Original
			const parentPath = self:_GetLivePath(proxy)
			const currentPath = table.clone(parentPath)
			table.insert(currentPath, key)
			const unwrappedValue = getOriginal(value)

			-- Table duplicate checks happen before validation/mutation.
			-- Orphaned proxies are intentionally treated as regular table assignments.
			if type(unwrappedValue) == "table" and self._onDuplicateTableWrite then
				const existingProxy = self._originalToProxy[unwrappedValue]
				if existingProxy ~= nil then
					const existingPath = self:_GetLivePath(existingProxy)
					if not arePathsEqual(existingPath, currentPath) then
						const existingMeta = self._proxyMeta[existingProxy]
						local isOrphan = true
						if existingMeta ~= nil then
							const liveValue, hasPath = getValueAtPath(self._rootTable, existingPath)
							isOrphan = not hasPath or liveValue ~= existingMeta.Original
						end

						if not isOrphan then
							const shouldAllow = self._onDuplicateTableWrite(currentPath, existingPath, unwrappedValue)
							if not shouldAllow then
								return
							end
						end
					end
				end
			end

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
				snapshot = self._changeDetector:CaptureSnapshot(self._rootTable, currentPath)
			end

			-- 2. Apply the change
			originalTable[key] = unwrappedValue

			-- 3. Detect changes (ChangeDetector compares new state against snapshot)
			if self._changeDetector and snapshot then
				self._changeDetector:CheckForChanges(snapshot)
			end

			-- 4. Update metadata
			if meta.IsArray then
				meta.ArrayLength = #originalTable
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
	Set the ChangeDetector instance to delegate change detection to.
]=]
function ProxyManager:SetChangeDetector(changeDetector: ChangeDetector)
	self._changeDetector = changeDetector
end

--[=[
	Set the callback for array insertions (appends only).
]=]
function ProxyManager:SetArrayInsertedCallback(callback: (path: PathArray<any>, index: number, newValue: any) -> ())
	self._onArrayInserted = callback
end

--[=[
	Set the callback fired when a non-append numeric index is directly assigned on an
	array proxy (e.g. `proxy[2] = value` when the array already has that slot).

	TableManager uses this to mark the array's batch log as poisoned, which forces
	Branch A (LCS snapshot diff) at flush time instead of the op-log coalescer.
]=]
function ProxyManager:SetBatchDirectArraySetCallback(callback: (path: PathArray<any>, index: number) -> ())
	self._onBatchDirectArraySet = callback
end

--[=[
	Set the callback fired for every non-array, non-append write through a proxy.
	Receives the **parent table's path** (the path of the proxy that owns the key
	that was written, i.e. NOT including the written key itself).

	TableManager uses this during a batch to record which top-level branches were
	dirtied so that the flush can diff only those branches instead of the whole tree.
]=]
function ProxyManager:SetBatchScalarWrittenCallback(callback: (parentPath: PathArray<any>) -> ())
	self._onBatchScalarWritten = callback
end

--[=[
	Set the callback fired for every proxy write before mutation.
	Returning `false` prevents the write. If an error message is returned it is raised.
]=]
function ProxyManager:SetValidateCallback(callback: (path: PathArray<any>, value: any) -> (boolean, string?))
	self._onValidateWrite = callback
end

--[=[
	Set the callback fired when a write would introduce a duplicate table reference.
	Return `true` to allow the write, `false` to suppress it.
]=]
function ProxyManager:SetDuplicateTableWriteCallback(callback: (
	writePath: PathArray<any>,
	existingPath: PathArray<any>,
	value: any
) -> boolean)
	self._onDuplicateTableWrite = callback
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
function ProxyManager.CreateProxy<T>(
	self: ProxyManager,
	original: T & { [any]: any },
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

	-- Create new proxy
	const proxy = newproxy(true) :: Proxy<T>
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
function ProxyManager.ReparentProxy(self: ProxyManager, proxy: Proxy<any>, newParentOriginal: any?, newKey: any?)
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

	self._changeDetector = nil
	self._onArrayInserted = nil
	self._onValidateWrite = nil
	self._onDuplicateTableWrite = nil
end

return ProxyManager
