-- Logan Hunt [Raildex]
-- Sep 15, 2023
--[=[
    @class NetWire
]=]

local RunService = game:GetService("RunService")

local NetWire

if RunService:IsServer() then
    NetWire = require(script:FindFirstChild("ServerWire"))
else
    NetWire = require(script:FindFirstChild("ClientWire"))
end

return NetWire