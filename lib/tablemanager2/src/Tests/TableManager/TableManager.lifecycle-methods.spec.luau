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
end
