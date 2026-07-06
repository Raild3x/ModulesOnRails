--!strict
--[[
	Specs for the known-delta scalar write fast lane (`Mutator.applyWrite`):
	a scalar->scalar transition at a trackable, opacity-free path in immediate
	flush mode skips the general diff engine — the one-node diff is synthesized
	directly and the baseline is patched incrementally (`Baseline.ApplyLeafSet`)
	instead of a full `Reconcile`.

	These tests pin the lane's OBSERVABLE EQUIVALENCE with the diffed path:
	event payloads and `metadata.Diff` shapes, same-value silence, baseline
	coherence with later flushes (the seed / incremental-patch obligations),
	and re-entrant write ordering (CONTRACT.md "Re-entrant writes are queued").
]]

return function(tiniest)
	local TableManager = require("../../TableManager")

	local describe = tiniest.describe
	local test = tiniest.test
	local expect = tiniest.expect

	describe("Scalar write fast lane", function()
		test("scalar change fires ValueChanged with a childless 'changed' diff node", function()
			local manager = TableManager.new { player = { health = 100 } }

			local seen: any = nil
			manager:OnValueChange("player.health", function(newValue, oldValue, metadata)
				seen = { newValue = newValue, oldValue = oldValue, metadata = metadata }
			end)

			manager:Set("player.health", 55)

			expect(seen).exists()
			expect(seen.newValue).is(55)
			expect(seen.oldValue).is(100)
			-- Shape must be indistinguishable from Diff.diff's scalar tail:
			-- a childless node, old/new carried, no children.
			expect(seen.metadata.Diff.type).is("changed")
			expect(seen.metadata.Diff.old).is(100)
			expect(seen.metadata.Diff.new).is(55)
			expect(seen.metadata.Diff.children).never_exists()
			expect(#seen.metadata.OriginPath).is(2)
			expect(seen.metadata.OriginPath[2]).is("health")

			manager:Destroy()
		end)

		test("nil -> scalar fires 'added'; scalar -> nil fires 'removed'", function()
			local manager = TableManager.new { player = { health = 100 } }

			local diffs: { any } = {}
			manager:OnValueChange("player.mana", function(_newValue, _oldValue, metadata)
				table.insert(diffs, metadata.Diff)
			end)

			manager:Set("player.mana", 25) -- key did not exist: added
			manager:Set("player.mana", nil) -- back to nil: removed

			expect(#diffs).is(2)
			expect(diffs[1].type).is("added")
			expect(diffs[1].old).never_exists()
			expect(diffs[1].new).is(25)
			expect(diffs[2].type).is("removed")
			expect(diffs[2].old).is(25)
			expect(diffs[2].new).never_exists()

			manager:Destroy()
		end)

		test("KeyAdded / KeyChanged / KeyRemoved fire at the parent path", function()
			local manager = TableManager.new { player = { health = 100 } }

			local events: { string } = {}
			manager:OnKeyAdd("player", function(key)
				table.insert(events, `added:{key}`)
			end)
			manager:OnKeyChange("player", function(key)
				table.insert(events, `changed:{key}`)
			end)
			manager:OnKeyRemove("player", function(key)
				table.insert(events, `removed:{key}`)
			end)

			manager:Set("player.mana", 25)
			manager:Set("player.mana", 30)
			manager:Set("player.mana", nil)

			expect(table.find(events, "added:mana")).exists()
			expect(table.find(events, "changed:mana")).exists()
			expect(table.find(events, "removed:mana")).exists()

			manager:Destroy()
		end)

		test("ancestor ValueChanged fires for a deep scalar write", function()
			local manager = TableManager.new {
				a = { b = { c = { value = 1 } } },
			}

			-- OnChange (unbounded depth) is the descendant-hearing listener;
			-- OnValueChange pins ListenDepth = 0 and would filter this out.
			local ancestorFired = 0
			manager:OnChange("a", function()
				ancestorFired += 1
			end)

			manager:Set("a.b.c.value", 2)

			expect(ancestorFired).is(1)
			expect(manager:Get("a.b.c.value")).is(2)

			manager:Destroy()
		end)

		test("same-value write fires nothing", function()
			local manager = TableManager.new { player = { health = 100 } }

			local fired = 0
			manager:OnValueChange("player.health", function()
				fired += 1
			end)
			manager:OnChange("player.health", function()
				fired += 1
			end)

			manager:Set("player.health", 100)

			expect(fired).is(0)
			expect(manager:Get("player.health")).is(100)

			manager:Destroy()
		end)

		test("same-value write keeps a later Flush quiet (baseline stays seeded)", function()
			local manager = TableManager.new { player = { health = 100 } }

			local fired = 0
			manager:OnValueChange("player.health", function()
				fired += 1
			end)

			-- The lane's early-out must still seed the baseline: a later Flush
			-- at/above the path diffs against it and must find nothing.
			manager:Set("player.health", 100)
			manager:Flush("player")
			manager:Flush("player.health")

			expect(fired).is(0)

			manager:Destroy()
		end)

		test("scalar write then Flush at an ancestor does not re-report the change", function()
			local manager = TableManager.new { player = { health = 100 } }

			local fired = 0
			manager:OnValueChange("player.health", function()
				fired += 1
			end)

			-- The incremental baseline patch (ApplyLeafSet) must leave the
			-- baseline == live, so the explicit ancestor flush finds no delta.
			manager:Set("player.health", 55)
			expect(fired).is(1)

			manager:Flush("player")
			expect(fired).is(1)

			manager:Destroy()
		end)

		test("first-ever write at a freshly tracked path stays flush-coherent", function()
			-- Exercises ApplyLeafSet's Materialize fallback: no baseline spine
			-- exists before the first tracked write.
			local manager = TableManager.new { player = { health = 100 } }

			local fired = 0
			manager:OnValueChange("player.health", function()
				fired += 1
			end)

			manager:Set("player.health", 55) -- first tracked write: fallback seeds the spine
			manager:Set("player.health", 60) -- second write: incremental patch
			expect(fired).is(2)

			manager:Flush("player")
			expect(fired).is(2)

			manager:Destroy()
		end)

		test("re-entrant clamp write delivers the outer event first and converges", function()
			local manager = TableManager.new { player = { health = 10 } }

			local deliveries: { { new: number, old: number } } = {}
			manager:OnValueChange("player.health", function(newValue, oldValue)
				table.insert(deliveries, { new = newValue, old = oldValue })
				if newValue > 50 then
					manager:Set("player.health", 50) -- clamp from inside the listener
				end
			end)

			manager:Set("player.health", 80)

			-- CONTRACT: the outer write's events deliver before the events of
			-- any write it triggered, and the stream converges on the final value.
			expect(#deliveries).is(2)
			expect(deliveries[1].new).is(80)
			expect(deliveries[1].old).is(10)
			expect(deliveries[2].new).is(50)
			expect(deliveries[2].old).is(80)
			expect(manager:Get("player.health")).is(50)

			manager:Destroy()
		end)

		test("OnApplied receives a Set op carrying the diff for a fast-lane write", function()
			local manager = TableManager.new { player = { health = 100 } }

			-- A local listener makes the path trackable, routing the write
			-- through the fast lane (not the untracked direct-ship fallback).
			manager:OnValueChange("player.health", function() end)

			local ops: { any } = {}
			manager:OnApplied(function(op)
				table.insert(ops, op)
			end)

			manager:Set("player.health", 55)

			expect(#ops).is(1)
			expect(ops[1].Kind).is("Set")
			expect(ops[1].Path[1]).is("player")
			expect(ops[1].Path[2]).is("health")
			expect(ops[1].Diff).exists()
			expect(ops[1].Diff.new).is(55)

			manager:Destroy()
		end)
	end)
end
