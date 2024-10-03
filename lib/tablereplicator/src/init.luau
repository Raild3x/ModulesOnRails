-- Authors: Logan Hunt (Raildex)
-- January 05, 2024
--[=[
    @class TableReplicator

    The entry point file for the TableReplicator System. See ServerTableReplicator for more info on usage.
]=]

--// Services //--
local RunService = game:GetService("RunService")

export type ClientTableReplicator = typeof(require(script.Client.ClientTableReplicator))
export type ServerTableReplicator = typeof(require(script.Server.ServerTableReplicator))
export type TableReplicator = ClientTableReplicator | ServerTableReplicator
export type TableReplicatorSingleton = typeof(require(script.Client.TableReplicatorSingleton))

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

-- Set the current TableReplicator to the correct one
if RunService:IsClient() then
    TableReplicator.Client = require(script.Client.ClientTableReplicator)
    TableReplicator.Current = TableReplicator.Client
else
    TableReplicator.Server = require(script.Server.ServerTableReplicator)
    TableReplicator.Current = TableReplicator.Server
end

-- initialize the metatable redirection
setmetatable(TableReplicator, {
    __index = function(t, key)
        if key == "Client" or key == "Server" then
            error("TableReplicator." .. key .. " is not availible in RunContext: " .. if RunService:IsClient() then "Server" else "Client")
        end
        return t.Current[key]
    end,
})

table.freeze(TableReplicator)

return TableReplicator