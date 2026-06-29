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

const Signal = require("../../Signal")
const Janitor = require("../../Janitor")
const Promise = require("../../Promise")
const Types = require("./Types")
const TokenCache = require("./TokenCache")

type Id = Types.Id
type Tags = Types.Tags
type TableManager<T> = Types.TableManager<T>
type ReplicationToken = Types.ReplicationToken
type SearchCondition = Types.SearchCondition

--// Module-level (per-realm) registries //--
export type Realm = {
	Storage: { [Id]: BaseReplicator },
	CreationListeners: { [string]: { (replicator: BaseReplicator) -> () } },
	ReplicatorCreated: Signal.Signal<(replicator: BaseReplicator) -> (), BaseReplicator>,
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

--[=[
	Resolves a `SearchCondition` into a plain predicate function.
]=]
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
			return replicator:GetTokenName() == tokenName
		end
	elseif conditionType == "table" then
		const asToken = condition :: ReplicationToken
		if TokenCache.isToken(asToken) then
			return function(replicator)
				return replicator:GetTokenName() == TokenCache.getTokenName(asToken)
			end
		end
		const tags = condition :: Tags
		return function(replicator)
			return replicator:IsSupersetOfTags(tags)
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

-- Written as a plain structural interface (every method/field listed
-- explicitly) rather than `typeof(setmetatable(..., BaseReplicator))`: the
-- latter bakes in `BaseReplicator` (the table) as a NOMINAL `@metatable`
-- requirement, which then rejects a value whose metatable was rebound to a
-- subclass (`ServerReplicator`/`ClientReplicator`) as "unrelated types" on
-- cast, even though it structurally provides every member through its own
-- `__index` chain back to `BaseReplicator`. A bare structural interface has
-- no such requirement, so subclasses cast/assign cleanly.
export type BR_Public<BR> = {
	-- Signals
	ChildAdded: Signal.Signal<(child: BR) -> (), BR>,
	ChildRemoved: Signal.Signal<(child: BR) -> (), BR>,
	ParentChanged: Signal.Signal<
		(newParent: BR?, oldParent: BR?) -> (),
		BR?,
		BR?
	>,

	-- Readable Fields
	Id: Id,
	Tags: Tags,
	Manager: TableManager<any>,

	-- Methods
	GetTokenName: (self: BR) -> string,
	IsTopLevel: (self: BR) -> boolean,

	GetParent: (self: BR) -> BR?,
	GetChildren: (self: BR) -> { BR },
	GetDescendants: (self: BR) -> { BR },
	FindFirstChild: (self: BR, condition: SearchCondition?, recursive: boolean?) -> BR?,
	PromiseFirstChild: (self: BR, condition: SearchCondition?) -> Promise.TypedPromise<BR>,

	IsSupersetOfTags: (self: BR, tags: Tags) -> boolean,
	IsSubsetOfTags: (self: BR, tags: Tags) -> boolean,

	Destroy: (self: BR) -> (),
}

export type BR_Internal<BR = BR_Internal> = {
	_Token: ReplicationToken,
	_Parent: BR?,
	_Children: { BR },
	_Janitor: Janitor.Janitor,
	_CreationListenersFired: boolean,

	_FireCreationListeners: (self: BR) -> (),
	_SetParentRefs: (self: BR, newParent: BR?) -> (),
} & BR_Public<BR>

export type BaseReplicator = BR_Public<BaseReplicator>

--[=[
	@tag Static
	Iterates every replicator currently in memory (`for _, replicator in BaseReplicator do`).
]=]
BaseReplicator.__iter = function()
	return next, (BaseReplicator :: any)._Realm.Storage
end

--------------------------------------------------------------------------------
--// Static Discovery //--
--------------------------------------------------------------------------------

--[=[
	@tag Static
	Returns the replicator with the given Id, if one currently exists.
]=]
function BaseReplicator.GetFromId(id: Id): BaseReplicator?
	return (BaseReplicator :: any)._Realm.Storage[id]
end

--[=[
	@tag Static

	Generates a fresh, process-unique replicator Id.
]=]
function BaseReplicator.GenerateId(): Id
	assert(RunService:IsServer(), "BaseReplicator.GenerateId should only be called on the server")
	nextId += 1
	return nextId
end

--[=[
	@tag Static
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
	Resolves with the first existing-or-future replicator matching `condition`.
]=]
function BaseReplicator.PromiseFirst(condition: SearchCondition?): Promise.TypedPromise<BaseReplicator>
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
	Listens for new replicators whose token name matches `tokenName`. Returns
	a disconnect function.
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
	self._Token = config.Token
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
	Fires every registered creation listener (and the global `ReplicatorCreated`
	signal) for this replicator's token. Subclasses call this once, after their
	own construction has fully finished.
]=]
function BaseReplicator._FireCreationListeners(self: BR_Internal)
	assert(not self._CreationListenersFired, "Creation listeners already fired for this replicator")
	self._CreationListenersFired = true

	const realm = BaseReplicator._Realm
	const listeners = realm.CreationListeners[self:GetTokenName()]
	if listeners then
		for _, listener in table.clone(listeners) do
			task.spawn(listener, self)
		end
	end
	realm.ReplicatorCreated:Fire(self)
end

--[=[
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

	Does not cascade to children -- they remain discoverable and stay alive,
	orphaned (their `_Parent` is cleared so a later `:Destroy()` on one of
	them doesn't reach back into this now-torn-down replicator's signals).
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

	for _, child in self._Children do
		child._Parent = nil
	end

	BaseReplicator._Realm.Storage[self.Id] = nil
	self._Janitor:Destroy()
end

--------------------------------------------------------------------------------
--// Identity Getters //--
--------------------------------------------------------------------------------

function BaseReplicator.GetTokenName(self: BR_Internal): string
	return TokenCache.getTokenName(self._Token)
end

--[=[
	A top-level replicator has no parent. Only top-level replicators can have
	their replication targets set directly on the server.
]=]
function BaseReplicator.IsTopLevel(self: BR_Internal): boolean
	return self._Parent == nil
end

--------------------------------------------------------------------------------
--// Hierarchy //--
--------------------------------------------------------------------------------

function BaseReplicator.GetParent(self: BR_Internal): BR_Internal?
	return self._Parent
end

function BaseReplicator.GetChildren(self: BR_Internal): { BR_Internal }
	return table.clone(self._Children)
end

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
): Promise.TypedPromise<BR_Internal>
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
	(ELI5: are all the given tags also on this replicator?).
]=]
function BaseReplicator.IsSupersetOfTags(self: BR_Internal, tags: Tags): boolean
	for tag, value in tags do
		if self.Tags[tag] ~= value then
			return false
		end
	end
	return true
end

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
