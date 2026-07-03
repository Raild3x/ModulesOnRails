--!strict
--[[
	Wire codec coverage for TableReplicator: the flat opcode item format
	(`FlatCodec`), the binary message framing (`MessageCodec`) including Phase 3
	in-band table dedup, and the per-frame op buffer (`OpBuffer`). Pure
	data-structure tests -- no `ServerReplicator` instances needed, except where
	table-dedup independence is proven through the real
	`ClientReplicator._HandleMessage` apply pipeline.
]]

return function(t: tiniest)
	local HttpService = game:GetService("HttpService")
	local FlatCodec = require("../Shared/Serialization/FlatCodec")
	local MessageCodec = require("../Shared/Serialization/MessageCodec")
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

		test("BuildMessage wraps items with the current version", function()
			local message = FlatCodec.BuildMessage {}
			expect(message.V).is(FlatCodec.Version)
			expect(#message.Items).is(0)
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

	describe("OpBuffer.PathKey", function()
		test("identical paths produce identical keys", function()
			expect(OpBuffer.PathKey { "a", "b" }).is(OpBuffer.PathKey { "a", "b" })
		end)

		test("string and number segments with the same tostring never collide", function()
			expect(OpBuffer.PathKey { 1 } == OpBuffer.PathKey { "1" }).is(false)
		end)

		test("paths that only differ by element grouping never collide", function()
			-- {"a","b"} vs {"a.b"} must not hash the same despite a naive
			-- separator-only join producing identical strings.
			expect(OpBuffer.PathKey { "a", "b" } == OpBuffer.PathKey { "a.b" }).is(false)
		end)

		test("different paths produce different keys", function()
			expect(OpBuffer.PathKey { "a" } == OpBuffer.PathKey { "b" }).is(false)
		end)

		test("empty path produces a stable, distinct key", function()
			expect(OpBuffer.PathKey {}).is(OpBuffer.PathKey {})
			expect(OpBuffer.PathKey {} == OpBuffer.PathKey { "a" }).is(false)
		end)
	end)

	describe("OpBuffer.PathRelation", function()
		test("identical paths are equal", function()
			expect(OpBuffer.PathRelation({ "a", "b" }, { "a", "b" })).is("equal")
		end)

		test("a strict prefix of b reports aPrefixB", function()
			expect(OpBuffer.PathRelation({ "a" }, { "a", "b" })).is("aPrefixB")
		end)

		test("b strict prefix of a reports bPrefixA", function()
			expect(OpBuffer.PathRelation({ "a", "b" }, { "a" })).is("bPrefixA")
		end)

		test("non-overlapping paths are disjoint", function()
			expect(OpBuffer.PathRelation({ "a" }, { "b" })).is("disjoint")
		end)

		test("siblings under a shared parent are disjoint, not prefixes", function()
			expect(OpBuffer.PathRelation({ "stats", "hp" }, { "stats", "mp" })).is("disjoint")
		end)

		test("empty path is a prefix of everything", function()
			expect(OpBuffer.PathRelation({}, { "a" })).is("aPrefixB")
			expect(OpBuffer.PathRelation({ "a" }, {})).is("bPrefixA")
		end)
	end)

	--------------------------------------------------------------------------------

	describe("MessageCodec (Phase 2 bit-packed framing + Phase 3 in-band table dedup)", function()
		local function roundTrip(items: { any }): any
			local buf, instances = MessageCodec.Encode(items)
			return MessageCodec.Decode(buf, instances)
		end

		test("version is preserved", function()
			local msg = roundTrip {}
			expect(msg.V).is(FlatCodec.Version)
		end)

		test("Create item round-trips Id/ParentId/Token/Tags/Data", function()
			local item = FlatCodec.CreateItem(5, 2, "PlayerData", { role = "admin" }, { Coins = 100 })
			local msg = roundTrip { item }
			expect(#msg.Items).is(1)
			local got = msg.Items[1] :: any
			expect(got.Op).is(FlatCodec.Op.Create)
			expect(got.Id).is(5)
			expect(got.ParentId).is(2)
			expect(got.Token).is("PlayerData")
			expect(got.Tags.role).is("admin")
			expect(got.Data.Coins).is(100)
		end)

		test("Create item with no parent uses the NoParent sentinel", function()
			local item = FlatCodec.CreateItem(1, nil, "T", {}, {})
			local msg = roundTrip { item }
			expect((msg.Items[1] :: any).ParentId).is(FlatCodec.NoParent)
		end)

		test("Destroy item round-trips Id", function()
			local item = FlatCodec.DestroyItem(9)
			local msg = roundTrip { item }
			local got = msg.Items[1] :: any
			expect(got.Op).is(FlatCodec.Op.Destroy)
			expect(got.Id).is(9)
		end)

		test("SetParent item round-trips Id/ParentId", function()
			local item = FlatCodec.SetParentItem(9, 3)
			local msg = roundTrip { item }
			local got = msg.Items[1] :: any
			expect(got.Op).is(FlatCodec.Op.SetParent)
			expect(got.Id).is(9)
			expect(got.ParentId).is(3)
		end)

		test("Ops item round-trips all six op kinds via FlatCodec.OpsItem/DecodeOps", function()
			local ops: any = {
				{ Kind = "Set", Path = { "a", "b" }, Value = 5 },
				{ Kind = "ArrayInsert", Path = { "arr" }, Index = 1, Value = "x" },
				{ Kind = "ArrayRemove", Path = { "arr" }, Index = 2 },
				{ Kind = "ArraySet", Path = { "arr" }, Index = 1, Value = "y" },
				{ Kind = "BatchBegin", Path = {} },
				{ Kind = "BatchEnd", Path = {} },
			}
			local item = FlatCodec.OpsItem(7, ops)
			local msg = roundTrip { item }
			local got = msg.Items[1] :: any
			expect(got.Op).is(FlatCodec.Op.Ops)
			expect(got.Id).is(7)
			local decoded = FlatCodec.DecodeOps(got)
			expect(#decoded).is(6)
			for i, op in decoded do
				expect(op.Kind).is(ops[i].Kind)
			end
			expect(decoded[1].Path[1]).is("a")
			expect(decoded[1].Path[2]).is("b")
			expect(decoded[1].Value).is(5)
			expect(decoded[2].Index).is(1)
			expect(decoded[2].Value).is("x")
			expect(decoded[3].Index).is(2)
			expect(decoded[4].Value).is("y")
		end)

		test("BatchBegin/BatchEnd are single-byte ops -- no path or value bytes", function()
			local ops: any = {
				{ Kind = "BatchBegin", Path = {} },
				{ Kind = "Set", Path = { "x" }, Value = 1 },
				{ Kind = "BatchEnd", Path = {} },
			}
			local msg = roundTrip { FlatCodec.OpsItem(1, ops) }
			local decoded = FlatCodec.DecodeOps(msg.Items[1] :: any)
			expect(decoded[1].Kind).is("BatchBegin")
			expect(decoded[2].Kind).is("Set")
			expect(decoded[3].Kind).is("BatchEnd")
		end)

		test("samePath flag: two consecutive ops on the same path both decode correctly", function()
			local ops: any = {
				{ Kind = "Set", Path = { "hp" }, Value = 10 },
				{ Kind = "Set", Path = { "hp" }, Value = 20 }, -- triggers samePath=1
			}
			local msg = roundTrip { FlatCodec.OpsItem(1, ops) }
			local decoded = FlatCodec.DecodeOps(msg.Items[1] :: any)
			expect(decoded[1].Value).is(10)
			expect(decoded[1].Path[1]).is("hp")
			expect(decoded[2].Value).is(20)
			expect(decoded[2].Path[1]).is("hp")
		end)

		test("path-prefix dedup: adjacent ops sharing a leading segment", function()
			local ops: any = {
				{ Kind = "Set", Path = { "stats", "hp" }, Value = 100 },
				{ Kind = "Set", Path = { "stats", "mp" }, Value = 50 }, -- shares "stats"
			}
			local msg = roundTrip { FlatCodec.OpsItem(1, ops) }
			local decoded = FlatCodec.DecodeOps(msg.Items[1] :: any)
			expect(decoded[1].Path[1]).is("stats")
			expect(decoded[1].Path[2]).is("hp")
			expect(decoded[1].Value).is(100)
			expect(decoded[2].Path[1]).is("stats")
			expect(decoded[2].Path[2]).is("mp")
			expect(decoded[2].Value).is(50)
		end)

		test("inline array index (1..14) is packed in the op header nibble", function()
			local ops: any = {
				{ Kind = "ArrayInsert", Path = { "items" }, Index = 3, Value = "Sword" },
				{ Kind = "ArrayRemove", Path = { "items" }, Index = 14 },
			}
			local msg = roundTrip { FlatCodec.OpsItem(1, ops) }
			local decoded = FlatCodec.DecodeOps(msg.Items[1] :: any)
			expect(decoded[1].Index).is(3)
			expect(decoded[1].Value).is("Sword")
			expect(decoded[2].Index).is(14)
		end)

		test("large array index (>=15) round-trips via sentinel + varint", function()
			local ops: any = {
				{ Kind = "ArrayRemove", Path = { "items" }, Index = 15 },
				{ Kind = "ArrayInsert", Path = { "items" }, Index = 300, Value = "x" },
			}
			local msg = roundTrip { FlatCodec.OpsItem(1, ops) }
			local decoded = FlatCodec.DecodeOps(msg.Items[1] :: any)
			expect(decoded[1].Index).is(15)
			expect(decoded[2].Index).is(300)
			expect(decoded[2].Value).is("x")
		end)

		test("op-count >62 uses sentinel + varint in the item header", function()
			local ops: any = {}
			for i = 1, 100 do
				ops[i] = { Kind = "Set", Path = { "x" }, Value = i }
			end
			local msg = roundTrip { FlatCodec.OpsItem(1, ops) }
			local decoded = FlatCodec.DecodeOps(msg.Items[1] :: any)
			expect(#decoded).is(100)
			expect(decoded[100].Value).is(100)
		end)

		test("multiple items in one message round-trip in order", function()
			local items = {
				FlatCodec.CreateItem(1, nil, "T", {}, { x = 1 }),
				FlatCodec.OpsItem(1, { { Kind = "Set", Path = { "x" }, Value = 2 } } :: any),
				FlatCodec.DestroyItem(1),
			}
			local msg = roundTrip(items)
			expect(#msg.Items).is(3)
			expect((msg.Items[1] :: any).Op).is(FlatCodec.Op.Create)
			expect((msg.Items[2] :: any).Op).is(FlatCodec.Op.Ops)
			expect((msg.Items[3] :: any).Op).is(FlatCodec.Op.Destroy)
		end)

		test("path elements of mixed types (string/number) round-trip", function()
			local ops: any = {
				{ Kind = "Set", Path = { "inv", 2, "id" }, Value = "A7" },
			}
			local msg = roundTrip { FlatCodec.OpsItem(1, ops) }
			local decoded = FlatCodec.DecodeOps(msg.Items[1] :: any)
			expect(decoded[1].Path[1]).is("inv")
			expect(decoded[1].Path[2]).is(2)
			expect(decoded[1].Path[3]).is("id")
			expect(decoded[1].Value).is("A7")
		end)

		test("BatchBegin/BatchEnd between data ops do not reset path-prefix dedup", function()
			local ops: any = {
				{ Kind = "Set", Path = { "stats", "hp" }, Value = 10 },
				{ Kind = "BatchBegin", Path = {} },
				{ Kind = "Set", Path = { "stats", "mp" }, Value = 5 }, -- still shares "stats"
				{ Kind = "BatchEnd", Path = {} },
			}
			local msg = roundTrip { FlatCodec.OpsItem(1, ops) }
			local decoded = FlatCodec.DecodeOps(msg.Items[1] :: any)
			expect(decoded[1].Path[2]).is("hp")
			expect(decoded[3].Path[1]).is("stats")
			expect(decoded[3].Path[2]).is("mp")
			expect(decoded[3].Value).is(5)
		end)

		-- Phase 3: in-band table dedup via BufferCodec identity interning

		test("shared table across two Create items decodes to independent copies", function()
			local shared = { hp = 100 }
			local items = {
				FlatCodec.CreateItem(1, nil, "A", {}, { B = shared }),
				FlatCodec.CreateItem(2, nil, "B", {}, { B = shared }),
			}
			local msg = roundTrip(items)
			local b1 = (msg.Items[1] :: any).Data.B
			local b2 = (msg.Items[2] :: any).Data.B
			expect(b1.hp).is(100)
			expect(b2.hp).is(100)
			expect(b1 == b2).is(false)
		end)

		test("shared table in Ops Values decodes to independent copies", function()
			local shared = { tag = "v" }
			local ops: any = {
				{ Kind = "Set", Path = { "a" }, Value = shared },
				{ Kind = "Set", Path = { "b" }, Value = shared },
			}
			local msg = roundTrip { FlatCodec.OpsItem(1, ops) }
			local decoded = FlatCodec.DecodeOps(msg.Items[1] :: any)
			expect(decoded[1].Value.tag).is("v")
			expect(decoded[2].Value.tag).is("v")
			expect(decoded[1].Value == decoded[2].Value).is(false)
		end)

		test("nested table dedup: sub-table C written directly then again inside containing table B", function()
			-- Op 1 sets A.B = C  (C is written in full, registered in tableRefs)
			-- Op 2 sets D = B    (B is written; when its .C field is reached, C is a back-ref)
			-- The second encoding of C must be cheaper than the first.
			local C = { Kind = "Weapon", Power = 42, Rarity = "Rare" }
			local B = { Name = "Container", C = C, Extra = true }

			local ops: any = {
				{ Kind = "Set", Path = { "A", "B" }, Value = C },
				{ Kind = "Set", Path = { "D" }, Value = B },
			}

			local optimizedBuf = (MessageCodec.Encode { FlatCodec.OpsItem(1, ops) })
			local optimizedBytes = buffer.len(optimizedBuf)

			local naiveBytes = 0
			for _, op in ops do
				local b = (MessageCodec.Encode { FlatCodec.OpsItem(1, { op }) })
				naiveBytes += buffer.len(b)
			end

			local rawBytes = #HttpService:JSONEncode(ops)
			local saved = naiveBytes - optimizedBytes
			print(
				string.format(
					"[MessageCodec] nested table dedup (C direct + C nested inside B): %d optimized / %d naive / %d raw — saved %d vs naive, %.0f%% of raw",
					optimizedBytes,
					naiveBytes,
					rawBytes,
					saved,
					optimizedBytes / rawBytes * 100
				)
			)

			expect(optimizedBytes < naiveBytes).is_true()

			local msg = MessageCodec.Decode(optimizedBuf, nil)
			local decoded = FlatCodec.DecodeOps(msg.Items[1] :: any)
			-- Op 1: A.B = C
			expect(decoded[1].Path[1]).is("A")
			expect(decoded[1].Path[2]).is("B")
			expect(decoded[1].Value.Kind).is("Weapon")
			expect(decoded[1].Value.Power).is(42)
			-- Op 2: D = B (which carries C as a sub-table)
			expect(decoded[2].Path[1]).is("D")
			expect(decoded[2].Value.Name).is("Container")
			expect(decoded[2].Value.C.Kind).is("Weapon")
			expect(decoded[2].Value.C.Power).is(42)
			-- Each decoded occurrence of C must be an independent copy
			expect(decoded[1].Value == decoded[2].Value.C).is(false)
		end)

		test("cyclic shared table: both items get independent copies with cycle preserved", function()
			local shared = {} :: any
			shared.self = shared
			local items = {
				FlatCodec.CreateItem(1, nil, "A", {}, { B = shared }),
				FlatCodec.CreateItem(2, nil, "B", {}, { B = shared }),
			}
			local msg = roundTrip(items)
			local b1 = (msg.Items[1] :: any).Data.B
			local b2 = (msg.Items[2] :: any).Data.B
			-- Cycle preserved within each independent copy
			expect(b1.self).is(b1)
			expect(b2.self).is(b2)
			expect(b1 == b2).is(false)
		end)

		-- Compression improvement measurements.
		-- Each test encodes the same data two ways:
		--   • optimized  — all ops/items in one Encode call (samePath, prefix dedup, cross-item interning)
		--   • naive      — each op/item encoded separately, summed (none of the above)
		-- The delta is the empirical saving from those three features combined.

		test("path-prefix dedup: 10 ops sharing a two-segment parent path", function()
			local ops: any = {
				{ Kind = "Set", Path = { "Character", "Stats", "Hp" }, Value = 100 },
				{ Kind = "Set", Path = { "Character", "Stats", "Mp" }, Value = 80 },
				{ Kind = "Set", Path = { "Character", "Stats", "Atk" }, Value = 15 },
				{ Kind = "Set", Path = { "Character", "Stats", "Def" }, Value = 10 },
				{ Kind = "Set", Path = { "Character", "Stats", "Spd" }, Value = 20 },
				{ Kind = "Set", Path = { "Character", "Stats", "Luk" }, Value = 5 },
				{ Kind = "Set", Path = { "Character", "Stats", "Crt" }, Value = 12 },
				{ Kind = "Set", Path = { "Character", "Stats", "Eva" }, Value = 8 },
				{ Kind = "Set", Path = { "Character", "Stats", "Acc" }, Value = 95 },
				{ Kind = "Set", Path = { "Character", "Stats", "Res" }, Value = 30 },
			}

			local optimizedBuf = (MessageCodec.Encode { FlatCodec.OpsItem(1, ops) })
			local optimizedBytes = buffer.len(optimizedBuf)

			local naiveBytes = 0
			for _, op in ops do
				local b = (MessageCodec.Encode { FlatCodec.OpsItem(1, { op }) })
				naiveBytes += buffer.len(b)
			end

			local rawBytes = #HttpService:JSONEncode(ops)
			local saved = naiveBytes - optimizedBytes
			print(
				string.format(
					"[MessageCodec] path-prefix dedup (%d ops under Character.Stats.*): %d optimized / %d naive / %d raw — saved %d vs naive, %.0f%% of raw",
					#ops,
					optimizedBytes,
					naiveBytes,
					rawBytes,
					saved,
					optimizedBytes / rawBytes * 100
				)
			)

			expect(optimizedBytes < naiveBytes).is_true()
			local msg = MessageCodec.Decode(optimizedBuf, nil)
			local decoded = FlatCodec.DecodeOps(msg.Items[1] :: any)
			expect(#decoded).is(10)
			expect(decoded[1].Path[1]).is("Character")
			expect(decoded[1].Path[2]).is("Stats")
			expect(decoded[5].Path[3]).is("Spd")
			expect(decoded[5].Value).is(20)
		end)

		test("samePath compaction: 20 consecutive updates to the same leaf path", function()
			local ops: any = {}
			for i = 1, 20 do
				ops[i] = { Kind = "Set", Path = { "Inventory", "SelectedSlot" }, Value = i }
			end

			local optimizedBuf = (MessageCodec.Encode { FlatCodec.OpsItem(1, ops) })
			local optimizedBytes = buffer.len(optimizedBuf)

			local naiveBytes = 0
			for _, op in ops do
				local b = (MessageCodec.Encode { FlatCodec.OpsItem(1, { op }) })
				naiveBytes += buffer.len(b)
			end

			local rawBytes = #HttpService:JSONEncode(ops)
			local saved = naiveBytes - optimizedBytes
			print(
				string.format(
					"[MessageCodec] samePath compaction (20 updates to Inventory.SelectedSlot): %d optimized / %d naive / %d raw — saved %d vs naive, %.0f%% of raw",
					optimizedBytes,
					naiveBytes,
					rawBytes,
					saved,
					optimizedBytes / rawBytes * 100
				)
			)

			expect(optimizedBytes < naiveBytes).is_true()
			local msg = MessageCodec.Decode(optimizedBuf, nil)
			local decoded = FlatCodec.DecodeOps(msg.Items[1] :: any)
			expect(#decoded).is(20)
			expect(decoded[1].Path[1]).is("Inventory")
			expect(decoded[20].Value).is(20)
			expect(decoded[20].Path[2]).is("SelectedSlot")
		end)

		test("cross-item string interning: 5 Create items with identical schema key names", function()
			local items: any = {}
			for i = 1, 5 do
				items[i] = FlatCodec.CreateItem(100 + i, nil, "PlayerData", { PlayerId = i }, {
					Coins = i * 50,
					Level = i,
					Inventory = { "Sword", "Shield" },
					Stats = { Hp = 100, Mp = 50, Atk = 10 + i },
				})
			end

			local optimizedBuf, optimizedInst = MessageCodec.Encode(items)
			local optimizedBytes = buffer.len(optimizedBuf)

			local naiveBytes = 0
			for _, item in items do
				local b = (MessageCodec.Encode { item })
				naiveBytes += buffer.len(b)
			end

			local rawBytes = #HttpService:JSONEncode(items)
			local saved = naiveBytes - optimizedBytes
			print(
				string.format(
					"[MessageCodec] cross-item string interning (5 Create items, shared schema keys): %d optimized / %d naive / %d raw — saved %d vs naive, %.0f%% of raw",
					optimizedBytes,
					naiveBytes,
					rawBytes,
					saved,
					optimizedBytes / rawBytes * 100
				)
			)

			expect(optimizedBytes < naiveBytes).is_true()
			local msg = MessageCodec.Decode(optimizedBuf, optimizedInst)
			expect(#msg.Items).is(5)
			expect((msg.Items[3] :: any).Data.Coins).is(150)
			expect((msg.Items[3] :: any).Data.Stats.Hp).is(100)
			expect((msg.Items[5] :: any).Data.Inventory[2]).is("Shield")
		end)

		test(
			"combined workload: realistic mixed Create + multi-op Ops message with deep paths and mixed types",
			function()
				-- One Create bootstrapping a player character, followed by an ops frame
				-- touching many different nested paths with mixed value types.
				local createItem = FlatCodec.CreateItem(200, nil, "Character", {}, {
					Name = "Hero",
					Level = 1,
					Position = { X = 10.5, Y = 0.0, Z = 22.3 },
					Stats = { Hp = 100, Mp = 50, Atk = 12, Def = 8 },
					Inventory = { "IronSword", "WoodShield", "HealthPotion" },
				})
				-- Keep a reference to the original BufferedOp list for the per-op
				-- naive measurement; opsItem.Ops holds already-converted WireOpEntry
				-- (numeric Kind), which cannot be fed back through FlatCodec.OpsItem.
				local rawOps: any = {
					{ Kind = "Set", Path = { "Stats", "Hp" }, Value = 85 },
					{ Kind = "Set", Path = { "Stats", "Mp" }, Value = 45 },
					{ Kind = "Set", Path = { "Level" }, Value = 2 },
					{ Kind = "ArrayInsert", Path = { "Inventory" }, Index = 4, Value = "MagicStaff" },
					{ Kind = "ArrayRemove", Path = { "Inventory" }, Index = 2 },
					{ Kind = "Set", Path = { "Stats", "Atk" }, Value = 15 },
					{ Kind = "BatchBegin", Path = {} },
					{ Kind = "Set", Path = { "Stats", "Def" }, Value = 10 },
					{ Kind = "Set", Path = { "Stats", "Hp" }, Value = 90 },
					{ Kind = "BatchEnd", Path = {} },
				}
				local opsItem = FlatCodec.OpsItem(200, rawOps)
				local items = { createItem, opsItem }

				local optimizedBuf, optimizedInst = MessageCodec.Encode(items)
				local optimizedBytes = buffer.len(optimizedBuf)

				-- Cross-item naive: each item encoded separately (loses cross-item interning).
				local naiveBytes = 0
				for _, item in items do
					local b = (MessageCodec.Encode { item })
					naiveBytes += buffer.len(b)
				end
				-- Per-op naive: each op in its own OpsItem (loses samePath + prefix dedup too).
				-- Uses rawOps (string Kind) so FlatCodec.OpsItem can re-convert correctly.
				local naiveBytesPerOp = naiveBytes - buffer.len((MessageCodec.Encode { opsItem }))
				local opsOnlyNaive = 0
				for _, op in rawOps do
					local b = (MessageCodec.Encode { FlatCodec.OpsItem(200, { op }) })
					opsOnlyNaive += buffer.len(b)
				end
				naiveBytesPerOp += opsOnlyNaive

				local rawBytes = #HttpService:JSONEncode { createItem, rawOps }
				print(
					string.format(
						"[MessageCodec] combined workload (1 Create + 10 ops): %d optimized / %d naive (per-item) / %d naive (per-op) / %d raw — %.0f%% of raw",
						optimizedBytes,
						naiveBytes,
						naiveBytesPerOp,
						rawBytes,
						optimizedBytes / rawBytes * 100
					)
				)

				-- Correctness assertions
				local msg = MessageCodec.Decode(optimizedBuf, optimizedInst)
				expect(#msg.Items).is(2)
				local gotCreate = msg.Items[1] :: any
				expect(gotCreate.Op).is(FlatCodec.Op.Create)
				expect(gotCreate.Data.Name).is("Hero")
				expect(gotCreate.Data.Stats.Atk).is(12)
				expect(#gotCreate.Data.Inventory).is(3)
				local decoded = FlatCodec.DecodeOps(msg.Items[2] :: any)
				expect(#decoded).is(10)
				expect(decoded[1].Path[1]).is("Stats")
				expect(decoded[1].Path[2]).is("Hp")
				expect(decoded[1].Value).is(85)
				expect(decoded[4].Kind).is("ArrayInsert")
				expect(decoded[4].Index).is(4)
				expect(decoded[4].Value).is("MagicStaff")
				expect(decoded[7].Kind).is("BatchBegin")
				expect(decoded[10].Kind).is("BatchEnd")
			end
		)

		test("Encode rejects an unknown item opcode", function()
			expect(function()
				MessageCodec.Encode({ { Op = 99, Id = 1 } } :: any)
			end).fails()
		end)

		test("an array op without an Index round-trips with Index = nil", function()
			-- The wire format reserves index-nibble 0 for "no index"; nothing in
			-- the current server emits it, but the decoder must honor it.
			local ops: any = {
				{ Kind = "ArrayRemove", Path = { "arr" } },
			}
			local msg = roundTrip { FlatCodec.OpsItem(1, ops) }
			local decoded = FlatCodec.DecodeOps(msg.Items[1] :: any)
			expect(decoded[1].Kind).is("ArrayRemove")
			expect(decoded[1].Index).is(nil)
			expect(decoded[1].Path[1]).is("arr")
		end)

		test("shared snapshot table arrives as independent copies on the client via full pipeline", function()
			local shared = { hp = 100 }
			local items = {
				FlatCodec.CreateItem(801, nil, "DedupeA", {}, { B = shared }),
				FlatCodec.CreateItem(802, nil, "DedupeB", {}, { B = shared }),
			}
			local buf, instances = MessageCodec.Encode(items);
			(ClientReplicator :: any)._HandleMessage(MessageCodec.Decode(buf, instances))

			local a = BaseReplicator.GetFromId(801) :: any
			local b = BaseReplicator.GetFromId(802) :: any
			expect(a.Manager.Raw.B.hp).is(100)
			expect(b.Manager.Raw.B.hp).is(100)
			expect(a.Manager.Raw.B == b.Manager.Raw.B).is(false)
			-- Mutating one copy leaves the other untouched
			a.Manager.Raw.B.hp = 5
			expect(b.Manager.Raw.B.hp).is(100)
;
			(ClientReplicator :: any)._HandleMessage(FlatCodec.BuildMessage { FlatCodec.DestroyItem(801) });
			(ClientReplicator :: any)._HandleMessage(FlatCodec.BuildMessage { FlatCodec.DestroyItem(802) })
		end)
	end)

	--------------------------------------------------------------------------------

	describe("OpApplier", function()
		local TableManagerModule = require("../Shared/Types").TableManager
		local OpApplier = require("../Client/OpApplier")

		test("applies every known op kind through one outer batch", function()
			local manager = TableManagerModule.new({ hp = 1, arr = { "a", "c" } })
			OpApplier.Apply(manager, {
				{ Kind = "BatchBegin", Path = {} },
				{ Kind = "Set", Path = { "hp" }, Value = 50 },
				{ Kind = "ArrayInsert", Path = { "arr" }, Index = 2, Value = "b" },
				{ Kind = "ArraySet", Path = { "arr" }, Index = 3, Value = "C" },
				{ Kind = "ArrayRemove", Path = { "arr" }, Index = 1 },
				{ Kind = "BatchEnd", Path = {} },
			} :: any)
			expect(manager.Raw.hp).is(50)
			expect(manager.Raw.arr[1]).is("b")
			expect(manager.Raw.arr[2]).is("C")
			expect(#manager.Raw.arr).is(2)
		end)

		test("an unknown op kind is skipped without aborting the batch", function()
			local manager = TableManagerModule.new({ hp = 1 })
			OpApplier.Apply(manager, {
				{ Kind = "SomethingNew", Path = { "hp" }, Value = 999 },
				{ Kind = "Set", Path = { "hp" }, Value = 2 },
			} :: any)
			expect(manager.Raw.hp).is(2)
		end)
	end)

	--------------------------------------------------------------------------------

	describe("ClientReplicator._HandleMessage guard paths", function()
		test("an item with an unknown Op is skipped without error", function()
			expect(function()
				(ClientReplicator :: any)._HandleMessage(FlatCodec.BuildMessage { { Op = 99, Id = 1 } :: any })
			end).never_fails()
		end)

		test("the Server proxy is read-only", function()
			(ClientReplicator :: any)._HandleMessage(
				FlatCodec.BuildMessage { FlatCodec.CreateItem(60031, nil, "ServerProxyReadOnly", {}, {}) }
			)
			local mirrored = BaseReplicator.GetFromId(60031) :: any
			expect(function()
				mirrored.Server.Anything = 5
			end).fails();
			(ClientReplicator :: any)._HandleMessage(FlatCodec.BuildMessage { FlatCodec.DestroyItem(60031) })
		end)

		test("a Signal op with a non-table payload for an untouched remote is dropped safely", function()
			(ClientReplicator :: any)._HandleMessage(
				FlatCodec.BuildMessage { FlatCodec.CreateItem(60021, nil, "SignalGuardNonTable", {}, {}) }
			)
			expect(function()
				(ClientReplicator :: any)._HandleMessage(FlatCodec.BuildMessage {
					FlatCodec.OpsItem(60021, { { Kind = "Signal", Path = { "NeverAccessed" }, Value = 7 } } :: any),
				})
			end).never_fails();
			(ClientReplicator :: any)._HandleMessage(FlatCodec.BuildMessage { FlatCodec.DestroyItem(60021) })
		end)

		test("a Signal op aimed at a replicator with no Server proxy is dropped safely", function()
			-- Server-side replicators live in the same realm during specs but have
			-- no `.Server` proxy; a stray Signal op for one must not crash.
			local ServerReplicator = require("../Server/ServerReplicator")
			local SpecUtils = require("./Helpers/SpecUtils")
			local replicator = ServerReplicator.new({
				Namespace = SpecUtils.uniqueToken("SignalGuardNoProxy"),
				Data = {},
				ReplicationTargets = {},
			})
			expect(function()
				(ClientReplicator :: any)._HandleMessage(FlatCodec.BuildMessage {
					FlatCodec.OpsItem(replicator.Id, { { Kind = "Signal", Path = { "X" }, Value = { 1 } } } :: any),
				})
			end).never_fails()
			replicator:Destroy()
		end)
	end)
end
