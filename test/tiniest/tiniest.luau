-- From dphfox/tiniest, licensed under BSD
--!strict

--[=[
	@class Tiniest
	
	Core testing framework that provides the fundamental test definition and execution functionality.
	
	This is typically not used directly - instead use `tiniest_for_roblox` which wraps this
	with Roblox-specific features and better defaults.
]=]

local tiniest_plugin = require("./tiniest_plugin")

pcall(function()
	task = require("@lune/task") -- override for Roblox environment
end)

type DescribeContext = {
	type: "describe",
	labels: { string },
	is_focused: boolean,
	add_test: (Test) -> (),
}

type RunContext = {
	type: "run",
}

type Context = DescribeContext | RunContext

export type ErrorReport = {
	type: "tiniest.ErrorReport",
	line: number,
	source: string,
	message: string,
	trace: string,
	code: {
		snippet: string,
		line: string,
	}?,
	context: { { label: string, value: any } }?,
}

export type Test = {
	labels: { string },
	run: (Context) -> (),
	is_focused: boolean,
}

export type RunResult = {
	tests: { Test },
	status_tally: {
		pass: number,
		fail: number,
		skipped: number,
	},
	individual: { [Test]: TestRunResult },
}

export type TestRunResult = PassTestRunResult | FailTestRunResult

export type PassTestRunResult = {
	status: "pass",
}

export type FailTestRunResult = {
	status: "fail",
	error: ErrorReport,
}

export type Options = {
	plugins: nil | { tiniest_plugin.Plugin },
}

export type RunOptions = {
	timeout_diagnostics: boolean | "always" | "on_error"?,
	-- In safe mode tests are run in isolated threads to protect against crashes and timeouts, but it
	-- may produce less accurate error reports for certain failure types and improper timing results.
	-- Tests will also take longer to complete due to thread overhead and serialized execution.
	safe_mode: boolean?,
	fail_fast: boolean?,
	timeout_seconds: number?, -- only available in safe mode
}

local function catch_errors(func: any, ...)
	local outer_trace = ""
	local function handler(message)
		local report: ErrorReport
		if typeof(message) == "table" and message.type == "tiniest.ErrorReport" then
			report = message :: ErrorReport
		else
			local source, line = debug.info(2, "sl")
			report = {
				type = "tiniest.ErrorReport",
				line = line,
				source = source,
				message = tostring(message),
				trace = debug.traceback(nil, 2), -- This is the traceback when the test actually errors instead of fails
			}
		end
		local from, to = string.find(report.trace, outer_trace, 1, true)
		if from ~= nil and to ~= nil then
			report.trace = report.trace:sub(1, from - 1) .. report.trace:sub(to + 1)
		end
		return report
	end
	outer_trace = debug.traceback()
	return xpcall(func, handler, ...)
end

local tiniest = {}

function tiniest.configure(options: Options)
	local plugins = tiniest_plugin.configure(options.plugins)

	local function rethrow(err: any, simplify_report: boolean): ()
		if simplify_report and typeof(err) == "table" and err.type == "tiniest.ErrorReport" then
			local report = err :: ErrorReport
			error(report.message, 0)
		end
		error(err, 0)
	end

	local get_context, with_root_context, with_inner_context, reset_context
	do
		local current_context: Context? = nil

		function get_context(): Context
			assert(current_context ~= nil, "This function can only be called from inside of a test suite")
			return current_context
		end

		function with_root_context(root_context: Context, inner: (Context) -> ()): ()
			assert(current_context == nil, "This function can't be called from inside of a test suite")
			current_context = root_context
			local ok, err = catch_errors(inner :: any, root_context)
			current_context = nil
			if not ok then
				-- For collection-time failures, surface a concise message at the public boundary.
				rethrow(err, root_context.type == "describe")
			end
		end

		function with_inner_context(make_context: (Context) -> Context, inner: (Context) -> ()): ()
			local outer_context = get_context()
			local inner_context = make_context(outer_context)
			current_context = inner_context
			local ok, err = catch_errors(inner :: any, inner_context)
			current_context = outer_context
			if not ok then
				-- Preserve the structured error so outer handlers can trim internal frames correctly.
				rethrow(err, false)
			end
		end

		function reset_context(): ()
			current_context = nil
		end
	end

	local self = {}

	local function build_unexpected_termination_error(test: Test): ErrorReport
		return {
			type = "tiniest.ErrorReport",
			line = 0,
			source = table.concat(test.labels, " > "),
			message = `Test worker terminated before reporting a result: {table.concat(test.labels, " > ")}`,
			trace = "Worker coroutine became dead before the test runner received completion.",
		}
	end

	local function build_watchdog_timeout_error(test: Test, seconds: number): ErrorReport
		return {
			type = "tiniest.ErrorReport",
			line = 0,
			source = table.concat(test.labels, " > "),
			message = `Watchdog timeout after {seconds}s: {table.concat(test.labels, " > ")}`,
			trace = "Worker did not complete within watchdog timeout window.",
		}
	end

	local function normalize_test_run_result(test: Test, value: any): TestRunResult
		if typeof(value) == "table" and (value.status == "pass" or value.status == "fail") then
			return value :: TestRunResult
		end

		local fail: TestRunResult = {
			status = "fail",
			error = {
				type = "tiniest.ErrorReport",
				line = 0,
				source = table.concat(test.labels, " > "),
				message = `Runner produced invalid test result payload ({typeof(value)}).`,
				trace = tostring(value),
			},
		}
		return fail
	end

	local function is_watchdog_failure(result: TestRunResult): boolean
		if result.status ~= "fail" then
			return false
		end
		local message = result.error.message
		return string.find(message, "Test worker terminated before reporting a result", 1, true) ~= nil
			or string.find(message, "Watchdog timeout after", 1, true) ~= nil
	end

	local function run_single_test(
		test: Test,
		context: Context,
		run_options: RunOptions,
		diagnostics_enabled: boolean,
		diagnostics_on_error_only: boolean
	): TestRunResult
		if diagnostics_enabled and not diagnostics_on_error_only then
			print(`[tiniest] Running: {table.concat(test.labels, " > ")}`)
		end

		local function run_test_body(): (boolean, TestRunResult)
			return xpcall(function()
				with_root_context(context, test.run)
				local pass: TestRunResult = {
					status = "pass",
				}
				return pass
			end, function(message)
				if diagnostics_enabled and diagnostics_on_error_only then
					warn(`[tiniest] Error in: {table.concat(test.labels, " > ")}`)
				end

				if typeof(message) == "table" and message.type == "tiniest.ErrorReport" then
					local fail: TestRunResult = {
						status = "fail",
						error = message :: ErrorReport,
					}
					return fail
				else
					local source, line = debug.info(1, "sl")
					local error: ErrorReport = {
						type = "tiniest.ErrorReport",
						line = line,
						source = source,
						message = tostring(message),
						trace = debug.traceback(),
					}
					local fail: TestRunResult = {
						status = "fail",
						error = error,
					}
					return fail
				end
			end)
		end

		if run_options.safe_mode ~= true then
			local _, test_run_result = run_test_body()
			return normalize_test_run_result(test, test_run_result)
		end

		local test_run_result: TestRunResult? = nil
		local worker_finished = false
		local worker_thread: thread? = nil
		local started_at = os.clock()
		local timeout_seconds = run_options.timeout_seconds or 60

		-- print(`[tiniest] Starting test with watchdog: {table.concat(test.labels, " > ")}`)
		task.defer(function()
			worker_thread = coroutine.running()
			local _, worker_result = run_test_body()
			test_run_result = normalize_test_run_result(test, worker_result)
			worker_finished = true
		end)

		while true do
			if worker_finished and test_run_result ~= nil then
				-- print(`[tiniest] Completed: {table.concat(test.labels, " > ")} - {test_run_result.status}`)
				return test_run_result
			end

			if worker_thread ~= nil and coroutine.status(worker_thread) == "dead" then
				reset_context()
				warn(`[tiniest] Watchdog detected terminated worker: {table.concat(test.labels, " > ")}`)
				local fail: TestRunResult = {
					status = "fail",
					error = build_unexpected_termination_error(test),
				}
				return fail
			end

			if os.clock() - started_at >= timeout_seconds then
				reset_context()
				if diagnostics_enabled then
					warn(`[tiniest] Watchdog timeout after {timeout_seconds}s: {table.concat(test.labels, " > ")}`)
				end
				local fail: TestRunResult = {
					status = "fail",
					error = build_watchdog_timeout_error(test, timeout_seconds),
				}
				return fail
			end

			task.wait()
		end
	end

	--[=[
		Creates a nested test suite with the given label.
		
		All tests and nested describes within the inner function will be grouped under this label.
		This allows for organizing tests hierarchically.
		
		@param label string -- The name/label for this test suite
		@param inner (Context) -> () -- Function containing test definitions
		
		## Example
		```lua
		describe("Player System", function()
			describe("Health", function()
				test("should start at 100", function()
					expect(player.Health).is(100)
				end)
			end)
			
			describe("Stamina", function()
				test("should decrease when running", function()
					-- test implementation
				end)
			end)
		end)
		```
	]=]
	function self.describe(label: string, inner: (Context) -> ()): ()
		with_inner_context(function(outer_context: Context): Context
			assert(outer_context.type == "describe", "This function can only be called outside of tests")
			local context = table.clone(outer_context)
			context.labels = table.clone(context.labels)
			table.insert(context.labels, label)
			return context
		end, inner)
	end

	-- Marks the current describe scope as focused so only its descendant tests run in focus mode.
	function self.FOCUS(): ()
		local context = get_context()
		assert(context.type == "describe", "This function can only be called outside of tests")
		context.is_focused = true
	end

	--[=[
		Defines an individual test case.
		
		Must be called within a describe block. The test will be executed when run_tests is called.
		
		@param label string -- The name/description of what this test does
		@param run (Context) -> () -- Function containing the test logic and assertions
		
		## Example
		```lua
		test("should add two numbers correctly", function()
			local result = add(2, 3)
			expect(result).is(5)
		end)
		
		test("should handle negative numbers", function()
			local result = add(-5, 3)
			expect(result).is(-2)
		end)
		```
	]=]
	function self.test(label: string, run: (Context) -> ()): ()
		assert(typeof(label) == "string", "Test label must be a string")
		assert(label ~= "", "Test Label should not be empty")
		assert(typeof(run) == "function", "Test body must be a function")
		local context = get_context()
		assert(context.type == "describe", "This function can only be called outside of tests")
		local labels = table.clone(context.labels)
		table.insert(labels, label)
		local test: Test = {
			labels = labels,
			run = run,
			is_focused = context.is_focused,
		}
		context.add_test(test)
	end

	--[=[
		Collects all tests defined within the inner function.
		
		Executes the inner function in a special context that captures all describe/test calls
		and returns them as an array of Test objects that can be passed to run_tests.
		
		@param inner (Context) -> () -- Function containing describe/test definitions
		@return {Test} -- Array of collected test objects
		
		## Example
		```lua
		local tests = collect_tests(function()
			describe("Math", function()
				test("addition", function()
					expect(1 + 1).is(2)
				end)
			end)
		end)
		
		local results = run_tests(tests, {})
		```
	]=]
	function self.collect_tests(inner: (Context) -> ()): { Test }
		local tests = {}
		local context: Context = {
			type = "describe",
			labels = {},
			is_focused = false,
			add_test = function(test)
				table.insert(tests, test)
			end,
		}
		with_root_context(context, inner)
		return tests
	end

	--[=[
		Executes the given array of tests and returns the results.
		
		Each test is run in isolation with error handling. Results include pass/fail status,
		error reports for failures, and aggregated statistics.
		
		@param tests {Test} -- Array of tests to run (typically from collect_tests)
		@param run_options RunOptions -- Configuration options for the test run
		@return RunResult -- Object containing test results and statistics
		
		## RunResult Structure
		- `tests: {Test}` -- The tests that were run
		- `status_tally: {pass: number, fail: number}` -- Count of passed and failed tests
		- `individual: {[Test]: TestRunResult}` -- Individual result for each test
		
		## Example
		```lua
		local tests = collect_tests(function()
			describe("Suite", function()
				test("passes", function()
					expect(true).is_true()
				end)
				test("fails", function()
					expect(false).is_true()
				end)
			end)
		end)
		
		local results = run_tests(tests, {})
		print(`Passed: {results.status_tally.pass}`)
		print(`Failed: {results.status_tally.fail}`)
		```
	]=]
	function self.run_tests(tests: { Test }, run_options: RunOptions): RunResult
		local thread = coroutine.running()
		local FINISHED_SUCCESSFULLY = false
		task.defer(function()
			while not FINISHED_SUCCESSFULLY do
				if coroutine.status(thread) == "dead" then
					warn(
						"[tiniest] Worker thread terminated unexpectedly during run. Enable 'safe_mode' in the run options for more info."
					)
					return
				end
				task.wait()
			end
		end)

		local has_focused = false
		for _, test in tests do
			if test.is_focused then
				has_focused = true
				break
			end
		end

		local tests_to_run: { Test } = tests
		if has_focused then
			tests_to_run = {}
			for _, test in tests do
				if test.is_focused then
					table.insert(tests_to_run, test)
				end
			end
		end

		plugins.notify("before_run", tests_to_run, run_options)

		local diagnostics_mode = run_options.timeout_diagnostics
		local diagnostics_enabled = diagnostics_mode == true
			or diagnostics_mode == "always"
			or diagnostics_mode == "on_error"
		local diagnostics_on_error_only = diagnostics_mode == "on_error"

		local context: Context = {
			type = "run",
		}

		local individual: { [Test]: TestRunResult } = {}
		local tests_executed = 0
		for _, test in tests_to_run do
			-- Defensive reset so a timed-out worker cannot poison subsequent runs.
			reset_context()
			plugins.notify("before_test", test, run_options)
			local test_run_result =
				run_single_test(test, context, run_options, diagnostics_enabled, diagnostics_on_error_only)
			plugins.notify("after_test", test, test_run_result, run_options)
			individual[test] = test_run_result
			tests_executed += 1

			if run_options.fail_fast and is_watchdog_failure(test_run_result) then
				if diagnostics_enabled then
					warn("[tiniest] Aborting run after watchdog failure (fail-fast enabled).")
				end
				break
			end
		end
		FINISHED_SUCCESSFULLY = true

		local skipped_count = #tests - tests_executed

		local status_tally = {
			pass = 0,
			fail = 0,
			skipped = skipped_count,
		}

		for _, result in individual do
			if result.status == "pass" then
				status_tally.pass += 1
			else
				status_tally.fail += 1
			end
		end

		local result: RunResult = {
			tests = tests_to_run,
			status_tally = status_tally,
			individual = individual,
		}
		plugins.notify("after_run", result, run_options)

		return result
	end

	return self
end

return tiniest
