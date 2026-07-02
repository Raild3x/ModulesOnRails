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
type FireMode = Types.FireMode

--// Module-level (per-realm) registries //--
export type Realm = {
	Storage: { [Id]: BaseReplicator },
	ReplicatorCreated: Types.Signal<(replicator: BaseReplicator) -> (), BaseReplicator>,
}

const function newRealm(): Realm
	return {
		Storage = {},
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
	String and token conditions compare against `replicator.Namespace`; anonymous
	replicators (Namespace == nil) never match either.
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
		const nameToMatch = condition :: string
		return function(replicator)
			return (replicator :: any).Namespace == nameToMatch
		end
	elseif conditionType == "table" then
		const asToken = condition :: ReplicationToken
		if TokenCache.isToken(asToken) then
			const nameToMatch = TokenCache.getTokenName(asToken)
			return function(replicator)
				return (replicator :: any).Namespace == nameToMatch
			end
		end
		const tags = condition :: Tags
		return function(replicator)
			return replicator:HasTags(tags)
		end
	end

	error(`Invalid SearchCondition type: '{conditionType}'`)
end

-- Cached probe for whether the current `Workspace.SignalBehavior` resolves to
-- deferred BindableEvent firing -- same technique `better-signal`'s internal
-- `IsDeferred` helper uses (not reused directly: it's a private `@self`-scoped
-- module inside the installed package, not part of its public API).
local cachedIsSignalBehaviorDeferred: boolean? = nil
const function isSignalBehaviorDeferred(): boolean
	if cachedIsSignalBehaviorDeferred == nil then
		const bindable = Instance.new("BindableEvent")
		local ran = false
		bindable.Event:Once(function()
			ran = true
		end)
		bindable:Fire()
		bindable:Destroy()
		cachedIsSignalBehaviorDeferred = not ran
	end
	return cachedIsSignalBehaviorDeferred :: boolean
end

-- Dispatches `fn(replicator)` per `mode`, mirroring how `Signal:Fire` /
-- `:FireDeferred` / `:FireBindable` would schedule a connected handler. Used
-- for discovery paths that don't go through an actual `Signal:Fire` call --
-- namely `ForEach`'s already-existing-matches loop -- so their scheduling
-- stays consistent with `ReplicatorCreated`'s.
const function dispatchListener(mode: FireMode, fn: (replicator: BaseReplicator) -> (), replicator: BaseReplicator)
	if mode == "deferred" then
		task.defer(fn, replicator)
	elseif mode == "bindable" then
		if isSignalBehaviorDeferred() then
			task.defer(fn, replicator)
		else
			task.spawn(fn, replicator)
		end
	else
		task.spawn(fn, replicator)
	end
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

--[=[
	@tag Static
	@prop BaseReplicator.ListenerFireMode FireMode
	How discovery listeners (`ReplicatorCreated`, `ForEach`, `OnNew`) are
	scheduled when a matching replicator is found. Defaults to `"bindable"`.
	Read-only -- use `SetListenerFireMode` to change it.
]=]
BaseReplicator.ListenerFireMode = "bindable" :: FireMode

--[=[
	@tag Static
	@within ServerReplicator
	@function SetListenerFireMode
	@param mode FireMode
	Overrides `ListenerFireMode`, the scheduling used for `ReplicatorCreated`,
	`ForEach`, and `OnNew` listeners going forward.
]=]
--[=[
	@tag Static
	@within ClientReplicator
	@function SetListenerFireMode
	@param mode FireMode
	Overrides `ListenerFireMode`, the scheduling used for `ReplicatorCreated`,
	`ForEach`, and `OnNew` listeners going forward.
]=]
function BaseReplicator.SetListenerFireMode(mode: FireMode)
	BaseReplicator.ListenerFireMode = mode
end

-- Re-export types from Types module for convenience
export type BR_Public<BR> = Types.BR_Public<BR>
export type BR_Internal<BR = BR_Internal> = Types.BR_Internal<BR>
export type BaseReplicator = Types.BaseReplicator

--[=[
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

	```lua
	local disconnect = ServerReplicator.ForEach("PlayerData", function(replicator)
		print("replicator", replicator.Id, "for", replicator.Tags.UserId)
	end)
	-- later:
	disconnect()
	```
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

	```lua
	-- By namespace string:
	local disconnect = ClientReplicator.ForEach("PlayerData", function(replicator)
		replicator.Manager:Observe("Coins", function(coins)
			print("Coins:", coins)
		end)
	end)

	-- By tag predicate:
	ClientReplicator.ForEach({ UserId = localPlayer.UserId }, function(replicator)
		-- only fires for the local player's replicator
	end)
	```
]=]
function BaseReplicator.ForEach(condition: SearchCondition?, fn: (replicator: BaseReplicator) -> ()): () -> ()
	const satisfies = reconcileCondition(condition)
	const mode = BaseReplicator.ListenerFireMode

	for _, replicator in BaseReplicator._Realm.Storage do
		if satisfies(replicator) then
			dispatchListener(mode, fn, replicator)
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

	```lua
	ClientReplicator.PromiseFirst("PlayerData"):andThen(function(replicator)
		print("Got PlayerData replicator:", replicator.Id)
	end)
	```
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
	@param condition SearchCondition
	@param fn (replicator: ServerReplicator) -> ()
	@return () -> ()
	Listens for *new* replicators matching `condition`. `condition` accepts the
	same forms as `GetAll`/`ForEach`: a namespace string, a `ReplicationToken`,
	a tags table, or a custom predicate. Returns a disconnect function.

	:::caution Prefer ForEach
	`OnNew` only fires for replicators created **after** this call. Use `ForEach`
	to also handle any already-existing matches (it runs the callback for those
	immediately, then subscribes for future ones).
	:::
]=]
--[=[
	@tag Static
	@within ClientReplicator
	@function OnNew
	@param condition SearchCondition
	@param fn (replicator: ClientReplicator) -> ()
	@return () -> ()
	Listens for *new* replicators matching `condition`. Returns a disconnect function.

	:::caution Prefer ForEach
	`OnNew` only fires for replicators created **after** this call. Call `ForEach`
	to handle any already-existing matches too. If called after `RequestData` has
	resolved, any replicators in the initial snapshot will be missed.
	:::
]=]
function BaseReplicator.OnNew(condition: SearchCondition, fn: (replicator: BaseReplicator) -> ()): () -> ()
	const satisfies = reconcileCondition(condition)
	-- `fn` is called directly (not task.spawn'd here): ReplicatorCreated's
	-- own Fire/FireDeferred/FireBindable call in `_FireCreationListeners`
	-- already schedules each connected handler per `ListenerFireMode`.
	const connection = BaseReplicator._Realm.ReplicatorCreated:Connect(function(replicator: BaseReplicator)
		if satisfies(replicator) then
			fn(replicator)
		end
	end)
	return function()
		connection:Disconnect()
	end
end

--------------------------------------------------------------------------------
--// Constructor //--
--------------------------------------------------------------------------------

-- Shared base constructor for both `ServerReplicator` and `ClientReplicator` subclasses.
-- `Namespace` accepts a string, a ReplicationToken, or nil (anonymous).
-- Both `self.Namespace` (string?) and `self.Token` (handle?) are set from it.
function BaseReplicator.new(config: {
	Id: Id,
	Namespace: (string | ReplicationToken)?,
	Tags: Tags?,
	Manager: TableManager<any>,
	Parent: BaseReplicator?,
}): BaseReplicator
	const self = setmetatable({}, BaseReplicator) :: BR_Internal

	-- Normalize namespace: token -> use as-is; string -> resolve handle; nil -> anonymous.
	local namespace: string? = nil
	local token: ReplicationToken? = nil
	local rawNs = config.Namespace
	if rawNs ~= nil then
		if TokenCache.isToken(rawNs) then
			token = rawNs :: ReplicationToken
			namespace = token.Name
		elseif typeof(rawNs) == "string" and rawNs ~= "" then
			namespace = rawNs :: string
			token = TokenCache.getOrCreateToken(namespace)
		end
	end

	self.Id = config.Id
	self.Namespace = namespace
	self.Token = token
	self.Tags = table.freeze(config.Tags or {})
	self.Manager = config.Manager
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
	Fires the global `ReplicatorCreated` signal for this replicator.
	`OnNew` listeners are connected directly to that signal; no per-name bucket
	is needed. Subclasses call this once, after their own construction finishes.
]=]
function BaseReplicator._FireCreationListeners(self: BR_Internal)
	assert(not self._CreationListenersFired, "Creation listeners already fired for this replicator")
	self._CreationListenersFired = true

	const signal = BaseReplicator._Realm.ReplicatorCreated
	const mode = BaseReplicator.ListenerFireMode
	if mode == "deferred" then
		signal:FireDeferred(self)
	elseif mode == "bindable" then
		signal:FireBindable(self)
	else
		signal:Fire(self)
	end
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
	Returns true if this replicator has no parent. Only top-level replicators
	can have their replication targets set directly.
]=]
--[=[
	@within ClientReplicator
	@method IsTopLevel
	@return boolean
	Returns true if this replicator has no parent.
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
--[=[
	@within ClientReplicator
	@method GetDescendants
	@return { ClientReplicator }
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

--[=[
	@within ServerReplicator
	@method PromiseFirstChild
	@param condition SearchCondition?
	@return Promise<ServerReplicator>
	Returns a Promise that resolves with the first child matching `condition`.
	Resolves immediately if a matching child already exists; otherwise waits for
	one to be added.
]=]
--[=[
	@within ClientReplicator
	@method PromiseFirstChild
	@param condition SearchCondition?
	@return Promise<ClientReplicator>
	Returns a Promise that resolves with the first child matching `condition`.
	Resolves immediately if a matching child already exists; otherwise waits for
	one to be added.
]=]
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
	@within ServerReplicator
	@method HasTags
	@param tags Tags
	@return boolean
	Returns true if every key/value in `tags` is present on this replicator.
	`IsSupersetOfTags` is an alias for this method.
]=]
--[=[
	@within ClientReplicator
	@method HasTags
	@param tags Tags
	@return boolean
	Returns true if every key/value in `tags` is present on this replicator.
	`IsSupersetOfTags` is an alias for this method.
]=]
function BaseReplicator.HasTags(self: BR_Internal, tags: Tags): boolean
	for tag, value in tags do
		if self.Tags[tag] ~= value then
			return false
		end
	end
	return true
end

--[=[
	@within ServerReplicator
	@method IsSupersetOfTags
	@param tags Tags
	@return boolean
	Alias for `HasTags`.
]=]
--[=[
	@within ClientReplicator
	@method IsSupersetOfTags
	@param tags Tags
	@return boolean
	Alias for `HasTags`.
]=]
BaseReplicator.IsSupersetOfTags = BaseReplicator.HasTags

--[=[
	@within ServerReplicator
	@method IsSubsetOfTags
	@param tags Tags
	@return boolean
	Returns true if every key/value on this replicator is present in `tags`.
	The inverse of `HasTags`: this replicator's tags must be a subset of `tags`.
]=]
--[=[
	@within ClientReplicator
	@method IsSubsetOfTags
	@param tags Tags
	@return boolean
	Returns true if every key/value on this replicator is present in `tags`.
	The inverse of `HasTags`: this replicator's tags must be a subset of `tags`.
]=]
function BaseReplicator.IsSubsetOfTags(self: BR_Internal, tags: Tags): boolean
	for tag, value in self.Tags do
		if tags[tag] ~= value then
			return false
		end
	end
	return true
end

--------------------------------------------------------------------------------
--// Deprecated //--
--------------------------------------------------------------------------------

function BaseReplicator.GetTokenName(self: BR_Internal): string
	warn("BaseReplicator.GetToken is deprecated; use .Namespace instead:", debug.traceback())
	return self.Namespace or ""
end

return BaseReplicator
