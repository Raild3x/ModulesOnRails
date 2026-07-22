--!strict
--[[
	End-to-end tests for the `SnapshotOldValues` listener option:
	- A listener that opts in receives a frozen, independent copy of a table
	  `oldValue`, immune to later mutation of the underlying baseline.
	- A listener that does NOT opt in keeps receiving the existing (possibly
	  baseline-backed, mutable) reference -- unchanged behavior.
	- Coverage across OnChange/OnValueChange, OnKeyChange, array element ops,
	  and the batch (Suspend/Resume) flush path.
]]

return function(t: tiniest)
	local TableManager = require("../../TableManager")

	local test = t.test
	local describe = t.describe
	local expect = t.expect

	describe("SnapshotOldValues", function()
		test("an opted-in OnChange listener receives a table oldValue with the expected contents", function()
			local manager = TableManager.new {
				player = { stats = { health = 100 } },
			}

			local capturedOld: any = nil
			manager:OnChange({ "player", "stats" }, function(_newValue, oldValue)
				capturedOld = oldValue
			end, { SnapshotOldValues = true })

			manager.Proxy.player.stats = { health = 50 }

			expect(capturedOld).exists()
			expect(capturedOld.health).is(100)

			manager:Destroy()
		end)

		test(
			"an opted-in listener's captured oldValue is immune to the same flush's own baseline reconcile, unlike the raw reference",
			function()
				-- Reproduces the underlying bug this option fixes: outside a batch,
				-- the "old" value handed to a listener is backed by ShadowNode's
				-- baseline mirror table. `_doFlush` fires listeners BEFORE
				-- reconciling that mirror to the new value -- but reconcile runs
				-- synchronously right after, in the SAME `Flush` call, and (since
				-- "a"'s live identity never changes here) REUSES and clears that
				-- exact mirror table in place. So by the time `Flush` returns, a
				-- plain listener's `oldValue` reference already reads the NEW
				-- value, not the true old one -- unless it opted into
				-- SnapshotOldValues, which copies the value out at fire time,
				-- before that same reconcile can touch it.
				local manager = TableManager.new {
					a = { value = 1 },
				}

				local snapshotOld: any = nil
				local rawOld: any = nil

				manager:OnValueChange("a", function(_newValue, oldValue)
					snapshotOld = oldValue
				end, { SnapshotOldValues = true })

				manager:OnValueChange("a", function(_newValue, oldValue)
					rawOld = oldValue
				end)

				-- Force the shadow to materialize via a content-identical `Set`
				-- (mirrors the documented Flush idiom -- see `shadow.spec.luau`).
				-- `Reconcile` (unlike `Materialize`) requires the baseline's parent
				-- spine to already exist, so a bare `Flush` on a never-tracked path
				-- would silently no-op instead of seeding it. `Set` finds no actual
				-- content difference (same value, just a new table object), so it
				-- fires no listener -- a pure materialization step.
				manager:Set("a", { value = 1 })

				local raw: any = manager.Raw

				-- Mutate "a" in place (same table identity) and flush.
				raw.a.value = 2
				manager:Flush("a")

				-- The opted-in listener's copy is independent: it still reads the
				-- true old value after the call returns.
				expect(snapshotOld.value).is(1)

				-- The non-opted listener's old value is the shared baseline mirror,
				-- already reconciled (cleared and refilled to the NEW value) by the
				-- time this very `Flush` call returned -- demonstrating the
				-- corruption SnapshotOldValues exists to avoid.
				expect(rawOld.value).is(2)

				-- A second flush reconciles the SAME mirror again, proving it isn't
				-- a one-off: the opted-in copy from THIS fire is independently
				-- correct, while the raw reference is immediately stale once more.
				raw.a.value = 3
				manager:Flush("a")
				expect(snapshotOld.value).is(2)
				expect(rawOld.value).is(3)

				manager:Destroy()
			end
		)

		test("a non-opted-in listener on the same node is unaffected by a sibling opted-in listener", function()
			local manager = TableManager.new {
				player = { stats = { health = 100 } },
			}

			local optedInOld: any = nil
			local plainOld: any = nil

			manager:OnChange({ "player", "stats" }, function(_newValue, oldValue)
				optedInOld = oldValue
			end, { SnapshotOldValues = true })

			manager:OnChange({ "player", "stats" }, function(_newValue, oldValue)
				plainOld = oldValue
			end)

			manager.Proxy.player.stats = { health = 50 }

			expect(optedInOld.health).is(100)
			expect(plainOld.health).is(100)
			-- Without the option, the raw (live-tree) old value is used as-is --
			-- distinct in principle from the frozen copy, though both read the
			-- same contents immediately after the change.
			expect(optedInOld).never_is(plainOld)

			manager:Destroy()
		end)

		test("OnKeyChange delivers a snapshot of a replaced table value when opted in", function()
			local manager = TableManager.new {
				player = { stats = { mana = 5 } },
			}

			local capturedKey: any = nil
			local capturedOld: any = nil

			manager:OnKeyChange("player", function(key, _newValue, oldValue)
				capturedKey = key
				capturedOld = oldValue
			end, { SnapshotOldValues = true })

			manager.Proxy.player.stats = { mana = 10 }

			expect(capturedKey).is("stats")
			expect(capturedOld.mana).is(5)

			manager:Destroy()
		end)

		test("OnArrayRemove delivers a snapshot of a removed table element when opted in", function()
			local manager = TableManager.new {
				items = { { id = "sword" }, { id = "shield" } },
			}

			local capturedOld: any = nil
			manager:OnArrayRemove({ "items" }, function(_index, oldValue)
				capturedOld = oldValue
			end, { SnapshotOldValues = true })

			manager:ArrayRemove("items", 1)

			expect(capturedOld).exists()
			expect(capturedOld.id).is("sword")

			manager:Destroy()
		end)

		test("OnArraySet delivers a snapshot of the replaced table element when opted in", function()
			local manager = TableManager.new {
				items = { { id = "sword" } },
			}

			local capturedOld: any = nil
			manager:OnArraySet({ "items" }, function(_index, _newValue, oldValue)
				capturedOld = oldValue
			end, { SnapshotOldValues = true })

			-- A same-index element replace only becomes a synthetic "ArraySet" via
			-- the batch flush's LCS re-diff (`ArrayDiff.emitDiff`'s setMode fuse);
			-- writing through the proxy directly is an ordinary dict-style write.
			manager:Suspend()
			manager.Proxy.items[1] = { id = "shield" }
			manager:Resume()

			expect(capturedOld).exists()
			expect(capturedOld.id).is("sword")

			manager:Destroy()
		end)

		test("a batched change still delivers a snapshot to an opted-in listener", function()
			local manager = TableManager.new {
				player = { stats = { health = 100 } },
			}

			local capturedOld: any = nil
			manager:OnChange({ "player", "stats" }, function(_newValue, oldValue)
				capturedOld = oldValue
			end, { SnapshotOldValues = true })

			manager:Suspend()
			manager.Proxy.player.stats = { health = 70 }
			manager:Resume()

			expect(capturedOld).exists()
			expect(capturedOld.health).is(100)

			manager:Destroy()
		end)

		test("an opted-in listener still receives a usable oldValue for a scalar change", function()
			local manager = TableManager.new {
				player = { health = 100 },
			}

			local capturedOld: any = nil
			manager:OnValueChange({ "player", "health" }, function(_newValue, oldValue)
				capturedOld = oldValue
			end, { SnapshotOldValues = true })

			manager.Proxy.player.health = 50

			expect(capturedOld).is(100)

			manager:Destroy()
		end)
	end)
end
