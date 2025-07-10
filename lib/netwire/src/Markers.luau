-- Logan Hunt [Raildex]
-- NetWire Markers
--[=[
	@class NetWireMarkers
	@ignore
	
	Utility functions for creating NetWire markers.
	These markers are used to designate where remote events and properties should be created.
	
	Markers provide a declarative way to set up networking infrastructure while maintaining
	type safety and providing clear intent about what type of remote object should be created.
]=]

--------------------------------------------------------------------------------
-- IMPORTS
--------------------------------------------------------------------------------

local NetWireTypes = require(script.Parent.NetWireTypes)
local Shared = require(script.Parent.Shared)

local Packages = script.Parent.Parent
local Symbol = require(Packages.Symbol)

--------------------------------------------------------------------------------
-- TYPES
--------------------------------------------------------------------------------

type EventMarker = NetWireTypes.EventMarker
type PropertyMarker = NetWireTypes.PropertyMarker
type ServerMiddleware = NetWireTypes.ServerMiddleware
type ServerRemoteProperty = NetWireTypes.ServerRemoteProperty
type ServerRemoteEvent = NetWireTypes.ServerRemoteEvent

--------------------------------------------------------------------------------
-- CONSTANTS
--------------------------------------------------------------------------------

-- Marker symbols for different remote types (local to this module)
local SIGNAL_MARKER = Symbol("SIGNAL_MARKER")
local UNRELIABLE_SIGNAL_MARKER = Symbol("UNRELIABLE_SIGNAL_MARKER")
local PROPERTY_MARKER = Symbol("PROPERTY_MARKER")

-- Create the marker metatable
local MARKER_MT = {
	__index = function(_, k: string)
		error(
			"Attempted to access an uninitialized NetWire object with key: "
				.. tostring(k)
				.. ". Ensure you have initialized the NetWire object prior to accessing this."
		)
	end,
	__tostring = function(self)
		if self[1] == SIGNAL_MARKER then
			return "NetWire.EventMarker"
		elseif self[1] == UNRELIABLE_SIGNAL_MARKER then
			return "NetWire.UnreliableEventMarker"
		elseif self[1] == PROPERTY_MARKER then
			return "NetWire.PropertyMarker"
		end
		return "NetWire.UnknownMarker"
	end,
}

--------------------------------------------------------------------------------
-- MARKER CREATION FUNCTIONS
--------------------------------------------------------------------------------

local NetWireMarkers = {}

--[=[
    @within NetWire

    Returns an EventMarker that is used to mark where a remoteSignal should be created.
    Calls ServerNetWire:RegisterEvent() when set to the index of a ServerNetWire.
    See ServerNetWire:RegisterEvent for more information.

    ```lua
    local MyWire = NetWire.Server("MyWire")
    MyWire.MyEvent = NetWire.createEvent()

    MyWire.MyEvent:Connect(function(plr: Player, msg: string)
        print(plr, "said:", msg)
    end)
    ```
]=]
function NetWireMarkers.createEvent(
	inboundMiddleware: { ServerMiddleware }?,
	outboundMiddleware: { ServerMiddleware }?
): ServerRemoteEvent
	Shared.validateContext(true, "createEvent")
	return setmetatable({ SIGNAL_MARKER, inboundMiddleware, outboundMiddleware }, MARKER_MT) :: any
end

--[=[
    @within NetWire
    
    Returns an EventMarker that is used to mark where an unreliable remoteSignal should be created.
    Calls ServerNetWire:RegisterEvent() when set to the index of a ServerNetWire.
    See ServerNetWire:RegisterEvent for more information.

    ```lua
    local MyWire = NetWire.Server("MyWire")
    MyWire.MyEvent = NetWire.createUnreliableEvent()

    MyWire.MyEvent:FireAll("Hello, world!")
    ```
]=]
function NetWireMarkers.createUnreliableEvent(
	inboundMiddleware: { ServerMiddleware }?,
	outboundMiddleware: { ServerMiddleware }?
): ServerRemoteEvent
	Shared.validateContext(true, "createUnreliableEvent")
	return setmetatable({ UNRELIABLE_SIGNAL_MARKER, inboundMiddleware, outboundMiddleware }, MARKER_MT) :: any
end

--[=[
	@within NetWire

	Returns a PropertyMarker that is used to mark where a remoteProperty should be created.
	NetWire will transform this marker into an actual ServerRemoteProperty. The returned value
	of this is actually a symbol and only becomes usable when set to the index of a ServerNetWire.

	@param initialValue any? -- Initial value for the property
	@param inboundMiddleware {ServerMiddleware}?
	@param outboundMiddleware {ServerMiddleware}?
	@return ServerRemoteProperty

	```lua
	local MyWire = NetWire.Server("MyWire")
	MyWire.MyProperty = NetWire.createProperty("Initial Value")
	MyWire.MyProperty:Set("New Value")
	print(MyWire.MyProperty:Get())
	```
]=]
function NetWireMarkers.createProperty(
	initialValue: any?,
	inboundMiddleware: { ServerMiddleware }?,
	outboundMiddleware: { ServerMiddleware }?
): ServerRemoteProperty
	Shared.validateContext(true, "createProperty")
	return setmetatable({ PROPERTY_MARKER, initialValue, inboundMiddleware, outboundMiddleware }, MARKER_MT) :: any
end

--------------------------------------------------------------------------------
-- INTERNAL EXPORTS
--------------------------------------------------------------------------------

-- Export symbols for internal use
NetWireMarkers._SIGNAL_MARKER = SIGNAL_MARKER
NetWireMarkers._UNRELIABLE_SIGNAL_MARKER = UNRELIABLE_SIGNAL_MARKER
NetWireMarkers._PROPERTY_MARKER = PROPERTY_MARKER

return NetWireMarkers
