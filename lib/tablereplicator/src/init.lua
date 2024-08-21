-- Authors: Logan Hunt (Raildex)
-- January 05, 2024

--// Services //--
local RunService = game:GetService("RunService")

local TCR : typeof(require(script.Client.TableClientReplicator)) = nil
local TSR : typeof(require(script.Server.TableServerReplicator)) = nil

export type TableClientReplicator = TCR.TableClientReplicator
export type TableServerReplicator = TSR.TableServerReplicator


if RunService:IsClient() then
    return require(script.Server.TableServerReplicator)
else
    return require(script.Client.TableClientReplicator)
end