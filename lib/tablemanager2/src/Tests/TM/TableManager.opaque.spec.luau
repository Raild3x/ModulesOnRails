--!strict
--[[
	Integration coverage for `Opaque`/`GlobalOpaque`/`OpaqueChildren`/
	`GlobalOpaqueChildren`: identity-based opacity marking, the diff
	suppression it buys inside Batch/Suspend, and the "opacity only
	short-circuits ANCESTOR diffs, never an explicit write to a descendant"
	contract.
]]

return function(t: tiniest)
	local TableManager = require("../../TableManager")
	local GcHelpers = require("../Helpers/GcHelpers")

	local test = t.test
	local describe = t.describe
	local expect = t.expect

	describe("Opaque", function()
		test("Set(path, Opaque(obj)) stores the bare object; Get/Raw return it directly", function()
			local manager = TableManager.new { player = {} }
			local obj = { hp = 100 }

			manager:Set("player", TableManager.Opaque(obj))

			expect(manager:Get("player")).is(obj)
			expect(manager.Raw.player).is(obj)

			manager:Destroy()
		end)

		test("raw mutation outside the API fires nothing, opaque or not (existing contract)", function()
			local manager = TableManager.new { player = {}, control = {} }
			local obj = { hp = 100 }
			local controlObj = { hp = 100 }
			manager:Set("player", TableManager.Opaque(obj))
			manager:Set("control", controlObj)

			local fired = 0
			manager.ValueChanged:Connect(function()
				fired += 1
			end)

			obj.hp = 1 -- direct Lua mutation, bypasses the API entirely
			controlObj.hp = 1

			expect(fired).is(0)

			manager:Destroy()
		end)

		test("mutation via proxy inside Batch is suppressed for Opaque but fires for a non-opaque control", function()
			local manager = TableManager.new { player = {}, control = {} }
			local obj = { hp = 100 }
			local controlObj = { hp = 100 }
			manager:Set("player", TableManager.Opaque(obj))
			manager:Set("control", controlObj)

			local playerChanges = 0
			local controlChanges = 0
			manager:OnChange({ "player" }, function()
				playerChanges += 1
			end)
			manager:OnChange({ "control" }, function()
				controlChanges += 1
			end)

			manager:Batch(function()
				manager.Proxy.player.hp = 50
				manager.Proxy.control.hp = 50
			end)

			expect(playerChanges).is(0)
			expect(controlChanges).is(1)

			manager:Destroy()
		end)

		test("mutation via proxy inside Suspend/Resume is suppressed for Opaque but fires for a non-opaque control", function()
			local manager = TableManager.new { player = {}, control = {} }
			local obj = { hp = 100 }
			local controlObj = { hp = 100 }
			manager:Set("player", TableManager.Opaque(obj))
			manager:Set("control", controlObj)

			local playerChanges = 0
			local controlChanges = 0
			manager:OnChange({ "player" }, function()
				playerChanges += 1
			end)
			manager:OnChange({ "control" }, function()
				controlChanges += 1
			end)

			manager:Suspend()
			manager.Proxy.player.hp = 50
			manager.Proxy.control.hp = 50
			manager:Resume()

			expect(playerChanges).is(0)
			expect(controlChanges).is(1)

			manager:Destroy()
		end)

		test("replacing the object fires exactly one signal, not a flood of descendant events", function()
			local manager = TableManager.new { player = {} }
			manager:Set("player", TableManager.Opaque({ hp = 100, stats = { str = 1, dex = 2 } }))

			local fired = 0
			manager.ValueChanged:Connect(function()
				fired += 1
			end)

			manager:Set("player", { hp = 1, stats = { str = 9, dex = 9, luck = 9 } })

			expect(fired).is(1)

			manager:Destroy()
		end)

		test("control: replacing a non-opaque object DOES flood descendant events", function()
			local manager = TableManager.new { player = {} }
			manager:Set("player", { hp = 100, stats = { str = 1, dex = 2 } })

			local fired = 0
			manager.ValueChanged:Connect(function()
				fired += 1
			end)

			manager:Set("player", { hp = 1, stats = { str = 9, dex = 9, luck = 9 } })

			expect(fired > 1).is_true()

			manager:Destroy()
		end)

		test("a direct write to a descendant path of an opaque object still fires (only ancestor diffs are short-circuited)", function()
			local manager = TableManager.new { player = {} }
			manager:Set("player", TableManager.Opaque({ hp = 100 }))

			local newHp
			manager:OnValueChange({ "player", "hp" }, function(value)
				newHp = value
			end)

			manager:Set({ "player", "hp" }, 50)

			expect(newHp).is(50)
			expect(manager:Get { "player", "hp" }).is(50)

			manager:Destroy()
		end)

		test("GlobalOpaque marks the object opaque for every manager, not just the one that wrapped it", function()
			local shared = { hp = 100 }
			local managerA = TableManager.new { shared = {} }
			local managerB = TableManager.new { shared = {} }

			managerA:Set("shared", TableManager.GlobalOpaque(shared))
			managerB:Set("shared", shared) -- same ref, NOT re-wrapped on this manager

			local changesB = 0
			managerB:OnChange({ "shared" }, function()
				changesB += 1
			end)

			managerB:Batch(function()
				managerB.Proxy.shared.hp = 1
			end)

			expect(changesB).is(0)

			managerA:Destroy()
			managerB:Destroy()
		end)

		test("MoveTo preserves the opaque mark (shared identity)", function()
			local manager = TableManager.new { a = {}, c = {} }
			local obj = { hp = 100 }
			manager:Set("a", TableManager.Opaque(obj))

			manager:MoveTo({ "a" }, { "c" })
			expect(manager:Get("c")).is(obj)

			local fired = 0
			manager:OnChange({ "c" }, function()
				fired += 1
			end)
			manager:Batch(function()
				manager.Proxy.c.hp = 1
			end)

			expect(fired).is(0) -- still opaque: same ref, still registered

			manager:Destroy()
		end)

		test("CopyTo produces a fresh ref that is NOT opaque until re-marked", function()
			local manager = TableManager.new { a = {}, b = {} }
			local obj = { hp = 100 }
			manager:Set("a", TableManager.Opaque(obj))

			manager:CopyTo({ "a" }, { "b" })
			expect(manager:Get("b")).never_is(obj) -- CopyTo deep-clones: fresh identity

			local fired = 0
			manager:OnChange({ "b" }, function()
				fired += 1
			end)
			manager:Batch(function()
				manager.Proxy.b.hp = 1
			end)

			expect(fired).is(1) -- the copy was never registered, so it's not opaque

			manager:Destroy()
		end)

		test("works without a proxy graph (EnableProxies = false)", function()
			local manager = TableManager.new({ player = {} }, { EnableProxies = false })
			local obj = { hp = 100 }
			manager:Set("player", TableManager.Opaque(obj))

			expect(manager:Get("player")).is(obj)

			local fired = 0
			manager:OnChange({ "player" }, function()
				fired += 1
			end)

			manager:Batch(function()
				manager:Set({ "player", "hp" }, 1) -- same `player` ref throughout; mutates "in place"
			end)

			expect(fired).is(0)

			manager:Destroy()
		end)

		test("Destroy releases the per-manager opacity registry", function()
			local manager = TableManager.new { player = {} }
			local isAlive: () -> boolean

			do
				local obj = { hp = 100 }
				isAlive = GcHelpers.WeakProbe(obj)
				manager:Set("player", TableManager.Opaque(obj))
			end

			local registries = (manager :: any)._opaqueRegistries
			manager:Set("player", nil :: any) -- drop the manager's own strong ref to obj
			manager:Destroy()

			local collected = GcHelpers.WaitForCollection(isAlive)
			expect(collected).is_true()
			expect(GcHelpers.CountKeys(registries.Opaque)).is(0)
		end)
	end)

	describe("OpaqueChildren", function()
		test("ArrayInsert/ArrayRemove fire normally; an inserted element's internal mutation in a Batch is suppressed", function()
			local manager = TableManager.new { items = {} }
			manager:Set("items", TableManager.OpaqueChildren({}))

			local inserted, removed = 0, 0
			manager.ArrayInserted:Connect(function()
				inserted += 1
			end)
			manager.ArrayRemoved:Connect(function()
				removed += 1
			end)

			local elem = { hp = 100 }
			manager:ArrayInsert("items", elem) -- inserted AFTER marking: auto-opaque

			expect(inserted).is(1)
			expect(manager:Get { "items", 1 }).is(elem)

			local elementChanges = 0
			manager:OnChange({ "items", 1 }, function()
				elementChanges += 1
			end)

			manager:Batch(function()
				manager.Proxy.items[1].hp = 1
			end)

			expect(elementChanges).is(0) -- internal mutation suppressed: auto-opaque child

			manager:ArrayRemove("items", 1)
			expect(removed).is(1)

			manager:Destroy()
		end)
	end)

	-- Phase 0 golden (see Docs/CONTRACT.md §7): opacity is PER-VIEWER. The same
	-- live table can be an opaque leaf to one manager (skip big diffs) while a
	-- different manager observes it transparently for its own granular changes.
	-- This property must survive the shadow/linking/opacity re-architecture.
	describe("Per-viewer opacity (Inventory/Sword)", function()
		test("the same table is opaque to one manager and transparent to another", function()
			local sword = { damage = 10, name = "Sword" }

			-- Sword manager: rooted at the sword, observes it TRANSPARENTLY.
			local swordMgr = TableManager.new(sword)
			-- Inventory manager: holds the SAME sword as an OPAQUE leaf.
			local inventoryTM = TableManager.new { equipped = {} }
			inventoryTM:Set("equipped", TableManager.Opaque(sword))

			local swordSaw: number? = nil
			swordMgr:OnValueChange("damage", function(value)
				swordSaw = value
			end)

			local inventorySawInternal = 0
			inventoryTM:OnChange("equipped", function()
				inventorySawInternal += 1
			end)

			-- Transparent viewer: a granular write through its own API is seen.
			swordMgr:Set("damage", 20)
			expect(swordSaw).is(20)

			-- Opaque viewer: an ancestor-level diff over `equipped` never walks into
			-- the opaque sword, so an internal change is invisible to inventory.
			inventoryTM:Batch(function()
				inventoryTM.Proxy.equipped.damage = 99
			end)
			expect(inventorySawInternal).is(0)

			-- Same identity throughout, so the underlying value is consistent for both.
			expect(swordMgr.Raw.damage).is(99)
			expect(inventoryTM.Raw.equipped.damage).is(99)

			swordMgr:Destroy()
			inventoryTM:Destroy()
		end)
	end)
end
