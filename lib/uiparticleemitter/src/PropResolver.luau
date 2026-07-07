-- Authors: Logan Hunt (Raildex)
-- July 06, 2026
--[[
	Resolves emitter props / Fire() overrides into concrete per-particle spawn
	parameters. This is the single place where Getter values are unwrapped,
	NumberRanges are rolled, and neutral defaults are applied — shared by both
	the continuous spawn loop and manual Fire() bursts.
]]

local Fusion = require("../Fusion")
local Types = require("./Types")

local peek = Fusion.peek

type Getter<T> = Types.Getter<T>

local PropResolver = {}

-- Neutral defaults, modeled after Roblox's ParticleEmitter conventions.
-- The confetti look from the original component lives in Presets.Confetti.
PropResolver.Defaults = {
	Size = Vector2.new(10, 10),
	Color3 = Color3.new(1, 1, 1),
	Velocity = Vector2.zero,
	Transparency = 0,
	LifeTime = NumberRange.new(2, 4),
	Rotation = 0,
	RotationSpeed = 0,
	Rate = 5,
	Drag = 0.95,
	Gravity = 500,
	MaxParticles = 1000,
}

--[[
	Unwraps a Getter<T>: peeks through Fusion state objects, then calls the
	result if it is a generator function.
]]
function PropResolver.Parse<T>(getter: Getter<T>): T
	local v = peek(getter)
	if typeof(v) == "function" then
		return v()
	end
	return v
end

--[[
	Resolves a `number | NumberRange` into a concrete number, rolling within
	the range using the provided Random instance.
]]
function PropResolver.ResolveRange(value: number | NumberRange, rng: Random): number
	if typeof(value) == "NumberRange" then
		return rng:NextNumber(value.Min, value.Max)
	end
	return value
end

local Parse = PropResolver.Parse
local ResolveRange = PropResolver.ResolveRange

--[[
	Resolves one particle's spawn parameters. `overrides` (from Fire) win over
	`props` (from the component), which win over the neutral defaults.
]]
function PropResolver.ResolveSpawnParams(
	props: Types.EmitterProps,
	overrides: Types.FireConfig?,
	rng: Random
): Types.SpawnParams
	local function pick(key: string): any
		if overrides and (overrides :: any)[key] ~= nil then
			return (overrides :: any)[key]
		end
		return (props :: any)[key]
	end

	local defaults = PropResolver.Defaults

	local size: Vector2 = Parse(pick("Size")) or defaults.Size
	local sizeScale: (number | NumberSequence)? = Parse(pick("SizeScale"))
	local color: Color3 | ColorSequence = Parse(pick("Color3")) or defaults.Color3
	local image: string? = Parse(pick("Image"))
	local velocity: Vector2 = Parse(pick("Velocity")) or defaults.Velocity
	local transparency: number | NumberSequence = Parse(pick("Transparency")) or defaults.Transparency

	local lifetime = Parse(pick("LifeTime"))
	if lifetime == nil then
		lifetime = defaults.LifeTime
	end
	local rotation = Parse(pick("Rotation"))
	if rotation == nil then
		rotation = defaults.Rotation
	end
	local rotationSpeed = Parse(pick("RotationSpeed"))
	if rotationSpeed == nil then
		rotationSpeed = defaults.RotationSpeed
	end

	return {
		Size = size,
		SizeScale = sizeScale,
		Color3 = color,
		Image = image,
		Velocity = velocity,
		Transparency = transparency,
		LifeTime = ResolveRange(lifetime, rng),
		Rotation = ResolveRange(rotation, rng),
		RotationSpeed = ResolveRange(rotationSpeed, rng),
	}
end

return PropResolver
