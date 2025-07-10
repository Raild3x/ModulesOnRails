-- Logan Hunt [Raildex]
-- Sep 17, 2023
-- Reorganized for better linting support
--[=[
    @class ClientNetWire
    @client

    Client-side NetWire implementation using Sleitnick's Comm under the hood.
    Provides a clean interface for consuming server-exposed networking APIs.

    **Structure:**
    - `ClientNetWireClass`: Contains static methods (utilities, promises, etc.)
    - `ClientNetWire`: Contains instance methods and constructor
    
    This separation ensures better linting support and prevents static methods from appearing 
    in instance method suggestions.

    **Key Features:**
    - **Promise-based readiness**: Wait for server APIs to become available
    - **Automatic proxy creation**: Seamless access to server methods and events
    - **Type safety**: Full typing support with proper metatable integration
    - **Middleware support**: Promise conversion and other transformations

    :::caution
    Wire indices may not always be ready for use immediately after creating a ClientNetWire.
    This can be the case if the ServerWire is created dynamically. To wait for a ClientNetWire
    to be ready for use, use NetWire.promiseWire. And then to wait for a
    particular index to be ready, use NetWire.promiseIndex.
    :::

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
        .indexReady(wireOrName: ClientNetWire | string, idx: string) -> Promise<...any>
        .onReady(clientNetWire: ClientNetWire | string) -> Promise<ClientNetWire>
        .promiseIndex(wireOrName: ClientNetWire | string, idx: string) -> Promise<...any>
        .promiseWire(clientNetWire: ClientNetWire | string) -> Promise<ClientNetWire>

    [CLIENT NETWIRE CLASS]
        .new(nameSpace: string) -> ClientNetWire
]]

--------------------------------------------------------------------------------
-- IMPORTS
--------------------------------------------------------------------------------

local RunService = game:GetService("RunService")

local RemotesFolder: Folder = script.Parent.Remotes

local Packages = script.Parent.Parent
local Promise = require(Packages.Promise)
local Janitor = require(Packages.Janitor)
local Signal = require(Packages.Signal)
local Comm = require(Packages.Comm).ClientComm
local NetWireTypes = require(script.Parent.NetWireTypes)
local Shared = require(script.Parent.Shared)
local ClientRemoteProxy = require(script.Parent.Utils.ClientRemoteProxy)
local ClientPromiseConversionMiddleware = require(script.Parent.Utils.ClientPromiseConversionMiddleware)

--------------------------------------------------------------------------------
-- CONSTANTS
--------------------------------------------------------------------------------

-- Import shared symbols
local NAME_KEY = Shared.NAME_KEY
local COMM_KEY = Shared.COMM_KEY
local JANI_KEY = Shared.JANI_KEY
local SIG_KEY = Shared.SIG_KEY

local RemoteTypes = {
	Function = "RF",
	Event = "RE",
	Property = "RP",
}

--------------------------------------------------------------------------------
-- TYPE DEFINITIONS
--------------------------------------------------------------------------------

--// Types //--
type Promise<T...> = NetWireTypes.Promise<T...>
type Connection = NetWireTypes.Connection
type ClientRemoteProperty = NetWireTypes.ClientRemoteProperty
type ClientRemoteEvent = NetWireTypes.ClientRemoteEvent

--------------------------------------------------------------------------------
-- MODULE STATE
--------------------------------------------------------------------------------

--// Module State //--
local NetWireCache = {} -- Cache of all Wires
local NewNetWireSignal = Signal.new() -- Signal for when a new wire is created

--------------------------------------------------------------------------------
-- CLIENT NETWIRE CLASS (STATIC METHODS)
--------------------------------------------------------------------------------

local ClientNetWireClass = {}
-- ClientNetWireClass.PromiseConversionMiddleware = ClientPromiseConversionMiddleware

--[=[
	@within ClientNetWire
	@prop ClassName "ClientNetWire"
	@private
	@readonly
]=]
ClientNetWireClass.ClassName = "ClientNetWire"

--// ClientNetWire Instance Methods Class //--

--[=[
    @class ClientNetWire
    @client
    
    Instance methods for ClientNetWire objects.
    These methods are available on created ClientNetWire instances.
]=]
type Remote = (<T...>(self: ClientNetWire, ...any) -> Promise<T...>) & ClientRemoteEvent & ClientRemoteProperty
local ClientNetWireMT = {}
ClientNetWireMT.__index = function(t, k): any
	if not ClientNetWireClass.isReady(t) then
		warn(
			`Attempted to index '{k}' in a ClientNetWire that is not ready or does not exist. Ensure the server side is actually being setup.`
		)
	else
		warn(
			`Index '{k}' is not yet initialized in this ClientNetWire. Use NetWire.promiseIndex to wait for the index.`
		)
	end
	local proxy = ClientRemoteProxy.new()
	rawset(t, k, proxy)
	return proxy
end
ClientNetWireMT.__newindex = function(_, k, v)
	error(`Attempted to set index '{k}' to '{v}' in a ClientNetWire. ClientNetWires are read-only.`)
end



--------------------------------------------------------------------------------
-- CONSTRUCTOR AND INSTANCE CREATION
--------------------------------------------------------------------------------

--[=[
    @within ClientNetWire

    @param nameSpace string
    @return ClientNetWire
    Creates a new ClientNetWire. If a ClientNetWire with the same nameSpace already exists, it will be returned instead.
]=]
function ClientNetWireClass.new(nameSpace: string)
	assert(RunService:IsClient(), "ClientNetWire.new can only be called from the client")
	assert(type(nameSpace) == "string", "ClientNetWire.new expects a string for the nameSpace parameter")

	if NetWireCache[nameSpace] then
		return NetWireCache[nameSpace]
	end

	local self = {}
	self["" :: string] = (nil :: any) :: Remote

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

					local inboundMiddleware = {}
					table.insert(inboundMiddleware, 1, ClientPromiseConversionMiddleware)

					local f = newComm:GetFunction(rf.Name, inboundMiddleware)
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

	setmetatable(self, ClientNetWireMT)

	NetWireCache[nameSpace] = self
	self[JANI_KEY]:Add(function()
		NetWireCache[nameSpace] = nil
	end)

	NewNetWireSignal:Fire(self)

	return self
end


--------------------------------------------------------------------------------
-- STATIC UTILITY METHODS
--------------------------------------------------------------------------------

--[=[
    @within ClientNetWire

    Returns a promise that resolves when the ClientNetWire is ready for use.
]=]
function ClientNetWireClass.onReady(clientNetWire: string | ClientNetWire): Promise<ClientNetWire>
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
		if ClientNetWireClass.isReady(wire) then
			return wire
		end
		return (wire[COMM_KEY] :: Promise<...any>):andThenReturn(wire)
	end)
end
ClientNetWireClass.promiseWire = ClientNetWireClass.onReady

--[=[
	@within ClientNetWire

	@param clientNetWire ClientNetWire | string
	@return boolean
	Can be used to check if a clientNetWire is ready for use.
	Accepts either a ClientNetWire instance or a string name of the wire.
	Returns `true` if the ClientNetWire is ready, `false` otherwise.
]=]
function ClientNetWireClass.isReady(clientNetWire: string | ClientNetWire): boolean
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
    @within ClientNetWire

    @param wireOrName ClientNetWire | string
    @param idx string -- The index to wait for existence of

    Returns a promise that resolves when the ClientNetWire is ready for use and the index exists.
    The resolved value is the value of the index.
]=]
function ClientNetWireClass.indexReady(wireOrName: string | ClientNetWire, idx: string): Promise<...any>
	return ClientNetWireClass.onReady(wireOrName):andThen(function(wire)
		if rawget(wire, idx) then
			return rawget(wire, idx)
		end
		return Promise.fromEvent(wire[SIG_KEY], function(idxName, _rType, _v)
			return idxName == idx
		end):andThen(function(_idxName, _rType, v)
			return v
		end)
	end)
end
ClientNetWireClass.promiseIndex = ClientNetWireClass.indexReady

--[=[
	@within ClientNetWire
	@private

	@param clientNetWire ClientNetWire
	Destroys a ClientNetWire, removing it from the cache.
]=]
function ClientNetWireClass.destroy(clientNetWire: ClientNetWire)
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

--------------------------------------------------------

local CallMT = {
	__call = function(_, ...)
		return ClientNetWireClass.new(...)
	end,
	__metatable = ClientNetWireClass, -- Prevents modification of the metatable
}
setmetatable(ClientNetWireClass, CallMT)

--------------------------------------------------------------------------------
-- MODULE EXPORTS AND METAMETHODS
--------------------------------------------------------------------------------

--[=[
	@within ClientNetWire
	@client
	@private

	@prop Client ClientNetWire
]=]
-- Export the class with static methods
-- Create a proper Client proxy that inherits the __call metamethod
-- Allows refined linting in places where runcontext is ambiguous
ClientNetWireClass.Client = setmetatable({}, {
	__call = function(_, ...)
		return ClientNetWireClass.new(...)
	end,
	__index = ClientNetWireClass,
	__metatable = ClientNetWireClass, -- Prevents modification of the metatable
})

table.freeze(ClientNetWireClass.Client)


table.freeze(ClientNetWireClass)

export type ClientNetWire = typeof(ClientNetWireClass.new(""))

return ClientNetWireClass
