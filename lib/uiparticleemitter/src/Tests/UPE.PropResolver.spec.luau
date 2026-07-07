--[[
	PropResolver coverage: Getter unwrapping, NumberRange rolling, neutral
	defaults, and Fire-override precedence.
]]

return function(tiniest)
	local Fusion = require("../../Fusion")
	local PropResolver = require("../PropResolver")

	local describe = tiniest.describe
	local test = tiniest.test
	local expect = tiniest.expect

	describe("Parse", function()
		test("passes constants through", function()
			expect(PropResolver.Parse(5)).is(5)
			expect(PropResolver.Parse("abc")).is("abc")
			expect(PropResolver.Parse(nil)).never_exists()
		end)

		test("calls generator functions", function()
			expect(PropResolver.Parse(function()
				return 42
			end)).is(42)
		end)

		test("peeks Fusion state objects", function()
			local scope = Fusion.scoped(Fusion)
			local value = scope:Value(7)
			expect(PropResolver.Parse(value)).is(7)
			Fusion.doCleanup(scope)
		end)

		test("calls a generator held inside a Fusion state object", function()
			local scope = Fusion.scoped(Fusion)
			local value = scope:Value(function()
				return "generated"
			end)
			expect(PropResolver.Parse(value)).is("generated")
			Fusion.doCleanup(scope)
		end)
	end)

	describe("ResolveRange", function()
		test("passes plain numbers through", function()
			expect(PropResolver.ResolveRange(3.5, Random.new(1))).is(3.5)
		end)

		test("rolls within a NumberRange", function()
			local rng = Random.new(123)
			for _ = 1, 20 do
				local rolled = PropResolver.ResolveRange(NumberRange.new(2, 4), rng)
				expect(rolled >= 2).is_true()
				expect(rolled <= 4).is_true()
			end
		end)

		test("is deterministic for the same seed", function()
			local a = PropResolver.ResolveRange(NumberRange.new(0, 100), Random.new(42))
			local b = PropResolver.ResolveRange(NumberRange.new(0, 100), Random.new(42))
			expect(a).is(b)
		end)

		test("collapses a zero-width range", function()
			expect(PropResolver.ResolveRange(NumberRange.new(5, 5), Random.new(1))).is(5)
		end)
	end)

	describe("ResolveSpawnParams", function()
		test("applies neutral defaults for empty props", function()
			local params = PropResolver.ResolveSpawnParams({}, nil, Random.new(1))
			expect(params.Size).is(Vector2.new(10, 10))
			expect(params.Color3).is(Color3.new(1, 1, 1))
			expect(params.Velocity).is(Vector2.zero)
			expect(params.Transparency).is(0)
			expect(params.Rotation).is(0)
			expect(params.RotationSpeed).is(0)
			expect(params.Image).never_exists()
			expect(params.SizeScale).never_exists()
			expect(params.LifeTime >= 2).is_true()
			expect(params.LifeTime <= 4).is_true()
		end)

		test("uses prop values over defaults", function()
			local params = PropResolver.ResolveSpawnParams({
				Size = Vector2.new(20, 5),
				Color3 = Color3.new(1, 0, 0),
				Velocity = function()
					return Vector2.new(1, 2)
				end,
				Transparency = 0.5,
				LifeTime = 3,
				Rotation = 45,
				RotationSpeed = NumberRange.new(10, 10),
				Image = "rbxassetid://1",
			}, nil, Random.new(1))
			expect(params.Size).is(Vector2.new(20, 5))
			expect(params.Color3).is(Color3.new(1, 0, 0))
			expect(params.Velocity).is(Vector2.new(1, 2))
			expect(params.Transparency).is(0.5)
			expect(params.LifeTime).is(3)
			expect(params.Rotation).is(45)
			expect(params.RotationSpeed).is(10)
			expect(params.Image).is("rbxassetid://1")
		end)

		test("Fire overrides win over props", function()
			local props = {
				Size = Vector2.new(20, 5),
				Transparency = 0.5,
				Rotation = 45,
			}
			local overrides = {
				Size = Vector2.new(1, 1),
				Rotation = 90,
			}
			local params = PropResolver.ResolveSpawnParams(props, overrides, Random.new(1))
			expect(params.Size).is(Vector2.new(1, 1))
			expect(params.Rotation).is(90)
			-- Untouched keys still come from props
			expect(params.Transparency).is(0.5)
		end)

		test("keeps sequences unresolved for per-frame evaluation", function()
			local transparencySequence = NumberSequence.new(0, 1)
			local colorSequence = ColorSequence.new(Color3.new(), Color3.new(1, 1, 1))
			local sizeSequence = NumberSequence.new(0.5, 1)
			local params = PropResolver.ResolveSpawnParams({
				Transparency = transparencySequence,
				Color3 = colorSequence,
				SizeScale = sizeSequence,
			}, nil, Random.new(1))
			expect(params.Transparency).is(transparencySequence)
			expect(params.Color3).is(colorSequence)
			expect(params.SizeScale).is(sizeSequence)
		end)
	end)
end
