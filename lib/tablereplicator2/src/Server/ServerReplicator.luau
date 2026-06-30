--!strict
--[=[
	@class ServerReplicator
	@server

	Replicates a TableManager2 instance to a set of players. Inherits from
	`BaseReplicator` (see there for the `Manager`/`Tags` fields, `GetParent`,
	`GetChildren`, `FindFirstChild`, etc).

	```lua
	local PlayerToken = ServerReplicator.Token("PlayerData")

	Players.PlayerAdded:Connect(function(player)
		local replicator = ServerReplicator.new({
			Token = PlayerToken,
			Data = { Coins = 0 },
			ReplicationTargets = player,
			Tags = { UserId = player.UserId },
		})
	end)
	```
]=]

const Players = game:GetService("Players")

const BaseReplicator = require("../Shared/BaseReplicator")
const Types = require("../Shared/Types")
const TableManagerModule = Types.TableManager
const ReplicationScope = require("./ReplicationScope")
const FrameCoordinator = require("./FrameCoordinator")
const ServerTransportModule = require("../Shared/Transport/ServerTransport")
const FlatCodec = require("../Shared/Serialization/FlatCodec")
const MessageCodec = require("../Shared/Serialization/MessageCodec")
const TokenCache = require("../Shared/TokenCache")

const REPLICATE_TO_ALL = "all"

type Id = Types.Id
type Tags = Types.Tags
type ReplicationToken = Types.ReplicationToken
type ReplicationTargets = Types.ReplicationTargets
type TableManager<T> = Types.TableManager<T>
type WireItem = Types.WireItem
type ServerTransport = ServerTransportModule.ServerTransport

--------------------------------------------------------------------------------
--// Class //--
--------------------------------------------------------------------------------

local ServerReplicator = setmetatable({}, BaseReplicator)
ServerReplicator.ClassName = "ServerReplicator"
ServerReplicator.__index = ServerReplicator

type SR_Public<SR> = {
	SetTargets: (self: SR, targets: ReplicationTargets) -> (),
	AddTarget: (self: SR, target: Player | { Player }) -> (),
	RemoveTarget: (self: SR, target: Player | { Player }) -> (),
	GetTargets: (self: SR) -> { Player },
	IsReplicatingTo: (self: SR, player: Player) -> boolean,
	SetParent: (self: SR, newParent: SR?) -> (),
}

type SR_Internal = {
	_Scope: ReplicationScope.ReplicationScope,
	_Coalesced: boolean,
	_Unreliable: boolean,

	_SendSnapshotTo: (self: SR_Internal, player: Player) -> (),
	_AddTarget: (self: SR_Internal, player: Player) -> (),
	_RemoveTarget: (self: SR_Internal, player: Player) -> (),
} & SR_Public<SR_Internal> & BaseReplicator.BR_Internal<SR_Internal>

export type ServerReplicator = SR_Public<ServerReplicator> & BaseReplicator.BR_Public<ServerReplicator>

--------------------------------------------------------------------------------
--// Module-level: transport, token registry, top-level bookkeeping //--
--------------------------------------------------------------------------------

const transport: ServerTransport = ServerTransportModule.new()

-- Test-only escape hatch: lets a spec spy on/replace `SendMessage`/
-- `NotifyDataSent` on the real singleton transport without needing a live
-- second client. Not part of the public API.
ServerReplicator._Transport = transport

-- The single server-wide ordering point for outbound data ops. Every scope's
-- `OnApplied` ops funnel here so they replay on the client in exact server
-- order regardless of which replicator produced them (per-scope flushing could
-- not guarantee that). Structural items are still sent directly below.
const frameCoordinator = FrameCoordinator.new(transport)

-- Test-only escape hatch: lets a spec force a deterministic flush of the
-- global per-frame op buffer instead of waiting for the deferred one.
ServerReplicator._FrameCoordinator = frameCoordinator

-- Every top-level replicator currently alive; the request-data handshake and
-- cross-scope `SetParent` walk this to find scopes.
const topLevelReplicators: { SR_Internal } = {}

-- A player who has completed the request-data handshake at least once.
-- Mirrors v1's global ACTIVE_PLAYERS set: a second `RequestData` from the
-- same player (e.g. a reconnect race) is a no-op rather than re-sending
-- every scope's snapshot a second time.
const hasBootstrapped: { [Player]: true } = {}

--[=[
	Depth-first collects `root` and every descendant into `out`, parents
	always appearing before their children -- the order a client needs to
	apply `Create` items in.
]=]
const function collectSubtree(root: SR_Internal, out: { SR_Internal })
	table.insert(out, root)
	for _, child in root:GetChildren() do
		collectSubtree(child, out)
	end
end

const function buildCreateItem(replicator: SR_Internal): WireItem
	const parent = replicator:GetParent()
	return FlatCodec.CreateItem(
		replicator.Id,
		if parent then parent.Id else nil,
		replicator:GetTokenName(),
		replicator.Tags,
		replicator.Manager.Raw
	)
end

--[=[
	Appends one `Create` item per replicator in `root`'s subtree (parent
	before child) onto `out`.
]=]
const function buildSnapshotItems(root: SR_Internal, out: { WireItem })
	const subtree = {}
	collectSubtree(root, subtree)
	for _, replicator in subtree do
		table.insert(out, buildCreateItem(replicator))
	end
end

const function isTableManager(value: any): boolean
	return type(value) == "table" and (value :: any).Raw ~= nil and type((value :: any).Set) == "function"
end

--[=[
	Builds an encoded wire message from `items` via `MessageCodec.Encode`.
	Shared tables are interned in-band by BufferCodec's identity tracking.
]=]
const function buildMessage(items: { WireItem }): (buffer, { Instance }?)
	return MessageCodec.Encode(items)
end

--------------------------------------------------------------------------------
--// Static: Token //--
--------------------------------------------------------------------------------

--[=[
	@tag Static
	@prop Token (name: string) -> ReplicationToken
	Creates a unique `ReplicationToken` identifying a replicator "class" to
	the client. May only be called once per `tokenName`; store and reuse the
	returned token rather than calling this again with the same name.

	This is intended to help prevent accidental collisions between different
	replicators in the same experience.
]=]
ServerReplicator.Token = setmetatable({
	new = TokenCache.registerNewToken,
	get = TokenCache.getExistingToken,
}, {
	__call = function(_, name: string): ReplicationToken
		return TokenCache.registerNewToken(name)
	end,
})
table.freeze(ServerReplicator.Token)

--------------------------------------------------------------------------------
--// Constructor //--
--------------------------------------------------------------------------------

--[=[
	@tag Static

	Creates a new `ServerReplicator`. Exactly one of `Parent` or
	`ReplicationTargets` must be given: a top-level replicator is created with
	`ReplicationTargets` (pass `{}` to start with none), and a child
	replicator is created with `Parent` and inherits its top-level ancestor's
	targets.
]=]
function ServerReplicator.new(config: {
	Token: ReplicationToken,
	Data: (TableManager<any> | { [any]: any })?,
	ReplicationTargets: ReplicationTargets?,
	Parent: ServerReplicator?,
	Tags: Tags?,
	Coalesced: boolean?, -- TODO: implement coalescing
}): ServerReplicator
	local token = config.Token
	if typeof(token) == "string" then
		warn("Avoid using raw strings for tokens; use ServerReplicator.Token instead")
		token = TokenCache.getOrCreateToken(token)
	end
	assert(TokenCache.isToken(token), "Invalid Token")

	local  targets = config.ReplicationTargets
	if typeof(targets) == "string" then
		targets = targets:lower()
	end

	const parent = config.Parent :: SR_Internal?
	if parent then
		assert(targets == nil, "Cannot specify ReplicationTargets when creating a child replicator")
	else
		assert(targets ~= nil, "Top-level replicators must be given ReplicationTargets (pass {} for none)")
	end

	local manager: TableManager<any>
	const data = (config.Data or {}) :: unknown
	if isTableManager(data) then
		manager = data :: TableManager<any>
	else
		manager = TableManagerModule.new(data)
	end

	const base = BaseReplicator.new {
		Id = BaseReplicator.GenerateId(),
		Token = token,
		Tags = config.Tags,
		Manager = manager,
		Parent = parent,
	}
	const self = setmetatable(base, ServerReplicator) :: SR_Internal

	if parent then
		self._Scope = parent._Scope
	else
		self._Scope = ReplicationScope.new(transport)
		table.insert(topLevelReplicators, self)
	end

	const managerDestroyedConn = manager:OnDestroy(function()
		self:Destroy()
	end)
	self._Janitor:Add(managerDestroyedConn)

	const disconnectApplied = manager:OnApplied(function(op)
		frameCoordinator:QueueOp(self._Scope, self.Id, op)
	end)
	self._Janitor:Add(disconnectApplied)

	if parent then
		parent.ChildAdded:Fire(self)
		const buf, instances = buildMessage { buildCreateItem(self) }
		for _, player in self._Scope:GetActivePlayers() do
			self._Scope:SendTo(player, buf, instances)
		end
	else
		self:SetTargets(targets :: ReplicationTargets)
	end

	self:_FireCreationListeners()
	return self
end

--------------------------------------------------------------------------------
--// Targeting //--
--------------------------------------------------------------------------------

--[=[
	@private
	Sends `replicator`'s subtree to `player` and marks them active in `replicator`'s scope.
]=]
function ServerReplicator._SendSnapshotTo(self: SR_Internal, player: Player)
	const items = {}
	buildSnapshotItems(self, items)
	const buf, instances = buildMessage(items)
	self._Scope:SendTo(player, buf, instances)
end

function ServerReplicator._AddTarget(self: SR_Internal, player: Player)
	local scope = self._Scope
	if scope:IsTargeting(player) then
		return
	end
	if hasBootstrapped[player] then
		scope:Activate(player)
		self:_SendSnapshotTo(player)
	else
		scope:AddPending(player)
	end
end

function ServerReplicator._RemoveTarget(self: SR_Internal, player: Player)
	const scope = self._Scope
	if scope:IsActive(player) then
		scope:RemoveActive(player)
		const buf, instances = buildMessage { FlatCodec.DestroyItem(self.Id) }
		scope:SendTo(player, buf, instances)
	else
		scope:RemovePending(player)
	end
end

--[=[
	Overwrites this top-level replicator's replication targets.
]=]
function ServerReplicator.SetTargets(self: SR_Internal, targets: ReplicationTargets)
	assert(self:IsTopLevel(), "Cannot set replication targets on a non-top-level replicator")
	const scope = self._Scope

	if targets == REPLICATE_TO_ALL then
		if scope:IsReplicatingToAll() then
			return
		end
		scope:SetAll(true)
		for _, player in Players:GetPlayers() do
			if hasBootstrapped[player] and not scope:IsActive(player) then
				scope:Activate(player)
				self:_SendSnapshotTo(player)
			end
		end
		return
	end

	scope:SetAll(false)

	const desired: { [Player]: true } = {}
	const list: { Player } = if typeof(targets) == "Instance" then { targets :: Player } else targets :: { Player }
	for _, player in list do
		desired[player] = true
	end

	for player in desired do
		self:_AddTarget(player)
	end

	for _, player in scope:GetTargetPlayers() do
		if not desired[player] then
			self:_RemoveTarget(player)
		end
	end
end

--[=[
	Adds a player (or list of players) to this top-level replicator's targets.
]=]
function ServerReplicator.AddTarget(self: SR_Internal, target: Player | { Player })
	assert(self:IsTopLevel(), "Cannot add a replication target on a non-top-level replicator")
	if self._Scope:IsReplicatingToAll() then
		return
	end
	local list: { Player } = if typeof(target) == "Instance" then { target :: Player } else target :: { Player }
	for _, player in list do
		self:_AddTarget(player)
	end
end

--[=[
	Removes a player (or list of players) from this top-level replicator's targets.
]=]
function ServerReplicator.RemoveTarget(self: SR_Internal, target: Player | { Player })
	assert(self:IsTopLevel(), "Cannot remove a replication target on a non-top-level replicator")
	const list: { Player } = if typeof(target) == "Instance" then { target :: Player } else target :: { Player }
	for _, player in list do
		self:_RemoveTarget(player)
	end
end

function ServerReplicator.GetTargets(self: SR_Internal): { Player }
	return self._Scope:GetTargetPlayers()
end

function ServerReplicator.IsReplicatingTo(self: SR_Internal, player: Player): boolean
	return self._Scope:IsTargeting(player)
end

--------------------------------------------------------------------------------
--// Hierarchy //--
--------------------------------------------------------------------------------

--[=[
	Reparents `self` under `newParent`. If they share a top-level ancestor,
	every currently-active player just gets a `SetParent` item. Otherwise
	`self`'s whole subtree moves to `newParent`'s scope: a player active in
	the new scope but not the old one gets a fresh snapshot, a player active
	in the old scope but not targeted by the new one gets a `Destroy`, and a
	player active in both just gets `SetParent`.
]=]
function ServerReplicator.SetParent(self: SR_Internal, newParent: SR_Internal)
	assert(not self:IsTopLevel(), "Cannot SetParent a top-level replicator")
	assert(newParent ~= nil, "newParent is required")

	do
		local current: SR_Internal? = newParent
		while current do
			if current == self then
				error("Cannot parent a replicator to one of its own descendants")
			end
			current = current:GetParent()
		end
	end

	const oldParent = self:GetParent()
	if oldParent == newParent then
		return
	end

	const oldScope = self._Scope
	const newScope = newParent._Scope

	if oldScope == newScope then
		self:_SetParentRefs(newParent)
		const buf, instances = buildMessage { FlatCodec.SetParentItem(self.Id, newParent.Id) }
		for _, player in oldScope:GetActivePlayers() do
			oldScope:SendTo(player, buf, instances)
		end
		return
	end

	const subtree: { SR_Internal } = {}
	collectSubtree(self, subtree)
	for _, replicator in subtree do
		replicator._Scope = newScope
	end

	self:_SetParentRefs(newParent)

	local oldActive = oldScope:GetActivePlayers()
	local oldActiveSet: { [Player]: true } = {}
	for _, player in oldActive do
		oldActiveSet[player] = true
	end

	for _, player in oldActive do
		if newScope:IsTargeting(player) then
			const buf, instances = buildMessage { FlatCodec.SetParentItem(self.Id, newParent.Id) }
			newScope:SendTo(player, buf, instances)
		else
			const buf, instances = buildMessage { FlatCodec.DestroyItem(self.Id) }
			newScope:SendTo(player, buf, instances)
		end
	end

	for _, player in newScope:GetTargetPlayers() do
		if newScope:IsActive(player) and not oldActiveSet[player] then
			local items = {}
			buildSnapshotItems(self, items)
			const buf, instances = buildMessage(items)
			newScope:SendTo(player, buf, instances)
		end
	end
end

--------------------------------------------------------------------------------
--// Lifecycle //--
--------------------------------------------------------------------------------

function ServerReplicator.Destroy(self: SR_Internal)
	-- Drop any ops queued earlier this frame so they can't flush out after the
	-- (synchronous) Destroy item below and reference a torn-down replicator.
	frameCoordinator:DropReplicator(self.Id)

	const buf, instances = buildMessage { FlatCodec.DestroyItem(self.Id) }
	for _, player in self._Scope:GetActivePlayers() do
		self._Scope:SendTo(player, buf, instances)
	end

	if self:IsTopLevel() then
		const index = table.find(topLevelReplicators, self)
		if index then
			table.remove(topLevelReplicators, index)
		end
	end

	getmetatable(ServerReplicator).Destroy(self)
end

--------------------------------------------------------------------------------
--// Request-data handshake //--
--------------------------------------------------------------------------------

transport.PlayerRequestedData:Connect(function(player: Player)
	if hasBootstrapped[player] then
		return
	end
	hasBootstrapped[player] = true

	const items: { WireItem } = {}
	for _, top in topLevelReplicators do
		if top._Scope:IsTargeting(player) then
			top._Scope:Activate(player)
			buildSnapshotItems(top, items)
		end
	end

	if #items > 0 then
		const buf, instances = buildMessage(items)
		transport:SendMessage(player, buf, instances)
	end
	transport:NotifyDataSent(player)
end)

transport.PlayerRemoving:Connect(function(player: Player)
	hasBootstrapped[player] = nil
	for _, top in topLevelReplicators do
		top._Scope:RemovePlayer(player)
	end
end)

--------------------------------------------------------------------------------
--// Finalization //--
--------------------------------------------------------------------------------

local allToken = ServerReplicator.Token("ServerReplicator.All")
local noneToken = ServerReplicator.Token("ServerReplicator.None")

--[=[
	@within ServerReplicator
	@prop All ServerReplicator
	A top-level replicator that replicates to every current and future
	player. Useful as a `Parent` for children that should always be visible
	to everyone. Do not modify it directly -- only parent to it.
]=]
ServerReplicator.All = ServerReplicator.new {
	Token = allToken,
	Data = {},
	ReplicationTargets = REPLICATE_TO_ALL,
}

--[=[
	@within ServerReplicator
	@prop None ServerReplicator
	A top-level replicator that replicates to nobody. Useful as a `Parent`
	for children that should exist on the server only. Do not modify it
	directly -- only parent to it.
]=]
ServerReplicator.None = ServerReplicator.new {
	Token = noneToken,
	Data = {},
	ReplicationTargets = {},
}

return ServerReplicator
