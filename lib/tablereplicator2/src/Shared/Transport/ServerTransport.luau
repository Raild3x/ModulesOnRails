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
local Types = require("../Types")

type WireMessage = Types.WireMessage

local function findOrCreateRemote(container: Instance): RemoteEvent
	local existing = container:FindFirstChild(Protocol.ReliableName)
	if existing then
		return existing :: RemoteEvent
	end
	local remote = Instance.new("RemoteEvent")
	remote.Name = Protocol.ReliableName
	remote.Parent = container
	return remote
end

local ServerTransport = {}
ServerTransport.__index = ServerTransport

export type ServerTransport = typeof(setmetatable(
	{} :: {
		PlayerRequestedData: Signal.Signal<(player: Player) -> (), Player>,
		PlayerRemoving: Signal.Signal<(player: Player) -> (), Player>,
		_remote: RemoteEvent,
		_janitor: Janitor.Janitor,
	},
	ServerTransport
))

function ServerTransport.new(): ServerTransport
	local self = setmetatable({}, ServerTransport) :: ServerTransport

	self._janitor = Janitor.new()
	self._remote = findOrCreateRemote(Protocol.RemoteContainer)
	self.PlayerRequestedData = Signal.new(self._janitor) :: any
	self.PlayerRemoving = Signal.new(self._janitor) :: any

	self._janitor:Add(self._remote.OnServerEvent:Connect(function(player: Player, requestKind: string)
		if requestKind == Protocol.RequestData then
			self.PlayerRequestedData:Fire(player)
		end
	end))

	self._janitor:Add(Players.PlayerRemoving:Connect(function(player: Player)
		self.PlayerRemoving:Fire(player)
	end))

	return self
end

--[=[
	Sends a wire message to `player`.
]=]
function ServerTransport.SendMessage(self: ServerTransport, player: Player, message: WireMessage)
	self._remote:FireClient(player, message)
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

function ServerTransport.Destroy(self: ServerTransport)
	self._janitor:Destroy()
end

return ServerTransport
