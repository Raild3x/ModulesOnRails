--!strict
--[=[
	@ignore
	@class ServerTransport
	@server

	Owns the replication `RemoteEvent` and exposes a small typed surface over
	it: send a message to a player, and observe "a player asked for the
	initial snapshot" / "a player left". Carries no replication state of its
	own -- `ServerReplicator` decides WHAT to send and WHEN.
]=]

local Players = game:GetService("Players")

local Signal = require("../../../Signal")
local Janitor = require("../../../Janitor")
local Protocol = require("./Protocol")

local function findOrCreateRemoteEvent(container: Instance, name: string): RemoteEvent
	local existing = container:FindFirstChild(name)
	if existing then
		return existing :: RemoteEvent
	end
	local remote = Instance.new("RemoteEvent")
	remote.Name = name
	remote.Parent = container
	return remote
end

local function findOrCreateUnreliableRemote(container: Instance): UnreliableRemoteEvent
	local existing = container:FindFirstChild(Protocol.UnreliableSignalName)
	if existing then
		return existing :: UnreliableRemoteEvent
	end
	local remote = Instance.new("UnreliableRemoteEvent")
	remote.Name = Protocol.UnreliableSignalName
	remote.Parent = container
	return remote
end

local function findOrCreateFunction(container: Instance): RemoteFunction
	local existing = container:FindFirstChild(Protocol.FunctionName)
	if existing then
		return existing :: RemoteFunction
	end
	local remote = Instance.new("RemoteFunction")
	remote.Name = Protocol.FunctionName
	remote.Parent = container
	return remote
end

local ServerTransport = {}
ServerTransport.__index = ServerTransport

export type ServerTransport = typeof(setmetatable(
	{} :: {
		PlayerRequestedData: Signal.Signal<(player: Player) -> (), Player>,
		PlayerRemoving: Signal.Signal<(player: Player) -> (), Player>,
		-- Fires whenever a client fires a custom signal (reliable or unreliable).
		-- Args: (player, replicatorId, name, ...payload)
		SignalReceived: any,
		_remote: RemoteEvent,
		_signalRemote: RemoteEvent,
		_unreliableRemote: UnreliableRemoteEvent,
		_functionRemote: RemoteFunction,
		_janitor: Janitor.Janitor,
	},
	ServerTransport
))

function ServerTransport.new(): ServerTransport
	local self = setmetatable({}, ServerTransport) :: ServerTransport

	self._janitor = Janitor.new()
	self._remote = findOrCreateRemoteEvent(Protocol.RemoteContainer, Protocol.ReliableName)
	self._signalRemote = findOrCreateRemoteEvent(Protocol.RemoteContainer, Protocol.SignalName)
	self._unreliableRemote = findOrCreateUnreliableRemote(Protocol.RemoteContainer)
	self._functionRemote = findOrCreateFunction(Protocol.RemoteContainer)

	self.PlayerRequestedData = Signal.new(self._janitor) :: any
	self.PlayerRemoving = Signal.new(self._janitor) :: any
	self.SignalReceived = Signal.new(self._janitor) :: any

	self._janitor:Add(self._remote.OnServerEvent:Connect(function(player: Player, requestKind: string)
		if requestKind == Protocol.RequestData then
			self.PlayerRequestedData:Fire(player)
		end
	end))

	self._janitor:Add(Players.PlayerRemoving:Connect(function(player: Player)
		self.PlayerRemoving:Fire(player)
	end))

	-- Route inbound custom signals (both reliable and unreliable) into SignalReceived.
	self._janitor:Add(self._signalRemote.OnServerEvent:Connect(function(player: Player, ...)
		self.SignalReceived:Fire(player, ...)
	end))
	self._janitor:Add(self._unreliableRemote.OnServerEvent:Connect(function(player: Player, ...)
		self.SignalReceived:Fire(player, ...)
	end))

	return self
end

--[=[
	Sends an encoded wire message (a `buffer` from `MessageCodec.Encode`, plus
	its `Instance` side-list) to `player`.
]=]
function ServerTransport.SendMessage(self: ServerTransport, player: Player, buf: buffer, instances: { Instance }?)
	self._remote:FireClient(player, buf, instances)
end

--[=[
	Tells `player`'s client that the response to its last `RequestData` has
	been fully sent (every snapshot message for it already went out over this
	same RemoteEvent, so ordered delivery guarantees the client sees them
	first).
]=]
function ServerTransport.NotifyDataSent(self: ServerTransport, player: Player)
	self._remote:FireClient(player, Protocol.RequestDataComplete)
end

--[=[
	Fires a custom signal to `player`. `unreliable` controls which remote is
	used (the dedicated UnreliableRemoteEvent vs the reliable one).
]=]
function ServerTransport.FireSignal(self: ServerTransport, player: Player, id: number, name: string, unreliable: boolean, ...: any)
	if unreliable then
		(self._unreliableRemote :: any):FireClient(player, id, name, ...)
	else
		self._signalRemote:FireClient(player, id, name, ...)
	end
end

--[=[
	Installs the server-side handler for all client->server function invocations.
	The handler receives `(player, replicatorId, name, ...args)` and its return
	values are forwarded back to the invoking client.
]=]
function ServerTransport.SetFunctionHandler(self: ServerTransport, handler: (player: Player, id: number, name: string, ...any) -> ...any)
	(self._functionRemote :: any).OnServerInvoke = handler
end

function ServerTransport.Destroy(self: ServerTransport)
	self._janitor:Destroy()
end

return ServerTransport
