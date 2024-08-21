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
    local TestNetWire1 = NetWire.Server.new("TestNetWire")
    local TestNetWire2 = NetWire.Server("TestNetWire")

    print(TestNetWire1 == TestNetWire2) -- true 
    ```
    :::info
    You can also create a by calling the package directly, but this is not encouraged as it
    obscures the RunContext in which the NetWire is being created.
    ```lua
    local TestNetWire3 = NetWire("TestNetWire")
    ```
    :::

    You can then create client exposed events by registering them with the method or setting their index:
    The following two lines accomplish the same thing.
    ```lua
    TestNetWire:RegisterEvent("TestEvent")
    TestNetWire.TestEvent = NetWire.createEvent()
    ```

    -----------------------------------------------------------------
    [EXAMPLES]
    -----------------------------------------------------------------
    ```lua
    local NetWire = require(game:GetService("ReplicatedStorage").NetWire)

    local myNetWire = NetWire.Server("MyNetWire")

    -- Aliases (These are equivalent. You can use either to create remote events)
    myNetWire.ServerSideEvent = NetWire.createEvent()
    myNetWire:RegisterEvent("ServerSideEvent")


    -- Setup a method
    function myNetWire:ServerSideFunction(player: Player, someArg: number)
        print(someArg)
        return someArg * 2
    end

    -- Connect to an event
    myNetWire.ServerSideEvent:Connect(function(plr: Player, someArg)
        print(someArg)
    end)

    -- Fire an event
    myNetWire.ServerSideEvent:FireAll(someArg)
    ```
    -----------------------------------------------------------------
    Example using a service
    ```lua
    local ExampleService = Roam.createService { Name = "ExampleService" }
    ExampleService.Client = {
        TestEvent = NetWire.createEvent()
    }

    -- Make a server exposed method MultNumber
    function ExampleService.Client:MultNumber(plr: Player, num: number): number
        return num * self.Server:GetMult() -- self.Server is internally set by NetWire when you do .fromService
    end

    --------------------------------------------------------------------------------

    function ExampleService:GetMult(): number
        return 2
    end

    function ExampleService:RoamStart()
        self.Client.TestEvent:FireAll("Hello from ExampleService!") -- send a message to all clients
    end

    function ExampleService:RoamInit()
        self.Client = NetWire.Server.fromService(self) -- Initialize the NetWire
    end
    ```
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
]]

local RunService = game:GetService("RunService")

local RemotesFolder: Folder = script.Parent:FindFirstChild("Remotes")

local Comm = require(script.Parent.Comm).ServerComm
local Symbol = require(script.Parent.Parent.Symbol)

--// Constants //--
local NAME_KEY = Symbol("NAME")
local COMM_KEY = Symbol("COMM")
local SIGNAL_MARKER = Symbol("SIGNAL_MARKER")
local PROPERTY_MARKER = Symbol("PROPERTY_MARKER")

--// Types //--
type SignalMarker = typeof(SIGNAL_MARKER)
type PropertyMarker = typeof(PROPERTY_MARKER)
type Marker = SignalMarker | PropertyMarker
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

type ServerRemoteEvent = {
    Connect: (self: ServerRemoteEvent, callback: (self: ServerRemoteEvent, plr: Player, ...any) -> ()) -> Connection;
    Fire: (self: ServerRemoteEvent, plr: Player, ...any) -> ();
    FireFor: (self: ServerRemoteEvent, plrs: {Player}, ...any) -> ();
    FireAll: (self: ServerRemoteEvent, ...any) -> ();
    FireExcept: (self: ServerRemoteEvent, plr: Player, ...any) -> ();
    FireFilter: (self: ServerRemoteEvent, predicate: (plr: Player, ...any) -> boolean, ...any) -> ();
}

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

    ```lua
    local ExampleService = Roam.createService { Name = "ExampleService" }
    ExampleService.Client = {
        TestEvent = NetWire.createEvent()
    }

    function ExampleService:RoamInit()
        NetWire.Server.setupServiceNetworking(self)
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
        error("Missing Service Name")
        -- local Roam = Import("Roam")
        -- ServiceName = Roam.getNameFromService(service)
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
    elseif v == SIGNAL_MARKER then
        self:RegisterEvent(k)
    elseif type(v) == "table" and v[1] == PROPERTY_MARKER then
        self:RegisterProperty(k, v[2])
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
function ServerNetWire:RegisterEvent(eventName: string)
    assert(type(eventName) == "string", "ServerNetWire:RegisterEvent expects a string for the eventName parameter")
    assert(not rawget(self, eventName), "ServerNetWire:RegisterEvent expects the eventName to not already exist")

    rawset(self, eventName, self[COMM_KEY]:CreateSignal(eventName))
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
function ServerNetWire:RegisterProperty(propertyName: string, initialValue: any?)
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
function ServerNetWire:RegisterMethod(functionName: string, callback: (self: any, plr: Player, ...any) -> (...any), tbl: {}?)
    assert(type(functionName) == "string", "ServerNetWire:RegisterFunction expects a string for the functionName parameter")
    assert(type(callback) == "function", "ServerNetWire:RegisterFunction expects a function for the callback parameter")
    assert(not rawget(self, functionName), "ServerNetWire:RegisterFunction expects the functionName to not already exist")

    local s = tbl or self
    rawset(s, functionName, callback)
    self[COMM_KEY]:WrapMethod(s, functionName)
end

--------------------------------------------------------

NetWire.Server = ServerNetWire
NetWire.setupServiceNetworking = ServerNetWire.setupServiceNetworking
NetWire.__call = function(_, ...)
    return ServerNetWire.new(...)
end
setmetatable(ServerNetWire, NetWire)

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
]=]
function NetWire.createEvent(): ServerRemoteEvent
    return SIGNAL_MARKER :: ServerRemoteEvent -- override the type for linting purposes
end
-- Aliases
NetWire.newEvent = NetWire.createEvent
NetWire.createSignal = NetWire.createEvent
NetWire.newSignal = NetWire.createEvent

--[=[
    @within NetWire
    @server

    Returns an PropertyMarker that is used to mark where a remoteProperty should be created.
    Calls ServerNetWire:RegisterProperty() when set to the index of a ServerNetWire.
    See ServerNetWire:RegisterProperty for more information.
]=]
function NetWire.createProperty(initialValue: any?): ServerRemoteProperty
    return { PROPERTY_MARKER, initialValue } :: ServerRemoteProperty -- override the type for linting purposes
end

--[=[
    @within NetWire
    @server

    @param wireName string
    @return ServerNetWire?
    Returns a ServerNetWire from the cache, if it exists.
]=]
function NetWire.getServer(wireName: string): ServerNetWire?
    return NetWireCache[wireName]
end



return NetWire
