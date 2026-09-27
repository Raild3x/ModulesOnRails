--!strict
-- Authors: Logan Hunt (Raildex)
-- September 27, 2026
--[=[
	@class LuauLiteral
	@private

	Prints plain data as a Luau table literal, and parses that literal back. The editor's
	`ExportSource` and import use it.

	Supported values: nil, booleans, numbers, strings, vectors (`vector.create`, and
	`Vector3.new` on input), and tables of those. Numbers print so they parse back exactly,
	including `math.huge`, `-0` and NaN (`0/0`). Dictionary keys print sorted, so the same
	data always prints the same text. Functions, other userdata and cycles are errors.

	`Parse` reads only this literal grammar, so it works where `loadstring` is unavailable
	(a client).
]=]

local LuauLiteral = {}

local INDENT = "\t"
local INLINE_WIDTH = 100 -- a table of plain values prints on one line up to this width

local RESERVED = {}
for _, word in
	string.split(
		"and break do else elseif end false for function if in local nil not or repeat return then true until while",
		" "
	)
do
	RESERVED[word] = true
end

local function formatNumber(n: number): string
	if n ~= n then
		return "0/0"
	elseif n == math.huge then
		return "math.huge"
	elseif n == -math.huge then
		return "-math.huge"
	end
	-- Luau's tostring is the shortest text that reads back exactly. string.format is not a
	-- fallback everywhere: Roblox's flushes subnormals such as 5e-324 to 0.
	local text = tostring(n)
	if tonumber(text) == n then
		return text
	end
	return string.format("%.17g", n)
end

local ESCAPES = { ["\n"] = "\\n", ["\r"] = "\\r", ["\t"] = "\\t", ['"'] = '\\"', ["\\"] = "\\\\" }

local function formatString(s: string): string
	return '"'
		.. string.gsub(s, '[%c"\\]', function(c: string): string
			return ESCAPES[c] or string.format("\\%03d", string.byte(c))
		end)
		.. '"'
end

local function isVector(value: any): boolean
	local kind = typeof(value)
	return kind == "vector" or kind == "Vector3"
end

local function formatKey(key: any): string
	if type(key) == "string" and string.match(key, "^[%a_][%w_]*$") and not RESERVED[key] then
		return key
	elseif type(key) == "string" then
		return `[{formatString(key)}]`
	elseif type(key) == "number" then
		return `[{formatNumber(key)}]`
	elseif type(key) == "boolean" then
		return `[{tostring(key)}]`
	end
	error(`LuauLiteral.Print: a {typeof(key)} cannot be a key`, 0)
end

-- Orders dictionary keys: booleans, then numbers, then strings, each ascending.
local KEY_RANK = { boolean = 1, number = 2, string = 3 }
local function keyLess(a: any, b: any): boolean
	local ra, rb = KEY_RANK[type(a)] or 4, KEY_RANK[type(b)] or 4
	if ra ~= rb then
		return ra < rb
	elseif type(a) == "boolean" then
		return not a and b
	end
	return a < b
end

local function printValue(value: any, depth: number, path: string, seen: { [any]: boolean }): string
	local kind = type(value)
	if kind == "nil" or kind == "boolean" then
		return tostring(value)
	elseif kind == "number" then
		return formatNumber(value)
	elseif kind == "string" then
		return formatString(value)
	elseif isVector(value) then
		return `vector.create({formatNumber(value.X)}, {formatNumber(value.Y)}, {formatNumber(value.Z)})`
	elseif kind ~= "table" then
		error(`LuauLiteral.Print: cannot print a {typeof(value)} at {path}`, 0)
	end
	if seen[value] then
		error(`LuauLiteral.Print: cycle at {path}`, 0)
	end
	seen[value] = true

	-- The array part first (1..n, in order), then the other keys sorted.
	local count = #value
	local keys = {}
	for key in value do
		if not (type(key) == "number" and key >= 1 and key <= count and key % 1 == 0) then
			table.insert(keys, key)
		end
	end
	table.sort(keys, keyLess)

	local entries = table.create(count + #keys)
	local nested = false
	for i = 1, count do
		local item = value[i]
		nested = nested or (type(item) == "table" and next(item) ~= nil)
		table.insert(entries, printValue(item, depth + 1, `{path}[{i}]`, seen))
	end
	for _, key in keys do
		local item = value[key]
		nested = nested or (type(item) == "table" and next(item) ~= nil)
		table.insert(entries, `{formatKey(key)} = {printValue(item, depth + 1, `{path}.{tostring(key)}`, seen)}`)
	end
	seen[value] = nil

	if #entries == 0 then
		return "{}"
	end
	local inline = `\{ {table.concat(entries, ", ")} }`
	if not nested and #inline <= INLINE_WIDTH then
		return inline
	end
	local pad = string.rep(INDENT, depth + 1)
	local lines = {}
	if nested or #keys > 0 then
		for _, entry in entries do
			table.insert(lines, pad .. entry .. ",")
		end
	else
		-- A long list of plain values (such as CDT Coords): wrap it at the inline width.
		local line = ""
		for _, entry in entries do
			if line ~= "" and #pad + #line + #entry + 2 > INLINE_WIDTH then
				table.insert(lines, pad .. line)
				line = ""
			end
			line ..= (if line == "" then "" else " ") .. entry .. ","
		end
		table.insert(lines, pad .. line)
	end
	return "{\n" .. table.concat(lines, "\n") .. "\n" .. string.rep(INDENT, depth) .. "}"
end

--[=[
	@within LuauLiteral
	Prints `value` as a Luau literal. Errors on a function, userdata other than a vector, or a
	cycle.
]=]
function LuauLiteral.Print(value: any): string
	return printValue(value, 0, "value", {})
end

-- Parser -----------------------------------------------------------------------------------

type Parser = { Source: string, Pos: number }

local function fail(p: Parser, message: string): never
	local line = select(2, string.gsub(string.sub(p.Source, 1, p.Pos), "\n", "")) + 1
	error(`LuauLiteral.Parse: {message} at line {line}`, 0)
end

local function skip(p: Parser)
	while true do
		local _, stop = string.find(p.Source, "^%s+", p.Pos)
		if stop then
			p.Pos = stop + 1
		end
		if string.sub(p.Source, p.Pos, p.Pos + 1) ~= "--" then
			return
		end
		local newline = string.find(p.Source, "\n", p.Pos, true)
		p.Pos = if newline then newline + 1 else #p.Source + 1
	end
end

local function accept(p: Parser, token: string): boolean
	skip(p)
	if string.sub(p.Source, p.Pos, p.Pos + #token - 1) == token then
		p.Pos += #token
		return true
	end
	return false
end

local function expect(p: Parser, token: string)
	if not accept(p, token) then
		fail(p, `expected '{token}'`)
	end
end

local function name(p: Parser): string?
	skip(p)
	local word = string.match(p.Source, "^[%a_][%w_]*", p.Pos)
	return word
end

local ESCAPE_CHARS = {
	n = "\n",
	t = "\t",
	r = "\r",
	a = "\a",
	b = "\b",
	f = "\f",
	v = "\v",
	["\\"] = "\\",
	['"'] = '"',
	["'"] = "'",
	["\n"] = "\n",
}

local function parseString(p: Parser): string
	local quote = string.sub(p.Source, p.Pos, p.Pos)
	p.Pos += 1
	local out = {}
	while true do
		local c = string.sub(p.Source, p.Pos, p.Pos)
		if c == "" or c == "\n" then
			fail(p, "unfinished string")
		elseif c == quote then
			p.Pos += 1
			return table.concat(out)
		elseif c == "\\" then
			local e = string.sub(p.Source, p.Pos + 1, p.Pos + 1)
			local digits = string.match(p.Source, "^%d%d?%d?", p.Pos + 1)
			local hex = string.match(p.Source, "^x(%x%x)", p.Pos + 1)
			if digits then
				table.insert(out, string.char(tonumber(digits) :: number))
				p.Pos += 1 + #digits
			elseif hex then
				table.insert(out, string.char(tonumber(hex, 16) :: number))
				p.Pos += 4
			elseif ESCAPE_CHARS[e] then
				table.insert(out, ESCAPE_CHARS[e])
				p.Pos += 2
			else
				fail(p, `unknown escape '\\{e}'`)
			end
		else
			table.insert(out, c)
			p.Pos += 1
		end
	end
end

local function parseNumber(p: Parser): number
	skip(p)
	local text = string.match(p.Source, "^%d*%.?%d+[eE][%+%-]?%d+", p.Pos)
		or string.match(p.Source, "^%d+%.?%d*", p.Pos)
		or string.match(p.Source, "^%.%d+", p.Pos)
	local n = text and tonumber(text)
	if n == nil then
		fail(p, "expected a number")
	end
	p.Pos += #(text :: string)
	return n :: number
end

local parseValue: (p: Parser) -> any

-- `vector.create(x, y, z)` / `Vector3.new(x, y, z)` after its name.
local function parseVector(p: Parser): any
	expect(p, "(")
	local x = parseValue(p)
	expect(p, ",")
	local y = parseValue(p)
	expect(p, ",")
	local z = parseValue(p)
	expect(p, ")")
	if type(x) ~= "number" or type(y) ~= "number" or type(z) ~= "number" then
		fail(p, "a vector takes three numbers")
	end
	return vector.create(x, y, z)
end

local function parseTable(p: Parser): { [any]: any }
	local out = {}
	local count = 0
	while not accept(p, "}") do
		if accept(p, "[") then
			local key = parseValue(p)
			expect(p, "]")
			expect(p, "=")
			if key == nil or key ~= key then
				fail(p, "a key cannot be nil or NaN")
			end
			out[key] = parseValue(p)
		else
			local word = name(p)
			local afterName = if word then string.match(p.Source, "^%s*=[^=]", p.Pos + #word) else nil
			if word and afterName and not RESERVED[word] then
				p.Pos += #word
				expect(p, "=")
				out[word] = parseValue(p)
			else
				count += 1
				out[count] = parseValue(p)
			end
		end
		if not accept(p, ",") and not accept(p, ";") then
			expect(p, "}")
			break
		end
	end
	return out
end

function parseValue(p: Parser): any
	skip(p)
	local c = string.sub(p.Source, p.Pos, p.Pos)
	local value: any
	if c == "{" then
		p.Pos += 1
		value = parseTable(p)
	elseif c == '"' or c == "'" then
		value = parseString(p)
	elseif c == "-" then
		p.Pos += 1
		local negated = parseValue(p)
		if type(negated) ~= "number" then
			fail(p, "'-' needs a number")
		end
		return -negated
	elseif string.match(c, "[%d%.]") then
		value = parseNumber(p)
		if accept(p, "/") then
			value /= parseNumber(p)
		end
	else
		local word = name(p)
		if word == nil then
			fail(p, `unexpected '{c}'`)
		end
		p.Pos += #(word :: string)
		if word == "true" or word == "false" then
			value = word == "true"
		elseif word == "nil" then
			value = nil
		elseif word == "math" and accept(p, ".") and accept(p, "huge") then
			value = math.huge
		elseif
			(word == "vector" and accept(p, ".") and accept(p, "create"))
			or (word == "Vector3" and accept(p, ".") and accept(p, "new"))
		then
			value = parseVector(p)
		else
			fail(p, `unexpected '{word}'`)
		end
	end
	return value
end

--[=[
	@within LuauLiteral
	Parses a literal printed by `Print` (an optional leading `return` is allowed). Errors,
	naming the line, on anything outside that grammar.
]=]
function LuauLiteral.Parse(source: string): any
	local p: Parser = { Source = source, Pos = 1 }
	local word = name(p)
	if word == "return" then
		p.Pos += #word
	end
	local value = parseValue(p)
	skip(p)
	if p.Pos <= #source then
		fail(p, "unexpected text after the value")
	end
	return value
end

return LuauLiteral
