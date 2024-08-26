-- Authors: Logan Hunt (Raildex)
-- January 05, 2024

--// Services //--
local RunService = game:GetService("RunService")

export type ClientTableReplicator = typeof(require(script.Client.ClientTableReplicator))
export type ServerTableReplicator = typeof(require(script.Server.ServerTableReplicator))
export type TableReplicator = ClientTableReplicator | ServerTableReplicator
export type TableReplicatorSingleton = typeof(require(script.Client.TableReplicatorSingleton))

if RunService:IsClient() then
    return require(script.Client.ClientTableReplicator)
else
    return require(script.Server.ServerTableReplicator)
end