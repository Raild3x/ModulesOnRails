--!strict
--[[
	Wire codec coverage for TableReplicator2: the flat opcode item format
	(`FlatCodec`), the Model V table-dedup layer (`RefCodec`), and the
	per-frame op buffer (`OpBuffer`). Pure data-structure tests -- no
	`ServerReplicator`/`ClientReplicator` instances needed, except where
	`RefCodec`'s client-side resolution is proven through the real
	`ClientReplicator._HandleMessage` apply pipeline.
]]

return function(t: tiniest)
	local FlatCodec = require("../Shared/Serialization/FlatCodec")
	local RefCodec = require("../Shared/Serialization/RefCodec")
	local OpBuffer = require("../Shared/OpBuffer")
	local BaseReplicator = require("../Shared/BaseReplicator")
	local ClientReplicator = require("../Client/ClientReplicator")

	local describe = t.describe
	local test = t.test
	local expect = t.expect

	--------------------------------------------------------------------------------

	describe("FlatCodec", function()
		test("CreateItem carries Id/ParentId/Token/Tags/Data", function()
			local create = FlatCodec.CreateItem(5, 2, "Tok", { a = 1 }, { b = 2 })
			expect(create.Op).is(FlatCodec.Op.Create)
			expect(create.Id).is(5)
			expect(create.ParentId).is(2)
			expect(create.Token).is("Tok")
			expect((create.Tags :: any).a).is(1)
			expect((create.Data :: any).b).is(2)
		end)

		test("CreateItem with no parent uses the NoParent sentinel", function()
			local createNoParent = FlatCodec.CreateItem(5, nil, "Tok", {}, {})
			expect(createNoParent.ParentId).is(FlatCodec.NoParent)
		end)

		test("DestroyItem carries only Op/Id", function()
			local destroy = FlatCodec.DestroyItem(9)
			expect(destroy.Op).is(FlatCodec.Op.Destroy)
			expect(destroy.Id).is(9)
		end)

		test("SetParentItem carries Id/ParentId", function()
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

		test("BuildMessage wraps items with the current version and no Refs when omitted", function()
			local message = FlatCodec.BuildMessage({})
			expect(message.V).is(FlatCodec.Version)
			expect(#message.Items).is(0)
			expect(message.Refs).is(nil)
		end)

		test("BuildMessage carries through an explicit Refs pool", function()
			local refs = { [1] = { hp = 100 } }
			local message = FlatCodec.BuildMessage({ FlatCodec.DestroyItem(1) }, refs :: any)
			expect(message.Refs).is(refs)
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

		test("a table referenced only once is left untouched even if nested deeply", function()
			local items = {
				FlatCodec.CreateItem(1, nil, "Tok", {}, { Outer = { Inner = { Value = 1 } } }),
			}
			local encoded, refs = RefCodec.Encode(items :: any)
			expect(refs).is(nil)
			expect((encoded[1] :: any).Data.Outer.Inner.Value).is(1)
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

		test("a table shared three-plus times still pools to exactly one Refs entry", function()
			local shared = { tag = "shared" }
			local items = {
				FlatCodec.CreateItem(1, nil, "Tok", {}, { B = shared }),
				FlatCodec.CreateItem(2, nil, "Tok", {}, { B = shared }),
				FlatCodec.CreateItem(3, nil, "Tok", {}, { B = shared }),
			}
			local encoded, refs = RefCodec.Encode(items :: any)
			expect(refs).never_is(nil)
			local count = 0
			for _ in refs :: any do
				count += 1
			end
			expect(count).is(1)
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
end
