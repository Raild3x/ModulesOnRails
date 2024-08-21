-- Logan Hunt [Raildex]
-- Sep 17, 2023
--[=[
    @class ClientNetWire
    @client

    Uses Sleitnick's Comm under the hood.

    :: caution ::
    Wire indices may not always be ready for use immediately after creating a ClientNetWire.
    This can be the case if the ServerWire is created dynamically. To wait for a ClientNetWire
    to be ready for use, use NetWire.promiseWire. And then to wait for a
    particular index to be ready, use NetWire.promiseIndex.

    ```lua
    local NetWire = require(game:GetService("ReplicatedStorage").NetWire)

    local myNetWire = NetWire.Client("MyNetWire")

    myNetWire:ServerSideFunction(someArg)

    myNetWire.ServerSideEvent:Connect(function(someArg)
        print(someArg)
    end)

    myNetWire.ServerSideEvent:Fire(someArg)
    ```
]=]

--[[
    [API]
      [NETWIRE CLASS]
        .Client -> ClientNetWire
        .getClient(wireName: string) -> ClientNetWire?
        .destroy(clientNetWire: ClientNetWire)
        .isReady(wireOrName: ClientNetWire | string) -> boolean
        .promiseIndex(wireOrName: ClientNetWire | string, idx: string) -> Promise<any>
        .promiseReady(clientNetWire: ClientNetWire | string) -> Promise<ClientNetWire>

    [CLIENT NETWIRE CLASS]
        .new(nameSpace: string) -> ClientNetWire
]]

local RunService = game:GetService("RunService")

local RemotesFolder: Folder = script.Parent.Remotes

local Packages = script.Parent.Parent
local Promise = require(Packages.Promise)
local Janitor = require(Packages.Janitor)
local Signal = require(Packages.Signal)
local Symbol = require(Packages.Symbol)
local Comm = require(script.Parent.Comm).ClientComm
local ClientRemoteProxy = require(script.Parent.ClientRemoteProxy)

--// Constants //--
local NAME_KEY = Symbol("NAME")
local COMM_KEY = Symbol("COMM")
local JANI_KEY = Symbol("JANITOR")
local SIG_KEY = Symbol("NEW_IDX_SIG")

local RemoteTypes = {
    Function = "RF";
    Event = "RE";
    Property = "RP";
}

--// Types //--
type Promise = typeof(Promise.new())
type Connection = {Disconnect: (...any) -> ()}
type ClientNetWire = {}

--// Volatiles //--
local NetWireCache = {} -- Cache of all Wires
local NewNetWireSignal = Signal.new() -- Signal for when a new wire is created

--------------------------------------------------------------------------------
--// NetWire //--
--------------------------------------------------------------------------------

--[=[
    @class NetWire
]=]
local NetWire = {}

--[=[
    @within NetWire
    @client

    @prop Client ClientNetWire
]=]

--[=[
    @within NetWire
    @client

    @param wireOrName ClientNetWire | string
    @param idx string -- The index to wait for existence of
    @return Promise
    Returns a promise that resolves when the ClientNetWire is ready for use and the index exists.
    The resolved value is the value of the index.
]=]
function NetWire.indexReady(wireOrName: string | ClientNetWire, idx: string): Promise
    return NetWire.onReady(wireOrName):andThen(function(wire)
        if rawget(wire, idx) then
            return rawget(wire, idx)
        end
        return Promise.fromEvent(wire[SIG_KEY], function(idxName, rType, v)
            return idxName == idx
        end):andThen(function(idxName, rType, v)
            return v
        end)
    end)
end
NetWire.promiseIndex = NetWire.indexReady

--[=[
    @within NetWire
    @client

    @param clientNetWire ClientNetWire | string
    @return Promise
    Returns a promise that resolves when the ClientNetWire is ready for use.
]=]
function NetWire.onReady(clientNetWire: string | ClientNetWire): Promise
    return Promise.new(function(resolve)
        if typeof(clientNetWire) == "string" then
            clientNetWire = NetWireCache[clientNetWire]
        end
        if not clientNetWire then
            resolve(Promise.fromEvent(NewNetWireSignal, function(wire)
                return wire[NAME_KEY] == clientNetWire
            end))
        end
        resolve(clientNetWire)
    end):andThen(function(wire)
        if NetWire.isReady(wire) then
            return wire
        end
        return (wire[COMM_KEY] :: Promise):andThenReturn(wire)
    end)
end
NetWire.promiseWire = NetWire.onReady

--[=[
    @within NetWire
    @client

    @param clientNetWire ClientNetWire | string
    @return boolean
    Can be used to check if a clientNetWire is ready for use.
]=]
function NetWire.isReady(clientNetWire: string | ClientNetWire): boolean
    if typeof(clientNetWire) == "string" then
        clientNetWire = NetWireCache[clientNetWire]
        if not clientNetWire then -- If NetWire is not cached, it is not ready
            return false
        end
    end
    assert(typeof(clientNetWire) == "table", "ClientNetWire must be a table")
    return not Promise.is(clientNetWire[COMM_KEY])
end

--[=[
    @within NetWire
    @client

    @param clientNetWire ClientNetWire
    Destroys a ClientNetWire, removing it from the cache.
]=]
function NetWire.destroy(clientNetWire: ClientNetWire)
    if not NetWireCache[clientNetWire[NAME_KEY]] then
        warn("Attempted to destroy an uncached ClientNetWire")
        return
    end
    NetWireCache[clientNetWire[NAME_KEY]] = nil
    clientNetWire[JANI_KEY]:Destroy()
    clientNetWire[JANI_KEY] = nil
    clientNetWire[COMM_KEY] = nil
    warn("Clearing NetWire cache for " .. clientNetWire[NAME_KEY] :: string)
end

--[=[
    @within NetWire
    @client

    @param wireName string
    @return ClientNetWire?
    Returns a ClientNetWire from the cache, if it exists.
]=]
function NetWire.getClient(wireName: string): ClientNetWire?
    return NetWireCache[wireName]
end

--------------------------------------------------------------------------------
--// ClientNetWire //--
--------------------------------------------------------------------------------

local ClientNetWire = {}
ClientNetWire.ClassName = "ClientNetWire";
ClientNetWire.__index = function(t, k)
    if not NetWire.isReady(t) then
        warn(`Attempted to index '{k}' in a ClientNetWire that is not ready. Use NetWire.promiseWire to wait for the ClientNetWire to be ready. Also ensure the server side is actually being setup.`)
    else
        warn(`Index '{k}' is not yet initialized in this ClientNetWire. Use NetWire.promiseIndex to wait for the index.`)
    end
    local proxy = ClientRemoteProxy.new()
    rawset(t, k, proxy)
    return proxy
end;
ClientNetWire.__newindex = function(_, k, v)
    error(`Attempted to set index '{k}' to '{v}' in a ClientNetWire. ClientNetWires are read-only.`)
end;

--[=[
    @within ClientNetWire
    @prop ClassName "ClientNetWire"
    @readonly
]=]

--[=[
    @tag constructor
    @tag static
    @within ClientNetWire

    @param nameSpace string
    @return ClientNetWire
    Creates a new ClientNetWire. If a ClientNetWire with the same nameSpace already exists, it will be returned instead.
]=]
function ClientNetWire.new(nameSpace: string)
    assert(RunService:IsClient(), "ClientNetWire.new can only be called from the client")
    assert(type(nameSpace) == "string", "ClientNetWire.new expects a string for the nameSpace parameter")

    if NetWireCache[nameSpace] then
        return NetWireCache[nameSpace]
    end

    local self = {}
    self[NAME_KEY] = nameSpace
    self[JANI_KEY] = Janitor.new()
    self[SIG_KEY] = Signal.new()

    self[COMM_KEY] = self[JANI_KEY]:AddPromise(Promise.new(function(resolve, reject)
        if not RunService:IsRunning() then
            reject("ClientNetWire.new can only be called from a running server")
        end

        local newComm = Comm.new(RemotesFolder, true, nameSpace)
        local folder = newComm._instancesFolder

        self[JANI_KEY]:Add(newComm)
        self[JANI_KEY]:LinkToInstance(folder)

        local function SetIndex(name, type, v)
            if ClientRemoteProxy.is(rawget(self, name)) then
                rawget(self, name):_SetRemote(v, type)
            end
            rawset(self, name, v)
            self[SIG_KEY]:Fire(name, type, v)
        end

        local function LoadFolder(_folder: Folder?)
            if not _folder then
                return
            end

            local fn
            if _folder.Name == "RF" then
                fn = function(rf)
                    if not rf:IsA("RemoteFunction") then
                        return
                    end
                    local f = newComm:GetFunction(rf.Name)
                    local v = function(_self, ...)
                        return f(...)
                    end
                    SetIndex(rf.Name, RemoteTypes.Function, v)
                end
            elseif _folder.Name == "RE" then
                fn = function(re)
                    if not re:IsA("RemoteEvent") then
                        return
                    end
                    local v = newComm:GetSignal(re.Name)
                    SetIndex(re.Name, RemoteTypes.Event, v)
                end
            elseif _folder.Name == "RP" then
                fn = function(rp)
                    if not rp:IsA("RemoteEvent") then
                        return
                    end
                    local v = newComm:GetProperty(rp.Name)
                    SetIndex(rp.Name, RemoteTypes.Property, v)
                end
            end

            for _, r in ipairs(_folder:GetChildren()) do
                fn(r)
            end
            _folder.ChildAdded:Connect(fn)
        end

        self[JANI_KEY]:Add(folder.ChildAdded:Connect(LoadFolder))
        LoadFolder(folder:FindFirstChild("RF"))
        LoadFolder(folder:FindFirstChild("RE"))
        LoadFolder(folder:FindFirstChild("RP"))

        self[COMM_KEY] = newComm
        resolve(newComm)
    end))

    setmetatable(self, ClientNetWire)

    NetWireCache[nameSpace] = self
    self[JANI_KEY]:Add(function()
        NetWireCache[nameSpace] = nil
    end)

    NewNetWireSignal:Fire(self)

    return self
end

--------------------------------------------------------

NetWire.Client = ClientNetWire
NetWire.__call = function(_, ...)
    return ClientNetWire.new(...)
end
ClientNetWire = setmetatable(ClientNetWire, NetWire)


return NetWire