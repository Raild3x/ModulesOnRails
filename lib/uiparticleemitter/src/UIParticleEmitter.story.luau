-- Authors: Logan Hunt (Raildex)
-- July 06, 2026
--[[
	UI Labs story demonstrating UIParticleEmitter with the Confetti preset:
	continuous spawning, live physics controls, noise-driven wind, and
	optional periodic bursts.

	Note: this repo has no story runner; the story ships with the package for
	use in consuming projects with UI Labs installed.
]]

local Fusion = require("../Fusion")
local UIParticleEmitter = require(script.Parent :: any)

local peek = Fusion.peek

local CONTROLS = {
	Enabled = true,
	Visible = true,
	Gravity = 500,
	Drag = 0.95,
	Rate = 30,
	TimeScale = 1,
	WindStrength = 50,
	WindNoiseScale = 0.01,
	VerticalForceMin = 200,
	VerticalForceMax = 600,
	HorizontalForceMin = -100,
	HorizontalForceMax = 100,
	BurstFiring = false,
}

return {
	fusion = Fusion,
	controls = CONTROLS,
	story = function(props)
		local controls = props.controls
		local scope = props.scope
		local rng = Random.new()

		local emitter = UIParticleEmitter(
			scope,
			UIParticleEmitter.Presets.Confetti {
				Parent = props.target,
				Enabled = controls.Enabled,
				Visible = controls.Visible,
				Gravity = controls.Gravity,
				Drag = controls.Drag,
				TimeScale = controls.TimeScale,
				Rate = controls.Rate,
				LifeTime = NumberRange.new(2, 5),
				RotationSpeed = NumberRange.new(-200, 200),
				Size = function()
					local length = rng:NextNumber(12, 25)
					return Vector2.new(length, length * rng:NextNumber(0.4, 0.6))
				end,
				Velocity = function()
					return Vector2.new(
						rng:NextNumber(peek(controls.HorizontalForceMin), peek(controls.HorizontalForceMax)),
						-rng:NextNumber(peek(controls.VerticalForceMin), peek(controls.VerticalForceMax))
					)
				end,
				Wind = function(pos: Vector2)
					-- Noise-driven wind field for a natural tumble
					local time = os.clock()
					local noiseScale = peek(controls.WindNoiseScale)
					local strength = peek(controls.WindStrength)
					local noiseX = math.noise(pos.X * noiseScale, pos.Y * noiseScale, time * 0.5)
					local noiseY = math.noise(pos.X * noiseScale + 100, pos.Y * noiseScale + 100, time * 0.5)
					return Vector2.new(noiseX * strength, noiseY * strength)
				end,
			}
		)

		-- Periodic bursts while the BurstFiring control is on
		local burstThread = task.spawn(function()
			while true do
				task.wait(3)
				if peek(controls.BurstFiring) then
					emitter:Fire { Amount = 50 }
				end
			end
		end)
		table.insert(scope, function()
			task.cancel(burstThread)
		end)
	end,
}
