-- Authors: Logan Hunt (Raildex)
-- January 05, 2024

--// Services //--
local RunService = game:GetService("RunService")

local CTR : typeof(require(script.Client.ClientTableReplicator)) = nil
local STR : typeof(require(script.Server.ServerTableReplicator)) = nil

export type ClientTableReplicator = CTR.ClientTableReplicator
export type ServerTableReplicator = STR.ServerTableReplicator


if RunService:IsClient() then
    return require(script.Server.ServerTableReplicator)
else
    return require(script.Client.ClientTableReplicator)
end