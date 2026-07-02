--!strict
--!native
--!optimize 2
--[=[
	@class ServerReplicator
	@server

	Wraps a `TableManager` and replicates it to one or more clients. Every write
	made through `.Manager` is automatically queued and sent at the end of the
	current frame.

	```lua
	Players.PlayerAdded:Connect(function(player)
		local replicator = ServerReplicator.new({
			Namespace = "PlayerData",
			Data = { Coins = 0 },
			Targets = player,
			Tags = { UserId = player.UserId },
		})

		replicator.Manager:Set("Coins", 100) -- replicated automatically

		player.Destroying:Connect(function()
			replicator:Destroy()
		end)
	end)
	```

	:::caution Always destroy when done
	Call `replicator:Destroy()` when a replicator is no longer needed. The replicator
	also listens to its manager's `OnDestroy` and tears itself down, so destroying
	the manager is sufficient when the manager's lifetime drives cleanup.
	:::

	### Going further
	- **Namespace collision safety** — See `TOKEN` for exclusive namespace ownership
	  in large codebases.
	- **Hierarchy** — Pass `Parent` instead of `ReplicationTargets` to create a child
	  replicator that inherits its ancestor's targets. Use `SetParent` to reparent later.
	- **Custom remotes** — Declare signals and functions in `config.Client` to send
	  events alongside data. See `RegisterRemoteSignal`, `RegisterOrderedRemoteSignal`,
	  `RegisterRemoteFunction`, and `RegisterOrderedRemoteFunction`.
	- **Flush control** — `Coalesced = true` deduplicates redundant same-key ops per
	  frame. `ImmediateFlush = true` sends this replicator's ops synchronously
	  (before the caller's next line) instead of batching to frame end.
	- **Sentinels** — `ServerReplicator.All` and `ServerReplicator.None` are
	  pre-built top-level replicators useful as parents.
]=]

const Players = game:GetService("Players")

const Types = require("../Shared/Types")
const TableManagerModule = Types.TableManager
const ReplicationScope = require("./ReplicationScope")
const BaseReplicator = require("../Shared/BaseReplicator")
const FrameCoordinatorModule = require("./FrameCoordinator")
const ServerTransportModule = require("../Shared/Transport/ServerTransport")
const Protocol = require("../Shared/Transport/Protocol")
const FlatCodec = require("../Shared/Serialization/FlatCodec")
const MessageCodec = require("../Shared/Serialization/MessageCodec")
const TokenCache = require("../Shared/TokenCache")
const ServerCustomRemote = require("./ServerCustomRemote")

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

type SR_Public<SR> = Types.SR_Public<SR>
type SR_Internal = Types.SR_Internal

export type ServerReplicator = Types.ServerReplicator

--------------------------------------------------------------------------------
--// Module-level: transport, token registry, top-level bookkeeping //--
--------------------------------------------------------------------------------

const transport = ServerTransportModule.new()

-- Test-only escape hatch
ServerReplicator._Transport = transport

-- The single server-wide ordering point for outbound data ops.
const frameCoordinator = FrameCoordinatorModule.new(transport)

-- Test-only escape hatch
ServerReplicator._FrameCoordinator = frameCoordinator

-- Every top-level replicator currently alive.
const topLevelReplicators: { SR_Internal } = {}

-- A player who has completed the request-data handshake at least once.
const hasBootstrapped: { [Player]: true } = {}

-- Depth-first collects `root` and every descendant into `out`, parents
-- always appearing before their children -- the order a client needs to
-- apply `Create` items in.
const function collectSubtree(root: SR_Internal, out: { SR_Internal })
	table.insert(out, root)
	for _, child in root:GetChildren() do
		collectSubtree(child, out)
	end
end

const function buildRemotesMap(replicator: SR_Internal): { [string]: string }?
	local remotes: { [string]: string } = {}
	for name, remote in (replicator :: any)._RemoteSignals do
		local r: any = remote
		if r._Coordinator ~= nil then
			remotes[name] = "OrderedSignal"
		elseif r._Unreliable then
			remotes[name] = "Unreliable"
		else
			remotes[name] = "Signal"
		end
	end
	for name in (replicator :: any)._RemoteFunctions do
		if (replicator :: any)._OrderedFunctions[name] then
			remotes[name] = "OrderedFunction"
		else
			remotes[name] = "Function"
		end
	end
	return if next(remotes) then remotes else nil
end

const function buildCreateItem(replicator: SR_Internal): WireItem
	const parent = replicator:GetParent()
	return FlatCodec.CreateItem(
		replicator.Id,
		if parent then parent.Id else nil,
		replicator.Namespace or "",
		replicator.Tags,
		replicator.Manager.Raw,
		buildRemotesMap(replicator)
	)
end

-- Appends one `Create` item per replicator in `root`'s subtree (parent
-- before child) onto `out`.
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

-- Builds an encoded wire message from `items` via `MessageCodec.Encode`.
-- Shared tables are interned in-band by BufferCodec's identity tracking.
const function buildMessage(items: { WireItem }): (buffer, { Instance }?)
	return MessageCodec.Encode(items)
end

-- Sends a metadata Signal op to all currently-active players in `replicator`'s
-- scope so they can update their ClientCustomRemote type info. Called whenever
-- a remote is registered after players may already have received the snapshot.
const function sendRemoteMeta(replicator: SR_Internal, name: string, kind: string)
	local scope = replicator._Scope
	if scope == nil then return end -- called during new() before _Scope is assigned
	const active = scope:GetActivePlayers()
	if #active == 0 then return end
	const op: Types.BufferedOp = { Kind = "Signal", Path = { Protocol.REMOTE_META }, Value = { name, kind } }
	const opsItem = FlatCodec.OpsItem(replicator.Id, { op :: any })
	const buf, instances = buildMessage { opsItem }
	for _, player in active do
		replicator._Scope:SendTo(player, buf, instances)
	end
end

--------------------------------------------------------------------------------
--// Static: Token //--
--------------------------------------------------------------------------------

--[=[
	@within ServerReplicator
	@tag Static
	@prop TOKEN (name: string) -> ReplicationToken
	Registers `name` in the namespace-ownership ledger and returns a
	`ReplicationToken` that exclusively owns that name for its lifetime.

	Using a token prevents any other system from accidentally creating a
	replicator with the same namespace string. Call this once per name
	(usually at the top of a module), store the result, and pass it as the
	`Namespace` (or `Token`) field when creating replicators.

	To release the name, call `ServerReplicator.TOKEN.destroy(token)` after all
	replicators using it have been destroyed.

	**You do not need a token** for simple cases — a plain string `Namespace`
	is fully supported and costs nothing extra:
	```lua
	-- Simple (no collision guard):
	ServerReplicator.new({ Namespace = "PlayerData", ... })

	-- Opt-in collision safety:
	local PlayerToken = ServerReplicator.TOKEN("PlayerData")
	ServerReplicator.new({ Namespace = PlayerToken, ... })
	```

	:::caution One owner per name
	`TOKEN("name")` errors if the name is already owned by another live token
	**or** if any raw-string replicators with that name already exist. Claim the
	token at module load before creating any replicators with that name.
	:::
]=]
ServerReplicator.TOKEN = setmetatable({
	new = TokenCache.registerToken,
	get = TokenCache.getExistingToken,
	destroy = TokenCache.destroyToken,
}, {
	__call = function(_, name: string): ReplicationToken
		return TokenCache.registerToken(name)
	end,
})
table.freeze(ServerReplicator.TOKEN)
ServerReplicator.Token = ServerReplicator.TOKEN -- Backwards compat alias

-- Deprecated no-op; raw strings are now accepted without a warning.
ServerReplicator.SuppressTokenWarnings = false

-- Unique sentinel values used inside a `config.Client` table to declare remotes.
-- Checked by identity so they can't be confused with user data.
local REMOTE_EVENT_SENTINEL = table.freeze({})
local UNRELIABLE_REMOTE_EVENT_SENTINEL = table.freeze({})

--[=[
	@within ServerReplicator
	@tag Static
	@prop createRemoteEvent () -> sentinel
	Returns a sentinel value for use in `config.Client` to declare a reliable
	custom signal. The sentinel is detected by `ServerReplicator.new` and
	replaced with a real `ServerCustomRemote`.

	```lua
	local r = ServerReplicator.new({
		Namespace = "MyReplicator",
		ReplicationTargets = player,
		Client = {
			Hit = ServerReplicator.createRemoteEvent(),
			GetScore = function(self, player) return 42 end,
		},
	})
	r.Client.Hit:FireAll()
	```
]=]
ServerReplicator.createRemoteEvent = function(): any
	return REMOTE_EVENT_SENTINEL
end

--[=[
	@within ServerReplicator
	@tag Static
	@prop createUnreliableEvent () -> sentinel
	Like `createRemoteEvent` but uses an `UnreliableRemoteEvent` so fire-and-forget
	semantics apply (no ordering or delivery guarantee).
]=]
ServerReplicator.createUnreliableEvent = function(): any
	return UNRELIABLE_REMOTE_EVENT_SENTINEL
end

--------------------------------------------------------------------------------
--// Constructor //--
--------------------------------------------------------------------------------

--[=[
	@tag Static
	@within ServerReplicator
	@function new

	Creates a new `ServerReplicator`.

	Exactly one of `Parent` or `ReplicationTargets` must be given: a top-level
	replicator is created with `ReplicationTargets` (pass `{}` to start with
	none), and a child replicator is created with `Parent` and inherits its
	top-level ancestor's targets.

	Config table fields:
	- `Namespace` - Optional string or `ReplicationToken` identifying the
	  replicator's class. Pass a plain string for simple cases, or a token
	  from `ServerReplicator.TOKEN()` for opt-in collision safety. Omit for
	  anonymous replicators (reachable only by Id, tags, or predicate).
	- `Data` - A `TableManager` instance or a raw table to replicate. Defaults to `{}`.
	- `Targets` - A `Player`, list of `Player`s, or `"all"`. Only valid
	  for top-level replicators; pass `{}` to start with no targets.
	- `Parent` - A parent `ServerReplicator`. Only valid for child replicators.
	- `Tags` - Optional `{ [string]: any }` metadata table used for filtering in
	  `ForEach`/`GetAll`/`GetFirst`.
	- `Coalesced` - If true, only the latest op per key is sent at frame end,
	  dropping intermediate writes. Defaults to false.
	- `ImmediateFlush` - If true, this replicator's ops are flushed to the wire
	  synchronously (before the caller's next line) instead of at frame end, so a
	  write lands before any external `RemoteEvent` fired in the same frame. Only
	  this replicator is flushed; others keep their normal frame batching. Because
	  each write sends immediately, N separate non-batched `Set`s produce N
	  messages -- wrap bulk writes in `manager:Batch(...)` to coalesce them into a
	  single immediate send at the end of the batch.
	- `Client` - Table declaring custom remotes. Values can be
	  `ServerReplicator.createRemoteEvent()`, `ServerReplicator.createUnreliableEvent()`,
	  or plain functions (registered as remote functions). See `RegisterRemoteSignal`.

	:::caution Namespace collision guard
	If you call `ServerReplicator.TOKEN("name")` to claim a namespace, any
	attempt to create a replicator with that name as a raw string will throw.
	Pass the token object directly instead of the string. Conversely, if raw-
	string replicators already exist for a name, `TOKEN()` will refuse to claim
	it until they are all destroyed.
	:::

	:::caution Conflicting Configurations
	The following configurations are invalid and will throw an error:
	- `Targets` and `Parent` cannot both be specified.
	- `Coalesced` and `ImmediateFlush` cannot both be true.
	:::
]=]
function ServerReplicator.new(config: {
	Namespace: (string | ReplicationToken)?,
	Data: (TableManager<any> | { [any]: any })?,
	Targets: ReplicationTargets?,
	Parent: ServerReplicator?,
	Tags: Tags?,
	Coalesced: boolean?,
	ImmediateFlush: boolean?,
	Client: { [string]: any }?,
}): ServerReplicator
	local rawNs: (string | ReplicationToken)? = config.Namespace or (config :: any).Token
	local resolvedNamespace: string? = nil
	local wasExplicitToken = false

	if rawNs ~= nil then
		if TokenCache.isToken(rawNs) then
			wasExplicitToken = true
			resolvedNamespace = TokenCache.getTokenName(rawNs :: ReplicationToken)
		elseif typeof(rawNs) == "string" and rawNs ~= "" then
			resolvedNamespace = rawNs :: string
		end
	end

	-- Ledger enforcement (server-only collision guard).
	if resolvedNamespace ~= nil then
		TokenCache.acquireNamespace(resolvedNamespace, rawNs :: string | ReplicationToken, wasExplicitToken)
	end

	local targets = config.Targets or (config :: any).ReplicationTargets
	if typeof(targets) == "string" then
		targets = targets:lower()
	end

	const parent = config.Parent :: SR_Internal?
	if parent then
		assert(targets == nil, "Cannot specify replication Targets when creating a child replicator")
	else
		assert(targets ~= nil, "Top-level replicators must be given replication Targets (pass {} for none)")
	end

	assert(not (config.Coalesced and config.ImmediateFlush), "Cannot set both Coalesced and ImmediateFlush")

	local manager: TableManager<any>
	const data = (config.Data or (config :: any).Manager or {}) :: unknown
	if isTableManager(data) then
		manager = data :: TableManager<any>
	else
		manager = TableManagerModule.new(data)
	end

	---------------------------------------------------------
	const base = BaseReplicator.new {
		Id = BaseReplicator.GenerateId(),
		Namespace = rawNs,
		Tags = config.Tags,
		Manager = manager,
		Parent = parent,
	}
	const self = setmetatable(base, ServerReplicator) :: SR_Internal
	self._Coalesced = config.Coalesced == true
	self._ImmediateFlush = config.ImmediateFlush == true
	self._ImmediateBatchOpen = false
	self._RemoteSignals = {}
	self._RemoteFunctions = {}
	self._OrderedFunctions = {}

	---------------------------------------------------------
	-- Build the Client proxy. __newindex routes sentinel/function assignments
	-- to the appropriate Register* method; direct rawset values (e.g. the
	-- registered ServerCustomRemote) are returned via normal __index.
	do
		const clientProxy = {}
		setmetatable(clientProxy, {
			__newindex = function(_t, k, v)
				const val = v :: any
				if val == REMOTE_EVENT_SENTINEL then
					self:RegisterOrderedRemoteSignal(k)
				elseif val == UNRELIABLE_REMOTE_EVENT_SENTINEL then
					self:RegisterRemoteUnreliableSignal(k)
				elseif type(val) == "function" then
					self:RegisterOrderedRemoteFunction(k, val)
				else
					warn(`ServerReplicator.Client: invalid declaration for '{k}'. Use createRemoteEvent(), createUnreliableEvent(), or a function.`)
				end
			end,
		})
		self.Client = clientProxy :: any

		-- Apply config.Client declarations up front so they're ready before any
		-- _FireCreationListeners callbacks run.
		for k, v in config.Client or {} do
			self.Client[k] = v
		end
	end

	---------------------------------------------------------
	const managerDestroyedConn = manager:OnDestroy(function()
		self:Destroy() -- TR shouldnt outlive its manager, but if it does, destroy the replicator to avoid dangling references
	end)
	self._Janitor:Add(managerDestroyedConn)

	const disconnectApplied = manager:OnApplied(function(op: Types.AppliedOp)
		frameCoordinator:QueueOp(self._Scope, self.Id, op, self._Coalesced)
		if not self._ImmediateFlush then
			return
		end

		-- Flush synchronously (before the caller's next line) so this
		-- replicator's ops beat any external RemoteEvent fired in the same frame.
		-- A manager batch fires BatchBegin -> net ops -> BatchEnd synchronously
		-- during Resume; hold the flush until BatchEnd so the whole window ships
		-- in one message rather than a Suspend with no matching Resume.
		if op.Kind == "BatchBegin" then
			self._ImmediateBatchOpen = true
		elseif op.Kind == "BatchEnd" then
			self._ImmediateBatchOpen = false
			frameCoordinator:FlushReplicator(self.Id)
		elseif not self._ImmediateBatchOpen then
			frameCoordinator:FlushReplicator(self.Id)
		end
	end)
	self._Janitor:Add(disconnectApplied)

	---------------------------------------------------------
	if parent then
		self._Scope = parent._Scope
	else
		self._Scope = ReplicationScope.new(transport)
		table.insert(topLevelReplicators, self)
	end

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

--[=[
	@ignore
	Flushes this replicator's queued ops to the wire now if it's an ImmediateFlush
	replicator and no manager batch window is currently open. Called from the
	signal paths (custom-remote fires, ordered-fn responses) after `QueueSignal`,
	mirroring the data path's synchronous flush. The batch guard keeps a signal
	fired inside a `manager:Batch(...)` buffered until the whole window ships at
	BatchEnd (see the OnApplied handler), so an ordered signal never jumps ahead
	of data queued before it.
]=]
function ServerReplicator._FlushIfImmediate(self: SR_Internal)
	if self._ImmediateFlush and not self._ImmediateBatchOpen then
		frameCoordinator:FlushReplicator(self.Id)
	end
end

--------------------------------------------------------------------------------
--// Targeting //--
--------------------------------------------------------------------------------

--[=[
	@ignore
	Sends `replicator`'s subtree to `player` and marks them active in `replicator`'s scope.
]=]
function ServerReplicator._SendSnapshotTo(self: SR_Internal, player: Player)
	const items = {}
	buildSnapshotItems(self, items)
	const buf, instances = buildMessage(items)
	self._Scope:SendTo(player, buf, instances)
end

--[=[
	@ignore
	Adds `player` to this replicator's scope, sending a snapshot if they have
	already bootstrapped. Does nothing if the player is already targeted.
]=]
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

--[=[
	@ignore
	Removes `player` from this replicator's scope, sending a `Destroy` if they
	were active. Does nothing if the player is not targeted.
]=]
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
	@within ServerReplicator
	@method SetTargets
	@param targets ReplicationTargets
	@tag TopLevel

	Overwrites this top-level replicator's replication targets.

	```lua
	replicator:SetTargets("all")              -- replicate to everyone
	replicator:SetTargets(player)             -- single player
	replicator:SetTargets({ player1, player2 }) -- explicit list
	```
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
	@within ServerReplicator
	@method AddTarget
	@param target Player | { Player }
	@tag TopLevel

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
	@within ServerReplicator
	@method RemoveTarget
	@param target Player | { Player }
	@tag TopLevel

	Removes a player (or list of players) from this top-level replicator's targets.
]=]
function ServerReplicator.RemoveTarget(self: SR_Internal, target: Player | { Player })
	assert(self:IsTopLevel(), "Cannot remove a replication target on a non-top-level replicator")
	const list: { Player } = if typeof(target) == "Instance" then { target :: Player } else target :: { Player }
	for _, player in list do
		self:_RemoveTarget(player)
	end
end

--[=[
	@within ServerReplicator
	@method GetTargets
	@return { Player }

	Returns a list of players this top-level replicator is currently replicating to.
]=]
function ServerReplicator.GetTargets(self: SR_Internal): { Player }
	return self._Scope:GetTargetPlayers()
end

--[=[
	@within ServerReplicator
	@method IsReplicatingTo
	@param player Player
	@return boolean

	Returns whether this replicator is currently replicating to the given player.
]=]
function ServerReplicator.IsReplicatingTo(self: SR_Internal, player: Player): boolean
	return self._Scope:IsTargeting(player)
end

--------------------------------------------------------------------------------
--// Hierarchy //--
--------------------------------------------------------------------------------

--[=[
	@within ServerReplicator
	@method SetParent
	@param newParent ServerReplicator

	Re-parents this replicator under `newParent`, moving its entire subtree.
	Cannot be called on a top-level replicator; cannot create cycles.

	If the move crosses scope boundaries (different top-level ancestors), players
	only in the old scope receive a `Destroy`, players only in the new scope
	receive a fresh snapshot, and players in both receive a `SetParent`.
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
--// Custom Remotes //--
--------------------------------------------------------------------------------

--[=[
	@within ServerReplicator
	@method RegisterRemoteSignal
	@param name string
	@return ServerCustomRemote

	Registers a reliable custom signal on this replicator. After registration,
	`replicator.Client[name]` returns a `ServerCustomRemote` with `Fire`,
	`FireAll`, `FireExcept`, `FirePredicate`, `Connect`, `Once`, and `Wait`.

	```lua
	-- Server
	local hitSignal = replicator:RegisterRemoteSignal("Hit")
	hitSignal:FireAll("headshot")

	-- Client
	replicator.Server.Hit:Connect(function(hitType)
		print("Hit:", hitType)
	end)
	```
]=]
function ServerReplicator.RegisterRemoteSignal(self: SR_Internal, name: string): any
	assert(not self._RemoteSignals[name], `Remote signal '{name}' already registered`)
	assert(not self._RemoteFunctions[name], `'{name}' is already registered as a remote function`)
	local remote = ServerCustomRemote.new(name, self, transport, false)
	self._RemoteSignals[name] = remote
	self._Janitor:Add(remote, "Destroy")
	rawset(self.Client, name, remote)
	sendRemoteMeta(self, name, "Signal")
	return remote
end

--[=[
	@within ServerReplicator
	@method RegisterRemoteUnreliableSignal
	@param name string
	@return ServerCustomRemote

	Like `RegisterRemoteSignal` but uses an `UnreliableRemoteEvent` for delivery.
]=]
function ServerReplicator.RegisterRemoteUnreliableSignal(self: SR_Internal, name: string): any
	assert(not self._RemoteSignals[name], `Remote signal '{name}' already registered`)
	assert(not self._RemoteFunctions[name], `'{name}' is already registered as a remote function`)
	local remote = ServerCustomRemote.new(name, self, transport, true)
	self._RemoteSignals[name] = remote
	self._Janitor:Add(remote, "Destroy")
	rawset(self.Client, name, remote)
	sendRemoteMeta(self, name, "Unreliable")
	return remote
end

--[=[
	@within ServerReplicator
	@method RegisterRemoteFunction
	@param name string
	@param fn (self: ServerReplicator, player: Player, ...any) -> ...any

	Registers a client→server function. Clients invoke it via
	`replicator.Server[name](...)` which yields until the server returns.
]=]
function ServerReplicator.RegisterRemoteFunction(self: SR_Internal, name: string, fn: any): any
	assert(not self._RemoteFunctions[name], `Remote function '{name}' already registered`)
	assert(not self._RemoteSignals[name], `'{name}' is already registered as a remote signal`)
	self._RemoteFunctions[name] = fn
	rawset(self.Client, name, fn)
	sendRemoteMeta(self, name, "Function")
	return fn
end

--[=[
	@within ServerReplicator
	@method RegisterOrderedRemoteSignal
	@param name string
	@return ServerCustomRemote

	Like `RegisterRemoteSignal` but delivers fires through the frame buffer,
	so they arrive at the client in the same ordered sequence as data ops
	enqueued in the same frame. Clients connect to it the same way:
	`replicator.Server[name]:Connect(...)`.
]=]
function ServerReplicator.RegisterOrderedRemoteSignal(self: SR_Internal, name: string): any
	assert(not self._RemoteSignals[name], `Remote signal '{name}' already registered`)
	assert(not self._RemoteFunctions[name], `'{name}' is already registered as a remote function`)
	local remote = ServerCustomRemote.new(name, self, transport, false, frameCoordinator)
	self._RemoteSignals[name] = remote
	self._Janitor:Add(remote, "Destroy")
	rawset(self.Client, name, remote)
	sendRemoteMeta(self, name, "OrderedSignal")
	return remote
end

--[=[
	@within ServerReplicator
	@method RegisterOrderedRemoteFunction
	@param name string
	@param fn (self: ServerReplicator, player: Player, ...any) -> ...any

	Like `RegisterRemoteFunction` but the server's response is delivered
	through the frame buffer so it arrives at the client in the same ordered
	sequence as data ops. The client must call `InvokeAsync(...)` (returns a
	Promise) instead of the blocking `Invoke(...)`.
]=]
function ServerReplicator.RegisterOrderedRemoteFunction(self: SR_Internal, name: string, fn: any): any
	assert(not self._RemoteFunctions[name], `Remote function '{name}' already registered`)
	assert(not self._RemoteSignals[name], `'{name}' is already registered as a remote signal`)
	self._RemoteFunctions[name] = fn
	self._OrderedFunctions[name] = true
	sendRemoteMeta(self, name, "OrderedFunction")
	return fn
end

--[=[
	@within ServerReplicator
	@method GetRemoteSignal
	@param name string
	@return ServerCustomRemote

	Returns an already-registered custom signal by name.
]=]
function ServerReplicator.GetRemoteSignal(self: SR_Internal, name: string): any
	local remote = self._RemoteSignals[name]
	assert(remote ~= nil, `Remote signal '{name}' is not registered on this replicator`)
	return remote
end

--------------------------------------------------------------------------------
--// Lifecycle //--
--------------------------------------------------------------------------------

--[=[
	@within ServerReplicator
	@method Destroy
	Destroys the replicator and orphans any children to `ServerReplicator.None`.
	This is synchronous and immediate; any queued ops for this replicator are 
	dropped, and all active players with the replicator have it destroyed on their end.
]=]
function ServerReplicator.Destroy(self: SR_Internal)
	frameCoordinator:DropReplicator(self.Id)

	for _, child: SR_Internal in self:GetChildren() do
		child:SetParent(ServerReplicator.None :: SR_Internal)
	end

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

	if self.Namespace then
		TokenCache.releaseNamespace(self.Namespace)
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

-- Sentinel prefix for ordered function invocations from the client.
-- The client fires this via the signal RemoteEvent; the server handles it,
-- calls the registered function, and queues the response as a Signal op
-- through the frame buffer so it arrives in order with data ops.

-- Route inbound custom signals (client → server) to the matching remote.
-- Also handles ordered function invocations identified by ORDERED_FN_CALL.
const signalReceived = transport.SignalReceived :: any
signalReceived:Connect(function(player: Player, id: number, name: string, ...: any)
	if not hasBootstrapped[player] then
		return
	end
	const replicator = BaseReplicator.GetFromId(id) :: SR_Internal?
	if replicator == nil then
		return
	end
	if not replicator._Scope:IsActive(player) then
		return
	end

	-- Ordered function invocation: first arg is the sentinel, second is the
	-- correlation ID the client is waiting on, rest are the actual call args.
	local args = { ... }
	if args[1] == Protocol.ORDERED_FN_CALL then
		local corrId = args[2] :: number
		local fn = replicator._RemoteFunctions[name]
		if fn then
			local results = table.pack(fn(replicator, player, table.unpack(args, 3)))
			local responseArgs = { Protocol.ORDERED_FN_RESPONSE, corrId }
			for i = 1, results.n do
				responseArgs[i + 2] = results[i]
			end
			frameCoordinator:QueueSignal(
				replicator._Scope,
				replicator.Id,
				name,
				{ player },
				responseArgs
			)
			replicator:_FlushIfImmediate()
		end
		return
	end

	const remote = replicator._RemoteSignals[name]
	if remote then
		remote:_FireServer(player, ...)
	end
end)

-- Route client→server function invocations to the matching registered function.
transport:SetFunctionHandler(function(player: Player, id: number, name: string, ...: any)
	if not hasBootstrapped[player] then
		return
	end
	const replicator = BaseReplicator.GetFromId(id) :: SR_Internal?
	assert(replicator ~= nil, `RemoteFunction: unknown replicator id {id}`)
	assert(replicator._Scope:IsActive(player), `RemoteFunction: player not active for replicator {id}`)
	const fn = replicator._RemoteFunctions[name]
	assert(fn ~= nil, `RemoteFunction: '{name}' not registered on replicator {id}`)
	return fn(replicator, player, ...)
end)

--[=[
	@tag Static
	@within ServerReplicator
	@function FlushNow
	Immediately flushes all pending data ops to active players without waiting
	for the end-of-frame deferred flush. Use this when you need data changes to
	arrive before (or alongside) an external `RemoteEvent` fired in the same frame.
]=]
function ServerReplicator.FlushNow()
	frameCoordinator:Flush()
end

--------------------------------------------------------------------------------
--// Finalization //--
--------------------------------------------------------------------------------

local allToken = ServerReplicator.TOKEN("ServerReplicator.All")
local noneToken = ServerReplicator.TOKEN("ServerReplicator.None")

--[=[
	@tag Static
	@prop ServerReplicator.All ServerReplicator
	A top-level replicator that replicates to every current and future
	player. Useful as a `Parent` for children that should always be visible
	to everyone, but may be moved later. Do not modify it directly — only parent to it.
]=]
ServerReplicator.All = ServerReplicator.new {
	Namespace = allToken,
	Data = {},
	ReplicationTargets = REPLICATE_TO_ALL,
}

--[=[
	@tag Static
	@prop ServerReplicator.None ServerReplicator
	A top-level replicator that replicates to nobody. Useful as a `Parent`
	for children that should not replicate yet and are waiting for a proper
	parent. Do not modify it directly — only parent to it.
]=]
ServerReplicator.None = ServerReplicator.new {
	Namespace = noneToken,
	Data = {},
	ReplicationTargets = {},
}

return ServerReplicator
