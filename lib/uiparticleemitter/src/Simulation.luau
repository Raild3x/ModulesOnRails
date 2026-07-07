-- Authors: Logan Hunt (Raildex)
-- July 06, 2026
--[[
	Pure particle physics and visual evaluation. `Step` mutates only the plain
	numeric fields of a particle table (never the Instance), so it can be
	tested deterministically. `ApplyVisuals` is the one place that writes the
	simulated state to the particle's GuiObject.
]]

local SequenceUtil = require("./SequenceUtil")
local Types = require("./Types")

local Simulation = {}

--[[
	Advances a particle's physics by `dt` seconds: position integration, drag,
	gravity, wind, rotation, and lifetime countdown.
]]
function Simulation.Step(particle: Types.Particle, dt: number, env: Types.SimulationEnv)
	particle.Position += particle.Velocity * dt

	particle.Velocity *= 1 - env.Drag * dt
	particle.Velocity += env.Gravity * dt

	local wind = env.Wind
	if wind then
		local windForce: Vector2 = if typeof(wind) == "function" then wind(particle.Position) else wind
		particle.Velocity += windForce * dt
	end

	particle.Rotation += particle.RotationSpeed * dt
	particle.LifeTime -= dt
end

--[[
	Returns the particle's normalized lifetime: 0 at spawn, 1 at death.
]]
function Simulation.GetNormalizedLifetime(particle: Types.Particle): number
	return 1 - math.clamp(particle.LifeTime / particle.InitialLifeTime, 0, 1)
end

--[[
	Computes the particle's current visual state (size, color, transparency)
	from its sequences at the current normalized lifetime. Pure.
]]
function Simulation.ComputeVisuals(particle: Types.Particle): (Vector2, Color3, number)
	local t = Simulation.GetNormalizedLifetime(particle)

	local size = particle.BaseSize
	if particle.SizeScaleSequence then
		size = size * SequenceUtil.EvaluateNumberSequence(particle.SizeScaleSequence, t)
	end

	local color: Color3
	if particle.ColorSequence then
		color = SequenceUtil.EvaluateColorSequence(particle.ColorSequence, t)
	else
		color = particle.BaseColor :: Color3
	end

	local transparency: number
	if particle.TransparencySequence then
		transparency = SequenceUtil.EvaluateNumberSequence(particle.TransparencySequence, t)
	else
		transparency = particle.BaseTransparency or 0
	end

	return size, color, transparency
end

--[[
	Writes the particle's simulated state to its GuiObject. `inset` is the
	LayerCollector's Y AbsolutePosition (GUI inset compensation).
]]
function Simulation.ApplyVisuals(particle: Types.Particle, inset: number)
	local size, color, transparency = Simulation.ComputeVisuals(particle)
	local instance = particle.Instance

	if particle.SizeScaleSequence then
		instance.Size = UDim2.fromOffset(size.X, size.Y)
	end

	if particle.RotationSpeed ~= 0 then
		instance.Rotation = particle.Rotation
	end

	if particle.IsImage then
		local imageLabel = instance :: ImageLabel
		imageLabel.ImageColor3 = color
		imageLabel.ImageTransparency = transparency
	else
		instance.BackgroundColor3 = color
		instance.BackgroundTransparency = transparency
	end

	instance.Position = UDim2.fromOffset(particle.Position.X, particle.Position.Y - inset)
end

return Simulation
