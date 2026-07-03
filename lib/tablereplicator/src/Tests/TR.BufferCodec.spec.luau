--!strict
--[[
	Byte-level coverage for `BufferCodec`: every tag family (fixed-width ints,
	explicit-width ints, floats, all string widths, string interning refs, all
	array/map widths, Roblox datatypes, side-list refs for Instances and untagged
	raw values, and table back-refs), plus buffer growth, varints, and every
	decode error path. Pure round-trip tests -- no replicators, no transport.
]]

return function(t: tiniest)
	local BufferCodec = require("../Shared/Serialization/BufferCodec")

	local describe = t.describe
	local test = t.test
	local expect = t.expect

	-- Encodes `value` with a fresh writer and decodes it back with a fresh
	-- reader, carrying the instance side-list across like the transport would.
	local function roundTrip(value: any): any
		local writer = BufferCodec.newWriter()
		BufferCodec.writeValue(writer, value)
		local buf, instances = BufferCodec.export(writer)
		local reader = BufferCodec.newReader(buf, instances)
		return BufferCodec.readValue(reader)
	end

	-- Round-trips `value` and asserts the encoded form is exactly `bytes` long,
	-- pinning which tag family the writer picked (1 tag byte + payload).
	local function roundTripSized(value: any, bytes: number): any
		local writer = BufferCodec.newWriter()
		BufferCodec.writeValue(writer, value)
		local buf = BufferCodec.export(writer)
		expect(buffer.len(buf)).is(bytes)
		local reader = BufferCodec.newReader(buf, nil)
		return BufferCodec.readValue(reader)
	end

	--------------------------------------------------------------------------------

	describe("BufferCodec primitives", function()
		test("nil round-trips", function()
			expect(roundTrip(nil)).is(nil)
		end)

		test("true and false round-trip", function()
			expect(roundTrip(true)).is(true)
			expect(roundTrip(false)).is(false)
		end)
	end)

	--------------------------------------------------------------------------------

	describe("BufferCodec numbers", function()
		test("fixint 0..127 packs into the tag byte", function()
			expect(roundTripSized(0, 1)).is(0)
			expect(roundTripSized(64, 1)).is(64)
			expect(roundTripSized(127, 1)).is(127)
		end)

		test("u8 128..255", function()
			expect(roundTripSized(128, 2)).is(128)
			expect(roundTripSized(255, 2)).is(255)
		end)

		test("u16 256..65535", function()
			expect(roundTripSized(256, 3)).is(256)
			expect(roundTripSized(65535, 3)).is(65535)
		end)

		test("u32 65536..4294967295", function()
			expect(roundTripSized(65536, 5)).is(65536)
			expect(roundTripSized(4294967295, 5)).is(4294967295)
		end)

		test("fixneg -1..-32 packs into the tag byte", function()
			expect(roundTripSized(-1, 1)).is(-1)
			expect(roundTripSized(-32, 1)).is(-32)
		end)

		test("i8 -33..-128", function()
			expect(roundTripSized(-33, 2)).is(-33)
			expect(roundTripSized(-128, 2)).is(-128)
		end)

		test("i16 -129..-32768", function()
			expect(roundTripSized(-129, 3)).is(-129)
			expect(roundTripSized(-32768, 3)).is(-32768)
		end)

		test("i32 -32769..-2147483648", function()
			expect(roundTripSized(-32769, 5)).is(-32769)
			expect(roundTripSized(-2147483648, 5)).is(-2147483648)
		end)

		test("f32 for fractions that fit f32 losslessly", function()
			expect(roundTripSized(1.5, 5)).is(1.5)
			expect(roundTripSized(-0.25, 5)).is(-0.25)
		end)

		test("f64 for fractions that do NOT fit f32", function()
			expect(roundTripSized(0.1, 9)).is(0.1)
		end)

		test("integers beyond the u32/i32 range fall through to floats", function()
			expect(roundTrip(2 ^ 40)).is(2 ^ 40) -- power of two: f32-exact
			expect(roundTrip(-(2 ^ 40))).is(-(2 ^ 40))
			expect(roundTrip(2 ^ 40 + 1)).is(2 ^ 40 + 1) -- 41 significant bits: needs f64
		end)
	end)

	--------------------------------------------------------------------------------

	describe("BufferCodec strings", function()
		test("fixstr: empty string and length-31 string", function()
			expect(roundTrip("")).is("")
			local s31 = string.rep("a", 31)
			expect(roundTripSized(s31, 32)).is(s31)
		end)

		test("str8: lengths 32..255", function()
			local s = string.rep("b", 200)
			expect(roundTripSized(s, 202)).is(s)
		end)

		test("str16: lengths 256..65535", function()
			local s = string.rep("c", 1000)
			expect(roundTripSized(s, 1003)).is(s)
		end)

		test("str32: length > 65535", function()
			local s = string.rep("d", 70000)
			expect(roundTripSized(s, 70005)).is(s)
		end)

		test("repeated string is interned to a 2-byte strref8", function()
			local writer = BufferCodec.newWriter()
			BufferCodec.writeValue(writer, { "hello-world", "hello-world" })
			local buf = BufferCodec.export(writer)
			-- 1 (fixarr) + 12 (fixstr) + 2 (strref8) bytes
			expect(buffer.len(buf)).is(15)
			local decoded = BufferCodec.readValue(BufferCodec.newReader(buf, nil))
			expect(decoded[1]).is("hello-world")
			expect(decoded[2]).is("hello-world")
		end)

		test("single-char strings are never interned", function()
			local writer = BufferCodec.newWriter()
			BufferCodec.writeValue(writer, { "x", "x" })
			local buf = BufferCodec.export(writer)
			-- 1 (fixarr) + 2 + 2: both occurrences written in full
			expect(buffer.len(buf)).is(5)
			local decoded = BufferCodec.readValue(BufferCodec.newReader(buf, nil))
			expect(decoded[2]).is("x")
		end)

		test("writeString/readString round-trip directly (fixstr via the string reader)", function()
			local writer = BufferCodec.newWriter()
			BufferCodec.writeString(writer, "direct")
			BufferCodec.writeString(writer, "direct") -- second copy reads back through a ref
			local buf = BufferCodec.export(writer)
			local reader = BufferCodec.newReader(buf, nil)
			expect(BufferCodec.readString(reader)).is("direct")
			expect(BufferCodec.readString(reader)).is("direct")
		end)

		test("strref16 kicks in past 255 interned strings", function()
			-- 300 unique strings intern to refs 1..300; repeating the 300th
			-- (ref 300 > 0xFF) forces the 3-byte strref16 form.
			local values = table.create(301)
			for i = 1, 300 do
				values[i] = `key{i}`
			end
			values[301] = values[300]
			local decoded = roundTrip(values)
			expect(#decoded).is(301)
			expect(decoded[300]).is("key300")
			expect(decoded[301]).is("key300")
			expect(decoded[1]).is("key1")
		end)
	end)

	--------------------------------------------------------------------------------

	describe("BufferCodec arrays and maps", function()
		local function sequence(n: number): { number }
			local out = table.create(n)
			for i = 1, n do
				out[i] = i % 100
			end
			return out
		end

		local function checkArray(n: number)
			local decoded = roundTrip(sequence(n))
			expect(#decoded).is(n)
			expect(decoded[1]).is(1)
			expect(decoded[n]).is(n % 100)
		end

		test("fixarr: sizes 0..15", function()
			expect(#roundTrip({})).is(0)
			checkArray(15)
		end)

		test("arr8: sizes 16..255", function()
			checkArray(16)
			checkArray(255)
		end)

		test("arr16: sizes 256..65535", function()
			checkArray(300)
		end)

		test("arr32: sizes > 65535", function()
			checkArray(70000)
		end)

		local function record(n: number): { [string]: number }
			local out = {}
			for i = 1, n do
				out[`k{i}`] = i
			end
			return out
		end

		local function checkMap(n: number)
			local decoded = roundTrip(record(n))
			local count = 0
			for _ in decoded do
				count += 1
			end
			expect(count).is(n)
			expect(decoded.k1).is(1)
			expect(decoded[`k{n}`]).is(n)
		end

		test("fixmap: sizes 0..15", function()
			checkMap(15)
		end)

		test("map8: sizes 16..255", function()
			checkMap(16)
			checkMap(255)
		end)

		test("map16: sizes 256..65535", function()
			checkMap(300)
		end)

		test("map32: sizes > 65535", function()
			checkMap(70000)
		end)

		test("mixed-key tables encode as maps, not arrays", function()
			local decoded = roundTrip({ 1, 2, 3, name = "mixed" })
			expect(decoded[1]).is(1)
			expect(decoded[3]).is(3)
			expect(decoded.name).is("mixed")
		end)

		test("nested tables round-trip", function()
			local decoded = roundTrip({ a = { b = { c = { 1, 2, { d = true } } } } })
			expect(decoded.a.b.c[1]).is(1)
			expect(decoded.a.b.c[3].d).is(true)
		end)
	end)

	--------------------------------------------------------------------------------

	describe("BufferCodec table back-refs", function()
		test("a table written twice decodes as one aliased table (tableref8)", function()
			local shared = { hp = 100 }
			local decoded = roundTrip({ a = shared, b = shared })
			expect(decoded.a.hp).is(100)
			expect(decoded.a).is(decoded.b) -- identity preserved at the codec layer
		end)

		test("cyclic tables round-trip with the cycle intact", function()
			local node: any = { name = "root" }
			node.self = node
			local decoded = roundTrip(node)
			expect(decoded.name).is("root")
			expect(decoded.self).is(decoded)
		end)

		test("tableref16 kicks in past 255 registered tables", function()
			-- Outer array is ref 1; 300 unique subtables take refs 2..301.
			-- Repeating the last one (ref 301 > 0xFF) forces tableref16.
			local values: { any } = table.create(301)
			for i = 1, 300 do
				values[i] = { i = i }
			end
			values[301] = values[300]
			local decoded = roundTrip(values)
			expect(decoded[300].i).is(300)
			expect(decoded[301]).is(decoded[300])
			expect(decoded[299] == decoded[300]).is(false)
		end)
	end)

	--------------------------------------------------------------------------------

	describe("BufferCodec Roblox datatypes", function()
		test("Vector3 round-trips", function()
			expect(roundTrip(Vector3.new(1, -2.5, 300))).is(Vector3.new(1, -2.5, 300))
		end)

		test("Vector2 round-trips", function()
			expect(roundTrip(Vector2.new(-7, 0.25))).is(Vector2.new(-7, 0.25))
		end)

		test("CFrame round-trips position and rotation", function()
			-- A permutation rotation matrix: every component is f32-exact, so
			-- the decoded CFrame compares equal component-by-component.
			local original = CFrame.new(1, 2, 3, 0, 1, 0, 0, 0, 1, 1, 0, 0)
			local decoded = roundTrip(original)
			local want = table.pack(original:GetComponents())
			local got = table.pack(decoded:GetComponents())
			for i = 1, 12 do
				expect(got[i]).is(want[i])
			end
		end)

		test("Color3 round-trips", function()
			expect(roundTrip(Color3.new(0.5, 0.25, 1))).is(Color3.new(0.5, 0.25, 1))
		end)
	end)

	--------------------------------------------------------------------------------

	describe("BufferCodec instance refs", function()
		test("an Instance rides the side list and resolves on read", function()
			local folder = Instance.new("Folder")
			local writer = BufferCodec.newWriter()
			BufferCodec.writeValue(writer, { target = folder })
			local buf, instances = BufferCodec.export(writer)
			expect(instances).never_is(nil)
			expect(#(instances :: { Instance })).is(1)
			local decoded = BufferCodec.readValue(BufferCodec.newReader(buf, instances))
			expect(decoded.target).is(folder)
			folder:Destroy()
		end)

		test("the same Instance written twice is deduplicated in the side list", function()
			local folder = Instance.new("Folder")
			local writer = BufferCodec.newWriter()
			BufferCodec.writeValue(writer, { a = folder, b = folder })
			local buf, instances = BufferCodec.export(writer)
			expect(#(instances :: { Instance })).is(1)
			local decoded = BufferCodec.readValue(BufferCodec.newReader(buf, instances))
			expect(decoded.a).is(folder)
			expect(decoded.b).is(folder)
			folder:Destroy()
		end)

		test("an unresolvable Instance ref decodes as nil", function()
			local folder = Instance.new("Folder")
			local writer = BufferCodec.newWriter()
			BufferCodec.writeValue(writer, folder)
			local buf = BufferCodec.export(writer)
			-- Reader constructed WITHOUT the side list (streamed out / server-only).
			expect(BufferCodec.readValue(BufferCodec.newReader(buf, nil))).is(nil)
			folder:Destroy()
		end)
	end)

	--------------------------------------------------------------------------------

	describe("BufferCodec raw side-list values", function()
		-- A Roblox datatype with no dedicated buffer tag: instead of erroring, the
		-- writer offloads it to the side list exactly as it does an Instance.
		test("an untagged datatype rides the side list instead of erroring", function()
			local value = NumberRange.new(2, 8)
			local writer = BufferCodec.newWriter()
			BufferCodec.writeValue(writer, { range = value })
			local buf, instances = BufferCodec.export(writer)
			expect(instances).never_is(nil)
			expect(#(instances :: { any })).is(1)
			local decoded = BufferCodec.readValue(BufferCodec.newReader(buf, instances))
			expect(decoded.range).is(value)
		end)

		test("the same untagged value written twice is deduplicated in the side list", function()
			local value = UDim2.new(0, 5, 1, 10)
			local writer = BufferCodec.newWriter()
			BufferCodec.writeValue(writer, { a = value, b = value })
			local buf, instances = BufferCodec.export(writer)
			expect(#(instances :: { any })).is(1)
			local decoded = BufferCodec.readValue(BufferCodec.newReader(buf, instances))
			expect(decoded.a).is(value)
			expect(decoded.b).is(value)
		end)

		test("Instances and untagged values share the one side list", function()
			local folder = Instance.new("Folder")
			local range = NumberRange.new(1, 3)
			local writer = BufferCodec.newWriter()
			BufferCodec.writeValue(writer, { folder, range })
			local buf, instances = BufferCodec.export(writer)
			expect(#(instances :: { any })).is(2)
			local decoded = BufferCodec.readValue(BufferCodec.newReader(buf, instances))
			expect(decoded[1]).is(folder)
			expect(decoded[2]).is(range)
			folder:Destroy()
		end)

		test("an untagged value decodes as nil when the side list is missing", function()
			local writer = BufferCodec.newWriter()
			BufferCodec.writeValue(writer, NumberRange.new(4, 4))
			local buf = BufferCodec.export(writer)
			expect(BufferCodec.readValue(BufferCodec.newReader(buf, nil))).is(nil)
		end)
	end)

	--------------------------------------------------------------------------------

	describe("BufferCodec non-serializable values", function()
		-- Functions/threads/signals can't cross a RemoteEvent, so they can't ride the
		-- side list either. The writer drops them to nil (warning as it does) so one
		-- bad value can't fail the whole batched message. These paths `warn`.
		test("a function is dropped to nil, never added to the side list", function()
			local writer = BufferCodec.newWriter()
			BufferCodec.writeValue(writer, function() end)
			local buf, instances = BufferCodec.export(writer)
			expect(instances).is(nil) -- nothing offloaded
			expect(BufferCodec.readValue(BufferCodec.newReader(buf, instances))).is(nil)
		end)

		test("a thread is dropped to nil", function()
			local writer = BufferCodec.newWriter()
			BufferCodec.writeValue(writer, coroutine.create(function() end))
			local buf, instances = BufferCodec.export(writer)
			expect(instances).is(nil)
			expect(BufferCodec.readValue(BufferCodec.newReader(buf, instances))).is(nil)
		end)

		test("an RBXScriptSignal is dropped to nil", function()
			local folder = Instance.new("Folder")
			local writer = BufferCodec.newWriter()
			BufferCodec.writeValue(writer, folder.ChildAdded)
			local buf, instances = BufferCodec.export(writer)
			expect(instances).is(nil)
			expect(BufferCodec.readValue(BufferCodec.newReader(buf, instances))).is(nil)
			folder:Destroy()
		end)

		test("a bad value is dropped without losing its siblings in the same table", function()
			local folder = Instance.new("Folder")
			local writer = BufferCodec.newWriter()
			BufferCodec.writeValue(writer, {
				name = "keep-me",
				count = 42,
				ref = folder,
				bad = function() end,
			})
			local buf, instances = BufferCodec.export(writer)
			-- Only `folder` reached the side list; the function did not.
			expect(#(instances :: { any })).is(1)
			local decoded = BufferCodec.readValue(BufferCodec.newReader(buf, instances))
			expect(decoded.name).is("keep-me")
			expect(decoded.count).is(42)
			expect(decoded.ref).is(folder)
			expect(decoded.bad).is(nil) -- the only casualty
			folder:Destroy()
		end)
	end)

	--------------------------------------------------------------------------------

	describe("BufferCodec varints", function()
		test("varints round-trip across width boundaries", function()
			for _, value in { 0, 1, 127, 128, 300, 16383, 16384, 2 ^ 31 } do
				local writer = BufferCodec.newWriter()
				BufferCodec.writeVarint(writer, value)
				local buf = BufferCodec.export(writer)
				expect(BufferCodec.readVarint(BufferCodec.newReader(buf, nil))).is(value)
			end
		end)
	end)

	--------------------------------------------------------------------------------

	describe("BufferCodec writer growth and reuse", function()
		test("the write buffer doubles until a large value fits", function()
			-- Initial capacity is 64 bytes; a 1000-byte string forces the
			-- grow loop through several doublings in one reserve call.
			local s = string.rep("g", 1000)
			expect(roundTrip(s)).is(s)
		end)

		test("resetWriter clears interning so a reused writer starts fresh", function()
			local writer = BufferCodec.newWriter()
			BufferCodec.writeValue(writer, "shared-key")
			BufferCodec.resetWriter(writer)
			BufferCodec.writeValue(writer, "shared-key")
			local buf = BufferCodec.export(writer)
			-- Written in full again (11-char fixstr), not as a 2-byte backref
			-- into interning state that no longer exists on the read side.
			expect(buffer.len(buf)).is(11)
			expect(BufferCodec.readValue(BufferCodec.newReader(buf, nil))).is("shared-key")
		end)
	end)

	--------------------------------------------------------------------------------

	describe("BufferCodec error paths", function()
		test("readString errors on a non-string tag", function()
			local writer = BufferCodec.newWriter()
			BufferCodec.writeValue(writer, true)
			local buf = BufferCodec.export(writer)
			expect(function()
				BufferCodec.readString(BufferCodec.newReader(buf, nil))
			end).fails()
		end)

		test("readString errors on a tag just past the fixstr range (array tag)", function()
			-- 0x40 is TAG_FIXARR: above TAG_FIXSTR but outside fixstr's window,
			-- exercising the upper-bound half of the fixstr range check.
			local writer = BufferCodec.newWriter()
			BufferCodec.writeByte(writer, 0x40)
			local buf = BufferCodec.export(writer)
			expect(function()
				BufferCodec.readString(BufferCodec.newReader(buf, nil))
			end).fails()
		end)

		test("readValue errors on an unknown tag byte", function()
			local writer = BufferCodec.newWriter()
			BufferCodec.writeByte(writer, 0x1F) -- unassigned tag range
			local buf = BufferCodec.export(writer)
			expect(function()
				BufferCodec.readValue(BufferCodec.newReader(buf, nil))
			end).fails()
		end)
	end)
end
