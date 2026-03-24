-- WeatherServer.luau
-- Server-side weather management system

--// Roblox Services //--
local RunService = game:GetService("RunService")

assert(RunService:IsServer(), "WeatherServer can only be required on the server")

--// Imports //--
local Janitor = require(script.Parent.Parent.Janitor)
local T = require(script.Parent.Parent.T)
local WeatherUtil = require(script.Parent.Shared.WeatherUtil)
local RemoteProperty = require(script.Parent.Networking.RemoteProperty)

--// Types //--
type WeatherData = WeatherUtil.WeatherData

--// Constants //--
local MINUTE = 60
local ValidateWeatherData = WeatherUtil.ValidateWeatherData
local RegisteredWeather = WeatherUtil.RegisteredWeather
local WeatherStarted = WeatherUtil.WeatherStarted
local WeatherStopped = WeatherUtil.WeatherStopped

--// State //--
local RegisteredWeatherEffects = {}
local ActiveWeatherEffects = {}
local WeatherCycleEnabled = false
local WeatherCycleThread = nil
local LastWeatherPicked = nil
local ExpirationLoopThread = nil -- Track the expiration loop thread

-- Setup networking
local ActiveWeatherProperty = RemoteProperty.new("WeatherSystem_ActiveWeather", {})

-- Create a folder to hold ObjectValues pointing to weather modules
local function getWeatherModulesFolder()
	local folder = script:FindFirstChild("WeatherModules")
	if not folder then
		folder = Instance.new("Folder")
		folder.Name = "WeatherModules"
		folder.Parent = script
	end
	return folder
end

--------------------------------------------------------------------------------
--// WeatherServer //--
--------------------------------------------------------------------------------

local WeatherServer = {}

--------------------------------------------------------------------------------
--// Internal Methods //--
--------------------------------------------------------------------------------

local function StartExpirationLoop()
	-- Don't start if already running
	if ExpirationLoopThread then
		return
	end

	ExpirationLoopThread = task.spawn(function()
		while true do
			local currentTime = workspace:GetServerTimeNow()
			local hasActiveWeather = false

			for weatherType, activeWeather in pairs(ActiveWeatherEffects) do
				hasActiveWeather = true
				if activeWeather.EndTime and currentTime >= activeWeather.EndTime then
					WeatherServer.StopWeather(weatherType)
				end
			end

			-- If no active weather, stop the loop
			if not hasActiveWeather then
				ExpirationLoopThread = nil
				return
			end

			task.wait(1) -- Check every second
		end
	end)
end

--------------------------------------------------------------------------------
--// Public Methods //--
--------------------------------------------------------------------------------

--[=[
	@prop RegisteredWeather Signal<string, WeatherData>
	@within WeatherServer
	Signal fired when a new weather type is registered.
]=]
WeatherServer.RegisteredWeather = RegisteredWeather

--[=[
	@prop WeatherStarted Signal<string>
	@within WeatherServer
	Signal fired when a weather effect starts.
]=]
WeatherServer.WeatherStarted = WeatherStarted

--[=[
	@prop WeatherStopped Signal<string>
	@within WeatherServer
	Signal fired when a weather effect stops.
]=]
WeatherServer.WeatherStopped = WeatherStopped

--------------------------------------------------------------------------------
--// Methods //--
--------------------------------------------------------------------------------

--[=[
	Registers a new weather type with its associated data.
	@param weatherType string -- The name of the weather type to register.
	@param weatherData WeatherData -- The config data associated with the weather type.
]=]
function WeatherServer.RegisterWeather(weatherType: string, weatherData: WeatherData)
	assert(T.string(weatherType), "Weather type must be a string")
	assert(not RegisteredWeatherEffects[weatherType], "Weather type already registered: " .. weatherType)
	assert(ValidateWeatherData(weatherData))

	RegisteredWeatherEffects[weatherType] = weatherData
	RegisteredWeather:Fire(weatherType, weatherData)
end

--[=[
	Registers a weather effect from a ModuleScript.
	The module must be in a visible location (ReplicatedStorage or ServerStorage) for client access.
	The module should return a single weather configuration table (not a collection of multiple weather types).
	@param weatherModule ModuleScript -- Module containing a single weather configuration
	@return string -- The path to the module for client access
	
	@example
	```lua
	-- RainWeather.lua (returns a single weather config)
	return {
		DisplayName = "Rain",
		Description = "Light rainfall",
		WeatherCycleData = {
			SelectionWeight = 5,
			Duration = NumberRange.new(120, 300),
		},
		-- ... other weather data
	}
	
	-- Server code
	local RainModule = game.ReplicatedStorage.Weather.RainWeather
	WeatherServer.RegisterWeatherFromModule(RainModule)
	```
]=]
function WeatherServer.RegisterWeatherFromModule(weatherModule: ModuleScript): string
	assert(
		typeof(weatherModule) == "Instance" and weatherModule:IsA("ModuleScript"),
		"weatherModule must be a ModuleScript"
	)

	-- Check if module is in a visible location
	local ReplicatedStorage = game:GetService("ReplicatedStorage")

	local isInReplicatedStorage = weatherModule:IsDescendantOf(ReplicatedStorage)
	local isInWorkspace = weatherModule:IsDescendantOf(workspace)

	if not (isInReplicatedStorage or isInWorkspace) then
		error(
			"WeatherModule must be located in ReplicatedStorage or Workspace for client access. Current location: "
				.. weatherModule:GetFullName()
		)
	end

	-- Require and validate the module
	local weatherData = require(weatherModule)
	assert(type(weatherData) == "table", "WeatherModule must return a weather configuration table")
	assert(ValidateWeatherData(weatherData), "Invalid weather data in module")

	-- Use the module name as the weather type
	local weatherType = weatherModule.Name

	-- Get the path for client to require
	local modulePath = weatherModule:GetFullName()

	-- Register the weather type
	WeatherServer.RegisterWeather(weatherType, weatherData)

	-- Create an ObjectValue pointing to the module for client discovery
	local weatherModulesFolder = getWeatherModulesFolder()
	local objectValue = Instance.new("ObjectValue")
	objectValue.Name = weatherType
	objectValue.Value = weatherModule
	objectValue.Parent = weatherModulesFolder

	print("WeatherServer: Registered weather '" .. weatherType .. "' from module:", modulePath)
	return modulePath
end

--[=[
	Returns an array of all registered weather types.
]=]
function WeatherServer.GetWeatherTypes(): { string }
	local types = {}
	for weatherType in pairs(RegisteredWeatherEffects) do
		table.insert(types, weatherType)
	end
	return types
end

--[=[
	Returns an array of all currently active weather types.
]=]
function WeatherServer.GetActiveWeather(): { string }
	local active = {}
	for weatherType in pairs(ActiveWeatherEffects) do
		table.insert(active, weatherType)
	end
	return active
end

--[=[
	Returns the config data that was given for the specified weather type.
]=]
function WeatherServer.GetWeatherData(weatherType: string): WeatherData?
	assert(T.string(weatherType), "Weather type must be a string")
	return RegisteredWeatherEffects[weatherType]
end

--[=[
	Checks if a specific weather type is currently active.
]=]
function WeatherServer.IsWeatherActive(weatherType: string): boolean
	assert(T.string(weatherType), "Weather type must be a string")
	if not RegisteredWeatherEffects[weatherType] then
		warn("Weather type not registered: " .. weatherType)
		return false
	end
	return ActiveWeatherEffects[weatherType] ~= nil
end

--[=[
	Starts a weather effect of the specified type.
	@param weatherType string -- The weather type to start
	@param config table? -- Optional configuration: {Duration: number?}
]=]
function WeatherServer.StartWeather(
	weatherType: string,
	config: {
		Duration: number?,
	}?
)
	local weatherData = RegisteredWeatherEffects[weatherType]
	if not weatherData then
		warn("Weather type not registered: " .. weatherType)
		return
	end

	local Config = config or {}
	assert(T.interface {
		Duration = T.optional(T.numberPositive),
	}(Config))

	local activeWeather = ActiveWeatherEffects[weatherType]
	if activeWeather then
		if Config.Duration then
			activeWeather.EndTime = workspace:GetServerTimeNow() + Config.Duration
		else
			activeWeather.EndTime = nil
		end
		return
	end

	local janitor = Janitor.new()
	ActiveWeatherEffects[weatherType] = {
		Janitor = janitor,
		EndTime = if Config.Duration then workspace:GetServerTimeNow() + Config.Duration else nil,
	}

	-- Update clients
	ActiveWeatherProperty:Set(WeatherServer.GetActiveWeather())

	-- Start expiration loop if needed
	if Config.Duration then
		StartExpirationLoop()
	end

	if weatherData.OnStart then
		janitor:Add(task.spawn(weatherData.OnStart, janitor))
	end

	WeatherStarted:Fire(weatherType)
end

--[=[
	Stops a weather effect of the specified type.
	@param weatherType string -- The weather type to stop
]=]
function WeatherServer.StopWeather(weatherType: string)
	local weatherData = RegisteredWeatherEffects[weatherType]
	if not weatherData then
		warn("Weather type not registered: " .. weatherType)
		return
	end

	local activeWeather = ActiveWeatherEffects[weatherType]
	if not activeWeather then
		warn(weatherType .. " is not currently active.")
		return
	end

	ActiveWeatherEffects[weatherType] = nil
	ActiveWeatherProperty:Set(WeatherServer.GetActiveWeather())

	local janitor = activeWeather.Janitor
	if weatherData.OnStop then
		janitor:Add(task.spawn(weatherData.OnStop, janitor))
	end
	janitor:Destroy()

	WeatherStopped:Fire(weatherType)
end

local function RunWeatherCycle()
	local weatherWeights = {}
	local totalWeight = 0

	for weatherType, weatherData in RegisteredWeatherEffects do
		local weight = weatherData.WeatherCycleData and weatherData.WeatherCycleData.SelectionWeight or 1
		if weatherType == LastWeatherPicked then
			weight = weight * 0.1 -- Reduce weight for last picked
		end
		table.insert(weatherWeights, {
			WeatherType = weatherType,
			Weight = weight,
		})
		totalWeight = totalWeight + weight
	end

	-- Weighted random selection
	local randomValue = math.random() * totalWeight
	local pickedWeather = nil
	local currentWeight = 0

	for _, entry in weatherWeights do
		currentWeight = currentWeight + entry.Weight
		if randomValue <= currentWeight then
			pickedWeather = entry.WeatherType
			break
		end
	end

	if not pickedWeather then
		return
	end

	local pickedWeatherData = WeatherServer.GetWeatherData(pickedWeather)
	local weatherCycleData = pickedWeatherData.WeatherCycleData or {}
	local durationValue = weatherCycleData.Duration or 60
	local duration = typeof(durationValue) == "NumberRange" and math.random(durationValue.Min, durationValue.Max)
		or durationValue

	local minutes, seconds = math.floor(duration / 60), math.floor(duration % 60)
	print("WeatherServer: Starting weather:", pickedWeather)
	print("Duration:", string.format("%02d:%02d", minutes, seconds))

	WeatherServer.StartWeather(pickedWeather, {
		Duration = duration,
	})
	LastWeatherPicked = pickedWeather
end

--[=[
	Enables automatic weather cycling.
	@param config table? -- Optional config: {DelayBetweenCycles: NumberRange?}
]=]
function WeatherServer.EnableWeatherCycle(config: {
	DelayBetweenCycles: NumberRange?,
}?)
	if WeatherCycleEnabled then
		warn("Weather cycle already enabled")
		return
	end

	WeatherCycleEnabled = true
	local Config = config or {}
	local DELAY_BETWEEN_CYCLES = Config.DelayBetweenCycles or NumberRange.new(5 * MINUTE, 15 * MINUTE)

	WeatherCycleThread = task.spawn(function()
		while WeatherCycleEnabled do
			RunWeatherCycle()
			local delay = math.random(DELAY_BETWEEN_CYCLES.Min, DELAY_BETWEEN_CYCLES.Max)
			local minutes, seconds = math.floor(delay / 60), math.floor(delay % 60)
			print("WeatherServer: Next weather cycle in:", string.format("%02d:%02d", minutes, seconds))
			task.wait(delay)
		end
	end)
end

--[=[
	Disables automatic weather cycling.
]=]
function WeatherServer.DisableWeatherCycle()
	WeatherCycleEnabled = false
	if WeatherCycleThread then
		task.cancel(WeatherCycleThread)
		WeatherCycleThread = nil
	end
end
--------------------------------------------------------------------------------
--// Initialization //--
--------------------------------------------------------------------------------

--[=[
	Sets up the ClientWeatherBootstrapper for all clients.
	This parents the bootstrapper to StarterPlayer.StarterPlayerScripts and existing player's PlayerScripts.
]=]
local function SetupClientBootstrapper()
	local Players = game:GetService("Players")
	local StarterPlayer = game:GetService("StarterPlayer")
	local StarterPlayerScripts = StarterPlayer:WaitForChild("StarterPlayerScripts")

	-- Find the bootstrapper script
	local bootstrapper = script.Parent:FindFirstChild("ClientWeatherBootstrapper")
	if not bootstrapper then
		error("WeatherServer: ClientWeatherBootstrapper script not found")
	end

	-- Create an ObjectValue pointing to the WeatherClient module for easy discovery
	local weatherClientRef = bootstrapper:FindFirstChild("WeatherClientModule")
	if not weatherClientRef then
		weatherClientRef = Instance.new("ObjectValue")
		weatherClientRef.Name = "WeatherClientModule"
		weatherClientRef.Value = script.Parent.Parent.Client.WeatherClient
		weatherClientRef.Parent = bootstrapper
	end

	-- Clone to StarterPlayerScripts if not already there
	if not StarterPlayerScripts:FindFirstChild("ClientWeatherBootstrapper") then
		local bootstrapperClone = bootstrapper:Clone()
		bootstrapperClone.Parent = StarterPlayerScripts
	end

	-- Add to existing players
	for _, player in Players:GetPlayers() do
		local playerScripts = player:FindFirstChild("PlayerScripts")
		if playerScripts and not playerScripts:FindFirstChild("ClientWeatherBootstrapper") then
			local bootstrapperClone = bootstrapper:Clone()
			bootstrapperClone.Parent = playerScripts
		end
	end
end

task.defer(SetupClientBootstrapper)

--------------------------------------------------------------------------------
--// Return //--
--------------------------------------------------------------------------------

return WeatherServer
