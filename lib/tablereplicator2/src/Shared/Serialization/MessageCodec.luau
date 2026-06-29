--!strict
--[=[
	@ignore
	@class MessageCodec

	Phase 1 of the byte-level wire rewrite: encodes a `{ WireItem }` list (plus
	an optional `RefCodec` pool) straight into a `buffer` via `BufferCodec`,
	instead of handing Roblox a plain Luau table to serialize. Item/op framing
	here is still one tag byte per field -- bit-level packing of the envelope
	(opcode/kind/path-prefix) is a later phase; this phase's win is removing
	repeated structural string keys and the per-frame table garbage.

	A single module-level writer is reused (reset per call) since `Encode`
	never yields -- safe under Luau's cooperative scheduling.
]=]

const BufferCodec = require("./BufferCodec")
const FlatCodec = require("./FlatCodec")
const Types = require("../Types")

type Reader = BufferCodec.Reader
type WireItem = Types.WireItem
type WireMessage = Types.WireMessage
type WireCreateItem = Types.WireCreateItem
type WireDestroyItem = Types.WireDestroyItem
type WireSetParentItem = Types.WireSetParentItem
type WireOpsItem = Types.WireOpsItem
type WireOpEntry = Types.WireOpEntry
type RefPool = { [number]: any }

const MessageCodec = {}

const writer = BufferCodec.newWriter()

const function writeItem(item: WireItem)
	BufferCodec.writeByte(writer, item.Op)

	if item.Op == FlatCodec.Op.Create then
		const create = item :: WireCreateItem
		BufferCodec.writeValue(writer, create.Id)
		BufferCodec.writeValue(writer, create.ParentId)
		BufferCodec.writeValue(writer, create.Token)
		BufferCodec.writeValue(writer, create.Tags)
		BufferCodec.writeValue(writer, create.Data)
	elseif item.Op == FlatCodec.Op.Destroy then
		BufferCodec.writeValue(writer, (item :: WireDestroyItem).Id)
	elseif item.Op == FlatCodec.Op.SetParent then
		const setParent = item :: WireSetParentItem
		BufferCodec.writeValue(writer, setParent.Id)
		BufferCodec.writeValue(writer, setParent.ParentId)
	elseif item.Op == FlatCodec.Op.Ops then
		const opsItem = item :: WireOpsItem
		BufferCodec.writeValue(writer, opsItem.Id)
		BufferCodec.writeVarint(writer, #opsItem.Ops)
		for _, entry in opsItem.Ops do
			BufferCodec.writeByte(writer, entry.Kind)
			BufferCodec.writeValue(writer, entry.Path)
			BufferCodec.writeValue(writer, entry.Value)
			BufferCodec.writeValue(writer, entry.Index)
		end
	else
		error(`[TableReplicator] MessageCodec: unknown item opcode {item.Op}`)
	end
end

--[=[
	Encodes `items` (already run through `RefCodec.Encode`, if applicable)
	plus the resulting `refs` pool into a `buffer`. Returns the buffer and the
	deduplicated `Instance` side-list (or `nil` when the message carries
	none), mirroring `BufferCodec.export`.
]=]
function MessageCodec.Encode(items: { WireItem }, refs: RefPool?): (buffer, { Instance }?)
	BufferCodec.resetWriter(writer)
	BufferCodec.writeByte(writer, FlatCodec.Version)
	BufferCodec.writeVarint(writer, #items)
	for _, item in items do
		writeItem(item)
	end
	BufferCodec.writeValue(writer, refs)
	return BufferCodec.export(writer)
end

const function readItem(reader: Reader): WireItem
	const op = BufferCodec.readByte(reader)

	if op == FlatCodec.Op.Create then
		return {
			Op = op,
			Id = BufferCodec.readValue(reader),
			ParentId = BufferCodec.readValue(reader),
			Token = BufferCodec.readValue(reader),
			Tags = BufferCodec.readValue(reader),
			Data = BufferCodec.readValue(reader),
		} :: WireCreateItem
	elseif op == FlatCodec.Op.Destroy then
		return { Op = op, Id = BufferCodec.readValue(reader) } :: WireDestroyItem
	elseif op == FlatCodec.Op.SetParent then
		return {
			Op = op,
			Id = BufferCodec.readValue(reader),
			ParentId = BufferCodec.readValue(reader),
		} :: WireSetParentItem
	elseif op == FlatCodec.Op.Ops then
		const id = BufferCodec.readValue(reader)
		const opCount = BufferCodec.readVarint(reader)
		const ops = table.create(opCount) :: { WireOpEntry }
		for i = 1, opCount do
			ops[i] = {
				Kind = BufferCodec.readByte(reader),
				Path = BufferCodec.readValue(reader),
				Value = BufferCodec.readValue(reader),
				Index = BufferCodec.readValue(reader),
			}
		end
		return { Op = op, Id = id, Ops = ops } :: WireOpsItem
	end

	error(`[TableReplicator] MessageCodec: unknown item opcode {op}`)
end

--[=[
	Decodes a `buffer` produced by `Encode` back into a `WireMessage`,
	resolving any `Instance` references against `instances` (the side-list
	`Encode` returned alongside the buffer).
]=]
function MessageCodec.Decode(buf: buffer, instances: { Instance }?): WireMessage
	const reader = BufferCodec.newReader(buf, instances)
	const version = BufferCodec.readByte(reader)
	const itemCount = BufferCodec.readVarint(reader)
	const items = table.create(itemCount) :: { WireItem }
	for i = 1, itemCount do
		items[i] = readItem(reader)
	end
	const refs = BufferCodec.readValue(reader) :: RefPool?
	return { V = version, Items = items, Refs = refs }
end

return MessageCodec
