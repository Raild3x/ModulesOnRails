-- Authors: Logan Hunt (Raildex)
-- July 06, 2026
--[[
	Shared type definitions for UIParticleEmitter.
]]

local Fusion = require("../Fusion")

export type UsedAs<T> = Fusion.UsedAs<T>
export type Scope<T> = Fusion.Scope<T>

-- A value that may be a constant, a Fusion state object, or (once unwrapped)
-- a generator function producing a fresh value per particle.
export type Getter<T> = UsedAs<T | () -> T>

-- Wind may be a constant force or a function sampling the wind at a position.
export type WindSource = Vector2 | (pos: Vector2) -> Vector2

--------------------------------------------------------------------------------
-- Public API types
--------------------------------------------------------------------------------

export type EmitterProps = {
	Parent: UsedAs<Instance>?,
	SpawnAreaPosition: UsedAs<UDim2>?,
	SpawnAreaAnchorPoint: UsedAs<Vector2>?,
	SpawnAreaSize: UsedAs<UDim2>?,

	Enabled: UsedAs<boolean>?,
	Visible: UsedAs<boolean>?,
	TimeScale: UsedAs<number>?,
	Rate: Getter<number>?,

	Drag: UsedAs<number>?,
	Gravity: UsedAs<number>?,
	Wind: UsedAs<WindSource>?,

	Velocity: Getter<Vector2>?,
	Size: Getter<Vector2>?,
	SizeScale: Getter<number | NumberSequence>?,
	Color3: Getter<Color3 | ColorSequence>?,
	Image: Getter<string>?,
	Transparency: Getter<number | NumberSequence>?,
	LifeTime: Getter<number | NumberRange>?,
	Rotation: Getter<number | NumberRange>?,
	RotationSpeed: Getter<number | NumberRange>?,

	MaxParticles: UsedAs<number>?,
	CleanupParticlesImmediately: UsedAs<boolean>?,
	Seed: number?,
}

export type FireConfig = {
	Amount: Getter<number>?,

	Size: Getter<Vector2>?,
	SizeScale: Getter<number | NumberSequence>?,
	Color3: Getter<Color3 | ColorSequence>?,
	Image: Getter<string>?,
	Transparency: Getter<number | NumberSequence>?,
	LifeTime: Getter<number | NumberRange>?,
	Velocity: Getter<Vector2>?,
	Rotation: Getter<number | NumberRange>?,
	RotationSpeed: Getter<number | NumberRange>?,

	-- Optional spawn area overrides
	SpawnAreaPosition: Getter<UDim2>?,
	SpawnAreaAbsolutePosition: Getter<Vector2>?,
	SpawnAreaAnchorPoint: Getter<Vector2>?,
	SpawnAreaSize: Getter<UDim2>?,
}

export type UIParticleEmitter = {
	UI: Frame,
	Fire: (self: UIParticleEmitter, config: FireConfig?) -> (),
	Stop: (self: UIParticleEmitter) -> (),
	Clear: (self: UIParticleEmitter) -> (),
	GetParticleCount: (self: UIParticleEmitter) -> number,
}

--------------------------------------------------------------------------------
-- Internal types
--------------------------------------------------------------------------------

-- Fully-resolved per-particle spawn parameters (no getters/state objects left).
export type SpawnParams = {
	Size: Vector2,
	SizeScale: (number | NumberSequence)?,
	Color3: Color3 | ColorSequence,
	Image: string?,
	Velocity: Vector2,
	LifeTime: number,
	Transparency: number | NumberSequence,
	Rotation: number,
	RotationSpeed: number,
}

-- Resolved spawn area overrides for a Fire() burst.
export type SpawnAreaOverrides = {
	SpawnAreaPosition: UDim2?,
	SpawnAreaAbsolutePosition: Vector2?,
	SpawnAreaAnchorPoint: Vector2?,
	SpawnAreaSize: UDim2?,
}

-- A live particle. Numeric/simulation fields are plain data so the physics
-- step can be tested without touching the Instance.
export type Particle = {
	Instance: GuiObject,
	IsImage: boolean,
	Position: Vector2,
	Velocity: Vector2,
	LifeTime: number,
	InitialLifeTime: number,
	Rotation: number,
	RotationSpeed: number,
	BaseSize: Vector2,
	SizeScaleSequence: NumberSequence?,
	BaseColor: Color3?,
	ColorSequence: ColorSequence?,
	TransparencySequence: NumberSequence?,
	BaseTransparency: number?,
}

-- Per-step environment for the physics simulation.
export type SimulationEnv = {
	Drag: number,
	Gravity: Vector2,
	Wind: WindSource?,
}

return nil
