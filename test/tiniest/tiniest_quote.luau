-- From dphfox/tiniest, licensed under BSD
--!strict

type SeenTables = { [table]: number }
type QuoteState = {
	seen: SeenTables,
	nextId: number,
}

local function tiniest_quote_internal(x: unknown, given_indent_amount: number?, state: QuoteState): string
	if type(x) == "nil" or type(x) == "number" or type(x) == "boolean" or type(x) == "userdata" then
		return tostring(x)
	elseif type(x) == "string" then
		return string.format("%q", x)
	elseif type(x) == "function" then
		return "function() ... end"
	elseif type(x) == "table" then
		local tbl: {} = x :: any
		local existingId = state.seen[tbl]
		if existingId ~= nil then
			return `<cycle:table#{existingId}>`
		end

		local tableId = state.nextId
		state.nextId += 1
		state.seen[tbl] = tableId

		local outer_indent_amount = given_indent_amount or 0
		local inner_indent_amount = outer_indent_amount + 1
		local outer_indent = string.rep("  ", outer_indent_amount)
		local inner_indent = string.rep("  ", inner_indent_amount)

		local sorted_pairs = {}
		for key, value in tbl do
			table.insert(sorted_pairs, {
				key = tiniest_quote_internal(key, inner_indent_amount, state),
				value = tiniest_quote_internal(value, inner_indent_amount, state),
			})
		end
		table.sort(sorted_pairs, function(a, b)
			return a.key < b.key
		end)
		local frozen = table.isfrozen(tbl)
		local lines = { if frozen then "table.freeze {" else "{" }
		for _, pair in sorted_pairs do
			table.insert(lines, `{inner_indent}[{pair.key}] = {pair.value};`)
		end
		table.insert(lines, outer_indent .. "}")
		return table.concat(lines, "\n")
	else
		return `{type(x)}({tostring(x)})`
	end
end

local function tiniest_quote(x: unknown, given_indent_amount: number?): string
	return tiniest_quote_internal(x, given_indent_amount, {
		seen = {},
		nextId = 1,
	})
end

return tiniest_quote :: (unknown) -> string
