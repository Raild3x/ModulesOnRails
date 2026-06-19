--!native
--!optimize 2
--!strict

const Types = require("./Types")

type Connection = Types.Connection
type ConnectionPrivate<Function, Arguments...> = Types.ConnectionPrivate<Function, Arguments...>
type SignalPrivate<Function, Arguments...> = Types.SignalPrivate<Function, Arguments...>

-- Connection class
const Connection = {}
Connection.ClassName = "Connection"
Connection.__index = Connection

function Connection.new<Function, Arguments...>(signal: SignalPrivate<Function, Arguments...>, callback: Function): Connection
	-- `setmetatable` can't unify its inferred return type with a generic instantiation of
	-- `ConnectionPrivate<Function, Arguments...>`, so this cast is a necessary escape hatch.
	return setmetatable({
		Connected = true,

		Function = callback,
		Next = nil,
		Signal = signal,
	}, Connection) :: never
end

function Connection.Disconnect(self: ConnectionPrivate<any, ...any>)
	if not self.Connected then
		return
	end

	self.Connected = false

	-- Unhook the node, but DON'T clear it. That way any fire calls that are
	-- currently sitting on this node will be able to iterate forwards off of
	-- it, but any subsequent fire calls will not hit it, and it will be GCed
	-- when no more fire calls are sitting on it.
	local signal = self.Signal
	local previous = signal.HandlerListHead
	if previous == self then
		signal.HandlerListHead = self.Next
	else
		while previous and previous.Next ~= self do
			previous = previous.Next
		end

		if previous then
			previous.Next = self.Next
		end
	end
end

Connection.disconnect = Connection.Disconnect
Connection.Destroy = Connection.Disconnect

function Connection.__tostring(self: Connection): string
	return "Connection"
end

return table.freeze(Connection)
