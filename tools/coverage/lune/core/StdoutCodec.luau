--!strict
--[=[
	@module core/StdoutCodec

	Decodes the chunked sentinel protocol the Studio coverage runner prints
	through run-in-roblox's stdout. The runner emits (protocol v2):

		[[TM-COV-BEGIN v2 enc=base64 chunks=N bytes=M]]
		[[TM-COV 1/N len=L]]<base64 slice>
		...
		[[TM-COV-END]]

	The body is base64 so every chunk is pure ASCII: HttpService:JSONEncode emits
	non-ASCII as raw multi-byte UTF-8, and byte-slicing the JSON could otherwise
	leave an invalid-UTF-8 fragment in a chunk that run-in-roblox (which
	re-JSONEncodes each captured log line) fails to ship. Each chunk carries its
	own byte length (`len=L`), so a clipped chunk is detected and pinpointed
	rather than only surfacing as a total-size mismatch. Everything outside the
	sentinel lines (test output, warnings) is ignored.
]=]

local serde = require("@lune/serde")

local StdoutCodec = {}

local B64_INDEX: { [string]: number } = {}
do
	local B64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
	for i = 1, 64 do
		B64_INDEX[string.sub(B64, i, i)] = i - 1
	end
end

local function base64decode(s: string): string
	local out: { string } = {}
	local i = 1
	local n = #s
	while i <= n do
		local d3 = string.sub(s, i + 2, i + 2)
		local d4 = string.sub(s, i + 3, i + 3)
		local c1 = B64_INDEX[string.sub(s, i, i)] or 0
		local c2 = B64_INDEX[string.sub(s, i + 1, i + 1)] or 0
		local c3 = B64_INDEX[d3] or 0
		local c4 = B64_INDEX[d4] or 0
		local num = c1 * 262144 + c2 * 4096 + c3 * 64 + c4
		out[#out + 1] = string.char((num // 65536) % 256)
		if d3 ~= "=" and d3 ~= "" then
			out[#out + 1] = string.char((num // 256) % 256)
		end
		if d4 ~= "=" and d4 ~= "" then
			out[#out + 1] = string.char(num % 256)
		end
		i += 4
	end
	return table.concat(out)
end

--[=[
	Extracts and JSON-decodes the coverage payload from captured stdout.
	Returns nil if no coverage block is present.
]=]
function StdoutCodec.decode(output: string): any?
	local total: number? = nil
	local byteLen: number? = nil
	local isBase64 = false
	local chunks: { [number]: string } = {}
	local chunkLens: { [number]: number } = {}

	for line in output:gmatch("[^\r\n]+") do
		local begin = line:match("^%[%[TM%-COV%-BEGIN (v[12].-)%]%]")
		if begin then
			local n = begin:match("chunks=(%d+)")
			local bytes = begin:match("bytes=(%d+)")
			total = tonumber(n)
			byteLen = tonumber(bytes)
			isBase64 = begin:find("enc=base64", 1, true) ~= nil
		end
		-- v2 chunks carry `len=L`; v1 chunks don't (len capture is optional).
		local idx, len, body = line:match("^%[%[TM%-COV (%d+)/%d+ len=(%d+)%]%](.*)$")
		if not idx then
			idx, body = line:match("^%[%[TM%-COV (%d+)/%d+%]%](.*)$")
		end
		if idx then
			local i = tonumber(idx) :: number
			chunks[i] = body
			if len then
				chunkLens[i] = tonumber(len) :: number
			end
		end
	end

	if total == nil then
		return nil
	end

	local parts: { string } = {}
	for i = 1, total do
		local part = chunks[i]
		if part == nil then
			error(`coverage output missing chunk {i}/{total} (dropped entirely by Studio output)`)
		end
		local expected = chunkLens[i]
		if expected ~= nil and #part ~= expected then
			error(
				`coverage output truncated: chunk {i}/{total} is {#part} bytes, expected {expected} `
					.. `(lost {expected - #part}; a single Studio output line was clipped)`
			)
		end
		table.insert(parts, part)
	end

	local body = table.concat(parts)
	if byteLen ~= nil and #body ~= byteLen then
		error(
			`coverage output truncated: reassembled {#body} bytes, expected {byteLen} `
				.. `(a chunk was clipped by Studio output; lower CHUNK in the runner)`
		)
	end

	local json = if isBase64 then base64decode(body) else body
	return serde.decode("json", json)
end

return StdoutCodec
