--[[
	Coverage for the selection backend (gamepad + keyboard "grab mode"), driven
	through the harness's fake input env (SelectedObject, InputBegan, and the CAS
	bind/fire seam). Exercises the modal grab flow that has no other test surface:
	  - Lift key on a selected source enters grab mode.
	  - Selection changes move the hover (and clear it off non-targets).
	  - Drop / cancel actions act only during a drag and only on Begin, and Sink.
	  - Drop/cancel binds live only for the duration of a drag.
]]

return function(t: tiniest)
	const Controller = require("../Controller")
	const Harness = require("./Helpers/Harness")

	const describe = t.describe
	const test = t.test
	const expect = t.expect
	const before_each = t.before_each
	const after_each = t.after_each

	-- Action names the selection backend binds (stable internal identifiers).
	const DROP_ACTION = "DragDropSelectionDrop"
	const CANCEL_ACTION = "DragDropSelectionCancel"

	local harness: any
	local backend: any

	const function frame(): Frame
		return Instance.new("Frame")
	end

	const function registerSource(instance: Instance, payload: any, extra: any?)
		const opts = extra or {}
		opts.GetPayload = opts.GetPayload or function()
			return payload
		end
		return Controller.RegisterSource(instance :: any, opts)
	end

	const function registerTarget(instance: Instance, extra: any?)
		const opts = extra or {}
		opts.OnDrop = opts.OnDrop or function() end
		return Controller.RegisterTarget(instance :: any, opts)
	end

	before_each(function()
		harness = Harness.new()
		backend = harness:StartSelectionBackend()
	end)

	after_each(function()
		harness:Destroy()
	end)

	--------------------------------------------------------------------------------
	describe("Gamepad grab mode", function()
		before_each(function()
			harness.CurrentClass = "Gamepad"
		end)

		-- Enters grab mode on a selected source and returns the carried target.
		const function grab(src: Instance)
			harness:SetSelected(src)
			harness:PressKey(Enum.KeyCode.ButtonX) -- GamepadLiftKeyCode default
		end

		test("the lift key on a selected source enters grab mode", function()
			const src = frame()
			registerSource(src, { Tags = { "Item" } })
			grab(src)
			expect(Controller.IsDragging()).is_true()
		end)

		test("drop and cancel actions are bound only during the drag", function()
			const src = frame()
			registerSource(src, { Tags = { "Item" } })

			expect(harness:IsActionBound(DROP_ACTION)).never_is_true()
			grab(src)
			expect(harness:IsActionBound(DROP_ACTION)).is_true()
			expect(harness:IsActionBound(CANCEL_ACTION)).is_true()

			harness:FireAction(DROP_ACTION)
			expect(harness:IsActionBound(DROP_ACTION)).never_is_true()
			expect(harness:IsActionBound(CANCEL_ACTION)).never_is_true()
		end)

		test("moving the selection onto a target hovers it", function()
			const src, dst = frame(), frame()
			registerSource(src, { Tags = { "Item" } })
			registerTarget(dst, { Accepts = { "Item" } })

			grab(src)
			harness:SetSelected(dst)
			const hovered = Controller.GetHoveredTarget()
			expect(hovered).exists()
			expect(hovered.Instance).is(dst)
		end)

		test("moving the selection off a target clears the hover", function()
			const src, dst, empty = frame(), frame(), frame()
			registerSource(src, { Tags = { "Item" } })
			registerTarget(dst, { Accepts = { "Item" } })

			grab(src)
			harness:SetSelected(dst)
			expect(Controller.GetHoveredTarget()).exists()

			harness:SetSelected(empty) -- not a registered target
			expect(Controller.GetHoveredTarget()).never_exists()
		end)

		test("the drop action drops on the selected target and sinks the input", function()
			const src, dst = frame(), frame()
			local dropped = 0
			registerSource(src, { Tags = { "Item" } })
			registerTarget(dst, {
				Accepts = { "Item" },
				OnDrop = function()
					dropped += 1
				end,
			})

			grab(src)
			harness:SetSelected(dst)
			const result = harness:FireAction(DROP_ACTION)
			expect(dropped).is(1)
			expect(Controller.IsDragging()).never_is_true()
			expect(result).is(Enum.ContextActionResult.Sink)
		end)

		test("the cancel action reverts the drag without dropping", function()
			const src, dst = frame(), frame()
			local dropped = 0
			registerSource(src, { Tags = { "Item" } })
			registerTarget(dst, {
				Accepts = { "Item" },
				OnDrop = function()
					dropped += 1
				end,
			})

			grab(src)
			harness:SetSelected(dst)
			harness:FireAction(CANCEL_ACTION)
			expect(dropped).is(0)
			expect(Controller.IsDragging()).never_is_true()
		end)

		test("an action on a non-Begin state passes through and does not drop", function()
			const src, dst = frame(), frame()
			local dropped = 0
			registerSource(src, { Tags = { "Item" } })
			registerTarget(dst, {
				Accepts = { "Item" },
				OnDrop = function()
					dropped += 1
				end,
			})

			grab(src)
			harness:SetSelected(dst)
			const result = harness:FireAction(DROP_ACTION, Enum.UserInputState.End)
			expect(result).is(Enum.ContextActionResult.Pass)
			expect(dropped).is(0)
			expect(Controller.IsDragging()).is_true()
		end)

		test("stopping the backend mid-drag unbinds its actions", function()
			const src = frame()
			registerSource(src, { Tags = { "Item" } })
			grab(src)
			expect(harness:IsActionBound(DROP_ACTION)).is_true()

			backend.Stop()
			expect(harness:IsActionBound(DROP_ACTION)).never_is_true()
		end)
	end)

	--------------------------------------------------------------------------------
	describe("Keyboard grab mode", function()
		test("the keyboard lift key enters grab mode", function()
			const src = frame()
			registerSource(src, { Tags = { "Item" } })
			harness:SetSelected(src)
			harness:PressKey(Enum.KeyCode.Return) -- KeyboardLiftKeyCode default
			expect(Controller.IsDragging()).is_true()
			expect(harness:IsActionBound(DROP_ACTION)).is_true()
		end)

		test("the lift key does nothing with no selection", function()
			harness:SetSelected(nil)
			harness:PressKey(Enum.KeyCode.Return)
			expect(Controller.IsDragging()).never_is_true()
		end)

		test("the lift key does nothing on an unregistered selection", function()
			harness:SetSelected(frame()) -- never registered as a source
			harness:PressKey(Enum.KeyCode.Return)
			expect(Controller.IsDragging()).never_is_true()
		end)

		test("a non-lift key is ignored", function()
			const src = frame()
			registerSource(src, { Tags = { "Item" } })
			harness:SetSelected(src)
			harness:PressKey(Enum.KeyCode.Space)
			expect(Controller.IsDragging()).never_is_true()
		end)
	end)
end
