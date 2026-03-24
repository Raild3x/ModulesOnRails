-- WeatherClient.luau
-- Client-side weather visualization and synchronization

--// Roblox Services //--
local Lighting = game:GetService("Lighting")
local RunService = game:GetService("RunService")

assert(RunService:IsClient(), "WeatherClient can only be required on the client")

--// Imports //--
local Janitor = require(script.Parent.Parent.Janitor)
local T = require(script.Parent.Parent.T)
local Fusion = require(script.Parent.Parent.Fusion)
local WeatherUtil = require(script.Parent.Shared.WeatherUtil)
local RemoteProperty = require(script.Parent.Networking.RemoteProperty)

--// Types //--
type WeatherData = WeatherUtil.WeatherData

--// Constants //--
local ValidateWeatherData = WeatherUtil.ValidateWeatherData
local RegisteredWeather = WeatherUtil.RegisteredWeather
local WeatherStarted = WeatherUtil.WeatherStarted
local WeatherStopped = WeatherUtil.WeatherStopped

--// State //--
local RegisteredWeatherEffects = {}
local ActiveWeatherEffects = {}

-- Setup networking
local ActiveWeatherProperty = RemoteProperty.fromServer("WeatherSystem_ActiveWeather")

-- Setup visual effects data
local AtmosphereData = {}
local CloudsData = {}
local LightingData = {}

--------------------------------------------------------------------------------
--// WeatherClient //--
--------------------------------------------------------------------------------

local WeatherClient = {}

--[=[
	@prop RegisteredWeather Signal<string, WeatherData>
	@within WeatherClient
	Signal fired when a new weather type is registered.
]=]
WeatherClient.RegisteredWeather = RegisteredWeather

--[=[
	@prop WeatherStarted Signal<string>
	@within WeatherClient
	Signal fired when a weather effect starts.
]=]
WeatherClient.WeatherStarted = WeatherStarted

--[=[
	@prop WeatherStopped Signal<string>
	@within WeatherClient
	Signal fired when a weather effect stops.
]=]
WeatherClient.WeatherStopped = WeatherStopped

--------------------------------------------------------------------------------
--// Methods //--
--------------------------------------------------------------------------------

--[=[
	Registers a new weather type with its associated data.
	Must match server registration.
	@param weatherType string -- The name of the weather type to register.
	@param weatherData WeatherData -- The config data associated with the weather type.
]=]
function WeatherClient.RegisterWeather(weatherType: string, weatherData: WeatherData)
	assert(T.string(weatherType), "Weather type must be a string")
	assert(not RegisteredWeatherEffects[weatherType], "Weather type already registered: " .. weatherType)
	assert(ValidateWeatherData(weatherData))

	RegisteredWeatherEffects[weatherType] = weatherData
	RegisteredWeather:Fire(weatherType, weatherData)
end

--[=[
	Returns an array of all registered weather types.
]=]
function WeatherClient.GetWeatherTypes(): { string }
	local types = {}
	for weatherType in pairs(RegisteredWeatherEffects) do
		table.insert(types, weatherType)
	end
	return types
end

--[=[
	Returns an array of all active weather effects.
]=]
function WeatherClient.GetActiveWeather(): { string }
	local active = {}
	for weatherType in pairs(ActiveWeatherEffects) do
		table.insert(active, weatherType)
	end
	return active
end

--[=[
	Checks if a specific weather type is currently active.
]=]
function WeatherClient.IsWeatherActive(weatherType: string): boolean
	assert(T.string(weatherType), "Weather type must be a string")
	if not RegisteredWeatherEffects[weatherType] then
		warn("Weather type not registered: " .. weatherType)
		return false
	end
	return ActiveWeatherEffects[weatherType] ~= nil
end

--[=[
	Returns the config data for the specified weather type.
]=]
function WeatherClient.GetWeatherData(weatherType: string): WeatherData?
	assert(T.string(weatherType), "Weather type must be a string")
	return RegisteredWeatherEffects[weatherType]
end

--------------------------------------------------------------------------------
--// Internal Methods //--
--------------------------------------------------------------------------------

local function StartWeather(weatherType: string)
	local weatherData = RegisteredWeatherEffects[weatherType]
	if not weatherData then
		warn("Weather type not registered: " .. weatherType)
		return
	end

	if ActiveWeatherEffects[weatherType] then
		warn("Weather type already active: " .. weatherType)
		return
	end

	local janitor = Janitor.new()
	ActiveWeatherEffects[weatherType] = {
		Janitor = janitor,
	}

	if weatherData.OnStart then
		janitor:Add(task.spawn(weatherData.OnStart, janitor))
	end

	WeatherStarted:Fire(weatherType)
end

local function StopWeather(weatherType: string)
	local weatherData = RegisteredWeatherEffects[weatherType]
	if not weatherData then
		warn("Weather type not registered: " .. weatherType)
		return
	end

	local activeWeather = ActiveWeatherEffects[weatherType]
	if not activeWeather then
		warn("Weather type not active: " .. weatherType)
		return
	end

	ActiveWeatherEffects[weatherType] = nil

	local janitor = activeWeather.Janitor
	if weatherData.OnStop then
		janitor:Add(task.spawn(weatherData.OnStop, janitor))
	end
	janitor:Destroy()

	WeatherStopped:Fire(weatherType)
end

--------------------------------------------------------------------------------
--// Visual Effects Setup //--
--------------------------------------------------------------------------------

local function GenerateDataCategory(scope, Data, DataCategory)
	local SortedWeathers = scope:Value {}

	local function sortWeatherEffects()
		local activeWeatherTypes = {}
		for weatherType in pairs(ActiveWeatherEffects) do
			table.insert(activeWeatherTypes, weatherType)
		end
		table.sort(activeWeatherTypes, function(a, b)
			local aData = RegisteredWeatherEffects[a]
			local bData = RegisteredWeatherEffects[b]
			local aPriority = aData and ((aData[DataCategory] and aData[DataCategory].Priority) or aData.Priority) or 1
			local bPriority = bData and ((bData[DataCategory] and bData[DataCategory].Priority) or bData.Priority) or 1
			return aPriority > bPriority
		end)
		SortedWeathers:set(activeWeatherTypes)
	end

	WeatherStarted:Connect(sortWeatherEffects)
	WeatherStopped:Connect(sortWeatherEffects)
	sortWeatherEffects()

	local function getHighestPriorityProperty(propertyName: string)
		local value = scope:Computed(function(use)
			local sortedWeathers = use(SortedWeathers)
			local propertyValue = Data[propertyName]
			for _, weatherType in sortedWeathers do
				local weatherData = RegisteredWeatherEffects[weatherType]
				if weatherData and weatherData[DataCategory] and weatherData[DataCategory][propertyName] then
					propertyValue = weatherData[DataCategory][propertyName]
					break
				end
			end
			return use(propertyValue)
		end)
		return scope:Spring(value, 0.5)
	end

	local tbl = {}
	for propertyName in Data do
		tbl[propertyName] = getHighestPriorityProperty(propertyName)
	end
	return tbl
end

local function SetupAtmosphere()
	local Atmosphere: Atmosphere = Lighting:FindFirstChildWhichIsA("Atmosphere")
	if not Atmosphere then
		warn("WeatherClient: No Atmosphere instance found in Lighting")
		return
	end
	local scope = Fusion.scoped(Fusion)

	AtmosphereData = {
		Color = scope:Value(Atmosphere.Color),
		Decay = scope:Value(Atmosphere.Decay),
		Density = scope:Value(Atmosphere.Density),
		Offset = scope:Value(Atmosphere.Offset),
		Glare = scope:Value(Atmosphere.Glare),
		Haze = scope:Value(Atmosphere.Haze),
	}

	local tbl = GenerateDataCategory(scope, AtmosphereData, "AtmosphereData")
	scope:Hydrate(Atmosphere)(tbl)
end

local function SetupClouds()
	local Clouds: Clouds = workspace.Terrain:FindFirstChildWhichIsA("Clouds")
	if not Clouds then
		warn("WeatherClient: No Clouds instance found in Terrain")
		return
	end
	local scope = Fusion.scoped(Fusion)

	CloudsData = {
		Color = scope:Value(Clouds.Color),
		Cover = scope:Value(Clouds.Cover),
		Density = scope:Value(Clouds.Density),
	}

	local tbl = GenerateDataCategory(scope, CloudsData, "CloudsData")
	scope:Hydrate(Clouds)(tbl)
end

local function SetupLighting()
	local scope = Fusion.scoped(Fusion)

	LightingData = {
		Ambient = scope:Value(Lighting.Ambient),
		Brightness = scope:Value(Lighting.Brightness),
		ColorShift_Bottom = scope:Value(Lighting.ColorShift_Bottom),
		ColorShift_Top = scope:Value(Lighting.ColorShift_Top),
		EnvironmentDiffuseScale = scope:Value(Lighting.EnvironmentDiffuseScale),
		EnvironmentSpecularScale = scope:Value(Lighting.EnvironmentSpecularScale),
		OutdoorAmbient = scope:Value(Lighting.OutdoorAmbient),
		ShadowSoftness = scope:Value(Lighting.ShadowSoftness),
		ClockTime = scope:Value(Lighting.ClockTime),
		GeographicLatitude = scope:Value(Lighting.GeographicLatitude),
		ExposureCompensation = scope:Value(Lighting.ExposureCompensation),
	}

	local tbl = GenerateDataCategory(scope, LightingData, "LightingData")
	scope:Hydrate(Lighting)(tbl)
end

--------------------------------------------------------------------------------
--// Initialization //--
--------------------------------------------------------------------------------

-- Setup visual effects
SetupAtmosphere()
SetupClouds()
SetupLighting()

-- Sync active weather from server
ActiveWeatherProperty:Observe(function(activeWeather)
	for _, weatherType in activeWeather do
		if not WeatherClient.IsWeatherActive(weatherType) then
			StartWeather(weatherType)
		end
	end
	for weatherType, _ in ActiveWeatherEffects do
		if not table.find(activeWeather, weatherType) then
			StopWeather(weatherType)
		end
	end
end)

-- Auto-discover and register weather modules from server
-- Wait for the WeatherServer's script to be available
local serverScript = script.Parent.Parent.Server.WeatherServer
local weatherModulesFolder = serverScript:WaitForChild("WeatherModules", 10)

if weatherModulesFolder then
	-- Register existing modules
	for _, objectValue in weatherModulesFolder:GetChildren() do
		if objectValue:IsA("ObjectValue") and objectValue.Value and objectValue.Value:IsA("ModuleScript") then
			local weatherModule = objectValue.Value
			local weatherType = objectValue.Name

			-- Require and register the weather config
			local success, weatherData = pcall(require, weatherModule)
			if success and type(weatherData) == "table" then
				local registerSuccess, err = pcall(function()
					WeatherClient.RegisterWeather(weatherType, weatherData)
				end)

				if registerSuccess then
					print("WeatherClient: Auto-registered weather '" .. weatherType .. "'")
				else
					warn("WeatherClient: Failed to register weather type '" .. weatherType .. "':", err)
				end
			else
				warn("WeatherClient: Failed to require weather module for '" .. weatherType .. "':", weatherData)
			end
		end
	end

	-- Listen for new modules being added
	weatherModulesFolder.ChildAdded:Connect(function(objectValue)
		if not objectValue:IsA("ObjectValue") then
			return
		end

		-- Wait for the value to be set if it hasn't been yet
		if not objectValue.Value then
			objectValue:GetPropertyChangedSignal("Value"):Wait()
		end

		if objectValue.Value and objectValue.Value:IsA("ModuleScript") then
			local weatherModule = objectValue.Value
			local weatherType = objectValue.Name

			-- Require and register the weather config
			local success, weatherData = pcall(require, weatherModule)
			if success and type(weatherData) == "table" then
				local registerSuccess, err = pcall(function()
					WeatherClient.RegisterWeather(weatherType, weatherData)
				end)

				if registerSuccess then
					print("WeatherClient: Auto-registered weather '" .. weatherType .. "'")
				else
					warn("WeatherClient: Failed to register weather type '" .. weatherType .. "':", err)
				end
			else
				warn("WeatherClient: Failed to require weather module for '" .. weatherType .. "':", weatherData)
			end
		end
	end)
else
	warn("WeatherClient: Could not find WeatherModules folder")
end

--------------------------------------------------------------------------------
--// Return //--
--------------------------------------------------------------------------------

return WeatherClient
