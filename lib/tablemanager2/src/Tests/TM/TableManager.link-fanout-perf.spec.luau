--!strict
--[[
	Tests for the linked fan-out optimizations (plan Part 2):

	- Phase A: a fanned-out write does NOT run a diff for a recipient that
	  observes nothing at that path (no listener/signal of its own would fire),
	  but the recipient's shadow is still kept current so a write IT later
	  originates fans out a correct oldValue.
	- Phase B: a recipient that DOES observe replays the origin's already-built
	  diff node instead of re-diffing — so the whole group costs one `Diff.diff`
	  per write, not one per member. Gated to "no opacity active on either side";
	  an opacity-active origin falls back to per-member re-diff, still correct.

	`Diff.diff` is monkeypatched to count real diff computations (ChangeDetector
	indexes `Diff.diff` at call time, so replacing the field is observed).
]]

return function(t: tiniest)
	const TableManager = require("../../TableManager")
	const Diff = require("../../Diff")

	const test = t.test
	const describe = t.describe
	const expect = t.expect

	-- Runs `fn`, returning how many times `Diff.diff` was called during it.
	-- Always restores the original, even if `fn` throws.
	const function countDiffsDuring(fn: () -> ()): number
		const real = Diff.diff
		local count = 0
		;(Diff :: any).diff = function(...)
			count += 1
			return real(...)
		end
		const ok, err = pcall(fn)
		;(Diff :: any).diff = real
		if not ok then
			error(err, 0)
		end
		return count
	end

	describe("Linked fan-out: Phase A (skip unobserved recipients)", function()
		test("a write to a slice no other member observes runs exactly ONE diff (origin only)", function()
			const shared = { inv = { gold = 0 }, stats = { hp = 100 } }
			const invMgr = TableManager.new(shared)
			const statsMgr = TableManager.new(shared)
			TableManager.Link({ { invMgr }, { statsMgr } })

			local invFires, statsFires = 0, 0
			invMgr:OnChange("inv", function()
				invFires += 1
			end)
			statsMgr:OnChange("stats", function()
				statsFires += 1
			end)

			const diffs = countDiffsDuring(function()
				invMgr:Set("inv.gold", 5)
			end)

			expect(diffs).is(1) -- origin diffs; statsMgr (observes only "stats") skips
			expect(invFires).is(1) -- origin's own ancestor listener still fires
			expect(statsFires).is(0) -- statsMgr observes nothing under "inv"

			invMgr:Destroy()
			statsMgr:Destroy()
		end)

		test("a skipped recipient's shadow stays current, so a write IT later originates fans out the right oldValue", function()
			const shared = { hp = 100 }
			const observer = TableManager.new(shared)
			const silent = TableManager.new(shared) -- never registers a listener
			TableManager.Link({ { observer }, { silent } })

			local observerOld: any
			observer:OnValueChange("hp", function(_newValue, oldValue)
				observerOld = oldValue
			end)

			-- observer writes; `silent` observes nothing → its fan-out diff is
			-- skipped, but its shadow must still advance to 50 via Materialize.
			observer:Set("hp", 50)
			expect((silent :: any)._shadow:Get({ "hp" })).is(50)

			-- Now `silent` originates a write. Its _doFlush reads old from its own
			-- shadow; if Phase A had wrongly skipped Materialize, this would be 100.
			silent:Set("hp", 25)
			expect(observerOld).is(50) -- correct prior value, not the stale 100

			observer:Destroy()
			silent:Destroy()
		end)

		test("a recipient observing via an ANCESTOR listener is NOT skipped", function()
			const shared = { nested = { deep = { val = 1 } } }
			const a = TableManager.new(shared)
			const b = TableManager.new(shared)
			TableManager.Link({ { a }, { b } })

			local bFires = 0
			b:OnChange("nested", function() -- ancestor of the changed leaf
				bFires += 1
			end)

			a:Set("nested.deep.val", 9)
			expect(bFires).is(1) -- ancestor coverage counts as observed

			a:Destroy()
			b:Destroy()
		end)
	end)

	describe("Linked fan-out: Phase B (reuse origin's diff node)", function()
		test("two members both observing one shared scalar cost ONE diff total", function()
			const shared = { hp = 100 }
			const a = TableManager.new(shared)
			const b = TableManager.new(shared)
			TableManager.Link({ { a }, { b } })

			local aNew, aOld, bNew, bOld
			a:OnValueChange("hp", function(newValue, oldValue)
				aNew, aOld = newValue, oldValue
			end)
			b:OnValueChange("hp", function(newValue, oldValue)
				bNew, bOld = newValue, oldValue
			end)

			const diffs = countDiffsDuring(function()
				a:Set("hp", 75)
			end)

			expect(diffs).is(1) -- origin diffs once; b replays the node, no re-diff
			expect(aNew).is(75)
			expect(aOld).is(100)
			expect(bNew).is(75)
			expect(bOld).is(100)

			a:Destroy()
			b:Destroy()
		end)

		test("reused-node dispatch delivers granular descendant events to the recipient", function()
			const shared = { profile = { name = "x", level = 1 } }
			const a = TableManager.new(shared)
			const b = TableManager.new(shared)
			TableManager.Link({ { a }, { b } })

			const bKeyChanges: { { key: any, new: any, old: any } } = {}
			b:OnKeyChange("profile", function(key, newValue, oldValue)
				table.insert(bKeyChanges, { key = key, new = newValue, old = oldValue })
			end)

			-- Replace the whole profile table with a structurally-different one;
			-- the recipient must still receive the per-key change for `level`.
			a:Set("profile", { name = "x", level = 2 })

			local sawLevel = false
			for _, c in bKeyChanges do
				if c.key == "level" then
					sawLevel = true
					expect(c.new).is(2)
					expect(c.old).is(1)
				end
			end
			expect(sawLevel).is(true)

			a:Destroy()
			b:Destroy()
		end)

		test("opacity active on the origin disengages reuse (recipient re-diffs) and stays correct", function()
			const shared = { flag = true }
			const a = TableManager.new(shared)
			const b = TableManager.new(shared)
			TableManager.Link({ { a }, { b } })

			-- Registering any opaque value in `a` activates a's opacity ctx
			-- (`GetOpaqueCtx() ~= nil`), so a's fan-out can no longer hand its
			-- diff node to `b` for reuse. (Done before b's listener exists, so
			-- this write fans out to nothing.)
			a:Set("blob", TableManager.Opaque({ stuff = 1 }))

			local bNew, bOld
			b:OnValueChange("flag", function(newValue, oldValue)
				bNew, bOld = newValue, oldValue
			end)

			const diffs = countDiffsDuring(function()
				a:Set("flag", false)
			end)

			-- origin (1) + b's fallback re-diff (1): reuse disengaged.
			expect(diffs).is(2)
			expect(bNew).is(false)
			expect(bOld).is(true)

			a:Destroy()
			b:Destroy()
		end)
	end)
end
