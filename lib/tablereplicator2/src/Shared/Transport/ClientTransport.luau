--!strict
--[=[
	@ignore
	@class ClientTransport
	@client

	Client side of `ServerTransport`: finds the replication `RemoteEvent`,
	exposes `MessageReceived` for every real wire message, and turns
	`RequestData` into a Promise that resolves once the server confirms the
	initial snapshot was fully sent.
]=]

const Signal = require("../../../Signal")
const Janitor = require("../../../Janitor")
const Promise = require("../../../Promise")
const Protocol = require("./Protocol")
const Types = require("../Types")
const MessageCodec = require("../Serialization/MessageCodec")

type WireMessage = Types.WireMessage

local ClientTransport = {}
ClientTransport.__index = ClientTransport

export type ClientTransport = typeof(setmetatable(
	{} :: {
		MessageReceived: Types.Signal<(message: WireMessage) -> (), WireMessage>,
		_remote: RemoteEvent?,
		_janitor: Janitor.Janitor,
		_dataComplete: Types.Signal<() -> ()>,
		_requested: boolean,
		_connected: boolean,
		_receivedData: boolean,
	},
	ClientTransport
))

function ClientTransport.new(): ClientTransport
	local self = setmetatable({}, ClientTransport) :: ClientTransport

	self._janitor = Janitor.new()
	self.MessageReceived = Signal.new(self._janitor) :: any
	self._dataComplete = Signal.new(self._janitor) :: any

	self._requested = false
	self._connected = false
	self._receivedData = false
	self._remote = nil

	self._janitor:Add(function()
		const remote = Protocol.RemoteContainer:WaitForChild(Protocol.ReliableName)
		assert(remote:IsA("RemoteEvent"), "Expected RemoteEvent")
		self:_connect(remote :: RemoteEvent)
	end)

	return self
end

function ClientTransport._connect(self: ClientTransport, remote: RemoteEvent)
	self._remote = remote

	self._janitor:Add(remote.OnClientEvent:Connect(function(payload: buffer | string, instances: { Instance }?)
		if payload == Protocol.RequestDataComplete then
			self._dataComplete:Fire()
		else
			self.MessageReceived:Fire(MessageCodec.Decode(payload :: buffer, instances))
		end
	end))

	if self._requested then
		remote:FireServer(Protocol.RequestData)
	end
end

--[=[
	Requests the initial snapshot from the server. Safe to call more than
	once -- every call after the first just returns a promise for the same
	in-flight (or already-resolved) request. Resolves once the server has
	finished sending the snapshot.
]=]
function ClientTransport.RequestData(self: ClientTransport): Promise.TypedPromise<()>
	if not self._requested then
		self._requested = true

		if self._connected then
			self._remote:FireServer(Protocol.RequestData)
		end
	end

	if self._receivedData then
		return Promise.resolve()
	end

	return Promise.fromEvent(self._dataComplete)
end

function ClientTransport.Destroy(self: ClientTransport)
	self._janitor:Destroy()
end

return ClientTransport
