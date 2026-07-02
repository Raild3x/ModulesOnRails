--!strict
--[=[
	@class ClientCustomRemote
	@client
	@ignore

	The client-side mirror of a `ServerCustomRemote`. Lazily created on first
	access via `replicator.Server.MySignal`. Fires to the server and receives
	fires from the server (both via direct RemoteEvent and via the ordered ops
	buffer).
]=]

const Types = require("../Shared/Types")
const Signal = Types.Signal
const Promise = Types.Promise
const Protocol = require("../Shared/Transport/Protocol")

const ClientTransportModule = require("../Shared/Transport/ClientTransport")
type ClientTransport = ClientTransportModule.ClientTransport

type Connection = Types.Connection
type GetTransport = () -> ClientTransport


-- Module-level map of correlation-ID → resolve callback for in-flight
-- InvokeAsync calls. The correlation ID is a monotonically incrementing number;
-- because client Lua is single-threaded, there are no races on `_nextCorrId`.
local _pendingInvocations: { [number]: (results: { any }) -> () } = {}
local _nextCorrId = 0

-- Exposed so ClientReplicator can resolve pending invocations when an ordered
-- function response arrives via the ops buffer.
local ClientCustomRemote = {}
ClientCustomRemote.__index = ClientCustomRemote
ClientCustomRemote._ORDERED_FN_RESPONSE = Protocol.ORDERED_FN_RESPONSE

export type ClientCustomRemote = typeof(setmetatable(
	{} :: {
		_Name: string,
		_Replicator: any,
		_GetTransport: GetTransport,
		_Inbound: any,
		_Unreliable: boolean,
		_RemoteType: string?,
	},
	ClientCustomRemote
))

function ClientCustomRemote.new(name: string, replicator: any, getTransport: GetTransport, unreliable: boolean?, remoteType: string?): ClientCustomRemote
	local self = setmetatable({}, ClientCustomRemote) :: ClientCustomRemote
	self._Name = name
	self._Replicator = replicator
	self._GetTransport = getTransport
	self._Inbound = Signal.new()
	self._Unreliable = unreliable == true or remoteType == "Unreliable"
	self._RemoteType = remoteType
	return self
end

local function warnSignalOnFunction(self: ClientCustomRemote, method: string)
	if self._RemoteType == "Function" or self._RemoteType == "OrderedFunction" then
		warn(`ClientCustomRemote: '{self._Name}' is registered as a {self._RemoteType} on the server — use Invoke() or InvokeAsync() instead of {method}()`)
	end
end

local function warnFunctionOnSignal(self: ClientCustomRemote, method: string)
	local t = self._RemoteType
	if t == "Signal" or t == "Unreliable" or t == "OrderedSignal" then
		warn(`ClientCustomRemote: '{self._Name}' is registered as a {t} on the server — use Connect() instead of {method}()`)
	end
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

-- Called by ClientReplicator when the server fires this signal (either via the
-- direct RemoteEvent or via the ordered ops buffer).
function ClientCustomRemote._FireClient(self: ClientCustomRemote, ...: any)
	self._Inbound:Fire(...)
end

-- Called by ClientReplicator when an ordered function response arrives via the
-- ops buffer. `corrId` identifies the pending InvokeAsync call to resolve.
function ClientCustomRemote._ResolveInvocation(corrId: number, results: { any })
	local resolve = _pendingInvocations[corrId]
	if resolve then
		_pendingInvocations[corrId] = nil
		resolve(results)
	end
end

--[=[
	Fires this signal to the server.
]=]
function ClientCustomRemote.Fire(self: ClientCustomRemote, ...: any)
	warnSignalOnFunction(self, "Fire")
	self._GetTransport():FireSignal(self._Replicator.Id, self._Name, self._Unreliable, ...)
end

--[=[
	Fires this signal to the server using unreliable delivery, regardless of how
	the remote was originally registered.
]=]
function ClientCustomRemote.FireUnreliable(self: ClientCustomRemote, ...: any)
	warnSignalOnFunction(self, "FireUnreliable")
	self._GetTransport():FireSignal(self._Replicator.Id, self._Name, true, ...)
end

--[=[
	Invokes the matching server-side **unordered** function and returns the
	result. Yields until the server's `OnServerInvoke` returns.
	Use `InvokeAsync` for ordered functions registered with
	`RegisterOrderedRemoteFunction`.
]=]
function ClientCustomRemote.Invoke(self: ClientCustomRemote, ...: any): ...any
	warnFunctionOnSignal(self, "Invoke")
	return self._GetTransport():InvokeFunction(self._Replicator.Id, self._Name, ...)
end

--[=[
	Invokes the matching server-side **ordered** function and returns a Promise
	that resolves with the function's return values. The response arrives
	through the ops buffer so it is guaranteed to come after any data ops the
	server enqueued in the same frame.

	Use this with functions registered via `RegisterOrderedRemoteFunction`.
]=]
function ClientCustomRemote.InvokeAsync(self: ClientCustomRemote, ...: any): Types.Promise<...any>
	warnFunctionOnSignal(self, "InvokeAsync")
	local args = { ... }
	return Promise.new(function(resolve, reject)
		_nextCorrId += 1
		local corrId = _nextCorrId
		_pendingInvocations[corrId] = function(results: { any })
			resolve(table.unpack(results))
		end
		local ok, err = pcall(function()
			self._GetTransport():FireSignal(
				self._Replicator.Id,
				self._Name,
				false,
				Protocol.ORDERED_FN_CALL,
				corrId,
				table.unpack(args)
			)
		end)
		if not ok then
			_pendingInvocations[corrId] = nil
			reject(err)
		end
	end) :: any
end

--[=[
	Connects a callback that fires whenever the server fires this signal.
]=]
function ClientCustomRemote.Connect(self: ClientCustomRemote, callback: (...any) -> ()): Connection
	warnSignalOnFunction(self, "Connect")
	return self._Inbound:Connect(callback)
end

--[=[
	Like `Connect` but disconnects automatically after the first fire.
]=]
function ClientCustomRemote.Once(self: ClientCustomRemote, callback: (...any) -> ()): Connection
	warnSignalOnFunction(self, "Once")
	return self._Inbound:Once(callback)
end

--[=[
	Yields until the server fires this signal.
]=]
function ClientCustomRemote.Wait(self: ClientCustomRemote): ...any
	warnSignalOnFunction(self, "Wait")
	return self._Inbound:Wait()
end

return ClientCustomRemote
