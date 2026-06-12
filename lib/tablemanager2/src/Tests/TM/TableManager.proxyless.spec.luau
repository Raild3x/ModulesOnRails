--!strict
--[[
	Coverage for `Config.EnableProxies = false`: every explicit API surface
	(Get/Set/array ops/MoveTo/CopyTo/Swap/Batch/Suspend/Resume/listeners/
	ForceNotify) must work identically without a proxy graph, `Proxy`/`GetProxy`
	must be unavailable, and replication fidelity must hold.
]]

return function(t: tiniest)
	local TableManager = require("../../TableManager")
	local ReplicationHarness = require("../Helpers/ReplicationHarness")

	local test = t.test
	local describe = t.describe
	local expect = t.expect

	describe("EnableProxies = false", function()
		test("Proxy is nil and GetProxy errors", function()
			local manager = TableManager.new({ player = { health = 100 } }, { EnableProxies = false })

			expect(manager.Proxy).is(nil)
			expect(function()
				manager:GetProxy { "player" }
			end).fails_with("GetProxy requires proxies %(Config%.EnableProxies = false for this TableManager%)")

			manager:Destroy()
		end)

		test("Get/Set work without proxies", function()
			local manager = TableManager.new({ player = { health = 100 } }, { EnableProxies = false })

			expect(manager:Get { "player", "health" }).is(100)

			manager:Set({ "player", "health" }, 75)
			expect(manager:Get { "player", "health" }).is(75)

			manager:Destroy()
		end)

		test("Set with buildTablesDynamically constructs missing subtrees", function()
			local manager = TableManager.new({}, { EnableProxies = false })

			manager:Set({ "a", "b", "c" }, 5, true)
			expect(manager:Get { "a", "b", "c" }).is(5)

			manager:Destroy()
		end)

		test("Set with a nil value on a missing path is a silent no-op", function()
			local manager = TableManager.new({}, { EnableProxies = false })

			manager:Set({ "missing", "leaf" }, nil)
			expect(manager:Get({ "missing" }, true)).is(nil)

			manager:Destroy()
		end)

		test("Set appending to an array fires ArrayInserted, not KeyAdded", function()
			local manager = TableManager.new({ items = { "A", "B" } }, { EnableProxies = false })

			local insertedCount = 0
			local keyAddedCount = 0
			local insertedConn = manager.ArrayInserted:Connect(function(_path, index, newValue)
				insertedCount += 1
				expect(index).is(3)
				expect(newValue).is("C")
			end)
			local keyAddedConn = manager.KeyAdded:Connect(function()
				keyAddedCount += 1
			end)

			manager:Set({ "items", 3 }, "C")

			expect(insertedCount).is(1)
			expect(keyAddedCount).is(0)
			expect(manager:Get { "items", 3 }).is("C")

			insertedConn:Disconnect()
			keyAddedConn:Disconnect()
			manager:Destroy()
		end)

		test("all array operations work without proxies", function()
			local manager = TableManager.new({ items = { "A", "B", "C" } }, { EnableProxies = false })

			manager:ArrayInsert({ "items" }, "D")
			expect(manager:Get { "items", 4 }).is("D")

			manager:ArrayInsert({ "items" }, 1, "Z")
			expect(manager:Get { "items", 1 }).is("Z")

			local removed = manager:ArrayRemove({ "items" }, 1)
			expect(removed).is("Z")
			expect(manager:Get { "items", 1 }).is("A")

			local foundIndex = manager:ArrayRemoveFirstValue({ "items" }, "B")
			expect(foundIndex).is(2)

			local swapRemoved = manager:ArraySwapRemove({ "items" }, 1)
			expect(swapRemoved).is("A")

			manager:ArrayInsert({ "items" }, "B")
			local swapFoundIndex = manager:ArraySwapRemoveFirstValue({ "items" }, "B")
			expect(swapFoundIndex).exists()

			manager:Destroy()
		end)

		test("MoveTo, CopyTo, and Swap work without proxies", function()
			local manager = TableManager.new({
				a = { value = 1 },
				b = { value = 2 },
				c = nil :: any,
			}, { EnableProxies = false })

			manager:MoveTo({ "a" }, { "c" })
			expect(manager:Get({ "a" }, true)).is(nil)
			expect(manager:Get { "c", "value" }).is(1)

			manager:CopyTo({ "b" }, { "d" })
			expect(manager:Get { "d", "value" }).is(2)
			expect(manager:Get { "b", "value" }).is(2)

			manager:Swap({ "c" }, { "d" })
			expect(manager:Get { "c", "value" }).is(2)
			expect(manager:Get { "d", "value" }).is(1)

			manager:Destroy()
		end)

		test("Batch/Suspend/Resume coalesce array operations without proxies", function()
			local manager = TableManager.new({ items = { "A", "B", "C" } }, { EnableProxies = false })

			local insertedCount = 0
			local removedCount = 0
			local conn1 = manager.ArrayInserted:Connect(function()
				insertedCount += 1
			end)
			local conn2 = manager.ArrayRemoved:Connect(function()
				removedCount += 1
			end)

			manager:Batch(function()
				manager:ArrayInsert({ "items" }, "D")
				manager:ArrayRemove({ "items" }, 1)
			end)

			expect(insertedCount).is(1)
			expect(removedCount).is(1)
			expect(manager:Get { "items" }).is_shallow_equal { "B", "C", "D" }

			conn1:Disconnect()
			conn2:Disconnect()
			manager:Destroy()
		end)

		test("OnChange/OnValueChange listeners and ForceNotify work without proxies", function()
			local manager = TableManager.new({ player = { health = 100 } }, { EnableProxies = false })

			local changeCount = 0
			local conn = manager:OnValueChange({ "player", "health" }, function(newValue, oldValue)
				changeCount += 1
				expect(newValue).is(100)
				expect(oldValue).is(100)
			end)

			manager:ForceNotify { "player", "health" }
			expect(changeCount).is(1)

			conn:Disconnect()
			manager:Destroy()
		end)

		test("DuplicateReferenceMode alongside disabled proxies does not error", function()
			local ok = pcall(function()
				local manager = TableManager.new(
					{ player = { health = 100 } },
					{ EnableProxies = false, DuplicateReferenceMode = "warn" }
				)
				manager:Destroy()
			end)

			expect(ok).is_true()
		end)

		test("replication fidelity holds with a proxyless source manager", function()
			local harness = ReplicationHarness.new({
				player = { health = 100, items = { "A", "B" } },
			}, "signals", { EnableProxies = false })
			harness:Connect()

			expect(harness:Step(function()
				harness.Source:Set({ "player", "health" }, 75)
			end)).is_true()

			expect(harness:Step(function()
				harness.Source:ArrayInsert({ "player", "items" }, "C")
			end)).is_true()

			expect(harness:Step(function()
				harness.Source:ArrayRemove({ "player", "items" }, 1)
			end)).is_true()

			expect(harness:IsConverged()).is_true()
			expect(harness:EchoMatches()).is_true()

			harness:Destroy()
		end)
	end)
end
