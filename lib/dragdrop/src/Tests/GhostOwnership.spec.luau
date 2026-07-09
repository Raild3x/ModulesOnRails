--[[
	Coverage for the consolidated ghost ownership seam: the drag machine is the sole
	owner of the GhostHandle, and the device → placement-style decision
	(ghostStyleForDevice) lives in one place. Driven through the harness fake ghost:
	  - Pointer devices drive the ghost via Follow, and only ever Follow.
	  - Selection devices (gamepad/keyboard) drive it via Snap, and only ever Snap.
	  - The machine places a Follow ghost from a position REPORTED by the backend
	    (api.ReportPointer); that transition is inert on a Snap drag, so a backend can
	    never reach the ghost across the transition surface.
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

	const function frame(): Frame
		return Instance.new("Frame")
	end

	const function registerSource(instance: Instance, payload: any, extra: any?)
		const opts = extra or {}
		opts.GetPayload = opts.GetPayload or function()
			return payload
		end
		return Core.RegisterSource(instance :: any, opts)
	end

	before_each(function()
		harness = Harness.new()
	end)

	after_each(function()
		harness:Destroy()
	end)

	--------------------------------------------------------------------------------
	describe("Follow devices (pointer)", function()
		before_each(function()
			harness:StartPointerBackend()
		end)

		test("a mouse drag drives the ghost via Follow, never Snap", function()
			const src = frame()
			registerSource(src, { Tags = { "Item" } })
			harness.HitList = { src }

			harness:MouseDown(Vector2.new(0, 0))
			harness:MouseMove(Vector2.new(20, 0)) -- past threshold: lifts (Follow)
			expect(Core.IsDragging()).is_true()

			harness:MouseMove(Vector2.new(50, 0))
			harness:Render()

			-- The machine placed the ghost from the reported pointer position.
			expect(harness.LastGhost.Followed).is(Vector2.new(50, 0))
			expect(harness.LastGhost.Snapped).never_exists()
		end)

		test("the machine places the ghost from a reported pointer position", function()
			const src = frame()
			registerSource(src, { Tags = { "Item" } })
			harness.HitList = { src }

			harness:MouseDown(Vector2.new(0, 0))
			harness:MouseMove(Vector2.new(20, 0))
			expect(Core.IsDragging()).is_true()

			-- Report straight through the transition surface: the ghost follows it.
			Core._api.ReportPointer(Vector2.new(120, 80))
			expect(harness.LastGhost.Followed).is(Vector2.new(120, 80))
		end)
	end)

	--------------------------------------------------------------------------------
	describe("Snap devices (selection)", function()
		before_each(function()
			harness:StartSelectionBackend()
		end)

		-- Enter grab mode on a selected source for the given lift key.
		const function grab(src: Instance, liftKey: Enum.KeyCode)
			registerSource(src, { Tags = { "Item" } })
			harness:SetSelected(src)
			harness:PressKey(liftKey)
		end

		test("a gamepad grab drives the ghost via Snap, never Follow", function()
			harness.CurrentClass = "Gamepad"
			grab(frame(), Enum.KeyCode.ButtonX) -- GamepadLiftKeyCode default
			expect(Core.IsDragging()).is_true()

			expect(harness.LastGhost.Snapped).exists()
			expect(harness.LastGhost.Followed).never_exists()
		end)

		test("a keyboard grab drives the ghost via Snap, never Follow", function()
			grab(frame(), Enum.KeyCode.Return) -- KeyboardLiftKeyCode default, MouseKeyboard class
			expect(Core.IsDragging()).is_true()

			expect(harness.LastGhost.Snapped).exists()
			expect(harness.LastGhost.Followed).never_exists()
		end)

		test("ReportPointer is inert on a Snap drag, so the backend cannot reach the ghost", function()
			harness.CurrentClass = "Gamepad"
			grab(frame(), Enum.KeyCode.ButtonX)
			expect(Core.IsDragging()).is_true()

			Core._api.ReportPointer(Vector2.new(200, 200))
			expect(harness.LastGhost.Followed).never_exists() -- still never followed
		end)
	end)
end
