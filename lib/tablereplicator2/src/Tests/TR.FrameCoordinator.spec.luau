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
			local repA = ServerReplicator.new({ Token = uniqueToken("OrderA"), Data = { x = 0 }, ReplicationTargets = { player } })
			local repB = ServerReplicator.new({ Token = uniqueToken("OrderB"), Data = { y = 0 }, ReplicationTargets = { player } })
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
			local replicator = ServerReplicator.new({ Token = uniqueToken("MergeRun"), Data = { x = 0 }, ReplicationTargets = { player } })
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
				ServerReplicator.new({ Token = uniqueToken("MidFrameAdd"), Data = { x = 0 }, ReplicationTargets = { existing } })
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
				ServerReplicator.new({ Token = uniqueToken("MidFrameRemove"), Data = { x = 0 }, ReplicationTargets = { stayer, leaver } })
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
			local repA = ServerReplicator.new({ Token = uniqueToken("DisjointA"), Data = { x = 0 }, ReplicationTargets = { playerA } })
			local repB = ServerReplicator.new({ Token = uniqueToken("DisjointB"), Data = { y = 0 }, ReplicationTargets = { playerB } })
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
end
