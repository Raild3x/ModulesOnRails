--!strict
--[=[
	@ignore
	@class MessageCodec

	Phase 2 wire framing: compile-time bit-level packing of the item and op
	envelopes, plus path-prefix dedup across adjacent ops in an Ops item.

	**Item header byte** — bits 7-6 = wire opcode (Create=0, Destroy=1,
	SetParent=2, Ops=3); bits 5-0 = payload (inline op-count for Ops,
	OPS_COUNT_SENTINEL(63) when count > 62, zero otherwise).

	**Op header byte** — bits 7-4 = idx nibble (inline 1-based array index for
	array kinds, IDX_SENTINEL(15) when index > 14, zero for non-array); bit 3 =
	samePath flag (path is identical to the previous op's, no path bytes follow);
	bits 2-0 = kind (Set=1 … BatchEnd=6 per FlatCodec.Kind).

	**Path block** (when samePath=0) — varint sharedPrefixLen, varint suffixLen,
	then each suffix element via BufferCodec.writeValue. BufferCodec string
	interning applies to path elements, so a repeated key costs 2 bytes.

	All item field values (Data, Tags, op Values) still go through
	BufferCodec.writeValue, so the full value type set is preserved.

	A single module-level writer is reused (reset per Encode call) — safe
	because Encode never yields under Luau's cooperative scheduler.
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

-- Cycle-aware deep copy. Produces a fresh independent table graph from `value`,
-- preserving aliasing and cycles within a single top-level call via `memo`.
-- Non-table values are returned as-is. Called per Create Data and per op Value
-- so that two items sharing a table identity get independent copies on decode.
local function deepCopy(value: any, memo: { [any]: any }?): any
	if type(value) ~= "table" then return value end
	local m: { [any]: any } = memo or {}
	local existing = m[value]
	if existing ~= nil then return existing end
	local copy: { [any]: any } = {}
	m[value] = copy
	for k, v in value :: { [any]: any } do
		copy[k] = deepCopy(v, m)
	end
	return copy
end

const MessageCodec = {}

-- Item header bit layout: bits 7-6 = wire opcode, bits 5-0 = payload.
-- Payload for Ops = inline op-count 0..62; OPS_COUNT_SENTINEL means a varint
-- count follows the header. For other opcodes payload is always 0.
local ITEM_HDR_CREATE    = 0x00 -- wire opcode 0b00
local ITEM_HDR_DESTROY   = 0x40 -- wire opcode 0b01
local ITEM_HDR_SETPARENT = 0x80 -- wire opcode 0b10
local ITEM_HDR_OPS_BASE  = 0xC0 -- wire opcode 0b11 (low 6 bits = op-count or sentinel)

local WIRE_OP_CREATE    = 0
local WIRE_OP_DESTROY   = 1
local WIRE_OP_SETPARENT = 2
local WIRE_OP_OPS       = 3

local OPS_INLINE_MAX     = 62
local OPS_COUNT_SENTINEL = 63

-- Op header bit layout: bits 7-4 = idx nibble, bit 3 = samePath, bits 2-0 = kind.
-- For array kinds (ArrayInsert/ArrayRemove/ArraySet) the idx nibble holds the
-- 1-based array index when 1..IDX_INLINE_MAX; IDX_SENTINEL means a varint index
-- follows the header. Non-array kinds always write idx nibble = 0.
local IDX_INLINE_MAX = 14
local IDX_SENTINEL   = 15

-- Maps wire-opcode bits (bits 7-6 of item header) → FlatCodec.Op values so
-- decoded WireItems carry the same .Op numbers callers already expect.
local WireOpToOp = table.freeze({
	[WIRE_OP_CREATE]    = FlatCodec.Op.Create,
	[WIRE_OP_DESTROY]   = FlatCodec.Op.Destroy,
	[WIRE_OP_SETPARENT] = FlatCodec.Op.SetParent,
	[WIRE_OP_OPS]       = FlatCodec.Op.Ops,
})

local Kind = FlatCodec.Kind

const writer = BufferCodec.newWriter()

local function pathsEqual(a: { any }, b: { any }): boolean
	local len = #a
	if len ~= #b then return false end
	for i = 1, len do
		if a[i] ~= b[i] then return false end
	end
	return true
end

-- Writes a path delta: varint(sharedPrefixLen) + varint(suffixLen) + each suffix
-- element. BufferCodec string interning applies to elements that repeat across ops.
local function writePath(path: { any }, prevPath: { any })
	local sharedLen = 0
	local minLen = math.min(#path, #prevPath)
	for i = 1, minLen do
		if path[i] ~= prevPath[i] then break end
		sharedLen = i
	end
	BufferCodec.writeVarint(writer, sharedLen)
	BufferCodec.writeVarint(writer, #path - sharedLen)
	for i = sharedLen + 1, #path do
		BufferCodec.writeValue(writer, path[i])
	end
end

-- Encodes one op entry and returns the new prevPath for the next op.
local function writeOpEntry(entry: WireOpEntry, prevPath: { any }): { any }
	local kind = entry.Kind
	local isBatch = kind == Kind.BatchBegin or kind == Kind.BatchEnd
	if isBatch then
		BufferCodec.writeByte(writer, kind) -- bits 0-2 only; bits 3-7 = 0
		return prevPath
	end

	local isArray = kind == Kind.ArrayInsert or kind == Kind.ArrayRemove or kind == Kind.ArraySet
	local hasValue = kind == Kind.Set or kind == Kind.ArrayInsert or kind == Kind.ArraySet
	local path = (entry.Path or {}) :: { any }
	local index = entry.Index
	local samePath = #path > 0 and #prevPath > 0 and pathsEqual(path, prevPath)
	local idxNibble = 0
	if isArray and index ~= nil then
		idxNibble = if index <= IDX_INLINE_MAX then index else IDX_SENTINEL
	end

	BufferCodec.writeByte(writer, kind + (if samePath then 0x08 else 0) + idxNibble * 0x10)

	if isArray and idxNibble == IDX_SENTINEL then
		BufferCodec.writeVarint(writer, index :: number)
	end
	if not samePath then
		writePath(path, prevPath)
	end
	if hasValue then
		BufferCodec.writeValue(writer, entry.Value)
	end

	return path
end

local function writeItem(item: WireItem)
	if item.Op == FlatCodec.Op.Create then
		local create = item :: WireCreateItem
		BufferCodec.writeByte(writer, ITEM_HDR_CREATE)
		BufferCodec.writeValue(writer, create.Id)
		BufferCodec.writeValue(writer, create.ParentId)
		BufferCodec.writeValue(writer, create.Token)
		BufferCodec.writeValue(writer, create.Tags)
		BufferCodec.writeValue(writer, create.Data)
	elseif item.Op == FlatCodec.Op.Destroy then
		BufferCodec.writeByte(writer, ITEM_HDR_DESTROY)
		BufferCodec.writeValue(writer, (item :: WireDestroyItem).Id)
	elseif item.Op == FlatCodec.Op.SetParent then
		local setParent = item :: WireSetParentItem
		BufferCodec.writeByte(writer, ITEM_HDR_SETPARENT)
		BufferCodec.writeValue(writer, setParent.Id)
		BufferCodec.writeValue(writer, setParent.ParentId)
	elseif item.Op == FlatCodec.Op.Ops then
		local opsItem = item :: WireOpsItem
		local opCount = #opsItem.Ops
		local countField = if opCount <= OPS_INLINE_MAX then opCount else OPS_COUNT_SENTINEL
		BufferCodec.writeByte(writer, ITEM_HDR_OPS_BASE + countField)
		if opCount > OPS_INLINE_MAX then
			BufferCodec.writeVarint(writer, opCount)
		end
		BufferCodec.writeValue(writer, opsItem.Id)
		local prevPath: { any } = {}
		for _, entry in opsItem.Ops do
			prevPath = writeOpEntry(entry, prevPath)
		end
	else
		error(`[TableReplicator] MessageCodec: unknown item opcode {item.Op}`)
	end
end

-- Reconstructs a path from a delta: reads sharedPrefixLen prefix elements from
-- prevPath, then reads suffixLen new elements from the buffer.
local function readPath(reader: Reader, prevPath: { any }): { any }
	local sharedLen = BufferCodec.readVarint(reader)
	local suffixLen = BufferCodec.readVarint(reader)
	local path = table.create(sharedLen + suffixLen) :: { any }
	for i = 1, sharedLen do
		path[i] = prevPath[i]
	end
	for i = sharedLen + 1, sharedLen + suffixLen do
		path[i] = BufferCodec.readValue(reader)
	end
	return path
end

-- Decodes one op entry and returns both the entry and the new prevPath.
local function readOpEntry(reader: Reader, prevPath: { any }): (WireOpEntry, { any })
	local header = BufferCodec.readByte(reader)
	local kind = header % 0x08
	local samePath = (header // 0x08) % 0x02 == 1
	local idxNibble = header // 0x10

	local isBatch = kind == Kind.BatchBegin or kind == Kind.BatchEnd
	if isBatch then
		return { Kind = kind, Path = nil, Value = nil, Index = nil }, prevPath
	end

	local isArray = kind == Kind.ArrayInsert or kind == Kind.ArrayRemove or kind == Kind.ArraySet
	local hasValue = kind == Kind.Set or kind == Kind.ArrayInsert or kind == Kind.ArraySet
	local index: number? = nil
	if isArray then
		if idxNibble == IDX_SENTINEL then
			index = BufferCodec.readVarint(reader)
		elseif idxNibble > 0 then
			index = idxNibble
		end
	end

	local path: { any } = if samePath then prevPath else readPath(reader, prevPath)
	local value: any = if hasValue then deepCopy(BufferCodec.readValue(reader)) else nil

	return { Kind = kind, Path = path, Value = value, Index = index }, path
end

local function readItem(reader: Reader): WireItem
	local headerByte = BufferCodec.readByte(reader)
	local wireOp = headerByte // 0x40
	local payload = headerByte % 0x40
	local flatOp = WireOpToOp[wireOp]

	if wireOp == WIRE_OP_CREATE then
		return {
			Op = flatOp,
			Id = BufferCodec.readValue(reader),
			ParentId = BufferCodec.readValue(reader),
			Token = BufferCodec.readValue(reader),
			Tags = deepCopy(BufferCodec.readValue(reader)),
			Data = deepCopy(BufferCodec.readValue(reader)),
		} :: WireCreateItem
	elseif wireOp == WIRE_OP_DESTROY then
		return { Op = flatOp, Id = BufferCodec.readValue(reader) } :: WireDestroyItem
	elseif wireOp == WIRE_OP_SETPARENT then
		return {
			Op = flatOp,
			Id = BufferCodec.readValue(reader),
			ParentId = BufferCodec.readValue(reader),
		} :: WireSetParentItem
	elseif wireOp == WIRE_OP_OPS then
		local opCount = if payload == OPS_COUNT_SENTINEL then BufferCodec.readVarint(reader) else payload
		local id = BufferCodec.readValue(reader)
		local ops = table.create(opCount) :: { WireOpEntry }
		local prevPath: { any } = {}
		for i = 1, opCount do
			local entry: WireOpEntry
			entry, prevPath = readOpEntry(reader, prevPath)
			ops[i] = entry
		end
		return { Op = flatOp, Id = id, Ops = ops } :: WireOpsItem
	end

	error(`[TableReplicator] MessageCodec: unknown wire opcode {wireOp}`)
end

--[=[
	Encodes `items` into a compact binary buffer using bit-packed framing.
	Shared tables within the message are automatically interned by BufferCodec's
	identity table-tracking, eliminating the need for a separate RefCodec pass.
	Returns the buffer and the deduplicated Instance side-list (or nil when the
	message carries none).
]=]
function MessageCodec.Encode(items: { WireItem }): (buffer, { Instance }?)
	BufferCodec.resetWriter(writer)
	BufferCodec.writeByte(writer, FlatCodec.Version)
	BufferCodec.writeVarint(writer, #items)
	for _, item in items do
		writeItem(item)
	end
	return BufferCodec.export(writer)
end

--[=[
	Decodes a buffer produced by `Encode` back into a `WireMessage`, resolving
	any Instance references against the side-list returned alongside the buffer.
	Each Create item's Data/Tags and each op Value is deep-copied so that two
	items which shared a table on the wire get independent copies on decode.
]=]
function MessageCodec.Decode(buf: buffer, instances: { Instance }?): WireMessage
	const reader = BufferCodec.newReader(buf, instances)
	const version = BufferCodec.readByte(reader)
	const itemCount = BufferCodec.readVarint(reader)
	const items = table.create(itemCount) :: { WireItem }
	for i = 1, itemCount do
		items[i] = readItem(reader)
	end
	return { V = version, Items = items }
end

return MessageCodec
