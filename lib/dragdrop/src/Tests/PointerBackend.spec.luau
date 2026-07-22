--[[
	Coverage for the pointer backend (mouse + touch), driven through the harness's
	fake input env — the same seam the real UserInputService/RenderStepped occupy in
	production. Exercises the gesture logic that has no other test surface:
	  - Mouse: drag-threshold lift, press-in-place click, drop hit-test, render follow.
	  - Touch: long-press lift, movement-slop scroll abort, drop, click, generation.
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
	local backend: any

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
		backend = harness:StartPointerBackend()
	end)

	after_each(function()
		harness:Destroy()
	end)

	--------------------------------------------------------------------------------
	describe("Mouse", function()
		test("press then move past the drag threshold lifts", function()
			const src = frame()
			registerSource(src, { Tags = { "Item" } })
			harness.HitList = { src }

			harness:MouseDown(Vector2.new(0, 0))
			expect(Core._api.GetState().Kind).is("Pending")

			harness:MouseMove(Vector2.new(20, 0)) -- 20px > 8px default threshold
			expect(Core.IsDragging()).is_true()
		end)

		test("a sub-threshold move does not lift", function()
			const src = frame()
			registerSource(src, { Tags = { "Item" } })
			harness.HitList = { src }

			harness:MouseDown(Vector2.new(0, 0))
			harness:MouseMove(Vector2.new(4, 0)) -- 4px < 8px
			expect(Core._api.GetState().Kind).is("Pending")
		end)

		test("press then release in place is a click, not a drag", function()
			const src = frame()
			local activated = 0
			registerSource(src, { Tags = { "Item" } }, {
				OnActivated = function()
					activated += 1
				end,
			})
			harness.HitList = { src }

			harness:MouseDown(Vector2.new(0, 0))
			harness:MouseUp(Vector2.new(0, 0))
			expect(activated).is(1)
			expect(Core._api.GetState().Kind).is("Idle")
		end)

		test("a press on empty space starts nothing", function()
			harness.HitList = {} -- nothing under the pointer
			harness:MouseDown(Vector2.new(0, 0))
			expect(Core._api.GetState().Kind).is("Idle")
		end)

		test("release over a compatible target drops on it", function()
			const src, dst = frame(), frame()
			local dropped = 0
			registerSource(src, { Tags = { "Item" } })
			registerTarget(dst, {
				Accepts = { "Item" },
				OnDrop = function()
					dropped += 1
				end,
			})

			harness.HitList = { src }
			harness:MouseDown(Vector2.new(0, 0))
			harness:MouseMove(Vector2.new(20, 0))
			expect(Core.IsDragging()).is_true()

			harness.HitList = { dst } -- pointer now over the target
			harness:MouseUp()
			expect(dropped).is(1)
			expect(Core.IsDragging()).never_is_true()
		end)

		test("render follows the pointer and re-hovers the target under it", function()
			const src, dst = frame(), frame()
			registerSource(src, { Tags = { "Item" } })
			registerTarget(dst, { Accepts = { "Item" } })

			harness.HitList = { src }
			harness:MouseDown(Vector2.new(0, 0))
			harness:MouseMove(Vector2.new(20, 0))

			harness.HitList = { dst }
			harness:MouseMove(Vector2.new(50, 0))
			harness:Render()

			expect(harness.LastGhost.Followed).is(Vector2.new(50, 0))
			expect(Core.GetHoveredTarget()).exists()
		end)

		test("a press while already dragging is ignored", function()
			const src1, src2 = frame(), frame()
			registerSource(src1, { Tags = { "Item" } })
			registerSource(src2, { Tags = { "Item" } })

			harness.HitList = { src1 }
			harness:MouseDown(Vector2.new(0, 0))
			harness:MouseMove(Vector2.new(20, 0))
			expect(Core.IsDragging()).is_true()

			harness.HitList = { src2 }
			harness:MouseDown(Vector2.new(0, 0)) -- second press, mid-drag
			const st = Core._api.GetState()
			assert(st.Kind == "Dragging", "expected the first drag to survive the second press")
			expect(st.Source.Instance).is(src1)
		end)
	end)

	--------------------------------------------------------------------------------
	describe("Touch", function()
		test("a long press lifts once the hold elapses", function()
			const src = frame()
			registerSource(src, { Tags = { "Item" } })
			harness.HitList = { src }

			harness:TouchStart(Vector2.new(0, 0))
			expect(Core._api.GetState().Kind).is("Pending")

			harness:Advance(0.4) -- LongPressSeconds default
			expect(Core.IsDragging()).is_true()
		end)

		test("moving past the slop before the hold aborts (treated as a scroll)", function()
			const src = frame()
			registerSource(src, { Tags = { "Item" } })
			harness.HitList = { src }

			const touch = harness:TouchStart(Vector2.new(0, 0))
			harness:TouchMove(touch, Vector2.new(20, 0)) -- 20px > 12px slop
			expect(Core._api.GetState().Kind).is("Idle")

			harness:Advance(0.4) -- the armed hold must not fire after abort
			expect(Core.IsDragging()).never_is_true()
		end)

		test("a sub-slop move does not abort the pending hold", function()
			const src = frame()
			registerSource(src, { Tags = { "Item" } })
			harness.HitList = { src }

			const touch = harness:TouchStart(Vector2.new(0, 0))
			harness:TouchMove(touch, Vector2.new(5, 0)) -- 5px < 12px
			expect(Core._api.GetState().Kind).is("Pending")

			harness:Advance(0.4)
			expect(Core.IsDragging()).is_true()
		end)

		test("release before the hold is a click, and the hold cannot fire afterward", function()
			const src = frame()
			local activated = 0
			registerSource(src, { Tags = { "Item" } }, {
				OnActivated = function()
					activated += 1
				end,
			})
			harness.HitList = { src }

			const touch = harness:TouchStart(Vector2.new(0, 0))
			harness:TouchEnd(touch)
			expect(activated).is(1)
			expect(Core._api.GetState().Kind).is("Idle")

			harness:Advance(0.4)
			expect(Core.IsDragging()).never_is_true()
		end)

		test("a lifted touch drag drops on the target under the release point", function()
			const src, dst = frame(), frame()
			local dropped = 0
			registerSource(src, { Tags = { "Item" } })
			registerTarget(dst, {
				Accepts = { "Item" },
				OnDrop = function()
					dropped += 1
				end,
			})

			harness.HitList = { src }
			const touch = harness:TouchStart(Vector2.new(0, 0))
			harness:Advance(0.4)
			expect(Core.IsDragging()).is_true()

			harness.HitList = { dst }
			harness:TouchMove(touch, Vector2.new(80, 0)) -- keep the touch position current
			harness:TouchEnd(touch, Vector2.new(80, 0))
			expect(dropped).is(1)
			expect(Core.IsDragging()).never_is_true()
		end)

		test("a second touch while one is pending is ignored", function()
			const src1, src2 = frame(), frame()
			registerSource(src1, { Tags = { "Item" } })
			registerSource(src2, { Tags = { "Item" } })

			harness.HitList = { src1 }
			harness:TouchStart(Vector2.new(0, 0))
			local st = Core._api.GetState()
			assert(st.Kind == "Pending", "expected the touch press to be pending")
			expect(st.Source.Instance).is(src1)

			harness.HitList = { src2 }
			harness:TouchStart(Vector2.new(0, 0)) -- second finger
			st = Core._api.GetState()
			assert(st.Kind == "Pending", "expected the first press to still be pending")
			expect(st.Source.Instance).is(src1)
		end)

		test("a released touch's stale hold does not disturb a later press", function()
			const src = frame()
			local lifts = 0
			registerSource(src, { Tags = { "Item" } }, {
				OnLift = function()
					lifts += 1
				end,
			})
			harness.HitList = { src }

			const first = harness:TouchStart(Vector2.new(0, 0))
			harness:TouchEnd(first) -- releases; first hold is now stale

			harness:TouchStart(Vector2.new(0, 0)) -- fresh press
			harness:Advance(0.4)
			expect(Core.IsDragging()).is_true()
			expect(lifts).is(1) -- only the fresh press lifted
		end)
	end)
end
