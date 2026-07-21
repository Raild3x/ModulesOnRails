--!strict

return function(t: tiniest)
	local TableManager = require("../../TableManager")

	local test = t.test
	local describe = t.describe
	local expect = t.expect

	describe("Method: Destroy", function()
		test("can destroy manager with active listeners and signals", function()
			local manager = TableManager.new {
				player = { health = 100 },
			}

			local listenerFired = false
			manager:OnValueChange({ "player", "health" }, function()
				listenerFired = true
			end)

			local signalConnection = manager.ValueChanged:Connect(function()
				listenerFired = true
			end)

			manager:Destroy()
			signalConnection:Disconnect()
			expect(listenerFired).never_is_true()
		end)

		test("destroy after writes does not throw", function()
			local manager = TableManager.new {
				player = { health = 100 },
			}

			manager.Proxy.player.health = 50

			local ok = pcall(function()
				manager:Destroy()
			end)

			expect(ok).is_true()
		end)

		test("destroy can be called twice safely", function()
			local manager = TableManager.new {
				player = { health = 100 },
			}

			local ok1 = pcall(function()
				manager:Destroy()
			end)
			local ok2 = pcall(function()
				manager:Destroy()
			end)

			expect(ok1).is_true()
			expect(ok2).is_true()
		end)
	end)

	describe("Method: OnDestroy", function()
		test("runs the callback when the manager is destroyed", function()
			local manager = TableManager.new { x = 1 }

			local fired = 0
			manager:OnDestroy(function()
				fired += 1
			end)

			expect(fired).is(0)
			manager:Destroy()
			expect(fired).is(1)
		end)

		test("the returned disconnect prevents the callback from firing", function()
			local manager = TableManager.new { x = 1 }

			local fired = false
			local disconnect = manager:OnDestroy(function()
				fired = true
			end)

			disconnect()
			manager:Destroy()

			expect(fired).never_is_true()
		end)

		test("runs every registered callback in order", function()
			local manager = TableManager.new { x = 1 }

			local order = {}
			manager:OnDestroy(function()
				table.insert(order, "a")
			end)
			manager:OnDestroy(function()
				table.insert(order, "b")
			end)

			manager:Destroy()

			expect(order).is_shallow_equal { "a", "b" }
		end)
	end)

	describe("Static: IsDestroyed", function()
		test("reports false while alive and true after Destroy", function()
			local manager = TableManager.new { x = 1 }

			expect(TableManager.IsDestroyed(manager)).never_is_true()
			manager:Destroy()
			expect(TableManager.IsDestroyed(manager)).is_true()
		end)

		test("the colon form still works after being destroyed", function()
			local manager = TableManager.new { x = 1 }
			manager:Destroy()

			expect(function()
				manager:IsDestroyed()
			end).never_fails()
		end)
	end)

	describe("Method: PromiseValue", function()
		test("stays pending until the value changes", function()
			local manager = TableManager.new { player = { health = 100 } }

			local prom = manager:PromiseValue { "player", "health" }
			-- The current value must not settle the promise (resolves on first change).
			expect(prom:getStatus()).is("Started")

			prom:cancel()
			manager:Destroy()
		end)

		test("resolves when the value first changes (no predicate)", function()
			local manager = TableManager.new { player = { health = 100 } }

			local prom = manager:PromiseValue { "player", "health" }
			manager:Set({ "player", "health" }, 90)

			expect(prom:getStatus()).is("Resolved")

			manager:Destroy()
		end)

		test("resolves synchronously when the current value already satisfies the predicate", function()
			-- PromiseValue's fast path (TableManager.luau:2035): the value already
			-- passes, so the promise resolves immediately without registering a
			-- listener.
			local manager = TableManager.new { hp = 0 }

			local prom = manager:PromiseValue("hp", function(value)
				return value <= 0
			end)

			expect(prom:getStatus()).is("Resolved")

			manager:Destroy()
		end)

		test("resolves only once the predicate is satisfied", function()
			local manager = TableManager.new { player = { health = 100 } }

			local prom = manager:PromiseValue({ "player", "health" }, function(value)
				return value <= 0
			end)

			manager:Set({ "player", "health" }, 50)
			expect(prom:getStatus()).is("Started") -- 50 does not satisfy value <= 0

			manager:Set({ "player", "health" }, 0)
			expect(prom:getStatus()).is("Resolved")

			manager:Destroy()
		end)

		test("cancelling disconnects the listener so a later change is inert", function()
			local manager = TableManager.new { hp = 100 }

			local prom = manager:PromiseValue("hp", function(value)
				return value == 1
			end)

			prom:cancel()
			expect(prom:getStatus()).is("Cancelled")

			-- Must not error or resolve now that the listener is gone.
			local ok = pcall(function()
				manager:Set("hp", 1)
			end)
			expect(ok).is_true()
			expect(prom:getStatus()).is("Cancelled")

			manager:Destroy()
		end)
	end)
end
