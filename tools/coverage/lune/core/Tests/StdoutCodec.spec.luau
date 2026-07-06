local StdoutCodec = require("../StdoutCodec")

-- Minimal base64 encoder (test-side counterpart of the codec's decoder).
local B64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
local function base64encode(s: string): string
	local out = {}
	for i = 1, #s, 3 do
		local a, b, c = string.byte(s, i, i + 2)
		local n = a * 65536 + (b or 0) * 256 + (c or 0)
		out[#out + 1] = B64:sub(n // 262144 % 64 + 1, n // 262144 % 64 + 1)
			.. B64:sub(n // 4096 % 64 + 1, n // 4096 % 64 + 1)
			.. (if b then B64:sub(n // 64 % 64 + 1, n // 64 % 64 + 1) else "=")
			.. (if c then B64:sub(n % 64 + 1, n % 64 + 1) else "=")
	end
	return table.concat(out)
end

-- Builds a v2 protocol block the way the Studio runner does.
local function chunksOf(b64: string, size: number): { string }
	local chunks = {}
	for i = 1, #b64, size do
		chunks[#chunks + 1] = b64:sub(i, i + size - 1)
	end
	return chunks
end

local function buildV2(json: string, chunkSize: number): string
	local b64 = base64encode(json)
	local chunks = chunksOf(b64, chunkSize)
	local lines = { `[[TM-COV-BEGIN v2 enc=base64 chunks={#chunks} bytes={#b64}]]` }
	for i, c in chunks do
		lines[#lines + 1] = `[[TM-COV {i}/{#chunks} len={#c}]]{c}`
	end
	lines[#lines + 1] = "[[TM-COV-END]]"
	return table.concat(lines, "\n")
end

local PAYLOAD = '{"hits":[1,0,2],"total":3,"map_sha":"cafe"}'
local EXPECTED = { hits = { 1, 0, 2 }, total = 3, map_sha = "cafe" }

return function(tiniest)
	local describe = tiniest.describe
	local test = tiniest.test
	local expect = tiniest.expect

	describe("StdoutCodec.decode", function()
		test("returns nil when no coverage block is present", function()
			expect(StdoutCodec.decode("test output\nall passed\n")).never_exists()
		end)

		test("decodes a v2 block split across chunks", function()
			local output = buildV2(PAYLOAD, 17)
			expect(StdoutCodec.decode(output)).is_deep_equal(EXPECTED)
		end)

		test("ignores noise lines interleaved with the protocol", function()
			local block = buildV2(PAYLOAD, 20)
			local noisy = "starting tests...\n" .. block:gsub("\n", "\nsome unrelated log line\n") .. "\ndone\n"
			expect(StdoutCodec.decode(noisy)).is_deep_equal(EXPECTED)
		end)

		test("reassembles chunks arriving out of order", function()
			local b64 = base64encode(PAYLOAD)
			local chunks = chunksOf(b64, 17)
			local lines = { `[[TM-COV-BEGIN v2 enc=base64 chunks={#chunks} bytes={#b64}]]` }
			for i = #chunks, 1, -1 do
				lines[#lines + 1] = `[[TM-COV {i}/{#chunks} len={#chunks[i]}]]{chunks[i]}`
			end
			lines[#lines + 1] = "[[TM-COV-END]]"
			expect(StdoutCodec.decode(table.concat(lines, "\n"))).is_deep_equal(EXPECTED)
		end)

		test("a missing chunk is reported by index", function()
			local output = buildV2(PAYLOAD, 20)
			local dropped = output:gsub("%[%[TM%-COV 2/%d+ [^\n]+\n", "")
			expect(function()
				StdoutCodec.decode(dropped)
			end).fails_with("missing chunk 2/")
		end)

		test("a clipped chunk is pinpointed via its len field", function()
			local b64 = base64encode(PAYLOAD)
			local chunks = chunksOf(b64, 17)
			local lines = { `[[TM-COV-BEGIN v2 enc=base64 chunks={#chunks} bytes={#b64}]]` }
			for i, c in chunks do
				-- Clip the tail of chunk 2 but keep its declared length.
				local body = if i == 2 then c:sub(1, #c - 5) else c
				lines[#lines + 1] = `[[TM-COV {i}/{#chunks} len={#c}]]{body}`
			end
			lines[#lines + 1] = "[[TM-COV-END]]"
			expect(function()
				StdoutCodec.decode(table.concat(lines, "\n"))
			end).fails_with(`chunk 2/{#chunks}`)
		end)

		test("a total byte mismatch without per-chunk lens is caught on reassembly", function()
			local output = `[[TM-COV-BEGIN v1 chunks=1 bytes=999]]\n[[TM-COV 1/1]]{PAYLOAD}\n[[TM-COV-END]]`
			expect(function()
				StdoutCodec.decode(output)
			end).fails_with("reassembled")
		end)

		test("decodes the v1 protocol (plain JSON, no per-chunk len)", function()
			local output = `[[TM-COV-BEGIN v1 chunks=1 bytes={#PAYLOAD}]]\n[[TM-COV 1/1]]{PAYLOAD}\n[[TM-COV-END]]`
			expect(StdoutCodec.decode(output)).is_deep_equal(EXPECTED)
		end)

		test("tolerates unpadded base64", function()
			-- Payload lengths 1 and 2 mod 3 normally get "=="/"=" padding; strip
			-- it so the decoder's short-final-group path runs.
			for _, json in { '{"k":1}', '{"k":12}' } do
				local b64 = base64encode(json):gsub("=", "")
				local output = table.concat({
					`[[TM-COV-BEGIN v2 enc=base64 chunks=1 bytes={#b64}]]`,
					`[[TM-COV 1/1 len={#b64}]]{b64}`,
					"[[TM-COV-END]]",
				}, "\n")
				local decoded = StdoutCodec.decode(output)
				expect(decoded.k).exists()
			end
		end)

		test("decodes when the BEGIN line omits the bytes field", function()
			local b64 = base64encode(PAYLOAD)
			local output = table.concat({
				"[[TM-COV-BEGIN v2 enc=base64 chunks=1]]",
				`[[TM-COV 1/1 len={#b64}]]{b64}`,
				"[[TM-COV-END]]",
			}, "\n")
			expect(StdoutCodec.decode(output)).is_deep_equal(EXPECTED)
		end)

		test("handles every base64 padding case", function()
			-- Payload lengths congruent to 2, 0 and 1 mod 3.
			for _, json in { '{"k":"abc"}', '{"k":"abcd"}', '{"k":"abcde"}' } do
				local decoded = StdoutCodec.decode(buildV2(json, 8))
				expect(decoded.k).is(json:match('"k":"(%w+)"'))
			end
		end)
	end)
end
