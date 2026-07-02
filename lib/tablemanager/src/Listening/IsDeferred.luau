--!native
--!optimize 2
--!strict
-- This file just checks if the current environment defers events naturally or not.

local cached: boolean? = nil

const function IsDeferred(): boolean
	if cached ~= nil then
		return cached
	end

	local handlerRun = false
	pcall(function()
		const bindableEvent = Instance.new("BindableEvent")
		bindableEvent.Event:Once(function()
			handlerRun = true
		end)
		bindableEvent:Fire()
		bindableEvent:Destroy()
	end)

	cached = not handlerRun
	return cached :: any
end

return IsDeferred
