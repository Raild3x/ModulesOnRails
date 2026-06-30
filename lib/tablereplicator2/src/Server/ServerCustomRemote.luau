--!strict
--[=[
	@class ServerCustomRemote
	@server
	@ignore

	A per-replicator custom signal: the server fires to active clients, and
	clients fire back. Created via `ServerReplicator:RegisterRemoteSignal` or
	`RegisterRemoteUnreliableSignal`; accessed from user code as
	`replicator.Client.MySignal`.
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
		_Inbound: Types.Signal<any, any>,

		_Unreliable: boolean,
	},
	ServerCustomRemote
))

function ServerCustomRemote.new(name: string, replicator: any, transport: ServerTransport, unreliable: boolean?): ServerCustomRemote
	local self = setmetatable({}, ServerCustomRemote) :: ServerCustomRemote
	self._Name = name
	self._Replicator = replicator
	self._Transport = transport
	self._Inbound = Signal.new()
	self._Unreliable = unreliable == true
	return self
end

function ServerCustomRemote.Destroy(self: ServerCustomRemote)
	self._Inbound:Destroy()
	setmetatable(self :: any, nil)
end

--[=[
	Returns whether this signal uses unreliable delivery.
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
	if not self._Replicator._Scope:IsActive(player) then
		warn(`ServerCustomRemote.Fire: player {player.Name} is not active for replicator {self._Replicator.Id}`)
		return
	end
	self._Transport:FireSignal(player, self._Replicator.Id, self._Name, self._Unreliable, ...)
end

--[=[
	Fires to all currently active players for this replicator.
]=]
function ServerCustomRemote.FireAll(self: ServerCustomRemote, ...: any)
	for _, player in self._Replicator._Scope:GetActivePlayers() do
		self:Fire(player, ...)
	end
end

--[=[
	Fires to all active players except the ones listed in `ignored`.
]=]
function ServerCustomRemote.FireExcept(self: ServerCustomRemote, ignored: Player | { Player }, ...: any)
	local ignoreList: { Player } = if typeof(ignored) == "Instance" then { ignored :: Player } else ignored :: { Player }
	for _, player in self._Replicator._Scope:GetActivePlayers() do
		if not table.find(ignoreList, player) then
			self:Fire(player, ...)
		end
	end
end

--[=[
	Fires to all active players for whom `predicate` returns true.
]=]
function ServerCustomRemote.FirePredicate(self: ServerCustomRemote, predicate: Predicate, ...: any)
	for _, player in self._Replicator._Scope:GetActivePlayers() do
		if predicate(player, ...) then
			self:Fire(player, ...)
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
