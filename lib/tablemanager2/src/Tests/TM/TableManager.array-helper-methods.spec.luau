--!strict

return function(t: tiniest)
	local TableManager = require("../../TableManager")

	local test = t.test
	local describe = t.describe
	local expect = t.expect

	describe("Method: ArrayRemoveFirstValue", function()
		test("removes first matching value and returns removed index", function()
			local manager = TableManager.new {
				items = { "A", "B", "A" },
			}

			local index = manager:ArrayRemoveFirstValue({ "items" }, "A")
			expect(index).is(1)
			expect(manager.Proxy.items[1]).is("B")
			expect(manager.Proxy.items[2]).is("A")

			manager:Destroy()
		end)

		test("supports proxy target and fires ArrayRemoved signal", function()
			local manager = TableManager.new {
				items = { "A", "B", "C" },
			}

			local listenerCount = 0
			local signalCount = 0
			local signalPath = nil
			local signalIndex = nil
			local signalValue = nil

			manager:OnArrayRemove({ "items" }, function(index, oldValue)
				listenerCount += 1
				expect(index).is(2)
				expect(oldValue).is("B")
			end)

			local conn = manager.ArrayRemoved:Connect(function(path, index, oldValue)
				signalCount += 1
				signalPath = path
				signalIndex = index
				signalValue = oldValue
			end)

			local index = manager:ArrayRemoveFirstValue(manager.Proxy.items, "B")
			expect(index).is(2)

			expect(listenerCount).is(1)
			expect(signalCount).is(1)
			expect(signalPath).is_shallow_equal { "items" }
			expect(signalIndex).is(2)
			expect(signalValue).is("B")

			conn:Disconnect()
			manager:Destroy()
		end)

		test("returns nil when value is not found", function()
			local manager = TableManager.new {
				items = { "A", "B" },
			}

			local index = manager:ArrayRemoveFirstValue({ "items" }, "Z")
			expect(index).is(nil)

			manager:Destroy()
		end)

		test("errors when target is not a table", function()
			local manager = TableManager.new {
				notArray = 5,
			}

			expect(function()
				manager:ArrayRemoveFirstValue({ "notArray" }, 5)
			end).fails_with("attempt to index nil with 'Original'")

			manager:Destroy()
		end)
	end)

	describe("Method: ArraySwapRemove", function()
		test("returns removed value and performs swap-remove", function()
			local manager = TableManager.new {
				items = { "A", "B", "C" },
			}

			local removed = manager:ArraySwapRemove({ "items" }, 1)
			expect(removed).is("A")
			expect(manager.Proxy.items[1]).is("C")
			expect(manager.Proxy.items[2]).is("B")
			expect(manager.Proxy.items[3]).is(nil)

			manager:Destroy()
		end)

		test("supports proxy target and fires ArrayRemoved + ArraySet signals", function()
			local manager = TableManager.new {
				items = { "A", "B", "C" },
			}

			local removedCount = 0
			local setCount = 0
			local removedIndex = nil
			local setIndex = nil

			local removedConn = manager.ArrayRemoved:Connect(function(_path, index, oldValue)
				removedCount += 1
				removedIndex = index
				expect(oldValue).is("C")
			end)
			local setConn = manager.ArraySet:Connect(function(_path, index, newValue, oldValue)
				setCount += 1
				setIndex = index
				expect(newValue).is("C")
				expect(oldValue).is("B")
			end)

			local removed = manager:ArraySwapRemove(manager.Proxy.items, 2)
			expect(removed).is("B")

			expect(removedCount).is(1)
			expect(setCount).is(1)
			expect(removedIndex).is(3)
			expect(setIndex).is(2)

			removedConn:Disconnect()
			setConn:Disconnect()
			manager:Destroy()
		end)

		test("returns nil for out-of-range index", function()
			local manager = TableManager.new {
				items = { "A", "B" },
			}

			local removed = manager:ArraySwapRemove({ "items" }, 99)
			expect(removed).is(nil)
			expect(manager.Proxy.items[1]).is("A")
			expect(manager.Proxy.items[2]).is("B")

			manager:Destroy()
		end)
	end)

	describe("Method: ArraySwapRemoveFirstValue", function()
		test("removes first matching value and returns removed index", function()
			local manager = TableManager.new {
				items = { "A", "B", "C" },
			}

			local index = manager:ArraySwapRemoveFirstValue({ "items" }, "B")
			expect(index).is(2)
			expect(manager.Proxy.items[1]).is("A")
			expect(manager.Proxy.items[2]).is("C")
			expect(manager.Proxy.items[3]).is(nil)

			manager:Destroy()
		end)

		test("supports proxy target and triggers remove + set listener callbacks", function()
			local manager = TableManager.new {
				items = { "A", "B", "C" },
			}

			local removeListenerCount = 0
			local setListenerCount = 0

			manager:OnArrayRemove({ "items" }, function(index, oldValue)
				removeListenerCount += 1
				expect(index).is(3)
				expect(oldValue).is("C")
			end)

			manager:OnArraySet({ "items" }, function(index, newValue, oldValue)
				setListenerCount += 1
				expect(index).is(2)
				expect(newValue).is("C")
				expect(oldValue).is("B")
			end)

			local index = manager:ArraySwapRemoveFirstValue(manager.Proxy.items, "B")
			expect(index).is(2)
			expect(removeListenerCount).is(1)
			expect(setListenerCount).is(1)

			manager:Destroy()
		end)

		test("returns nil when value is not found", function()
			local manager = TableManager.new {
				items = { "A", "B" },
			}

			local index = manager:ArraySwapRemoveFirstValue({ "items" }, "Z")
			expect(index).is(nil)

			manager:Destroy()
		end)
	end)
end
