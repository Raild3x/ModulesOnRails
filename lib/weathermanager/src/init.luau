-- init.luau
-- Main entry point for the WeatherSystem package

local RunService = game:GetService("RunService")

local WeatherSystem = {}

if RunService:IsServer() then
	WeatherSystem.Server = require(script.Server.WeatherServer)
end

if RunService:IsClient() then
	WeatherSystem.Client = require(script.Client.WeatherClient)
end

-- Export shared types and utilities
WeatherSystem.WeatherUtil = require(script.Shared.WeatherUtil)

return WeatherSystem
