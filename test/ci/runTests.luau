--!nonstrict
--[[
	test/ci/runTests.luau

	Entry point executed on a real Roblox server by the Open Cloud Luau Execution
	API. It runs inside the plain (uninstrumented) test place built by
	`tools/ci/run_tests.luau`, which mounts every `lib/<pkg>` under
	`ReplicatedStorage.src` and the tiniest framework under
	`ReplicatedStorage.test.tiniest` (see tools/ci/PlaceTree).

	Responsibilities:
		- Discover and run every `*.spec` ModuleScript under ReplicatedStorage.src
		  using tiniest's hierarchy collector.
		- Print the tiniest report (captured in the Open Cloud task logs).
		- error() at the end if anything failed, so the Open Cloud task is marked
		  FAILED and CI goes red.

	This is the plain "did the specs pass on real Roblox?" runner. It does NOT
	instrument or collect coverage -- that lives in the coverage system's own
	runner script.
]]

-- Replaced by tools/ci/run_tests.luau before upload: a package name to scope the
-- run to a single lib/<pkg>, or "" to run every package's specs. (The literal
-- token remains only if this file is somehow run without templating.)
local SCOPE_PACKAGE = "__SCOPE_PACKAGE__"

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local src = ReplicatedStorage:WaitForChild("src")
local tiniestFolder = ReplicatedStorage:WaitForChild("test"):WaitForChild("tiniest")

-- Scope collection to one package when requested, so an unrelated package's
-- unresolved deps can't abort the whole run.
local root: Instance = src
if SCOPE_PACKAGE ~= "" and not SCOPE_PACKAGE:match("^__") then
	root = src:FindFirstChild(SCOPE_PACKAGE)
		or error(`package '{SCOPE_PACKAGE}' not found under ReplicatedStorage.src`)
end

local tiniest = require(tiniestFolder.tiniest_for_roblox).configure({
	pretty = {
		trim_duplicate_trace = true,
		-- Show the full tree (passes included) so the CI log is a complete record.
		hide_passed_tests = false,
	},
})

-- Discover every spec under ReplicatedStorage.src, skipping vendored `_Index`
-- dependency trees (mirrors the coverage runner's ignore rules).
local tests = tiniest.collect_tests_from_hierarchy(root, {
	ignore = function(inst)
		if inst.Name == "_Index" then
			return true, true -- ignoreSelf, ignoreDescendants
		end
		return false, false
	end,
})

local result = tiniest.run_tests(tests, {})
local tally = result.status_tally

if tally.fail > 0 then
	-- A real error() (not just a printed line) marks the Open Cloud task FAILED,
	-- which the driver keys off to fail CI. The report above is already in the logs.
	error(`FAILED: {tally.pass} passed, {tally.fail} failed, {tally.skipped} skipped`, 0)
end
