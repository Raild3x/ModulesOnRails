-- Logan Hunt [Raildex]
-- Sep 15, 2023
-- Reorganized for better linting support
--[=[
    @class ServerNetWire
    @server

    Server-side NetWire implementation using Sleitnick's Comm under the hood. 
    Provides a comprehensive interface for creating and managing networking infrastructure
    across your server codebase.

    **Structure:**
    - `ServerNetWireClass`: Contains static methods (constructors, utilities)
    - `ServerNetWire`: Contains instance methods (RegisterEvent, RegisterProperty, etc.)
    
    This separation ensures better linting support and prevents static methods from appearing 
    in instance method suggestions.

    **Key Features:**
    - **Declarative API**: Use markers to declare networking infrastructure
    - **Memoization**: NetWires are cached by namespace for consistency
    - **Service Integration**: Built-in support for Roam and similar frameworks
    - **Middleware Support**: Comprehensive inbound and outbound middleware system
    - **Type Safety**: Full typing with proper metatable integration

    **NetWire Creation:**
    The following variables are all equivalent as NetWires are memoized by their namespace,
    so creating a new one with the same namespace will return the same object.
    ```lua
    local TestNetWire1 = NetWire.Server.new("MyNetWire")
    local TestNetWire2 = NetWire.Server("MyNetWire")

    print(TestNetWire1 == TestNetWire2) -- true 
    ```
    :::info
    You can also create a by calling the package directly, but this is not encouraged as it
    obscures the RunContext in which the NetWire is being created.
    ```lua
    local TestNetWire3 = NetWire("MyNetWire")
    ```
    :::

    **Event and Property Creation:**
    You can create client exposed events by registering them with the method or setting their index:
    The following two lines accomplish the same thing.
    ```lua
    TestNetWire:RegisterEvent("TestEvent")
    TestNetWire.TestEvent = NetWire.createEvent()
    ```
    More examples can be found under the respective construction methods.
]=]

--[[
     [API]
      [NETWIRE CLASS]
        .createEvent() -> EventMarker
        .createProperty(initialValue: any?) -> PropertyMarker
        .getServer(wireName: string) -> ServerNetWire?
        .Server -> ServerNetWireClass

      [SERVER NETWIRE CLASS]
        .new(nameSpace: string) -> ServerNetWire
        .fromService(service: Service) -> ServerNetWire
        :RegisterEvent(eventName: string)
        :RegisterProperty(propertyName: string, initialValue: any?)
        :RegisterMethod(functionName: string, callback: (self: any, plr: Player, ...any) -> (...any), tbl: {}?)
        :Destroy()

    --------------------------------------------------------------------------------
    More Examples
    --------------------------------------------------------------------------------
    ```lua
    local NetWire = require(ReplicatedStorage.NetWire)

    local myNetWire = NetWire.Server("MyNetWire")

    --------------------------------------------------------------------------------
    -- Setup a method
    function myNetWire:ServerSideFunction(player: Player, someArg: number)
        print(someArg)
        return someArg * 2
    end

    --------------------------------------------------------------------------------
    -- Aliases (These are equivalent. You can use either to create remote events)
    myNetWire.ServerSideEvent = NetWire.createEvent()
    myNetWire:RegisterEvent("ServerSideEvent")

    -- Connect to an event
    myNetWire.ServerSideEvent:Connect(function(plr: Player, someArg)
        print(someArg)
    end)

    -- Fire an event
    myNetWire.ServerSideEvent:FireAll(someArg)

    --------------------------------------------------------------------------------
    -- Properties
    myNetWire.ServeSideProperty = NetWire.createProperty(0)
    ```
]]

--------------------------------------------------------------------------------
-- IMPORTS
--------------------------------------------------------------------------------

local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local RemotesFolder: Folder = script.Parent:FindFirstChild("Remotes")

local Packages = script.Parent.Parent
local Comm = require(Packages.Comm).ServerComm
local Markers = require(script.Parent.Markers)
local Types = require(script.Parent.NetWireTypes)
local Shared = require(script.Parent.Shared)
local ServerPromiseConversionMiddleware = require(script.Parent.Utils.ServerPromiseConversionMiddleware)

--------------------------------------------------------------------------------
-- CONSTANTS
--------------------------------------------------------------------------------

-- Import shared symbols
local NAME_KEY = Shared.NAME_KEY
local COMM_KEY = Shared.COMM_KEY

-- Import marker symbols from Markers module
local SIGNAL_MARKER = Markers._SIGNAL_MARKER
local UNRELIABLE_SIGNAL_MARKER = Markers._UNRELIABLE_SIGNAL_MARKER
local PROPERTY_MARKER = Markers._PROPERTY_MARKER

--------------------------------------------------------------------------------
-- TYPE DEFINITIONS
--------------------------------------------------------------------------------

--// Types //--
type table = { [any]: any }
type SignalMarker = typeof(SIGNAL_MARKER)
type UnreliableSignalMarker = typeof(UNRELIABLE_SIGNAL_MARKER)
type PropertyMarker = typeof(PROPERTY_MARKER)
type Marker = SignalMarker | PropertyMarker | UnreliableSignalMarker
type ParsableValue = Marker | (self: table, player: Player, ...any) -> ...any

type Service = {
	Name: string,
	Client: { [string]: ParsableValue },
	[any]: any,
}

type Connection = Types.Connection
type ServerRemoteEvent = Types.ServerRemoteEvent
type ServerRemoteProperty = Types.ServerRemoteProperty
type ServerMiddleware = Types.ServerMiddleware

--------------------------------------------------------------------------------
-- MODULE STATE
--------------------------------------------------------------------------------

--// Module State //--
local NetWireCache = {} -- Cache of all Wires

--------------------------------------------------------------------------------
-- PRIVATE HELPER FUNCTIONS
--------------------------------------------------------------------------------

--[[
    Attempts to register a value to the NetWire. It will infer the type of value and call the corresponding method.
]]
local function autoRegister(self: any, k: string, v: ParsableValue): boolean
	if type(v) == "function" then
		self:RegisterMethod(k, v)
	elseif type(v) == "table" then
		local vType = v[1]
		if vType == SIGNAL_MARKER then
			self:RegisterEvent(k, false, table.unpack(v, 2))
		elseif vType == UNRELIABLE_SIGNAL_MARKER then
			self:RegisterEvent(k, true, table.unpack(v, 2))
		elseif vType == PROPERTY_MARKER then
			self:RegisterProperty(k, table.unpack(v, 2))
		else
			return false
		end
	else
		return false
	end
	return true
end

--[[
    Reads through a table and adds all the methods, events, and properties to the NetWire.
]]
local function parseTable(self: any, tbl: { [string]: ParsableValue })
	for k, v in pairs(tbl) do
		local registrationSuccess = autoRegister(self, k, v)
		if not registrationSuccess then
			warn("Unsupported Value in table:", v, "at key:", k, "\n", debug.traceback())
		end
	end
end

--[[
    Sets the Server index of the NetWire. Used with RemoteMethods and Services.
]]
local function setServer(self: any, tbl: { [any]: any })
	rawset(self, "Server", tbl)
end

--------------------------------------------------------------------------------
-- SERVER NETWIRE CLASS (STATIC METHODS)
--------------------------------------------------------------------------------

local ServerNetWireClass = {}
ServerNetWireClass.ClassName = "ServerNetWire"

--------------------------------------------------------------------------------
-- INSTANCE METHODS CLASS
--------------------------------------------------------------------------------

--// ServerNetWire Instance Methods Class //--
local ServerNetWire = {}

local ServerNetWireMT = {}
ServerNetWireMT.__index = ServerNetWire
ServerNetWireMT.__newindex = function(self, k: string, v: ParsableValue)
	local registrationSuccess = autoRegister(self, k, v)
	if not registrationSuccess then
		warn("Attempted to set unexpected Value in ServerNetWire table:", v, "at key:", k)
		rawset(self, k, v)
	end
	return v
end
table.freeze(ServerNetWireMT)

--[=[
    @within ServerNetWire
    @prop ClassName "ServerNetWire"
    @readonly
    @private
]=]
ServerNetWire.ClassName = "ServerNetWire"

--[=[
    @tag constructor
    @tag static
    @within ServerNetWire

    Constructs a new ServerNetWire. If a ServerNetWire with the same nameSpace already exists, it will
    be returned instead.
    
    @param nameSpace string | Service -- The namespace for the NetWire or a Service object
    @return ServerNetWire
]=]
function ServerNetWireClass.new(nameSpace: string | Service)
	if typeof(nameSpace) == "table" then
		return ServerNetWireClass.setupServiceNetworking(nameSpace)
	end
	assert(RunService:IsServer(), "ServerNetWire.new can only be called from the server")
	assert(type(nameSpace) == "string", "ServerNetWire.new expects a string for the nameSpace parameter")

	-- Check if a NetWire with the same nameSpace already exists
	if NetWireCache[nameSpace] then
		return NetWireCache[nameSpace]
	end

	local self = {}

	-- Allows linter to recognize the Server index
	self.Server = nil :: any

	-- Allows linter to recognize string keys as potential Remotes
	self["" :: string] = (
		nil :: any
	) :: ServerRemoteEvent & ServerRemoteProperty & (self: any, player: Player, ...any) -> ...any

	-- Set up the internal keys for the NetWire
	self[NAME_KEY] = nameSpace
	self[COMM_KEY] = Comm.new(RemotesFolder, nameSpace)
	setmetatable(self, ServerNetWireMT)

	NetWireCache[nameSpace] = self

	return self
end

--[=[
    @tag constructor
    @tag static
    @within ServerNetWire

    @param service Service
    @return ServerNetWire

    Creates a ServerNetWire from a Roam Service.
    This method will read the service's Name and Client table to create the NetWire.
    The goal of this function is to recreate the simplicity of Knit's networking features without
    the systems being coupled together. 
    In order to access the service on the client, use `NetWire.Client("SERVICE_NAME")`.

    ```lua
    local NetWire = require(Packages.NetWire).Server
    local Roam = require(Packages.Roam)
    ----------------------------------------------------------------

    local ExampleService = {}
    ExampleService.Client = {
        TestEvent = NetWire.createEvent()
    }

    function ExampleService.Client:Greeting(plr: Player, msg: string)
        print(plr.Name, "said", msg) 
    end

    ----------------------------------------------------------------

    function ExampleService:RoamInit()
         -- Build the NetWire from the service Client table and replace it
        NetWire.setupServiceNetworking(self)
    end

    function ExampleService:RoamStart()
        task.wait(10)
         -- send a message to all clients
        self.Client.TestEvent:FireAll("Hello from ExampleService!")
    end

    ----------------------------------------------------------------

    Roam.registerService(ExampleService, "ExampleService")
    return ExampleService
    ```

    :::caution Client Table Overwrite
    Calling this function will overwrite the service's `Client` table with the NetWire.
    You should not store anything aside from supported NetWire objects in the Client table.
    :::

    :::info Where to call
    This function should be called within the init method of the service. This is
    to prevent netwires from being created outside of a running game.
    :::
]=]
function ServerNetWireClass.setupServiceNetworking(service: Service)
	assert(RunService:IsServer(), "ServerNetWire.fromService can only be called from the server")
	assert(
		typeof(service.Client) == "table",
		"ServerNetWire.fromService expects a table for the service parameter with a Client key"
	)

	local ServiceName = service.Name
	if not ServiceName then
		local roam = ReplicatedStorage:FindFirstChild("Roam", true)
		if roam then
			local Roam = require(roam)
			ServiceName = Roam.getNameFromService(service)
		end
	end

	assert(
		typeof(ServiceName) == "string",
		"ServerNetWire.fromService expects a string for the service parameter with a Name key"
	)

	if NetWireCache[ServiceName] then
		return NetWireCache[ServiceName]
	end

	local newNetWire = ServerNetWireClass.new(ServiceName)
	setServer(newNetWire, service)
	parseTable(newNetWire, service.Client)

	service.Client = newNetWire

	return newNetWire
end
do
	ServerNetWireClass.fromService = ServerNetWireClass.setupServiceNetworking
end

--// ServerNetWire Instance Methods //--

--[=[
    @tag destructor
    @within ServerNetWire
    @private

    Destroys the NetWire and removes it from the internal cache.
]=]
function ServerNetWire:Destroy()
	NetWireCache[self[NAME_KEY]] = nil
	self[COMM_KEY]:Destroy()
end

--[=[
    @within ServerNetWire
    @param eventName string
    Creates a remote event with the given name.


    Server Documentation: https://sleitnick.github.io/RbxUtil/api/RemoteSignal

    Client Documentation: https://sleitnick.github.io/RbxUtil/api/ClientRemoteSignal

    ```lua
    -- Server Side
    local myWire = NetWire.Server("MyWire")

    myWire.TestEvent = NetWire.createEvent()

    myWire.TestEvent:Connect(function(plr: Player, someArg)
        print(someArg)
    end)

    myWire.TestEvent:FireAll("Hello from the server!")

    ---------------------------------------------------------
    -- Client Side
    local myWire = NetWire.Client("MyWire")

    myWire.TestEvent:Connect(function(someArg)
        print(someArg)
    end)

    myWire.TestEvent:Fire("Hello from the client!")
    ```
]=]
function ServerNetWire:RegisterEvent(
	eventName: string,
	isUnreliable: boolean?,
	inboundMiddleware: { ServerMiddleware }?,
	outboundMiddleware: { ServerMiddleware }?
)
	assert(type(eventName) == "string", "ServerNetWire:RegisterEvent expects a string for the eventName parameter")
	assert(not rawget(self, eventName), "ServerNetWire:RegisterEvent expects the eventName to not already exist")

	rawset(self, eventName, self[COMM_KEY]:CreateSignal(eventName, isUnreliable, inboundMiddleware, outboundMiddleware))
end

--[=[
    @within ServerNetWire
    @param propertyName string
    @param initialValue any?
    Creates a remote property with the given name.

    Server Documentation: https://sleitnick.github.io/RbxUtil/api/RemoteProperty
    
    Client Documentation: https://sleitnick.github.io/RbxUtil/api/ClientRemoteProperty

    ```lua
    -- Server Side
    local myWire = NetWire.Server("MyWire")

    myWire.TestProperty = NetWire.createProperty("Hello")

    ---------------------------------------------------------
    -- Client Side
    local myWire = NetWire.Client("MyWire")

    if myWire.TestProperty:IsReady() then -- Check if its ready first
        print( myWire.TestProperty:Get() ) -- "Hello"
    end
    ```
]=]
function ServerNetWire:RegisterProperty(
	propertyName: string,
	initialValue: any?,
	inboundMiddleware: { ServerMiddleware }?,
	outboundMiddleware: { ServerMiddleware }?
)
	assert(
		type(propertyName) == "string",
		"ServerNetWire:RegisterProperty expects a string for the propertyName parameter"
	)
	assert(
		not rawget(self, propertyName),
		"ServerNetWire:RegisterProperty expects the propertyName to not already exist"
	)

	rawset(
		self,
		propertyName,
		self[COMM_KEY]:CreateProperty(propertyName, initialValue, inboundMiddleware, outboundMiddleware)
	)
end

--[=[
    @within ServerNetWire
    @param functionName string
    @param callback (self: any, plr: Player, ...any) -> (...any)
    @param tbl {}?
    Creates a remote function with the given name. This is not suggested to be used by end users; instead
    you should just append a function to a netwire object and it will properly wrap it for you.
    
    ```lua
    -- Server Side
    local myWire = NetWire.Server("MyWire")

    function myWire:TestMethod(plr: Player, arg: number)
        return arg * 2
    end

    ---------------------------------------------------------
    -- Client Side
    local myWire = NetWire.Client("MyWire")

    myWire:TestMethod(5):andThen(function(result)
        print(result) -- 10
    end)
    ```
]=]
function ServerNetWire:RegisterMethod(
	functionName: string,
	callback: (self: any, plr: Player, ...any) -> ...any,
	tbl: {}?,
	inboundMiddleware: { ServerMiddleware }?,
	outboundMiddleware: { ServerMiddleware }?
)
	assert(
		type(functionName) == "string",
		"ServerNetWire:RegisterFunction expects a string for the functionName parameter"
	)
	assert(type(callback) == "function", "ServerNetWire:RegisterFunction expects a function for the callback parameter")
	assert(
		not rawget(self, functionName),
		"ServerNetWire:RegisterFunction expects the functionName to not already exist"
	)

	local s = tbl or self
	rawset(s, functionName, callback)

	outboundMiddleware = outboundMiddleware or {}
	assert(
		typeof(outboundMiddleware) == "table",
		"ServerNetWire:RegisterFunction expects a table for the outboundMiddleware parameter"
	)
	table.insert(outboundMiddleware, ServerPromiseConversionMiddleware)

	self[COMM_KEY]:WrapMethod(s, functionName, inboundMiddleware, outboundMiddleware)
end

--------------------------------------------------------------------------------
-- MODULE EXPORTS AND METAMETHODS
--------------------------------------------------------------------------------

--// Module Exports //--
ServerNetWireClass.createEvent = Markers.createEvent
ServerNetWireClass.createUnreliableEvent = Markers.createUnreliableEvent
ServerNetWireClass.createProperty = Markers.createProperty

local CallMT = {
	__call = function(_, ...)
		return ServerNetWireClass.new(...)
	end,
	__metatable = ServerNetWireClass, -- Prevents modification of the metatable
}
setmetatable(ServerNetWireClass, CallMT)

-- Export the class with static methods
-- Create a proper Server proxy that inherits the __call metamethod
-- Allows refined linting in places where runcontext is ambiguous
ServerNetWireClass.Server = setmetatable({}, {
	__call = function(_, ...)
		return ServerNetWireClass.new(...)
	end,
	__index = ServerNetWireClass,
	__metatable = ServerNetWireClass, -- Prevents modification of the metatable
})

-- table.freeze(ServerNetWireClass.Server)
-- table.freeze(ServerNetWireClass)

return ServerNetWireClass
