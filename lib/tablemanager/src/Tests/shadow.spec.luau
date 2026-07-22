--!strict
--[[
	Tests for Phase 2 of the coverage-tree plan: the persistent `Shadow`
	mirror and `TableManager:Flush`, which replace the old per-write
	CaptureSnapshot/CheckForChanges pair on the immediate (non-batched) write
	path. Covers:
	- `Shadow` in isolation (Get/Materialize/Reconcile/Release).
	- JIT seeding: the first trackable write after a region becomes observed
	  diffs against the PRE-write value, not against a missing/nil baseline.
	- The shadow staying in sync with live data across every write entry
	  point (Set, proxy, array ops, link fan-out, batched Resume).
	- Proxy-vs-`Set` `oldValue` parity (the "single-source" rule).
	- The public `Flush` for external-mutation detection.
]]

return function(t: tiniest)
	const TableManager = require("../TableManager")
	const ShadowNode = require("../Baseline/ShadowNode")
	const Coverage = require("../Diffing/Coverage")

	const test = t.test
	const describe = t.describe
	const expect = t.expect

	-- `ShadowNode` is a stateless module backing a global identity-keyed
	-- registry: every function reads/writes nodes keyed by the live table
	-- it's handed directly (no per-manager handle to construct). These
	-- isolated unit tests just pass plain tables in place of `manager.Raw`,
	-- exactly as `Baseline.*` does for a real manager.

	describe("ShadowNode", function()
		test("Get returns nil for a never-materialized path", function()
			expect(ShadowNode.Get({}, { "a" })).never_exists()
		end)

		test("Materialize seeds a scalar leaf and Get returns it", function()
			const live = { a = { b = 5 } }
			ShadowNode.Materialize(live, { "a", "b" })
			expect(ShadowNode.Get(live, { "a", "b" })).is(5)
		end)

		test("Materialize deep-copies a table leaf (mutating live doesn't affect the mirror)", function()
			const live = { a = { x = 1 } }
			ShadowNode.Materialize(live, { "a" })
			live.a.x = 2
			expect(ShadowNode.Get(live, { "a" }).x).is(1)
		end)

		test("Reconcile refreshes the mirror to the current live value", function()
			const live = { a = 1 }
			ShadowNode.Materialize(live, { "a" })
			live.a = 2
			ShadowNode.Reconcile(live, { "a" })
			expect(ShadowNode.Get(live, { "a" })).is(2)
		end)

		test("Reconcile at the root replaces the whole mirror", function()
			const live = { a = 1 }
			ShadowNode.Materialize(live, {})
			expect(ShadowNode.Get(live, { "a" })).is(1)
			const newRoot = { a = 99 }
			ShadowNode.Reconcile(newRoot, {})
			expect(ShadowNode.Get(newRoot, { "a" })).is(99)
		end)

		test("Materialize is idempotent on an already-materialized path", function()
			const live = { a = { b = 1, c = 2 } }
			ShadowNode.Materialize(live, { "a", "b" })
			ShadowNode.Materialize(live, { "a", "c" })
			-- Both leaves survive: materializing "a.c" must not wipe out "a.b".
			expect(ShadowNode.Get(live, { "a", "b" })).is(1)
			expect(ShadowNode.Get(live, { "a", "c" })).is(2)
		end)

		test("a newly-created intermediate node captures sibling keys never themselves materialized", function()
			const live = { player = { health = 100, mana = 5 } }
			-- Only "health" is ever individually materialized; "mana" is a
			-- sibling under the same new intermediate node ("player").
			ShadowNode.Materialize(live, { "player", "health" })
			-- The intermediate "player" node must carry "mana" too, even though
			-- nothing ever materialized {"player", "mana"} directly - otherwise a
			-- later wholesale replacement of "player" couldn't detect its removal.
			expect(ShadowNode.Get(live, { "player", "mana" })).is(5)
		end)

		test("two roots sharing a live table share the SAME baseline node", function()
			const shared = { health = 100 }
			const rawA = { stats = shared }
			const rawB = { stats = shared }
			ShadowNode.Materialize(rawA, { "stats", "health" })
			-- `rawB` never materialized anything itself, but its "stats" slot
			-- resolves to the SAME identity-keyed node `rawA` just populated,
			-- since both mirror the same live `shared` table.
			ShadowNode.Materialize(rawB, { "stats", "health" })
			expect(ShadowNode.Get(rawB, { "stats", "health" })).is(100)
			shared.health = 50
			ShadowNode.Reconcile(rawA, { "stats", "health" })
			expect(ShadowNode.Get(rawB, { "stats", "health" })).is(50)
		end)

		test("RebindRoot re-keys the root node so Get survives a root identity swap", function()
			const oldRoot = { a = 1 }
			ShadowNode.Materialize(oldRoot, {})
			expect(ShadowNode.Get(oldRoot, { "a" })).is(1)

			-- Simulate a `Set({}, newRoot)`: the live root identity is swapped,
			-- and the baseline must follow so `Get({})` still returns the seeded
			-- pre-swap contents (the diff "old"), not nil.
			const newRoot = { a = 2, b = 3 }
			ShadowNode.RebindRoot(oldRoot, newRoot)
			expect(ShadowNode.Get(newRoot, { "a" })).is(1) -- still the pre-swap baseline
			expect(ShadowNode.Get(newRoot, { "b" })).never_exists()

			-- A subsequent root reconcile then refreshes it to the new contents.
			ShadowNode.Reconcile(newRoot, {})
			expect(ShadowNode.Get(newRoot, { "a" })).is(2)
			expect(ShadowNode.Get(newRoot, { "b" })).is(3)
		end)
	end)

	describe("Coverage.PassesThroughOpaqueAncestor", function()
		test("false when nothing along the path is opaque", function()
			const manager = TableManager.new { player = { hp = 100 } }
			const ctx = (manager :: any)._changeDetector:GetOpaqueCtx()
			expect(Coverage.PassesThroughOpaqueAncestor(manager :: any, { "player", "hp" }, ctx)).never_is_true()
			manager:Destroy()
		end)

		test("true when the direct parent is opaque", function()
			const manager = TableManager.new { player = {} }
			manager:Set("player", TableManager.Opaque({ hp = 100 }))
			const ctx = (manager :: any)._changeDetector:GetOpaqueCtx()
			expect(Coverage.PassesThroughOpaqueAncestor(manager :: any, { "player", "hp" }, ctx)).is_true()
			manager:Destroy()
		end)

		test("false for the opaque path itself (only DESCENDANTS of it count)", function()
			const manager = TableManager.new { player = {} }
			manager:Set("player", TableManager.Opaque({ hp = 100 }))
			const ctx = (manager :: any)._changeDetector:GetOpaqueCtx()
			expect(Coverage.PassesThroughOpaqueAncestor(manager :: any, { "player" }, ctx)).never_is_true()
			manager:Destroy()
		end)
	end)

	describe("Shadow integration (TableManager)", function()
		test("a direct write into an opaque descendant never corrupts the opaque object (repeated writes stay accurate)", function()
			const manager = TableManager.new { player = {} }
			manager:Set("player", TableManager.Opaque({ hp = 100 }))

			const seen: { any } = {}
			manager:OnValueChange({ "player", "hp" }, function(newValue, oldValue)
				table.insert(seen, { newValue, oldValue })
			end)

			-- If Materialize aliased the live opaque object instead of bypassing
			-- the shadow for it, this first write would corrupt the "old"
			-- baseline together with "new", making the SECOND write's oldValue
			-- wrong too (it would read back whatever the first write just set).
			manager:Set({ "player", "hp" }, 50)
			manager:Set({ "player", "hp" }, 75)

			expect(seen[1][1]).is(50)
			expect(seen[1][2]).is(100)
			expect(seen[2][1]).is(75)
			expect(seen[2][2]).is(50)

			manager:Destroy()
		end)

		test("replacing an ancestor reports removal of a sibling key that was never itself written", function()
			const manager = TableManager.new {
				player = { health = 100, mana = 5 },
			}

			-- A global Signal connection (not a path-scoped registry listener)
			-- makes every write independently trackable WITHOUT ever
			-- materializing a whole subtree up front. "mana" is never itself
			-- the target of a write below, only "health" is.
			local removedKeys: { any } = {}
			manager.KeyRemoved:Connect(function(_path, key)
				table.insert(removedKeys, key)
			end)

			manager:Set("player.health", 50)
			manager:Set("player", { health = 1 })

			expect(manager:Get("player")).is_shallow_equal { health = 1 }
			expect(table.find(removedKeys, "mana")).exists()

			manager:Destroy()
		end)

		test("the first trackable write after a listener registers diffs against the PRE-existing value", function()
			const manager = TableManager.new {
				a = { b = 5 },
			}

			-- "a.b" already had a real value (5) BEFORE any listener existed, so
			-- the shadow was never materialized for it. The listener below makes
			-- a write at "a" trackable for the FIRST time; without JIT-seeding the
			-- shadow from the pre-write value, this would misreport "b" as having
			-- gone from nil -> 6 (or as a spurious extra "added" key) instead of 5 -> 6.
			local capturedOld: any
			manager:OnValueChange("a", function(_newValue, oldValue)
				capturedOld = oldValue
			end)

			manager:Set("a", { b = 6 })

			expect(capturedOld).exists()
			expect(capturedOld.b).is(5)

			manager:Destroy()
		end)

		test("proxy writes and :Set report identical oldValue (single-source rule)", function()
			const manager = TableManager.new {
				x = 1,
			}

			const seenViaSet: { any } = {}
			manager:OnValueChange("x", function(newValue, oldValue)
				table.insert(seenViaSet, { newValue, oldValue })
			end)

			manager:Set("x", 2)
			const proxy: any = manager.Proxy
			proxy.x = 3

			expect(seenViaSet[1][1]).is(2)
			expect(seenViaSet[1][2]).is(1)
			expect(seenViaSet[2][1]).is(3)
			expect(seenViaSet[2][2]).is(2)

			manager:Destroy()
		end)

		test("the shadow stays in sync after a Set so the NEXT unrelated flush isn't corrupted", function()
			const manager = TableManager.new {
				a = { value = 1 },
				z = 1,
			}

			manager:OnValueChange("a", function() end)
			manager:OnValueChange("z", function() end)

			manager:Set("a", { value = 2 })

			-- A later, unrelated write at a DIFFERENT root branch must not see
			-- stale shadow state for "a" leak into its own diff.
			local zOld: any
			manager:OnValueChange("z", function(_newValue, oldValue)
				zOld = oldValue
			end)
			manager:Set("z", 5)

			expect(zOld).is(1)
			expect(ShadowNode.Get((manager :: any).Raw, { "a" }).value).is(2)

			manager:Destroy()
		end)

		test("array operations keep the shadow's mirror of the array in sync", function()
			const manager = TableManager.new {
				items = { "a", "b" },
			}

			-- Cover the array's PARENT so the array's own ops are forced trackable
			-- and exercised through the shadow-sync added to fireArrayOperation.
			manager:OnChange("items", function() end)

			manager:ArrayInsert("items", "c")
			manager:ArrayRemove("items", 1)

			expect(ShadowNode.Get((manager :: any).Raw, { "items" })).is_shallow_equal { "b", "c" }

			manager:Destroy()
		end)

		test("a coalesced batch leaves the shadow consistent with post-batch live state", function()
			const manager = TableManager.new {
				x = 1,
			}
			manager:OnValueChange("x", function() end)

			manager:Batch(function()
				manager:Set("x", 2)
				manager:Set("x", 3)
			end)

			expect(ShadowNode.Get((manager :: any).Raw, { "x" })).is(3)

			-- A subsequent immediate write must diff against the post-batch
			-- value (3), not a stale pre-batch one (1).
			local capturedOld: any
			manager:OnValueChange("x", function(_newValue, oldValue)
				capturedOld = oldValue
			end)
			manager:Set("x", 4)

			expect(capturedOld).is(3)

			manager:Destroy()
		end)

		test("a batch fires net changes once and suppresses net-zero changes", function()
			const manager = TableManager.new {
				x = 1,
			}
			local fireCount = 0
			local lastNew: any
			manager:OnValueChange("x", function(newValue)
				fireCount += 1
				lastNew = newValue
			end)

			manager:Batch(function()
				manager:Set("x", 2)
				manager:Set("x", 3)
			end)
			expect(fireCount).is(1)
			expect(lastNew).is(3)

			manager:Batch(function()
				manager:Set("x", 99)
				manager:Set("x", 3)
			end)
			expect(fireCount).is(1) -- net-zero (3 -> 99 -> 3): no second fire

			manager:Destroy()
		end)

		test("cross-manager fan-out keeps the target manager's shadow in sync", function()
			const shared = { health = 100 }
			const a = TableManager.new(shared)
			const b = TableManager.new(shared)
			-- Implicit sharing: both root at `shared`, so they co-observe it.

			b:OnValueChange("health", function() end)
			a:Set("health", 50)

			expect(ShadowNode.Get((b :: any).Raw, { "health" })).is(50)

			-- A later write on `a` must diff against the now-current value (50)
			-- from `b`'s perspective too, not the stale original (100).
			local bOld: any
			b:OnValueChange("health", function(_newValue, oldValue)
				bOld = oldValue
			end)
			a:Set("health", 25)
			expect(bOld).is(50)

			a:Destroy()
			b:Destroy()
		end)

		test("Flush surfaces a mutation made by code that bypassed Set/Proxy", function()
			const manager = TableManager.new {
				a = { value = 1 },
			}

			local captured: { any } = {}
			manager:OnValueChange("a", function(newValue, oldValue)
				captured = { newValue, oldValue }
			end)

			-- Force the shadow to materialize, then mutate the raw table directly,
			-- bypassing Set/Proxy entirely.
			manager:Set("a", { value = 1 })
			const raw: any = manager.Raw
			raw.a = { value = 2 }

			manager:Flush("a")

			expect(captured[1].value).is(2)
			expect(captured[2].value).is(1)

			manager:Destroy()
		end)

		test("Flush is a no-op when nothing observes the given path", function()
			const manager = TableManager.new {
				a = 1,
			}
			-- Must not error even though nothing covers "a".
			expect(function()
				manager:Flush("a")
			end).never_fails()
			manager:Destroy()
		end)

		test("an explicit Flush inside a batch defers instead of firing immediately", function()
			const manager = TableManager.new {
				x = 1,
			}
			local fireCount = 0
			manager:OnValueChange("x", function()
				fireCount += 1
			end)

			manager:Suspend()
			manager:Set("x", 2)
			manager:Flush("x")
			expect(fireCount).is(0) -- still suspended; Flush must not break batch atomicity
			manager:Resume()
			expect(fireCount).is(1)

			manager:Destroy()
		end)

		test("repeated churn on an observed path does not grow the shadow's mirror size", function()
			const manager = TableManager.new {
				n = 0,
			}
			manager:OnValueChange("n", function() end)

			for i = 1, 50 do
				manager:Set("n", i)
			end

			-- The root node for a single scalar path is always exactly one slot;
			-- this mostly guards against Materialize accidentally accumulating
			-- stale sibling entries on repeated calls.
			local count = 0
			for _ in ShadowNode.Get((manager :: any).Raw, {}) do
				count += 1
			end
			expect(count).is(1)

			manager:Destroy()
		end)
	end)
end
