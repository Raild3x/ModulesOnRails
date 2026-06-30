--!strict
--[[
	Coverage for every public `ServerReplicator` method: `Token`, `new`'s
	validation, targeting (`SetTargets`/`AddTarget`/`RemoveTarget`/
	`GetTargets`/`IsReplicatingTo`), hierarchy (`SetParent`), and `Destroy`.

	No real RemoteEvent traffic is exercised here -- server-side behavior is
	asserted by spying on `ServerReplicator._Transport` directly (a test-only
	escape hatch, not part of the public API). `Player` targets are stood in
	for with plain tables (`:: any`-cast): every targeting code path here
	only ever uses a player value as an opaque dictionary key, never a real
	`Player` API, so a real `Players` connection isn't needed to exercise it.
]]

return function(t: tiniest)
	local FlatCodec = require("../Shared/Serialization/FlatCodec")
	local BaseReplicator = require("../Shared/BaseReplicator")
	local ServerReplicator = require("../Server/ServerReplicator")
	local FakeManager = require("./Helpers/FakeManager")
	local SpecUtils = require("./Helpers/SpecUtils")

	local describe = t.describe
	local test = t.test
	local expect = t.expect

	local uniqueToken = SpecUtils.uniqueToken
	local spyOnTransport = SpecUtils.spyOnTransport

	--------------------------------------------------------------------------------

	describe("ServerReplicator.Token", function()
		test("creates a fresh token for an unused name", function()
			local token = ServerReplicator.Token("ServerReplicator.Token.Fresh")
			expect(token).never_is(nil)
		end)

		test("errors if the same name is registered twice", function()
			ServerReplicator.Token("DuplicateTokenTest")
			expect(function()
				ServerReplicator.Token("DuplicateTokenTest")
			end).fails()
		end)

		test(".new(name) is equivalent to calling the token table directly", function()
			local viaCall = ServerReplicator.Token("TokenNewVsCall.Call")
			local viaNew = ServerReplicator.Token.new("TokenNewVsCall.New")
			expect(SpecUtils.getTokenName(viaCall)).is("TokenNewVsCall.Call")
			expect(SpecUtils.getTokenName(viaNew)).is("TokenNewVsCall.New")
		end)

		test(".get(name) returns the same token object .new() registered", function()
			local registered = ServerReplicator.Token.new("TokenGetRoundTrip")
			local fetched = ServerReplicator.Token.get("TokenGetRoundTrip")
			expect(fetched).is(registered)
		end)

		test(".get(name) returns nil for a name that was never registered", function()
			expect(ServerReplicator.Token.get("NeverRegisteredTokenName")).is(nil)
		end)
	end)

	--------------------------------------------------------------------------------

	describe("ServerReplicator.new", function()
		test("requires exactly one of Parent / ReplicationTargets", function()
			local token = uniqueToken("ParentXorTargets")
			expect(function()
				ServerReplicator.new({ Token = token, Data = FakeManager.new() })
			end).fails()

			local parent = ServerReplicator.new({ Token = token, Data = FakeManager.new(), ReplicationTargets = {} })
			expect(function()
				ServerReplicator.new({ Token = token, Data = FakeManager.new(), Parent = parent, ReplicationTargets = {} })
			end).fails()
			parent:Destroy()
		end)

		test("a plain Data table is wrapped in a real TableManager", function()
			local replicator =
				ServerReplicator.new({ Token = uniqueToken("NewPlainData"), Data = { Coins = 5 }, ReplicationTargets = {} })
			expect(replicator.Manager.Raw.Coins).is(5)
			replicator:Destroy()
		end)

		test("an existing TableManager passed as Data is used directly, not re-wrapped", function()
			local FakeManagerInstance = FakeManager.new({ Tag = "original" })
			local replicator =
				ServerReplicator.new({ Token = uniqueToken("NewExistingManager"), Data = FakeManagerInstance, ReplicationTargets = {} })
			expect(replicator.Manager).is(FakeManagerInstance)
			replicator:Destroy()
		end)

		test("Tags default to an empty table when omitted", function()
			local replicator =
				ServerReplicator.new({ Token = uniqueToken("NewDefaultTags"), Data = FakeManager.new(), ReplicationTargets = {} })
			-- `IsSubsetOfTags({})` is only true if the replicator's OWN tags
			-- are themselves empty -- unlike `IsSupersetOfTags({})`, which is
			-- trivially true no matter what tags the replicator actually has.
			expect(replicator:IsSubsetOfTags({})).is_true()
			replicator:Destroy()
		end)

		test("a child automatically inherits its parent's replication scope", function()
			local player = { Name = "P" } :: any
			local parent =
				ServerReplicator.new({ Token = uniqueToken("NewScopeInheritParent"), Data = FakeManager.new(), ReplicationTargets = { player } })
			local child = ServerReplicator.new({ Token = uniqueToken("NewScopeInheritChild"), Data = FakeManager.new(), Parent = parent })
			expect(child:IsReplicatingTo(player)).is_true()
			child:Destroy()
			parent:Destroy()
		end)
	end)

	--------------------------------------------------------------------------------

	describe("ServerReplicator.SetTargets", function()
		test("explicit list drives IsReplicatingTo/GetTargets", function()
			local token = uniqueToken("SetTargets")
			local playerA = { Name = "A" } :: any
			local playerB = { Name = "B" } :: any

			local replicator = ServerReplicator.new({ Token = token, Data = FakeManager.new(), ReplicationTargets = { playerA } })
			expect(replicator:IsReplicatingTo(playerA)).is_true()
			expect(replicator:IsReplicatingTo(playerB)).is(false)

			replicator:SetTargets({ playerB })
			expect(replicator:IsReplicatingTo(playerA)).is(false)
			expect(replicator:IsReplicatingTo(playerB)).is_true()

			replicator:Destroy()
		end)

		test("switching to a smaller list removes everyone not in the new set", function()
			local playerA = { Name = "A" } :: any
			local playerB = { Name = "B" } :: any
			local replicator = ServerReplicator.new({
				Token = uniqueToken("SetTargetsShrink"),
				Data = FakeManager.new(),
				ReplicationTargets = { playerA, playerB },
			})
			replicator:SetTargets({ playerA })
			expect(replicator:IsReplicatingTo(playerA)).is_true()
			expect(replicator:IsReplicatingTo(playerB)).is(false)
			replicator:Destroy()
		end)

		test('SetTargets("all") replicates to every bootstrapped player', function()
			local player = { Name = "AllModePlayer" } :: any
			;(ServerReplicator :: any)._Transport.PlayerRequestedData:Fire(player)

			local replicator = ServerReplicator.new({ Token = uniqueToken("SetTargetsAll"), Data = FakeManager.new(), ReplicationTargets = {} })
			replicator:SetTargets("all" :: any)
			expect(replicator:IsReplicatingTo(player)).is_true()

			replicator:Destroy()
		end)

		test('SetTargets("all") a second time is a no-op (does not re-send)', function()
			local replicator = ServerReplicator.new({ Token = uniqueToken("SetTargetsAllTwice"), Data = FakeManager.new(), ReplicationTargets = "all" :: any })

			local calls, restore = spyOnTransport()
			replicator:SetTargets("all" :: any)
			restore()

			expect(#calls).is(0)
			replicator:Destroy()
		end)

		test("errors when called on a non-top-level replicator", function()
			local top = ServerReplicator.new({ Token = uniqueToken("SetTargetsNonTopTop"), Data = FakeManager.new(), ReplicationTargets = {} })
			local child = ServerReplicator.new({ Token = uniqueToken("SetTargetsNonTopChild"), Data = FakeManager.new(), Parent = top })
			expect(function()
				child:SetTargets({})
			end).fails()
			child:Destroy()
			top:Destroy()
		end)
	end)

	--------------------------------------------------------------------------------

	describe("ServerReplicator.AddTarget", function()
		test("sends a snapshot to an already-bootstrapped player", function()
			local token = uniqueToken("AddTargetBootstrapped")
			local player = { Name = "Bootstrapped" } :: any
			local replicator = ServerReplicator.new({ Token = token, Data = FakeManager.new(), ReplicationTargets = {} })

			-- Simulate the player having already completed the request-data
			-- handshake for some OTHER scope at some earlier point.
			;(ServerReplicator :: any)._Transport.PlayerRequestedData:Fire(player)

			local calls, restore = spyOnTransport()
			-- `AddTarget` distinguishes a single Player from a list via
			-- `typeof() == "Instance"`; the fake player stand-in is a plain
			-- table, so it must be wrapped to take the list branch correctly.
			replicator:AddTarget({ player })
			restore()

			expect(replicator:IsReplicatingTo(player)).is_true()
			expect(#calls).is(1)
			expect(calls[1].Player).is(player)
			expect(calls[1].Message.Items[1].Op).is(FlatCodec.Op.Create)

			replicator:Destroy()
		end)

		test("a not-yet-bootstrapped player is queued pending without sending anything yet", function()
			local replicator = ServerReplicator.new({ Token = uniqueToken("AddTargetPending"), Data = FakeManager.new(), ReplicationTargets = {} })
			local player = { Name = "NeverBootstrapped" } :: any

			local calls, restore = spyOnTransport()
			replicator:AddTarget({ player })
			restore()

			expect(#calls).is(0)
			expect(replicator:IsReplicatingTo(player)).is_true()
			replicator:Destroy()
		end)

		test("adds every player in a list at once", function()
			local playerA = { Name = "A" } :: any
			local playerB = { Name = "B" } :: any
			local replicator = ServerReplicator.new({ Token = uniqueToken("AddTargetMultiple"), Data = FakeManager.new(), ReplicationTargets = {} })
			replicator:AddTarget({ playerA, playerB })
			expect(replicator:IsReplicatingTo(playerA)).is_true()
			expect(replicator:IsReplicatingTo(playerB)).is_true()
			replicator:Destroy()
		end)

		test("is a no-op once the scope is already replicating to everyone", function()
			local replicator =
				ServerReplicator.new({ Token = uniqueToken("AddTargetAllNoOp"), Data = FakeManager.new(), ReplicationTargets = "all" :: any })
			local player = { Name = "Irrelevant" } :: any

			local calls, restore = spyOnTransport()
			replicator:AddTarget({ player })
			restore()

			expect(#calls).is(0)
			replicator:Destroy()
		end)

		test("errors when called on a non-top-level replicator", function()
			local top = ServerReplicator.new({ Token = uniqueToken("AddTargetNonTopTop"), Data = FakeManager.new(), ReplicationTargets = {} })
			local child = ServerReplicator.new({ Token = uniqueToken("AddTargetNonTopChild"), Data = FakeManager.new(), Parent = top })
			expect(function()
				child:AddTarget({ { Name = "X" } :: any })
			end).fails()
			child:Destroy()
			top:Destroy()
		end)
	end)

	--------------------------------------------------------------------------------

	describe("ServerReplicator.RemoveTarget", function()
		test("sends a Destroy to a currently-active player", function()
			local token = uniqueToken("RemoveTargetActive")
			local player = { Name = "Active" } :: any
			local replicator = ServerReplicator.new({ Token = token, Data = FakeManager.new(), ReplicationTargets = { player } })
			-- Not yet bootstrapped, so the player is only Pending; force them
			-- Active the same way the request-data handshake would.
			;(replicator :: any)._Scope:Activate(player)

			local calls, restore = spyOnTransport()
			-- Same `typeof() == "Instance"` wrapping requirement as AddTarget above.
			replicator:RemoveTarget({ player })
			restore()

			expect(replicator:IsReplicatingTo(player)).is(false)
			expect(#calls).is(1)
			expect(calls[1].Message.Items[1].Op).is(FlatCodec.Op.Destroy)

			replicator:Destroy()
		end)

		test("a pending (not yet active) player is dropped without sending anything", function()
			local player = { Name = "Pending" } :: any
			local replicator = ServerReplicator.new({ Token = uniqueToken("RemoveTargetPending"), Data = FakeManager.new(), ReplicationTargets = { player } })

			local calls, restore = spyOnTransport()
			replicator:RemoveTarget({ player })
			restore()

			expect(#calls).is(0)
			expect(replicator:IsReplicatingTo(player)).is(false)
			replicator:Destroy()
		end)

		test("removing a player that was never targeted is a safe no-op", function()
			local replicator = ServerReplicator.new({ Token = uniqueToken("RemoveTargetUntracked"), Data = FakeManager.new(), ReplicationTargets = {} })
			local player = { Name = "NeverTargeted" } :: any
			expect(function()
				replicator:RemoveTarget({ player })
			end).never_fails()
			replicator:Destroy()
		end)

		test("removes every player in a list at once", function()
			local playerA = { Name = "A" } :: any
			local playerB = { Name = "B" } :: any
			local replicator = ServerReplicator.new({
				Token = uniqueToken("RemoveTargetMultiple"),
				Data = FakeManager.new(),
				ReplicationTargets = { playerA, playerB },
			})
			replicator:RemoveTarget({ playerA, playerB })
			expect(replicator:IsReplicatingTo(playerA)).is(false)
			expect(replicator:IsReplicatingTo(playerB)).is(false)
			replicator:Destroy()
		end)

		test("errors when called on a non-top-level replicator", function()
			local top = ServerReplicator.new({ Token = uniqueToken("RemoveTargetNonTopTop"), Data = FakeManager.new(), ReplicationTargets = {} })
			local child = ServerReplicator.new({ Token = uniqueToken("RemoveTargetNonTopChild"), Data = FakeManager.new(), Parent = top })
			expect(function()
				child:RemoveTarget({ { Name = "X" } :: any })
			end).fails()
			child:Destroy()
			top:Destroy()
		end)
	end)

	--------------------------------------------------------------------------------

	describe("ServerReplicator.GetTargets", function()
		test("returns the explicit list passed at construction, even while still pending", function()
			local playerA = { Name = "A" } :: any
			local playerB = { Name = "B" } :: any
			local replicator = ServerReplicator.new({
				Token = uniqueToken("GetTargetsExplicit"),
				Data = FakeManager.new(),
				ReplicationTargets = { playerA, playerB },
			})
			local targets = replicator:GetTargets()
			expect(table.find(targets, playerA) ~= nil).is_true()
			expect(table.find(targets, playerB) ~= nil).is_true()
			replicator:Destroy()
		end)

		test("returns an empty list for ReplicationTargets = {}", function()
			local replicator = ServerReplicator.new({ Token = uniqueToken("GetTargetsEmpty"), Data = FakeManager.new(), ReplicationTargets = {} })
			expect(#replicator:GetTargets()).is(0)
			replicator:Destroy()
		end)

		test("reflects membership after AddTarget", function()
			local replicator = ServerReplicator.new({ Token = uniqueToken("GetTargetsAfterAdd"), Data = FakeManager.new(), ReplicationTargets = {} })
			local player = { Name = "Added" } :: any
			replicator:AddTarget({ player })
			expect(table.find(replicator:GetTargets(), player) ~= nil).is_true()
			replicator:Destroy()
		end)

		test("reflects membership after RemoveTarget", function()
			local player = { Name = "Removed" } :: any
			local replicator =
				ServerReplicator.new({ Token = uniqueToken("GetTargetsAfterRemove"), Data = FakeManager.new(), ReplicationTargets = { player } })
			replicator:RemoveTarget({ player })
			expect(table.find(replicator:GetTargets(), player) ~= nil).never_is_true()
			replicator:Destroy()
		end)

		test("does not error in \"all\" mode", function()
			local replicator =
				ServerReplicator.new({ Token = uniqueToken("GetTargetsAllMode"), Data = FakeManager.new(), ReplicationTargets = "all" :: any })
			expect(function()
				replicator:GetTargets()
			end).never_fails()
			replicator:Destroy()
		end)
	end)

	--------------------------------------------------------------------------------

	describe("ServerReplicator.IsReplicatingTo", function()
		test("true for an active target", function()
			local player = { Name = "Active" } :: any
			local replicator =
				ServerReplicator.new({ Token = uniqueToken("IsReplicatingToActive"), Data = FakeManager.new(), ReplicationTargets = { player } })
			;(replicator :: any)._Scope:Activate(player)
			expect(replicator:IsReplicatingTo(player)).is_true()
			replicator:Destroy()
		end)

		test("false for a player that was never targeted", function()
			local replicator = ServerReplicator.new({ Token = uniqueToken("IsReplicatingToNever"), Data = FakeManager.new(), ReplicationTargets = {} })
			expect(replicator:IsReplicatingTo({ Name = "Stranger" } :: any)).is(false)
			replicator:Destroy()
		end)

		test("true for a pending (not yet active) target", function()
			local player = { Name = "Pending" } :: any
			local replicator =
				ServerReplicator.new({ Token = uniqueToken("IsReplicatingToPending"), Data = FakeManager.new(), ReplicationTargets = { player } })
			expect(replicator:IsReplicatingTo(player)).is_true()
			replicator:Destroy()
		end)

		test("false after RemoveTarget", function()
			local player = { Name = "Removed" } :: any
			local replicator =
				ServerReplicator.new({ Token = uniqueToken("IsReplicatingToRemoved"), Data = FakeManager.new(), ReplicationTargets = { player } })
			replicator:RemoveTarget({ player })
			expect(replicator:IsReplicatingTo(player)).is(false)
			replicator:Destroy()
		end)

		test("true for any player at all once the scope replicates to everyone", function()
			local replicator =
				ServerReplicator.new({ Token = uniqueToken("IsReplicatingToAllMode"), Data = FakeManager.new(), ReplicationTargets = "all" :: any })
			expect(replicator:IsReplicatingTo({ Name = "AnyoneAtAll" } :: any)).is_true()
			replicator:Destroy()
		end)
	end)

	--------------------------------------------------------------------------------

	describe("ServerReplicator.SetParent", function()
		test("within the same scope sends a SetParent item", function()
			local token = uniqueToken("SetParentSameScope")
			local player = { Name = "P" } :: any
			local top = ServerReplicator.new({ Token = token, Data = FakeManager.new(), ReplicationTargets = { player } })
			;(top :: any)._Scope:Activate(player)
			local childA = ServerReplicator.new({ Token = token, Data = FakeManager.new(), Parent = top })
			local childB = ServerReplicator.new({ Token = token, Data = FakeManager.new(), Parent = top })

			local calls, restore = spyOnTransport()
			childA:SetParent(childB)
			restore()

			expect(childA:GetParent()).is(childB)
			expect(#calls).is(1)
			expect(calls[1].Message.Items[1].Op).is(FlatCodec.Op.SetParent)
			expect(calls[1].Message.Items[1].ParentId).is(childB.Id)

			childA:Destroy()
			childB:Destroy()
			top:Destroy()
		end)

		test("errors when the new parent is a descendant of self", function()
			local token = uniqueToken("SetParentCircular")
			local top = ServerReplicator.new({ Token = token, Data = FakeManager.new(), ReplicationTargets = {} })
			local child = ServerReplicator.new({ Token = token, Data = FakeManager.new(), Parent = top })
			local grandchild = ServerReplicator.new({ Token = token, Data = FakeManager.new(), Parent = child })

			expect(function()
				child:SetParent(grandchild)
			end).fails()

			grandchild:Destroy()
			child:Destroy()
			top:Destroy()
		end)

		test("across scopes reconciles Create/Destroy/SetParent per player", function()
			local token = uniqueToken("SetParentCrossScope")
			local onlyOld = { Name = "OnlyOld" } :: any
			local onlyNew = { Name = "OnlyNew" } :: any
			local both = { Name = "Both" } :: any

			local oldTop = ServerReplicator.new({ Token = token, Data = FakeManager.new(), ReplicationTargets = { onlyOld, both } })
			local newTop = ServerReplicator.new({ Token = token, Data = FakeManager.new(), ReplicationTargets = { onlyNew, both } })
			;(oldTop :: any)._Scope:Activate(onlyOld)
			;(oldTop :: any)._Scope:Activate(both)
			;(newTop :: any)._Scope:Activate(onlyNew)
			;(newTop :: any)._Scope:Activate(both)

			local moved = ServerReplicator.new({ Token = token, Data = FakeManager.new(), Parent = oldTop })

			local calls, restore = spyOnTransport()
			moved:SetParent(newTop)
			restore()

			local byPlayer: { [any]: any } = {}
			for _, call in calls do
				byPlayer[call.Player] = call.Message.Items[1]
			end

			expect(byPlayer[onlyOld].Op).is(FlatCodec.Op.Destroy)
			expect(byPlayer[both].Op).is(FlatCodec.Op.SetParent)
			expect(byPlayer[onlyNew].Op).is(FlatCodec.Op.Create)
			expect(moved:GetParent()).is(newTop)

			moved:Destroy()
			oldTop:Destroy()
			newTop:Destroy()
		end)

		test("is a no-op when the new parent is already the current parent", function()
			local top = ServerReplicator.new({ Token = uniqueToken("SetParentNoOpTop"), Data = FakeManager.new(), ReplicationTargets = {} })
			local child = ServerReplicator.new({ Token = uniqueToken("SetParentNoOpChild"), Data = FakeManager.new(), Parent = top })

			local calls, restore = spyOnTransport()
			child:SetParent(top)
			restore()

			expect(#calls).is(0)
			child:Destroy()
			top:Destroy()
		end)

		test("errors when called on a top-level replicator", function()
			local top = ServerReplicator.new({ Token = uniqueToken("SetParentTopLevelError"), Data = FakeManager.new(), ReplicationTargets = {} })
			local otherTop = ServerReplicator.new({ Token = uniqueToken("SetParentTopLevelErrorOther"), Data = FakeManager.new(), ReplicationTargets = {} })
			expect(function()
				top:SetParent(otherTop)
			end).fails()
			top:Destroy()
			otherTop:Destroy()
		end)
	end)

	--------------------------------------------------------------------------------

	describe("ServerReplicator.Destroy", function()
		test("sends a Destroy item to active players and drops from discovery", function()
			local token = uniqueToken("DestroyTest")
			local player = { Name = "P" } :: any
			local replicator = ServerReplicator.new({ Token = token, Data = FakeManager.new(), ReplicationTargets = { player } })
			;(replicator :: any)._Scope:Activate(player)
			local id = replicator.Id

			local calls, restore = spyOnTransport()
			replicator:Destroy()
			restore()

			expect(#calls).is(1)
			expect(calls[1].Message.Items[1].Op).is(FlatCodec.Op.Destroy)
			expect(BaseReplicator.GetFromId(id)).is(nil)
		end)

		test("sends a Destroy item to every active player, not just one", function()
			local playerA = { Name = "A" } :: any
			local playerB = { Name = "B" } :: any
			local replicator = ServerReplicator.new({
				Token = uniqueToken("DestroyMultiplePlayers"),
				Data = FakeManager.new(),
				ReplicationTargets = { playerA, playerB },
			})
			;(replicator :: any)._Scope:Activate(playerA)
			;(replicator :: any)._Scope:Activate(playerB)

			local calls, restore = spyOnTransport()
			replicator:Destroy()
			restore()

			expect(#calls).is(2)
		end)

		test("drops any data ops queued earlier this frame for that replicator", function()
			local player = { Name = "P" } :: any
			local replicator =
				ServerReplicator.new({ Token = uniqueToken("DestroyDropsQueuedOps"), Data = { x = 0 }, ReplicationTargets = { player } })
			;(replicator :: any)._Scope:Activate(player)

			replicator.Manager:Set("x", 1) -- queued, not yet flushed

			local calls, restore = spyOnTransport()
			replicator:Destroy() -- synchronous Destroy item + drops the queued op
			;(ServerReplicator :: any)._FrameCoordinator:Flush() -- would resurrect the op if not dropped
			restore()

			expect(#calls).is(1)
			expect(calls[1].Message.Items[1].Op).is(FlatCodec.Op.Destroy)
		end)

		test("does not affect an unrelated replicator", function()
			local a = ServerReplicator.new({ Token = uniqueToken("DestroyUnrelatedA"), Data = FakeManager.new(), ReplicationTargets = {} })
			local b = ServerReplicator.new({ Token = uniqueToken("DestroyUnrelatedB"), Data = FakeManager.new(), ReplicationTargets = {} })
			a:Destroy()
			expect(BaseReplicator.GetFromId(b.Id)).is(b)
			b:Destroy()
		end)

		test("a pending (never-activated) target receives nothing, since it was never sent anything", function()
			local player = { Name = "NeverActivated" } :: any
			local replicator =
				ServerReplicator.new({ Token = uniqueToken("DestroyPendingOnly"), Data = FakeManager.new(), ReplicationTargets = { player } })

			local calls, restore = spyOnTransport()
			replicator:Destroy()
			restore()

			expect(#calls).is(0)
		end)

		test("destroying a parent reparents its children to ServerReplicator.None server-side", function()
			local parent = ServerReplicator.new({ Token = uniqueToken("DestroyReparentsToNone"), Data = FakeManager.new(), ReplicationTargets = {} })
			local child = ServerReplicator.new({ Token = uniqueToken("DestroyReparentsToNoneChild"), Data = FakeManager.new(), Parent = parent })
			parent:Destroy()
			expect(BaseReplicator.GetFromId(child.Id)).is(child)
			expect(child:GetParent()).is(ServerReplicator.None)
			expect(child:IsTopLevel()).is_false()
			child:Destroy()
		end)

		test("destroying a parent with an active-player child sends the child's Destroy before the parent's", function()
			local player = { Name = "P" } :: any
			local parent = ServerReplicator.new({ Token = uniqueToken("DestroyOrderParent"), Data = FakeManager.new(), ReplicationTargets = { player } })
			;(parent :: any)._Scope:Activate(player)
			local child = ServerReplicator.new({ Token = uniqueToken("DestroyOrderChild"), Data = FakeManager.new(), Parent = parent })
			local parentId = parent.Id
			local childId = child.Id

			local calls, restore = spyOnTransport()
			parent:Destroy()
			restore()

			local childMsgIdx: number? = nil
			local parentMsgIdx: number? = nil
			for i, call in calls do
				local item = call.Message.Items[1] :: any
				if item.Op == FlatCodec.Op.Destroy then
					if item.Id == childId then
						childMsgIdx = i
					elseif item.Id == parentId then
						parentMsgIdx = i
					end
				end
			end

			expect(childMsgIdx).never_is(nil)
			expect(parentMsgIdx).never_is(nil)
			expect((childMsgIdx :: number) < (parentMsgIdx :: number)).is_true()
		end)

		test("destroying a parent with multiple active-player children sends a Destroy for each child", function()
			local player = { Name = "P" } :: any
			local parent = ServerReplicator.new({ Token = uniqueToken("DestroyMultiChildParent"), Data = FakeManager.new(), ReplicationTargets = { player } })
			;(parent :: any)._Scope:Activate(player)
			local childA = ServerReplicator.new({ Token = uniqueToken("DestroyMultiChildA"), Data = FakeManager.new(), Parent = parent })
			local childB = ServerReplicator.new({ Token = uniqueToken("DestroyMultiChildB"), Data = FakeManager.new(), Parent = parent })

			local calls, restore = spyOnTransport()
			parent:Destroy()
			restore()

			local destroyIds: { [number]: boolean } = {}
			for _, call in calls do
				local item = call.Message.Items[1] :: any
				if item.Op == FlatCodec.Op.Destroy then
					destroyIds[item.Id] = true
				end
			end

			expect(destroyIds[childA.Id]).is_true()
			expect(destroyIds[childB.Id]).is_true()
			expect(destroyIds[parent.Id]).is_true()
		end)

		test("destroying a childless replicator still works (no-op children loop)", function()
			local replicator = ServerReplicator.new({ Token = uniqueToken("DestroyNoChildrenNoop"), Data = FakeManager.new(), ReplicationTargets = {} })
			expect(function()
				replicator:Destroy()
			end).never_fails()
		end)
	end)
end
