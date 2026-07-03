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

const RunService = game:GetService("RunService")

const Signal = require("../../../Signal")
const Janitor = require("../../../Janitor")
const Promise = require("../../../Promise")
const Protocol = require("./Protocol")
const Types = require("../Types")
const MessageCodec = require("../Serialization/MessageCodec")

const IS_CLIENT = RunService:IsClient()

type WireMessage = Types.WireMessage

local ClientTransport = {}
ClientTransport.__index = ClientTransport

export type ClientTransport = typeof(setmetatable(
	{} :: {
		MessageReceived: Types.Signal<(message: WireMessage) -> (), WireMessage>,
		-- Fires whenever the server fires a custom signal to this client.
		-- Args: (replicatorId, name, ...payload)
		SignalReceived: any,
		_remote: RemoteEvent?,
		_signalRemote: RemoteEvent?,
		_unreliableRemote: UnreliableRemoteEvent?,
		_functionRemote: RemoteFunction?,
		_janitor: Types.Janitor,
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
	self.SignalReceived = Signal.new(self._janitor) :: any
	self._dataComplete = Signal.new(self._janitor) :: any

	self._requested = false
	self._connected = false
	self._receivedData = false
	self._remote = nil
	self._signalRemote = nil
	self._unreliableRemote = nil
	self._functionRemote = nil

	-- Every remote here is wired with client-only APIs (OnClientEvent /
	-- FireServer), so all connection setup lives behind this single IsClient()
	-- gate. On the server -- only ever reached from the test runner -- nothing
	-- connects: `_remote`/`_connected` stay unset, so the outbound methods below
	-- short-circuit on their own and no method needs its own IsClient() check.
	if IS_CLIENT then
		self._janitor:Add(task.spawn(function()
			const remote = Protocol.RemoteContainer:WaitForChild(Protocol.ReliableName)
			assert(remote:IsA("RemoteEvent"), "Expected RemoteEvent")
			self:_connect(remote :: RemoteEvent)
		end))

		-- Connect the custom-signal remotes in the background so they're ready
		-- as soon as RequestData resolves (the server creates them at startup).
		self._janitor:Add(task.spawn(function()
			const rawSignal = Protocol.RemoteContainer:WaitForChild(Protocol.SignalName)
			assert(rawSignal:IsA("RemoteEvent"), "Expected RemoteEvent for Signal")
			const signalRemote = rawSignal :: RemoteEvent
			self._signalRemote = signalRemote
			const signalConn = signalRemote.OnClientEvent:Connect(function(...)
				local sig = self.SignalReceived :: any
				sig:Fire(...)
			end)
			self._janitor:Add(signalConn)

			const rawUnreliable = Protocol.RemoteContainer:WaitForChild(Protocol.UnreliableSignalName)
			assert(rawUnreliable:IsA("UnreliableRemoteEvent"), "Expected UnreliableRemoteEvent")
			const unreliableRemote = rawUnreliable :: UnreliableRemoteEvent
			self._unreliableRemote = unreliableRemote
			const unreliableConn = unreliableRemote.OnClientEvent:Connect(function(...)
				local sig = self.SignalReceived :: any
				sig:Fire(...)
			end)
			self._janitor:Add(unreliableConn)

			const rawFn = Protocol.RemoteContainer:WaitForChild(Protocol.FunctionName)
			assert(rawFn:IsA("RemoteFunction"), "Expected RemoteFunction")
			self._functionRemote = rawFn :: RemoteFunction
		end))
	end

	return self
end

-- Client-only: only ever called from the IsClient()-gated spawn in `new`.
function ClientTransport._connect(self: ClientTransport, remote: RemoteEvent)
	assert(not self._remote, "Already connected to a RemoteEvent")
	self._remote = remote

	self._janitor:Add(remote.OnClientEvent:Connect(function(payload: buffer | string, instances: { any }?)
		if payload == Protocol.RequestDataComplete then
			self._receivedData = true
			self._dataComplete:Fire()
		else
			self.MessageReceived:Fire(MessageCodec.Decode(payload :: buffer, instances))
		end
	end))

	if self._requested then
		remote:FireServer(Protocol.RequestData)
	end

	self._connected = true
end

--[=[
	Fires a custom signal to the server. `unreliable` controls which remote is used.
]=]
function ClientTransport.FireSignal(self: ClientTransport, id: number, name: string, unreliable: boolean, ...: any)
	if unreliable then
		local remote = self._unreliableRemote
		assert(remote ~= nil, "UnreliableRemoteEvent not yet connected")
		local r = remote :: any
		r:FireServer(id, name, ...)
	else
		local remote = self._signalRemote
		assert(remote ~= nil, "Signal RemoteEvent not yet connected")
		remote:FireServer(id, name, ...)
	end
end

--[=[
	Invokes the server-side function handler and returns the result. Yields until
	the server responds.
]=]
function ClientTransport.InvokeFunction(self: ClientTransport, id: number, name: string, ...: any): ...any
	local remote = self._functionRemote
	assert(remote ~= nil, "RemoteFunction not yet connected")
	return remote:InvokeServer(id, name, ...)
end

--[=[
	Requests the initial snapshot from the server. Safe to call more than
	once -- every call after the first just returns a promise for the same
	in-flight (or already-resolved) request. Resolves once the server has
	finished sending the snapshot.
]=]
function ClientTransport.RequestData(self: ClientTransport): Types.Promise<()>
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
