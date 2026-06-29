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
			local message = FlatCodec.BuildMessage({ opsItem })
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
				ServerReplicator.new({ Token = token, Data = { Coins = 5 }, ReplicationTargets = { client.Player } })
			client:RequestData()

			local mirrored = client:GetFromId(replicator.Id) :: any
			expect(mirrored).never_is(nil)
			expect(mirrored:GetTokenName()).is(getTokenName(token))
			expect(mirrored.Manager.Raw.Coins).is(5)

			replicator:Destroy()
			intermediary:Destroy()
		end)

		test("a data op delivered after FrameCoordinator:Flush lands on the client", function()
			local token = uniqueToken("FakeIntermediaryOps")
			local intermediary = FakeIntermediary.new()
			local client = intermediary:Connect()

			local replicator =
				ServerReplicator.new({ Token = token, Data = { Coins = 0 }, ReplicationTargets = { client.Player } })
			client:RequestData()

			replicator.Manager:Set("Coins", 42)
			;(ServerReplicator :: any)._FrameCoordinator:Flush()

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
				ServerReplicator.new({ Token = token, Data = { Coins = 7 }, ReplicationTargets = { clientA.Player } })
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

			local replicator = ServerReplicator.new({ Token = token, Data = { Coins = 3 }, ReplicationTargets = {} })
			-- `AddTarget` distinguishes a single Player from a list via
			-- `typeof() == "Instance"`; the fake player stand-in is a plain
			-- table, so it must be wrapped to take the list branch correctly.
			replicator:AddTarget({ clientA.Player })

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

			local replicator = ServerReplicator.new({
				Token = token,
				Data = { Coins = 1 },
				ReplicationTargets = { clientA.Player, clientB.Player },
			})
			clientA:RequestData()
			clientB:RequestData()

			expect(clientA:GetFromId(replicator.Id)).never_is(nil)
			expect(clientB:GetFromId(replicator.Id)).never_is(nil)

			-- Same `typeof() == "Instance"` wrapping requirement as AddTarget above.
			replicator:RemoveTarget({ clientA.Player })

			expect(clientA:GetFromId(replicator.Id)).is(nil)
			expect(clientB:GetFromId(replicator.Id)).never_is(nil)

			-- Ops enqueued after the removal must not error trying to reach the
			-- now-inactive clientA, and must still land on clientB.
			replicator.Manager:Set("Coins", 99)
			;(ServerReplicator :: any)._FrameCoordinator:Flush()

			local mirroredB = clientB:GetFromId(replicator.Id) :: any
			expect(mirroredB.Manager.Raw.Coins).is(99)

			replicator:Destroy()
			intermediary:Destroy()
		end)

		test("SetTargets swaps the active client -- old target is torn down, new target gets a fresh snapshot", function()
			local token = uniqueToken("FakeIntermediarySetTargetsSwap")
			local intermediary = FakeIntermediary.new()
			local clientA = intermediary:Connect()
			local clientB = intermediary:Connect()
			clientA:RequestData()
			clientB:RequestData()

			local replicator =
				ServerReplicator.new({ Token = token, Data = { Coins = 4 }, ReplicationTargets = { clientA.Player } })
			expect(clientA:GetFromId(replicator.Id)).never_is(nil)
			expect(clientB:GetFromId(replicator.Id)).is(nil)

			replicator:SetTargets({ clientB.Player })

			expect(clientA:GetFromId(replicator.Id)).is(nil)
			local mirroredB = clientB:GetFromId(replicator.Id) :: any
			expect(mirroredB).never_is(nil)
			expect(mirroredB.Manager.Raw.Coins).is(4)

			replicator:Destroy()
			intermediary:Destroy()
		end)

		test("a child replicator is visible only to its parent scope's targeted client", function()
			local token = uniqueToken("FakeIntermediaryChildScope")
			local intermediary = FakeIntermediary.new()
			local clientA = intermediary:Connect()
			local clientB = intermediary:Connect()

			local parent = ServerReplicator.new({ Token = token, Data = {}, ReplicationTargets = { clientA.Player } })
			clientA:RequestData()
			clientB:RequestData()

			local child = ServerReplicator.new({ Token = token, Data = { Hp = 50 }, Parent = parent })

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
				ServerReplicator.new({ Token = token, Data = {}, ReplicationTargets = { onlyOld.Player, both.Player } })
			local newTop =
				ServerReplicator.new({ Token = token, Data = {}, ReplicationTargets = { onlyNew.Player, both.Player } })
			local moved = ServerReplicator.new({ Token = token, Data = { Tag = "moved" }, Parent = oldTop })

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
	end)
end
