--!strict
-- Ticket 26: how to ship a bake in a place. For the demo level and the 256-stud bench map,
-- measures each way of holding NavMesh.Serialize's buffer in a place: its size as a string,
-- its size in a saved place (SerializationService writes the same binary format as a .rbxl),
-- the load time (string -> buffer), and whether it survives a save and load. Also probes the
-- limits: StringValue length, a buffer attribute, a binary string attribute, BinaryStringValue.
-- Run: python tools/navmesh/studio/studio.py ship

type Options = { NavMesh: any, Level: any, Scenes: any, Reps: number }

local EncodingService = game:GetService("EncodingService")
local SerializationService = game:GetService("SerializationService")
local ZSTD = Enum.CompressionAlgorithm.Zstd

local function median(samples: { number }): number
	table.sort(samples)
	return samples[math.ceil(#samples / 2)]
end

-- Median ms of `reps` calls of fn (each gets a fresh setup value when `setup` is given).
local function time(reps: number, fn: (any) -> any, setup: (() -> any)?): (number, any)
	local samples, result = {}, nil
	for _ = 1, reps do
		local arg = if setup then setup() else nil
		local t0 = os.clock()
		result = fn(arg)
		table.insert(samples, (os.clock() - t0) * 1000)
	end
	return median(samples), result
end

-- The \xNN ModuleScript source the demo's bake.luau writes (48 bytes per line).
local function hexSource(data: string): string
	local lines = {}
	for i = 1, #data, 48 do
		local chunk = string.sub(data, i, i + 47)
		table.insert(lines, '\t"' .. string.gsub(chunk, ".", function(c)
			return string.format("\\x%02x", string.byte(c))
		end) .. '"')
	end
	return "return table.concat({\n" .. table.concat(lines, ",\n") .. ",\n})\n"
end

-- A shorter literal: printable ASCII as itself, other bytes as the shortest \ddd.
local function shortSource(data: string): string
	local out = {}
	for i = 1, #data do
		local b = string.byte(data, i)
		local nextDigit = i < #data and string.find(string.sub(data, i + 1, i + 1), "%d") ~= nil
		if b >= 32 and b <= 126 and b ~= 34 and b ~= 92 then
			out[i] = string.char(b)
		elseif nextDigit then
			out[i] = string.format("\\%03d", b)
		else
			out[i] = "\\" .. b
		end
	end
	return 'return "' .. table.concat(out) .. '"\n'
end

-- A small base64 decoder in plain Luau (what a Lune tool or a place without EncodingService
-- would need).
local DECODE = {}
for i = 1, 64 do
	DECODE[string.byte("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/", i)] = i - 1
end
local function luauBase64Decode(s: string): buffer
	local padding = if string.sub(s, -2) == "==" then 2 elseif string.sub(s, -1) == "=" then 1 else 0
	local out = buffer.create(#s // 4 * 3 - padding)
	local src = buffer.fromstring(s)
	local o = 0
	for i = 0, #s - 1, 4 do
		local a, b = DECODE[buffer.readu8(src, i)], DECODE[buffer.readu8(src, i + 1)]
		local c, d = DECODE[buffer.readu8(src, i + 2)] or 0, DECODE[buffer.readu8(src, i + 3)] or 0
		local n = bit32.bor(bit32.lshift(a, 18), bit32.lshift(b, 12), bit32.lshift(c, 6), d)
		buffer.writeu8(out, o, bit32.rshift(n, 16))
		if o + 1 < buffer.len(out) then
			buffer.writeu8(out, o + 1, bit32.band(bit32.rshift(n, 8), 255))
		end
		if o + 2 < buffer.len(out) then
			buffer.writeu8(out, o + 2, bit32.band(n, 255))
		end
		o += 3
	end
	return out
end

-- Bytes of `instance` in the binary place format, and a copy read back from those bytes.
local function saveAndLoad(instance: Instance): (number, Instance?)
	local ok, saved = pcall(SerializationService.SerializeInstancesAsync, SerializationService, { instance })
	if not ok then
		print(`[W] SerializeInstancesAsync: {saved}`)
		return -1, nil
	end
	local loaded = SerializationService:DeserializeInstancesAsync(saved)
	return buffer.len(saved), loaded[1]
end

local function stringValue(name: string, value: string): StringValue
	local v = Instance.new("StringValue")
	v.Name = name
	v.Value = value
	return v
end

local LIMIT = 200_000 -- StringValue.Value and ModuleScript.Source: must be shorter

-- `text` as StringValues named 1, 2, ... under a Folder, each under the limit.
local function chunked(text: string): Folder
	local folder = Instance.new("Folder")
	folder.Name = "Bake"
	for i = 1, #text, LIMIT - 1 do
		stringValue(tostring(i // (LIMIT - 1) + 1), string.sub(text, i, i + LIMIT - 2)).Parent = folder
	end
	return folder
end

local function unchunk(folder: Instance): string
	local parts = {}
	for i = 1, #folder:GetChildren() do
		parts[i] = ((folder :: any)[tostring(i)] :: StringValue).Value
	end
	return table.concat(parts)
end

local function probeLimits()
	for _, n in { 199_999, 200_000, 200_001, 1_000_000, 4_000_000 } do
		local s = string.rep("A", n)
		local ok, err = pcall(function()
			stringValue("Probe", s)
		end)
		local v = if ok then stringValue("Probe", s) else nil
		local size, loaded = -1, nil
		if v then
			size, loaded = saveAndLoad(v)
		end
		print(
			`[L] StringValue {n} chars | set {if ok then "ok" else err} | reads {if v then #v.Value else -1}`
				.. ` | after save+load {if loaded then #(loaded :: StringValue).Value else -1} | saved bytes {size}`
		)
	end
	local folder = Instance.new("Folder")
	local ok, err = pcall(folder.SetAttribute, folder, "Bake", buffer.create(8))
	print(`[L] buffer attribute | {if ok then "accepted: " .. typeof(folder:GetAttribute("Bake")) else err}`)
	local binary = string.rep("\0\255\128\1", 64)
	ok, err = pcall(folder.SetAttribute, folder, "Bake", binary)
	local _, loaded = saveAndLoad(folder)
	print(
		`[L] binary string attribute | set {if ok then "ok" else err} | equal {folder:GetAttribute("Bake") == binary}`
			.. ` | equal after save+load {loaded and loaded:GetAttribute("Bake") == binary}`
	)
	local bsv = Instance.new("BinaryStringValue")
	ok, err = pcall(function()
		(bsv :: any).Value = binary
	end)
	print(`[L] BinaryStringValue.Value | {if ok then "scriptable" else err}`)
end

local function measure(o: Options, name: string, data: buffer)
	local raw = buffer.tostring(data)
	local reps = o.Reps
	local deserializeMs = time(reps, function()
		return o.NavMesh.Deserialize(data)
	end)
	print(`[B] {name} | {#raw} bytes | Deserialize {string.format("%.2f", deserializeMs)} ms`)

	local function row(option: string, text: number, saved: number, loadMs: number, intact: boolean)
		print(
			`[R] {name} | {option} | {text} | {string.format("%.2f", text / #raw)} | {saved}`
				.. ` | {string.format("%.2f", loadMs)} | {if intact then "yes" else "NO"}`
		)
	end

	-- 1, 1b: a string literal in a ModuleScript; loading it is compile + run (a fresh module
	-- each rep, since require caches).
	for _, variant in { { "ModuleScript \\xNN", hexSource(raw) }, { "ModuleScript \\ddd", shortSource(raw) } } do
		local source = variant[2]
		if #source >= LIMIT then
			print(
				`[R] {name} | {variant[1]} | {#source} | {string.format("%.2f", #source / #raw)} | - | - | over the Source limit`
			)
			continue
		end
		local serial = 0
		local function module(): ModuleScript
			-- A unique trailing comment per rep, so Studio cannot reuse compiled bytecode.
			serial += 1
			local m = Instance.new("ModuleScript")
			m.Source = source .. "--" .. serial
			return m
		end
		local ms, result = time(reps, function(m)
			return buffer.fromstring(require(m) :: any)
		end, module)
		local saved, loaded = saveAndLoad(module())
		local intact = buffer.tostring(result) == raw
			and loaded ~= nil
			and string.sub((loaded :: ModuleScript).Source, 1, #source) == source
		row(variant[1], #source, saved, ms, intact)
	end

	-- 2: base64 in StringValues (chunked under the length limit), decoded by EncodingService
	-- and by plain Luau; 2c: zstd first.
	local compressMs, packed = time(reps, function()
		return EncodingService:CompressBuffer(data, ZSTD, 19)
	end)
	print(`[C] {name} | zstd level 19 | {buffer.len(packed)} bytes | {string.format("%.2f", compressMs)} ms`)
	for _, variant in
		{
			{ "StringValue base64 (EncodingService)", data, false, false },
			{ "StringValue base64 (Luau decoder)", data, false, true },
			{ "StringValue zstd+base64", packed, true, false },
		}
	do
		local text = buffer.tostring(EncodingService:Base64Encode(variant[2]))
		local saved, loaded = saveAndLoad(chunked(text))
		local ms, result = time(reps, function()
			local joined = unchunk(loaded :: Instance)
			local b = if variant[4]
				then luauBase64Decode(joined)
				else EncodingService:Base64Decode(buffer.fromstring(joined))
			return if variant[3] then EncodingService:DecompressBuffer(b, ZSTD) else b
		end)
		row(`{variant[1]} x{math.ceil(#text / (LIMIT - 1))}`, #text, saved, ms, buffer.tostring(result) == raw)
	end

	-- 3: the raw bytes (and zstd bytes) as a string attribute.
	for _, variant in
		{ { "attribute raw bytes", raw, false }, { "attribute zstd bytes", buffer.tostring(packed), true } }
	do
		local folder = Instance.new("Folder")
		folder:SetAttribute("Bake", variant[2])
		local bytes, copy = saveAndLoad(folder)
		ms, result = time(reps, function()
			local b = buffer.fromstring((copy :: Instance):GetAttribute("Bake") :: string)
			return if variant[3] then EncodingService:DecompressBuffer(b, ZSTD) else b
		end)
		row(variant[1], #variant[2], bytes, ms, buffer.tostring(result) == raw)
	end
end

return function(o: Options)
	probeLimits()
	local demo = o.NavMesh.Serialize(o.NavMesh.Build(o.Level.Desc))
	measure(o, "demo", demo)
	for _, scene in o.Scenes do
		if scene.Name == "bench" then
			measure(o, "bench", o.NavMesh.Serialize(o.NavMesh.Build(scene.Make())))
		end
	end
	print("[MARK] done")
end
