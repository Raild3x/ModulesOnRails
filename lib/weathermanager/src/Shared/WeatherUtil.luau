local Janitor = require(script.Parent.Parent.Janitor)
local Signal = require(script.Parent.Parent.Signal)
local T = require(script.Parent.Parent.T)

--// Signals //--
local RegisteredWeather = Signal.new()
local WeatherStarted = Signal.new()
local WeatherStopped = Signal.new()

type LightingData = {
	Priority: number?, -- Priority for lighting changes. Overrides lower priority lighting data
	Ambient: Color3?,
	Brightness: number?,
	ColorShift_Bottom: Color3?,
	ColorShift_Top: Color3?,
	EnvironmentDiffuseScale: number?,
	EnvironmentSpecularScale: number?,
	OutdoorAmbient: Color3?,
	ShadowSoftness: number?,
	ClockTime: number?,
	GeographicLatitude: number?,
	ExposureCompensation: number?,
}

--// Types //--
type Janitor = typeof(Janitor.new())
export type WeatherData = {
	DisplayName: string,
	Description: string?, -- Optional description for the weather effect

	WeatherCycleData: { -- Data used when weather is randomly selected during the weather cycle
		SelectionWeight: number?, -- weight for random selection. Higher weight means more likely to be selected
		Duration: number | NumberRange?, -- duration for the weather effect
	}?,

	Priority: number?, -- Priority for the weather effect. Higher priority overrides lower priority weather effects
	AtmosphereData: {
		Priority: number?, -- Priority for atmosphere changes. Ovverrides lower priority atmosphere data
		Color: Color3?,
		Decay: Color3?,
		Density: number?,
		Offset: number?,
		Glare: number?,
		Haze: number?,
	}?,
	CloudsData: {
		Priority: number?, -- Priority for cloud changes. Overrides lower priority cloud data
		Color: Color3?,
		Cover: number?,
		Density: number?,
	}?,
	LightingData: LightingData?,

	-- Callback functions to handle starting and stopping the weather effect
	OnStart: ((janitor: Janitor) -> ())?,
	OnStop: ((janitor: Janitor) -> ())?,
}

local ValidateWeatherData = T.interface {
	DisplayName = T.string,
	OnStart = T.optional(T.callback),
	OnStop = T.optional(T.callback),
}

local function LoadLightingDataFromFolder(Folder: Instance): LightingData
	local LightingData: LightingData = {}

	for _, Attribute in pairs(Folder:GetAttributes()) do
		LightingData[Attribute] = Folder:GetAttribute(Attribute)
	end

	return LightingData
end

return {
	ValidateWeatherData = ValidateWeatherData,
	RegisteredWeather = RegisteredWeather,
	WeatherStarted = WeatherStarted,
	WeatherStopped = WeatherStopped,
	LoadLightingDataFromFolder = LoadLightingDataFromFolder,
}
