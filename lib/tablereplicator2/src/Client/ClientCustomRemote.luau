--!strict
--[=[
	@class ClientCustomRemote
	@client
	@ignore

	The client-side mirror of a `ServerCustomRemote`. Lazily created on first
	access via `replicator.Server.MySignal`. Fires to the server and receives
	fires from the server.
]=]

const Types = require("../Shared/Types")
const Signal = Types.Signal

const ClientTransportModule = require("../Shared/Transport/ClientTransport")
type ClientTransport = ClientTransportModule.ClientTransport

type Connection = Types.Connection
type GetTransport = () -> ClientTransport

local ClientCustomRemote = {}
ClientCustomRemote.__index = ClientCustomRemote

export type ClientCustomRemote = typeof(setmetatable(
	{} :: {
		_Name: string,
		_Replicator: any,
		_GetTransport: GetTransport,
		_Inbound: any,
		_Unreliable: boolean,
	},
	ClientCustomRemote
))

function ClientCustomRemote.new(name: string, replicator: any, getTransport: GetTransport, unreliable: boolean?): ClientCustomRemote
	local self = setmetatable({}, ClientCustomRemote) :: ClientCustomRemote
	self._Name = name
	self._Replicator = replicator
	self._GetTransport = getTransport
	self._Inbound = Signal.new()
	self._Unreliable = unreliable == true
	return self
end

function ClientCustomRemote.Destroy(self: ClientCustomRemote)
	self._Inbound:Destroy()
	setmetatable(self :: any, nil)
end

--[=[
	Returns whether this signal uses unreliable delivery.
]=]
function ClientCustomRemote.IsUnreliable(self: ClientCustomRemote): boolean
	return self._Unreliable
end

-- Called by ClientReplicator's transport listener when the server fires this signal.
function ClientCustomRemote._FireClient(self: ClientCustomRemote, ...: any)
	self._Inbound:Fire(...)
end

--[=[
	Fires this signal to the server.
]=]
function ClientCustomRemote.Fire(self: ClientCustomRemote, ...: any)
	self._GetTransport():FireSignal(self._Replicator.Id, self._Name, self._Unreliable, ...)
end

--[=[
	Fires this signal to the server using unreliable delivery, regardless of how
	the remote was originally registered.
]=]
function ClientCustomRemote.FireUnreliable(self: ClientCustomRemote, ...: any)
	self._GetTransport():FireSignal(self._Replicator.Id, self._Name, true, ...)
end

--[=[
	Invokes the matching server-side function and returns the result. Yields.
]=]
function ClientCustomRemote.Invoke(self: ClientCustomRemote, ...: any): ...any
	return self._GetTransport():InvokeFunction(self._Replicator.Id, self._Name, ...)
end

--[=[
	Connects a callback that fires whenever the server fires this signal.
]=]
function ClientCustomRemote.Connect(self: ClientCustomRemote, callback: (...any) -> ()): Connection
	return self._Inbound:Connect(callback)
end

--[=[
	Like `Connect` but disconnects automatically after the first fire.
]=]
function ClientCustomRemote.Once(self: ClientCustomRemote, callback: (...any) -> ()): Connection
	return self._Inbound:Once(callback)
end

--[=[
	Yields until the server fires this signal.
]=]
function ClientCustomRemote.Wait(self: ClientCustomRemote): ...any
	return self._Inbound:Wait()
end

return ClientCustomRemote
