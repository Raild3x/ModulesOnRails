--!strict
--[=[
	@ignore
	@class BaseReplicator

	Shared identity, hierarchy, tag, and discovery logic inherited by both
	`ServerReplicator` and `ClientReplicator` (classic Luau prototype-chain
	inheritance: a subclass module does
	`setmetatable({}, BaseReplicator)` so missing keys fall through to here).
]=]

const RunService = game:GetService("RunService")

const Types = require("./Types")
const Signal = Types.Signal
const Promise = Types.Promise
const Janitor = Types.Janitor
const TokenCache = require("./TokenCache")

type Promise<T...> = Types.Promise<T...>
type Id = Types.Id
type Tags = Types.Tags
type TableManager<T> = Types.TableManager<T>
type ReplicationToken = Types.ReplicationToken
type SearchCondition = Types.SearchCondition

--// Module-level (per-realm) registries //--
export type Realm = {
	Storage: { [Id]: BaseReplicator },
	CreationListeners: { [string]: { (replicator: BaseReplicator) -> () } },
	ReplicatorCreated: Types.Signal<(replicator: BaseReplicator) -> (), BaseReplicator>,
}

const function newRealm(): Realm
	return {
		Storage = {},
		CreationListeners = {},
		ReplicatorCreated = Signal.new() :: any,
	}
end

--// Volatile State //--
local nextId = 0

--------------------------------------------------------------------------------
--// Util Functions //--
--------------------------------------------------------------------------------

--[[
	Resolves a `SearchCondition` into a plain predicate function.
]]
const function reconcileCondition(condition: SearchCondition?): (replicator: BaseReplicator) -> boolean
	local conditionType = typeof(condition)

	if conditionType == "nil" then
		return function()
			return true
		end
	elseif conditionType == "function" then
		return condition :: any
	elseif conditionType == "string" then
		const tokenName = condition :: string
		return function(replicator)
			return replicator.Token.Name == tokenName
		end
	elseif conditionType == "table" then
		const asToken = condition :: ReplicationToken
		if TokenCache.isToken(asToken) then
			return function(replicator)
				return replicator.Token.Name == TokenCache.getTokenName(asToken)
			end
		end
		const tags = condition :: Tags
		return function(replicator)
			return replicator:HasTags(tags)
		end
	end

	error(`Invalid SearchCondition type: '{conditionType}'`)
end

--------------------------------------------------------------------------------
--// Class //--
--------------------------------------------------------------------------------

local BaseReplicator = {}
BaseReplicator.ClassName = "BaseReplicator"
BaseReplicator.__index = BaseReplicator

-- Test-only escape hatch: lets a spec swap in an independent realm (its own
-- Storage/CreationListeners/ReplicatorCreated) to simulate a second,
-- independent client in the same process -- see Tests/Helpers/
-- FakeIntermediary.luau. Defaults to one shared realm, matching today's
-- behavior exactly; production code never swaps this. Not part of the
-- public API.
BaseReplicator._Realm = newRealm()
BaseReplicator._NewRealm = newRealm

--[=[
	@tag Static
	@prop ServerReplicator.ReplicatorCreated Signal<ServerReplicator>
	Signal that fires whenever a new replicator is created, regardless of token.
]=]
--[=[
	@tag Static
	@prop ClientReplicator.ReplicatorCreated Signal<ClientReplicator>
	Signal that fires whenever a new replicator is created, regardless of token.
]=]
BaseReplicator.ReplicatorCreated = BaseReplicator._Realm.ReplicatorCreated -- re-export for convenience

-- Re-export types from Types module for convenience
export type BR_Public<BR> = Types.BR_Public<BR>
export type BR_Internal<BR = BR_Internal> = Types.BR_Internal<BR>
export type BaseReplicator = Types.BaseReplicator

--[=[
	@private
	@within BaseReplicator
	@tag Static
	Iterates every replicator currently in memory (`for _, replicator in BaseReplicator do`).
]=]
BaseReplicator.__iter = function()
	return next, BaseReplicator._Realm.Storage
end

--------------------------------------------------------------------------------
--// Static Discovery //--
--------------------------------------------------------------------------------

--[=[
	@tag Static
	@private
	Generates a fresh, process-unique replicator Id.
]=]
function BaseReplicator.GenerateId(): Id
	assert(RunService:IsServer(), "BaseReplicator.GenerateId should only be called on the server")
	nextId += 1
	return nextId
end

--[=[
	@tag Static
	@within ServerReplicator
	@function GetFromId
	@param id Id
	@return ServerReplicator?
	Returns the replicator with the given Id, if one currently exists.
]=]
--[=[
	@tag Static
	@within ClientReplicator
	@function GetFromId
	@param id Id
	@return ClientReplicator?
	Returns the replicator with the given Id, if one currently exists.
]=]
function BaseReplicator.GetFromId(id: Id): BaseReplicator?
	return BaseReplicator._Realm.Storage[id]
end

--[=[
	@tag Static
	@within ServerReplicator
	@function PromiseFromId
	@param id Id
	@return Promise<ServerReplicator>
	Returns a promise that resolves with the replicator with the given Id, if one currently exists or is created in the future.
]=]
--[=[
	@tag Static
	@within ClientReplicator
	@function PromiseFromId
	@param id Id
	@return Promise<ClientReplicator>
	Returns a promise that resolves with the replicator with the given Id, if one currently exists or is created in the future.
]=]
function BaseReplicator.PromiseFromId(id: Id): Promise<BaseReplicator>
	const existing = BaseReplicator.GetFromId(id)
	if existing then
		return Promise.resolve(existing)
	end
	return Promise.fromEvent(BaseReplicator._Realm.ReplicatorCreated, function(replicator)
		return replicator.Id == id
	end)
end


--[=[
	@tag Static
	@within ServerReplicator
	@function GetAll
	@param condition SearchCondition?
	@return { ServerReplicator }

	Returns every currently-loaded replicator matching `condition` (no condition = all).
]=]
--[=[
	@tag Static
	@within ClientReplicator
	@function GetAll
	@param condition SearchCondition?
	@return { ClientReplicator }

	Returns every currently-loaded replicator matching `condition` (no condition = all).
]=]
function BaseReplicator.GetAll(condition: SearchCondition?): { BaseReplicator }
	const satisfies = reconcileCondition(condition)
	const results = {}
	for _, replicator in BaseReplicator._Realm.Storage do
		if satisfies(replicator) then
			table.insert(results, replicator)
		end
	end
	return results
end

--[=[
	@tag Static
	@within ServerReplicator
	@function ForEach
	@param condition SearchCondition?
	@param fn (replicator: ServerReplicator) -> ()
	@return () -> ()

	Runs `fn` for every existing replicator matching `condition`, and again for
	every future one. Returns a disconnect function that stops future invocations.
]=]
--[=[
	@tag Static
	@within ClientReplicator
	@function ForEach
	@param condition SearchCondition?
	@param fn (replicator: ClientReplicator) -> ()
	@return () -> ()

	Runs `fn` for every existing replicator matching `condition`, and again for
	every future one. Returns a disconnect function that stops future invocations.
]=]
function BaseReplicator.ForEach(condition: SearchCondition?, fn: (replicator: BaseReplicator) -> ()): () -> ()
	const satisfies = reconcileCondition(condition)

	for _, replicator in BaseReplicator._Realm.Storage do
		if satisfies(replicator) then
			task.spawn(fn, replicator)
		end
	end

	const connection = BaseReplicator._Realm.ReplicatorCreated:Connect(function(replicator: BaseReplicator)
		if satisfies(replicator) then
			fn(replicator)
		end
	end)

	return function()
		connection:Disconnect()
	end
end

--[=[
	@tag Static
	@within ServerReplicator
	@function PromiseFirst
	@param condition SearchCondition?
	@return Promise<ServerReplicator>
	Resolves with the first existing-or-future replicator matching `condition`.
]=]
--[=[
	@tag Static
	@within ClientReplicator
	@function PromiseFirst
	@param condition SearchCondition?
	@return Promise<ClientReplicator>
	Resolves with the first existing-or-future replicator matching `condition`.
]=]
function BaseReplicator.PromiseFirst(condition: SearchCondition?): Promise<BaseReplicator>
	const satisfies = reconcileCondition(condition)
	for _, replicator in BaseReplicator._Realm.Storage do
		if satisfies(replicator) then
			return Promise.resolve(replicator)
		end
	end
	return Promise.fromEvent(BaseReplicator._Realm.ReplicatorCreated, satisfies)
end

--[=[
	@tag Static
	@within ServerReplicator
	@function GetFirst
	@param condition SearchCondition?
	@return ServerReplicator?
	Returns the first replicator matching `condition`, or nil if none exists.
]=]
--[=[
	@tag Static
	@within ClientReplicator
	@function GetFirst
	@param condition SearchCondition?
	@return ClientReplicator?
	Returns the first replicator matching `condition`, or nil if none exists.
]=]
function BaseReplicator.GetFirst(condition: SearchCondition?): BaseReplicator?
	const satisfies = reconcileCondition(condition)
	for _, replicator in BaseReplicator._Realm.Storage do
		if satisfies(replicator) then
			return replicator
		end
	end
	return nil
end

--[=[
	@tag Static
	@within ServerReplicator
	@function OnNew
	@param tokenName string
	@param fn (replicator: ServerReplicator) -> ()
	@return () -> ()
	Listens for new replicators whose token name matches `tokenName`. Returns
	a disconnect function.

	:::caution Hooking after RequestData
	Calling `OnNew` after `ClientReplicator.RequestData()` has already resolved
	will miss any replicators that were created in the initial snapshot. ForEach is
	the preferred way to listen for new replicators, since it also runs for any existing
	replicators that match the condition.
	:::
]=]
--[=[
	@tag Static
	@within ClientReplicator
	@function OnNew
	@param tokenName string
	@param fn (replicator: ClientReplicator) -> ()
	@return () -> ()
	Listens for new replicators whose token name matches `tokenName`. Returns
	a disconnect function.

	:::caution Hooking after RequestData
	Calling `OnNew` after `ClientReplicator.RequestData()` has already resolved
	will miss any replicators that were created in the initial snapshot. ForEach is
	the preferred way to listen for new replicators, since it also runs for any existing
	replicators that match the condition.
	:::
]=]
function BaseReplicator.OnNew(tokenName: string, fn: (replicator: BaseReplicator) -> ()): () -> ()
	const creationListeners = BaseReplicator._Realm.CreationListeners
	local listeners = creationListeners[tokenName]
	if listeners == nil then
		listeners = {}
		creationListeners[tokenName] = listeners
	end
	table.insert(listeners, fn)

	return function()
		-- Removes from the exact list `fn` was inserted into above, regardless
		-- of which realm is active by the time this disconnect runs.
		local index = table.find(listeners, fn)
		if index then
			table.remove(listeners, index)
		end
	end
end

--------------------------------------------------------------------------------
--// Constructor //--
--------------------------------------------------------------------------------

-- Shared base constructor for both `ServerReplicator` and `ClientReplicator` subclasses
function BaseReplicator.new(config: {
	Id: Id,
	Token: ReplicationToken,
	Tags: Tags?,
	Manager: TableManager<any>,
	Parent: BaseReplicator?,
}): BaseReplicator
	const self = setmetatable({}, BaseReplicator) :: BR_Internal

	self.Id = config.Id
	self.Tags = table.freeze(config.Tags or {})
	self.Manager = config.Manager
	self.Token = config.Token
	self._Parent = config.Parent :: BR_Internal?
	self._Children = {}
	self._CreationListenersFired = false
	
	self._Janitor = Janitor.new()
	self.ChildAdded = Signal.new(self._Janitor) :: any
	self.ChildRemoved = Signal.new(self._Janitor) :: any
	self.ParentChanged = Signal.new(self._Janitor) :: any

	if self._Parent then
		table.insert(self._Parent._Children, self)
	end

	BaseReplicator._Realm.Storage[self.Id] = self

	return self
end

--------------------------------------------------------------------------------
--// Lifecycle //--
--------------------------------------------------------------------------------

--[=[
	@private
	Fires every registered creation listener (and the global `ReplicatorCreated`
	signal) for this replicator's token. Subclasses call this once, after their
	own construction has fully finished.
]=]
function BaseReplicator._FireCreationListeners(self: BR_Internal)
	assert(not self._CreationListenersFired, "Creation listeners already fired for this replicator")
	self._CreationListenersFired = true

	const realm = BaseReplicator._Realm
	const listeners = realm.CreationListeners[self.Token.Name]
	if listeners then
		for _, listener in table.clone(listeners) do
			task.spawn(listener, self)
		end
	end
	realm.ReplicatorCreated:Fire(self)
end

--[=[
	@private
	Reparents `self` under `newParent` (or to no parent), updating both sides'
	child lists and firing `ChildAdded`/`ChildRemoved`/`ParentChanged`. Pure
	bookkeeping -- callers are responsible for any replication-specific work
	(syncing subscriptions, informing the wire, etc.) around this call.
]=]
function BaseReplicator._SetParentRefs(self: BR_Internal, newParent: BR_Internal?)
	const oldParent = self._Parent
	if oldParent == newParent then
		return
	end

	if oldParent then
		const index = table.find(oldParent._Children, self)
		if index then
			table.remove(oldParent._Children, index)
		end
	end

	self._Parent = newParent
	if newParent then
		table.insert(newParent._Children, self)
	end

	if oldParent then
		oldParent.ChildRemoved:Fire(self)
	end
	if newParent then
		newParent.ChildAdded:Fire(self)
	end
	self.ParentChanged:Fire(newParent, oldParent)
end

--[=[
	Base teardown: detaches from the parent (if any) and releases the janitor
	(signals, etc). Subclasses should call this via their parent metatable
	(`getmetatable(Subclass).Destroy(self)`) AFTER their own teardown.

	A replicator must never be destroyed while it still has children: a bare
	`_Parent = nil` would leave them silently (and incorrectly) top-level.
	Subclasses are responsible for reparenting or destroying their children
	(e.g. `ServerReplicator.Destroy` reparents them to `ServerReplicator.None`)
	before calling down into this.
]=]
function BaseReplicator.Destroy(self: BR_Internal)
	const parent = self._Parent
	if parent then
		const index = table.find(parent._Children, self)
		if index then
			table.remove(parent._Children, index)
		end
		parent.ChildRemoved:Fire(self)
	end

	assert(#self._Children == 0, "Cannot destroy a replicator that still has children -- reparent or destroy them first")

	BaseReplicator._Realm.Storage[self.Id] = nil
	self._Janitor:Destroy()
end

--------------------------------------------------------------------------------
--// Identity Getters //--
--------------------------------------------------------------------------------

--[=[
	@within ServerReplicator
	@method IsTopLevel
	@return boolean
	A top-level replicator has no parent. Only top-level replicators can have
	their replication targets set directly on the server.
]=]
--[=[
	@within ClientReplicator
	@method IsTopLevel
	@return boolean
	A top-level replicator has no parent. Only top-level replicators can have
	their replication targets set directly on the server.
]=]
function BaseReplicator.IsTopLevel(self: BR_Internal): boolean
	return self._Parent == nil
end

--------------------------------------------------------------------------------
--// Hierarchy //--
--------------------------------------------------------------------------------

--[=[
	@within ServerReplicator
	@method GetParent
	@return ServerReplicator?
	Gets the parent replicator, or nil if this is a top-level replicator.
]=]
--[=[
	@within ClientReplicator
	@method GetParent
	@return ClientReplicator?
	Gets the parent replicator, or nil if this is a top-level replicator.
]=]
function BaseReplicator.GetParent(self: BR_Internal): BR_Internal?
	return self._Parent
end

--[=[
	@within ServerReplicator
	@method GetChildren
	@return { ServerReplicator }
	Gets the immediate children of this replicator.
]=]
--[=[
	@within ClientReplicator
	@method GetChildren
	@return { ClientReplicator }
	Gets the immediate children of this replicator.
]=]
function BaseReplicator.GetChildren(self: BR_Internal): { BR_Internal }
	return table.clone(self._Children)
end

--[=[
	@within ServerReplicator
	@method GetDescendants
	@return { ServerReplicator }
	Gets all descendants of this replicator, recursively.
]=]
function BaseReplicator.GetDescendants(self: BR_Internal): { BR_Internal }
	const descendants = {}
	const function collect(parent: BR_Internal)
		for _, child in parent._Children do
			table.insert(descendants, child)
			collect(child)
		end
	end
	collect(self)
	return descendants
end

--[=[
	@within ServerReplicator
	@method FindFirstChild
	@param condition SearchCondition? -- optional predicate, token name, or tag set
	@param recursive boolean? -- whether to search recursively (default false)
	@return ServerReplicator?
	Finds the first child of this replicator that matches `condition`, or nil if none.
]=]
--[=[
	@within ClientReplicator
	@method FindFirstChild
	@param condition SearchCondition? -- optional predicate, token name, or tag set
	@param recursive boolean? -- whether to search recursively (default false)
	@return ClientReplicator?
	Finds the first child of this replicator that matches `condition`, or nil if none.
]=]
function BaseReplicator.FindFirstChild(
	self: BR_Internal,
	condition: SearchCondition?,
	recursive: boolean?
): BR_Internal?
	const satisfies = reconcileCondition(condition)

	for _, child in self._Children do
		if satisfies(child) then
			return child
		end
	end

	if recursive then
		for _, child in self._Children do
			const found = child:FindFirstChild(condition, true)
			if found then
				return found :: BR_Internal
			end
		end
	end

	return nil
end

function BaseReplicator.PromiseFirstChild(
	self: BR_Internal,
	condition: SearchCondition?
): Promise<BR_Internal>
	const existing = self:FindFirstChild(condition)
	if existing then
		return Promise.resolve(existing)
	end

	const satisfies = reconcileCondition(condition)
	return Promise.fromEvent(self.ChildAdded, satisfies)
end

--------------------------------------------------------------------------------
--// Tags //--
--------------------------------------------------------------------------------

--[=[
	True if every key/value in `tags` is also present on this replicator
]=]
function BaseReplicator.HasTags(self: BR_Internal, tags: Tags): boolean
	for tag, value in tags do
		if self.Tags[tag] ~= value then
			return false
		end
	end
	return true
end
BaseReplicator.IsSupersetOfTags = BaseReplicator.HasTags

--[=[
	True if every key/value on this replicator is also present in `tags`
	(ELI5: are all of this replicator's tags also in the given tags?).
]=]
function BaseReplicator.IsSubsetOfTags(self: BR_Internal, tags: Tags): boolean
	for tag, value in self.Tags do
		if tags[tag] ~= value then
			return false
		end
	end
	return true
end

return BaseReplicator
