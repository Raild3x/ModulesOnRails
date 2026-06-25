--!strict
--[[
	Cross-manager propagation under the implicit-sharing model (see `Propagation`).
	"Sharing a table identity = being linked": any table reachable (transparently)
	in two or more managers' trees is observed by all of them, and a write through
	one propagates to the others — no explicit `Link`/`AutoLink` call. Divergence
	(replacing a shared reference) lapses the sharing lazily. Opacity is the opt-out.
]]

return function(t: tiniest)
	local TableManager = require("../../TableManager")

	local test = t.test
	local describe = t.describe
	local expect = t.expect

	describe("Implicit sharing — propagation", function()
		test("whole-root co-observers: writes on either side fire ValueChanged on the other", function()
			local shared = { health = 100 }
			local a = TableManager.new(shared)
			local b = TableManager.new(shared)
			-- Both root at `shared`, so they co-observe it automatically.

			local bNew, bOld
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

			expect(a:IsLinkedWith(b)).is_true()
			expect(b:IsLinkedWith(a)).is_true()

			a:Destroy()
			b:Destroy()
		end)

		test("interior co-observers: differing anchor paths translate correctly", function()
			local sharedNode = { x = 1 }
			local dataA = { B = sharedNode }
			local dataB = { other = { nested = sharedNode } }

			local a = TableManager.new(dataA)
			local b = TableManager.new(dataB)
			-- `sharedNode` lives at "B" in `a` and "other.nested" in `b`.

			local seenNew
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

		test("a throwing listener on one co-observer does not block fan-out to the others", function()
			local shared = { value = 1 }
			local a = TableManager.new(shared)
			local b = TableManager.new(shared)
			local c = TableManager.new(shared)

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

		test("nested co-observers sharing several identities along a path fire exactly once", function()
			-- `a` and `b` share BOTH the root and the nested `items` array; a single
			-- array op must still deliver to the other side exactly once (dedupe by
			-- recipient, not once per shared ancestor identity).
			local shared = { items = { "A", "B" } }
			local a = TableManager.new(shared)
			local b = TableManager.new(shared)

			local inserts = 0
			b:OnArrayInsert("items", function()
				inserts += 1
			end)

			a:ArrayInsert("items", "C")

			expect(inserts).is(1)
			expect(b.Raw.items[3]).is("C")

			a:Destroy()
			b:Destroy()
		end)
	end)

	describe("Implicit sharing — divergence", function()
		test("replacing a shared interior reference lapses sharing for that manager", function()
			local sharedNode = { x = 1 }
			local a = TableManager.new({ B = sharedNode })
			local b = TableManager.new({ B = sharedNode })
			expect(a:IsLinkedWith(b)).is_true()

			-- Replace `B` on a's side entirely; a no longer holds `sharedNode`.
			a:Set("B", { x = 99 })

			expect(a:IsLinkedWith(b)).never_is_true()
			-- b's data is untouched by the divergent write.
			expect(b.Raw.B.x).is(1)

			-- Further writes on either side no longer cross.
			local bSaw = false
			b:OnValueChange("B.x", function()
				bSaw = true
			end)
			a:Set("B.x", 7)
			expect(bSaw).never_is_true()
			expect(b.Raw.B.x).is(1)

			a:Destroy()
			b:Destroy()
		end)

		test("re-rooting a manager via Set({}, ...) lapses its sharing", function()
			local shared = { health = 100 }
			local a = TableManager.new(shared)
			local b = TableManager.new(shared)
			expect(a:IsLinkedWith(b)).is_true()

			-- Re-root `a` onto a brand-new table; it no longer holds `shared`.
			a:Set({}, { health = 5 })

			expect(a:IsLinkedWith(b)).never_is_true()
			-- b keeps the original shared object, untouched by a's re-root.
			expect(b.Raw.health).is(100)
			expect(a.Raw.health).is(5)

			a:Destroy()
			b:Destroy()
		end)

		test("destroying one of three co-observers keeps the others sharing", function()
			local shared = { value = 1 }
			local a = TableManager.new(shared)
			local b = TableManager.new(shared)
			local c = TableManager.new(shared)

			b:Destroy()

			expect(a:IsLinkedWith(c)).is_true()
			expect(a:IsLinkedWith(b)).never_is_true()

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
	end)

	describe("Linked-manager introspection (GetLinkedManagers / IsLinkedWith)", function()
		test("IsLinkedWith and GetLinkedManagers report co-observing managers", function()
			local shared = { value = 1 }
			local a = TableManager.new(shared)
			local b = TableManager.new(shared)
			local c = TableManager.new(shared)

			expect(a:IsLinkedWith(b)).is_true()
			expect(a:IsLinkedWith(c)).is_true()

			local managers = a:GetLinkedManagers()
			expect(#managers).is(2)
			-- excludes self
			local containsSelf = false
			for _, m in managers do
				if m == a then
					containsSelf = true
				end
			end
			expect(containsSelf).never_is_true()

			a:Destroy()
			b:Destroy()
			c:Destroy()
		end)
	end)

	describe("Implicit sharing — nested/derived managers (subsumes AutoLink)", function()
		test("a manager rooted at another's interior table shares it (parent created first)", function()
			local Data = { Inventory = { { Name = "Sword" } }, Stats = { Health = 100 } }
			local PlayerTM = TableManager.new(Data)
			local StatsTM = TableManager.new(Data.Stats)
			local SwordTM = TableManager.new(Data.Inventory[1])

			local statsSeen
			PlayerTM:OnValueChange("Stats.Health", function(newValue)
				statsSeen = newValue
			end)
			StatsTM:Set("Health", 50)
			expect(Data.Stats.Health).is(50)
			expect(statsSeen).is(50)

			-- reverse direction
			local healthOnStats
			StatsTM:OnValueChange("Health", function(newValue)
				healthOnStats = newValue
			end)
			PlayerTM:Set("Stats.Health", 75)
			expect(healthOnStats).is(75)

			local swordSeen
			PlayerTM:OnValueChange({ "Inventory", 1, "Name" }, function(newValue)
				swordSeen = newValue
			end)
			SwordTM:Set("Name", "Axe")
			expect(swordSeen).is("Axe")

			PlayerTM:Destroy()
			StatsTM:Destroy()
			SwordTM:Destroy()
		end)

		test("sharing is order-independent (child manager created before parent)", function()
			local statsTable = { Health = 100 }
			local StatsTM = TableManager.new(statsTable)
			local PlayerTM = TableManager.new({ Stats = statsTable })

			local seen
			PlayerTM:OnValueChange("Stats.Health", function(newValue)
				seen = newValue
			end)
			StatsTM:Set("Health", 25)
			expect(seen).is(25)

			PlayerTM:Destroy()
			StatsTM:Destroy()
		end)

		test("inserting a managed table into an array shares it", function()
			local PlayerTM = TableManager.new({ Inventory = {} })
			local sword = { Name = "Sword" }
			local SwordTM = TableManager.new(sword)

			PlayerTM:ArrayInsert("Inventory", sword)

			local seen
			PlayerTM:OnValueChange({ "Inventory", 1, "Name" }, function(newValue)
				seen = newValue
			end)
			SwordTM:Set("Name", "Mace")
			expect(seen).is("Mace")

			PlayerTM:Destroy()
			SwordTM:Destroy()
		end)

		test("nested/bulk insert shares immediately (the whole inserted subtree is registered)", function()
			local PlayerTM = TableManager.new({})
			local sword = { Name = "Sword" }
			local SwordTM = TableManager.new(sword)

			-- sword is nested one level inside the assigned composite value; the
			-- whole subtree is registered, so sharing is immediate (no Ensure step).
			PlayerTM:Set("bag", { sword })
			expect(PlayerTM:IsLinkedWith(SwordTM)).is_true()

			local seen
			PlayerTM:OnValueChange({ "bag", 1, "Name" }, function(newValue)
				seen = newValue
			end)
			SwordTM:Set("Name", "Dagger")
			expect(seen).is("Dagger")

			PlayerTM:Destroy()
			SwordTM:Destroy()
		end)

		test("removing a nested managed table lapses the sharing", function()
			local Data = { Inventory = { { Name = "Sword" } } }
			local PlayerTM = TableManager.new(Data)
			local SwordTM = TableManager.new(Data.Inventory[1])

			expect(PlayerTM:IsLinkedWith(SwordTM)).is_true()

			PlayerTM:ArrayRemove("Inventory", 1)
			expect(PlayerTM:IsLinkedWith(SwordTM)).never_is_true()

			PlayerTM:Destroy()
			SwordTM:Destroy()
		end)
	end)
end
