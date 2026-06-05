--!strict

return function(t: tiniest)
	local TableManager = require("../../TableManager")

	local test = t.test
	local describe = t.describe
	local expect = t.expect

	describe("Method: MoveTo", function()
		test("supports proxy source and updates destination", function()
			local manager = TableManager.new {
				a = { value = 1 },
				b = { value = 2 },
			}

			manager:MoveTo(manager.Proxy.a, { "b" })

			expect(manager.Proxy.a).is(nil)
			expect(manager.Proxy.b.value).is(1)

			manager:Destroy()
		end)

		test("rejects moving root", function()
			local manager = TableManager.new {
				a = { value = 1 },
			}

			expect(function()
				manager:MoveTo({}, { "a" })
			end).fails_with("MoveTo cannot move the root table")

			manager:Destroy()
		end)

		test("rejects moving into a descendant path", function()
			local manager = TableManager.new {
				a = { child = { value = 1 } },
			}

			expect(function()
				manager:MoveTo({ "a" }, { "a", "child", "newPlace" })
			end).fails_with("MoveTo cannot move a table into one of its descendants")

			manager:Destroy()
		end)

		test("rejects moving a non-table source", function()
			local manager = TableManager.new {
				a = 1,
				b = { value = 2 },
			}

			expect(function()
				manager:MoveTo({ "a" }, { "b" })
			end).fails_with("MoveTo source must be a table")

			manager:Destroy()
		end)
	end)

	describe("Method: CopyTo", function()
		test("deep copies table data", function()
			local manager = TableManager.new {
				a = { nested = { value = 1 } },
				b = { nested = { value = 99 } },
			}

			manager:CopyTo({ "a" }, { "b" })

			expect(manager.Proxy.b.nested.value).is(1)
			expect(manager.Proxy.b).is_not(manager.Proxy.a)

			manager.Proxy.b.nested.value = 77
			expect(manager.Proxy.a.nested.value).is(1)
			expect(manager.Proxy.b.nested.value).is(77)

			manager:Destroy()
		end)

		test("supports proxy source", function()
			local manager = TableManager.new {
				a = { value = 1 },
				b = { value = 2 },
			}

			manager:CopyTo(manager.Proxy.a, { "b" })

			expect(manager.Proxy.a.value).is(1)
			expect(manager.Proxy.b.value).is(1)
			expect(manager.Proxy.b).is_not(manager.Proxy.a)

			manager:Destroy()
		end)

		test("rejects root destination", function()
			local manager = TableManager.new {
				a = { value = 1 },
			}

			expect(function()
				manager:CopyTo({ "a" }, {})
			end).fails_with("CopyTo cannot set the root table")

			manager:Destroy()
		end)
	end)

	describe("Method: Swap", function()
		test("swaps scalar values", function()
			local manager = TableManager.new {
				a = 1,
				b = 2,
			}

			manager:Swap({ "a" }, { "b" })

			expect(manager.Proxy.a).is(2)
			expect(manager.Proxy.b).is(1)

			manager:Destroy()
		end)

		test("swaps table values and preserves live proxy identity", function()
			local manager = TableManager.new {
				a = { value = 10 },
				b = { value = 20 },
			}

			local heldA = manager.Proxy.a
			local heldB = manager.Proxy.b

			manager:Swap({ "a" }, { "b" })

			expect(manager.Proxy.a.value).is(20)
			expect(manager.Proxy.b.value).is(10)
			expect(manager.Proxy.b).is(heldA)
			expect(manager.Proxy.a).is(heldB)

			heldA.value = 111
			expect(manager.Proxy.b.value).is(111)

			manager:Destroy()
		end)

		test("supports proxy arguments", function()
			local manager = TableManager.new {
				a = { value = 10 },
				b = { value = 20 },
			}

			manager:Swap(manager.Proxy.a, manager.Proxy.b)

			expect(manager.Proxy.a.value).is(20)
			expect(manager.Proxy.b.value).is(10)

			manager:Destroy()
		end)

		test("rejects root path", function()
			local manager = TableManager.new {
				a = 1,
			}

			expect(function()
				manager:Swap({}, { "a" })
			end).fails_with("Swap cannot target the root table")

			manager:Destroy()
		end)

		test("rejects ancestor and descendant paths", function()
			local manager = TableManager.new {
				a = { child = { value = 1 } },
			}

			expect(function()
				manager:Swap({ "a" }, { "a", "child" })
			end).fails_with("Swap cannot swap ancestor/descendant paths")

			manager:Destroy()
		end)
	end)
end
