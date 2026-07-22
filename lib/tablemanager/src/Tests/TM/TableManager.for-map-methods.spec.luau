--!strict

return function(t: tiniest)
	local TableManager = require("../../TableManager")

	local test = t.test
	local describe = t.describe
	local expect = t.expect

	describe("Method: ForKeys", function()
		test("fires once per existing key on subscribe", function()
			local manager = TableManager.new { a = 1, b = 2 }
			local seen: { [string]: number } = {}

			manager:ForKeys({}, function(_itemJanitor, key)
				seen[key] = (seen[key] or 0) + 1
			end)

			expect(seen.a).is(1)
			expect(seen.b).is(1)

			manager:Destroy()
		end)

		test("fires again when a new key is added", function()
			local manager = TableManager.new { a = 1 }
			local count = 0

			manager:ForKeys({}, function()
				count += 1
			end)
			expect(count).is(1)

			manager:Set("b", 2)
			expect(count).is(2)

			manager:Destroy()
		end)

		test("does not re-run the handler when an existing key's value changes", function()
			local manager = TableManager.new { a = 1 }
			local count = 0
			local capturedJanitor: any = nil

			manager:ForKeys({}, function(itemJanitor)
				count += 1
				capturedJanitor = itemJanitor
			end)
			expect(count).is(1)

			manager:Set("a", 99)
			expect(count).is(1)
			expect(capturedJanitor).exists()

			manager:Destroy()
		end)

		test("destroys the item's Janitor when its key is removed", function()
			local manager = TableManager.new { a = 1 }
			local destroyed = false

			manager:ForKeys({}, function(itemJanitor)
				itemJanitor:Add(function()
					destroyed = true
				end)
			end)
			expect(destroyed).never_is_true()

			manager:Set("a", nil :: any)
			expect(destroyed).is_true()

			manager:Destroy()
		end)

		test("tears down every live item when the whole source is replaced by a non-table", function()
			-- reconcile's removal pass (ForMap.luau:121, `type(current) ~= "table"`):
			-- the tracked source is scalarized while items are live, so every item
			-- must be destroyed rather than key-compared against a non-table.
			local manager = TableManager.new { inv = { sword = 1, shield = 1 } }
			local destroyed: { [string]: boolean } = {}

			manager:ForKeys("inv", function(itemJanitor, key)
				itemJanitor:Add(function()
					destroyed[key] = true
				end)
			end)

			-- Replace the populated `inv` table with a scalar in one write.
			manager:Set("inv", 5 :: any)

			expect(destroyed.sword).is_true()
			expect(destroyed.shield).is_true()

			manager:Destroy()
		end)
	end)

	describe("Method: ForValues", function()
		test("tracks duplicate values as independent items", function()
			local manager = TableManager.new { items = { 1, 1, 2 } }
			local fireCount = 0

			manager:ForValues("items", function()
				fireCount += 1
			end)

			expect(fireCount).is(3)

			manager:Destroy()
		end)

		test("does not re-trigger the surviving occurrence when a value moves index", function()
			local manager = TableManager.new { items = { "a", "b" } }
			local addCount = 0
			local bDestroyed = false

			manager:ForValues("items", function(itemJanitor, value)
				addCount += 1
				if value == "b" then
					itemJanitor:Add(function()
						bDestroyed = true
					end)
				end
			end)
			expect(addCount).is(2)

			manager:ArraySwapRemove("items", 1) -- removes "a", backfills with "b"

			expect(addCount).is(2) -- "b"'s occurrence was never torn down/recreated
			expect(bDestroyed).never_is_true()

			manager:Destroy()
		end)
	end)

	describe("Method: ForPairs", function()
		test("fires once per existing pair on subscribe", function()
			local manager = TableManager.new { a = 1, b = 2 }
			local seen: { [string]: number } = {}

			manager:ForPairs({}, function(_itemJanitor, key)
				seen[key] = (seen[key] or 0) + 1
			end)

			expect(seen.a).is(1)
			expect(seen.b).is(1)

			manager:Destroy()
		end)

		test("tears down and re-runs when the value changes at an existing key", function()
			local manager = TableManager.new { a = 1 }
			local addCount = 0
			local destroyedCount = 0

			manager:ForPairs({}, function(itemJanitor)
				addCount += 1
				itemJanitor:Add(function()
					destroyedCount += 1
				end)
			end)
			expect(addCount).is(1)
			expect(destroyedCount).is(0)

			manager:Set("a", 99)

			expect(addCount).is(2)
			expect(destroyedCount).is(1)

			manager:Destroy()
		end)
	end)

	describe("Method: MapKeys", function()
		test("derived manager is keyed by transform's return value", function()
			local manager = TableManager.new { a = 1, b = 2 }

			local derived = manager:MapKeys({}, function(_entryJanitor, key)
				return string.upper(key)
			end)

			expect(derived:Get("A")).is(1)
			expect(derived:Get("B")).is(2)

			manager:Destroy()
			derived:Destroy()
		end)

		test("output value refreshes on source value change without re-running transform", function()
			local manager = TableManager.new { a = 1 }
			local transformCalls = 0

			local derived = manager:MapKeys({}, function(_entryJanitor, key)
				transformCalls += 1
				return string.upper(key)
			end)
			expect(transformCalls).is(1)

			manager:Set("a", 99)

			expect(derived:Get("A")).is(99)
			expect(transformCalls).is(1)

			manager:Destroy()
			derived:Destroy()
		end)

		test("destroying the derived manager disconnects from the source", function()
			local manager = TableManager.new { a = 1 }

			local derived = manager:MapKeys({}, function(_entryJanitor, key)
				return string.upper(key)
			end)

			derived:Destroy()

			expect(function()
				manager:Set("b", 2)
			end).never_fails()

			manager:Destroy()
		end)
	end)

	describe("Method: MapValues", function()
		test("derived manager is keyed by source key with transformed values", function()
			local manager = TableManager.new { a = 1, b = 2 }

			local derived = manager:MapValues({}, function(_entryJanitor, value)
				return value * 10
			end)

			expect(derived:Get("a")).is(10)
			expect(derived:Get("b")).is(20)

			manager:Destroy()
			derived:Destroy()
		end)

		test("output updates when the source value changes", function()
			local manager = TableManager.new { a = 1 }

			local derived = manager:MapValues({}, function(_entryJanitor, value)
				return value * 10
			end)
			expect(derived:Get("a")).is(10)

			manager:Set("a", 5)
			expect(derived:Get("a")).is(50)

			manager:Destroy()
			derived:Destroy()
		end)
	end)

	describe("Method: MapPairs", function()
		test("derived manager is keyed by transform's first return value", function()
			local manager = TableManager.new { a = 1, b = 2 }

			local derived = manager:MapPairs({}, function(_entryJanitor, key, value)
				return key .. "_x", value
			end)

			expect(derived:Get("a_x")).is(1)
			expect(derived:Get("b_x")).is(2)

			manager:Destroy()
			derived:Destroy()
		end)
	end)
end
