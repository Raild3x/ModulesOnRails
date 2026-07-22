--!strict

return function(t: tiniest)
	local TableManager = require("../../TableManager")
	local T = require("../../../T")

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

		test("rejects moving to the root", function()
			-- The `#targetPath == 0` operand: root as the *destination*.
			local manager = TableManager.new {
				a = { value = 1 },
			}

			expect(function()
				manager:MoveTo({ "a" }, {})
			end).fails_with("MoveTo cannot move the root table")

			manager:Destroy()
		end)

		test("rolls back the reparent when the batched write fails", function()
			-- A schema that types `boxes.b` as a number makes the inner
			-- `Set(target, sourceTable)` throw, so MoveTo must restore the source
			-- proxy/value and leave neither path in a partial state.
			local manager = TableManager.new({
				boxes = { a = { x = 1 }, b = 2 },
			}, {
				Schema = T.interface {
					boxes = T.interface {
						a = T.interface { x = T.number },
						b = T.number,
					},
				},
			})

			local heldA = manager.Proxy.boxes.a

			expect(function()
				manager:MoveTo({ "boxes", "a" }, { "boxes", "b" })
			end).fails()

			-- Source untouched, destination untouched, proxy still valid.
			expect(manager:Get({ "boxes", "a", "x" })).is(1)
			expect(manager:Get({ "boxes", "b" })).is(2)
			expect(manager.Proxy.boxes.a).is(heldA)
			expect(heldA.x).is(1)

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

		test("rejects a destination parent that is not a table", function()
			-- getParentOriginalAtPath (Mutator.luau:75): the destination's parent
			-- resolves to a scalar, so the copy is refused before any mutation.
			local manager = TableManager.new {
				a = { value = 1 },
				b = 2,
			}

			expect(function()
				manager:CopyTo({ "a" }, { "b", "deep" })
			end).fails_with("CopyTo destination parent must be a table")

			manager:Destroy()
		end)

		test("deep-copies a value with shared inner references, preserving the sharing", function()
			-- deepCloneValue's memo (Mutator.luau:90) must return the same clone
			-- when it revisits a table reached by two paths (a diamond), rather
			-- than duplicating it or looping forever.
			local shared = { tag = "S" }
			local manager = TableManager.new {
				src = { left = shared, right = shared },
			}

			manager:CopyTo({ "src" }, { "dst" })

			-- The copy is independent of the source...
			expect(manager.Raw.dst).never_is(manager.Raw.src)
			expect(manager.Raw.dst.left).never_is(shared)
			expect(manager.Raw.dst.left.tag).is("S")
			-- ...but the internal sharing is preserved (one clone, two slots).
			expect(manager.Raw.dst.left).is(manager.Raw.dst.right)

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

		test("rejects ancestor/descendant paths when the descendant is the first argument", function()
			-- The reversed operand: IsPrefixPath(pathB, pathA) rather than
			-- IsPrefixPath(pathA, pathB).
			local manager = TableManager.new {
				a = { child = { value = 1 } },
			}

			expect(function()
				manager:Swap({ "a", "child" }, { "a" })
			end).fails_with("Swap cannot swap ancestor/descendant paths")

			manager:Destroy()
		end)

		test("rejects the root as the second argument", function()
			-- The `#pathB == 0` operand: root as the *second* path.
			local manager = TableManager.new {
				a = 1,
			}

			expect(function()
				manager:Swap({ "a" }, {})
			end).fails_with("Swap cannot target the root table")

			manager:Destroy()
		end)

		test("rolls back both reparents when the batched write fails", function()
			-- Schema types `boxes.a` as an interface and `boxes.b` as a number.
			-- Swap sets `boxes.a = valueB (a number)`, which the schema rejects,
			-- so both reparents must be restored and neither path mutated.
			local manager = TableManager.new({
				boxes = { a = { x = 1 }, b = 2 },
			}, {
				Schema = T.interface {
					boxes = T.interface {
						a = T.interface { x = T.number },
						b = T.number,
					},
				},
			})

			local heldA = manager.Proxy.boxes.a

			expect(function()
				manager:Swap({ "boxes", "a" }, { "boxes", "b" })
			end).fails()

			expect(manager:Get({ "boxes", "a", "x" })).is(1)
			expect(manager:Get({ "boxes", "b" })).is(2)
			expect(manager.Proxy.boxes.a).is(heldA)
			expect(heldA.x).is(1)

			manager:Destroy()
		end)
	end)

	describe("Method: Set (root replacement)", function()
		test("replaces the entire root table contents", function()
			local manager = TableManager.new {
				a = 1,
				b = { value = 2 },
			}

			manager:Set({}, { a = 10, c = 3 })

			expect(manager:Get("a")).is(10)
			expect(manager:Get("b")).is(nil)
			expect(manager:Get("c")).is(3)

			manager:Destroy()
		end)

		test("preserves manager.Proxy identity and reads new data", function()
			local manager = TableManager.new {
				a = 1,
			}
			local heldProxy = manager.Proxy

			manager:Set({}, { a = 2, nested = { v = 5 } })

			expect(manager.Proxy).is(heldProxy)
			expect(heldProxy.a).is(2)
			expect(heldProxy.nested.v).is(5)
			expect(manager.Raw).is(manager:Get({}))

			manager:Destroy()
		end)

		test("fires root key listeners for added and removed keys", function()
			local manager = TableManager.new {
				keep = 1,
				drop = 2,
			}

			local addedValues = {}
			local removedValues = {}
			local rootChanges = 0

			local addConn = manager:OnKeyAdd({}, function(key, newValue)
				table.insert(addedValues, newValue)
			end)
			local removeConn = manager:OnKeyRemove({}, function(key, oldValue)
				table.insert(removedValues, oldValue)
			end)
			local changeConn = manager:OnChange({}, function()
				rootChanges += 1
			end)

			manager:Set({}, { keep = 10, fresh = 3 })

			expect(table.find(addedValues, 3)).exists()
			expect(table.find(removedValues, 2)).exists()
			expect(rootChanges > 0).is(true)

			addConn:Disconnect()
			removeConn:Disconnect()
			changeConn:Disconnect()
			manager:Destroy()
		end)

		test("is a no-op when setting the same root table", function()
			local manager = TableManager.new {
				a = 1,
			}

			local changes = 0
			local conn = manager:OnChange({}, function()
				changes += 1
			end)

			manager:Set({}, manager.Raw)

			expect(changes).is(0)

			conn:Disconnect()
			manager:Destroy()
		end)

		test("rejects setting the root to nil", function()
			local manager = TableManager.new {
				a = 1,
			}

			expect(function()
				manager:Set({}, nil :: any)
			end).fails_with("root must remain a table")

			manager:Destroy()
		end)

		test("rejects replacing the root inside a batch", function()
			local manager = TableManager.new {
				a = 1,
			}

			expect(function()
				manager:Batch(function()
					manager:Set({}, { a = 2 })
				end)
			end).fails_with("Cannot replace the root table inside a batch")

			manager:Destroy()
		end)

		test("enforces the root schema and rejects invalid replacements", function()
			local manager = TableManager.new({
				count = 1,
			}, {
				Schema = T.strictInterface {
					count = T.number,
				},
			})

			expect(function()
				manager:Set({}, { count = "nope" })
			end).fails()

			-- The rejected write must not have mutated the root.
			expect(manager:Get("count")).is(1)

			manager:Set({}, { count = 5 })
			expect(manager:Get("count")).is(5)

			manager:Destroy()
		end)
	end)

	describe("Method: Update", function()
		test("passes the old value to the updater and stores its return", function()
			local manager = TableManager.new {
				player = { health = 100 },
			}

			local seenOld = nil
			local returned = manager:Update({ "player", "health" }, function(old)
				seenOld = old
				return old + 5
			end)

			expect(seenOld).is(100)
			expect(returned).is(105)
			expect(manager:Get({ "player", "health" })).is(105)

			manager:Destroy()
		end)

		test("fires ValueChanged for the updated path", function()
			local manager = TableManager.new {
				score = 1,
			}

			local fired = 0
			manager:OnValueChange("score", function()
				fired += 1
			end)

			manager:Update("score", function(old)
				return old * 10
			end)

			expect(fired).is(1)
			expect(manager:Get("score")).is(10)

			manager:Destroy()
		end)

		test("an empty path read-modify-writes the whole root", function()
			-- applyRMW's `lastIdx == 0` branch (Mutator.luau:545): the updater
			-- receives the live root and its return replaces it.
			local manager = TableManager.new {
				a = 1,
				b = 2,
			}

			local seenRoot: any = nil
			manager:Update({}, function(root)
				seenRoot = root
				return { c = 3 }
			end)

			expect(seenRoot.a).is(1)
			expect(manager:Get("a")).is(nil)
			expect(manager:Get("b")).is(nil)
			expect(manager:Get("c")).is(3)

			manager:Destroy()
		end)

		test("errors when an intermediate path segment is not a table", function()
			-- applyRMW spine walk (Mutator.luau:556): a scalar sits mid-path.
			local manager = TableManager.new {
				a = 1,
			}

			expect(function()
				manager:Update({ "a", "b", "c" }, function(old)
					return old
				end)
			end).fails_with("Path segment b is not a table")

			manager:Destroy()
		end)

		test("errors when the parent path segment is not a table", function()
			-- applyRMW spine tail check (Mutator.luau:561): the direct parent is
			-- a scalar.
			local manager = TableManager.new {
				a = 1,
			}

			expect(function()
				manager:Update({ "a", "b" }, function(old)
					return old
				end)
			end).fails_with("Path segment b is not a table")

			manager:Destroy()
		end)
	end)

	describe("Method: Increment", function()
		test("adds the delta and returns the new value", function()
			local manager = TableManager.new {
				player = { coins = 10 },
			}

			local returned = manager:Increment({ "player", "coins" }, 5)

			expect(returned).is(15)
			expect(manager:Get({ "player", "coins" })).is(15)

			manager:Destroy()
		end)

		test("supports negative deltas", function()
			local manager = TableManager.new { coins = 10 }

			expect(manager:Increment("coins", -4)).is(6)
			expect(manager:Get("coins")).is(6)

			manager:Destroy()
		end)
	end)

	describe("Method: UpdateKey", function()
		test("updates the value at path[key] via the updater", function()
			local manager = TableManager.new {
				inventory = { apples = 3 },
			}

			local returned = manager:UpdateKey({ "inventory" }, "apples", function(old)
				return old + 2
			end)

			expect(returned).is(5)
			expect(manager:Get({ "inventory", "apples" })).is(5)

			manager:Destroy()
		end)

		test("ArrayUpdate is an alias for UpdateKey", function()
			local manager = TableManager.new {
				list = { 10, 20, 30 },
			}

			manager:ArrayUpdate({ "list" }, 2, function(old)
				return old + 5
			end)

			expect(manager:Get({ "list", 2 })).is(25)

			manager:Destroy()
		end)
	end)

	describe("Method: IncrementKey", function()
		test("adds the delta at path[key] and returns the new value", function()
			local manager = TableManager.new {
				stats = { xp = 100 },
			}

			local returned = manager:IncrementKey({ "stats" }, "xp", 50)

			expect(returned).is(150)
			expect(manager:Get({ "stats", "xp" })).is(150)

			manager:Destroy()
		end)

		test("ArrayIncrement is an alias for IncrementKey", function()
			local manager = TableManager.new {
				list = { 1, 2, 3 },
			}

			expect(manager:ArrayIncrement({ "list" }, 3, 7)).is(10)
			expect(manager:Get({ "list", 3 })).is(10)

			manager:Destroy()
		end)
	end)
end
