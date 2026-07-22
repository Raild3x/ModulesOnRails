--[[
	Coverage for the drag state machine (driven through Core) and its edge-case fixes:
	  - BeginDrag refusal paths and the DragHandle lifecycle.
	  - Scroll-lock restore ordering (including a throwing OnDrop).
	  - Unregister / Destroying mid-drag (source and hovered target).
	  - Preferred-input class switch cancel (Dragging and Pending).
	  - ConsumeActivation window, Observe semantics, signals, reentrancy safety.
	  - The Pending → Dragging / click / abort transitions via the backend api.
	  - The input-class grouping that keeps mouse↔keyboard from cancelling.
]]

return function(t: tiniest)
	const Core = require("../Core")
	const InputUtil = require("../InputUtil")
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

	const function registerTarget(instance: Instance, extra: any?)
		const opts = extra or {}
		opts.OnDrop = opts.OnDrop or function() end
		return Core.RegisterTarget(instance :: any, opts)
	end

	before_each(function()
		harness = Harness.new()
	end)

	after_each(function()
		harness:Destroy()
	end)

	--------------------------------------------------------------------------------
	describe("BeginDrag refusals", function()
		before_each(function()
			Core.SetInputMode("Scriptable")
		end)

		test("refuses an unregistered instance", function()
			expect(Core.BeginDrag(frame())).never_exists()
		end)

		test("refuses when GetPayload returns nil", function()
			const src = frame()
			registerSource(src, nil, {
				GetPayload = function()
					return nil
				end,
			})
			expect(Core.BeginDrag(src)).never_exists()
		end)

		test("refuses while a drag is already active", function()
			const src1, src2 = frame(), frame()
			registerSource(src1, { Tags = { "A" } })
			registerSource(src2, { Tags = { "B" } })
			expect(Core.BeginDrag(src1)).exists()
			expect(Core.BeginDrag(src2)).never_exists()
		end)

		test("resolves a descendant of a registered source", function()
			const src = frame()
			const child = frame()
			child.Parent = src
			registerSource(src, { Tags = { "A" } })
			expect(Core.BeginDrag(child)).exists()
			expect(Core.IsDragging()).is_true()
		end)
	end)

	--------------------------------------------------------------------------------
	describe("DragHandle lifecycle", function()
		before_each(function()
			Core.SetInputMode("Scriptable")
		end)

		test("SetHoveredTarget(nil) clears the hover and reports success", function()
			const src, dst = frame(), frame()
			registerSource(src, { Tags = { "Item" } })
			registerTarget(dst, { Accepts = { "Item" } })
			const handle = Core.BeginDrag(src)
			expect(handle:SetHoveredTarget(dst)).is_true()
			expect(handle:SetHoveredTarget(nil)).is_true()
			expect(Core.GetHoveredTarget()).never_exists()
		end)

		test("GetPayload returns the carried payload", function()
			const src = frame()
			const payload = { Tags = { "Item" }, Guid = "abc" }
			registerSource(src, payload)
			const handle = Core.BeginDrag(src)
			expect(handle:GetPayload()).is(payload)
		end)

		test("methods no-op after the drag has ended", function()
			const src, dst = frame(), frame()
			registerSource(src, { Tags = { "Item" } })
			registerTarget(dst, { Accepts = { "Item" } })
			const handle = Core.BeginDrag(src)
			handle:Cancel() -- ends the drag
			expect(handle:IsActive()).never_is_true()
			expect(handle:SetHoveredTarget(dst)).never_is_true()
			expect(handle:Drop()).never_is_true()
		end)

		test("Drop returns false when nothing is hovered (revert)", function()
			const src = frame()
			registerSource(src, { Tags = { "Item" } })
			const handle = Core.BeginDrag(src)
			expect(handle:Drop()).never_is_true()
			expect(Core.IsDragging()).never_is_true()
		end)
	end)

	--------------------------------------------------------------------------------
	describe("Scroll-lock restore", function()
		before_each(function()
			Core.SetInputMode("Scriptable")
		end)

		test("locks ancestor scrolling for the drag and restores it on drop", function()
			const sf = Instance.new("ScrollingFrame")
			const src = frame()
			src.Parent = sf
			registerSource(src, { Tags = { "Item" } })
			expect(sf.ScrollingEnabled).is_true()

			Core.BeginDrag(src)
			expect(sf.ScrollingEnabled).never_is_true()

			Core.Drop()
			expect(sf.ScrollingEnabled).is_true()
		end)

		test("restores scrolling even when OnDrop throws", function()
			const sf = Instance.new("ScrollingFrame")
			const src = frame()
			const dst = frame()
			src.Parent = sf
			registerSource(src, { Tags = { "Item" } })
			registerTarget(dst, {
				Accepts = { "Item" },
				OnDrop = function()
					error("boom")
				end,
			})
			const handle = Core.BeginDrag(src)
			handle:SetHoveredTarget(dst)
			expect(handle:Drop()).is_true() -- drop still resolves to the valid target
			expect(sf.ScrollingEnabled).is_true() -- restored before the throwing callback ran
			expect(Core.IsDragging()).never_is_true()
		end)
	end)

	--------------------------------------------------------------------------------
	describe("Registration teardown mid-drag", function()
		before_each(function()
			Core.SetInputMode("Scriptable")
		end)

		test("unregistering the active source cancels the drag", function()
			const src = frame()
			const unregister = registerSource(src, { Tags = { "Item" } })
			Core.BeginDrag(src)
			expect(Core.IsDragging()).is_true()
			unregister()
			expect(Core.IsDragging()).never_is_true()
		end)

		test("destroying the active source cancels the drag", function()
			const src = frame()
			registerSource(src, { Tags = { "Item" } })
			Core.BeginDrag(src)
			src:Destroy()
			expect(Core.IsDragging()).never_is_true()
		end)

		test("unregistering the hovered target clears the hover", function()
			const src, dst = frame(), frame()
			registerSource(src, { Tags = { "Item" } })
			const unregisterTargetFn = registerTarget(dst, { Accepts = { "Item" } })
			const handle = Core.BeginDrag(src)
			handle:SetHoveredTarget(dst)
			expect(Core.GetHoveredTarget()).exists()
			unregisterTargetFn()
			expect(Core.GetHoveredTarget()).never_exists()
			expect(Core.IsDragging()).is_true()
		end)

		test("destroying the hovered target clears the hover", function()
			const src, dst = frame(), frame()
			registerSource(src, { Tags = { "Item" } })
			registerTarget(dst, { Accepts = { "Item" } })
			const handle = Core.BeginDrag(src)
			handle:SetHoveredTarget(dst)
			dst:Destroy()
			expect(Core.GetHoveredTarget()).never_exists()
			expect(Core.IsDragging()).is_true()
		end)
	end)

	--------------------------------------------------------------------------------
	describe("Preferred-input switch cancel", function()
		const function entryFor(instance: Instance)
			registerSource(instance, { Tags = { "Item" } })
			return Core._api.ResolveSource(instance)
		end

		test("a class switch cancels an active (non-controlled) drag", function()
			const entry = entryFor(frame())
			Core._api.Press(entry, Vector2.zero, nil, "Mouse")
			Core._api.Lift()
			expect(Core.IsDragging()).is_true()

			harness:SwitchInput("Touch")
			expect(Core.IsDragging()).never_is_true()
		end)

		test("a class switch aborts a pending press", function()
			const entry = entryFor(frame())
			Core._api.Press(entry, Vector2.zero, nil, "Mouse")
			expect(Core._api.GetState().Kind).is("Pending")

			harness:SwitchInput("Gamepad")
			expect(Core._api.GetState().Kind).is("Idle")
		end)
	end)

	--------------------------------------------------------------------------------
	describe("Backend transitions (api)", function()
		const function entryFor(instance: Instance)
			registerSource(instance, { Tags = { "Item" } })
			return Core._api.ResolveSource(instance)
		end

		test("Press then Lift enters Dragging", function()
			const entry = entryFor(frame())
			Core._api.Press(entry, Vector2.zero, nil, "Mouse")
			expect(Core._api.GetState().Kind).is("Pending")
			Core._api.Lift()
			expect(Core.IsDragging()).is_true()
		end)

		test("ReleaseAsClick fires OnActivated and returns to Idle", function()
			const src = frame()
			local activated = 0
			registerSource(src, { Tags = { "Item" } }, {
				OnActivated = function()
					activated += 1
				end,
			})
			const entry = Core._api.ResolveSource(src)
			Core._api.Press(entry, Vector2.zero, nil, "Mouse")
			Core._api.ReleaseAsClick()
			expect(activated).is(1)
			expect(Core._api.GetState().Kind).is("Idle")
		end)

		test("AbortPending returns to Idle without activating", function()
			const src = frame()
			local activated = 0
			registerSource(src, { Tags = { "Item" } }, {
				OnActivated = function()
					activated += 1
				end,
			})
			const entry = Core._api.ResolveSource(src)
			Core._api.Press(entry, Vector2.zero, nil, "Mouse")
			Core._api.AbortPending()
			expect(activated).is(0)
			expect(Core._api.GetState().Kind).is("Idle")
		end)

		test("Press with a nil payload stays Idle", function()
			const src = frame()
			registerSource(src, nil, {
				GetPayload = function()
					return nil
				end,
			})
			const entry = Core._api.ResolveSource(src)
			Core._api.Press(entry, Vector2.zero, nil, "Mouse")
			expect(Core._api.GetState().Kind).is("Idle")
		end)

		test("Press with a throwing GetPayload stays Idle", function()
			const src = frame()
			registerSource(src, nil, {
				GetPayload = function()
					error("nope")
				end,
			})
			const entry = Core._api.ResolveSource(src)
			Core._api.Press(entry, Vector2.zero, nil, "Mouse")
			expect(Core._api.GetState().Kind).is("Idle")
		end)
	end)

	--------------------------------------------------------------------------------
	describe("ConsumeActivation", function()
		before_each(function()
			Core.SetInputMode("Scriptable")
		end)

		test("is true immediately after a drag ends and false once the window passes", function()
			const src = frame()
			registerSource(src, { Tags = { "Item" } })
			const handle = Core.BeginDrag(src)
			handle:Cancel()
			expect(Core.ConsumeActivation()).is_true()
			harness:Advance(0.1)
			expect(Core.ConsumeActivation()).never_is_true()
		end)
	end)

	--------------------------------------------------------------------------------
	describe("State-change signals", function()
		before_each(function()
			Core.SetInputMode("Scriptable")
		end)

		test("ActivePayloadChanged fires on change, not on connect", function()
			const calls = {}
			const conn = Core.ActivePayloadChanged:Connect(function(payload)
				table.insert(calls, { Value = payload })
			end)
			expect(#calls).is(0) -- no fire on connect; seed from GetActivePayload instead

			const src = frame()
			const payload = { Tags = { "Item" } }
			registerSource(src, payload)
			const handle = Core.BeginDrag(src)
			expect(#calls).is(1)
			expect(calls[1].Value).is(payload)

			handle:Cancel()
			expect(#calls).is(2)
			expect(calls[2].Value).never_exists()

			conn:Disconnect()
			Core.BeginDrag(src)
			expect(#calls).is(2) -- no further calls after disconnect
		end)
	end)

	--------------------------------------------------------------------------------
	describe("Signals", function()
		before_each(function()
			Core.SetInputMode("Scriptable")
		end)

		test("DragStarted carries payload and source instance", function()
			const src = frame()
			const payload = { Tags = { "Item" } }
			registerSource(src, payload)
			local seenPayload, seenSource
			const conn = Core.DragStarted:Connect(function(p, s)
				seenPayload, seenSource = p, s
			end)
			Core.BeginDrag(src)
			conn:Disconnect()
			expect(seenPayload).is(payload)
			expect(seenSource).is(src)
		end)

		test("Dropped and DragEnded carry the target descriptor on a valid drop", function()
			const src, dst = frame(), frame()
			const payload = { Tags = { "Item" } }
			registerSource(src, payload)
			registerTarget(dst, { Accepts = { "Item" }, Metadata = { Index = 7 } })
			local droppedDescriptor, endedDescriptor
			const c1 = Core.Dropped:Connect(function(_p, target)
				droppedDescriptor = target
			end)
			const c2 = Core.DragEnded:Connect(function(_p, target)
				endedDescriptor = target
			end)
			const handle = Core.BeginDrag(src)
			handle:SetHoveredTarget(dst)
			handle:Drop()
			c1:Disconnect()
			c2:Disconnect()
			expect(droppedDescriptor).exists()
			expect(droppedDescriptor.Metadata.Index).is(7)
			expect(endedDescriptor).exists()
		end)

		test("DragEnded carries a nil target on cancel", function()
			const src = frame()
			registerSource(src, { Tags = { "Item" } })
			local endedWith: any = "unset"
			const conn = Core.DragEnded:Connect(function(_p, target)
				endedWith = target
			end)
			const handle = Core.BeginDrag(src)
			handle:Cancel()
			conn:Disconnect()
			expect(endedWith).never_exists()
		end)
	end)

	--------------------------------------------------------------------------------
	describe("Reentrancy safety", function()
		before_each(function()
			Core.SetInputMode("Scriptable")
		end)

		test("calling Cancel from within OnDragEnd is safe", function()
			const src = frame()
			local ran = false
			registerSource(src, { Tags = { "Item" } }, {
				OnDragEnd = function()
					ran = true
					Core.Cancel() -- must be a no-op, state already reset
				end,
			})
			const handle = Core.BeginDrag(src)
			handle:Cancel()
			expect(ran).is_true()
			expect(Core.IsDragging()).never_is_true()
		end)

		test("calling Cancel from within OnDrop is safe", function()
			const src, dst = frame(), frame()
			registerSource(src, { Tags = { "Item" } })
			registerTarget(dst, {
				Accepts = { "Item" },
				OnDrop = function()
					Core.Cancel()
				end,
			})
			const handle = Core.BeginDrag(src)
			handle:SetHoveredTarget(dst)
			expect(handle:Drop()).is_true()
			expect(Core.IsDragging()).never_is_true()
		end)
	end)

	--------------------------------------------------------------------------------
	describe("Input-class grouping", function()
		test("mouse and keyboard share one class (so they never cancel each other)", function()
			expect(InputUtil.ClassifyInputType(Enum.UserInputType.MouseButton1)).is("MouseKeyboard")
			expect(InputUtil.ClassifyInputType(Enum.UserInputType.Keyboard)).is("MouseKeyboard")
		end)

		test("touch and gamepad are distinct classes", function()
			expect(InputUtil.ClassifyInputType(Enum.UserInputType.Touch)).is("Touch")
			expect(InputUtil.ClassifyInputType(Enum.UserInputType.Gamepad1)).is("Gamepad")
		end)

		test("an unmapped input type classifies as nil (never forces a cancel)", function()
			expect(InputUtil.ClassifyInputType(Enum.UserInputType.Focus)).never_exists()
		end)

		test("CurrentInputClass reports a known class", function()
			const class = InputUtil.CurrentInputClass()
			expect(class == "MouseKeyboard" or class == "Touch" or class == "Gamepad").is_true()
		end)
	end)

	--------------------------------------------------------------------------------
	describe("Geometry helpers", function()
		test("GetBasePlayerGui returns an Instance", function()
			expect(InputUtil.GetBasePlayerGui()).is_a("Instance")
		end)

		test("PointerLocation returns a Vector2", function()
			expect(InputUtil.PointerLocation()).is_a("Vector2")
		end)

		test("GuiObjectsAt returns a table", function()
			expect(InputUtil.GuiObjectsAt(Vector2.zero)).is_a("table")
		end)
	end)

	--------------------------------------------------------------------------------
	describe("Programmatic control surface", function()
		before_each(function()
			Core.SetInputMode("Scriptable")
		end)

		test("MoveTo positions the ghost and resolves hover via hit-test", function()
			const src, dst = frame(), frame()
			registerSource(src, { Tags = { "Item" } })
			registerTarget(dst, { Accepts = { "Item" } })
			harness.HitList = { dst } -- what GuiObjectsAt returns for the moved-to point

			const handle = Core.BeginDrag(src, Vector2.new(10, 10)) -- pointer-controlled
			expect(handle).exists()
			handle:MoveTo(Vector2.new(40, 40))
			expect(Core.GetHoveredTarget()).exists()
			expect(harness.LastGhost.Followed).is(Vector2.new(40, 40) - Vector2.zero)
		end)

		test("GetActivePayload reflects the airborne payload", function()
			const src = frame()
			const payload = { Tags = { "Item" } }
			registerSource(src, payload)
			expect(Core.GetActivePayload()).never_exists()
			const handle = Core.BeginDrag(src)
			expect(Core.GetActivePayload()).is(payload)
			handle:Cancel()
			expect(Core.GetActivePayload()).never_exists()
		end)

		test("HoveredTargetChanged fires on change, not on connect", function()
			const src, dst = frame(), frame()
			registerSource(src, { Tags = { "Item" } })
			registerTarget(dst, { Accepts = { "Item" } })
			const calls = {}
			const conn = Core.HoveredTargetChanged:Connect(function(target)
				table.insert(calls, { Value = target })
			end)
			expect(#calls).is(0) -- no fire on connect

			const handle = Core.BeginDrag(src)
			handle:SetHoveredTarget(dst)
			expect(#calls).is(1)
			expect(calls[1].Value).exists()
			conn:Disconnect()
		end)

		test("Drop and Cancel are no-ops when idle", function()
			expect(Core.Drop()).never_is_true()
			expect(Core.Cancel()).never_exists()
		end)
	end)

	--------------------------------------------------------------------------------
	describe("Input mode", function()
		test("rejects an invalid mode", function()
			expect(function()
				Core.SetInputMode("Weird" :: any)
			end).fails_with("Invalid input mode")
		end)

		test("setting the current mode again is a no-op", function()
			expect(Core.GetInputMode()).is("Automatic")
			Core.SetInputMode("Automatic")
			expect(Core.GetInputMode()).is("Automatic")
		end)

		test("switching to Scriptable cancels any active drag", function()
			const src = frame()
			registerSource(src, { Tags = { "Item" } })
			Core._api.Press(Core._api.ResolveSource(src), Vector2.zero, nil, "Mouse")
			Core._api.Lift()
			expect(Core.IsDragging()).is_true()
			Core.SetInputMode("Scriptable")
			expect(Core.IsDragging()).never_is_true()
		end)
	end)
end
