-- Authors: Logan Hunt (Raildex)
-- January 05, 2024

--[=[
    @class TableReplicator

    TableReplicator is a library that enables the replication of tables between the server and client.

    Basic usage:
    ```lua
    -- SERVER
    local TableManager = require(Packages.TableManager)
    local TableReplicator = require(Packages.TableReplicator).Server

    local manager = TableManager.new({
        Age = 18,
    })

    local replicator = TableReplicator.new({
        ClassToken = "PlayerData",
        TableManager = manager,
        ReplicationTargets = "All",
    })
    ```
    ```lua
    -- CLIENT
    local TableReplicator = require(Packages.TableReplicator).Client

    TableReplicator.forEach("PlayerData", function(replicator)
        local manager = replicator:GetTableManager()

        manager:Observe("Age", function(age)
            print("Age changed to:", age)
        end)
    end)

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