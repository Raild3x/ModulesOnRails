-- ClientWeatherBootstrapper.client.luau
-- Bootstraps the weather system on the client by requiring the WeatherClient

local RunService = game:GetService("RunService")

assert(RunService:IsClient(), "ClientWeatherBootstrapper must run on the client")

-- Get the WeatherClient module reference from the ObjectValue
local weatherClientRef = script:WaitForChild("WeatherClientModule", 10)
if not weatherClientRef or not weatherClientRef.Value then
	error("ClientWeatherBootstrapper: WeatherClientModule reference not found")
end

local weatherClientModule = weatherClientRef.Value
if not weatherClientModule:IsA("ModuleScript") then
	error("ClientWeatherBootstrapper: WeatherClientModule is not a ModuleScript")
end

-- Require the WeatherClient to initialize it
local success, result = pcall(require, weatherClientModule)
if not success then
	error("ClientWeatherBootstrapper: Failed to require WeatherClient: " .. tostring(result))
end

print("ClientWeatherBootstrapper: WeatherClient initialized")
