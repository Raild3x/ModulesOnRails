--!strict
--[[
	Teardown / removal coverage for the For* reconcilers (ForMap). The existing
	for-map suite covers subscribe + incremental change, but not:
	  * disconnecting a connection while items are still live (teardownAll),
	  * a value fully leaving a ForValues multiset (the counts[value] == nil
	    removal pass),
	  * a duplicate count shrinking (while #list > count),
	  * reconciling a keyed path whose value is not a table (early return),
	  * the double-Disconnect no-op guard.
]]

return function(t: tiniest)
	local TableManager = require("../../TableManager")

	local test = t.test
	local describe = t.describe
	local expect = t.expect

	describe("ForValues teardown / removal", function()
		test("Disconnect tears down every live item (teardownAll)", function()
			local manager = TableManager.new { items = { 1, 1, 2 } }
			local destroyed = 0

			local conn = manager:ForValues("items", function(itemJanitor)
				itemJanitor:Add(function()
					destroyed += 1
				end)
			end)
			expect(destroyed).is(0)

			conn:Disconnect()
			expect(destroyed).is(3) -- all three occurrences torn down

			manager:Destroy()
		end)

		test("a second Disconnect is a no-op", function()
			local manager = TableManager.new { items = { "a" } }
			local destroyed = 0

			local conn = manager:ForValues("items", function(itemJanitor)
				itemJanitor:Add(function()
					destroyed += 1
				end)
			end)

			conn:Disconnect()
			expect(destroyed).is(1)
			conn:Disconnect() -- guarded early return; must not re-run teardown
			expect(destroyed).is(1)

			manager:Destroy()
		end)

		test("a value fully leaving the array destroys its item (removal pass)", function()
			local manager = TableManager.new { items = { "x", "y" } }
			local destroyed: { [string]: number } = {}

			manager:ForValues("items", function(itemJanitor, value)
				itemJanitor:Add(function()
					destroyed[value] = (destroyed[value] or 0) + 1
				end)
			end)
			expect(destroyed.x).is(nil)

			manager:Set("items", { "y" }) -- "x" is gone entirely

			expect(destroyed.x).is(1)
			expect(destroyed.y).is(nil) -- "y" survives

			manager:Destroy()
		end)

		test("a shrinking duplicate count destroys the surplus occurrence", function()
			local manager = TableManager.new { items = { 1, 1 } }
			local destroyed = 0

			manager:ForValues("items", function(itemJanitor)
				itemJanitor:Add(function()
					destroyed += 1
				end)
			end)
			expect(destroyed).is(0)

			manager:Set("items", { 1 }) -- count for 1 drops 2 -> 1

			expect(destroyed).is(1) -- exactly one surplus occurrence removed

			manager:Destroy()
		end)
	end)

	describe("ForPairs teardown", function()
		test("Disconnect tears down every live keyed item (teardownAll)", function()
			local manager = TableManager.new { a = 1, b = 2 }
			local destroyed = 0

			local conn = manager:ForPairs({}, function(itemJanitor)
				itemJanitor:Add(function()
					destroyed += 1
				end)
			end)

			conn:Disconnect()
			expect(destroyed).is(2)

			manager:Destroy()
		end)

		test("reconciling a non-table value adds no items", function()
			local manager = TableManager.new { scalar = 5 }
			local addCount = 0

			-- The path resolves to a number, so the keyed reconciler bails after the
			-- (empty) removal pass without ever calling the handler.
			manager:ForPairs("scalar", function()
				addCount += 1
			end)
			expect(addCount).is(0)

			manager:Destroy()
		end)
	end)

	describe("For* options", function()
		test("FireForExisting = false suppresses the initial fire", function()
			local manager = TableManager.new { items = { 1, 2, 3 } }
			local addCount = 0

			manager:ForValues("items", function()
				addCount += 1
			end, { FireForExisting = false })

			-- No initial reconcile: the handler does not run for the three items
			-- already present at subscribe time.
			expect(addCount).is(0)
			task.wait()
			expect(addCount).is(0)

			-- The first actual change triggers a FULL reconcile, which catches up
			-- every value present at that point (1, 2, 3 and the newly added 4).
			manager:ArrayInsert("items", 4)
			expect(addCount).is(4)

			manager:Destroy()
		end)

		test("an options table without Defer still fires initially (immediate manager)", function()
			-- Exercises the `options.Defer` false side of the deferral check while
			-- options is present (FireForExisting defaults to true here).
			local manager = TableManager.new({ items = { 1, 2 } }, {
				ListenerFireMode = "immediate",
			})
			local addCount = 0

			manager:ForValues("items", function()
				addCount += 1
			end, { FireForExisting = true })

			expect(addCount).is(2) -- fired synchronously, no Defer

			manager:Destroy()
		end)

		test("ForValues on a scalar path tracks nothing", function()
			local manager = TableManager.new { scalar = 7 }
			local addCount = 0

			-- current is not a table, so the value multiset stays empty.
			manager:ForValues("scalar", function()
				addCount += 1
			end)
			expect(addCount).is(0)

			manager:Destroy()
		end)
	end)
end
