--!strict

return function(t: tiniest)
	local TableManager = require("../../TableManager")

	local test = t.test
	local describe = t.describe
	local expect = t.expect

	describe("TableManager.Link / LinkGroup", function()
		test("whole-root link: writes on either side fire ValueChanged on the other", function()
			local shared = { health = 100 }
			local a = TableManager.new(shared)
			local b = TableManager.new(shared)

			local group = TableManager.Link({ { a }, { b } })

			local bPath, bNew, bOld
			b:OnValueChange("health", function(newValue, oldValue)
				bNew, bOld = newValue, oldValue
			end)

			a:Set("health", 50)

			expect(b.Raw.health).is(50)
			expect(bNew).is(50)
			expect(bOld).is(100)

			local aNew
			a:OnValueChange("health", function(newValue)
				aNew = newValue
			end)
			b:Set("health", 25)
			expect(a.Raw.health).is(25)
			expect(aNew).is(25)

			expect(group:HasMember(a)).is_true()
			expect(group:HasMember(b)).is_true()

			a:Destroy()
			b:Destroy()
		end)

		test("4-arg call form links two managers", function()
			local shared = { value = 1 }
			local a = TableManager.new(shared)
			local b = TableManager.new(shared)

			TableManager.Link(a, "", b, "")

			local seen
			b:OnValueChange("value", function(newValue)
				seen = newValue
			end)
			a:Set("value", 2)
			expect(seen).is(2)

			a:Destroy()
			b:Destroy()
		end)

		test("interior-anchor link: differing anchor paths translate correctly", function()
			local sharedNode = { x = 1 }
			local dataA = { B = sharedNode }
			local dataB = { other = { nested = sharedNode } }

			local a = TableManager.new(dataA)
			local b = TableManager.new(dataB)

			TableManager.Link({ { a, "B" }, { b, "other.nested" } })

			local seenPath, seenNew
			b:OnValueChange("other.nested.x", function(newValue)
				seenNew = newValue
			end)

			a:Set("B.x", 42)

			expect(b.Raw.other.nested.x).is(42)
			expect(seenNew).is(42)

			-- And the reverse direction
			local aSeen
			a:OnValueChange("B.x", function(newValue)
				aSeen = newValue
			end)
			b:Set("other.nested.x", 7)
			expect(a.Raw.B.x).is(7)
			expect(aSeen).is(7)

			a:Destroy()
			b:Destroy()
		end)

		test("array op fan-out: insert/remove/set propagate and keep proxy bookkeeping correct", function()
			local shared = { items = { "A", "B", "C" } }
			local a = TableManager.new(shared)
			local b = TableManager.new(shared)

			TableManager.Link({ { a }, { b } })

			-- Hold a proxy on b for the element currently at index 2 ("B")
			local bProxyForB = b:GetProxy({ "items", 2 })

			local insertedIndex, insertedValue
			b:OnArrayInsert("items", function(index, newValue)
				insertedIndex, insertedValue = index, newValue
			end)

			a:ArrayInsert("items", 1, "X")

			expect(b.Raw.items[1]).is("X")
			expect(insertedIndex).is(1)
			expect(insertedValue).is("X")
			-- b's held proxy for the original "B" element should have shifted to index 3
			expect((b:GetProxy({ "items", 3 }))).is(bProxyForB)

			local removedIndex, removedValue
			b:OnArrayRemove("items", function(index, oldValue)
				removedIndex, removedValue = index, oldValue
			end)

			a:ArrayRemove("items", 1) -- removes "X"

			expect(b.Raw.items[1]).is("A")
			expect(removedIndex).is(1)
			expect(removedValue).is("X")
			expect((b:GetProxy({ "items", 2 }))).is(bProxyForB)

			local setIndex, setNew, setOld
			b:OnArraySet("items", function(index, newValue, oldValue)
				setIndex, setNew, setOld = index, newValue, oldValue
			end)

			-- items is currently {"A", "B", "C"}; swap-remove index 1 backfills
			-- index 1 with "C" (ArraySet) and shrinks the array (ArrayRemoved).
			a:ArraySwapRemove("items", 1)

			expect(b.Raw.items[1]).is("C")
			expect(b.Raw.items[2]).is("B")
			expect(b.Raw.items[3]).is(nil)
			expect(setIndex).is(1)
			expect(setNew).is("C")
			expect(setOld).is("A")
			-- b's held proxy for "B" (still at index 2) is unaffected by the swap-remove.
			expect((b:GetProxy({ "items", 2 }))).is(bProxyForB)

			a:Destroy()
			b:Destroy()
		end)

		test("divergence: replacing the anchor object removes that member and dissolves a 2-member group", function()
			local sharedNode = { x = 1 }
			local dataA = { B = sharedNode }
			local dataB = { B = sharedNode }

			local a = TableManager.new(dataA)
			local b = TableManager.new(dataB)

			local group = TableManager.Link({ { a, "B" }, { b, "B" } })

			local removedMember
			group.MemberRemoved:Connect(function(manager)
				removedMember = manager
			end)

			local dissolved = false
			group.Dissolved:Connect(function()
				dissolved = true
			end)

			-- Replace `B` on a's side entirely; this severs a's anchor.
			a:Set("B", { x = 99 })

			expect(removedMember).is(a)
			expect(dissolved).is_true()
			expect(group:HasMember(a)).never_is_true()
			expect(group:HasMember(b)).never_is_true()

			-- b's data is untouched by the divergent write.
			expect(b.Raw.B.x).is(1)

			a:Destroy()
			b:Destroy()
		end)

		test("topology robustness: destroying the middle member of a 3-way group keeps the others linked", function()
			local shared = { value = 1 }
			local a = TableManager.new(shared)
			local b = TableManager.new(shared)
			local c = TableManager.new(shared)

			local group = TableManager.Link({ { a }, { b }, { c } })
			group:Add(c) -- idempotent re-add is a no-op (already linked via Link)

			b:Destroy()

			expect(group:HasMember(a)).is_true()
			expect(group:HasMember(b)).never_is_true()
			expect(group:HasMember(c)).is_true()

			local cSeen
			c:OnValueChange("value", function(newValue)
				cSeen = newValue
			end)

			a:Set("value", 2)

			expect(c.Raw.value).is(2)
			expect(cSeen).is(2)

			a:Destroy()
			c:Destroy()
		end)

		test("a throwing listener on one member does not block fan-out to the others", function()
			local shared = { value = 1 }
			local a = TableManager.new(shared)
			local b = TableManager.new(shared)
			local c = TableManager.new(shared)

			TableManager.Link({ { a }, { b }, { c } })

			b:OnValueChange("value", function()
				error("boom")
			end)

			local cSeen
			c:OnValueChange("value", function(newValue)
				cSeen = newValue
			end)

			local ok = pcall(function()
				a:Set("value", 2)
			end)

			expect(ok).is_true()
			expect(c.Raw.value).is(2)
			expect(cSeen).is(2)

			a:Destroy()
			b:Destroy()
			c:Destroy()
		end)

		test("echo loop prevention: a single write fires the receiving manager's listener exactly once", function()
			local shared = { value = 1 }
			local a = TableManager.new(shared)
			local b = TableManager.new(shared)

			TableManager.Link({ { a }, { b } })

			local aFireCount, bFireCount = 0, 0
			a.ValueChanged:Connect(function()
				aFireCount += 1
			end)
			b.ValueChanged:Connect(function()
				bFireCount += 1
			end)

			a:Set("value", 2)

			expect(aFireCount).is(1)
			expect(bFireCount).is(1)

			a:Destroy()
			b:Destroy()
		end)

		test("Unlink removes membership from a specific group or all groups", function()
			local shared = { value = 1 }
			local a = TableManager.new(shared)
			local b = TableManager.new(shared)

			local group = TableManager.Link({ { a }, { b } })

			expect(#a:GetLinkGroups()).is(1)

			a:Unlink(group)

			expect(#a:GetLinkGroups()).is(0)
			expect(group:HasMember(a)).never_is_true()

			a:Destroy()
			b:Destroy()
		end)

		test("Destroy unlinks a manager from all of its groups", function()
			local shared = { value = 1 }
			local a = TableManager.new(shared)
			local b = TableManager.new(shared)

			local group = TableManager.Link({ { a }, { b } })

			a:Destroy()

			expect(group:HasMember(a)).never_is_true()
			expect(group:HasMember(b)).never_is_true() -- group dissolved below 2 members

			b:Destroy()
		end)
	end)
end
