--[=[

	@class BufferCodec

	Compact binary value codec over Luau buffers — the byte-level layer of the replication
	wire (Wire.luau is the message layer on top). Every value starts with a one-byte tag, and
	the common cases bit-pack their payload into the tag byte itself so they cost zero extra
	bytes: integers 0..127 and -32..-1, string lengths 0..31, array/map sizes 0..15. Larger
	values fall through to explicit-width tags, with numbers stored in the smallest integer
	width that holds them (or f32 when it round-trips losslessly, f64 otherwise).

	Strings of length >= 2 are interned per message: the first occurrence writes the bytes,
	repeats write a 2-3 byte back-reference. Repeated dictionary keys (arrays of uniform
	records in a snapshot) collapse to almost nothing. Reader and writer must apply the same
	interning rule (INTERN_MIN_LENGTH / INTERN_MAX_COUNT) or references desync.

	Instances cannot live inside a buffer — only the engine can serialize an instance ref,
	and only as a remote argument. The writer therefore collects them into a side list
	(deduplicated) and stores a 1-based index in the buffer; `export` returns the list so the
	message layer can ship it as a second remote argument, and the reader resolves indices
	against the received list. A ref the engine can not resolve on the client (streamed
	out, server-only) decodes as nil.

	Any value the buffer has no tag for (Roblox datatypes without a dedicated tag — Ray,
	Region3, UDim2, EnumItem, … — as well as anything else) rides that same side list rather
	than being rejected: the codec hands the raw value to the remote to serialize natively,
	exactly like an Instance ref. The buffer stores only the index. This keeps unsupported
	data flowing (at native remote cost) instead of erroring out the whole message.

	A value a RemoteEvent genuinely can't serialize (function, thread, RBXScriptSignal,
	RBXScriptConnection — see NON_REPLICABLE_TYPES) can't ride the side list either: sending
	it would throw at FireClient and take the whole batched message down. The writer instead
	warns and encodes nil in its place, so that one bad value is dropped in isolation while
	every unrelated op sharing the frame still delivers.

	Directly-tagged value types (bit-packed into the buffer): nil, boolean, number, string,
	table, Vector3, Vector2, CFrame, Color3. Instances and everything else ride the side list.

]=]

------------------------------------------------------------------------------------------------
-- // Types
------------------------------------------------------------------------------------------------

export type Writer = {
	buf: buffer,
	cursor: number,
	interned: { [string]: number },
	internedCount: number,
	-- Side list of values the buffer can't hold inline (Instances and any
	-- untagged type), deduplicated by identity; the buffer stores a 1-based index.
	instanceRefs: { [any]: number },
	instances: { any },
	tableRefs: { [{ [any]: any }]: number },
	tableRefCount: number,
}

export type Reader = {
	buf: buffer,
	cursor: number,
	interned: { string },
	instances: { any }?,
	tableRefs: { { [any]: any } },
}

------------------------------------------------------------------------------------------------
-- // Globals
------------------------------------------------------------------------------------------------

local TAG_NIL = 0x00
local TAG_FALSE = 0x01
local TAG_TRUE = 0x02
local TAG_F32 = 0x03
local TAG_F64 = 0x04
local TAG_U8 = 0x05
local TAG_U16 = 0x06
local TAG_U32 = 0x07
local TAG_I8 = 0x08
local TAG_I16 = 0x09
local TAG_I32 = 0x0A
local TAG_STR8 = 0x0B
local TAG_STR16 = 0x0C
local TAG_STR32 = 0x0D
local TAG_STRREF8 = 0x0E
local TAG_STRREF16 = 0x0F
local TAG_ARR8 = 0x10
local TAG_ARR16 = 0x11
local TAG_ARR32 = 0x12
local TAG_MAP8 = 0x13
local TAG_MAP16 = 0x14
local TAG_MAP32 = 0x15
local TAG_VECTOR3 = 0x16
local TAG_VECTOR2 = 0x17
local TAG_CFRAME = 0x18
local TAG_COLOR3 = 0x19
local TAG_REF        = 0x1A -- varint index into the side list (Instance or any untagged value)
local TAG_TABLEREF8  = 0x1B -- u8  back-ref id: table seen earlier this message
local TAG_TABLEREF16 = 0x1C -- u16 back-ref id

local TAG_FIXSTR = 0x20 -- 0x20..0x3F: string, length 0..31 in the low 5 bits
local TAG_FIXARR = 0x40 -- 0x40..0x4F: array, size 0..15 in the low 4 bits
local TAG_FIXMAP = 0x50 -- 0x50..0x5F: map, size 0..15 in the low 4 bits
local TAG_FIXNEG = 0x60 -- 0x60..0x7F: integer -32..-1
local TAG_FIXINT = 0x80 -- 0x80..0xFF: integer 0..127 in the low 7 bits

local FIXSTR_MAX = 31
local FIXARR_MAX = 15
local FIXMAP_MAX = 15

local INTERN_MIN_LENGTH = 2
local INTERN_MAX_COUNT = 0xFFFF

local INITIAL_CAPACITY = 64

-- Best-effort block-list of `typeof` results a RemoteEvent can't serialize. A
-- value of one of these types can't ride the side list -- offloading it would
-- throw at FireClient and take the whole batched message down with it -- so the
-- writer warns and encodes nil in its place, letting the unrelated ops in the
-- same frame still deliver. Extend this as other non-serializable types surface;
-- it deliberately never lists a valid datatype, so a real value is never dropped.
local NON_REPLICABLE_TYPES: { [string]: true } = {
	["function"] = true,
	thread = true,
	RBXScriptSignal = true,
	RBXScriptConnection = true,
}

local f32Scratch = buffer.create(4)

------------------------------------------------------------------------------------------------
-- // Helpers
------------------------------------------------------------------------------------------------

local writeValue, readValue -- forward-declared: tables recurse through them

local function fitsF32(value: number): boolean
	buffer.writef32(f32Scratch, 0, value)
	return buffer.readf32(f32Scratch, 0) == value
end

local function reserve(writer: Writer, bytes: number)
	local needed = writer.cursor + bytes
	local capacity = buffer.len(writer.buf)
	if needed <= capacity then
		return
	end

	repeat
		capacity *= 2
	until capacity >= needed

	local grown = buffer.create(capacity)
	buffer.copy(grown, 0, writer.buf, 0, writer.cursor)
	writer.buf = grown
end

local function putU8(writer: Writer, value: number)
	reserve(writer, 1)
	buffer.writeu8(writer.buf, writer.cursor, value)
	writer.cursor += 1
end

local function putU16(writer: Writer, value: number)
	reserve(writer, 2)
	buffer.writeu16(writer.buf, writer.cursor, value)
	writer.cursor += 2
end

local function putU32(writer: Writer, value: number)
	reserve(writer, 4)
	buffer.writeu32(writer.buf, writer.cursor, value)
	writer.cursor += 4
end

local function putI8(writer: Writer, value: number)
	reserve(writer, 1)
	buffer.writei8(writer.buf, writer.cursor, value)
	writer.cursor += 1
end

local function putI16(writer: Writer, value: number)
	reserve(writer, 2)
	buffer.writei16(writer.buf, writer.cursor, value)
	writer.cursor += 2
end

local function putI32(writer: Writer, value: number)
	reserve(writer, 4)
	buffer.writei32(writer.buf, writer.cursor, value)
	writer.cursor += 4
end

local function putF32(writer: Writer, value: number)
	reserve(writer, 4)
	buffer.writef32(writer.buf, writer.cursor, value)
	writer.cursor += 4
end

local function putF64(writer: Writer, value: number)
	reserve(writer, 8)
	buffer.writef64(writer.buf, writer.cursor, value)
	writer.cursor += 8
end

local function getU8(reader: Reader): number
	local value = buffer.readu8(reader.buf, reader.cursor)
	reader.cursor += 1
	return value
end

local function getU16(reader: Reader): number
	local value = buffer.readu16(reader.buf, reader.cursor)
	reader.cursor += 2
	return value
end

local function getU32(reader: Reader): number
	local value = buffer.readu32(reader.buf, reader.cursor)
	reader.cursor += 4
	return value
end

local function getI8(reader: Reader): number
	local value = buffer.readi8(reader.buf, reader.cursor)
	reader.cursor += 1
	return value
end

local function getI16(reader: Reader): number
	local value = buffer.readi16(reader.buf, reader.cursor)
	reader.cursor += 2
	return value
end

local function getI32(reader: Reader): number
	local value = buffer.readi32(reader.buf, reader.cursor)
	reader.cursor += 4
	return value
end

local function getF32(reader: Reader): number
	local value = buffer.readf32(reader.buf, reader.cursor)
	reader.cursor += 4
	return value
end

local function getF64(reader: Reader): number
	local value = buffer.readf64(reader.buf, reader.cursor)
	reader.cursor += 8
	return value
end

--[=[
	@within BufferCodec
	@function newWriter
	Creates a new writer used for encoding values into a binary buffer.

	The writer maintains temporary state while encoding, including string
	interning tables and deduplicated instance references.

	```lua
	local writer = BufferCodec.newWriter()

	BufferCodec.writeValue(writer, {
		Name = "Player",
		Health = 100,
	})

	local buffer, instances = BufferCodec.export(writer)
	```

	@return Writer
]=]
const function newWriter(): Writer
	return {
		buf = buffer.create(INITIAL_CAPACITY),
		cursor = 0,
		interned = {},
		internedCount = 0,
		instanceRefs = {},
		instances = {},
		tableRefs = {},
		tableRefCount = 0,
	}
end

const function resetWriter(writer: Writer)
    writer.cursor = 0
    writer.interned = {}
    writer.internedCount = 0
    writer.instanceRefs = {}
    writer.instances = {}
    writer.tableRefs = {}
    writer.tableRefCount = 0
end

--[=[
	@within BufferCodec
	@function export
	Finalizes a writer.

	Returns a tightly-sized buffer containing the encoded bytes and an
	optional side list of raw values (Instances and any untagged types) which
	must accompany the buffer when transmitting over a RemoteEvent.

	```lua
	local buffer, instances = BufferCodec.export(writer)

	RemoteEvent:FireClient(player, buffer, instances)
	```

	@param writer Writer

	@return buffer
	@return {any}?
]=]
const function export(writer: Writer): (buffer, { any }?)
	local out = buffer.create(writer.cursor)
	buffer.copy(out, 0, writer.buf, 0, writer.cursor)
	return out, if #writer.instances > 0 then writer.instances else nil
end

--[=[
	@within BufferCodec
	@function newReader
	Creates a reader for decoding values from an encoded buffer.

	The supplied side list should be the same list returned by
	`export` on the writing side.

	```lua
	local reader = BufferCodec.newReader(buffer, instances)

	local value = BufferCodec.readValue(reader)
	```

	@param buffer buffer
	@param instances {any}?

	@return Reader
]=]
const function newReader(buf: buffer, instances: { any }?): Reader
	return {
		buf = buf,
		cursor = 0,
		interned = {},
		instances = instances,
		tableRefs = {},
	}
end

-- NOTE: Only supports unsigned varints
const function writeVarint(writer: Writer, value: number)
	while value >= 0x80 do
		putU8(writer, value % 0x80 + 0x80)
		value = value // 0x80
	end
	putU8(writer, value)
end

const function readVarint(reader: Reader): number
	local result = 0
	local shift = 1
	while true do
		local byte = getU8(reader)
		result += byte % 0x80 * shift
		if byte < 0x80 then
			return result
		end
		shift *= 0x80
	end
end

const function writeString(writer: Writer, value: string)
	local ref = writer.interned[value]
	if ref then
		if ref <= 0xFF then
			putU8(writer, TAG_STRREF8)
			putU8(writer, ref)
		else
			putU8(writer, TAG_STRREF16)
			putU16(writer, ref)
		end
		return
	end

	local length = #value
	if length <= FIXSTR_MAX then
		putU8(writer, TAG_FIXSTR + length)
	elseif length <= 0xFF then
		putU8(writer, TAG_STR8)
		putU8(writer, length)
	elseif length <= 0xFFFF then
		putU8(writer, TAG_STR16)
		putU16(writer, length)
	else
		putU8(writer, TAG_STR32)
		putU32(writer, length)
	end

	reserve(writer, length)
	buffer.writestring(writer.buf, writer.cursor, value)
	writer.cursor += length

	if length >= INTERN_MIN_LENGTH and writer.internedCount < INTERN_MAX_COUNT then
		writer.internedCount += 1
		writer.interned[value] = writer.internedCount
	end
end

const function readStringPayload(reader: Reader, length: number): string
	local value = buffer.readstring(reader.buf, reader.cursor, length)
	reader.cursor += length

	if length >= INTERN_MIN_LENGTH and #reader.interned < INTERN_MAX_COUNT then
		table.insert(reader.interned, value)
	end

	return value
end

const function readStringFromTag(reader: Reader, tag: number): string
	if tag >= TAG_FIXSTR and tag <= TAG_FIXSTR + FIXSTR_MAX then
		return readStringPayload(reader, tag - TAG_FIXSTR)
	elseif tag == TAG_STR8 then
		return readStringPayload(reader, getU8(reader))
	elseif tag == TAG_STR16 then
		return readStringPayload(reader, getU16(reader))
	elseif tag == TAG_STR32 then
		return readStringPayload(reader, getU32(reader))
	elseif tag == TAG_STRREF8 then
		return reader.interned[getU8(reader)]
	elseif tag == TAG_STRREF16 then
		return reader.interned[getU16(reader)]
	end

	error(`[TableReplicator] expected a string tag, got 0x{string.format("%02X", tag)}`)
end

const function readString(reader: Reader): string
	return readStringFromTag(reader, getU8(reader))
end

const function writeNumber(writer: Writer, value: number)
	if value % 1 == 0 and value >= -2147483648 and value <= 4294967295 then
		if value >= 0 then
			if value <= 0x7F then
				putU8(writer, TAG_FIXINT + value)
			elseif value <= 0xFF then
				putU8(writer, TAG_U8)
				putU8(writer, value)
			elseif value <= 0xFFFF then
				putU8(writer, TAG_U16)
				putU16(writer, value)
			else
				putU8(writer, TAG_U32)
				putU32(writer, value)
			end
		else
			if value >= -32 then
				putU8(writer, TAG_FIXNEG + value + 32)
			elseif value >= -0x80 then
				putU8(writer, TAG_I8)
				putI8(writer, value)
			elseif value >= -0x8000 then
				putU8(writer, TAG_I16)
				putI16(writer, value)
			else
				putU8(writer, TAG_I32)
				putI32(writer, value)
			end
		end
	elseif fitsF32(value) then
		putU8(writer, TAG_F32)
		putF32(writer, value)
	else
		putU8(writer, TAG_F64)
		putF64(writer, value)
	end
end

const function writeTable(writer: Writer, value: { [any]: any })
	local ref = writer.tableRefs[value]
	if ref then
		if ref <= 0xFF then
			putU8(writer, TAG_TABLEREF8)
			putU8(writer, ref)
		else
			putU8(writer, TAG_TABLEREF16)
			putU16(writer, ref)
		end
		return
	end
	writer.tableRefCount += 1
	writer.tableRefs[value] = writer.tableRefCount

	local arrayLength = #value
	local totalKeys = 0
	for _ in value do
		totalKeys += 1
	end

	if totalKeys == arrayLength then
		if arrayLength <= FIXARR_MAX then
			putU8(writer, TAG_FIXARR + arrayLength)
		elseif arrayLength <= 0xFF then
			putU8(writer, TAG_ARR8)
			putU8(writer, arrayLength)
		elseif arrayLength <= 0xFFFF then
			putU8(writer, TAG_ARR16)
			putU16(writer, arrayLength)
		else
			putU8(writer, TAG_ARR32)
			putU32(writer, arrayLength)
		end

		for index = 1, arrayLength do
			writeValue(writer, value[index])
		end
	else
		if totalKeys <= FIXMAP_MAX then
			putU8(writer, TAG_FIXMAP + totalKeys)
		elseif totalKeys <= 0xFF then
			putU8(writer, TAG_MAP8)
			putU8(writer, totalKeys)
		elseif totalKeys <= 0xFFFF then
			putU8(writer, TAG_MAP16)
			putU16(writer, totalKeys)
		else
			putU8(writer, TAG_MAP32)
			putU32(writer, totalKeys)
		end

		for key, entry in value do
			writeValue(writer, key)
			writeValue(writer, entry)
		end
	end
end

-- Offloads a value the buffer can't hold inline (an Instance, or any type without
-- a dedicated tag) to the deduplicated side list, writing only its 1-based index.
-- The reader resolves that index against the list shipped alongside the buffer.
local function writeRef(writer: Writer, value: any)
	local ref = writer.instanceRefs[value]
	if not ref then
		table.insert(writer.instances, value)
		ref = #writer.instances
		writer.instanceRefs[value] = ref
	end
	putU8(writer, TAG_REF)
	writeVarint(writer, ref)
end

--[=[
	@within BufferCodec
	@function writeValue
	Encodes any Luau value.

	Directly tagged into the buffer:

	• nil
	• boolean
	• number
	• string
	• table
	• Vector2
	• Vector3
	• CFrame
	• Color3

	Instances and any other type (Roblox datatypes without a dedicated tag, etc.)
	ride the side list as raw values and are serialized natively by the remote.

	A value the remote can't serialize at all (function, thread, RBXScriptSignal,
	RBXScriptConnection) is dropped in isolation: the writer warns and encodes nil
	so the rest of the message still delivers.

	@param writer Writer
	@param value any
]=]
function writeValue(writer: Writer, value: any)
	local valueType = typeof(value)

	if value == nil then
		putU8(writer, TAG_NIL)
	elseif valueType == "boolean" then
		putU8(writer, if value then TAG_TRUE else TAG_FALSE)
	elseif valueType == "number" then
		writeNumber(writer, value)
	elseif valueType == "string" then
		writeString(writer, value)
	elseif valueType == "table" then
		writeTable(writer, value)
	elseif valueType == "Instance" then
		writeRef(writer, value)
	elseif valueType == "Vector3" then
		putU8(writer, TAG_VECTOR3)
		putF32(writer, value.X)
		putF32(writer, value.Y)
		putF32(writer, value.Z)
	elseif valueType == "Vector2" then
		putU8(writer, TAG_VECTOR2)
		putF32(writer, value.X)
		putF32(writer, value.Y)
	elseif valueType == "CFrame" then
		putU8(writer, TAG_CFRAME)
		local components = table.pack(value:GetComponents())
		for index = 1, 12 do
			putF32(writer, components[index])
		end
	elseif valueType == "Color3" then
		putU8(writer, TAG_COLOR3)
		putF32(writer, value.R)
		putF32(writer, value.G)
		putF32(writer, value.B)
	elseif NON_REPLICABLE_TYPES[valueType] then
		-- The remote can't serialize this, so it can't ride the side list either.
		-- Drop just this value (encode nil) and warn, rather than letting it throw
		-- at FireClient and lose every unrelated op batched into the same message.
		warn(`[TableReplicator] cannot replicate a value of type "{valueType}"; encoding nil in its place so the rest of the message still delivers`)
		putU8(writer, TAG_NIL)
	else
		-- No dedicated tag, but the remote can serialize it: offload the raw value
		-- to the side list and let the remote handle it, exactly like an Instance ref.
		writeRef(writer, value)
	end
end

const function readArray(reader: Reader, count: number): { any }
	local out = table.create(count)
	table.insert(reader.tableRefs, out) -- register before filling so back-refs during fill alias correctly
	for index = 1, count do
		out[index] = readValue(reader)
	end
	return out
end

const function readMap(reader: Reader, count: number): { [any]: any }
	local out = {}
	table.insert(reader.tableRefs, out) -- register before filling so back-refs during fill alias correctly
	for _ = 1, count do
		local key = readValue(reader)
		out[key] = readValue(reader)
	end
	return out
end

--[=[
	@within BufferCodec
	@function readValue
	Reads the next encoded value from the stream.

	Returns the decoded Luau value.

	@param reader Reader

	@return any
]=]
function readValue(reader: Reader): any
	local tag = getU8(reader)

	if tag >= TAG_FIXINT then
		return tag - TAG_FIXINT
	elseif tag >= TAG_FIXNEG then
		return tag - TAG_FIXNEG - 32
	elseif tag >= TAG_FIXMAP then
		return readMap(reader, tag - TAG_FIXMAP)
	elseif tag >= TAG_FIXARR then
		return readArray(reader, tag - TAG_FIXARR)
	elseif tag >= TAG_FIXSTR then
		return readStringPayload(reader, tag - TAG_FIXSTR)
	end

	if tag == TAG_NIL then
		return nil
	elseif tag == TAG_FALSE then
		return false
	elseif tag == TAG_TRUE then
		return true
	elseif tag == TAG_F32 then
		return getF32(reader)
	elseif tag == TAG_F64 then
		return getF64(reader)
	elseif tag == TAG_U8 then
		return getU8(reader)
	elseif tag == TAG_U16 then
		return getU16(reader)
	elseif tag == TAG_U32 then
		return getU32(reader)
	elseif tag == TAG_I8 then
		return getI8(reader)
	elseif tag == TAG_I16 then
		return getI16(reader)
	elseif tag == TAG_I32 then
		return getI32(reader)
	elseif tag == TAG_STR8 or tag == TAG_STR16 or tag == TAG_STR32 or tag == TAG_STRREF8 or tag == TAG_STRREF16 then
		return readStringFromTag(reader, tag)
	elseif tag == TAG_ARR8 then
		return readArray(reader, getU8(reader))
	elseif tag == TAG_ARR16 then
		return readArray(reader, getU16(reader))
	elseif tag == TAG_ARR32 then
		return readArray(reader, getU32(reader))
	elseif tag == TAG_MAP8 then
		return readMap(reader, getU8(reader))
	elseif tag == TAG_MAP16 then
		return readMap(reader, getU16(reader))
	elseif tag == TAG_MAP32 then
		return readMap(reader, getU32(reader))
	elseif tag == TAG_REF then
		local ref = readVarint(reader)
		return if reader.instances then reader.instances[ref] else nil
	elseif tag == TAG_VECTOR3 then
		return Vector3.new(getF32(reader), getF32(reader), getF32(reader))
	elseif tag == TAG_VECTOR2 then
		return Vector2.new(getF32(reader), getF32(reader))
	elseif tag == TAG_CFRAME then
		local components = table.create(12)
		for index = 1, 12 do
			components[index] = getF32(reader)
		end

		-- Casting `table.unpack(...) :: any` would truncate the multi-return to a
		-- single value, so cast the constructor instead of the argument list.
		return (CFrame.new :: any)(table.unpack(components))
	elseif tag == TAG_COLOR3 then
		return Color3.new(getF32(reader), getF32(reader), getF32(reader))
	elseif tag == TAG_TABLEREF8 then
		return reader.tableRefs[getU8(reader)]
	elseif tag == TAG_TABLEREF16 then
		return reader.tableRefs[getU16(reader)]
	end

	error(`[TableReplicator] unknown value tag 0x{string.format("%02X", tag)}`)
end

------------------------------------------------------------------------------------------------
-- // BufferCodec
------------------------------------------------------------------------------------------------

local BufferCodec = {
	newWriter = newWriter,
    resetWriter = resetWriter,
	export = export,
	writeByte = putU8,
	writeVarint = writeVarint,
	writeString = writeString,
	writeValue = writeValue,

	newReader = newReader,
	readByte = getU8,
	readVarint = readVarint,
	readString = readString,
	readValue = readValue,
}

return BufferCodec