--!native
--!optimize 2
--!strict
--[[
    Authors:
        stravant - July 31st, 2021 - Created the file.
        sleitnick - August 3rd, 2021 - Modified for Knit.
        HowManySmall - July 30th, 2024 - Added several new features and strict mode.
        Raildex - June 17, 2026 - Lune path support and other minor changes.
    License:
        Licensed under the MIT license.
]]
--[=[
    @class Signal

    Batched Yield-Safe Signal Implementation

    This is a Signal class which has effectively identical behavior to a
    normal RBXScriptSignal, with the only difference being a couple extra
    stack frames at the bottom of the stack trace when an error is thrown.
    This implementation caches runner coroutines, so the ability to yield in
    the signal handlers comes at minimal extra cost over a naive signal
    implementation that either always or never spawns a thread.

    Example:
    ```lua
    local signal: Signal<(message: string) -> (), string> = Signal.new()

    signal:Connect(function(message) -- message type is inferred and the parameter name is as well :)
        print("Got message:", message)
    end)

    signal:Fire("Hello world!")
    ```
]=]

--// Imports //--
const Types = require("./Types")
const FastDefer = require("./FastDefer")
const IsDeferred = require("./IsDeferred")
const Connection = require("./Connection")

--// Constants //--
local IS_DEFERRED = IsDeferred()

--// Volatile State //--
-- The currently idle thread to run the next handler on
local FreeRunnerThread: thread? = nil

--// Types //--
type SignalPrivate<Fn, Args...> = Types.SignalPrivate<Fn, Args...>

export type Connection = Types.Connection
export type Signal<Fn, Args...> = Types.Signal<Fn, Args...>
export type ClassicSignal<Args...> = Types.ClassicSignal<Args...>
export type VoidSignal = Types.VoidSignal

-------------------------------------------------------------------------------------
--// Utility Fns //--
-------------------------------------------------------------------------------------

-- Fn which acquires the currently idle handler runner thread, runs the
-- callback on it, and then releases the thread, returning it to being the
-- currently idle one.
-- If there was a currently idle runner thread already, that's okay, that old
-- one will just get thrown and eventually GCed.
const function AcquireRunnerThreadAndCallEventHandler<Args...>(callback: (Args...) -> (), ...: Args...)
	local acquiredRunnerThread = FreeRunnerThread
	FreeRunnerThread = nil
	callback(...)
	-- The handler finished running, this runner thread is free again.
	FreeRunnerThread = acquiredRunnerThread
end

-- Coroutine runner that we create coroutines of. The coroutine can be
-- repeatedly resumed with functions to run followed by the argument to run
-- them with.
const function RunEventHandlerInFreeThread<Args...>(callback: (Args...) -> (), ...: Args...)
	AcquireRunnerThreadAndCallEventHandler(callback, ...)
	while true do
		AcquireRunnerThreadAndCallEventHandler(coroutine.yield())
	end
end

-- Guards against a connection being disconnected before its deferred call runs
-- (the connection may have been unhooked between `task.defer`/`FastDefer` being
-- scheduled and this actually executing).
const function DeferExecution<Fn, Args...>(connection: Types.ConnectionPrivate<any, Args...>, ...: Args...)
	if connection.Connected then
		connection.Fn(...)
	end
end

-------------------------------------------------------------------------------------
--// Class Setup //--
-------------------------------------------------------------------------------------

const Signal = {}
Signal.ClassName = "Signal"
const Signal_MT = {
	__index = Signal,
	__tostring = function()
		return "Signal"
	end,
}

--[=[
	Whether or not to do a warning when a thread is suspended when
	[Signal.DisconnectAll] is called. By default it is `false`.

	@since v2.1.0
	@prop DebugMode boolean
	@within Signal
]=]

--[=[
	Constructs a new Signal.

	@param janitor? Janitor -- Adds the Signal to the Janitor.
	@return Signal<Fn, Args...>
]=]
function Signal.new<Fn, Args...>(janitor: Types.JanitorLike?): Signal<Fn, Args...>
	-- `setmetatable` can't unify its inferred return type with a generic instantiation of
	-- `SignalPrivate<Fn, Args...>`, so this cast is a necessary escape hatch.
	const self: SignalPrivate<Fn, Args...> = setmetatable({}, Signal_MT) :: never
	self.DebugMode = false
	self.HandlerListHead = nil
	self.ProxyHandler = nil
	self.YieldedThreads = nil

	if janitor then
		janitor:Add(self, "Destroy")
	end

	return self :: Signal<Fn, Args...>
end

--[=[
	Constructs a new Signal that wraps around an RBXScriptSignal.

	For example:

	```lua
	local signal = Signal.Wrap(workspace.ChildAdded)
	signal:Connect(function(part) print(part.Name .. " added") end)
	Instance.new("Part").Parent = workspace
	```

	@param rbxScriptSignal RBXScriptSignal -- Existing RBXScriptSignal to wrap
	@param janitor? Janitor -- Adds the Signal to the Janitor.
	@return Signal
]=]
function Signal.Wrap<Fn, Args...>(rbxScriptSignal: RBXScriptSignal, janitor: Types.JanitorLike?): Signal<Fn, Args...>
	const self: SignalPrivate<Fn, Args...> = setmetatable({}, Signal_MT) :: never
	self.DebugMode = false
	self.HandlerListHead = nil
	self.YieldedThreads = nil

	if janitor then
		janitor:Add(self, "Destroy")
	end

	self.ProxyHandler = rbxScriptSignal:Connect(function(...)
		self:Fire(...)
	end)

	return self :: Signal<Fn, Args...>
end

--[=[
	Checks if the given value is a Signal.

	@param value unknown -- Object to check.
	@return boolean -- `true` if the value is a Signal.
]=]
function Signal.Is(value: any): boolean
	return type(value) == "table" and getmetatable(value) == Signal
end

--[=[
	A shorthand for [Signal.Is].

	@function instanceof
	@within Signal

	@param value unknown -- Object to check.
	@return boolean -- `true` if the value is a Signal.
]=]
Signal.instanceof = Signal.Is

-------------------------------------------------------------------------------------
--// Methods //--
-------------------------------------------------------------------------------------

--[=[
	Connects a function to the signal, which will be called anytime the signal
	is fired.

	```lua
	signal:Connect(function(msg, num)
		print(msg, num)
	end)

	signal:Fire("Hello", 25)
	```

	@method Connect
	@within Signal

	@param callback (Args...) -> () -- The function you are connecting.
	@return Connection
]=]
function Signal.Connect<Fn, Args...>(self: SignalPrivate<Fn, Args...>, callback: (Args...) -> ()): Connection
	-- TODO: optimize this further
	const connection: Types.ConnectionPrivate<any, ...any> = setmetatable({
		Connected = true,

		Fn = callback,
		Next = nil,
		Signal = self,
	}, Connection) :: never

	const handlerListHead = self.HandlerListHead
	if handlerListHead then
		connection.Next = handlerListHead
		self.HandlerListHead = connection
	else
		self.HandlerListHead = connection
	end

	return connection :: Connection
end

--[=[
	@deprecated v1.3.0 -- Use `Signal:Once` instead.
	@param callback (Args...) -> () -- The function you are connecting.
	@return Connection
]=]
function Signal.ConnectOnce<Fn, Args...>(self: Signal<Fn, Args...>, callback: (Args...) -> ()): Connection
	return self:Once(callback)
end

--[=[
	Connects a function to the signal, which will be called the next time the signal fires. Once
	the connection is triggered, it will disconnect itself.

	```lua
	signal:Once(function(msg, num)
		print(msg, num)
	end)

	signal:Fire("Hello", 25)
	signal:Fire("This message will not go through", 10)
	```

	@param callback (Args...) -> () -- The function you are connecting.
	@return Connection
]=]
function Signal.Once<Fn, Args...>(self: Signal<Fn, Args...>, callback: (Args...) -> ()): Connection
	local connection: Connection
	local hasFired = false
	connection = self:Connect(function(...)
		if hasFired then
			return
		end
		hasFired = true
		connection:Disconnect()
		callback(...)
	end)

	return connection
end

--[=[
	The exact same as [Signal.Connect], but it returns an [RBXScriptConnection]
	instead.

	@since v2.0.0
	@method ConnectClassic
	@within Signal

	@param callback (Args...) -> () -- The function you are connecting.
	@return RBXScriptConnection
]=]
-- `ConnectClassic`/`OnceClassic`/`ConnectOnceClassic` intentionally expose `Connect`/
-- `Once`/`ConnectOnce` under a label suggesting an `RBXScriptConnection`-returning API,
-- even though the runtime value is always our own `Connection` table (which duck-types
-- compatibly: `Connected`, `Disconnect`). This bridges that intentional mismatch.
Signal.ConnectClassic = Signal.Connect :: any
Signal.ConnectOnceClassic = Signal.ConnectOnce :: any
--[=[
	The exact same as [Signal.Once], but it returns an [RBXScriptConnection]
	instead.

	@since v2.0.0
	@method OnceClassic
	@within Signal

	@param callback (Args...) -> () -- The function you are connecting.
	@return RBXScriptConnection
]=]
Signal.OnceClassic = Signal.Once :: any

--[=[
	Gets all the connections in the signal.

	@method GetConnections
	@within Signal

	@return {Connection}
]=]
function Signal.GetConnections<Fn, Args...>(self: SignalPrivate<Fn, Args...>): { Connection }
	const items: { Connection } = {}
	local length = 0

	local item = self.HandlerListHead
	while item do
		length += 1
		items[length] = item
		item = item.Next
	end

	return items
end

--[=[
	Checks if there are any active connections in the signal.

	@since v1.0.1
	@method IsConnectedTo
	@within Signal

	@return boolean
]=]
function Signal.IsConnectedTo<Fn, Args...>(self: SignalPrivate<Fn, Args...>): boolean
	return not not self.HandlerListHead
end

-- Signal:Fire(...) implemented by running the handler functions on the
-- coRunnerThread, and any time the resulting thread yielded without returning
-- to us, that means that it yielded to the Roblox scheduler and has been taken
-- over by Roblox scheduling, meaning we have to make a new coroutine runner.
--[=[
	Fire the signal, which will call all of the connected functions with the
	given arguments.

	```lua
	signal:Fire("Hello")

	-- Any number of arguments can be fired:
	signal:Fire("Hello", 32, {Test = "Test"}, true)
	```

	@method Fire
	@within Signal

	@param ... Args...
]=]
function Signal.Fire<Fn, Args...>(self: SignalPrivate<Fn, Args...>, ...: Args...)
	local item = self.HandlerListHead
	while item do
		if item.Connected then
			if not FreeRunnerThread then
				FreeRunnerThread = coroutine.create(RunEventHandlerInFreeThread)
			end
			task.spawn(FreeRunnerThread :: thread, item.Fn, ...)
		end
		item = item.Next
	end
end

--[=[
	Same as [Signal.Fire], but uses `task.defer` internally & doesn't take
	advantage of thread reuse.

	```lua
	signal:FireDeferred("Hello")
	```

	@method FireDeferred
	@within Signal

	@param ... Args...
]=]
function Signal.FireDeferred<Fn, Args...>(self: SignalPrivate<Fn, Args...>, ...: Args...)
	local item = self.HandlerListHead
	while item do
		task.defer(DeferExecution, item, ...)
		item = item.Next
	end
end

--[=[
	An "unsafe" version of [Signal.FireDeferred] that uses recycled threads
	to fire. Don't know if this will work the exact same, therefore it is
	unsafe. This should be faster than even [Signal.Fire] though, or around its
	performance level.

	@since v2.0.0
	@method FireDeferredUnsafe
	@within Signal

	@param ... Args...
]=]
function Signal.FireDeferredUnsafe<Fn, Args...>(self: SignalPrivate<Fn, Args...>, ...: Args...)
	local item = self.HandlerListHead
	while item do
		FastDefer(DeferExecution, item, ...)
		item = item.Next
	end
end

--[=[
	This function mirrors how a [BindableEvent] would be fired given the
	current [Workspace.SignalBehavior] setting. If it is set to
	`Enum.SignalBehavior.Deferred`, it will use [Signal.FireDeferred] and if it
	is set to `Enum.SignalBehavior.Immediate`, it will use [Signal.Fire].

	@since v2.1.0
	@method FireBindable
	@within Signal

	@param ... Args...
]=]
Signal.FireBindable = if IS_DEFERRED then Signal.FireDeferred else Signal.Fire

--[=[
	This function mirrors how a [BindableEvent] would be fired given the
	current [Workspace.SignalBehavior] setting. If it is set to
	`Enum.SignalBehavior.Deferred`, it will use [Signal.FireDeferredUnsafe]
	and if it is set to `Enum.SignalBehavior.Immediate`, it will use
	[Signal.Fire].

	@since v2.1.0
	@method FireBindableUnsafe
	@within Signal

	@param ... Args...
]=]
Signal.FireBindableUnsafe = if IS_DEFERRED then Signal.FireDeferredUnsafe else Signal.Fire

--[=[
	Yields the current thread until the signal is fired, and returns the
	arguments fired from the signal. Yielding the current thread is not always
	desirable. If the desire is to only capture the next event fired, using
	[Signal.Once] might be a better solution.

	```lua
	task.spawn(function()
		local msg, num = signal:Wait()
		print(msg, num) --> "Hello", 32
	end)

	signal:Fire("Hello", 32)
	```

	@method Wait
	@within Signal

	@yields
	@return ... Args...
]=]
function Signal.Wait<Fn, Args...>(self: SignalPrivate<Fn, Args...>): Args...
	local yieldedThreads = self.YieldedThreads :: { [thread]: true }
	if not yieldedThreads then
		yieldedThreads = {}
		self.YieldedThreads = yieldedThreads
	end

	const thread = coroutine.running()
	yieldedThreads[thread] = true

	self:Once(function(...)
		yieldedThreads[thread] = nil
		task.spawn(thread, ...)
	end)

	return coroutine.yield()
end

--[=[
	Disconnect all handlers. Since we use a linked list it suffices to clear
	the reference to the head handler.

	```lua
	signal:DisconnectAll()
	```

	@method DisconnectAll
	@within Signal
]=]
function Signal.DisconnectAll<Fn, Args...>(self: SignalPrivate<Fn, Args...>)
	local item = self.HandlerListHead
	while item do
		item.Connected = false
		item = item.Next
	end

	self.HandlerListHead = nil

	const yieldedThreads = self.YieldedThreads
	if yieldedThreads then
		const debugMode = self.DebugMode
		for thread in yieldedThreads do
			if coroutine.status(thread) == "suspended" then
				if debugMode then
					warn(debug.traceback(thread, "signal disconnected; yielded thread cancelled", 2))
				end
				task.cancel(thread)
			end
		end
		table.clear(yieldedThreads)
	end
end

--[=[
	Cleans up the signal and renders it completely unusable.

	:::tip Cleanups
	Technically, this is only necessary if the signal is created using
	[Signal.Wrap]. Connections should be properly GC'd once the signal is no
	longer referenced anywhere. However, it is still good practice to include
	ways to strictly clean up resources. Calling [Signal.Destroy] on a signal
	will also disconnect all connections immediately.
	:::

	```lua
	signal:Destroy()
	```

	@method Destroy
	@within Signal
]=]
function Signal.Destroy<Fn, Args...>(self: SignalPrivate<Fn, Args...>)
	self:DisconnectAll()

	const proxyHandler = self.ProxyHandler
	if proxyHandler then
		proxyHandler:Disconnect()
	end

	table.clear(self)
	setmetatable(self, nil)
end

return table.freeze(Signal) :: {
	ClassName: "Signal",
	new: <Fn, Args...>(janitor: Types.JanitorLike?) -> Signal<Fn, Args...>,
	Wrap: <Fn, Args...>(rbxScriptSignal: RBXScriptSignal, janitor: Types.JanitorLike?) -> Signal<Fn, Args...>,
	Is: (value: any) -> boolean,
}
