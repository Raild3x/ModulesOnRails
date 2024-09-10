--[=[
	Generic command definition template
	@class CmdrCommandDefinitionTemplate
	@ignore
]=]

local HttpService = game:GetService("HttpService")

local value = script:WaitForChild("CmdrJsonCommandData")
return HttpService:JSONDecode(value.Value)