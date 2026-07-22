--!strict
--[[
	Coverage for `FrameCoordinator`, the single server-wide ordering point for
	outbound data ops (see its module doc for the full rationale). Server-side
	behavior is asserted by spying on `ServerReplicator._Transport` directly
	-- a test-only escape hatch, not part of the public API. `Player` targets
	are plain tables (`:: any`-cast): this code only ever uses a player value
	as an opaque dictionary key.
]]

return function(t: tiniest)
	local ServerReplicator = require("../Server/ServerReplicator")
	local FrameCoordinator = require("../Server/FrameCoordinator")
	local FlatCodec = require("../Shared/Serialization/FlatCodec")
	local SpecUtils = require("./Helpers/SpecUtils")

	local describe = t.describe
	local test = t.test
	local expect = t.expect

	local uniqueToken = SpecUtils.uniqueToken
	local spyOnTransport = SpecUtils.spyOnTransport

	--------------------------------------------------------------------------------

	describe("FrameCoordinator global ordering", function()
		test("interleaved ops across two replicators replay in one message in server order", function()
			local player = { Name = "P" } :: any
			local repA = ServerReplicator.new({ Namespace = uniqueToken("OrderA"), Data = { x = 0 }, ReplicationTargets = { player } })
			local repB = ServerReplicator.new({ Namespace = uniqueToken("OrderB"), Data = { y = 0 }, ReplicationTargets = { player } })
			;(repA :: any)._Scope:Activate(player)
			;(repB :: any)._Scope:Activate(player)

			local calls, restore = spyOnTransport()
			repA.Manager:Set("x", 1)
			repB.Manager:Set("y", 1)
			repA.Manager:Set("x", 2)
			;(ServerReplicator :: any)._FrameCoordinator:Flush()
			restore()

			-- One message to the player. A's two Sets are NOT adjacent (B's Set
			-- landed between them), so they stay separate items in A, B, A order
			-- -- exactly the cross-replicator interleave per-scope flushing lost.
			expect(#calls).is(1)
			local items = calls[1].Message.Items
			expect(#items).is(3)
			expect(items[1].Id).is(repA.Id)
			expect(items[2].Id).is(repB.Id)
			expect(items[3].Id).is(repA.Id)

			repA:Destroy()
			repB:Destroy()
		end)

		test("consecutive ops for one replicator merge into a single Ops item", function()
			local player = { Name = "P" } :: any
			local replicator = ServerReplicator.new({ Namespace = uniqueToken("MergeRun"), Data = { x = 0 }, ReplicationTargets = { player } })
			;(replicator :: any)._Scope:Activate(player)

			local calls, restore = spyOnTransport()
			replicator.Manager:Set("x", 1)
			replicator.Manager:Set("x", 2)
			;(ServerReplicator :: any)._FrameCoordinator:Flush()
			restore()

			expect(#calls).is(1)
			local items = calls[1].Message.Items
			expect(#items).is(1)
			expect(items[1].Id).is(replicator.Id)
			expect(#items[1].Ops).is(2)

			replicator:Destroy()
		end)

		test("an op enqueued before a mid-frame target add is not sent to the new player", function()
			local existing = { Name = "Existing" } :: any
			local late = { Name = "Late" } :: any
			local replicator =
				ServerReplicator.new({ Namespace = uniqueToken("MidFrameAdd"), Data = { x = 0 }, ReplicationTargets = { existing } })
			;(replicator :: any)._Scope:Activate(existing)

			local calls, restore = spyOnTransport()
			-- Op enqueued while only `existing` is active...
			replicator.Manager:Set("x", 1)
			-- ...then `late` becomes active mid-frame, the way a snapshot send would.
			;(replicator :: any)._Scope:Activate(late)
			;(ServerReplicator :: any)._FrameCoordinator:Flush()
			restore()

			local byPlayer: { [any]: any } = {}
			for _, call in calls do
				byPlayer[call.Player] = call.Message
			end
			expect(byPlayer[existing]).never_is(nil)
			expect(byPlayer[late]).is(nil)

			replicator:Destroy()
		end)

		test("an op enqueued after a mid-frame target remove is not sent to the removed player", function()
			local stayer = { Name = "Stayer" } :: any
			local leaver = { Name = "Leaver" } :: any
			local replicator =
				ServerReplicator.new({ Namespace = uniqueToken("MidFrameRemove"), Data = { x = 0 }, ReplicationTargets = { stayer, leaver } })
			;(replicator :: any)._Scope:Activate(stayer)
			;(replicator :: any)._Scope:Activate(leaver)

			local calls, restore = spyOnTransport()
			replicator.Manager:Set("x", 1)
			;(replicator :: any)._Scope:RemoveActive(leaver)
			;(ServerReplicator :: any)._FrameCoordinator:Flush()
			restore()

			local byPlayer: { [any]: any } = {}
			for _, call in calls do
				byPlayer[call.Player] = call.Message
			end
			expect(byPlayer[stayer]).never_is(nil)
			expect(byPlayer[leaver]).is(nil)

			replicator:Destroy()
		end)

		test("ops for two different replicators going to two disjoint audiences each reach only their own player", function()
			local playerA = { Name = "A" } :: any
			local playerB = { Name = "B" } :: any
			local repA = ServerReplicator.new({ Namespace = uniqueToken("DisjointA"), Data = { x = 0 }, ReplicationTargets = { playerA } })
			local repB = ServerReplicator.new({ Namespace = uniqueToken("DisjointB"), Data = { y = 0 }, ReplicationTargets = { playerB } })
			;(repA :: any)._Scope:Activate(playerA)
			;(repB :: any)._Scope:Activate(playerB)

			local calls, restore = spyOnTransport()
			repA.Manager:Set("x", 1)
			repB.Manager:Set("y", 1)
			;(ServerReplicator :: any)._FrameCoordinator:Flush()
			restore()

			expect(#calls).is(2)
			local byPlayer: { [any]: any } = {}
			for _, call in calls do
				byPlayer[call.Player] = call.Message.Items[1]
			end
			expect(byPlayer[playerA].Id).is(repA.Id)
			expect(byPlayer[playerB].Id).is(repB.Id)

			repA:Destroy()
			repB:Destroy()
		end)
	end)

	--------------------------------------------------------------------------------

	describe("FrameCoordinator coalescing (opt-in per-replicator)", function()
		test("repeated same-path Sets on a coalesced replicator collapse to one op carrying the final value", function()
			local player = { Name = "P" } :: any
			local replicator = ServerReplicator.new({
				Namespace = uniqueToken("CoalesceSamePath"),
				Data = { x = 0 },
				ReplicationTargets = { player },
				Coalesced = true,
			})
			;(replicator :: any)._Scope:Activate(player)

			local calls, restore = spyOnTransport()
			replicator.Manager:Set("x", 1)
			replicator.Manager:Set("x", 2)
			replicator.Manager:Set("x", 3)
			;(ServerReplicator :: any)._FrameCoordinator:Flush()
			restore()

			expect(#calls).is(1)
			local items = calls[1].Message.Items
			expect(#items).is(1)
			expect(#items[1].Ops).is(1)
			local decoded = FlatCodec.DecodeOps(items[1])
			expect(decoded[1].Value).is(3)

			replicator:Destroy()
		end)

		test("a later ancestor Set drops an already-buffered descendant Set on the same coalesced replicator", function()
			local player = { Name = "P" } :: any
			local replicator =
				ServerReplicator.new({ Namespace = uniqueToken("CoalesceAncestor"), Data = { Stats = { Hp = 10 } }, ReplicationTargets = { player } })
			local scope = (replicator :: any)._Scope
			scope:Activate(player)
			local coordinator = (ServerReplicator :: any)._FrameCoordinator

			local calls, restore = spyOnTransport()
			coordinator:QueueOp(scope, replicator.Id, { Kind = "Set", Path = { "Stats", "Hp" }, NewValue = 50 } :: any, true)
			coordinator:QueueOp(
				scope,
				replicator.Id,
				{ Kind = "Set", Path = { "Stats" }, NewValue = { Hp = 1, Mp = 1 } } :: any,
				true
			)
			coordinator:Flush()
			restore()

			expect(#calls).is(1)
			local items = calls[1].Message.Items
			expect(#items).is(1)
			expect(#items[1].Ops).is(1)
			local decoded = FlatCodec.DecodeOps(items[1])
			expect(#decoded[1].Path).is(1)
			expect(decoded[1].Path[1]).is("Stats")
			expect(decoded[1].Value.Hp).is(1)

			replicator:Destroy()
		end)

		test("a descendant Set after an ancestor Set is kept (refines the leaf, not subsumed)", function()
			local player = { Name = "P" } :: any
			local replicator =
				ServerReplicator.new({ Namespace = uniqueToken("CoalesceDescendantAfter"), Data = { Stats = { Hp = 10 } }, ReplicationTargets = { player } })
			local scope = (replicator :: any)._Scope
			scope:Activate(player)
			local coordinator = (ServerReplicator :: any)._FrameCoordinator

			local calls, restore = spyOnTransport()
			coordinator:QueueOp(
				scope,
				replicator.Id,
				{ Kind = "Set", Path = { "Stats" }, NewValue = { Hp = 1, Mp = 1 } } :: any,
				true
			)
			coordinator:QueueOp(scope, replicator.Id, { Kind = "Set", Path = { "Stats", "Hp" }, NewValue = 99 } :: any, true)
			coordinator:Flush()
			restore()

			expect(#calls).is(1)
			local items = calls[1].Message.Items
			expect(#items).is(1)
			expect(#items[1].Ops).is(2)
			local decoded = FlatCodec.DecodeOps(items[1])
			expect(#decoded[1].Path).is(1)
			expect(#decoded[2].Path).is(2)
			expect(decoded[2].Value).is(99)

			replicator:Destroy()
		end)

		test("an array op barriers coalescing: Sets before and after it on the same path are not merged", function()
			local player = { Name = "P" } :: any
			local replicator =
				ServerReplicator.new({ Namespace = uniqueToken("CoalesceArrayBarrier"), Data = { Items = {} }, ReplicationTargets = { player } })
			local scope = (replicator :: any)._Scope
			scope:Activate(player)
			local coordinator = (ServerReplicator :: any)._FrameCoordinator

			local calls, restore = spyOnTransport()
			coordinator:QueueOp(scope, replicator.Id, { Kind = "Set", Path = { "Items" }, NewValue = { "a" } } :: any, true)
			coordinator:QueueOp(
				scope,
				replicator.Id,
				{ Kind = "ArrayInsert", Path = { "Items" }, Index = 2, NewValue = "b" } :: any,
				true
			)
			coordinator:QueueOp(
				scope,
				replicator.Id,
				{ Kind = "Set", Path = { "Items" }, NewValue = { "a", "b", "c" } } :: any,
				true
			)
			coordinator:Flush()
			restore()

			expect(#calls).is(1)
			local items = calls[1].Message.Items
			expect(#items).is(1)
			-- Set, ArrayInsert, Set -- none collapsed across the array-op barrier.
			expect(#items[1].Ops).is(3)
			local decoded = FlatCodec.DecodeOps(items[1])
			expect(decoded[1].Kind).is("Set")
			expect(decoded[2].Kind).is("ArrayInsert")
			expect(decoded[3].Kind).is("Set")

			replicator:Destroy()
		end)

		test("BatchBegin/BatchEnd markers are dropped entirely for a coalesced replicator", function()
			local player = { Name = "P" } :: any
			local replicator = ServerReplicator.new({ Namespace = uniqueToken("CoalesceBatchMarkers"), Data = { x = 0 }, ReplicationTargets = { player } })
			local scope = (replicator :: any)._Scope
			scope:Activate(player)
			local coordinator = (ServerReplicator :: any)._FrameCoordinator

			local calls, restore = spyOnTransport()
			coordinator:QueueOp(scope, replicator.Id, { Kind = "BatchBegin", Path = {} } :: any, true)
			coordinator:QueueOp(scope, replicator.Id, { Kind = "Set", Path = { "x" }, NewValue = 1 } :: any, true)
			coordinator:QueueOp(scope, replicator.Id, { Kind = "BatchEnd", Path = {} } :: any, true)
			coordinator:Flush()
			restore()

			expect(#calls).is(1)
			local items = calls[1].Message.Items
			expect(#items).is(1)
			expect(#items[1].Ops).is(1)
			local decoded = FlatCodec.DecodeOps(items[1])
			expect(decoded[1].Kind).is("Set")

			replicator:Destroy()
		end)

		test("a coalesced replicator's in-place update sorts to its last-write position, preserving cross-replicator order", function()
			local player = { Name = "P" } :: any
			local repA = ServerReplicator.new({ Namespace = uniqueToken("CoalesceOrderA"), Data = { x = 0 }, ReplicationTargets = { player } })
			local repB = ServerReplicator.new({ Namespace = uniqueToken("CoalesceOrderB"), Data = { y = 0 }, ReplicationTargets = { player } })
			local scopeA = (repA :: any)._Scope
			local scopeB = (repB :: any)._Scope
			scopeA:Activate(player)
			scopeB:Activate(player)
			local coordinator = (ServerReplicator :: any)._FrameCoordinator

			local calls, restore = spyOnTransport()
			-- A writes "x", then B writes "y", then A rewrites "x" (coalesced,
			-- in place) -- the merged A op must sort AFTER B's, since A's last
			-- write happened after B's.
			coordinator:QueueOp(scopeA, repA.Id, { Kind = "Set", Path = { "x" }, NewValue = 1 } :: any, true)
			coordinator:QueueOp(scopeB, repB.Id, { Kind = "Set", Path = { "y" }, NewValue = 1 } :: any, false)
			coordinator:QueueOp(scopeA, repA.Id, { Kind = "Set", Path = { "x" }, NewValue = 2 } :: any, true)
			coordinator:Flush()
			restore()

			expect(#calls).is(1)
			local items = calls[1].Message.Items
			expect(#items).is(2)
			expect(items[1].Id).is(repB.Id)
			expect(items[2].Id).is(repA.Id)
			local decodedA = FlatCodec.DecodeOps(items[2])
			expect(decodedA[1].Value).is(2)

			repA:Destroy()
			repB:Destroy()
		end)

		test("dropping a coalesced replicator clears its pending coalesce slots", function()
			local player = { Name = "P" } :: any
			local replicator = ServerReplicator.new({ Namespace = uniqueToken("CoalesceDropClears"), Data = { x = 0 }, ReplicationTargets = { player } })
			local scope = (replicator :: any)._Scope
			scope:Activate(player)
			local coordinator = (ServerReplicator :: any)._FrameCoordinator

			local calls, restore = spyOnTransport()
			coordinator:QueueOp(scope, replicator.Id, { Kind = "Set", Path = { "x" }, NewValue = 1 } :: any, true)
			replicator:Destroy() -- drops the queued Set + its coalesce slot
			coordinator:Flush()
			restore()

			-- Only the (synchronous) Destroy item should have been sent; the
			-- dropped coalesced Set must not resurface at flush.
			for _, call in calls do
				for _, item in call.Message.Items do
					expect(item.Op).never_is(FlatCodec.Op.Ops)
				end
			end
		end)
	end)

	--------------------------------------------------------------------------------

	describe("FrameCoordinator per-replicator flush (FlushReplicator)", function()
		test("sends only the target replicator's ops and leaves other replicators' entries buffered", function()
			local player = { Name = "P" } :: any
			local repA = ServerReplicator.new({ Namespace = uniqueToken("FlushReplA"), Data = { x = 0 }, ReplicationTargets = { player } })
			local repB = ServerReplicator.new({ Namespace = uniqueToken("FlushReplB"), Data = { y = 0 }, ReplicationTargets = { player } })
			local scopeA = (repA :: any)._Scope
			local scopeB = (repB :: any)._Scope
			scopeA:Activate(player)
			scopeB:Activate(player)
			local coordinator = (ServerReplicator :: any)._FrameCoordinator

			local calls, restore = spyOnTransport()
			coordinator:QueueOp(scopeA, repA.Id, { Kind = "Set", Path = { "x" }, NewValue = 1 } :: any, false)
			coordinator:QueueOp(scopeB, repB.Id, { Kind = "Set", Path = { "y" }, NewValue = 1 } :: any, false)

			-- Flush only A: exactly one message, carrying only A's op.
			coordinator:FlushReplicator(repA.Id)
			expect(#calls).is(1)
			expect(#calls[1].Message.Items).is(1)
			expect(calls[1].Message.Items[1].Id).is(repA.Id)

			-- B's entry is still buffered -- a plain Flush now sends it.
			coordinator:Flush()
			expect(#calls).is(2)
			expect(calls[2].Message.Items[1].Id).is(repB.Id)
			restore()

			repA:Destroy()
			repB:Destroy()
		end)

		test("is a no-op when the target replicator has no queued entries", function()
			local player = { Name = "P" } :: any
			local repA = ServerReplicator.new({ Namespace = uniqueToken("FlushReplEmptyA"), Data = { x = 0 }, ReplicationTargets = { player } })
			local repB = ServerReplicator.new({ Namespace = uniqueToken("FlushReplEmptyB"), Data = { y = 0 }, ReplicationTargets = { player } })
			local scopeB = (repB :: any)._Scope
			scopeB:Activate(player)
			local coordinator = (ServerReplicator :: any)._FrameCoordinator

			local calls, restore = spyOnTransport()
			coordinator:QueueOp(scopeB, repB.Id, { Kind = "Set", Path = { "y" }, NewValue = 1 } :: any, false)

			-- A has nothing queued -> no send, and B's entry is untouched.
			coordinator:FlushReplicator(repA.Id)
			expect(#calls).is(0)

			coordinator:Flush()
			expect(#calls).is(1)
			expect(calls[1].Message.Items[1].Id).is(repB.Id)
			restore()

			repA:Destroy()
			repB:Destroy()
		end)
	end)

	--------------------------------------------------------------------------------

	describe("FrameCoordinator deferred auto-flush (scheduler seam)", function()
		test("a queued op auto-flushes on the scheduler pump, without an explicit Flush", function()
			local player = { Name = "P" } :: any
			local replicator =
				ServerReplicator.new({ Namespace = uniqueToken("AutoFlush"), Data = { x = 0 }, ReplicationTargets = { player } })
			;(replicator :: any)._Scope:Activate(player)

			local calls, restore = spyOnTransport()
			-- The write enqueues the op and marks the shared coordinator scheduled;
			-- it does NOT flush synchronously.
			replicator.Manager:Set("x", 1)

			-- Drive the scheduler exactly as the live Heartbeat connection would,
			-- then let the deferred drain run across the next couple of frames --
			-- no direct coordinator:Flush(), so this covers the real reschedule path.
			FrameCoordinator._PumpScheduler()
			task.wait()
			task.wait()
			restore()

			local sawOp = false
			for _, call in calls do
				for _, item in call.Message.Items do
					if item.Id == replicator.Id then
						sawOp = true
					end
				end
			end
			expect(sawOp).is_true()

			replicator:Destroy()
		end)

		test("pumping an idle scheduler is a no-op", function()
			-- Drain anything a previous test left scheduled, then pump again with
			-- an empty schedule.
			FrameCoordinator._PumpScheduler()
			task.wait()
			task.wait()
			expect(function()
				FrameCoordinator._PumpScheduler()
			end).never_fails()
		end)
	end)

	--------------------------------------------------------------------------------

	describe("FrameCoordinator audience cache invalidation", function()
		test("an activation between two enqueues refreshes the cached audience", function()
			local early = { Name = "Early" } :: any
			local late = { Name = "Late" } :: any
			local replicator = ServerReplicator.new({
				Namespace = uniqueToken("AudienceCacheStale"),
				Data = { x = 0 },
				ReplicationTargets = { early, late },
			})
			local scope = (replicator :: any)._Scope
			scope:Activate(early)

			local calls, restore = spyOnTransport()
			replicator.Manager:Set("x", 1) -- audience cached as { early }
			scope:Activate(late) -- bumps the scope's active version
			replicator.Manager:Set("x", 2) -- stale cache detected, re-captured
			;(ServerReplicator :: any)._FrameCoordinator:Flush()
			restore()

			local opsSeen: { [any]: number } = {}
			for _, call in calls do
				local decoded = FlatCodec.DecodeOps(call.Message.Items[1])
				opsSeen[call.Player] = #decoded
			end
			expect(opsSeen[early]).is(2) -- both writes
			expect(opsSeen[late]).is(1) -- only the write enqueued after activation

			replicator:Destroy()
		end)
	end)

	--------------------------------------------------------------------------------

	describe("FrameCoordinator coalescing with disjoint array ops", function()
		test("an array op on a disjoint path leaves a pending coalesced Set untouched", function()
			local player = { Name = "P" } :: any
			local replicator = ServerReplicator.new({
				Namespace = uniqueToken("CoalesceDisjointArray"),
				Data = { a = 0, list = {} },
				ReplicationTargets = { player },
			})
			local scope = (replicator :: any)._Scope
			scope:Activate(player)
			local coordinator = (ServerReplicator :: any)._FrameCoordinator

			local calls, restore = spyOnTransport()
			coordinator:QueueOp(scope, replicator.Id, { Kind = "Set", Path = { "a" }, NewValue = 1 } :: any, true)
			-- Disjoint path: must NOT invalidate the pending Set slot on { a }.
			coordinator:QueueOp(
				scope,
				replicator.Id,
				{ Kind = "ArrayInsert", Path = { "list" }, Index = 1, NewValue = "x" } :: any,
				true
			)
			-- A follow-up Set on { a } must still coalesce into the original slot.
			coordinator:QueueOp(scope, replicator.Id, { Kind = "Set", Path = { "a" }, NewValue = 2 } :: any, true)
			coordinator:Flush()
			restore()

			expect(#calls).is(1)
			local decoded = FlatCodec.DecodeOps(calls[1].Message.Items[1])
			expect(#decoded).is(2) -- coalesced Set + the array op, not three entries
			local kinds: { [string]: any } = {}
			for _, op in decoded do
				kinds[op.Kind] = op
			end
			expect(kinds.Set.Value).is(2)
			expect(kinds.ArrayInsert.Value).is("x")

			replicator:Destroy()
		end)
	end)
end
