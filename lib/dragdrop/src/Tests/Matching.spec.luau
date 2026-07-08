--[[
	Coverage for payload/target compatibility: the payload's `Tags` list against
	the target's `Accepts` (share at least one tag; empty/nil Accepts takes any),
	and the CanDrop gate (including a throwing predicate). Driven through
	Scriptable mode so hover/drop are decided purely by the compatibility logic.
]]

return function(t: tiniest)
	const Controller = require("../Controller")
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

	-- Register a source producing `payload`, a target with the given options,
	-- begin a scriptable drag, and return the handle + a `dropped` recorder set
	-- by the target's OnDrop.
	const function scenario(payload: any, targetOptions: any)
		const dropped = { Count = 0, Payload = nil :: any }
		const src = frame()
		const dst = frame()
		Controller.RegisterSource(src, {
			GetPayload = function()
				return payload
			end,
		})
		const opts = table.clone(targetOptions)
		const userOnDrop = opts.OnDrop
		opts.OnDrop = function(p: any, target: any)
			dropped.Count += 1
			dropped.Payload = p
			if userOnDrop then
				userOnDrop(p, target)
			end
		end
		Controller.RegisterTarget(dst, opts)
		const handle = Controller.BeginDrag(src)
		return handle, dst, dropped
	end

	before_each(function()
		harness = Harness.new()
		Controller.SetInputMode("Scriptable")
	end)

	after_each(function()
		harness:Destroy()
	end)

	describe("Tags × Accepts", function()
		test("accepts when a single tag matches", function()
			const handle, dst, dropped = scenario({ Tags = { "Item" } }, { Accepts = { "Item" } })
			expect(handle:SetHoveredTarget(dst)).is_true()
			expect(Controller.GetHoveredTarget()).exists()
			expect(handle:Drop()).is_true()
			expect(dropped.Count).is(1)
		end)

		test("rejects when no tag matches", function()
			const handle, dst, dropped = scenario({ Tags = { "Item" } }, { Accepts = { "Food" } })
			expect(handle:SetHoveredTarget(dst)).never_is_true()
			expect(Controller.GetHoveredTarget()).never_exists()
			expect(handle:Drop()).never_is_true()
			expect(dropped.Count).is(0)
		end)

		test("accepts when any of several tags matches", function()
			const handle, dst = scenario({ Tags = { "Item", "Food" } }, { Accepts = { "Food" } })
			expect(handle:SetHoveredTarget(dst)).is_true()
		end)

		test("rejects a multi-tag payload with no shared tag", function()
			const handle, dst = scenario({ Tags = { "Item", "Weapon" } }, { Accepts = { "Food" } })
			expect(handle:SetHoveredTarget(dst)).never_is_true()
		end)

		test("a payload with no tags is rejected by a filtered target", function()
			const handle, dst = scenario({ Tags = {} }, { Accepts = { "Item" } })
			expect(handle:SetHoveredTarget(dst)).never_is_true()
		end)

		test("a payload with no tags still matches an accept-any target", function()
			const handle, dst = scenario({ Tags = {} }, {})
			expect(handle:SetHoveredTarget(dst)).is_true()
		end)

		test("a target with no Accepts takes any payload", function()
			const handle, dst = scenario({ Tags = { "Anything" } }, {})
			expect(handle:SetHoveredTarget(dst)).is_true()
		end)

		test("a target with an empty Accepts also takes any payload", function()
			const handle, dst = scenario({ Tags = { "Item" } }, { Accepts = {} })
			expect(handle:SetHoveredTarget(dst)).is_true()
		end)
	end)

	describe("CanDrop gate", function()
		test("blocks a drop when CanDrop returns false", function()
			const handle, dst, dropped = scenario({ Tags = { "Item" } }, {
				Accepts = { "Item" },
				CanDrop = function()
					return false
				end,
			})
			expect(handle:SetHoveredTarget(dst)).never_is_true()
			expect(handle:Drop()).never_is_true()
			expect(dropped.Count).is(0)
		end)

		test("allows a drop when CanDrop returns true", function()
			const handle, dst = scenario({ Tags = { "Item" } }, {
				Accepts = { "Item" },
				CanDrop = function()
					return true
				end,
			})
			expect(handle:SetHoveredTarget(dst)).is_true()
		end)

		test("treats a throwing CanDrop as a rejection (no crash)", function()
			const handle, dst = scenario({ Tags = { "Item" } }, {
				Accepts = { "Item" },
				CanDrop = function()
					error("boom")
				end,
			})
			expect(handle:SetHoveredTarget(dst)).never_is_true()
		end)
	end)
end
