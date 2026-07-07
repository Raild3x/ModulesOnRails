-- Authors: Logan Hunt (Raildex)
-- July 06, 2026
--[[
	Prop-table factories for common particle looks. The emitter's built-in
	defaults are neutral (white square, no motion); presets layer a look on
	top and let caller overrides win.
]]

local Types = require("./Types")

local Presets = {}

--[=[
	@within UIParticleEmitter
	@function Confetti
	@param overrides EmitterProps? -- Props merged over the preset (overrides win)
	@return EmitterProps

	Returns a props table for a classic confetti look: randomly hued strips
	with random spin, tumbling under gravity. Accessible as
	`UIParticleEmitter.Presets.Confetti`.

	```lua
	local confetti = UIParticleEmitter(scope, UIParticleEmitter.Presets.Confetti({
		Parent = screenGui,
		Rate = 30,
	}))
	confetti:Fire({ Amount = 100 })
	```
]=]
function Presets.Confetti(overrides: Types.EmitterProps?): Types.EmitterProps
	local rng = if overrides and overrides.Seed then Random.new(overrides.Seed) else Random.new()

	local props: Types.EmitterProps = {
		Size = function()
			local length = rng:NextNumber(10, 20)
			return Vector2.new(length, length * rng:NextNumber(0.4, 0.6))
		end,
		Color3 = function()
			return Color3.fromHSV(rng:NextNumber(), 0.5, 1)
		end,
		Velocity = function()
			return Vector2.new(rng:NextNumber(-30, 30), rng:NextNumber(-30, 30))
		end,
		Rotation = NumberRange.new(0, 360),
		RotationSpeed = NumberRange.new(-100, 100),
		LifeTime = NumberRange.new(2, 4),
	}

	if overrides then
		for key, value in overrides :: any do
			(props :: any)[key] = value
		end
	end

	return props
end

return Presets
