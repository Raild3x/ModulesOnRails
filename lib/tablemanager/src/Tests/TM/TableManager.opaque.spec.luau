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

		-- The following four drive Diff's opaque-child handling, which only runs
		-- when an opaque value sits as a CHILD inside a parent-level `diff_tables`.
		-- Each replaces the whole parent `p` (so `p` is diffed child-by-child) with a
		-- per-change Signal connected, which forces a FULL-depth diff (an `OnChange`
		-- at `p` alone bounds the diff to depth 0 and never recurses into `p`'s
		-- children). The opaque object is registered via an earlier UNOBSERVED write
		-- so the diff's opacity context is active.

		test("removing an opaque child diffs it as a single removed leaf (make_opaque_leaf removed arm)", function()
			-- Diff.make_opaque_leaf's removed arm (Diff.luau:202, `v2 == nil`). A
			-- listener AT the opaque leaf forces the diff to enumerate its removal.
			local manager = TableManager.new { p = { keep = 1 } }
			local obj = { big = true }
			manager:Set("p", { keep = 1, thing = TableManager.Opaque(obj) }) -- unobserved: registers opacity

			local removed = 0
			manager:OnChange({ "p", "thing" }, function()
				removed += 1
			end)

			manager:Set("p", { keep = 1 }) -- `thing` (opaque) removed within p's diff

			expect(removed > 0).is_true()
			expect(manager:Get({ "p", "thing" })).is(nil)

			manager:Destroy()
		end)

		test("replacing a plain child with an opaque one diffs the new opaque side (diff_tables)", function()
			-- Diff.diff_tables' new-side-opaque path (Diff.luau:294): child `slot`
			-- goes plain-table -> opaque within p's diff.
			local manager = TableManager.new { p = { slot = { plain = 1 } } }
			local obj = { opaque = true }
			manager:Set("blob", TableManager.Opaque(obj)) -- unobserved: registers opacity

			local changed = 0
			local conn = manager.KeyChanged:Connect(function() -- forces full-depth diff
				changed += 1
			end)

			manager:Set("p", { slot = obj }) -- slot: {plain=1} -> opaque obj

			expect(changed > 0).is_true()
			expect(manager:Get({ "p", "slot" })).is(obj)

			conn:Disconnect()
			manager:Destroy()
		end)

		test("adding a container that nests an opaque child does not deep-walk it (make_addition_tree)", function()
			-- Diff.make_addition_tree's opaque-child branch (Diff.luau:185).
			local manager = TableManager.new { p = { keep = 1 } }
			local obj = { instance = true }
			manager:Set("blob", TableManager.Opaque(obj)) -- unobserved: registers opacity

			local added = 0
			local conn = manager.KeyAdded:Connect(function() -- forces full-depth diff
				added += 1
			end)

			manager:Set("p", { keep = 1, box = { thing = obj } }) -- `box` added, nests the opaque

			expect(added > 0).is_true()
			expect(manager:Get({ "p", "box", "thing" })).is(obj)

			conn:Disconnect()
			manager:Destroy()
		end)

		test("removing a container that nests an opaque child does not deep-walk it (make_removal_tree)", function()
			-- Diff.make_removal_tree's opaque-child branch (Diff.luau:166). A listener
			-- inside the removed container forces the diff to enumerate its subtree.
			local manager = TableManager.new { p = { keep = 1 } }
			local obj = { instance = true }
			manager:Set("p", { keep = 1, box = { thing = TableManager.Opaque(obj) } }) -- unobserved

			local removed = 0
			manager:OnChange({ "p", "box" }, function()
				removed += 1
			end)

			manager:Set("p", { keep = 1 }) -- `box` (nesting the opaque) removed within p's diff

			expect(removed > 0).is_true()
			expect(manager:Get({ "p", "box" })).is(nil)

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

	describe("FrozenTablesAreOpaque", function()
		test("a DEEPLY frozen value is opaque even with the flag off (default config)", function()
			local manager = TableManager.new { player = {} }
			local frozen = table.freeze({ hp = 100, stats = table.freeze({ str = 1, dex = 2 }) })

			manager:Set("player", frozen)

			local fired = 0
			manager.ValueChanged:Connect(function()
				fired += 1
			end)

			-- Replacing the whole frozen object is a single identity-compared leaf,
			-- not a deep descendant diff (mirrors "replacing the object fires
			-- exactly one signal" above for explicit Opaque).
			manager:Set("player", { hp = 1, stats = { str = 9, dex = 9, luck = 9 } })

			expect(fired).is(1)

			manager:Destroy()
		end)

		test("a SHALLOWLY frozen value is NOT opaque when the flag is off (default config)", function()
			local manager = TableManager.new { player = {} }
			-- Top-level frozen, but `stats` itself is an ordinary mutable table --
			-- not deep-frozen, so it must not be short-circuited without opting in.
			local shallow = table.freeze({ hp = 100, stats = { str = 1, dex = 2 } })

			manager:Set("player", shallow)

			local fired = 0
			manager.ValueChanged:Connect(function()
				fired += 1
			end)

			manager:Set("player", { hp = 1, stats = { str = 9, dex = 9, luck = 9 } })

			expect(fired > 1).is_true()

			manager:Destroy()
		end)

		test("a SHALLOWLY frozen value IS opaque once FrozenTablesAreOpaque is enabled", function()
			local manager = TableManager.new({ player = {} }, { FrozenTablesAreOpaque = true })
			local shallow = table.freeze({ hp = 100, stats = { str = 1, dex = 2 } })

			manager:Set("player", shallow)

			local fired = 0
			manager.ValueChanged:Connect(function()
				fired += 1
			end)

			manager:Set("player", { hp = 1, stats = { str = 9, dex = 9, luck = 9 } })

			expect(fired).is(1)

			manager:Destroy()
		end)

		test("a direct write to a descendant path of a deep-frozen object's REPLACEMENT still fires normally", function()
			-- Once `player` is replaced by a fresh (non-frozen) table, that table is
			-- not opaque -- the deep-frozen mark is per-identity, not sticky to the path.
			local manager = TableManager.new { player = {} }
			manager:Set("player", table.freeze({ hp = 100 }))
			manager:Set("player", { hp = 100 })

			local newHp
			manager:OnValueChange({ "player", "hp" }, function(value)
				newHp = value
			end)

			manager:Set({ "player", "hp" }, 50)

			expect(newHp).is(50)
			expect(manager:Get { "player", "hp" }).is(50)

			manager:Destroy()
		end)

		test("a shallow-frozen table with a mutable descendant still reports a DIRECT write to that descendant", function()
			-- Regression guard for the shallow-freeze foot-gun: even with the flag
			-- ON (so the frozen ancestor is genuinely treated as opaque -- this
			-- exercises `Coverage.PassesThroughOpaqueAncestor`'s one-off-diff
			-- bypass, not just an inactive ctx), a direct write to the mutable
			-- descendant itself must still fire -- only ANCESTOR-level diffs of
			-- the frozen container are short-circuited.
			local mutableStats = { str = 1 }
			local shallow = table.freeze({ stats = mutableStats })
			local manager = TableManager.new({ player = shallow }, { FrozenTablesAreOpaque = true })

			local newStr
			manager:OnValueChange({ "player", "stats", "str" }, function(value)
				newStr = value
			end)

			manager:Set({ "player", "stats", "str" }, 9)

			expect(newStr).is(9)
			expect(manager:Get { "player", "stats", "str" }).is(9)

			manager:Destroy()
		end)

		test("defaults to false: an existing manager's behavior is unchanged without the flag", function()
			local manager = TableManager.new { value = table.freeze({ a = 1 }) }
			expect((manager :: any)._opaqueRegistries.FrozenTablesAreOpaque).is(false)
			manager:Destroy()
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

		-- Per-viewer opacity across a SHARED parent (see Docs/CONTRACT.md §7). Two
		-- managers co-observe the same parent `P` but disagree on a child `C`'s
		-- opacity. They share `REGISTRY[P]`; its single `child` slot's shape is now
		-- chosen by GLOBAL observership (content node iff someone observes `C`
		-- transparently), so N's transparent reconcile and M's opaque reconcile
		-- agree on the shape and never corrupt each other. M (opaque on `C`)
		-- recovers `C`'s identity from the content-node slot via the diff's
		-- `identityOf` resolver, so an internal mutation of `C` is invisible to it.
		test("mixed-opacity co-observers of a shared parent do not corrupt each other's baseline", function()
			local C = { hp = 100 }
			local P = { child = C }
			local N = TableManager.new { Region = P } -- transparent on P + C
			local M = TableManager.new(P) -- co-observes the SAME P (root)

			-- M treats the shared child C as an opaque leaf.
			M:Set("child", TableManager.Opaque(C))

			-- N observes C transparently; a real write materializes the shared child
			-- slot as a full content node.
			N:Set({ "Region", "child", "hp" }, 101)

			-- M is opaque on C: an internal mutation of C must be INVISIBLE to M.
			local mSaw = false
			M:OnValueChange({ "child" }, function()
				mSaw = true
			end)
			C.hp = 50 -- raw internal mutation of the shared child
			M:Flush({ "child" })

			expect(mSaw).never_is_true()

			N:Destroy()
			M:Destroy()
		end)

		test("transparent co-observer of a shared parent still sees the child's internal change", function()
			local C = { hp = 100 }
			local P = { child = C }
			local N = TableManager.new { Region = P } -- transparent on P + C
			local M = TableManager.new(P)
			M:Set("child", TableManager.Opaque(C)) -- M opaque on C

			-- Seed N's baseline for the shared child slot.
			N:Set({ "Region", "child", "hp" }, 101)

			local nSaw: number? = nil
			N:OnValueChange({ "Region", "child", "hp" }, function(value)
				nSaw = value
			end)
			C.hp = 50 -- raw internal mutation of the shared child
			N:Flush({ "Region", "child", "hp" })

			expect(nSaw).is(50) -- transparent viewer is unaffected by M's opacity

			N:Destroy()
			M:Destroy()
		end)

		test("a shared child's internal change reaches the transparent co-observer but not the opaque one", function()
			local C = { hp = 100 }
			local P = { child = C }
			local N = TableManager.new { Region = P }
			local M = TableManager.new(P)
			M:Set("child", TableManager.Opaque(C))
			N:Set({ "Region", "child", "hp" }, 101)

			local mSaw = false
			M:OnValueChange({ "child" }, function()
				mSaw = true
			end)
			local nSaw: number? = nil
			N:OnValueChange({ "Region", "child", "hp" }, function(value)
				nSaw = value
			end)

			C.hp = 50 -- raw internal mutation of the shared child
			-- The transparent viewer consumes the diff first (shared baseline); the
			-- opaque viewer must still stay silent even after that reconcile.
			N:Flush({ "Region", "child", "hp" })
			M:Flush({ "child" })

			expect(nSaw).is(50)
			expect(mSaw).never_is_true()

			N:Destroy()
			M:Destroy()
		end)

		test("opaque co-observer's own Batch mutation of the shared child stays suppressed", function()
			local C = { hp = 100 }
			local P = { child = C }
			local N = TableManager.new { Region = P } -- transparent co-observer of P + C
			local M = TableManager.new(P)
			M:Set("child", TableManager.Opaque(C))

			-- N materializes the shared child slot as a full content node (the
			-- corruption vector the fix neutralizes).
			N:Set({ "Region", "child", "hp" }, 101)

			local mSaw = false
			M:OnChange({ "child" }, function()
				mSaw = true
			end)

			M:Batch(function()
				M.Proxy.child.hp = 50 -- internal mutation of M's opaque leaf
			end)

			expect(mSaw).never_is_true() -- ancestor diff over the opaque child is short-circuited

			N:Destroy()
			M:Destroy()
		end)

		test("reassigning an opaque shared child fires exactly one change for the opaque viewer", function()
			local C = { hp = 100 }
			local P = { child = C }
			local N = TableManager.new { Region = P }
			local M = TableManager.new(P)
			M:Set("child", TableManager.Opaque(C))
			N:Set({ "Region", "child", "hp" }, 101) -- content-node slot for C

			local mFired = 0
			M:OnChange({ "child" }, function()
				mFired += 1
			end)

			-- A reference replacement: swap the opaque child for a brand-new table.
			-- The opaque viewer compares the old identity (recovered from the
			-- content-node slot) against the new ref and fires exactly once.
			M:Set("child", TableManager.Opaque({ hp = 1 }))

			expect(mFired).is(1)

			N:Destroy()
			M:Destroy()
		end)
	end)
end