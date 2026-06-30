--!strict
--[=[
	@ignore
	@class Protocol

	Names agreed on by both `ServerTransport` and `ClientTransport` so they can
	find the same Instances without any other shared state.
]=]

local Protocol = {}

-- A single reliable RemoteEvent carries everything in Phase 1: client->server
-- "RequestData" requests, and server->client wire messages + the
-- "RequestDataComplete" control marker. Both directions share one Instance
-- because Roblox guarantees ordered delivery per RemoteEvent, which is what
-- lets the marker reliably arrive AFTER the snapshot it follows.
Protocol.ReliableName = "Reliable"

-- Client -> Server request kinds (first positional arg of FireServer).
Protocol.RequestData = "RequestData"

-- Server -> Client control marker (sent as a bare string instead of a
-- WireMessage table, so the client can tell it apart from real messages
-- without a wrapper).
Protocol.RequestDataComplete = "RequestDataComplete"

-- Reference for where Remotes are parented.
Protocol.RemoteContainer = script

-- Custom-remote channels: a dedicated reliable RemoteEvent for reliable custom
-- signals, an UnreliableRemoteEvent for unreliable custom signals, and a
-- RemoteFunction for client->server function calls. These are kept separate
-- from the data channel so arbitrary RPC args never intermingle with the
-- binary MessageCodec stream.
Protocol.SignalName = "Signal"
Protocol.UnreliableSignalName = "UnreliableSignal"
Protocol.FunctionName = "Function"

return Protocol
