--[[
	Simulation coverage: deterministic physics stepping on plain particle
	tables, normalized-lifetime math, and visual computation/application.
]]

return function(tiniest)
	local Simulation = require("../Simulation")

	local describe = tiniest.describe
	local test = tiniest.test
	local expect = tiniest.expect

	local function approx(a: number, b: number): boolean
		return math.abs(a - b) < 1e-4
	end

	local function approxV2(a: Vector2, b: Vector2): boolean
		return approx(a.X, b.X) and approx(a.Y, b.Y)
	end

	-- Builds a minimal particle table; simulation fields only (no Instance
	-- needed for Step/ComputeVisuals).
	local function makeParticle(overrides: { [string]: any }?)
		local particle = {
			Instance = nil :: any,
			IsImage = false,
			Position = Vector2.zero,
			Velocity = Vector2.zero,
			LifeTime = 2,
			InitialLifeTime = 2,
			Rotation = 0,
			RotationSpeed = 0,
			BaseSize = Vector2.new(10, 10),
			BaseColor = Color3.new(1, 1, 1),
		}
		for key, value in overrides or {} do
			(particle :: any)[key] = value
		end
		return particle
	end

	local NO_FORCES = { Drag = 0, Gravity = Vector2.zero, Wind = nil }

	describe("Step", function()
		test("integrates position from velocity", function()
			local particle = makeParticle { Velocity = Vector2.new(10, -5) }
			Simulation.Step(particle, 1, NO_FORCES)
			expect(approxV2(particle.Position, Vector2.new(10, -5))).is_true()
		end)

		test("applies drag as a per-second decay", function()
			local particle = makeParticle { Velocity = Vector2.new(100, 0) }
			Simulation.Step(particle, 0.1, { Drag = 0.5, Gravity = Vector2.zero })
			expect(approxV2(particle.Velocity, Vector2.new(95, 0))).is_true()
		end)

		test("accumulates gravity", function()
			local particle = makeParticle()
			Simulation.Step(particle, 0.1, { Drag = 0, Gravity = Vector2.new(0, 500) })
			expect(approxV2(particle.Velocity, Vector2.new(0, 50))).is_true()
		end)

		test("applies constant wind", function()
			local particle = makeParticle()
			Simulation.Step(particle, 0.5, { Drag = 0, Gravity = Vector2.zero, Wind = Vector2.new(20, 0) })
			expect(approxV2(particle.Velocity, Vector2.new(10, 0))).is_true()
		end)

		test("samples functional wind at the particle position", function()
			local sampledAt: Vector2? = nil
			local particle = makeParticle { Position = Vector2.new(3, 4) }
			Simulation.Step(particle, 1, {
				Drag = 0,
				Gravity = Vector2.zero,
				Wind = function(pos: Vector2)
					sampledAt = pos
					return Vector2.new(1, 1)
				end,
			})
			expect(sampledAt).is(Vector2.new(3, 4))
			expect(approxV2(particle.Velocity, Vector2.new(1, 1))).is_true()
		end)

		test("advances rotation by rotation speed", function()
			local particle = makeParticle { RotationSpeed = 90 }
			Simulation.Step(particle, 0.5, NO_FORCES)
			expect(approx(particle.Rotation, 45)).is_true()
		end)

		test("counts down lifetime", function()
			local particle = makeParticle { LifeTime = 2 }
			Simulation.Step(particle, 0.25, NO_FORCES)
			expect(approx(particle.LifeTime, 1.75)).is_true()
		end)
	end)

	describe("GetNormalizedLifetime", function()
		test("is 0 at spawn and 1 at death", function()
			expect(Simulation.GetNormalizedLifetime(makeParticle { LifeTime = 2, InitialLifeTime = 2 })).is(0)
			expect(Simulation.GetNormalizedLifetime(makeParticle { LifeTime = 0, InitialLifeTime = 2 })).is(1)
		end)

		test("is 0.5 at half life and clamps out-of-range values", function()
			expect(Simulation.GetNormalizedLifetime(makeParticle { LifeTime = 1, InitialLifeTime = 2 })).is(0.5)
			expect(Simulation.GetNormalizedLifetime(makeParticle { LifeTime = -1, InitialLifeTime = 2 })).is(1)
			expect(Simulation.GetNormalizedLifetime(makeParticle { LifeTime = 5, InitialLifeTime = 2 })).is(0)
		end)
	end)

	describe("ComputeVisuals", function()
		test("uses base values when no sequences are present", function()
			local size, color, transparency = Simulation.ComputeVisuals(makeParticle {
				BaseColor = Color3.new(1, 0, 0),
				BaseTransparency = 0.25,
			})
			expect(size).is(Vector2.new(10, 10))
			expect(color).is(Color3.new(1, 0, 0))
			expect(transparency).is(0.25)
		end)

		test("defaults transparency to 0 when unset", function()
			local _, _, transparency = Simulation.ComputeVisuals(makeParticle())
			expect(transparency).is(0)
		end)

		test("evaluates sequences at the normalized lifetime", function()
			local particle = makeParticle {
				LifeTime = 1,
				InitialLifeTime = 2,
				SizeScaleSequence = NumberSequence.new(1, 2),
				ColorSequence = ColorSequence.new(Color3.new(0, 0, 0), Color3.new(1, 1, 1)),
				TransparencySequence = NumberSequence.new(0, 1),
				BaseColor = nil,
			}
			local size, color, transparency = Simulation.ComputeVisuals(particle)
			expect(approxV2(size, Vector2.new(15, 15))).is_true()
			expect(approx(color.R, 0.5)).is_true()
			expect(approx(transparency, 0.5)).is_true()
		end)
	end)

	describe("ApplyVisuals", function()
		test("writes position, color and transparency to a Frame", function()
			local frame = Instance.new("Frame")
			local particle = makeParticle {
				Instance = frame,
				Position = Vector2.new(100, 250),
				BaseColor = Color3.new(0, 1, 0),
				BaseTransparency = 0.5,
			}
			Simulation.ApplyVisuals(particle, 50)
			expect(frame.Position).is(UDim2.fromOffset(100, 200))
			expect(frame.BackgroundColor3).is(Color3.new(0, 1, 0))
			expect(frame.BackgroundTransparency).is(0.5)
			frame:Destroy()
		end)

		test("writes image properties for ImageLabel particles", function()
			local imageLabel = Instance.new("ImageLabel")
			local particle = makeParticle {
				Instance = imageLabel,
				IsImage = true,
				BaseColor = Color3.new(0, 0, 1),
				BaseTransparency = 0.75,
			}
			Simulation.ApplyVisuals(particle, 0)
			expect(imageLabel.ImageColor3).is(Color3.new(0, 0, 1))
			expect(imageLabel.ImageTransparency).is(0.75)
			imageLabel:Destroy()
		end)

		test("only writes Rotation when the particle spins", function()
			local frame = Instance.new("Frame")
			frame.Rotation = 15
			local still = makeParticle { Instance = frame, Rotation = 99, RotationSpeed = 0 }
			Simulation.ApplyVisuals(still, 0)
			expect(frame.Rotation).is(15)

			local spinning = makeParticle { Instance = frame, Rotation = 30, RotationSpeed = 10 }
			Simulation.ApplyVisuals(spinning, 0)
			expect(frame.Rotation).is(30)
			frame:Destroy()
		end)

		test("only writes Size when a size sequence is present", function()
			local frame = Instance.new("Frame")
			frame.Size = UDim2.fromOffset(1, 1)
			local static = makeParticle { Instance = frame }
			Simulation.ApplyVisuals(static, 0)
			expect(frame.Size).is(UDim2.fromOffset(1, 1))

			local animated = makeParticle {
				Instance = frame,
				LifeTime = 0,
				SizeScaleSequence = NumberSequence.new(2),
			}
			Simulation.ApplyVisuals(animated, 0)
			expect(frame.Size).is(UDim2.fromOffset(20, 20))
			frame:Destroy()
		end)
	end)
end
