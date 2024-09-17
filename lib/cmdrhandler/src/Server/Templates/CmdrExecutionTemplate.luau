--[=[
	Generic command definition template which we can use to
	@class CmdrCommandDefinitionTemplate
	@ignore
]=]

local function waitForValue(objectValue)
	local value = objectValue.Value
	if value then
		return value
	end

	return objectValue.Changed:Wait()
end

local cmdrCommandId = waitForValue(script:WaitForChild("CmdrCommandId"))
local commandServiceDefinition = require(waitForValue(script:WaitForChild("CmdrServerTarget")))

return function(...)
	return commandServiceDefinition:__executeCommand(cmdrCommandId, ...)
end