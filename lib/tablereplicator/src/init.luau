-- Authors: Logan Hunt (Raildex)
-- January 05, 2024

--[=[
    @class TableReplicator

    TableReplicator is a library that enables the easy replication of tables between the server and client.
    It takes a TableManager on the server and creates a syncronized copy on specified clients. This system
    was based off of Loleris's Replica system.

    BASIC USAGE
    ----

    ----
    **[SERVER]**

    You must first create a `TableManager` object on the server containing the data table you want to replicate.
    ```lua
    local TableManager = require(Packages.TableManager)

    local myManager = TableManager.new({
        Age = 18,
    })
    ```
    
    Then we create a new TableReplicator to handle the replication of our TableManager. In order to do so we must first
    require the module and get the `.Server` index of it since we are accessing the Server side.
    ```lua
    local TableReplicator = require(Packages.TableReplicator).Server
    ```
    Next we need a `Token` in order to identify our Replicator on the Client so we use `TableReplicator.Token` to 
    construct a unique token. Tokens are unique and can only be created once per string. This is to prevent collisions.
    ```lua
    local dataToken = TableReplicator.Token("PlayerData")
    ```

    Finally we can construct our replicator; passing in the token, the table manager, and setting our ReplicationTargets to
    `All`.
    ```lua
    local replicator = TableReplicator.new({
        Token = dataToken,
        TableManager = manager,
        ReplicationTargets = "All",
    })
    ```
    The `ReplicationTargets` are the Player or Players who the Replicator will replicate to. Setting it to `All` tells
    the Replicator to replicate to all current and future players. Once the replicator has been constructed it will begin
    trying to replicate to the appropriate clients.
    
    ----
    **[CLIENT]**
    
    In order to set up the Client we have to get access to the Client side of the package similarly to how we did on the Server.
    ```lua
    local TableReplicator = require(Packages.TableReplicator).Client
    ```
    
    There are many ways to get the replicators on the Client, but the easiest way is with the `forEach` function. This
    will take a Token name and run a function for all existing and future replicators with that Token name. 
    ```lua
    TableReplicator.forEach("PlayerData", function(replicator)
        local manager = replicator:GetTableManager()

        manager:Observe("Age", function(age)
            print("Age is:", age)
        end)
    end)
    ```
    Inside of the function we can fetch the syncronized TableManager and listen to changes on it. In this case we are observing
    the Age index.

    Finally, somewhere in your client code you must request the existing data from the server. This will begin replication to your
    client.
    ```lua
    TableReplicator.requestServerData()
    ```
]=]

--// Services //--
local RunService = game:GetService("RunService")

export type TableReplicatorSingleton = typeof(require(script.Client.TableReplicatorSingleton))
export type ClientTableReplicator = typeof(require(script.Client.ClientTableReplicator))
export type ServerTableReplicator = typeof(require(script.Server.ServerTableReplicator))
export type TableReplicator = ClientTableReplicator | ServerTableReplicator

local CTR : ClientTableReplicator = nil :: any
local STR : ServerTableReplicator = nil :: any

local TableReplicator = {}
TableReplicator.Current = nil :: TableReplicator

--[=[
    @client
    @within TableReplicator
    @prop Client ClientTableReplicator
]=]
TableReplicator.Client = CTR

--[=[
    @server
    @within TableReplicator
    @prop Server ServerTableReplicator
]=]
TableReplicator.Server = STR

if RunService:IsClient() then
    TableReplicator.Client = require(script.Client.ClientTableReplicator)
    TableReplicator.Current = TableReplicator.Client
else
    TableReplicator.Server = require(script.Server.ServerTableReplicator)
    TableReplicator.Current = TableReplicator.Server
end

setmetatable(TableReplicator, {
    __index = TableReplicator.Current
})

return TableReplicator