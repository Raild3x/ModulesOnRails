--!strict
--[=[
	Runs the adapter specs (they are outside the `coverage_self` source root, `core/`, so
	the self-coverage run doesn't pick them up). From the repo root:

		lune run tools/coverage/lune/adapters/Tests/run.luau

	Exits non-zero when any spec fails.
]=]

local fs = require("@lune/fs")
local process = require("@lune/process")

local dynRequire: any = require
local ROOT = "../../../../../"
local SPEC_DIR = "tools/coverage/lune/adapters/Tests"

local tiniest = dynRequire(ROOT .. "test/tiniest/tiniest_for_lune").configure({
	pretty = { hide_passed_tests = false },
})

local specFiles = {}
for _, entry in fs.readDir(SPEC_DIR) do
	if entry:match("%.spec%.luau$") then
		table.insert(specFiles, entry)
	end
end
table.sort(specFiles)

local tests = tiniest.collect_tests(function()
	for _, file in specFiles do
		tiniest.describe(file, function()
			dynRequire("./" .. file:gsub("%.luau$", ""))(tiniest)
		end)
	end
end)

local result = tiniest.run_tests(tests, { safe_mode = true })
if result.status_tally.fail > 0 then
	process.exit(1)
end
