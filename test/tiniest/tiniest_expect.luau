-- From dphfox/tiniest, licensed under BSD
--!strict

--[=[
	@class TiniestExpect
	
	Provides assertion methods for testing. All assertions return the expectation object,
	allowing for method chaining.
	
	## Example Usage
	```lua
	local expect = require(path.to.tiniest_expect).expect
	
	-- Basic equality
	expect(5).is(5)
	expect("hello").is("hello")
	
	-- Type checking
	expect(myValue).is_a("number")
	expect(myFunction).is_a("function")
	
	-- Existence checking
	expect(myValue).exists()
	expect(nil).never_exists()
	
	-- Boolean assertions
	expect(true).is_true()
	expect(false).never_is_true()
	
	-- Table/userdata assertions
	expect(myTable).has_key("Health")
	expect(myTable).has_value(100)
	expect(myTable).never_has_key("InvalidKey")
	
	-- Function assertions
	expect(function() error("fail") end).fails()
	expect(function() error("specific error") end).fails_with("specific")
	expect(function() return true end).never_fails()
	```
]=]

local tiniest_quote = require("./tiniest_quote")
local outputCapture = require("./tiniest_output_capture")
local tiniest_context = require("./tiniest_context")

local tiniest_expect = {}

type Context = {
	target: unknown,
	test: string,
	params: { unknown },
	context_filter: { any }?,
}

local context: Context = {
	target = nil,
	test = "",
	params = {},
	context_filter = nil,
}

local function fail(message: string?): never
	local quoted = {}
	for index, param in context.params do
		quoted[index] = tiniest_quote(param)
	end
	local param_list = table.concat(quoted, ",")
	local source, line = debug.info(4, "sl")
	local resolved_context: { { label: string, value: any } }? = nil
	local filter = context.context_filter
	local entries: { tiniest_context.Entry }
	if filter ~= nil and #filter > 0 then
		entries = tiniest_context.get_all(table.unpack(filter))
	else
		entries = tiniest_context.get_all()
	end
	if #entries > 0 then
		local ctx: { { label: string, value: any } } = {}
		for _, entry in entries do
			local label: string = if entry.is_anonymous then "[?]" else tiniest_quote(entry.id)
			local value: any
			if typeof(entry.data) == "function" then
				local ok, result = pcall(entry.data, context.target)
				value = if ok then result else entry.data
			else
				value = entry.data
			end
			table.insert(ctx, { label = label, value = value })
		end
		resolved_context = ctx
	end
	error({
		type = "tiniest.ErrorReport",
		line = line,
		source = source,
		message = "Expectation not met" .. if message == nil then "" else `, because:\n{message}`,
		trace = debug.traceback(nil, 4), -- This is the traceback when an expectation fails
		code = {
			snippet = `expect({tiniest_quote(context.target)}).{context.test}({param_list})`,
			line = line,
		},
		context = resolved_context,
	}, 0)
end

local function check(condition: boolean, cause: string): ()
	if not condition then
		error(`Bad usage of expect().{context.test}()\nCause: {cause}`, 0)
	end
end

local function is_indexable(x: unknown): boolean
	return type(x) == "table" or type(x) == "userdata"
end

--[=[
	Creates an expectation object for the given value with chainable assertion methods.
	
	@param a any -- The value to create assertions for
	@return table -- An expectation object with assertion methods
	
	## Available Assertions
	
	### Existence
	- `.exists()` -- Asserts the value is not nil
	- `.never_exists()` -- Asserts the value is nil
	
	### Equality
	- `.is(b)` -- Asserts the value equals b using == comparison
	- `.never_is(b)` -- Asserts the value does not equal b
	
	### Boolean
	- `.is_true()` -- Asserts the value is true (must be boolean type)
	- `.never_is_true()` -- Asserts the value is false (must be boolean type)
	
	### Type Checking
	- `.is_a(type)` -- Asserts the value's typeof() matches the given type string
	- `.never_is_a(type)` -- Asserts the value's typeof() does not match
	
	### Table/Userdata
	- `.has_key(key)` -- Asserts the table/userdata has the given key
	- `.never_has_key(key)` -- Asserts the table/userdata does not have the key
	- `.has_value(value)` -- Asserts the table contains the value (uses table.find)
	- `.never_has_value(value)` -- Asserts the table does not contain the value
	
	### Functions
	- `.fails()` -- Asserts the function throws an error when called
	- `.never_fails()` -- Asserts the function does not throw an error
	- `.fails_with(message)` -- Asserts the function fails with an error containing the message (case-insensitive)
	- `.never_fails_with(message)` -- Asserts the function doesn't fail with the message

	### Output Capture
	### Output Capture (Roblox only, via `LogService.MessageOut`)
	Captures `print`, `warn`, and cross-thread `error` output.

	- Errors thrown **directly** in `fn` are caught by our `pcall` and stored in
	  `CapturedOutput.fnError`. They are NOT in the `error` spec field. Use
	  `fails` / `fails_with` if you only care about direct errors.
	- Errors thrown in **other threads** (e.g. inside a `task.spawn` inside `fn`)
	  are NOT caught by `pcall` and DO arrive via `LogService.MessageOut`. Those
	  go into `CapturedOutput.errors` and can be asserted with `spec.error`.

	`fn` runs in a new thread. After it finishes, `captureOutput` waits at most
	`timeout` seconds (default **0.5 s**) for in-flight `LogService` events.
	Both assertions exit as soon as their condition is decided, so tests never
	sit through the full timeout unnecessarily:
	- `outputs` exits as soon as all spec conditions are satisfied.
	- `never_outputs` exits as soon as any violation is detected (for fast
	  failure), but must wait the full timeout to confirm success.

	Spec field values (`print`, `warn`, `error`):
	- `true`        -- at least one line of that kind must exist
	- `"pattern"`   -- at least one line must match the Lua pattern (case-insensitive)
	- `{"p1","p2"}` -- for *each* pattern, at least one line must match

	If `fn` itself throws (i.e. `fnError` is set), a note is appended to any
	failure message automatically. `fnError` is informational and does not by
	itself cause `outputs` / `never_outputs` to fail.

	- `.outputs(spec, timeout?)` -- Asserts all spec conditions are met
	- `.never_outputs(spec, timeout?)` -- Asserts none of the spec conditions are met

	Shorthands (equivalent to `outputs`/`never_outputs` with a single-field spec):
	- `.prints(pattern?, timeout?)` -- Asserts `fn` prints something (matching `pattern` if given)
	- `.never_prints(pattern?, timeout?)` -- Asserts `fn` does not print (or not matching `pattern`)
	- `.warns(pattern?, timeout?)` -- Asserts `fn` warns something
	- `.never_warns(pattern?, timeout?)` -- Asserts `fn` does not warn
	- `.errors(pattern?, timeout?)` -- Asserts a cross-thread error is logged
	- `.never_errors(pattern?, timeout?)` -- Asserts no cross-thread error is logged
	
	## Examples
	```lua
	-- Chain multiple assertions
	expect(myPlayer).exists().is_a("Instance")
	
	-- Test function behavior
	expect(function() 
		return MyModule.DivideByZero(10, 0) 
	end).fails_with("cannot divide")
	
	-- Test table contents
	expect(inventory).has_key("Gold").has_value(100)
	```
]=]
function tiniest_expect.expect(a: any)
	local tests = {}
	context.context_filter = nil

	local function check_type(expectedType: string, value: any, msg: string?): ()
		if msg ~= nil then
			msg ..= ": "
		end
		check(
			typeof(value) == expectedType,
			`{msg or ""}Expected type '{expectedType}' but got type '{typeof(value)}' for value: {tiniest_quote(value)}`
		)
	end

	function tests.exists()
		return if a ~= nil then tests else fail()
	end

	function tests.never_exists()
		return if a == nil then tests else fail()
	end

	function tests.is(b: any)
		return if a == b then tests else fail(`Got '{tiniest_quote(a)}' but expected it to be '{tiniest_quote(b)}'`)
	end

	function tests.is_not(b: any)
		return if a ~= b then tests else fail(`Got '{tiniest_quote(a)}' but expected it to not be '{tiniest_quote(b)}'`)
	end

	function tests.never_is(b: any)
		return if a ~= b then tests else fail(`Got '{tiniest_quote(a)}' but expected it to not be '{tiniest_quote(b)}'`)
	end

	function tests.is_shallow_equal(b: { [any]: any })
		check(typeof(a) == "table", "expect() value must be a table")
		check(typeof(b) == "table", "is_shallow_equal() value must be a table")
		local failureReasons = {}
		local checkedKeys = {}
		for k, v in a do
			if b[k] ~= v then
				table.insert(
					failureReasons,
					`Key [{tiniest_quote(k)}] is not equivalent. Got {tiniest_quote(v)} and {tiniest_quote(b[k])}.`
				)
			end
			checkedKeys[k] = true
		end
		for k, v in b do
			if a[k] ~= v and checkedKeys[k] ~= true then
				table.insert(
					failureReasons,
					`Key [{tiniest_quote(k)}] is not equivalent. Got {tiniest_quote(a[k])} and {tiniest_quote(v)}.`
				)
			end
		end
		return if #failureReasons == 0 then tests else fail(table.concat(failureReasons, "\n"))
	end

	function tests.is_deep_equal(b: { [any]: any })
		check(typeof(a) == "table", "expect() value must be a table")
		check(typeof(b) == "table", "is_deep_equal() value must be a table")
		local failureReasons = {}
		local checkedKeys = {}
		local function deep_check(a: any, b: any, path: string)
			for k, v in a do
				local new_path = path .. "[" .. tiniest_quote(k) .. "]"
				checkedKeys[new_path] = true

				if typeof(v) == "table" and typeof(b[k]) == "table" then
					deep_check(v, b[k], new_path)
				elseif b[k] ~= v then
					table.insert(
						failureReasons,
						`Key {new_path} is not equivalent. Got {tiniest_quote(v)} and {tiniest_quote(b[k])}.`
					)
				end
			end
			for k, v in b do
				local new_path = path .. "[" .. tiniest_quote(k) .. "]"
				if checkedKeys[new_path] ~= true and a[k] ~= v then
					table.insert(
						failureReasons,
						`Key {new_path} is not equivalent. Got {tiniest_quote(a[k])} and {tiniest_quote(v)}.`
					)
				end
			end
		end

		deep_check(a, b, "")
		return if #failureReasons == 0 then tests else fail(table.concat(failureReasons, "\n"))
	end

	function tests.is_true()
		check_type("boolean", a, "is_true()")
		return if a then tests else fail()
	end

	function tests.never_is_true()
		check_type("boolean", a, "never_is_true()")
		return if not a then tests else fail()
	end

	function tests.is_a(b: string)
		return if typeof(a) == b
			then tests
			else fail(
				`Expected '{tiniest_quote(a)}' to be type of '{tiniest_quote(b)}'. Got typeof '{tiniest_quote(a)}' instead.`
			)
	end

	function tests.never_is_a(b: string)
		return if typeof(a) ~= b
			then tests
			else fail(`Expected '{tiniest_quote(a)}' to not be type of '{tiniest_quote(b)}'`)
	end

	function tests.has_key(b: any)
		check(is_indexable(a), "expect() value must be indexable")
		check(b ~= nil, "key cannot be nil")
		return if a[b] then tests else fail()
	end

	function tests.never_has_key(b: any)
		check(is_indexable(a), "expect() value must be indexable")
		check(b ~= nil, "key cannot be nil")
		return if not a[b] then tests else fail(`[{tiniest_quote(b)}] = {tiniest_quote(a[b])}`)
	end

	function tests.has_value(b: any)
		check(typeof(a) == "table", "expect() value must be table")
		check(b ~= nil, "value cannot be nil")
		return if table.find(a, b) then tests else fail()
	end

	function tests.never_has_value(b: any)
		check(typeof(a) == "table", "expect() value must be table")
		check(b ~= nil, "value cannot be nil")
		local index = table.find(a, b)
		return if index == nil then tests else fail(`Found at index {index}`)
	end

	function tests.fails()
		check(typeof(a) == "function", "expect() value must be function")
		local ok = pcall(a)
		return if not ok then tests else fail()
	end

	function tests.never_fails()
		check(typeof(a) == "function", "expect() value must be function")
		local ok, err = pcall(a)
		return if ok then tests else fail(`Failed with {tiniest_quote(err)}`)
	end

	function tests.fails_with(b: string)
		check(typeof(a) == "function", "expect() value must be function")
		local ok, err = pcall(a)
		return if not ok and err:lower():match(b:lower())
			then tests
			else if ok then fail("Did not fail") else fail(`Failed with {tiniest_quote(err)}`)
	end

	function tests.never_fails_with(b: string)
		check(typeof(a) == "function", "expect() value must be function")
		local ok, err = pcall(a)
		return if ok or not err:lower():match(b:lower()) then tests else fail()
	end

	-- ── Output-capture helpers ──────────────────────────────────────────────────────

	local function describeCaptured(lines: { string }): string
		return if #lines > 0 then table.concat(lines, "; ") else "(nothing)"
	end

	local function findMatch(lines: { string }, pattern: string): string?
		local lower = pattern:lower()
		for _, line in lines do
			if line:lower():match(lower) then
				return line
			end
		end
		return nil
	end

	--- Applies one spec field against `lines`, appending any failure reason.
	--- `negate` flips the logic for `never_outputs`.
	local function checkSpecField(
		specValue: (true | string | { string })?,
		lines: { string },
		kind: string,
		failures: { string },
		negate: boolean
	): ()
		if specValue == nil then
			return
		end
		if specValue == true then
			if not negate and #lines == 0 then
				table.insert(failures, `Expected at least one {kind}, got none`)
			elseif negate and #lines > 0 then
				table.insert(failures, `Expected no {kind}s, but got: {describeCaptured(lines)}`)
			end
		elseif typeof(specValue) == "string" then
			local matched = findMatch(lines, specValue)
			if not negate and matched == nil then
				table.insert(failures, `No {kind} matched pattern '{specValue}'. Got: {describeCaptured(lines)}`)
			elseif negate and matched ~= nil then
				table.insert(failures, `{kind} matched pattern '{specValue}': '{matched}'`)
			end
		elseif typeof(specValue) == "table" then
			for _, pattern in specValue :: { string } do
				local matched = findMatch(lines, pattern)
				if not negate and matched == nil then
					table.insert(failures, `No {kind} matched pattern '{pattern}'. Got: {describeCaptured(lines)}`)
				elseif negate and matched ~= nil then
					table.insert(failures, `{kind} matched pattern '{pattern}': '{matched}'`)
				end
			end
		end
	end

	type OutputSpec = {
		print: (true | string | { string })?,
		warn: (true | string | { string })?,
		error: (true | string | { string })?,
	}

	--- Returns true when all conditions in `spec` are already satisfied by `captured`.
	--- Used as the `stopPredicate` for `outputs` so we exit as soon as we have everything.
	local function specSatisfied(spec: OutputSpec, captured: outputCapture.CapturedOutput): boolean
		if spec.print ~= nil then
			if spec.print == true then
				if #captured.prints == 0 then
					return false
				end
			elseif typeof(spec.print) == "string" then
				if findMatch(captured.prints, spec.print :: string) == nil then
					return false
				end
			else
				for _, p in spec.print :: { string } do
					if findMatch(captured.prints, p) == nil then
						return false
					end
				end
			end
		end
		if spec.warn ~= nil then
			if spec.warn == true then
				if #captured.warns == 0 then
					return false
				end
			elseif typeof(spec.warn) == "string" then
				if findMatch(captured.warns, spec.warn :: string) == nil then
					return false
				end
			else
				for _, p in spec.warn :: { string } do
					if findMatch(captured.warns, p) == nil then
						return false
					end
				end
			end
		end
		if spec.error ~= nil then
			if spec.error == true then
				if #captured.errors == 0 then
					return false
				end
			elseif typeof(spec.error) == "string" then
				if findMatch(captured.errors, spec.error :: string) == nil then
					return false
				end
			else
				for _, p in spec.error :: { string } do
					if findMatch(captured.errors, p) == nil then
						return false
					end
				end
			end
		end
		return true
	end

	--- Returns true as soon as any spec condition is violated by `captured`.
	--- Used as the `stopPredicate` for `never_outputs` so we fail fast.
	local function specViolated(spec: OutputSpec, captured: outputCapture.CapturedOutput): boolean
		if spec.print ~= nil then
			if spec.print == true then
				if #captured.prints > 0 then
					return true
				end
			elseif typeof(spec.print) == "string" then
				if findMatch(captured.prints, spec.print :: string) ~= nil then
					return true
				end
			else
				for _, p in spec.print :: { string } do
					if findMatch(captured.prints, p) ~= nil then
						return true
					end
				end
			end
		end
		if spec.warn ~= nil then
			if spec.warn == true then
				if #captured.warns > 0 then
					return true
				end
			elseif typeof(spec.warn) == "string" then
				if findMatch(captured.warns, spec.warn :: string) ~= nil then
					return true
				end
			else
				for _, p in spec.warn :: { string } do
					if findMatch(captured.warns, p) ~= nil then
						return true
					end
				end
			end
		end
		if spec.error ~= nil then
			if spec.error == true then
				if #captured.errors > 0 then
					return true
				end
			elseif typeof(spec.error) == "string" then
				if findMatch(captured.errors, spec.error :: string) ~= nil then
					return true
				end
			else
				for _, p in spec.error :: { string } do
					if findMatch(captured.errors, p) ~= nil then
						return true
					end
				end
			end
		end
		return false
	end

	local function appendFnError(captured: outputCapture.CapturedOutput, failures: { string }): ()
		if captured.fnError ~= nil then
			table.insert(failures, `(fn itself threw: {captured.fnError})`)
		end
	end

	function tests.outputs(spec: OutputSpec, timeout: number?)
		check(typeof(a) == "function", "expect() value must be function")
		local captured = outputCapture.captureOutput(a, timeout, function(c)
			return specSatisfied(spec, c)
		end)
		local failures: { string } = {}
		checkSpecField(spec.print, captured.prints, "print", failures, false)
		checkSpecField(spec.warn, captured.warns, "warn", failures, false)
		checkSpecField(spec.error, captured.errors, "error", failures, false)
		appendFnError(captured, failures)
		return if #failures == 0 then tests else fail(table.concat(failures, "\n"))
	end

	function tests.never_outputs(spec: OutputSpec, timeout: number?)
		check(typeof(a) == "function", "expect() value must be function")
		local captured = outputCapture.captureOutput(a, timeout, function(c)
			return specViolated(spec, c) -- stop early on first violation (fast failure)
		end)
		local failures: { string } = {}
		checkSpecField(spec.print, captured.prints, "print", failures, true)
		checkSpecField(spec.warn, captured.warns, "warn", failures, true)
		checkSpecField(spec.error, captured.errors, "error", failures, true)
		appendFnError(captured, failures)
		return if #failures == 0 then tests else fail(table.concat(failures, "\n"))
	end

	function tests.prints(pattern: (true | string | { string })?, timeout: number?)
		return tests.outputs({ print = pattern or true }, timeout)
	end

	function tests.never_prints(pattern: (true | string | { string })?, timeout: number?)
		return tests.never_outputs({ print = pattern or true }, timeout)
	end

	function tests.warns(pattern: (true | string | { string })?, timeout: number?)
		return tests.outputs({ warn = pattern or true }, timeout)
	end

	function tests.never_warns(pattern: (true | string | { string })?, timeout: number?)
		return tests.never_outputs({ warn = pattern or true }, timeout)
	end

	function tests.errors(pattern: (true | string | { string })?, timeout: number?)
		return tests.outputs({ error = pattern or true }, timeout)
	end

	function tests.never_errors(pattern: (true | string | { string })?, timeout: number?)
		return tests.never_outputs({ error = pattern or true }, timeout)
	end

	function tests.is_greater_than(b: number)
		check(typeof(a) == "number", "expect() value must be a number")
		check(typeof(b) == "number", "is_greater_than() value must be a number")
		return if a > b
			then tests
			else fail(`Got {tiniest_quote(a)} but expected it to be greater than {tiniest_quote(b)}`)
	end

	function tests.is_less_than(b: number)
		check(typeof(a) == "number", "expect() value must be a number")
		check(typeof(b) == "number", "is_less_than() value must be a number")
		return if a < b
			then tests
			else fail(`Got {tiniest_quote(a)} but expected it to be less than {tiniest_quote(b)}`)
	end

	function tests.is_greater_or_equal_to(b: number)
		check(typeof(a) == "number", "expect() value must be a number")
		check(typeof(b) == "number", "value must be a number")
		return if a >= b
			then tests
			else fail(`Got {tiniest_quote(a)} but expected it to be greater than or equal to {tiniest_quote(b)}`)
	end

	function tests.is_less_or_equal_to(b: number)
		check(typeof(a) == "number", "expect() value must be a number")
		check(typeof(b) == "number", "value must be a number")
		return if a <= b
			then tests
			else fail(`Got {tiniest_quote(a)} but expected it to be less than or equal to {tiniest_quote(b)}`)
	end

	for name: any, body: any in tests do
		tests[name] = function(...)
			context.target = a
			context.test = name
			context.params = { ... }
			return body(...)
		end
	end

	function tests.with_context(...: any)
		context.context_filter = { ... }
		return tests
	end

	return tests
end

export type expect = typeof(tiniest_expect.expect)

return tiniest_expect
