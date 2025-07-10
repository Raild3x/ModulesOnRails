-- Logan Hunt [Raildex]
-- NetWire Types
--[=[
	@class NetWireTypes
	@ignore
	
	Type definitions for the NetWire library.
	This file provides all the type definitions used throughout the library,
	keeping them centralized for better maintainability and consistency.
]=]

--------------------------------------------------------------------------------
-- IMPORTS
--------------------------------------------------------------------------------

local Packages = script.Parent.Parent
local Promise = require(Packages.Promise)

--------------------------------------------------------------------------------
-- CORE TYPES
--------------------------------------------------------------------------------

export type Promise<T...> = typeof(Promise.new(function(_resolve: (T...) -> (), _reject: (any) -> ()) end))

--[=[
	@within NetWireTypes
	@interface Connection
	.Disconnect () -> () -- Disconnects the connection
	.Connected boolean -- Whether the connection is still active
	
	Represents a connection that can be disconnected.
]=]
export type Connection = {
	Disconnect: () -> (),
	Connected: boolean,
}

--[=[
	@within NetWireTypes
	@interface Service
	.Name string -- The name of the service
	.Client {[string]: any} -- Client-exposed methods and properties
	.[any] any -- Additional service properties
	
	Service table structure for integration with Roam framework or similar service-based architectures.
]=]
export type Service = {
	Name: string,
	Client: { [string]: any },
	[any]: any,
}

--------------------------------------------------------------------------------
-- MIDDLEWARE TYPES
--------------------------------------------------------------------------------

--[=[
	@within ServerNetWire
	@type ServerMiddleware (player: Player, args: {any}) -> (shouldContinue: boolean, ...any)
	
	Middleware function for server-side operations.
	Returns whether to continue processing and any modified arguments.
]=]
export type ServerMiddleware = (player: Player, args: { any }) -> (boolean, ...any)

--[=[
	@within ClientNetWire
	@type ClientMiddleware (args: {any}) -> (shouldContinue: boolean, ...any)
	
	Middleware function for client-side operations.
	Returns whether to continue processing and any modified arguments.
]=]
export type ClientMiddleware = (args: { any }) -> (boolean, ...any)

--------------------------------------------------------------------------------
-- REMOTE EVENT TYPES
--------------------------------------------------------------------------------

--[=[
	@class ServerRemoteEvent
	@server
	
	Server-side remote event class providing comprehensive event functionality.
	Based on Sleitnick's Comm RemoteSignal implementation.
]=]

--[=[
	@within ServerRemoteEvent
	@method Connect
	@param fn (player: Player, ...: any) -> nil
	@return Connection
	
	Connect a function to the signal. Anytime a matching ClientRemoteEvent
	on a client fires, the connected function will be invoked with the
	arguments passed by the client.
]=]

--[=[
	@within ServerRemoteEvent
	@method Fire
	@param player Player -- The target client
	@param ... any -- Arguments passed to the client
	
	Fires the signal at the specified client with any arguments.

	:::note Outbound Middleware
	All arguments pass through any outbound middleware (if any)
	before being sent to the clients.
	:::
]=]

--[=[
	@within ServerRemoteEvent
	@method FireAll
	@param ... any
	
	Fires the signal at _all_ clients with any arguments.

	:::note Outbound Middleware
	All arguments pass through any outbound middleware (if any)
	before being sent to the clients.
	:::
]=]

--[=[
	@within ServerRemoteEvent
	@method FireExcept
	@param ignorePlayer Player -- The client to ignore
	@param ... any -- Arguments passed to the other clients
	
	Fires the signal to all clients _except_ the specified
	client.

	:::note Outbound Middleware
	All arguments pass through any outbound middleware (if any)
	before being sent to the clients.
	:::
]=]

--[=[
	@within ServerRemoteEvent
	@method FireFilter
	@param predicate (player: Player, argsFromFire: ...) -> boolean
	@param ... any -- Arguments to pass to the clients (and to the predicate)
	
	Fires the signal at any clients that pass the `predicate`
	function test. This can be used to fire signals with much
	more control logic.

	:::note Outbound Middleware
	All arguments pass through any outbound middleware (if any)
	before being sent to the clients.
	:::

	:::caution Predicate Before Middleware
	The arguments sent to the predicate are sent _before_ getting
	transformed by any middleware.
	:::

	```lua
	-- Fire signal to players of the same team:
	remoteSignal:FireFilter(function(player)
		return player.Team.Name == "Best Team"
	end)
	```
]=]

--[=[
	@within ServerRemoteEvent
	@method FireFor
	@param players {Player}
	@param ... any
	
	Fires a signal at the clients within the `players` table. This is
	useful when signals need to fire for a specific set of players.

	For more complex firing, see `FireFilter`.

	:::note Outbound Middleware
	All arguments pass through any outbound middleware (if any)
	before being sent to the clients.
	:::

	```lua
	local players = {somePlayer1, somePlayer2, somePlayer3}
	remoteSignal:FireFor(players, "Hello, players!")
	```
]=]

--[=[
	@within ServerRemoteEvent
	@method IsUnreliable
	@return boolean
	
	Returns whether this remote event is unreliable (uses UnreliableRemoteEvent).
]=]

export type ServerRemoteEvent = {
	Connect: (self: ServerRemoteEvent, callback: (self: ServerRemoteEvent, plr: Player, ...any) -> ()) -> Connection,
	Fire: (self: ServerRemoteEvent, plr: Player, ...any) -> (),
	FireFor: (self: ServerRemoteEvent, plrs: { Player }, ...any) -> (),
	FireAll: (self: ServerRemoteEvent, ...any) -> (),
	FireExcept: (self: ServerRemoteEvent, plr: Player, ...any) -> (),
	FireFilter: (self: ServerRemoteEvent, predicate: (plr: Player, ...any) -> boolean, ...any) -> (),
	IsUnreliable: (self: ServerRemoteEvent) -> boolean,
}

--[=[
	@class ClientRemoteEvent
	@client
	
	Client-side remote event class for receiving and sending events to the server.
]=]

--[=[
	@within ClientRemoteEvent
	@method Connect
	@param fn (...: any) -> ()
	@return Connection
	
	Connects a function to the remote signal. The function will be
	called anytime the equivalent server-side RemoteSignal is
	fired at this specific client that created this client signal.
]=]

--[=[
	@within ClientRemoteEvent
	@method Fire
	@param ... any
	
	Fires the equivalent server-side signal with the given arguments.

	:::note Outbound Middleware
	All arguments pass through any outbound middleware before being
	sent to the server.
	:::
]=]

export type ClientRemoteEvent = {
	Connect: (self: ClientRemoteEvent, callback: (...any) -> ()) -> Connection,
	Fire: (self: ClientRemoteEvent, ...any) -> (),
}

--------------------------------------------------------------------------------
-- REMOTE PROPERTY TYPES
--------------------------------------------------------------------------------

--[=[
	@class ServerRemoteProperty
	@server
	
	Server-side remote property class with per-player state management.
	Based on Sleitnick's Comm RemoteProperty implementation.

	Values set can be anything that can pass through a
	[RemoteEvent](https://developer.roblox.com/en-us/articles/Remote-Functions-and-Events#parameter-limitations).

	Here is a cheat-sheet for the below methods:
	- Setting data
		- `Set`: Set "top" value for all current and future players. Overrides any custom-set data per player.
		- `SetTop`: Set the "top" value for all players, but does _not_ override any custom-set data per player.
		- `SetFor`: Set custom data for the given player. Overrides the "top" value. (_Can be nil_)
		- `SetForList`: Same as `SetFor`, but accepts a list of players.
		- `SetFilter`: Accepts a predicate function which checks for which players to set.
	- Clearing data
		- `ClearFor`: Clears the custom data set for a given player. Player will start using the "top" level value instead.
		- `ClearForList`: Same as `ClearFor`, but accepts a list of players.
		- `ClearFilter`: Accepts a predicate function which checks for which players to clear.
	- Getting data
		- `Get`: Retrieves the "top" value
		- `GetFor`: Gets the current value for the given player. If cleared, returns the top value.

	:::caution Network Usage
	Calling any of the data setter methods (e.g. `Set()`) will
	fire the underlying RemoteEvent to replicate data to the
	clients. Therefore, setting data should only occur when it
	is necessary to change the data that the clients receive.
	:::

	:::caution Tables
	Tables _can_ be used with RemoteProperties. However, the
	RemoteProperty object will _not_ watch for changes within
	the table. Therefore, anytime changes are made to the table,
	the data must be set again using one of the setter methods.
	:::
]=]

--[=[
	@within ServerRemoteProperty
	@method Set
	@param value any
	
	Sets the top-level value of all clients to the same value.
	
	:::note Override Per-Player Data
	This will override any per-player data that was set using
	`SetFor` or `SetFilter`. To avoid overriding this data,
	`SetTop` can be used instead.
	:::

	```lua
	-- Examples
	remoteProperty:Set(10)
	remoteProperty:Set({SomeData = 32})
	remoteProperty:Set("HelloWorld")
	```
]=]

--[=[
	@within ServerRemoteProperty
	@method SetTop
	@param value any
	
	Set the top-level value of the property, but does not override
	any per-player data (e.g. set with `SetFor` or `SetFilter`).
	Any player without custom-set data will receive this new data.

	This is useful if certain players have specific values that
	should not be changed, but all other players should receive
	the same new value.

	```lua
	-- Using just 'Set' overrides per-player data:
	remoteProperty:SetFor(somePlayer, "CustomData")
	remoteProperty:Set("Data")
	print(remoteProperty:GetFor(somePlayer)) --> "Data"

	-- Using 'SetTop' does not override:
	remoteProperty:SetFor(somePlayer, "CustomData")
	remoteProperty:SetTop("Data")
	print(remoteProperty:GetFor(somePlayer)) --> "CustomData"
	```
]=]

--[=[
	@within ServerRemoteProperty
	@method SetFor
	@param player Player
	@param value any
	
	Set the value of the property for a specific player. This
	will override the value used by `Set` (and the initial value
	set for the property when created).

	This value _can_ be `nil`. In order to reset the value for a
	given player and let the player use the top-level value held
	by this property, either use `Set` to set all players' data,
	or use `ClearFor`.

	```lua
	remoteProperty:SetFor(somePlayer, "CustomData")
	```
]=]

--[=[
	@within ServerRemoteProperty
	@method SetForList
	@param players {Player}
	@param value any
	
	Set the value of the property for specific players. This just
	loops through the players given and calls `SetFor`.

	```lua
	local players = {player1, player2, player3}
	remoteProperty:SetForList(players, "CustomData")
	```
]=]

--[=[
	@within ServerRemoteProperty
	@method SetFilter
	@param predicate (Player, any) -> boolean
	@param value any -- Value to set for the clients (and to the predicate)
	
	Sets the value for specific clients that pass the `predicate`
	function test. This can be used to finely set the values
	based on more control logic (e.g. setting certain values
	per team).

	```lua
	-- Set the value of "NewValue" to players with a name longer than 10 characters:
	remoteProperty:SetFilter(function(player)
		return #player.Name > 10
	end, "NewValue")
	```
]=]

--[=[
	@within ServerRemoteProperty
	@method ClearFor
	@param player Player
	
	Clears the custom property value for the given player. When
	this occurs, the player will reset to use the top-level
	value held by this property (either the value set when the
	property was created, or the last value set by `Set`).

	```lua
	remoteProperty:Set("DATA")

	remoteProperty:SetFor(somePlayer, "CUSTOM_DATA")
	print(remoteProperty:GetFor(somePlayer)) --> "CUSTOM_DATA"

	-- DOES NOT CLEAR, JUST SETS CUSTOM DATA TO NIL:
	remoteProperty:SetFor(somePlayer, nil)
	print(remoteProperty:GetFor(somePlayer)) --> nil

	-- CLEAR:
	remoteProperty:ClearFor(somePlayer)
	print(remoteProperty:GetFor(somePlayer)) --> "DATA"
	```
]=]

--[=[
	@within ServerRemoteProperty
	@method ClearForList
	@param players {Player}
	
	Clears the custom value for the given players. This
	just loops through the list of players and calls
	the `ClearFor` method for each player.
]=]

--[=[
	@within ServerRemoteProperty
	@method ClearFilter
	@param predicate (Player) -> boolean
	
	The same as `SetFilter`, except clears the custom value
	for any player that passes the predicate.
]=]

--[=[
	@within ServerRemoteProperty
	@method Get
	@return any
	
	Returns the top-level value held by the property. This will
	either be the initial value set, or the last value set
	with `Set()`.

	```lua
	remoteProperty:Set("Data")
	print(remoteProperty:Get()) --> "Data"
	```
]=]

--[=[
	@within ServerRemoteProperty
	@method GetFor
	@param player Player
	@return any
	
	Returns the current value for the given player. This value
	will depend on if `SetFor` or `SetFilter` has affected the
	custom value for the player. If so, that custom value will
	be returned. Otherwise, the top-level value will be used
	(e.g. value from `Set`).

	```lua
	-- Set top level data:
	remoteProperty:Set("Data")
	print(remoteProperty:GetFor(somePlayer)) --> "Data"

	-- Set custom data:
	remoteProperty:SetFor(somePlayer, "CustomData")
	print(remoteProperty:GetFor(somePlayer)) --> "CustomData"

	-- Set top level again, overriding custom data:
	remoteProperty:Set("NewData")
	print(remoteProperty:GetFor(somePlayer)) --> "NewData"

	-- Set custom data again, and set top level without overriding:
	remoteProperty:SetFor(somePlayer, "CustomData")
	remoteProperty:SetTop("Data")
	print(remoteProperty:GetFor(somePlayer)) --> "CustomData"

	-- Clear custom data to use top level data:
	remoteProperty:ClearFor(somePlayer)
	print(remoteProperty:GetFor(somePlayer)) --> "Data"
	```
]=]

export type ServerRemoteProperty = {
	Set: (self: ServerRemoteProperty, value: any) -> (),
	SetTop: (self: ServerRemoteProperty, value: any) -> (),
	SetFor: (self: ServerRemoteProperty, plr: Player, value: any) -> (),
	SetForList: (self: ServerRemoteProperty, plrs: { Player }, value: any) -> (),
	SetFilter: (self: ServerRemoteProperty, predicate: (plr: Player, value: any) -> boolean, value: any) -> (),
	ClearFor: (self: ServerRemoteProperty, plr: Player) -> (),
	ClearForList: (self: ServerRemoteProperty, plrs: { Player }) -> (),
	ClearFilter: (self: ServerRemoteProperty, predicate: (plr: Player) -> boolean) -> (),
	Get: (self: ServerRemoteProperty) -> any,
	GetFor: (self: ServerRemoteProperty, plr: Player) -> any,
}

--[=[
	@class ClientRemoteProperty
	@client
	
	Client-side remote property class with reactive updates.
	Based on Sleitnick's Comm RemoteProperty implementation.
]=]

--[=[
	@within ClientRemoteProperty
	@prop Changed Signal<any>

	Fires when the property receives an updated value
	from the server.

	```lua
	clientRemoteProperty.Changed:Connect(function(value)
		print("New value", value)
	end)
	```
]=]

--[=[
	@within ClientRemoteProperty
	@method Get
	@return any
	
	Gets the value of the property object.

	:::caution
	This value might not be ready right away. Use `OnReady()` or `IsReady()`
	before calling `Get()`. If not ready, this value will return `nil`.
	:::
]=]

--[=[
	@within ClientRemoteProperty
	@method OnReady
	@return Promise<any>
	
	Returns a Promise which resolves once the property object is
	ready to be used. The resolved promise will also contain the
	value of the property.

	```lua
	-- Use andThen clause:
	clientRemoteProperty:OnReady():andThen(function(initialValue)
		print(initialValue)
	end)

	-- Use await:
	local success, initialValue = clientRemoteProperty:OnReady():await()
	if success then
		print(initialValue)
	end
	```
]=]

--[=[
	@within ClientRemoteProperty
	@method IsReady
	@return boolean
	
	Returns `true` if the property object is ready to be
	used. In other words, it has successfully gained
	connection to the server-side version and has synced
	in the initial value.

	```lua
	if clientRemoteProperty:IsReady() then
		local value = clientRemoteProperty:Get()
	end
	```
]=]

--[=[
	@within ClientRemoteProperty
	@method Observe
	@param observer (any) -> nil
	@return Connection
	
	Observes the value of the property. The observer will
	be called right when the value is first ready, and
	every time the value changes. This is safe to call
	immediately (i.e. no need to use `IsReady` or `OnReady`
	before using this method).

	Observing is essentially listening to `Changed`, but
	also sends the initial value right away (or at least
	once `OnReady` is completed).

	```lua
	local function ObserveValue(value)
		print(value)
	end

	clientRemoteProperty:Observe(ObserveValue)
	```
]=]

export type ClientRemoteProperty = {
	Get: (self: ClientRemoteProperty) -> any,
	IsReady: (self: ClientRemoteProperty) -> boolean,
	OnReady: (self: ClientRemoteProperty) -> Promise<...any>,
	Observe: (self: ClientRemoteProperty, observer: (any) -> ()) -> Connection,
}

--------------------------------------------------------------------------------
-- MARKER TYPES
--------------------------------------------------------------------------------

--[=[
	@within NetWireTypes
	@interface EventMarker
	.__netWireMarker "Event"
	.inboundMiddleware {ServerMiddleware}?
	.outboundMiddleware {ServerMiddleware}?
	
	Marker object used to designate where remote events should be created.
]=]
export type EventMarker = {
	__netWireMarker: "Event",
	inboundMiddleware: { ServerMiddleware }?,
	outboundMiddleware: { ServerMiddleware }?,
}

--[=[
	@within NetWireTypes
	@interface PropertyMarker
	.__netWireMarker "Property"
	.initialValue any?
	.inboundMiddleware {ServerMiddleware}?
	.outboundMiddleware {ServerMiddleware}?
	
	Marker object used to designate where remote properties should be created.
]=]
export type PropertyMarker = {
	__netWireMarker: "Property",
	initialValue: any?,
	inboundMiddleware: { ServerMiddleware }?,
	outboundMiddleware: { ServerMiddleware }?,
}

return nil
