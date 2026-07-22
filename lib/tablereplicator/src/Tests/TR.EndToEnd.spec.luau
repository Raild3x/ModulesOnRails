--!strict
--[[
	End-to-end coverage that crosses module boundaries: the full
	OnApplied -> OpBuffer -> FlatCodec -> OpApplier round trip, and the
	`FakeIntermediary` test helper (see Tests/Helpers/FakeIntermediary.luau)
	that bridges a real `ServerReplicator` and a real `ClientReplicator`
	world in one process, so these tests drive the real server API and
	assert on real client-side `BaseReplicator` state instead of inspecting
	wire-message shape or hand-building messages.
]]

return function(t: tiniest)
	local OpBuffer = require("../Shared/OpBuffer")
	local FlatCodec = require("../Shared/Serialization/FlatCodec")
	local MessageCodec = require("../Shared/Serialization/MessageCodec")
	local BaseReplicator = require("../Shared/BaseReplicator")
	local ServerReplicator = require("../Server/ServerReplicator")
	local OpApplier = require("../Client/OpApplier")
	local Types = require("../Shared/Types")
	local TableManagerModule = Types.TableManager
	local FakeIntermediary = require("./Helpers/FakeIntermediary")
	local SpecUtils = require("./Helpers/SpecUtils")

	local describe = t.describe
	local test = t.test
	local expect = t.expect

	local uniqueToken = SpecUtils.uniqueToken
	local getTokenName = SpecUtils.getTokenName
	local deepEqual = SpecUtils.deepEqual
	local wireCopy = SpecUtils.wireCopy
	local spyOnTransport = SpecUtils.spyOnTransport

	--------------------------------------------------------------------------------

	describe("End-to-end op fidelity (OnApplied -> OpBuffer -> FlatCodec -> OpApplier)", function()
		test("a sequence of Set/Increment/Array/Batch ops reproduces identical Raw state", function()
			local initial = { Coins = 0, Player = { Name = "Foo" }, Items = { "a", "b" } }
			local source = TableManagerModule.new(wireCopy(initial))
			local replica = TableManagerModule.new(wireCopy(initial))

			local buffer = OpBuffer.new()
			source:OnApplied(function(op)
				buffer:Push(1, op)
			end)

			source:Set("Coins", 100)
			source:Increment("Coins", 50)
			source:Set("Player.Name", "Bar")
			source:ArrayInsert("Items", "c")
			source:ArrayRemove("Items", 1)
			source:Batch(function()
				source:Set("Coins", 1)
				source:ArrayInsert("Items", "d")
			end)

			local drained = buffer:Drain()
			expect(#drained).is(1)

			-- Round-trip through the actual wire codec, not just OpApplier
			-- directly, so the test also proves the codec preserves fidelity.
			local opsItem = FlatCodec.OpsItem(drained[1].Id, drained[1].Ops)
			local message = FlatCodec.BuildMessage { opsItem }
			local decodedOps = FlatCodec.DecodeOps(message.Items[1] :: any)

			OpApplier.Apply(replica, decodedOps)

			expect(deepEqual(source.Raw, replica.Raw)).is_true()
		end)
	end)

	--------------------------------------------------------------------------------

	describe("FakeIntermediary (server -> client end-to-end)", function()
		test("RequestData delivers an already-targeted replicator's snapshot to the client", function()
			local token = uniqueToken("FakeIntermediarySnapshot")
			local intermediary = FakeIntermediary.new()
			local client = intermediary:Connect()

			local replicator =
				ServerReplicator.new { Namespace = token, Data = { Coins = 5 }, ReplicationTargets = { client.Player } }
			client:RequestData()

			local mirrored = client:GetFromId(replicator.Id) :: any
			expect(mirrored).never_is(nil)
			expect(mirrored.Namespace).is(getTokenName(token))
			expect(mirrored.Manager.Raw.Coins).is(5)

			replicator:Destroy()
			intermediary:Destroy()
		end)

		test("a data op delivered after FrameCoordinator:Flush lands on the client", function()
			local token = uniqueToken("FakeIntermediaryOps")
			local intermediary = FakeIntermediary.new()
			local client = intermediary:Connect()

			local replicator =
				ServerReplicator.new { Namespace = token, Data = { Coins = 0 }, ReplicationTargets = { client.Player } }
			client:RequestData()

			replicator.Manager:Set("Coins", 42);
			(ServerReplicator :: any)._FrameCoordinator:Flush()

			local mirrored = client:GetFromId(replicator.Id) :: any
			expect(mirrored.Manager.Raw.Coins).is(42)

			replicator:Destroy()
			intermediary:Destroy()
		end)

		test("two clients have independent applied state -- only the targeted one sees the replicator", function()
			local token = uniqueToken("FakeIntermediaryTwoClients")
			local intermediary = FakeIntermediary.new()
			local clientA = intermediary:Connect()
			local clientB = intermediary:Connect()

			local replicator =
				ServerReplicator.new { Namespace = token, Data = { Coins = 7 }, ReplicationTargets = { clientA.Player } }
			clientA:RequestData()
			clientB:RequestData()

			local mirroredA = clientA:GetFromId(replicator.Id) :: any
			expect(mirroredA).never_is(nil)
			expect(mirroredA.Manager.Raw.Coins).is(7)
			expect(clientB:GetFromId(replicator.Id)).is(nil)

			replicator:Destroy()
			intermediary:Destroy()
		end)

		test("AddTarget after bootstrap delivers a live snapshot to only that client", function()
			local token = uniqueToken("FakeIntermediaryAddTarget")
			local intermediary = FakeIntermediary.new()
			local clientA = intermediary:Connect()
			local clientB = intermediary:Connect()

			-- Bootstrap both with no targets yet, the way a real client's first
			-- RequestData() would.
			clientA:RequestData()
			clientB:RequestData()

			local replicator = ServerReplicator.new { Namespace = token, Data = { Coins = 3 }, ReplicationTargets = {} }
			-- `AddTarget` distinguishes a single Player from a list via
			-- `typeof() == "Instance"`; the fake player stand-in is a plain
			-- table, so it must be wrapped to take the list branch correctly.
			replicator:AddTarget { clientA.Player }

			local mirroredA = clientA:GetFromId(replicator.Id) :: any
			expect(mirroredA).never_is(nil)
			expect(mirroredA.Manager.Raw.Coins).is(3)
			expect(clientB:GetFromId(replicator.Id)).is(nil)

			replicator:Destroy()
			intermediary:Destroy()
		end)

		test("RemoveTarget tears down the replicator on that client without affecting another active client", function()
			local token = uniqueToken("FakeIntermediaryRemoveTarget")
			local intermediary = FakeIntermediary.new()
			local clientA = intermediary:Connect()
			local clientB = intermediary:Connect()

			local replicator = ServerReplicator.new {
				Namespace = token,
				Data = { Coins = 1 },
				ReplicationTargets = { clientA.Player, clientB.Player },
			}
			clientA:RequestData()
			clientB:RequestData()

			expect(clientA:GetFromId(replicator.Id)).never_is(nil)
			expect(clientB:GetFromId(replicator.Id)).never_is(nil)

			-- Same `typeof() == "Instance"` wrapping requirement as AddTarget above.
			replicator:RemoveTarget { clientA.Player }

			expect(clientA:GetFromId(replicator.Id)).is(nil)
			expect(clientB:GetFromId(replicator.Id)).never_is(nil)

			-- Ops enqueued after the removal must not error trying to reach the
			-- now-inactive clientA, and must still land on clientB.
			replicator.Manager:Set("Coins", 99);
			(ServerReplicator :: any)._FrameCoordinator:Flush()

			local mirroredB = clientB:GetFromId(replicator.Id) :: any
			expect(mirroredB.Manager.Raw.Coins).is(99)

			replicator:Destroy()
			intermediary:Destroy()
		end)

		test(
			"SetTargets swaps the active client -- old target is torn down, new target gets a fresh snapshot",
			function()
				local token = uniqueToken("FakeIntermediarySetTargetsSwap")
				local intermediary = FakeIntermediary.new()
				local clientA = intermediary:Connect()
				local clientB = intermediary:Connect()
				clientA:RequestData()
				clientB:RequestData()

				local replicator = ServerReplicator.new {
					Namespace = token,
					Data = { Coins = 4 },
					ReplicationTargets = { clientA.Player },
				}
				expect(clientA:GetFromId(replicator.Id)).never_is(nil)
				expect(clientB:GetFromId(replicator.Id)).is(nil)

				replicator:SetTargets { clientB.Player }

				expect(clientA:GetFromId(replicator.Id)).is(nil)
				local mirroredB = clientB:GetFromId(replicator.Id) :: any
				expect(mirroredB).never_is(nil)
				expect(mirroredB.Manager.Raw.Coins).is(4)

				replicator:Destroy()
				intermediary:Destroy()
			end
		)

		test("a child replicator is visible only to its parent scope's targeted client", function()
			local token = uniqueToken("FakeIntermediaryChildScope")
			local intermediary = FakeIntermediary.new()
			local clientA = intermediary:Connect()
			local clientB = intermediary:Connect()

			local parent = ServerReplicator.new { Namespace = token, Data = {}, ReplicationTargets = { clientA.Player } }
			clientA:RequestData()
			clientB:RequestData()

			local child = ServerReplicator.new { Namespace = token, Data = { Hp = 50 }, Parent = parent }

			local mirroredChildA = clientA:GetFromId(child.Id) :: any
			expect(mirroredChildA).never_is(nil)
			expect(mirroredChildA.Manager.Raw.Hp).is(50)
			expect(mirroredChildA:GetParent().Id).is(parent.Id)
			expect(clientB:GetFromId(child.Id)).is(nil)

			child:Destroy()
			parent:Destroy()
			intermediary:Destroy()
		end)

		test("SetParent across scopes reconciles Create/Destroy/SetParent for each real client", function()
			local token = uniqueToken("FakeIntermediarySetParentCrossScope")
			local intermediary = FakeIntermediary.new()
			local onlyOld = intermediary:Connect()
			local onlyNew = intermediary:Connect()
			local both = intermediary:Connect()
			onlyOld:RequestData()
			onlyNew:RequestData()
			both:RequestData()

			local oldTop =
				ServerReplicator.new { Namespace = token, Data = {}, ReplicationTargets = { onlyOld.Player, both.Player } }
			local newTop =
				ServerReplicator.new { Namespace = token, Data = {}, ReplicationTargets = { onlyNew.Player, both.Player } }
			local moved = ServerReplicator.new { Namespace = token, Data = { Tag = "moved" }, Parent = oldTop }

			expect(onlyOld:GetFromId(moved.Id)).never_is(nil)
			expect(both:GetFromId(moved.Id)).never_is(nil)
			expect(onlyNew:GetFromId(moved.Id)).is(nil)

			moved:SetParent(newTop)

			-- Only in the old scope -> torn down.
			expect(onlyOld:GetFromId(moved.Id)).is(nil)

			-- In both scopes -> re-parented in place, not recreated.
			local mirroredBoth = both:GetFromId(moved.Id) :: any
			expect(mirroredBoth).never_is(nil)
			expect(mirroredBoth:GetParent().Id).is(newTop.Id)

			-- Only in the new scope -> a fresh snapshot.
			local mirroredNew = onlyNew:GetFromId(moved.Id) :: any
			expect(mirroredNew).never_is(nil)
			expect(mirroredNew.Manager.Raw.Tag).is("moved")

			moved:Destroy()
			oldTop:Destroy()
			newTop:Destroy()
			intermediary:Destroy()
		end)

		test("destroying a parent tears down parent and child on the client", function()
			local token = uniqueToken("DestroyParentWithChildE2E")
			local intermediary = FakeIntermediary.new()
			local client = intermediary:Connect()

			local parent = ServerReplicator.new { Namespace = token, Data = {}, ReplicationTargets = { client.Player } }
			client:RequestData()
			local child = ServerReplicator.new { Namespace = token, Data = { Hp = 10 }, Parent = parent }

			expect(client:GetFromId(parent.Id)).never_is(nil)
			expect(client:GetFromId(child.Id)).never_is(nil)

			parent:Destroy()

			expect(client:GetFromId(parent.Id)).is(nil)
			expect(client:GetFromId(child.Id)).is(nil)

			-- Children survive on the server even after the client loses them.
			expect(BaseReplicator.GetFromId(child.Id)).is(child)

			child:Destroy()
			intermediary:Destroy()
		end)

		test("destroying a parent tears down all descendants on the client (multi-level subtree)", function()
			local token = uniqueToken("DestroySubtreeE2E")
			local intermediary = FakeIntermediary.new()
			local client = intermediary:Connect()

			local top = ServerReplicator.new { Namespace = token, Data = {}, ReplicationTargets = { client.Player } }
			client:RequestData()
			local child = ServerReplicator.new { Namespace = token, Data = {}, Parent = top }
			local grandchild = ServerReplicator.new { Namespace = token, Data = { X = 1 }, Parent = child }

			expect(client:GetFromId(top.Id)).never_is(nil)
			expect(client:GetFromId(child.Id)).never_is(nil)
			expect(client:GetFromId(grandchild.Id)).never_is(nil)

			top:Destroy()

			expect(client:GetFromId(top.Id)).is(nil)
			expect(client:GetFromId(child.Id)).is(nil)
			expect(client:GetFromId(grandchild.Id)).is(nil)

			grandchild:Destroy()
			child:Destroy()
			intermediary:Destroy()
		end)

		test("destroying a parent does not affect a sibling replicator on the client", function()
			local token = uniqueToken("DestroyParentSiblingUnaffectedE2E")
			local intermediary = FakeIntermediary.new()
			local client = intermediary:Connect()

			local topA = ServerReplicator.new { Namespace = token, Data = {}, ReplicationTargets = { client.Player } }
			local topB =
				ServerReplicator.new { Namespace = token, Data = { Val = 7 }, ReplicationTargets = { client.Player } }
			client:RequestData()
			local childOfA = ServerReplicator.new { Namespace = token, Data = {}, Parent = topA }

			topA:Destroy()

			expect(client:GetFromId(topA.Id)).is(nil)
			expect(client:GetFromId(childOfA.Id)).is(nil)
			local mirroredB = client:GetFromId(topB.Id) :: any
			expect(mirroredB).never_is(nil)
			expect(mirroredB.Manager.Raw.Val).is(7)

			childOfA:Destroy()
			topB:Destroy()
			intermediary:Destroy()
		end)
	end)

	--------------------------------------------------------------------------------

	describe("Multiple replicators watching the same or linked TableManagers", function()
		test("shared TableManager root: single mutation reaches each replicator's targeted client", function()
			local token = uniqueToken("SharedTMIndepClients")
			local intermediary = FakeIntermediary.new()
			local clientA = intermediary:Connect()
			local clientB = intermediary:Connect()

			-- Both replicators wrap the SAME TableManager instance.
			local sharedTM = TableManagerModule.new { Coins = 0 }
			local repA =
				ServerReplicator.new { Namespace = token, Data = sharedTM, ReplicationTargets = { clientA.Player } }
			local repB =
				ServerReplicator.new { Namespace = token, Data = sharedTM, ReplicationTargets = { clientB.Player } }

			clientA:RequestData()
			clientB:RequestData()

			sharedTM:Set("Coins", 42)
			ServerReplicator._FrameCoordinator:Flush()

			local mA = clientA:GetFromId(repA.Id) :: any
			local mB = clientB:GetFromId(repB.Id) :: any
			expect(mA.Manager.Raw.Coins).is(42)
			expect(mB.Manager.Raw.Coins).is(42)

			-- Each client only sees its own replicator.
			expect(clientA:GetFromId(repB.Id)).is(nil)
			expect(clientB:GetFromId(repA.Id)).is(nil)

			repA:Destroy()
			repB:Destroy()
			intermediary:Destroy()
		end)

		test(
			"shared TableManager, same target client: one message with one OpsItem per replicator, no duplicate ops",
			function()
				local token = uniqueToken("SharedTMOneFlush")
				local intermediary = FakeIntermediary.new()
				local client = intermediary:Connect()

				local sharedTM = TableManagerModule.new { Value = 0 }
				local rep1 =
					ServerReplicator.new { Namespace = token, Data = sharedTM, ReplicationTargets = { client.Player } }
				local rep2 =
					ServerReplicator.new { Namespace = token, Data = sharedTM, ReplicationTargets = { client.Player } }

				client:RequestData()

				-- Spy ON TOP of the intermediary's hook: decode the buffer so we can
				-- inspect payload contents, and still forward so client state updates.
				local captured: { { Player: any, Message: any } } = {}
				local prevSend = (ServerReplicator :: any)._Transport.SendMessage;
				(ServerReplicator :: any)._Transport.SendMessage = function(self, player, buf, instances)
					table.insert(captured, { Player = player, Message = MessageCodec.Decode(buf, instances) })
					prevSend(self, player, buf, instances)
				end

				sharedTM:Set("Value", 99);
				(ServerReplicator :: any)._FrameCoordinator:Flush();
				(ServerReplicator :: any)._Transport.SendMessage = prevSend

				-- Exactly one message for this player (FrameCoordinator batches all ops).
				expect(#captured).is(1)
				expect(captured[1].Player).is(client.Player)

				-- Two OpsItems (one per replicator ID), not four — proves the mutation
				-- was not double-queued per replicator.
				local items = captured[1].Message.Items
				expect(#items).is(2)

				-- Each OpsItem carries exactly one op with the correct value — proves
				-- no internal duplication within a single replicator's run.
				local seenIds: { [number]: boolean } = {}
				for _, item in items do
					local wireOps = item :: any
					expect(wireOps.Op).is(FlatCodec.Op.Ops)
					local decoded = FlatCodec.DecodeOps(wireOps)
					expect(#decoded).is(1)
					expect(decoded[1].Kind).is("Set")
					expect(decoded[1].Value).is(99)
					seenIds[wireOps.Id] = true
				end
				expect(seenIds[rep1.Id]).is(true)
				expect(seenIds[rep2.Id]).is(true)

				-- Client mirrors reflect the new value via the delivered message.
				local m1 = client:GetFromId(rep1.Id) :: any
				local m2 = client:GetFromId(rep2.Id) :: any
				expect(m1.Manager.Raw.Value).is(99)
				expect(m2.Manager.Raw.Value).is(99)

				rep1:Destroy()
				rep2:Destroy()
				intermediary:Destroy()
			end
		)

		test(
			"linked TableManagers (co-observers): mutation through child TM propagates to both replicators on client",
			function()
				local token = uniqueToken("LinkedTMCoObserve")
				local intermediary = FakeIntermediary.new()
				local client = intermediary:Connect()

				-- `sharedStats` is the shared interior node.
				-- parentTM observes it at path "Stats"; childTM is rooted at it.
				-- A write through either TM propagates to the other (TableManager2
				-- implicit sharing).
				local sharedStats = { Hp = 100, Mp = 50 }
				local parentTM = TableManagerModule.new { Stats = sharedStats, Name = "Hero" }
				local childTM = TableManagerModule.new(sharedStats)

				local parentRep =
					ServerReplicator.new { Namespace = token, Data = parentTM, ReplicationTargets = { client.Player } }
				local childRep = ServerReplicator.new { Namespace = token, Data = childTM, Parent = parentRep }

				client:RequestData()

				-- Writing through childTM fires OnApplied on both managers (co-observation).
				-- parentRep gets a translated path ("Stats.Hp"); childRep gets the root path ("Hp").
				childTM:Set("Hp", 75);
				(ServerReplicator :: any)._FrameCoordinator:Flush()

				local mirroredParent = client:GetFromId(parentRep.Id) :: any
				local mirroredChild = client:GetFromId(childRep.Id) :: any

				expect(mirroredParent.Manager.Raw.Stats.Hp).is(75)
				expect(mirroredChild.Manager.Raw.Hp).is(75)
				-- Mp was not touched.
				expect(mirroredParent.Manager.Raw.Stats.Mp).is(50)

				childRep:Destroy()
				parentRep:Destroy()
				intermediary:Destroy()
			end
		)

		test("two independent replicators same client: mutations stay isolated to each replicator's ID", function()
			local token = uniqueToken("IndepTMsIsolation")
			local intermediary = FakeIntermediary.new()
			local client = intermediary:Connect()

			local tm1 = TableManagerModule.new { Score = 0 }
			local tm2 = TableManagerModule.new { Score = 0 }
			local rep1 = ServerReplicator.new { Namespace = token, Data = tm1, ReplicationTargets = { client.Player } }
			local rep2 = ServerReplicator.new { Namespace = token, Data = tm2, ReplicationTargets = { client.Player } }

			client:RequestData()

			-- Only mutate tm1.
			tm1:Set("Score", 10);
			(ServerReplicator :: any)._FrameCoordinator:Flush()

			local m1 = client:GetFromId(rep1.Id) :: any
			local m2 = client:GetFromId(rep2.Id) :: any
			expect(m1.Manager.Raw.Score).is(10)
			expect(m2.Manager.Raw.Score).is(0) -- unaffected

			-- Mutate only tm2.
			tm2:Set("Score", 7);
			(ServerReplicator :: any)._FrameCoordinator:Flush()

			expect(m1.Manager.Raw.Score).is(10) -- unchanged
			expect(m2.Manager.Raw.Score).is(7)

			rep1:Destroy()
			rep2:Destroy()
			intermediary:Destroy()
		end)
	end)

	--------------------------------------------------------------------------------

	describe("Coalescing (opt-in per-replicator)", function()
		test(
			"a coalesced replicator collapses repeated same-frame writes to a single op; client lands on the final value",
			function()
				local token = uniqueToken("CoalesceE2ESamePath")
				local intermediary = FakeIntermediary.new()
				local client = intermediary:Connect()

				local replicator = ServerReplicator.new {
					Namespace = token,
					Data = { Hp = 0 },
					ReplicationTargets = { client.Player },
					Coalesced = true,
				}
				client:RequestData()

				local captured: { { Player: any, Message: any } } = {}
				local prevSend = (ServerReplicator :: any)._Transport.SendMessage;
				(ServerReplicator :: any)._Transport.SendMessage = function(self, player, buf, instances)
					table.insert(captured, { Player = player, Message = MessageCodec.Decode(buf, instances) })
					prevSend(self, player, buf, instances)
				end

				replicator.Manager:Set("Hp", 10)
				replicator.Manager:Set("Hp", 20)
				replicator.Manager:Set("Hp", 30);
				(ServerReplicator :: any)._FrameCoordinator:Flush();
				(ServerReplicator :: any)._Transport.SendMessage = prevSend

				expect(#captured).is(1)
				local items = captured[1].Message.Items
				expect(#items).is(1)
				local decoded = FlatCodec.DecodeOps(items[1] :: any)
				expect(#decoded).is(1)
				expect(decoded[1].Value).is(30)

				local mirrored = client:GetFromId(replicator.Id) :: any
				expect(mirrored.Manager.Raw.Hp).is(30)

				replicator:Destroy()
				intermediary:Destroy()
			end
		)

		test("a non-coalesced (default) replicator still delivers every intermediate write", function()
			local token = uniqueToken("CoalesceE2EControl")
			local intermediary = FakeIntermediary.new()
			local client = intermediary:Connect()

			local replicator =
				ServerReplicator.new { Namespace = token, Data = { Hp = 0 }, ReplicationTargets = { client.Player } }
			client:RequestData()

			local captured: { { Player: any, Message: any } } = {}
			local prevSend = (ServerReplicator :: any)._Transport.SendMessage;
			(ServerReplicator :: any)._Transport.SendMessage = function(self, player, buf, instances)
				table.insert(captured, { Player = player, Message = MessageCodec.Decode(buf, instances) })
				prevSend(self, player, buf, instances)
			end

			replicator.Manager:Set("Hp", 10)
			replicator.Manager:Set("Hp", 20)
			replicator.Manager:Set("Hp", 30);
			(ServerReplicator :: any)._FrameCoordinator:Flush();
			(ServerReplicator :: any)._Transport.SendMessage = prevSend

			local items = captured[1].Message.Items
			local decoded = FlatCodec.DecodeOps(items[1] :: any)
			expect(#decoded).is(3)

			local mirrored = client:GetFromId(replicator.Id) :: any
			expect(mirrored.Manager.Raw.Hp).is(30)

			replicator:Destroy()
			intermediary:Destroy()
		end)

		test(
			"two replicators sharing one TableManager, one coalesced and one not: independent streams, identical final client state",
			function()
				local token = uniqueToken("CoalesceE2ESharedTM")
				local intermediary = FakeIntermediary.new()
				local clientA = intermediary:Connect()
				local clientB = intermediary:Connect()

				-- Both replicators wrap the SAME TableManager instance; only `coalescedRep`
				-- opts into coalescing. The two are independent op streams (own `Id`s),
				-- so collapsing one must never affect the other.
				local sharedTM = TableManagerModule.new { Hp = 0 }
				local coalescedRep = ServerReplicator.new {
					Namespace = token,
					Data = sharedTM,
					ReplicationTargets = { clientA.Player },
					Coalesced = true,
				}
				local plainRep =
					ServerReplicator.new { Namespace = token, Data = sharedTM, ReplicationTargets = { clientB.Player } }

				clientA:RequestData()
				clientB:RequestData()

				local captured: { { Player: any, Message: any } } = {}
				local prevSend = (ServerReplicator :: any)._Transport.SendMessage;
				(ServerReplicator :: any)._Transport.SendMessage = function(self, player, buf, instances)
					table.insert(captured, { Player = player, Message = MessageCodec.Decode(buf, instances) })
					prevSend(self, player, buf, instances)
				end

				sharedTM:Set("Hp", 10)
				sharedTM:Set("Hp", 20)
				sharedTM:Set("Hp", 30);
				(ServerReplicator :: any)._FrameCoordinator:Flush();
				(ServerReplicator :: any)._Transport.SendMessage = prevSend

				local byPlayer: { [any]: any } = {}
				for _, call in captured do
					byPlayer[call.Player] = call.Message
				end

				local coalescedOps = FlatCodec.DecodeOps(byPlayer[clientA.Player].Items[1] :: any)
				local plainOps = FlatCodec.DecodeOps(byPlayer[clientB.Player].Items[1] :: any)
				expect(#coalescedOps).is(1)
				expect(#plainOps).is(3)

				local mirroredA = clientA:GetFromId(coalescedRep.Id) :: any
				local mirroredB = clientB:GetFromId(plainRep.Id) :: any
				expect(mirroredA.Manager.Raw.Hp).is(30)
				expect(mirroredB.Manager.Raw.Hp).is(30)

				coalescedRep:Destroy()
				plainRep:Destroy()
				intermediary:Destroy()
			end
		)
	end)

	--------------------------------------------------------------------------------

	describe("ImmediateFlush (synchronous per-replicator send)", function()
		test("a bare Set sends synchronously, before any explicit Flush", function()
			local player = { Name = "P" } :: any
			local replicator = ServerReplicator.new({
				Namespace = uniqueToken("ImmediateBareSet"),
				Data = { Hp = 0 },
				ReplicationTargets = { player },
				ImmediateFlush = true,
			})
			;(replicator :: any)._Scope:Activate(player)

			local calls, restore = spyOnTransport()
			replicator.Manager:Set("Hp", 10)
			-- No Flush() called -- the message must already be on the wire.
			expect(#calls).is(1)
			expect(calls[1].Message.Items[1].Id).is(replicator.Id)
			local decoded = FlatCodec.DecodeOps(calls[1].Message.Items[1] :: any)
			expect(decoded[1].Value).is(10)
			restore()

			replicator:Destroy()
		end)

		test("N separate non-batched Sets produce N messages (the immediate tradeoff)", function()
			local player = { Name = "P" } :: any
			local replicator = ServerReplicator.new({
				Namespace = uniqueToken("ImmediateNSets"),
				Data = { Hp = 0 },
				ReplicationTargets = { player },
				ImmediateFlush = true,
			})
			;(replicator :: any)._Scope:Activate(player)

			local calls, restore = spyOnTransport()
			replicator.Manager:Set("Hp", 10)
			replicator.Manager:Set("Hp", 20)
			replicator.Manager:Set("Hp", 30)
			restore()

			expect(#calls).is(3)

			replicator:Destroy()
		end)

		test("a manager Batch of several writes produces exactly one message at BatchEnd; client lands on net end-state", function()
			local token = uniqueToken("ImmediateBatchE2E")
			local intermediary = FakeIntermediary.new()
			local client = intermediary:Connect()

			local replicator = ServerReplicator.new({
				Namespace = token,
				Data = { Hp = 0, Mp = 0 },
				ReplicationTargets = { client.Player },
				ImmediateFlush = true,
			})
			client:RequestData()

			local captured: { any } = {}
			local prevSend = (ServerReplicator :: any)._Transport.SendMessage;
			(ServerReplicator :: any)._Transport.SendMessage = function(self, p, buf, instances)
				table.insert(captured, MessageCodec.Decode(buf, instances))
				prevSend(self, p, buf, instances)
			end

			replicator.Manager:Batch(function()
				replicator.Manager:Set("Hp", 100)
				replicator.Manager:Set("Hp", 50) -- overwrite within the batch -> net 50
				replicator.Manager:Set("Mp", 10)
			end);
			(ServerReplicator :: any)._Transport.SendMessage = prevSend

			-- One message from the whole batch (flushed at BatchEnd), not one per write.
			expect(#captured).is(1)
			local mirrored = client:GetFromId(replicator.Id) :: any
			expect(mirrored.Manager.Raw.Hp).is(50)
			expect(mirrored.Manager.Raw.Mp).is(10)

			replicator:Destroy()
			intermediary:Destroy()
		end)

		test("isolation: an ImmediateFlush replicator sends synchronously; a plain replicator on the same TableManager stays buffered", function()
			local playerImm = { Name = "Imm" } :: any
			local playerPlain = { Name = "Plain" } :: any
			local sharedTM = TableManagerModule.new({ Hp = 0 })
			local immRep = ServerReplicator.new({
				Namespace = uniqueToken("ImmediateIsoImm"),
				Data = sharedTM,
				ReplicationTargets = { playerImm },
				ImmediateFlush = true,
			})
			local plainRep = ServerReplicator.new({
				Namespace = uniqueToken("ImmediateIsoPlain"),
				Data = sharedTM,
				ReplicationTargets = { playerPlain },
			})
			;(immRep :: any)._Scope:Activate(playerImm)
			;(plainRep :: any)._Scope:Activate(playerPlain)

			local calls, restore = spyOnTransport()
			sharedTM:Set("Hp", 10)

			-- Only the immediate replicator has sent so far, to its own player.
			expect(#calls).is(1)
			expect(calls[1].Player).is(playerImm)
			expect(calls[1].Message.Items[1].Id).is(immRep.Id)

			-- The plain replicator's op is still buffered -- a Flush delivers it.
			;(ServerReplicator :: any)._FrameCoordinator:Flush()
			expect(#calls).is(2)
			expect(calls[2].Player).is(playerPlain)
			expect(calls[2].Message.Items[1].Id).is(plainRep.Id)
			restore()

			immRep:Destroy()
			plainRep:Destroy()
		end)

		test("an ordered signal FireAll sends synchronously on an ImmediateFlush replicator", function()
			local player = { Name = "P" } :: any
			local replicator = ServerReplicator.new({
				Namespace = uniqueToken("ImmediateSignal"),
				Data = {},
				ReplicationTargets = { player },
				ImmediateFlush = true,
			})
			;(replicator :: any)._Scope:Activate(player)
			replicator:RegisterOrderedRemoteSignal("Hit")

			local calls, restore = spyOnTransport()
			;(replicator :: any).Client.Hit:FireAll("dmg")
			-- No Flush() -- the ordered signal must already be on the wire.
			expect(#calls).is(1)
			restore()

			replicator:Destroy()
		end)

		test("a signal fired inside a Batch is held until BatchEnd and ships in one complete window", function()
			local player = { Name = "P" } :: any
			local replicator = ServerReplicator.new({
				Namespace = uniqueToken("ImmediateSignalInBatch"),
				Data = { Hp = 0 },
				ReplicationTargets = { player },
				ImmediateFlush = true,
			})
			;(replicator :: any)._Scope:Activate(player)
			replicator:RegisterOrderedRemoteSignal("Hit")

			local calls, restore = spyOnTransport()
			replicator.Manager:Batch(function()
				replicator.Manager:Set("Hp", 5)
				;(replicator :: any).Client.Hit:FireAll("dmg")
				-- Mid-batch: nothing sent yet (the window is still open).
				expect(#calls).is(0)
			end)

			-- One message after BatchEnd, framed by a complete Batch window so no
			-- unterminated Suspend reaches the client.
			expect(#calls).is(1)
			local decoded = FlatCodec.DecodeOps(calls[1].Message.Items[1] :: any)
			expect(decoded[1].Kind).is("BatchBegin")
			expect(decoded[#decoded].Kind).is("BatchEnd")
			local sawSignal = false
			for _, op in decoded do
				if op.Kind == "Signal" then
					sawSignal = true
				end
			end
			expect(sawSignal).is(true)
			restore()

			replicator:Destroy()
		end)
	end)
end
