-- Quick navmesh spec run (no coverage instrumentation), for iterating: every
-- lib/navmesh/src/Tests/*.spec.luau, failures only. The gate is still
-- `lune run coverage.luau package=navmesh`. Run from the repo root:
--   lune run tools/navmesh/specs.luau
local fs = require("@lune/fs")
local tiniest = require("../../test/tiniest/tiniest_for_lune").configure {
	snapshot_path = "./test/__snapshots__",
	save_snapshots = false,
	pretty = { hide_passed_tests = true },
}
local dynRequire: any = require
local names = {}
for _, file in fs.readDir("lib/navmesh/src/Tests") do
	local name = file:match("^(.+%.spec)%.luau$")
	if name then
		table.insert(names, name)
	end
end
table.sort(names)
local tests = tiniest.collect_tests(function()
	for _, name in names do
		tiniest.describe("src/Tests/" .. name, function()
			dynRequire("../../lib/navmesh/src/Tests/" .. name)(tiniest)
		end)
	end
end)
local result = tiniest.run_tests(tests, { safe_mode = true })
print("PASS", result.status_tally.pass, "FAIL", result.status_tally.fail)
