-- Logan Hunt [Raildex]
-- Sep 15, 2023
-- Reorganized for optimal linting and developer experience
--[=[
    @class NetWire

    NetWire is a networking library that enables functionality similar to Sleitnick's [Comm](https://sleitnick.github.io/RbxUtil/api/Comm/) library,
    except it doesn't require the usage of intermediate instances. It provides a simple, no hassle, API for setting up
    client-server communication.
    
    ----
    ### Remote Event Example:
    A simple example of how to set up a NetWire instance and use it to send a message from a client to the server.
    ```lua
    -- On the server:
    -- 1) Require your NetWire module and access the desired run context.
    local NetWire = require(Packages.NetWire).Server -- or .Client if in a LocalScript

    -- 2) Create a new NetWire instance with a unique namespace by calling the Package.
    local myWire = NetWire("MyWire")

    -- 3) Define events and/or properties on the wire instance.
    --    Here we will define some new event named `MyEvent`.
    myWire.MyEvent = NetWire.createEvent()
    
    -- 4) We will then connect to it and start listening.
    myWire.MyEvent:Connect(function(player: Player, data: any)
        print(player, "sent data:", data)
    end)
    ```

    5) On the opposite run context, we will access the NetWire via the same name and fire the event.
    ```lua
    -- On the client:
    local NetWire = require(Packages.NetWire).Client
    local myWire = NetWire("MyWire")
    myWire.MyEvent:Fire("Hello from the client!")
    ```

    ----
    ### Remote Function Example:
    **(Client -> Server -> Client)**
    ```lua
    -- On the server:
    local NetWire = require(Packages.NetWire).Server
    local myWire = NetWire("MyWire")

    function myWire:MyFunction(player: Player, arg1: any, arg2: any)
        print(player, "called MyFunction with args:", arg1, arg2)
        return "Hello from the server!"
    end
    ```
    ```lua
    -- On the client:
    local NetWire = require(Packages.NetWire).Client
    local myWire = NetWire("MyWire")

    local response = myWire:MyFunction("Hello", 42)
    -- ! Remote functions return as promises !
    response:andThen(function(result)
        print("Received response:", result)
    end)
    ```
    :::info
    Remote functions are not available for (Server -> Client -> Server) communication.
    :::
]=]

--------------------------------------------------------------------------------
-- IMPORTS
--------------------------------------------------------------------------------

local RunService = game:GetService("RunService")

local ServerWireClass = require(script.ServerWire)
local ClientWireClass = require(script.ClientWire)

--------------------------------------------------------------------------------
-- TYPE DEFINITIONS
--------------------------------------------------------------------------------

export type ServerNetWire = typeof(ServerWireClass.new(""))
export type ClientNetWire = typeof(ClientWireClass.new(""))

--------------------------------------------------------------------------------
-- MAIN NETWIRE INTERFACE
--------------------------------------------------------------------------------

-- Create a unified NetWire that dynamically resolves to the correct class
local NetWire = {
	Server = ServerWireClass,
	Client = ClientWireClass,
}

--[=[
    @within NetWire
    @server
    @prop Server ServerNetWire
    Access point for server-side NetWire functionality.
    Can also be called as a function to create/access a new server wire instance.
    ```lua
    local myWire = NetWire.Server("MyWire")
    local myWireOther = NetWire.Server.new("MyWire")
    print(myWire == myWireOther) -- true
    ```
    :::info
    NetWire memoizes the created wire instance so any subsequent calls with the same name will return the same wire instance.
    :::
]=]

--[=[
    @within NetWire
    @client
    @prop Client ClientNetWire
    Access point for client-side NetWire functionality.
    Can also be called as a function to create/access a new client wire instance.
    ```lua
    local myWire = NetWire.Client("MyWire")
    local myWireOther = NetWire.Client.new("MyWire")
    print(myWire == myWireOther) -- true
    ```
]=]

--------------------------------------------------------------------------------
-- DYNAMIC RESOLUTION METAMETHODS
--------------------------------------------------------------------------------

-- Set up proper metamethods for dynamic resolution and backward compatibility
local NetWireMT = {
	__call = function(_, ...)
		if RunService:IsServer() then
			return ServerWireClass(...)
		else
			return ClientWireClass(...)
		end
	end,
	__index = function(_, key)
		if RunService:IsServer() then
			return ServerWireClass[key]
		else
			return ClientWireClass[key]
		end
	end,
	__metatable = "Dont look at me!", -- Prevent further metamethod changes
}

setmetatable(NetWire, NetWireMT)

return NetWire
