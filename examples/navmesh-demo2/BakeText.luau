--!strict
-- HAND-ROLLED (bake): the shipping recipe from the NavMesh.Serialize doc. The bake is base64 text
-- in StringValues `1`, `2`, ... (Rojo makes them from NavMeshBake/*.txt). Studio decodes with
-- EncodingService (and zstd when the bytes start with the frame magic); Lune has no base64, so
-- this module carries a plain Luau encoder and decoder for bake.luau and sim.luau.
local BakeText = {}

local ALPHABET = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
local DECODE = {}
for i = 1, 64 do
	DECODE[string.byte(ALPHABET, i)] = i - 1
end
local ZSTD_MAGIC = 0xFD2FB528
BakeText.CHUNK = 199_999 -- a script cannot set a StringValue of 200,000 characters or more

function BakeText.Encode(data: buffer): string
	local n = buffer.len(data)
	local out = table.create(n // 3 + 1)
	for i = 0, n - 1, 3 do
		local b = if i + 1 < n then buffer.readu8(data, i + 1) else 0
		local c = if i + 2 < n then buffer.readu8(data, i + 2) else 0
		local v = buffer.readu8(data, i) * 65536 + b * 256 + c
		local s = ""
		for k = 3, 0, -1 do
			local d = bit32.band(bit32.rshift(v, 6 * k), 63) + 1
			s ..= string.sub(ALPHABET, d, d)
		end
		table.insert(
			out,
			if i + 1 >= n then string.sub(s, 1, 2) .. "==" elseif i + 2 >= n then string.sub(s, 1, 3) .. "=" else s
		)
	end
	return table.concat(out)
end

local function decode(s: string): buffer
	local padding = if string.sub(s, -2) == "==" then 2 elseif string.sub(s, -1) == "=" then 1 else 0
	local out = buffer.create(#s // 4 * 3 - padding)
	local o = 0
	for i = 1, #s, 4 do
		local a, b, c, d = string.byte(s, i, i + 3)
		local v = DECODE[a] * 262144 + DECODE[b] * 4096 + (DECODE[c] or 0) * 64 + (DECODE[d] or 0)
		for k = 2, 0, -1 do
			if o < buffer.len(out) then
				buffer.writeu8(out, o, bit32.band(bit32.rshift(v, 8 * k), 255))
				o += 1
			end
		end
	end
	return out
end

-- The bake's bytes from its chunks, in order.
function BakeText.Load(chunks: { string }): buffer
	local text = table.concat(chunks)
	local ok, EncodingService = pcall(function()
		return (game :: any):GetService("EncodingService")
	end)
	if not ok then
		return decode(text) -- Lune: the files are plain base64
	end
	local data = EncodingService:Base64Decode(buffer.fromstring(text))
	if buffer.len(data) >= 4 and buffer.readu32(data, 0) == ZSTD_MAGIC then
		data = EncodingService:DecompressBuffer(data, Enum.CompressionAlgorithm.Zstd)
	end
	return data
end

-- The StringValues of a bake Folder (Studio), in order.
function BakeText.Chunks(folder: Instance): { string }
	local chunks = {}
	for i = 1, #folder:GetChildren() do
		table.insert(chunks, (folder:FindFirstChild(tostring(i)) :: StringValue).Value)
	end
	return chunks
end

return BakeText
