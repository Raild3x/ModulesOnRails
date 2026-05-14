-- From dphfox/tiniest, licensed under BSD
--!strict

--[=[
	@class TiniestContext

	Manages a per-test stack of labeled context entries. Context entries are
	automatically cleared between tests and optionally displayed when an
	expectation fails.

	Exposed on the configured testing instance as `t.context`.

	## Example Usage
	```lua
	return function(t)
		t.test("processes items correctly", function()
			local items = { "a", "b", "c" }
			for i, item in items do
				t.context.set("i", i)
				t.context.set("item", item)
				t.expect(process(item)).is("ok")
			end
		end)
	end
	```
]=]

export type Entry = {
	id: any,
	data: any,
	is_anonymous: boolean,
}

local tiniest_context = {}
tiniest_context.is_tiniest_plugin = true

local stack: { Entry } = {}

function tiniest_context.before_test(): ()
	tiniest_context.clear()
end

--[=[
	Pushes a new context entry onto the stack.

	When called with a single argument, the entry is **anonymous** — a unique
	symbol is generated for its id and returned. When called with two arguments,
	the first is used as a named id.

	@param id_or_data any -- The id (named) or the data value (anonymous)
	@param data any? -- The data value; if nil, treats id_or_data as anonymous data
	@return any -- The id for named entries, or a unique symbol for anonymous entries

	## Example
	```lua
	-- Named entry:
	t.context.push("iteration", i)

	-- Anonymous entry (symbol returned for later use):
	local sym = t.context.push(someComputedValue)
	```
]=]
function tiniest_context.push(id_or_data: any, data: any?): any
	if data == nil then
		local symbol = {} -- unique table reference acts as anonymous id
		local entry: Entry = {
			id = symbol,
			data = id_or_data,
			is_anonymous = true,
		}
		table.insert(stack, entry)
		return symbol
	else
		local entry: Entry = {
			id = id_or_data,
			data = data,
			is_anonymous = false,
		}
		table.insert(stack, entry)
		return id_or_data
	end
end

--[=[
	Updates the data of the most recent entry with the given id in-place.
	If no entry with that id exists, pushes a new named entry.

	Useful inside loops where you want to update a slot on each iteration
	rather than growing the stack.

	@param id any -- The id of the entry to update or create
	@param data any -- The new data value

	## Example
	```lua
	for i, item in items do
		t.context.set("i", i)       -- updates the same slot each iteration
		t.context.set("item", item)
		t.expect(process(item)).is("ok")
	end
	```
]=]
function tiniest_context.set(id: any, data: any): ()
	for i = #stack, 1, -1 do
		if stack[i].id == id then
			stack[i].data = data
			return
		end
	end
	local entry: Entry = { id = id, data = data, is_anonymous = false }
	table.insert(stack, entry)
end

--[=[
	Returns the most recent entry on the stack, or the most recent entry
	matching each given id when ids are provided.

	@param ... any -- Optional ids to match; if none, returns the most recent entry
	@return {Entry} -- Array of matching entries

	## Example
	```lua
	local latest = t.context.get()
	local entry = t.context.get("myId")
	```
]=]
function tiniest_context.get(...: any): { Entry }
	local ids = { ... }
	if #ids == 0 then
		local entry = stack[#stack]
		return if entry ~= nil then { entry } else {}
	end
	local results: { Entry } = {}
	for _, id in ids do
		for i = #stack, 1, -1 do
			if stack[i].id == id then
				table.insert(results, stack[i])
				break
			end
		end
	end
	return results
end

--[=[
	Returns all context entries on the stack.
	When ids are provided, returns only entries whose id matches any of them,
	preserving stack order.

	@param ... any -- Optional ids to filter by; if none, returns all entries
	@return {Entry} -- Array of matching entries in stack order

	## Example
	```lua
	local all = t.context.get_all()
	local subset = t.context.get_all("a", "b")
	```
]=]
function tiniest_context.get_all(...: any): { Entry }
	local ids = { ... }
	if #ids == 0 then
		return table.clone(stack)
	end
	local id_set: { [any]: boolean } = {}
	for _, id in ids do
		id_set[id] = true
	end
	local results: { Entry } = {}
	for _, entry in stack do
		if id_set[entry.id] then
			table.insert(results, entry)
		end
	end
	return results
end

--[=[
	Removes the most recent context entry from the stack.
	When ids are provided, removes the most recent entry matching each id.

	@param ... any -- Optional ids to match; if none, removes the most recent entry
]=]
function tiniest_context.pop(...: any): ()
	local ids = { ... }
	if #ids == 0 then
		table.remove(stack)
		return
	end
	for _, id in ids do
		for i = #stack, 1, -1 do
			if stack[i].id == id then
				table.remove(stack, i)
				break
			end
		end
	end
end

--[=[
	Removes all context entries from the stack.
]=]
function tiniest_context.clear(): ()
	table.clear(stack)
end

return tiniest_context
