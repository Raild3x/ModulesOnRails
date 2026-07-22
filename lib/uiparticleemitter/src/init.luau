-- Authors: Logan Hunt (Raildex)
-- July 06, 2026
--[=[
	@class UIParticleEmitter

	A Fusion 0.3 component that emits 2D particles (Frames or ImageLabels),
	similar to Roblox's ParticleEmitter but for ScreenGuis. Particles can
	spawn continuously while `Enabled`, or on demand via `:Fire()`.

	Features:
	- Continuous spawning based on `Rate`, plus manual bursts with `:Fire()`
	- Physics simulation with gravity, drag, wind (constant or positional
	  function), and rotation
	- `NumberSequence` / `ColorSequence` support for animating transparency,
	  color, and size over a particle's lifetime (keypoint envelopes are
	  ignored; values interpolate linearly between keypoints)
	- Solid color (Frame) or image (ImageLabel) particles, recycled through
	  a pool shared by all emitters on the same LayerCollector for high spawn
	  rates
	- `MaxParticles` cap (new spawns are dropped at the cap)
	- `MaintainRelativePosition` makes live particles ride along with the
	  emitter as it moves, instead of staying where they spawned in screen
	  space (default off)
	- Particle management with `:Stop()`, `:Clear()`, and `:GetParticleCount()`
	- Presets via `UIParticleEmitter.Presets` (e.g. `Presets.Confetti`)

	Most particle props accept a constant, a Fusion state object, or a
	generator function called once per particle spawn.

	By design, destroying the emitter's scope does **not** kill live
	particles: spawning stops, but existing particles finish their natural
	lifetime before everything cleans itself up. Pass
	`CleanupParticlesImmediately = true` to destroy them instantly instead.

	Usage:
	```lua
	local scope = Fusion.scoped(Fusion)

	-- Neutral particles with a fade-out
	local emitter = UIParticleEmitter(scope, {
		Parent = screenGui,
		SpawnAreaPosition = UDim2.fromScale(0.5, 0.5),
		Enabled = true,
		Rate = 20,
		Velocity = function()
			return Vector2.new(math.random(-50, 50), -math.random(100, 200))
		end,
		Transparency = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 0),
			NumberSequenceKeypoint.new(0.8, 0),
			NumberSequenceKeypoint.new(1, 1),
		}),
	})

	-- Confetti preset with a manual burst
	local confetti = UIParticleEmitter(scope, UIParticleEmitter.Presets.Confetti({
		Parent = screenGui,
		Enabled = false,
	}))
	confetti:Fire({ Amount = 100 })
	```
]=]

local Emitter = require("@self/Emitter")
local Presets = require("@self/Presets")
local Types = require("@self/Types")

export type Getter<T> = Types.Getter<T>
export type EmitterProps = Types.EmitterProps
export type FireConfig = Types.FireConfig
export type UIParticleEmitter = Types.UIParticleEmitter

--[=[
	@within UIParticleEmitter
	@prop Presets Presets
	@readonly

	Prop-table factories for common looks. Currently ships
	`Presets.Confetti(overrides?)`.
]=]

local UIParticleEmitter = setmetatable({
	Presets = Presets,
}, {
	__call = function(_, scope: Types.Scope<any>, props: EmitterProps): UIParticleEmitter
		return Emitter.new(scope, props) :: any
	end,
})

return UIParticleEmitter
