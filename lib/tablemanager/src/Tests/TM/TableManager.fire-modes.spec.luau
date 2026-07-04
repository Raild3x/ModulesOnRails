--!strict
--[[
	End-to-end coverage of the non-default fire modes, driven through a real
	TableManager (the ListenerRegistry suite already covers the modes at the
	registry level; these exercise the manager-level integration seams that the
	registry tests bypass):

	  * SignalFireMode = "deferred" / "coalesced" / "immediate" on the public
	    per-change Signals (Emitter.fireSignal / fireSignalCoalesced),
	  * ListenerFireMode != "immediate" deferring TableManager:Observe's initial
	    fire,
	  * For* initial-fire deferral via the `Defer` option and via a non-immediate
	    ListenerFireMode.

	These tests yield (`task.wait()`) to observe deferred/coalesced delivery,
	matching the idiom already used in ListenerRegistry.spec / CoalescedFlush.spec.
]]

return function(t: tiniest)
	local TableManager = require("../../TableManager")

	local test = t.test
	local describe = t.describe
	local expect = t.expect

	describe("SignalFireMode", function()
		test("'deferred' delivers the signal after a yield, not synchronously", function()
			local manager = TableManager.new({ player = { health = 100 } }, {
				SignalFireMode = "deferred",
			})

			local fired: { any } = {}
			local conn = manager.ValueChanged:Connect(function(_path, newValue)
				table.insert(fired, newValue)
			end)

			manager:Set({ "player", "health" }, 50)
			expect(#fired).is(0) -- deferred: nothing yet

			task.wait()
			expect(#fired).is(1)
			expect(fired[1]).is(50)

			conn:Disconnect()
			manager:Destroy()
		end)

		test("'coalesced' collapses repeated fires into one carrying latest new + first old", function()
			local manager = TableManager.new({ player = { health = 100 } }, {
				SignalFireMode = "coalesced",
			})

			local fireCount = 0
			local lastNew: any = nil
			local lastOld: any = nil
			local conn = manager.ValueChanged:Connect(function(_path, newValue, oldValue)
				fireCount += 1
				lastNew = newValue
				lastOld = oldValue
			end)

			manager:Set({ "player", "health" }, 75)
			manager:Set({ "player", "health" }, 50)
			expect(fireCount).is(0) -- nothing synchronous

			task.wait()
			expect(fireCount).is(1) -- two fires collapsed into one
			expect(lastNew).is(50) -- latest new value wins
			expect(lastOld).is(100) -- original old value preserved from the first fire

			conn:Disconnect()
			manager:Destroy()
		end)

		test("'coalesced' handles signals with no old-value arg (ArrayInserted)", function()
			-- ArrayInserted has no "OldValue"-style arg, so the coalesce merge takes
			-- the latest-wins path (getOldValueArgIndex -> nil).
			local manager = TableManager.new({ list = {} }, {
				SignalFireMode = "coalesced",
			})

			local fireCount = 0
			local conn = manager.ArrayInserted:Connect(function()
				fireCount += 1
			end)

			manager:ArrayInsert("list", "a")
			manager:ArrayInsert("list", "b")
			expect(fireCount).is(0)

			task.wait()
			expect(fireCount).is(1) -- collapsed

			conn:Disconnect()
			manager:Destroy()
		end)

		test("'immediate' delivers the signal synchronously", function()
			local manager = TableManager.new({ player = { health = 100 } }, {
				SignalFireMode = "immediate",
			})

			local fired: { any } = {}
			local conn = manager.ValueChanged:Connect(function(_path, newValue)
				table.insert(fired, newValue)
			end)

			manager:Set({ "player", "health" }, 50)
			expect(#fired).is(1) -- immediate: already delivered, no yield
			expect(fired[1]).is(50)

			conn:Disconnect()
			manager:Destroy()
		end)
	end)

	describe("Observe initial fire (ListenerFireMode)", function()
		test("defers the initial fire when the listener mode is not immediate", function()
			local manager = TableManager.new({ health = 100 }, {
				ListenerFireMode = "deferred",
			})

			local fired: { any } = {}
			manager:Observe("health", function(newValue)
				table.insert(fired, newValue)
			end)

			expect(#fired).is(0) -- deferred: initial fire hasn't run yet

			task.wait()
			expect(#fired).is(1)
			expect(fired[1]).is(100)

			manager:Destroy()
		end)

		test("fires the initial value synchronously in immediate mode", function()
			local manager = TableManager.new({ health = 100 }, {
				ListenerFireMode = "immediate",
			})

			local fired: { any } = {}
			manager:Observe("health", function(newValue)
				table.insert(fired, newValue)
			end)

			expect(#fired).is(1) -- immediate initial fire
			expect(fired[1]).is(100)

			manager:Destroy()
		end)
	end)

	describe("For* deferred initial fire", function()
		test("the Defer option defers the initial fire on an immediate manager", function()
			local manager = TableManager.new({ items = { 1, 2 } }, {
				ListenerFireMode = "immediate",
			})

			local added = 0
			manager:ForValues("items", function()
				added += 1
			end, { Defer = true })

			expect(added).is(0) -- Defer: initial reconcile is scheduled, not run

			task.wait()
			expect(added).is(2)

			manager:Destroy()
		end)

		test("a non-immediate listener mode defers the initial fire without the option", function()
			local manager = TableManager.new({ a = 1, b = 2 }, {
				ListenerFireMode = "deferred",
			})

			local seen = 0
			manager:ForKeys({}, function()
				seen += 1
			end)

			expect(seen).is(0) -- deferred by the registry's mode

			task.wait()
			expect(seen).is(2)

			manager:Destroy()
		end)
	end)
end
