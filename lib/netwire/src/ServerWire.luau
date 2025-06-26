-- Logan Hunt [Raildex]
-- Sep 15, 2023
--[=[
    @class ServerNetWire
    @server

    Uses Sleitnick's Comm under the hood. Provides a simple to use interface for networking across
    your codebase. This is a server side only module. To begin using it, you must first create a
    ServerNetWire object. This can be done by calling NetWire.Server, or by calling NetWire.Server.new

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

    You can then create client exposed events by registering them with the method or setting their index:
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
        :SetServer(tbl: {[any]: any})
        :RegisterEvent(eventName: string)
        :RegisterProperty(propertyName: string, initialValue: any?)
        :RegisterMethod(functionName: string, callback: (self: any, plr: Player, ...any) -> (...any), tbl: {}?)
        :Destroy()

    -----------------------------------------------------------------
    More Examples
    -----------------------------------------------------------------
    ```lua
    local NetWire = require(ReplicatedStorage.NetWire)

    local myNetWire = NetWire.Server("MyNetWire")

    -----------------------------------------------------------------------------
    -- Setup a method
    function myNetWire:ServerSideFunction(player: Player, someArg: number)
        print(someArg)
        return someArg * 2
    end

    -----------------------------------------------------------------------------
    -- Aliases (These are equivalent. You can use either to create remote events)
    myNetWire.ServerSideEvent = NetWire.createEvent()
    myNetWire:RegisterEvent("ServerSideEvent")

    -- Connect to an event
    myNetWire.ServerSideEvent:Connect(function(plr: Player, someArg)
        print(someArg)
    end)

    -- Fire an event
    myNetWire.ServerSideEvent:FireAll(someArg)

    -----------------------------------------------------------------------------
    -- Properties
    myNetWire.ServeSideProperty = NetWire.createProperty(0)
    ```
]]

local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local RemotesFolder: Folder = script.Parent:FindFirstChild("Remotes")

local Packages = script.Parent.Parent
local Comm = require(Packages.Comm).ServerComm
local Symbol = require(Packages.Symbol)
local ServerPromiseConversionMiddleware = require(script.Parent.ServerPromiseConversionMiddleware)

--// Constants //--
local NAME_KEY = Symbol("NAME")
local COMM_KEY = Symbol("COMM")
local SIGNAL_MARKER = Symbol("SIGNAL_MARKER")
local UNRELIABLE_SIGNAL_MARKER = Symbol("UNRELIABLE_SIGNAL_MARKER")
local PROPERTY_MARKER = Symbol("PROPERTY_MARKER")

--// Types //--
type SignalMarker = typeof(SIGNAL_MARKER)
type UnreliableSignalMarker = typeof(UNRELIABLE_SIGNAL_MARKER)
type PropertyMarker = typeof(PROPERTY_MARKER)
type Marker = SignalMarker | PropertyMarker | UnreliableSignalMarker
type ParsableValue = Marker | (self: ServerNetWire, ...any) -> (...any)

type table = {[any]: any}
type ServerNetWire = table

type Service = {
    Name: string;
    Client: {[string]: ParsableValue};
    [any]: any;
}

type Connection = {
    Disconnect: () -> ();
    Connected: boolean;
}

--[=[
    @within ServerNetWire
    @type ServerRemoteEvent RemoteSignal
    https://sleitnick.github.io/RbxUtil/api/RemoteSignal
]=]
type ServerRemoteEvent = {
    Connect: (self: ServerRemoteEvent, callback: (self: ServerRemoteEvent, plr: Player, ...any) -> ()) -> Connection;
    Fire: (self: ServerRemoteEvent, plr: Player, ...any) -> ();
    FireFor: (self: ServerRemoteEvent, plrs: {Player}, ...any) -> ();
    FireAll: (self: ServerRemoteEvent, ...any) -> ();
    FireExcept: (self: ServerRemoteEvent, plr: Player, ...any) -> ();
    FireFilter: (self: ServerRemoteEvent, predicate: (plr: Player, ...any) -> boolean, ...any) -> ();
    IsUnreliable: (self: ServerRemoteEvent) -> boolean;
}

--[=[
    @within ServerNetWire
    @type ServerRemoteProperty RemoteProperty
    https://sleitnick.github.io/RbxUtil/api/RemoteProperty
]=]
type ServerRemoteProperty = {
    Set: (self: ServerRemoteProperty, value: any) -> ();
    SetTop: (self: ServerRemoteProperty, value: any) -> ();
    SetFor: (self: ServerRemoteProperty, plr: Player, value: any) -> ();
    SetForList: (self: ServerRemoteProperty, plrs: {Player}, value: any) -> ();
    SetFilter: (self: ServerRemoteProperty, predicate: (plr: Player, value: any) -> boolean, value: any) -> ();
    ClearFor: (self: ServerRemoteProperty, plr: Player) -> ();
    ClearForList: (self: ServerRemoteProperty, plrs: {Player}) -> ();
    ClearFilter: (self: ServerRemoteProperty, predicate: (plr: Player) -> boolean) -> ();
    Get: (self: ServerRemoteProperty) -> any;
    GetFor: (self: ServerRemoteProperty, plr: Player) -> any;
}

--[=[
    @within ServerNetWire
    @type ServerMiddleware (player: Player, args: {any}) -> (shouldContinue: boolean, ...any)
]=]
type ServerMiddleware = (player: Player, args: {any}) -> (boolean, ...any)

--// Volatiles //--
local NetWireCache = {} -- Cache of all Wires
local NetWire = {} -- Class Declaration

--------------------------------------------------------

local ServerNetWire = {}
ServerNetWire.ClassName = "ServerNetWire";
ServerNetWire.__index = ServerNetWire;
ServerNetWire.__newindex = function(self, k: string, v: any)
    local registrationSuccess = self:AutoRegister(k, v)
    if not registrationSuccess then
        warn("Attempted to set unexpected Value in ServerNetWire table:",v,"at key:",k)
        rawset(self, k, v)
    end
end;

--[=[
    @within ServerNetWire
    @prop ClassName "ServerNetWire"
    @readonly
]=]


--[=[
    @tag constructor
    @tag static
    @within ServerNetWire

    Constructs a new ServerNetWire. If a ServerNetWire with the same nameSpace already exists, it will be returned instead.
]=]
function ServerNetWire.new(nameSpace: string | Service)
    if typeof(nameSpace) == "table" then
        return ServerNetWire.fromService(nameSpace)
    end
    assert(RunService:IsServer(), "ServerNetWire.new can only be called from the server")
    assert(type(nameSpace) == "string", "ServerNetWire.new expects a string for the nameSpace parameter")

    if NetWireCache[nameSpace] then
        return NetWireCache[nameSpace]
    end

    local self = {}
    self[NAME_KEY] = nameSpace
    self[COMM_KEY] = Comm.new(RemotesFolder, nameSpace)
    setmetatable(self, ServerNetWire)

    NetWireCache[nameSpace] = self

    return self
end

--[=[
    @tag constructor
    @tag static

    @param service Service
    @return ServerNetWire

    Creates a ServerNetWire from a Roam Service.
    This method will read the service's Name and Client table to create the NetWire.
    The goal of this function is to recreate the simplicity of Knit's networking features without
    the systems being coupled together. 
    In order to access the service on the client, use `NetWire.Client("SERVICE_NAME")`.

    ```lua
    local ExampleService = Roam.createService { Name = "ExampleService" }
    ExampleService.Client = {
        TestEvent = NetWire.createEvent()
    }

    function ExampleService.Client:Greeting(plr: Player, msg: string)
        print(plr.Name, "said", msg) 
    end

    ----------------------------------------------------------------

    function ExampleService:RoamInit()
        NetWire.Server.setupServiceNetworking(self)
    end

    function ExampleService:RoamStart()
        self.Client.TestEvent:FireAll("Hello from ExampleService!") -- send a message to all clients
    end
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
function ServerNetWire.setupServiceNetworking(service: Service)
    assert(RunService:IsServer(), "ServerNetWire.fromService can only be called from the server")
    assert(typeof(service.Client) == "table", "ServerNetWire.fromService expects a table for the service parameter with a Client key")

    local ServiceName = service.Name
    if not ServiceName then
        local roam = ReplicatedStorage:FindFirstChild("Roam", true) 
        if roam then
            local Roam = require(roam)
            ServiceName = Roam.getNameFromService(service)
        end
    end

    assert(typeof(ServiceName) == "string", "ServerNetWire.fromService expects a string for the service parameter with a Name key")

    if NetWireCache[ServiceName] then
        return NetWireCache[ServiceName]
    end

    local newNetWire = ServerNetWire.new(ServiceName)
    newNetWire:SetServer(service)
    newNetWire:Parse(service.Client)

    service.Client = newNetWire :: ServerNetWire

    return newNetWire
end
ServerNetWire.fromService = ServerNetWire.setupServiceNetworking

--[=[
    @tag destructor

    Destroys the NetWire and removes it from the internal cache.
]=]
function ServerNetWire:Destroy()
    NetWireCache[self[NAME_KEY]] = nil
    self[COMM_KEY]:Destroy()
end

--[=[
    @private

    Reads through a table and adds all the methods, events, and properties to the NetWire.
]=]
function ServerNetWire:Parse(tbl: {[string]: ParsableValue})
    for k, v in pairs(tbl) do
        local registrationSuccess = self:AutoRegister(k, v)
        if not registrationSuccess then
            warn("Unsupported Value in table:",v,"at key:",k,"\n",debug.traceback())
        end
    end
end

--[=[
    @private

    Attempts to register a value to the NetWire. It will infer the type of value and call the corresponding method.
]=]
function ServerNetWire:AutoRegister(k: string, v: ParsableValue): boolean
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

--[=[
    @private

    Sets the Server index of the NetWire. Used with RemoteMethods and Services.
]=]
function ServerNetWire:SetServer(tbl: {[any]: any})
    rawset(self, "Server", tbl)
end

--[=[
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
function ServerNetWire:RegisterEvent(eventName: string, isUnreliable: boolean?, inboundMiddleware: {ServerMiddleware}?, outboundMiddleware: {ServerMiddleware}?)
    assert(type(eventName) == "string", "ServerNetWire:RegisterEvent expects a string for the eventName parameter")
    assert(not rawget(self, eventName), "ServerNetWire:RegisterEvent expects the eventName to not already exist")

    rawset(self, eventName, self[COMM_KEY]:CreateSignal(eventName, isUnreliable, inboundMiddleware, outboundMiddleware))
end

--[=[
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
function ServerNetWire:RegisterProperty(propertyName: string, initialValue: any?, inboundMiddleware: {ServerMiddleware}?, outboundMiddleware: {ServerMiddleware}?)
    assert(type(propertyName) == "string", "ServerNetWire:RegisterProperty expects a string for the propertyName parameter")
    assert(not rawget(self, propertyName), "ServerNetWire:RegisterProperty expects the propertyName to not already exist")

    rawset(self, propertyName, self[COMM_KEY]:CreateProperty(propertyName, initialValue))
end

--[=[
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
function ServerNetWire:RegisterMethod(functionName: string, callback: (self: any, plr: Player, ...any) -> (...any), tbl: {}?, inboundMiddleware: {ServerMiddleware}?, outboundMiddleware: {ServerMiddleware}?)
    assert(type(functionName) == "string", "ServerNetWire:RegisterFunction expects a string for the functionName parameter")
    assert(type(callback) == "function", "ServerNetWire:RegisterFunction expects a function for the callback parameter")
    assert(not rawget(self, functionName), "ServerNetWire:RegisterFunction expects the functionName to not already exist")

    local s = tbl or self
    rawset(s, functionName, callback)

    outboundMiddleware = outboundMiddleware or {}
    assert(typeof(outboundMiddleware) == "table", "ServerNetWire:RegisterFunction expects a table for the outboundMiddleware parameter")
    table.insert(outboundMiddleware, ServerPromiseConversionMiddleware)

    self[COMM_KEY]:WrapMethod(s, functionName, inboundMiddleware, outboundMiddleware)
end

--------------------------------------------------------

NetWire.Server = ServerNetWire
NetWire.PromiseConversionMiddleware = ServerPromiseConversionMiddleware
NetWire.setupServiceNetworking = ServerNetWire.setupServiceNetworking
NetWire.__call = function(_, ...)
    return ServerNetWire.new(...)
end
setmetatable(ServerNetWire, NetWire)

local MARKER_MT = {
    __index = function(self, k: string)
        error("Attempted to access an uninitialized NetWire object with key: " .. tostring(k) ..". | Ensure you have initialized the NetWire object prior to accessing this.")
    end
}

--[=[
    @within NetWire
    @server

    @prop Server ServerNetWire
]=]


--[=[
    @within NetWire
    @server

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
function NetWire.createEvent(inboundMiddleware: {ServerMiddleware}?, outboundMiddleware: {ServerMiddleware}?): ServerRemoteEvent
    return setmetatable({ SIGNAL_MARKER, inboundMiddleware, outboundMiddleware }, MARKER_MT) :: any
end
-- Aliases
-- NetWire.newEvent = NetWire.createEvent
-- NetWire.createSignal = NetWire.createEvent
-- NetWire.newSignal = NetWire.createEvent

--[=[
    @within NetWire
    @server

    Returns an EventMarker that is used to mark where a remoteSignal should be created.
    Calls ServerNetWire:RegisterEvent() when set to the index of a ServerNetWire.
    See ServerNetWire:RegisterEvent for more information.

    ```lua
    local MyWire = NetWire.Server("MyWire")
    MyWire.MyEvent = NetWire.createUnreliableEvent()

    MyWire.MyEvent:FireAll("Hello, world!")
    ```
]=]
function NetWire.createUnreliableEvent(inboundMiddleware: {ServerMiddleware}?, outboundMiddleware: {ServerMiddleware}?): ServerRemoteEvent
    return setmetatable({ UNRELIABLE_SIGNAL_MARKER, inboundMiddleware, outboundMiddleware }, MARKER_MT) :: any
end

--[=[
    @within NetWire
    @server

    Returns an PropertyMarker that is used to mark where a remoteProperty should be created.
    Calls ServerNetWire:RegisterProperty() when set to the index of a ServerNetWire.
    See ServerNetWire:RegisterProperty for more information.

    ```lua
    local MyWire = NetWire.Server("MyWire")

    MyWire.MyProperty = NetWire.createProperty(0)

    print(MyWire.MyProperty:Get()) -- 0
    ```
]=]
function NetWire.createProperty(initialValue: any?, inboundMiddleware: {ServerMiddleware}?, outboundMiddleware: {ServerMiddleware}?): ServerRemoteProperty
    return setmetatable({ PROPERTY_MARKER, initialValue, inboundMiddleware, outboundMiddleware }, MARKER_MT) :: any
end

--[=[
    @within NetWire
    @server
    @private

    @param wireName string
    @return ServerNetWire?
    Returns a ServerNetWire from the cache, if it exists.
]=]
function NetWire.getServer(wireName: string): ServerNetWire?
    return NetWireCache[wireName]
end



return NetWire
