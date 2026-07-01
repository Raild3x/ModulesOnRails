--!strict
--[=[
	@class ServerCustomRemote
	@server
	@ignore

	A per-replicator custom signal: the server fires to active clients, and
	clients fire back. Created via `ServerReplicator:RegisterRemoteSignal`,
	`RegisterRemoteUnreliableSignal`, or `RegisterOrderedRemoteSignal`;
	accessed from user code as `replicator.Client.MySignal`.

	When constructed with a `coordinator` (FrameCoordinator), `Fire*` methods
	route through the frame buffer so signal fires arrive at the client in the
	same ordered sequence as adjacent data ops. Without a coordinator, fires go
	directly through the transport RemoteEvent.
]=]

const Types = require("../Shared/Types")
const Signal = Types.Signal

const ServerTransportModule = require("../Shared/Transport/ServerTransport")
type ServerTransport = ServerTransportModule.ServerTransport

type Connection = Types.Connection
type Predicate = (player: Player, ...any) -> boolean

local ServerCustomRemote = {}
ServerCustomRemote.__index = ServerCustomRemote

export type ServerCustomRemote = typeof(setmetatable(
	{} :: {
		_Name: string,
		_Replicator: any,
		_Transport: ServerTransport,
		_Coordinator: any?,
		_Inbound: Types.Signal<any, any>,
		_Unreliable: boolean,
	},
	ServerCustomRemote
))

-- `coordinator`: when provided (a FrameCoordinator), Fire* methods route
-- through the frame buffer instead of the transport, so signal fires arrive
-- at the client in the same ordered sequence as data ops.
function ServerCustomRemote.new(name: string, replicator: any, transport: ServerTransport, unreliable: boolean?, coordinator: any?): ServerCustomRemote
	local self = setmetatable({}, ServerCustomRemote) :: ServerCustomRemote
	self._Name = name
	self._Replicator = replicator
	self._Transport = transport
	self._Coordinator = coordinator
	self._Inbound = Signal.new()
	self._Unreliable = unreliable == true
	return self
end

function ServerCustomRemote.Destroy(self: ServerCustomRemote)
	self._Inbound:Destroy()
	setmetatable(self :: any, nil)
end

--[=[
	Returns whether this signal uses unreliable delivery (only applies to
	unordered signals; ordered signals always use reliable delivery).
]=]
function ServerCustomRemote.IsUnreliable(self: ServerCustomRemote): boolean
	return self._Unreliable
end

-- Called by ServerReplicator's transport listener when a client fires this signal.
function ServerCustomRemote._FireServer(self: ServerCustomRemote, player: Player, ...: any)
	self._Inbound:Fire(player, ...)
end

--[=[
	Fires to a specific active player.
]=]
function ServerCustomRemote.Fire(self: ServerCustomRemote, player: Player, ...: any)
	assert(typeof(player) == "Instance" and player:IsA("Player"), "ServerCustomRemote.Fire: expected a Player")
	local scope = self._Replicator._Scope
	if not scope:IsActive(player) then
		warn(`ServerCustomRemote.Fire: player {player.Name} is not active for replicator {self._Replicator.Id}`)
		return
	end
	if self._Coordinator then
		self._Coordinator:QueueSignal(scope, self._Replicator.Id, self._Name, { player }, { ... })
	else
		self._Transport:FireSignal(player, self._Replicator.Id, self._Name, self._Unreliable, ...)
	end
end

--[=[
	Fires to all currently active players for this replicator.
]=]
function ServerCustomRemote.FireAll(self: ServerCustomRemote, ...: any)
	local scope = self._Replicator._Scope
	local players = scope:GetActivePlayers()
	if self._Coordinator then
		if #players > 0 then
			self._Coordinator:QueueSignal(scope, self._Replicator.Id, self._Name, players, { ... })
		end
	else
		for _, player in players do
			self._Transport:FireSignal(player, self._Replicator.Id, self._Name, self._Unreliable, ...)
		end
	end
end

--[=[
	Fires to all active players except the ones listed in `ignored`.
]=]
function ServerCustomRemote.FireExcept(self: ServerCustomRemote, ignored: Player | { Player }, ...: any)
	local ignoreList: { Player } = if typeof(ignored) == "Instance" then { ignored :: Player } else ignored :: { Player }
	local scope = self._Replicator._Scope
	if self._Coordinator then
		local audience = {}
		for _, player in scope:GetActivePlayers() do
			if not table.find(ignoreList, player) then
				table.insert(audience, player)
			end
		end
		if #audience > 0 then
			self._Coordinator:QueueSignal(scope, self._Replicator.Id, self._Name, audience, { ... })
		end
	else
		for _, player in scope:GetActivePlayers() do
			if not table.find(ignoreList, player) then
				self._Transport:FireSignal(player, self._Replicator.Id, self._Name, self._Unreliable, ...)
			end
		end
	end
end

--[=[
	Fires to all active players for whom `predicate` returns true.
]=]
function ServerCustomRemote.FirePredicate(self: ServerCustomRemote, predicate: Predicate, ...: any)
	local scope = self._Replicator._Scope
	if self._Coordinator then
		local audience = {}
		for _, player in scope:GetActivePlayers() do
			if predicate(player, ...) then
				table.insert(audience, player)
			end
		end
		if #audience > 0 then
			self._Coordinator:QueueSignal(scope, self._Replicator.Id, self._Name, audience, { ... })
		end
	else
		for _, player in scope:GetActivePlayers() do
			if predicate(player, ...) then
				self._Transport:FireSignal(player, self._Replicator.Id, self._Name, self._Unreliable, ...)
			end
		end
	end
end

--[=[
	Connects a callback that fires whenever a client fires this signal.
	The callback receives `(player, ...args)`.
]=]
function ServerCustomRemote.Connect(self: ServerCustomRemote, callback: (player: Player, ...any) -> ()): Connection
	return self._Inbound:Connect(callback)
end

--[=[
	Like `Connect` but disconnects automatically after the first fire.
]=]
function ServerCustomRemote.Once(self: ServerCustomRemote, callback: (player: Player, ...any) -> ()): Connection
	return self._Inbound:Once(callback)
end

--[=[
	Yields until a client fires this signal. If `predicate` is a `Player`,
	waits for that specific player. If it's a function, waits until the
	function returns true for the incoming args.
]=]
function ServerCustomRemote.Wait(self: ServerCustomRemote, predicate: (Player | Predicate)?): (Player, ...any)
	local inbound = self._Inbound
	if predicate == nil then
		return inbound:Wait()
	end
	if typeof(predicate) == "function" then
		local results
		repeat
			results = table.pack(inbound:Wait())
		until (predicate :: Predicate)(results[1], table.unpack(results, 2))
		return table.unpack(results)
	else
		local target = predicate :: Player
		local results
		repeat
			results = table.pack(inbound:Wait())
		until results[1] == target
		return table.unpack(results)
	end
end

return ServerCustomRemote
