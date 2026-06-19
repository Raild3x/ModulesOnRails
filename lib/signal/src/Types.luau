--!strict

--[=[
	A Fn connected to a signal.
	@type ConnectionFn (...any) -> ()
	@within Signal
]=]

--[=[
	Represents a connection to a signal.

	```lua
	local connection = signal:Connect(Fn() end)
	print(connection.Connected) --> true
	connection:Disconnect()
	print(connection.Connected) --> false
	```

	@interface Connection
	@field Connected boolean
	@field Disconnect (self: Connection) -> ()
	@field Destroy (self: Connection) -> ()
	@field disconnect (self: Connection) -> ()
	@within Signal
]=]

-------------------------------------------------------------------------------------
--// Connection //--
-------------------------------------------------------------------------------------

export type Connection = {
	Connected: boolean,

	Disconnect: (self: Connection) -> (),
	Destroy: (self: Connection) -> (),
	disconnect: (self: Connection) -> (),
}

export type ConnectionPrivate<Fn, Args...> = {
	Fn: Fn,
	Next: ConnectionPrivate<Fn, Args...>?,
	Signal: SignalPrivate<Fn, Args...>,
} & Connection

-------------------------------------------------------------------------------------
--// Signal //--
-------------------------------------------------------------------------------------

export type JanitorLike = {
	Add: (self: JanitorLike, item: any, cleanupMethodName: string?, key: any?) -> any,
}

export type Signal<Fn, Args...> = {
	DebugMode: boolean,
	Connect: (self: Signal<Fn, Args...>, Fn: Fn) -> Connection,
	Once: (self: Signal<Fn, Args...>, Fn: Fn) -> Connection,
	-- ConnectOnce: (self: Signal<Fn, Args...>, Fn: Fn) -> Connection, -- Deprecated, use Once instead

	-- Same as Connect, but the return types to a RBXScriptConnection instead of a Connection. (Internally the same)
	ConnectClassic: (self: Signal<Fn, Args...>, Fn: Fn) -> RBXScriptConnection,
	OnceClassic: (self: Signal<Fn, Args...>, Fn: Fn) -> RBXScriptConnection,
	-- ConnectOnceClassic: (self: Signal<Fn, Args...>, Fn: Fn) -> RBXScriptConnection, -- Deprecated, use OnceClassic instead

	GetConnections: (self: Signal<Fn, Args...>) -> { Connection },
	IsConnectedTo: (self: Signal<Fn, Args...>) -> boolean,

	--- Fire the callbacks immediately (spawn).
	Fire: (self: Signal<Fn, Args...>, Args...) -> (),
	--- Fires the callbacks deferred.
	FireDeferred: (self: Signal<Fn, Args...>, Args...) -> (),
	--- Fires the callbacks deferred, but reuses threads if possible.
	FireDeferredUnsafe: (self: Signal<Fn, Args...>, Args...) -> (),
	--- Fires the callbacks depending on the environment settings.
	FireBindable: (self: Signal<Fn, Args...>, Args...) -> (),
	--- Fires the callbacks depending on the environment settings, but reuses threads if possible.
	FireBindableUnsafe: (self: Signal<Fn, Args...>, Args...) -> (),

	Wait: (self: Signal<Fn, Args...>) -> Args...,

	DisconnectAll: (self: Signal<Fn, Args...>) -> (),
	Destroy: (self: Signal<Fn, Args...>) -> (),
}

export type SignalPrivate<Fn, Args...> = {
	HandlerListHead: ConnectionPrivate<Fn, Args...>?,
	ProxyHandler: RBXScriptConnection?,
	YieldedThreads: { [thread]: true }?,
} & Signal<Fn, Args...>

-------------------------------------------------------------------------------------
--// Exported convenience aliases //--
-------------------------------------------------------------------------------------

-- A signal that fires with no Args.
export type VoidSignal = Signal<() -> ()>

-- `Signal<Fn, Args...>` with a single argument-pack generic parameter
-- instead of separate `Fn`/`Args...` parameters — for call sites that don't
-- need a named callback signature (e.g. `Signal.ClassicSignal<...any>`).
export type ClassicSignal<T...> = Signal<(T...) -> (), T...>

return nil
