--!strict
--[[
	Tests for `Config.FlushMode = "coalesced"` (CoalescedFlush.luau): instead
	of running a direct write's diff+fire+reconcile cycle (`_doFlush`)
	synchronously, it defers that cycle to frame-end (`task.defer`) and merges
	every path flushed before then into one pending flush root — their common
	ancestor — so N writes under one subtree in a frame cost one shadow
	diff/reconcile instead of N. Covers:
	- The basic defer-and-merge-to-one-fire behavior, frame-start old / final new.
	- The ancestor-merge math itself (siblings collapse up; a descendant of the
	  current root doesn't widen it; unrelated branches widen to the root).
	- The persistent shadow staying at its frame-start baseline until the
	  deferred flush actually runs.
	- A write made from inside the deferred flush's own listener still gets a
	  correct, separate flush (not lost, not double-fired).
	- `Suspend`/`Flush` draining any still-pending coalesced flush first, so a
	  baseline read taken directly off live data (Batch's pre-batch snapshot,
	  an explicit Flush) can never silently absorb a not-yet-reported
	  transition the pending flush was holding.
	- `FlushMode = "immediate"` (the default) is unchanged.
]]

return function(t: tiniest)
	const TableManager = require("../TableManager")
	const ShadowNode = require("../ShadowNode")

	const test = t.test
	const describe = t.describe
	const expect = t.expect

	describe("FlushMode = coalesced", function()
		test("multiple Sets to the same path in a frame fire exactly once at frame-end with frame-start old and final new", function()
			const manager = TableManager.new({
				player = { hp = 100 },
			}, {
				FlushMode = "coalesced",
			})

			const fires: { { new: any, old: any } } = {}
			manager:OnValueChange("player.hp", function(newValue, oldValue)
				table.insert(fires, { new = newValue, old = oldValue })
			end)

			manager:Set("player.hp", 90)
			manager:Set("player.hp", 80)
			manager:Set("player.hp", 70)

			expect(#fires).is(0) -- flush deferred; nothing fired synchronously
			expect(manager:Get("player.hp")).is(70) -- the write itself is never deferred

			task.wait()

			expect(#fires).is(1)
			expect(fires[1].old).is(100)
			expect(fires[1].new).is(70)

			manager:Destroy()
		end)

		test("sibling deep writes in a frame collapse the pending root to their common ancestor; each leaf still fires once", function()
			const manager = TableManager.new({
				a = { b = { x = 1 }, c = { y = 2 } },
			}, {
				FlushMode = "coalesced",
			})

			const bxFires: { { new: any, old: any } } = {}
			const cyFires: { { new: any, old: any } } = {}
			manager:OnValueChange("a.b.x", function(newValue, oldValue)
				table.insert(bxFires, { new = newValue, old = oldValue })
			end)
			manager:OnValueChange("a.c.y", function(newValue, oldValue)
				table.insert(cyFires, { new = newValue, old = oldValue })
			end)

			manager:Set("a.b.x", 10)
			expect((manager :: any)._pendingFlushRoot).is_shallow_equal { "a", "b", "x" }

			manager:Set("a.c.y", 20)
			expect((manager :: any)._pendingFlushRoot).is_shallow_equal { "a" }

			expect(#bxFires).is(0)
			expect(#cyFires).is(0)

			task.wait()

			expect(#bxFires).is(1)
			expect(bxFires[1].old).is(1)
			expect(bxFires[1].new).is(10)
			expect(#cyFires).is(1)
			expect(cyFires[1].old).is(2)
			expect(cyFires[1].new).is(20)

			manager:Destroy()
		end)

		test("a descendant write after an ancestor write does not widen the pending root", function()
			const manager = TableManager.new({
				a = { b = { x = 1 } },
			}, {
				FlushMode = "coalesced",
			})
			manager:OnValueChange("a.b", function() end)
			manager:OnValueChange("a.b.x", function() end)

			manager:Set("a.b", { x = 2 })
			expect((manager :: any)._pendingFlushRoot).is_shallow_equal { "a", "b" }

			-- {"a","b","x"} is a descendant of the current root {"a","b"}; the
			-- common ancestor of the two is still {"a","b"} -- it must not widen.
			manager:Set("a.b.x", 3)
			expect((manager :: any)._pendingFlushRoot).is_shallow_equal { "a", "b" }

			task.wait()
			expect(manager:Get("a.b.x")).is(3)

			manager:Destroy()
		end)

		test("writes under unrelated root branches widen the pending root to the whole tree; each leaf still fires once", function()
			const manager = TableManager.new({
				a = { x = 1 },
				q = { y = 2 },
			}, {
				FlushMode = "coalesced",
			})

			local aFires, qFires = 0, 0
			manager:OnValueChange("a.x", function()
				aFires += 1
			end)
			manager:OnValueChange("q.y", function()
				qFires += 1
			end)

			manager:Set("a.x", 10)
			manager:Set("q.y", 20)

			expect((manager :: any)._pendingFlushRoot).is_shallow_equal {}

			task.wait()

			expect(aFires).is(1)
			expect(qFires).is(1)
			expect(manager:Get("a.x")).is(10)
			expect(manager:Get("q.y")).is(20)

			manager:Destroy()
		end)

		test("the shadow stays at its frame-start baseline until the deferred flush actually runs", function()
			const manager = TableManager.new({ x = 1 }, { FlushMode = "coalesced" })
			manager:OnValueChange("x", function() end) -- make "x" trackable

			manager:Set("x", 2)
			expect(ShadowNode.Get((manager :: any).Raw, { "x" })).is(1)

			manager:Set("x", 3)
			expect(ShadowNode.Get((manager :: any).Raw, { "x" })).is(1) -- still frame-start, not 2

			local capturedOld: any
			manager:OnValueChange("x", function(_newValue, oldValue)
				capturedOld = oldValue
			end)

			task.wait()

			expect(capturedOld).is(1)
			expect(ShadowNode.Get((manager :: any).Raw, { "x" })).is(3)

			manager:Destroy()
		end)

		test("a write made from inside the deferred flush's own listener still gets a correct, separate flush", function()
			const manager = TableManager.new({ x = 1, y = 10 }, { FlushMode = "coalesced" })

			local yFireCount = 0
			local capturedYOld: any
			manager:OnValueChange("y", function(_newValue, oldValue)
				yFireCount += 1
				capturedYOld = oldValue
			end)

			local reentered = false
			manager:OnValueChange("x", function()
				if not reentered then
					reentered = true
					manager:Set("y", 20) -- re-entrant write during the x flush
				end
			end)

			manager:Set("x", 2)

			-- The re-entrant y-write schedules its OWN coalesced flush, which may
			-- land on a later defer tick than the one that ran the x flush -- wait
			-- across a bounded number of ticks rather than assuming exactly one.
			for _ = 1, 5 do
				if yFireCount > 0 then
					break
				end
				task.wait()
			end

			expect(yFireCount).is(1) -- exactly once: not lost, not double-fired
			expect(capturedYOld).is(10)
			expect(manager:Get("y")).is(20)

			manager:Destroy()
		end)

		test("Batch force-flushes a pending coalesced write first, so no transition is dropped across Suspend's snapshot", function()
			const manager = TableManager.new({ x = 0 }, { FlushMode = "coalesced" })

			const seen: { { new: any, old: any } } = {}
			manager:OnValueChange("x", function(newValue, oldValue)
				table.insert(seen, { new = newValue, old = oldValue })
			end)

			manager:Set("x", 1) -- schedules a coalesced flush; not yet drained

			manager:Batch(function()
				manager:Set("x", 2)
			end)

			-- Resume runs synchronously; it must have force-flushed the pending
			-- "0 -> 1" transition BEFORE Suspend took its own pre-batch snapshot,
			-- otherwise that transition is silently absorbed and never reported.
			expect(#seen).is(2)
			expect(seen[1].old).is(0)
			expect(seen[1].new).is(1)
			expect(seen[2].old).is(1)
			expect(seen[2].new).is(2)

			-- No leftover pending state, and no double-fire when the original
			-- (now-stale) deferred flush eventually runs.
			task.wait()
			expect(#seen).is(2)

			manager:Destroy()
		end)

		test("an explicit Flush drains a pending coalesced write first, so no transition is dropped", function()
			const manager = TableManager.new({ x = 0 }, { FlushMode = "coalesced" })

			const seen: { { new: any, old: any } } = {}
			manager:OnValueChange("x", function(newValue, oldValue)
				table.insert(seen, { new = newValue, old = oldValue })
			end)

			manager:Set("x", 1) -- schedules a coalesced flush; not yet drained

			-- A direct Raw mutation that bypasses Set/Proxy entirely, then an
			-- explicit Flush to surface it -- Flush's documented use case.
			const raw: any = manager.Raw
			raw.x = 2

			manager:Flush("x")

			expect(#seen).is(1)
			expect(seen[1].old).is(0)
			expect(seen[1].new).is(2)

			task.wait()
			expect(#seen).is(1) -- the now-stale deferred flush is a no-op

			manager:Destroy()
		end)

		test("FlushMode = immediate (the default) still flushes synchronously per Set, unchanged", function()
			const manager = TableManager.new { x = 1 }

			local fireCount = 0
			local lastNew: any, lastOld: any
			manager:OnValueChange("x", function(newValue, oldValue)
				fireCount += 1
				lastNew = newValue
				lastOld = oldValue
			end)

			manager:Set("x", 2)
			expect(fireCount).is(1) -- fired synchronously, no task.wait() needed
			expect(lastNew).is(2)
			expect(lastOld).is(1)

			manager:Set("x", 3)
			expect(fireCount).is(2)

			manager:Destroy()
		end)
	end)
end
