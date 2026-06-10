--!strict
-- Authors: Logan Hunt (Raildex)
-- June 09, 2026
--[=[
	@class ProxyNode

	Unified proxy node for the ProxyGraph reactive data-graph. A single
	ProxyNode class handles scalar, table, and array modes. All mutable
	state lives in module-level tables keyed by proxy userdata identity so
	that the proxy objects themselves carry no visible Lua fields.

	## Data model
	`_nodeValue[proxy]` is the authoritative raw data:
	  - Scalar mode: the scalar value itself.
	  - Table/Array mode: a plain Lua table that is mutated IN PLACE as
	    descendant values change. Child proxy _nodeValue[child] tables share
	    the same table reference as _nodeValue[parent][key], so scalar writes
	    propagate back via explicit parent-sync; nested table writes propagate
	    automatically through the shared reference.

	## Parent tracking
	`_weakParents[child]` is a weak-keyed table `{[parentProxy]: key}`.
	Parents hold strong references to children via `_children[parent][key]`.
	When a parent is GC'd (via Scope cleanup), its entry in `_weakParents`
	disappears automatically.
]=]

const Propagation = require("./Propagation")
const Batch = require("./Batch")
const Diff = require("./Diff")
const Signals = require("./Signals")
const Types = require("./Types")

-- Internal raw userdata type; keeps all module-level tables keyed by identity.
-- External consumers use Types.Proxy<T> (the generic public type) instead.
type Proxy<T = any> = Types.Proxy<T>
type NodeMode = Types.NodeMode
type Connection = Types.Connection
type SetOptions = Types.SetOptions

-- ─── Module-level state (all keyed by proxy userdata) ────────────────────────

local _nodeValue: { [Proxy]: any } = {}
local _nodeMode: { [Proxy]: NodeMode } = {}
local _children: { [Proxy]: { [any]: Proxy } } = {}
local _weakParents: { [Proxy]: { [Proxy]: any } } = {} -- child → weak{parent: key}
local _isOpaque: { [Proxy]: { [any]: boolean } } = {} -- (Phase 9)
local _destroyed: { [Proxy]: boolean } = {}

-- Shared with Propagation so the same table is used for generation stamps.
local _nodeGeneration: { [any]: number } = Propagation._nodeGeneration

-- ─── OpaqueWrapper sentinel ───────────────────────────────────────────────────

local OpaqueWrapperMeta = {}
OpaqueWrapperMeta.__index = OpaqueWrapperMeta

local function isOpaqueWrapper(v: any): boolean
	return type(v) == "table" and getmetatable(v) == OpaqueWrapperMeta
end

-- ─── Helpers ─────────────────────────────────────────────────────────────────

local RESERVED: { [string]: boolean } = {
	Get = true,
	Set = true,
	Remove = true,
	Insert = true,
	Find = true,
	Destroy = true,
	DestroyChain = true,
}

local function isProxy(v: any): boolean
	return type(v) == "userdata" and _nodeMode[v :: Proxy] ~= nil
end

local function determineMode(value: any): NodeMode
	if type(value) ~= "table" then
		return "scalar"
	end
	local count = 0
	local maxIdx = 0
	for k in value do
		if type(k) ~= "number" or k ~= math.floor(k) or k < 1 then
			return "table"
		end
		count += 1
		if k > maxIdx then
			maxIdx = k
		end
	end
	return if count == maxIdx then "array" else "table"
end

-- Deep copy of raw value for :Get() return. Follows proxy references to
-- produce a plain-Lua snapshot.
local function deepCopy<T>(value: T): T
	if isProxy(value) then
		return deepCopy(_nodeValue[value :: Proxy])
	elseif type(value) ~= "table" then
		return value
	end
	local copy: { [any]: any } = {}
	for k, v in value :: { [any]: any } do
		copy[k] = deepCopy(v)
	end
	return copy :: any
end

-- ─── Impl table (set / reconcileChildren mutual recursion) ───────────────────
-- Both functions call each other. Storing them in a named table means each
-- body looks up the sibling at CALL time, removing the need for forward
-- declarations.

type ImplType = {
	set: (node: Proxy, newValue: any, genOverride: number?) -> (),
	reconcileChildren: (proxy: Proxy, diffNode: Diff.DiffNode, newData: { [any]: any }, gen: number) -> (),
}

local impl = {} :: ImplType

-- ─── Public table ────────────────────────────────────────────────────────────

local ProxyNode = {}

-- ─── Parent walk ─────────────────────────────────────────────────────────────

local function walkParents(node: Proxy, generation: number, newValue: any, oldValue: any)
	local parents = _weakParents[node]
	if parents == nil then
		return
	end
	for parent in parents do
		if _nodeGeneration[parent] == generation then
			continue
		end
		_nodeGeneration[parent] = generation
		Signals.tryFire(Signals.peek("onChange", parent), newValue, oldValue)
		walkParents(parent, generation, newValue, oldValue)
	end
end

-- ─── Signal firing ───────────────────────────────────────────────────────────

local function fireNodeChange(node: Proxy, newValue: any, oldValue: any, generation: number)
	_nodeGeneration[node] = generation
	Signals.tryFire(Signals.peek("onValueChange", node), newValue, oldValue)
	Signals.tryFire(Signals.peek("onChange", node), newValue, oldValue)
	walkParents(node, generation, newValue, oldValue)
end

-- ─── Structural reconciliation ────────────────────────────────────────────────

impl.reconcileChildren = function(proxy: Proxy, diffNode: Diff.DiffNode, newData: { [any]: any }, gen: number)
	local children = diffNode.children
	if children == nil then
		return
	end

	local myChildren = _children[proxy]
	local rawTable: { [any]: any } = _nodeValue[proxy]

	for key, childDiff in children do
		if childDiff.type == "removed" then
			local childProxy = myChildren[key]
			myChildren[key] = nil
			rawTable[key] = nil
			if childProxy ~= nil and _weakParents[childProxy] ~= nil then
				_weakParents[childProxy][proxy] = nil
			end
			Signals.tryFire(Signals.peek("onKeyRemoved", proxy), key, childProxy)
		elseif childDiff.type == "added" then
			local addedValue = newData[key]
			rawTable[key] = addedValue
			if myChildren[key] ~= nil then
				impl.set(myChildren[key], addedValue, gen)
			end
			Signals.tryFire(Signals.peek("onKeyAdded", proxy), key, myChildren[key])
		elseif childDiff.type == "changed" then
			rawTable[key] = childDiff.new
			local childProxy = myChildren[key]
			if childProxy ~= nil then
				impl.set(childProxy, childDiff.new, gen)
			end
		elseif childDiff.type == "descendantChanged" then
			local childProxy = myChildren[key]
			if childProxy ~= nil then
				_nodeGeneration[childProxy] = gen
				impl.reconcileChildren(childProxy, childDiff, newData[key], gen)
				if not Batch.isBatching() then
					Signals.tryFire(Signals.peek("onChange", childProxy), rawTable[key], childDiff.old)
				else
					Batch.record(childProxy, childDiff.old, rawTable[key])
				end
			end
		end
	end
end

-- ─── Internal set ────────────────────────────────────────────────────────────

impl.set = function(node: Proxy, newValue: any, genOverride: number?)
	local currentValue = _nodeValue[node]
	if newValue == currentValue then
		return
	end

	local gen: number
	if genOverride ~= nil then
		gen = genOverride
	else
		gen = Propagation.beginWrite()
	end

	-- Stamp self FIRST so that walkParents calls from child impl.set invocations
	-- stop here and don't reach our ancestors before we're ready to fire.
	_nodeGeneration[node] = gen

	local mode = _nodeMode[node]
	local oldValue: any = currentValue

	if mode == "scalar" then
		_nodeValue[node] = newValue
		local parents = _weakParents[node]
		if parents ~= nil then
			for parent, key in parents do
				local parentRaw: { [any]: any } = _nodeValue[parent]
				if type(parentRaw) == "table" then
					parentRaw[key] = newValue
				end
			end
		end
	elseif mode == "table" or mode == "array" then
		if type(newValue) == "table" then
			local newMode = determineMode(newValue)
			_nodeMode[node] = newMode
			local diffResult = Diff.diff(currentValue, newValue)
			if diffResult == nil then
				if genOverride == nil then
					Propagation.endWrite()
				end
				return
			end
			impl.reconcileChildren(node, diffResult, newValue, gen)
			oldValue = nil
		else
			_nodeMode[node] = "scalar"
			_nodeValue[node] = newValue
			local myChildren = _children[node]
			for _, child in myChildren do
				if _weakParents[child] ~= nil then
					_weakParents[child][node] = nil
				end
			end
			table.clear(myChildren)
			local parents = _weakParents[node]
			if parents ~= nil then
				for parent, key in parents do
					local parentRaw: { [any]: any } = _nodeValue[parent]
					if type(parentRaw) == "table" then
						parentRaw[key] = newValue
					end
				end
			end
		end
	end

	local currentRawValue = _nodeValue[node]
	if Batch.isBatching() then
		Batch.record(node, oldValue, currentRawValue)
	else
		Signals.tryFire(Signals.peek("onValueChange", node), currentRawValue, oldValue)
		Signals.tryFire(Signals.peek("onChange", node), currentRawValue, oldValue)
		walkParents(node, gen, currentRawValue, oldValue)
	end

	if genOverride == nil then
		Propagation.endWrite()
	end
end

-- Register the batch flush callback (wires Batch → ProxyNode without circular dep).
Batch.registerFlushFn(function(items: { { node: any, new: any, old: any } })
	local gen = Propagation.beginWrite()
	for _, item in ipairs(items) do
		fireNodeChange(item.node :: Proxy, item.new, item.old, gen)
	end
	Propagation.endWrite()
end)

-- ─── Method closures returned by __index for reserved keys ───────────────────

local function method_Get<T>(self: Proxy<T>): T
	return deepCopy(_nodeValue[self])
end

local function method_Set(self: Proxy, newValue: any, _opts: SetOptions?)
	impl.set(self, newValue)
end

local function method_Remove(self: Proxy, key: any)
	local mode = _nodeMode[self]
	if mode ~= "table" and mode ~= "array" then
		error("Remove() is only valid on table or array proxies", 2)
	end
	local rawTable: { [any]: any } = _nodeValue[self]
	if rawTable[key] == nil then
		return
	end

	local gen = Propagation.beginWrite()
	_nodeGeneration[self] = gen

	local childProxy = _children[self][key]
	_children[self][key] = nil
	rawTable[key] = nil
	if childProxy ~= nil and _weakParents[childProxy] ~= nil then
		_weakParents[childProxy][self] = nil
	end
	Signals.tryFire(Signals.peek("onKeyRemoved", self), key, childProxy)

	if Batch.isBatching() then
		Batch.record(self, rawTable, rawTable)
	else
		Signals.tryFire(Signals.peek("onChange", self), rawTable, rawTable)
		walkParents(self, gen, rawTable, rawTable)
	end

	Propagation.endWrite()
end

-- ─── Destroy / DestroyChain ───────────────────────────────────────────────────

-- Destroys `proxy`: destroys (and disconnects all listeners from) its
-- signals, unlinks it from any parents, and clears its module-level state.
-- Idempotent — safe to call more than once. Does NOT touch this proxy's
-- children; see destroyChain for recursive teardown.
local function destroyNode(proxy: Proxy)
	if _destroyed[proxy] then
		return
	end
	_destroyed[proxy] = true

	Signals.destroy(proxy)

	local parents = _weakParents[proxy]
	if parents ~= nil then
		for parent, key in parents do
			if _children[parent] ~= nil and _children[parent][key] == proxy then
				_children[parent][key] = nil
			end
		end
	end

	_weakParents[proxy] = nil :: any
	_children[proxy] = nil :: any
	_nodeValue[proxy] = nil
	_nodeMode[proxy] = nil :: any
	_isOpaque[proxy] = nil :: any
	_nodeGeneration[proxy] = nil :: any
end

-- Recursively destroys `proxy` and all of its descendant ProxyNodes
-- (leaf-first), then `proxy` itself. A child is destroyed even if it is
-- also referenced as a child elsewhere in the graph.
local function destroyChain(proxy: Proxy)
	local children = _children[proxy]
	if children ~= nil then
		local snapshot = table.clone(children)
		for _, child in snapshot do
			destroyChain(child)
		end
	end
	destroyNode(proxy)
end

local function method_Destroy(self: Proxy)
	destroyNode(self)
end

local function method_DestroyChain(self: Proxy)
	destroyChain(self)
end

-- ─── Proxy metatable ─────────────────────────────────────────────────────────
-- Defined before ProxyNode.new so all metamethod copies are taken from a
-- complete table.  __index and __newindex reference `createChild` which is
-- defined immediately after ProxyNode.new — both are only called from user
-- code (after the module finishes loading), so there is no ordering issue.

local ProxyMeta = {}
ProxyMeta.__metatable = "The metatable is locked."

ProxyMeta.__iter = function(proxy: Proxy): any
	local rawTable: { [any]: any } = _nodeValue[proxy]
	if type(rawTable) ~= "table" then
		return function()
			return nil :: any, nil :: any
		end, {} :: { [any]: any }, nil
	end
	return next, rawTable, nil
end

ProxyMeta.__len = function(proxy: Proxy): number
	local rawTable: { [any]: any } = _nodeValue[proxy]
	if type(rawTable) ~= "table" then
		return 0
	end
	return #rawTable
end

ProxyMeta.__tostring = function(proxy: Proxy): string
	local mode = _nodeMode[proxy]
	return `ProxyNode({mode})`
end

ProxyMeta.__eq = function(a: Proxy, b: Proxy): boolean
	return rawequal(a, b)
end

-- ─── ProxyNode.new ───────────────────────────────────────────────────────────
-- Defined before createChild because createChild calls ProxyNode.new.
-- ProxyMeta is already populated with all non-createChild metamethods above;
-- __index and __newindex are assigned below (after createChild is defined).
-- Since ProxyNode.new is only called from user code / createChild (both of
-- which happen after the module finishes loading), ProxyMeta is always fully
-- populated by the time the copy occurs.

function ProxyNode.new<T>(value: T): Types.Proxy<T>
	local proxy = newproxy(true) :: Proxy
	local mt: any = getmetatable(proxy)
	for k, v in ProxyMeta :: any do
		mt[k] = v
	end

	local mode = determineMode(value)
	_nodeMode[proxy] = mode
	_children[proxy] = {}
	_weakParents[proxy] = setmetatable({}, { __mode = "k" }) :: { [Proxy]: any }
	_isOpaque[proxy] = {}

	if mode == "scalar" then
		_nodeValue[proxy] = value
	else
		_nodeValue[proxy] = if type(value) == "table" then table.clone(value) else value
	end

	return (proxy :: any) :: Types.Proxy<T>
end

-- ─── createChild (defined after ProxyNode.new) ───────────────────────────────

local function createChild(parent: Proxy, key: any, value: any): Proxy
	local child = ProxyNode.new(value)
	_weakParents[child][parent] = key
	_children[parent][key] = child
	local parentRaw: { [any]: any } = _nodeValue[parent]
	if parentRaw ~= nil and type(value) == "table" then
		parentRaw[key] = _nodeValue[child]
	end
	return child
end

-- ─── ProxyMeta.__index / __newindex (defined after createChild) ───────────────

ProxyMeta.__index = function(proxy: Proxy, key: any): any
	if key == "Get" then
		return method_Get
	elseif key == "Set" then
		return method_Set
	elseif key == "Remove" then
		return method_Remove
	elseif key == "Destroy" then
		return method_Destroy
	elseif key == "DestroyChain" then
		return method_DestroyChain
	end

	local mode = _nodeMode[proxy]
	if mode ~= "table" and mode ~= "array" then
		return nil
	end

	local opaqueSlots = _isOpaque[proxy]
	if opaqueSlots ~= nil and opaqueSlots[key] then
		local rawTable: { [any]: any } = _nodeValue[proxy]
		return rawTable ~= nil and rawTable[key] or nil
	end

	local myChildren = _children[proxy]
	local existing = myChildren[key]
	if existing ~= nil then
		return existing
	end

	local rawTable: { [any]: any } = _nodeValue[proxy]
	if rawTable == nil then
		return nil
	end
	local rawValue = rawTable[key]
	if rawValue == nil then
		return nil
	end

	return createChild(proxy, key, rawValue)
end

ProxyMeta.__newindex = function(proxy: Proxy, key: any, value: any)
	if RESERVED[key] then
		error(`Cannot assign to reserved key "{tostring(key)}" on a ProxyNode`, 2)
	end

	local mode = _nodeMode[proxy]
	if mode == "scalar" then
		error("Cannot assign a field to a scalar ProxyNode", 2)
	end

	local myChildren = _children[proxy]
	local rawTable: { [any]: any } = _nodeValue[proxy]

	if isProxy(value) then
		local vProxy = value :: Proxy
		local existingChild = myChildren[key]
		if existingChild ~= nil and existingChild ~= vProxy then
			if _weakParents[existingChild] ~= nil then
				_weakParents[existingChild][proxy] = nil
			end
			myChildren[key] = nil
		end
		if _weakParents[vProxy] == nil then
			_weakParents[vProxy] = setmetatable({}, { __mode = "k" }) :: { [Proxy]: any }
		end
		_weakParents[vProxy][proxy] = key
		myChildren[key] = vProxy
		rawTable[key] = _nodeValue[vProxy]

		local gen = Propagation.beginWrite()
		_nodeGeneration[proxy] = gen
		if Batch.isBatching() then
			Batch.record(proxy, rawTable, rawTable)
		else
			Signals.tryFire(Signals.peek("onChange", proxy), rawTable, rawTable)
			walkParents(proxy, gen, rawTable, rawTable)
		end
		Propagation.endWrite()
		return
	end

	local existingChild = myChildren[key]
	if existingChild ~= nil then
		impl.set(existingChild, value)
	else
		local isNew = rawTable[key] == nil
		rawTable[key] = value

		local gen = Propagation.beginWrite()
		_nodeGeneration[proxy] = gen

		createChild(proxy, key, value)

		if isNew then
			Signals.tryFire(Signals.peek("onKeyAdded", proxy), key, myChildren[key])
		end

		if Batch.isBatching() then
			Batch.record(proxy, rawTable, rawTable)
		else
			Signals.tryFire(Signals.peek("onValueChange", proxy), rawTable, rawTable)
			Signals.tryFire(Signals.peek("onChange", proxy), rawTable, rawTable)
			walkParents(proxy, gen, rawTable, rawTable)
		end

		Propagation.endWrite()
	end
end

-- ─── Public API ──────────────────────────────────────────────────────────────

function ProxyNode.getSignals(proxy: any): Types.SignalsTable
	return Signals.getSignals(proxy :: Proxy)
end

function ProxyNode.isProxy(v: any): boolean
	return isProxy(v)
end

function ProxyNode.makeOpaqueWrapper<T>(value: T): { _opaqueValue: T }
	return setmetatable({ _opaqueValue = value }, OpaqueWrapperMeta) :: any
end

function ProxyNode.isOpaqueWrapper(v: any): boolean
	return isOpaqueWrapper(v)
end

--[=[
	Returns the raw internal value for `proxy` without copying. For scalars
	this is the scalar value; for table/array proxies this is the live mutable
	table. Intended for read-only use inside Computed/Effect `use()` calls.
]=]
function ProxyNode.peek(proxy: any): any
	return _nodeValue[proxy :: Proxy]
end

--[=[
	Returns the OnValueChange signal for `proxy`, creating it lazily on first
	call. Used by Computed/Effect to subscribe without allocating the full
	signals wrapper table.
]=]
function ProxyNode.getOnValueChangeSignal(proxy: any): Types.AnySignal
	return Signals.getOnValueChangeSignal(proxy :: Proxy)
end

return ProxyNode
