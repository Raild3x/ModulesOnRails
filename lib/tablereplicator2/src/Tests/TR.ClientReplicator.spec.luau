--!strict
--[[
	Coverage for `ClientReplicator`: its tiny real public surface
	(`RequestData`, `Destroy`) plus the apply pipeline behind every wire
	operation it handles (Create/Destroy/SetParent/Ops), exercised by feeding
	hand-built wire messages straight into `ClientReplicator._HandleMessage`
	-- a test-only escape hatch standing in for a real `ClientTransport.
	MessageReceived` delivery, not part of the public API.

	`ClientReplicator.RequestData()`'s REAL handshake/snapshot behavior can't
	be exercised end-to-end here: it lazily builds a real `ClientTransport`,
	which waits on a real `RemoteEvent` round-trip that never completes
	against the plain-table player stand-ins used in this whole test suite
	(no real `Player` Instance exists to `FireClient`/`FireServer` with). That
	full behavior -- a `RequestData()`-triggered snapshot landing correctly on
	a simulated client -- is covered by the 8 `FakeIntermediary` tests in
	`TableReplicator.EndToEnd.spec.luau`, which exercise the exact same
	server-side handshake `RequestData()` triggers, just invoked through a
	test-only signal-fire seam instead of a real transport. Only smoke tests
	on the real function itself live here.
]]

return function(t: tiniest)
	local FlatCodec = require("../Shared/Serialization/FlatCodec")
	local BaseReplicator = require("../Shared/BaseReplicator")
	local ClientReplicator = require("../Client/ClientReplicator")

	local describe = t.describe
	local test = t.test
	local expect = t.expect

	local function handle(message: any)
		ClientReplicator._HandleMessage(message)
	end

	local function destroy(id: number)
		handle(FlatCodec.BuildMessage { FlatCodec.DestroyItem(id) })
	end

	--------------------------------------------------------------------------------

	describe("ClientReplicator: Create handling", function()
		test("builds a replicator with the right parent/tags/data", function()
			handle(FlatCodec.BuildMessage {
				FlatCodec.CreateItem(60001, nil, "ClientCreateTest", { K = "v" }, { Coins = 5 }),
			})

			local replicator = BaseReplicator.GetFromId(60001) :: any
			expect(replicator).never_is(nil)
			expect(replicator.Namespace).is("ClientCreateTest")
			expect(replicator.Tags.K).is("v")
			expect(replicator.Manager.Raw.Coins).is(5)
			expect(replicator:IsTopLevel()).is_true()

			destroy(60001)
			expect(BaseReplicator.GetFromId(60001)).is(nil)
		end)

		test("a child create references its already-built parent in the same message", function()
			handle(FlatCodec.BuildMessage {
				FlatCodec.CreateItem(60002, nil, "ClientCreateParent", {}, {}),
				FlatCodec.CreateItem(60003, 60002, "ClientCreateChild", {}, {}),
			})
			local child = BaseReplicator.GetFromId(60003) :: any
			expect(child:GetParent().Id).is(60002)
			destroy(60002)
		end)

		test("fires ChildAdded on the parent", function()
			handle(FlatCodec.BuildMessage { FlatCodec.CreateItem(60004, nil, "ClientCreateParentEvent", {}, {}) })
			local parent = BaseReplicator.GetFromId(60004) :: any
			local added: any = nil
			parent.ChildAdded:Connect(function(child)
				added = child
			end)
			handle(FlatCodec.BuildMessage { FlatCodec.CreateItem(60005, 60004, "ClientCreateChildEvent", {}, {}) })
			expect(added).never_is(nil)
			expect(added.Id).is(60005)
			destroy(60004)
		end)

		test("fires creation listeners (OnNew) only after the whole message is built", function()
			local seenParentAlreadyHasChild = false
			local disconnect = BaseReplicator.OnNew("ClientCreateListenerParent", function(replicator)
				seenParentAlreadyHasChild = #replicator:GetChildren() == 1
			end)
			handle(FlatCodec.BuildMessage {
				FlatCodec.CreateItem(60006, nil, "ClientCreateListenerParent", {}, {}),
				FlatCodec.CreateItem(60007, 60006, "ClientCreateListenerChild", {}, {}),
			})
			expect(seenParentAlreadyHasChild).is_true()
			disconnect()
			destroy(60006)
		end)

		test("a grandchild can reference a parent that is ALSO new in the same message", function()
			handle(FlatCodec.BuildMessage {
				FlatCodec.CreateItem(60008, nil, "ClientCreateGGTop", {}, {}),
				FlatCodec.CreateItem(60009, 60008, "ClientCreateGGMid", {}, {}),
				FlatCodec.CreateItem(60010, 60009, "ClientCreateGGLeaf", {}, {}),
			})
			local leaf = BaseReplicator.GetFromId(60010) :: any
			expect(leaf:GetParent().Id).is(60009)
			expect(leaf:GetParent():GetParent().Id).is(60008)
			destroy(60008)
		end)
	end)

	--------------------------------------------------------------------------------

	describe("ClientReplicator: Destroy handling", function()
		test("tears down a single leaf replicator", function()
			handle(FlatCodec.BuildMessage { FlatCodec.CreateItem(60101, nil, "ClientDestroyLeaf", {}, {}) })
			destroy(60101)
			expect(BaseReplicator.GetFromId(60101)).is(nil)
		end)

		test("recursively tears down descendants", function()
			handle(FlatCodec.BuildMessage {
				FlatCodec.CreateItem(60102, nil, "ClientDestroyTest", {}, {}),
				FlatCodec.CreateItem(60103, 60102, "ClientDestroyTest", {}, {}),
			})
			expect(BaseReplicator.GetFromId(60102)).never_is(nil)
			expect(BaseReplicator.GetFromId(60103)).never_is(nil)

			destroy(60102)
			expect(BaseReplicator.GetFromId(60102)).is(nil)
			expect(BaseReplicator.GetFromId(60103)).is(nil)
		end)

		test("destroying one child leaves the parent and other siblings intact", function()
			handle(FlatCodec.BuildMessage {
				FlatCodec.CreateItem(60104, nil, "ClientDestroySiblingsParent", {}, {}),
				FlatCodec.CreateItem(60105, 60104, "ClientDestroySiblingA", {}, {}),
				FlatCodec.CreateItem(60106, 60104, "ClientDestroySiblingB", {}, {}),
			})
			destroy(60105)
			expect(BaseReplicator.GetFromId(60104)).never_is(nil)
			expect(BaseReplicator.GetFromId(60105)).is(nil)
			expect(BaseReplicator.GetFromId(60106)).never_is(nil)
			destroy(60104)
		end)

		test("asserts when the Destroy item references an unknown replicator", function()
			expect(function()
				destroy(60199) -- never created
			end).fails()
		end)

		test("removes the replicator from BaseReplicator.GetAll too", function()
			handle(FlatCodec.BuildMessage { FlatCodec.CreateItem(60107, nil, "ClientDestroyGetAll", {}, {}) })
			expect(#BaseReplicator.GetAll("ClientDestroyGetAll")).is(1)
			destroy(60107)
			expect(#BaseReplicator.GetAll("ClientDestroyGetAll")).is(0)
		end)
	end)

	--------------------------------------------------------------------------------

	describe("ClientReplicator: SetParent handling", function()
		test("re-homes the child in the local hierarchy", function()
			handle(FlatCodec.BuildMessage {
				FlatCodec.CreateItem(60201, nil, "ClientSetParentTest", {}, {}),
				FlatCodec.CreateItem(60202, nil, "ClientSetParentTest", {}, {}),
				FlatCodec.CreateItem(60203, 60201, "ClientSetParentTest", {}, {}),
			})

			local newParent = BaseReplicator.GetFromId(60202) :: any
			local child = BaseReplicator.GetFromId(60203) :: any
			expect(child:GetParent().Id).is(60201)

			handle(FlatCodec.BuildMessage { FlatCodec.SetParentItem(60203, 60202) })
			expect(child:GetParent()).is(newParent)

			destroy(60201)
			destroy(60202)
		end)

		test("fires ParentChanged with the new and old parent", function()
			handle(FlatCodec.BuildMessage {
				FlatCodec.CreateItem(60204, nil, "ClientSetParentEventTop", {}, {}),
				FlatCodec.CreateItem(60205, nil, "ClientSetParentEventTop", {}, {}),
				FlatCodec.CreateItem(60206, 60204, "ClientSetParentEventChild", {}, {}),
			})
			local child = BaseReplicator.GetFromId(60206) :: any
			local newParentSeen, oldParentSeen
			child.ParentChanged:Connect(function(newParent, oldParent)
				newParentSeen, oldParentSeen = newParent, oldParent
			end)
			handle(FlatCodec.BuildMessage { FlatCodec.SetParentItem(60206, 60205) })
			expect((newParentSeen :: any).Id).is(60205)
			expect((oldParentSeen :: any).Id).is(60204)
			destroy(60204)
			destroy(60205)
		end)

		test("updates GetChildren on both the old and new parent", function()
			handle(FlatCodec.BuildMessage {
				FlatCodec.CreateItem(60207, nil, "ClientSetParentChildrenOld", {}, {}),
				FlatCodec.CreateItem(60208, nil, "ClientSetParentChildrenNew", {}, {}),
				FlatCodec.CreateItem(60209, 60207, "ClientSetParentChildrenChild", {}, {}),
			})
			local oldParent = BaseReplicator.GetFromId(60207) :: any
			local newParent = BaseReplicator.GetFromId(60208) :: any
			handle(FlatCodec.BuildMessage { FlatCodec.SetParentItem(60209, 60208) })
			expect(#oldParent:GetChildren()).is(0)
			expect(#newParent:GetChildren()).is(1)
			destroy(60207)
			destroy(60208)
		end)

		test("asserts when the SetParent item references an unknown child or parent", function()
			handle(FlatCodec.BuildMessage { FlatCodec.CreateItem(60210, nil, "ClientSetParentUnknown", {}, {}) })
			expect(function()
				handle(FlatCodec.BuildMessage { FlatCodec.SetParentItem(60299, 60210) }) -- unknown child
			end).fails()
			expect(function()
				handle(FlatCodec.BuildMessage { FlatCodec.SetParentItem(60210, 60298) }) -- unknown parent
			end).fails()
			destroy(60210)
		end)

		test("re-parenting twice across two messages ends at the final parent", function()
			handle(FlatCodec.BuildMessage {
				FlatCodec.CreateItem(60211, nil, "ClientSetParentTwiceA", {}, {}),
				FlatCodec.CreateItem(60212, nil, "ClientSetParentTwiceB", {}, {}),
				FlatCodec.CreateItem(60213, nil, "ClientSetParentTwiceC", {}, {}),
				FlatCodec.CreateItem(60214, 60211, "ClientSetParentTwiceChild", {}, {}),
			})
			local child = BaseReplicator.GetFromId(60214) :: any
			handle(FlatCodec.BuildMessage { FlatCodec.SetParentItem(60214, 60212) })
			handle(FlatCodec.BuildMessage { FlatCodec.SetParentItem(60214, 60213) })
			expect(child:GetParent().Id).is(60213)
			destroy(60211)
			destroy(60212)
			destroy(60213)
		end)
	end)

	--------------------------------------------------------------------------------

	describe("ClientReplicator: Ops handling", function()
		local function newOpsReplicator(id: number, data: { [string]: any })
			handle(FlatCodec.BuildMessage { FlatCodec.CreateItem(id, nil, "ClientOpsTest", {}, data) })
			return BaseReplicator.GetFromId(id) :: any
		end

		test("Set applies through the real Mutator API", function()
			local replicator = newOpsReplicator(60301, { Coins = 0 })
			handle(FlatCodec.BuildMessage {
				FlatCodec.OpsItem(60301, { { Kind = "Set", Path = { "Coins" }, Value = 10 } } :: any),
			})
			expect(replicator.Manager.Raw.Coins).is(10)
			destroy(60301)
		end)

		test("ArrayInsert applies through the real Mutator API", function()
			local replicator = newOpsReplicator(60302, { Items = {} })
			handle(FlatCodec.BuildMessage {
				FlatCodec.OpsItem(
					60302,
					{ { Kind = "ArrayInsert", Path = { "Items" }, Index = 1, Value = "Sword" } } :: any
				),
			})
			expect(replicator.Manager.Raw.Items[1]).is("Sword")
			destroy(60302)
		end)

		test("ArrayRemove applies through the real Mutator API", function()
			local replicator = newOpsReplicator(60303, { Items = { "a", "b" } })
			handle(FlatCodec.BuildMessage {
				FlatCodec.OpsItem(60303, { { Kind = "ArrayRemove", Path = { "Items" }, Index = 1 } } :: any),
			})
			expect(replicator.Manager.Raw.Items[1]).is("b")
			expect(#replicator.Manager.Raw.Items).is(1)
			destroy(60303)
		end)

		test("ArraySet applies through the real Mutator API", function()
			local replicator = newOpsReplicator(60304, { Items = { "a", "b" } })
			handle(FlatCodec.BuildMessage {
				FlatCodec.OpsItem(60304, { { Kind = "ArraySet", Path = { "Items" }, Index = 2, Value = "c" } } :: any),
			})
			expect(replicator.Manager.Raw.Items[2]).is("c")
			destroy(60304)
		end)

		test("BatchBegin/BatchEnd markers apply without erroring and surrounding ops still land", function()
			local replicator = newOpsReplicator(60305, { Coins = 0 })
			handle(FlatCodec.BuildMessage {
				FlatCodec.OpsItem(
					60305,
					{
						{ Kind = "BatchBegin", Path = {} },
						{ Kind = "Set", Path = { "Coins" }, Value = 7 },
						{ Kind = "BatchEnd", Path = {} },
					} :: any
				),
			})
			expect(replicator.Manager.Raw.Coins).is(7)
			destroy(60305)
		end)
	end)

	--------------------------------------------------------------------------------

	describe("ClientReplicator.RequestData", function()
		test("returns a Promise without erroring", function()
			expect(function()
				ClientReplicator.RequestData()
			end).never_fails()
		end)

		test("is safe to call more than once", function()
			expect(function()
				ClientReplicator.RequestData()
				ClientReplicator.RequestData()
			end).never_fails()
		end)

		test("stays pending in this realm -- there is no real transport to resolve it", function()
			local promise = ClientReplicator.RequestData()
			expect(promise:getStatus()).is("Started")
		end)

		test("multiple outstanding promises all stay pending together", function()
			local first = ClientReplicator.RequestData()
			local second = ClientReplicator.RequestData()
			expect(first:getStatus()).is("Started")
			expect(second:getStatus()).is("Started")
		end)
	end)

	--------------------------------------------------------------------------------

	describe("ClientReplicator.Destroy", function()
		test("errors for a top-level mirror -- destruction is server-driven only", function()
			handle(FlatCodec.BuildMessage { FlatCodec.CreateItem(60401, nil, "ClientDestroyMethodTop", {}, {}) })
			local replicator = BaseReplicator.GetFromId(60401) :: any
			expect(function()
				replicator:Destroy()
			end).fails()
			destroy(60401)
		end)

		test("errors for a child mirror", function()
			handle(FlatCodec.BuildMessage {
				FlatCodec.CreateItem(60402, nil, "ClientDestroyMethodParent", {}, {}),
				FlatCodec.CreateItem(60403, 60402, "ClientDestroyMethodChild", {}, {}),
			})
			local child = BaseReplicator.GetFromId(60403) :: any
			expect(function()
				child:Destroy()
			end).fails()
			destroy(60402)
		end)

		test("errors for a grandchild mirror", function()
			handle(FlatCodec.BuildMessage {
				FlatCodec.CreateItem(60404, nil, "ClientDestroyMethodGP", {}, {}),
				FlatCodec.CreateItem(60405, 60404, "ClientDestroyMethodMid", {}, {}),
				FlatCodec.CreateItem(60406, 60405, "ClientDestroyMethodLeaf", {}, {}),
			})
			local leaf = BaseReplicator.GetFromId(60406) :: any
			expect(function()
				leaf:Destroy()
			end).fails()
			destroy(60404)
		end)

		test("errors even after data ops have been applied to it", function()
			handle(FlatCodec.BuildMessage {
				FlatCodec.CreateItem(60407, nil, "ClientDestroyMethodAfterOps", {}, { Coins = 0 }),
			})
			local replicator = BaseReplicator.GetFromId(60407) :: any
			handle(FlatCodec.BuildMessage {
				FlatCodec.OpsItem(60407, { { Kind = "Set", Path = { "Coins" }, Value = 5 } } :: any),
			})
			expect(function()
				replicator:Destroy()
			end).fails()
			destroy(60407)
		end)

		test("fails consistently on repeated attempts", function()
			handle(FlatCodec.BuildMessage { FlatCodec.CreateItem(60408, nil, "ClientDestroyMethodTwice", {}, {}) })
			local replicator = BaseReplicator.GetFromId(60408) :: any
			expect(function()
				replicator:Destroy()
			end).fails()
			expect(function()
				replicator:Destroy()
			end).fails()
			destroy(60408)
		end)
	end)
end
