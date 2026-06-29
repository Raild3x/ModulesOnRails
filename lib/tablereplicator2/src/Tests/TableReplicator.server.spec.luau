--!strict
--[[
	Phase 1 coverage for TableReplicator2: the wire codec, the per-frame op
	buffer, BaseReplicator discovery/hierarchy/tags, ServerReplicator
	targeting + hierarchy + lifecycle, and ClientReplicator's apply pipeline.

	No real RemoteEvent traffic is exercised here: `FireServer`/`FireClient`
	are realm-restricted in real Roblox (a server-only test context has no
	client to deliver to), so server-side behavior is asserted by spying on
	`ServerReplicator._Transport` directly, and client-side behavior is
	exercised by feeding hand-built wire messages straight into
	`ClientReplicator._HandleMessage` -- both test-only escape hatches, not
	part of the public API. `Player` targets are stood in for with plain
	tables (`:: any`-cast): every targeting/hierarchy code path here only
	ever uses a player value as an opaque dictionary key, never a real
	`Player` API, so a real `Players` connection isn't needed to exercise it.
]]

return function(t: tiniest)
	local FlatCodec = require("../Shared/Serialization/FlatCodec")
	local RefCodec = require("../Shared/Serialization/RefCodec")
	local OpBuffer = require("../Shared/OpBuffer")
	local BaseReplicator = require("../Shared/BaseReplicator")
	local ServerReplicator = require("../Server/ServerReplicator")
	local ClientReplicator = require("../Client/ClientReplicator")
	local OpApplier = require("../Client/OpApplier")
	local Types = require("../Shared/Types")
	local TableManagerModule = Types.TableManager
	local FakeManager = require("./Helpers/FakeManager")
	local FakeIntermediary = require("./Helpers/FakeIntermediary")

	const getTokenName = function(token)
		return token.__NAME__
	end

	local describe = t.describe
	local test = t.test
	local expect = t.expect

	-- ServerReplicator.Token enforces one-use-per-name globally for the
	-- whole process, so every test needs its own unique name.
	local tokenCounter = 0
	local function uniqueToken(label: string)
		tokenCounter += 1
		return ServerReplicator.Token(`{label}#{tokenCounter}`)
	end

	-- `FireClient` can't be delivered to the plain-table player stand-ins used
	-- throughout this file (it requires a real `Player` Instance), so the real
	-- `ServerTransport.SendMessage`/`NotifyDataSent` must never run here. This
	-- installs a permanent no-op baseline -- covering every send that happens
	-- OUTSIDE a `spyOnTransport()` window: replicator construction/`Destroy`
	-- during test setup/cleanup, and `ServerReplicator.All`'s "all" scope
	-- eagerly snapshotting any player that fires `PlayerRequestedData`.
	local function noop() end
	;(ServerReplicator._Transport :: any).SendMessage = noop
	;(ServerReplicator._Transport :: any).NotifyDataSent = noop

	-- Reassigns `SendMessage` directly on the live transport instance,
	-- shadowing the class method (see `ServerTransport.__index`) so calls are
	-- recorded instead of hitting the real method. Restored back to the no-op
	-- baseline above, NOT to the real method (see why above).
	local function spyOnTransport(): ({ { Player: any, Message: any } }, () -> ())
		local calls = {}
		(ServerReplicator._Transport :: any).SendMessage = function(_self, player, message)
			table.insert(calls, { Player = player, Message = message })
		end
		return calls, function()
			(ServerReplicator._Transport :: any).SendMessage = noop
		end
	end

	local function deepEqual(a: any, b: any): boolean
		if a == b then
			return true
		end
		if type(a) ~= "table" or type(b) ~= "table" then
			return false
		end
		for k, v in a do
			if not deepEqual(v, b[k]) then
				return false
			end
		end
		for k in b do
			if a[k] == nil then
				return false
			end
		end
		return true
	end

	local function wireCopy(value: any): any
		if type(value) ~= "table" then
			return value
		end
		local copy = {}
		for k, v in value do
			copy[wireCopy(k)] = wireCopy(v)
		end
		return copy
	end

	--------------------------------------------------------------------------------

	describe("FlatCodec", function()
		test("Create/Destroy/SetParent items carry their fields", function()
			local create = FlatCodec.CreateItem(5, 2, "Tok", { a = 1 }, { b = 2 })
			expect(create.Op).is(FlatCodec.Op.Create)
			expect(create.Id).is(5)
			expect(create.ParentId).is(2)
			expect(create.Token).is("Tok")
			expect((create.Tags :: any).a).is(1)
			expect((create.Data :: any).b).is(2)

			local createNoParent = FlatCodec.CreateItem(5, nil, "Tok", {}, {})
			expect(createNoParent.ParentId).is(FlatCodec.NoParent)

			local destroy = FlatCodec.DestroyItem(9)
			expect(destroy.Op).is(FlatCodec.Op.Destroy)
			expect(destroy.Id).is(9)

			local setParent = FlatCodec.SetParentItem(9, 3)
			expect(setParent.Op).is(FlatCodec.Op.SetParent)
			expect(setParent.Id).is(9)
			expect(setParent.ParentId).is(3)
		end)

		test("OpsItem/DecodeOps round-trips Kind/Path/Value/Index for every op kind", function()
			local ops = {
				{ Kind = "Set", Path = { "a", "b" }, Value = 5 },
				{ Kind = "ArrayInsert", Path = { "arr" }, Index = 1, Value = "x" },
				{ Kind = "ArrayRemove", Path = { "arr" }, Index = 2 },
				{ Kind = "ArraySet", Path = { "arr" }, Index = 1, Value = "y" },
				{ Kind = "BatchBegin", Path = {} },
				{ Kind = "BatchEnd", Path = {} },
			}
			local item = FlatCodec.OpsItem(7, ops :: any)
			expect(item.Op).is(FlatCodec.Op.Ops)
			expect(item.Id).is(7)
			expect(#item.Ops).is(6)

			local decoded = FlatCodec.DecodeOps(item)
			expect(#decoded).is(6)
			for i, op in decoded do
				expect(op.Kind).is(ops[i].Kind)
			end
			expect(decoded[1].Path[1]).is("a")
			expect(decoded[1].Value).is(5)
			expect(decoded[2].Index).is(1)
			expect(decoded[2].Value).is("x")
			expect(decoded[3].Index).is(2)
			expect(decoded[4].Value).is("y")
		end)

		test("BuildMessage wraps items with the current version", function()
			local message = FlatCodec.BuildMessage({})
			expect(message.V).is(FlatCodec.Version)
			expect(#message.Items).is(0)
		end)
	end)

	--------------------------------------------------------------------------------

	describe("RefCodec (Model V table dedup)", function()
		test("Encode is a no-op when no table is shared", function()
			local items = {
				FlatCodec.CreateItem(1, nil, "Tok", {}, { a = 1, nested = { b = 2 } }),
			}
			local encoded, refs = RefCodec.Encode(items :: any)
			expect(refs).is(nil)
			expect(encoded).is(items) -- same list, no copying
		end)

		test("Encode de-dups a table shared across two items; ResolveValue expands to independent copies", function()
			local shared = { hp = 100 }
			local items = {
				FlatCodec.CreateItem(1, nil, "Tok", {}, { B = shared }),
				FlatCodec.CreateItem(2, nil, "Tok", {}, { B = shared }),
			}
			local encoded, refs = RefCodec.Encode(items :: any)
			expect(refs).never_is(nil)

			-- Exactly one pooled definition; both Data.B are placeholders to it.
			local count = 0
			for _ in refs :: any do
				count += 1
			end
			expect(count).is(1)

			local marker = RefCodec.Marker
			local placeholderA = (encoded[1] :: any).Data.B
			local placeholderB = (encoded[2] :: any).Data.B
			expect(placeholderA[marker]).never_is(nil)
			expect(placeholderA[marker]).is(placeholderB[marker])

			-- Resolved separately -> equal values, distinct tables.
			local resolvedA = RefCodec.ResolveValue((encoded[1] :: any).Data, refs :: any)
			local resolvedB = RefCodec.ResolveValue((encoded[2] :: any).Data, refs :: any)
			expect(resolvedA.B.hp).is(100)
			expect(resolvedB.B.hp).is(100)
			expect(resolvedA.B == resolvedB.B).is(false)
		end)

		test("a shared table containing a cycle round-trips without hanging", function()
			local shared = {} :: any
			shared.self = shared
			local items = {
				FlatCodec.CreateItem(1, nil, "Tok", {}, { B = shared }),
				FlatCodec.CreateItem(2, nil, "Tok", {}, { B = shared }),
			}
			local encoded, refs = RefCodec.Encode(items :: any)
			expect(refs).never_is(nil)

			local resolved = RefCodec.ResolveValue((encoded[1] :: any).Data, refs :: any)
			-- The cycle is preserved within a single resolved value.
			expect(resolved.B.self).is(resolved.B)
		end)

		test("a shared snapshot table arrives as independent copies on the client", function()
			local shared = { hp = 100 }
			local items = {
				FlatCodec.CreateItem(701, nil, "RefShareA", {}, { B = shared }),
				FlatCodec.CreateItem(702, nil, "RefShareB", {}, { B = shared }),
			}
			local encoded, refs = RefCodec.Encode(items :: any)
			;(ClientReplicator :: any)._HandleMessage(FlatCodec.BuildMessage(encoded, refs))

			local a = BaseReplicator.GetFromId(701) :: any
			local b = BaseReplicator.GetFromId(702) :: any
			expect(a.Manager.Raw.B.hp).is(100)
			expect(b.Manager.Raw.B.hp).is(100)
			expect(a.Manager.Raw.B == b.Manager.Raw.B).is(false)

			-- Mutating one copy leaves the other untouched.
			a.Manager.Raw.B.hp = 5
			expect(b.Manager.Raw.B.hp).is(100)

			;(ClientReplicator :: any)._HandleMessage(FlatCodec.BuildMessage({ FlatCodec.DestroyItem(701) }))
			;(ClientReplicator :: any)._HandleMessage(FlatCodec.BuildMessage({ FlatCodec.DestroyItem(702) }))
		end)
	end)

	--------------------------------------------------------------------------------

	describe("OpBuffer", function()
		test("normalizes a Set op carrying NewValue", function()
			local buffer = OpBuffer.new()
			buffer:Push(1, { Kind = "Set", Path = { "x" }, NewValue = 5 } :: any)
			local drained = buffer:Drain()
			expect(#drained).is(1)
			expect(drained[1].Id).is(1)
			expect(drained[1].Ops[1].Kind).is("Set")
			expect(drained[1].Ops[1].Value).is(5)
		end)

		test("normalizes a Set op riding a Diff node (uses Diff.new, not NewValue)", function()
			local buffer = OpBuffer.new()
			buffer:Push(1, { Kind = "Set", Path = { "x" }, Diff = { new = 9, old = 5, type = "changed" } } :: any)
			local drained = buffer:Drain()
			expect(drained[1].Ops[1].Value).is(9)
		end)

		test("normalizes array ops, keeping Index", function()
			local buffer = OpBuffer.new()
			buffer:Push(1, { Kind = "ArrayInsert", Path = { "arr" }, Index = 1, NewValue = "x" } :: any)
			buffer:Push(1, { Kind = "ArrayRemove", Path = { "arr" }, Index = 2 } :: any)
			buffer:Push(1, { Kind = "ArraySet", Path = { "arr" }, Index = 1, NewValue = "y" } :: any)
			local ops = buffer:Drain()[1].Ops
			expect(ops[1].Kind).is("ArrayInsert")
			expect(ops[1].Value).is("x")
			expect(ops[2].Kind).is("ArrayRemove")
			expect(ops[2].Index).is(2)
			expect(ops[3].Kind).is("ArraySet")
			expect(ops[3].Value).is("y")
		end)

		test("BatchBegin/BatchEnd markers carry no value", function()
			local buffer = OpBuffer.new()
			buffer:Push(1, { Kind = "BatchBegin", Path = {} } :: any)
			buffer:Push(1, { Kind = "BatchEnd", Path = {} } :: any)
			local ops = buffer:Drain()[1].Ops
			expect(ops[1].Kind).is("BatchBegin")
			expect(ops[2].Kind).is("BatchEnd")
		end)

		test("groups ops by replicator id, in first-touched order", function()
			local buffer = OpBuffer.new()
			buffer:Push(2, { Kind = "Set", Path = { "a" }, NewValue = 1 } :: any)
			buffer:Push(1, { Kind = "Set", Path = { "b" }, NewValue = 2 } :: any)
			buffer:Push(2, { Kind = "Set", Path = { "c" }, NewValue = 3 } :: any)
			local drained = buffer:Drain()
			expect(#drained).is(2)
			expect(drained[1].Id).is(2)
			expect(#drained[1].Ops).is(2)
			expect(drained[2].Id).is(1)
		end)

		test("Drain empties the buffer", function()
			local buffer = OpBuffer.new()
			buffer:Push(1, { Kind = "Set", Path = { "a" }, NewValue = 1 } :: any)
			expect(buffer:IsEmpty()).is(false)
			buffer:Drain()
			expect(buffer:IsEmpty()).is_true()
			expect(#buffer:Drain()).is(0)
		end)
	end)

	--------------------------------------------------------------------------------

	describe("BaseReplicator discovery, hierarchy, and tags", function()
		test("OnNew fires for a future replicator with a matching token", function()
			local token = uniqueToken("OnNewTest")
			local seen: { any } = {}
			local disconnect = BaseReplicator.OnNew(getTokenName(token), function(replicator)
				table.insert(seen, replicator)
			end)

			local replicator = ServerReplicator.new({ Token = token, Data = FakeManager.new(), ReplicationTargets = {} })

			expect(#seen).is(1)
			expect(seen[1]).is(replicator)

			disconnect()
			replicator:Destroy()
		end)

		test("GetAll(token) returns only replicators using that token", function()
			local tokenA = uniqueToken("GetAllA")
			local tokenB = uniqueToken("GetAllB")
			local a = ServerReplicator.new({ Token = tokenA, Data = FakeManager.new(), ReplicationTargets = {} })
			local b = ServerReplicator.new({ Token = tokenB, Data = FakeManager.new(), ReplicationTargets = {} })

			local resultsA = BaseReplicator.GetAll(tokenA)
			expect(#resultsA).is(1)
			expect(resultsA[1]).is(a)

			a:Destroy()
			b:Destroy()
		end)

		test("tag predicates: IsSupersetOfTags / IsSubsetOfTags", function()
			local token = uniqueToken("TagsTest")
			local replicator =
				ServerReplicator.new({ Token = token, Data = FakeManager.new(), ReplicationTargets = {}, Tags = { A = 1, B = 2 } })

			expect(replicator:IsSupersetOfTags({ A = 1 })).is_true()
			expect(replicator:IsSupersetOfTags({ A = 1, B = 2 })).is_true()
			expect(replicator:IsSupersetOfTags({ A = 99 })).is(false)

			expect(replicator:IsSubsetOfTags({ A = 1, B = 2, C = 3 })).is_true()
			expect(replicator:IsSubsetOfTags({ A = 1 })).is(false)

			replicator:Destroy()
		end)

		test("GetChildren/GetDescendants/FindFirstChild walk the hierarchy", function()
			local token = uniqueToken("HierarchyTest")
			local parent = ServerReplicator.new({ Token = token, Data = FakeManager.new(), ReplicationTargets = {} })
			local child = ServerReplicator.new({ Token = token, Data = FakeManager.new(), Parent = parent, Tags = { Name = "Child" } })
			local grandchild =
				ServerReplicator.new({ Token = token, Data = FakeManager.new(), Parent = child, Tags = { Name = "Grandchild" } })

			expect(#parent:GetChildren()).is(1)
			expect(parent:GetChildren()[1]).is(child)
			expect(#parent:GetDescendants()).is(2)

			local found = parent:FindFirstChild({ Name = "Grandchild" }, true)
			expect(found).is(grandchild)
			expect(parent:FindFirstChild({ Name = "Grandchild" })).is(nil)

			grandchild:Destroy()
			child:Destroy()
			parent:Destroy()
		end)
	end)

	--------------------------------------------------------------------------------

	describe("ServerReplicator construction", function()
		test("Token errors if the same name is registered twice", function()
			ServerReplicator.Token("DuplicateTokenTest")
			expect(function()
				ServerReplicator.Token("DuplicateTokenTest")
			end).fails()
		end)

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
	end)

	--------------------------------------------------------------------------------

	describe("ServerReplicator targeting", function()
		test("SetTargets(explicit list) drives IsReplicatingTo/GetTargets", function()
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

		test("AddTarget sends a snapshot to an already-bootstrapped player", function()
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

		test("RemoveTarget sends a Destroy to a currently-active player", function()
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
	end)

	--------------------------------------------------------------------------------

	describe("ServerReplicator hierarchy", function()
		test("constructing a child sends Create to the parent scope's active players", function()
			local token = uniqueToken("ChildCreateSend")
			local player = { Name = "P" } :: any
			local parent = ServerReplicator.new({ Token = token, Data = FakeManager.new(), ReplicationTargets = { player } })
			;(parent :: any)._Scope:Activate(player)

			local calls, restore = spyOnTransport()
			local child = ServerReplicator.new({ Token = token, Data = FakeManager.new(), Parent = parent })
			restore()

			expect(#calls).is(1)
			expect(calls[1].Message.Items[1].Op).is(FlatCodec.Op.Create)
			expect(calls[1].Message.Items[1].Id).is(child.Id)
			expect(calls[1].Message.Items[1].ParentId).is(parent.Id)

			child:Destroy()
			parent:Destroy()
		end)

		test("SetParent within the same scope sends a SetParent item", function()
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

		test("SetParent errors when the new parent is a descendant of self", function()
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

		test("SetParent across scopes reconciles Create/Destroy/SetParent per player", function()
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
	end)

	--------------------------------------------------------------------------------

	describe("ServerReplicator lifecycle", function()
		test("Destroy sends a Destroy item to active players and drops from discovery", function()
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
	end)

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
	end)

	--------------------------------------------------------------------------------

	describe("ClientReplicator apply pipeline", function()
		test("a Create item builds a replicator with the right parent/tags/data", function()
			local message = FlatCodec.BuildMessage({
				FlatCodec.CreateItem(101, nil, "ClientCreateTest", { K = "v" }, { Coins = 5 }),
			})
			;(ClientReplicator :: any)._HandleMessage(message)

			local replicator = BaseReplicator.GetFromId(101) :: any
			expect(replicator).never_is(nil)
			expect(replicator:GetTokenName()).is("ClientCreateTest")
			expect(replicator.Tags.K).is("v")
			expect(replicator.Manager.Raw.Coins).is(5)
			expect(replicator:IsTopLevel()).is_true()

			-- Recursive teardown is server-driven only; route through the
			-- internal handler the same way a real `Destroy` item would.
			;(ClientReplicator :: any)._HandleMessage(FlatCodec.BuildMessage({ FlatCodec.DestroyItem(101) }))
			expect(BaseReplicator.GetFromId(101)).is(nil)
		end)

		test("Destroy recursively tears down descendants", function()
			local message = FlatCodec.BuildMessage({
				FlatCodec.CreateItem(201, nil, "ClientDestroyTest", {}, {}),
				FlatCodec.CreateItem(202, 201, "ClientDestroyTest", {}, {}),
			})
			;(ClientReplicator :: any)._HandleMessage(message)
			expect(BaseReplicator.GetFromId(201)).never_is(nil)
			expect(BaseReplicator.GetFromId(202)).never_is(nil)

			;(ClientReplicator :: any)._HandleMessage(FlatCodec.BuildMessage({ FlatCodec.DestroyItem(201) }))
			expect(BaseReplicator.GetFromId(201)).is(nil)
			expect(BaseReplicator.GetFromId(202)).is(nil)
		end)

		test("SetParent re-homes the child in the local hierarchy", function()
			local message = FlatCodec.BuildMessage({
				FlatCodec.CreateItem(301, nil, "ClientSetParentTest", {}, {}),
				FlatCodec.CreateItem(302, nil, "ClientSetParentTest", {}, {}),
				FlatCodec.CreateItem(303, 301, "ClientSetParentTest", {}, {}),
			})
			;(ClientReplicator :: any)._HandleMessage(message)

			local newParent = BaseReplicator.GetFromId(302) :: any
			local child = BaseReplicator.GetFromId(303) :: any
			expect(child:GetParent().Id).is(301)

			;(ClientReplicator :: any)._HandleMessage(FlatCodec.BuildMessage({ FlatCodec.SetParentItem(303, 302) }))
			expect(child:GetParent()).is(newParent)

			;(ClientReplicator :: any)._HandleMessage(FlatCodec.BuildMessage({ FlatCodec.DestroyItem(301) }))
			;(ClientReplicator :: any)._HandleMessage(FlatCodec.BuildMessage({ FlatCodec.DestroyItem(302) }))
		end)

		test("an Ops item applies through the real Mutator API", function()
			local message = FlatCodec.BuildMessage({
				FlatCodec.CreateItem(401, nil, "ClientOpsTest", {}, { Coins = 0, Items = {} }),
			})
			;(ClientReplicator :: any)._HandleMessage(message)
			local replicator = BaseReplicator.GetFromId(401) :: any

			local opsItem = FlatCodec.OpsItem(401, {
				{ Kind = "Set", Path = { "Coins" }, Value = 10 },
				{ Kind = "ArrayInsert", Path = { "Items" }, Index = 1, Value = "Sword" },
			} :: any)
			;(ClientReplicator :: any)._HandleMessage(FlatCodec.BuildMessage({ opsItem }))

			expect(replicator.Manager.Raw.Coins).is(10)
			expect(replicator.Manager.Raw.Items[1]).is("Sword")

			;(ClientReplicator :: any)._HandleMessage(FlatCodec.BuildMessage({ FlatCodec.DestroyItem(401) }))
		end)
	end)

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
