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

		test("Set({}, newTable) replaces the root without proxies", function()
			local manager = TableManager.new({ a = 1, b = 2 }, { EnableProxies = false })

			local rootChanges = 0
			local conn = manager:OnChange({}, function()
				rootChanges += 1
			end)

			manager:Set({}, { a = 10, c = 3 })

			expect(manager:Get("a")).is(10)
			expect(manager:Get("b")).is(nil)
			expect(manager:Get("c")).is(3)
			expect(manager.Raw).is(manager:Get({}))
			expect(rootChanges > 0).is(true)

			conn:Disconnect()
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
					{ EnableProxies = false, DuplicateReferenceMode = "copy" }
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

		-- These exercise `TableManager._NotifyApplied` (the LinkGroup fan-out replay
		-- path) when `_proxyManager == nil`. The proxy-key-shift step must no-op
		-- cleanly on a proxyless receiver while the op still converges and re-fires
		-- the receiver's listeners/signals.
		test("linked proxyless managers fan out a scalar Set", function()
			local shared = { player = { health = 100 } }
			local a = TableManager.new(shared, { EnableProxies = false })
			local b = TableManager.new(shared, { EnableProxies = false })

			TableManager.Link({ { a }, { b } })

			local bNew, bOld
			b:OnValueChange({ "player", "health" }, function(newValue, oldValue)
				bNew, bOld = newValue, oldValue
			end)

			a:Set({ "player", "health" }, 50)

			expect(b.Raw.player.health).is(50)
			expect(bNew).is(50)
			expect(bOld).is(100)

			a:Destroy()
			b:Destroy()
		end)

		test("linked proxyless managers fan out array insert/remove/set", function()
			local shared = { items = { "A", "B", "C" } }
			local a = TableManager.new(shared, { EnableProxies = false })
			local b = TableManager.new(shared, { EnableProxies = false })

			TableManager.Link({ { a }, { b } })

			local inserted = {}
			local removed = {}
			local setOps = {}
			b:OnArrayInsert({ "items" }, function(index, newValue)
				table.insert(inserted, { index, newValue })
			end)
			b:OnArrayRemove({ "items" }, function(index, oldValue)
				table.insert(removed, { index, oldValue })
			end)
			b:OnArraySet({ "items" }, function(index, newValue, oldValue)
				table.insert(setOps, { index, newValue, oldValue })
			end)

			-- ArrayInsert fan-out hits the "ArrayInsert" branch of _NotifyApplied.
			a:ArrayInsert({ "items" }, 1, "X")
			expect(b:Get { "items" }).is_shallow_equal { "X", "A", "B", "C" }
			expect(#inserted).is(1)
			expect(inserted[1][1]).is(1)
			expect(inserted[1][2]).is("X")

			-- ArrayRemove fan-out hits the "ArrayRemove" branch.
			a:ArrayRemove({ "items" }, 2)
			expect(b:Get { "items" }).is_shallow_equal { "X", "B", "C" }
			expect(#removed).is(1)
			expect(removed[1][1]).is(2)

			-- ArraySwapRemove emits an ArraySet (backfill) + ArrayRemoved, exercising
			-- the "ArraySet" branch on the proxyless receiver.
			a:ArraySwapRemove({ "items" }, 1)
			expect(b:Get { "items" }).is_shallow_equal { "C", "B" }
			expect(#setOps).is(1)
			expect(setOps[1][1]).is(1)
			expect(setOps[1][2]).is("C")

			a:Destroy()
			b:Destroy()
		end)

		test("mixed proxied + proxyless link fans out array ops both directions", function()
			local shared = { items = { "A", "B" } }
			local proxied = TableManager.new(shared)
			local proxyless = TableManager.new(shared, { EnableProxies = false })

			TableManager.Link({ { proxied }, { proxyless } })

			-- The proxied side holds a proxy that must stay coherent after an op that
			-- originates on the proxyless side fans out and runs ShiftKeys on the
			-- proxied receiver.
			local heldProxy = proxied:GetProxy { "items", 2 } -- "B"

			proxyless:ArrayInsert({ "items" }, 1, "X")
			expect(proxied:Get { "items" }).is_shallow_equal { "X", "A", "B" }
			expect((proxied:GetProxy { "items", 3 })).is(heldProxy)

			-- Reverse: an op on the proxied side fans out to the proxyless receiver,
			-- whose key-shift is a clean no-op.
			local proxylessInserted
			proxyless:OnArrayInsert({ "items" }, function(_index, newValue)
				proxylessInserted = newValue
			end)
			proxied:ArrayInsert({ "items" }, "Y")
			expect(proxyless:Get { "items" }).is_shallow_equal { "X", "A", "B", "Y" }
			expect(proxylessInserted).is("Y")

			proxied:Destroy()
			proxyless:Destroy()
		end)
	end)
end
