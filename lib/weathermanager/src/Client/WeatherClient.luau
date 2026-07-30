-- WeatherClient.luau
-- Client-side weather visualization and synchronization

--// Roblox Services //--
local Lighting = game:GetService("Lighting")
local RunService = game:GetService("RunService")

assert(RunService:IsClient(), "WeatherClient can only be required on the client")

--// Imports //--
local Packages = script.Parent.Parent.Parent
local Janitor = require(Packages.Janitor)
local T = require(Packages.T)
local Fusion = require(Packages.Fusion)
local WeatherUtil = require(Packages.WeatherManager.Shared.WeatherUtil)
local RemoteProperty = require(Packages.WeatherManager.Networking.RemoteProperty)

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

-- Maps each WeatherData category to the Roblox instance class it drives.
-- Used to create missing instances on demand when a weather effect that
-- references a category becomes active for the first time.
local CategoryInstanceRequirements = {
	SkyboxData = { parent = Lighting, className = "Sky" },
	AtmosphereData = { parent = Lighting, className = "Atmosphere" },
	BloomData = { parent = Lighting, className = "BloomEffect" },
	BlurData = { parent = Lighting, className = "BlurEffect" },
	ColorCorrectionData = { parent = Lighting, className = "ColorCorrectionEffect" },
	DepthOfFieldData = { parent = Lighting, className = "DepthOfFieldEffect" },
	SunRaysData = { parent = Lighting, className = "SunRaysEffect" },
	CloudData = { parent = workspace.Terrain, className = "Clouds" },
}

-- Setup visual effects data
local AtmosphereData = {}
local CloudsData = {}
local LightingData = {}
local SkyboxData = {}
local BloomData = {}
local BlurData = {}
local ColorCorrectionData = {}
local DepthOfFieldData = {}
local SunRaysData = {}

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
--// Visual Effects Setup //--
--------------------------------------------------------------------------------

-- Registered refresher functions, one per tracked property. Calling
-- RefreshBaselines() snapshots all current instance values into their
-- corresponding Fusion Values so the spring transitions FROM the live state.
local BaselineRefreshers: { () -> () } = {}

local function trackProperty(scope, instance, propertyName)
	local value = scope:Value(instance[propertyName])
	table.insert(BaselineRefreshers, function()
		value:set(instance[propertyName])
	end)
	return value
end

local function RefreshBaselines()
	for _, refresh in BaselineRefreshers do
		refresh()
	end
end

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
		local computed = scope:Computed(function(use)
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
		-- Only apply Spring to types Fusion can interpolate. Strings (texture IDs,
		-- etc.) must be returned as plain Computed or Fusion errors with nil.
		local baselineType = typeof(Fusion.peek(Data[propertyName]))
		if baselineType == "number" or baselineType == "Color3" or baselineType == "Vector3" then
			return scope:Spring(computed, 0.5)
		end
		return computed
	end

	local tbl = {}
	for propertyName in Data do
		tbl[propertyName] = getHighestPriorityProperty(propertyName)
	end
	return tbl
end

local function SetupSkybox(Sky: Sky)
	local scope = Fusion.scoped(Fusion)

	SkyboxData = {
		MoonAngularSize = trackProperty(scope, Sky, "MoonAngularSize"),
		MoonTextureId = trackProperty(scope, Sky, "MoonTextureId"),
		SkyboxBk = trackProperty(scope, Sky, "SkyboxBk"),
		SkyboxDn = trackProperty(scope, Sky, "SkyboxDn"),
		SkyboxFt = trackProperty(scope, Sky, "SkyboxFt"),
		SkyboxLf = trackProperty(scope, Sky, "SkyboxLf"),
		SkyboxRt = trackProperty(scope, Sky, "SkyboxRt"),
		SkyboxUp = trackProperty(scope, Sky, "SkyboxUp"),
		SkyboxOrientation = trackProperty(scope, Sky, "SkyboxOrientation"),
		StarCount = trackProperty(scope, Sky, "StarCount"),
		SunAngularSize = trackProperty(scope, Sky, "SunAngularSize"),
		SunTextureId = trackProperty(scope, Sky, "SunTextureId"),
	}

	local tbl = GenerateDataCategory(scope, SkyboxData, "SkyboxData")
	scope:Hydrate(Sky)(tbl)
end

local function SetupBloom(Bloom: BloomEffect)
	local scope = Fusion.scoped(Fusion)

	BloomData = {
		Intensity = trackProperty(scope, Bloom, "Intensity"),
		Size = trackProperty(scope, Bloom, "Size"),
		Threshold = trackProperty(scope, Bloom, "Threshold"),
	}

	local tbl = GenerateDataCategory(scope, BloomData, "BloomData")
	scope:Hydrate(Bloom)(tbl)
end

local function SetupBlur(Blur: BlurEffect)
	local scope = Fusion.scoped(Fusion)

	BlurData = {
		Size = trackProperty(scope, Blur, "Size"),
	}

	local tbl = GenerateDataCategory(scope, BlurData, "BlurData")
	scope:Hydrate(Blur)(tbl)
end

local function SetupColorCorrection(ColorCorrection: ColorCorrectionEffect)
	local scope = Fusion.scoped(Fusion)

	ColorCorrectionData = {
		Brightness = trackProperty(scope, ColorCorrection, "Brightness"),
		Contrast = trackProperty(scope, ColorCorrection, "Contrast"),
		Saturation = trackProperty(scope, ColorCorrection, "Saturation"),
		TintColor = trackProperty(scope, ColorCorrection, "TintColor"),
	}

	local tbl = GenerateDataCategory(scope, ColorCorrectionData, "ColorCorrectionData")
	scope:Hydrate(ColorCorrection)(tbl)
end

local function SetupDepthOfField(DepthOfField: DepthOfFieldEffect)
	local scope = Fusion.scoped(Fusion)

	DepthOfFieldData = {
		FarIntensity = trackProperty(scope, DepthOfField, "FarIntensity"),
		FocusDistance = trackProperty(scope, DepthOfField, "FocusDistance"),
		NearIntensity = trackProperty(scope, DepthOfField, "NearIntensity"),
		InFocusRadius = trackProperty(scope, DepthOfField, "InFocusRadius"),
	}

	local tbl = GenerateDataCategory(scope, DepthOfFieldData, "DepthOfFieldData")
	scope:Hydrate(DepthOfField)(tbl)
end

local function SetupSunRays(SunRays: SunRaysEffect)
	local scope = Fusion.scoped(Fusion)

	SunRaysData = {
		Intensity = trackProperty(scope, SunRays, "Intensity"),
		Spread = trackProperty(scope, SunRays, "Spread"),
	}

	local tbl = GenerateDataCategory(scope, SunRaysData, "SunRaysData")
	scope:Hydrate(SunRays)(tbl)
end

local function SetupAtmosphere(Atmosphere: Atmosphere)
	local scope = Fusion.scoped(Fusion)

	AtmosphereData = {
		Color = trackProperty(scope, Atmosphere, "Color"),
		Decay = trackProperty(scope, Atmosphere, "Decay"),
		Density = trackProperty(scope, Atmosphere, "Density"),
		Offset = trackProperty(scope, Atmosphere, "Offset"),
		Glare = trackProperty(scope, Atmosphere, "Glare"),
		Haze = trackProperty(scope, Atmosphere, "Haze"),
	}

	local tbl = GenerateDataCategory(scope, AtmosphereData, "AtmosphereData")
	scope:Hydrate(Atmosphere)(tbl)
end

local function SetupClouds(Clouds: Clouds)
	local scope = Fusion.scoped(Fusion)

	CloudsData = {
		Color = trackProperty(scope, Clouds, "Color"),
		Cover = trackProperty(scope, Clouds, "Cover"),
		Density = trackProperty(scope, Clouds, "Density"),
	}

	local tbl = GenerateDataCategory(scope, CloudsData, "CloudsData")
	scope:Hydrate(Clouds)(tbl)
end

local function SetupLighting()
	local scope = Fusion.scoped(Fusion)

	LightingData = {
		Ambient = trackProperty(scope, Lighting, "Ambient"),
		Brightness = trackProperty(scope, Lighting, "Brightness"),
		ColorShift_Bottom = trackProperty(scope, Lighting, "ColorShift_Bottom"),
		ColorShift_Top = trackProperty(scope, Lighting, "ColorShift_Top"),
		EnvironmentDiffuseScale = trackProperty(scope, Lighting, "EnvironmentDiffuseScale"),
		EnvironmentSpecularScale = trackProperty(scope, Lighting, "EnvironmentSpecularScale"),
		OutdoorAmbient = trackProperty(scope, Lighting, "OutdoorAmbient"),
		ShadowSoftness = trackProperty(scope, Lighting, "ShadowSoftness"),
		ClockTime = trackProperty(scope, Lighting, "ClockTime"),
		GeographicLatitude = trackProperty(scope, Lighting, "GeographicLatitude"),
		ExposureCompensation = trackProperty(scope, Lighting, "ExposureCompensation"),
	}

	local tbl = GenerateDataCategory(scope, LightingData, "LightingData")
	scope:Hydrate(Lighting)(tbl)
end

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

	-- Snapshot whatever the external lighting system currently has as the
	-- baseline before any weather properties take over.
	if next(ActiveWeatherEffects) == nil then
		RefreshBaselines()
	end

	-- Create any Roblox instances required by this weather's data categories
	-- if they don't yet exist. ChildAdded fires synchronously on .Parent =,
	-- so each Setup* function runs and its Fusion pipeline is fully wired
	-- before WeatherStarted fires below.
	for category, req in CategoryInstanceRequirements do
		if weatherData[category] and not req.parent:FindFirstChildWhichIsA(req.className) then
			Instance.new(req.className).Parent = req.parent
		end
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
--// Initialization //--
--------------------------------------------------------------------------------

-- Setup visual effects
-- Lighting is always present, run immediately.
SetupLighting()

-- For all optional child instances: run setup now if present, and watch for
-- late additions so an external system can create them at any point.
local function trySetup(instance, setupFn)
	if instance then
		setupFn(instance)
	end
end

trySetup(Lighting:FindFirstChildWhichIsA("Sky"), SetupSkybox)
trySetup(Lighting:FindFirstChildWhichIsA("Atmosphere"), SetupAtmosphere)
trySetup(Lighting:FindFirstChildWhichIsA("BloomEffect"), SetupBloom)
trySetup(Lighting:FindFirstChildWhichIsA("BlurEffect"), SetupBlur)
trySetup(Lighting:FindFirstChildWhichIsA("ColorCorrectionEffect"), SetupColorCorrection)
trySetup(Lighting:FindFirstChildWhichIsA("DepthOfFieldEffect"), SetupDepthOfField)
trySetup(Lighting:FindFirstChildWhichIsA("SunRaysEffect"), SetupSunRays)
trySetup(workspace.Terrain:FindFirstChildWhichIsA("Clouds"), SetupClouds)

-- Map class names to their setup functions for the ChildAdded listeners below.
local lightingSetupByClass = {
	Sky = SetupSkybox,
	Atmosphere = SetupAtmosphere,
	BloomEffect = SetupBloom,
	BlurEffect = SetupBlur,
	ColorCorrectionEffect = SetupColorCorrection,
	DepthOfFieldEffect = SetupDepthOfField,
	SunRaysEffect = SetupSunRays,
}

Lighting.ChildAdded:Connect(function(child)
	local setupFn = lightingSetupByClass[child.ClassName]
	if setupFn then
		setupFn(child)
	end
end)

workspace.Terrain.ChildAdded:Connect(function(child)
	if child:IsA("Clouds") then
		SetupClouds(child)
	end
end)

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
