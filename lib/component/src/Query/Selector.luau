--!strict
-- Selector dialect: parser + lowering for the Component selector language, a
-- superset of Roblox's native `CollectionService:CreateCollection` grammar.
--
--   ClassName  #Name  .Tag  [Prop = v]  [$Attr = v]  [$Attr]  A > B  A >> B
--   :has(sel)  :not(compound)  group, group        (native subset)
--   [$Attr != v]  [$Attr >= n]  (> < <=)  [$Attr ~ "pat"]  [$Attr:typeof(t)]
--   float literals                                  (dialect extensions)
--
-- Each parsed group lowers to:
--   - seed terms (classes with IsA semantics, tags) for candidate sources;
--   - residual MatchSpecs on the existing Attr/Prop IR — the residuals carry
--     the COMPLETE match semantics (the fallback path has no native half);
--   - a native selector string that is the tightest sound SUPERSET the real
--     CreateCollection grammar can express (used as the tracking universe by
--     the native backend), plus `needsNative` for features the fallback
--     cannot evaluate (`>` / `>>` / `:has`).
--
-- Exactness rules (probed on engine 0.734): native attr equality is
-- type-COERCED (`[$X = 5]` matches the string "5"), so attr-eq terms are
-- superset-only and always pair with an exact-type residual; a `:not()` whose
-- inner form is not EXACTLY native-expressible is dropped from the native
-- form entirely (narrowing a :not's inner would shrink the outer set, which
-- is the unsound direction — dropping widens, which is safe).
--
-- Dialect semantics that differ from native on purpose:
--   - `[$X = "5"]` requires the STRING "5" (exact, not coerced);
--   - `[$X != v]` matches when the attribute is absent (v ~= nil);
--   - comparisons match numbers only; `~` matches strings only.
--
-- Parse results (including residual matcher closures) are cached per
-- canonical form, so equivalent spellings share closure identities and
-- structurally equal queries keep interning into one engine.
-- ponytail: cache is unbounded; selectors are small interned strings, revisit
-- only if someone generates unbounded distinct selector text at runtime.
-- Authors: Logan Hunt [Raildex]

const Types = require(script.Parent.Types)

type MatchSpec = Types.MatchSpec
type Matcher = Types.Matcher

const Selector = {}

--------------------------------------------------------------------------------
-- AST types
--------------------------------------------------------------------------------

export type BracketOp = "exists" | "=" | "!=" | ">" | ">=" | "<" | "<=" | "~" | "typeof"

export type ParsedBracket = {
	attr: boolean, -- [$Attr ...] vs [Prop ...]
	name: string,
	op: BracketOp,
	value: unknown?, -- string | number | boolean | nil (exists/typeof)
	typeName: string?, -- typeof only
}

export type ParsedCompound = {
	classes: { string },
	names: { string },
	tags: { string },
	brackets: { ParsedBracket },
	nots: { ParsedCompound },
	has: { string }, -- normalized inner selectors (native-only)
}

export type LoweredCompound = {
	classes: { string },
	tags: { string },
	attrs: { MatchSpec },
	props: { MatchSpec },
}

export type ParsedGroup = {
	-- Hops in document order; the LAST compound is the subject. Entries before
	-- it carry the combinator that links them to the next hop.
	hops: { { combinator: (">" | ">>")?, compound: ParsedCompound } },
	subject: ParsedCompound,
	needsNative: boolean,
	nativeSelector: string?, -- tightest sound superset, nil when inexpressible
	lowered: LoweredCompound, -- subject only (ancestor hops are native-only)
	loweredNots: { LoweredCompound },
}

export type ParseResult = {
	normalized: string,
	groups: { ParsedGroup },
	needsNative: boolean,
	nativeSelector: string?, -- comma-join of group natives, nil if any group is nil
}

--------------------------------------------------------------------------------
-- Scanner / recursive-descent parser
--------------------------------------------------------------------------------

type Parser = { s: string, pos: number }

const function parseError(p: Parser, message: string): never
	error(`[Component] Selector parse error at position {p.pos}: {message}`, 0)
end

const function skipWs(p: Parser)
	const nextPos = string.find(p.s, "%S", p.pos)
	p.pos = nextPos or #p.s + 1
end

const function peek(p: Parser): string
	return string.sub(p.s, p.pos, p.pos)
end

const function tryConsume(p: Parser, token: string): boolean
	if string.sub(p.s, p.pos, p.pos + #token - 1) == token then
		p.pos += #token
		return true
	end
	return false
end

const function ident(p: Parser): string?
	const match = string.match(p.s, "^[%a_][%w_]*", p.pos)
	if match then
		p.pos += #match
	end
	return match
end

const function quotedString(p: Parser): string?
	const quote = peek(p)
	if quote ~= '"' and quote ~= "'" then
		return nil
	end
	local out = ""
	local i = p.pos + 1
	while i <= #p.s do
		const ch = string.sub(p.s, i, i)
		if ch == "\\" then
			out ..= string.sub(p.s, i + 1, i + 1)
			i += 2
		elseif ch == quote then
			p.pos = i + 1
			return out
		else
			out ..= ch
			i += 1
		end
	end
	return parseError(p, `unterminated string (missing closing {quote})`)
end

-- value := quoted | number | true | false | bare-ident
const function bracketValue(p: Parser): (unknown, boolean)
	const str = quotedString(p)
	if str ~= nil then
		return str, true -- was-quoted (strings normalize to quoted form)
	end
	const num = string.match(p.s, "^%-?%d+%.?%d*", p.pos)
	if num then
		p.pos += #num
		const parsed = tonumber(num)
		if parsed == nil then
			parseError(p, `malformed number literal '{num}'`)
		end
		return parsed, false
	end
	const word = ident(p)
	if word == nil then
		parseError(p, "expected a value (string, number, boolean, or name)")
		error("unreachable")
	end
	if word == "true" then
		return true, false
	elseif word == "false" then
		return false, false
	end
	return word, false -- bare word: a string value
end

const BRACKET_OPS: { string } = { "!=", ">=", "<=", "=", ">", "<", "~" } -- two-char first

-- bracket := ["$"] ident [ op value | ":typeof(" ident ")" ]  "]"
const function parseBracket(p: Parser): ParsedBracket
	skipWs(p)
	const isAttr = tryConsume(p, "$")
	const name = ident(p)
	if name == nil then
		return parseError(p, "expected an attribute or property name inside [ ]")
	end
	skipWs(p)

	local op: BracketOp = "exists"
	local value: unknown? = nil
	local typeName: string? = nil

	if tryConsume(p, ":") then
		if not tryConsume(p, "typeof") or not tryConsume(p, "(") then
			return parseError(p, "expected typeof(...) after ':' in a filter")
		end
		skipWs(p)
		typeName = ident(p)
		if typeName == nil then
			return parseError(p, "expected a type name inside :typeof( )")
		end
		skipWs(p)
		if not tryConsume(p, ")") then
			return parseError(p, "expected ')' to close :typeof(")
		end
		op = "typeof"
	else
		for _, candidate in BRACKET_OPS do
			if tryConsume(p, candidate) then
				op = candidate :: BracketOp
				break
			end
		end
		if op ~= "exists" then
			skipWs(p)
			value = bracketValue(p)
			if op == "~" and type(value) ~= "string" then
				return parseError(p, "the ~ operator expects a quoted Lua pattern string")
			end
			if op == "~" then
				-- Compile-check the pattern now so a bad pattern fails at build
				-- time, not inside a pcall'd matcher at runtime.
				const pattern = value :: string
				const ok = pcall(function()
					return string.match("", pattern)
				end)
				if not ok then
					return parseError(p, `invalid Lua pattern '{value}'`)
				end
			end
			if (op == ">" or op == ">=" or op == "<" or op == "<=") and type(value) ~= "number" then
				return parseError(p, `the {op} operator expects a number literal`)
			end
		end
	end

	skipWs(p)
	if not tryConsume(p, "]") then
		return parseError(p, "Expected ']' to complete a property filter")
	end
	return { attr = isAttr, name = name, op = op, value = value, typeName = typeName }
end

local parseSelectorInner: (p: Parser) -> { { hops: { { combinator: (">" | ">>")?, compound: ParsedCompound } } } }

-- compound := term+  (whitespace between terms is AND, mirroring native)
const function parseCompound(p: Parser, context: string): ParsedCompound
	const compound: ParsedCompound = { classes = {}, names = {}, tags = {}, brackets = {}, nots = {}, has = {} }
	local sawTerm = false
	while true do
		skipWs(p)
		const ch = peek(p)
		if ch == "#" then
			p.pos += 1
			const name = ident(p)
			if name == nil then
				return parseError(p, "expected a name after '#'")
			end
			table.insert(compound.names, name)
		elseif ch == "." then
			p.pos += 1
			const tag = ident(p)
			if tag == nil then
				return parseError(p, "expected a tag after '.'")
			end
			table.insert(compound.tags, tag)
		elseif ch == "[" then
			p.pos += 1
			table.insert(compound.brackets, parseBracket(p))
		elseif ch == ":" then
			p.pos += 1
			const pseudo = ident(p)
			if pseudo ~= "has" and pseudo ~= "not" then
				return parseError(p, `unknown pseudo-class ':{pseudo or "?"}' (expected :has or :not)`)
			end
			skipWs(p)
			if not tryConsume(p, "(") then
				return parseError(p, `expected '(' after :{pseudo}`)
			end
			if pseudo == "not" then
				-- Dialect restriction: :not takes one compound (no combinators,
				-- commas, or nesting) so the fallback can lower it to negatives.
				const inner = parseCompound(p, ":not")
				skipWs(p)
				if not tryConsume(p, ")") then
					return parseError(p, "combinators, commas, and nesting are not supported inside :not(...)")
				end
				table.insert(compound.nots, inner)
			else
				const groups = parseSelectorInner(p)
				skipWs(p)
				if not tryConsume(p, ")") then
					return parseError(p, "expected ')' to close :has(")
				end
				-- Store normalized inner text; :has is native-only either way.
				table.insert(compound.has, Selector._printGroups(groups))
			end
		else
			const class = ident(p)
			if class == nil then
				break
			end
			table.insert(compound.classes, class)
		end
		sawTerm = true
		-- Terms may be flush against each other (`Part.Tag[$X]`); whitespace
		-- before the next term is fine too, but a following combinator, comma,
		-- or `)` ends this compound (handled by the caller's lookahead).
		const nextCh = string.match(p.s, "^%s*([>,%)])", p.pos)
		if nextCh ~= nil then
			break
		end
	end
	if not sawTerm then
		return parseError(p, `Expected at least one filter{if context ~= "" then ` in {context}` else ""}`)
	end
	return compound
end

-- group := compound { (">" | ">>") compound }
const function parseGroup(p: Parser): { hops: { { combinator: (">" | ">>")?, compound: ParsedCompound } } }
	const hops: { { combinator: (">" | ">>")?, compound: ParsedCompound } } = {}
	local pending: (">" | ">>")? = nil
	while true do
		const compound = parseCompound(p, "")
		table.insert(hops, { combinator = pending, compound = compound })
		skipWs(p)
		if tryConsume(p, ">>") then
			pending = ">>"
		elseif tryConsume(p, ">") then
			pending = ">"
		else
			break
		end
	end
	return { hops = hops }
end

function parseSelectorInner(p: Parser)
	const groups = {}
	while true do
		skipWs(p)
		table.insert(groups, parseGroup(p))
		skipWs(p)
		if not tryConsume(p, ",") then
			break
		end
	end
	return groups
end

--------------------------------------------------------------------------------
-- Canonical printing (normalization)
--------------------------------------------------------------------------------

const function printValue(value: unknown): string
	if type(value) == "string" then
		return `"{string.gsub(string.gsub(value, "\\", "\\\\"), '"', '\\"')}"`
	end
	return tostring(value)
end

const function printBracket(b: ParsedBracket): string
	const prefix = if b.attr then "$" else ""
	if b.op == "exists" then
		return `[{prefix}{b.name}]`
	elseif b.op == "typeof" then
		return `[{prefix}{b.name}:typeof({b.typeName})]`
	end
	return `[{prefix}{b.name} {b.op} {printValue(b.value)}]`
end

const function printCompound(c: ParsedCompound): string
	const parts: { string } = {}
	const classes = table.clone(c.classes)
	table.sort(classes)
	for _, class in classes do
		table.insert(parts, class)
	end
	const names = table.clone(c.names)
	table.sort(names)
	for _, name in names do
		table.insert(parts, "#" .. name)
	end
	const tags = table.clone(c.tags)
	table.sort(tags)
	for _, tag in tags do
		table.insert(parts, "." .. tag)
	end
	const brackets = {}
	for _, b in c.brackets do
		table.insert(brackets, printBracket(b))
	end
	table.sort(brackets)
	for _, b in brackets do
		table.insert(parts, b)
	end
	const has = table.clone(c.has)
	table.sort(has)
	for _, inner in has do
		table.insert(parts, `:has({inner})`)
	end
	const nots = {}
	for _, inner in c.nots do
		table.insert(nots, `:not({printCompound(inner)})`)
	end
	table.sort(nots)
	for _, n in nots do
		table.insert(parts, n)
	end
	return table.concat(parts)
end

const function printGroup(group: { hops: { { combinator: (">" | ">>")?, compound: ParsedCompound } } }): string
	const parts: { string } = {}
	for _, hop in group.hops do
		if hop.combinator ~= nil then
			table.insert(parts, ` {hop.combinator} `)
		end
		table.insert(parts, printCompound(hop.compound))
	end
	return table.concat(parts)
end

-- Also used by :has normalization mid-parse.
function Selector._printGroups(groups: { { hops: { { combinator: (">" | ">>")?, compound: ParsedCompound } } } }): string
	const printed = {}
	for _, group in groups do
		table.insert(printed, printGroup(group))
	end
	table.sort(printed) -- comma groups are a commutative OR
	return table.concat(printed, ", ")
end

--------------------------------------------------------------------------------
-- Lowering: residual MatchSpecs (complete semantics for the fallback path)
--------------------------------------------------------------------------------

const function specOf(name: string, ...: Matcher): MatchSpec
	const count = select("#", ...)
	return {
		name = name,
		exists = count == 0,
		matchers = table.pack(...) :: { Matcher },
		count = count,
	}
end

-- Property equality must be enum-aware: `[Material = "Neon"]` matches the
-- EnumItem by name (probed native behavior), and our residual mirrors it.
const function propEqMatcher(literal: unknown): Matcher
	if type(literal) ~= "string" then
		return literal -- number/bool: plain exact equality
	end
	return function(_instance: Instance, value: unknown): boolean
		return value == literal or (typeof(value) == "EnumItem" and (value :: EnumItem).Name == literal)
	end
end

const function bracketMatcher(b: ParsedBracket): Matcher?
	const op = b.op
	if op == "exists" then
		return nil -- 0-matcher spec = existence
	elseif op == "=" then
		return if b.attr then b.value else propEqMatcher(b.value)
	elseif op == "!=" then
		const literal = b.value
		if b.attr or type(literal) ~= "string" then
			return function(_instance: Instance, value: unknown): boolean
				return value ~= literal
			end
		end
		return function(_instance: Instance, value: unknown): boolean
			return value ~= literal and not (typeof(value) == "EnumItem" and (value :: EnumItem).Name == literal)
		end
	elseif op == "~" then
		const pattern = b.value :: string
		return function(_instance: Instance, value: unknown): boolean
			return type(value) == "string" and string.match(value, pattern) ~= nil
		end
	elseif op == "typeof" then
		const typeName = b.typeName
		return function(_instance: Instance, value: unknown): boolean
			return typeof(value) == typeName
		end
	end
	-- Numeric comparisons (numbers only, by design).
	const bound = b.value :: number
	if op == ">" then
		return function(_instance: Instance, value: unknown): boolean
			return type(value) == "number" and value > bound
		end
	elseif op == ">=" then
		return function(_instance: Instance, value: unknown): boolean
			return type(value) == "number" and value >= bound
		end
	elseif op == "<" then
		return function(_instance: Instance, value: unknown): boolean
			return type(value) == "number" and value < bound
		end
	else -- "<="
		return function(_instance: Instance, value: unknown): boolean
			return type(value) == "number" and value <= bound
		end
	end
end

--[=[
	Lowers one compound to seed terms + residual MatchSpecs carrying the
	complete dialect semantics. Exposed so callers can lower `:not(...)` inner
	compounds with the same rules.
]=]
function Selector.lowerCompound(c: ParsedCompound): LoweredCompound
	const attrs: { MatchSpec } = {}
	const props: { MatchSpec } = {}
	for _, name in c.names do
		table.insert(props, specOf("Name", name))
	end
	for _, b in c.brackets do
		const matcher = bracketMatcher(b)
		const spec = if matcher == nil then specOf(b.name) else specOf(b.name, matcher)
		table.insert(if b.attr then attrs else props, spec)
	end
	return {
		classes = table.clone(c.classes),
		tags = table.clone(c.tags),
		attrs = attrs,
		props = props,
	}
end

--------------------------------------------------------------------------------
-- Native superset form
--------------------------------------------------------------------------------

-- Native term for one bracket: (term, isExact). nil term = dropped (widen).
-- Rows per the probed grammar matrix (engine 0.734).
const function nativeBracket(b: ParsedBracket): (string?, boolean)
	const prefix = if b.attr then "$" else ""
	if b.op == "exists" then
		return `[{prefix}{b.name}]`, true
	end
	if b.op ~= "=" then
		-- Comparisons/pattern/typeof are dialect-only: widen to existence for
		-- attrs (sound superset); properties always exist per-class, so a bare
		-- existence check adds nothing — drop the term.
		return if b.attr then `[${b.name}]` else nil, false
	end
	const value = b.value
	if b.attr then
		-- Native attr equality is type-coerced: usable as a superset only, and
		-- float literals do not parse natively.
		if type(value) == "number" and value % 1 ~= 0 then
			return `[${b.name}]`, false
		end
		return `[${b.name} = {printValue(value)}]`, false
	end
	-- Properties: bool/string/enum-name literals are native and exact
	-- (enum-name matching is identical to our residual); numbers are not
	-- (floats rejected, integers unproven — conservative drop).
	if type(value) == "boolean" or type(value) == "string" then
		return `[{b.name} = {printValue(value)}]`, true
	end
	return nil, false
end

-- Native form of a compound: (selector?, isExact). nil = no native term at
-- all (native has no universal selector, so an empty compound is
-- inexpressible even as a superset).
const function nativeCompound(c: ParsedCompound): (string?, boolean)
	const parts: { string } = {}
	local exact = true
	for _, class in c.classes do
		table.insert(parts, class)
	end
	for _, name in c.names do
		table.insert(parts, "#" .. name)
	end
	for _, tag in c.tags do
		table.insert(parts, "." .. tag)
	end
	for _, b in c.brackets do
		const term, termExact = nativeBracket(b)
		if term ~= nil then
			table.insert(parts, term)
		end
		if term == nil or not termExact then
			exact = false
		end
	end
	for _, inner in c.has do
		-- :has of a superset is a superset — sound to keep, but not exact.
		table.insert(parts, `:has({inner})`)
		exact = false
	end
	for _, innerNot in c.nots do
		-- :not is only sound in the native form when its inner is EXACT
		-- (widening a :not's inner shrinks the outer set). Otherwise drop.
		const innerNative, innerExact = nativeCompound(innerNot)
		if innerNative ~= nil and innerExact then
			table.insert(parts, `:not({innerNative})`)
		else
			exact = false
		end
	end
	if #parts == 0 then
		return nil, false
	end
	return table.concat(parts), exact
end

const function nativeGroup(group: { hops: { { combinator: (">" | ">>")?, compound: ParsedCompound } } }): string?
	const parts: { string } = {}
	for _, hop in group.hops do
		const native = nativeCompound(hop.compound)
		if native == nil then
			return nil
		end
		if hop.combinator ~= nil then
			table.insert(parts, ` {hop.combinator} `)
		end
		table.insert(parts, native)
	end
	return table.concat(parts)
end

--------------------------------------------------------------------------------
-- Public entry
--------------------------------------------------------------------------------

const resultCache: { [string]: ParseResult } = {}

--[=[
	@within Query
	@function ParseSelector
	@param selector string
	@return ParseResult

	Parses a Component selector-dialect string, erroring on invalid syntax.
	Results are cached per canonical form: equivalent spellings return the SAME
	result table (and therefore share residual matcher identities, which keeps
	structurally equal queries interning into one engine).
]=]
function Selector.parse(selector: string): ParseResult
	assert(type(selector) == "string", "[Component] selector must be a string")
	const direct = resultCache[selector]
	if direct ~= nil then
		return direct
	end

	const p: Parser = { s = selector, pos = 1 }
	skipWs(p)
	if p.pos > #p.s then
		error("[Component] Selector parse error: Expected at least one filter", 0)
	end
	const rawGroups = parseSelectorInner(p)
	skipWs(p)
	if p.pos <= #p.s then
		parseError(p, `unexpected '{peek(p)}'`)
	end

	const normalized = Selector._printGroups(rawGroups)
	const cached = resultCache[normalized]
	if cached ~= nil then
		resultCache[selector] = cached
		return cached
	end

	const groups: { ParsedGroup } = {}
	local anyNeedsNative = false
	local allNative: boolean = true
	for _, raw in rawGroups do
		const subject = raw.hops[#raw.hops].compound
		const needsNative = #raw.hops > 1 or #subject.has > 0
		const native = nativeGroup(raw)
		const loweredNots = {}
		for _, innerNot in subject.nots do
			table.insert(loweredNots, Selector.lowerCompound(innerNot))
		end
		if needsNative then
			anyNeedsNative = true
		end
		if native == nil then
			allNative = false
		end
		table.insert(groups, {
			hops = raw.hops,
			subject = subject,
			needsNative = needsNative,
			nativeSelector = native,
			lowered = Selector.lowerCompound(subject),
			loweredNots = loweredNots,
		})
	end

	const nativeParts: { string } = {}
	if allNative then
		for _, group in groups do
			table.insert(nativeParts, group.nativeSelector :: string)
		end
	end

	const result: ParseResult = {
		normalized = normalized,
		groups = groups,
		needsNative = anyNeedsNative,
		nativeSelector = if allNative then table.concat(nativeParts, ", ") else nil,
	}
	resultCache[normalized] = result
	resultCache[selector] = result
	return result
end

return Selector
