--!strict

return function(t: tiniest)
	local TableManager = require("../../TableManager")

	local test = t.test
	local describe = t.describe
	local expect = t.expect

	describe("Method: OnKeyAdd", function()
		test("fires when a key is added", function()
			local manager = TableManager.new {
				player = { health = 100, mana = nil :: number? },
			}

			local fireCount = 0
			local addedValue = nil

			manager:OnKeyAdd({ "player" }, function(newValue)
				fireCount += 1
				addedValue = newValue
			end)

			manager.Proxy.player.mana = 50

			expect(fireCount).is(1)
			expect(addedValue).is(50)

			manager:Destroy()
		end)

		test("respects ListenDepth = 0 for descendant adds", function()
			local manager = TableManager.new {
				player = { stats = { level = nil :: number? } },
			}

			local fireCount = 0
			manager:OnKeyAdd({ "player" }, function()
				fireCount += 1
			end, { ListenDepth = 0 })

			manager.Proxy.player.stats.level = 10
			expect(fireCount).is(0)

			manager:Destroy()
		end)

		test("supports string path and matches KeyAdded signal payload", function()
			local manager = TableManager.new {
				player = { health = 100, energy = nil :: number? },
			}
			local managerAny: any = manager

			local listenerCount = 0
			local signalCount = 0
			local signalPath = nil
			local signalKey = nil
			local signalValue = nil

			managerAny:OnKeyAdd("player", function(newValue)
				listenerCount += 1
				expect(newValue).is(25)
			end)

			local conn = manager.KeyAdded:Connect(function(path, key, value)
				signalCount += 1
				signalPath = path
				signalKey = key
				signalValue = value
			end)

			manager.Proxy.player.energy = 25

			expect(listenerCount).is(1)
			expect(signalCount).is(1)
			expect(signalPath).is_shallow_equal { "player" }
			expect(signalKey).is("energy")
			expect(signalValue).is(25)

			conn:Disconnect()
			manager:Destroy()
		end)
	end)

	describe("Method: OnKeyRemove", function()
		test("fires when a key is removed", function()
			local manager = TableManager.new {
				player = { mana = 20 :: number? },
			}

			local fireCount = 0
			local removedValue = nil

			manager:OnKeyRemove({ "player" }, function(oldValue)
				fireCount += 1
				removedValue = oldValue
			end)

			manager.Proxy.player.mana = nil

			expect(fireCount).is(1)
			expect(removedValue).is(20)

			manager:Destroy()
		end)

		test("can remove a nested key under a root child", function()
			local manager = TableManager.new {
				settings = { volume = 80, quality = "high" :: string? },
			}

			local fireCount = 0
			manager:OnKeyRemove({ "settings" }, function()
				fireCount += 1
			end)

			manager.Proxy.settings.quality = nil
			expect(fireCount).is(1)

			manager:Destroy()
		end)

		test("supports string path and matches KeyRemoved signal payload", function()
			local manager = TableManager.new {
				player = { shield = 30 :: number? },
			}
			local managerAny: any = manager

			local listenerCount = 0
			local signalCount = 0
			local signalPath = nil
			local signalKey = nil
			local signalValue = nil

			managerAny:OnKeyRemove("player", function(oldValue)
				listenerCount += 1
				expect(oldValue).is(30)
			end)

			local conn = manager.KeyRemoved:Connect(function(path, key, oldValue)
				signalCount += 1
				signalPath = path
				signalKey = key
				signalValue = oldValue
			end)

			manager.Proxy.player.shield = nil

			expect(listenerCount).is(1)
			expect(signalCount).is(1)
			expect(signalPath).is_shallow_equal { "player" }
			expect(signalKey).is("shield")
			expect(signalValue).is(30)

			conn:Disconnect()
			manager:Destroy()
		end)
	end)

	describe("Method: OnArrayInsert", function()
		test("fires with index and value payload", function()
			local manager = TableManager.new {
				items = { "Sword" },
			}

			local fireCount = 0
			local seenIndex = nil
			local seenValue = nil

			manager:OnArrayInsert({ "items", 2 }, function(index, value)
				fireCount += 1
				seenIndex = index
				seenValue = value
			end)

			manager:ArrayInsert("items", "Shield")

			expect(fireCount).is(1)
			expect(seenIndex).is(2)
			expect(seenValue).is("Shield")

			manager:Destroy()
		end)

		test("supports proxy mutation target and ArrayInserted signal payload", function()
			local manager = TableManager.new {
				items = { "Sword", "Shield" },
			}

			local listenerCount = 0
			local signalCount = 0
			local signalPath = nil
			local signalIndex = nil
			local signalValue = nil

			manager:OnArrayInsert({ "items", 3 }, function(index, value)
				listenerCount += 1
				expect(index).is(3)
				expect(value).is("Potion")
			end)

			local conn = manager.ArrayInserted:Connect(function(path, index, value)
				signalCount += 1
				signalPath = path
				signalIndex = index
				signalValue = value
			end)

			manager:ArrayInsert(manager.Proxy.items, "Potion")

			expect(listenerCount).is(1)
			expect(signalCount).is(1)
			expect(signalPath).is_shallow_equal { "items" }
			expect(signalIndex).is(3)
			expect(signalValue).is("Potion")

			conn:Disconnect()
			manager:Destroy()
		end)

		test("only fires when the exact insert leaf path matches", function()
			local manager = TableManager.new {
				items = { "Sword" },
			}

			local mismatched = 0
			local matched = 0
			manager:OnArrayInsert({ "items", 3 }, function()
				mismatched += 1
			end)
			manager:OnArrayInsert({ "items", 2 }, function()
				matched += 1
			end)

			manager:ArrayInsert({ "items" }, "Shield")

			expect(mismatched).is(0)
			expect(matched).is(1)

			manager:Destroy()
		end)
	end)

	describe("Method: OnArrayRemove", function()
		test("fires with index and oldValue payload", function()
			local manager = TableManager.new {
				items = { "Sword", "Shield" },
			}

			local fireCount = 0
			local seenIndex = nil
			local seenValue = nil

			manager:OnArrayRemove({ "items", 1 }, function(index, oldValue)
				fireCount += 1
				seenIndex = index
				seenValue = oldValue
			end)

			manager:ArrayRemove({ "items" }, 1)

			expect(fireCount).is(1)
			expect(seenIndex).is(1)
			expect(seenValue).is("Sword")

			manager:Destroy()
		end)

		test("supports proxy mutation target and ArrayRemoved signal payload", function()
			local manager = TableManager.new {
				items = { "Sword", "Shield", "Potion" },
			}

			local listenerCount = 0
			local signalCount = 0
			local signalPath = nil
			local signalIndex = nil
			local signalValue = nil

			manager:OnArrayRemove("items", function(index, oldValue)
				listenerCount += 1
				expect(index).is(2)
				expect(oldValue).is("Shield")
			end)

			local conn = manager.ArrayRemoved:Connect(function(path, index, value)
				signalCount += 1
				signalPath = path
				signalIndex = index
				signalValue = value
			end)

			manager:ArrayRemove(manager.Proxy.items, 2)

			expect(listenerCount).is(1)
			expect(signalCount).is(1)
			expect(signalPath).is_shallow_equal { "items" }
			expect(signalIndex).is(2)
			expect(signalValue).is("Shield")

			conn:Disconnect()
			manager:Destroy()
		end)

		test("only fires when the exact remove leaf path matches", function()
			local manager = TableManager.new {
				items = { "Sword", "Shield", "Potion" },
			}

			local mismatched = 0
			local matched = 0
			manager:OnArrayRemove({ "items", 1 }, function()
				mismatched += 1
			end)
			manager:OnArrayRemove({ "items", 2 }, function()
				matched += 1
			end)

			manager:ArrayRemove({ "items" }, 2)

			expect(mismatched).is(0)
			expect(matched).is(1)

			manager:Destroy()
		end)
	end)

	describe("Method: OnArraySet", function()
		test("fires when ArraySwapRemove performs a set", function()
			local manager = TableManager.new {
				items = { "A", "B", "C" },
			}

			local fireCount = 0
			local seenIndex = nil
			local seenNew = nil
			local seenOld = nil

			manager:OnArraySet({ "items", 1 }, function(index, newValue, oldValue)
				fireCount += 1
				seenIndex = index
				seenNew = newValue
				seenOld = oldValue
			end)

			manager:ArraySwapRemove({ "items" }, 1)

			expect(fireCount).is(1)
			expect(seenIndex).is(1)
			expect(seenNew).is("C")
			expect(seenOld).is("A")

			manager:Destroy()
		end)

		test("supports proxy mutation target and ArraySet signal payload", function()
			local manager = TableManager.new {
				items = { "A", "B", "C" },
			}

			local listenerCount = 0
			local signalCount = 0
			local signalPath = nil
			local signalIndex = nil
			local signalNew = nil
			local signalOld = nil

			manager:OnArraySet({ "items", 1 }, function(index, newValue, oldValue)
				listenerCount += 1
				expect(index).is(1)
				expect(newValue).is("C")
				expect(oldValue).is("A")
			end)

			local conn = manager.ArraySet:Connect(function(path, index, newValue, oldValue)
				signalCount += 1
				signalPath = path
				signalIndex = index
				signalNew = newValue
				signalOld = oldValue
			end)

			manager:ArraySwapRemove(manager.Proxy.items, 1)

			expect(listenerCount).is(1)
			expect(signalCount).is(1)
			expect(signalPath).is_shallow_equal { "items" }
			expect(signalIndex).is(1)
			expect(signalNew).is("C")
			expect(signalOld).is("A")

			conn:Disconnect()
			manager:Destroy()
		end)

		test("does not fire when swap-removing the last element", function()
			local manager = TableManager.new {
				items = { "A", "B" },
			}

			local listenerCount = 0
			local signalCount = 0
			manager:OnArraySet({ "items", 2 }, function()
				listenerCount += 1
			end)
			local conn = manager.ArraySet:Connect(function()
				signalCount += 1
			end)

			manager:ArraySwapRemove({ "items" }, 2)

			expect(listenerCount).is(0)
			expect(signalCount).is(0)

			conn:Disconnect()
			manager:Destroy()
		end)
	end)
end
