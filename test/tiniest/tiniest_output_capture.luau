-- From dphfox/tiniest, licensed under BSD
--!strict

--[=[
	@module TiniestOutputCapture

	Captures `print` and `warn` output produced by a function call by connecting to
	`LogService.MessageOut`. Requires a Roblox DataModel environment (Studio or a
	live server / client).

	> **Error checking** -- errors thrown *directly* in `fn` are caught by `pcall`
	> before they reach `LogService` and are stored in `CapturedOutput.fnError`.
	> Errors thrown in *other threads* spawned inside `fn` (e.g. via `task.spawn`)
	> are **not** caught by `pcall` and **do** arrive via `LogService.MessageOut`;
	> these are stored in `CapturedOutput.errors` and can be asserted with the
	> `error` field on `OutputSpec`.
	> For synchronous single-thread error checking, `fails` / `fails_with` in
	> `tiniest_expect` remain the direct approach.

	> **Pure Luau** -- overriding `_G.print` is unreliable for code that has already
	> captured `print` into a local before the override is applied. `setenv` /
	> `getenv` operate on OS environment variables, not Lua globals. For these
	> reasons the pure-Luau path is intentionally omitted.

	## Usage

	```lua
	local outputCapture = require("./tiniest_output_capture")

	local captured = outputCapture.captureOutput(function()
		print("hello")
		warn("something wrong")
	end)

	print(captured.prints) --> { "hello" }
	print(captured.warns)  --> { "something wrong" }
	print(captured.errors) --> {} (cross-thread errors only)
	print(captured.fnError) --> nil, or e.g. "Scripts/Foo:12: bad value"
	```

	### Timeout and early exit

	`fn` always runs in a `task.spawn` thread. After `fn` finishes, `captureOutput`
	waits up to `timeout` more seconds (default **0.5 s**) for any in-flight
	`LogService` events to arrive.

	Pass a `stopPredicate` to opt in to early exit: whenever a new message is
	captured (or immediately when `fn` finishes), the predicate is called. If it
	returns `true`, `captureOutput` stops waiting right away — the test does not
	have to sit through the remaining timeout.

	```lua
	-- Stop as soon as at least one print has been collected:
	local captured = outputCapture.captureOutput(fn, 1, function(c)
		return #c.prints > 0
	end)
	```
]=]

--- The captured output produced by a single function call.
export type CapturedOutput = {
	--- Lines emitted via `print(...)`.
	prints: { string },
	--- Lines emitted via `warn(...)`.
	warns: { string },
	--- Error messages from threads other than `fn`'s own thread (e.g. errors inside
	--- task.spawn calls made by `fn`). Direct errors from `fn` itself go to `fnError`.
	errors: { string },
	--- The error thrown directly by `fn`, caught by `pcall`. `nil` if `fn` succeeded.
	fnError: string?,
}

--- Describes what to look for in captured output. Per field:
---   `true`       -- at least one line of that kind must exist
---   `string`     -- at least one line must match the Lua pattern (case-insensitive)
---   `{string}`   -- for each pattern, at least one line must match
export type OutputSpec = {
	print: (true | string | { string })?,
	warn: (true | string | { string })?,
	error: (true | string | { string })?,
}

--[=[
	Captures all `print` and `warn` output produced by calling `fn`.

	`fn` is always run in a new thread via `task.spawn`. After `fn` completes,
	`captureOutput` waits at most `timeout` seconds (default 0.5) for any
	remaining `LogService` events to arrive.

	If `stopPredicate` is supplied it is called after each new message and
	immediately after `fn` finishes. On the first call that returns `true`
	`captureOutput` stops waiting and returns early, avoiding the rest of the
	timeout.

	@param fn () -> () -- The function to call and observe.
	@param timeout number? -- Max seconds to wait after `fn` finishes. Default 0.5.
	@param stopPredicate ((CapturedOutput) -> boolean)? -- Optional early-exit predicate.
	@return CapturedOutput -- A snapshot of what was printed, warned, and errored.
]=]
local function captureOutput(
	fn: () -> (),
	timeout: number?,
	stopPredicate: ((CapturedOutput) -> boolean)?
): CapturedOutput
	local LogService = (game :: any):GetService("LogService")
	local MessageType = (Enum :: any).MessageType
	local effectiveTimeout = timeout or 0.5

	local captured: CapturedOutput = { prints = {}, warns = {}, errors = {}, fnError = nil }
	local bindable = Instance.new("BindableEvent")
	local fired = false

	local function tryFire()
		if not fired then
			fired = true
			bindable:Fire()
		end
	end

	local conn = LogService.MessageOut:Connect(function(message: string, messageType: EnumItem)
		if messageType == MessageType.MessageOutput then
			table.insert(captured.prints, message)
		elseif messageType == MessageType.MessageWarning then
			table.insert(captured.warns, message)
		elseif messageType == MessageType.MessageError then
			table.insert(captured.errors, message)
		end
		-- After each new message, check if we can stop early.
		if stopPredicate and stopPredicate(captured) then
			tryFire()
		end
	end)

	task.spawn(function()
		local ok, err = pcall(fn)
		if not ok then
			-- Store but do not re-throw: the caller decides how to treat this.
			captured.fnError = tostring(err)
		end
		-- fn is done. Fire early if the predicate is already satisfied.
		if stopPredicate == nil or stopPredicate(captured) then
			tryFire()
		end
		-- Grace period: fire unconditionally after the timeout, covering the
		-- case where stopPredicate is nil (never_outputs) or never becomes true.
		task.delay(effectiveTimeout, tryFire)
	end)

	bindable.Event:Wait()
	conn:Disconnect()
	bindable:Destroy()

	return captured
end

return {
	captureOutput = captureOutput,
}
