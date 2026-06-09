--!strict
return function(t: tiniest)
	local TableManager = require("../../TableManager")

	local test = t.test
	local describe = t.describe
	local expect = t.expect

	describe("Method: ArrayInsert", function()
		test("supports both path and proxy targets", function()
			local manager = TableManager.new {
				items = { "Sword" },
			}

			manager:ArrayInsert({ "items" }, "Shield")
			manager:ArrayInsert(manager.Proxy.items, "Potion")

			expect(manager.Proxy.items[1]).is("Sword")
			expect(manager.Proxy.items[2]).is("Shield")
			expect(manager.Proxy.items[3]).is("Potion")

			manager:Destroy()
		end)

		test("updates held proxy key after insert shift", function()
			local manager = TableManager.new {
				items = { { value = 10 } },
			}

			local heldProxy = manager.Proxy.items[1]
			expect(heldProxy).exists()

			local capturedPath = nil
			manager:OnValueChange({ "items", 2, "value" }, function(_new, _old, metadata)
				capturedPath = metadata.OriginPath
			end)

			manager:ArrayInsert({ "items" }, 1, { value = 99 })
			heldProxy.value = 42

			expect(manager:Get { "items", 2, "value" }).is(42)
			expect(capturedPath).exists()
			assert(capturedPath, "Expected capturedPath to be set in OnValueChange callback")
			expect(capturedPath[1]).is("items")
			expect(capturedPath[2]).is(2)
			expect(capturedPath[3]).is("value")

			manager:Destroy()
		end)

		test("notifies ancestors for array insert", function()
			local manager = TableManager.new {
				game = {
					players = { "Alice", "Bob" },
				},
			}

			local gameNotified = 0
			local gameKeyChanged = 0
			local originPath = nil

			manager:OnValueChange({ "game" }, function(_newValue, _oldValue, metadata)
				gameNotified += 1
				originPath = metadata.OriginPath
			end)

			manager:OnKeyChange({ "game" }, function(key, _newValue, _oldValue)
				gameKeyChanged += 1
				expect(key).is("players")
			end)

			manager:ArrayInsert({ "game", "players" }, "Charlie")

			expect(gameNotified).is(1)
			expect(gameKeyChanged).is(1)
			expect(originPath).exists()
			assert(originPath, "Expected originPath to be set in OnValueChange callback")
			expect(#originPath).is(3)

			manager:Destroy()
		end)

		test("does not shift proxies in sibling arrays", function()
			local manager = TableManager.new {
				a = { { value = 1 } },
				b = { { value = 2 } },
			}

			local bProxy1 = manager.Proxy.b[1]
			manager:ArrayInsert({ "a" }, 1, { value = 99 })

			bProxy1.value = 77
			expect(manager:Get { "b", 1, "value" }).is(77)

			manager:Destroy()
		end)

		test("fresh proxy access returns same object after index shift", function()
			local manager = TableManager.new {
				items = { { value = 10 } },
			}

			local heldProxy = manager.Proxy.items[1]
			manager:ArrayInsert({ "items" }, 1, { value = 99 })

			local freshProxy = manager.Proxy.items[2]
			expect(freshProxy).is(heldProxy)

			manager:Destroy()
		end)

		test("nested array insert updates deeply held proxy live path", function()
			local manager = TableManager.new {
				items = { { nested = { { v = 1 }, { v = 2 } } } },
			}

			local heldProxy = manager.Proxy.items[1].nested[2]
			expect(heldProxy).exists()

			manager:ArrayInsert(manager.Proxy.items[1].nested, 1, { v = 99 })
			heldProxy.v = 42

			expect(manager.Proxy.items[1].nested[1].v).is(99)
			expect(manager.Proxy.items[1].nested[3].v).is(42)

			manager:Destroy()
		end)

		test("tostring for held proxy reflects updated index after insert", function()
			local manager = TableManager.new {
				items = { { value = 1 } },
			}

			local heldProxy = manager.Proxy.items[1]
			expect(tostring(heldProxy)).is("TableManager.Data(items.1)")

			manager:ArrayInsert({ "items" }, 1, { value = 99 })
			expect(tostring(heldProxy)).is("TableManager.Data(items.2)")

			manager:Destroy()
		end)

		test("iteration after insert shift yields current keys", function()
			local manager = TableManager.new {
				items = { { v = 1 }, { v = 2 } },
			}

			local _ = manager.Proxy.items[1]
			manager:ArrayInsert({ "items" }, 1, { v = 0 })

			local keys = {}
			for k in manager.Proxy.items do
				table.insert(keys, k)
			end
			table.sort(keys)

			expect(#keys).is(3)
			expect(keys[1]).is(1)
			expect(keys[2]).is(2)
			expect(keys[3]).is(3)

			manager:Destroy()
		end)
	end)

	describe("Method: ArrayRemove", function()
		test("supports both path and proxy targets", function()
			local manager = TableManager.new {
				items = { "Sword", "Shield", "Potion" },
			}

			local removedByPath = manager:ArrayRemove({ "items" }, 1)
			local removedByProxy = manager:ArrayRemove(manager.Proxy.items, 1)

			expect(removedByPath).is("Sword")
			expect(removedByProxy).is("Shield")
			expect(manager.Proxy.items[1]).is("Potion")
			expect(manager.Proxy.items[2]).is(nil)

			manager:Destroy()
		end)

		test("updates held proxy key after remove shift", function()
			local manager = TableManager.new {
				items = { { value = 0 }, { value = 20 } },
			}

			local heldProxy = manager.Proxy.items[2]
			expect(heldProxy).exists()

			local capturedPath = nil
			manager:OnValueChange({ "items", 1, "value" }, function(_new, _old, metadata)
				capturedPath = metadata.OriginPath
			end)

			manager:ArrayRemove({ "items" }, 1)
			heldProxy.value = 77

			expect(manager:Get { "items", 1, "value" }).is(77)
			assert(capturedPath, "Expected capturedPath to be set in OnValueChange callback")
			expect(capturedPath[1]).is("items")
			expect(capturedPath[2]).is(1)
			expect(capturedPath[3]).is("value")

			manager:Destroy()
		end)

		test("notifies ancestors for array remove", function()
			local manager = TableManager.new {
				game = {
					players = { "Alice", "Bob", "Charlie" },
				},
			}

			local notifiedCount = 0
			manager:OnValueChange({ "game" }, function()
				notifiedCount += 1
			end)

			manager:ArrayRemove({ "game", "players" }, 2)
			expect(notifiedCount).is(1)

			manager:Destroy()
		end)

		test("dead proxy after remove does not corrupt live array", function()
			local manager = TableManager.new {
				items = { { value = 10 }, { value = 20 } },
			}

			local deadProxy = manager.Proxy.items[1]
			local survivorProxy = manager.Proxy.items[2]

			manager:ArrayRemove({ "items" }, 1)
			expect(manager:Get { "items", 1, "value" }).is(20)

			deadProxy.value = 999
			expect(survivorProxy.value).is(20)
			expect(manager:Get { "items", 1, "value" }).is(20)

			manager:Destroy()
		end)

		test("multiple inserts then remove preserve accumulated held proxy shift", function()
			local manager = TableManager.new {
				items = { { value = 10 } },
			}

			local heldProxy = manager.Proxy.items[1]
			manager:ArrayInsert({ "items" }, 1, { value = 1 })
			manager:ArrayInsert({ "items" }, 1, { value = 2 })
			manager:ArrayInsert({ "items" }, 1, { value = 3 })

			heldProxy.value = 99

			expect(manager:Get { "items", 4, "value" }).is(99)
			expect(manager:Get { "items", 1, "value" }).is(3)
			expect(manager:Get { "items", 2, "value" }).is(2)
			expect(manager:Get { "items", 3, "value" }).is(1)

			manager:Destroy()
		end)

		test("table.remove on proxy array is rejected", function()
			local manager = TableManager.new {
				items = { "Sword", "Shield" },
			}

			expect(function()
				table.remove(manager.Proxy.items, 1)
			end).fails_with("invalid argument #1 to 'remove' %(table expected, got userdata%)")

			expect(manager.Proxy.items[1]).is("Sword")
			expect(manager.Proxy.items[2]).is("Shield")
			expect(manager.Proxy.items[3]).is(nil)

			manager:Destroy()
		end)

		test("removing from one array does not shift held proxy in sibling array", function()
			local manager = TableManager.new {
				a = { { value = 1 }, { value = 2 } },
				b = { { value = 10 }, { value = 20 } },
			}

			local heldB = manager.Proxy.b[2]
			manager:ArrayRemove({ "a" }, 1)

			heldB.value = 77
			expect(manager:Get { "b", 2, "value" }).is(77)

			manager:Destroy()
		end)
	end)
end
