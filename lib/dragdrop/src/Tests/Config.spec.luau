--[[
	Coverage for Configure(): partial merge, unknown-key and wrong-type rejection,
	and the LayerCollector validation on GhostContainer. Config is a process
	singleton, so each test resets it via the harness teardown.
]]

return function(t: tiniest)
	const Core = require("../Core")
	const Harness = require("./Helpers/Harness")

	const describe = t.describe
	const test = t.test
	const expect = t.expect
	const before_each = t.before_each
	const after_each = t.after_each

	local harness: any

	before_each(function()
		harness = Harness.new()
	end)

	after_each(function()
		harness:Destroy()
	end)

	describe("Configure", function()
		test("merges a partial config over the defaults", function()
			expect(function()
				Core.Configure { DragThresholdPx = 20 }
			end).never_fails()
			-- Applying an unrelated key afterwards must not error either.
			expect(function()
				Core.Configure { LongPressSeconds = 0.25 }
			end).never_fails()
		end)

		test("accepts EnumItem keycodes and a LayerCollector container", function()
			const gui = Instance.new("ScreenGui")
			expect(function()
				Core.Configure {
					GamepadLiftKeyCode = Enum.KeyCode.ButtonY,
					KeyboardCancelKeyCode = Enum.KeyCode.Escape,
					GhostContainer = gui,
				}
			end).never_fails()
		end)

		test("rejects an unknown key", function()
			expect(function()
				Core.Configure({ Nonsense = 5 } :: any)
			end).fails_with("Unknown config key")
		end)

		test("rejects a wrong value type", function()
			expect(function()
				Core.Configure({ DragThresholdPx = "big" } :: any)
			end).fails_with("must be a number")
		end)

		test("rejects a non-LayerCollector container", function()
			expect(function()
				Core.Configure({ GhostContainer = Instance.new("Frame") } :: any)
			end).fails_with("must be a LayerCollector")
		end)

		test("rejects a non-table argument", function()
			expect(function()
				Core.Configure(42 :: any)
			end).fails()
		end)

		test("ResetConfig restores defaults and clears optional keys", function()
			Core.Configure {
				DragThresholdPx = 42,
				GhostContainer = Instance.new("ScreenGui"),
			}
			expect(Core._api.GetConfig("DragThresholdPx")).is(42)
			expect(Core._api.GetConfig("GhostContainer")).exists()

			Core.ResetConfig()
			expect(Core._api.GetConfig("DragThresholdPx")).is(8)
			expect(Core._api.GetConfig("GhostContainer")).never_exists()
		end)
	end)
end
